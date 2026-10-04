'use strict';
/*
 * Airlock subscription account pool — the one implementation of the account list.
 *   A PLATFORM asset (hub/assets/accounts/) since ACCT_OWN, 2026-09-01; it began as
 *   part of devterm's app.js, which is why the injected deps below are shaped like a
 *   terminal's. Its launchers — devterm's control, the return widget and the hub's
 *   identity pill — all open panel.html on this platform origin, so this file executes
 *   beside the platform API exactly once rather than being loaded on each app origin.
 *   Optional feature (the account icon is only shown when the accounts feature is
 *   enabled). Switch / usage / pool-login UI. Coupling to a terminal is only the
 *   injected functions below (no core vars), which is what let it move.
 * DI factory: window.initAccounts(deps) is the only global. deps =
 *   { flash, postJson, mkFocus, closeTabPops, placePop }; returns 4 API functions.
 * Every fetch is relative to THIS DOCUMENT'S directory (see API below) on the origin
 *   that serves the account API, so the page hosting it must be served by that same
 *   gate and from the same directory. That is why the devterm gate aliases this file
 *   rather than the hub serving it at its own origin — until the surface moves.
 * Load order: before panel.html's inline host; the panel calls this factory.
 *
 * Shell (POPUP_SHELL, 2026-09-23): four collapsed sections with one-line headers
 *   (who · how much · next reset) plus an action-needed summary line. Only Claude
 *   starts expanded. Login-type work runs as guided flows (ready → approve → check →
 *   done) inside its own section, and a saved-account switch runs as an inline
 *   confirm strip → progress → done card — the popup/panel never closes underneath.
 *   Unread slots read 「확인 중」; every user-visible string is Korean.
 */
