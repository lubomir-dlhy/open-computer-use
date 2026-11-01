import AppKit
import ApplicationServices
import Foundation
import ImageIO

struct VisualCursorTarget: Equatable {
    let point: CGPoint
    let window: CursorTargetWindow?
    /// The same point expressed relative to the window frame the snapshot
    /// reported. The overlay keeps it so a window that moves before or during
    /// the action can be re-derived instead of drawing on the display the
    /// window just left.
    var anchor: CursorRestingAnchor? = nil
}

public enum ClickMethod: String, CaseIterable, Sendable {
    case auto
    case accessibility
    case appPost = "app_post"
    case skyClick = "sky_click"
    case global
}

func clickActionSnapshotRecoveryPolicy(for method: ClickMethod) -> SnapshotRecoveryPolicy {
    method == .skyClick ? .readOnly : .allowActivation
}

func parseClickMethod(_ rawValue: String?) throws -> ClickMethod {
    let normalized = rawValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ClickMethod.auto.rawValue

    guard let method = ClickMethod(rawValue: normalized) else {
        let expected = ClickMethod.allCases.map(\.rawValue).joined(separator: ", ")
        throw ComputerUseError.message(
            "Invalid click_method '\(rawValue ?? "")'. Expected one of: \(expected)"
        )
    }

    return method
}

func validateClickMethod(
    _ method: ClickMethod,
    hasElementIndex: Bool,
    environment: [String: String]
) throws {
    if method == .accessibility, !hasElementIndex {
        throw ComputerUseError.message("click_method 'accessibility' requires element_index")
    }

    if method == .global, !globalPointerFallbacksEnabled(environment: environment) {
        throw ComputerUseError.message(
            "click_method 'global' requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 because it may move the system pointer and change foreground focus"
        )
    }
}

public enum KeyMethod: String, CaseIterable, Sendable {
    case auto
    case skyKey = "sky_key"
}

func keyActionSnapshotRecoveryPolicy(for method: KeyMethod) -> SnapshotRecoveryPolicy {
    method == .skyKey ? .readOnly : .allowActivation
}

func parseKeyMethod(_ rawValue: String?) throws -> KeyMethod {
    let normalized = rawValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? KeyMethod.auto.rawValue

    guard let method = KeyMethod(rawValue: normalized) else {
        let expected = KeyMethod.allCases.map(\.rawValue).joined(separator: ", ")
        throw ComputerUseError.message(
            "Invalid key_method '\(rawValue ?? "")'. Expected one of: \(expected)"
        )
    }

    return method
}

func validateSkyClickArguments(
    method: ClickMethod,
    mouseButton: String,
    clickCount: Int,
    modifiers: CGEventFlags = []
) throws {
    guard method == .skyClick else {
        if !modifiers.isEmpty, method != .auto {
            throw ComputerUseError.message("modifiers are only supported with click_method 'sky_click' or 'auto'")
        }
        return
    }

    guard MouseButtonKind(rawValue: mouseButton.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) != nil else {
        throw ComputerUseError.message(
            "click_method 'sky_click' supports mouse_button left, right or middle"
        )
    }

    guard (1...3).contains(clickCount) else {
        throw ComputerUseError.message(
            "click_method 'sky_click' supports click_count 1, 2 or 3"
        )
    }
}

func parseMouseModifiers(_ rawValues: [String]?) throws -> CGEventFlags {
    var flags: CGEventFlags = []
    for rawValue in rawValues ?? [] {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "cmd", "command":
            flags.insert(.maskCommand)
        case "shift":
            flags.insert(.maskShift)
        case "option", "alt":
            flags.insert(.maskAlternate)
        case "control", "ctrl":
            flags.insert(.maskControl)
        default:
            throw ComputerUseError.message(
                "Invalid modifier '\(rawValue)'. Expected any of: cmd, shift, option, control"
            )
        }
    }
    return flags
}

struct VisualCursorScreenMapping: Equatable {
    let screenStateFrame: CGRect
    let appKitFrame: CGRect
}

func currentVisualCursorScreenMappings() -> [VisualCursorScreenMapping] {
    NSScreen.screens.compactMap { screen in
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return VisualCursorScreenMapping(
            screenStateFrame: CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value)),
            appKitFrame: screen.frame
        )
    }
}

