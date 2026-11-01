# Browser control (Chrome)

The `browser` MCP tool (and `cua.browser` in the `js` REPL) drives Chrome tabs through the Open Computer Use
Browser extension, so web work needs no window, menu, screenshot or synthetic mouse event on the user's screen.

## Pieces

```text
MCP client ── browser tool ── BrowserBridge ──unix socket──▶ open-computer-use (native host) ──stdio──▶ extension ──chrome.debugger──▶ tab
```

- `apps/OpenComputerUseBrowserExtension`: MV3 service worker. Sessions are tab groups titled `OCU`; it opens tabs
  with `chrome.tabs.create({ active: false })`, navigates with the tabs API, and runs CDP commands in a tab,
  attaching the debugger on first use (with `Page.enable` and focus emulation). Chrome detaches the debugger when
  another extension (iCloud Passwords, a password manager) puts a `chrome-extension://` frame into the page; the
  extension then removes that frame from the agent's tab and retries once.
- `BrowserNativeHost.swift`: Chrome starts `open-computer-use` with the extension origin as its argument. The host
  relays native messages to clients on `~/Library/Application Support/OpenComputerUse/Browser/<pid>.sock`,
  renumbering request ids so several MCP sessions share one extension connection.
- `BrowserBridge.swift`: one socket per process; session id `ocu-<pid>-<session>`. At turn end it calls
  `finalizeTabs`: tabs the agent opened close, claimed user tabs are released (ungrouped), kept tabs stay. On
  connect it finalizes sessions whose process has exited.
- `BrowserTool.swift` / `BrowserPageScript.swift`: actions. A page script (installed once per document) renders a
  snapshot of `[ref] role "name" state` lines plus visible text; refs stay stable for an element's lifetime, so
  actions return a diff (`~` changed, `+` added, `-` removed), the full snapshot after a navigation.

## Actions

| Action | What it does |
| --- | --- |
| `open`, `claim`, `tabs` | New background tab with a URL; take over one of the user's tabs; list both. |
| `navigate`, `back`, `forward`, `reload`, `close` | Tab navigation through the tabs API; `close` only closes tabs the agent opened. |
| `keep` | Keep a tab after the turn (`deliverable`, or `handoff` to continue later). |
| `show` | Bring the tab forward (only when the user wants to watch). |
| `snapshot`, `screenshot` | Page snapshot; `Page.captureScreenshot` of the tab. |
| `click`, `hover`, `type`, `key`, `scroll`, `select` | CDP `Input.*` events at the element (by `ref`, `selector`, `name` or `x`/`y`); `type` uses `Input.insertText`, takes `secret_env`, `clear`, and `format` html/markdown (dispatched as a paste event, no clipboard). `click` and `key` take `hold`. |
| `drag` | Trusted HTML5 drag-and-drop: `Input.setInterceptDrags`, then `Input.dispatchDragEvent` at the target; a pointer drag when the source is not draggable; `drag_method: "js"` for a synthetic DataTransfer drag. |
| `wait` | `url` fragment, `load` state, `selector`; every action also takes `wait_for` text. |
| `dialog` | Accept or dismiss a JS `alert`/`confirm`/`prompt` (reported by any action while open). |
| `upload` | `DOM.setFileInputFiles` on a file input, or intercepts the file chooser a button opens. |
| `download` | Optionally clicks, then waits for the next download to finish and reports its path. |
| `evaluate` | Runs JavaScript in the page and returns its JSON value. |

## Background behaviour

Nothing here activates Chrome: tab creation is `active: false`, navigation goes through `chrome.tabs.update`, and
input is CDP events to the renderer. The tab is not selected, so the user's visible tab does not change; the new
tab and the `OCU` group appear in the tab strip of Chrome's last focused window. Chrome shows its "started
debugging this browser" bar while the debugger is attached; the extension detaches at turn end.

## Install

`open-computer-use browser-setup` registers the native host for the installed binary and copies the extension to
`~/Library/Application Support/OpenComputerUse/BrowserExtension`; load that folder with **Load unpacked** in
`chrome://extensions` (Developer mode). See the extension README for removal.