window.initAccounts = function initAccounts(deps) {
  // Where the account API answers. Every fetch below is same-origin to the page that
  // loaded this file, and the panel is always served beside the API it calls — so the
  // base is this document's own directory rather than a hard-coded "/". Both of today's
  // hosts serve at the origin root, so this is "/" and nothing changes yet; when the
  // panel moves under a prefix its fetches follow it, with no second place to update.
  var API = (function () {
    try { return String(location.pathname).replace(/[^/]*$/, '') || '/'; }
    catch (e) { return '/'; }
  })();
  const flash = deps.flash, postJson = deps.postJson, mkFocus = deps.mkFocus,
        closeTabPops = deps.closeTabPops, placePop = deps.placePop;

// ---- Claude account switch (claude-switch) — click the top square icon ----
// usage color rule: 5h and 7d have different thresholds; the row color is the worse of
// the two (OR). Neither axis is ever suppressed — a spent 5h window is the strongest
// reason this list has to say "not this one".
// The threshold NUMBERS are deliberately not here — the backend's USAGE_TH is the only
// source and ships them in /accounts and /acct-alert as `thresholds`. devterm's icon,
// these rows and the Airlock return widget (a different origin) all grade against the
// same numbers; a frontend copy is how "devterm is red but the widget is calm" happens.
const C_GRAY = '#8a92a6', C_GREEN = '#7bd88f', C_AMBER = '#e6b34d', C_RED = '#e05a5a';

let TH = null;   // server-provided thresholds. Without them we do not colour at all.
function setThresholds(t) {
  if (t && typeof t.warn5 === 'number') TH = t;
  else if (!TH && window.console) console.warn('[devterm] no thresholds received — usage colouring disabled (older server?)');
}

function usageLevel(kind, p) {   // 0=ok 1=warn 2=critical
  if (p == null || !TH) return 0;
  return kind === '5h' ? (p >= TH.crit5 ? 2 : p >= TH.warn5 ? 1 : 0)
                       : (p >= TH.crit7 ? 2 : p >= TH.warn7 ? 1 : 0);
}
function levelColor(lv) { return lv === 2 ? C_RED : lv === 1 ? C_AMBER : C_GREEN; }

// row color = OR (the worse of the two). Nothing mutes an axis: this list answers
// "which account can I use right now", and a 5h window at 100% is the one state where
// the answer is certainly no. It used to drop the 5h axis once the window was spent,
// which painted a fully exhausted account GREEN — measured 2026-08-09 on a row reading
// `5h 100% / 7d 15%`, sitting green next to accounts that were merely at 95%.
function usageColor(u5, u7) {
  if (!TH) return C_GRAY;                 // thresholds unknown = neutral; green and red would both be a lie
  return levelColor(Math.max(usageLevel('5h', u5), usageLevel('7d', u7)));
}

// reset-time formatting — like a statusline (5h = time only / 7d = date + time). ISO(UTC) -> local.
function fmtReset(iso, withDate) {
  if (!iso) return '?';
  const d = new Date(iso);
  if (isNaN(d.getTime())) return '?';
  const p = n => String(n).padStart(2, '0');
  const hm = p(d.getHours()) + ':' + p(d.getMinutes());
  return withDate ? p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + hm : hm;
}

// hover tip text — two lines like a statusline. Unused (0%) window has resets_at=null -> '—'.
// A refreshToken expiry does NOT slide — it is fixed at login (~30 days) and does not
// refresh. So even a daily-use account dies at ~30 days. Warn ahead of time by days left.
function rtWarnDays() { return TH ? TH.rtWarnDays : 5; }   // server is the source; display-only fallback
function rtLeft(a) {   // days left (fractional) · null if unknown
  return a && a.rtExpiry ? (a.rtExpiry - Date.now()) / 86400000 : null;
}
function rtWarnText(d) {
  if (d <= 0) return '⚠ Expired · log in again';
  if (d < 1) return '⚠ Expires today · log in again';
  return '⚠ Expires in ' + Math.floor(d) + ' days · log in again';
}
function usageAgeText(u) {
  const age = u && Number(u.age);
  if (!Number.isFinite(age) || age < 0) return '';
  if (age < 60) return 'just now';
  const minutes = Math.round(age / 60);
  if (minutes < 60) return minutes + ' min ago';
  const hours = Math.round(minutes / 60);
  return hours + (hours === 1 ? ' hour ago' : ' hours ago');
}
function usageFreshnessText(u) {
  const bits = [];
  const age = usageAgeText(u);
  if (age) bits.push(age);
  if (u && u.err) bits.push('unavailable now (' + u.err + ')');
  return bits.join(' · ');
}
function acctTipText(u, a) {
  const L = [];
  if (u.use5h == null && u.use7d == null) {
    L.push(u.err === 'no data' ? 'Waiting for a usage reading\n(collected every 3-40 min)'
         : u.err === 'no store' ? 'No shared usage store\nOnly the active account can be read here.'
         : 'Could not read usage\n' + (u.err || '?'));
  } else {
    L.push('5h reset ' + (u.reset5h ? fmtReset(u.reset5h, false) : '—') +
           '\nWeekly reset ' + (u.reset7d ? fmtReset(u.reset7d, true) : '—') +
           (usageFreshnessText(u) ? '\n' + usageFreshnessText(u) : ''));
  }
  // who holds it = the shared store's holders. Using the same account in two places burns 5h twice as fast.
  const h = (a && a.holders) || [];
  if (h.length) L.push('In use\n' + h.map(function (x) { return '· ' + x.who; }).join('\n'));
  const d = rtLeft(a);
  if (d != null) {
    L.push(d <= rtWarnDays()
      ? rtWarnText(d) + '\n(The expiry is fixed at about 30 days after login\nand does not extend with use)'
      : Math.floor(d) + ' days until login expires');
  }
  return L.join('\n\n');
}

// If the active account is warn/critical, the top / key-bar Claude icon itself signals it (amber = mild / red = clear).
// 5h full (grey = locked) does not warn — it was already red before locking.
let _acctIconCls = '', _acctIconTimer = null;
let _acctAlert = null;
function applyAcctIconCls() {
  document.querySelectorAll('[aria-label*="Switch account"]').forEach(function (b) {
    b.classList.toggle('acct-warn', _acctIconCls === 'acct-warn');
    b.classList.toggle('acct-crit', _acctIconCls === 'acct-crit');
  });
}
// The grade is decided by the backend (/acct-alert, USAGE_TH is the source) — here we
// only paint the class. The Airlock return widget polls the same endpoint, so the icon
// and the widget turn amber/red at the same instant instead of drifting apart.
function refreshAcctIcon() {
  fetch(API + 'acct-alert', { cache: 'no-store' }).then(function (x) { return x.json(); }).then(function (j) {
    _acctAlert = j || null;
    if (j && j.thresholds) setThresholds(j.thresholds);
    _acctIconCls = j && j.level === 'crit' ? 'acct-crit' : j && j.level === 'warn' ? 'acct-warn' : '';
    applyAcctIconCls();
  }).catch(function () {});
}
function startAcctIconWatch() {
  if (_acctIconTimer) return;
  refreshAcctIcon();
  _acctIconTimer = setInterval(refreshAcctIcon, 60000);   // icon alert refresh only; Claude usage is not polled
}

// show next to the cursor immediately (native title has ~1s delay + tiny text).
let _acctTipEl = null;
function hideAcctTip() { if (_acctTipEl) { _acctTipEl.remove(); _acctTipEl = null; } }
function placeAcctTip(e) {
  if (!_acctTipEl) return;
  const el = _acctTipEl, pad = 14;
  const x = Math.min(e.clientX + pad, window.innerWidth - el.offsetWidth - 6);
  const y = Math.min(e.clientY + pad, (window.visualViewport ? window.visualViewport.height : window.innerHeight) - el.offsetHeight - 6);   // above the keyboard (visual viewport)
  el.style.left = Math.max(6, x) + 'px';
  el.style.top = Math.max(6, y) + 'px';
}
function showAcctTip(e, u, a) {
  hideAcctTip();
  const el = document.createElement('div'); el.className = 'acct-tip';
  el.textContent = acctTipText(u, a);
  document.body.appendChild(el);   // must attach before measuring
  _acctTipEl = el;
  placeAcctTip(e);
}

// ---- small DOM helpers (the shell below is built from these) ----
function mk(tag, cls, text) {
  const e = document.createElement(tag || 'div');
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}
function mkBtn(label, cls, fn) {
  const b = mk('button', cls || '', label);
  b.addEventListener('pointerdown', function (e) { e.preventDefault(); });
  if (fn) b.onclick = function (e) { e.stopPropagation(); fn(); };
  return b;
}
// Success cards close themselves — pressing 완료 to dismiss good news is busywork.
// Failure cards keep their explicit buttons (the error must be readable).
function autoCloseDone(st, paint, alive) {
  setTimeout(function () {
    if (alive() && st.flow && st.flow.step === 'done') { st.flow = null; paint(); }
  }, 2500);
}
function mkBtnRow() {
  const d = mk('div', 'codex-btns');
  for (let i = 0; i < arguments.length; i++) if (arguments[i]) d.appendChild(arguments[i]);
  return d;
}
// per-list shell state. One list = one popup opening or one panel render.
function newShellState() {
  return {
    expand: { claude: true, codex: false, agy: false, muse: false },
    flow: null,                       // {sec, kind, step, ...} — one guided flow at a time
    claude: null, codex: null, codexUsage: null, agy: null, muse: null,
  };
}
function activeClaude(st) {
  const list = (st.claude && st.claude.accounts) || [];
  return list.find(function (a) { return a.active; }) || null;
}
// "how much" for a Claude usage pair. Unread slots read 확인 중 — never 0%, never blank.
function claudeUsageText(u) {
  u = u || {};
  if (u.use5h == null && u.use7d == null) {
    if (u.err === 'no data') return 'Waiting for data\nEvery 3-40 min';
    if (u.err === 'no store') return 'No usage\nsource';
    if (u.err) return 'Unavailable\n' + u.err;
    return 'Checking';
  }
  return '5h ' + (u.use5h == null ? '—' : u.use5h + '%') +
       '\nWeekly ' + (u.use7d == null ? '—' : u.use7d + '%');
}

// ---- one-line headers: who · how much · next reset ----
function claudeHead(st) {
  const j = st.claude;
  if (!j) return 'Claude · Checking';
  if (j.enabled === false) return 'Claude · Switching disabled in this app';
  const list = j.accounts || [];
  const a = activeClaude(st);
  if (!a) return 'Claude · ' + list.length + ' accounts · None active';
  const u = a.usage || {};
  const much = (u.use5h == null && u.use7d == null)
    ? 'Checking'
    : '5h ' + (u.use5h == null ? '—' : u.use5h + '%') +
      ' · Weekly ' + (u.use7d == null ? '—' : u.use7d + '%');
  const reset = u.reset5h ? ' · Next reset ' + fmtReset(u.reset5h, false) : '';
  return 'Claude · Active ' + (a.email || a.name) + ' · ' + much + reset + ' · ' + list.length + ' accounts';
}
function codexHead(st) {
  const cx = st.codex;
  if (!cx) return 'Codex · Checking';
  if (cx.state === 'pending') return 'Codex · Login in progress';
  if (cx.state !== 'ok') return 'Codex · Login required';
  const u = st.codexUsage || {};
  const much = u.codexUse7d == null ? 'Checking' : 'Weekly ' + u.codexUse7d + '%';
  const reset = u.codexReset7d ? ' · Resets ' + fmtReset(u.codexReset7d, true) : '';
  if (u.codexErr === 'auth') return 'Codex · Signed out · Log in again';
  return 'Codex · Signed in ' + (cx.email || '') + ' · ' + much + reset;
}
function agyHead(st) {
  const u = st.agy;
  if (!u) return 'Gemini · Checking';
  const acc = u.account || '';
  const gs = u.groups || [];
  if (!acc && !gs.length) {
    if (u.refreshing) return 'Gemini · Reading…';
    return 'Gemini · No reading yet';
  }
  const g = agyGemini(gs);
  const much = !g ? 'Checking'
    : '5h ' + Math.max(0, Math.round(100 - g.fiveHourRemaining)) + '% · Weekly ' +
      Math.max(0, Math.round(100 - g.weeklyRemaining)) + '%';
  const n = (u.accounts || []).length;
  return 'Gemini · Active ' + (acc || 'Checking') + ' · ' + much + (n > 1 ? ' · ' + n + ' accounts' : '');
}
// action-needed summary. Always rendered: calm days read 조치 필요 없음, not silence.
function shellIssues(st) {
  const out = [];
  const cx = st.codex;
  if (cx && cx.state === 'pending') out.push({ sec: 'codex', label: 'Codex login in progress' });
  else if (cx && cx.state !== 'ok' && cx.state !== 'unknown') out.push({ sec: 'codex', label: 'Codex login required' });
  else if (cx && cx.state === 'ok' && st.codexUsage && st.codexUsage.codexErr === 'auth')
    out.push({ sec: 'codex', label: 'Codex signed out' });
  const dead = ((st.claude && st.claude.accounts) || []).filter(function (a) {
    return a.health && a.health.state === 'dead';
  });
  if (dead.length) out.push({ sec: 'claude', label: 'Claude expired logins: ' + dead.length });
  if (st.geminiUsageBad) out.push({ sec: 'gemini', label: 'Gemini usage unavailable' });
  return out;
}

// ---- Codex (ChatGPT) — this box's single account. No pool/swap (Codex design) -> status + re-login + logout ----
// Codex usage is read from /codex-usage, which spawns an app-server behind a cache, so
// it is asked for separately from the identity (/claude-status) and only while the
// section is open. The identity string guards against showing a previous account's
// numbers: a reply that arrives after a logout/login is dropped.
let _codexIdentity = null, _codexUsage = null, _codexViewGeneration = 0,
    _codexOperationPending = false;
const CODEX_STALE_REASK_MS = 3000;
function setCodexIdentity(cx) {
  const state = cx && cx.state ? cx.state : 'unknown';
  const account = cx && (cx.accountId || cx.email);
  const identity = state === 'ok' && !account ? null : state + ':' + (account || '');
  if (_codexIdentity !== identity) {
    _codexIdentity = identity;
    _codexUsage = null;                    // do not reuse numbers across a switch
  }
  return identity;
}
function codexUsageView(u) {
  return {
    codexUse7d: u && u.use7d,
    codexReset7d: u && u.reset7d,
    codexCredits: u && u.resetCredits,
    codexStale: !!(u && u.stale),
    codexErr: u && (u.lastErr || u.err),
  };
}
function fetchCodexUsage(st, paint, alive, reaskState, revalidate) {
  const cx = st.codex, identity = _codexIdentity;
  alive = alive || function () { return true; };
  reaskState = reaskState || { scheduled: false };
  if (!alive() || !cx || cx.state !== 'ok') return;
  const fetchOpts = { cache: 'no-store' };
  if (revalidate) fetchOpts.headers = { 'X-Airlock-Revalidate': 'wait' };
  fetch(API + 'codex-usage', fetchOpts).then(function (x) { return x.json(); }).then(function (u) {
    if (!alive() || _codexIdentity !== identity) return;   // login state changed -> drop
    const hasValue = u && u.use7d != null;
    if (hasValue && (!u.accountId || (cx.accountId && cx.accountId !== u.accountId))) {
      // numbers we cannot tie to the account we are showing are not displayed at all
      _codexUsage = null;
      st.codexUsage = { codexErr: 'account mismatch' };
    } else {
      _codexUsage = codexUsageView(u);
      st.codexUsage = _codexUsage;
    }
    paint();
    if (hasValue && u.stale && !reaskState.scheduled) {
      reaskState.scheduled = true;
      setTimeout(function () {
        if (!alive() || _codexIdentity !== identity) return;
        fetchCodexUsage(st, paint, alive, reaskState, true);
      }, CODEX_STALE_REASK_MS);
    }
  }).catch(function () {
    if (!alive() || _codexIdentity !== identity) return;
    st.codexUsage = { codexErr: 'Could not read usage' };
    paint();
  });
}

// Antigravity quota. The server answers with its last reading at once and re-reads in
// the background when that reading is older than 20 minutes (it has to open the agy CLI
// to do so), so this paints the remembered numbers first and asks again until the
// re-read is done. agy reports "remaining"; rows show "used" like every other section.
const AGY_REASK_MS = 4000, AGY_REASK_MAX = 25;
function fetchAgy(st, paint, alive, tries) {
  tries = tries || 0;
  fetch(API + 'agy-usage', { cache: 'no-store' }).then(function (x) { return x.json(); }).then(function (u) {
    if (!alive()) return;
    if (!u || u.enabled !== true) { st.agy = { enabled: false }; paint(); return; }
    st.agy = u;
    st.geminiUsageBad = !!u.lastErr;
    paint();
    if (u.refreshing && tries < AGY_REASK_MAX) {
      setTimeout(function () { if (alive()) fetchAgy(st, paint, alive, tries + 1); }, AGY_REASK_MS);
    }
  }).catch(function () {
    if (!alive()) return;
    if (!st.agy) { st.agyFailed = true; paint(); }
  });
}
// Saved agy logins, one row each like the Claude list. A switch is confirm strip
// -> checking -> done/fail inline; the account API proves the login before it
// replaces the live one, so a refusal leaves agy on the account it was on.
// Gemini is what agy is used for here, so its group drives the row numbers and
// color — not the worst group (a spent Claude-in-agy group would paint every row red).
function agyGemini(groups) {
  const gs = groups || [];
  return gs.find(function (g) { return /GEMINI/i.test(g.name || ''); }) || gs[0] || null;
}
function agoText(sec) {
  if (sec == null) return '';
  if (sec < 60) return 'just now';
  if (sec < 3600) return Math.round(sec / 60) + ' min ago';
  return Math.round(sec / 3600) + ' h ago';
}
function renderAgyAccounts(st, box, paint, alive) {
  const u = st.agy || {};
  const accounts = u.accounts || [];
  const f = st.flow;
  if (!(f && f.sec === 'agy' && f.kind === 'login')) {
    box.appendChild(mkBtnRow(mkBtn('Add account', 'codex-btn', function () {
      st.flow = { sec: 'agy', kind: 'login', step: 'start' }; paint();
      postJson(API + 'agy-login-start', {}).then(function (r) {
        if (!alive()) return;
        if (r && r.ok && r.url) { st.flow.step = 'code'; st.flow.url = r.url; }
        else { st.flow.step = 'fail'; st.flow.why = (r && r.error) || 'Could not start agy login'; }
        paint();
      }).catch(function () { if (alive()) { st.flow.step = 'fail'; st.flow.why = 'Request did not reach the server'; paint(); } });
    })));
  } else {
    box.appendChild(renderAgyLoginCard(st, paint, alive));
  }
  if (accounts.length < 2) return;
  accounts.slice().sort(function (a, b) { return (b.active ? 1 : 0) - (a.active ? 1 : 0); }).forEach(function (a) {
    const b = mkBtn('', 'acctrow' + (a.active ? ' active' : ''), null);
    const L = mk('div', 'acct-l');
    L.appendChild(mk('span', 'nm', (a.active ? '✓ ' : '') + a.email));
    const live = a.active && u.account === a.email;
    const groups = live ? u.groups : a.groups;
    const age = live ? u.age : a.age;
    const when = agoText(age);
    L.appendChild(mk('span', 'pl', (a.active ? 'In use' : 'Tap to switch') + (when ? ' · ' + when : '')));
    const R = mk('div', 'acct-r');
    const g = agyGemini(groups);
    if (g) {
      const w5 = Math.max(0, Math.round(100 - g.fiveHourRemaining));
      const w7 = Math.max(0, Math.round(100 - g.weeklyRemaining));
      R.style.color = usageColor(w5, w7);
      R.textContent = 'Gemini 5h ' + w5 + '%\nWeekly ' + w7 + '%';
    } else {
      R.style.color = C_GRAY;
      R.textContent = a.active ? '' : 'No reading yet';
    }
    b.appendChild(L); b.appendChild(R);
    b.onclick = function () {
      if (a.active) { flash('Already active: ' + a.email, 1400); return; }
      if (st.flow && st.flow.sec === 'agy' && st.flow.step === 'run') return;
      st.flow = { sec: 'agy', kind: 'switch', step: 'confirm', target: a.email };
      paint();
    };
    box.appendChild(b);
    if (f && f.sec === 'agy' && f.target === a.email) box.appendChild(renderAgySwitchCard(st, paint, alive));
  });
}
function renderAgyLoginCard(st, paint, alive) {
  const f = st.flow, c = mk('div', 'confirm-strip');
  if (f.step === 'start') { c.appendChild(mk('div', '', 'Starting Google login…')); return c; }
  if (f.step === 'fail') {
    const e = mk('div', '', f.why || 'Login failed'); e.style.color = C_RED; c.appendChild(e);
    c.appendChild(mkBtnRow(mkBtn('Close', '', function () { st.flow = null; paint(); }))); return c;
  }
  if (f.step === 'done') {
    const d = mk('div', '', '✓ ' + f.email + ' added · active account unchanged'); d.style.color = C_GREEN; c.appendChild(d);
    c.appendChild(mkBtnRow(mkBtn('OK', '', function () { st.flow = null; paint(); }))); return c;
  }
  const a = mk('a', '', 'Open Google login'); a.href = f.url; a.target = '_blank'; a.rel = 'noopener noreferrer'; c.appendChild(a);
  c.appendChild(mk('div', 'dots', 'After Google approves, paste the one-time code here.'));
  const input = document.createElement('input'); input.type = 'text'; input.autocomplete = 'off'; input.placeholder = 'Google code'; c.appendChild(input);
  c.appendChild(mkBtnRow(mkBtn(f.step === 'run' ? 'Saving…' : 'Save account', 'codex-btn p', function () {
    if (f.step === 'run') return; const code = input.value.trim(); if (!code) return;
    f.step = 'run'; paint();
    postJson(API + 'agy-login-code', { code: code }).then(function (r) {
      if (!alive()) return;
      if (r && r.ok) { f.step = 'done'; f.email = r.email; st.agy = null; fetchAgy(st, paint, alive); }
      else { f.step = 'fail'; f.why = (r && r.error) || 'Login failed'; }
      paint();
    }).catch(function () { if (alive()) { f.step = 'fail'; f.why = 'Request did not reach the server'; paint(); } });
  }), mkBtn('Cancel', '', function () { st.flow = null; paint(); })));
  return c;
}
function renderAgySwitchCard(st, paint, alive) {
  const f = st.flow;
  const c = mk('div', 'confirm-strip');
  const t = mk('div', '', '');
  const who = mk('span', '', f.target); who.style.fontWeight = '700';
  t.appendChild(who);
  if (f.step === 'confirm') {
    t.appendChild(mk('span', '', ' · Switch agy to this login (checked first, about 10 s)'));
    c.appendChild(t);
    // Running agy seats keep the old login and write it back when they refresh.
    // The person decides whether they restart now (idle seats just respawn, busy
    // ones lose the turn and get one "continue") or restarts them later.
    c.appendChild(mk('div', 'dots', 'Running agy seats keep the old login and can switch it back. Restart them now? Busy seats lose their turn, then get a "continue".'));
    const go = function (reseat) {
      f.step = 'run'; f.reseat = reseat; paint();
      postJson(API + 'agy-switch', { email: f.target, reseat: reseat }).then(function (res) {
        if (!alive()) return;
        if (res && res.ok) {
          f.step = 'done';
          const r = res.reseat || {};
          const bits = [];
          if (r.restarted) bits.push(r.restarted + ' idle seat(s) restarted');
          if (r.continued) bits.push(r.continued + ' busy seat(s) restarted and told to continue');
          f.note = bits.join(' · ');
          f.why = !res.needsRestart ? ''
            : reseat ? (res.runningAgy + ' agy process(es) outside Paseo still hold the old login and may switch it back')
            : (res.runningAgy + ' running agy process(es) still hold the old login — restart them (seat-recovery) before they switch it back');
          st.agy = null; fetchAgy(st, paint, alive);
        } else {
          f.step = 'fail'; f.why = ((res && res.error) || 'Unknown failure') + ' · previous login unchanged';
        }
        paint();
      }).catch(function () {
        if (!alive()) return;
        f.step = 'fail'; f.why = 'Request did not reach the server · previous login unchanged'; paint();
      });
    };
    c.appendChild(mkBtnRow(
      mkBtn('Switch + restart', 'codex-btn p', function () { go(true); }),
      mkBtn('Switch only', 'codex-btn', function () { go(false); }),
      mkBtn('Cancel', 'codex-btn', function () { st.flow = null; paint(); })));
    return c;
  }
  if (f.step === 'run') { t.appendChild(mk('span', '', ' · Checking the login…')); c.appendChild(t); return c; }
  if (f.step === 'done') {
    t.appendChild(mk('span', '', ' · ✓ agy now uses this login' + (f.note ? ' · ' + f.note : '') + (f.why ? ' · ' + f.why : '')));
    t.style.color = f.why ? C_AMBER : C_GREEN;
    c.appendChild(t);
    if (!f.why && !f.note) autoCloseDone(st, paint, alive);
    else c.appendChild(mkBtnRow(mkBtn('OK', '', function () { st.flow = null; paint(); })));
    return c;
  }
  t.appendChild(mk('span', '', ' · ' + f.why)); t.style.color = C_RED;
  c.appendChild(t);
  c.appendChild(mkBtnRow(mkBtn('Close', '', function () { st.flow = null; paint(); })));
  return c;
}

function renderAgyBody(box, u, onReask) {
  box.textContent = '';
  const head = mk('div', 'codex-row');
  // With the saved-login list above, the account is already named there; this line
  // then only heads the usage rows.
  const listed = (u.accounts || []).length >= 2 && u.account;
  if (listed) {
    // The rows above already carry the account, its Gemini numbers and the age.
    // Other model groups are side detail here: one small gray line each, so a
    // spent Claude-in-agy group does not shout over the Gemini numbers.
    (u.groups || []).forEach(function (g) {
      if (g === agyGemini(u.groups)) return;
      const name = String(g.name || '').replace(/ MODELS$/, '').toLowerCase().replace(/\b\w/g, function (c) { return c.toUpperCase(); });
      box.appendChild(mk('div', 'dots', name + ' (in agy) · 5h ' + Math.max(0, Math.round(100 - g.fiveHourRemaining)) +
        '% · Weekly ' + Math.max(0, Math.round(100 - g.weeklyRemaining)) + '% · resets ' +
        fmtReset(new Date(g.weeklyResetAt * 1000).toISOString(), true)));
    });
    if (u.refreshing) box.appendChild(mk('div', 'dots', 'Reading again…'));
    if (u.lastErr) {
      box.appendChild(mk('div', 'dots', 'Your login is valid; only usage could not be read. You do not need to log in again.'));
      box.appendChild(mkBtnRow(mkBtn('Read usage again', '', function () { if (onReask) onReask(); })));
    }
    return;
  }
  const nm = mk('span', 'nm', u.account || (u.refreshing ? 'Reading…' : 'No reading yet'));
  if (!u.account) nm.style.color = C_GRAY;
  const pl = mk('span', 'pl');
  const bits = [];
  if (u.age != null) bits.push(u.age < 60 ? 'just now' : Math.round(u.age / 60) + ' min ago');
  if (u.refreshing) bits.push('Reading again…');
  else if (u.lastErr) bits.push('Last read failed: ' + u.lastErr);
  pl.textContent = bits.join(' · ');
  head.appendChild(nm); head.appendChild(pl); box.appendChild(head);
  (u.groups || []).forEach(function (g) {
    const row = mk('div', 'codex-row');
    const gn = mk('span', 'nm'), gp = mk('span', 'pl');
    const used5 = Math.max(0, Math.round(100 - g.fiveHourRemaining));
    const used7 = Math.max(0, Math.round(100 - g.weeklyRemaining));
    const name = String(g.name || '').replace(/ MODELS$/, '').toLowerCase().replace(/\b\w/g, function (c) { return c.toUpperCase(); });
    gn.textContent = name + ' · 5h ' + used5 + '% · Weekly ' + used7 + '%';
    gn.style.color = levelColor(Math.max(usageLevel('5h', used5), usageLevel('7d', used7)));
    gp.textContent = fmtReset(new Date(g.fiveHourResetAt * 1000).toISOString()) +
      ' / ' + fmtReset(new Date(g.weeklyResetAt * 1000).toISOString(), true) + ' reset';
    row.appendChild(gn); row.appendChild(gp); box.appendChild(row);
  });
  if (u.lastErr) {
    box.appendChild(mk('div', 'dots', 'Your login is valid; only usage could not be read. You do not need to log in again.'));
    box.appendChild(mkBtnRow(mkBtn('Read usage again', '', function () { if (onReask) onReask(); })));
  }
}

// Muse key swap is manual. The account API decides which keys are eligible;
// this panel only lets a person choose one and reports the commit result.
function fetchMuse(st, paint, alive, tries) {
  tries = tries || 0;
  fetch(API + 'muse-swap-candidates', { cache: 'no-store' }).then(function (x) { return x.json(); }).then(function (m) {
    if (!alive()) return;
    st.muse = m && m.enabled === true ? m : { enabled: false };
    paint();
    // The surface answered with its last reading and is re-reading behind it.
    if (m && m.refreshing && tries < 8) {
      setTimeout(function () { if (alive()) fetchMuse(st, paint, alive, tries + 1); }, 3000);
    }
  }).catch(function () {
    if (!alive()) return;
    if (!st.muse) { st.museFailed = true; paint(); }
  });
}
function museHead(st) {
  const m = st.muse;
  if (!m) return 'Muse · Checking';
  const cur = (m.candidates || []).find(function (e) { return e.account === m.active; });
  const w = cur ? museWindows(cur) : {};
  return 'Muse · Active ' + (m.active || 'Unavailable') +
    (w.rolling ? ' · 5h ' + w.rolling.percent + '%' : '') +
    (w.weekly ? ' · Weekly ' + w.weekly.percent + '%' : '');
}
function museLimitsText(entry) {
  const order = ['rolling', 'weekly', 'monthly'];
  const by = {};
  (entry.limits || []).forEach(function (w) { by[w.window] = w.percent; });
  return order.map(function (k) { return k + ' ' + by[k] + '%'; }).join(' · ');
}
// One key = one row, the same grammar as the Claude list: ✓ current key on top,
// 5h/weekly/monthly on the right in usage colors, a tap opens the inline confirm
// strip. Spent or unreadable keys stay visible but cannot be picked.
function museLevel(entry) {
  const by = {};
  (entry.limits || []).forEach(function (w) { by[w.window] = w.percent; });
  return Math.max(usageLevel('5h', by.rolling || 0), usageLevel('7d', by.weekly || 0),
                  usageLevel('7d', by.monthly || 0));
}
function museWindows(entry) {
  const by = {};
  (entry.limits || []).forEach(function (w) { by[w.window] = w; });
  return by;
}
function renderMuseBody(st, body, paint, alive) {
  body.textContent = '';
  const m = st.muse || {};
  const f = st.flow && st.flow.sec === 'muse' ? st.flow : null;
  if (m.age != null && m.age >= 60) {
    const age = mk('div', 'dots', 'Checked ' + Math.round(m.age / 60) + ' min ago' + (m.refreshing ? ' · reading again…' : ''));
    body.appendChild(age);
  }
  const rows = (m.candidates || []).slice();
  if (!rows.length) {
    body.appendChild(mk('div', 'codex-row', m.sheet === 'ok'
      ? 'No replacement key is available'
      : 'Cannot switch: assignment sheet unavailable'));
    return;
  }
  const rank = function (e) { return e.account === m.active ? 0 : e.eligible ? 1 : 2; };
  rows.sort(function (a, b) { return rank(a) - rank(b); });
  rows.forEach(function (entry) {
    const active = entry.account === m.active;
    const w = museWindows(entry);
    const blocked = !active && !entry.eligible;
    const b = mkBtn('', 'acctrow' + (active ? ' active' : '') + (blocked ? ' dead' : ''), null);
    const L = mk('div', 'acct-l');
    L.appendChild(mk('span', 'nm', (active ? '✓ ' : '') + entry.account));
    let sub = active ? 'In use' : entry.err ? 'Usage unavailable' : entry.eligible ? 'Tap to switch' : 'Spent';
    if (w.weekly && w.weekly.percent >= 100 && w.weekly.resetAt) sub += ' · weekly resets ' + fmtReset(w.weekly.resetAt, true);
    else if (w.monthly && w.monthly.percent >= 100 && w.monthly.resetAt) sub += ' · monthly resets ' + fmtReset(w.monthly.resetAt, true);
    else if (w.rolling && w.rolling.percent >= 100 && w.rolling.resetAt) sub += ' · 5h resets ' + fmtReset(w.rolling.resetAt, false);
    L.appendChild(mk('span', 'pl', sub));
    const R = mk('div', 'acct-r');
    if (entry.err || !entry.limits || !entry.limits.length) {
      R.style.color = C_GRAY; R.textContent = '—';
    } else {
      R.style.color = levelColor(museLevel(entry));
      R.textContent = '5h ' + (w.rolling ? w.rolling.percent : '—') + '%\nWeekly ' + (w.weekly ? w.weekly.percent : '—') +
        '%\nMonth ' + (w.monthly ? w.monthly.percent : '—') + '%';
    }
    b.appendChild(L); b.appendChild(R);
    b.onclick = function () {
      if (active) { flash('Already in use: ' + entry.account, 1400); return; }
      if (blocked) { flash(entry.err ? 'This key cannot be read right now' : 'This key is spent', 1600); return; }
      if (f && f.step === 'run') return;
      st.flow = { sec: 'muse', kind: 'switch', step: 'confirm', target: entry.account, item: entry.item };
      paint();
    };
    body.appendChild(b);
    if (f && f.target === entry.account) body.appendChild(renderMuseSwitchCard(st, paint, alive));
  });
}
function renderMuseSwitchCard(st, paint, alive) {
  const f = st.flow;
  const c = mk('div', 'confirm-strip');
  const t = mk('div', '', '');
  const who = mk('span', '', f.target); who.style.fontWeight = '700';
  t.appendChild(who);
  if (f.step === 'confirm') {
    t.appendChild(mk('span', '', ' · Switch Muse to this key'));
    c.appendChild(t);
    // Running Muse seats keep the old key until their opencode server restarts.
    // The person decides: restart them now (idle seats reload, busy ones lose the
    // turn and get a "continue"), or restart them later.
    c.appendChild(mk('div', 'dots', 'Running Muse sessions keep the old key until restarted. Restart them now? Busy ones lose their turn, then get a "continue".'));
    const go = function (reseat) {
      f.step = 'run'; paint();
      postJson(API + 'muse-swap', { item: f.item, reseat: reseat }).then(function (r) {
        if (!alive()) return;
        if (r && r.ok) {
          f.step = 'done';
          const rs = r.reseat || {};
          const bits = [];
          if (rs.restarted) bits.push(rs.restarted + ' idle session(s) restarted');
          if (rs.continued) bits.push(rs.continued + ' busy session(s) restarted and told to continue');
          if (rs.failed) bits.push(rs.failed + ' could not be restarted');
          f.note = bits.join(' · ');
          f.why = r.needsRestart ? 'running sessions still use the previous key — restart them with seat-recovery' : '';
          st.muse = null; fetchMuse(st, paint, alive);
        } else {
          f.step = 'fail'; f.why = ((r && r.error) || 'Switch refused') + ' · previous key unchanged';
        }
        paint();
      }).catch(function () {
        if (!alive()) return;
        f.step = 'fail'; f.why = 'Switch request failed · previous key unchanged'; paint();
      });
    };
    c.appendChild(mkBtnRow(
      mkBtn('Switch + restart', 'codex-btn p', function () { go(true); }),
      mkBtn('Switch only', 'codex-btn', function () { go(false); }),
      mkBtn('Cancel', 'codex-btn', function () { st.flow = null; paint(); })));
    return c;
  }
  if (f.step === 'run') { t.appendChild(mk('span', '', ' · Switching…')); c.appendChild(t); return c; }
  if (f.step === 'done') {
    t.appendChild(mk('span', '', ' · ✓ Muse now uses this key' + (f.note ? ' · ' + f.note : '') + (f.why ? ' · ' + f.why : '')));
    t.style.color = f.why ? C_AMBER : C_GREEN;
    c.appendChild(t);
    c.appendChild(mkBtnRow(mkBtn('OK', 'codex-btn', function () { st.flow = null; paint(); })));
    return c;
  }
  t.appendChild(mk('span', '', ' · ' + f.why)); t.style.color = C_RED;
  c.appendChild(t);
  c.appendChild(mkBtnRow(mkBtn('Close', 'codex-btn', function () { st.flow = null; paint(); })));
  return c;
}

// ---- section bodies ----
function renderClaudeBody(st, body, paint, alive) {
  body.textContent = '';
  const j = st.claude;
  if (!j) { body.appendChild(mk('div', 'dots', 'Checking accounts and usage…')); return; }
  if (j.enabled === false) {
    body.appendChild(mk('div', 'dots', 'Claude account switching is disabled in this app')); return;
  }
  const f = st.flow;
  if (f && f.sec === 'claude' && f.kind === 'add') { renderClaudeAdd(st, body, paint, alive); return; }
  (j.accounts || []).forEach(function (a) {
    const dead = a.health && a.health.state === 'dead';
    const u = a.usage || {};
    const b = mkBtn('', 'acctrow' + (dead ? ' dead' : '') + (a.active ? ' active' : ''), null);
    const L = mk('div', 'acct-l');
    const nm = mk('span', 'nm', (a.active ? '✓ ' : dead ? '❌ ' : '') + (a.email || a.name));
    const pl = mk('span', 'pl');
    pl.textContent = dead ? (a.health.reason || 'Unavailable')
                          : (a.kind ? a.kind + ' · ' : '') + a.sub;
    const freshness = !dead ? usageFreshnessText(u) : '';
    if (freshness) pl.textContent += ' · ' + freshness;
    if (dead) b.title = a.health.reason || '';
    const rtd = dead ? null : rtLeft(a);
    if (rtd != null && rtd <= rtWarnDays()) {
      const w = mk('span', '', ' · ' + rtWarnText(rtd));
      w.style.color = rtd <= 2 ? C_RED : C_AMBER; w.style.fontWeight = '600';
      pl.appendChild(w);
    }
    L.appendChild(nm); L.appendChild(pl);
    const R = mk('div', 'acct-r');
    if (dead) {
      R.style.color = C_AMBER;
      R.textContent = 'Log in again';
    } else if (u.use5h != null || u.use7d != null) {
      R.style.color = usageColor(u.use5h, u.use7d);
      R.textContent = '5h ' + (u.use5h == null ? '—' : u.use5h + '%') + '\nWeekly ' + (u.use7d == null ? '—' : u.use7d + '%');
    } else {
      R.style.color = '#8a92a6';
      R.textContent = claudeUsageText(u);
    }
    if (!dead) {
      b.addEventListener('mouseenter', function (e) { showAcctTip(e, u, a); });
      b.addEventListener('mousemove', placeAcctTip);
      b.addEventListener('mouseleave', hideAcctTip);
    }
    b.appendChild(L); b.appendChild(R);
    if (!a.active) {
      const x = mk('span', 'acct-x', '✕');
      x.title = 'Remove this account from the pool';
      x.addEventListener('pointerdown', function (e) { e.preventDefault(); e.stopPropagation(); });
      x.addEventListener('click', function (e) {
        e.preventDefault(); e.stopPropagation();
        const label = a.email || a.name;
        if (!window.confirm('Remove account: ' + label + '\n\nThis removes it from the pool.\nLogging in again restores the same slot. Continue?')) return;
        hideAcctTip();
        postJson(API + 'acct-remove', { name: a.name }).then(function (res) {
          if (res && res.ok) {
            flash('🗑 Removed ' + label, 2500);
            st.claude = null; st.flow = null; paint(); fetchClaude(st, paint, alive);
            refreshAcctIcon();
          }
          else flash('Could not remove account' + (res && res.error ? ': ' + res.error : ''), 3500);
        }).catch(function () { flash('Remove request did not reach the server', 2000); });
      });
      b.appendChild(x);
    }
    b.onclick = function () {
      if (dead) { startFlow(st, paint, 'claude', 'add', { relogin: a.email || a.name }); return; }
      if (a.active) { flash('Already active: ' + a.name, 1400); return; }
      // A switch is confirm strip → progress → done, inline. The list is never
      // closed or redrawn away underneath it (POPUP_SHELL).
      st.flow = { sec: 'claude', kind: 'switch', step: 'confirm', target: a.name };
      paint();
    };
    body.appendChild(b);
    if (f && f.sec === 'claude' && f.kind === 'switch' && f.target === a.name) {
      body.appendChild(renderSwitchCard(st, a, paint, alive));
    }
  });
  const busy = !!(f && f.sec === 'claude');
  const add = mkBtn('Add account', 'addacct', function () { startFlow(st, paint, 'claude', 'add', {}); });
  if (busy) add.disabled = true;
  body.appendChild(add);
}

// switch confirm strip → progress → done/fail. Never closes the list.
function renderSwitchCard(st, a, paint, alive) {
  const f = st.flow;
  if (f.step === 'confirm') {
    const c = mk('div', 'confirm-strip');
    const t = mk('div', '', '');
    const b = mk('span', '', ''); b.style.fontWeight = '700';
    b.textContent = (a.email || a.name);
    t.appendChild(b);
    t.appendChild(mk('span', '', ' · Switch for new sessions · Running sessions stay unchanged'));
    c.appendChild(t);
    c.appendChild(mkBtnRow(
      mkBtn('Switch', 'p', function () {
        f.step = 'run'; paint();
        postJson(API + 'acct-switch', { name: a.name }).then(function (res) {
          if (!alive()) return;
          if (res && res.ok) {
            (st.claude.accounts || []).forEach(function (x) { x.active = (x.name === a.name); });
            flash('✓ ' + (a.email || a.name) + ' is active (applies within a minute · restart a session to use it now)', 3000);
            refreshAcctIcon();
            f.step = 'done';
          } else {
            f.step = 'fail'; f.why = (res && res.error) || 'Unknown failure';
          }
          paint();
        }).catch(function () {
          if (!alive()) return;
          f.step = 'fail'; f.why = 'Request did not reach the server'; paint();
        });
      }),
      mkBtn('Cancel', '', function () { st.flow = null; paint(); })));
    return c;
  }
  if (f.step === 'run') return mk('div', 'prog', '⟳ Switching to ' + (a.email || a.name) + '…');
  if (f.step === 'done') {
    const c = mk('div', 'flow-done', '✓ ' + (a.email || a.name) + ' is active · Applies to new sessions');
    autoCloseDone(st, paint, alive);
    return c;
  }
  // fail
  const c = mk('div', 'flow-fail');
  c.appendChild(mk('div', '', 'Switch failed — the previous account is unchanged'));
  c.appendChild(mk('div', 'mu', f.why || ''));
  c.appendChild(mkBtnRow(
    mkBtn('Log in again', 'p', function () { startFlow(st, paint, 'claude', 'add', { relogin: a.email || a.name }); }),
    mkBtn('Close', '', function () { st.flow = null; paint(); }),
    mkBtn('Copy diagnostics', '', function () {
      if (navigator.clipboard) navigator.clipboard.writeText('acct-switch ' + a.name + ': ' + (f.why || ''));
      flash('Diagnostics copied', 1500);
    })));
  return c;
}

// Claude add/re-login: ready → approve → check → done/fail. The live account is
// untouched until the new code verifies (keep → verify → commit).
function renderClaudeAdd(st, body, paint, alive) {
  const f = st.flow, box = mk('div', 'flow');
  const j = st.claude, active = activeClaude(st);
  const cancel = mkBtn('Cancel', '', function () { st.flow = null; paint(); });
  if (f.step === 'ready') {
    box.appendChild(mk('div', 'step', '① Ready'));
    box.appendChild(mk('div', '', f.relogin
      ? 'Restore the login for “' + f.relogin + '” in the same slot.'
      : 'Add a Claude account to this box pool. The current account (' + (active ? (active.email || active.name) : 'none') + ') will not change.'));
    box.appendChild(mk('div', 'mu', 'Approve once in your browser, then switch without a browser. The login lasts about 30 days.'));
    box.appendChild(mkBtnRow(
      mkBtn('Open Claude approval page', 'p', function () {
        postJson(API + 'acct-login-url', {}).then(function (res) {
          if (!alive()) return;
          if (res && res.ok && res.url) { f.step = 'approve'; f.url = res.url; paint(); }
          else { f.step = 'fail'; f.why = (res && res.error) || 'Could not create approval link'; paint(); }
        }).catch(function () { if (alive()) { f.step = 'fail'; f.why = 'Approval link request did not reach the server'; paint(); } });
      }), cancel));
  } else if (f.step === 'approve') {
    box.appendChild(mk('div', 'step', '② Approve'));
    const p = mk('div', '',
      '① In a new tab, sign in to the account you want to add and approve it. ② Claude will show a one-time code.');
    box.appendChild(p);
    if (f.url) {
      const a = mk('a', 'acct-link', '🔗 Sign in and approve in your browser');
      a.href = f.url; a.target = '_blank'; a.rel = 'noopener noreferrer';
      box.appendChild(a);
    }
    const lbl = mk('label', 'lbl', '③ One-time code from the approval page → paste it here');
    box.appendChild(lbl);
    const inp = document.createElement('input');
    inp.type = 'text'; inp.placeholder = 'Code from the approval page'; inp.autocomplete = 'off'; inp.spellcheck = false;
    inp.value = f.codeText || '';
    inp.addEventListener('input', function () { f.codeText = inp.value; });
    inp.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') { e.preventDefault(); submitCode(); }
    });
    box.appendChild(inp);
    const submitCode = function () {
      const code = (f.codeText || inp.value || '').trim();
      if (!code) { inp.focus(); flash('Paste the code', 2000); return; }
      f.step = 'check'; paint();
      postJson(API + 'acct-login-code', { code: code }).then(function (r) {
        if (!alive()) return;
        if (r && r.ok) {
          f.added = f.relogin || (r.email || 'New account');
          const list = (st.claude && st.claude.accounts) || [];
          const t = list.find(function (x) { return (x.email || x.name) === f.relogin; });
          if (t) { delete t.health; t.usage = { use5h: 0, use7d: 0 }; t.rtExpiry = Date.now() + 30 * 86400000; }
          else if (!f.relogin && !list.some(function (x) { return (x.email || x.name) === f.added; })) {
            list.push({ name: f.added, email: f.added, kind: '', sub: '', active: false,
              usage: { use5h: 0, use7d: 0 }, rtExpiry: Date.now() + 30 * 86400000, holders: [] });
          }
          f.step = 'done'; refreshAcctIcon();
        } else { f.step = 'fail'; f.why = (r && r.error) || 'Could not verify the code'; }
        paint();
      }).catch(function () { if (alive()) { f.step = 'fail'; f.why = 'Verification request did not reach the server'; paint(); } });
    };
    box.appendChild(mkBtnRow(
      mkBtn('Open approval page again', '', function () { flash('Open the link above again for a new approval link', 2500); }),
      mkBtn('Verify code and add', 'p', submitCode), cancel));
  } else if (f.step === 'check') {
    box.appendChild(mk('div', 'step', '③ Checking'));
    box.appendChild(mk('div', 'prog', '⟳ Checking code · The pool is still unchanged'));
    box.appendChild(mkBtnRow(cancel));
  } else if (f.step === 'done') {
    box.appendChild(mk('div', 'step', '④ Done'));
    const c = mk('div', 'flow-done', '✓ ' + f.added + (f.relogin ? ' login restored' : ' added to the pool') + ' · The current account was not changed');
    box.appendChild(c);
    box.appendChild(mkBtnRow(
      mkBtn('Switch to this account', 'p', function () {
        const t = ((st.claude && st.claude.accounts) || []).find(function (x) { return (x.email || x.name) === f.added; });
        if (t && !t.active) st.flow = { sec: 'claude', kind: 'switch', step: 'confirm', target: t.name };
        else st.flow = null;
        paint();
      })));
    autoCloseDone(st, paint, alive);
  } else {
    box.appendChild(mk('div', 'step', '④′ Failed'));
    const c = mk('div', 'flow-fail');
    c.appendChild(mk('div', '', 'Could not verify the code'));
    c.appendChild(mk('div', 'mu', (f.why || '') + ' · The one-time code expires quickly. Get another from a new approval link.'));
    box.appendChild(c);
    box.appendChild(mkBtnRow(
      mkBtn('Open approval page again', 'p', function () { f.step = 'approve'; f.codeText = ''; paint(); }),
      cancel));
  }
  body.appendChild(box);
}

