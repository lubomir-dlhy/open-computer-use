## [2026-11-01 17:15] | Task: Route browser work to the right Chrome profile

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `claude-opus-5-5`
* **Runtime**: `Claude Code CLI (E5 Code)`

### 📥 User Query
> Add the extension to my Chrome profiles (personal, CulturePulse, contact@lubomirdlhy.sk); OCU should be smart enough to do CulturePulse work in its profile and personal work in the personal one, which is the default.

### 🛠 Changes Overview
**Scope:** `apps/OpenComputerUseBrowserExtension`, `packages/OpenComputerUseKit`, `scripts/node-repl`, `skills/open-computer-use`, docs.

**Key Actions:**
- **Extension 1.1.0**: `getInfo` returns a random per-profile token kept in `chrome.storage.local`; `background` permission so Chrome keeps profiles with the extension loaded without a window; `onStartup` wakes the worker so it connects at profile start.
- **`BrowserProfiles`**: finds the profile folder whose extension storage holds the token, reads name and email from `Local State`; default and per-profile notes from `browser-profiles.json` (or `OPEN_COMPUTER_USE_BROWSER_PROFILE`); matches by name, email or folder, never by note.
- **`BrowserBridge`**: one socket per profile (Chrome starts one native host per profile); routes by tab owner, then `profile`, then the current tab's profile, then the default; `finalizeTabs` in every profile at turn end.
- **`browser` tool / `js`**: `profile` on `open` and `tabs`, its schema description listing the profiles, notes and default; `tabs` groups by profile and names installed profiles that are not running.

### 🧠 Design Intent (Why)
Chrome has no API to reach another profile from an extension, and each profile runs its own extension instance and native host, so profile choice has to happen in the bridge. The token avoids the `identity.email` permission and also identifies profiles not signed in to Google. Listing the profiles in the parameter description lets the agent choose by the task's account without an extra call. Loading a windowless profile with `open --profile-directory --no-startup-window` brought Chrome forward and still did not load the extension, so the bridge reports a profile that is not running instead of launching it.

### 📁 Files Modified
- `apps/OpenComputerUseBrowserExtension/{background.js,manifest.json,README.md}`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/{BrowserProfiles.swift,BrowserBridge.swift,BrowserTool.swift,ToolDefinitions.swift}`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/BrowserToolTests.swift`
- `scripts/node-repl/open-computer-use-repl.mjs`
- `skills/open-computer-use/{SKILL.md,references/usage.md}`, `docs/browser-control.md`
