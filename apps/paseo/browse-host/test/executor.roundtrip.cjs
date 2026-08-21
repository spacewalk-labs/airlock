// SPDX-License-Identifier: MIT
"use strict";
// Direct round-trip test of the executor against real Chromium (no daemon).
// Validates command handlers + ref loop + response payload shapes.
// Run: node test/executor.roundtrip.cjs   (needs a resolvable 'playwright')

const path = require("node:path");
const { BrowserHostExecutor } = require("../src/executor.js");
const security = require("../src/security.js");

// Test URL policy: allow data: setup pages, but still enforce the REAL private-IP
// guard for everything else (so the metadata-block assertion is genuine).
const testUrlPolicy = {
  assertUrlAllowed: async (u) => {
    if (String(u).startsWith("data:")) return new URL(u);
    return security.assertUrlAllowed(u);
  },
  shouldAbortSubRequest: security.shouldAbortSubRequest,
};

// Resolve playwright: prefer local dep, fall back to the @playwright/mcp bundle
// available on dev-box for local dev testing.
function loadChromium() {
  const candidates = [
    "playwright",
    process.env.PASEO_PLAYWRIGHT_PATH,
  ];
  for (const c of candidates) {
    try { return require(c).chromium; } catch {}
  }
  throw new Error("playwright not resolvable");
}

const PAGE = `data:text/html,${encodeURIComponent(
  `<!doctype html><title>RT</title><body>
   <h1>Round Trip</h1>
   <button onclick="document.title='CLICKED'">Press</button>
   <input placeholder="name">
   <p id="late"></p>
   <script>setTimeout(()=>{document.getElementById('late').textContent='ready-marker'},300)</script>
   </body>`,
)}`;

let passed = 0;
let failed = 0;
function check(name, cond, detail) {
  if (cond) { passed++; console.log(`  ok  ${name}`); }
  else { failed++; console.log(`FAIL  ${name}${detail ? " :: " + detail : ""}`); }
}

(async () => {
  const chromium = loadChromium();
  const exec = new BrowserHostExecutor({
    log: (m) => process.env.VERBOSE && console.log("[exec]", m),
    launchChromium: () => chromium.launch({ headless: true, args: ["--no-sandbox"] }),
    urlPolicy: testUrlPolicy,
  });

  const req = (command, args = {}, workspaceId = "ws1") => ({
    requestId: "req_" + Math.random().toString(36).slice(2),
    workspaceId,
    command: { command, args },
  });

  // new_tab
  let r = await exec.execute(req("new_tab", { url: PAGE }));
  check("new_tab ok", r.ok, JSON.stringify(r.error));
  check("new_tab has browserId", r.ok && /^[0-9a-f-]{36}$/.test(r.result.browserId));
  check("new_tab workspaceId", r.ok && r.result.workspaceId === "ws1");
  const bid = r.ok ? r.result.browserId : null;

  // snapshot + ref format
  r = await exec.execute(req("snapshot", { browserId: bid }));
  check("snapshot ok", r.ok, JSON.stringify(r.error));
  check("snapshot format aria-yaml", r.ok && r.result.format === "aria-yaml");
  check("snapshot emits @e refs", r.ok && /\[ref=@e\d+\]/.test(r.result.snapshot), r.ok ? r.result.snapshot.slice(0, 120) : "");
  check("snapshot stats.refCount>0", r.ok && r.result.stats.refCount > 0);
  const snap = r.ok ? r.result.snapshot : "";
  const btnRef = (snap.match(/button[^\n]*\[ref=(@e\d+)\]/) || [])[1];
  const inpRef = (snap.match(/textbox[^\n]*\[ref=(@e\d+)\]/) || [])[1];
  check("found button ref", Boolean(btnRef), snap.slice(0, 200));

  // click via ref -> changes title
  r = await exec.execute(req("click", { browserId: bid, ref: btnRef }));
  check("click ok", r.ok, JSON.stringify(r.error));
  r = await exec.execute(req("snapshot", { browserId: bid }));
  check("title changed after click", r.ok && r.result.title === "CLICKED", r.ok ? r.result.title : "");

  // fill via ref
  r = await exec.execute(req("fill", { browserId: bid, ref: inpRef, value: "hello-world" }));
  check("fill ok", r.ok, JSON.stringify(r.error));

  // screenshot
  r = await exec.execute(req("screenshot", { browserId: bid, fullPage: false }));
  check("screenshot ok", r.ok, JSON.stringify(r.error));
  check("screenshot png base64", r.ok && r.result.mimeType === "image/png" && r.result.dataBase64.length > 100);

  // wait for text
  r = await exec.execute(req("wait", { browserId: bid, text: "ready-marker" }));
  check("wait text matched", r.ok && r.result.matched === "text", JSON.stringify(r.error));

  // navigate (allowed) + SSRF (denied)
  r = await exec.execute(req("navigate", { browserId: bid, url: "https://example.com/" }));
  check("navigate example.com ok", r.ok, JSON.stringify(r.error));
  r = await exec.execute(req("navigate", { browserId: bid, url: "http://169.254.169.254/latest/" }));
  check("navigate metadata denied", !r.ok && r.error.code === "browser_denied", JSON.stringify(r));

  // stale ref: after navigate, the old button ref should not resolve
  r = await exec.execute(req("click", { browserId: bid, ref: btnRef }));
  check("stale ref -> browser_stale_ref", !r.ok && r.error.code === "browser_stale_ref", JSON.stringify(r.error));

  // list_tabs
  r = await exec.execute(req("list_tabs", {}));
  check("list_tabs ok", r.ok && r.result.tabs.length === 1, JSON.stringify(r));

  // workspace boundary: a tab is not addressable from another workspace.
  const w2 = await exec.execute(req("new_tab", { url: PAGE }, "ws2"));
  const w2bid = w2.ok ? w2.result.browserId : null;
  check("workspace mismatch -> browser_tab_not_found", (await exec.execute(req("snapshot", { browserId: bid }, "ws2"))).error?.code === "browser_tab_not_found");
  r = await exec.execute(req("list_tabs", {}, "ws1"));
  check("list_tabs excludes other workspace", r.ok && !r.result.tabs.some((t) => t.browserId === w2bid));
  if (w2bid) await exec.execute(req("close_tab", { browserId: w2bid }, "ws2"));

  // unsupported command -> browser_unsupported
  r = await exec.execute(req("evaluate", { browserId: bid, function: "()=>1" }));
  check("unsupported -> browser_unsupported", !r.ok && r.error.code === "browser_unsupported", JSON.stringify(r.error));

  // tab-not-found
  r = await exec.execute(req("snapshot", { browserId: "00000000-0000-4000-8000-000000000000" }));
  check("bad browserId -> browser_tab_not_found", !r.ok && r.error.code === "browser_tab_not_found");

  // close_tab
  r = await exec.execute(req("close_tab", { browserId: bid }));
  check("close_tab ok", r.ok, JSON.stringify(r.error));
  r = await exec.execute(req("list_tabs", {}));
  check("list_tabs empty after close", r.ok && r.result.tabs.length === 0);

  await exec.shutdown();
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error("FATAL", e); process.exit(2); });