func screenStatePointToAppKitGlobalPoint(
    fromScreenStatePoint point: CGPoint,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> CGPoint {
    guard let mapping = screenMappings.first(where: { $0.screenStateFrame.contains(point) }) else {
        return point
    }

    let localX = point.x - mapping.screenStateFrame.minX
    let localY = point.y - mapping.screenStateFrame.minY

    return CGPoint(
        x: mapping.appKitFrame.minX + localX,
        y: mapping.appKitFrame.maxY - localY
    )
}

func visualCursorAppKitPoint(
    fromScreenStatePoint point: CGPoint,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> CGPoint {
    screenStatePointToAppKitGlobalPoint(
        fromScreenStatePoint: point,
        screenMappings: screenMappings
    )
}

func inputEventPoint(
    fromScreenStatePoint point: CGPoint,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> CGPoint {
    point
}

/// Anchor for a cursor target built from a window-local point.
///
/// The click paths derive their point from the snapshot, so they carry the
/// window frame that point belongs to; the overlay needs both to follow the
/// window if it moves before or during the action.
func makeCursorWindowAnchor(snapshot: AppSnapshot, windowLocalPoint: CGPoint) -> CursorRestingAnchor? {
    guard let windowID = snapshot.targetWindowID, let windowBounds = snapshot.windowBounds else {
        return nil
    }

    // Registering here keeps the live-frame source next to the anchor that
    // depends on it: the window list can lag a move by about a second, so the
    // accessibility element is what makes the re-derivation immediate.
    CursorWindowFrameTracker.register(windowID: windowID, element: snapshot.windowElement)

    return CursorRestingAnchor(
        windowID: windowID,
        layer: snapshot.targetWindowLayer ?? 0,
        windowLocalPoint: windowLocalPoint,
        windowBounds: windowBounds
    )
}

func makeVisualCursorTarget(
    at point: CGPoint,
    targetWindowID: CGWindowID?,
    targetWindowLayer: Int?,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings(),
    anchor: CursorRestingAnchor? = nil
) -> VisualCursorTarget {
    VisualCursorTarget(
        point: screenStatePointToAppKitGlobalPoint(
            fromScreenStatePoint: point,
            screenMappings: screenMappings
        ),
        window: targetWindowID.map { CursorTargetWindow(windowID: $0, layer: targetWindowLayer ?? 0) },
        anchor: anchor
    )
}

func makeVisualCursorTarget(
    localFrame: CGRect?,
    windowBounds: CGRect?,
    targetWindowID: CGWindowID?,
    targetWindowLayer: Int?,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> VisualCursorTarget? {
    guard let localFrame, let windowBounds else {
        return nil
    }

    let point = CGPoint(
        x: windowBounds.minX + localFrame.midX,
        y: windowBounds.minY + localFrame.midY
    )
    return makeVisualCursorTarget(
        at: point,
        targetWindowID: targetWindowID,
        targetWindowLayer: targetWindowLayer,
        screenMappings: screenMappings,
        anchor: targetWindowID.map { windowID in
            CursorRestingAnchor(
                windowID: windowID,
                layer: targetWindowLayer ?? 0,
                windowLocalPoint: CGPoint(x: localFrame.midX, y: localFrame.midY),
                windowBounds: windowBounds
            )
        }
    )
}

func inputFallbackDebugEnabled(environment: [String: String]) -> Bool {
    guard let rawValue = environment["OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
        return false
    }

    return ["1", "true", "yes", "on"].contains(rawValue)
}

/// Activating, unhiding or raising the target puts it in front of the user's work, so it is opt-in.
func foregroundActivationEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    guard let rawValue = environment["OPEN_COMPUTER_USE_ALLOW_FOREGROUND_ACTIVATION"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
        return false
    }

    return ["1", "true", "yes", "on"].contains(rawValue)
}

func globalPointerFallbacksEnabled(environment: [String: String]) -> Bool {
    guard let rawValue = environment["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
        return false
    }

    return ["1", "true", "yes", "on"].contains(rawValue)
}

/// Whether an action's result reads the window back (settle, then a full snapshot).
/// A program driving the tools (the `js` REPL adapter) reads state explicitly and
/// sets `OPEN_COMPUTER_USE_ACTION_READ_BACK=0`, so its actions return a short status.
func actionReadBackEnabled(environment: [String: String]) -> Bool {
    guard let rawValue = environment["OPEN_COMPUTER_USE_ACTION_READ_BACK"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
        return true
    }

    return !["0", "false", "no", "off"].contains(rawValue)
}

/// How a `drag` is delivered. `drag` has no method argument; the path is decided
/// by the same process-level gate that authorizes `click_method=global`.
enum DragDeliveryPath: String, CaseIterable {
    /// `CGEvent.postToPid`: never moves the system pointer, but the events do not
    /// pass through the window server, so window-server drag sessions (window
    /// moves, text selection, Finder drag-and-drop) are not driven.
    case appPost = "app_post"
    /// SkyLight pid post with target-only synthetic focus, like `sky_click`:
    /// reaches Chromium web content without moving the system pointer.
    case sky
    /// `.cghidEventTap`: drives window-server drag sessions and may move the
    /// real pointer or change foreground focus.
    case global
}

public enum DragMethod: String, CaseIterable, Sendable {
    case auto
    case appPost = "app_post"
    case sky
    case global
}

func parseDragMethod(_ rawValue: String?) throws -> DragMethod {
    let normalized = rawValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? DragMethod.auto.rawValue
    guard let method = DragMethod(rawValue: normalized) else {
        let expected = DragMethod.allCases.map(\.rawValue).joined(separator: ", ")
        throw ComputerUseError.message("Invalid drag_method '\(rawValue ?? "")'. Expected one of: \(expected)")
    }
    return method
}

func dragDeliveryPath(environment: [String: String], method: DragMethod = .auto) throws -> DragDeliveryPath {
    let globalAllowed = globalPointerFallbacksEnabled(environment: environment)
    switch method {
    case .auto:
        return globalAllowed ? .global : .appPost
    case .appPost:
        return .appPost
    case .sky:
        return .sky
    case .global:
        guard globalAllowed else {
            throw ComputerUseError.message(
                "drag_method 'global' requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 because it may move the system pointer and change foreground focus"
            )
        }
        return .global
    }
}

func dragDeliveryNote(for path: DragDeliveryPath) -> String {
    switch path {
    case .appPost:
        return "Drag delivered via app_post: mouse events were posted directly to the target process and the system pointer did not move. This path cannot drive window-server drag sessions such as window moves, text selection, or Finder drag-and-drop. If the drag had no effect, set OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 in the server process environment to use the global pointer path, which may move the real pointer and change foreground focus."
    case .global:
        return "Drag delivered via global pointer path: OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS is enabled, so the real pointer may have moved and foreground focus may have changed."
    case .sky:
        return "Drag delivered via SkyLight: events were posted to the target window with target-only synthetic focus; the system pointer did not move."
    }
}

/// Inserts the delivery note after the snapshot text and before any screenshot,
/// so `primaryText` remains the snapshot for existing consumers.
func appendingDragDeliveryNote(to result: ToolCallResult, path: DragDeliveryPath) -> ToolCallResult {
    var content = result.content
    let insertIndex = content.firstIndex { $0.dictionary["type"] as? String == "image" } ?? content.endIndex
    content.insert(.text(dragDeliveryNote(for: path)), at: insertIndex)
    return ToolCallResult(content: content, isError: result.isError)
}

func selectTextErrorMessage(_ error: TextSelectionResolverError, elementIndex: String) -> String {
    switch error {
    case .emptyText:
        return "select_text requires non-empty text"
    case .notFound:
        return "select_text could not find the requested text in element \(elementIndex); pass text exactly as it appears in the accessibility tree"
    case .ambiguous(let occurrenceCount):
        return "select_text found \(occurrenceCount) matches in element \(elementIndex); provide prefix or suffix to disambiguate the target"
    }
}

func selectTextUnreadableValueErrorMessage(elementIndex: String) -> String {
    return "element \(elementIndex) has no readable accessibility text value, so select_text cannot locate the requested text"
}

/// Inserts a verification note after the snapshot text and before any screenshot, matching
/// `appendingDragDeliveryNote` so `primaryText` stays the snapshot for existing consumers.
func screenshotPixelScale(
    screenshotPixelSize: CGSize?,
    windowBounds: CGRect?
) -> CGSize {
    guard
        let screenshotPixelSize,
        let windowBounds,
        windowBounds.width > 0,
        windowBounds.height > 0,
        screenshotPixelSize.width > 0,
        screenshotPixelSize.height > 0
    else {
        return CGSize(width: 1, height: 1)
    }

    return CGSize(
        width: screenshotPixelSize.width / windowBounds.width,
        height: screenshotPixelSize.height / windowBounds.height
    )
}

func screenshotPixelToWindowPoint(
    _ point: CGPoint,
    screenshotPixelSize: CGSize?,
    windowBounds: CGRect?
) -> CGPoint {
    let scale = screenshotPixelScale(
        screenshotPixelSize: screenshotPixelSize,
        windowBounds: windowBounds
    )
    return CGPoint(
        x: point.x / scale.width,
        y: point.y / scale.height
    )
}

let nonSettableSetValueErrorMessage = "Cannot set a value for an element that is not settable"

func setValueAttributeIsSettable(result: AXError, settable: Bool, attribute: String) throws -> Bool {
    guard result == .success else {
        throw ComputerUseError.message("AXUIElementIsAttributeSettable(\(attribute)) failed with \(result.rawValue)")
    }

    return settable
}

func invalidSecondaryActionErrorMessage(action: String, elementIndex: Int) -> String {
    "\(action) is not a valid secondary action for \(elementIndex)"
}

func localClickActionPoints(frame: CGRect, isSyntheticText: Bool) -> [CGPoint] {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    let leading = CGPoint(
        x: frame.minX + min(max(frame.width * 0.3, 20), max(frame.width - 4, 20)),
        y: frame.midY
    )

    if isSyntheticText {
        return [leading]
    }

    if abs(leading.x - center.x) < 1 {
        return [center]
    }

    return [center, leading]
}

func isLikelySyntheticSideActionCandidate(
    parentFrame: CGRect?,
    candidateFrame: CGRect?,
    hasPrimaryAction: Bool,
    labels: [String]
) -> Bool {
    let hasSideActionLabel = labels.contains { label in
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return false
        }

        if normalized == "完成" || normalized == "done" || normalized == "complete" || normalized == "archive" {
            return true
        }

        if normalized.count <= 24 {
            if normalized.contains("完成") {
                return true
            }

            if normalized.contains("mark") && (normalized.contains("done") || normalized.contains("complete")) {
                return true
            }
        }

        return false
    }

    guard let parentFrame, let candidateFrame else {
        return false
    }

    let trailingBandWidth = min(max(parentFrame.width * 0.22, 56), 140)
    let isTrailing = candidateFrame.midX >= parentFrame.maxX - trailingBandWidth
    let compactWidth = candidateFrame.width <= max(88, parentFrame.width * 0.18)
    let compactHeight = candidateFrame.height <= max(44, parentFrame.height * 1.2)
    let isCompact = compactWidth && compactHeight

    if hasSideActionLabel && hasPrimaryAction && isCompact {
        return true
    }

    return isTrailing && isCompact && (hasPrimaryAction || hasSideActionLabel)
}

func shouldScanDescendantsOfHitRecord(originalFrame: CGRect?, hitFrame: CGRect?) -> Bool {
    guard let originalFrame, let hitFrame else {
        return true
    }

    let originalArea = max(originalFrame.width * originalFrame.height, 1)
    let hitArea = hitFrame.width * hitFrame.height
    if hitArea > max(originalArea * 12, 20_000) {
        return false
    }

    if hitFrame.height > max(originalFrame.height * 4, 96),
       hitFrame.width > max(originalFrame.width * 2, 240)
    {
        return false
    }

    return true
}

func isLikelyContainingRowActionFrame(
    targetFrame: CGRect,
    candidateFrame: CGRect?,
    hasPrimaryAction: Bool
) -> Bool {
    let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
    guard
        hasPrimaryAction,
        let candidateFrame,
        candidateFrame.insetBy(dx: -2, dy: -2).contains(targetCenter),
        candidateFrame.width >= targetFrame.width,
        candidateFrame.height >= targetFrame.height,
        candidateFrame.height <= max(targetFrame.height + 32, targetFrame.height * 2)
    else {
        return false
    }

    return true
}

func canUseActivationOnlyClickFallback(role: String?) -> Bool {
    guard let role else {
        return false
    }

    return role == kAXWindowRole as String
}

func canUseKeyboardTextFallback(role: String?, roleDescription: String?, isValueSettable: Bool) -> Bool {
    if isValueSettable {
        return true
    }

    guard let role else {
        return false
    }

    if role == kAXTextFieldRole as String || role == "AXTextArea" || role == "AXTextView" {
        return true
    }

    guard let roleDescription = roleDescription?.lowercased() else {
        return false
    }

    return roleDescription.contains("text field")
        || roleDescription.contains("text area")
        || roleDescription.contains("text entry")
}

func isElectronScopedWebRowClickOptimizationTarget(appName: String, bundleIdentifier: String?) -> Bool {
    let normalizedBundleIdentifier = bundleIdentifier?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let normalizedName = appName
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    if let normalizedBundleIdentifier,
       normalizedBundleIdentifier.hasPrefix("com.electron.")
            || normalizedBundleIdentifier.contains(".electron.")
            || normalizedBundleIdentifier.contains("lark")
            || normalizedBundleIdentifier.contains("feishu")
    {
        return true
    }

    return normalizedName == "lark" || normalizedName == "feishu" || normalizedName == "飞书"
}

func shouldPreferContainingWebRowAXClickCandidate(
    role: String?,
    isSyntheticText: Bool,
    hasWebAreaAncestor: Bool,
    appName: String,
    bundleIdentifier: String?
) -> Bool {
    guard hasWebAreaAncestor,
          isElectronScopedWebRowClickOptimizationTarget(
            appName: appName,
            bundleIdentifier: bundleIdentifier
          )
    else {
        return false
    }

    guard let role else {
        return isSyntheticText
    }

    return role == kAXStaticTextRole as String || role == kAXGroupRole as String || isSyntheticText
}

public final class ComputerUseService {
    private var snapshotsByApp: [String: AppSnapshot] = [:]
    private var invalidatedSnapshotAliases: Set<String> = []
    // Defaults are read per call: the app agent applies the caller's OPEN_COMPUTER_USE_*
    // variables for the duration of each request.
    private var callObservation: ActionObservation?
    var actionObservation: ActionObservation {
        callObservation ?? .defaults(environment: ProcessInfo.processInfo.environment)
    }

    /// Runs one tool call with explicit action-result options.
    public func withActionObservation<T>(_ observation: ActionObservation?, _ body: () throws -> T) rethrows -> T {
        let previous = callObservation
        callObservation = observation ?? previous
        defer { callObservation = previous }
        return try body()
    }

    // Targeted-lookup registry. `query` stores each match here keyed by a high,
    // monotonic element index; the existing element actions resolve that index to
    // the queried control and act without any snapshot. Indexes sit above the
    // snapshot tree range and are never reissued, so a later snapshot cannot
    // reassign one to a different control.
    private struct TargetedElement {
        let record: ElementRecord
        let context: TargetedAX.WindowContext
        let criteria: TargetedAX.Criteria
    }
    private let targetedElements = TargetedElementRegistry<TargetedElement>()

    public func clearQueryIndexes() { targetedElements.clear() }

    public init() {}

    /// The result an action returns, read once the window has settled. A diff
    /// compares against `baseline`, by default the state the agent last saw.
    private func actionResult(
        for query: String,
        recoveryPolicy: SnapshotRecoveryPolicy = .allowActivation,
        baseline: AppSnapshot? = nil
    ) throws -> ToolCallResult {
        let options = actionObservation
        guard options.readsBack else {
            return .text("ok")
        }

        let stored = snapshotsByApp[query.lowercased()].flatMap { $0.observation.includeAX ? $0 : nil }
        let previous = baseline ?? stored
        // Only a full result renumbers; otherwise indices the agent holds stay valid.
        let seed = options.state == .full ? nil : stored.flatMap { $0.mode == .accessibility ? StableIndexSeed(previous: $0) : nil }
        let settledRead: (AppSnapshot, waitMet: Bool?)
        do {
            settledRead = try settledSnapshot(for: query, previous: previous, recoveryPolicy: recoveryPolicy,
                                              seed: seed, options: options)
        } catch ComputerUseError.appNotFound {
            return .text("ok; the app is no longer running.")
        } catch ComputerUseError.stateUnavailable(let message) where message.hasPrefix(computerUseNoWindowFoundMessage) {
            return .text("ok; the app has no window now.")
        }
        let (settled, waitMet) = settledRead
        var snapshot = settled
        // Fixture coordinates resolve by identifier, so they never need a screenshot.
        snapshot.observation.includeScreenshot = snapshot.mode == .fixture
        if options.screenshot, let capture = SnapshotBuilder.captureScreenshot(of: snapshot) {
            snapshot.screenshotData = capture.data
            snapshot.screenshotNote = capture.note
            snapshot.observation.includeScreenshot = true
        } else {
            snapshot.screenshotNote = nil
            if let previous, let size = screenshotPixelSize(snapshot: previous),
               previous.targetWindowID == snapshot.targetWindowID,
               previous.windowBounds?.size == snapshot.windowBounds?.size {
                snapshot.carriedScreenshotPixelSize = size
            }
        }
        rememberSnapshot(snapshot, for: query)

        var text: String
        switch options.state {
        case .full:
            text = snapshot.renderedText(style: .actionResult)
        case .none:
            text = "ok"
        case .diff:
            text = previous.map { renderedDiff(from: $0, to: snapshot) } ?? snapshot.renderedText(style: .actionResult)
        }
        if let waitFor = options.waitFor, waitMet == false {
            text += "\nwait_for \(quoted(waitFor)) not met after \(String(format: "%g", options.waitTimeout))s."
        }

        var content = [ToolResultContentItem.text(text)]
        if options.screenshot {
            if let note = snapshot.screenshotNote { content.append(.text(note)) }
            if let data = snapshot.screenshotData { content.append(.screenshotImage(data)) }
        }
        return ToolCallResult(content: content)
    }

    /// Reads the tree until it stops changing instead of sleeping a fixed time:
    /// returns as soon as two reads agree after a change, or when nothing has
    /// changed for a short window. A `wait_for` condition overrides both.
    private func settledSnapshot(
        for query: String,
        previous: AppSnapshot?,
        recoveryPolicy: SnapshotRecoveryPolicy,
        seed: StableIndexSeed?,
        options: ActionObservation
    ) throws -> (AppSnapshot, waitMet: Bool?) {
        let pollInterval: TimeInterval = 0.03
        let unchangedWindow: TimeInterval = 0.25
        let maxSettle: TimeInterval = 1.2
        // Large trees cost more per read than a second confirmation is worth.
        let confirmReadBudget: TimeInterval = 0.12
        let condition = WaitCondition(options.waitFor)
        // Never relaunch here: an action that made the app quit must not reopen it.
        let app = try AppDiscovery.resolveRunning(query)
        let pin = windowPin(for: query)
        let start = TimingLog.now()
        var last: AppSnapshot?

        while true {
            let readStart = TimingLog.now()
            let snapshot = try SnapshotBuilder.build(
                for: app,
                textLimit: previous?.textLimit ?? .defaults,
                treeLimits: previous?.treeLimits ?? .defaults,
                recoveryPolicy: recoveryPolicy,
                observation: SnapshotObservationOptions(includeAX: true, includeScreenshot: false),
                stableIndices: seed,
                windowPin: pin
            )
            let now = TimingLog.now()
            let elapsed = now - start
            defer { last = snapshot }

            if let condition {
                if condition.isSatisfied(by: snapshot) {
                    TimingLog.log("action.settle(wait_for)", since: start)
                    return (snapshot, true)
                }
                if elapsed >= min(options.waitTimeout, ActionObservation.maxWaitTimeout) {
                    return (snapshot, false)
                }
            } else {
                let changed = previous.map { !sameObservedState($0, snapshot) } ?? true
                let stable = last.map { sameObservedState($0, snapshot) } ?? false
                if (changed && (stable || now - readStart > confirmReadBudget || elapsed >= maxSettle))
                    || (!changed && elapsed >= unchangedWindow) {
                    TimingLog.log("action.settle", since: start)
                    return (snapshot, nil)
                }
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
    }

    private func sameObservedState(_ lhs: AppSnapshot, _ rhs: AppSnapshot) -> Bool {
        lhs.treeLines == rhs.treeLines && lhs.windowTitle == rhs.windowTitle
            && lhs.focusedSummary == rhs.focusedSummary && lhs.selectedText == rhs.selectedText
    }

    private func renderedDiff(from previous: AppSnapshot, to snapshot: AppSnapshot) -> String {
        let diff = TreeDiff(
            before: treeDiffEntries(lines: previous.treeLines, indices: previous.treeLineIndices),
            after: treeDiffEntries(lines: snapshot.treeLines, indices: snapshot.treeLineIndices)
        )
        let full = snapshot.renderedText(style: .actionResult)
        var lines: [String] = []
        if previous.windowTitle != snapshot.windowTitle || previous.targetWindowID != snapshot.targetWindowID {
            lines.append("Window: \(quoted(displayWindowTitle(snapshot.windowTitle, appName: snapshot.app.name))).")
        }
        if diff.isEmpty {
            lines.append("No accessibility tree change.")
        } else {
            lines.append(contentsOf: diff.rendered())
        }
        if snapshot.selectedText != previous.selectedText, let selectedText = snapshot.selectedText, !selectedText.isEmpty {
            lines.append("Selected text: [\(selectedText)]")
        } else if snapshot.focusedSummary != previous.focusedSummary, let focusedSummary = snapshot.focusedSummary {
            lines.append("Focused: \(focusedSummary)")
        }
        let text = lines.joined(separator: "\n")
        // A diff that is nearly the whole tree reads worse than the tree itself.
        return text.count * 5 >= full.count * 4 ? full : text
    }

    /// Runs element and keyboard actions back to back without reading the window
    /// between them, then reports one result against the state before the batch.
    /// Indices in every step refer to that state. Stops at the first failing step.
    public func runBatch(
        app query: String,
        steps: [(tool: String, observation: ActionObservation, run: () throws -> ToolCallResult)]
    ) throws -> ToolCallResult {
        let baseline = snapshotsByApp[query.lowercased()]
        var failure: String?
        var completed = 0
        var notes: [String] = []
        for (offset, step) in steps.enumerated() {
            do {
                let result = try withActionObservation(step.observation) { try step.run() }
                if result.isError {
                    failure = "step \(offset + 1) (\(step.tool)) failed: \(result.textContent)"
                } else if result.textContent != "ok" {
                    let text = result.textContent.hasPrefix("ok\n") ? String(result.textContent.dropFirst(3)) : result.textContent
                    notes.append("step \(offset + 1): \(text)")
                }
            } catch {
                failure = "step \(offset + 1) (\(step.tool)) failed: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))"
            }
            if failure != nil { break }
            completed += 1
        }

        var header = failure.map { ["Ran \(completed) of \(steps.count) steps; \($0)"] } ?? ["Ran \(steps.count) steps."]
        header += notes
        var content: [ToolResultContentItem] = []
        do {
            let readBack = try actionResult(for: query, recoveryPolicy: .readOnly, baseline: baseline)
            // The read-back text always comes first; fold the step summary into it.
            content = Array(readBack.content.dropFirst())
            if let text = readBack.primaryText, text != "ok" {
                header.append(text)
            }
        } catch {
            header.append("Could not read the window back: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
        }
        content.insert(.text(header.joined(separator: "\n")), at: 0)
        return ToolCallResult(content: content, isError: failure != nil)
    }

    public func listApps() -> ToolCallResult {
        ToolCallResult.text(
            AppDiscovery.listCatalog()
                .map(\.renderedLine)
                .joined(separator: "\n")
        )
    }

    public func getAppState(
        app query: String,
        textLimit: SnapshotTextLimit = .defaults,
        treeLimits: AccessibilityTreeLimits = .defaults,
        windowPlacement: WindowPlacement = .keep,
        observation: SnapshotObservationOptions = .defaults,
        windowID: CGWindowID? = nil
    ) throws -> ToolCallResult {
        try observation.validate()
        guard windowPlacement != .keep else {
            return snapshotResult(
                for: try snapshotParkingMinimizedWindow(for: query, textLimit: textLimit, treeLimits: treeLimits, recoveryPolicy: .allowActivation, observation: observation, windowID: windowID),
                style: .fullState
            )
        }

        // Explicit placements never activate or raise; they only move the frame.
        let snapshot = windowPlacement == .agentDisplay
            ? try snapshotParkingMinimizedWindow(for: query, textLimit: textLimit, treeLimits: treeLimits, recoveryPolicy: .readOnly, observation: observation, windowID: windowID)
            : try refreshSnapshot(for: query, textLimit: textLimit, treeLimits: treeLimits, recoveryPolicy: .readOnly, observation: observation, windowID: windowID)
        guard snapshot.mode != .fixture else {
            throw ComputerUseError.message("window_placement '\(windowPlacement.rawValue)' is not supported for fixture apps")
        }
        switch windowPlacement {
        case .agentDisplay:
            guard let windowID = snapshot.targetWindowID, let windowElement = snapshot.windowElement else {
                throw ComputerUseError.stateUnavailable("window_placement 'agent_display' requires a current target window. Run get_app_state again.")
            }
            try AgentDisplay.shared.park(windowID: windowID, pid: snapshot.app.pid, window: windowElement)
        case .restore:
            try AgentDisplay.shared.restoreAll(pid: snapshot.app.pid)
            do {
                return snapshotResult(for: try refreshSnapshot(for: query, textLimit: textLimit, treeLimits: treeLimits, recoveryPolicy: .readOnly, observation: observation), style: .fullState)
            } catch ComputerUseError.stateUnavailable(let message) where message.hasPrefix(computerUseNoWindowFoundMessage) {
                return ToolCallResult.text("Restored the app's windows; they are minimized again, as before.")
            }
        case .keep:
            break
        }

        return snapshotResult(for: try refreshSnapshot(for: query, textLimit: textLimit, treeLimits: treeLimits, recoveryPolicy: .readOnly, observation: observation), style: .fullState)
    }

    /// Selects the outline or table row an element belongs to (Finder lists, Mail
    /// message lists); with `extending`, adds it to the current selection.
    private func selectTableRow(containing element: AXUIElement?, extending: Bool) -> Bool {
        var current = element
        for _ in 0..<5 {
            guard let node = current else { return false }
            if stringValue(of: node, attribute: kAXRoleAttribute) == kAXRowRole as String,
               let table = copyParent(of: node),
               [kAXOutlineRole as String, kAXTableRole as String].contains(stringValue(of: table, attribute: kAXRoleAttribute) ?? ""),
               isSettable(element: table, attribute: kAXSelectedRowsAttribute) {
                var rows = [node]
                if extending {
                    var value: CFTypeRef?
                    if AXUIElementCopyAttributeValue(table, kAXSelectedRowsAttribute as CFString, &value) == .success,
                       let selected = value as? [AXUIElement] {
                        rows = selected.filter { !CFEqual($0, node) } + [node]
                    }
                }
                return AXUIElementSetAttributeValue(table, kAXSelectedRowsAttribute as CFString, rows as CFArray) == .success
            }
            current = copyParent(of: node)
        }
        return false
    }

    /// Pressing twice through accessibility is not a double-click: "double-click to
    /// open/edit" handlers need mouse events carrying the click count.
    private func performMultiClick(
        on record: ElementRecord,
        windowPoint: CGPoint,
        targetPoint: CGPoint,
        clickCount: Int,
        elementIndex: String,
        snapshot: AppSnapshot
    ) throws {
        if clickCount == 2, let element = record.element,
           try performAction(named: "AXOpen", on: element, availableActions: record.rawActions) {
            return
        }
        // SkyLight gives the target synthetic focus, so a background window takes the
        // clicks instead of treating the first one as an activation click.
        try performExplicitMouseClick(
            method: SkyLightSPI.shared.capability.isAvailable ? .skyClick : .appPost,
            modifiers: [],
            at: targetPoint,
            windowPoint: windowPoint,
            button: .left,
            clickCount: clickCount,
            targetDescription: "element_index=\(elementIndex)",
            snapshot: snapshot
        )
    }

    /// Opens an element's context menu and picks an item in one call, so the menu,
    /// which captures the keyboard while open, is up only for a moment.
    public func chooseContextMenuItem(app query: String, elementIndex: String, item: String) throws -> ToolCallResult {
        let snapshot = try snapshotForAction(app: query, elementIndex: elementIndex)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)
        guard let element = record.element else {
            throw ComputerUseError.stateUnavailable("element \(elementIndex) has no backing accessibility object")
        }
        guard try performAction(named: kAXShowMenuAction as String, on: element, availableActions: copyActions(for: element) ?? record.rawActions) else {
            throw ComputerUseError.message("element \(elementIndex) has no context menu (no AXShowMenu action)")
        }
        let deadline = Date().addingTimeInterval(1)
        var menu: AXUIElement?
        while menu == nil, Date() < deadline {
            menu = openContextMenu(near: element)
            if menu == nil { Thread.sleep(forTimeInterval: 0.03) }
        }
        guard let menu else {
            throw ComputerUseError.message("element \(elementIndex)'s context menu did not appear in the accessibility tree")
        }
        let items = copyChildren(of: menu)
        let titles = items.map { stringValue(of: $0, attribute: kAXTitleAttribute) ?? "" }
        guard let target = MenuPath.match(item, in: titles).map({ items[$0] }) ?? MenuPath.pressableDescendant(matching: item, in: items) else {
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            throw ComputerUseError.invalidArguments("context menu has no unique item \(item.debugDescription). Items: \(titles.filter { !$0.isEmpty }.joined(separator: ", "))")
        }
        AXUIElementSetMessagingTimeout(target, 1)
        let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
        guard result == .success || result == .cannotComplete else {
            _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            throw ComputerUseError.message("Pressing context menu item \(item) failed with \(result.rawValue)")
        }
        return try actionResult(for: query, recoveryPolicy: .readOnly)
    }

    /// A context menu hangs off the element it was shown for, or off an ancestor
    /// such as the outline of a Finder row.
    private func openContextMenu(near element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0..<6 {
            guard let node = current else { return nil }
            if let menu = copyChildren(of: node).first(where: { stringValue(of: $0, attribute: kAXRoleAttribute) == kAXMenuRole as String }) {
                return menu
            }
            current = copyParent(of: node)
        }
        return nil
    }

    /// Presses a menu bar item by its titles, without opening the menu on screen.
    public func pressMenuItem(app query: String, path: [String]) throws -> ToolCallResult {
        try requireUsableComputerUseSession()
        let app = try AppDiscovery.resolveRunning(query)
        let appElement = AXUIElementCreateApplication(app.pid)
        var item = try MenuPath.resolve(path, appElement: appElement, requireEnabled: false)
        // Commands that act on the key window (Rename, Compress, Close Window) are
        // disabled while the app is in the background. Synthetic SkyLight focus on
        // its window, which never activates the app, lets AppKit re-validate them.
        var focus: SkyLightSyntheticFocusContext?
        if !MenuPath.isEnabled(item), let windowID = currentWindowID(for: query, pid: app.pid) {
            focus = try? SkyLightSPI.shared.beginSyntheticTargetFocus(targetPID: app.pid, targetWindowID: windowID)
            let deadline = Date().addingTimeInterval(0.5)
            while focus != nil, !MenuPath.isEnabled(item), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.03)
                item = try MenuPath.resolve(path, appElement: appElement, requireEnabled: false)
            }
        }
        defer {
            if let focus {
                try? SkyLightSPI.shared.endSyntheticTargetFocus(focus)
            }
        }
        guard MenuPath.isEnabled(item) else {
            throw ComputerUseError.message("menu item \(path.joined(separator: " > ")) is disabled")
        }
        // A menu command that opens a modal panel can hold the reply; the press is already delivered.
        AXUIElementSetMessagingTimeout(item, 2)
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard result == .success || result == .cannotComplete else {
            throw ComputerUseError.message("Pressing menu item \(path.joined(separator: " > ")) failed with \(result.rawValue)")
        }
        do {
            return try actionResult(for: query, recoveryPolicy: .readOnly)
        } catch ComputerUseError.stateUnavailable {
            return .text("Pressed \(path.joined(separator: " > ")); the app has no window to read back.")
        }
    }

    /// The window the agent works in, or the app's focused window.
    private func currentWindowID(for query: String, pid: pid_t) -> CGWindowID? {
        if let windowID = snapshotsByApp[query.lowercased()]?.targetWindowID {
            return windowID
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return SkyLightSPI.shared.windowID(for: value as! AXUIElement)
    }

    public func click(
        app query: String,
        elementIndex: String?,
        x: Double?,
        y: Double?,
        clickCount: Int,
        mouseButton: String,
        clickMethod: ClickMethod = .auto,
        modifiers: CGEventFlags = []
    ) throws -> ToolCallResult {
        try validateClickMethod(
            clickMethod,
            hasElementIndex: elementIndex != nil,
            environment: ProcessInfo.processInfo.environment
        )
        try validateSkyClickArguments(
            method: clickMethod,
            mouseButton: mouseButton,
            clickCount: clickCount,
            modifiers: modifiers
        )

        let snapshot = try snapshotForAction(app: query, elementIndex: elementIndex)
        let button = MouseButtonKind(rawValue: mouseButton.lowercased()) ?? .left
        if elementIndex == nil, !snapshot.acceptsScreenshotCoordinates {
            throw ComputerUseError.stateUnavailable(SnapshotObservationOptions.screenshotOmittedNote + "; request a screenshot before screenshot-coordinate actions")
        }
        if snapshot.mode == .fixture {
            guard clickMethod == .auto else {
                throw ComputerUseError.message(
                    "click_method '\(clickMethod.rawValue)' is not supported for fixture apps"
                )
            }

            let cursorTarget: VisualCursorTarget?
            if let elementIndex {
                let record = try lookupElement(snapshot: snapshot, index: elementIndex)
                guard let identifier = record.identifier else {
                    throw ComputerUseError.invalidArguments("fixture click requires an identifier-backed element")
                }
                cursorTarget = visualCursorTarget(for: record, snapshot: snapshot)
                moveVisualCursor(to: cursorTarget)
                try FixtureBridge.post(FixtureCommand(kind: "click", identifier: identifier))
            } else if let x, let y {
                let identifier = try fixtureIdentifier(at: CGPoint(x: x, y: y), snapshot: snapshot)
                cursorTarget = fixtureVisualCursorTarget(identifier: identifier, snapshot: snapshot)
                moveVisualCursor(to: cursorTarget)
                try FixtureBridge.post(FixtureCommand(kind: "click", identifier: identifier, x: x, y: y))
            } else {
                throw ComputerUseError.invalidArguments("click requires either element_index or x/y")
            }

            Thread.sleep(forTimeInterval: 0.15)
            pulseVisualCursor(at: cursorTarget, clickCount: clickCount, mouseButton: button)
            return try actionResult(for: query)
        }

        if let elementIndex {
            let record = try lookupElement(snapshot: snapshot, index: elementIndex)
            guard let windowPoint = clickPoint(for: record, snapshot: snapshot) else {
                throw ComputerUseError.stateUnavailable("element \(elementIndex) has no clickable frame")
            }
            let targetPoint = try windowPointToGlobalPoint(snapshot: snapshot, point: windowPoint)
            let cursorTarget = makeVisualCursorTarget(
                at: targetPoint,
                targetWindowID: snapshot.targetWindowID,
                targetWindowLayer: snapshot.targetWindowLayer,
                anchor: makeCursorWindowAnchor(snapshot: snapshot, windowLocalPoint: windowPoint)
            )

            moveVisualCursor(to: cursorTarget)

            do {
                switch clickMethod {
                case .auto where clickCount == 1 && button == .left
                    && selectTableRow(containing: record.element, extending: modifiers.contains(.maskCommand)):
                    break
                case .auto where clickCount >= 2 && button == .left:
                    try performMultiClick(on: record, windowPoint: windowPoint, targetPoint: targetPoint,
                                          clickCount: clickCount, elementIndex: elementIndex, snapshot: snapshot)
                case .auto:
                    if !(try performAXClickSequence(
                        on: record,
                        snapshot: snapshot,
                        button: button,
                        clickCount: clickCount,
                        includeNearbyHitTesting: true,
                        allowActivationFallback: true
                    )) {
                        try performNonAXClickFallback(
                            at: targetPoint,
                            button: button,
                            clickCount: clickCount,
                            targetDescription: "element_index=\(elementIndex)",
                            snapshot: snapshot
                        )
                    }
                case .accessibility:
                    guard try performAXClickSequence(
                        on: record,
                        snapshot: snapshot,
                        button: button,
                        clickCount: clickCount,
                        includeNearbyHitTesting: true,
                        allowActivationFallback: true
                    ) else {
                        throw ComputerUseError.message(
                            "click_method 'accessibility' could not click element_index=\(elementIndex)"
                        )
                    }
                case .appPost, .skyClick, .global:
                    try performExplicitMouseClick(
                        method: clickMethod,
                        modifiers: modifiers,
                        at: targetPoint,
                        windowPoint: windowPoint,
                        button: button,
                        clickCount: clickCount,
                        targetDescription: "element_index=\(elementIndex)",
                        snapshot: snapshot
                    )
                }
            } catch {
                settleVisualCursor(at: cursorTarget)
                throw error
            }

            pulseVisualCursor(at: cursorTarget, clickCount: clickCount, mouseButton: button)
        } else if let x, let y {
            let screenshotPoint = CGPoint(x: x, y: y)
            let point = try screenshotPixelToWindowPointInSnapshot(snapshot: snapshot, point: screenshotPoint)
            let targetPoint = try windowPointToGlobalPoint(snapshot: snapshot, point: point)
            let cursorTarget = makeVisualCursorTarget(
                at: targetPoint,
                targetWindowID: snapshot.targetWindowID,
                targetWindowLayer: snapshot.targetWindowLayer,
                anchor: makeCursorWindowAnchor(snapshot: snapshot, windowLocalPoint: point)
            )

            moveVisualCursor(to: cursorTarget)

            do {
                switch clickMethod {
                case .auto:
                    let candidates = try clickCandidates(at: point, in: snapshot)
                    var handled = false
                    for record in candidates {
                        if try performAXClickSequence(
                            on: record,
                            snapshot: snapshot,
                            button: button,
                            clickCount: clickCount,
                            includeNearbyHitTesting: false,
                            allowActivationFallback: false,
                            clickPoint: point
                        ) {
                            handled = true
                            break
                        }
                    }

                    if !handled {
                        let targetDescription = "x=\(Int(screenshotPoint.x)) y=\(Int(screenshotPoint.y))"
                        do {
                            // Background AppKit windows ignore plain pid-posted clicks; SkyLight reaches them.
                            try performExplicitMouseClick(
                                method: .skyClick,
                                modifiers: modifiers,
                                at: targetPoint,
                                windowPoint: point,
                                button: button,
                                clickCount: clickCount,
                                targetDescription: targetDescription,
                                snapshot: snapshot
                            )
                        } catch {
                            try performNonAXClickFallback(
                                at: targetPoint,
                                button: button,
                                clickCount: clickCount,
                                targetDescription: targetDescription,
                                snapshot: snapshot
                            )
                        }
                    }
                case .accessibility:
                    throw ComputerUseError.message("click_method 'accessibility' requires element_index")
                case .appPost, .skyClick, .global:
                    try performExplicitMouseClick(
                        method: clickMethod,
                        modifiers: modifiers,
                        at: targetPoint,
                        windowPoint: point,
                        button: button,
                        clickCount: clickCount,
                        targetDescription: "x=\(Int(screenshotPoint.x)) y=\(Int(screenshotPoint.y))",
                        snapshot: snapshot
                    )
                }
            } catch {
                settleVisualCursor(at: cursorTarget)
                throw error
            }

            pulseVisualCursor(at: cursorTarget, clickCount: clickCount, mouseButton: button)
        } else {
            throw ComputerUseError.invalidArguments("click requires either element_index or x/y")
        }

        return try actionResult(for: query, recoveryPolicy: clickActionSnapshotRecoveryPolicy(for: clickMethod))
    }

    public func performSecondaryAction(app query: String, elementIndex: String, action: String) throws -> ToolCallResult {
        let snapshot = try snapshotForAction(app: query, elementIndex: elementIndex)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)

        if snapshot.mode == .fixture {
            guard action.caseInsensitiveCompare("Raise") == .orderedSame else {
                throw ComputerUseError.message(invalidSecondaryActionMessage(action: action, record: record))
            }

            return try actionResult(for: query)
        }

        guard let rawAction = matchingAction(requested: action, record: record) else {
            throw ComputerUseError.message(invalidSecondaryActionMessage(action: action, record: record))
        }

        guard let element = record.element else {
            throw ComputerUseError.stateUnavailable("element \(elementIndex) has no backing accessibility object")
        }

        try requireUsableComputerUseSession()
        let result = AXUIElementPerformAction(element, rawAction as CFString)
        guard result == .success else {
            throw ComputerUseError.message("AXUIElementPerformAction failed with \(result.rawValue)")
        }

        return try actionResult(for: query)
    }

    public func scroll(app query: String, direction: String, elementIndex: String, pages: Double) throws -> ToolCallResult {
        let normalized = direction.lowercased()
        guard ["up", "down", "left", "right"].contains(normalized) else {
            throw ComputerUseError.message("Invalid scroll direction: \(direction)")
        }
        guard pages.isFinite, pages > 0 else {
            throw ComputerUseError.message("pages must be > 0")
        }

        let snapshot = try snapshotForAction(app: query, elementIndex: elementIndex)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)

        if snapshot.mode == .fixture {
            guard let identifier = record.identifier else {
                throw ComputerUseError.invalidArguments("fixture scroll requires an identifier-backed element")
            }
            try FixtureBridge.post(FixtureCommand(kind: "scroll", identifier: identifier, direction: normalized, pages: pages))
            Thread.sleep(forTimeInterval: 0.15)
            return try actionResult(for: query)
        }

        if let repeatCount = integralScrollPageCount(pages),
           let rawAction = record.rawActions.first(where: { $0.caseInsensitiveCompare("AXScroll\(normalized.capitalized)ByPage") == .orderedSame }),
           let element = record.element {
            for _ in 0..<repeatCount {
                try requireUsableComputerUseSession()
                _ = AXUIElementPerformAction(element, rawAction as CFString)
                Thread.sleep(forTimeInterval: 0.05)
            }
        } else if let point = try globalPoint(for: record, snapshot: snapshot) {
            try performScrollEvent(
                at: point,
                direction: normalized,
                pages: pages,
                targetDescription: "element_index=\(elementIndex)",
                snapshot: snapshot
            )
        } else {
            throw ComputerUseError.stateUnavailable("element \(elementIndex) has no scrollable frame")
        }

        return try actionResult(for: query)
    }

    public func drag(
        app query: String,
        fromX: Double,
        fromY: Double,
        toX: Double,
        toY: Double,
        dragMethod: DragMethod = .auto,
        via waypoints: [CGPoint] = [],
        modifiers: CGEventFlags = []
    ) throws -> ToolCallResult {
        let snapshot = try currentSnapshot(for: query)
        guard snapshot.acceptsScreenshotCoordinates else {
            throw ComputerUseError.stateUnavailable(SnapshotObservationOptions.screenshotOmittedNote + "; request a screenshot before screenshot-coordinate actions")
        }
        if snapshot.mode == .fixture {
            try FixtureBridge.post(FixtureCommand(kind: "drag", identifier: "fixture-drag-pad", x: fromX, y: fromY, toX: toX, toY: toY))
            Thread.sleep(forTimeInterval: 0.15)
            return try actionResult(for: query)
        }

        let windowPoints = try ([CGPoint(x: fromX, y: fromY)] + waypoints + [CGPoint(x: toX, y: toY)]).map {
            try screenshotPixelToWindowPointInSnapshot(snapshot: snapshot, point: $0)
        }
        let globalPoints = try windowPoints.map { try windowPointToGlobalPoint(snapshot: snapshot, point: $0) }
        let path = try performDragEvent(
            windowPoints: windowPoints,
            globalPoints: globalPoints,
            method: dragMethod,
            modifiers: modifiers,
            targetDescription: "from=(\(Int(fromX)), \(Int(fromY))) to=(\(Int(toX)), \(Int(toY)))",
            snapshot: snapshot
        )
        return appendingDragDeliveryNote(
            to: try actionResult(for: query, recoveryPolicy: path == .sky ? .readOnly : .allowActivation),
            path: path
        )
    }

    public func typeText(app query: String, text: String, keyMethod: KeyMethod = .auto) throws -> ToolCallResult {
        let snapshot = try currentSnapshot(for: query)
        if snapshot.mode == .fixture {
            try requireAutoKeyMethodForFixture(keyMethod)
            try FixtureBridge.post(FixtureCommand(kind: "type_text", identifier: "fixture-input", value: text))
            Thread.sleep(forTimeInterval: 0.15)
            return try actionResult(for: query)
        }

        if keyMethod == .skyKey {
            let target = try skyKeyTarget(for: snapshot)
            try InputSimulation.typeTextWithSkyLight(text, windowID: target.windowID, pid: target.pid)
            return try actionResult(for: query, recoveryPolicy: keyActionSnapshotRecoveryPolicy(for: keyMethod))
        }

        if try typeTextBySettingFocusedValueIfAvailable(text, in: snapshot) {
            return try actionResult(for: query)
        }

        guard try canTypeTextUsingKeyboardFallback(in: snapshot) else {
            throw ComputerUseError.stateUnavailable("type_text requires a focused editable text element. Click a text entry area first, or use set_value on a settable text element.")
        }

        try InputSimulation.typeText(text, pid: snapshot.app.pid)
        return try actionResult(for: query)
    }

    public func pressKey(app query: String, key: String, keyMethod: KeyMethod = .auto) throws -> ToolCallResult {
        let snapshot = try currentSnapshot(for: query)
        if snapshot.mode == .fixture {
            try requireAutoKeyMethodForFixture(keyMethod)
            try FixtureBridge.post(FixtureCommand(kind: "press_key", identifier: "fixture-key-capture", value: key))
            Thread.sleep(forTimeInterval: 0.15)
            return try actionResult(for: query)
        }

        if keyMethod == .skyKey {
            let target = try skyKeyTarget(for: snapshot)
            try InputSimulation.pressKeyWithSkyLight(key, windowID: target.windowID, pid: target.pid)
            return try actionResult(for: query, recoveryPolicy: keyActionSnapshotRecoveryPolicy(for: keyMethod))
        }

        // Background Chromium windows and AppKit menu shortcuts ignore keys posted
        // to the process; SkyLight delivery reaches them without activating the app.
        if prefersSkyKeys(for: snapshot), let target = try? skyKeyTarget(for: snapshot),
           (try? InputSimulation.pressKeyWithSkyLight(key, windowID: target.windowID, pid: target.pid)) != nil {
            return try actionResult(for: query, recoveryPolicy: .readOnly)
        }

        try InputSimulation.pressKey(key, pid: snapshot.app.pid)
        return try actionResult(for: query)
    }

    private func prefersSkyKeys(for snapshot: AppSnapshot) -> Bool {
        snapshot.mode == .accessibility
            && SkyLightSPI.shared.capability.isAvailable
            && NSWorkspace.shared.frontmostApplication?.processIdentifier != snapshot.app.pid
    }

    private func requireAutoKeyMethodForFixture(_ keyMethod: KeyMethod) throws {
        guard keyMethod == .auto else {
            throw ComputerUseError.message(
                "key_method '\(keyMethod.rawValue)' is not supported for fixture apps"
            )
        }
    }

    private func skyKeyTarget(for snapshot: AppSnapshot) throws -> SkyKeyboardTarget {
        guard let windowID = snapshot.targetWindowID else {
            throw ComputerUseError.stateUnavailable(
                "key_method 'sky_key' requires a current on-screen target window. Run get_app_state again."
            )
        }

        return SkyKeyboardTarget(windowID: windowID, pid: snapshot.app.pid)
    }

    public func setValue(app query: String, elementIndex: String, value: String) throws -> ToolCallResult {
        let snapshot = try snapshotForAction(app: query, elementIndex: elementIndex)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)

        if snapshot.mode == .fixture {
            guard let identifier = record.identifier else {
                throw ComputerUseError.invalidArguments("fixture set_value requires a known element identifier")
            }

            let cursorTarget = visualCursorTarget(for: record, snapshot: snapshot)
            moveVisualCursor(to: cursorTarget)
            try FixtureBridge.post(FixtureCommand(kind: "set_value", identifier: identifier, value: value))
            Thread.sleep(forTimeInterval: 0.15)
            settleVisualCursor(at: cursorTarget)
            return try actionResult(for: query)
        }

        guard let element = record.element else {
            throw ComputerUseError.stateUnavailable("element \(elementIndex) has no backing accessibility object")
        }

        guard try isSettableForSetValue(element: element, attribute: kAXValueAttribute) else {
            throw ComputerUseError.message(nonSettableSetValueErrorMessage)
        }

        let cursorTarget = visualCursorTarget(for: record, snapshot: snapshot)
        moveVisualCursor(to: cursorTarget)

        do {
            try requireUsableComputerUseSession()
            // Focus the field first so a following Return or Tab reaches it, not the page.
            if isSettable(element: element, attribute: kAXFocusedAttribute) {
                _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, setValuePayload(value, for: element))
            guard result == .success else {
                throw ComputerUseError.message("AXUIElementSetAttributeValue failed with \(result.rawValue)")
            }
        } catch {
            settleVisualCursor(at: cursorTarget)
            throw error
        }

        settleVisualCursor(at: cursorTarget)
        return try actionResult(for: query)
    }

    public func selectText(
        app query: String,
        elementIndex: String,
        text: String,
        prefix: String?,
        suffix: String?,
        selection: TextSelectionMode
    ) throws -> ToolCallResult {
        let snapshot = try snapshotForAction(app: query, elementIndex: elementIndex)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)

        if snapshot.mode == .fixture {
            guard let identifier = record.identifier, identifier == "fixture-input",
                  let state = try FixtureBridge.readState(),
                  let value = state.elements.first(where: { $0.identifier == identifier })?.value else {
                throw ComputerUseError.invalidArguments("fixture select_text requires a readable input element")
            }
            let target = try resolveTextSelection(value: value, text: text, prefix: prefix, suffix: suffix,
                                                 selection: selection, elementIndex: elementIndex)
            let cursorTarget = visualCursorTarget(for: record, snapshot: snapshot)
            moveVisualCursor(to: cursorTarget)
            defer { settleVisualCursor(at: cursorTarget) }
            try FixtureBridge.post(FixtureCommand(kind: "select_text", identifier: identifier, value: text,
                                                 selection: selection.rawValue, prefix: prefix, suffix: suffix))
            let deadline = Date().addingTimeInterval(1)
            while Date() < deadline {
                if let applied = try FixtureBridge.readState(), applied.focusedIdentifier == identifier,
                   applied.selectedRangeLocation == target.location, applied.selectedRangeLength == target.length,
                   let current = applied.elements.first(where: { $0.identifier == identifier })?.value,
                   current.utf16.elementsEqual(value.utf16) {
                    return try actionResult(for: query, recoveryPolicy: .readOnly)
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw ComputerUseError.message("select_text could not verify fixture selection")
        }

        try requireUsableComputerUseSession()
        guard let element = record.element else {
            throw ComputerUseError.stateUnavailable("element \(elementIndex) has no backing accessibility object")
        }
        guard let value = stringValue(of: element, attribute: kAXValueAttribute) else {
            throw ComputerUseError.message(selectTextUnreadableValueErrorMessage(elementIndex: elementIndex))
        }
        let target = try resolveTextSelection(value: value, text: text, prefix: prefix, suffix: suffix,
                                             selection: selection, elementIndex: elementIndex)
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            throw ComputerUseError.message("element \(elementIndex) does not support setting an accessibility text range")
        }
        let cursorTarget = visualCursorTarget(for: record, snapshot: snapshot)
        moveVisualCursor(to: cursorTarget)
        defer { settleVisualCursor(at: cursorTarget) }
        try applyVerifiedTextSelection(
            target: target, originalValue: value,
            validate: { try requireUsableComputerUseSession() },
            readValue: { stringValue(of: element, attribute: kAXValueAttribute) },
            writeRange: { try AccessibilityTextSelection.writeRange($0, to: element) },
            readRange: { AccessibilityTextSelection.readRange(of: element) }
        )
        return try actionResult(for: query, recoveryPolicy: .readOnly)
    }

    private func resolveTextSelection(value: String, text: String, prefix: String?, suffix: String?,
                                      selection: TextSelectionMode, elementIndex: String) throws -> TextSelectionTarget {
        do {
            return try TextSelectionResolver.resolve(value: value, text: text, prefix: prefix, suffix: suffix, selection: selection)
        } catch let error as TextSelectionResolverError {
            throw ComputerUseError.message(selectTextErrorMessage(error, elementIndex: elementIndex))
        }
    }

    /// Find controls in the app's current window by text and/or role, using the
    /// app's own accessibility search where it offers one. No tree render, no
    /// screenshot. Each result carries an `index` the existing element actions
    /// (click, set_value, select_text, scroll, perform_secondary_action) accept.
    public func query(
        app query: String,
        text: String? = nil,
        role: String? = nil,
        exact: Bool = false,
        limit: Int = 20,
        maxNodes: Int = 500,
        windowID: CGWindowID? = nil
    ) throws -> [String: Any] {
        guard (text.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false) || (role.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false) else {
            throw ComputerUseError.invalidArguments("query requires at least one of text or role")
        }

        guard text.map({ $0.utf16.count <= 1000 }) ?? true, role.map({ $0.utf16.count <= 1000 }) ?? true else {
            throw ComputerUseError.invalidArguments("query text and role must be at most 1000 UTF-16 code units")
        }
        try requireUsableComputerUseSession()
        let app = try AppDiscovery.resolveRunning(query)
        let context = try SnapshotBuilder.resolveTargetWindow(for: app, windowID: windowID)
        let criteria = TargetedAX.Criteria(text: text, exact: exact, role: role,
                                          limit: min(100, max(1, limit)), maxNodes: min(5000, max(1, maxNodes)))
        let result = try SnapshotBuilder.targetedSearch(criteria, in: context)
        try requireUsableComputerUseSession()
        let matches = result.records.map { registerTargetedElement(record: $0, context: context, criteria: criteria) }
        return ["matches": matches, "truncated": result.truncated,
                "stop_reason": result.stopReason ?? "complete", "visited_nodes": result.visitedNodes,
                "window_id": context.windowID.map { Int($0) } ?? 0,
                "max_nodes": criteria.maxNodes, "limit": criteria.limit]
    }

    /// A snapshot carrying real window context but no rendered tree or screenshot,
    /// so the existing action internals run unchanged against a queried element.
    private func liteSnapshot(context: TargetedAX.WindowContext, elements: [Int: ElementRecord]) -> AppSnapshot {
        AppSnapshot(
            app: context.app,
            windowTitle: nil,
            windowBounds: context.windowBounds,
            targetWindowID: context.windowID,
            targetWindowLayer: context.windowLayer,
            screenshotData: nil,
            mode: .accessibility,
            treeLines: [],
            focusedSummary: nil,
            focusedElement: context.focusedElement,
            selectedText: nil,
            windowElement: context.windowElement,
            elements: elements
        )
    }

    /// The snapshot an element action runs against. A queried index resolves to
    /// that control's own window context with no snapshot; any other index uses
    /// the normal current snapshot.
    private func snapshotForAction(app query: String, elementIndex: String?) throws -> AppSnapshot {
        if let elementIndex, let index = Int(elementIndex), index > TargetedElementRegistry<TargetedElement>.indexBase {
            try requireUsableComputerUseSession()
            let app = try AppDiscovery.resolveRunning(query)
            let target = try targetedElements.resolve(index, app: TargetedAppIdentity(app: app))
            do {
                let (context, record) = try SnapshotBuilder.currentGeometry(of: target.record, in: target.context, criteria: target.criteria)
                return liteSnapshot(context: context, elements: [index: record])
            } catch {
                targetedElements.remove(index)
                throw error
            }
        }
        return try currentSnapshot(for: query)
    }

    private func registerTargetedElement(record source: ElementRecord, context: TargetedAX.WindowContext,
                                         criteria: TargetedAX.Criteria) -> [String: Any] {
        var record: ElementRecord!
        _ = targetedElements.insert(app: TargetedAppIdentity(app: context.app)) { index in
            record = ElementRecord(index: index, identifier: source.identifier, element: source.element,
                                   localFrame: source.localFrame, role: source.role, title: source.title, value: source.value,
                                   rawActions: source.rawActions, prettyActions: source.prettyActions, isSyntheticText: source.isSyntheticText)
            return TargetedElement(record: record, context: context, criteria: criteria)
        }
        return compactRecordDictionary(record)
    }

    private func compactRecordDictionary(_ record: ElementRecord) -> [String: Any] {
        var dict: [String: Any] = ["index": record.index]
        if let role = record.role, !role.isEmpty { dict["role"] = role }
        if let title = record.title, !title.isEmpty { dict["title"] = title }
        if let value = record.value, !value.isEmpty { dict["value"] = value }
        if let identifier = record.identifier, !identifier.isEmpty { dict["identifier"] = identifier }
        if let frame = record.localFrame {
            dict["bounds"] = ["x": frame.origin.x, "y": frame.origin.y, "w": frame.size.width, "h": frame.size.height]
        }
        if !record.prettyActions.isEmpty { dict["actions"] = record.prettyActions }
        return dict
    }

    func currentSnapshot(for query: String) throws -> AppSnapshot {
        if let snapshot = snapshotsByApp[query.lowercased()] {
            if snapshot.mode != .fixture {
                do {
                    try requireUsableComputerUseSession()
                } catch {
                    snapshotsByApp.removeAll()
                    throw error
                }
            }
            return snapshot
        }

        if invalidatedSnapshotAliases.contains(query.lowercased()) {
            throw ComputerUseError.stateUnavailable(SnapshotObservationOptions.accessibilityOmittedNote)
        }
        return try refreshSnapshot(for: query)
    }

    @discardableResult
    /// A minimized window is un-minimized, and a hidden app unhidden, on the
    /// agent display instead of in front of the user.
    private func snapshotParkingMinimizedWindow(
        for query: String,
        textLimit: SnapshotTextLimit,
        treeLimits: AccessibilityTreeLimits,
        recoveryPolicy: SnapshotRecoveryPolicy,
        observation: SnapshotObservationOptions,
        windowID: CGWindowID? = nil
    ) throws -> AppSnapshot {
        // A hidden app's tree is readable, but its screenshot is blank and
        // coordinate clicks never reach it.
        if !foregroundActivationEnabled(), AgentDisplay.shared.isSupported,
           let app = try? AppDiscovery.resolve(query), app.name != FixtureBridge.appName {
            _ = try AgentDisplay.shared.parkHiddenApp(pid: app.pid)
        }
        do {
            return try refreshSnapshot(for: query, textLimit: textLimit, treeLimits: treeLimits, recoveryPolicy: recoveryPolicy, observation: observation, windowID: windowID)
        } catch ComputerUseError.stateUnavailable(let message) where message.hasPrefix(computerUseNoWindowFoundMessage) {
            guard !foregroundActivationEnabled(), AgentDisplay.shared.isSupported else {
                throw ComputerUseError.stateUnavailable(message)
            }
            let app = try AppDiscovery.resolve(query)
            guard try AgentDisplay.shared.parkMinimizedWindow(pid: app.pid)
                    || AgentDisplay.shared.openWindowInBackground(app: app) else {
                throw ComputerUseError.stateUnavailable(message)
            }
            return try refreshSnapshot(for: query, textLimit: textLimit, treeLimits: treeLimits, recoveryPolicy: .readOnly, observation: observation)
        }
    }

    private func refreshSnapshot(
        for query: String,
        textLimit: SnapshotTextLimit = .defaults,
        treeLimits: AccessibilityTreeLimits = .defaults,
        recoveryPolicy: SnapshotRecoveryPolicy = .allowActivation,
        observation: SnapshotObservationOptions = .defaults,
        windowID: CGWindowID? = nil
    ) throws -> AppSnapshot {
        let app = try AppDiscovery.resolve(query)
        let pin = windowID.map { WindowPin(windowID: $0, knownWindowIDs: [], explicit: true) } ?? windowPin(for: query)
        let snapshot = try SnapshotBuilder.build(
            for: app,
            textLimit: textLimit,
            treeLimits: treeLimits,
            recoveryPolicy: recoveryPolicy,
            observation: observation,
            windowPin: pin
        )
        if let windowID, snapshot.targetWindowID != windowID {
            let available = snapshot.windows.map { "\($0.windowID) \(quoted($0.title))" }.joined(separator: ", ")
            throw ComputerUseError.invalidArguments("window_id \(windowID) is not a window of \(snapshot.app.name). Windows: \(available)")
        }

        rememberSnapshot(snapshot, for: query)
        return snapshot
    }

    private func windowPin(for query: String) -> WindowPin? {
        snapshotsByApp[query.lowercased()].flatMap(WindowPin.init(snapshot:))
    }

    func rememberSnapshot(_ snapshot: AppSnapshot, for query: String) {
        let app = snapshot.app
        if !snapshot.observation.includeAX {
            var pids: Set<Int32> = [app.pid]
            if let previous = snapshotsByApp[query.lowercased()] { pids.insert(previous.app.pid) }
            let aliases = snapshotsByApp.compactMap { pids.contains($0.value.app.pid) ? $0.key : nil }
            for alias in aliases {
                snapshotsByApp.removeValue(forKey: alias)
                invalidatedSnapshotAliases.insert(alias)
            }
            targetedElements.removeAll(forPIDs: pids)
        }

        let keys = Set([
            query.lowercased(),
            String(app.pid),
            app.name.lowercased(),
            (app.bundleIdentifier ?? "").lowercased(),
        ].filter { !$0.isEmpty })

        for key in keys {
            snapshotsByApp[key] = snapshot
            invalidatedSnapshotAliases.remove(key)
        }

    }

    private func lookupElement(snapshot: AppSnapshot, index: String) throws -> ElementRecord {
        guard let parsedIndex = Int(index), let record = snapshot.elements[parsedIndex] else {
            throw ComputerUseError.invalidArguments("unknown element_index '\(index)'")
        }

        return record
    }

    func matchingAction(requested: String, record: ElementRecord) -> String? {
        if let exact = record.rawActions.first(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }) {
            return exact
        }
        let visibleActions = record.role.map { meaningfulRawActions(record.rawActions, role: $0) } ?? record.rawActions
        let matches = visibleActions.filter { rawAction in
            secondaryActionNamesEquivalent(requested, secondaryActionDisplayName(rawAction))
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func invalidSecondaryActionMessage(action: String, record: ElementRecord) -> String {
        invalidSecondaryActionErrorMessage(action: action, elementIndex: record.index)
    }

    private func performPreferredClick(on record: ElementRecord, button: MouseButtonKind, clickCount: Int) throws -> Bool {
        guard let element = record.element else {
            return false
        }

        switch button {
        case .left:
            if clickCount <= 1,
               !hasAncestorRole("AXWebArea", of: element),
               try selectContainingListItem(for: element)
            {
                return true
            }

            if try performAction(named: kAXPressAction as String, on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                return true
            }

            if try performAction(named: kAXConfirmAction as String, on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                return true
            }

            if try performAction(named: "AXOpen", on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                return true
            }
        case .right:
            if try performAction(named: kAXShowMenuAction as String, on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                return true
            }
        case .middle:
            break
        }

        return false
    }

    private func clickCandidates(at point: CGPoint, in snapshot: AppSnapshot) throws -> [ElementRecord] {
        var candidates: [ElementRecord] = []

        if let bestRecord = bestElement(containing: point, in: snapshot) {
            candidates.append(bestRecord)
        }

        if let hitRecord = try hitTestElement(at: point, in: snapshot) {
            candidates.append(hitRecord)
        }

        return candidates.reduce(into: []) { uniqueCandidates, candidate in
            if !uniqueCandidates.contains(where: { sameElement($0.element, candidate.element) }) {
                uniqueCandidates.append(candidate)
            }
        }
    }

    private func sameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else {
            return false
        }

        return CFEqual(lhs, rhs)
    }

    private func selectContainingListItem(for element: AXUIElement) throws -> Bool {
        guard let target = selectableListItem(containing: element) else {
            return false
        }

        try requireUsableComputerUseSession()
        let result = AXUIElementSetAttributeValue(
            target.list,
            kAXSelectedChildrenAttribute as CFString,
            [target.item] as CFArray
        )

        switch result {
        case .success:
            return true
        case .failure, .attributeUnsupported, .actionUnsupported, .cannotComplete, .noValue, .invalidUIElement, .illegalArgument:
            return false
        default:
            throw ComputerUseError.message("AXUIElementSetAttributeValue(\(kAXSelectedChildrenAttribute)) failed with \(result.rawValue)")
        }
    }

    private func selectableListItem(containing element: AXUIElement) -> (list: AXUIElement, item: AXUIElement)? {
        var current = element
        var directChild = element

        for _ in 0..<8 {
            guard let parent = copyParent(of: current) else {
                return nil
            }

            if stringValue(of: parent, attribute: kAXRoleAttribute) == kAXListRole as String,
               isSettable(element: parent, attribute: kAXSelectedChildrenAttribute)
            {
                return (parent, directChild)
            }

            directChild = parent
            current = parent
        }

        return nil
    }

    private func performAXClickSequence(
        on record: ElementRecord,
        snapshot: AppSnapshot,
        button: MouseButtonKind,
        clickCount: Int,
        includeNearbyHitTesting: Bool,
        allowActivationFallback: Bool,
        clickPoint: CGPoint? = nil
    ) throws -> Bool {
        let preferContainingWebRowAXClick = shouldPreferContainingWebRowAXClick(record, in: snapshot)
        debugClickDecision("record=\(clickDebugDescription(record)) preferContainingWebRowAXClick=\(preferContainingWebRowAXClick)")

        if preferContainingWebRowAXClick,
           try performContainingWebRowClick(for: record, snapshot: snapshot, button: button, clickCount: clickCount)
        {
            return true
        }

        if !preferContainingWebRowAXClick {
            if try performPreferredClick(on: record, button: button, clickCount: clickCount) {
                debugClickDecision("handled by preferred target \(clickDebugDescription(record))")
                return true
            }

            // A click on a window's blank area must not fall through to its close or minimize button.
            for candidate in descendantClickCandidates(for: record, snapshot: snapshot)
            where clickPoint.map({ candidate.localFrame?.contains($0) ?? false }) ?? true {
                if try performPreferredClick(on: candidate, button: button, clickCount: clickCount) {
                    debugClickDecision("handled by descendant \(clickDebugDescription(candidate))")
                    return true
                }
            }

            if includeNearbyHitTesting {
                for localPoint in clickActionPoints(for: record, snapshot: snapshot) {
                    guard let hitRecord = try hitTestElement(at: localPoint, in: snapshot) ?? bestElement(containing: localPoint, in: snapshot) else {
                        continue
                    }

                    if !isLikelySyntheticSideAction(hitRecord, in: record),
                       try performPreferredClick(on: hitRecord, button: button, clickCount: clickCount)
                    {
                        debugClickDecision("handled by hit record \(clickDebugDescription(hitRecord))")
                        return true
                    }

                    if shouldScanDescendantsOfHitRecord(
                        originalFrame: clickFrame(for: record, snapshot: snapshot),
                        hitFrame: hitRecord.localFrame
                    ) {
                        for candidate in descendantClickCandidates(
                            for: hitRecord,
                            snapshot: snapshot,
                            sideActionScope: record
                        ) {
                            if try performPreferredClick(on: candidate, button: button, clickCount: clickCount) {
                                debugClickDecision("handled by hit descendant \(clickDebugDescription(candidate))")
                                return true
                            }
                        }
                    }
                }
            }
        }

        guard
            allowActivationFallback,
            foregroundActivationEnabled(),
            !record.isSyntheticText,
            button == .left,
            let element = record.element,
            canUseActivationOnlyClickFallback(role: stringValue(of: element, attribute: kAXRoleAttribute))
        else {
            return false
        }

        if try activateClickTarget(element: element, availableActions: record.rawActions) {
            debugClickDecision("handled by activation fallback \(clickDebugDescription(record))")
            return true
        }

        return false
    }

    private func performAction(named action: String, on element: AXUIElement, availableActions: [String], repeatCount: Int = 1) throws -> Bool {
        guard availableActions.contains(where: { $0.caseInsensitiveCompare(action) == .orderedSame }) else {
            return false
        }

        // Showing a menu runs the app's menu tracking loop, which holds the AX
        // reply until the menu closes; the menu is open once the request is in.
        let showsMenu = action == kAXShowMenuAction as String
        if showsMenu {
            AXUIElementSetMessagingTimeout(element, 0.5)
        }
        defer {
            if showsMenu {
                AXUIElementSetMessagingTimeout(element, 0)
            }
        }
        let attempts = max(repeatCount, 1)
        for index in 0..<attempts {
            try requireUsableComputerUseSession()
            let result = AXUIElementPerformAction(element, action as CFString)
            switch result {
            case .cannotComplete where showsMenu:
                return true
            case .success:
                if index < attempts - 1 {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            case .attributeUnsupported where action.caseInsensitiveCompare("AXOpen") == .orderedSame:
                return true
            case .failure, .actionUnsupported, .attributeUnsupported, .cannotComplete, .noValue, .invalidUIElement, .illegalArgument:
                return false
            default:
                throw ComputerUseError.message("AXUIElementPerformAction(\(action)) failed with \(result.rawValue)")
            }
        }

        return true
    }

    private func activateClickTarget(element: AXUIElement, availableActions: [String]) throws -> Bool {
        var activated = false

        if try performAction(named: kAXRaiseAction as String, on: element, availableActions: availableActions) {
            activated = true
        }

        if try setBoolAttribute(named: kAXMainAttribute, on: element) {
            activated = true
        }

        if try setBoolAttribute(named: kAXFocusedAttribute, on: element) {
            activated = true
        }

        return activated
    }

    private func setBoolAttribute(named attribute: String, on element: AXUIElement) throws -> Bool {
        try requireUsableComputerUseSession()
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanTrue)
        switch result {
        case .success:
            return true
        case .failure, .attributeUnsupported, .actionUnsupported, .cannotComplete, .noValue, .invalidUIElement, .illegalArgument:
            return false
        default:
            throw ComputerUseError.message("AXUIElementSetAttributeValue(\(attribute)) failed with \(result.rawValue)")
        }
    }

    private func isSettable(element: AXUIElement, attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return result == .success && settable.boolValue
    }

    /// Sliders and steppers reject a string value; send a number when the element holds one.
    private func setValuePayload(_ value: String, for element: AXUIElement) -> CFTypeRef {
        var current: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &current) == .success,
              let current, CFGetTypeID(current) == CFNumberGetTypeID(),
              let number = Double(value.trimmingCharacters(in: .whitespaces))
        else {
            return value as CFString
        }
        return NSNumber(value: number)
    }

    private func isSettableForSetValue(element: AXUIElement, attribute: String) throws -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return try setValueAttributeIsSettable(
            result: result,
            settable: settable.boolValue,
            attribute: attribute
        )
    }

    private func bestElement(containing point: CGPoint, in snapshot: AppSnapshot) -> ElementRecord? {
        snapshot.elements.values
            .filter { $0.localFrame?.contains(point) ?? false }
            .sorted { lhs, rhs in
                let lhsPriority = clickPriority(for: lhs)
                let rhsPriority = clickPriority(for: rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }

                return frameArea(of: lhs) < frameArea(of: rhs)
            }
            .first
    }

    private func hitTestElement(at point: CGPoint, in snapshot: AppSnapshot) throws -> ElementRecord? {
        let appElement = AXUIElementCreateApplication(snapshot.app.pid)
        let globalPoint = try screenshotToGlobalPoint(snapshot: snapshot, x: Double(point.x), y: Double(point.y))
        var hitElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(appElement, Float(globalPoint.x), Float(globalPoint.y), &hitElement)
        guard result == .success, let hitElement else {
            return nil
        }

        let rawActions = copyActions(for: hitElement) ?? []
        return ElementRecord(
            index: -1,
            identifier: nil,
            element: hitElement,
            localFrame: localFrame(of: hitElement, windowBounds: snapshot.windowBounds),
            rawActions: rawActions,
            prettyActions: rawActions
        )
    }

    private func clickPriority(for record: ElementRecord) -> Int {
        if record.rawActions.contains(where: {
            $0.caseInsensitiveCompare(kAXPressAction as String) == .orderedSame ||
            $0.caseInsensitiveCompare(kAXConfirmAction as String) == .orderedSame ||
            $0.caseInsensitiveCompare(kAXShowMenuAction as String) == .orderedSame ||
            $0.caseInsensitiveCompare(kAXRaiseAction as String) == .orderedSame
        }) {
            return 0
        }

        if let element = record.element,
           isSettable(element: element, attribute: kAXMainAttribute) ||
           isSettable(element: element, attribute: kAXFocusedAttribute) {
            return 1
        }

        return 2
    }

    private func frameArea(of record: ElementRecord) -> CGFloat {
        guard let frame = record.localFrame else {
            return .greatestFiniteMagnitude
        }

        return frame.width * frame.height
    }

    private func localCenter(for record: ElementRecord) -> CGPoint? {
        guard let frame = record.localFrame else {
            return nil
        }

        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func clickActionPoints(for record: ElementRecord, snapshot: AppSnapshot) -> [CGPoint] {
        guard let frame = clickFrame(for: record, snapshot: snapshot) else {
            return []
        }

        return localClickActionPoints(frame: frame, isSyntheticText: record.isSyntheticText)
    }

    private func descendantClickCandidates(
        for record: ElementRecord,
        snapshot: AppSnapshot,
        sideActionScope: ElementRecord? = nil
    ) -> [ElementRecord] {
        guard let element = record.element else {
            return []
        }

        let sideActionParent = sideActionScope ?? record
        return descendantClickCandidates(of: element, windowBounds: snapshot.windowBounds)
            .filter { candidate in
                !isLikelySyntheticSideAction(candidate, in: sideActionParent)
            }
            .sorted { lhs, rhs in
                let lhsPriority = clickPriority(for: lhs)
                let rhsPriority = clickPriority(for: rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }

                return frameArea(of: lhs) < frameArea(of: rhs)
            }
    }

    private func descendantClickCandidates(of element: AXUIElement, windowBounds: CGRect?, depth: Int = 0) -> [ElementRecord] {
        guard depth < 3 else {
            return []
        }

        var results: [ElementRecord] = []
        for child in copyChildren(of: element) {
            let rawActions = copyActions(for: child) ?? []
            results.append(
                ElementRecord(
                    index: -1,
                    identifier: nil,
                    element: child,
                    localFrame: localFrame(of: child, windowBounds: windowBounds),
                    rawActions: rawActions,
                    prettyActions: rawActions
                )
            )
            results.append(contentsOf: descendantClickCandidates(of: child, windowBounds: windowBounds, depth: depth + 1))
        }

        return results
    }

    private func isLikelySyntheticSideAction(_ candidate: ElementRecord, in parent: ElementRecord) -> Bool {
        isLikelySyntheticSideActionCandidate(
            parentFrame: parent.localFrame,
            candidateFrame: candidate.localFrame,
            hasPrimaryAction: hasPrimaryClickAction(candidate),
            labels: accessibilityLabels(for: candidate.element)
        )
    }

    private func hasPrimaryClickAction(_ record: ElementRecord) -> Bool {
        record.rawActions.contains { action in
            action.caseInsensitiveCompare(kAXPressAction as String) == .orderedSame ||
                action.caseInsensitiveCompare(kAXConfirmAction as String) == .orderedSame ||
                action.caseInsensitiveCompare("AXOpen") == .orderedSame ||
                action.caseInsensitiveCompare(kAXShowMenuAction as String) == .orderedSame
        }
    }

    private func shouldPreferContainingWebRowAXClick(_ record: ElementRecord, in snapshot: AppSnapshot) -> Bool {
        guard
            let element = record.element
        else {
            return false
        }

        return shouldPreferContainingWebRowAXClickCandidate(
            role: stringValue(of: element, attribute: kAXRoleAttribute),
            isSyntheticText: record.isSyntheticText,
            hasWebAreaAncestor: hasAncestorRole("AXWebArea", of: element),
            appName: snapshot.app.name,
            bundleIdentifier: snapshot.app.bundleIdentifier
        )
    }

    private func performContainingWebRowClick(
        for record: ElementRecord,
        snapshot: AppSnapshot,
        button: MouseButtonKind,
        clickCount: Int
    ) throws -> Bool {
        guard
            button == .left,
            clickCount <= 1,
            let element = record.element,
            let targetFrame = record.localFrame
        else {
            return false
        }

        var current = element

        for _ in 0..<6 {
            guard let parent = copyParent(of: current) else {
                return false
            }

            let rawActions = copyActions(for: parent) ?? []
            let candidate = ElementRecord(
                index: -1,
                identifier: nil,
                element: parent,
                localFrame: localFrame(of: parent, windowBounds: snapshot.windowBounds),
                rawActions: rawActions,
                prettyActions: rawActions
            )

            if isLikelyContainingWebRowAction(targetFrame: targetFrame, candidate: candidate),
               !isLikelySyntheticSideAction(candidate, in: record),
               try performAction(named: kAXPressAction as String, on: parent, availableActions: rawActions)
            {
                debugClickDecision("handled by containing web row \(clickDebugDescription(candidate))")
                return true
            }

            current = parent
        }

        return false
    }

    private func isLikelyContainingWebRowAction(
        targetFrame: CGRect,
        candidate: ElementRecord
    ) -> Bool {
        isLikelyContainingRowActionFrame(
            targetFrame: targetFrame,
            candidateFrame: candidate.localFrame,
            hasPrimaryAction: hasPrimaryClickAction(candidate)
        )
    }

    private func hasAncestorRole(_ role: String, of element: AXUIElement) -> Bool {
        var current = element

        for _ in 0..<12 {
            guard let parent = copyParent(of: current) else {
                return false
            }

            if stringValue(of: parent, attribute: kAXRoleAttribute) == role {
                return true
            }

            current = parent
        }

        return false
    }

    private func accessibilityLabels(for element: AXUIElement?) -> [String] {
        guard let element else {
            return []
        }

        return [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXHelpAttribute as String,
            kAXValueAttribute as String,
            "AXIdentifier"
        ].compactMap { attribute in
            stringValue(of: element, attribute: attribute)
        }
    }

    /// The app's focus now: the stored snapshot predates any action run without read-back.
    private func liveFocusedElement(in snapshot: AppSnapshot) -> AXUIElement? {
        var value: CFTypeRef?
        let appElement = AXUIElementCreateApplication(snapshot.app.pid)
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return snapshot.focusedElement
        }
        return (value as! AXUIElement)
    }

    private func typeTextBySettingFocusedValueIfAvailable(_ text: String, in snapshot: AppSnapshot) throws -> Bool {
        // A focus that cannot report settability falls through to keyboard input.
        guard let element = liveFocusedElement(in: snapshot),
              (try? isSettableForSetValue(element: element, attribute: kAXValueAttribute)) == true
        else {
            return false
        }

        let baseValue = editableBaseValue(for: element)
        try requireUsableComputerUseSession()
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, (baseValue + text) as CFString)
        switch result {
        case .success:
            return true
        case .failure, .attributeUnsupported, .actionUnsupported, .cannotComplete, .noValue, .invalidUIElement, .illegalArgument:
            return false
        default:
            throw ComputerUseError.message("AXUIElementSetAttributeValue failed with \(result.rawValue)")
        }
    }

    private func canTypeTextUsingKeyboardFallback(in snapshot: AppSnapshot) throws -> Bool {
        guard let element = liveFocusedElement(in: snapshot) else {
            return false
        }

        let role = stringValue(of: element, attribute: kAXRoleAttribute)
        let roleDescription = role.flatMap {
            stringValue(of: element, attribute: kAXRoleDescriptionAttribute) ?? humanizedRoleDescription(for: $0)
        }
        return canUseKeyboardTextFallback(
            role: role,
            roleDescription: roleDescription,
            isValueSettable: (try? isSettableForSetValue(element: element, attribute: kAXValueAttribute)) ?? false
        )
    }

    private func humanizedRoleDescription(for role: String) -> String {
        if role == kAXTextFieldRole as String {
            return "text field"
        }

        switch role {
        case "AXTextArea", "AXTextView":
            return "text entry area"
        default:
            return ""
        }
    }

    private func editableBaseValue(for element: AXUIElement) -> String {
        let childTextValues = editableDescendantTextValues(in: element)
            .filter { !looksLikeEditablePlaceholder($0) }
        if !childTextValues.isEmpty {
            return childTextValues.joined()
        }

        guard let currentValue = stringValue(of: element, attribute: kAXValueAttribute) else {
            return ""
        }

        let normalizedValue = normalizeEditablePlaceholderText(currentValue)
        if normalizedValue.isEmpty || looksLikeEditablePlaceholder(normalizedValue) {
            return ""
        }

        for attribute in ["AXPlaceholderValue", "AXPlaceholder"] {
            guard let placeholder = stringValue(of: element, attribute: attribute) else {
                continue
            }

            if normalizedValue == normalizeEditablePlaceholderText(placeholder) {
                return ""
            }
        }

        return currentValue
    }

    private func editableDescendantTextValues(in element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 4 else {
            return []
        }

        var values: [String] = []
        for child in copyChildren(of: element) {
            if stringValue(of: child, attribute: kAXRoleAttribute) == kAXStaticTextRole as String,
               let value = stringValue(of: child, attribute: kAXValueAttribute)
                    ?? stringValue(of: child, attribute: kAXTitleAttribute)
            {
                let normalized = normalizeEditablePlaceholderText(value)
                if !normalized.isEmpty {
                    values.append(normalized)
                }
            }

            values.append(contentsOf: editableDescendantTextValues(in: child, depth: depth + 1))
        }

        return values
    }

    private func looksLikeEditablePlaceholder(_ value: String) -> Bool {
        let normalized = normalizeEditablePlaceholderText(value)
        return normalized == "沟通时请保持“公开可接受”"
    }

    private func normalizeEditablePlaceholderText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clickFrame(for record: ElementRecord, snapshot: AppSnapshot) -> CGRect? {
        guard let frame = record.localFrame else {
            return nil
        }

        guard
            !record.isSyntheticText,
            let element = record.element,
            stringValue(of: element, attribute: kAXRoleAttribute) == kAXStaticTextRole as String,
            let rowFrame = containingRowFrame(for: element, textFrame: frame, windowBounds: snapshot.windowBounds)
        else {
            return frame
        }

        return rowFrame
    }

    private func containingRowFrame(for element: AXUIElement, textFrame: CGRect, windowBounds: CGRect?) -> CGRect? {
        let textCenter = CGPoint(x: textFrame.midX, y: textFrame.midY)
        var current = element

        for _ in 0..<4 {
            guard let parent = copyParent(of: current) else {
                return nil
            }

            if let frame = localFrame(of: parent, windowBounds: windowBounds),
               frame.insetBy(dx: -2, dy: -2).contains(textCenter),
               frame.width >= textFrame.width + 40,
               frame.height >= textFrame.height,
               frame.height <= max(textFrame.height * 4, 96)
            {
                return frame
            }

            current = parent
        }

        return nil
    }

    private func copyActions(for element: AXUIElement) -> [String]? {
        var actions: CFArray?
        let result = AXUIElementCopyActionNames(element, &actions)
        guard result == .success else {
            return nil
        }

        return actions as? [String]
    }

    private func copyChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let value else {
            return []
        }

        return value as? [AXUIElement] ?? []
    }

    private func copyParent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        guard result == .success, let value else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private func stringValue(of element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else {
            return nil
        }

        return value as? String
    }

    private func localFrame(of element: AXUIElement, windowBounds: CGRect?) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)

        guard
            positionResult == .success,
            sizeResult == .success,
            let positionValue,
            let sizeValue
        else {
            return nil
        }

        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position), AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return nil
        }

        let frame = CGRect(origin: position, size: size)
        guard let windowBounds else {
            return frame
        }

        return windowRelativeFrame(elementFrame: frame, windowBounds: windowBounds)
    }

    private func globalPoint(for record: ElementRecord, snapshot: AppSnapshot) throws -> CGPoint? {
        guard let frame = record.localFrame else {
            return nil
        }

        return try windowPointToGlobalPoint(
            snapshot: snapshot,
            point: CGPoint(x: frame.midX, y: frame.midY)
        )
    }

    private func clickPoint(for record: ElementRecord, snapshot: AppSnapshot) -> CGPoint? {
        clickActionPoints(for: record, snapshot: snapshot).first ?? localCenter(for: record)
    }

    private func screenshotToGlobalPoint(snapshot: AppSnapshot, x: Double, y: Double) throws -> CGPoint {
        try windowPointToGlobalPoint(
            snapshot: snapshot,
            point: try screenshotPixelToWindowPointInSnapshot(
                snapshot: snapshot,
                point: CGPoint(x: x, y: y)
            )
        )
    }

    private func screenshotPixelToWindowPointInSnapshot(snapshot: AppSnapshot, point: CGPoint) throws -> CGPoint {
        if snapshot.screenshotData == nil, snapshot.carriedScreenshotPixelSize == nil, let note = snapshot.screenshotNote {
            throw ComputerUseError.stateUnavailable(note + "; coordinate input requires a delivered screenshot")
        }
        return screenshotPixelToWindowPoint(
            point,
            screenshotPixelSize: screenshotPixelSize(snapshot: snapshot),
            windowBounds: snapshot.windowBounds
        )
    }

    private func screenshotPixelSize(snapshot: AppSnapshot) -> CGSize? {
        if snapshot.screenshotData == nil, let carried = snapshot.carriedScreenshotPixelSize {
            return carried
        }
        guard
            let screenshotData = snapshot.screenshotData,
            let imageSource = CGImageSourceCreateWithData(screenshotData as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
            let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat,
            pixelWidth > 0,
            pixelHeight > 0
        else {
            return nil
        }

        return CGSize(width: pixelWidth, height: pixelHeight)
    }

    private func windowPointToGlobalPoint(snapshot: AppSnapshot, point: CGPoint) throws -> CGPoint {
        guard let windowBounds = snapshot.windowBounds else {
            let appReference = snapshot.app.bundleIdentifier ?? snapshot.app.name
            throw ComputerUseError.stateUnavailable("No window bounds are available for \(appReference). Run get_app_state after bringing the app on screen.")
        }

        return CGPoint(x: windowBounds.minX + point.x, y: windowBounds.minY + point.y)
    }

    private func fixtureIdentifier(at point: CGPoint, snapshot: AppSnapshot) throws -> String {
        let candidates = snapshot.elements.values
            .filter { $0.identifier != nil && ($0.localFrame?.contains(point) ?? false) }
            .sorted { lhs, rhs in
                let lhsArea = (lhs.localFrame?.width ?? 0) * (lhs.localFrame?.height ?? 0)
                let rhsArea = (rhs.localFrame?.width ?? 0) * (rhs.localFrame?.height ?? 0)
                return lhsArea < rhsArea
            }

        guard let identifier = candidates.first?.identifier else {
            throw ComputerUseError.invalidArguments("No fixture element contains coordinate (\(Int(point.x)), \(Int(point.y)))")
        }

        return identifier
    }

    private func visualCursorTarget(for record: ElementRecord, snapshot: AppSnapshot) -> VisualCursorTarget? {
        // The accessibility element is the overlay's only immediate source of
        // truth for the window frame: the window list can keep reporting the
        // pre-move origin for about a second.
        CursorWindowFrameTracker.register(
            windowID: snapshot.targetWindowID,
            element: snapshot.windowElement
        )

        return makeVisualCursorTarget(
            localFrame: record.localFrame,
            windowBounds: snapshot.windowBounds,
            targetWindowID: snapshot.targetWindowID,
            targetWindowLayer: snapshot.targetWindowLayer
        )
    }

    private func fixtureVisualCursorTarget(identifier: String, snapshot: AppSnapshot) -> VisualCursorTarget? {
        let record = snapshot.elements.values.first { $0.identifier == identifier }
        return record.flatMap { visualCursorTarget(for: $0, snapshot: snapshot) }
    }

    private func moveVisualCursor(to target: VisualCursorTarget?) {
        guard let target else {
            return
        }

        VisualCursorSupport.enqueueOnMain(startsMove: true) {
            SoftwareCursorOverlay.moveCursor(to: target.point, in: target.window, anchor: target.anchor)
        }
    }

    private func settleVisualCursor(at target: VisualCursorTarget?) {
        guard let target else {
            return
        }

        VisualCursorSupport.enqueueOnMain(startsMove: false) {
            SoftwareCursorOverlay.settle(at: target.point, in: target.window, anchor: target.anchor)
        }
    }

    private func pulseVisualCursor(at target: VisualCursorTarget?, clickCount: Int, mouseButton: MouseButtonKind) {
        guard let target else {
            return
        }

        VisualCursorSupport.enqueueOnMain(startsMove: false) {
            SoftwareCursorOverlay.pulseClick(
                at: target.point,
                clickCount: clickCount,
                mouseButton: mouseButton,
                in: target.window,
                anchor: target.anchor
            )
        }
    }

    private func debugInputFallback(tool: String, targetDescription: String, snapshot: AppSnapshot) {
        guard inputFallbackDebugEnabled(environment: ProcessInfo.processInfo.environment) else {
            return
        }

        let appReference = snapshot.app.bundleIdentifier ?? snapshot.app.name
        fputs(
            "[open-computer-use] global pointer fallback tool=\(tool) app=\(appReference) target=\(targetDescription)\n",
            stderr
        )
    }

    private func debugClickDecision(_ message: String) {
        guard inputFallbackDebugEnabled(environment: ProcessInfo.processInfo.environment) else {
            return
        }

        fputs("[open-computer-use] click decision \(message)\n", stderr)
    }

    private func clickDebugDescription(_ record: ElementRecord) -> String {
        let role = record.element.flatMap { stringValue(of: $0, attribute: kAXRoleAttribute) } ?? "nil"
        let actions = record.rawActions.joined(separator: ",")
        let frame = record.localFrame.map { "x=\(Int($0.minX)) y=\(Int($0.minY)) w=\(Int($0.width)) h=\(Int($0.height))" } ?? "nil"
        return "index=\(record.index) role=\(role) synthetic=\(record.isSyntheticText) actions=[\(actions)] frame=\(frame)"
    }

    private func integralScrollPageCount(_ pages: Double) -> Int? {
        let rounded = pages.rounded(.toNearestOrAwayFromZero)
        guard abs(pages - rounded) < 0.000001 else {
            return nil
        }
        return max(Int(rounded), 1)
    }

    private func performScrollEvent(
        at point: CGPoint,
        direction: String,
        pages: Double,
        targetDescription: String,
        snapshot: AppSnapshot
    ) throws {
        let eventPoint = inputEventPoint(fromScreenStatePoint: point)

        if globalPointerFallbacksEnabled(environment: ProcessInfo.processInfo.environment) {
            debugInputFallback(
                tool: "scroll",
                targetDescription: targetDescription,
                snapshot: snapshot
            )
            InputSimulation.prepareAppForGlobalPointerInput(snapshot.app)
            try InputSimulation.scrollGlobally(at: eventPoint, direction: direction, pages: pages)
            return
        }

        try InputSimulation.scrollTargeted(at: eventPoint, direction: direction, pages: pages, pid: snapshot.app.pid)
    }

    private func performDragEvent(
        windowPoints: [CGPoint],
        globalPoints: [CGPoint],
        method: DragMethod,
        modifiers: CGEventFlags,
        targetDescription: String,
        snapshot: AppSnapshot
    ) throws -> DragDeliveryPath {
        let eventPoints = globalPoints.map { inputEventPoint(fromScreenStatePoint: $0) }
        let eventStart = eventPoints[0]
        let eventEnd = eventPoints[eventPoints.count - 1]
        let path = try dragDeliveryPath(environment: ProcessInfo.processInfo.environment, method: method)
        if path != .sky, eventPoints.count > 2 || !modifiers.isEmpty {
            throw ComputerUseError.message("path and modifiers are only supported with drag_method 'sky'")
        }

        switch path {
        case .global:
            debugInputFallback(
                tool: "drag",
                targetDescription: targetDescription,
                snapshot: snapshot
            )
            InputSimulation.prepareAppForGlobalPointerInput(snapshot.app)
            try InputSimulation.dragGlobally(from: eventStart, to: eventEnd)
        case .appPost:
            try InputSimulation.dragTargeted(from: eventStart, to: eventEnd, pid: snapshot.app.pid)
        case .sky:
            guard let windowBounds = snapshot.windowBounds, let windowID = snapshot.targetWindowID else {
                throw ComputerUseError.stateUnavailable(
                    "drag_method 'sky' requires a current target window. Run get_app_state again."
                )
            }
            try SkyClickDispatcher.drag(
                through: zip(eventPoints, windowPoints).map {
                    SkyClickTarget(screenPoint: $0, windowPoint: $1, windowBounds: windowBounds, windowID: windowID, pid: snapshot.app.pid)
                },
                modifiers: modifiers
            )
        }

        return path
    }

    private func performNonAXClickFallback(
        at point: CGPoint,
        button: MouseButtonKind,
        clickCount: Int,
        targetDescription: String,
        snapshot: AppSnapshot
    ) throws {
        let eventPoint = inputEventPoint(fromScreenStatePoint: point)

        if globalPointerFallbacksEnabled(environment: ProcessInfo.processInfo.environment) {
            debugInputFallback(
                tool: "click",
                targetDescription: targetDescription,
                snapshot: snapshot
            )
            InputSimulation.prepareAppForGlobalPointerInput(snapshot.app)
            try InputSimulation.clickGlobally(at: eventPoint, button: button, clickCount: clickCount)
            return
        }

        do {
            try InputSimulation.clickTargeted(
                at: eventPoint,
                button: button,
                clickCount: clickCount,
                pid: snapshot.app.pid
            )
            return
        } catch {
            guard globalPointerFallbacksEnabled(environment: ProcessInfo.processInfo.environment) else {
                throw ComputerUseError.message(
                    "click could not be handled through accessibility, and global pointer fallback is disabled. Set OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 to allow physical-pointer fallback for this process."
                )
            }
        }
    }

    private func performExplicitMouseClick(
        method: ClickMethod,
        modifiers: CGEventFlags,
        at point: CGPoint,
        windowPoint: CGPoint,
        button: MouseButtonKind,
        clickCount: Int,
        targetDescription: String,
        snapshot: AppSnapshot
    ) throws {
        let eventPoint = inputEventPoint(fromScreenStatePoint: point)

        switch method {
        case .appPost:
            debugClickDecision("requested=app_post executed=pid_post target=\(targetDescription)")
            try InputSimulation.clickTargeted(
                at: eventPoint,
                button: button,
                clickCount: clickCount,
                pid: snapshot.app.pid
            )
        case .skyClick:
            guard let windowBounds = snapshot.windowBounds, let windowID = snapshot.targetWindowID else {
                throw ComputerUseError.stateUnavailable(
                    "click_method 'sky_click' requires a current on-screen target window. Run get_app_state again."
                )
            }
            debugClickDecision("requested=sky_click executed=skylight_pid_post target=\(targetDescription)")
            try InputSimulation.clickWithSkyLight(
                at: eventPoint,
                windowPoint: windowPoint,
                windowBounds: windowBounds,
                windowID: windowID,
                clickCount: clickCount,
                button: button,
                modifiers: modifiers,
                pid: snapshot.app.pid
            )
        case .global:
            guard globalPointerFallbacksEnabled(environment: ProcessInfo.processInfo.environment) else {
                throw ComputerUseError.message(
                    "click_method 'global' requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 because it may move the system pointer and change foreground focus"
                )
            }
            debugClickDecision("requested=global executed=global_hid target=\(targetDescription)")
            InputSimulation.prepareAppForGlobalPointerInput(snapshot.app)
            try InputSimulation.clickGlobally(at: eventPoint, button: button, clickCount: clickCount)
        case .auto, .accessibility:
            throw ComputerUseError.message(
                "click_method '\(method.rawValue)' is not a direct mouse event method"
            )
        }
    }

    private func snapshotResult(for snapshot: AppSnapshot, style: SnapshotTextStyle) -> ToolCallResult {
        var content = [ToolResultContentItem.text(snapshot.renderedText(style: style))]
        if let note = snapshot.screenshotNote { content.append(.text(note)) }
        if let screenshotData = snapshot.screenshotData {
            content.append(.screenshotImage(screenshotData))
        }
        return ToolCallResult(content: content)
    }
}
