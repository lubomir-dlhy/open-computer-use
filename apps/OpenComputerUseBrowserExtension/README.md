# Open Computer Use Browser

Chrome (MV3) extension that lets Open Computer Use drive Chrome tabs in the background through
`chrome.debugger`. It talks to the `open-computer-use` binary over native messaging
(`sk.lubomirdlhy.opencomputeruse.browser`); the binary relays to the MCP server's `browser` tool.

Extension ID: `lljfcieajkdnodcjjgfonlfjpnloecbo` (fixed by the public key in `manifest.json`).

Install:

1. `open-computer-use browser-setup` writes
   `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/sk.lubomirdlhy.opencomputeruse.browser.json`
   and copies this folder to `~/Library/Application Support/OpenComputerUse/BrowserExtension`.
2. In Chrome, in each profile Open Computer Use should reach: `chrome://extensions`, Developer mode on,
   **Load unpacked**, pick that folder (in the folder picker, Cmd+Shift+G and paste the path).

The `background` permission keeps a profile with the extension loaded while it has no window, so the agent can
open tabs in it. Reloading the extension (an upgrade) unloads such profiles; reload with a window open in each.

Remove: **Remove** on the extension's card in `chrome://extensions` of each profile, then delete the manifest above,
`~/Library/Application Support/OpenComputerUse/BrowserExtension` and
`~/Library/Application Support/OpenComputerUse/browser-profiles.json`.

Adapted from [open-browser-use](https://github.com/iFurySt/open-browser-use) (MIT, Copyright (c) 2026 Leo);
see `LICENSE.open-browser-use` and the repository's `THIRD_PARTY_NOTICES.md`.
