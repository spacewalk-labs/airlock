// SPDX-License-Identifier: Apache-2.0
"use strict";
// Playwright-backed executor for Paseo browser automation commands.
//
// One executor owns a single headless Chromium. Isolation & ordering (task doc §5):
//   workspaceId -> BrowserContext   (cookie/storage isolation)
//   browserId   -> Page             (a "tab")
//   per-tab serial queue            (the broker does NOT order commands per tab)
//
// Refs: Paseo commands carry ref "@eN"; Playwright's ai-mode aria snapshot emits
// "[ref=eN]" and resolves via the "aria-ref=eN" selector. We wrap emitted refs
// with "@" and strip it back on resolve. A ref that no longer resolves (DOM
// changed / navigated) surfaces as browser_stale_ref.

const { randomUUID } = require("node:crypto");
const security = require("./security.js");
const { BrowserDenied } = security;

const DEFAULT_VIEWPORT = { width: 1280, height: 800 };
const SNAPSHOT_MAX_CHARS = 200_000;
const SCREENSHOT_MAX_BYTES = 8_000_000; // ~8 MB PNG cap before we refuse
const REDACT_KEY_RE = /^(token|key|secret|code|auth|access_token|password|email)$/i;

function capText(value) {
  return String(value ?? "").slice(0, 1024);
}

function safeUrl(page) {
  try { return page.url(); } catch { return ""; }
}

function redactText(value) {
  let text = capText(value);
  text = text.replace(/Bearer\s+\S+/gi, "Bearer <redacted>");
  // Long opaque tokens — hex / base64 / base64url (incl. - and _, e.g. JWT segments).
  text = text.replace(/[A-Za-z0-9+/_-]{32,}={0,2}/g, "<redacted>");
  // key:value / key=value for secret-bearing keys — short values too (a token
  // need not be long). Mirrors the URL key set minus the high-false-positive
  // generics (code/email/key) that would shred ordinary console text.
  text = text.replace(/("?(?:api[_-]?key|access[_-]?token|token|secret|password|auth)"?\s*[:=]\s*)"?[^\s"]+/gi, "$1<redacted>");
  return capText(text);
}

function redactUrl(value) {
  const raw = String(value ?? "");
  try {
    const url = new URL(raw);
    url.hash = "";        // OAuth implicit #access_token=… lives in the fragment
    url.username = "";     // strip userinfo user:pass@host (never a diagnostic need)
    url.password = "";
    for (const [key, item] of url.searchParams) {
      if (REDACT_KEY_RE.test(key)) url.searchParams.set(key, "<redacted>");
      else if (item) url.searchParams.set(key, redactText(item));
    }
    const path = url.pathname.split("/").map((segment) => {
      if (REDACT_KEY_RE.test(segment) || /^[A-Za-z0-9+/_-]{20,}={0,2}$/.test(segment)) {
        return "<redacted>";
      }
      return segment;
    });
    url.pathname = path.join("/");
    return capText(url.toString());
  } catch {
    return redactText(raw); // not a parseable URL — still scrub tokens, never raw
  }
}

// A command handler either returns a result object (merged into the ok payload)
// or throws HostError / BrowserDenied to become a failure payload.
class HostError extends Error {
  constructor(code, message, retryable = false) {
    super(message);
    this.name = "HostError";
    this.code = code;
    this.retryable = retryable;
  }
}

class BrowserHostExecutor {
  constructor({ log, launchChromium, maxTabs = 24, defaultTimeoutMs = 12_000, urlPolicy } = {}) {
    this.log = log ?? (() => {});
    this.launchChromium = launchChromium; // () => Promise<Browser>
    this.maxTabs = maxTabs;
    this.defaultTimeoutMs = defaultTimeoutMs;
    // URL policy is injectable for testing; defaults to the real SSRF guard.
    this.assertUrlAllowed = (urlPolicy && urlPolicy.assertUrlAllowed) || security.assertUrlAllowed;
    this.shouldAbortSubRequest = (urlPolicy && urlPolicy.shouldAbortSubRequest) || security.shouldAbortSubRequest;
    this.browser = null;
    this.browserPromise = null;
    this.contexts = new Map(); // workspaceId -> { context, guardInstalled }
    this.tabs = new Map(); // browserId -> { page, workspaceId, tail }
    this.workspaceLocks = new Map(); // workspaceId -> Promise (serialize new_tab)
    this.pendingTabs = new Map(); // browserId -> Promise<tab> (ensureTab dedupe, §14.4)
    // single nullable callback; host.js injects the roster broadcaster. NOT an EventEmitter (one consumer; a throwing listener must never corrupt executor critical paths).
    this.rosterSink = null;
  }

