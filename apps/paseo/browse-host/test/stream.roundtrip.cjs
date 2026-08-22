// SPDX-License-Identifier: Apache-2.0
"use strict";
// Level 2 (§14.5/§14.8) live-stream transport e2e against real Chromium.
// Proves: WS handshake -> ensureTab create-on-demand -> CDP jpeg screencast frame
// -> input dispatch (mouse/text) -> toolbar nav (reload) -> state sync, plus the
// Origin gate (CSWSH defense). No daemon; the stream server talks straight to the
// executor. Run: node test/stream.roundtrip.cjs
//
// Frame wire format (§14.5): [uint32LE headerLen][headerJSON][jpeg bytes].

const WebSocket = require("ws");
const { BrowserHostExecutor } = require("../src/executor.js");
const { BrowseStreamServer } = require("../src/stream-server.js");
const security = require("../src/security.js");

const testUrlPolicy = {
  assertUrlAllowed: async (u) => {
    if (String(u).startsWith("data:")) return new URL(u);
    return security.assertUrlAllowed(u);
  },
  shouldAbortSubRequest: security.shouldAbortSubRequest,
};

function loadChromium() {
  for (const c of ["playwright", process.env.PASEO_PLAYWRIGHT_PATH]) {
    try { return require(c).chromium; } catch {}
  }
  throw new Error("playwright not resolvable");
}

const ORIGIN = "https://dev-box.example.ts.net:8447";
const PAGE = `data:text/html,${encodeURIComponent("<!doctype html><title>LiveA</title><body onclick='window.__clk=(window.__clk||0)+1' style='background:#3366cc;height:100vh;margin:0'><h1>Live</h1><input id='i'></body>")}`;
const ID = "abcdef01-2345-4678-8abc-def012345678";

let passed = 0, failed = 0;
function check(name, cond, detail) {
  if (cond) { passed++; console.log(`  ok  ${name}`); }
  else { failed++; console.log(`FAIL  ${name}${detail ? " :: " + detail : ""}`); }
}
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

function parseFrame(buf) {
  const headerLen = buf.readUInt32LE(0);
  const header = JSON.parse(buf.slice(4, 4 + headerLen).toString("utf8"));
  const jpeg = buf.slice(4 + headerLen);
  return { header, jpeg };
}

// Collect messages from a connected client until predicate or timeout.
function collect(ws) {
  const state = { texts: [], frames: [], closed: null };
  ws.on("message", (data, isBinary) => {
    if (isBinary) state.frames.push(parseFrame(data));
    else { try { state.texts.push(JSON.parse(String(data))); } catch {} }
  });
  ws.on("close", (code) => { state.closed = code; });
  return state;
}
async function until(fn, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (fn()) return true; await wait(50); }
  return false;
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
    port: 0, // random free port
    allowedOrigins: [ORIGIN],
  });
  server.start();
  await until(() => server.boundPort() && server.boundPort() > 0, 3000);
  const port = server.boundPort();
  check("stream server bound to a port", port > 0, String(port));
  const base = `ws://127.0.0.1:${port}/browse-view/`;

  // ── 1. Origin gate: wrong origin is rejected before any stream ──────────
  {
    const bad = new WebSocket(base + ID, { headers: { Origin: "https://evil.example" } });
    const st = collect(bad);
    await until(() => st.closed !== null, 3000);
    check("wrong Origin rejected (1008)", st.closed === 1008, "closed=" + st.closed);
  }

  // ── 2. Happy path: handshake -> frame -> input -> nav ───────────────────
  const ws = new WebSocket(base + ID, { headers: { Origin: ORIGIN } });
  const st = collect(ws);
  await new Promise((res, rej) => { ws.on("open", res); ws.on("error", rej); });
  ws.send(JSON.stringify({ type: "hello", workspaceId: "wsLive", url: PAGE }));

  const gotReady = await until(() => st.texts.some((t) => t.type === "ready"), 8000);
  check("received ready", gotReady);
  check("create-on-demand: executor has the tab", exec.getTab(ID) !== null);
  check("tab bound to hello workspace", exec.getTab(ID) && exec.getTab(ID).workspaceId === "wsLive");

  const gotState = await until(() => st.texts.some((t) => t.type === "state" && /LiveA/.test(decodeURIComponent(t.url || ""))), 8000);
  check("received state sync with url/title", gotState);

  const gotFrame = await until(() => st.frames.length > 0, 8000);
  check("received >=1 screencast frame", gotFrame, `frames=${st.frames.length}`);
  if (st.frames.length) {
    const f = st.frames[0];
    check("frame is JPEG (SOI FFD8)", f.jpeg.length > 2 && f.jpeg[0] === 0xff && f.jpeg[1] === 0xd8);
    check("frame carries screencast metadata", !!f.header && !!f.header.md);
  }

  // mouse dispatch: a click anywhere increments the page counter (proves the CDP
  // mouse event reached the page, independent of pixel-exact hit-testing).
  ws.send(JSON.stringify({ type: "mouse", event: "move", x: 40, y: 120 }));
  ws.send(JSON.stringify({ type: "mouse", event: "down", x: 40, y: 120, button: "left", clickCount: 1 }));
  ws.send(JSON.stringify({ type: "mouse", event: "up", x: 40, y: 120, button: "left", clickCount: 1 }));
  await wait(300);
  let clicks = 0;
  try { clicks = await exec.getTab(ID).page.evaluate(() => window.__clk || 0); } catch {}
  check("mouse click dispatched into page", clicks >= 1, `clicks=${clicks}`);

  // text dispatch: focus the input deterministically, then insertText via stream.
  try { await exec.getTab(ID).page.focus("#i"); } catch {}
  ws.send(JSON.stringify({ type: "text", text: "hello" }));
  await wait(400);
  let typed = "";
  try { typed = await exec.getTab(ID).page.evaluate(() => document.getElementById("i") ? document.getElementById("i").value : "?"); } catch {}
  check("text input dispatched into page", typed === "hello", `value=${JSON.stringify(typed)}`);

  // toolbar nav: reload through the executor (serialized), expect a fresh state.
  const before = st.texts.length;
  ws.send(JSON.stringify({ type: "nav", action: "reload" }));
  const navState = await until(() => st.texts.slice(before).some((t) => t.type === "state"), 8000);
  check("reload nav produced a state update", navState);

  // key path: Enter as a control key (rawKeyDown/keyUp) — just assert no crash.
  ws.send(JSON.stringify({ type: "key", event: "down", key: "Enter", code: "Enter" }));
  ws.send(JSON.stringify({ type: "key", event: "up", key: "Enter", code: "Enter" }));
  await wait(200);
  check("control key dispatch did not kill the stream", ws.readyState === WebSocket.OPEN);

  // ── 3. viewer leaving does NOT destroy the page (§14.4 lease) ────────────
  ws.close();
  await wait(300);
  check("page survives viewer disconnect", exec.getTab(ID) !== null);

  // ── 4. bad browserId rejected ───────────────────────────────────────────
  {
    const bad = new WebSocket(base + "not-a-valid-id", { headers: { Origin: ORIGIN } });
    const st2 = collect(bad);
    await until(() => st2.closed !== null, 3000);
    check("invalid browserId rejected (1008)", st2.closed === 1008, "closed=" + st2.closed);
  }

  await server.shutdown();
  await exec.shutdown();
  console.log(`\n${passed} passed, ${failed} failed`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
