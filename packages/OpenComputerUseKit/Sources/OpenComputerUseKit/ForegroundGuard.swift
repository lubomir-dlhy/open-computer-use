import AppKit
import ApplicationServices
import Foundation

/// Some apps bring themselves forward on their own; Chrome does for every new tab
/// or window, however it is created. While an action runs, and for a moment after
/// since the activation arrives asynchronously, this hands the foreground straight
/// back to the app the user was in. Only the action's target app is reverted.
final class ForegroundGuard: @unchecked Sendable {
    static let shared = ForegroundGuard()

    private let lock = NSLock()
    private var targetPID: pid_t?
    private var userPID: pid_t?
    private var armedUntil = Date.distantPast
    private var polling = false

    func arm(targetPID: pid_t) {
        guard !foregroundActivationEnabled() else { return }
        let frontmost = Self.frontmostPID()
        let startPolling: Bool = lock.withLock {
            self.targetPID = targetPID
            userPID = frontmost == targetPID ? nil : frontmost
            armedUntil = .distantFuture
            defer { polling = true }
            return !polling
        }
        guard startPolling else { return }
        // Polled rather than observed: the CLI and MCP processes may not run a main run loop.
        Thread.detachNewThread { [self] in
            while lock.withLock({ Date() < armedUntil }) {
                revertIfNeeded()
                Thread.sleep(forTimeInterval: 0.03)
            }
            lock.withLock { polling = false }
        }
    }

    func disarm(after grace: TimeInterval = 1) {
        lock.withLock {
            if armedUntil == .distantFuture {
                armedUntil = Date().addingTimeInterval(grace)
            }
        }
    }

    private func revertIfNeeded() {
        let (target, user) = lock.withLock { (targetPID, userPID) }
        guard let target, let user, Self.frontmostPID() == target,
              let app = NSRunningApplication(processIdentifier: user), !app.isTerminated else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(user), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
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