  // Fan a tab lifecycle event to the roster broadcaster, if wired. Never throws
  // into the caller (open/close/crash run on Playwright critical paths).
  emitRoster(evt) {
    try { if (this.rosterSink) this.rosterSink(evt); }
    catch (e) { this.log("roster sink error: " + (e && e.message)); }
  }

  async ensureBrowser() {
    if (this.browser) return this.browser;
    if (!this.browserPromise) {
      this.browserPromise = Promise.resolve(this.launchChromium()).then((b) => {
        this.browser = b;
        b.on("disconnected", () => {
          this.browser = null;
          this.browserPromise = null;
          this.contexts.clear();
          this.tabs.clear();
          this.emitRoster({ kind: "reset", reason: "chromium_disconnected" });
          this.log("chromium disconnected; state reset");
        });
        return b;
      });
      this.browserPromise.catch(() => {
        this.browserPromise = null;
      });
    }
    return this.browserPromise;
  }

  async ensureContext(workspaceId) {
    const existing = this.contexts.get(workspaceId);
    if (existing) return existing.context;
    const browser = await this.ensureBrowser();
    const context = await browser.newContext({ viewport: DEFAULT_VIEWPORT });
    context.setDefaultTimeout(this.defaultTimeoutMs);
    // Route guard: abort sub-requests to literal private IPs (SSRF depth-2).
    await context.route("**/*", (route) => {
      const url = route.request().url();
      if (this.shouldAbortSubRequest(url)) {
        route.abort("blockedbyclient").catch(() => {});
        return;
      }
      route.continue().catch(() => {});
    });
    // Auto-dismiss dialogs so a stray alert()/confirm() can't stall a command.
    context.on("dialog", (dialog) => {
      dialog.dismiss().catch(() => {});
    });
    this.contexts.set(workspaceId, { context });
    return context;
  }

  // Serialize a mutation on a single tab's queue.
  runOnTab(browserId, workspaceId, fn) {
    const tab = this.tabs.get(browserId);
    if (!tab || tab.workspaceId !== workspaceId) {
      return Promise.reject(
        new HostError("browser_tab_not_found", `No browser tab found for ID: ${browserId}`),
      );
    }
    const run = tab.tail.then(() => fn(tab));
    tab.tail = run.then(
      () => {},
      () => {},
    );
    return run;
  }

  // Serialize new_tab per workspace (context creation race).
  runOnWorkspace(workspaceId, fn) {
    const prev = this.workspaceLocks.get(workspaceId) ?? Promise.resolve();
    const run = prev.then(() => fn());
    this.workspaceLocks.set(
      workspaceId,
      run.then(
        () => {},
        () => {},
      ),
    );
    return run;
  }

