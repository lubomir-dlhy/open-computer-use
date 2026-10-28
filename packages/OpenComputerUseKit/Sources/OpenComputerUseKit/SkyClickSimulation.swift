import AppKit
import CoreGraphics
import Foundation

struct SkyClickTarget {
    let screenPoint: CGPoint
    let windowPoint: CGPoint
    let windowBounds: CGRect
    let windowID: CGWindowID
    let pid: pid_t
}

enum SkyClickEventKind: Equatable, Sendable {
    case moved
    case down
    case dragged
    case up

    var cgEventType: CGEventType {
        switch self {
        case .moved:
            return .mouseMoved
        case .down:
            return .leftMouseDown
        case .dragged:
            return .leftMouseDragged
        case .up:
            return .leftMouseUp
        }
    }

    func cgEventType(button: MouseButtonKind) -> CGEventType {
        switch (self, button) {
        case (.moved, _):
            return .mouseMoved
        case (.down, _):
            return button.downEvent
        case (.up, _):
            return button.upEvent
        case (.dragged, .left):
            return .leftMouseDragged
        case (.dragged, .right):
            return .rightMouseDragged
        case (.dragged, .middle):
            return .otherMouseDragged
        }
    }
}

extension MouseButtonKind {
    var skyButtonNumber: Int64 {
        switch self {
        case .left:
            return 0
        case .right:
            return 1
        case .middle:
            return 2
        }
    }
}

enum SkyClickPointKind: Equatable, Sendable {
    case target
    case primer
}

struct SkyClickEventStep: Equatable, Sendable {
    let kind: SkyClickEventKind
    let pointKind: SkyClickPointKind
    let clickState: Int64
    let phase: Int64
    let delayAfter: TimeInterval
}

func skyClickEventRecipe(clickCount: Int) throws -> [SkyClickEventStep] {
    guard (1...3).contains(clickCount) else {
        throw ComputerUseError.message(
            "click_method 'sky_click' supports click_count 1, 2 or 3"
        )
    }

    var steps = [
        SkyClickEventStep(kind: .moved, pointKind: .target, clickState: 0, phase: 2, delayAfter: 0.015),
        SkyClickEventStep(kind: .down, pointKind: .primer, clickState: 1, phase: 1, delayAfter: 0.001),
        SkyClickEventStep(kind: .up, pointKind: .primer, clickState: 1, phase: 2, delayAfter: 0.100),
    ]

    for pairIndex in 1...clickCount {
        steps.append(
            SkyClickEventStep(
                kind: .down,
                pointKind: .target,
                clickState: Int64(pairIndex),
                phase: 3,
                delayAfter: 0.001
            )
        )
        steps.append(
            SkyClickEventStep(
                kind: .up,
                pointKind: .target,
                clickState: Int64(pairIndex),
                phase: 3,
                delayAfter: pairIndex < clickCount ? 0.080 : 0
            )
        )
    }

    return steps
}

/// The window must still exist and belong to the snapshot's process. It does
/// not need to be on-screen: SkyLight routes by window id, so a covered window
/// or one on another Space is a valid target (verified live on macOS 27).
func skyClickWindowMatchesTarget(
    windowInfo: [[String: Any]],
    windowID: CGWindowID,
    pid: pid_t
) -> Bool {
    skyKeyWindowMatchesTarget(windowInfo: windowInfo, windowID: windowID, pid: pid)
}

enum SkyClickDispatcher {
    private static let primerScreenPoint = CGPoint(x: -1, y: -1)
    private static let primerWindowPoint = CGPoint(x: -1, y: -1)
    private static let dispatchLock = NSLock()

    // Raw private event fields used by the Chromium-compatible Cua Driver path.
    private enum EventField {
        static let gesturePhase: UInt32 = 0
        static let clickState: UInt32 = 1
        static let buttonNumber: UInt32 = 3
        static let subtype: UInt32 = 7
        static let targetPID: UInt32 = 40
        static let windowNumber: UInt32 = 51
        static let clickGroupID: UInt32 = 58
        static let windowUnderPointer: UInt32 = 91
        static let handlingWindowUnderPointer: UInt32 = 92
    }

    static func click(
        target: SkyClickTarget,
        clickCount: Int,
        button: MouseButtonKind = .left,
        modifiers: CGEventFlags = [],
        spi: SkyLightSPI = .shared
    ) throws {
        try requireUsableComputerUseSession()
        guard spi.capability.isAvailable else {
            throw ComputerUseError.message(
                "click_method 'sky_click' is unavailable: \(spi.capability.unavailableReason)"
            )
        }

        dispatchLock.lock()
        let start = TimingLog.now()
        defer {
            TimingLog.log("sky_click.total", since: start)
            dispatchLock.unlock()
        }

        try validate(target: target)
        let recipe = try skyClickEventRecipe(clickCount: clickCount)
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ComputerUseError.message("Failed to create SkyLight HID event source.")
        }

