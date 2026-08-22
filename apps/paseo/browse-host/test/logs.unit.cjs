// SPDX-License-Identifier: Apache-2.0
"use strict";

const { BrowserHostExecutor, redactText, redactUrl } = require("../src/executor.js");
const security = require("../src/security.js");

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const policy = {
  assertUrlAllowed: async (url) => (String(url).startsWith("data:") ? new URL(url) : security.assertUrlAllowed(url)),
  shouldAbortSubRequest: security.shouldAbortSubRequest,
};
function loadChromium() {
  for (const c of ["playwright", process.env.PASEO_PLAYWRIGHT_PATH]) {
    try { return require(c).chromium; } catch {}
  }
  throw new Error("playwright not resolvable");
}

let passed = 0, failed = 0;
function check(name, condition, detail) {
  if (condition) { passed++; console.log(`  ok  ${name}`); }
  else { failed++; console.log(`FAIL  ${name}${detail ? ` :: ${detail}` : ""}`); }
}

(async () => {
  const chromium = loadChromium();
  const executor = new BrowserHostExecutor({
    launchChromium: () => chromium.launch({ headless: true, args: ["--no-sandbox"] }),
    urlPolicy: policy,
  });
  const tab = await executor.ensureTab("logs-unit", "logs-ws");
  const page = tab.page;
  await page.route("**/status*", (route) => route.fulfill({ status: 503, body: "failed" }));
  await page.route("**/abort", (route) => route.abort("failed"));
  await page.setContent(`<!doctype html><title>logs</title><script>
    console.error('Bearer super-secret-token apiKey: secret-value');
    console.warn('warning'); console.info('info'); console.debug('debug');
    throw new Error('uncaught failure');
  </script>`);
  await page.evaluate(async () => {
    await fetch('http://127.0.0.1/status?token=query-secret');
    try { await fetch('http://127.0.0.1/abort'); } catch {}
    try { await fetch('http://169.254.169.254/blocked'); } catch {}
  });
  await wait(300);

  const result = await executor.cmdLogs(tab, { maxEntries: 200 });
  const levels = result.console.map((entry) => entry.level);
  check("console levels mapped", ["error", "warning", "info", "debug"].every((level) => levels.includes(level)));
  check("pageerror captured", result.console.some((entry) => entry.level === "error" && /uncaught failure/.test(entry.message)));
  check("HTTP failure captured only", result.network.some((entry) => entry.status === 503) && !result.network.some((entry) => entry.status === 200));
  check("requestfailed captured in both rings", result.console.some((entry) => /network request failed/.test(entry.message)) && result.network.some((entry) => entry.status === undefined));
  check("SSRF requestfailed omitted", !result.network.some((entry) => entry.url.includes("169.254.169.254")) && !result.console.some((entry) => entry.message.includes("169.254.169.254")));
  check("console secrets redacted", !result.console.some((entry) => /super-secret|secret-value/.test(entry.message)) && result.console.some((entry) => entry.message.includes("<redacted>")));
  check("URL secrets redacted", !result.network.some((entry) => /query-secret/.test(entry.url)));
  check("redactUrl removes fragment and path secret", !redactUrl("https://example.test/token/0123456789abcdef0123#access_token=fragment-secret").includes("fragment-secret") && !redactUrl("https://example.test/token/0123456789abcdef0123#access_token=fragment-secret").includes("0123456789abcdef0123"));
  check("redactText caps and redacts bearer", redactText("Bearer abcdef apiKey: value").includes("Bearer <redacted>") && redactText("!".repeat(2000)).length === 1024);
  check("redactUrl strips userinfo", !redactUrl("https://alice:hunter2pw@example.test/x").includes("hunter2pw"));
  check("redactUrl redacts base64url token in path and query", (() => {
    const jwt = "eyJhbGciOiJIUzI1NiJ9-Ab_Cd-Ef_Gh-Ij_Kl-Mn_Op";
    const out = redactUrl(`https://x.test/api/${jwt}?session=${jwt}`);
    return !out.includes(jwt);
  })());
  check("redactUrl scrubs unparseable input via redactText", !redactUrl("junk Bearer sekret-token-value").includes("sekret-token-value"));
  check("redactText redacts short access_token/auth kv", !redactText('{"access_token":"short-secret"}').includes("short-secret") && !redactText("auth: tinytok").includes("tinytok"));
  for (let i = 0; i < 205; i++) await page.evaluate((n) => console.info(`ring-${n}`), i);
  await wait(100);
  const capped = await executor.cmdLogs(tab, { maxEntries: 200 });
  check("rings evict above 200", capped.console.length <= 200 && capped.network.length <= 200);
  const limited = await executor.cmdLogs(tab, { maxEntries: 1 });
  check("maxEntries slices both rings", limited.console.length <= 1 && limited.network.length <= 1);

  await executor.shutdown();
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})().catch((error) => { console.error("FATAL", error); process.exit(2); });