function renderCodexBody(st, box, paint, alive) {
  box.textContent = '';
  const cx = st.codex;
  const f = st.flow;
  if (f && f.sec === 'codex') { renderCodexFlow(st, box, paint, alive); return; }
  if (!cx) { box.appendChild(mk('div', 'dots', 'Checking…')); return; }
  const ok = cx.state === 'ok';
  const row = mk('div', 'codex-row');
  const nm = mk('span', 'nm', ok ? (cx.email || '(Signed in)')
    : cx.state === 'none' ? 'Login required'
    : cx.state === 'pending' ? 'Login in progress' : (cx.reason || cx.state));
  if (!ok) nm.style.color = '#e6b34d';
  const pl = mk('span', 'pl', ok ? ((cx.plan ? cx.plan + ' · ' : '') + 'ChatGPT')
    : cx.state === 'none' ? ' Login required' : '');
  row.appendChild(nm); row.appendChild(pl); box.appendChild(row);
  if (ok) box.appendChild(codexUsageRow(st.codexUsage));
  const busy = _codexOperationPending;
  const relog = mkBtn(ok ? 'Log in again' : 'Log in', '', function () {
    startFlow(st, paint, 'codex', 'relogin', {});
  });
  if (busy) relog.disabled = true;
  const btns = mkBtnRow(relog);
  if (ok) {
    const lo = mkBtn('Log out', 'danger', function () {
      if (!window.confirm('Log out of Codex — this removes the login from this box. Continue?')) return;
      lo.disabled = true; lo.textContent = '…';
      postJson(API + 'codex-logout', {}).then(function (r) {
        if (!alive()) return;
        _codexOperationPending = false;
        if (r && r.ok) {
          setCodexIdentity({ state: 'none' });
          st.codex = { state: 'none' }; st.codexUsage = null;
          flash('Logged out of Codex', 2000); paint();
        } else { lo.disabled = false; lo.textContent = 'Log out'; flash('Could not log out' + (r && r.error ? ': ' + r.error : ''), 3000); }
      }).catch(function () {
        if (!alive()) return;
        _codexOperationPending = false;
        lo.disabled = false; lo.textContent = 'Log out'; flash('Logout request did not reach the server', 2000);
      });
    });
    if (busy) lo.disabled = true;
    btns.appendChild(lo);
  }
  box.appendChild(btns);
}
// The 7d weekly window is the one Codex actually limits on; there is no 5h window to
// show. Graded against the same server thresholds as the Claude rows, so "amber" means
// the same thing in both sections.
function codexUsageRow(usage) {
  const row = mk('div', 'codex-row');
  const nm = mk('span', 'nm'), pl = mk('span', 'pl');
  const u7 = usage && usage.codexUse7d;
  // auth.json is still here (so the row above shows an email and a plan) but the token
  // behind it was revoked — the account line must say so, or the first symptom is an
  // agent dying with "please sign in again". Numbers, if any, are from before the death.
  if (usage && usage.codexErr === 'auth') {
    nm.textContent = 'Signed out — log in again';
    nm.style.color = C_RED;
    pl.textContent = 'You logged out elsewhere or signed in with another account';
    row.appendChild(nm); row.appendChild(pl);
    return row;
  }
  if (u7 == null) {
    nm.textContent = 'Weekly usage';
    nm.style.color = C_GRAY;
    pl.textContent = usage && usage.codexErr ? String(usage.codexErr) : 'Checking…';
  } else {
    nm.textContent = 'Weekly ' + u7 + '%' + (usage.codexStale ? ' (last reading)' : '');
    nm.style.color = levelColor(usageLevel('7d', u7));
    const bits = [];
    if (usage.codexReset7d) bits.push('Resets ' + fmtReset(usage.codexReset7d, true));
    if (usage.codexCredits != null) bits.push('Credits ' + usage.codexCredits);
    pl.textContent = bits.join(' · ');
  }
  row.appendChild(nm); row.appendChild(pl);
  return row;
}

