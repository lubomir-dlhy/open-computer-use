import Foundation

let computerUseServerInstructions = """
Computer Use tools operate macOS apps in the background, so the user can keep using their computer. Don't disrupt their session, for example by overwriting the clipboard, unless they ask. If an app has a dedicated plugin or skill that can do the task, prefer it.

Call `get_app_state` at the start of every turn before acting; the session stops after each assistant turn. If a tool is missing, surface it with tool_search.

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
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            if let response = handle(line: line) {
                FileHandle.standardOutput.write((response + "\n").data(using: .utf8)!)
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
            let id = payload["id"]
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
            case "notifications/initialized":
                return nil
            case "notifications/turn-ended":
                endTurn()
                return nil
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
        AgentLeases.shared.release(session: sessionID)
        VisualCursorSupport.performOnMain {
            SoftwareCursorOverlay.reset()
        }
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
        let data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.message("Failed to encode JSON-RPC response.")
        }

        return text
    }
}