        // Cua uses the nanosecond component of wall-clock time here, which is
        // always below one billion. Keep the same narrow raw-field range;
        // WindowServer does not publish field 58's accepted width.
        let clickGroupID = Int64(DispatchTime.now().uptimeNanoseconds % 1_000_000_000)

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusContext: SkyLightSyntheticFocusContext?
        if frontmostPID == target.pid {
            focusContext = nil
        } else {
            focusContext = try spi.beginSyntheticTargetFocus(
                targetPID: target.pid,
                targetWindowID: target.windowID
            )
        }

        do {
            for step in recipe {
                try requireUsableComputerUseSession()
                let isTarget = step.pointKind == .target
                let screenPoint = isTarget ? target.screenPoint : primerScreenPoint
                let windowPoint = isTarget ? target.windowPoint : primerWindowPoint
                // The primer stays a plain left click; only the target events carry the requested button and modifiers.
                let stepButton: MouseButtonKind = isTarget ? button : .left
                let eventType = step.kind.cgEventType(button: stepButton)
                guard let event = CGEvent(
                    mouseEventSource: source,
                    mouseType: eventType,
                    mouseCursorPosition: screenPoint,
                    mouseButton: stepButton.cgButton
                ) else {
                    throw ComputerUseError.message(
                        "Failed to create sky_click mouse event \(eventType.rawValue)."
                    )
                }

                try stamp(
                    event,
                    target: target,
                    windowPoint: windowPoint,
                    clickState: step.clickState,
                    phase: step.phase,
                    clickGroupID: clickGroupID,
                    buttonNumber: stepButton.skyButtonNumber,
                    spi: spi
                )
                if isTarget, step.kind != .moved {
                    event.flags = modifiers
                }

                // SkyLight alone reaches both Chromium and AppKit; also posting through
                // CGEvent.postToPid delivered every event twice.
                try spi.postToPid(event, pid: target.pid)

                let delay = step.delayAfter * InputTiming.skyClickDelayScale
                if delay > 0 {
                    Thread.sleep(forTimeInterval: delay)
                }
            }
        } catch {
            if let focusContext {
                try? spi.endSyntheticTargetFocus(focusContext)
            }
            throw error
        }

