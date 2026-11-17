---
name: open-computer-use
description: Platform-neutral guidance for using Open Computer Use, the open-source Computer Use MCP server and CLI for macOS, Linux, and Windows. Use when an agent needs to install, verify, troubleshoot, configure, or operate Open Computer Use through its native CLI, stdio MCP server, or direct Computer Use tool calls.
---

# Open Computer Use

## Overview

Open Computer Use exposes Computer Use as a local CLI and stdio MCP server. It is not Codex.app-specific; adapt the commands and MCP config to the agent runtime you are operating in.

The macOS runtime requires macOS 14.0 or later. Windows and Linux use their own platform runtimes and are not subject to this macOS minimum.

It supports the same core tool surface across macOS, Linux, and Windows:
`list_apps`, `get_app_state`, `click`, `perform_secondary_action`, `scroll`,
`drag`, `type_text`, `press_key`, and `set_value`.

The macOS runtime additionally implements `select_text`, which selects the given text inside a text
element or places the text cursor before / after it (`selection`: `text`, `cursor_before`,
`cursor_after`). Pass `text` exactly as it appears in the accessibility tree, plus `prefix` /
`suffix` when it is not unique; an ambiguous target fails closed instead of silently selecting the
first match. JavaScript exposes `app.selectText(elementIndex, text, options?)`. Unreadable or mismatched range verification throws, including when full action read-back is off. Windows and Linux runtimes do not implement this tool yet.

macOS additionally exposes `query`: a targeted accessibility lookup that finds
controls by text and/or role without rendering a tree or taking a screenshot.

## Core Workflow

1. On macOS, run `sw_vers -productVersion` before invoking the CLI and require macOS 14.0 or later. On older versions, explain that the runtime cannot launch; do not recommend `doctor` or permission changes as a fix for binary incompatibility.
2. Check the CLI is installed with `open-computer-use -h` or `ocu -h`. If installation or setup is missing, read [references/installation.md](references/installation.md).
3. On supported macOS versions, run `open-computer-use doctor` before the first real GUI task. If permissions are missing, ask the user to approve Accessibility and Screen Recording in the onboarding UI.
4. Inspect available apps before acting: `open-computer-use call list_apps`.
5. Capture current UI state with `open-computer-use call get_app_state --args '{"app":"TextEdit"}'`. The default state is usually enough for UI operation.
6. When the task needs longer semantic text, such as chat history, email bodies, document text, or long form content, call `get_app_state` with `text_limit: 1000` or `text_limit: "max"`.
7. When visible long pages or lists appear incomplete even after scrolling, call `get_app_state` with a larger `max_tree_nodes` or `max_tree_depth`.
8. Prefer element-targeted actions using `element_index` from the latest `get_app_state` result.
9. For multi-step CLI work, use `open-computer-use call --calls '<json-array>'` so one process can reuse the latest element index mapping.
10. For agent runtimes that support local MCP servers, configure `open-computer-use mcp` or `ocu mcp` and call the exposed Computer Use tools directly. Read [references/usage.md](references/usage.md).
11. For direct code-first orchestration, run `ocu capabilities` and then use one-shot `ocu js` or persistent `ocu repl`. Read [references/usage.md](references/usage.md).
12. If communication, permission, or desktop-session access fails, read [references/troubleshooting.md](references/troubleshooting.md).

## Operating Rules

- Treat the target desktop as the user's real session. Do not inspect password managers, unrelated private content, or sensitive apps unless the user explicitly asked for that task.
- Ask before sending, deleting, purchasing, approving, uploading, or making other externally visible changes.
- Do not assume Codex.app plugin helpers are available. Use the installed `open-computer-use` / `ocu` CLI or an explicit MCP config.
- Use indexes returned by `get_app_state` or macOS `query` in the same native session; do not guess indexes across sessions or after large UI changes.
- Prefer semantic actions and `set_value` for editable controls. Use coordinate `click`, `scroll`, and `drag` only when the element tree does not expose a safer target.
- On macOS, do not enable `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1` unless the user explicitly requested `click_method: "global"`, a `drag` that must drive a window-server drag session (window move, drag-select text, Finder drag-and-drop), or other diagnostic behavior that may move the real pointer. Without it `drag` reports `Drag delivered via app_post` and those operations have no effect; see `references/usage.md` for alternatives.
- On macOS, keep every interaction in the background: never raise, activate or un-minimize the user's windows, and avoid app shortcuts that bring a window forward (Chrome `cmd+l`). Prefer `sky_click`, `drag_method: "sky"` and `sky_key` for Chromium/Electron. See "Staying in the Background" in `references/usage.md`.
- On Windows and Linux, confirm the command is running inside the logged-in desktop session before assuming GUI automation is available.

