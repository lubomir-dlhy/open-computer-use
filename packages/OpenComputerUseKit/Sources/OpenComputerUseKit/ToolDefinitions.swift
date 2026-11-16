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
    public static var all: [ToolDefinition] {
        configured(virtualDisplayEnabled: VirtualDisplayConfig.current.enabled)
    }

    static func configured(virtualDisplayEnabled: Bool) -> [ToolDefinition] {
        guard !virtualDisplayEnabled else { return definitions }
        return definitions.map { tool in
            guard tool.name == "get_app_state" else { return tool }
            var schema = tool.inputSchema
            var properties = schema["properties"] as? [String: Any] ?? [:]
            properties.removeValue(forKey: "window_placement")
            schema["properties"] = properties
            return ToolDefinition(name: tool.name, description: tool.description, annotations: tool.annotations, inputSchema: schema)
        }
    }

    private static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "click",
            description: "Click an element by index, at x/y pixel coordinates in the last screenshot, or a menu bar item by menu_path.",
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
                    "hold": holdProperty(),
                    "menu_item": stringProperty(description: "With element_index: open the element's context menu and choose this item in one step (preferred over a right-click then a second click)."),
                    "menu_path": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Menu bar titles to press without opening the menu, e.g. [\"File\", \"New window\"] or [\"Apple\", \"About This Mac\"]. Case-insensitive; a unique prefix is enough.",
                    ],
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
                    "include_screenshot": ["type": "boolean", "description": "Default: a screenshot on first contact with a window or when its tree is thin. True always captures; false never does"],
                    "app": appProperty(),
                    "text_limit": textLimitProperty(description: "Max text chars, or \"max\". Default 500"),
                    "max_tree_nodes": positiveIntegerProperty(description: "Default 1200"),
                    "max_tree_depth": positiveIntegerProperty(description: "Default 64"),
                    "window_id": positiveIntegerProperty(description: "Read this window (ids are listed under Other windows); later actions stay on it"),
                    "keep_window": ["type": "boolean", "description": "Keep this window open when you finish. Windows you open are otherwise closed at the end of your turn."],
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
                    "hold": holdProperty(),
                ],
                required: ["app", "key"]
            )
        ),
        ToolDefinition(
            name: "scroll",
            description: "Scroll an element, or the view under x/y in the last screenshot, by pages.",
            annotations: defaultAnnotations(),
            inputSchema: actionSchema(
                properties: [
                    "app": appProperty(),
                    "direction": stringProperty(description: "up, down, left or right"),
                    "element_index": elementIndexProperty(),
                    "x": numberProperty(description: "Screenshot pixel X, instead of element_index"),
                    "y": numberProperty(description: "Screenshot pixel Y"),
                    "pages": numberProperty(description: "Fractional allowed. Default 1"),
                ],
                required: ["app", "direction"]
            )
        ),
        ToolDefinition(
            name: "set_value",
            description: "Set the value of a settable element and verify the actual value (text compared exactly; an empty string clears it). An unverified write is an error.",
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
                    "paste": ["type": "boolean", "description": "Paste instead of typing; the user's clipboard is restored"],
                    "format": stringProperty(description: "With paste: text (default), html or markdown (pasted as rich text)", enumValues: ["text", "html", "markdown"]),
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
        ToolDefinition(
            name: "browser",
            description: "Drive Chrome tabs in the background through the Open Computer Use Browser extension: Chrome never comes forward and the user's tabs stay untouched. Start with open (a new background tab, in the profile that fits the task) or tabs then claim. A snapshot lists the page as [ref] role \"name\" state lines; refs stay valid while the element exists, and actions return only what changed. Tabs you open close when your turn ends unless you keep them; claimed tabs are released.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "action": stringProperty(enumValues: BrowserTool.actions),
                    "tab": integerProperty(description: "Tab id; defaults to the tab you used last"),
                    "profile": stringProperty(description: BrowserProfiles.parameterDescription()),
                    "url": stringProperty(description: "open, navigate; wait: a URL fragment to wait for"),
                    "ref": integerProperty(description: "Element ref from the snapshot"),
                    "selector": stringProperty(description: "CSS selector instead of ref (searches open shadow roots and same-origin frames)"),
                    "name": stringProperty(description: "Visible name or text instead of ref"),
                    "x": numberProperty(description: "Viewport CSS pixel X instead of an element"),
                    "y": numberProperty(),
                    "to_ref": integerProperty(description: "drag destination; also to_selector, to_name, to_x, to_y"),
                    "to_selector": stringProperty(),
                    "to_name": stringProperty(),
                    "to_x": numberProperty(),
                    "to_y": numberProperty(),
                    "drag_method": stringProperty(description: "auto (default): a trusted HTML5 drag when the source is draggable, else a pointer drag", enumValues: ["auto", "pointer", "js"]),
                    "text": stringProperty(description: "type: inserted into the element (focused first) or the focused field; dialog: prompt answer"),
                    "secret_env": secretEnvProperty(),
                    "clear": ["type": "boolean", "description": "type: replace the field's current value"],
                    "format": stringProperty(description: "type: text (default), or html / markdown pasted as rich text", enumValues: ["text", "html", "markdown"]),
                    "key": stringProperty(description: "e.g. Enter, Tab, Escape, ArrowDown, cmd+a, shift+Tab"),
                    "button": stringProperty(enumValues: ["left", "right", "middle"]),
                    "click_count": integerProperty(description: "2 for a double-click"),
                    "modifiers": stringArrayProperty(description: "Held during the click", enumValues: modifierNames),
                    "hold": numberProperty(description: "click, key: seconds to hold before release"),
                    "force": ["type": "boolean", "description": "click even when another element covers the target"],
                    "direction": stringProperty(enumValues: ["up", "down", "left", "right"]),
                    "amount": numberProperty(description: "scroll: viewport heights, default 1"),
                    "value": stringProperty(description: "select: option text or value of a native <select>"),
                    "files": ["type": "array", "items": ["type": "string"], "description": "upload: absolute file paths"],
                    "accept": ["type": "boolean", "description": "dialog: true accepts (default), false dismisses"],
                    "status": stringProperty(description: "keep: deliverable (default) or handoff", enumValues: ["deliverable", "handoff"]),
                    "expression": stringProperty(description: "evaluate: JavaScript run in the page; promises are awaited and the JSON value returned"),
                    "load": stringProperty(description: "wait: load state", enumValues: ["domcontentloaded", "load"]),
                    "max_chars": integerProperty(description: "Snapshot size budget, default 6000"),
                    "state": stringProperty(description: "diff (default) returns changes; full the whole snapshot; none just ok", enumValues: ["diff", "full", "none"]),
                    "wait_for": stringProperty(description: "Text to wait for on the page; \"!text\" waits until it is gone"),
                    "wait_timeout": numberProperty(),
                ],
                required: ["action"]
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

private func holdProperty() -> [String: Any] {
    numberProperty(description: "Seconds to hold before release")
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
        description: "auto (default; press_key uses sky_key while the app is in the background), or sky_key: authenticated SkyLight key events to the current target window without changing focus. Try sky_key when auto has no effect.",
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
