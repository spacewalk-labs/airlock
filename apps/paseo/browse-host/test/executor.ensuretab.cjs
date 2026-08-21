// SPDX-License-Identifier: MIT
"use strict";
// Level 2 (§14.4) executor tests: ensureTab idempotency / concurrent dedupe /
// immutable workspace binding, and back/forward/reload commands.
// Run: node test/executor.ensuretab.cjs   (needs a resolvable 'playwright')

const { BrowserHostExecutor } = require("../src/executor.js");
const security = require("../src/security.js");

const testUrlPolicy = {
  assertUrlAllowed: async (u) => {
    if (String(u).startsWith("data:")) return new URL(u);
    return security.assertUrlAllowed(u);
  },
  shouldAbortSubRequest: security.shouldAbortSubRequest,
};

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

const PAGE = (t) => `data:text/html,${encodeURIComponent(`<!doctype html><title>${t}</title><h1>${t}</h1>`)}`;

let passed = 0, failed = 0;
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
    maxTabs: 4,
  });

  const ID = "11111111-2222-4333-8444-555555555555";

  // ── ensureTab create-on-demand ──────────────────────────────────────────
  const tab1 = await exec.ensureTab(ID, "wsA", PAGE("Alpha"));
  check("ensureTab creates tab", !!tab1 && tab1.browserId === ID);
  check("ensureTab bound to workspace", tab1.workspaceId === "wsA");
  check("ensureTab navigated to initial url", (tab1.page.url() || "").startsWith("data:"));
  check("tabs size 1 after ensureTab", exec.countTabs() === 1);

  // ── idempotent: same id returns the SAME tab object ─────────────────────
  const tab2 = await exec.ensureTab(ID, "wsA");
  check("ensureTab idempotent (same object)", tab2 === tab1);
  check("no extra tab created", exec.countTabs() === 1);

  // ── concurrent dedupe: many parallel ensureTab → one page ───────────────
  const ID2 = "99999999-8888-4777-8666-555555555555";
  const results = await Promise.all(
    Array.from({ length: 8 }, () => exec.ensureTab(ID2, "wsA", PAGE("Beta"))),
  );
  const allSame = results.every((t) => t === results[0]);
  check("concurrent ensureTab dedupes to one tab", allSame);
  check("only one page for concurrent id", exec.countTabs() === 2, `size=${exec.countTabs()}`);

  // ── immutable binding: same id, different workspace → denied ────────────
  let bindErr = null;
  try { await exec.ensureTab(ID, "wsDIFFERENT"); } catch (e) { bindErr = e; }
  check("rebind to other workspace rejected", !!bindErr && bindErr.code === "browser_denied", bindErr && bindErr.code);

  // ── getTab ──────────────────────────────────────────────────────────────
  check("getTab returns the tab", exec.getTab(ID) === tab1);
  check("getTab unknown -> null", exec.getTab("00000000-0000-4000-8000-000000000000") === null);

  // ── back / forward / reload on an ensureTab'd page ──────────────────────
  // navigate Alpha->Gamma, back to Alpha, forward to Gamma, reload.
  let r = await exec.execute({ requestId: "n1", workspaceId: "wsA", command: { command: "navigate", args: { browserId: ID, url: PAGE("Gamma") } } });
  check("navigate ok", r.ok, JSON.stringify(r.error));
  const gammaUrl = r.ok ? r.result.url : "";

  r = await exec.execute({ requestId: "b1", workspaceId: "wsA", command: { command: "back", args: { browserId: ID } } });
  check("back ok", r.ok, JSON.stringify(r.error));
  check("back returned to prior page", r.ok && r.result.url !== gammaUrl && /Alpha/.test(decodeURIComponent(r.result.url)));

  r = await exec.execute({ requestId: "f1", workspaceId: "wsA", command: { command: "forward", args: { browserId: ID } } });
  check("forward ok", r.ok, JSON.stringify(r.error));
  check("forward returned to later page", r.ok && /Gamma/.test(decodeURIComponent(r.result.url)));

  r = await exec.execute({ requestId: "r1", workspaceId: "wsA", command: { command: "reload", args: { browserId: ID } } });
  check("reload ok", r.ok, JSON.stringify(r.error));

  // back/forward/reload advertised in the command set
  const { SUPPORTED_COMMANDS } = require("../src/commands.js");
  check("back/forward/reload advertised", ["back", "forward", "reload"].every((c) => SUPPORTED_COMMANDS.includes(c)));

  await exec.shutdown();
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
