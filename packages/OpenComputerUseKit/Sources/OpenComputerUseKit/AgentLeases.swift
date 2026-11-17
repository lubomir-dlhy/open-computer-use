import CoreGraphics
import Foundation

/// What an agent session works on. Apps that open several windows are shared by
/// window; apps with one main window (System Settings, Calculator, Notes) are
/// claimed whole, so only one agent drives them at a time.
enum LeasedResource: Hashable, CustomStringConvertible {
    case window(pid: pid_t, windowID: CGWindowID)
    case app(pid: pid_t)

    var pid: pid_t {
        switch self {
        case let .window(pid, _), let .app(pid): return pid
        }
    }

    func conflicts(with other: LeasedResource) -> Bool {
        guard pid == other.pid else { return false }
        switch (self, other) {
        case let (.window(_, lhs), .window(_, rhs)): return lhs == rhs
        default: return true
        }
    }

    var description: String {
        switch self {
        case let .window(pid, windowID): return "window \(windowID) of pid \(pid)"
        case let .app(pid): return "app pid \(pid)"
        }
    }
}

struct LeaseBusy: Error {
    let resource: LeasedResource
    let owner: Int
}

/// Lets several agents work at once: each claims the window or app it acts on
/// for its session, and waits while another session holds it. Input into one
/// process is serialized separately, for the length of a single call, because
/// synthetic focus and key state are per process.
final class AgentLeases: @unchecked Sendable {
    static let shared = AgentLeases()

    private struct Lease {
        let session: Int
        var lastUsed: Date
    }

    private let condition = NSCondition()
    private var leases: [LeasedResource: Lease] = [:]
    private var busyPIDs: Set<pid_t> = []
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Claims `resource` for `session` and runs `body` while holding the target
    /// process's input lock. Waits up to `wait` for another session's claim to end
    /// or go idle for `idleExpiry`.
    func perform<T>(
        _ resource: LeasedResource,
        session: Int,
        wait: TimeInterval,
        idleExpiry: TimeInterval,
        _ body: () throws -> T
    ) throws -> T {
        let deadline = now().addingTimeInterval(wait)
        condition.lock()
        while true {
            dropExpired(idleExpiry: idleExpiry)
            let blocker = leases.first { $0.key.conflicts(with: resource) && $0.value.session != session }
            if blocker == nil, !busyPIDs.contains(resource.pid) {
                break
            }
            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else {
                condition.unlock()
                throw LeaseBusy(resource: blocker?.key ?? resource, owner: blocker?.value.session ?? session)
            }
            // Idle claims expire without a signal, so wake up to look again.
            condition.wait(until: Date().addingTimeInterval(min(remaining, 0.25)))
        }
        // A session works in one window per app; moving to another frees the last.
        if case .window = resource {
            leases = leases.filter { entry in
                guard entry.value.session == session, entry.key.pid == resource.pid, entry.key != resource,
                      case .window = entry.key else { return true }
                return false
            }
        }
        leases[resource] = Lease(session: session, lastUsed: now())
        busyPIDs.insert(resource.pid)
        condition.unlock()

        defer {
            condition.lock()
            busyPIDs.remove(resource.pid)
            leases[resource]?.lastUsed = now()
            condition.broadcast()
            condition.unlock()
        }
        return try body()
    }

    /// The session holding a claim that conflicts with `resource`, if it is someone else.
    func otherOwner(of resource: LeasedResource, session: Int, idleExpiry: TimeInterval) -> Int? {
        condition.lock()
        defer { condition.unlock() }
        dropExpired(idleExpiry: idleExpiry)
        return leases.first { $0.key.conflicts(with: resource) && $0.value.session != session }?.value.session
    }

    func release(session: Int) {
        condition.lock()
        leases = leases.filter { $0.value.session != session }
        condition.broadcast()
        condition.unlock()
    }

    private func dropExpired(idleExpiry: TimeInterval) {
        let cutoff = now().addingTimeInterval(-idleExpiry)
        leases = leases.filter { $0.value.lastUsed >= cutoff || busyPIDs.contains($0.key.pid) }
    }
}

/// How agents share an app: by window when it can open more windows of its own,
/// otherwise one agent at a time.
enum AppConcurrency {
    static let singletonListKey = "OPEN_COMPUTER_USE_SINGLETON_APPS"
    static let windowedListKey = "OPEN_COMPUTER_USE_WINDOWED_APPS"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]

    /// An app is shared by window when its menu bar offers to open another window
    /// or document ("New window", "New Finder Window", TextEdit's "New").
    static func opensWindows(menuTitles: [String]) -> Bool {
        menuTitles.contains { title in
            let words = title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            guard words.first == "new" else { return false }
            return words.count == 1 || words.contains("window") || words.contains("tab") || words.contains("document")
        }
    }

    static func isSingleton(bundleIdentifier: String?, name: String, environment: [String: String],
                            menuTitles: () -> [String]) -> Bool {
        let keys = [bundleIdentifier?.lowercased(), name.lowercased()].compactMap { $0 }
        func listed(_ key: String) -> Bool {
            let entries = (environment[key] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            return keys.contains(where: entries.contains)
        }
        if listed(singletonListKey) { return true }
        if listed(windowedListKey) { return false }
        let cacheKey = keys.first ?? name
        if let cached = lock.withLock({ cache[cacheKey] }) { return cached }
        let singleton = !opensWindows(menuTitles: menuTitles())
        lock.withLock { cache[cacheKey] = singleton }
        return singleton
    }
}
