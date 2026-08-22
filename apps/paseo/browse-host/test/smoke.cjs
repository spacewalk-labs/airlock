// SPDX-License-Identifier: Apache-2.0
"use strict";
// Network-free smoke of the executor against the installed Playwright/Chromium.
// Proves chromium launches, ai-mode snapshot yields @e refs, ref actions work,
// and the SSRF guard denies internal addresses. Used by smoke.sh as a deploy
// gate (catches a Playwright version without ariaSnapshot mode:"ai").
// Run from the install dir so `require("playwright")` resolves locally.

const { BrowserHostExecutor } = require("../src/executor.js");
const security = require("../src/security.js");

const testUrlPolicy = {
  assertUrlAllowed: async (u) => (String(u).startsWith("data:") ? new URL(u) : security.assertUrlAllowed(u)),
  shouldAbortSubRequest: security.shouldAbortSubRequest,
};

const PAGE = `data:text/html,${encodeURIComponent(
  `<title>Smoke</title><h1>hi</h1><button onclick="document.title='OK'">go</button><input placeholder="n">`,
)}`;

let failed = 0;
const check = (n, c, d) => { if (c) console.log("  ok  " + n); else { failed++; console.log("FAIL  " + n + (d ? " :: " + d : "")); } };

(async () => {
  let chromium;
  try { chromium = require("playwright").chromium; }
  catch (e) { console.log("FAIL  playwright not resolvable :: " + e.message); process.exit(1); }

  const exec = new BrowserHostExecutor({
    launchChromium: () => chromium.launch({ headless: true, args: ["--no-sandbox"] }),
    urlPolicy: testUrlPolicy,
  });
  const req = (command, args = {}) => ({ requestId: "s" + Math.random().toString(36).slice(2), workspaceId: "smoke", command: { command, args } });

  let r = await exec.execute(req("new_tab", { url: PAGE }));
  check("new_tab", r.ok, r.ok ? "" : JSON.stringify(r.error));
  const bid = r.ok ? r.result.browserId : null;

  r = await exec.execute(req("snapshot", { browserId: bid }));
  check("snapshot @e refs (mode:ai)", r.ok && /\[ref=@e\d+\]/.test(r.result.snapshot), r.ok ? r.result.snapshot.slice(0, 100) : JSON.stringify(r.error));
  const btn = r.ok ? (r.result.snapshot.match(/button[^\n]*\[ref=(@e\d+)\]/) || [])[1] : null;

  r = await exec.execute(req("click", { browserId: bid, ref: btn }));
  check("click via ref", r.ok, r.ok ? "" : JSON.stringify(r.error));

  r = await exec.execute(req("screenshot", { browserId: bid }));
  check("screenshot png", r.ok && r.result.mimeType === "image/png", r.ok ? "" : JSON.stringify(r.error));

  r = await exec.execute(req("logs", { browserId: bid, maxEntries: 1 }));
  check("logs round-trip", r.ok && r.result.command === "logs" && Array.isArray(r.result.console) && Array.isArray(r.result.network), JSON.stringify(r.error));

  r = await exec.execute(req("navigate", { browserId: bid, url: "http://169.254.169.254/" }));
  check("SSRF denied", !r.ok && r.error.code === "browser_denied", JSON.stringify(r));

  await exec.execute(req("close_tab", { browserId: bid }));
  await exec.shutdown();
  console.log(failed ? `\nSMOKE FAIL (${failed})` : "\nSMOKE OK");
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error("SMOKE FATAL", e); process.exit(2); });
