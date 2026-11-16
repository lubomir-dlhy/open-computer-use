#!/usr/bin/env node
// Drives the browser tool end to end: the unpacked extension in Chrome for Testing (headless), the
// native host and an in-process MCP server, against a local fixture shop. Everything lives under a
// temporary home, so the user's Chrome and its native-host sockets are never touched.
//   node scripts/tests/browser-e2e-smoke.mjs [OpenComputerUse binary] [Chrome for Testing binary]
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

assert.equal(process.platform, "darwin", "browser e2e smoke requires macOS");
const root = fileURLToPath(new URL("../../", import.meta.url));
const nativePath = path.resolve(process.argv[2] ?? path.join(root, ".build/debug/OpenComputerUse"));
const chromePath = process.argv[3] ?? findChromeForTesting();
assert.ok(existsSync(nativePath), "Run swift build first");
assert.ok(chromePath && existsSync(chromePath), "Chrome for Testing not found; pass its binary path");

function findChromeForTesting() {
  const cache = path.join(homedir(), "Library/Caches/ms-playwright");
  if (!existsSync(cache)) return null;
  for (const dir of readdirSync(cache).filter((name) => /^chromium-\d+$/.test(name)).sort().reverse()) {
    const binary = path.join(cache, dir, "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing");
    if (existsSync(binary)) return binary;
  }
  return null;
}

const product = { name: "Trail Shoe", sku: "TS-42", price: "89.90", currency: "EUR" };
const pages = {
  "/product": `<!doctype html><title>Trail Shoe</title>
<script type="application/ld+json">${JSON.stringify({ "@context": "https://schema.org", "@type": "Product", name: product.name, sku: product.sku,
    brand: { "@type": "Brand", name: "Ridge" },
    offers: { "@type": "Offer", price: product.price, priceCurrency: product.currency, availability: "https://schema.org/InStock" } })}</script>
<script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"sku":"TS-42","variants":3}}}</script>
<h1>Trail Shoe</h1><p id="price">89,90 €</p><section id="stock"><p>Checking stock…</p></section>
<button aria-label="Add to cart">+</button>
<script>setTimeout(async () => {
  const stock = await (await fetch("/api/stock?sku=TS-42")).json();
  document.querySelector("#stock").innerHTML = "<p>In stock: " + stock.quantity + " pairs</p>";
}, 300);</script>`,
  "/challenge": `<!doctype html><title>Just a moment...</title><div id="challenge-form">Checking your browser</div>`,
};
const server = createServer((request, response) => {
  const url = new URL(request.url, "http://localhost");
  if (url.pathname === "/old-product") { response.writeHead(301, { location: "/product" }); response.end(); return; }
  if (url.pathname === "/api/stock") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ sku: url.searchParams.get("sku"), quantity: 7, warehouse: "BTS" }));
    return;
  }
  const page = pages[url.pathname];
  response.writeHead(page ? 200 : 404, { "content-type": "text/html; charset=utf-8" });
  response.end(page ?? "<!doctype html><title>Not found</title><h1>Gone</h1>");
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const base = `http://127.0.0.1:${server.address().port}`;

// Short: the host socket path must stay under the 104-byte Unix socket limit.
const temp = mkdtempSync("/tmp/ocu-e2e-");
const home = path.join(temp, "home");
const profile = path.join(temp, "chrome");
mkdirSync(path.join(profile, "NativeMessagingHosts"), { recursive: true });
writeFileSync(path.join(profile, "NativeMessagingHosts", "sk.lubomirdlhy.opencomputeruse.browser.json"), JSON.stringify({
  name: "sk.lubomirdlhy.opencomputeruse.browser", description: "Open Computer Use Browser (e2e)", path: nativePath, type: "stdio",
  allowed_origins: ["chrome-extension://lljfcieajkdnodcjjgfonlfjpnloecbo/"],
}));
const env = { ...process.env, HOME: home, CFFIXED_USER_HOME: home, OPEN_COMPUTER_USE_DISABLE_APP_AGENT_PROXY: "1", OPEN_COMPUTER_USE_VISUAL_CURSOR: "0" };
const chrome = spawn(chromePath, [
  // Without the mock keychain the network stack waits on the login keychain, which the temporary home lacks.
  "--headless=new", "--use-mock-keychain", `--user-data-dir=${profile}`, `--load-extension=${path.join(root, "apps/OpenComputerUseBrowserExtension")}`,
  "--no-first-run", "--no-default-browser-check", "--disable-search-engine-choice-screen", "about:blank",
], { env, stdio: "ignore" });

