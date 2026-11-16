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
| `snapshot`, `screenshot` | Page snapshot (`find`: only matching lines with a line of context; `ref`: only that element's part); `Page.captureScreenshot` of the tab. |
| `click`, `hover`, `type`, `key`, `scroll`, `select` | CDP `Input.*` events at the element (by `ref`, `selector`, `name` or `x`/`y`); `type` uses `Input.insertText`, takes `secret_env`, `clear`, and `format` html/markdown (dispatched as a paste event, no clipboard). `click` and `key` take `hold`. |
| `drag` | Trusted HTML5 drag-and-drop: `Input.setInterceptDrags`, then `Input.dispatchDragEvent` at the target; a pointer drag when the source is not draggable; `drag_method: "js"` for a synthetic DataTransfer drag. |
| `wait` | `url` fragment, `load` state (`networkidle`: nothing loading for 0.5 s), `selector`; every action also takes `wait_for` text. |
| `dialog` | Accept or dismiss a JS `alert`/`confirm`/`prompt` (reported by any action while open). |
| `upload` | `DOM.setFileInputFiles` on a file input, or intercepts the file chooser a button opens. |
| `download` | Optionally clicks, then waits for the next download to finish and reports its path. |
| `evaluate` | Runs JavaScript in the page and returns its JSON value. |
| `extract` | Structured data: one line per schema.org product (price, currency, availability, SKU/GTIN, brand) from JSON-LD, microdata or product meta tags, then the raw JSON-LD, meta and microdata; lists embedded JSON scripts (`__NEXT_DATA__`, …), which `selector` reads. |
| `requests` | The tab's network log: documents, XHR, fetch and JSON of the current page (`type` widens it, `filter` narrows by URL), `r<id>` each; `request: "r12"` returns that response's body. |

## Saved flows (experimental)

A task an agent repeats with other inputs (the stock of another SKU, the price of another product) can be saved
once and then run without driving the page. Adapted from agent-browser's saved flows (v0.42), for a tool that runs
in the user's own Chrome.

- **Recording** is always on: every replayable action in a tab (`open`, `navigate`, `back`, `forward`, `reload`,
  `click`, `hover`, `type`, `key`, `scroll`, `select`, `wait`) is kept with the network-log id it started after.
  A `ref` is turned into a selector unique on the page (id, `data-testid`, `name`, `aria-label`, `placeholder`,
  `href`, else an `nth-of-type` path) plus the element's name before the action runs. Coordinates make a step
  unreplayable.
- **`flow_save`** (`flow`, `params`, `output`, `description`) takes the steps since the tab's last `open` or
  `navigate`. `output` is the request that answers the task (`r12`), or `extract` for the page's product data;
  by default the JSON response from the site that used a param, else the largest. `params` maps names to the
  example values the recording used: they become `{{name}}` in the start URL, the output's URL path and query and
  body, and typed text, never in a host. Only reads are saved: GET, or GraphQL documents with no mutation. Other
  first-party requests in the range (telemetry aside) are listed as writes and the flow then never replays. Cookies
  and credential, CSRF, token and signature headers are never recorded. The answer's key paths (lists by their first
  items) and its largest list are stored. Files: `~/Library/Application Support/OpenComputerUse/flows/<site>/<name>.json`, mode 0600.
- **`flow_run`** (`flow`, `params`, `fields`, `where`, `limit`) tries the tier that worked last, then the other:
  - *page*: the request with `fetch` (credentials included) from a background tab on the site, opened at the start
    URL once per session and reused, so a loop over SKUs costs one fetch each. HTML outputs are parsed for product data.
  - *replay*: the recorded steps in a fresh background tab, then the matching request read from its network log.
  Values are URL-encoded into URLs and placed inside JSON strings in bodies; a rendered URL off the flow's site, or a
  query a value would turn into a mutation, is refused. 401/403 (`auth_expired`), 404/410 (`not_found`) and 429
  (`rate_limited`) end the run. An answer missing a quarter of the saved paths, or the list, has drifted: the next
  tier is tried, and the flow is marked unverified when none answers. `where` (`field=value`, substring),
  `fields` and `limit` apply to the saved list.
- **`flow_list`** lists flows (`url` narrows to a site); `open` and `navigate` mention a site's flows.

Not done: agent-browser's direct-HTTP tier (would need the browser's cookies and resolving only public addresses),
flows that write.

## Network log and page status

The extension attaches to a tab as `open` starts loading it (attaching to a tab Chrome has not given a renderer yet
stalls the debugger session) and before the navigation actions, and enables CDP `Network`, so the log holds the
page's requests; when it missed the main document, its status comes from the page's Navigation Timing entry. Per tab it keeps the last 400 requests (redirect hops included, with status, MIME
type, size and up to 2 KB of a request body) until the tab closes; bodies are read on demand with
`Network.getResponseBody` while the debugger is attached (it detaches at turn end). `open`, `navigate`, `back`,
`forward` and `reload` report the main document's `HTTP <status>` and any redirects. A snapshot whose page is a bot
check (Cloudflare, DataDome, PerimeterX, hCaptcha, reCAPTCHA, Akamai) says so in its header, so it is not read as
the site. Network idle counts requests still loading, except WebSockets, event streams and requests older than
10 s (long polls).

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
