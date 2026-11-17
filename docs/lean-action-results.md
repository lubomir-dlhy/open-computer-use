# Lean action results (macOS)

macOS action tools (`click`, `drag`, `perform_secondary_action`, `press_key`, `scroll`, `select_text`, `set_value`, `type_text`) and the `batch` tool report what changed in the accessibility tree, not the whole tree. They no longer attach a screenshot by default. `get_app_state` is unchanged.

## Result format

```text
~ 9 checkbox Subscribe to newsletter Value: on
+ 250 heading Details panel (in 5)
+ 	251 text Details panel
- 17 text Drop zone (and 2 inside)
Focused: 2 text field Name, Value: Ada
```

- `~` is an element whose line changed, `+` an added element (`(in N)` names the parent of a new subtree; deeper lines are indented), and `-` the root of a removed subtree.
- `Window: "…"` appears when the target window changed. `Selected text:` or `Focused:` appears when it changed.
- `No accessibility tree change.` means the read-back matched the state the agent last saw.
- If the diff would be nearly as large as the tree (for example after a navigation), the whole tree is returned instead. Diffs longer than 150 entries are cut off with a pointer to `get_app_state`; removals keep up to a fifth of that space.

## Stable element indices

The diff compares against the state the agent last saw: the last `get_app_state`, or the last action result. Elements that are still present keep their index, matched by AX element identity. New elements get indices above any issued before, so an index is never reused for another control. `get_app_state` and `state:"full"` renumber the tree sequentially, as before.

## Per-call options

Every action tool, and `batch`, accepts:

| Argument | Meaning |
| --- | --- |
| `state` | `diff` (default), `full` (whole tree, the old result), or `none` (`ok`, no read-back). |
| `screenshot` | `true` attaches a window screenshot. Default `false`. |
| `wait_for` | Return once this text appears in the tree (case-insensitive). `!text` waits until it is gone. |
| `wait_timeout` | Seconds for `wait_for`, default 5, max 30. On timeout the result says the condition was not met; it is not an error. |

Coordinate actions after a read-back without a screenshot keep mapping onto the last screenshot the agent saw, as long as the target window and its size are unchanged.

## Batch

`batch` runs up to 50 action steps on one app in one call: `{"app": "…", "steps": [{"tool": "set_value", "element_index": "2", "value": "Ada"}, {"tool": "click", "element_index": "9"}]}`. Nothing is read between steps, so every index refers to the state before the batch. A step's own `wait_for` holds the next step until the condition is met. The batch stops at the first failing step, still reads the window back, and returns `isError` with `Ran N of M steps; step K (tool) failed: …` followed by the diff against the pre-batch state.

## Settling instead of fixed sleeps

The read-back no longer sleeps a fixed 100–150 ms. It reads the tree (AX only, no capture) every 30 ms until one of these holds:

- after a change, two consecutive reads agree, or a single read took over 120 ms (large trees), or 1.2 s have passed;
- nothing has changed for 150 ms;
- the `wait_for` condition holds, or its timeout expires.

The visual cursor no longer blocks the action. Moving to the target took about 1.45 s and the click pulse 0.18 s. Both ran synchronously before every element `click`, `set_value` and `select_text`. Animations now play on the main thread while the action and read-back proceed, one after another; a new move drops queued ones. Set `OPEN_COMPUTER_USE_VISUAL_CURSOR_BLOCKING=1` to wait for each animation as before.

## Compatibility

- `OPEN_COMPUTER_USE_ACTION_RESULT=full` restores the previous default for every call (whole tree plus screenshot). `none` returns `ok`.
- `OPEN_COMPUTER_USE_ACTION_READ_BACK=0` still returns `ok` without a read-back. The `js` REPL adapter no longer sets it: its actions return the diff to the script without showing it.
- Tool names are unchanged. `batch` is new. Descriptions are shorter and no longer end with "This tool is part of plugin `Computer Use`."
- Linux and Windows runtimes are unchanged and still return their existing results.

## Measurements

These numbers come from a scripted MCP bench on a release build. It uses the cua-eval `MCPClient` and its token estimate: chars/4, plus w×h/750 per image. The bench drives a private copy of the eval's AppKit fixture and a local web page in Safari, median of 5 rounds:

| Call | Before s | After s | Before tokens | After tokens |
| --- | --- | --- | --- | --- |
| fixture `click` | 2.00 | 0.27 | 784 | 11 |
| fixture `set_value` | 1.67 | 0.17 | 784 | 24 |
| fixture `press_key` | 0.23 | 0.28 | 784 | 21 |
| web `click` | 2.13 | 0.22 | 5080 | 28 |
| web `set_value` | 1.96 | 0.23 | 5080 | 7 |
| `batch` of 3 fixture steps | 3.90 (3 calls) | 0.45 | 2352 (3 calls) | 51 |

`tools/list` plus server instructions went from 3,604 to 3,083 estimated tokens, even with `batch` added and four result options on nine tools.

## Cheaper observation

- `get_app_state` attaches a screenshot only on first contact with a window in a session, or when the window's tree has fewer than 12 elements (too thin to act on). Otherwise it notes that the screenshot was skipped and keeps coordinate input working from the last capture of the same window at the same size. `include_screenshot: true` always captures, `false` never does; `OPEN_COMPUTER_USE_STATE_SCREENSHOT=always` restores the old default.
- `scroll` takes `x`/`y` in the last screenshot instead of `element_index`.
- `click` and `press_key` take `hold`: seconds the button or key stays down before release (up to 10).
- `type_text` with `paste: true` pastes through the app's own Paste (`format`: `text`, `html` or `markdown`, the last two as rich text) and puts the user's clipboard back afterwards. `secret_env` cannot be pasted.
