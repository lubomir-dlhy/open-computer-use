import Foundation

/// The environment a tool call runs with. The app agent serves several clients at
/// once, one thread each, so per-call OPEN_COMPUTER_USE_* settings live with the
/// serving thread instead of in the process environment.
public enum RequestEnvironment {
    private static let key = "ocu.request-environment"

    public static var current: [String: String] {
        Thread.current.threadDictionary[key] as? [String: String] ?? ProcessInfo.processInfo.environment
    }

    public static func with<T>(_ environment: [String: String], _ body: () throws -> T) rethrows -> T {
        let previous = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = environment
        defer { Thread.current.threadDictionary[key] = previous }
        return try body()
    }
}

/// How long the current call holds a click's button or a key down before release.
enum InputHold {
    private static let key = "ocu.input-hold"

    static var seconds: TimeInterval {
        Thread.current.threadDictionary[key] as? TimeInterval ?? 0
    }

    static func with<T>(_ seconds: TimeInterval, _ body: () throws -> T) rethrows -> T {
        let previous = Thread.current.threadDictionary[key]
        Thread.current.threadDictionary[key] = seconds
        defer { Thread.current.threadDictionary[key] = previous }
        return try body()
    }

    static func pause() {
        if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
    }
}
