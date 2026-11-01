import Darwin
import Foundation

/// Client side of the browser extension's native hosts: Chrome starts one host per
/// profile, so the bridge keeps one socket per profile, shared by every agent
/// session, and routes each call by tab, then by profile.
final class BrowserBridge: @unchecked Sendable {
    static let shared = BrowserBridge()

    private final class Waiter {
        let semaphore = DispatchSemaphore(value: 0)
        var response: [String: Any]?
    }

    final class Connection {
        let fd: Int32
        let path: String
        let writeLock = NSLock()
        var profile: BrowserProfile?

        init(fd: Int32, path: String) {
            self.fd = fd
            self.path = path
        }
    }

    private let lock = NSLock()
    private let scanLock = NSLock()
    private var connections: [String: Connection] = [:]
    private var lastScan = Date.distantPast
    private var nextID = 1
    private var waiters: [Int: (waiter: Waiter, path: String)] = [:]
    private var tabOwners: [Int: String] = [:]
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

    /// Sends one extension command to the profile owning `tabId`, else `profile`,
    /// else the session's current tab's profile, else the default profile.
    func call(_ method: String, _ params: [String: Any] = [:], profile: String? = nil, timeout: TimeInterval = 15) throws -> Any {
        var params = params
        if params["session_id"] == nil { params["session_id"] = Self.sessionID() }
        let connection = try route(params, profile: profile)
        let result = try send(connection, method, params, timeout: timeout)
        if ["createTab", "getTabs", "getUserTabs", "claimUserTab"].contains(method) { record(result, on: connection) }
        return result
    }

    /// Runs a CDP command in a tab; the extension attaches its debugger on first use.
    @discardableResult
    func cdp(_ tab: Int, _ method: String, _ params: [String: Any] = [:], timeout: TimeInterval = 10) throws -> [String: Any] {
        let result = try call("executeCdp", ["tabId": tab, "method": method, "commandParams": params,
                                             "timeoutMs": Int(timeout * 1000)], timeout: timeout + 2)
        return result as? [String: Any] ?? [:]
    }

    /// Connected profiles with the session's tabs and the user's tabs in each.
    func profiles() throws -> [(profile: BrowserProfile?, mine: [[String: Any]], all: [[String: Any]])] {
        let live = try refresh(force: true)
        let params: [String: Any] = ["session_id": Self.sessionID()]
        return live.map { connection in
            let mine = (try? send(connection, "getTabs", params, timeout: 5)) as? [[String: Any]] ?? []
            let all = (try? send(connection, "getUserTabs", params, timeout: 5)) as? [[String: Any]] ?? []
            record(all, on: connection)
            return (connection.profile, mine, all)
        }
    }

    func profile(ofTab tab: Int) -> BrowserProfile? {
        lock.withLock { tabOwners[tab].flatMap { connections[$0]?.profile } }
    }

    func openDialog(tab: Int) -> [String: Any]? {
        lock.withLock { dialogs[tab] }
    }

    func takeDrag(tab: Int) -> [String: Any]? {
        lock.withLock { drags.removeValue(forKey: tab) }
    }

    /// Closes the session's own tabs, releases claimed ones and keeps marked ones, in every profile.
    func endTurn(owner: Int) {
        guard let state = lock.withLock({ sessions.removeValue(forKey: owner) }) else { return }
        let keep = state.keep.map { ["tabId": $0.key, "status": $0.value] as [String: Any] }
        for connection in lock.withLock({ Array(connections.values) }) {
            _ = try? send(connection, "finalizeTabs", ["session_id": Self.sessionID(owner), "keep": keep], timeout: 5)
        }
    }

    static let unavailable = ComputerUseError.stateUnavailable(
        "Chrome is not connected. Install the Open Computer Use Browser extension (run `open-computer-use browser-setup`) and keep Chrome open."
    )

    // MARK: - Routing

    private func route(_ params: [String: Any], profile: String?) throws -> Connection {
        let live = try refresh()
        if let tab = params["tabId"] as? Int {
            if let owner = owner(of: tab) { return owner }
            for connection in live {
                if let list = try? send(connection, "getUserTabs", ["session_id": params["session_id"] ?? Self.sessionID()], timeout: 5) {
                    record(list, on: connection)
                }
            }
            if let owner = owner(of: tab) { return owner }
            throw ComputerUseError.invalidArguments("tab \(tab) is not open in a connected Chrome profile; see action tabs")
        }
        if let profile {
            return try connection(for: profile, in: live)
        }
        if let current = session(SessionOwner.current, { $0.currentTab }), let owner = owner(of: current) {
            return owner
        }
        if live.count > 1, let preferred = BrowserProfiles.defaultProfile(among: live.compactMap(\.profile)),
           let connection = live.first(where: { $0.profile == preferred }) {
            return connection
        }
        return live[0]
    }

