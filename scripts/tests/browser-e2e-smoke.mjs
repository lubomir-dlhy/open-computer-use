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

const catalog = { "TS-42": { name: "Trail Shoe", price: "89.90", quantity: 7 }, "TS-43": { name: "Road Shoe", price: "74.50", quantity: 3 } };
let stockShape = 1;
const productPage = (sku) => {
  const item = catalog[sku] ?? catalog["TS-42"];
  return `<!doctype html><title>${item.name}</title>
<script type="application/ld+json">${JSON.stringify({ "@context": "https://schema.org", "@type": "Product", name: item.name, sku,
    brand: { "@type": "Brand", name: "Ridge" },
    offers: { "@type": "Offer", price: item.price, priceCurrency: "EUR", availability: "https://schema.org/InStock" } })}</script>
<script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"sku":"TS-42","variants":3}}}</script>
<h1>${item.name}</h1><p id="price">${item.price.replace(".", ",")} €</p><section id="stock"><p>Checking stock…</p></section>
<button aria-label="Add to cart" onclick="fetch('/api/cart', { method: 'POST', body: JSON.stringify({ sku: '${sku}' }) })">+</button>
<script>setTimeout(async () => {
  const stock = await (await fetch("/api/stock?sku=${sku}")).json();
  document.querySelector("#stock").innerHTML = "<p>In stock: " + stock.quantity + " pairs</p>";
}, 300);</script>`;
};
const pages = {
  // The search API only answers requests the page signed for this load, so only a replay can run it.
  "/search": `<!doctype html><title>Search</title><input id="q" placeholder="Search shoes"><button id="go">Search</button><ul id="results"></ul>
<script>const sig = String(Math.random()).slice(2);
document.querySelector("#go").onclick = async () => {
  const q = document.querySelector("#q").value;
  const answer = await (await fetch("/api/search?q=" + encodeURIComponent(q), { headers: { "x-request-sig": sig } })).json();
  document.querySelector("#results").innerHTML = answer.results.map((r) => "<li>" + r.name + " " + r.price + "</li>").join("");
};</script>`,
  "/challenge": `<!doctype html><title>Just a moment...</title><div id="challenge-form">Checking your browser</div>`,
};
const server = createServer((request, response) => {
  const url = new URL(request.url, "http://localhost");
  if (url.pathname === "/old-product") { response.writeHead(301, { location: "/product?sku=TS-42" }); response.end(); return; }
  const json = (status, value) => { response.writeHead(status, { "content-type": "application/json" }); response.end(JSON.stringify(value)); };
  if (url.pathname === "/api/stock") {
    const sku = url.searchParams.get("sku");
    if (!catalog[sku]) { json(404, { error: "unknown sku" }); return; }
    json(200, stockShape === 1 ? { sku, quantity: catalog[sku].quantity, warehouse: "BTS" } : { item: sku, available: true });
    return;
  }
  if (url.pathname === "/api/search") {
    if (!request.headers["x-request-sig"]) { json(400, { error: "unsigned" }); return; }
    const q = (url.searchParams.get("q") ?? "").toLowerCase();
    json(200, { query: q, results: Object.entries(catalog).filter(([, item]) => item.name.toLowerCase().includes(q))
      .map(([sku, item]) => ({ sku, name: item.name, price: Number(item.price), stock: { quantity: item.quantity } })) });
    return;
  }
  if (url.pathname === "/api/cart") { json(200, { ok: true }); return; }
  if (url.pathname === "/product") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end(productPage(url.searchParams.get("sku") ?? "TS-42"));
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
], { env, stdio: "ignore", detached: true });

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
  // The redirect is in the network log when the debugger attached in time, else counted by the page.
  assert.match(opened, /HTTP 200, (redirected from .*\/old-product \(301\)|after 1 redirect)/);

  const extracted = await browser({ action: "extract" });
  console.log(extracted.split("\n")[0]);
  assert.match(extracted.split("\n")[0], /^Product "Trail Shoe", 89\.90 EUR \(InStock\), sku TS-42, brand Ridge$/);
  assert.match(extracted, /Embedded JSON .*script#__NEXT_DATA__/);
  assert.match(await browser({ action: "extract", selector: "script#__NEXT_DATA__" }), /"variants":3/);

  await browser({ action: "wait", load: "networkidle", wait_for: "In stock" });
  assert.match(await browser({ action: "snapshot", find: "in stock" }), /In stock: 7 pairs/);
  const requests = await browser({ action: "requests" });
  console.log(requests);
  const stockID = /^(r\d+) GET 200 fetch application\/json .*\/api\/stock\?sku=TS-42$/m.exec(requests)?.[1];
  assert.ok(stockID, "the stock API call is listed");
  if (/redirected from/.test(opened)) assert.match(requests, /^r\d+ GET 301 document \/old-product → redirect$/m);
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

  // Saved flows: a stock check through the page tier, product data from HTML, and a signed search by replay.
  await browser({ action: "open", url: `${base}/product?sku=TS-42` });
  await browser({ action: "wait", load: "networkidle", wait_for: "In stock" });
  const savedStock = await browser({ action: "flow_save", flow: "stock", params: { sku: "TS-42" }, description: "stock for a SKU" });
  console.log(savedStock);
  assert.match(savedStock, /Saved flow 127\.0\.0\.1\/stock .*GET .*\/api\/stock\?sku=\{\{sku\}\}/);
  const stock43 = await browser({ action: "flow_run", flow: "stock", params: { sku: "TS-43" } });
  console.log(stock43);
  assert.match(stock43, /^Flow 127\.0\.0\.1\/stock via page: HTTP 200\n.*"quantity":3/);
  assert.match(await browser({ action: "flow_run", flow: "stock", params: { sku: "TS-43" }, fields: "quantity" }), /\n\{"quantity":3\}$/);
  const unknown = await request("tools/call", { name: "browser", arguments: { action: "flow_run", flow: "stock", params: { sku: "XX-1" } } });
  assert.match(unknown.result.content[0].text, /not_found \(HTTP 404\)/);
  await assert.rejects(browser({ action: "flow_run", flow: "stock" }), /needs params sku/);
  // A value is encoded into the query, so it cannot move the request elsewhere.
  await assert.rejects(browser({ action: "flow_run", flow: "stock", params: { sku: "x&sku=TS-42/../@evil.example" } }), /not_found \(HTTP 404\)/);

  const savedPrice = await browser({ action: "flow_save", flow: "price", output: "extract", params: { sku: "TS-42" } });
  assert.match(savedPrice, /product data of .*\/product\?sku=\{\{sku\}\}/);
  assert.match(await browser({ action: "flow_run", flow: "price", params: { sku: "TS-43" } }), /Product "Road Shoe", 74\.50 EUR \(InStock\), sku TS-43/);

  await browser({ action: "click", name: "Add to cart" });
  const withWrite = await browser({ action: "flow_save", flow: "stock-after-cart", params: { sku: "TS-42" } });
  assert.match(withWrite, /Not replayable: the recording changed data on the site \(POST \/api\/cart\)/);
  const cartID = /^(r\d+) POST/m.exec(await browser({ action: "requests", type: "all", filter: "cart" }))?.[1];
  await assert.rejects(browser({ action: "flow_save", flow: "cart", output: cartID }), /may change data; flows only save reads/);

  const searchPage = await browser({ action: "open", url: `${base}/search` });
  assert.match(searchPage, /Saved flows for this site: .*stock\(sku\)/);
  const input = /\[(\d+)\] textbox "Search shoes"/.exec(searchPage)[1];
  await browser({ action: "type", ref: Number(input), text: "shoe" });
  await browser({ action: "click", name: "Search", wait_for: "Road Shoe" });
  const savedSearch = await browser({ action: "flow_save", flow: "search", params: { query: "shoe" } });
  console.log(savedSearch);
  assert.match(savedSearch, /list is at results/);
  const searched = await browser({ action: "flow_run", flow: "search", params: { query: "road" }, fields: "sku,price,stock.quantity" });
  console.log(searched);
  assert.match(searched, /via replay: HTTP 200/);
  assert.match(searched, /"items":\[\{"price":74\.5,"sku":"TS-43","stock\.quantity":3\}\]/);
  const filtered = await browser({ action: "flow_run", flow: "search", params: { query: "shoe" }, where: "name=trail", limit: 1 });
  assert.match(filtered, /"matched":1/);
  assert.match(filtered, /"total":2/);
  assert.match(await browser({ action: "flow_list" }), /127\.0\.0\.1\/search\(query\) — .*\[replay, verified/);

  stockShape = 2;
  await assert.rejects(browser({ action: "flow_run", flow: "stock", params: { sku: "TS-43" } }), /failed \(page: the answer changed shape \(missing quantity/);
  assert.match(await browser({ action: "flow_list" }), /stock\(sku\) — stock for a SKU \[page, unverified/);
  console.log("browser e2e smoke passed");
} finally {
  mcp.kill();
  // Chrome's helpers outlive a SIGTERM to the browser process; end the whole group.
  try { process.kill(-chrome.pid, "SIGKILL"); } catch {}
  server.close();
  await new Promise((resolve) => setTimeout(resolve, 300));
  rmSync(temp, { recursive: true, force: true });
}
