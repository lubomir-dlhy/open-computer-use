#!/usr/bin/env node
// Runs the browser page script in headless Chrome and checks snapshot hints.
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";

const root = new URL("../../", import.meta.url).pathname;
const swift = readFileSync(join(root, "packages/OpenComputerUseKit/Sources/OpenComputerUseKit/BrowserPageScript.swift"), "utf8");
const script = swift.split('#"""')[1].split('"""#')[0];
const chrome = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const page = `<!doctype html><title>x</title>
<button><svg><title>Close dialog</title></svg></button>
<button><i class="fa fa-solid fa-trash"></i></button>
<button data-testid="settings-toggle"><span></span></button>
<a href="/"><img src="/static/logo-dark.png?v=3"></a>
<button id=":r7:"><svg><use href="#icon-share"></use></svg></button>
<button id="export-btn"></button>
<ul><li><span>Ann</span><span>Admin</span><div><button>Edit</button></div></li>
<li><span>Ben</span><span>Viewer</span><div><button>Edit</button></div></li></ul>
<div role="row"><p>Order 551 shipped</p><p>a</p><p>b</p><p>c</p><p>d</p><button>Track</button></div>
<div role="row"><p>Order 552 pending</p><p>a</p><p>b</p><p>c</p><p>d</p><button>Track</button></div>
<button>Unique</button>
<script>${script};document.title = JSON.stringify(window.__ocu.snapshot(4000).lines)</script>`;

const dir = mkdtempSync(join(tmpdir(), "ocu-hints-"));
writeFileSync(join(dir, "page.html"), page);
const dom = execFileSync(chrome, ["--headless=new", "--disable-gpu", `--user-data-dir=${join(dir, "profile")}`, "--dump-dom", `file://${join(dir, "page.html")}`], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
const title = dom.match(/<title>(.*?)<\/title>/s)[1].replace(/&quot;/g, '"').replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">");
const lines = JSON.parse(title);
const hinted = (pattern) => lines.find((line) => pattern.test(line));

assert.match(hinted(/^\[1\]/), /hint="icon Close dialog"/);
assert.match(hinted(/^\[2\]/), /hint="icon trash"/);
assert.match(hinted(/^\[3\]/), /hint="testid settings-toggle"/);
assert.match(hinted(/^\[4\] link/), /hint="image logo-dark.png"/);
assert.match(hinted(/^\[5\]/), /hint="icon share"$/);
assert.match(hinted(/^\[6\]/), /hint="id export-btn"/);
assert.ok(lines.filter((line) => line.includes('"Edit"')).every((line) => !line.includes("hint=")), "rows shown just above need no hint");
assert.deepEqual(lines.filter((line) => line.includes('"Track"')).map((line) => line.match(/hint="in \\"(Order \d+)/)?.[1]), ["Order 551", "Order 552"]);
assert.ok(lines.some((line) => /button "Unique"$/.test(line)));
console.log("browser snapshot hints smoke passed");