        if let focusContext {
            // SkyLight delivery is asynchronous. Keep the target's AppKit
            // synthetic active state long enough for Chromium's renderer hop
            // to consume the final mouse-up before deactivating only the target.
            let rendererSettle = 0.100 * InputTiming.skyClickDelayScale
            if rendererSettle > 0 {
                Thread.sleep(forTimeInterval: rendererSettle)
            }
            try spi.endSyntheticTargetFocus(focusContext)
        }
    }

    /// Background drag through the same SkyLight path as `click`: the system
    /// pointer does not move and only the target app receives synthetic focus.
    static func drag(
        through points: [SkyClickTarget],
        modifiers: CGEventFlags = [],
        spi: SkyLightSPI = .shared
    ) throws {
        guard let start = points.first, let end = points.last, points.count >= 2 else {
            throw ComputerUseError.message("drag_method 'sky' requires at least a start and an end point")
        }
        try requireUsableComputerUseSession()
        guard spi.capability.isAvailable else {
            throw ComputerUseError.message(
                "drag_method 'sky' is unavailable: \(spi.capability.unavailableReason)"
            )
        }
        guard points.allSatisfy({ $0.pid == start.pid && $0.windowID == start.windowID }) else {
            throw ComputerUseError.message("drag_method 'sky' requires every point in the same window")
        }

        dispatchLock.lock()
        let startTime = TimingLog.now()
        defer {
            TimingLog.log("sky_drag.total", since: startTime)
            dispatchLock.unlock()
        }

        for point in points {
            try validate(target: point)
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ComputerUseError.message("Failed to create SkyLight HID event source.")
        }

        let clickGroupID = Int64(DispatchTime.now().uptimeNanoseconds % 1_000_000_000)
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusContext: SkyLightSyntheticFocusContext? = frontmostPID == start.pid
            ? nil
            : try spi.beginSyntheticTargetFocus(targetPID: start.pid, targetWindowID: start.windowID)

        var previousScreenPoint = start.screenPoint
        func post(
            _ kind: SkyClickEventKind,
            screenPoint: CGPoint,
            windowPoint: CGPoint,
            clickState: Int64,
            phase: Int64,
            delayAfter: TimeInterval
        ) throws {
            try requireUsableComputerUseSession()
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: kind.cgEventType,
                mouseCursorPosition: screenPoint,
                mouseButton: .left
            ) else {
                throw ComputerUseError.message("Failed to create sky drag mouse event \(kind.cgEventType.rawValue).")
            }
            try stamp(
                event,
                target: start,
                windowPoint: windowPoint,
                clickState: clickState,
                phase: phase,
                clickGroupID: clickGroupID,
                buttonNumber: 0,
                spi: spi
            )
            if kind != .moved, screenPoint != primerScreenPoint {
                event.flags = modifiers
            }
            if kind == .dragged {
                let dx = Int64((screenPoint.x - previousScreenPoint.x).rounded())
                let dy = Int64((screenPoint.y - previousScreenPoint.y).rounded())
                event.setIntegerValueField(.mouseEventDeltaX, value: dx)
                event.setIntegerValueField(.mouseEventDeltaY, value: dy)
            }
            previousScreenPoint = screenPoint
            try spi.postToPid(event, pid: start.pid)
            let delay = delayAfter * InputTiming.skyClickDelayScale
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
        }

        do {
            try post(.moved, screenPoint: start.screenPoint, windowPoint: start.windowPoint, clickState: 0, phase: 2, delayAfter: 0.015)
            try post(.down, screenPoint: primerScreenPoint, windowPoint: primerWindowPoint, clickState: 1, phase: 1, delayAfter: 0.001)
            try post(.up, screenPoint: primerScreenPoint, windowPoint: primerWindowPoint, clickState: 1, phase: 2, delayAfter: 0.100)
            try post(.down, screenPoint: start.screenPoint, windowPoint: start.windowPoint, clickState: 1, phase: 3, delayAfter: 0.030)
            for (from, to) in zip(points, points.dropFirst()) {
                let stepCount = InputSimulation.dragStepCount(from: from.screenPoint, to: to.screenPoint)
                for step in 1...stepCount {
                    let progress = CGFloat(step) / CGFloat(stepCount)
                    try post(
                        .dragged,
                        screenPoint: interpolate(from.screenPoint, to.screenPoint, progress),
                        windowPoint: interpolate(from.windowPoint, to.windowPoint, progress),
                        clickState: 1,
                        phase: 3,
                        delayAfter: 0.012
                    )
                }
            }
            try post(.up, screenPoint: end.screenPoint, windowPoint: end.windowPoint, clickState: 1, phase: 3, delayAfter: 0)
        } catch {
            if let focusContext {
                try? spi.endSyntheticTargetFocus(focusContext)
            }
            throw error
        }

        if let focusContext {
            let rendererSettle = 0.100 * InputTiming.skyClickDelayScale
            if rendererSettle > 0 {
                Thread.sleep(forTimeInterval: rendererSettle)
            }
            try spi.endSyntheticTargetFocus(focusContext)
        }
    }

    private static func interpolate(_ from: CGPoint, _ to: CGPoint, _ progress: CGFloat) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress)
    }

    private static func validate(target: SkyClickTarget) throws {
        guard
            target.screenPoint.x.isFinite,
            target.screenPoint.y.isFinite,
            target.windowPoint.x.isFinite,
            target.windowPoint.y.isFinite,
            target.windowBounds.width > 0,
            target.windowBounds.height > 0
        else {
            throw ComputerUseError.message("sky_click requires finite target coordinates and window bounds")
        }

        let localBounds = CGRect(origin: .zero, size: target.windowBounds.size)
        guard localBounds.contains(target.windowPoint) else {
            throw ComputerUseError.message("sky_click target is outside the snapshot window bounds")
        }

        if NSRunningApplication(processIdentifier: target.pid)?.isHidden == true {
            throw ComputerUseError.stateUnavailable(
                "sky_click target app is hidden. Unhide it first; sky_click does not change window visibility."
            )
        }
        let windowInfo = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        guard skyClickWindowMatchesTarget(
            windowInfo: windowInfo,
            windowID: target.windowID,
            pid: target.pid
        ) else {
            throw ComputerUseError.stateUnavailable(
                "sky_click target window no longer exists or is no longer owned by the target app. Run get_app_state again."
            )
        }
    }

    private static func stamp(
        _ event: CGEvent,
        target: SkyClickTarget,
        windowPoint: CGPoint,
        clickState: Int64,
        phase: Int64,
        clickGroupID: Int64,
        buttonNumber: Int64,
        spi: SkyLightSPI
    ) throws {
        let windowID = Int64(target.windowID)
        try spi.setIntegerField(event, field: EventField.gesturePhase, value: phase)
        try spi.setIntegerField(event, field: EventField.clickState, value: clickState)
        try spi.setIntegerField(event, field: EventField.buttonNumber, value: buttonNumber)
        try spi.setIntegerField(event, field: EventField.subtype, value: 3)
        try spi.setIntegerField(event, field: EventField.targetPID, value: Int64(target.pid))
        try spi.setIntegerField(event, field: EventField.windowNumber, value: windowID)
        try spi.setIntegerField(event, field: EventField.clickGroupID, value: clickGroupID)
        try spi.setIntegerField(event, field: EventField.windowUnderPointer, value: windowID)
        try spi.setIntegerField(event, field: EventField.handlingWindowUnderPointer, value: windowID)
        try spi.setWindowLocation(event, point: windowPoint)
    }

}