  // Create a page bound to browserId in its workspace context. Caller holds the
  // workspace lock. Shared by cmdNewTab (agent) and ensureTab (stream, §14.4).
  async _openPage(browserId, workspaceId, origin) {
    const context = await this.ensureContext(workspaceId);
    const page = await context.newPage();
    const tab = {
      browserId,
      page,
      workspaceId,
      origin,
      tail: Promise.resolve(),
      logs: { console: [], network: [] },
      navGen: 0,
      closed: false,
    };
    const reqStart = new WeakMap();
    const push = (kind, entry) => {
      try {
        const ring = tab.logs[kind];
        ring.push(entry);
        while (ring.length > 200) ring.shift();
      } catch {}
    };
    page.on("console", (message) => {
      try {
        const location = message.location();
        const source = location && location.url ? location.url : undefined;
        const line = location && Number.isInteger(location.lineNumber) ? location.lineNumber : undefined;
        push("console", {
          level: { error: "error", warning: "warning", debug: "debug" }[message.type()] || "info",
          message: redactText(message.text()),
          timestamp: Date.now(),
          ...(source ? { source: redactUrl(source) } : {}),
          ...(line !== undefined ? { line } : {}),
        });
      } catch {}
    });
    page.on("pageerror", (error) => {
      try {
        push("console", {
          level: "error",
          message: redactText((error.message || "") + (error.stack ? `\n${error.stack}` : "")),
          timestamp: Date.now(),
        });
      } catch {}
    });
    page.on("request", (request) => {
      try { reqStart.set(request, Date.now()); } catch {}
    });
    page.on("response", async (response) => {
      try {
        const status = response.status();
        if (status < 400) return;
        const request = response.request();
        const startTime = reqStart.get(request) || Date.now();
        push("network", {
          url: redactUrl(request.url()),
          startTime,
          duration: Date.now() - startTime,
          method: request.method(),
          status,
          type: request.resourceType(),
        });
      } catch {}
    });
    page.on("requestfailed", (request) => {
      try {
        if (this.shouldAbortSubRequest(request.url())) return;
        const startTime = reqStart.get(request) || Date.now();
        const url = redactUrl(request.url());
        const failure = request.failure();
        const failureText = failure && failure.errorText || "failed";
        push("console", {
          level: "error",
          message: redactText(`network request failed: ${request.method()} ${url} — ${failureText}`),
          timestamp: Date.now(),
        });
        push("network", {
          url,
          startTime,
          duration: Date.now() - startTime,
          method: request.method(),
          type: request.resourceType(),
        });
      } catch {}
    });
    this.tabs.set(browserId, tab);
    this.emitRoster({ kind: "open", browserId, workspaceId, origin, url: safeUrl(page), title: "", status: "open" });
    page.on("framenavigated", (frame) => {
      if (frame !== page.mainFrame()) return;
      const gen = ++tab.navGen;
      const url = safeUrl(page);
      this._scheduleNavEmit(tab, gen, url);
    });
    let finalized = false;
    const finalize = (reason) => {
      if (finalized || this.tabs.get(browserId) !== tab) {
        finalized = true;
        tab.closed = true;
        return;
      }
      finalized = true;
      tab.closed = true;
      if (tab._navTimer) clearTimeout(tab._navTimer);
      this.tabs.delete(browserId);
      this.emitRoster({ kind: "close", browserId, workspaceId, origin, ...(reason ? { reason } : {}) });
    };
    page.on("close", () => finalize());
    page.on("crash", () => {
      finalize("crash");
      try { page.close().catch(() => {}); } catch {}
    });
    return tab;
  }

  _scheduleNavEmit(tab, gen, url) {
    if (tab._navTimer) clearTimeout(tab._navTimer);
    tab._navTimer = setTimeout(async () => {
      if (tab.navGen !== gen || tab.closed) return;
      let title = "";
      try { title = await tab.page.title(); } catch {}
      if (tab.navGen !== gen || tab.closed || this.tabs.get(tab.browserId) !== tab) return;
      let closed = false;
      try { closed = tab.page.isClosed(); } catch {}
      if (closed) return;
      tab.title = title;
      this.emitRoster({ kind: "nav", browserId: tab.browserId, workspaceId: tab.workspaceId, origin: tab.origin, url, title, status: "open" });
    }, 300);
  }

  // Agent-origin tabs only (human viewer tabs are not surfaced). Shape mirrors the
  // "open"/"nav" event tab fields so the client reconciles by browserId.
  rosterSnapshot() {
    const out = [];
    for (const [browserId, tab] of this.tabs) {
      if (tab.origin !== "agent") continue;
      out.push({ browserId, workspaceId: tab.workspaceId, origin: tab.origin, url: safeUrl(tab.page), title: tab.title || "", status: "open" });
    }
    return out;
  }

