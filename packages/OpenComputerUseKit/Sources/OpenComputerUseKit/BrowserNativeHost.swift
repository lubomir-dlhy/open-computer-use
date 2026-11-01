import Darwin
import Foundation

/// Chrome's native-messaging host for the Open Computer Use Browser extension.
/// Chrome starts it with the extension's origin as the only argument and talks
/// length-prefixed JSON over stdin and stdout; the host relays that to local
/// clients on a Unix socket, renumbering request ids so several clients can share
/// the one extension connection. Adapted from open-browser-use's Go relay (MIT).
public enum BrowserNativeHost {
    public static let hostName = "sk.lubomirdlhy.opencomputeruse.browser"
    public static let extensionID = "lljfcieajkdnodcjjgfonlfjpnloecbo"

    static var socketDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenComputerUse/Browser", isDirectory: true)
    }

    public static func isInvocation(arguments: [String]) -> Bool {
        arguments.first == "browser-host" || arguments.first?.hasPrefix("chrome-extension://") == true
    }

    public static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let relay = Relay()
        do {
            try relay.serve()
        } catch {
            FileHandle.standardError.write(Data("open-computer-use browser-host: \(error)\n".utf8))
        }
        relay.shutdown()
        exit(0)
    }

    /// Writes Chrome's native-messaging manifest pointing at `executable` and copies
    /// the extension next to it, so Chrome loads it from a path that survives upgrades.
    public static func setup(executable: URL, extensionSource: URL?) throws -> String {
        let fileManager = FileManager.default
        let chromeHosts = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
        try fileManager.createDirectory(at: chromeHosts, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": hostName,
            "description": "Open Computer Use Browser",
            "path": executable.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        let manifestURL = chromeHosts.appendingPathComponent("\(hostName).json")
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: manifestURL)

        var lines = ["Native host: \(manifestURL.path) -> \(executable.path)"]
        if let extensionSource {
            let target = socketDirectory.deletingLastPathComponent().appendingPathComponent("BrowserExtension", isDirectory: true)
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: extensionSource, to: target)
            lines.append("Extension: \(target.path) (id \(extensionID))")
            lines.append("In Chrome open chrome://extensions, turn on Developer mode, choose Load unpacked and pick that folder.")
        }
        return lines.joined(separator: "\n")
    }

    private final class Relay: @unchecked Sendable {
        private let lock = NSLock()
        private let stdoutLock = NSLock()
        private var clients: [Int32: NSLock] = [:]
        private var clientSessions: [Int32: Set<String>] = [:]
        private var pending: [Int: (client: Int32, id: Any)] = [:]
        private var nextID = 1
        private var listener: Int32 = -1
        let socketPath = BrowserNativeHost.socketDirectory.appendingPathComponent("\(getpid()).sock").path

        func serve() throws {
            try FileManager.default.createDirectory(at: BrowserNativeHost.socketDirectory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            listener = try BrowserSocket.listen(path: socketPath)
            Thread.detachNewThread { [self] in acceptLoop() }
            while let frame = BrowserSocket.readFrame(fd: STDIN_FILENO) {
                fromExtension(frame)
            }
        }

        func shutdown() {
            unlink(socketPath)
            if listener >= 0 { close(listener) }
        }

        private func acceptLoop() {
            while true {
                let fd = accept(listener, nil, nil)
                guard fd >= 0 else {
                    if errno == EINTR { continue }
                    return
                }
                lock.withLock { clients[fd] = NSLock() }
                Thread.detachNewThread { [self] in
                    while let frame = BrowserSocket.readFrame(fd: fd) {
                        fromClient(fd, frame)
                    }
                    let sessions = lock.withLock { () -> Set<String> in
                        clients[fd] = nil
                        pending = pending.filter { $0.value.client != fd }
                        return clientSessions.removeValue(forKey: fd) ?? []
                    }
                    close(fd)
                    // A client that exits mid-turn still gets its tabs closed or released.
                    for session in sessions {
                        let message: [String: Any] = ["jsonrpc": "2.0", "method": "finalizeTabs", "params": ["session_id": session, "keep": []]]
                        if let data = try? JSONSerialization.data(withJSONObject: message) {
                            _ = stdoutLock.withLock { BrowserSocket.writeFrame(fd: STDOUT_FILENO, data) }
                        }
                    }
                }
            }
        }

        private func fromClient(_ fd: Int32, _ frame: Data) {
            guard var message = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] else { return }
            if let session = (message["params"] as? [String: Any])?["session_id"] as? String {
                lock.withLock { _ = clientSessions[fd, default: []].insert(session) }
            }
            if let id = message["id"] {
                message["id"] = lock.withLock { () -> Int in
                    defer { nextID += 1 }
                    pending[nextID] = (fd, id)
                    return nextID
                }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
            _ = stdoutLock.withLock { BrowserSocket.writeFrame(fd: STDOUT_FILENO, data) }
        }

        private func fromExtension(_ frame: Data) {
            guard var message = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] else { return }
            if message["method"] == nil, let id = message["id"] as? Int {
                guard let route = lock.withLock({ pending.removeValue(forKey: id) }),
                      let writeLock = lock.withLock({ clients[route.client] }) else { return }
                message["id"] = route.id
                guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
                _ = writeLock.withLock { BrowserSocket.writeFrame(fd: route.client, data) }
                return
            }
            let targets = lock.withLock { clients }
            for (fd, writeLock) in targets {
                _ = writeLock.withLock { BrowserSocket.writeFrame(fd: fd, frame) }
            }
        }
    }
}

/// Native-messaging framing: a 32-bit length in native byte order, then JSON.
enum BrowserSocket {
    static func readFrame(fd: Int32) -> Data? {
        guard let header = readExactly(fd: fd, count: 4) else { return nil }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard length <= 64 * 1024 * 1024 else { return nil }
        return readExactly(fd: fd, count: Int(length))
    }

    @discardableResult
    static func writeFrame(fd: Int32, _ payload: Data) -> Bool {
        var length = UInt32(payload.count)
        var data = Data(bytes: &length, count: 4)
        data.append(payload)
        return data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    private static func readExactly(fd: Int32, count: Int) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let received = data.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, count - offset) }
            if received < 0, errno == EINTR { continue }
            guard received > 0 else { return nil }
            offset += received
        }
        return data
    }

    static func listen(path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ComputerUseError.message("socket() failed: \(errno)") }
        var address = try socketAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 16) == 0 else {
            close(fd)
            throw ComputerUseError.message("cannot listen on \(path): \(errno)")
        }
        chmod(path, 0o600)
        return fd
    }

    static func connect(path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = try? socketAddress(path) else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private static func socketAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ComputerUseError.message("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }
}
