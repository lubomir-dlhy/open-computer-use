import AppKit
import ApplicationServices
import Foundation

/// Windows an agent session opened, so they can be closed when it is done,
/// whether it succeeded or not. Apps the session launched are quit once they have
/// no windows left. A window the agent marks as kept stays open.
final class AgentWindows: @unchecked Sendable {
    private struct Opened {
        let pid: pid_t
        var kept: Bool
    }

    private let lock = NSLock()
    private var opened: [CGWindowID: Opened] = [:]
    private var launched: Set<pid_t> = []

    /// Runs `body` and records the windows of `query`'s app that appeared during it.
    func tracking<T>(app query: String, _ body: () throws -> T) rethrows -> T {
        let before = try? AppDiscovery.resolveRunning(query)
        let windowsBefore = before.map { Self.windowIDs(pid: $0.pid) } ?? []
        defer {
            if let after = try? AppDiscovery.resolveRunning(query) {
                let appeared = Self.windowIDs(pid: after.pid).subtracting(before?.pid == after.pid ? windowsBefore : [])
                lock.withLock {
                    for windowID in appeared where opened[windowID] == nil {
                        opened[windowID] = Opened(pid: after.pid, kept: false)
                    }
                    if before?.pid != after.pid {
                        launched.insert(after.pid)
                    }
                }
            }
        }
        return try body()
    }

    func keep(windowID: CGWindowID) {
        lock.withLock { opened[windowID]?.kept = true }
    }

    func isOpenedByAgent(_ windowID: CGWindowID) -> Bool {
        lock.withLock { opened[windowID] != nil }
    }

    /// Closes what the session opened. Never discards work: when an app asks to
    /// save, the question is cancelled and the window left open.
    @discardableResult
    func closeAll() -> [String] {
        let (windows, apps) = lock.withLock { () -> ([CGWindowID: Opened], Set<pid_t>) in
            defer { opened.removeAll(); launched.removeAll() }
            return (opened, launched)
        }
        var leftOpen: [String] = []
        for (windowID, window) in windows where !window.kept {
            guard let element = Self.windowElement(pid: window.pid, windowID: windowID) else { continue }
            if !Self.close(element, pid: window.pid, windowID: windowID) {
                leftOpen.append(Self.title(of: element))
            }
        }
        for pid in apps where !windows.contains(where: { $0.value.pid == pid && $0.value.kept }) {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
                  Self.windowIDs(pid: pid).isEmpty else { continue }
            app.terminate()
        }
        return leftOpen
    }

    private static func close(_ window: AXUIElement, pid: pid_t, windowID: CGWindowID) -> Bool {
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button, CFGetTypeID(button) == AXUIElementGetTypeID(),
              AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success else {
            return false
        }
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if !windowIDs(pid: pid).contains(windowID) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Still open: most likely a "save changes?" sheet. Cancel it rather than lose work.
        for child in children(of: window) where stringValue(child, kAXRoleAttribute) == kAXSheetRole as String {
            _ = AXUIElementPerformAction(child, kAXCancelAction as CFString)
            if let cancel = children(of: child).first(where: { stringValue($0, kAXTitleAttribute) == "Cancel" }) {
                _ = AXUIElementPerformAction(cancel, kAXPressAction as CFString)
            }
        }
        return false
    }

    static func windowIDs(pid: pid_t) -> Set<CGWindowID> {
        Set(axWindows(pid: pid).compactMap { SkyLightSPI.shared.windowID(for: $0) })
    }

    private static func windowElement(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        axWindows(pid: pid).first { SkyLightSPI.shared.windowID(for: $0) == windowID }
    }

    private static func axWindows(pid: pid_t) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func title(of window: AXUIElement) -> String {
        stringValue(window, kAXTitleAttribute) ?? "untitled window"
    }
}
