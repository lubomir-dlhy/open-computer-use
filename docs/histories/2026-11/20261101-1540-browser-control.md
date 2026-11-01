## [2026-11-01 15:40] | Task: Chrome control through a fork-owned browser extension, js parity, cheaper observation

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI (E5 Code)`

### 📥 User Query
> Close the gaps found against Codex CU: a Chrome control channel (tabs without menus or activation, claiming tabs, tab cleanup, CDP input, waits, dialogs, file inputs, downloads, evaluate, HTML5 drag-and-drop, secret typing) built from open-browser-use imported as the fork's own code (own extension, key, host name; no dependency on the original author; license kept). Make `js` level with the native tools without silently disabling read-back, add paste with clipboard restore, and make observation cheaper (screenshot only on first contact or a thin tree, scroll at a point, click/key hold).

### 🛠 Changes Overview
**Scope:** `apps/OpenComputerUseBrowserExtension`, `apps/OpenComputerUse`, `packages/OpenComputerUseKit`, `scripts/node-repl`, `scripts/build-open-computer-use-app.sh`, `skills/open-computer-use`, docs.

**Key Actions:**
- **Extension**: MV3 extension adapted from open-browser-use v1.1.0 (MIT): JSON-RPC over native messaging, tab-group sessions, `active:false` tabs, tabs-API navigation, CDP passthrough, file chooser and downloads; own ID, key, host name `sk.lubomirdlhy.opencomputeruse.browser`. Removes another extension's frame and re-attaches when Chrome drops the debugger for it (iCloud Passwords on DemoQA). Keep marks stored in the extension; a client that disconnects mid-turn is finalized by the host.
- **Native host**: `open-computer-use` doubles as the native-messaging host (Chrome passes the extension origin), relaying to a per-host Unix socket with request-id renumbering; `browser-setup` registers it and copies the extension.
- **`browser` tool**: snapshot with stable refs and diff results; click/hover/type/key/scroll/select via CDP input, trusted HTML5 drag via drag interception, waits, dialogs, upload, download, evaluate, screenshot, keep/claim/close; ends the turn with `finalizeTabs`.
- **`js`**: actions return their diff unshown (no more `OPEN_COMPUTER_USE_ACTION_READ_BACK=0`); `state`/`waitFor`/`waitTimeout`, `menuItem`/`menuPath`/`modifiers`/`hold`, `secretEnv`, `windowId`, `batch`, `paste`, and `cua.browser` tab bindings.
- **Native**: `get_app_state` screenshot on first contact or a thin tree; `scroll` at `x`/`y`; `hold` on `click`/`press_key`; `type_text` `paste` (text/html/markdown) with clipboard restore, never for secrets.

### 🧠 Design Intent (Why)
Web tasks through AX and synthetic window events could not do HTML5 drag-and-drop and made Chrome activate itself whenever a tab or window was created. Driving tabs through the debugger keeps Chrome in the background and gives trusted page input. The code is copied rather than depended on so the fork owns its extension identity and builds everything from this repository.

### 📁 Files Modified
- `apps/OpenComputerUseBrowserExtension/*`
- `apps/OpenComputerUse/Sources/OpenComputerUse/OpenComputerUseMain.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/{BrowserNativeHost,BrowserBridge,BrowserTool,BrowserPageScript,PasteText}.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/{ComputerUseService,ComputerUseToolDispatcher,ToolDefinitions,MCPServer,RequestEnvironment,InputSimulation,SkyClickSimulation,OpenComputerUseCLI}.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/{BrowserToolTests,OpenComputerUseKitTests,SelectiveObservationTests}.swift`
- `scripts/node-repl/open-computer-use-repl.mjs`, `scripts/node-repl/open-computer-use-repl.test.mjs`
- `scripts/build-open-computer-use-app.sh`, `THIRD_PARTY_NOTICES.md`
- `docs/browser-control.md`, `docs/lean-action-results.md`, `docs/ARCHITECTURE.md`
- `skills/open-computer-use/SKILL.md`, `skills/open-computer-use/references/usage.md`
