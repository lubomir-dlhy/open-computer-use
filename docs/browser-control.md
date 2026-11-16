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
- `BrowserBridge.swift`: Chrome starts one host per profile, so the bridge keeps one socket per profile; session
  id `ocu-<pid>-<session>`. A call goes to the profile that owns its tab, else the `profile` argument, else the
  profile of the session's current tab, else the default profile. At turn end it calls `finalizeTabs` in every
  profile: tabs the agent opened close, claimed user tabs are released (ungrouped), kept tabs stay. On connect it
  finalizes sessions whose process has exited.
- `BrowserProfiles.swift`: tells which profile a connection is. The extension keeps a random token in
  `chrome.storage.local` and returns it from `getInfo`; the bridge finds the profile folder whose
  `Local Extension Settings/<id>` holds it, then reads the name and email from Chrome's `Local State`. This works
  for profiles that are not signed in.
- `BrowserTool.swift` / `BrowserPageScript.swift`: actions. A page script (installed once per document) renders a
  snapshot of `[ref] role "name" state` lines plus visible text; refs stay stable for an element's lifetime, so
  actions return a diff (`~` changed, `+` added, `-` removed), the full snapshot after a navigation.
  A control with no name, or with the same role and name as an earlier one, gets a `hint="…"`: its icon (SVG
  title, `<use>` id or icon class), image file, `data-testid`, `name` or a hand-written `id`, and for a repeated name
  the text of its row (`tr`, `li`, `[role=row]`, …) unless that text is already among the four lines above.

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

## Profiles

The `profile` argument (on `open` and `tabs`; `cua.browser.open(url, { profile })` in `js`) takes a profile's name,
email or folder. Its schema description lists the profiles that have the extension, with the user's notes and the
default, so an agent picks the profile that matches the task's account without a lookup call. `tabs` lists tabs per
profile and names installed profiles that are not running.

`~/Library/Application Support/OpenComputerUse/browser-profiles.json` holds the default and the notes:

```json
{
  "default": "me@gmail.com",
  "notes": { "me@work.com": "Work: company Google Workspace, Jira" }
}
```

`OPEN_COMPUTER_USE_BROWSER_PROFILE` overrides the default. Without either, a call with no tab and no profile goes to
the first connected profile.

A profile's extension runs only while Chrome has the profile loaded. The manifest asks for the `background`
permission, so Chrome keeps such profiles loaded with no window open and loads them at startup. A profile that is
not running yet (installed but never opened since Chrome started) needs one window opened by the user; opening
one programmatically brings Chrome forward, so the bridge reports it instead. Reloading the extension drops that
hold, so Chrome unloads windowless profiles; reload while each profile has a window open. A tab opened in a
profile with no window gets a new window, minimised right away so it never covers the user's windows (Chrome on
macOS ignores `state: "minimized"` in `windows.create`).

A call with no `tab` and no `profile` follows the session's current tab, except `open`, which goes to the default
profile.

## Background behaviour

Nothing here activates Chrome: tab creation is `active: false`, navigation goes through `chrome.tabs.update`, and
input is CDP events to the renderer. The tab is not selected, so the user's visible tab does not change; the new
tab and the `OCU` group appear in the tab strip of Chrome's last focused window. Chrome shows its "started
debugging this browser" bar while the debugger is attached; the extension detaches at turn end.

## Install

`open-computer-use browser-setup` registers the native host for the installed binary and copies the extension to
`~/Library/Application Support/OpenComputerUse/BrowserExtension`; load that folder with **Load unpacked** in
`chrome://extensions` (Developer mode), once in each profile that should be reachable. See the extension README for
removal.
