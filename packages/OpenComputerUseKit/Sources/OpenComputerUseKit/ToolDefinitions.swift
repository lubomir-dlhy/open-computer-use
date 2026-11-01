import Foundation

public struct ToolDefinition: @unchecked Sendable {
    public let name: String
    public let description: String
    public let annotations: [String: Any]
    public let inputSchema: [String: Any]

    public init(name: String, description: String, annotations: [String: Any], inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.annotations = annotations
        self.inputSchema = inputSchema
    }

    public var asDictionary: [String: Any] {
        var dictionary: [String: Any] = [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
        ]

        if !annotations.isEmpty {
            dictionary["annotations"] = annotations
        }

        return dictionary
    }
}

public enum ToolDefinitions {
    public static let all: [ToolDefinition] = [
        ToolDefinition(
            name: "click",
            description: "Click an element by index, or at x/y pixel coordinates in the last screenshot.",
            annotations: defaultAnnotations(),
            inputSchema: actionSchema(
                properties: [
                    "app": appProperty(),
                    "element_index": elementIndexProperty(),
                    "x": numberProperty(description: "Screenshot pixel X"),
                    "y": numberProperty(description: "Screenshot pixel Y"),
                    "click_count": integerProperty(description: "Default 1"),
                    "mouse_button": stringProperty(description: "Default left", enumValues: ["left", "right", "middle"]),
                    "click_method": stringProperty(
                        description: "auto (default); accessibility needs element_index; app_post posts to the app; sky_click uses the SkyLight background-window path; global may move the pointer and needs OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1.",
                        enumValues: ClickMethod.allCases.map(\.rawValue)
                    ),
                    "modifiers": stringArrayProperty(description: "Held during the click (sky_click only)", enumValues: modifierNames),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "drag",
            description: "Drag between screenshot pixel coordinates. The default path posts events to the app without moving the pointer, so it cannot drive window-server drags (window moves, text selection, or Finder drag-and-drop); those need OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 in the server environment and may move the real pointer. The result names the path used.",
            annotations: defaultAnnotations(),
            inputSchema: actionSchema(
                properties: [
                    "app": appProperty(),
                    "from_x": numberProperty(),
                    "from_y": numberProperty(),
                    "to_x": numberProperty(),
                    "to_y": numberProperty(),
                    "drag_method": stringProperty(
                        description: "auto (default); sky posts via SkyLight to the window without moving the pointer, for Chromium web content; app_post and global force those paths.",
                        enumValues: DragMethod.allCases.map(\.rawValue)
                    ),
                    "path": pointArrayProperty(description: "[x, y] waypoints between from and to (sky only)"),
                    "modifiers": stringArrayProperty(description: "Held during the drag (sky only)", enumValues: modifierNames),
                ],
                required: ["app", "from_x", "from_y", "to_x", "to_y"]
            )
        ),
        ToolDefinition(
            name: "query",
            description: "Find controls in the app's current window by text and/or role, without a full tree or screenshot. Each match has an index usable by element actions for 120 s; the result reports truncated, stop_reason, visited_nodes and window_id. Running apps only.",
            annotations: readOnlyAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": appProperty(),
                    "text": stringProperty(description: "Case-insensitive substring of title, description or value (max 1000 UTF-16 units)"),
                    "role": stringProperty(description: "AX role; prefix optional (button or AXButton)"),
                    "exact": ["type": "boolean", "description": "Match the whole text. Default false"],
                    "limit": positiveIntegerProperty(description: "Default 20, max 100"),
                    "max_nodes": positiveIntegerProperty(description: "Traversal cap. Default 500, max 5000; 2 s deadline"),
                    "window_id": positiveIntegerProperty(description: "CGWindowID to search instead of the current window"),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "get_app_state",
            description: "Start an app session if needed and return the key window's accessibility tree and a screenshot. Call once per turn before acting. Action results keep these element indices until the next call.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "include_ax": ["type": "boolean", "default": true, "description": "False skips the tree and invalidates element indices"],
                    "include_screenshot": ["type": "boolean", "default": true, "description": "False skips capture; coordinate actions need a screenshot"],
                    "app": appProperty(),
                    "text_limit": textLimitProperty(description: "Max text chars, or \"max\". Default 500"),
                    "max_tree_nodes": positiveIntegerProperty(description: "Default 1200"),
                    "max_tree_depth": positiveIntegerProperty(description: "Default 64"),
                    "window_placement": stringProperty(
                        description: "keep (default); agent_display parks the window on the agent's invisible display so a covered or other-Space window renders and takes input without touching the user's Space, focus or pointer (it leaves the user's desktop until restore or exit); restore puts it back.",
                        enumValues: WindowPlacement.allCases.map(\.rawValue)
                    ),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "list_apps",
            description: "List running apps and apps used in the last 14 days, with usage frequency.",
            annotations: readOnlyAnnotations(),
            inputSchema: objectSchema(properties: [:], required: [])
        ),
        ToolDefinition(
            name: "perform_secondary_action",
            description: "Invoke a secondary accessibility action listed for an element.",
            annotations: defaultAnnotations(),
            inputSchema: actionSchema(
                properties: [
                    "app": appProperty(),
                    "element_index": elementIndexProperty(),
                    "action": stringProperty(description: "Action name as listed"),
                ],
                required: ["app", "element_index", "action"]
            )
        ),
        ToolDefinition(
            name: "press_key",
            description: "Press a key or combination in xdotool `key` syntax, e.g. \"Return\", \"Tab\", \"super+c\", \"Up\", \"KP_0\".",
            annotations: defaultAnnotations(),
            inputSchema: actionSchema(
                properties: [
                    "app": appProperty(),
                    "key": stringProperty(),
                    "key_method": keyMethodProperty(),
                ],
                required: ["app", "key"]
            )
        ),
        ToolDefinition(
            name: "scroll",
            description: "Scroll an element by pages.",
            annotations: defaultAnnotations(),
            inputSchema: actionSchema(
                properties: [
                    "app": appProperty(),
                    "direction": stringProperty(description: "up, down, left or right"),
                    "element_index": elementIndexProperty(),
                    "pages": numberProperty(description: "Fractional allowed. Default 1"),
                ],
                required: ["app", "element_index", "direction"]
            )
        ),
        ToolDefinition(
            name: "set_value",
            description: "Set the value of a settable element.",
            annotations: defaultAnnotations(),
            inputSchema: actionSchema(
                properties: [
                    "app": appProperty(),
                    "element_index": elementIndexProperty(),
                    "value": stringProperty(),
                    "secret_env": secretEnvProperty(),
                ],
                required: ["app", "element_index"]
            )
        ),
        ToolDefinition(
            name: "select_text",
            description: "Select text in a text element, or put the cursor before or after it. Give the text exactly as in the tree, including Markdown; add prefix or suffix if it repeats.",
            annotations: defaultAnnotations(),
            inputSchema: actionSchema(
                properties: [
                    "app": appProperty(),
                    "element_index": elementIndexProperty(),
                    "text": stringProperty(),
                    "prefix": stringProperty(description: "Text just before the target"),
                    "suffix": stringProperty(description: "Text just after the target"),
                    "selection": stringProperty(description: "Default text", enumValues: TextSelectionMode.allCases.map(\.rawValue)),
                ],
                required: ["app", "element_index", "text"]
            )
        ),
        ToolDefinition(
            name: "type_text",
            description: "Type literal text into the focused element.",
            annotations: defaultAnnotations(),
            inputSchema: actionSchema(
                properties: [
                    "app": appProperty(),
                    "text": stringProperty(),
                    "secret_env": secretEnvProperty(),
                    "key_method": keyMethodProperty(),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "batch",
            description: "Run several actions on one app in one call, with no read-back between steps, and return one result. Indices in every step refer to the state before the batch. Stops at the first failing step.",
            annotations: defaultAnnotations(),
            inputSchema: actionSchema(
                properties: [
                    "app": appProperty(),
                    "steps": [
                        "type": "array",
                        "description": "Each step is {tool, ...that tool's arguments}; a step's wait_for holds the next step until it is met.",
                        "items": [
                            "type": "object",
                            "properties": ["tool": ["type": "string", "enum": ComputerUseToolDispatcher.actionTools.sorted()]],
                            "required": ["tool"],
                        ],
                        "minItems": 1,
                        "maxItems": 50,
                    ],
                ],
                required: ["app", "steps"]
            )
        ),
    ]
}

private let modifierNames = ["cmd", "shift", "option", "control"]

/// Every action accepts the same result options, documented once in the server instructions.
private func actionSchema(properties: [String: Any], required: [String]) -> [String: Any] {
    objectSchema(
        properties: properties.merging([
            "state": stringProperty(enumValues: ActionStateMode.allCases.map(\.rawValue)),
            "screenshot": ["type": "boolean"],
            "wait_for": stringProperty(),
            "wait_timeout": numberProperty(),
        ]) { current, _ in current },
        required: required
    )
}

private func appProperty() -> [String: Any] {
    stringProperty(description: "App name or bundle id")
}

private func secretEnvProperty() -> [String: Any] {
    stringProperty(description: "Instead of the literal text: name of an environment variable in the Open Computer Use process (e.g. a password). Its value is used but never returned.")
}

private func elementIndexProperty() -> [String: Any] {
    ["type": "string"]
}

private func objectSchema(properties: [String: Any], required: [String]) -> [String: Any] {
    var schema: [String: Any] = [
        "type": "object",
        "properties": properties,
        "additionalProperties": false,
    ]

    if !required.isEmpty {
        schema["required"] = required
    }

    return schema
}

private func defaultAnnotations() -> [String: Any] {
    [
        "destructiveHint": false,
        "openWorldHint": false,
    ]
}

private func readOnlyAnnotations() -> [String: Any] {
    [
        "destructiveHint": false,
        "idempotentHint": true,
        "openWorldHint": false,
        "readOnlyHint": true,
    ]
}

private func keyMethodProperty() -> [String: Any] {
    stringProperty(
        description: "auto (default), or sky_key: authenticated SkyLight key events to the current on-screen target window without changing focus. Try sky_key when auto has no effect, e.g. menu shortcuts like super+s.",
        enumValues: KeyMethod.allCases.map(\.rawValue)
    )
}

private func stringProperty(description: String? = nil, enumValues: [String]? = nil) -> [String: Any] {
    var property: [String: Any] = ["type": "string"]
    if let description {
        property["description"] = description
    }

    if let enumValues {
        property["enum"] = enumValues
    }

    return property
}

private func stringArrayProperty(description: String, enumValues: [String]) -> [String: Any] {
    [
        "type": "array",
        "description": description,
        "items": ["type": "string", "enum": enumValues],
    ]
}

private func pointArrayProperty(description: String) -> [String: Any] {
    [
        "type": "array",
        "description": description,
        "items": [
            "type": "array",
            "items": ["type": "number"],
            "minItems": 2,
            "maxItems": 2,
        ],
    ]
}

private func integerProperty(description: String) -> [String: Any] {
    [
        "type": "integer",
        "description": description,
    ]
}

private func positiveIntegerProperty(description: String) -> [String: Any] {
    [
        "type": "integer",
        "minimum": 1,
        "description": description,
    ]
}

private func textLimitProperty(description: String) -> [String: Any] {
    [
        "anyOf": [
            [
                "type": "integer",
                "minimum": 1,
            ],
            [
                "type": "string",
                "enum": [SnapshotTextLimit.maxKeyword],
            ],
        ],
        "description": description,
    ]
}

private func numberProperty(description: String? = nil) -> [String: Any] {
    description.map { ["type": "number", "description": $0] } ?? ["type": "number"]
}
