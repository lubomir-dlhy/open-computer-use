import Foundation

/// One recorded browser action, with the network-log id it started after.
struct RecordedFlowStep {
    var action: String
    var args: [String: Any]
    var firstRequest: Int
    var replayable: Bool
}

/// A saved flow: the request that answered a task, the steps that led to it, and the shape of its answer.
struct BrowserFlow: Codable {
    var version = 1
    var name: String
    var site: String
    var profile: String?
    var startURL: String
    var description: String?
    var params: [String: String]
    var output: Output
    var steps: [Step]
    var writes: [String]
    var tier: String?
    var verified: Bool
    var verifiedAt: Date?
    var createdAt: Date

    struct Output: Codable {
        /// "request": a JSON response; "extract": the structured data of an HTML page.
        var kind: String
        var method: String
        var url: String
        var body: String?
        var headers: [String: String]?
        var shape: [String]
        var list: String?
    }

    struct Step: Codable {
        var action: String
        var args: [String: FlowValue]
    }

    var replayable: Bool { writes.isEmpty && !steps.isEmpty }
}

enum FlowValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), strings([String])

    init?(_ value: Any) {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            self = .bool(number.boolValue)
        case let string as String: self = .string(string)
        case let number as NSNumber: self = .number(number.doubleValue)
        case let strings as [String]: self = .strings(strings)
        default: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? container.decode(Double.self) { self = .number(number) }
        else if let string = try? container.decode(String.self) { self = .string(string) }
        else { self = .strings(try container.decode([String].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .strings(value): try container.encode(value)
        }
    }

    var any: Any {
        switch self {
        case let .string(value): value
        case let .number(value): value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value as Any
        case let .bool(value): value
        case let .strings(value): value
        }
    }
}

enum BrowserFlowStore {
    static var directory: URL {
        BrowserNativeHost.socketDirectory.deletingLastPathComponent().appendingPathComponent("flows", isDirectory: true)
    }

    static func url(site: String, name: String) -> URL {
        directory.appendingPathComponent(site, isDirectory: true).appendingPathComponent("\(name).json")
    }

    static func save(_ flow: BrowserFlow) throws {
        let file = url(site: flow.site, name: flow.name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(flow).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func all(site: String? = nil) -> [BrowserFlow] {
        let fileManager = FileManager.default
        let sites = site.map { [$0] } ?? ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return sites.sorted().flatMap { site -> [BrowserFlow] in
            let folder = directory.appendingPathComponent(site, isDirectory: true)
            let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
                (try? Data(contentsOf: folder.appendingPathComponent(name))).flatMap { try? decoder.decode(BrowserFlow.self, from: $0) }
            }
        }
    }

    static func find(_ query: String) throws -> BrowserFlow {
        let parts = query.split(separator: "/", maxSplits: 1).map(String.init)
        let matches = parts.count == 2 ? all(site: parts[0]).filter { $0.name == parts[1] } : all().filter { $0.name == query }
        guard let flow = matches.first else {
            throw ComputerUseError.invalidArguments("no saved flow named \(query); see action flow_list")
        }
        guard matches.count == 1 else {
            throw ComputerUseError.invalidArguments("several sites have a flow named \(query): \(matches.map { "\($0.site)/\($0.name)" }.joined(separator: ", "))")
        }
        return flow
    }
}

/// The site a host belongs to: example.co.uk for shop.example.co.uk. A flow never leaves it.
func browserFlowSite(_ host: String) -> String {
    let labels = host.lowercased().split(separator: ".").map(String.init)
    guard labels.count > 2, labels.allSatisfy({ !$0.isEmpty }), Int(labels.last!) == nil else { return host.lowercased() }
    let secondLevel: Set<String> = ["co", "com", "net", "org", "gov", "ac", "edu", "or", "ne"]
    let keep = labels.last!.count == 2 && secondLevel.contains(labels[labels.count - 2]) ? 3 : 2
    return labels.suffix(keep).joined(separator: ".")
}

/// Key paths of a JSON value (arrays by their first items), to tell later whether the answer kept its shape.
func browserFlowShape(_ value: Any, depth: Int = 3) -> [String] {
    var paths = Set<String>()
    func walk(_ value: Any, _ path: String, _ depth: Int) {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                let next = path.isEmpty ? key : "\(path).\(key)"
                paths.insert(next)
                if depth > 0 { walk(child, next, depth - 1) }
            }
        } else if let array = value as? [Any], let first = array.first {
            // A key only the first item has is not part of the shape.
            let items = array.prefix(3).compactMap { $0 as? [String: Any] }
            if let firstItem = first as? [String: Any], items.count == min(array.count, 3) {
                let common = items.map { Set($0.keys) }.reduce(Set(firstItem.keys)) { $0.intersection($1) }
                for key in common {
                    let next = "\(path)[].\(key)"
                    paths.insert(next)
                    if depth > 0, let child = firstItem[key] { walk(child, next, depth - 1) }
                }
            }
        }
    }
    walk(value, "", depth)
    return paths.sorted().prefix(80).map { $0 }
}

