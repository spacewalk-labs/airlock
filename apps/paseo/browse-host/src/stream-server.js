// SPDX-License-Identifier: MIT
"use strict";
// Live browser-panel stream transport (task doc §14.5). A loopback WS server the
// patched paseo web-ui reaches at wss://<fqdn>:8447/browse-view/<browserId>,
// proxied by the owner-gated nginx paseo gate. On connect we bind (create-on-
// demand via executor.ensureTab) the browserId's Playwright page, attach a CDP
// screencast, stream jpeg frames out (binary, backpressure-acked), and dispatch
// input events (mouse/key/wheel) + toolbar nav (navigate/back/forward/reload,
// through the executor's URL policy + per-page serial queue) back in.
//
// Security (§14.8, proportionate — this is an owner-only tool):
//   1. nginx owner gate ($paseo_owner_deny) is the primary boundary.
//   2. Origin check here defends cross-site WebSocket hijacking (browser sends
//      Origin; JS cannot forge it).
//   3. browserId is an unguessable client-generated UUID.
//   A per-session capability token is an injectable hardening hook (tokenStore),
//   off by default for a single-owner box.

const WebSocket = require("ws");

// Screencast tuning. jpeg over WS, one-outstanding-frame backpressure.
const SCREENCAST = { format: "jpeg", quality: 60, maxWidth: 1600, maxHeight: 1200, everyNthFrame: 1 };
const MAX_INPUT_MSG_BYTES = 256 * 1024;
const MAX_WS_BUFFER = 4 * 1024 * 1024; // drop/coalesce frames when the client lags
const IDLE_STREAM_MS = 5 * 60 * 1000;

// App-range WS close code (4000-4999) meaning "the page is gone; do NOT reconnect".
// MUST differ from 1000 (idle close, page kept) so the client can distinguish terminal.
const CLOSE_TAB_GONE = 4001;

// browserId shapes createWorkspaceBrowser() emits: UUIDv4 or `${Date.now()}-hex`.
const BROWSER_ID_RE = /^(?:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|\d{13,}-[0-9a-f]+)$/i;

// Minimal Windows virtual-key codes for non-text keys we forward as rawKeyDown/
// keyUp. Printable text goes through Input.insertText instead (§14.5), so this
// table only needs control/navigation keys. IME/composition is out of MVP scope.
const VK = {
  Enter: 13, Tab: 9, Backspace: 8, Delete: 46, Escape: 27, Space: 32,
  ArrowLeft: 37, ArrowUp: 38, ArrowRight: 39, ArrowDown: 40,
  Home: 36, End: 35, PageUp: 33, PageDown: 34, Insert: 45,
  Shift: 16, Control: 17, Alt: 18, Meta: 91,
  F1: 112, F2: 113, F3: 114, F4: 115, F5: 116, F6: 117,
  F7: 118, F8: 119, F9: 120, F10: 121, F11: 122, F12: 123,
};

// DOM MouseEvent.buttons bitmask by primary button.
const BTN_MASK = { left: 1, right: 2, middle: 4 };

// CDP modifier bitmask: Alt=1, Ctrl=2, Meta=4, Shift=8.
function modMask(m) {
  if (!m) return 0;
  return (m.alt ? 1 : 0) | (m.ctrl ? 2 : 0) | (m.meta ? 4 : 0) | (m.shift ? 8 : 0);
}

function frameHeader(meta) {
  const json = Buffer.from(JSON.stringify(meta), "utf8");
  const len = Buffer.allocUnsafe(4);
  len.writeUInt32LE(json.length, 0);
  return Buffer.concat([len, json]);
}

class BrowseStreamServer {
  constructor({ executor, log, port = 6768, host = "127.0.0.1", allowedOrigins = null, tokenStore = null, maxStreams = 4, server = null } = {}) {
    this.executor = executor;
    this.log = log ?? (() => {});
    this.port = port;
    this.host = host;
    // allowedOrigins: array of exact origin strings, or null = warn-once + allow
    // (owner gate still protects; install.sh sets the box FQDN origin).
    this.allowedOrigins = allowedOrigins;
    this.tokenStore = tokenStore;
    this.maxStreams = maxStreams;
    this.injectedServer = server;
    this.wss = null;
    this.streams = new Set();
    this.rosterSubscribers = new Set();
    this._originWarned = false;
  }

  // Actual bound port (useful when constructed with port 0 for tests).
  boundPort() {
    const addr = this.injectedServer ? this.injectedServer.address() : this.wss && this.wss.address();
    return addr && typeof addr === "object" ? addr.port : this.port;
  }