  // Idempotent create-or-get for a client-supplied browserId (§14.4). Both the
  // live-view stream transport and agent automation may call this and share one
  // page (display == automation target). Concurrent calls return the same
  // in-flight creation promise. A browserId is bound to one workspace for life;
  // rebinding to a different workspace is refused (split-brain guard).
  ensureTab(browserId, workspaceId, initialUrl) {
    const existing = this.tabs.get(browserId);
    if (existing) {
      if (existing.workspaceId !== workspaceId) {
        return Promise.reject(new HostError(
          "browser_denied",
          `browserId ${browserId} is already bound to a different workspace.`,
        ));
      }
      return Promise.resolve(existing);
    }
    const pending = this.pendingTabs.get(browserId);
    if (pending) {
      // A create is in flight. Isolation must hold on the concurrent path too:
      // validate the requester's workspace against the tab it resolves to (the
      // in-flight tab may belong to another workspace).
      return pending.then((tab) => {
        if (tab.workspaceId !== workspaceId) {
          throw new HostError("browser_denied", `browserId ${browserId} is already bound to a different workspace.`);
        }
        return tab;
      });
    }
    // No await between the get above and this set → concurrent callers dedupe.
    const p = this._createTab(browserId, workspaceId, initialUrl);
    this.pendingTabs.set(browserId, p);
    const clear = () => {
      if (this.pendingTabs.get(browserId) === p) this.pendingTabs.delete(browserId);
    };
    p.then(clear, clear);
    return p;
  }

  async _createTab(browserId, workspaceId, initialUrl) {
    if (initialUrl) await this.assertUrlAllowed(initialUrl);
    return this.runOnWorkspace(workspaceId, async () => {
      const again = this.tabs.get(browserId);
      if (again) return again;
      if (this.countTabs() >= this.maxTabs) {
        throw new HostError("browser_denied", `Tab limit reached (${this.maxTabs}).`);
      }
      const tab = await this._openPage(browserId, workspaceId, "viewer");
      if (initialUrl) {
        try {
          await tab.page.goto(initialUrl, { waitUntil: "domcontentloaded" });
        } catch (err) {
          // Keep the tab even if the initial nav fails; the live view can retry.
          this.log(`ensureTab initial nav failed for ${browserId}: ${err.message}`);
        }
      }
      return tab;
    });
  }

  getTab(browserId) {
    return this.tabs.get(browserId) || null;
  }

  countTabs() {
    return this.tabs.size;
  }

  // request: { requestId, command:{command,args}, workspaceId?, agentId?, cwd? }
  // returns a response payload (ok:true{result} | ok:false{error}).
  async execute(request) {
    const requestId = request.requestId;
    const command = request.command;
    const workspaceId = request.workspaceId || "default";
    try {
      const result = await this.dispatch(command, workspaceId);
      return { requestId, ok: true, result };
    } catch (err) {
      const code = err instanceof HostError ? err.code
        : err instanceof BrowserDenied ? "browser_denied"
        : "browser_unknown_error";
      const retryable = err instanceof HostError ? err.retryable : false;
      const message = err && err.message ? err.message : String(err);
      this.log(`command ${command && command.command} failed: ${code}: ${message}`);
      return { requestId, ok: false, error: { code, message, retryable } };
    }
  }

  async dispatch(command, workspaceId) {
    const name = command.command;
    const args = command.args || {};
    switch (name) {
      case "list_tabs":
        return this.cmdListTabs(workspaceId);
      case "new_tab":
        return this.cmdNewTab(args, workspaceId);
      case "navigate":
        return this.runOnTab(args.browserId, workspaceId, (tab) => this.cmdNavigate(tab, args));
      case "back":
        return this.runOnTab(args.browserId, workspaceId, (tab) => this.cmdBack(tab));
      case "forward":
        return this.runOnTab(args.browserId, workspaceId, (tab) => this.cmdForward(tab));
      case "reload":
        return this.runOnTab(args.browserId, workspaceId, (tab) => this.cmdReload(tab));
      case "snapshot":
        return this.runOnTab(args.browserId, workspaceId, (tab) => this.cmdSnapshot(tab));
      case "screenshot":
        return this.runOnTab(args.browserId, workspaceId, (tab) => this.cmdScreenshot(tab, args));
      case "click":
        return this.runOnTab(args.browserId, workspaceId, (tab) => this.cmdClick(tab, args));
      case "fill":
        return this.runOnTab(args.browserId, workspaceId, (tab) => this.cmdFill(tab, args));
      case "wait":
        return this.runOnTab(args.browserId, workspaceId, (tab) => this.cmdWait(tab, args));
      case "close_tab":
        return this.runOnTab(args.browserId, workspaceId, (tab) => this.cmdCloseTab(tab));
      case "logs":
        return this.runOnTab(args.browserId, workspaceId, (tab) => this.cmdLogs(tab, args));
      default:
        throw new HostError("browser_unsupported", `Command "${name}" is not implemented by this host.`);
    }
  }

