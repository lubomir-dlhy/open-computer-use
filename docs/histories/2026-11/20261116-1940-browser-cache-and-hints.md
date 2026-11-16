## [2026-11-16 19:40] | Task: prompt-cache-stable tool list and browser snapshot hints

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> Browser Use and Vercel's agent-browser both optimized speed and caching; research it and incorporate it.

### 🛠 Changes Overview
**Scope:** `OpenComputerUseKit` (MCP server, browser page script, browser profiles), skill, docs

**Key Actions:**
- **Stable `tools/list` bytes**: MCP responses are encoded with sorted keys. Swift seeds dictionary order per process, so every new session sent the same schemas in a different key order and missed the client's prompt cache from the tool definitions on. Profile notes are matched in sorted order.
- **Snapshot hints**: unnamed controls, and controls whose role and name repeat, get `hint="…"` (icon, image file, `data-testid`, `name`, hand-written `id`, or the row's text unless it is in the four lines above). Page script version 2 so open documents pick it up.
- **Version**: `1.1.3-sky.14`.

### 🧠 Design Intent (Why)
Browser Use 1.0.4 halved model cost by never rewriting earlier prompt content (screenshots pruned in batches, 78% → 96% cache hits). An MCP server does not own the history, but its tool definitions sit at the front of every prompt, so they must be byte-identical across sessions. agent-browser 0.43 added the same kind of hints so agents can tell icon-only and repeated controls apart without a screenshot. Hints are computed inline so they share the snapshot's character budget, and row text the snapshot already shows is not repeated.

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/MCPServer.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/BrowserPageScript.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/BrowserProfiles.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `scripts/tests/browser-snapshot-hints-smoke.mjs`
- `docs/browser-control.md`
- `skills/open-computer-use/references/usage.md`