// Codex re-login: keep → verify → commit. Starting keeps the existing login in a
// backup; cancelling (or the server TTL, SAFETY) restores it. Nothing is discarded
// before the new credential verifies.
function renderCodexFlow(st, box, paint, alive) {
  const f = st.flow, cbox = mk('div', 'flow');
  const cx = st.codex || { state: 'none' };
  if (f.step === 'ready') {
    cbox.appendChild(mk('div', 'step', '① Ready'));
    cbox.appendChild(mk('div', '', 'Now: ' + (cx.state === 'ok'
      ? 'Signed in ' + (cx.email || '') + ' · Weekly ' + ((st.codexUsage && st.codexUsage.codexUse7d) != null ? st.codexUsage.codexUse7d + '%' : 'Checking')
      : 'Not signed in')));
    cbox.appendChild(mk('div', '', 'Codex will be unavailable briefly. The existing login is saved and restored if you cancel or after 15 minutes.'));
    cbox.appendChild(mk('div', 'mu', 'Running Codex sessions on this box may stop on their next request.'));
    cbox.appendChild(mkBtnRow(
      mkBtn('Start login', 'p', function () {
        f.backup = cx.state === 'ok' ? Object.assign({}, cx) : null;
        _codexOperationPending = true;
        postJson(API + 'codex-login-start', {}).then(function (r) {
          if (!alive()) return;
          if (r && r.ok && r.code) {
            st.codex = { state: 'pending' };
            f.step = 'approve'; f.code = r.code; f.url = r.url; paint();
          } else {
            _codexOperationPending = false;
            flash('Could not start Codex login' + (r && r.error ? ': ' + r.error : ''), 4500);
          }
        }).catch(function () {
          if (!alive()) return;
          _codexOperationPending = false;
          flash('Codex login request did not reach the server', 2000);
        });
      }),
      mkBtn('Cancel', '', function () { st.flow = null; paint(); })));
  } else if (f.step === 'approve') {
    cbox.appendChild(mk('div', 'step', '② Browser approval'));
    cbox.appendChild(mk('div', '', '① Open a new tab → OpenAI approval page'));
    cbox.appendChild(mk('div', '', '② Enter the code below on that page'));
    if (f.url) {
      const a = mk('a', 'acct-link', '🔗 ' + f.url);
      a.href = f.url; a.target = '_blank'; a.rel = 'noopener noreferrer';
      cbox.appendChild(a);
    }
    const codeEl = mk('code', 'cg-cmd', f.code || '');
    codeEl.title = 'Click to copy';
    codeEl.onclick = function () {
      if (navigator.clipboard && f.code) { navigator.clipboard.writeText(f.code); flash('Copied', 1200); }
    };
    cbox.appendChild(codeEl);
    cbox.appendChild(mk('div', 'mu', 'Airlock generated this code → enter it in your browser'));
    cbox.appendChild(mk('div', 'warnln', '⏱ Approve within 15 minutes · Existing login saved'));
    const chk = mkBtn('Check approval', 'p', function () {
      chk.disabled = true; chk.textContent = 'Checking…';
      fetch(API + 'claude-status').then(function (x) { return x.json(); }).then(function (s) {
        if (!alive()) return;
        const ncx = (s && s.codex) || {};
        if (ncx.state === 'ok') {
          _codexOperationPending = false;
          flash('✓ Signed in to Codex: ' + (ncx.email || ''), 3000);
          const identity = setCodexIdentity(ncx);
          st.codex = ncx; st.codexUsage = _codexUsage;
          f.step = 'done'; paint();
          fetchCodexUsage(st, paint, alive, { scheduled: false });
        } else {
          chk.disabled = false; chk.textContent = 'Check approval';
          flash('Not approved yet — enter and approve the code, then check again', 4000);
        }
      }).catch(function () { if (alive()) { chk.disabled = false; chk.textContent = 'Check approval'; } });
    });
    cbox.appendChild(mkBtnRow(chk,
      mkBtn('Cancel and restore previous login', 'danger', function () {
        postJson(API + 'codex-login-cancel', {}).then(function (rr) {
          if (!alive()) return;
          _codexOperationPending = false;
          if (rr && rr.ok) {
            if (f.backup) { st.codex = Object.assign({}, f.backup); st.codex.state = 'ok'; setCodexIdentity(st.codex); }
            else st.codex = { state: 'none' };
            st.codexUsage = null;
            flash(rr.restored ? 'Cancelled — previous login restored' : 'Cancelled', 2500);
            st.flow = null; paint();
          } else flash('Could not cancel' + (rr && rr.error ? ': ' + rr.error : ''), 3000);
        }).catch(function () {});
      })));
  } else if (f.step === 'check') {
    cbox.appendChild(mk('div', 'step', '③ Checking'));
    cbox.appendChild(mk('div', 'prog', '⟳ Checking new login…'));
  } else {
    cbox.appendChild(mk('div', 'step', '④ Done'));
    cbox.appendChild(mk('div', 'flow-done', '✓ Signed in again as ' + ((st.codex && st.codex.email) || '') + ' · Usage will be read for the new account'));
    autoCloseDone(st, paint, alive);
  }
  box.appendChild(cbox);
}