  async cmdNewTab(args, workspaceId) {
    if (this.countTabs() >= this.maxTabs) {
      throw new HostError("browser_denied", `Tab limit reached (${this.maxTabs}).`);
    }
    if (args.url) await this.assertUrlAllowed(args.url);
    return this.runOnWorkspace(workspaceId, async () => {
      const tab = await this._openPage(randomUUID(), workspaceId, "agent");
      if (args.url) {
        try {
          await tab.page.goto(args.url, { waitUntil: "domcontentloaded" });
        } catch (err) {
          try { await tab.page.close(); } catch {}
          throw new HostError("browser_unknown_error", `Navigation failed: ${err.message}`, true);
        }
      }
      return { command: "new_tab", browserId: tab.browserId, workspaceId, url: tab.page.url() || "about:blank" };
    });
  }

  cmdListTabs(workspaceId) {
    const tabs = [];
    for (const [browserId, tab] of this.tabs) {
      if (tab.workspaceId !== workspaceId) continue;
      let url = "";
      let title = "";
      try { url = tab.page.url(); } catch {}
      tabs.push({
        browserId,
        workspaceId: tab.workspaceId,
        url,
        title,
        isActive: false,
        isLoading: false,
      });
    }
    // Titles need an await; fetch them in parallel then attach.
    return Promise.all(
      tabs.map(async (t) => {
        const tab = this.tabs.get(t.browserId);
        try { t.title = await tab.page.title(); } catch {}
        return t;
      }),
    ).then((withTitles) => ({ command: "list_tabs", tabs: withTitles }));
  }

  async cmdNavigate(tab, args) {
    await this.assertUrlAllowed(args.url);
    try {
      await tab.page.goto(args.url, { waitUntil: "domcontentloaded" });
    } catch (err) {
      throw new HostError("browser_unknown_error", `Navigation failed: ${err.message}`, true);
    }
    return { command: "navigate", browserId: tab.browserId, url: tab.page.url() };
  }

  // back/forward/reload back the live-view toolbar (§14.6/§14.9). goBack/goForward
  // return null (not an error) when there is no history entry — that is fine.
  async cmdBack(tab) {
    try {
      await tab.page.goBack({ waitUntil: "domcontentloaded" });
    } catch (err) {
      throw new HostError("browser_unknown_error", `Back failed: ${err.message}`, true);
    }
    return { command: "back", browserId: tab.browserId, url: tab.page.url() };
  }

  async cmdForward(tab) {
    try {
      await tab.page.goForward({ waitUntil: "domcontentloaded" });
    } catch (err) {
      throw new HostError("browser_unknown_error", `Forward failed: ${err.message}`, true);
    }
    return { command: "forward", browserId: tab.browserId, url: tab.page.url() };
  }

  async cmdReload(tab) {
    try {
      await tab.page.reload({ waitUntil: "domcontentloaded" });
    } catch (err) {
      throw new HostError("browser_unknown_error", `Reload failed: ${err.message}`, true);
    }
    return { command: "reload", browserId: tab.browserId, url: tab.page.url() };
  }

  async cmdSnapshot(tab) {
    let raw;
    try {
      raw = await tab.page.locator("body").ariaSnapshot({ mode: "ai" });
    } catch (err) {
      throw new HostError("browser_unknown_error", `Snapshot failed: ${err.message}`);
    }
    // Emit Paseo-style refs: [ref=eN] -> [ref=@eN]
    const snapshot = raw.replace(/\[ref=(e\d+)\]/g, "[ref=@$1]");
    const truncated = snapshot.length > SNAPSHOT_MAX_CHARS;
    const body = truncated ? snapshot.slice(0, SNAPSHOT_MAX_CHARS) : snapshot;
    const refCount = (snapshot.match(/\[ref=@e\d+\]/g) || []).length;
    const nodeCount = (snapshot.match(/^\s*- /gm) || []).length;
    let url = "";
    let title = "";
    try { url = tab.page.url(); } catch {}
    try { title = await tab.page.title(); } catch {}
    return {
      command: "snapshot",
      browserId: tab.browserId,
      workspaceId: tab.workspaceId,
      url,
      title,
      format: "aria-yaml",
      snapshot: body,
      truncated,
      stats: { nodeCount, refCount, textLength: body.length },
    };
  }

