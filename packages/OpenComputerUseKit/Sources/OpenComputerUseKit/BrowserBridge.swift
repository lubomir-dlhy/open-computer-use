import Darwin
import Foundation

/// Client side of the browser extension's native host: one socket per process,
/// shared by every agent session, with per-session tab bookkeeping.
final class BrowserBridge: @unchecked Sendable {
    static let shared = BrowserBridge()

    private final class Waiter {
        let semaphore = DispatchSemaphore(value: 0)
        var response: [String: Any]?
    }

    private let lock = NSLock()
    private let writeLock = NSLock()
    private var fd: Int32 = -1
    private var nextID = 1
    private var waiters: [Int: Waiter] = [:]
    private var dialogs: [Int: [String: Any]] = [:]
    private var drags: [Int: [String: Any]] = [:]
    private var sessions: [Int: SessionState] = [:]

    struct SessionState {
        var currentTab: Int?
        var keep: [Int: String] = [:]
        var snapshots: [Int: [String]] = [:]
    }

    static func sessionID(_ owner: Int = SessionOwner.current) -> String {
        "ocu-\(getpid())-\(owner)"
    }

    func session<T>(_ owner: Int = SessionOwner.current, _ body: (inout SessionState) -> T) -> T {
        lock.withLock {
            var state = sessions[owner] ?? SessionState()
            defer { sessions[owner] = state }
            return body(&state)
        }
    }

    /// Sends one extension command; `params` gains the caller's session id.
    func call(_ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 15) throws -> Any {
        var params = params
        if params["session_id"] == nil { params["session_id"] = Self.sessionID() }
        let (id, waiter) = try lock.withLock { () -> (Int, Waiter) in
            if fd < 0 { try connect() }
            defer { nextID += 1 }
            let waiter = Waiter()
            waiters[nextID] = waiter
            return (nextID, waiter)
        }
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: message)
        let socket = lock.withLock { fd }
        guard writeLock.withLock({ BrowserSocket.writeFrame(fd: socket, data) }) else {
            lock.withLock { waiters[id] = nil }
            disconnect(socket)
            throw Self.unavailable
        }
        guard waiter.semaphore.wait(timeout: .now() + timeout) == .success, let response = waiter.response else {
            lock.withLock { waiters[id] = nil }
            throw ComputerUseError.stateUnavailable("Chrome did not answer \(method) within \(Int(timeout)) s")
        }
        if let error = response["error"] as? [String: Any] {
            throw ComputerUseError.stateUnavailable(error["message"] as? String ?? "Chrome reported an error")
        }
        return response["result"] ?? [:]
    }

    /// Runs a CDP command in a tab; the extension attaches its debugger on first use.
    @discardableResult
    func cdp(_ tab: Int, _ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 10) throws -> [String: Any] {
        let result = try call("executeCdp", ["tabId": tab, "method": method, "commandParams": params,
                                             "timeoutMs": Int(timeout * 1000)], timeout: timeout + 2)
        return result as? [String: Any] ?? [:]
    }

    func openDialog(tab: Int) -> [String: Any]? {
        lock.withLock { dialogs[tab] }
    }

    func takeDrag(tab: Int) -> [String: Any]? {
        lock.withLock { drags.removeValue(forKey: tab) }
    }

    /// Closes the session's own tabs, releases claimed ones and keeps marked ones.
    func endTurn(owner: Int) {
        guard let state = lock.withLock({ sessions.removeValue(forKey: owner) }) else { return }
        let keep = state.keep.map { ["tabId": $0.key, "status": $0.value] as [String: Any] }
        SessionOwner.with(owner) {
            _ = try? call("finalizeTabs", ["keep": keep], timeout: 5)
        }
    }

    /// Finalizes sessions whose Open Computer Use process exited without ending its turn.
    private func sweepEndedSessions() {
        guard let sessions = try? call("listSessions") as? [String] else { return }
        for session in sessions {
            let parts = session.split(separator: "-")
            guard parts.count == 3, parts[0] == "ocu", let pid = Int32(parts[1]), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
            _ = try? call("finalizeTabs", ["session_id": session, "keep": []], timeout: 5)
        }
    }

    static let unavailable = ComputerUseError.stateUnavailable(
        "Chrome is not connected. Install the Open Computer Use Browser extension (run `open-computer-use browser-setup`) and keep Chrome open."
    )

    private func connect() throws {
        let directory = BrowserNativeHost.socketDirectory
        let sockets = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "sock" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        for socket in sockets {
            if let connected = BrowserSocket.connect(path: socket.path) {
                fd = connected
                Thread.detachNewThread { [self] in readLoop(connected) }
                DispatchQueue.global().async { [self] in sweepEndedSessions() }
                return
            }
            if let pid = Int32(socket.deletingPathExtension().lastPathComponent), kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(at: socket)
            }
        }
        throw Self.unavailable
    }

    private func disconnect(_ socket: Int32) {
        let orphaned = lock.withLock { () -> [Waiter] in
            guard fd == socket else { return [] }
            fd = -1
            dialogs.removeAll()
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        close(socket)
        for waiter in orphaned {
            waiter.response = ["error": ["message": "Chrome disconnected"]]
            waiter.semaphore.signal()
        }
    }

    private func readLoop(_ socket: Int32) {
        while let frame = BrowserSocket.readFrame(fd: socket) {
            guard let message = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] else { continue }
            if let method = message["method"] as? String {
                notification(method, message["params"] as? [String: Any] ?? [:])
            } else if let id = message["id"] as? Int, let waiter = lock.withLock({ waiters.removeValue(forKey: id) }) {
                waiter.response = message
                waiter.semaphore.signal()
            }
        }
        disconnect(socket)
    }

    private func notification(_ method: String, _ params: [String: Any]) {
        guard method == "onCDPEvent", let tab = (params["source"] as? [String: Any])?["tabId"] as? Int,
              let event = params["method"] as? String else { return }
        let payload = params["params"] as? [String: Any] ?? [:]
        lock.withLock {
            switch event {
            case "Page.javascriptDialogOpening": dialogs[tab] = payload
            case "Page.javascriptDialogClosed": dialogs[tab] = nil
            case "Input.dragIntercepted": drags[tab] = payload["data"] as? [String: Any]
            default: break
            }
        }
    }
}