/// The path of the largest list of objects in a JSON value: what where, fields and limit work on.
func browserFlowList(_ value: Any) -> String? {
    var best: (path: String, count: Int)?
    func walk(_ value: Any, _ path: String, _ depth: Int) {
        if let array = value as? [Any] {
            if array.first is [String: Any], array.count > (best?.count ?? 0) { best = (path, array.count) }
        } else if let object = value as? [String: Any], depth > 0 {
            for (key, child) in object { walk(child, path.isEmpty ? key : "\(path).\(key)", depth - 1) }
        }
    }
    walk(value, "", 5)
    return best?.path
}

func browserFlowValue(_ root: Any, at path: String) -> Any? {
    guard !path.isEmpty else { return root }
    var current: Any? = root
    for key in path.split(separator: ".") {
        if let array = current as? [Any], let index = Int(key) {
            current = array.indices.contains(index) ? array[index] : nil
        } else {
            current = (current as? [String: Any])?[String(key)]
        }
    }
    return current
}

/// `where` (field=value, comma-separated, case-insensitive substring), `fields` and `limit` over the flow's list.
func browserFlowShape(output root: Any, list: String?, where filter: String?, fields: String?, limit: Int?) -> Any {
    let fieldPaths = fields?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    func project(_ item: Any) -> Any {
        guard let fieldPaths, !fieldPaths.isEmpty else { return item }
        var projected: [String: Any] = [:]
        for path in fieldPaths { projected[path] = browserFlowValue(item, at: path) ?? NSNull() }
        return projected
    }
    guard let list, let items = browserFlowValue(root, at: list) as? [Any], filter != nil || limit != nil || fieldPaths != nil else {
        return project(root)
    }
    let conditions = (filter ?? "").split(separator: ",").compactMap { condition -> (String, String)? in
        let parts = condition.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count == 2 ? (parts[0], parts[1].lowercased()) : nil
    }
    let matched = items.filter { item in
        conditions.allSatisfy { path, wanted in
            guard let value = browserFlowValue(item, at: path) else { return false }
            return "\(value)".lowercased().contains(wanted)
        }
    }
    let kept = limit.map { Array(matched.prefix(max(0, $0))) } ?? matched
    return ["total": items.count, "matched": matched.count, "items": kept.map(project)]
}

extension BrowserTool {
    private static let recordableActions: Set<String> = [
        "open", "navigate", "back", "forward", "reload", "click", "hover", "type", "key", "scroll", "select", "wait",
    ]
    private static let replayedArguments: Set<String> = [
        "url", "text", "secret_env", "clear", "format", "key", "button", "click_count", "modifiers", "direction",
        "amount", "value", "load", "selector", "name", "wait_for", "force", "profile",
    ]
    private static let readMethods: Set<String> = ["GET", "HEAD"]

    // MARK: - Recording

    /// Captured before the action runs: a ref may be gone once it has.
    func recordableStep(_ action: String, _ arguments: [String: Any]) -> RecordedFlowStep? {
        guard Self.recordableActions.contains(action) else { return nil }
        var args = arguments.filter { Self.replayedArguments.contains($0.key) }
        var replayable = !(arguments["x"] != nil && arguments["ref"] == nil && arguments["selector"] == nil && arguments["name"] == nil)
        var first = 0
        if action != "open", let id = try? tab(arguments) {
            first = (try? networkLog(id))?["lastId"] as? Int ?? 0
            if let ref = arguments["ref"] as? Int {
                let stable = (try? call(id, "stableTarget", ["ref": ref])) as? [String: Any]
                if let selector = stable?["selector"] as? String { args["selector"] = selector }
                if let name = stable?["name"] as? String, args["selector"] == nil { args["name"] = name }
                replayable = replayable && (args["selector"] != nil || args["name"] != nil)
            }
        }
        return RecordedFlowStep(action: action, args: args, firstRequest: first, replayable: replayable)
    }

