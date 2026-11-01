## [2026-11-01 07:30] | Task: Close OCU's background gaps from the GPT eval and ship 1.1.3-sky.9

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> The eval (GPT-6.1 Terra via codex exec, strict background checks) found that OCU passed 18/26 tasks (10 fully in the background), against 23/26 for Codex CU. Implement the remaining gaps: secret-by-reference input, Chrome tabs and windows without focus steals and with correct window targeting, context and system menus, web double-click editing, Finder operations, HTML5 drag-and-drop if background-safe, and opening windows for windowless apps. Stay background-safe, keep lean results, bump the version, build the signed app and install it globally with a backup.

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`, app agent proxy, skill, docs

**Key Actions:**
- **Secrets**: `type_text` / `set_value` accept `secret_env`. The proxy forwards only referenced variables, values are redacted from all later results, and only password-like names are allowed unless listed in `OPEN_COMPUTER_USE_SECRET_ENV`.
- **Menus**: `click menu_path` presses menu bar items without opening them. `click menu_item` opens an element's context menu and picks an item in one step. A plain right-click lists the menu and closes it again, since open menus capture the user's keyboard.
- **Windows**: reads stay pinned to the agent's window and follow only windows that are new; `get_app_state window_id` selects a window and the app's other windows are listed. Windowless apps get a window in the background (reopen without activation, parked). Read-backs never relaunch an app.
- **Foreground guard**: Chrome activates itself for every new tab or window. During an action and for a second after, a foreground taken by the target app is handed back to the user's app (about 80 ms).
- **Input**: `press_key` auto uses SkyLight delivery in the background. Double-clicks use real SkyLight events. `batch` holds one synthetic focus session, so in-place editors survive. `type_text` replaces a selection in web content with real keystrokes. `set_value` focuses the field first.
- **Lists/Finder**: row clicks select via `AXSelectedRows`, with `cmd` to extend the selection. Finder context menu commands (Compress) work in the background.

### 🧠 Design Intent (Why)
Every fix keeps the target app inactive. Where macOS or the app forces the foreground (Chrome window creation, About This Mac, open context menus), the exposure is shortened rather than hidden.

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/{SecretInput,MenuPath,ForegroundGuard}.swift` (new)
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/{ComputerUseService,ComputerUseToolDispatcher,AccessibilitySnapshot,AgentDisplay,AppDiscovery,SkyLightSPI,ToolDefinitions,MCPServer}.swift`
- `apps/OpenComputerUse/Sources/OpenComputerUse/MacOSAppAgentProxy.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/{SecretInputTests,BackgroundWindowTests}.swift`
- `skills/open-computer-use/SKILL.md`, `docs/ARCHITECTURE.md`

## [2026-11-01 08:10] | Task: Let several agents use Computer Use at once

### 📥 User Query
> Computer use should run things in parallel in a smart way: work that can be split by window should run side by side, and single-instance apps must handle concurrency (at most one agent working on them).

### 🛠 Changes Overview
- **Per-request environment** (`RequestEnvironment`): per-call OPEN_COMPUTER_USE_* settings and secrets live with the serving thread. The app agent no longer runs every request under one global lock with `setenv`.
- **Leases** (`AgentLeases`): an action claims the agent's window (apps whose menus can open another window or document) or the whole app (single-window apps). Other sessions wait up to 30 s and then get a clear error; `get_app_state` notes the conflict without waiting. Claims end with the session's turn, or after 120 s idle. Input into one process is serialized for the length of a call.
- Foreground guard and SkyLight held focus are per action and per process instead of single global slots. Locked Use scoped requests stay strictly serialized.
- Live check (two clients on one agent): actions on two apps overlapped; a second agent was refused a single-window app with a clear message, and got it as soon as the first agent's turn ended.
