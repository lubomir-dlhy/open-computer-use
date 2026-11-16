import Foundation

let computerUseServerInstructions = """
Computer Use tools operate macOS apps in the background, so the user can keep using their computer. Don't disrupt their session, for example by overwriting the clipboard, unless they ask. If an app has a dedicated plugin or skill that can do the task, prefer it.

Call `get_app_state` at the start of every turn before acting; the session stops after each assistant turn. For web pages in Chrome use the `browser` tool instead, which needs no `get_app_state`. If a tool is missing, surface it with tool_search.

An action returns only what changed since the state you last saw: `~` changed, `+` added (`(in N)` names the parent), `-` removed. Element indices stay stable until the next `get_app_state`, which renumbers the tree. Every action also takes state ("diff" by default, "full" for the whole tree, "none" for just ok), screenshot (true attaches one), wait_for (text to wait for in the tree; "!text" waits until it is gone) and wait_timeout (seconds, default 5). Use `batch` for several steps in one call, and `get_app_state` for the full picture.

Prefer element indices to coordinates. Avoid AppleScript. Ask before destructive or externally visible actions such as sending, deleting or purchasing.
"""

public final class StdioMCPServer {
    private let service: ComputerUseService
    private let dispatcher: ComputerUseToolDispatcher
    private let backgroundStateReset: (Int) -> Void
    private let turnStateReset: (Int) -> Void
    public let sessionID = SessionOwner.makeID()

    public init(
        service: ComputerUseService = ComputerUseService(),
        backgroundStateReset: @escaping (Int) -> Void = { resetOpenComputerUseBackgroundWindowState(session: $0) },
        turnStateReset: @escaping (Int) -> Void = { resetOpenComputerUseTurnState(session: $0) }
    ) {
        self.service = service
        self.dispatcher = ComputerUseToolDispatcher(service: service)
        self.backgroundStateReset = backgroundStateReset
        self.turnStateReset = turnStateReset
    }

    public func run() throws {
        defer { endSession() }
        let requests = MCPStdinRequests()
        while let request = requests.next() {
            // This thread's autorelease pool never drains on its own: each response's encoded
            // bytes (a screenshot's base64 among them) stayed alive for the whole session.
            autoreleasepool {
                let response = handle(line: request.line)
                if requests.finish(), let response {
                    FileHandle.standardOutput.write((response + "\n").data(using: .utf8)!)
                }
            }
        }
    }

    public func handle(line: String) -> String? {
        SessionOwner.with(sessionID) { handleInSession(line: line) }
    }

