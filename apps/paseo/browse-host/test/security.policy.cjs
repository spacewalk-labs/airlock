// SPDX-License-Identifier: Apache-2.0
"use strict";
// Locks the PROPORTIONATE url policy (owner-only tool): loopback / RFC1918 /
// tailnet are ALLOWED (browsing one's own dev servers is the point); only cloud-
// metadata / link-local / multicast / non-http(s) are blocked. Network-free.
// Run: node test/security.policy.cjs
const sec = require("../src/security.js");

let passed = 0, failed = 0;
function ck(name, cond, detail) {
  if (cond) { passed++; console.log(`  ok  ${name}`); }
  else { failed++; console.log(`FAIL  ${name}${detail ? " :: " + detail : ""}`); }
}

(async () => {
  // Allowed: the owner's own localhost / internal / tailnet + public.
  for (const u of [
    "http://localhost:3000", "http://127.0.0.1:8080", "http://10.0.0.5",
    "http://192.168.1.5", "http://172.16.0.9:7700", "https://example.com",
  ]) {
    let ok = true, msg = "";
    try { await sec.assertUrlAllowed(u); } catch (e) { ok = false; msg = e.message; }
    ck("allow " + u, ok, msg);
  }
  // Blocked: cloud metadata / link-local / multicast / non-http.
  for (const u of [
    "http://169.254.169.254/latest/meta-data/", "http://169.254.1.1/",
    "http://224.0.0.1/", "ftp://host/x",
  ]) {
    let denied = false;
    try { await sec.assertUrlAllowed(u); } catch (e) { denied = e.code === "browser_denied"; }
    ck("block " + u, denied);
  }
  // Sub-request guard: abort metadata, allow private (internal pages load).
  ck("subreq abort metadata", sec.shouldAbortSubRequest("http://169.254.169.254/x") === true);
  ck("subreq allow private", sec.shouldAbortSubRequest("http://10.0.0.5/img") === false);
  ck("subreq allow loopback", sec.shouldAbortSubRequest("http://127.0.0.1/a") === false);

  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
