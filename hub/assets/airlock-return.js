/* airlock-return.js — a "return to Airlock" button + unread badge (shared widget).
 *
 * Why: when an Airlock tool is used as a home-screen standalone web app there is
 * no browser chrome (no back button), so there is no way back to the Airlock
 * entrance. Some tools own their UI and can add a button inline; upstream bundles
 * (orca, paseo, code-server, ...) cannot be edited, so the nginx gate injects this
 * script before </body> via sub_filter.
 *
 * Modes (chosen by the injected <script>'s data-mode):
 *   - floating (default): a draggable round button. Good for orca/paseo — it
 *     floats over the app and the user can move it out of the way. Position is
 *     remembered per-device in localStorage. data-anchor picks the default corner.
 *   - corner: a fixed rounded tile in the top-left (the Airlock mark, light on
 *     dark). For same-origin subpath tools (markwand, notepad, publish, ...).
 *   - native: an inline tile appended into a data-target placeholder
 *     (default #airlock-slot) so a frontend can place it in its own header.
 *
 * Menu (only when the injected script carries data-menu="1" AND data-panel="<devterm
 * base url>", i.e. the separate-port tools): a tap opens a small menu instead of
 * navigating: "Go to Airlock", "Subscription accounts", "Secret drop". The latter two
 * open devterm's panel.html in a modal iframe rather than reimplementing it: the UI lives in
 * devterm, its fetches are same-origin there, and there is one implementation to keep
 * right. Without data-panel there is nothing to open, so the menu stays off and a tap
 * navigates as before (never a dead menu entry). If the panel does not load within 6s
 * the modal says so and prints the address it tried, instead of showing a blank box.
 *
 * Subscription ring (all modes, needs data-panel): polls devterm's /acct-alert every
 * 30s — the same endpoint devterm's own account icon uses, so both turn amber (warn) or
 * red-and-blinking (critical) at the same instant. The thresholds live only in the
 * backend, so there is no second copy here to drift. A failed poll clears the ring: no
 * reading is not a warning.
 *
 * Needs-action badge (all modes): polls Dev Monitor's owner message preview every 30s
 * and shows the "still needs a person" count (falling back to the older unread count
 * against a not-yet-upgraded backend) as a small grey circle. Hidden for non-owner and
 * for a genuinely disabled messages backend (404/403) — those are real zeros. A fetch
 * that fails for any other reason (5xx, network, bad JSON) leaves the badge exactly as
 * it was: overwriting it to 0 on a backend error would read as "nothing to do" when the
 * truth is "do not know", and that is the one distinction this badge exists to preserve.
 *
 * Interaction (robust on iOS): navigation is a click (fires reliably on tap in
 * iOS Safari). Dragging (floating) uses pointer events on window listeners
 * (setPointerCapture can swallow the trailing click on iOS, so it is avoided);
 * a real drag suppresses the one click that follows it.
 *
 * Properties: self-contained (zero deps), idempotent, hidden inside iframes /
 * previews (only shows in the top-level app).
 *
 * Names (2026-08-07 rename; the overlap ends 2026-09-07):
 *   The published names here carried the company prefix this project used before it
 *   was open-sourced. They are part of the contract with an out-of-tree frontend, so
 *   they could not simply be scrubbed the way an internal comment can. The rule
 *   applied instead: rename what we EMIT, keep accepting what we RECEIVE.
 *     emitted, renamed now  — the button's element id, the localStorage position key
 *     received, both accepted — the native slot (#airlock-slot, then #swk-airlock-slot)
 *                              and the panel's close message (both spellings)
 *   The legacy spellings below are due for deletion on 2026-09-07 — a date rather
 *   than "one release", because this repo has no releases to count. They are the
 *   only reason `swk-airlock-return|swk-airlock-slot|swk-panel-close` is still on the
 *   ALLOW list of the internal-string scan in .github/workflows/ci.yml — that scan
 *   fails on a stale allowlist entry, so removing these lines forces removing those.
 */