    func record(_ step: RecordedFlowStep, _ arguments: [String: Any]) {
        bridge.session { state in
            guard let tab = step.action == "open" ? state.currentTab : (arguments["tab"] as? Int ?? state.currentTab) else { return }
            var steps = step.action == "open" ? [] : state.flowSteps[tab] ?? []
            steps.append(step)
            state.flowSteps[tab] = Array(steps.suffix(200))
        }
    }

    func flowHint() -> String? {
        guard let id = bridge.session(SessionOwner.current, { $0.currentTab }), let host = href(id).flatMap({ URL(string: $0)?.host }) else { return nil }
        let flows = BrowserFlowStore.all(site: browserFlowSite(host))
        guard !flows.isEmpty else { return nil }
        let names = flows.prefix(8).map { flow in "\(flow.name)(\(flow.params.keys.sorted().joined(separator: ", ")))" }
        return "Saved flows for this site: \(names.joined(separator: ", ")). Run one with action flow_run instead of browsing; it is experimental, so continue in the page if it fails."
    }

    // MARK: - Save

    func saveFlow(_ arguments: [String: Any]) throws -> ToolCallResult {
        let name = try string("flow", arguments)
        guard name.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw ComputerUseError.invalidArguments("flow names are lowercase letters, digits, - and _, up to 64 characters")
        }
        let id = try tab(arguments)
        let recorded = bridge.session { $0.flowSteps[id] } ?? []
        guard let start = recorded.lastIndex(where: { ["open", "navigate"].contains($0.action) }) else {
            throw ComputerUseError.invalidArguments("nothing to save in tab \(id): a flow records from an open or navigate onward")
        }
        let steps = Array(recorded[start...])
        guard let startURL = steps[0].args["url"] as? String, let host = URL(string: startURL)?.host else {
            throw ComputerUseError.stateUnavailable("the recording has no start URL")
        }
        let site = browserFlowSite(host)
        let params = try flowParams(arguments["params"], examples: true)

        let log = try networkLog(id)
        let entries = (log["entries"] as? [[String: Any]] ?? []).filter { ($0["id"] as? Int ?? 0) > steps[0].firstRequest }
        let sameSite = { (entry: [String: Any]) in
            URL(string: entry["url"] as? String ?? "")?.host.map(browserFlowSite) == site
        }
        let writes = entries.filter { entry in
            let method = (entry["method"] as? String ?? "GET").uppercased()
            return sameSite(entry) && !Self.readMethods.contains(method) && !Self.isGraphQLQuery(entry["postData"] as? String)
                && !Self.isTelemetry(entry["url"] as? String ?? "") && (entry["type"] as? String) != "Ping"
        }.map { "\($0["method"] as? String ?? "") \(URL(string: $0["url"] as? String ?? "")?.path ?? "")" }

        let output = try flowOutput(arguments["output"] as? String, tab: id, entries: entries, site: site, params: params)
        var flow = BrowserFlow(
            name: name, site: site, profile: bridge.profile(ofTab: id)?.label, startURL: startURL,
            description: arguments["description"] as? String, params: params, output: output,
            steps: steps.allSatisfy(\.replayable) ? steps.map { step in
                BrowserFlow.Step(action: step.action, args: step.args.compactMapValues(FlowValue.init))
            } : [],
            writes: Array(Set(writes)).sorted(), tier: "page", verified: true, verifiedAt: Date(), createdAt: Date()
        )
        try template(&flow)
        try BrowserFlowStore.save(flow)

