# Open Computer Use Browser

Chrome (MV3) extension that lets Open Computer Use drive Chrome tabs in the background through
`chrome.debugger`. It talks to the `open-computer-use` binary over native messaging
(`sk.lubomirdlhy.opencomputeruse.browser`); the binary relays to the MCP server's `browser` tool.

Extension ID: `lljfcieajkdnodcjjgfonlfjpnloecbo` (fixed by the public key in `manifest.json`).

Install:

1. `open-computer-use browser-setup` writes
   `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/sk.lubomirdlhy.opencomputeruse.browser.json`
   and copies this folder to `~/Library/Application Support/OpenComputerUse/BrowserExtension`.
2. In Chrome: `chrome://extensions`, Developer mode on, **Load unpacked**, pick that folder.

Remove: **Remove** on the extension's card in `chrome://extensions`, then delete the manifest above and
`~/Library/Application Support/OpenComputerUse/BrowserExtension`.

Adapted from [open-browser-use](https://github.com/iFurySt/open-browser-use) (MIT, Copyright (c) 2026 Leo);
see `LICENSE.open-browser-use` and the repository's `THIRD_PARTY_NOTICES.md`.