    private func connection(for query: String, in live: [Connection]) throws -> Connection {
        if let match = BrowserProfiles.select(query, from: live.compactMap(\.profile)),
           let connection = live.first(where: { $0.profile == match }) {
            return connection
        }
        let installed = BrowserProfiles.installed()
        if let wanted = BrowserProfiles.select(query, from: installed) {
            throw ComputerUseError.stateUnavailable(
                "Chrome profile \(wanted.label) is not running; ask the user to open a Chrome window in it once (it then stays connected)"
            )
        }
        let known = installed.map(\.label).joined(separator: ", ")
        throw ComputerUseError.invalidArguments("no Chrome profile matches \"\(query)\"; profiles with the extension: \(known)")
    }

    private func owner(of tab: Int) -> Connection? {
        lock.withLock { tabOwners[tab].flatMap { connections[$0] } }
    }

    private func record(_ result: Any, on connection: Connection) {
        let tabs = (result as? [[String: Any]]) ?? (result as? [String: Any]).map { [$0] } ?? []
        let ids = tabs.compactMap { $0["id"] as? Int }
        guard !ids.isEmpty else { return }
        lock.withLock {
            for id in ids { tabOwners[id] = connection.path }
        }
    }

    // MARK: - Connections

    /// Connects to every host socket not yet connected; rescans at most once a second.
    @discardableResult
    private func refresh(force: Bool = false) throws -> [Connection] {
        try scanLock.withLock {
            if force || Date().timeIntervalSince(lastScan) > 1 || lock.withLock({ connections.isEmpty }) {
                lastScan = Date()
                for connection in connectNew() {
                    identify(connection)
                    DispatchQueue.global().async { [self] in sweepEndedSessions(connection) }
                }
            }
            let live = lock.withLock { Array(connections.values) }.sorted { $0.path < $1.path }
            guard !live.isEmpty else { throw Self.unavailable }
            return live
        }
    }

    private func connectNew() -> [Connection] {
        let directory = BrowserNativeHost.socketDirectory
        let sockets = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "sock" }
        var added: [Connection] = []
        for socket in sockets where lock.withLock({ connections[socket.path] == nil }) {
            guard let fd = BrowserSocket.connect(path: socket.path) else {
                if let pid = Int32(socket.deletingPathExtension().lastPathComponent), kill(pid, 0) != 0 {
                    try? FileManager.default.removeItem(at: socket)
                }
                continue
            }
            let connection = Connection(fd: fd, path: socket.path)
            lock.withLock { connections[socket.path] = connection }
            Thread.detachNewThread { [self] in readLoop(connection) }
            added.append(connection)
        }
        return added
    }

    private func identify(_ connection: Connection) {
        guard let info = try? send(connection, "getInfo", ["session_id": Self.sessionID()], timeout: 5) as? [String: Any],
              let token = info["profileToken"] as? String else { return }
        let profile = BrowserProfiles.profile(holding: token)
        lock.withLock { connection.profile = profile }
    }

    /// Finalizes sessions whose Open Computer Use process exited without ending its turn.
    private func sweepEndedSessions(_ connection: Connection) {
        guard let sessions = try? send(connection, "listSessions", ["session_id": Self.sessionID()], timeout: 5) as? [String] else { return }
        for session in sessions {
            let parts = session.split(separator: "-")
            guard parts.count == 3, parts[0] == "ocu", let pid = Int32(parts[1]), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
            _ = try? send(connection, "finalizeTabs", ["session_id": session, "keep": []], timeout: 5)
        }
    }

    private func send(_ connection: Connection, _ method: String, _ params: [String: Any], timeout: TimeInterval) throws -> Any {
        let (id, waiter) = lock.withLock { () -> (Int, Waiter) in
            defer { nextID += 1 }
            let waiter = Waiter()
            waiters[nextID] = (waiter, connection.path)
            return (nextID, waiter)
        }
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: message)
        guard connection.writeLock.withLock({ BrowserSocket.writeFrame(fd: connection.fd, data) }) else {
            lock.withLock { waiters[id] = nil }
            disconnect(connection)
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

    private func disconnect(_ connection: Connection) {
        let orphaned = lock.withLock { () -> [Waiter] in
            guard connections[connection.path] === connection else { return [] }
            connections[connection.path] = nil
            tabOwners = tabOwners.filter { $0.value != connection.path }
            let mine = waiters.filter { $0.value.path == connection.path }
            for id in mine.keys { waiters[id] = nil }
            return mine.values.map(\.waiter)
        }
        close(connection.fd)
        for waiter in orphaned {
            waiter.response = ["error": ["message": "Chrome disconnected"]]
            waiter.semaphore.signal()
        }
    }

    private func readLoop(_ connection: Connection) {
        while let frame = BrowserSocket.readFrame(fd: connection.fd) {
            guard let message = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] else { continue }
            if let method = message["method"] as? String {
                notification(method, message["params"] as? [String: Any] ?? [:])
            } else if let id = message["id"] as? Int, let entry = lock.withLock({ waiters.removeValue(forKey: id) }) {
                entry.waiter.response = message
                entry.waiter.semaphore.signal()
            }
        }
        disconnect(connection)
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