        var lines = ["Saved flow \(site)/\(name) (experimental): \(flow.output.kind == "extract" ? "product data of" : flow.output.method) \(flow.output.url)"]
        if let list = flow.output.list { lines.append("Its list is at \(list.isEmpty ? "the top level" : list); flow_run takes where, fields and limit over it.") }
        lines.append(flow.params.isEmpty ? "No params." : "Params: \(flow.params.map { "\($0.key) (e.g. \(json($0.value)))" }.sorted().joined(separator: ", ")).")
        if !flow.writes.isEmpty {
            lines.append("Not replayable: the recording changed data on the site (\(flow.writes.joined(separator: ", "))); runs only resend the read.")
        } else if flow.steps.isEmpty {
            lines.append("Not replayable: a step had no stable target (coordinates); runs only resend the read.")
        }
        let example = flow.params.mapValues { _ in "…" }
        lines.append("Run it: {\"action\": \"flow_run\", \"flow\": \"\(name)\"\(example.isEmpty ? "" : ", \"params\": \(json(example))")}")
        return .text(lines.joined(separator: "\n"))
    }

    private func flowParams(_ raw: Any?, examples: Bool) throws -> [String: String] {
        guard let raw else { return [:] }
        guard let object = raw as? [String: Any] else { throw ComputerUseError.invalidArguments("params is an object of name to value") }
        var params: [String: String] = [:]
        for (key, value) in object {
            guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]{0,31}$", options: .regularExpression) != nil else {
                throw ComputerUseError.invalidArguments("param name \(key) must be a short identifier")
            }
            let text = (value as? String) ?? (value as? NSNumber)?.stringValue ?? ""
            guard !text.isEmpty, !examples || text.count >= 2 else {
                throw ComputerUseError.invalidArguments("param \(key) needs \(examples ? "an example value of at least 2 characters as recorded" : "a value")")
            }
            params[key] = text
        }
        return params
    }

    private func flowOutput(_ requested: String?, tab id: Int, entries: [[String: Any]], site: String, params: [String: String]) throws -> BrowserFlow.Output {
        if requested == "extract" {
            let page = href(id) ?? ""
            let structured = try call(id, "structured") as? [String: Any] ?? [:]
            guard !Self.productSummaries(jsonld: structured["jsonld"] as? [[String: Any]] ?? [], microdata: structured["microdata"] as? [[String: Any]] ?? [],
                                         meta: structured["meta"] as? [String: Any] ?? [:]).isEmpty else {
                throw ComputerUseError.stateUnavailable("this page has no product data to save; pass output as a request id from action requests")
            }
            return BrowserFlow.Output(kind: "extract", method: "GET", url: page, body: nil, headers: nil, shape: ["product"], list: nil)
        }
        let candidates = entries.filter { entry in
            let method = (entry["method"] as? String ?? "GET").uppercased()
            let status = entry["status"] as? Int ?? 0
            return (entry["mimeType"] as? String ?? "").contains("json") && (200..<300).contains(status)
                && (Self.readMethods.contains(method) || Self.isGraphQLQuery(entry["postData"] as? String))
                && URL(string: entry["url"] as? String ?? "")?.host.map(browserFlowSite) == site && !Self.isTelemetry(entry["url"] as? String ?? "")
        }
        let entry: [String: Any]
        if let requested {
            guard let number = Int(requested.trimmingCharacters(in: CharacterSet(charactersIn: "rR "))),
                  let match = entries.first(where: { $0["id"] as? Int == number }) else {
                throw ComputerUseError.invalidArguments("output is \"extract\" or a request id (r12) recorded since the flow's start; see action requests")
            }
            entry = match
        } else {
            // The response that used a param is the answer; otherwise the largest JSON one.
            let usesParam = candidates.filter { entry in
                params.values.contains { (entry["url"] as? String ?? "").contains($0) || (entry["postData"] as? String ?? "").contains($0)
                    || (entry["url"] as? String ?? "").contains(Self.urlEncoded($0)) }
            }
            guard let best = (usesParam.isEmpty ? candidates : usesParam).max(by: { ($0["size"] as? Double ?? 0) < ($1["size"] as? Double ?? 0) }) else {
                throw ComputerUseError.stateUnavailable("no JSON response from \(site) was recorded since the flow's start; pass output: \"extract\" for a product page, or a request id")
            }
            entry = best
        }
        let method = (entry["method"] as? String ?? "GET").uppercased()
        let url = entry["url"] as? String ?? ""
        guard URL(string: url)?.host.map(browserFlowSite) == site else {
            throw ComputerUseError.invalidArguments("r\(entry["id"] ?? "") goes to another site; a flow stays on \(site)")
        }
        guard Self.readMethods.contains(method) || Self.isGraphQLQuery(entry["postData"] as? String) else {
            throw ComputerUseError.invalidArguments("r\(entry["id"] ?? "") is a \(method) that may change data; flows only save reads (GET, or GraphQL queries)")
        }
        if entry["type"] as? String == "Document" || (entry["mimeType"] as? String ?? "").contains("html") {
            return BrowserFlow.Output(kind: "extract", method: "GET", url: url, body: nil, headers: nil, shape: ["product"], list: nil)
        }
        guard let requestID = entry["requestId"] as? String,
              let result = try? bridge.cdp(id, "Network.getResponseBody", ["requestId": requestID], timeout: 10),
              let text = Self.decodeBody(result), let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            throw ComputerUseError.stateUnavailable("Chrome no longer has the body of r\(entry["id"] ?? ""); repeat the step that loads it, then save")
        }
        return BrowserFlow.Output(kind: "request", method: method, url: url, body: entry["postData"] as? String,
                                  headers: (entry["headers"] as? [String: String]).map { $0.filter { $0.key == "accept" || $0.key == "content-type" || $0.key.hasPrefix("x-") || $0.key.hasPrefix("apollo") } },
                                  shape: browserFlowShape(value), list: browserFlowList(value))
    }

    /// Example values become {{name}} wherever the recording used them, except in a URL's host.
    private func template(_ flow: inout BrowserFlow) throws {
        var used = Set<String>()
        func inURL(_ url: String) -> String {
            guard var components = URLComponents(string: url) else { return url }
            var path = components.percentEncodedPath
            var query = components.percentEncodedQuery
            for (name, example) in flow.params {
                for variant in Set([example, Self.urlEncoded(example), example.replacingOccurrences(of: " ", with: "+")]) {
                    if path.contains(variant) { path = path.replacingOccurrences(of: variant, with: "{{\(name)}}"); used.insert(name) }
                    if let current = query, current.contains(variant) { query = current.replacingOccurrences(of: variant, with: "{{\(name)}}"); used.insert(name) }
                }
            }
            components.percentEncodedPath = path.replacingOccurrences(of: "{{", with: "%7B%7B").replacingOccurrences(of: "}}", with: "%7D%7D")
            components.percentEncodedQuery = query?.replacingOccurrences(of: "{{", with: "%7B%7B").replacingOccurrences(of: "}}", with: "%7D%7D")
            return (components.string ?? url).replacingOccurrences(of: "%7B%7B", with: "{{").replacingOccurrences(of: "%7D%7D", with: "}}")
        }
        func inText(_ text: String) -> String {
            var text = text
            for (name, example) in flow.params where text.contains(example) {
                text = text.replacingOccurrences(of: example, with: "{{\(name)}}")
                used.insert(name)
            }
            return text
        }
        flow.startURL = inURL(flow.startURL)
        flow.output.url = inURL(flow.output.url)
        flow.output.body = flow.output.body.map(inText)
        flow.steps = flow.steps.map { step in
            var step = step
            for key in ["url", "text", "value"] {
                guard case let .string(value) = step.args[key] else { continue }
                step.args[key] = .string(key == "url" ? inURL(value) : inText(value))
            }
            return step
        }
        if let unused = flow.params.keys.sorted().first(where: { !used.contains($0) }) {
            throw ComputerUseError.invalidArguments("param \(unused)'s example \(json(flow.params[unused]!)) appears nowhere in the recording; pass a value it typed or a URL used")
        }
    }

    // MARK: - Run

    func runFlow(_ arguments: [String: Any]) throws -> ToolCallResult {
        var flow = try BrowserFlowStore.find(try string("flow", arguments))
        let values = try flowParams(arguments["params"], examples: false)
        if let missing = flow.params.keys.sorted().first(where: { values[$0] == nil }) {
            throw ComputerUseError.invalidArguments("flow \(flow.name) needs params \(flow.params.keys.sorted().joined(separator: ", ")); \(missing) is missing")
        }
        let request = try renderedRequest(flow, values)
        var tiers = [flow.tier ?? "page", "page", "replay"].reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if !flow.replayable { tiers.removeAll { $0 == "replay" } }

        var notes: [String] = []
        for tier in tiers {
            let outcome: FlowOutcome
            do {
                outcome = tier == "page" ? try runPageTier(flow, request) : try runReplayTier(flow, values, request)
            } catch {
                notes.append("\(tier): \(error.localizedDescription)")
                continue
            }
            switch outcome {
            case let .answer(value, status):
                let drift = flow.output.kind == "request" ? flow.output.shape.filter { browserFlowPathMissing($0, in: value) } : []
                // A quarter of the shape gone, or the list itself, is a different answer; less is an unverified one.
                let listGone = flow.output.list.map { list in drift.contains { $0 == list || (!list.isEmpty && $0.hasPrefix(list + "[]")) } } ?? false
                if !drift.isEmpty, drift.count * 4 >= flow.output.shape.count || listGone {
                    notes.append("\(tier): the answer changed shape (missing \(drift.prefix(5).joined(separator: ", ")))")
                    continue
                }
                flow.tier = tier
                flow.verified = drift.isEmpty
                flow.verifiedAt = Date()
                try? BrowserFlowStore.save(flow)
                return .text(flowResult(flow, tier: tier, status: status, value: value, drift: drift, notes: notes, arguments: arguments))
            case let .stop(message):
                return ToolCallResult(content: [.text("Flow \(flow.site)/\(flow.name): \(message)")], isError: true)
            }
        }
        flow.verified = false
        try? BrowserFlowStore.save(flow)
        let tried = notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))"
        return ToolCallResult(content: [.text("Flow \(flow.site)/\(flow.name) failed\(tried). The site may have changed: do the task in the page instead, then save the flow again.")], isError: true)
    }

    private enum FlowOutcome {
        case answer(Any, Int)
        case stop(String)
    }

    private struct FlowRequest {
        var startURL: String
        var method: String
        var url: String
        var body: String?
    }

    private func renderedRequest(_ flow: BrowserFlow, _ values: [String: String]) throws -> FlowRequest {
        func url(_ template: String) throws -> String {
            var rendered = template
            for (name, value) in values { rendered = rendered.replacingOccurrences(of: "{{\(name)}}", with: Self.urlEncoded(value)) }
            guard let host = URL(string: rendered)?.host, browserFlowSite(host) == flow.site,
                  URL(string: template.replacingOccurrences(of: "{{", with: "").replacingOccurrences(of: "}}", with: ""))?.host == host else {
                throw ComputerUseError.invalidArguments("the params would take the flow off \(flow.site)")
            }
            return rendered
        }
        var body = flow.output.body
        if let template = body {
            if let data = template.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
                // Values land inside JSON strings, escaped, so they cannot change the request's structure.
                func fill(_ value: Any) -> Any {
                    if let string = value as? String {
                        return values.reduce(string) { $0.replacingOccurrences(of: "{{\($1.key)}}", with: $1.value) }
                    }
                    if let array = value as? [Any] { return array.map(fill) }
                    if let object = value as? [String: Any] { return object.mapValues(fill) }
                    return value
                }
                body = (try? JSONSerialization.data(withJSONObject: fill(object), options: [.withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) }
            } else {
                body = values.reduce(template) { $0.replacingOccurrences(of: "{{\($1.key)}}", with: Self.urlEncoded($1.value)) }
            }
            if Self.isGraphQLQuery(template), !Self.isGraphQLQuery(body) {
                throw ComputerUseError.invalidArguments("the params would turn the flow's query into a write")
            }
        }
        return FlowRequest(startURL: try url(flow.startURL), method: flow.output.method, url: try url(flow.output.url), body: body)
    }

    /// The flow's request sent with fetch from a background tab on the site, reused across runs.
    private func runPageTier(_ flow: BrowserFlow, _ request: FlowRequest) throws -> FlowOutcome {
        let tab = try flowTab(flow, startURL: request.startURL)
        let response = try call(tab, "flowFetch", [
            "url": request.url, "method": request.method, "body": request.body as Any? ?? NSNull(),
            "headers": flow.output.headers ?? [:], "extract": flow.output.kind == "extract",
        ]) as? [String: Any] ?? [:]
        let status = response["status"] as? Int ?? 0
        if let stop = Self.stopStatus(status) { return .stop(stop) }
        guard (200..<300).contains(status) else {
            throw ComputerUseError.stateUnavailable("HTTP \(status)")
        }
        if flow.output.kind == "extract" {
            let structured = response["structured"] as? [String: Any] ?? [:]
            return .answer(try productAnswer(structured), status)
        }
        guard let text = response["text"] as? String,
              let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            throw ComputerUseError.stateUnavailable("the answer is not JSON (\(response["contentType"] as? String ?? "unknown type"))")
        }
        return .answer(value, status)
    }

    /// The recorded steps again in a fresh background tab; the answer is read from what they load.
    private func runReplayTier(_ flow: BrowserFlow, _ values: [String: String], _ request: FlowRequest) throws -> FlowOutcome {
        let saved = bridge.session { $0.currentTab }
        defer { bridge.session { $0.currentTab = saved } }
        var opened: Int?
        defer { if let opened { _ = try? dispatch(["action": "close", "tab": opened]) } }
        for (index, step) in flow.steps.enumerated() {
            var args = step.args.mapValues(\.any)
            for key in ["url", "text", "value"] {
                guard let template = args[key] as? String else { continue }
                args[key] = values.reduce(template) { $0.replacingOccurrences(of: "{{\($1.key)}}", with: key == "url" ? Self.urlEncoded($1.value) : $1.value) }
            }
            args["action"] = step.action
            args["state"] = "none"
            if index == 0 {
                args["action"] = "open"
                if let profile = flow.profile { args["profile"] = profile }
            } else if let opened {
                args["tab"] = opened
            }
            let result = try dispatch(args)
            if result.isError { throw ComputerUseError.stateUnavailable("step \(index + 1) (\(step.action)) failed: \(result.primaryText ?? "")") }
            if index == 0 {
                opened = bridge.session { $0.currentTab }
                if let opened, let host = href(opened).flatMap({ URL(string: $0)?.host }), browserFlowSite(host) != flow.site {
                    throw ComputerUseError.stateUnavailable("the replay left \(flow.site)")
                }
            }
        }
        guard let tab = opened else { throw ComputerUseError.stateUnavailable("the replay opened no tab") }
        try? poll(8, "the network to go quiet") {
            guard let log = try? networkLog(tab) else { return true }
            return (log["loading"] as? Int ?? 0) == 0 && (log["quietMs"] as? Int ?? 0) >= 500
        }
        if flow.output.kind == "extract" {
            return .answer(try productAnswer(try call(tab, "structured") as? [String: Any] ?? [:]), 200)
        }
        let wantedPath = URL(string: request.url)?.path
        let entries = (try networkLog(tab)["entries"] as? [[String: Any]] ?? []).filter { entry in
            (entry["method"] as? String ?? "").uppercased() == request.method && URL(string: entry["url"] as? String ?? "")?.path == wantedPath
        }
        guard let entry = entries.last(where: { (200..<300).contains($0["status"] as? Int ?? 0) }) ?? entries.last else {
            throw ComputerUseError.stateUnavailable("the replay did not load \(request.method) \(wantedPath ?? request.url)")
        }
        let status = entry["status"] as? Int ?? 0
        if let stop = Self.stopStatus(status) { return .stop(stop) }
        guard let requestID = entry["requestId"] as? String,
              let result = try? bridge.cdp(tab, "Network.getResponseBody", ["requestId": requestID], timeout: 10),
              let text = Self.decodeBody(result), let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            throw ComputerUseError.stateUnavailable("the replayed answer has no JSON body")
        }
        return .answer(value, status)
    }

    private func flowTab(_ flow: BrowserFlow, startURL: String) throws -> Int {
        if let tab = bridge.session(SessionOwner.current, { $0.flowTabs[flow.site] }),
           let host = href(tab).flatMap({ URL(string: $0)?.host }), browserFlowSite(host) == flow.site {
            return tab
        }
        let saved = bridge.session { $0.currentTab }
        defer { bridge.session { $0.currentTab = saved } }
        var args: [String: Any] = ["action": "open", "url": startURL, "state": "none"]
        if let profile = flow.profile { args["profile"] = profile }
        let result = try dispatch(args)
        guard !result.isError, let tab = bridge.session(SessionOwner.current, { $0.currentTab }), tab != saved else {
            throw ComputerUseError.stateUnavailable("could not open \(flow.site): \(result.primaryText ?? "")")
        }
        if let blocked = (try? call(tab, "challenge")) as? String {
            throw ComputerUseError.stateUnavailable("\(flow.site) shows a bot check (\(blocked))")
        }
        bridge.session { $0.flowTabs[flow.site] = tab }
        return tab
    }

    private func productAnswer(_ structured: [String: Any]) throws -> Any {
        let jsonld = structured["jsonld"] as? [[String: Any]] ?? []
        let microdata = structured["microdata"] as? [[String: Any]] ?? []
        let meta = structured["meta"] as? [String: Any] ?? [:]
        let lines = Self.productSummaries(jsonld: jsonld, microdata: microdata, meta: meta)
        guard !lines.isEmpty else { throw ComputerUseError.stateUnavailable("the page has no product data any more") }
        return ["products": lines]
    }

    private func flowResult(_ flow: BrowserFlow, tier: String, status: Int, value: Any, drift: [String], notes: [String], arguments: [String: Any]) -> String {
        var lines = ["Flow \(flow.site)/\(flow.name) via \(tier)\(drift.isEmpty ? "" : ", unverified: missing \(drift.prefix(5).joined(separator: ", "))"): HTTP \(status)"]
        if !notes.isEmpty { lines.append("Fell back after \(notes.joined(separator: "; ")).") }
        if flow.output.kind == "extract", let products = (value as? [String: Any])?["products"] as? [String] {
            lines += products
        } else {
            let limit = (arguments["limit"] as? Int) ?? (arguments["limit"] as? Double).map(Int.init)
            let shaped = browserFlowShape(output: value, list: flow.output.list, where: arguments["where"] as? String,
                                          fields: arguments["fields"] as? String, limit: limit)
            lines.append(compactJSON(shaped))
        }
        return Self.clip(lines.joined(separator: "\n"), arguments["max_chars"] as? Int ?? 6000, hint: "narrow it with fields, where and limit")
    }

    // MARK: - List

    func listFlows(_ arguments: [String: Any]) throws -> ToolCallResult {
        let site = (arguments["url"] as? String).flatMap { URL(string: $0)?.host ?? $0 }.map(browserFlowSite)
        let flows = BrowserFlowStore.all(site: site)
        guard !flows.isEmpty else { return .text("No saved flows\(site.map { " for \($0)" } ?? ""). Save one with flow_save after doing a task in a tab.") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return .text(flows.map { flow in
            let params = flow.params.keys.sorted().joined(separator: ", ")
            let state = flow.verified ? "verified \(flow.verifiedAt.map { formatter.string(from: $0) } ?? "")" : "unverified"
            return "\(flow.site)/\(flow.name)(\(params)) — \(flow.description ?? flow.output.url) [\(flow.tier ?? "page"), \(state)\(flow.replayable ? "" : ", no replay")]"
        }.joined(separator: "\n"))
    }

    // MARK: - Helpers

    static func isGraphQLQuery(_ body: String?) -> Bool {
        guard let body, let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else { return false }
        let operations = (object as? [[String: Any]]) ?? (object as? [String: Any]).map { [$0] } ?? []
        return !operations.isEmpty && operations.allSatisfy { operation in
            guard let query = operation["query"] as? String else { return false }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.lowercased().hasPrefix("mutation") && !trimmed.lowercased().hasPrefix("subscription")
                && trimmed.range(of: "\\bmutation\\b", options: [.regularExpression, .caseInsensitive]) == nil
        }
    }

    static func isTelemetry(_ url: String) -> Bool {
        url.range(of: "/(collect|track|tracking|beacon|analytics|telemetry|log|logs|events?|metrics|rum|pixel|stats|insights)(/|\\?|$)",
                  options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func urlEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func decodeBody(_ result: [String: Any]) -> String? {
        guard let body = result["body"] as? String else { return nil }
        guard result["base64Encoded"] as? Bool == true else { return body }
        return Data(base64Encoded: body).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Answers a run must not retry past: another tier would only ask again.
    static func stopStatus(_ status: Int) -> String? {
        switch status {
        case 401, 403: "auth_expired (HTTP \(status)): sign in to the site in Chrome, or do the task in the page"
        case 404, 410: "not_found (HTTP \(status)): the site has no such item"
        case 429: "rate_limited (HTTP 429): wait before running it again"
        default: nil
        }
    }
}

func browserFlowPathMissing(_ path: String, in root: Any) -> Bool {
    func walk(_ value: Any?, _ keys: ArraySlice<Substring>) -> Bool {
        guard let key = keys.first else { return value != nil }
        if key.hasSuffix("[]") {
            let name = key.dropLast(2)
            let container = name.isEmpty ? value : (value as? [String: Any])?[String(name)]
            guard let array = container as? [Any] else { return false }
            return array.isEmpty || walk(array[0], keys.dropFirst())
        }
        guard let object = value as? [String: Any], object.keys.contains(String(key)) else { return false }
        return walk(object[String(key)], keys.dropFirst())
    }
    let keys = path.replacingOccurrences(of: "[].", with: "[]\u{0}").split(whereSeparator: { $0 == "." || $0 == "\u{0}" })
    return !walk(root, keys[...])
}

private func json(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes, .sortedKeys]) else { return "\(value)" }
    return String(decoding: data, as: UTF8.self)
}