// The extension starts the native host once its service worker runs; its socket means Chrome is reachable.
const sockets = path.join(home, "Library/Application Support/OpenComputerUse/Browser");
for (let waited = 0; !(existsSync(sockets) && readdirSync(sockets).some((name) => name.endsWith(".sock"))); waited += 100) {
  assert.ok(waited < 20_000, "the extension never started the native host");
  await new Promise((resolve) => setTimeout(resolve, 100));
}
const mcp = spawn(nativePath, ["mcp"], { env, stdio: ["pipe", "pipe", "inherit"] });
let buffered = "";
const waiting = new Map();
mcp.stdout.on("data", (data) => {
  buffered += data;
  let newline;
  while ((newline = buffered.indexOf("\n")) >= 0) {
    const message = JSON.parse(buffered.slice(0, newline));
    buffered = buffered.slice(newline + 1);
    waiting.get(message.id)?.(message);
  }
});
let nextID = 1;
function request(method, params) {
  const id = nextID++;
  mcp.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  return new Promise((resolve) => waiting.set(id, resolve));
}
async function browser(args) {
  const response = await request("tools/call", { name: "browser", arguments: args });
  const text = response.result?.content?.map((item) => item.text ?? "").join("\n") ?? JSON.stringify(response);
  if (response.result?.isError) throw new Error(`${args.action}: ${text}`);
  return text;
}

try {
  await request("initialize", { protocolVersion: "2025-03-26", clientInfo: { name: "e2e", version: "1" }, capabilities: {} });
  const opened = await browser({ action: "open", url: `${base}/old-product` });
  console.log(opened.split("\n").slice(0, 3).join("\n"));
  assert.match(opened, /HTTP 200, redirected from .*\/old-product \(301\)/);

  const extracted = await browser({ action: "extract" });
  console.log(extracted.split("\n")[0]);
  assert.match(extracted.split("\n")[0], /^Product "Trail Shoe", 89\.90 EUR \(InStock\), sku TS-42, brand Ridge$/);
  assert.match(extracted, /Embedded JSON .*script#__NEXT_DATA__/);
  assert.match(await browser({ action: "extract", selector: "script#__NEXT_DATA__" }), /"variants":3/);

  const idle = await browser({ action: "wait", load: "networkidle", wait_for: "In stock" });
  assert.match(idle, /In stock: 7 pairs/);
  const requests = await browser({ action: "requests" });
  console.log(requests);
  const stockID = /^(r\d+) GET 200 fetch application\/json .*\/api\/stock\?sku=TS-42$/m.exec(requests)?.[1];
  assert.ok(stockID, "the stock API call is listed");
  assert.match(requests, /^r\d+ GET 301 document \/old-product → redirect$/m);
  const body = await browser({ action: "requests", request: stockID });
  assert.match(body, /"quantity":7/);
  assert.match(await browser({ action: "requests", filter: "stock" }), /\/api\/stock/);

  const found = await browser({ action: "snapshot", find: "in stock|€" });
  console.log(found);
  assert.match(found, /2 lines match "in stock\|€":/);
  assert.match(found, /In stock: 7 pairs/);
  const cartRef = /\[(\d+)\] button "Add to cart"/.exec(await browser({ action: "snapshot" }))[1];
  const scoped = await browser({ action: "snapshot", ref: Number(cartRef) });
  assert.match(scoped, new RegExp(`Within \\[${cartRef}\\]:\\n\\[${cartRef}\\] button "Add to cart"$`));

  assert.match(await browser({ action: "navigate", url: `${base}/discontinued` }), /^HTTP 404/m);
  const blocked = await browser({ action: "navigate", url: `${base}/challenge` });
  assert.match(blocked, /Bot check: Cloudflare challenge/);
  console.log("browser e2e smoke passed");
} finally {
  mcp.kill();
  chrome.kill();
  server.close();
  await new Promise((resolve) => setTimeout(resolve, 300));
  rmSync(temp, { recursive: true, force: true });
}
