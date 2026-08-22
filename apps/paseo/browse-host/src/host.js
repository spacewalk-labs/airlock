// SPDX-License-Identifier: Apache-2.0
"use strict";
// paseo-browse-host: a loopback WebSocket client that registers as a Paseo
// browser automation host and drives headless Chromium via the executor.
//
// It connects to the Paseo daemon's /ws, sends a hello advertising the
// browser_host capability, then answers browser.automation.execute.request
// messages with browser.automation.execute.response. Paseo server is NOT
// modified — this is a sidecar speaking the existing protocol (task doc §5).

const WebSocket = require("ws");
const { BrowserHostExecutor } = require("./executor.js");
const { BrowseStreamServer } = require("./stream-server.js");
const { SUPPORTED_COMMANDS } = require("./commands.js");

const WS_PROTOCOL_VERSION = 1;

function readConfig(env) {
  return {
    wsUrl: env.PASEO_WS_URL || "ws://127.0.0.1:19952/ws",
    clientId: env.PASEO_HOST_CLIENT_ID || "airlock-paseo-browse-host",
    hostKind: env.PASEO_HOST_KIND || "server",
    // Optional daemon bearer token, sent as the `paseo.bearer.<token>` subprotocol.
    token: env.PASEO_DAEMON_TOKEN || null,
    maxTabs: Number(env.PASEO_BROWSE_MAX_TABS || 24),
    chromiumPath: env.PASEO_BROWSE_CHROMIUM_PATH || null,
    reconnectMinMs: 1_000,
    reconnectMaxMs: 30_000,
    // Level 2 live-view stream server (task doc §14.5). Loopback only; nginx
    // owner-gates /browse-view/. Disabled with PASEO_BROWSE_STREAM_DISABLED=1.
    streamEnabled: env.PASEO_BROWSE_STREAM_DISABLED ? false : true,
    streamHost: env.PASEO_BROWSE_STREAM_HOST || "127.0.0.1",
    streamPort: Number(env.PASEO_BROWSE_STREAM_PORT || 19953),
    maxStreams: Number(env.PASEO_BROWSE_MAX_STREAMS || 4),
    // Exact allowed WS Origin(s) (CSWSH defense, §14.8). install.sh sets the box
    // FQDN origin; unset = warn-once + allow (owner gate still enforced).
    allowedOrigins: env.PASEO_BROWSE_ALLOWED_ORIGIN
      ? env.PASEO_BROWSE_ALLOWED_ORIGIN.split(",").map((s) => s.trim()).filter(Boolean)
      : null,
  };
}

function nowIso() {
  return new Date().toISOString();
}

function makeLogger(name) {
  return (msg, extra) => {
    const line = `[${nowIso()}] [${name}] ${msg}`;
    if (extra !== undefined) console.log(line, JSON.stringify(extra));
    else console.log(line);
  };
}

class BrowseHost {
  constructor({ env = process.env, chromium } = {}) {
    this.config = readConfig(env);
    this.log = makeLogger("browse-host");
    this.chromium = chromium || null; // lazy require unless injected
    this.executor = new BrowserHostExecutor({
      log: (m) => this.log(m),
      maxTabs: this.config.maxTabs,
      launchChromium: () => this.launchChromium(),
    });
    this.ws = null;
    this.reconnectMs = this.config.reconnectMinMs;
    this.reconnectTimer = null;
    this.stopped = false;
    this.registered = false;
    this.streamServer = this.config.streamEnabled
      ? new BrowseStreamServer({
          executor: this.executor,
          log: (m) => this.log(m),
          host: this.config.streamHost,
          port: this.config.streamPort,
          allowedOrigins: this.config.allowedOrigins,
          maxStreams: this.config.maxStreams,
        })
      : null;
    // Wire tab lifecycle from the executor to the roster broadcaster.
    if (this.streamServer) {
      this.executor.rosterSink = (evt) => this.streamServer.onRosterEvent(evt);
    }
  }

  launchChromium() {
    const chromium = this.chromium || require("playwright").chromium;
    const opts = { headless: true, args: ["--no-sandbox"] };
    if (this.config.chromiumPath) opts.executablePath = this.config.chromiumPath;
    return chromium.launch(opts);
  }