  start() {
    const opts = { maxPayload: MAX_INPUT_MSG_BYTES };
    if (this.injectedServer) opts.server = this.injectedServer;
    else { opts.host = this.host; opts.port = this.port; }
    this.wss = new WebSocket.Server(opts);
    this.wss.on("connection", (ws, req) => this._onConnection(ws, req).catch((e) => {
      this.log(`stream connection error: ${e && e.message}`);
      this._safeClose(ws, 1011, "internal");
    }));
    this.wss.on("listening", () => this.log(`stream server listening on ws://${this.host}:${this.port} (/browse-view/<id>)`));
    this.wss.on("error", (e) => this.log(`stream server error: ${e && e.message}`));
    return this;
  }

  originAllowed(origin) {
    if (this.allowedOrigins == null) {
      if (!this._originWarned) {
        this.log("WARN: PASEO_BROWSE_ALLOWED_ORIGIN unset — accepting any Origin (owner gate still enforced)");
        this._originWarned = true;
      }
      return true;
    }
    return this.allowedOrigins.includes(origin);
  }

  async _onConnection(ws, req) {
    const url = req.url || "";
    const origin = req.headers.origin || "";
    // Origin gate FIRST — common to roster + per-id. The roster path has ZERO id
    // entropy (literal "roster"), so Origin is its only app-layer defense (§5.2).
    if (!this.originAllowed(origin)) {
      this.log(`stream rejected: origin ${origin} not allowed (${url})`);
      return this._safeClose(ws, 1008, "origin");
    }
    // Roster channel: workspace-agnostic agent-tab list + deltas (§5.2).
    if (/^\/browse-view\/roster(?:[/?#]|$)/.test(url)) {
      return this._onRosterConnection(ws);
    }
    // Path: /browse-view/<browserId>
    const m = url.match(/^\/browse-view\/([^/?#]+)/);
    const browserId = m ? decodeURIComponent(m[1]) : "";
    if (!BROWSER_ID_RE.test(browserId)) {
      return this._safeClose(ws, 1008, "bad browserId");
    }
    if (this.streams.size >= this.maxStreams) {
      return this._safeClose(ws, 1013, "too many streams");
    }

    // Handshake: first client message carries workspaceId (+ optional token, url).
    const hello = await this._firstMessage(ws, 10_000);
    if (!hello || hello.type !== "hello") {
      return this._safeClose(ws, 1002, "expected hello");
    }
    const workspaceId = String(hello.workspaceId || "default");
    if (this.tokenStore) {
      const ok = this.tokenStore.verify(hello.token, browserId, workspaceId);
      if (!ok) return this._safeClose(ws, 1008, "token");
    }

    let tab;
    if (hello.expectExisting) {
      // Roster-originated viewer: bind only if the agent tab still exists.
      tab = this.executor.getTab(browserId);
      if (!tab || tab.workspaceId !== workspaceId) {
        this._send(ws, { type: "tab_closed", browserId });
        return this._safeClose(ws, CLOSE_TAB_GONE, "tab gone");
      }
    } else {
      // Human "New browser": preserve create-on-demand behavior.
      try {
        tab = await this.executor.ensureTab(browserId, workspaceId, hello.url || undefined);
      } catch (err) {
        this._send(ws, { type: "error", code: err.code || "browser_unknown_error", message: err.message });
        return this._safeClose(ws, 1011, "ensureTab");
      }
    }

    const stream = new Stream({ ws, tab, browserId, workspaceId, server: this });
    this.streams.add(stream);
    ws.on("close", () => { this.streams.delete(stream); stream.dispose(); });
    ws.on("error", () => { this.streams.delete(stream); stream.dispose(); });
    await stream.begin();
  }

  // A roster subscriber gets a snapshot followed by live agent-tab deltas.
  _onRosterConnection(ws) {
    const sub = { ws };
    this.rosterSubscribers.add(sub);
    try {
      this._send(ws, { type: "snapshot", tabs: this.executor.rosterSnapshot() });
    } catch (e) {
      this.log(`roster snapshot send failed: ${e && e.message}`);
    }
    ws.on("close", () => this.rosterSubscribers.delete(sub));
    ws.on("error", () => this.rosterSubscribers.delete(sub));
  }

  // Called by executor.rosterSink; only agent-tab lifecycle is surfaced.
  onRosterEvent(evt) {
    if (!evt) return;
    if (evt.kind === "reset") {
      for (const sub of this.rosterSubscribers) this._send(sub.ws, { type: "reset" });
      for (const s of Array.from(this.streams)) {
        this._send(s.ws, { type: "tab_closed", browserId: s.browserId });
        this._safeClose(s.ws, CLOSE_TAB_GONE, "reset");
      }
      return;
    }
    if (evt.origin !== "agent") return;
    if (evt.kind === "open" || evt.kind === "nav") {
      const tab = {
        browserId: evt.browserId,
        workspaceId: evt.workspaceId,
        url: evt.url || "",
        title: evt.title || "",
        status: evt.status || "open",
      };
      for (const sub of this.rosterSubscribers) this._send(sub.ws, { type: "upsert", tab });
    } else if (evt.kind === "close") {
      for (const sub of this.rosterSubscribers) this._send(sub.ws, { type: "remove", browserId: evt.browserId });
    }
  }

  _firstMessage(ws, timeoutMs) {
    return new Promise((resolve) => {
      const timer = setTimeout(() => { cleanup(); resolve(null); }, timeoutMs);
      const onMsg = (data) => {
        cleanup();
        try { resolve(JSON.parse(String(data))); } catch { resolve(null); }
      };
      const cleanup = () => { clearTimeout(timer); ws.off("message", onMsg); };
      ws.on("message", onMsg);
    });
  }

  _send(ws, obj) {
    if (ws.readyState === WebSocket.OPEN) {
      try { ws.send(JSON.stringify(obj)); } catch {}
    }
  }

  _safeClose(ws, code, reason) {
    try { ws.close(code, reason); } catch {}
  }

  async shutdown() {
    for (const s of this.streams) s.dispose();
    this.streams.clear();
    for (const sub of this.rosterSubscribers) this._safeClose(sub.ws, 1001, "shutdown");
    this.rosterSubscribers.clear();
    if (this.wss) await new Promise((r) => this.wss.close(r));
  }
}

// One live viewer of one page: its own CDP session + screencast + input pump.
class Stream {
  constructor({ ws, tab, browserId, workspaceId, server }) {
    this.ws = ws;
    this.tab = tab;
    this.browserId = browserId;
    this.workspaceId = workspaceId;
    this.server = server;
    this.executor = server.executor;
    this.log = server.log;
    this.cdp = null;
    this.disposed = false;
    this._lastActivity = Date.now();
    this._idleTimer = null;
    this._onFrame = null;
    this._onNav = null;
    this._onNavFrame = null;
    this._onTabClosed = null;
  }

  async begin() {
    const page = this.tab.page;
    this.cdp = await page.context().newCDPSession(page);
    // Push nav-state sync (§14.6): agent or user navigation updates the toolbar.
    this._onNav = () => this._pushState().catch(() => {});
    this._onNavFrame = (frame) => { if (frame === page.mainFrame()) this._onNav(); };
    page.on("framenavigated", this._onNavFrame);
    page.on("load", this._onNav);
    // Terminal close: the page itself is gone; suppress client reconnects.
    this._onTabClosed = () => {
      this._send({ type: "tab_closed", browserId: this.browserId });
      this.server._safeClose(this.ws, CLOSE_TAB_GONE, "tab closed");
    };
    page.once("close", this._onTabClosed);

    this._onFrame = (evt) => this._handleFrame(evt);
    this.cdp.on("Page.screencastFrame", this._onFrame);
    await this.cdp.send("Page.enable").catch(() => {});
    await this.cdp.send("Page.startScreencast", SCREENCAST);

    this.ws.on("message", (data) => this._onInput(data));
    await this._pushState().catch(() => {});
    this._send({ type: "ready", browserId: this.browserId });
    this._armIdle();
  }

  _handleFrame(evt) {
    if (this.disposed) return;
    const sessionId = evt.sessionId;
    // Always ack so Chromium keeps producing; drop the payload if the client lags
    // (coalesce to the freshest frame — §14.5 backpressure).
    const ack = () => { this.cdp && this.cdp.send("Page.screencastFrameAck", { sessionId }).catch(() => {}); };
    if (this.ws.readyState !== WebSocket.OPEN || this.ws.bufferedAmount > MAX_WS_BUFFER) {
      ack();
      return;
    }
    try {
      const jpeg = Buffer.from(evt.data, "base64");
      const header = frameHeader({ md: evt.metadata });
      this.ws.send(Buffer.concat([header, jpeg]), { binary: true }, ack);
    } catch {
      ack();
    }
  }

  async _onInput(data) {
    if (this.disposed) return;
    this._lastActivity = Date.now();
    let msg;
    try { msg = JSON.parse(String(data)); } catch { return; }
    try {
      switch (msg.type) {
        case "mouse": return await this._mouse(msg);
        case "text": return await this._text(msg);
        case "key": return await this._key(msg);
        case "nav": return await this._nav(msg);
        case "resize": return await this._resize(msg);
        case "ack": return; // reserved: explicit client ack
        default: return;
      }
    } catch (err) {
      const code = (err && err.code) || "browser_unknown_error";
      this.log(`input dispatch failed (${msg && msg.type}) for ${this.browserId}: ${code}: ${err && err.message}`);
      // Surface it to the client — a swallowed nav error reads as "nothing
      // happened" (e.g. a blocked URL). No silent failure.
      this._send({ type: "error", code, message: (err && err.message) || "command failed" });
    }
  }

  async _mouse(m) {
    const type = { move: "mouseMoved", down: "mousePressed", up: "mouseReleased", wheel: "mouseWheel" }[m.event];
    if (!type) return;
    const p = { type, x: Math.round(m.x || 0), y: Math.round(m.y || 0), modifiers: modMask(m.modifiers) };
    if (m.event === "down" || m.event === "up") {
      const button = m.button || "left";
      p.button = button;
      p.clickCount = m.clickCount || 1;
      // buttons is the bitmask of buttons held DURING the event; Chromium needs
      // it non-zero on press to synthesize a click. Derive from `button` when the
      // client omits it (left=1, right=2, middle=4); 0 on release.
      p.buttons = m.buttons != null ? m.buttons : (m.event === "down" ? (BTN_MASK[button] || 1) : 0);
    } else {
      p.button = "none";
      p.buttons = m.buttons || 0;
      if (m.event === "wheel") { p.deltaX = m.deltaX || 0; p.deltaY = m.deltaY || 0; }
    }
    await this.cdp.send("Input.dispatchMouseEvent", p);
  }

  // Ordinary printable text — insertText is IME/layout robust for plain input.
  async _text(m) {
    if (typeof m.text !== "string" || m.text.length === 0) return;
    await this.cdp.send("Input.insertText", { text: m.text });
  }

  // Control/navigation keys via rawKeyDown/keyUp with a virtual-key code.
  async _key(m) {
    const cdpType = m.event === "up" ? "keyUp" : "rawKeyDown";
    await this.cdp.send("Input.dispatchKeyEvent", {
      type: cdpType,
      key: m.key,
      code: m.code,
      windowsVirtualKeyCode: VK[m.key] || VK[m.code] || 0,
      modifiers: modMask(m.modifiers),
    });
  }

  // Toolbar nav goes through the executor: URL policy + per-page serial queue
  // (§14.5/§14.6) so a user click never interleaves with an agent command.
  async _nav(m) {
    const id = this.browserId;
    let result;
    if (m.action === "navigate") {
      result = await this.executor.runOnTab(id, this.workspaceId, (tab) => this.executor.cmdNavigate(tab, { url: m.url }));
    } else if (m.action === "back") {
      result = await this.executor.runOnTab(id, this.workspaceId, (tab) => this.executor.cmdBack(tab));
    } else if (m.action === "forward") {
      result = await this.executor.runOnTab(id, this.workspaceId, (tab) => this.executor.cmdForward(tab));
    } else if (m.action === "reload") {
      result = await this.executor.runOnTab(id, this.workspaceId, (tab) => this.executor.cmdReload(tab));
    } else {
      return;
    }
    await this._pushState().catch(() => {});
    return result;
  }

  async _resize(m) {
    const width = Math.max(1, Math.min(SCREENCAST.maxWidth, Math.round(m.width || 0)));
    const height = Math.max(1, Math.min(SCREENCAST.maxHeight, Math.round(m.height || 0)));
    if (!width || !height) return;
    // setViewportSize is a page-state change → serialize on the tab queue.
    await this.executor.runOnTab(this.browserId, this.workspaceId, async (tab) => {
      await tab.page.setViewportSize({ width, height });
    });
  }

  async _pushState() {
    const page = this.tab.page;
    let url = "", title = "";
    try { url = page.url(); } catch {}
    try { title = await page.title(); } catch {}
    this._send({ type: "state", url, title });
  }

  _send(obj) {
    if (this.ws.readyState === WebSocket.OPEN) {
      try { this.ws.send(JSON.stringify(obj)); } catch {}
    }
  }

  _armIdle() {
    const tick = () => {
      if (this.disposed) return;
      if (Date.now() - this._lastActivity > IDLE_STREAM_MS) {
        this.log(`stream idle ${this.browserId} → closing viewer (page kept)`);
        this.server._safeClose(this.ws, 1000, "idle");
        return;
      }
      this._idleTimer = setTimeout(tick, 30_000);
    };
    this._idleTimer = setTimeout(tick, 30_000);
  }

  dispose() {
    if (this.disposed) return;
    this.disposed = true;
    if (this._idleTimer) clearTimeout(this._idleTimer);
    const page = this.tab && this.tab.page;
    if (page) {
      if (this._onNavFrame) { try { page.off("framenavigated", this._onNavFrame); } catch {} }
      if (this._onNav) { try { page.off("load", this._onNav); } catch {} }
      if (this._onTabClosed) { try { page.off("close", this._onTabClosed); } catch {} }
    }
    // Stop the screencast + detach CDP; the page itself stays alive (a viewer
    // leaving does not destroy the browser — the agent may still use it, §14.4).
    if (this.cdp) {
      const cdp = this.cdp;
      this.cdp = null;
      cdp.send("Page.stopScreencast").catch(() => {});
      cdp.detach().catch(() => {});
    }
  }
}

module.exports = { BrowseStreamServer };
