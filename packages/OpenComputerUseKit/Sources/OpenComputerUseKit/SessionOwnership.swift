import Darwin
import Foundation

/// The MCP session borrowing window state. One app agent serves every host session,
/// so parked windows and occlusion pins are released per owner.
enum SessionOwner {
    // Per thread: the app agent serves concurrent connections on separate threads.
    private static let key = "ocu.session-owner"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastID = 0

    static var current: Int {
        Thread.current.threadDictionary[key] as? Int ?? 0
    }

    static func makeID() -> Int {
        lock.withLock {
            lastID += 1
            return lastID
        }
    }

    static func with<T>(_ owner: Int, _ body: () throws -> T) rethrows -> T {
        let previous = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = owner
        defer { Thread.current.threadDictionary[key] = previous }
        return try body()
    }
}

/// Run `body` with window state it borrows attributed to `session`.
public func withOpenComputerUseSession<T>(_ session: Int, _ body: () throws -> T) rethrows -> T {
    try SessionOwner.with(session, body)
}

/// `pid` followed by its ancestors, up to launchd.
public func processAncestry(of pid: pid_t = getpid()) -> [pid_t] {
    var chain: [pid_t] = []
    var current = pid
    while current > 0, !chain.contains(current), chain.count < 64 {
        chain.append(current)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else {
            break
        }
        current = info.kp_eproc.e_ppid
    }
    return chain
}

/// The sessions a turn-ended signal belongs to: those whose host is the sender's nearest
/// ancestor. A sender unrelated to any session (a terminal) reaches all of them equally.
public func turnEndedRecipients(senderAncestry: [pid_t], sessionAncestries: [Int: [pid_t]]) -> Set<Int> {
    guard !senderAncestry.isEmpty else {
        return Set(sessionAncestries.keys)
    }
    let distances = sessionAncestries.mapValues { chain in
        chain.lazy.compactMap { senderAncestry.firstIndex(of: $0) }.first ?? senderAncestry.count
    }
    guard let nearest = distances.values.min() else {
        return []
    }
    return Set(distances.filter { $0.value == nearest }.keys)
}

func encodeProcessAncestry(_ chain: [pid_t]) -> String {
    chain.map(String.init).joined(separator: ",")
}

public func decodeProcessAncestry(_ text: String?) -> [pid_t] {
    (text ?? "").split(separator: ",").compactMap { pid_t($0) }
}