  start() {
    if (this.streamServer) {
      try { this.streamServer.start(); }
      catch (err) { this.log(`stream server failed to start: ${err && err.message}`); }
    }
    this.connect();
    process.on("SIGTERM", () => this.shutdown("SIGTERM"));
    process.on("SIGINT", () => this.shutdown("SIGINT"));
  }

  connect() {
    if (this.stopped) return;
    const protocols = this.config.token ? [`paseo.bearer.${this.config.token}`] : [];
    this.log(`connecting to ${this.config.wsUrl}`);
    let ws;
    try {
      ws = new WebSocket(this.config.wsUrl, protocols);
    } catch (err) {
      this.log(`connect threw: ${err.message}`);
      this.scheduleReconnect();
      return;
    }
    this.ws = ws;
    this.registered = false;

    ws.on("open", () => {
      this.reconnectMs = this.config.reconnectMinMs;
      this.sendHello();
    });
    ws.on("message", (data) => this.onMessage(data));
    ws.on("close", (code, reason) => {
      this.registered = false;
      this.log(`ws closed code=${code} reason=${reason ? reason.toString() : ""}`);
      this.scheduleReconnect();
    });
    ws.on("error", (err) => {
      this.log(`ws error: ${err.message}`);
      // 'close' fires after 'error'; reconnect scheduled there.
    });
  }

  sendHello() {
    const hello = {
      type: "hello",
      clientId: this.config.clientId,
      clientType: "cli",
      protocolVersion: WS_PROTOCOL_VERSION,
      capabilities: {
        browser_host: { hostKind: this.config.hostKind, supportedCommands: SUPPORTED_COMMANDS },
      },
    };
    this.send(hello);
    this.registered = true;
    this.log(`hello sent; advertised browser_host (${SUPPORTED_COMMANDS.length} commands, hostKind=${this.config.hostKind})`);
  }

  async onMessage(data) {
    let msg;
    try {
      msg = JSON.parse(data.toString());
    } catch {
      return; // non-JSON / binary frames are not for us
    }
    if (!msg || msg.type !== "session" || !msg.message) return;
    const inner = msg.message;
    if (inner.type !== "browser.automation.execute.request") return;

    const requestId = inner.requestId;
    const cmdName = inner.command && inner.command.command;
    const started = Date.now();
    this.log(`request ${cmdName} (${requestId})`);
    let payload;
    try {
      payload = await this.executor.execute({
        requestId,
        command: inner.command,
        workspaceId: inner.workspaceId,
        agentId: inner.agentId,
        cwd: inner.cwd,
      });
    } catch (err) {
      // Executor.execute never throws, but guard anyway so we always answer.
      payload = {
        requestId,
        ok: false,
        error: { code: "browser_unknown_error", message: String(err && err.message || err), retryable: false },
      };
    }
    const ms = Date.now() - started;
    this.log(`response ${cmdName} (${requestId}) ok=${payload.ok}${payload.ok ? "" : " code=" + (payload.error && payload.error.code)} ${ms}ms`);
    this.send({ type: "session", message: { type: "browser.automation.execute.response", payload } });
  }

  send(obj) {
    const ws = this.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      this.log("send skipped: socket not open");
      return;
    }
    ws.send(JSON.stringify(obj));
  }

  scheduleReconnect() {
    if (this.stopped) return;
    if (this.reconnectTimer) return;
    const delay = this.reconnectMs;
    this.reconnectMs = Math.min(this.reconnectMs * 2, this.config.reconnectMaxMs);
    this.log(`reconnecting in ${delay}ms`);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delay);
  }

  async shutdown(reason) {
    if (this.stopped) return;
    this.stopped = true;
    this.log(`shutting down (${reason})`);
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    try { if (this.ws) this.ws.close(); } catch {}
    try { if (this.streamServer) await this.streamServer.shutdown(); } catch {}
    try { await this.executor.shutdown(); } catch {}
    process.exit(0);
  }
}

module.exports = { BrowseHost, readConfig };

if (require.main === module) {
  new BrowseHost().start();
}