// xAI section removed (POPUP_SHELL rework, 사람 결정 9dac31a6 팝업에서 제거):
// the backend xai-* routes stay, but this shell no longer lists, fetches or
// flows them. The section below used to live here; deleting it outright keeps
// a removed section from ever reading as a passing one.
function startFlow(st, paint, sec, kind, extra) {
  if (st.flow) { flash('Finish or cancel the current action first', 2500); return; }
  st.flow = Object.assign({ sec: sec, kind: kind, step: 'ready' }, extra || {});
  st.expand[sec] = true;
  if (sec === 'codex') _codexOperationPending = kind === 'relogin';
  paint();
}

// ---- data fetches (each paints on arrival; sections never wait for each other) ----
function fetchClaude(st, paint, alive) {
  fetch(API + 'accounts').then(function (x) { return x.json(); }).then(function (j) {
    if (!alive()) return;
    if (j && j.thresholds) setThresholds(j.thresholds);
    st.claude = j && j.enabled === false ? { enabled: false } : j;
    paint();
    if (j && j.enabled === false) return;
    postJson(API + 'acct-usage-now', {}).then(function (fresh) {
      if (!alive()) return;
      if (st.flow && st.flow.sec === 'claude') return;    // a login form owns the section
      if (!fresh || !fresh.usage) {
        const a = activeClaude(st);
        if (a) a.usage = Object.assign({}, a.usage || {}, { err: 'unreadable response' });
        paint();
        return;
      }
      ((st.claude && st.claude.accounts) || []).forEach(function (a) {
        const matches = fresh.email ? a.email === fresh.email && a.kind === fresh.kind : a.active;
        if (!matches) return;
        if (fresh.usage.err || (fresh.usage.use5h == null && fresh.usage.use7d == null)) {
          a.usage = Object.assign({}, a.usage || {}, { err: fresh.usage.err || 'unreadable' });
        } else {
          a.usage = fresh.usage;
        }
      });
      paint();
    }).catch(function () {
      if (!alive()) return;
      const a = activeClaude(st);
      if (a) a.usage = Object.assign({}, a.usage || {}, { err: 'request failed' });
      paint();
    });
  }).catch(function () {
    if (!alive()) return;
    st.claudeFailed = true; paint();
  });
}
function fetchCodex(st, paint, alive) {
  _codexOperationPending = false;
  fetch(API + 'codex-status', { cache: 'no-store' }).then(function (x) { return x.json(); }).then(function (cx) {
    if (!alive()) return;
    cx = (cx && cx.state) ? cx : { state: 'unknown' };
    setCodexIdentity(cx);
    st.codex = cx;
    st.codexUsage = _codexUsage;
    paint();
    if (cx.state === 'ok') fetchCodexUsage(st, paint, alive, { scheduled: false });
  }).catch(function () {
    if (!alive()) return;
    st.codex = { state: 'unknown', reason: 'Could not read status' }; paint();
  });
}
// account popup placement — under the anchor, but flip above it if there isn't room below (bottom key bar).
// The list/Codex/login form fill async so the height grows; re-place on each render (reflow).
function placeAcctMenu(pop, anchor) {
  const r = anchor.getBoundingClientRect();
  const vh = window.visualViewport ? Math.round(window.visualViewport.height) : window.innerHeight;
  const h = pop.offsetHeight;
  let top = r.bottom + 6;
  if (top + h > vh - 6) top = r.top - h - 6;              // overflow below -> flip above the anchor
  top = Math.max(6, Math.min(top, vh - h - 8));           // still overflowing -> clamp into the viewport (internal scroll)
  pop.style.left = Math.max(6, Math.min(r.right - 320, window.innerWidth - pop.offsetWidth - 8)) + 'px';
  pop.style.top = top + 'px';
}
// The account list is built once and shown in two places: the popup anchored to the
// icon (devterm) and a plain panel that fills its container (panel.html, which the
// Airlock return widget opens in an iframe from another origin). Only the framing
// differs, so the list itself lives here and the caller passes the framing in:
//   reflow()     — re-place after the height changed (no-op for a panel)
//   reopen()     — redraw from scratch (after a removal)
//   alive()      — is the container still on the page (drop late replies)
//   onSwitched() — what to do after a successful switch (popup closes, panel redraws)
function fillAcctList(list, opts) {
  const reflow = opts.reflow, alive = opts.alive || function () { return true; };
  const st = newShellState();
  list.textContent = '';
  const needs = mk('div', 'needs', 'Checking required actions…');
  list.appendChild(needs);
  // Build the section shells NOW, before any request answers. /accounts runs the
  // account CLI (up to 15 s) and then the fleet store; the Codex and agy rows do
  // not depend on it and must not wait for it — they paint from their own calls.
  const secs = {};
  const order = ['claude', 'codex', 'agy', 'muse'];
  const titles = { claude: 'Claude', codex: 'Codex', agy: 'Gemini', muse: 'Muse' };
  order.forEach(function (key) {
    const sec = mk('div', 'sec'); sec.dataset.sec = key;
    const head = mk('div', 'sec-head');
    head.appendChild(mk('span', 'chev', '▸'));
    head.appendChild(mk('span', 'sec-title'));
    head.onclick = function () {
      if (st.flow && st.flow.sec === key) return;   // a guided flow owns its section
      st.expand[key] = !st.expand[key];
      paint();
      if (reflow) reflow();
    };
    const body = mk('div', 'sec-body');
    sec.appendChild(head); sec.appendChild(body);
    list.appendChild(sec);
    secs[key] = { sec: sec, head: head, body: body };
  });
  const headText = { claude: claudeHead, codex: codexHead, agy: agyHead, muse: museHead };
  function paint() {
    if (!alive()) return;
    // summary line
    needs.textContent = '';
    const iss = shellIssues(st);
    if (!st.claude && !st.codex && !st.agy) {
      needs.appendChild(mk('span', '', 'Checking required actions…'));
    } else if (!iss.length) {
      needs.appendChild(mk('span', '', 'No action required'));
    } else {
      needs.appendChild(mk('span', '', iss.length + ' action' + (iss.length === 1 ? '' : 's') + ' required · '));
      iss.forEach(function (it, i) {
        if (i) needs.appendChild(mk('span', '', ' · '));
        const a = mk('a', '', it.label);
        a.dataset.go = it.sec;
        a.onclick = function () { st.expand[it.sec] = true; paint(); if (reflow) reflow(); };
        needs.appendChild(a);
      });
    }
    order.forEach(function (key) {
      const S = secs[key];
      const open = !!st.expand[key];
      // agy unreadable box / Muse keys absent: no section at all (as before).
      const hide = (key === 'agy' && st.agy && st.agy.enabled === false) ||
                   (key === 'muse' && st.muse && st.muse.enabled === false);
      S.sec.style.display = hide ? 'none' : '';
      if (hide) return;
      S.head.querySelector('.chev').textContent = open ? '▾' : '▸';
      S.head.querySelector('.sec-title').textContent = headText[key](st);
      S.body.style.display = open ? '' : 'none';
      if (!open) return;
      if (key === 'claude') renderClaudeBody(st, S.body, paint, alive);
      else if (key === 'codex') renderCodexBody(st, S.body, paint, alive);
      else if (key === 'agy') {
        S.body.textContent = '';
        if (!st.agy && !st.agyFailed) S.body.appendChild(mk('div', 'dots', 'Checking…'));
        else if (st.agyFailed) S.body.appendChild(mk('div', 'dots', 'Could not read usage'));
        else if (st.agy && st.agy.enabled === false) S.body.appendChild(mk('div', 'dots', 'Not available on this box'));
        else {
          renderAgyBody(S.body, st.agy || {}, function () {
            st.agy = null; st.agyFailed = false; paint();
            fetchAgy(st, paint, alive);
          });
          const list = mk('div', '');
          renderAgyAccounts(st, list, paint, alive);
          if (list.childNodes.length) S.body.insertBefore(list, S.body.firstChild);
        }
      }
      else if (key === 'muse') {
        S.body.textContent = '';
        if (!st.muse && !st.museFailed) S.body.appendChild(mk('div', 'dots', 'Checking…'));
        else if (st.museFailed) S.body.appendChild(mk('div', 'dots', 'Could not read Muse key'));
        else if (st.muse && st.muse.enabled === false) S.body.appendChild(mk('div', 'dots', 'Not available on this box'));
        else renderMuseBody(st, S.body, paint, alive);
      }
    });
    if (reflow) reflow();
  }
  paint();
  fetchClaude(st, paint, alive);
  fetchCodex(st, paint, alive);
  fetchAgy(st, paint, alive);
  fetchMuse(st, paint, alive);
}