    private func handleInSession(line: String) -> String? {
        do {
            guard let payload = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return try encodeJSONRPCError(id: nil, code: -32700, message: "Invalid JSON-RPC payload")
            }

            let method = payload["method"] as? String
            // A message without an id is a notification, which JSON-RPC never answers.
            guard let id = payload["id"] else {
                if method == "notifications/turn-ended" {
                    endTurn()
                }
                return nil
            }
            let params = payload["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                return try encodeJSONRPCResult(
                    id: id,
                    result: [
                        "protocolVersion": "2025-03-26",
                        "serverInfo": [
                            "name": "open-computer-use",
                            "version": openComputerUseVersion,
                        ],
                        "capabilities": [
                            "tools": [
                                "listChanged": false,
                            ],
                        ],
                        "instructions": computerUseServerInstructions,
                    ]
                )
            case "ping":
                return try encodeJSONRPCResult(id: id, result: [:])
            case "tools/list":
                return try encodeJSONRPCResult(
                    id: id,
                    result: [
                        "tools": ToolDefinitions.all.map(\.asDictionary),
                    ]
                )
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let result = try dispatcher.callTool(name: name, arguments: arguments)
                return try encodeJSONRPCResult(
                    id: id,
                    result: result.asDictionary
                )
            default:
                if method == nil {
                    return nil
                }

                return try encodeJSONRPCError(id: id, code: -32601, message: "Method not found: \(method ?? "")")
            }
        } catch let error as ComputerUseError {
            let payload = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            let id = payload?["id"]
            let result = ToolCallResult.text(SecretInput.redact(error.errorDescription ?? String(describing: error)), isError: error.toolResultIsError)
            return try? encodeJSONRPCResult(id: id, result: result.asDictionary)
        } catch {
            let message = SecretInput.redact((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            let payload = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            let id = payload?["id"]
            return try? encodeJSONRPCResult(
                id: id,
                result: [
                    "content": [
                        [
                            "type": "text",
                            "text": message,
                        ],
                    ],
                    "isError": true,
                ]
            )
        }
    }

    /// Release state that is scoped to one MCP client session. App-hosted MCP
    /// connections call this explicitly because they use `handle(line:)`
    /// instead of the stdio `run()` loop.
    public func endSession() {
        endTurn()
        backgroundStateReset(sessionID)
    }

    private func endTurn() {
        service.clearQueryIndexes()
        // Done or failed, the agent's own windows go away before others may claim the app.
        SessionOwner.with(sessionID) { _ = service.closeOpenedWindows() }
        BrowserBridge.shared.endTurn(owner: sessionID)
        AgentLeases.shared.release(session: sessionID)
        VisualCursorSupport.resetOnMain()
        turnStateReset(sessionID)
    }

    private func encodeJSONRPCResult(id: Any?, result: [String: Any]) throws -> String {
        try encode([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result,
        ])
    }

    private func encodeJSONRPCError(id: Any?, code: Int, message: String) throws -> String {
        try encode([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": code,
                "message": message,
            ],
        ])
    }

    private func encode(_ object: [String: Any]) throws -> String {
        // Swift seeds dictionary order per process; unsorted tool schemas would differ
        // between sessions and miss the client's prompt cache.
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.message("Failed to encode JSON-RPC response.")
        }

        return text
    }
}

/// The requests of a stdio MCP session. Lines are read on their own thread, so a `notifications/cancelled` is seen while
/// a request runs; the caller still handles requests one at a time, in order. A cancelled request that hasn't started
/// never runs. One that is running finishes (an action can't be stopped halfway), but its answer is dropped, as MCP
/// asks of a server.
public final class MCPStdinRequests: @unchecked Sendable {
    public struct Request {
        public let line: String
        let key: String?
    }

    private let condition = NSCondition()
    private var waiting: [Request] = []
    private var running: String?
    private var runningCancelled = false
    private var ended = false

    public init(readLine: @escaping @Sendable () -> String? = { Swift.readLine(strippingNewline: true) }) {
        Thread { [self] in
            while let line = readLine() {
                // No run loop drains this thread's autorelease pool either.
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { autoreleasepool { add(line) } }
            }
            condition.lock()
            ended = true
            condition.broadcast()
            condition.unlock()
        }.start()
    }

    /// The next request in order, waiting for one; nil once the input has ended and every request was handled.
    public func next() -> Request? {
        condition.lock()
        defer { condition.unlock() }
        while waiting.isEmpty && !ended { condition.wait() }
        guard !waiting.isEmpty else { return nil }
        let request = waiting.removeFirst()
        running = request.key
        runningCancelled = false
        return request
    }

    /// Ends the request from `next`; false when it was cancelled while it ran, so its answer is dropped.
    public func finish() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        running = nil
        return !runningCancelled
    }

    private func add(_ line: String) {
        let payload = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        condition.lock()
        defer { condition.unlock() }
        if payload?["method"] as? String == "notifications/cancelled", payload?["id"] == nil {
            guard payload?["jsonrpc"] as? String == "2.0" else { return }
            let key = Self.key((payload?["params"] as? [String: Any])?["requestId"])
            if let key, let index = waiting.firstIndex(where: { $0.key == key }) {
                waiting.remove(at: index)
            } else if let key, key == running {
                runningCancelled = true
            }
            return
        }
        let key = payload?["method"] as? String == "initialize" ? nil : Self.key(payload?["id"])
        waiting.append(Request(line: line, key: key))
        condition.signal()
    }

    /// A JSON-RPC id as a key: 7 and "7" are different ids.
    private static func key(_ id: Any?) -> String? {
        switch id {
        case let text as String: "s:" + text
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): "n:" + number.stringValue
        default: nil
        }
    }
}
