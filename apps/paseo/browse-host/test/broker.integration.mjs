// SPDX-License-Identifier: Apache-2.0
// Integration test against the REAL upstream Paseo broker.
//
// Loads @getpaseo/server's BrowserToolsBroker, registers a client that pipes
// requests through our executor with JSON round-trips (simulating the WS wire),
// and drives broker.execute(). This proves our response payloads pass the
// broker's own schema validation (receiveResponse) + browserId affinity — the
// strongest e2e short of a live LLM agent. Needs network (example.com) and a
// resolvable 'playwright'.
//
// Run: node test/broker.integration.mjs

import { createRequire } from "node:module";
import http from "node:http";
const require = createRequire(import.meta.url);

const BROKER_PATH = process.env.PASEO_BROKER_PATH || "";
if (!BROKER_PATH) {
  console.log("SKIP broker.integration — set PASEO_BROKER_PATH to the installed @getpaseo/server broker.js");
  process.exit(0);
}

const { BrowserToolsBroker } = await import(BROKER_PATH);
const { BrowserHostExecutor } = require("../src/executor.js");
const { SUPPORTED_COMMANDS } = require("../src/commands.js");

const fixtureServer = http.createServer((req, res) => {
  if (req.url === "/fail") {
    res.writeHead(503, { "content-type": "text/plain" });
    res.end("fixture failure");
    return;
  }
  res.writeHead(200, { "content-type": "text/html" });
  res.end(`<!doctype html><title>logs fixture</title><script>
    console.error("fixture console error");
    setTimeout(() => fetch("/fail"), 20);
  </script>`);
});
await new Promise((resolve) => fixtureServer.listen(0, "127.0.0.1", resolve));
const fixtureUrl = `http://127.0.0.1:${fixtureServer.address().port}/`;

function loadChromium() {
  for (const c of [
    "playwright",
    process.env.PASEO_PLAYWRIGHT_PATH,
  ]) {
    try { return require(c).chromium; } catch {}
  }
  throw new Error("playwright not resolvable");
}

let passed = 0, failed = 0;
function check(name, cond, detail) {
  if (cond) { passed++; console.log(`  ok  ${name}`); }
  else { failed++; console.log(`FAIL  ${name}${detail ? " :: " + detail : ""}`); }
}

const chromium = loadChromium();
const executor = new BrowserHostExecutor({
  log: () => {},
  launchChromium: () => chromium.launch({ headless: true, args: ["--no-sandbox"] }),
});

const broker = new BrowserToolsBroker({});

// Register a host that mimics the WS wire: JSON round-trip in and out, and hand
// the response back through the real broker.receiveResponse.
broker.registerClient({
  id: "test-server-host",
  hostKind: "server",
  supportedCommands: SUPPORTED_COMMANDS,
  sendBrowserAutomationRequest: (request) => {
    // Simulate serialization to the sidecar and back.
    const wire = JSON.parse(JSON.stringify(request));
    executor
      .execute({
        requestId: wire.requestId,
        command: wire.command,
        workspaceId: wire.workspaceId,
      })
      .then((payload) => {
        const responseMsg = JSON.parse(
          JSON.stringify({ type: "browser.automation.execute.response", payload }),
        );
        const accepted = broker.receiveResponse(responseMsg);
        if (!accepted) console.log("  !! broker rejected response for", wire.requestId);
      });
  },
});

const exec = (command, args = {}, workspaceId = "ws1") =>
  broker.execute({ command: { command, args }, workspaceId });

// new_tab (real http URL — broker validates the schema)
let r = await exec("new_tab", { url: "https://example.com/" });
check("broker new_tab ok", r.ok, JSON.stringify(r.error));
const bid = r.ok ? r.result.browserId : null;
check("new_tab browserId is uuid", Boolean(bid) && /^[0-9a-f-]{36}$/.test(bid));

// snapshot routed by affinity to our host
r = await exec("snapshot", { browserId: bid });
check("broker snapshot ok (affinity)", r.ok, JSON.stringify(r.error));
check("snapshot passed broker schema + has @e refs", r.ok && /\[ref=@e\d+\]/.test(r.result.snapshot));
const linkRef = r.ok ? (r.result.snapshot.match(/link[^\n]*\[ref=(@e\d+)\]/) || [])[1] : null;

// click a ref through the broker (example.com has a link)
if (linkRef) {
  r = await exec("click", { browserId: bid, ref: linkRef });
  check("broker click via ref ok", r.ok, JSON.stringify(r.error));
} else {
  check("example.com had a link ref", false, "no link ref in snapshot");
}

// SSRF through the real broker path -> our host denies
r = await exec("navigate", { browserId: bid, url: "http://169.254.169.254/latest/meta-data/" });
check("broker navigate metadata -> denied", !r.ok && r.error.code === "browser_denied", JSON.stringify(r));

// logs through the real broker/schema path, using a local fixture to produce
// a console error and an HTTP 503 without depending on an external site.
r = await exec("navigate", { browserId: bid, url: fixtureUrl });
check("broker logs fixture navigate ok", r.ok, JSON.stringify(r.error));
await new Promise((resolve) => setTimeout(resolve, 300));
r = await exec("logs", { browserId: bid, maxEntries: 50 });
check("broker logs ok (receiveResponse schema)", r.ok, JSON.stringify(r.error));
check("logs result has exact arrays", r.ok && r.result.command === "logs" && r.result.browserId === bid && Array.isArray(r.result.console) && Array.isArray(r.result.network));
check("logs contains console error", r.ok && r.result.console.some((entry) => /fixture console error/.test(entry.message)));
check("logs contains HTTP failure", r.ok && r.result.network.some((entry) => entry.status === 503));

// list_tabs (single host -> direct)
r = await exec("list_tabs", {});
check("broker list_tabs ok", r.ok && r.result.tabs.some((t) => t.browserId === bid), JSON.stringify(r));

// close_tab
r = await exec("close_tab", { browserId: bid });
check("broker close_tab ok", r.ok, JSON.stringify(r.error));

await executor.shutdown();
await new Promise((resolve) => fixtureServer.close(resolve));
console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
