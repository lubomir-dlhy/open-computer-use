## [2026-11-16 22:15] | Task: saved browser flows (record once, rerun with new inputs)

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> agent-browser's saved flows ("record a browser task once, replay it without the browser") would be useful for our product checks; implement them.

### 🛠 Changes Overview
**Scope:** browser extension (1.3.0), `OpenComputerUseKit` browser tool, JS REPL, skill, docs

**Key Actions:**
- **Recording**: browser actions are kept per tab with their network-log range; refs become stable selectors plus names before the action runs.
- **`flow_save`**: output request or page product data, params by example value (never in a host), reads only (GET, GraphQL queries), writes listed and replay disabled, credential headers never kept, answer shape and list stored in owner-only files.
- **`flow_run`**: page tier (fetch from a reused background tab on the site) then replay tier (recorded steps in a fresh tab); stop statuses, drift detection, `fields` / `where` / `limit`; `flow_list` and a hint after `open`.
- **Fix**: `open` attaches right after creating the tab with its URL; attaching to a renderer-less `about:blank` stalled the debugger session. Commands at attach are bounded, and navigation status falls back to Navigation Timing.
- **Tests**: e2e smoke covers page tier, product-data flow, signed API by replay, list shaping, writes, 404, encoding, drift; unit tests for site, shape, drift, shaping, read detection, file round trip; REPL binding test.
- **Version**: `1.1.4-sky.3`.

### 🧠 Design Intent (Why)
Product checks repeat the same steps for other SKUs. Running in the user's own Chrome, the page tier reuses their session without handling cookies, and a loop over SKUs costs one fetch each; the replay tier covers APIs that only the page can sign. A direct-HTTP tier is left out until needed: it would need cookie export and public-address checks.

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/BrowserFlows.swift` (new), `BrowserTool.swift`, `BrowserBridge.swift`, `BrowserPageScript.swift`, `ToolDefinitions.swift`
- `apps/OpenComputerUseBrowserExtension/background.js`, `manifest.json`
- `scripts/node-repl/open-computer-use-repl.mjs`, `scripts/node-repl/open-computer-use-repl.test.mjs`, `scripts/tests/browser-e2e-smoke.mjs`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/BrowserToolTests.swift`
- `docs/browser-control.md`, `skills/open-computer-use/SKILL.md`, `skills/open-computer-use/references/usage.md`
