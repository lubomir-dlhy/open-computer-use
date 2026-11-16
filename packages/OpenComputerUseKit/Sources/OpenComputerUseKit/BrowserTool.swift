import Foundation

/// The `browser` tool: Chrome tabs driven through the extension's debugger
/// connection, so nothing is clicked on screen and Chrome never comes forward.
final class BrowserTool {
    private let bridge: BrowserBridge

    init(bridge: BrowserBridge = .shared) {
        self.bridge = bridge
    }

    static let actions = [
        "tabs", "open", "claim", "navigate", "back", "forward", "reload", "close", "keep", "show",
        "snapshot", "screenshot", "click", "hover", "type", "key", "scroll", "drag", "select",
        "wait", "dialog", "upload", "download", "evaluate", "requests", "extract",
    ]

    private struct Snapshot {
        var title: String
        var url: String
        var scroll: String
        var lines: [String]
        var truncated: Int
        var challenge: String?

        var header: String {
            let base = "\(title.isEmpty ? "(untitled)" : title) — \(url) [scroll \(scroll)]"
            guard let challenge else { return base }
            return base + "\nBot check: \(challenge). This is not the site's page: wait (action wait, load networkidle) or ask the user to solve it (action show)."
        }
    }

    func call(_ arguments: [String: Any]) throws -> ToolCallResult {
        guard let action = arguments["action"] as? String, Self.actions.contains(action) else {
            throw ComputerUseError.invalidArguments("action must be one of \(Self.actions.joined(separator: ", "))")
        }
        switch action {
        case "tabs":
            return try listTabs(profile: arguments["profile"] as? String)
        case "open":
            let url = try string("url", arguments)
            let tab = try bridge.call("createTab", ["url": url], profile: arguments["profile"] as? String) as? [String: Any] ?? [:]
            guard let id = tab["id"] as? Int else { throw ComputerUseError.stateUnavailable("Chrome did not open a tab") }
            bridge.session { $0.currentTab = id }
            waitForLoad(id, timeout: wait(arguments, default: 15))
            let place = bridge.profile(ofTab: id).map { " in profile \($0.label)" } ?? ""
            let opened = "Tab \(id) opened in the background\(place). It closes when your turn ends unless you keep it (action keep)."
            return try page(id, arguments, note: [opened, navigationStatus(id)].compactMap { $0 }.joined(separator: "\n"))
        case "claim":
            let id = try int("tab", arguments)
            _ = try bridge.call("claimUserTab", ["tabId": id])
            bridge.session { $0.currentTab = id }
            return try page(id, arguments, note: "Tab \(id) claimed; it stays open and is released when your turn ends.")
        case "navigate", "back", "forward", "reload":
            let id = try tab(arguments)
            var params: [String: Any] = ["tabId": id, "command": action]
            if action == "navigate" { params["url"] = try string("url", arguments) }
            let before = href(id)
            _ = try bridge.call("tabCommand", params)
            waitForLoad(id, timeout: wait(arguments, default: 15), leaving: action == "reload" ? nil : before)
            return try page(id, arguments, note: navigationStatus(id))
        case "close":
            let id = try tab(arguments)
            _ = try bridge.call("tabCommand", ["tabId": id, "command": "close"])
            bridge.session { state in
                if state.currentTab == id { state.currentTab = nil }
                state.keep[id] = nil
                state.snapshots[id] = nil
            }
            return .text("ok; tab \(id) closed")
        case "keep":
            let id = try tab(arguments)
            let status = arguments["status"] as? String ?? "deliverable"
            guard status == "deliverable" || status == "handoff" else {
                throw ComputerUseError.invalidArguments("status must be deliverable or handoff")
            }
            _ = try bridge.call("markTab", ["tabId": id, "status": status])
            bridge.session { $0.keep[id] = status }
            return .text("ok; tab \(id) stays open after your turn")
        case "show":
            let id = try tab(arguments)
            _ = try bridge.call("tabCommand", ["tabId": id, "command": "show"])
            return .text("ok; tab \(id) is in front")
        case "snapshot":
            let id = try tab(arguments)
            if let pattern = arguments["find"] as? String {
                return try find(id, pattern, arguments)
            }
            if let ref = arguments["ref"] as? Int {
                let scoped = try snapshot(id, arguments, scope: ref)
                return .text(([scoped.header, "Within [\(ref)]:"] + render(scoped)).joined(separator: "\n"))
            }
            return try page(id, arguments)
        case "requests":
            let id = try tab(arguments)
            if let request = arguments["request"] as? String {
                return try responseBody(id, request, arguments)
            }
            return try listRequests(id, arguments)
        case "extract":
            let id = try tab(arguments)
            if let selector = arguments["selector"] as? String {
                let text = try call(id, "embedded", selector) as? String ?? ""
                return .text(Self.clip(text, arguments["max_chars"] as? Int ?? 8000, hint: "raise max_chars, or read a part with evaluate"))
            }
            return try extract(id, arguments)
        case "screenshot":
            let id = try tab(arguments)
            let result = try bridge.cdp(id, "Page.captureScreenshot", ["format": "jpeg", "quality": 70], timeout: 5)
            guard let base64 = result["data"] as? String, let data = Data(base64Encoded: base64) else {
                throw ComputerUseError.stateUnavailable("Chrome returned no screenshot")
            }
            return ToolCallResult(content: [.screenshotImage(data)])
        case "wait":
            let id = try tab(arguments)
            return try act(id, arguments) {
                let timeout = wait(arguments, default: 10)
                if let fragment = arguments["url"] as? String {
                    try poll(timeout, "the URL to contain \(fragment)") {
                        href(id)?.contains(fragment) == true
                    }
                }
                if let load = arguments["load"] as? String {
                    let states = load == "domcontentloaded" ? ["interactive", "complete"] : ["complete"]
                    try poll(timeout, "the page to load") {
                        ((try? evaluate(id, "document.readyState")) as? String).map(states.contains) == true
                    }
                    if load == "networkidle" {
                        // Quiet: nothing loading (streams and long polls aside) for half a second.
                        try poll(timeout, "the network to go quiet") {
                            guard let log = try? networkLog(id) else { return true }
                            return (log["loading"] as? Int ?? 0) == 0 && (log["quietMs"] as? Int ?? 0) >= 500
                        }
                    }
                }
                if let selector = arguments["selector"] as? String {
                    try poll(timeout, "\(selector) to appear") {
                        (try? evaluate(id, "!!document.querySelector(\(json(selector)))") as? Bool) == true
                    }
                }
            }
        case "dialog":
            let id = try tab(arguments)
            guard let dialog = bridge.openDialog(tab: id) else {
                return .text("No dialog is open in tab \(id).")
            }
            var params: [String: Any] = ["accept": arguments["accept"] as? Bool ?? true]
            if let text = arguments["text"] as? String { params["promptText"] = text }
            try bridge.cdp(id, "Page.handleJavaScriptDialog", params)
            return .text("ok; \(dialog["type"] as? String ?? "dialog") \(params["accept"] as? Bool == true ? "accepted" : "dismissed")")
        case "evaluate":
            let id = try tab(arguments)
            try failIfDialog(id)
            let value = try evaluate(id, try string("expression", arguments), timeout: wait(arguments, default: 10))
            let text: String
            if let value, JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
                text = String(decoding: data, as: UTF8.self)
            } else if let value = value as? String {
                text = json(value)
            } else {
                text = value.map { "\($0)" } ?? "undefined"
            }
            return .text(text.count > 8000 ? String(text.prefix(8000)) + "… (\(text.count) chars)" : text)
        default:
            let id = try tab(arguments)
            return try act(id, arguments) { try perform(action, id, arguments) }
        }
    }

    // MARK: - Actions

    private func perform(_ action: String, _ id: Int, _ arguments: [String: Any]) throws {
        switch action {
        case "click":
            let point = try target(id, arguments, force: arguments["force"] as? Bool == true)
            let button = arguments["button"] as? String ?? "left"
            let count = arguments["click_count"] as? Int ?? 1
            let modifiers = try modifierMask(arguments["modifiers"])
            try mouse(id, "mouseMoved", point, modifiers: modifiers)
            for click in 1...max(1, min(count, 3)) {
                try mouse(id, "mousePressed", point, button: button, clicks: click, modifiers: modifiers)
                if let hold = arguments["hold"] as? Double, hold > 0 { Thread.sleep(forTimeInterval: min(hold, 10)) }
                try mouse(id, "mouseReleased", point, button: button, clicks: click, modifiers: modifiers)
            }
        case "hover":
            try mouse(id, "mouseMoved", try target(id, arguments, force: true))
        case "type":
            let text: String
            if let name = arguments[SecretInput.argumentKey] as? String {
                guard arguments["text"] == nil else { throw ComputerUseError.invalidArguments("pass either text or secret_env, not both") }
                text = try SecretInput.resolve(name)
            } else {
                text = try string("text", arguments)
            }
            if hasTarget(arguments) {
                let focused = try call(id, "focus", targetSpec(arguments), arguments["clear"] as? Bool ?? false) as? Bool
                if focused != true {
                    try perform("click", id, arguments.filter { ["ref", "selector", "name", "x", "y"].contains($0.key) })
                }
            }
            let format = arguments["format"] as? String ?? "text"
            if format != "text" {
                guard arguments[SecretInput.argumentKey] == nil else { throw ComputerUseError.invalidArguments("format applies to text, not secret_env") }
                let html = format == "markdown" ? PasteContent.html(fromMarkdown: text) : text
                if try call(id, "pasteRich", html, text) as? Bool == true { return }
            }
            try bridge.cdp(id, "Input.insertText", ["text": text])
        case "key":
            try press(id, try string("key", arguments), hold: arguments["hold"] as? Double)
        case "scroll":
            let direction = arguments["direction"] as? String ?? "down"
            let pages = arguments["amount"] as? Double ?? 1
            let height = ((try? evaluate(id, "innerHeight")) as? Double) ?? 800
            let distance = pages * height * 0.8
            let (dx, dy): (Double, Double) = switch direction {
            case "up": (0, -distance)
            case "left": (-distance, 0)
            case "right": (distance, 0)
            default: (0, distance)
            }
            let spec: Any = hasTarget(arguments) && arguments["x"] == nil ? targetSpec(arguments) : NSNull()
            let before = try call(id, "scrollPosition", spec) as? [Double]
            let point: [String: Double]
            if let x = arguments["x"] as? Double, let y = arguments["y"] as? Double {
                point = ["x": x, "y": y]
            } else if hasTarget(arguments) {
                point = try target(id, arguments, force: true, scroll: false)
            } else {
                let size = try evaluate(id, "[innerWidth, innerHeight]") as? [Double] ?? [800, 600]
                point = ["x": size[0] / 2, "y": size[1] / 2]
            }
            try bridge.cdp(id, "Input.dispatchMouseEvent", ["type": "mouseWheel", "x": point["x"]!, "y": point["y"]!,
                                                            "deltaX": dx, "deltaY": dy])
            Thread.sleep(forTimeInterval: 0.1)
            // Wheel events can go unhandled in a tab Chrome is not painting; scroll directly then.
            if let before, before == (try call(id, "scrollPosition", spec) as? [Double]) {
                _ = try call(id, "scrollBy", spec, dx, dy)
            }
        case "select":
            _ = try call(id, "selectOption", targetSpec(arguments), try string("value", arguments))
        case "drag":
            try drag(id, arguments)
        case "upload":
            guard let files = arguments["files"] as? [String], !files.isEmpty else {
                throw ComputerUseError.invalidArguments("upload needs files: absolute paths")
            }
            for file in files where !FileManager.default.fileExists(atPath: file) {
                throw ComputerUseError.invalidArguments("no file at \(file)")
            }
            if let objectID = try objectID(id, "window.__ocu.fileInput(\(json(targetSpec(arguments))))") {
                try bridge.cdp(id, "DOM.setFileInputFiles", ["objectId": objectID, "files": files])
            } else {
                // A button that opens the chooser: intercept the chooser it opens.
                final class Outcome: @unchecked Sendable { var chooser: [String: Any]?; var error: Error? }
                let outcome = Outcome()
                let done = DispatchSemaphore(value: 0)
                let owner = SessionOwner.current
                let bridge = bridge
                DispatchQueue.global().async {
                    SessionOwner.with(owner) {
                        do { outcome.chooser = try bridge.call("waitForFileChooser", ["tabId": id, "timeoutMs": 5000], timeout: 7) as? [String: Any] }
                        catch { outcome.error = error }
                    }
                    done.signal()
                }
                Thread.sleep(forTimeInterval: 0.2)
                try perform("click", id, arguments)
                done.wait()
                guard let chooserID = outcome.chooser?["fileChooserId"] as? String else {
                    throw outcome.error ?? ComputerUseError.stateUnavailable("no file chooser opened")
                }
                _ = try bridge.call("setFileChooserFiles", ["fileChooserId": chooserID, "files": files])
            }
        case "download":
            let since = Date().timeIntervalSince1970 * 1000 - 500
            if hasTarget(arguments) { try perform("click", id, arguments) }
            let item = try bridge.call("waitForDownload", ["since": since, "timeoutMs": Int(wait(arguments, default: 30) * 1000)],
                                       timeout: wait(arguments, default: 30) + 2) as? [String: Any] ?? [:]
            downloadNote = "download \(item["status"] as? String ?? "?"): \(item["filename"] as? String ?? "")"
        default:
            throw ComputerUseError.invalidArguments("unknown action \(action)")
        }
    }

    private var downloadNote: String?

    private func drag(_ id: Int, _ arguments: [String: Any]) throws {
        let from = try target(id, arguments, force: true)
        let toArguments = Dictionary(uniqueKeysWithValues: arguments.compactMap { key, value -> (String, Any)? in
            key.hasPrefix("to_") ? (String(key.dropFirst(3)), value) : nil
        })
        guard hasTarget(toArguments) else {
            throw ComputerUseError.invalidArguments("drag needs a destination: to_ref, to_selector, to_name or to_x/to_y")
        }
        let method = arguments["drag_method"] as? String ?? "auto"
        if method == "js" {
            _ = try call(id, "syntheticDrag", targetSpec(arguments), targetSpec(toArguments))
            return
        }
        _ = bridge.takeDrag(tab: id)
        let html5 = method != "pointer"
        if html5 { try bridge.cdp(id, "Input.setInterceptDrags", ["enabled": true]) }
        defer { if html5 { _ = try? bridge.cdp(id, "Input.setInterceptDrags", ["enabled": false]) } }
        try mouse(id, "mouseMoved", from)
        try mouse(id, "mousePressed", from, button: "left", clicks: 1)
        let to = try target(id, toArguments, force: true, scroll: false)
        let steps = 8
        var intercepted: [String: Any]?
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            let point = ["x": from["x"]! + (to["x"]! - from["x"]!) * t, "y": from["y"]! + (to["y"]! - from["y"]!) * t]
            try mouse(id, "mouseMoved", point, buttons: 1)
            if html5, intercepted == nil {
                Thread.sleep(forTimeInterval: 0.03)
                intercepted = bridge.takeDrag(tab: id)
                if intercepted != nil { break }
            }
        }
        if let data = intercepted {
            for type in ["dragEnter", "dragOver", "drop"] {
                try bridge.cdp(id, "Input.dispatchDragEvent", ["type": type, "x": to["x"]!, "y": to["y"]!, "data": data])
            }
            try mouse(id, "mouseReleased", to, button: "left", clicks: 1)
            return
        }
        try mouse(id, "mouseMoved", to, buttons: 1)
        try mouse(id, "mouseReleased", to, button: "left", clicks: 1)
        if from["draggable"] == 1, method == "auto" {
            _ = try call(id, "syntheticDrag", targetSpec(arguments), targetSpec(toArguments))
        }
    }

    // MARK: - Results

    /// Runs an action, settles, and reports what changed on the page.
    private func act(_ id: Int, _ arguments: [String: Any], _ body: () throws -> Void) throws -> ToolCallResult {
        try failIfDialog(id)
        let state = arguments["state"] as? String ?? "diff"
        let baseline = bridge.session { $0.snapshots[id] }
        let before = baseline == nil && state == "diff" ? try? snapshot(id, arguments) : nil
        let urlBefore = href(id)
        downloadNote = nil
        do {
            try body()
        } catch let error as ComputerUseError {
            if let dialog = bridge.openDialog(tab: id) { return dialogResult(dialog) }
            throw error
        }
        if let dialog = bridge.openDialog(tab: id) { return dialogResult(dialog) }
        try settle(id, arguments)
        if let dialog = bridge.openDialog(tab: id) { return dialogResult(dialog) }
        var notes = downloadNote.map { [$0] } ?? []
        if state == "none" { return .text((["ok"] + notes).joined(separator: "\n")) }
        let after = try snapshot(id, arguments)
        if state == "full" || (urlBefore != nil && urlBefore != after.url) {
            notes.insert(after.header, at: 0)
            if state == "full" || urlBefore.map({ !sameDocument($0, after.url) }) == true {
                return .text((notes + render(after)).joined(separator: "\n"))
            }
        }
        let previous = baseline ?? before?.lines ?? []
        let changes = Self.diff(before: previous, after: after.lines)
        let body = changes.isEmpty ? ["ok; no visible change"] : ["ok"] + changes
        return .text((body + notes).joined(separator: "\n"))
    }

    private func sameDocument(_ left: String, _ right: String) -> Bool {
        left.split(separator: "#").first == right.split(separator: "#").first
    }

    private func page(_ id: Int, _ arguments: [String: Any], note: String? = nil) throws -> ToolCallResult {
        if let dialog = bridge.openDialog(tab: id) { return dialogResult(dialog) }
        if arguments["state"] as? String == "none" { return .text(note ?? "ok") }
        let snapshot = try snapshot(id, arguments)
        var lines = [snapshot.header] + render(snapshot)
        if let note { lines.insert(note, at: 0) }
        return .text(lines.joined(separator: "\n"))
    }

    private func render(_ snapshot: Snapshot) -> [String] {
        snapshot.truncated > 0
            ? snapshot.lines + ["… \(snapshot.truncated) more lines; raise max_chars, scroll, or use find via evaluate"]
            : snapshot.lines
    }

    private func dialogResult(_ dialog: [String: Any]) -> ToolCallResult {
        let type = dialog["type"] as? String ?? "alert"
        let message = dialog["message"] as? String ?? ""
        return .text("A \(type) dialog is open: \(json(message)). Answer it with action dialog (accept true or false\(type == "prompt" ? ", text" : "")).")
    }

    private func failIfDialog(_ id: Int) throws {
        if let dialog = bridge.openDialog(tab: id) {
            throw ComputerUseError.stateUnavailable(dialogResult(dialog).primaryText ?? "A dialog is open")
        }
    }

    private func listTabs(profile query: String?) throws -> ToolCallResult {
        var profiles = try bridge.profiles()
        if let query {
            let known = profiles.compactMap(\.profile)
            guard let match = BrowserProfiles.select(query, from: known) else {
                throw ComputerUseError.invalidArguments("no connected Chrome profile matches \"\(query)\"; connected: \(known.map(\.label).joined(separator: ", "))")
            }
            profiles = profiles.filter { $0.profile == match }
        }
        let current = bridge.session { $0.currentTab }
        let preferred = BrowserProfiles.defaultProfile(among: profiles.compactMap(\.profile))
        var lines: [String] = []
        for entry in profiles {
            if profiles.count > 1 || query != nil {
                let label = entry.profile.map { $0.label + ($0.note.map { " — \($0)" } ?? "") + ($0 == preferred ? " [default]" : "") }
                lines.append("Profile \(label ?? "unknown"):")
            }
            let mineIDs = Set(entry.mine.compactMap { $0["id"] as? Int })
            lines += entry.mine.map { tab in
                let id = tab["id"] as? Int ?? 0
                return "  \(id)\(id == current ? " (current)" : "") yours, \(tab["origin"] as? String == "agent" ? "opened" : "claimed") \(json(tab["title"] as? String ?? "")) \(tab["url"] as? String ?? "")"
            }
            lines += entry.all.filter { !mineIDs.contains($0["id"] as? Int ?? -1) }.prefix(40).map { tab in
                "  \(tab["id"] as? Int ?? 0)\(tab["active"] as? Bool == true ? " (front)" : "") \(json(tab["title"] as? String ?? "")) \(tab["url"] as? String ?? "")"
            }
        }
        let offline = BrowserProfiles.installed().filter { installed in !profiles.contains { $0.profile?.directory == installed.directory } }
        if query == nil, !offline.isEmpty {
            lines.append("Not running in Chrome (the user must open a window in it once): \(offline.map(\.label).joined(separator: ", "))")
        }
        lines.append("Claim a user tab to act in it; leave the others alone.")
        return .text(lines.joined(separator: "\n"))
    }

    /// `+` added, `-` removed, `~` changed (same ref, new state).
    static func diff(before: [String], after: [String], limit: Int = 40) -> [String] {
        func ref(_ line: String) -> String? {
            guard line.hasPrefix("["), let end = line.firstIndex(of: "]") else { return nil }
            return String(line[..<end])
        }
        let beforeByRef = Dictionary(before.compactMap { line in ref(line).map { ($0, line) } }, uniquingKeysWith: { first, _ in first })
        let afterRefs = Set(after.compactMap(ref))
        let beforeSet = Set(before)
        let afterSet = Set(after)
        var changes: [String] = []
        for line in after where !beforeSet.contains(line) {
            if let key = ref(line), beforeByRef[key] != nil {
                changes.append("~ \(line)")
            } else {
                changes.append("+ \(line)")
            }
        }
        for line in before where !afterSet.contains(line) {
            if let key = ref(line), afterRefs.contains(key) { continue }
            changes.append("- \(line)")
        }
        guard changes.count > limit else { return changes }
        return Array(changes.prefix(limit)) + ["… \(changes.count - limit) more changes; take a snapshot"]
    }

    /// A scoped snapshot is not what later diffs compare against: it leaves the rest of the page out.
    private func snapshot(_ id: Int, _ arguments: [String: Any], scope: Int? = nil, maxChars: Int? = nil) throws -> Snapshot {
        let budget = maxChars ?? arguments["max_chars"] as? Int ?? 6000
        guard let raw = try call(id, "snapshot", budget, scope.map { $0 as Any } ?? NSNull()) as? [String: Any] else {
            throw ComputerUseError.stateUnavailable("the page returned no snapshot")
        }
        let snapshot = Snapshot(title: raw["title"] as? String ?? "", url: raw["url"] as? String ?? "",
                                scroll: raw["scroll"] as? String ?? "", lines: raw["lines"] as? [String] ?? [],
                                truncated: raw["truncated"] as? Int ?? 0, challenge: raw["challenge"] as? String)
        if scope == nil {
            bridge.session { $0.snapshots[id] = snapshot.lines }
        }
        return snapshot
    }

    // MARK: - Finding, network and structured data

    /// Snapshot lines matching a pattern, with one line of context each side.
    private func find(_ id: Int, _ pattern: String, _ arguments: [String: Any]) throws -> ToolCallResult {
        let regex = try (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
            ?? (NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: pattern), options: [.caseInsensitive]))
        let snapshot = try snapshot(id, arguments, maxChars: 400_000)
        let lines = snapshot.lines
        let hits = lines.indices.filter { regex.firstMatch(in: lines[$0], range: NSRange(lines[$0].startIndex..., in: lines[$0])) != nil }
        guard !hits.isEmpty else {
            return .text("\(snapshot.header)\nNo snapshot line matches \(json(pattern)).")
        }
        var shown = IndexSet()
        for hit in hits { shown.insert(integersIn: max(0, hit - 1)...min(lines.count - 1, hit + 1)) }
        var output = [snapshot.header, "\(hits.count) \(hits.count == 1 ? "line matches" : "lines match") \(json(pattern)):"]
        var previous: Int?
        for index in shown {
            if let previous, index > previous + 1 { output.append("…") }
            output.append(lines[index])
            previous = index
        }
        return .text(Self.clip(output.joined(separator: "\n"), arguments["max_chars"] as? Int ?? 6000, hint: "narrow the pattern"))
    }

    private func networkLog(_ id: Int) throws -> [String: Any] {
        try bridge.call("networkLog", ["tabId": id]) as? [String: Any] ?? [:]
    }

    /// The HTTP status of the page's last load, with its redirects; nil when unknown.
    private func navigationStatus(_ id: Int) -> String? {
        guard let log = try? networkLog(id), let entries = log["entries"] as? [[String: Any]],
              let last = entries.last(where: { $0["main"] as? Bool == true }) else { return nil }
        var parts: [String] = []
        if let failed = last["failed"] as? String {
            parts.append("Load failed: \(failed)")
        } else if let status = last["status"] as? Int {
            parts.append("HTTP \(status)")
        } else {
            return nil
        }
        let byID = Dictionary(entries.compactMap { entry in (entry["id"] as? Int).map { ($0, entry) } }, uniquingKeysWith: { first, _ in first })
        var hops: [String] = []
        var from = last["redirectedFrom"] as? Int
        while let current = from, let entry = byID[current], hops.count < 10 {
            hops.insert("\(entry["url"] as? String ?? "") (\(entry["status"] as? Int ?? 0))", at: 0)
            from = entry["redirectedFrom"] as? Int
        }
        if !hops.isEmpty { parts.append("redirected from " + hops.joined(separator: " → ")) }
        return parts.joined(separator: ", ")
    }

    private static let defaultRequestTypes: Set<String> = ["document", "xhr", "fetch"]

    private func listRequests(_ id: Int, _ arguments: [String: Any]) throws -> ToolCallResult {
        let log = try networkLog(id)
        let entries = log["entries"] as? [[String: Any]] ?? []
        let navigation = log["navigation"] as? Int ?? 0
        let types = (arguments["type"] as? String).map { Set($0.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        let filter = arguments["filter"] as? String
        let regex = filter.flatMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        let page = entries.last(where: { $0["main"] as? Bool == true })?["url"] as? String
        let origin = page.flatMap { URL(string: $0) }.flatMap { url in url.host.map { "\(url.scheme ?? "https")://\($0)\(url.port.map { ":\($0)" } ?? "")" } }
        let matching = entries.filter { entry in
            let type = (entry["type"] as? String ?? "other").lowercased()
            let mime = entry["mimeType"] as? String ?? ""
            if let types {
                guard types.contains("all") || types.contains(type) else { return false }
            } else {
                guard entry["navigation"] as? Int == navigation,
                      Self.defaultRequestTypes.contains(type) || mime.contains("json") else { return false }
            }
            guard let filter else { return true }
            let url = entry["url"] as? String ?? ""
            if let regex { return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
            return url.localizedCaseInsensitiveContains(filter)
        }
        guard !matching.isEmpty else {
            let attached = log["attached"] as? Bool ?? false
            return .text(attached || !entries.isEmpty
                ? "No matching requests since this page loaded\(types == nil ? " (documents, XHR, fetch and JSON; type all shows every type)" : "")."
                : "No requests recorded yet: the tab's network log starts with the first action in it. Reload (action reload) to record the page load.")
        }
        let limit = 40
        var lines = ["\(matching.count) request\(matching.count == 1 ? "" : "s")\(matching.count > limit ? ", the last \(limit) shown (narrow with filter)" : ""). Read a response with requests and request: \"r<id>\"."]
        lines += matching.suffix(limit).map { Self.requestLine($0, origin: origin) }
        if let loading = log["loading"] as? Int, loading > 0 { lines.append("\(loading) still loading.") }
        return .text(lines.joined(separator: "\n"))
    }

    private static func requestLine(_ entry: [String: Any], origin: String?) -> String {
        var url = entry["url"] as? String ?? ""
        if let origin, url.hasPrefix(origin + "/") { url = String(url.dropFirst(origin.count)) }
        if url.count > 160 { url = String(url.prefix(159)) + "…" }
        let status: String
        if let failed = entry["failed"] as? String {
            status = "failed (\(failed))"
        } else if let code = entry["status"] as? Int {
            status = String(code)
        } else {
            status = "loading"
        }
        var parts = ["r\(entry["id"] as? Int ?? 0)", entry["method"] as? String ?? "GET", status, (entry["type"] as? String ?? "").lowercased()]
        if let mime = entry["mimeType"] as? String, !mime.isEmpty { parts.append(mime) }
        if let size = entry["size"] as? Double, size > 0 { parts.append(byteCount(Int(size))) }
        parts.append(url)
        if entry["redirectedTo"] != nil { parts.append("→ redirect") }
        if entry["fromCache"] as? Bool == true { parts.append("(cached)") }
        return parts.joined(separator: " ")
    }

    private static func byteCount(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B" : bytes < 1_048_576 ? String(format: "%.1f KB", Double(bytes) / 1024) : String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    private func responseBody(_ id: Int, _ request: String, _ arguments: [String: Any]) throws -> ToolCallResult {
        guard let number = Int(request.trimmingCharacters(in: CharacterSet(charactersIn: "rR "))) else {
            throw ComputerUseError.invalidArguments("request is an id from the requests list, such as r12")
        }
        let entries = try networkLog(id)["entries"] as? [[String: Any]] ?? []
        guard let entry = entries.first(where: { $0["id"] as? Int == number }), let requestID = entry["requestId"] as? String else {
            throw ComputerUseError.invalidArguments("no request r\(number) in this tab's log; list them with action requests")
        }
        var lines = ["\(entry["method"] as? String ?? "GET") \(entry["status"] as? Int ?? 0) \(entry["mimeType"] as? String ?? "") \(entry["url"] as? String ?? "")"]
        if let post = entry["postData"] as? String { lines.append("Request body: \(post)") }
        if let target = entry["redirectedTo"] as? String {
            lines.append("Redirected to \(target); a redirect has no body.")
            return .text(lines.joined(separator: "\n"))
        }
        let result: [String: Any]
        do {
            result = try bridge.cdp(id, "Network.getResponseBody", ["requestId": requestID], timeout: 10)
        } catch {
            throw ComputerUseError.stateUnavailable("Chrome no longer has the body of r\(number) (\(error.localizedDescription)); repeat the action that loads it and read it right after")
        }
        var body = result["body"] as? String ?? ""
        if result["base64Encoded"] as? Bool == true {
            guard let data = Data(base64Encoded: body), let text = String(data: data, encoding: .utf8) else {
                lines.append("Binary body, \(Self.byteCount(Data(base64Encoded: body)?.count ?? 0)).")
                return .text(lines.joined(separator: "\n"))
            }
            body = text
        }
        lines.append(body)
        return .text(Self.clip(lines.joined(separator: "\n"), arguments["max_chars"] as? Int ?? 8000, hint: "raise max_chars, or fetch and filter it with evaluate"))
    }

    private func extract(_ id: Int, _ arguments: [String: Any]) throws -> ToolCallResult {
        guard let raw = try call(id, "structured") as? [String: Any] else {
            throw ComputerUseError.stateUnavailable("the page returned no structured data")
        }
        let jsonld = raw["jsonld"] as? [[String: Any]] ?? []
        let meta = raw["meta"] as? [String: Any] ?? [:]
        let microdata = (raw["microdata"] as? [[String: Any]] ?? []).filter { $0.values.contains { !($0 is NSNull) } }
        let embedded = raw["embedded"] as? [[String: Any]] ?? []
        var lines = Self.productSummaries(jsonld: jsonld, microdata: microdata, meta: meta)
        if !jsonld.isEmpty { lines.append("JSON-LD: " + compactJSON(jsonld)) }
        if !meta.isEmpty { lines.append("Meta: " + compactJSON(meta)) }
        if !microdata.isEmpty { lines.append("Microdata: " + compactJSON(microdata)) }
        if !embedded.isEmpty {
            lines.append("Embedded JSON (read with extract and selector): " + embedded.map {
                "\($0["selector"] as? String ?? "") \(Self.byteCount($0["bytes"] as? Int ?? 0))"
            }.joined(separator: ", "))
        }
        if lines.isEmpty {
            return .text("No structured data on this page. Try action requests for the site's own API, or snapshot with find.")
        }
        return .text(Self.clip(lines.joined(separator: "\n"), arguments["max_chars"] as? Int ?? 6000, hint: "raise max_chars"))
    }

    /// One line per product: what a price or stock check needs, before the raw data.
    static func productSummaries(jsonld: [[String: Any]], microdata: [[String: Any]], meta: [String: Any]) -> [String] {
        func types(_ node: [String: Any]) -> [String] {
            (node["@type"] as? [String]) ?? [(node["@type"] as? String)].compactMap { $0 }
        }
        func text(_ value: Any?) -> String? {
            switch value {
            case let string as String: return string.isEmpty ? nil : string
            case let number as NSNumber: return number.stringValue
            case let object as [String: Any]: return text(object["name"] ?? object["@id"])
            case let array as [Any]: return array.compactMap(text).first
            default: return nil
            }
        }
        func availability(_ value: Any?) -> String? {
            text(value).map { $0.replacingOccurrences(of: "https://schema.org/", with: "").replacingOccurrences(of: "http://schema.org/", with: "") }
        }
        func offerText(_ raw: Any?) -> String? {
            let offers = (raw as? [[String: Any]]) ?? (raw as? [String: Any]).map { [$0] } ?? []
            let rendered = offers.prefix(3).compactMap { offer -> String? in
                let currency = text(offer["priceCurrency"]).map { " \($0)" } ?? ""
                var price: String?
                if let value = text(offer["price"]) {
                    price = value + currency
                } else if let low = text(offer["lowPrice"]) {
                    price = "\(low)–\(text(offer["highPrice"]) ?? "?")\(currency)"
                } else if let spec = offer["priceSpecification"] {
                    price = offerText(spec)
                }
                let parts = [price, availability(offer["availability"]).map { "(\($0))" }, text(offer["seller"]).map { "seller \($0)" }].compactMap { $0 }
                return parts.isEmpty ? nil : parts.joined(separator: " ")
            }
            return rendered.isEmpty ? nil : rendered.joined(separator: "; ") + (offers.count > 3 ? "; …\(offers.count - 3) more offers" : "")
        }
        var lines: [String] = []
        var nodes = jsonld
        // A product group lists its variants; each is a product of its own.
        for node in jsonld where types(node).contains("ProductGroup") {
            nodes += (node["hasVariant"] as? [[String: Any]]) ?? []
        }
        for node in nodes where types(node).contains(where: { $0 == "Product" || $0 == "ProductGroup" }) {
            var parts = ["Product \(json(text(node["name"]) ?? "?"))"]
            if let offer = offerText(node["offers"]) { parts.append(offer) }
            for key in ["sku", "gtin13", "gtin", "mpn"] {
                if let value = text(node[key]) { parts.append("\(key) \(value)"); break }
            }
            if let brand = text(node["brand"]) { parts.append("brand \(brand)") }
            if let url = text(node["url"]) { parts.append(url) }
            lines.append(parts.joined(separator: ", "))
            if lines.count >= 20 { break }
        }
        if lines.isEmpty {
            for item in microdata where item["price"] is String {
                let price = [item["price"], item["priceCurrency"]].compactMap { $0 as? String }.joined(separator: " ")
                let stock = availability(item["availability"]).map { " (\($0))" } ?? ""
                lines.append("Product \(json(item["name"] as? String ?? "?")), \(price)\(stock)\((item["sku"] as? String).map { ", sku \($0)" } ?? "")")
            }
        }
        if lines.isEmpty, let amount = text(meta["product:price:amount"] ?? meta["og:price:amount"]) {
            let currency = text(meta["product:price:currency"] ?? meta["og:price:currency"]).map { " \($0)" } ?? ""
            let stock = availability(meta["product:availability"] ?? meta["og:availability"]).map { " (\($0))" } ?? ""
            lines.append("Product \(json(text(meta["og:title"]) ?? "?")), \(amount)\(currency)\(stock)")
        }
        return lines
    }

    private func compactJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "\(value)" }
        return String(decoding: data, as: UTF8.self)
    }

    static func clip(_ text: String, _ limit: Int, hint: String) -> String {
        guard text.count > limit, limit > 0 else { return text }
        return String(text.prefix(limit)) + "… (\(text.count - limit) more chars; \(hint))"
    }

    // MARK: - Waiting

    private func settle(_ id: Int, _ arguments: [String: Any]) throws {
        if let raw = arguments["wait_for"] as? String, let condition = WaitCondition(raw) {
            let timeout = wait(arguments, default: 5)
            try poll(timeout, condition.absent ? "\(json(condition.text)) to go away" : "\(json(condition.text)) to appear") {
                guard let present = try? self.call(id, "textState", condition.text) as? Bool else { return false }
                return present != condition.absent
            }
            return
        }
        let deadline = Date().addingTimeInterval(2)
        var last = ""
        var stableSince = Date()
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            let signature = (try? call(id, "signature") as? String) ?? ""
            if signature != last {
                last = signature
                stableSince = Date()
            } else if !signature.isEmpty, !signature.contains("|loading|"), Date().timeIntervalSince(stableSince) >= 0.2 {
                return
            }
        }
    }

    private func href(_ id: Int) -> String? {
        (try? evaluate(id, "location.href")) as? String
    }

    private func waitForLoad(_ id: Int, timeout: TimeInterval, leaving previous: String? = nil) {
        let deadline = Date().addingTimeInterval(timeout)
        let start = Date()
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            guard let state = (try? evaluate(id, "[location.href, document.readyState]")) as? [String], state.count == 2 else { continue }
            if let previous, state[0] == previous, Date().timeIntervalSince(start) < 2 { continue }
            if state[0] != "about:blank", state[1] != "loading" { return }
        }
    }

    private func poll(_ timeout: TimeInterval, _ what: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if condition() { return }
            guard Date() < deadline else {
                throw ComputerUseError.stateUnavailable("Timed out after \(Int(timeout)) s waiting for \(what)")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // MARK: - Page access

    private func evaluate(_ id: Int, _ expression: String, timeout: TimeInterval = 10) throws -> Any? {
        let result = try bridge.cdp(id, "Runtime.evaluate", ["expression": expression, "returnByValue": true,
                                                              "awaitPromise": true, "userGesture": true], timeout: timeout)
        if let exception = result["exceptionDetails"] as? [String: Any] {
            let description = (exception["exception"] as? [String: Any])?["description"] as? String
            throw ComputerUseError.stateUnavailable(
                (description ?? exception["text"] as? String ?? "JavaScript failed").components(separatedBy: "\n    at ").first ?? "JavaScript failed")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    private func objectID(_ id: Int, _ expression: String) throws -> String? {
        let result = try bridge.cdp(id, "Runtime.evaluate", ["expression": "\(browserPageScript);\(expression)", "returnByValue": false])
        if let exception = result["exceptionDetails"] as? [String: Any] {
            throw ComputerUseError.stateUnavailable((exception["exception"] as? [String: Any])?["description"] as? String ?? "JavaScript failed")
        }
        let object = result["result"] as? [String: Any]
        return object?["subtype"] as? String == "null" ? nil : object?["objectId"] as? String
    }

    /// Calls a helper from the page script, installing it first if the document is new.
    private func call(_ id: Int, _ function: String, _ arguments: Any...) throws -> Any? {
        let encoded = arguments.map { json($0) }.joined(separator: ",")
        return try evaluate(id, "\(browserPageScript);window.__ocu.\(function)(\(encoded))")
    }

    private func target(_ id: Int, _ arguments: [String: Any], force: Bool, scroll: Bool = true) throws -> [String: Double] {
        if let x = arguments["x"] as? Double, let y = arguments["y"] as? Double {
            return ["x": x, "y": y]
        }
        guard let point = try call(id, "point", targetSpec(arguments), scroll) as? [String: Any],
              let x = point["x"] as? Double, let y = point["y"] as? Double else {
            throw ComputerUseError.stateUnavailable("could not locate the element")
        }
        if let covered = point["covered"] as? String, !force {
            throw ComputerUseError.stateUnavailable("The element is covered by \(covered). Close or scroll past it, or pass force true.")
        }
        return ["x": x, "y": y, "draggable": point["draggable"] as? Bool == true ? 1 : 0]
    }

    private func hasTarget(_ arguments: [String: Any]) -> Bool {
        ["ref", "selector", "name"].contains { arguments[$0] != nil } || (arguments["x"] != nil && arguments["y"] != nil)
    }

    private func targetSpec(_ arguments: [String: Any]) -> [String: Any] {
        arguments.filter { ["ref", "selector", "name"].contains($0.key) }
    }

    // MARK: - Input

    private func mouse(_ id: Int, _ type: String, _ point: [String: Double], button: String = "none", clicks: Int = 0,
                       buttons: Int? = nil, modifiers: Int = 0) throws {
        var params: [String: Any] = ["type": type, "x": point["x"] ?? 0, "y": point["y"] ?? 0, "modifiers": modifiers]
        if type != "mouseMoved" {
            params["button"] = button
            params["clickCount"] = clicks
        }
        if let buttons {
            params["buttons"] = buttons
            params["button"] = "left"
        }
        // A handler that opens alert() holds the event until the dialog is answered.
        do {
            try bridge.cdp(id, "Input.dispatchMouseEvent", params, timeout: 3)
        } catch where bridge.openDialog(tab: id) != nil {
            return
        }
    }

    private func modifierMask(_ raw: Any?) throws -> Int {
        guard let names = raw as? [String] else { return 0 }
        return try names.reduce(0) { mask, name in
            switch name.lowercased() {
            case "alt", "option": return mask | 1
            case "ctrl", "control": return mask | 2
            case "cmd", "command", "meta", "super": return mask | 4
            case "shift": return mask | 8
            default: throw ComputerUseError.invalidArguments("unknown modifier \(name)")
            }
        }
    }

    private func press(_ id: Int, _ spec: String, hold: Double?) throws {
        let parts = spec.split(separator: "+").map { String($0) }
        guard let keyName = parts.last, !keyName.isEmpty else { throw ComputerUseError.invalidArguments("key is empty") }
        let modifiers = try modifierMask(Array(parts.dropLast()))
        guard let key = Self.key(keyName) else { throw ComputerUseError.invalidArguments("unknown key \(keyName)") }
        var down: [String: Any] = ["type": key.text == nil || modifiers & 6 != 0 ? "rawKeyDown" : "keyDown", "key": key.key,
                                   "code": key.code, "windowsVirtualKeyCode": key.keyCode, "modifiers": modifiers]
        if let text = key.text, modifiers & 6 == 0 {
            down["text"] = modifiers & 8 != 0 ? text.uppercased() : text
        }
        // Chrome on macOS runs editing shortcuts through menu commands, not key events.
        if modifiers == 4, let command = ["a": "selectAll", "c": "copy", "x": "cut", "v": "paste", "z": "undo"][keyName.lowercased()] {
            down["commands"] = [command]
        }
        try bridge.cdp(id, "Input.dispatchKeyEvent", down, timeout: 3)
        if let hold, hold > 0 { Thread.sleep(forTimeInterval: min(hold, 10)) }
        try bridge.cdp(id, "Input.dispatchKeyEvent", ["type": "keyUp", "key": key.key, "code": key.code,
                                                       "windowsVirtualKeyCode": key.keyCode, "modifiers": modifiers], timeout: 3)
    }

    private static func key(_ name: String) -> (key: String, code: String, keyCode: Int, text: String?)? {
        let named: [String: (String, String, Int, String?)] = [
            "enter": ("Enter", "Enter", 13, "\r"), "return": ("Enter", "Enter", 13, "\r"), "tab": ("Tab", "Tab", 9, nil),
            "escape": ("Escape", "Escape", 27, nil), "esc": ("Escape", "Escape", 27, nil),
            "backspace": ("Backspace", "Backspace", 8, nil), "delete": ("Delete", "Delete", 46, nil),
            "space": (" ", "Space", 32, " "), "arrowup": ("ArrowUp", "ArrowUp", 38, nil), "up": ("ArrowUp", "ArrowUp", 38, nil),
            "arrowdown": ("ArrowDown", "ArrowDown", 40, nil), "down": ("ArrowDown", "ArrowDown", 40, nil),
            "arrowleft": ("ArrowLeft", "ArrowLeft", 37, nil), "left": ("ArrowLeft", "ArrowLeft", 37, nil),
            "arrowright": ("ArrowRight", "ArrowRight", 39, nil), "right": ("ArrowRight", "ArrowRight", 39, nil),
            "home": ("Home", "Home", 36, nil), "end": ("End", "End", 35, nil),
            "pageup": ("PageUp", "PageUp", 33, nil), "pagedown": ("PageDown", "PageDown", 34, nil),
        ]
        if let entry = named[name.lowercased()] { return entry }
        if name.count == 1, let char = name.lowercased().first {
            if char.isLetter, let ascii = char.asciiValue {
                return (String(char), "Key\(char.uppercased())", Int(ascii) - 32, String(char))
            }
            if char.isNumber, let ascii = char.asciiValue {
                return (String(char), "Digit\(char)", Int(ascii), String(char))
            }
            return (String(char), "", 0, String(char))
        }
        if name.lowercased().hasPrefix("f"), let number = Int(name.dropFirst()), (1...12).contains(number) {
            return ("F\(number)", "F\(number)", 111 + number, nil)
        }
        return nil
    }

    // MARK: - Arguments

    private func tab(_ arguments: [String: Any]) throws -> Int {
        if let id = arguments["tab"] as? Int {
            bridge.session { $0.currentTab = id }
            return id
        }
        guard let current = bridge.session(SessionOwner.current, { $0.currentTab }) else {
            throw ComputerUseError.invalidArguments("no current tab: open a URL, or claim a tab from action tabs")
        }
        return current
    }

    private func int(_ key: String, _ arguments: [String: Any]) throws -> Int {
        guard let value = arguments[key] as? Int else { throw ComputerUseError.invalidArguments("\(key) must be an integer") }
        return value
    }

    private func string(_ key: String, _ arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else {
            throw ComputerUseError.invalidArguments("\(key) must be a non-empty string")
        }
        return value
    }

    private func wait(_ arguments: [String: Any], default value: TimeInterval) -> TimeInterval {
        (arguments["wait_timeout"] as? Double).map { min(max($0, 0.1), 60) } ?? value
    }
}

private func json(_ value: Any) -> String {
    if let string = value as? String {
        let data = (try? JSONSerialization.data(withJSONObject: [string], options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
    if value is NSNull { return "null" }
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]) {
        return String(decoding: data, as: UTF8.self)
    }
    return "null"
}