  async cmdScreenshot(tab, args) {
    let buf;
    try {
      buf = await tab.page.screenshot({ fullPage: Boolean(args.fullPage), type: "png" });
    } catch (err) {
      throw new HostError("screenshot_no_frame", `Screenshot failed: ${err.message}`, true);
    }
    if (buf.length > SCREENSHOT_MAX_BYTES) {
      throw new HostError("browser_denied", `Screenshot too large (${buf.length} bytes).`);
    }
    const size = tab.page.viewportSize() || DEFAULT_VIEWPORT;
    return {
      command: "screenshot",
      browserId: tab.browserId,
      mimeType: "image/png",
      dataBase64: buf.toString("base64"),
      width: size.width,
      height: size.height,
    };
  }

  async cmdClick(tab, args) {
    const locator = this.refLocator(tab, args.ref);
    try {
      await locator.click({
        button: args.button || "left",
        clickCount: args.doubleClick ? 2 : 1,
        modifiers: args.modifiers && args.modifiers.length ? args.modifiers : undefined,
      });
    } catch (err) {
      throw this.mapRefError(err, args.ref);
    }
    return { command: "click", browserId: tab.browserId, ref: args.ref };
  }

  async cmdFill(tab, args) {
    const locator = this.refLocator(tab, args.ref);
    try {
      await locator.fill(args.value);
    } catch (err) {
      throw this.mapRefError(err, args.ref);
    }
    return { command: "fill", browserId: tab.browserId, ref: args.ref };
  }

  async cmdWait(tab, args) {
    const timeout = args.timeoutMs || this.defaultTimeoutMs;
    if (args.text) {
      try {
        await tab.page.getByText(args.text, { exact: false }).first().waitFor({ state: "visible", timeout });
      } catch (err) {
        throw new HostError("browser_timeout", `Timed out waiting for text: ${args.text}`, true);
      }
      return { command: "wait", browserId: tab.browserId, matched: "text" };
    }
    // url
    try {
      await tab.page.waitForURL((u) => u.href.includes(args.url), { timeout });
    } catch (err) {
      throw new HostError("browser_timeout", `Timed out waiting for url: ${args.url}`, true);
    }
    return { command: "wait", browserId: tab.browserId, matched: "url" };
  }

  async cmdCloseTab(tab) {
    const browserId = tab.browserId;
    try {
      await tab.page.close();   // fires page.on("close") -> tabs.delete + roster close (single source)
    } catch (err) {
      throw new HostError("browser_unknown_error", `Close failed: ${err.message}`, true);
    }
    return { command: "close_tab", browserId };
  }

  async cmdLogs(tab, args) {
    const n = Math.min(Math.max(1, args.maxEntries || 50), 200);
    return {
      command: "logs",
      browserId: tab.browserId,
      console: tab.logs.console.slice(-n),
      network: tab.logs.network.slice(-n),
    };
  }

  // "@eN" -> locator("aria-ref=eN")
  refLocator(tab, ref) {
    const id = String(ref).replace(/^@/, "");
    return tab.page.locator(`aria-ref=${id}`);
  }

  mapRefError(err, ref) {
    const msg = String(err && err.message);
    if (/aria-ref|resolve|no element|not found|strict mode/i.test(msg)) {
      return new HostError("browser_stale_ref", `Ref ${ref} no longer resolves; take a fresh snapshot.`, true);
    }
    if (/Timeout/i.test(msg)) {
      return new HostError("browser_timeout", msg, true);
    }
    return new HostError("browser_unknown_error", msg);
  }

  async shutdown() {
    if (this.browser) {
      try { await this.browser.close(); } catch {}
    }
  }
}


module.exports = { BrowserHostExecutor, HostError, redactText, redactUrl };