## Background Recipes (macOS)

Work without bringing apps forward or touching the user's windows:

- **Menus:** `click` with `menu_path`, e.g. `{"app": "Google Chrome", "menu_path": ["File", "New window"]}`, presses a
  menu bar item without opening the menu. Titles are case-insensitive and a unique prefix is enough
  (`["File", "Compress"]` in Finder). Use `["Apple", "About This Mac"]` for the Apple menu. Do not click menu bar
  items to open them; an open menu covers the user's screen and captures their typing.
- **Chrome: use the `browser` tool first.** When the Open Computer Use Browser extension is installed it drives
  Chrome tabs through the debugger, entirely in the background: Chrome never comes forward and no window is
  touched. `{"action":"open","url":...}` opens a background tab and returns a snapshot of `[ref] role "name"`
  lines; act with `click`/`hover`/`type`/`key`/`scroll`/`drag`/`select`/`upload` by `ref` (or `selector`, or
  `name`), and each action returns only what changed. `type` takes `secret_env` like `type_text`. `drag` does
  real HTML5 drag-and-drop. `wait` waits for `url`, `load` or `selector`; every action takes `wait_for`. A JS
  `alert`/`confirm` is reported; answer it with `{"action":"dialog","accept":true}`. `evaluate` runs JavaScript
  for reads; do not use it to change the page instead of acting on it. For prices, stock and other facts, read
  data before layout: `extract` (structured product data and embedded JSON), `requests` (the page's API calls;
  `request: "r12"` for a body), `snapshot` with `find`. Navigation results start with `HTTP <status>`; a
  `Bot check:` header means a challenge page, not the site: wait or ask the user. A check you will repeat for
  other inputs: do it once, `flow_save` it with `params` (the example values you used), then `flow_run` with new
  values; if a run fails, fall back to the page (flows are experimental). Tabs you open close when your turn
  ends: if the tab holds the result the user asked for (a submitted form, an opened page), call
  `{"action":"keep"}` before you finish. To work in a tab the user already has open, `tabs` then `claim`.
  Open tabs in the Chrome profile whose account the task belongs to: pass `profile` (the parameter lists the
  user's profiles, notes and default), e.g. an organisation's work in its profile, personal tasks in the default.
  If `browser` says Chrome is not connected, fall back to the window recipe below.
- **Your own browser window:** never reuse or click the user's tabs. Open a window with
  `menu_path: ["File", "New window"]`; Open Computer Use switches to it and stays on it. `set_value` the address bar,
  then `press_key` `Return`. Close it with its `close button` element when done (the File > Close Window menu item
  is disabled while the app is in the background).
- **Windows:** `get_app_state` lists the app's other windows; pass `window_id` to read a specific one. Later actions
  stay on that window.
- **Apps without a window:** `get_app_state` asks the app to show one in the background (on the agent display).
- **Context menus:** `click` with `element_index` and `"menu_item": "Mark as done"` opens that element's
  context menu and chooses the item in one step (a word of a label also works). A right-click
  (`"mouse_button": "right"`) on an element only lists the menu's items and closes it again, because an open
  menu captures the user's typing; then choose with `menu_item`.
- **Double-click and in-place editing:** `click` with `"click_count": 2` on an element index sends a real
  background double-click. To edit in place (e.g. a TodoMVC item), put the double-click, `press_key` `super+a`,
  `type_text` and `press_key` `Return` in one `batch`: between separate calls the editor loses focus and closes.
- **Lists and Finder:** clicking a row selects it; add `"modifiers": ["cmd"]` to add a row to the selection.
  Single clicks never open files; a double-click does. Finder works in the background when each operation is
  one `batch` (it keeps Finder's window focused for the whole sequence):
  - Rename: `[{"tool":"click","element_index":ROW,"click_method":"sky_click"}, {"tool":"press_key","key":"Return"},
    {"tool":"press_key","key":"super+a"}, {"tool":"type_text","text":"new-name.txt"}, {"tool":"press_key","key":"Return"}]`
  - Move into a folder shown in the same window: `[click FILE_ROW (sky_click), press super+c,
    click FOLDER_ROW (sky_click), press super+Down, press super+alt+v, press super+Up]`. The user's clipboard
    is restored afterwards.
  - Expand a folder row in list view: `[click ROW (sky_click), press Right]`.
  - Compress: select the files and press the menu bar item in the same batch, e.g. `[click ROW1 (sky_click),
    click ROW2 (sky_click, "modifiers": ["cmd"]), {"tool":"click","menu_path":["File","Compress"]}]`. Inside a
    batch Finder's menu bar commands are enabled and no menu is shown; prefer this to context menus, which pop up
    over the user's screen.
  Finder tags cannot be applied in the background yet; say so instead of retrying.
- **Popovers:** keys sent with the default method can close a transient popover; use `"key_method": "app_post"`
  for keys meant for a popover's field.
- **Keys:** `press_key` delivers through SkyLight while the app is in the background, so shortcuts and `Return`
  reach Chromium and AppKit menus. Do not force `click_method: "app_post"`/`"sky_click"` on elements that have an
  index; the default tries accessibility first.

## Cleaning Up (macOS)

Windows you open (File > New window, Get Info, an app Open Computer Use had to launch) are closed when your turn
ends, or when your session ends because you finished or failed. An app launched for you is quit once it has no
windows. When the task or the user needs a window to stay, such as "leave the article open", call
`get_app_state` with `"keep_window": true` on it. A window whose app asks to save changes is left open instead of
discarding work, so save or close documents yourself.

## Several Agents at Once (macOS)

Agents connected to the same Open Computer Use app work in parallel. Each claims what it acts on:

- **Apps that open more windows** (Chrome, Finder, TextEdit, Safari) are shared by window. Work in your own window
  (`menu_path: ["File", "New window"]`); a window another agent is using makes your action wait.
- **Apps with one main window** (System Settings, Calculator, Notes, About panels) are used by one agent at a time.
- An action on something another agent holds waits up to 30 s (`OPEN_COMPUTER_USE_LEASE_WAIT_SECONDS`), then fails
  with a message saying so; `get_app_state` notes it without waiting. A claim ends with the agent's turn or after
  120 s idle (`OPEN_COMPUTER_USE_LEASE_IDLE_SECONDS`). Override the classification with
  `OPEN_COMPUTER_USE_SINGLETON_APPS` / `OPEN_COMPUTER_USE_WINDOWED_APPS` (comma-separated names or bundle ids).

## Secrets (macOS)

When a password or other secret is provided as an environment variable of the Open Computer Use
process, never ask for or print its value. Pass the variable's name instead of the text:

- `type_text` with `{"app": "...", "secret_env": "MY_PASSWORD"}` types it into the focused field.
- `set_value` with `{"app": "...", "element_index": "4", "secret_env": "MY_PASSWORD"}` sets it.

Open Computer Use reads the value itself, and every later result shows `•••` in its place. By default
only names containing `PASSWORD`, `PASSCODE`, `PIN` or `OTP` are accepted; others must be listed in
`OPEN_COMPUTER_USE_SECRET_ENV` (comma-separated). Prefer `set_value` on the password field, then click
the form's submit button.

## Common CLI Actions

```sh
open-computer-use -h
ocu -h
ocu capabilities --json
ocu js 'nodeRepl.write(6 * 7)'
ocu repl
open-computer-use doctor
open-computer-use call list_apps
ocu call list_apps
open-computer-use call get_app_state --args '{"app":"TextEdit"}'
open-computer-use call get_app_state --args '{"app":"TextEdit","text_limit":1000}'
open-computer-use call get_app_state --args '{"app":"TextEdit","text_limit":"max"}'
open-computer-use call get_app_state --args '{"app":"Google Chrome","max_tree_nodes":3000,"max_tree_depth":96}'
open-computer-use call click --args '{"app":"TextEdit","element_index":"0"}'
open-computer-use call type_text --args '{"app":"TextEdit","text":"Hello from Open Computer Use"}'
```

For a short sequence that reuses state in one process:

```sh
open-computer-use call --calls '[
  {"tool":"get_app_state","args":{"app":"TextEdit"}},
  {"tool":"press_key","args":{"app":"TextEdit","key":"Return"}}
]'
```

## MCP Usage

For runtimes that can launch local MCP servers over stdio, use:

```toml
[mcp_servers.open_computer_use]
command = "open-computer-use"
args = ["mcp"]
```

Read [references/usage.md](references/usage.md) for JSON config examples, direct tool-call patterns, and platform notes.

## References

- [references/installation.md](references/installation.md): one-time CLI install, agent MCP install commands, and macOS permissions.
- [references/usage.md](references/usage.md): MCP config, direct CLI calls, sequencing, and platform behavior.
- [references/troubleshooting.md](references/troubleshooting.md): permission, desktop-session, app discovery, and action failures.
