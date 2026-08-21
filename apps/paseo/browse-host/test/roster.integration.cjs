// SPDX-License-Identifier: MIT
"use strict";

// Roster + get-only + terminal-close integration against real Chromium.
// Run: node test/roster.integration.cjs

const WebSocket = require("ws");
const { BrowserHostExecutor } = require("../src/executor.js");
const { BrowseStreamServer } = require("../src/stream-server.js");
const security = require("../src/security.js");

const testUrlPolicy = {
  assertUrlAllowed: async (u) => String(u).startsWith("data:") ? new URL(u) : security.assertUrlAllowed(u),
  shouldAbortSubRequest: security.shouldAbortSubRequest,
};

function loadChromium() {
  for (const c of ["playwright", process.env.PASEO_PLAYWRIGHT_PATH]) {
    try { return require(c).chromium; } catch {}
  }
  throw new Error("playwright not resolvable");
}

const ORIGIN = "https://dev-box.example.ts.net:8447";
const PAGE_A = `data:text/html,${encodeURIComponent("<!doctype html><title>AgentA</title><body>agent a</body>")}`;
const PAGE_B = `data:text/html,${encodeURIComponent("<!doctype html><title>AgentB</title><body>agent b</body>")}`;

let passed = 0, failed = 0;
function check(name, cond, detail) {
  if (cond) { passed++; console.log(`  ok  ${name}`); }
  else { failed++; console.log(`FAIL  ${name}${detail ? " :: " + detail : ""}`); }
}
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(fn, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (fn()) return true; await wait(50); }
  return false;
}
function collect(ws) {
  const state = { texts: [], closed: null };
  ws.on("message", (data, isBinary) => {
    if (!isBinary) { try { state.texts.push(JSON.parse(String(data))); } catch {} }
  });
  ws.on("error", () => {});
  ws.on("close", (code) => { state.closed = code; });
  return state;
}
async function openWs(url, hello) {
  const ws = new WebSocket(url, { headers: { Origin: ORIGIN } });
  const state = collect(ws);
  await new Promise((resolve, reject) => { ws.once("open", resolve); ws.once("error", reject); });
  if (hello) ws.send(JSON.stringify(hello));
  return { ws, state };
}