(function () {
  "use strict";
  var ID = "airlock-return";
  var LEGACY_ID = "swk-airlock-return";             // remove 2026-09-07
  if (window.top !== window.self) return;          // hidden inside iframes/previews
  // Idempotent against BOTH spellings: during an upgrade a page can already carry
  // a button injected by the previous version, and a second one is worse than none.
  if (document.getElementById(ID) || document.getElementById(LEGACY_ID)) return;

  // ---- mode: from the injected <script data-mode> (default floating) ----
  var mode = "floating";
  var targetSelector = "#airlock-slot";
  var LEGACY_SLOT = "#swk-airlock-slot";            // remove 2026-09-07
  var targetExplicit = false;                       // operator named a slot via data-target
  var anchor = "bottom-left";
  // data-menu="1" + data-panel="<devterm base url>": tap opens a small menu instead of
  // navigating immediately, so a tool that owns the whole screen can still reach the
  // account panel. Without data-panel there is nothing to open, so the menu stays off
  // and a tap navigates as before (no dead menu entries).
  var wantMenu = false;
  var panelBase = "";
  try {
    var self = document.currentScript ||
      document.querySelector('script[src^="/airlock-return.js"]');
    if (self && self.dataset) {
      if (self.dataset.mode === "corner" || self.dataset.mode === "native") mode = self.dataset.mode;
      if (self.dataset.target) { targetSelector = self.dataset.target; targetExplicit = true; }
      if (self.dataset.anchor === "bottom-right") anchor = "bottom-right";
      if (self.dataset.menu === "1") wantMenu = true;
      if (self.dataset.panel) panelBase = String(self.dataset.panel).replace(/\/+$/, "") + "/";
    }
  } catch (e) {}
  var useMenu = wantMenu && !!panelBase;

  // Canonical hub origin = https://<host>/ (443, no port). The launcher opens
  // every tool via the deployment's FQDN, so location.hostname here is already the
  // FQDN that matches the hub's TLS cert — return to it directly (one load, no
  // redirect flash). Subpath tools are same-origin; separate-port tools are a
  // different port on the same host and 443 is the hub.
  var AIRLOCK = "https://" + location.hostname + "/";
  // Badge source = the hub's owner message preview (absolute path, reachable from
  // any tool origin). 404s (and the badge stays hidden) unless dev-monitor's
  // message console is enabled.
  var UNREAD_URL = AIRLOCK + "monitor/api/owner/messages/preview";
  // Subscription warning source. The verdict is the backend's (devterm's /acct-alert,
  // which owns the thresholds), so this button turns amber/red at the same instant
  // devterm's own account icon does — no second copy of the rules to drift.
  var ALERT_URL = panelBase ? panelBase + "acct-alert" : "";
  var POLL_MS = 30000;

  var POS_KEY = "airlock:btn-pos-v1";               // per-device position (floating)
  var LEGACY_POS_KEY = "swk:airlock-btn-pos-v1";    // remove 2026-09-07

  // The two compatibility rules, pure and side-effect free so that
  // install/test-frontend-namespace.sh can lift them out and exercise them in
  // node — a DOM stub for the whole widget would test the stub, not the rule.
  function airlockResolveSlot(doc, selector, legacySelector) {
    var el = null;
    try { el = doc.querySelector(selector); } catch (e) {}
    if (el || !legacySelector) return el;
    try { el = doc.querySelector(legacySelector); } catch (e) {}
    return el;
  }
  function airlockIsCloseMessage(data) {
    return data === "airlock-panel-close" || data === "swk-panel-close";
  }
  var FLOAT_SIZE = 44, CORNER_SIZE = 40, NATIVE_SIZE = 30, EDGE = 8, DRAG = 6;
  var SIZE = mode === "corner" ? CORNER_SIZE : mode === "native" ? NATIVE_SIZE : FLOAT_SIZE;

  // The Airlock porthole mark (dome + perspective floor grid), white. Painted with
  // currentColor via a CSS mask so it takes the tile's glyph colour. Used in every
  // mode.
  var LOGO_SZ = Math.round(SIZE * 0.62);
  var LOGO_URI = 'url(data:image/png;base64,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) center/contain no-repeat';

  var btn = document.createElement("button");
  btn.id = ID;
  btn.type = "button";
  btn.title = "Airlock (dev-hub home)";
  btn.setAttribute("aria-label", "Return to Airlock");
  var S = btn.style;                                 // inline styles = isolated from app CSS
  S.position = "fixed";
  S.zIndex = "2147483000";
  S.width = S.height = SIZE + "px";
  S.margin = S.padding = "0";
  S.border = "none";
  S.cursor = "pointer";
  S.display = "flex";
  S.alignItems = S.justifyContent = "center";
  S.boxShadow = "0 2px 10px rgba(0,0,0,.35), 0 0 0 1px rgba(255,255,255,.14)";
  S.opacity = "0.9";
  S.touchAction = "none";
  S.webkitTapHighlightColor = "transparent";
  S.webkitUserSelect = S.userSelect = "none";
  S.transition = "opacity .15s ease";
  // green Airlock tile + light mark (all modes are self-contained — no PNG asset)
  S.background = "#173d29";
  S.color = "#e6f2ea";

  if (mode === "native") {
    S.borderRadius = "8px";
    S.position = "relative";
    S.zIndex = "auto";
    S.boxShadow = "none";
  } else if (mode === "corner") {
    S.borderRadius = "11px";
  } else {
    S.borderRadius = "50%";
  }
  var lg = document.createElement("span");
  lg.setAttribute("aria-hidden", "true");
  lg.style.cssText = "display:block;width:" + LOGO_SZ + "px;height:" + LOGO_SZ + "px;background:currentColor;-webkit-mask:" + LOGO_URI + ";mask:" + LOGO_URI + ";";
  btn.appendChild(lg);

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }
  function applyXY(x, y) {
    var maxX = window.innerWidth - SIZE - EDGE, maxY = window.innerHeight - SIZE - EDGE;
    S.left = clamp(x, EDGE, maxX) + "px";
    S.top = clamp(y, EDGE, maxY) + "px";
    S.right = S.bottom = "auto";
  }
  function anchorCorner() {                            // corner = top-left (respect safe-area)
    S.left = "max(12px, env(safe-area-inset-left, 0px))";
    S.top = "max(12px, env(safe-area-inset-top, 0px))";
    S.right = S.bottom = "auto";
  }
  function anchorFloatDefault() {                      // floating with no saved pos
    if (anchor === "bottom-right") {
      S.right = "max(14px, env(safe-area-inset-right, 0px))";
      S.left = "auto";
    } else {
      S.left = "max(14px, env(safe-area-inset-left, 0px))";
      S.right = "auto";
    }
    S.bottom = "max(20px, env(safe-area-inset-bottom, 0px))";
    S.top = "auto";
  }
  var placed = false;                                // positioned via top/left (dragged/restored)
  if (mode === "corner") {
    anchorCorner();
  } else if (mode === "floating") {
    (function restore() {
      var p = null;
      try {
        // Read the new key, fall back to the pre-rename one and carry it over, so a
        // device that had dragged the button keeps its position across the rename.
        var raw = localStorage.getItem(POS_KEY);
        if (raw === null) {
          raw = localStorage.getItem(LEGACY_POS_KEY);
          if (raw !== null) { localStorage.setItem(POS_KEY, raw); localStorage.removeItem(LEGACY_POS_KEY); }
        }
        p = JSON.parse(raw || "null");
      } catch (e) {}
      if (p && typeof p.x === "number" && typeof p.y === "number") { applyXY(p.x, p.y); placed = true; }
      else anchorFloatDefault();
    })();
  }

  // ---- unread badge (all modes) ----
  var badge = document.createElement("span");
  var B = badge.style;
  B.position = "absolute";
  B.top = "-5px";
  B.right = "-5px";
  B.minWidth = "18px";
  B.height = "18px";
  B.boxSizing = "border-box";
  B.padding = "0 5px";
  B.borderRadius = "9px";
  B.background = "#6b7280";                           // grey circle (mark is light on green)
  B.color = "#fff";
  B.font = "700 11px/18px -apple-system, system-ui, sans-serif";
  B.textAlign = "center";
  B.letterSpacing = "0";
  B.boxShadow = "0 0 0 2px rgba(0,0,0,.28)";
  B.pointerEvents = "none";
  B.display = "none";                                 // hidden by default (0 / non-owner / error)
  if (mode === "native") {
    B.top = B.right = "-4px";
    B.minWidth = B.height = "15px";
    B.padding = "0 4px";
    B.borderRadius = "8px";
    B.font = "700 9.5px/15px -apple-system, system-ui, sans-serif";
  }
  badge.setAttribute("aria-hidden", "true");
  btn.appendChild(badge);

  function setUnread(n) {
    if (n > 0) {
      badge.textContent = n > 99 ? "99+" : String(n);
      badge.style.display = "block";
      btn.setAttribute("aria-label", "Return to Airlock — " + n + " needs action");
    } else {
      badge.style.display = "none";
      btn.setAttribute("aria-label", "Return to Airlock");
    }
  }
  function pollUnread() {
    fetch(UNREAD_URL, { cache: "no-store" })
      .then(function (r) {
        // 403 (not the owner) and 404 (messages feature not enabled on this box) are real
        // zeros, not failures — this device is never going to see a count here.
        if (r.status === 403 || r.status === 404) { setUnread(0); return null; }
        if (!r.ok) return undefined;                  // unexpected status — see below
        return r.json();
      })
      .then(function (d) {
        if (d === null) return;                       // handled above (403/404)
        if (d === undefined) return;                  // unexpected status — keep last known
        setUnread((d && d.needs_action_count != null) ? d.needs_action_count
          : (d && d.unread_count) || 0);
      })
      .catch(function () {});                          // network / bad JSON — keep last known
  }

  // ---- subscription warning ring ----
  // amber = warn, red + blink = critical. Blinking only at critical on purpose: a
  // static ring on a button the user has learnt to ignore is not a warning.
  var RING_BASE = S.boxShadow;
  var alertLevel = "", alertInfo = null, blinkTimer = null, blinkOn = false;
  function paintRing() {
    if (blinkTimer) { clearInterval(blinkTimer); blinkTimer = null; }
    if (alertLevel === "warn") {
      S.boxShadow = RING_BASE + ", 0 0 0 3px #e6b34d, 0 0 12px rgba(230,179,77,.65)";
    } else if (alertLevel === "crit") {
      blinkOn = true;
      var flip = function () {
        S.boxShadow = blinkOn
          ? RING_BASE + ", 0 0 0 3px #e05a5a, 0 0 14px rgba(224,90,90,.8)"
          : RING_BASE + ", 0 0 0 3px rgba(224,90,90,.35)";
        blinkOn = !blinkOn;
      };
      flip();
      blinkTimer = setInterval(flip, 700);
    } else {
      S.boxShadow = RING_BASE;
    }
  }
  function alertReason(a) {
    if (!a || a.level === "none" || !a.level) return "";
    if (a.reason === "login") {
      return a.rtDays == null ? "login expiring" :
        (a.rtDays <= 0 ? "login expired" : "login expires in " + a.rtDays + "d");
    }
    if (a.reason === "codex-login") return "Codex sign-in revoked — re-login";
    if (a.reason === "codex") return "Codex 7d " + (a.codexUse7d == null ? "high" : a.codexUse7d + "%");
    var bits = [];
    if (a.use5h != null) bits.push("5h " + a.use5h + "%");
    if (a.use7d != null) bits.push("7d " + a.use7d + "%");
    return bits.join(" · ") || "usage high";
  }
  function pollAlert() {
    if (!ALERT_URL) return;
    fetch(ALERT_URL, { cache: "no-store" })
      .then(function (r) { if (!r.ok) throw 0; return r.json(); })
      .then(function (a) {
        alertInfo = a || null;
        alertLevel = a && (a.level === "warn" || a.level === "crit") ? a.level : "";
        paintRing();
      })
      // No reading = no warning. A failed poll must not leave a red ring implying a
      // state we cannot see (and must not invent one either).
      .catch(function () { alertInfo = null; alertLevel = ""; paintRing(); });
  }

  // ---- menu (only when data-menu + data-panel are both given) ----
  var menuEl = null, modalEl = null;
  function closeMenu() { if (menuEl) { menuEl.remove(); menuEl = null; } }
  function closeModal() { if (modalEl) { modalEl.remove(); modalEl = null; } }
  function menuRow(label, sub, onClick) {
    var b = document.createElement("button");
    b.type = "button";
    b.style.cssText = "display:block;width:100%;text-align:left;border:none;background:transparent;" +
      "color:#e8ecf4;font:13.5px/1.35 -apple-system,system-ui,sans-serif;padding:11px 14px;cursor:pointer;";
    var t = document.createElement("div"); t.textContent = label; b.appendChild(t);
    if (sub) {
      var sEl = document.createElement("div");
      sEl.textContent = sub;
      sEl.style.cssText = "margin-top:2px;font-size:11.5px;color:#e6b34d;";
      b.appendChild(sEl);
    }
    b.addEventListener("mouseenter", function () { b.style.background = "rgba(255,255,255,.07)"; });
    b.addEventListener("mouseleave", function () { b.style.background = "transparent"; });
    b.addEventListener("click", function (e) { e.preventDefault(); e.stopPropagation(); onClick(); });
    return b;
  }
  // The panel is shown in a modal iframe: the UI lives in devterm and its fetches are
  // same-origin there, so nothing has to be duplicated here and no CORS is involved.
  function openPanel(which, title) {
    closeMenu();
    closeModal();
    var ov = document.createElement("div");
    ov.style.cssText = "position:fixed;inset:0;z-index:2147483100;background:rgba(0,0,0,.6);" +
      "display:flex;align-items:center;justify-content:center;padding:16px;";
    var box = document.createElement("div");
    box.style.cssText = "background:#1b1f29;border:1px solid #3a4254;border-radius:12px;" +
      "box-shadow:0 18px 48px rgba(0,0,0,.5);width:min(420px,100%);height:min(560px,92vh);" +
      "display:flex;flex-direction:column;overflow:hidden;";
    var head = document.createElement("div");
    head.style.cssText = "flex:0 0 auto;display:flex;align-items:center;gap:10px;padding:10px 12px;" +
      "border-bottom:1px solid #2c3240;color:#f2f5fa;font:600 14px -apple-system,system-ui,sans-serif;";
    var ttl = document.createElement("span"); ttl.textContent = title; ttl.style.flex = "1";
    var x = document.createElement("button");
    x.type = "button"; x.textContent = "✕";
    x.setAttribute("aria-label", "Close");
    x.style.cssText = "width:34px;height:30px;border:none;border-radius:8px;background:#3a4254;color:#fff;" +
      "font-size:17px;line-height:1;cursor:pointer;";
    x.addEventListener("click", function (e) { e.preventDefault(); closeModal(); });
    head.appendChild(ttl); head.appendChild(x);
    var frame = document.createElement("iframe");
    frame.src = panelBase + "panel.html?p=" + which + "&embed=1";
    frame.style.cssText = "flex:1 1 auto;width:100%;border:none;background:#1b1f29;";
    var note = document.createElement("div");
    note.style.cssText = "display:none;padding:14px;color:#c3c9d4;font:12.5px/1.6 -apple-system,system-ui,sans-serif;";
    box.appendChild(head); box.appendChild(frame); box.appendChild(note);
    ov.appendChild(box);
    ov.addEventListener("click", function (e) { if (e.target === ov) closeModal(); });
    (document.body || document.documentElement).appendChild(ov);
    modalEl = ov;
    // A blank rectangle is not an error message: if the panel never loads (devterm not
    // installed, wrong port), say so and show the address that was tried.
    var loaded = false;
    frame.addEventListener("load", function () { loaded = true; });
    setTimeout(function () {
      if (loaded || modalEl !== ov) return;
      frame.style.display = "none";
      note.style.display = "block";
      note.textContent = "The devterm panel did not load within 6s: " + frame.src +
        " — check that devterm is installed and reachable on that address.";
    }, 6000);
  }
  function openMenu() {
    if (menuEl) { closeMenu(); return; }
    var m = document.createElement("div");
    m.style.cssText = "position:fixed;z-index:2147483100;min-width:236px;background:#202431;" +
      "border:1px solid #3a4254;border-radius:10px;box-shadow:0 14px 36px rgba(0,0,0,.45);" +
      "padding:5px 0;overflow:hidden;";
    m.appendChild(menuRow("Go to Airlock", "", function () { closeMenu(); go(); }));
    m.appendChild(menuRow("Subscription accounts", alertReason(alertInfo), function () {
      openPanel("accounts", "Subscription accounts");
    }));
    m.appendChild(menuRow("Secret drop", "value stays on the box · path only", function () {
      openPanel("secret", "Secret drop");
    }));
    (document.body || document.documentElement).appendChild(m);
    // place next to the button, then pull back inside the viewport
    var r = btn.getBoundingClientRect(), mh = m.offsetHeight, mw = m.offsetWidth;
    var top = r.bottom + 8, left = r.left;
    if (top + mh > window.innerHeight - 8) top = Math.max(8, r.top - mh - 8);
    if (left + mw > window.innerWidth - 8) left = Math.max(8, window.innerWidth - mw - 8);
    m.style.top = top + "px";
    m.style.left = left + "px";
    menuEl = m;
    setTimeout(function () {              // not in this same click
      document.addEventListener("pointerdown", onDocDown, true);
    }, 0);
  }
  function onDocDown(e) {
    if (menuEl && !menuEl.contains(e.target) && e.target !== btn && !btn.contains(e.target)) {
      closeMenu();
      document.removeEventListener("pointerdown", onDocDown, true);
    }
  }
  // The panel cannot close the modal that contains it, so it asks us to.
  window.addEventListener("message", function (e) {
    if (airlockIsCloseMessage(e.data)) closeModal();
  });
  document.addEventListener("keydown", function (e) {
    if (e.key !== "Escape") return;
    if (modalEl) closeModal();
    else if (menuEl) closeMenu();
  });

  // ---- navigation = click (fires reliably on iOS tap); suppress the click after a drag ----
  var suppressClick = false, navigated = false;
  function go() {
    if (navigated) return;
    navigated = true;
    window.location.href = AIRLOCK;
  }
  btn.addEventListener("click", function (e) {
    e.preventDefault();
    if (suppressClick) { suppressClick = false; e.stopPropagation(); return; }
    if (useMenu) { openMenu(); return; }
    go();
  });
  btn.addEventListener("keydown", function (e) {
    if (e.key === "Enter" || e.key === " ") { e.preventDefault(); go(); }
  });

  // ---- drag = pointer + window listeners (floating only; avoid capture so the click survives) ----
  if (mode === "floating") {
    var start = null, dragging = false;
    var onMove = function (e) {
      if (!start) return;
      if (!dragging && Math.abs(e.clientX - start.x) + Math.abs(e.clientY - start.y) < DRAG) return;
      dragging = true;
      S.opacity = "1";
      applyXY(e.clientX - start.ox, e.clientY - start.oy);
      placed = true;
      e.preventDefault();
    };
    var onUp = function () {
      window.removeEventListener("pointermove", onMove, true);
      window.removeEventListener("pointerup", onUp, true);
      window.removeEventListener("pointercancel", onUp, true);
      S.opacity = "0.9";
      if (dragging) {
        suppressClick = true;                          // ignore the one click after this drag
        setTimeout(function () { suppressClick = false; }, 350);
        var r = btn.getBoundingClientRect();
        try { localStorage.setItem(POS_KEY, JSON.stringify({ x: r.left, y: r.top })); } catch (_) {}
      }
      start = null; dragging = false;
    };
    btn.addEventListener("pointerdown", function (e) {
      var r = btn.getBoundingClientRect();
      start = { x: e.clientX, y: e.clientY, ox: e.clientX - r.left, oy: e.clientY - r.top };
      dragging = false;
      window.addEventListener("pointermove", onMove, true);
      window.addEventListener("pointerup", onUp, true);
      window.addEventListener("pointercancel", onUp, true);
    });
    window.addEventListener("resize", function () {     // keep it on-screen on rotate/resize
      if (!placed) return;
      var r = btn.getBoundingClientRect();
      applyXY(r.left, r.top);
    });
  }

  function mount() {
    if (mode === "native") {
      // No legacy fallback when the operator named the slot: an explicit data-target
      // that does not resolve is a mistake to surface, not one to paper over.
      var slot = airlockResolveSlot(document, targetSelector, targetExplicit ? null : LEGACY_SLOT);
      if (!slot) {
        if (window.console && console.debug) console.debug("airlock-return: native target not found");
        return;
      }
      slot.appendChild(btn);
    } else {
      (document.body || document.documentElement).appendChild(btn);
    }
    pollUnread();
    setInterval(pollUnread, POLL_MS);
    if (ALERT_URL) {
      pollAlert();
      setInterval(pollAlert, POLL_MS);
    }
  }
  if (document.body) mount();
  else document.addEventListener("DOMContentLoaded", mount, { once: true });
})();
