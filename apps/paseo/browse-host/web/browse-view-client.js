// SPDX-License-Identifier: Apache-2.0
/* paseo-browse-host — live browser panel companion (task doc §14.2).
 *
 * Loaded by the self-hosted paseo web-ui (index.html <script>, injected at
 * install). All the high-churn live-view logic lives HERE, out of the 14 MB
 * minified bundle, so upstream version bumps don't break it (orca-web lockstep
 * lesson). The bundle patch is minimal: it (1) un-gates the "New browser" button
 * on web and (2) marks the BrowserPane container with
 *   data-paseo-browser-id / data-paseo-workspace-id / data-paseo-server-id
 * which we observe here and turn into a live canvas + toolbar wired to the
 * owner-gated wss://<host>/browse-view/<browserId> stream.
 *
 * Wire format (§14.5): server->client binary frame = [u32LE headerLen][headerJSON][jpeg];
 * text messages = JSON {type:"ready"|"state"|"error"}. client->server = JSON
 * {type:"hello"|"mouse"|"text"|"key"|"nav"|"resize"}.
 */
// A terminal WS close means "page gone; do NOT reconnect" (§5.4). App range 4xxx.
function isTerminalCloseCode(code) { return code === 4001; }
function closeAction(code, alreadyClosed) {
  if (alreadyClosed) return "none";
  return isTerminalCloseCode(code) ? "terminal" : "reconnect";
}

// Reduce a roster message onto a Map<browserId, tab>. Pure; unit-tested.
function applyRosterMessage(map, msg) {
  if (!msg || typeof msg !== "object") return map;
  if (msg.type === "snapshot") {
    map.clear();
    (msg.tabs || []).forEach(function (t) { if (t && t.browserId) map.set(t.browserId, t); });
  } else if (msg.type === "upsert" && msg.tab && msg.tab.browserId) map.set(msg.tab.browserId, msg.tab);
  else if (msg.type === "remove" && msg.browserId) map.delete(msg.browserId);
  else if (msg.type === "reset") map.clear();
  return map;
}

