import Foundation

/// What an action reports about the window after it runs.
public enum ActionStateMode: String, CaseIterable, Sendable {
    /// Only what changed in the accessibility tree since the state the agent last saw.
    case diff
    /// The whole accessibility tree, as `get_app_state` renders it.
    case full
    /// A short confirmation; nothing is read back.
    case none
}

public struct ActionObservation: Equatable, Sendable {
    public var state: ActionStateMode
    public var screenshot: Bool
    /// Text that must appear in the tree before the result returns; a leading `!` waits for it to disappear.
    public var waitFor: String?
    public var waitTimeout: TimeInterval

    public static let defaultWaitTimeout: TimeInterval = 5
    public static let maxWaitTimeout: TimeInterval = 30

    public init(state: ActionStateMode = .diff, screenshot: Bool = false, waitFor: String? = nil,
                waitTimeout: TimeInterval = ActionObservation.defaultWaitTimeout) {
        self.state = state
        self.screenshot = screenshot
        self.waitFor = waitFor
        self.waitTimeout = waitTimeout
    }

    /// `OPEN_COMPUTER_USE_ACTION_RESULT=full` restores the pre-1.2 result (whole tree plus
    /// screenshot); `OPEN_COMPUTER_USE_ACTION_READ_BACK=0` keeps returning a bare "ok".
    public static func defaults(environment: [String: String]) -> ActionObservation {
        guard actionReadBackEnabled(environment: environment) else {
            return ActionObservation(state: .none)
        }
        let raw = environment["OPEN_COMPUTER_USE_ACTION_RESULT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch raw {
        case ActionStateMode.full.rawValue: return ActionObservation(state: .full, screenshot: true)
        case ActionStateMode.none.rawValue: return ActionObservation(state: .none)
        default: return ActionObservation()
        }
    }

    var readsBack: Bool { state != .none || screenshot || waitFor != nil }
}

struct WaitCondition {
    let text: String
    let absent: Bool

    init?(_ raw: String?) {
        guard var text = raw, !text.isEmpty else { return nil }
        absent = text.hasPrefix("!")
        if absent { text.removeFirst() }
        guard !text.isEmpty else { return nil }
        self.text = text
    }

    func isSatisfied(by snapshot: AppSnapshot) -> Bool {
        let haystack = ([snapshot.windowTitle ?? ""] + snapshot.treeLines).joined(separator: "\n")
        return haystack.localizedCaseInsensitiveContains(text) != absent
    }
}

/// One rendered element plus any unindexed continuation lines that follow it.
struct TreeDiffEntry: Equatable {
    let index: Int
    let depth: Int
    let parent: Int?
    var body: String
}

func treeDiffEntries(lines: [String], indices: [Int?]) -> [TreeDiffEntry] {
    var entries: [TreeDiffEntry] = []
    var ancestors: [(depth: Int, index: Int)] = []
    for (offset, line) in lines.enumerated() {
        let index = offset < indices.count ? indices[offset] : leadingIndex(of: line)
        let trimmed = line.drop { $0 == "\t" || $0 == " " }
        guard let index else {
            if !entries.isEmpty { entries[entries.count - 1].body += "\n" + trimmed }
            continue
        }
        let indent = line.prefix { $0 == "\t" || $0 == " " }
        let depth = indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 4
        while let last = ancestors.last, last.depth >= depth { ancestors.removeLast() }
        entries.append(TreeDiffEntry(index: index, depth: depth, parent: ancestors.last?.index, body: String(trimmed)))
        ancestors.append((depth, index))
    }
    return entries
}

private func leadingIndex(of line: String) -> Int? {
    Int(line.drop { $0 == "\t" || $0 == " " }.prefix { $0.isNumber })
}

struct TreeDiff {
    /// Changed and added entries, in the new tree's order.
    private(set) var updates: [(entry: TreeDiffEntry, isAdded: Bool)] = []
    /// Roots of removed subtrees with how many removed entries they contained.
    private(set) var removed: [(entry: TreeDiffEntry, descendants: Int)] = []

    var isEmpty: Bool { updates.isEmpty && removed.isEmpty }
    var count: Int { updates.count + removed.count }

    init(before: [TreeDiffEntry], after: [TreeDiffEntry]) {
        let beforeByIndex = Dictionary(before.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in after {
            if let old = beforeByIndex[entry.index] {
                if old.body != entry.body { updates.append((entry, false)) }
            } else {
                updates.append((entry, true))
            }
        }
        let afterIndices = Set(after.map(\.index))
        var rootPosition: [Int: Int] = [:]
        for entry in before where !afterIndices.contains(entry.index) {
            if let parent = entry.parent, let position = rootPosition[parent] {
                removed[position].descendants += 1
                rootPosition[entry.index] = position
            } else {
                rootPosition[entry.index] = removed.count
                removed.append((entry, 0))
            }
        }
    }

    func rendered(maxEntries: Int = 150) -> [String] {
        var lines: [String] = []
        let addedIndices = Set(updates.filter(\.isAdded).map(\.entry.index))
        var runRootDepth = 0
        for (entry, isAdded) in updates.prefix(maxEntries) {
            guard isAdded else {
                lines.append("~ \(entry.body)")
                continue
            }
            let parentIsAdded = entry.parent.map(addedIndices.contains) ?? false
            if !parentIsAdded { runRootDepth = entry.depth }
            let indent = String(repeating: "\t", count: max(0, entry.depth - runRootDepth))
            let context = parentIsAdded ? "" : entry.parent.map { " (in \($0))" } ?? ""
            lines.append("+ \(indent)\(entry.body)\(context)")
        }
        for (entry, descendants) in removed.prefix(max(0, maxEntries - updates.count)) {
            let firstLine = entry.body.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? entry.body
            lines.append("- \(firstLine)\(descendants > 0 ? " (and \(descendants) inside)" : "")")
        }
        if count > maxEntries {
            lines.append("… \(count - maxEntries) more changes; call get_app_state for the full tree.")
        }
        return lines
    }
}
