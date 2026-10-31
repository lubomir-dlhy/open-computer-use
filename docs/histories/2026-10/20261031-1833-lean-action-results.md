## [2026-10-31 18:33] | Task: Make macOS action results lean and fast

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> A CUA eval (Claude driving OCU over MCP, 19 tasks) found that every action returned the full AX tree plus a screenshot (2.7k–5.6k tokens per call). Click and set_value took about 3 s, and roughly half of the wall time was spent inside tools. Make OCU faster and more token-efficient without regressing background behaviour: lean diff results with stable ids, opt-in screenshots, batching, readiness waits instead of fixed sleeps, and trimmed tool schemas. Keep the old behaviour reachable and measure before and after.

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`, smoke suite, skill and docs

**Key Actions:**
- **Diff results**: actions return `~`/`+`/`-` tree changes against the state the agent last saw. Snapshots record which line belongs to which element, and a read-back reuses the previous indices by AX element identity, so known indices stay valid. A diff nearly as large as the tree falls back to the full tree.
- **Per-call options**: `state` (diff, full or none), `screenshot`, `wait_for` (`!text` waits for absence) and `wait_timeout` on every action. `OPEN_COMPUTER_USE_ACTION_RESULT=full` restores the old default, and `OPEN_COMPUTER_USE_ACTION_READ_BACK=0` behaves as before.
- **`batch` tool**: up to 50 steps on one app with no read-back between them, one combined result against the pre-batch state, and a stop at the first failure.
- **Settle loop**: replaced the fixed 100–150 ms sleeps with AX-only reads every 30 ms until the tree is stable, unchanged for 150 ms, or `wait_for` is met. A screenshot is captured only when requested. Without one, the last screenshot's pixel size carries over for coordinate actions while the window size is unchanged.
- **Non-blocking cursor**: the visual cursor's move (about 1.45 s) and pulse (about 0.18 s) ran synchronously before every element click, set_value and select_text. They now play on the main thread while the action proceeds, and a new move drops queued animations. `OPEN_COMPUTER_USE_VISUAL_CURSOR_BLOCKING=1` restores the old wait.
- **Schema trim**: shorter tool, parameter and server-instruction text; the result options are documented once in the instructions.
- **Robustness**: `type_text` reads the live focused element and falls back to keyboard input when settability cannot be read. `set_value` sends a number to elements whose value is numeric, such as sliders.

### 🧠 Design Intent (Why)
Each agent step re-sends the whole conversation, so a full tree and image in every result compounds quickly. The eval showed most tool time was the cursor animation, not AX work. The changes keep the old full-state path one argument or environment variable away, and leave background input paths untouched.

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ActionResult.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseToolDispatcher.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolDefinitions.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/MCPServer.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SoftwareCursorOverlay.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/ActionResultTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `apps/OpenComputerUseSmokeSuite/Sources/OpenComputerUseSmokeSuite/main.swift`
- `docs/lean-action-results.md`, `docs/ARCHITECTURE.md`, `skills/open-computer-use/references/usage.md`