(function () {
  "use strict";
  if (typeof window !== "undefined" && window.__paseoBrowseViewInstalled) return;
  if (typeof document === "undefined") return;
  window.__paseoBrowseViewInstalled = true;

  var MARKER = "data-paseo-browser-id";
  var mounted = new WeakSet();

  function wsBase() {
    // wss only: paseo is reachable over https alone (Airlock's plaintext ports
    // serve nothing but a 301), so a ws:// fallback would only downgrade.
    return "wss://" + location.host + "/browse-view/";
  }

  function modsOf(e) {
    return { alt: e.altKey, ctrl: e.ctrlKey, meta: e.metaKey, shift: e.shiftKey };
  }

  // A live panel bound to one BrowserPane container element.
  function LivePanel(container) {
    this.container = container;
    this.browserId = container.getAttribute(MARKER);
    this.workspaceId = container.getAttribute("data-paseo-workspace-id") || "default";
    this.expectExisting = container.getAttribute("data-paseo-expect-existing") === "1";
    this.ws = null;
    this.closed = false;
    this.frameW = 0;
    this.frameH = 0;
    this.reconnectMs = 500;
    this.pendingMove = null;
    this.buildDom();
    this.connect();
    this.observeRemoval();
  }

  LivePanel.prototype.buildDom = function () {
    var c = this.container;
    if (getComputedStyle(c).position === "static") c.style.position = "relative";

    var overlay = document.createElement("div");
    overlay.style.cssText =
      "position:absolute;inset:0;display:flex;flex-direction:column;background:#181b1a;z-index:2;";

    var bar = document.createElement("div");
    bar.style.cssText =
      "display:flex;gap:6px;padding:6px;background:#22262b;align-items:center;flex:0 0 auto;";
    var mk = function (label, title) {
      var b = document.createElement("button");
      b.textContent = label;
      b.title = title || label;
      b.style.cssText =
        "background:#2f353c;color:#dfe3e6;border:0;border-radius:4px;padding:4px 8px;cursor:pointer;font:13px system-ui;";
      return b;
    };
    var self = this;
    var back = mk("←", "Back");
    var fwd = mk("→", "Forward");
    var reload = mk("↻", "Reload");
    back.onclick = function () { self.send({ type: "nav", action: "back" }); };
    fwd.onclick = function () { self.send({ type: "nav", action: "forward" }); };
    reload.onclick = function () { self.send({ type: "nav", action: "reload" }); };

    var url = document.createElement("input");
    url.type = "text";
    url.placeholder = "Enter a URL and press Enter";
    url.spellcheck = false;
    url.style.cssText =
      "flex:1 1 auto;min-width:0;background:#12151a;color:#dfe3e6;border:1px solid #333a42;border-radius:4px;padding:5px 8px;font:13px system-ui;";
    url.addEventListener("keydown", function (e) {
      if (e.key === "Enter") { e.stopPropagation(); self.navigate(url.value.trim()); }
    });
    this.urlInput = url;

    bar.appendChild(back); bar.appendChild(fwd); bar.appendChild(reload); bar.appendChild(url);

    var canvas = document.createElement("canvas");
    canvas.tabIndex = 0;
    canvas.style.cssText =
      "flex:1 1 auto;width:100%;height:100%;min-height:0;display:block;background:#0d0f12;outline:none;cursor:default;";
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");

    var status = document.createElement("div");
    status.style.cssText =
      "position:absolute;left:0;right:0;bottom:0;padding:4px 8px;background:rgba(20,22,25,.85);color:#9aa4ad;font:12px system-ui;display:none;z-index:3;";
    this.status = status;

    overlay.appendChild(bar);
    overlay.appendChild(canvas);
    overlay.appendChild(status);
    c.appendChild(overlay);
    this.overlay = overlay;

    this.wireInput();
    this.wireResize();
  };

  LivePanel.prototype.setStatus = function (text) {
    if (!text) { this.status.style.display = "none"; return; }
    this.status.textContent = text;
    this.status.style.display = "block";
  };

  // Map a DOM pointer event to page coordinates in the frame's pixel space.
  LivePanel.prototype.toPage = function (e) {
    var r = this.canvas.getBoundingClientRect();
    var w = this.frameW || r.width || 1;
    var h = this.frameH || r.height || 1;
    return {
      x: (e.clientX - r.left) / (r.width || 1) * w,
      y: (e.clientY - r.top) / (r.height || 1) * h,
    };
  };

  LivePanel.prototype.wireInput = function () {
    var self = this;
    var cv = this.canvas;
    cv.addEventListener("mousedown", function (e) {
      e.preventDefault(); cv.focus();
      var p = self.toPage(e);
      self.send({ type: "mouse", event: "down", x: p.x, y: p.y, button: btn(e.button), buttons: e.buttons, clickCount: e.detail || 1, modifiers: modsOf(e) });
    });
    cv.addEventListener("mouseup", function (e) {
      var p = self.toPage(e);
      self.send({ type: "mouse", event: "up", x: p.x, y: p.y, button: btn(e.button), buttons: e.buttons, clickCount: e.detail || 1, modifiers: modsOf(e) });
    });
    // Coalesce moves to one per animation frame.
    cv.addEventListener("mousemove", function (e) {
      var p = self.toPage(e);
      self.pendingMove = { type: "mouse", event: "move", x: p.x, y: p.y, buttons: e.buttons, modifiers: modsOf(e) };
      if (!self.moveRaf) {
        self.moveRaf = requestAnimationFrame(function () {
          self.moveRaf = 0;
          if (self.pendingMove) { self.send(self.pendingMove); self.pendingMove = null; }
        });
      }
    });
    cv.addEventListener("wheel", function (e) {
      e.preventDefault();
      var p = self.toPage(e);
      self.send({ type: "mouse", event: "wheel", x: p.x, y: p.y, deltaX: e.deltaX, deltaY: e.deltaY, modifiers: modsOf(e) });
    }, { passive: false });
    cv.addEventListener("contextmenu", function (e) { e.preventDefault(); });

    cv.addEventListener("keydown", function (e) {
      // Printable, no ctrl/meta -> insert as text (IME-robust). Else control key.
      if (e.key && e.key.length === 1 && !e.ctrlKey && !e.metaKey) {
        e.preventDefault();
        self.send({ type: "text", text: e.key });
      } else {
        e.preventDefault();
        self.send({ type: "key", event: "down", key: e.key, code: e.code, modifiers: modsOf(e) });
      }
    });
    cv.addEventListener("keyup", function (e) {
      if (!(e.key && e.key.length === 1 && !e.ctrlKey && !e.metaKey)) {
        self.send({ type: "key", event: "up", key: e.key, code: e.code, modifiers: modsOf(e) });
      }
    });
  };

  function btn(n) { return n === 2 ? "right" : n === 1 ? "middle" : "left"; }

  LivePanel.prototype.wireResize = function () {
    var self = this;
    var send = function () {
      var r = self.canvas.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) {
        self.send({ type: "resize", width: Math.round(r.width), height: Math.round(r.height) });
      }
    };
    this.ro = new ResizeObserver(function () {
      clearTimeout(self.resizeT);
      self.resizeT = setTimeout(send, 150);
    });
    this.ro.observe(this.canvas);
  };

  LivePanel.prototype.navigate = function (raw) {
    if (!raw) return;
    var u = raw;
    if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(u)) u = "https://" + u;
    this.send({ type: "nav", action: "navigate", url: u });
  };

  LivePanel.prototype.connect = function () {
    if (this.closed) return;
    var self = this;
    this.setStatus("Connecting…");
    var ws;
    try { ws = new WebSocket(wsBase() + encodeURIComponent(this.browserId)); }
    catch (e) { this.scheduleReconnect(); return; }
    ws.binaryType = "arraybuffer";
    this.ws = ws;
    ws.onopen = function () {
      self.reconnectMs = 500;
      var r = self.canvas.getBoundingClientRect();
      self.send({
        type: "hello", protocolVersion: 1, workspaceId: self.workspaceId,
        width: Math.round(r.width) || undefined, height: Math.round(r.height) || undefined,
        ...(self.expectExisting ? { expectExisting: true } : {}),
      });
    };
    ws.onmessage = function (ev) {
      if (typeof ev.data === "string") { self.onText(ev.data); return; }
      self.onFrame(ev.data);
    };
    ws.onclose = function (ev) {
      self.ws = null;
      var action = closeAction(ev && ev.code, self.closed);
      if (action === "none") return;
      if (action === "terminal") { self.setStatus("Closed by agent"); self.dispose(); return; }
      self.setStatus("Reconnecting…"); self.scheduleReconnect();
    };
    ws.onerror = function () { try { ws.close(); } catch (e) {} };
  };

  LivePanel.prototype.scheduleReconnect = function () {
    if (this.closed) return;
    var self = this;
    setTimeout(function () { self.connect(); }, this.reconnectMs);
    this.reconnectMs = Math.min(this.reconnectMs * 2, 10000);
  };

  LivePanel.prototype.onText = function (data) {
    var msg;
    try { msg = JSON.parse(data); } catch (e) { return; }
    if (msg.type === "ready") { this.setStatus(""); }
    else if (msg.type === "state") {
      if (document.activeElement !== this.urlInput && typeof msg.url === "string") this.urlInput.value = msg.url;
    } else if (msg.type === "error") {
      this.setStatus("Error: " + (msg.message || msg.code || "unknown"));
    } else if (msg.type === "tab_closed") {
      this.setStatus("Closed by agent");
      this.dispose();
    }
  };

  LivePanel.prototype.onFrame = function (buf) {
    if (!buf || buf.byteLength < 4) return;
    var dv = new DataView(buf);
    var headerLen = dv.getUint32(0, true);
    if (buf.byteLength < 4 + headerLen) return;
    var jpeg = new Uint8Array(buf, 4 + headerLen);
    var self = this;
    // Render via an <img> + object URL (not createImageBitmap — iOS/Safari
    // support for createImageBitmap(Blob) is unreliable and was rendering blank).
    var blob = new Blob([jpeg], { type: "image/jpeg" });
    var url = URL.createObjectURL(blob);
    var img = new Image();
    img.onload = function () {
      if (!self.closed) {
        var w = img.naturalWidth, h = img.naturalHeight;
        if (self.canvas.width !== w || self.canvas.height !== h) { self.canvas.width = w; self.canvas.height = h; }
        self.frameW = w; self.frameH = h;
        try { self.ctx.drawImage(img, 0, 0); } catch (e) {}
        self.setStatus(""); // pixels are flowing → clear any connecting/error note
      }
      URL.revokeObjectURL(url);
    };
    img.onerror = function () { URL.revokeObjectURL(url); };
    img.src = url;
  };

  LivePanel.prototype.send = function (obj) {
    if (this.ws && this.ws.readyState === 1) {
      try { this.ws.send(JSON.stringify(obj)); } catch (e) {}
    }
  };

  LivePanel.prototype.observeRemoval = function () {
    var self = this;
    // Tear down when the pane container leaves the DOM.
    this.removalObserver = new MutationObserver(function () {
      if (!document.contains(self.container)) self.dispose();
    });
    this.removalObserver.observe(document.body, { childList: true, subtree: true });
  };

  LivePanel.prototype.dispose = function () {
    if (this.closed) return;
    this.closed = true;
    if (this.ro) this.ro.disconnect();
    if (this.removalObserver) this.removalObserver.disconnect();
    if (this.ws) { try { this.ws.close(); } catch (e) {} this.ws = null; }
    mounted.delete(this.container);
    if (this.overlay && this.overlay.parentNode) this.overlay.parentNode.removeChild(this.overlay);
  };

  function scan(root) {
    var nodes = root.querySelectorAll ? root.querySelectorAll("[" + MARKER + "]") : [];
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (!mounted.has(el) && el.getAttribute(MARKER)) {
        mounted.add(el);
        try { new LivePanel(el); } catch (e) { /* keep the app alive */ }
      }
    }
  }

  function RosterDock() {
    this.tabs = new Map();
    this.ws = null;
    this.reconnectMs = 500;
    this.currentViewerId = null;
    this.buildDom();
    this.connect();
  }

  RosterDock.prototype.buildDom = function () {
    var self = this;
    var dock = document.createElement("div");
    dock.id = "paseo-agent-dock";
    dock.style.cssText = "position:fixed;right:16px;bottom:16px;z-index:2147483000;font:13px system-ui;color:#dfe3e6;";
    var chip = document.createElement("button");
    chip.className = "paseo-agent-chip";
    chip.style.cssText = "background:#263b52;color:#fff;border:1px solid #4d789f;border-radius:16px;padding:8px 13px;cursor:pointer;font:inherit;box-shadow:0 2px 8px #0008;";
    chip.onclick = function () { self.list.style.display = self.list.style.display === "none" ? "block" : "none"; };
    var list = document.createElement("div");
    list.className = "paseo-agent-list";
    list.style.cssText = "display:none;margin-bottom:6px;min-width:220px;max-width:360px;background:#20252b;border:1px solid #46515c;border-radius:6px;padding:4px;box-shadow:0 3px 14px #0009;";
    this.dock = dock;
    this.chip = chip;
    this.list = list;
    dock.appendChild(list);
    dock.appendChild(chip);
    document.body.appendChild(dock);
    this.render();
  };

  RosterDock.prototype.connect = function () {
    var self = this;
    try { this.ws = new WebSocket(wsBase() + "roster"); }
    catch (e) { this.scheduleReconnect(); return; }
    this.ws.onopen = function () { self.reconnectMs = 500; };
    this.ws.onmessage = function (ev) {
      var msg;
      try { msg = JSON.parse(ev.data); } catch (e) { return; }
      applyRosterMessage(self.tabs, msg);
      self.render();
      if (self.currentViewerId && !self.tabs.has(self.currentViewerId)) self.closeViewer();
    };
    this.ws.onclose = function () {
      self.ws = null;
      self.scheduleReconnect();
    };
    this.ws.onerror = function () { try { self.ws.close(); } catch (e) {} };
  };

  RosterDock.prototype.scheduleReconnect = function () {
    var self = this;
    setTimeout(function () { self.connect(); }, this.reconnectMs);
    this.reconnectMs = Math.min(this.reconnectMs * 2, 10000);
  };

  RosterDock.prototype.render = function () {
    var self = this;
    var tabs = Array.from(this.tabs.values());
    this.dock.style.display = tabs.length ? "block" : "none";
    this.chip.textContent = "Agent · " + tabs.length;
    while (this.list.firstChild) this.list.removeChild(this.list.firstChild);
    tabs.forEach(function (tab) {
      var item = document.createElement("button");
      item.className = "paseo-agent-item";
      item.dataset.rosterId = tab.browserId;
      item.textContent = (tab.url || tab.browserId.slice(0, 12)) + " · " + (tab.workspaceId || "").slice(0, 8);
      item.style.cssText = "display:block;width:100%;text-align:left;background:#2a3037;color:#dfe3e6;border:0;border-radius:4px;padding:7px 8px;margin:2px 0;cursor:pointer;font:inherit;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;";
      item.onclick = function () { self.openViewer(tab.browserId); };
      self.list.appendChild(item);
    });
  };

  RosterDock.prototype.openViewer = function (browserId) {
    var self = this;
    var tab = this.tabs.get(browserId);
    if (!tab) return;
    if (this.currentViewerId === browserId) return;
    this.closeViewer();
    var panel = document.createElement("div");
    panel.className = "paseo-agent-viewer";
    panel.style.cssText = "position:fixed;right:16px;bottom:56px;width:min(800px,calc(100vw - 32px));height:min(600px,calc(100vh - 88px));z-index:2147482999;background:#181b1a;border:1px solid #46515c;border-radius:6px;box-shadow:0 4px 22px #000b;";
    var close = document.createElement("button");
    close.textContent = "×";
    close.title = "Close viewer";
    close.style.cssText = "position:absolute;right:6px;top:4px;z-index:4;background:#2f353c;color:#fff;border:0;border-radius:4px;font-size:20px;line-height:24px;width:28px;cursor:pointer;";
    close.onclick = function () { self.closeViewer(); };
    var viewer = document.createElement("div");
    // Attributes must precede append: MutationObserver watches childList, not attributes.
    viewer.setAttribute(MARKER, browserId);
    viewer.setAttribute("data-paseo-workspace-id", tab.workspaceId || "default");
    viewer.setAttribute("data-paseo-expect-existing", "1");
    viewer.style.cssText = "position:absolute;inset:0;";
    panel.appendChild(close);
    panel.appendChild(viewer);
    document.body.appendChild(panel);
    this.viewer = panel;
    this.currentViewerId = browserId;
  };

  RosterDock.prototype.closeViewer = function () {
    if (this.viewer && this.viewer.parentNode) this.viewer.parentNode.removeChild(this.viewer);
    this.viewer = null;
    this.currentViewerId = null;
  };

  function start() {
    scan(document);
    var mo = new MutationObserver(function (records) {
      for (var i = 0; i < records.length; i++) {
        var added = records[i].addedNodes;
        for (var j = 0; j < added.length; j++) {
          var n = added[j];
          if (n.nodeType === 1) {
            if (n.hasAttribute && n.hasAttribute(MARKER)) scan(n.parentNode || document);
            else scan(n);
          }
        }
      }
    });
    mo.observe(document.documentElement, { childList: true, subtree: true });
    new RosterDock();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();

if (typeof module !== "undefined" && module.exports) {
  module.exports = { isTerminalCloseCode, applyRosterMessage, closeAction };
}
