import AppKit
import ApplicationServices
import Foundation

/// Some apps bring themselves forward on their own; Chrome does for every new tab
/// or window, however it is created. While an action runs, and for a moment after
/// since the activation arrives asynchronously, this hands the foreground straight
/// back to the app the user was in. Only an action's own target app is reverted.
final class ForegroundGuard: @unchecked Sendable {
    static let shared = ForegroundGuard()

    private struct Watch {
        let targetPID: pid_t
        let userPID: pid_t
        var until: Date
    }

    private let lock = NSLock()
    private var watches: [UUID: Watch] = [:]
    private var polling = false

    /// Starts watching `targetPID`; several actions may be watched at once.
    func arm(targetPID: pid_t) -> UUID? {
        guard !foregroundActivationEnabled(), let frontmost = Self.frontmostPID(), frontmost != targetPID else {
            return nil
        }
        let token = UUID()
        let startPolling: Bool = lock.withLock {
            watches[token] = Watch(targetPID: targetPID, userPID: frontmost, until: .distantFuture)
            defer { polling = true }
            return !polling
        }
        if startPolling {
            // Polled rather than observed: the CLI and MCP processes may not run a main run loop.
            Thread.detachNewThread { [self] in
                while true {
                    let active: [Watch] = lock.withLock {
                        watches = watches.filter { $0.value.until > Date() }
                        if watches.isEmpty { polling = false }
                        return Array(watches.values)
                    }
                    guard !active.isEmpty else { return }
                    if let frontmost = Self.frontmostPID(), let watch = active.first(where: { $0.targetPID == frontmost }),
                       let app = NSRunningApplication(processIdentifier: watch.userPID), !app.isTerminated {
                        AXUIElementSetAttributeValue(AXUIElementCreateApplication(watch.userPID), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                    }
                    Thread.sleep(forTimeInterval: 0.03)
                }
            }
        }
        return token
    }

    /// Keeps watching for `grace` after the action ends, then stops.
    func disarm(_ token: UUID?, after grace: TimeInterval = 2.5) {
        guard let token else { return }
        lock.withLock { watches[token]?.until = Date().addingTimeInterval(grace) }
    }

    /// Read live from the accessibility server; NSWorkspace's value lags without a run loop.
    private static func frontmostPID() -> pid_t? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(value as! AXUIElement, &pid) == .success ? pid : nil
    }
}