(async () => {
  const chromium = loadChromium();
  const exec = new BrowserHostExecutor({
    log: (m) => process.env.VERBOSE && console.log("[exec]", m),
    launchChromium: () => chromium.launch({ headless: true, args: ["--no-sandbox"] }),
    urlPolicy: testUrlPolicy,
  });
  const server = new BrowseStreamServer({
    executor: exec,
    log: (m) => process.env.VERBOSE && console.log("[stream]", m),
    host: "127.0.0.1",
    port: 0,
    allowedOrigins: [ORIGIN],
  });
  exec.rosterSink = (evt) => server.onRosterEvent(evt);
  server.start();
  await until(() => server.boundPort() > 0, 3000);
  const base = `ws://127.0.0.1:${server.boundPort()}/browse-view/`;

  // Origin is checked before the roster path is dispatched.
  {
    const ws = new WebSocket(base + "roster", { headers: { Origin: "https://evil.example" } });
    const st = collect(ws);
    await until(() => st.closed !== null, 3000);
    check("bad Origin rejected on roster (1008)", st.closed === 1008, `closed=${st.closed}`);
  }

  const agent = await exec.cmdNewTab({ url: PAGE_A }, "agent-workspace");
  const viewerId = "abcdef01-2345-4678-8abc-def012345678";
  await exec.ensureTab(viewerId, "viewer-workspace", PAGE_B);
  const roster = await openWs(base + "roster");
  const snapshot = await until(() => roster.state.texts.some((m) => m.type === "snapshot"), 3000);
  const snap = roster.state.texts.find((m) => m.type === "snapshot");
  check("roster snapshot received", snapshot);
  check("snapshot contains agent tab only", snap && snap.tabs.length === 1 && snap.tabs[0].browserId === agent.browserId);

  const agentNav = `data:text/html,${encodeURIComponent("<!doctype html><title>AgentA-Navigated</title><body>changed</body>")}`;
  await exec.cmdNavigate(exec.getTab(agent.browserId), { url: agentNav });
  const upsert = await until(() => roster.state.texts.some((m) => m.type === "upsert" && m.tab.browserId === agent.browserId && /AgentA-Navigated/.test(m.tab.title)), 5000);
  check("agent navigate produces roster upsert with title", upsert);

  const reconnect = await openWs(base + "roster");
  const reconnectSnapshot = await until(() => reconnect.state.texts.some((m) => m.type === "snapshot"), 3000);
  const reconnectSnap = reconnect.state.texts.find((m) => m.type === "snapshot");
  check("reconnected roster snapshot preserves title", reconnectSnapshot && reconnectSnap.tabs.some((t) => t.browserId === agent.browserId && t.title === "AgentA-Navigated"));
  await reconnect.ws.close();

  // Viewer-origin tabs remain usable but never appear in roster deltas.
  check("viewer-origin tab absent from roster", !roster.state.texts.some((m) => m.type === "upsert" && m.tab.browserId === viewerId));

  // Bind a roster-originated viewer to the existing page; no second page is created.
  const agentViewer = await openWs(base + encodeURIComponent(agent.browserId), {
    type: "hello", workspaceId: "agent-workspace", expectExisting: true,
  });
  check("get-only viewer receives ready", await until(() => agentViewer.state.texts.some((m) => m.type === "ready"), 5000));
  check("get-only viewer preserves one tab", exec.countTabs() === 2);
  const page = exec.getTab(agent.browserId).page;
  const listenersBefore = page.listenerCount("framenavigated");
  agentViewer.ws.close();
  await until(() => agentViewer.ws.readyState === WebSocket.CLOSED, 3000);
  check("viewer dispose removes framenavigated listener", await until(() => page.listenerCount("framenavigated") < listenersBefore, 3000));

  // Rebind and close the actual page: viewer gets terminal notification/close.
  const liveViewer = await openWs(base + encodeURIComponent(agent.browserId), {
    type: "hello", workspaceId: "agent-workspace", expectExisting: true,
  });
  await until(() => liveViewer.state.texts.some((m) => m.type === "ready"), 5000);
  await exec.cmdCloseTab(exec.getTab(agent.browserId));
  check("page close sends roster remove", await until(() => roster.state.texts.some((m) => m.type === "remove" && m.browserId === agent.browserId), 3000));
  check("page close is terminal for viewer", await until(() => liveViewer.state.closed !== null, 3000) && (liveViewer.state.closed === 4001 || liveViewer.state.texts.some((m) => m.type === "tab_closed")));

  // Stale roster click is get-only: it must not create a phantom page.
  const stale = await openWs(base + encodeURIComponent(agent.browserId), {
    type: "hello", workspaceId: "agent-workspace", expectExisting: true,
  });
  check("stale get-only viewer receives tab_closed", await until(() => stale.state.texts.some((m) => m.type === "tab_closed"), 3000));
  check("stale get-only viewer closes with 4001", await until(() => stale.state.closed !== null, 3000) && stale.state.closed === 4001);
  check("stale get-only viewer creates no phantom", exec.getTab(agent.browserId) === null);

  // Chromium disconnect resets the roster and terminates active viewers.
  const resetAgent = await exec.cmdNewTab({ url: PAGE_B }, "reset-workspace");
  const resetViewer = await openWs(base + encodeURIComponent(resetAgent.browserId), {
    type: "hello", workspaceId: "reset-workspace", expectExisting: true,
  });
  await until(() => resetViewer.state.texts.some((m) => m.type === "ready"), 5000);
  await exec.browser.close();
  check("chromium disconnect sends roster reset", await until(() => roster.state.texts.some((m) => m.type === "reset"), 5000));
  check("chromium disconnect terminates active viewer", await until(() => resetViewer.state.closed !== null, 5000));

  await roster.ws.close();
  await server.shutdown();
  await exec.shutdown();
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