// devterm: the popup anchored to the account icon.
function openAcctMenu(anchor) {
  closeTabPops();
  const pop = document.createElement('div'); pop.className = 'tab-pop acct';
  const list = document.createElement('div');
  list.appendChild(mk('div', 'dots', 'Checking accounts and usage…')); pop.appendChild(list);
  const r = anchor.getBoundingClientRect();
  placePop(pop, r.right - 320, r.bottom + 6);   // append to body first so we can measure
  const reflow = function () { placeAcctMenu(pop, anchor); };
  reflow();                                     // place from the loading state — flip above if near the bottom bar
  fillAcctList(list, {
    reflow: reflow,
    reopen: function () { openAcctMenu(anchor); },
    alive: function () { return document.body.contains(pop); },
    onSwitched: function () { openAcctMenu(anchor); },
  });
}

// panel.html: the same list filling a container, with no popup framing. The panel never
// closes underneath a switch — the ✓ moves inline and the list redraws in place.
function renderAcctPanel(container) {
  container.className = 'tab-pop acct acct-panel';
  container.textContent = '';
  const list = document.createElement('div');
  container.appendChild(list);
  fillAcctList(list, {
    reflow: function () {},
    reopen: function () { renderAcctPanel(container); },
    alive: function () { return document.body.contains(container); },
    onSwitched: function () { renderAcctPanel(container); },
  });
}

  // the 4 the terminal core uses + the one panel.html uses
  return { openAcctMenu: openAcctMenu, applyAcctIconCls: applyAcctIconCls,
           startAcctIconWatch: startAcctIconWatch, hideAcctTip: hideAcctTip,
           renderAcctPanel: renderAcctPanel };
};
