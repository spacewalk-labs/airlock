// SPDX-License-Identifier: MIT
"use strict";

// Real Chromium companion e2e: roster -> dock -> viewer canvas -> terminal close.
// Run: node test/companion.e2e.cjs

const fs = require("node:fs");
const http = require("node:http");
const { BrowserHostExecutor } = require("../src/executor.js");
const { BrowseStreamServer } = require("../src/stream-server.js");
const security = require("../src/security.js");

const testUrlPolicy = {
  assertUrlAllowed: async (u) => String(u).startsWith("data:") ? new URL(u) : security.assertUrlAllowed(u),
  shouldAbortSubRequest: security.shouldAbortSubRequest,
};

function loadChromium() {
  for (const name of [
    "playwright",
    process.env.PASEO_PLAYWRIGHT_PATH,
  ]) {
    try { return require(name).chromium; } catch {}
  }
  throw new Error("playwright not resolvable");
}

const companion = fs.readFileSync(require.resolve("../web/browse-view-client.js"), "utf8");
const DATA_PAGE = `data:text/html,${encodeURIComponent(`<!doctype html><title>Agent frame</title><body style="margin:0;background:#2d8f63;color:white;font:48px system-ui">AGENT FRAME</body>`)}`;
const HTML = `<!doctype html><meta charset="utf-8"><title>Companion e2e</title><body><script>${companion}</script></body>`;

let passed = 0;
let failed = 0;
function check(name, condition, detail) {
  if (condition) { passed++; console.log(`  ok  ${name}`); }
  else { failed++; console.log(`FAIL  ${name}${detail ? ` :: ${detail}` : ""}`); }
}

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      resolve();
    });
  });
}

function closeHttp(server) {
  if (!server.listening) return Promise.resolve();
  return new Promise((resolve) => server.close(() => resolve()));
}

(async () => {
  const chromium = loadChromium();
  let exec;
  let stream;
  let httpServer;
  let page;
  try {
    exec = new BrowserHostExecutor({
      log: (m) => process.env.VERBOSE && console.log("[exec]", m),
      launchChromium: () => chromium.launch({ headless: true, args: ["--no-sandbox"] }),
      urlPolicy: testUrlPolicy,
    });

    httpServer = http.createServer((req, res) => {
      if (req.method !== "GET" || req.url !== "/") {
        res.writeHead(404).end();
        return;
      }
      res.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      res.end(HTML);
    });
    await listen(httpServer);
    const port = httpServer.address().port;
    const origin = `http://127.0.0.1:${port}`;
    stream = new BrowseStreamServer({
      executor: exec,
      log: (m) => process.env.VERBOSE && console.log("[stream]", m),
      server: httpServer,
      allowedOrigins: [origin],
    });
    exec.rosterSink = (evt) => stream.onRosterEvent(evt);
    stream.start();

    const agent = await exec.cmdNewTab({ url: DATA_PAGE }, "ws-e2e");
    page = await exec.browser.newPage();
    await page.goto(`${origin}/`, { waitUntil: "domcontentloaded" });

    await page.waitForSelector("#paseo-agent-dock", { state: "visible", timeout: 8000 });
    check("agent dock chip appears with count 1", await page.locator(".paseo-agent-chip").textContent() === "Agent · 1");

    await page.click(".paseo-agent-chip");
    await page.waitForSelector(".paseo-agent-list", { state: "visible", timeout: 3000 });
    check("roster item has no live-panel marker", await page.evaluate(() =>
      [...document.querySelectorAll(".paseo-agent-item")].length === 1 &&
      [...document.querySelectorAll(".paseo-agent-item")].every((el) => !el.hasAttribute("data-paseo-browser-id"))));

    await page.click(".paseo-agent-item");
    await page.waitForSelector(".paseo-agent-viewer canvas", { state: "attached", timeout: 3000 });
    // A frame actually rendered: verify its pixels, not the canvas default size.
    await page.waitForFunction(() => {
      const canvas = document.querySelector(".paseo-agent-viewer canvas");
      if (!canvas || !canvas.width || !canvas.height) return false;
      const pixel = canvas.getContext("2d").getImageData(Math.floor(canvas.width / 2), Math.floor(canvas.height / 2), 1, 1).data;
      return pixel[1] > 120 && pixel[1] > pixel[0] && pixel[1] > pixel[2];
    }, null, { timeout: 8000 });
    check("viewer canvas receives a green agent frame", true);
    check("viewer is get-only and creates no phantom tab", exec.countTabs() === 1);

    await exec.cmdCloseTab(exec.getTab(agent.browserId));
    await page.waitForFunction(() => {
      const dock = document.querySelector("#paseo-agent-dock");
      const chip = document.querySelector(".paseo-agent-chip");
      return dock && dock.style.display === "none" && chip && chip.textContent === "Agent · 0" &&
        !document.querySelector(".paseo-agent-viewer");
    }, null, { timeout: 8000 });
    check("agent close removes dock item and viewer", true);
  } finally {
    if (page) await page.close().catch(() => {});
    if (stream) await stream.shutdown().catch(() => {});
    await closeHttp(httpServer);
    if (exec) await exec.shutdown().catch(() => {});
  }
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error(e);
  console.log(`\n${passed} passed, ${failed + 1} failed`);
  process.exit(1);
});
