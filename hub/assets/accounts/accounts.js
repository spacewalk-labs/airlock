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
  if (d <= 0) return '⚠ 만료됨 · 다시 로그인';
  if (d < 1) return '⚠ 오늘 만료 · 다시 로그인';
  return '⚠ ' + Math.floor(d) + '일 뒤 만료 · 다시 로그인';
}
function acctTipText(u, a) {
  const L = [];
  if (u.use5h == null && u.use7d == null) {
    L.push(u.err === 'no data' ? '사용량 수집 중\n(1분마다)'
         : u.err === 'no store' ? '공유 사용량 저장소가 없어\n여기서는 사용 중인 계정만 읽힙니다.'
         : '조회 실패\n' + (u.err || '?'));
  } else {
    L.push('5시간↻ ' + (u.reset5h ? fmtReset(u.reset5h, false) : '—') +
           '\n주간↺ ' + (u.reset7d ? fmtReset(u.reset7d, true) : '—') +
           (u.stale ? '\n(마지막 값)' : ''));
  }
  // who holds it = the shared store's holders. Using the same account in two places burns 5h twice as fast.
  const h = (a && a.holders) || [];
  if (h.length) L.push('사용 중\n' + h.map(function (x) { return '· ' + x.who; }).join('\n'));
  const d = rtLeft(a);
  if (d != null) {
    L.push(d <= rtWarnDays()
      ? rtWarnText(d) + '\n(만료일은 로그인 뒤 약 30일로 고정 —\n써도 늘어나지 않습니다)'
      : '로그인 만료까지 ' + Math.floor(d) + '일');
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
  _acctIconTimer = setInterval(refreshAcctIcon, 60000);   // matches the background collection cadence (1 min)
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
    if (u.err === 'no data') return '수집 중\n(1분 이내)';
    if (u.err === 'no store') return '사용량 출처\n없음';
    if (u.err) return '확인 실패\n' + u.err;
    return '확인 중';
  }
  return '5시간 ' + (u.use5h == null ? '—' : u.use5h + '%') +
       '\n주간 ' + (u.use7d == null ? '—' : u.use7d + '%');
}

// ---- one-line headers: who · how much · next reset ----
function claudeHead(st) {
  const j = st.claude;
  if (!j) return 'Claude · 확인 중';
  if (j.enabled === false) return 'Claude · 이 앱에서는 전환 꺼짐';
  const list = j.accounts || [];
  const a = activeClaude(st);
  if (!a) return 'Claude · 계정 ' + list.length + '개 · 사용 중 없음';
  const u = a.usage || {};
  const much = (u.use5h == null && u.use7d == null)
    ? '확인 중'
    : '5시간 ' + (u.use5h == null ? '—' : u.use5h + '%') +
      ' · 주간 ' + (u.use7d == null ? '—' : u.use7d + '%');
  const reset = u.reset5h ? ' · 다음 초기화 ' + fmtReset(u.reset5h, false) : '';
  return 'Claude · 사용 중 ' + (a.email || a.name) + ' · ' + much + reset + ' · 계정 ' + list.length + '개';
}
function codexHead(st) {
  const cx = st.codex;
  if (!cx) return 'Codex · 확인 중';
  if (cx.state === 'pending') return 'Codex · 로그인 진행 중';
  if (cx.state !== 'ok') return 'Codex · 로그인 필요';
  const u = st.codexUsage || {};
  const much = u.codexUse7d == null ? '확인 중' : '주간 ' + u.codexUse7d + '%';
  const reset = u.codexReset7d ? ' · ' + fmtReset(u.codexReset7d, true) + ' 초기화' : '';
  if (u.codexErr === 'auth') return 'Codex · 로그인 해제됨 · 다시 로그인';
  return 'Codex · 로그인됨 ' + (cx.email || '') + ' · ' + much + reset;
}
function agyHead(st) {
  const u = st.agy;
  if (!u) return 'Gemini · 확인 중';
  const acc = u.account || '';
  const gs = u.groups || [];
  if (!acc && !gs.length) {
    if (u.refreshing) return 'Gemini · 읽는 중…';
    return 'Gemini · 아직 읽은 값 없음';
  }
  let worst5 = null, worst7 = null;
  gs.forEach(function (g) {
    const w5 = Math.max(0, Math.round(100 - g.fiveHourRemaining));
    const w7 = Math.max(0, Math.round(100 - g.weeklyRemaining));
    worst5 = worst5 == null ? w5 : Math.max(worst5, w5);
    worst7 = worst7 == null ? w7 : Math.max(worst7, w7);
  });
  const much = worst5 == null ? '확인 중' : '5시간 ' + worst5 + '% · 주간 ' + worst7 + '%';
  return 'Gemini · 사용 중 ' + (acc || '확인 중') + ' · ' + much + ' · 계정 ' + gs.length + '개';
}
// action-needed summary. Always rendered: calm days read 조치 필요 없음, not silence.
function shellIssues(st) {
  const out = [];
  const cx = st.codex;
  if (cx && cx.state === 'pending') out.push({ sec: 'codex', label: 'Codex 로그인 진행 중' });
  else if (cx && cx.state !== 'ok' && cx.state !== 'unknown') out.push({ sec: 'codex', label: 'Codex 로그인 필요' });
  else if (cx && cx.state === 'ok' && st.codexUsage && st.codexUsage.codexErr === 'auth')
    out.push({ sec: 'codex', label: 'Codex 로그인 해제됨' });
  const dead = ((st.claude && st.claude.accounts) || []).filter(function (a) {
    return a.health && a.health.state === 'dead';
  });
  if (dead.length) out.push({ sec: 'claude', label: 'Claude 로그인 만료 ' + dead.length + '건' });
  if (st.geminiUsageBad) out.push({ sec: 'gemini', label: 'Gemini 사용량 확인 불가' });
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
    st.codexUsage = { codexErr: '확인 실패' };
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
function renderAgyBody(box, u, onReask) {
  box.textContent = '';
  const head = mk('div', 'codex-row');
  const nm = mk('span', 'nm', u.account || (u.refreshing ? '읽는 중…' : '아직 읽은 값 없음'));
  if (!u.account) nm.style.color = C_GRAY;
  const pl = mk('span', 'pl');
  const bits = [];
  if (u.age != null) bits.push(u.age < 60 ? '방금' : Math.round(u.age / 60) + '분 전');
  if (u.refreshing) bits.push('다시 읽는 중…');
  else if (u.lastErr) bits.push('마지막 읽기 실패: ' + u.lastErr);
  pl.textContent = bits.join(' · ');
  head.appendChild(nm); head.appendChild(pl); box.appendChild(head);
  if (!u.account && !u.refreshing) {
    // AGY_SWAP ① RED: agy offers no login/switch path, so this section stays
    // read-only. When there is no reading, say the one true thing: a human
    // signs in by running agy in a terminal on this box. (Wording owned by
    // AGY_SWAP — kept verbatim so its gate keeps passing.)
    const hint = mk('div', 'codex-row', 'Manual login only — run agy in a terminal on this box and sign in with Google.');
    hint.style.color = C_GRAY;
    box.appendChild(hint);
  }
  (u.groups || []).forEach(function (g) {
    const row = mk('div', 'codex-row');
    const gn = mk('span', 'nm'), gp = mk('span', 'pl');
    const used5 = Math.max(0, Math.round(100 - g.fiveHourRemaining));
    const used7 = Math.max(0, Math.round(100 - g.weeklyRemaining));
    const name = String(g.name || '').replace(/ MODELS$/, '').toLowerCase().replace(/\b\w/g, function (c) { return c.toUpperCase(); });
    gn.textContent = name + ' · 5시간 ' + used5 + '% · 주간 ' + used7 + '%';
    gn.style.color = levelColor(Math.max(usageLevel('5h', used5), usageLevel('7d', used7)));
    gp.textContent = fmtReset(new Date(g.fiveHourResetAt * 1000).toISOString()) +
      ' / ' + fmtReset(new Date(g.weeklyResetAt * 1000).toISOString(), true) + ' 초기화';
    row.appendChild(gn); row.appendChild(gp); box.appendChild(row);
  });
  if (u.lastErr) {
    box.appendChild(mk('div', 'dots', '로그인은 정상입니다 — 사용량만 읽지 못했습니다. 다시 로그인할 필요 없습니다.'));
    box.appendChild(mkBtnRow(mkBtn('사용량 다시 읽기', '', function () { if (onReask) onReask(); })));
  }
}

// Muse key status (POPUP_SHELL rework). Current key only: the row shows the
// three usage numbers or 확인 불가, never a candidate list and never a swap
// button. Swapping lives in the fleet app now (it owns the picker and the
// POST /muse-swap call); this shell keeps reading GET /muse-swap-candidates
// so the numbers stay, but offers nothing to click. A swap can therefore never
// originate here, so there is no swapped banner and no 교체 막힘 pill.
function fetchMuse(st, paint, alive) {
  fetch(API + 'muse-swap-candidates', { cache: 'no-store' }).then(function (x) { return x.json(); }).then(function (m) {
    if (!alive()) return;
    st.muse = m && m.enabled === true ? m : { enabled: false };
    paint();
  }).catch(function () {
    if (!alive()) return;
    if (!st.muse) { st.museFailed = true; paint(); }
  });
}
function museHead(st) {
  const m = st.muse;
  if (!m) return 'Muse · 확인 중';
  return 'Muse · 사용 중 ' + (m.active || '확인 불가');
}
function museLimitsText(entry) {
  const order = ['rolling', 'weekly', 'monthly'];
  const by = {};
  (entry.limits || []).forEach(function (w) { by[w.window] = w.percent; });
  return order.map(function (k) { return k + ' ' + by[k] + '%'; }).join(' · ');
}
function renderMuseBody(st, body, paint, alive) {
  body.textContent = '';
  const m = st.muse || {};
  const head = mk('div', 'codex-row');
  const nm = mk('span', 'nm', m.active ? ('현재 키: ' + m.active) : '현재 키 확인 불가');
  if (!m.active) nm.style.color = C_GRAY;
  head.appendChild(nm);
  const ep = mk('span', 'pl');
  const cur = (m.candidates || []).find(function (e) { return e.account === m.active; });
  if (cur && !cur.err) {
    ep.textContent = museLimitsText(cur);
    const worst = Math.max.apply(null, (cur.limits || []).map(function (w) { return w.percent; }));
    if (worst >= 100) ep.style.color = C_RED;
  } else {
    ep.textContent = '확인 불가';
    ep.style.color = C_GRAY;
  }
  head.appendChild(ep); body.appendChild(head);
  body.appendChild(mk('div', 'codex-row', '키 교체는 플릿 앱에서 한다'));
}

// ---- section bodies ----
function renderClaudeBody(st, body, paint, alive) {
  body.textContent = '';
  const j = st.claude;
  if (!j) { body.appendChild(mk('div', 'dots', '계정·사용량 확인 중…')); return; }
  if (j.enabled === false) {
    body.appendChild(mk('div', 'dots', '이 앱에서는 Claude 계정 전환이 꺼져 있습니다')); return;
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
    pl.textContent = dead ? (a.health.reason || '사용 불가')
                          : (a.kind ? a.kind + ' · ' : '') + a.sub;
    if (!dead && u.stale && (u.use5h != null || u.use7d != null)) pl.textContent += ' · (마지막 값)';
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
      R.textContent = '다시 로그인';
    } else if (u.use5h != null || u.use7d != null) {
      R.style.color = usageColor(u.use5h, u.use7d);
      R.textContent = '5시간 ' + (u.use5h == null ? '—' : u.use5h + '%') + '\n주간 ' + (u.use7d == null ? '—' : u.use7d + '%');
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
      x.title = '풀에서 이 계정 지우기';
      x.addEventListener('pointerdown', function (e) { e.preventDefault(); e.stopPropagation(); });
      x.addEventListener('click', function (e) {
        e.preventDefault(); e.stopPropagation();
        const label = a.email || a.name;
        if (!window.confirm('계정 지우기: ' + label + '\n\n풀에서 지웁니다.\n다시 로그인하면 같은 자리가 살아납니다. 계속할까요?')) return;
        hideAcctTip();
        postJson(API + 'acct-remove', { name: a.name }).then(function (res) {
          if (res && res.ok) {
            flash('🗑 ' + label + ' 지웠습니다', 2500);
            st.claude = null; st.flow = null; paint(); fetchClaude(st, paint, alive);
            refreshAcctIcon();
          }
          else flash('지우지 못했습니다' + (res && res.error ? ': ' + res.error : ''), 3500);
        }).catch(function () { flash('지우기 요청이 닿지 않았습니다', 2000); });
      });
      b.appendChild(x);
    }
    b.onclick = function () {
      if (dead) { startFlow(st, paint, 'claude', 'add', { relogin: a.email || a.name }); return; }
      if (a.active) { flash('이미 사용 중입니다: ' + a.name, 1400); return; }
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
  const add = mkBtn('계정 추가', 'addacct', function () { startFlow(st, paint, 'claude', 'add', {}); });
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
    t.appendChild(mk('span', '', ' 로 전환 · 새 세션부터 적용 · 지금 돌아가는 세션은 그대로'));
    c.appendChild(t);
    c.appendChild(mkBtnRow(
      mkBtn('전환', 'p', function () {
        f.step = 'run'; paint();
        postJson(API + 'acct-switch', { name: a.name }).then(function (res) {
          if (!alive()) return;
          if (res && res.ok) {
            (st.claude.accounts || []).forEach(function (x) { x.active = (x.name === a.name); });
            flash('✓ ' + (a.email || a.name) + ' 사용 중 (1분 안에 적용 · 바로 쓰려면 세션을 다시 시작하세요)', 3000);
            refreshAcctIcon();
            f.step = 'done';
          } else {
            f.step = 'fail'; f.why = (res && res.error) || '알 수 없는 실패';
          }
          paint();
        }).catch(function () {
          if (!alive()) return;
          f.step = 'fail'; f.why = '요청이 닿지 않았습니다'; paint();
        });
      }),
      mkBtn('취소', '', function () { st.flow = null; paint(); })));
    return c;
  }
  if (f.step === 'run') return mk('div', 'prog', '⟳ ' + (a.email || a.name) + ' 로 전환 중…');
  if (f.step === 'done') {
    const c = mk('div', 'flow-done', '✓ ' + (a.email || a.name) + ' 사용 중 · 새 세션부터 적용');
    c.appendChild(mkBtnRow(mkBtn('완료', 'p', function () { st.flow = null; paint(); })));
    return c;
  }
  // fail
  const c = mk('div', 'flow-fail');
  c.appendChild(mk('div', '', '전환하지 못했습니다 — 기존 계정 그대로'));
  c.appendChild(mk('div', 'mu', f.why || ''));
  c.appendChild(mkBtnRow(
    mkBtn('다시 로그인', 'p', function () { startFlow(st, paint, 'claude', 'add', { relogin: a.email || a.name }); }),
    mkBtn('닫기', '', function () { st.flow = null; paint(); }),
    mkBtn('진단 정보 복사', '', function () {
      if (navigator.clipboard) navigator.clipboard.writeText('acct-switch ' + a.name + ': ' + (f.why || ''));
      flash('진단 정보를 복사했습니다', 1500);
    })));
  return c;
}

// Claude add/re-login: ready → approve → check → done/fail. The live account is
// untouched until the new code verifies (keep → verify → commit).
function renderClaudeAdd(st, body, paint, alive) {
  const f = st.flow, box = mk('div', 'flow');
  const j = st.claude, active = activeClaude(st);
  const cancel = mkBtn('취소', '', function () { st.flow = null; paint(); });
  if (f.step === 'ready') {
    box.appendChild(mk('div', 'step', '① 준비'));
    box.appendChild(mk('div', '', f.relogin
      ? '「' + f.relogin + '」 로그인을 되살립니다. 같은 자리로 돌아옵니다.'
      : 'Claude 계정을 이 박스 풀에 추가합니다. 현재 계정(' + (active ? (active.email || active.name) : '없음') + ')은 바뀌지 않습니다.'));
    box.appendChild(mk('div', 'mu', '브라우저에서 한 번 승인하면 그 뒤로는 브라우저 없이 전환합니다. 로그인은 약 30일 유지됩니다.'));
    box.appendChild(mkBtnRow(
      mkBtn('Claude 승인 페이지 열기', 'p', function () {
        postJson(API + 'acct-login-url', {}).then(function (res) {
          if (!alive()) return;
          if (res && res.ok && res.url) { f.step = 'approve'; f.url = res.url; paint(); }
          else { f.step = 'fail'; f.why = (res && res.error) || '승인 링크를 만들지 못했습니다'; paint(); }
        }).catch(function () { if (alive()) { f.step = 'fail'; f.why = '승인 링크 요청이 닿지 않았습니다'; paint(); } });
      }), cancel));
  } else if (f.step === 'approve') {
    box.appendChild(mk('div', 'step', '② 승인'));
    const p = mk('div', '',
      '① 새 탭에서 추가할 계정으로 로그인하고 승인하세요. ② 승인이 끝나면 Claude가 일회용 코드를 보여줍니다.');
    box.appendChild(p);
    if (f.url) {
      const a = mk('a', 'acct-link', '🔗 브라우저에서 로그인·승인하기');
      a.href = f.url; a.target = '_blank'; a.rel = 'noopener noreferrer';
      box.appendChild(a);
    }
    const lbl = mk('label', 'lbl', '③ 승인 페이지에서 받은 일회용 코드 → 여기에 붙여넣기');
    box.appendChild(lbl);
    const inp = document.createElement('input');
    inp.type = 'text'; inp.placeholder = '승인 페이지에서 받은 코드'; inp.autocomplete = 'off'; inp.spellcheck = false;
    inp.value = f.codeText || '';
    inp.addEventListener('input', function () { f.codeText = inp.value; });
    inp.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') { e.preventDefault(); submitCode(); }
    });
    box.appendChild(inp);
    const submitCode = function () {
      const code = (f.codeText || inp.value || '').trim();
      if (!code) { inp.focus(); flash('코드를 붙여넣으세요', 2000); return; }
      f.step = 'check'; paint();
      postJson(API + 'acct-login-code', { code: code }).then(function (r) {
        if (!alive()) return;
        if (r && r.ok) {
          f.added = f.relogin || (r.email || '새 계정');
          const list = (st.claude && st.claude.accounts) || [];
          const t = list.find(function (x) { return (x.email || x.name) === f.relogin; });
          if (t) { delete t.health; t.usage = { use5h: 0, use7d: 0 }; t.rtExpiry = Date.now() + 30 * 86400000; }
          else if (!f.relogin && !list.some(function (x) { return (x.email || x.name) === f.added; })) {
            list.push({ name: f.added, email: f.added, kind: '', sub: '', active: false,
              usage: { use5h: 0, use7d: 0 }, rtExpiry: Date.now() + 30 * 86400000, holders: [] });
          }
          f.step = 'done'; refreshAcctIcon();
        } else { f.step = 'fail'; f.why = (r && r.error) || '코드를 확인할 수 없습니다'; }
        paint();
      }).catch(function () { if (alive()) { f.step = 'fail'; f.why = '확인 요청이 닿지 않았습니다'; paint(); } });
    };
    box.appendChild(mkBtnRow(
      mkBtn('승인 페이지 다시 열기', '', function () { flash('새 승인 링크는 위 링크를 다시 여세요', 2500); }),
      mkBtn('코드 확인하고 추가', 'p', submitCode), cancel));
  } else if (f.step === 'check') {
    box.appendChild(mk('div', 'step', '③ 확인 중'));
    box.appendChild(mk('div', 'prog', '⟳ 코드 확인 중 · 풀은 아직 그대로'));
    box.appendChild(mkBtnRow(cancel));
  } else if (f.step === 'done') {
    box.appendChild(mk('div', 'step', '④ 완료'));
    const c = mk('div', 'flow-done', '✓ ' + f.added + (f.relogin ? ' 로그인을 되살렸습니다' : ' 을 풀에 추가했습니다') + ' · 현재 계정은 바꾸지 않았습니다');
    box.appendChild(c);
    box.appendChild(mkBtnRow(
      mkBtn('이 계정으로 전환', 'p', function () {
        const t = ((st.claude && st.claude.accounts) || []).find(function (x) { return (x.email || x.name) === f.added; });
        if (t && !t.active) st.flow = { sec: 'claude', kind: 'switch', step: 'confirm', target: t.name };
        else st.flow = null;
        paint();
      }),
      mkBtn('완료', '', function () { st.flow = null; paint(); })));
  } else {
    box.appendChild(mk('div', 'step', '④′ 실패'));
    const c = mk('div', 'flow-fail');
    c.appendChild(mk('div', '', '코드를 확인할 수 없습니다'));
    c.appendChild(mk('div', 'mu', (f.why || '') + ' · 코드는 일회용이라 짧게 유지됩니다. 새 승인 링크에서 다시 받으세요.'));
    box.appendChild(c);
    box.appendChild(mkBtnRow(
      mkBtn('승인 페이지 다시 열기', 'p', function () { f.step = 'approve'; f.codeText = ''; paint(); }),
      cancel));
  }
  body.appendChild(box);
}

function renderCodexBody(st, box, paint, alive) {
  box.textContent = '';
  const cx = st.codex;
  const f = st.flow;
  if (f && f.sec === 'codex') { renderCodexFlow(st, box, paint, alive); return; }
  if (!cx) { box.appendChild(mk('div', 'dots', '확인 중…')); return; }
  const ok = cx.state === 'ok';
  const row = mk('div', 'codex-row');
  const nm = mk('span', 'nm', ok ? (cx.email || '(로그인됨)')
    : cx.state === 'none' ? '로그인 필요'
    : cx.state === 'pending' ? '로그인 진행 중' : (cx.reason || cx.state));
  if (!ok) nm.style.color = '#e6b34d';
  const pl = mk('span', 'pl', ok ? ((cx.plan ? cx.plan + ' · ' : '') + 'ChatGPT')
    : cx.state === 'none' ? ' 로그인이 필요합니다' : '');
  row.appendChild(nm); row.appendChild(pl); box.appendChild(row);
  if (ok) box.appendChild(codexUsageRow(st.codexUsage));
  const busy = _codexOperationPending;
  const relog = mkBtn(ok ? '다시 로그인' : '로그인', '', function () {
    startFlow(st, paint, 'codex', 'relogin', {});
  });
  if (busy) relog.disabled = true;
  const btns = mkBtnRow(relog);
  if (ok) {
    const lo = mkBtn('로그아웃', 'danger', function () {
      if (!window.confirm('Codex 로그아웃 — 이 박스의 로그인을 지웁니다. 계속할까요?')) return;
      lo.disabled = true; lo.textContent = '…';
      postJson(API + 'codex-logout', {}).then(function (r) {
        if (!alive()) return;
        _codexOperationPending = false;
        if (r && r.ok) {
          setCodexIdentity({ state: 'none' });
          st.codex = { state: 'none' }; st.codexUsage = null;
          flash('Codex 로그아웃했습니다', 2000); paint();
        } else { lo.disabled = false; lo.textContent = '로그아웃'; flash('로그아웃하지 못했습니다' + (r && r.error ? ': ' + r.error : ''), 3000); }
      }).catch(function () {
        if (!alive()) return;
        _codexOperationPending = false;
        lo.disabled = false; lo.textContent = '로그아웃'; flash('로그아웃 요청이 닿지 않았습니다', 2000);
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
    nm.textContent = '로그인이 해제됨 — 다시 로그인';
    nm.style.color = C_RED;
    pl.textContent = '다른 곳에서 로그아웃했거나 다른 계정으로 로그인했습니다';
    row.appendChild(nm); row.appendChild(pl);
    return row;
  }
  if (u7 == null) {
    nm.textContent = '주간 사용량';
    nm.style.color = C_GRAY;
    pl.textContent = usage && usage.codexErr ? String(usage.codexErr) : '확인 중…';
  } else {
    nm.textContent = '주간 ' + u7 + '%' + (usage.codexStale ? ' (마지막 값)' : '');
    nm.style.color = levelColor(usageLevel('7d', u7));
    const bits = [];
    if (usage.codexReset7d) bits.push(fmtReset(usage.codexReset7d, true) + ' 초기화');
    if (usage.codexCredits != null) bits.push('크레딧 ' + usage.codexCredits);
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
    cbox.appendChild(mk('div', 'step', '① 준비'));
    cbox.appendChild(mk('div', '', '지금: ' + (cx.state === 'ok'
      ? '로그인됨 ' + (cx.email || '') + ' · 주간 ' + ((st.codexUsage && st.codexUsage.codexUse7d) != null ? st.codexUsage.codexUse7d + '%' : '확인 중')
      : '로그인 없음')));
    cbox.appendChild(mk('div', '', '시작하면 Codex를 잠시 쓸 수 없습니다. 기존 로그인은 임시 보관되고, 취소하거나 15분이 지나면 자동 복구됩니다.'));
    cbox.appendChild(mk('div', 'mu', '이 박스에서 Codex로 돌아가는 세션이 있으면 다음 요청에서 멈출 수 있습니다.'));
    cbox.appendChild(mkBtnRow(
      mkBtn('재로그인 시작', 'p', function () {
        f.backup = cx.state === 'ok' ? Object.assign({}, cx) : null;
        _codexOperationPending = true;
        postJson(API + 'codex-login-start', {}).then(function (r) {
          if (!alive()) return;
          if (r && r.ok && r.code) {
            st.codex = { state: 'pending' };
            f.step = 'approve'; f.code = r.code; f.url = r.url; paint();
          } else {
            _codexOperationPending = false;
            flash('Codex 로그인을 시작하지 못했습니다' + (r && r.error ? ': ' + r.error : ''), 4500);
          }
        }).catch(function () {
          if (!alive()) return;
          _codexOperationPending = false;
          flash('Codex 로그인 요청이 닿지 않았습니다', 2000);
        });
      }),
      mkBtn('취소', '', function () { st.flow = null; paint(); })));
  } else if (f.step === 'approve') {
    cbox.appendChild(mk('div', 'step', '② 브라우저 승인'));
    cbox.appendChild(mk('div', '', '① 새 탭 열기 → OpenAI 승인 페이지'));
    cbox.appendChild(mk('div', '', '② 아래 코드를 그 페이지에 입력'));
    if (f.url) {
      const a = mk('a', 'acct-link', '🔗 ' + f.url);
      a.href = f.url; a.target = '_blank'; a.rel = 'noopener noreferrer';
      cbox.appendChild(a);
    }
    const codeEl = mk('code', 'cg-cmd', f.code || '');
    codeEl.title = '누르면 복사';
    codeEl.onclick = function () {
      if (navigator.clipboard && f.code) { navigator.clipboard.writeText(f.code); flash('복사했습니다', 1200); }
    };
    cbox.appendChild(codeEl);
    cbox.appendChild(mk('div', 'mu', '이 코드는 Airlock이 만든 코드입니다 → 브라우저에 입력'));
    cbox.appendChild(mk('div', 'warnln', '⏱ 15분 안에 승인 · 기존 로그인 보관됨'));
    const chk = mkBtn('승인 확인', 'p', function () {
      chk.disabled = true; chk.textContent = '확인 중…';
      fetch(API + 'claude-status').then(function (x) { return x.json(); }).then(function (s) {
        if (!alive()) return;
        const ncx = (s && s.codex) || {};
        if (ncx.state === 'ok') {
          _codexOperationPending = false;
          flash('✓ Codex 로그인했습니다: ' + (ncx.email || ''), 3000);
          const identity = setCodexIdentity(ncx);
          st.codex = ncx; st.codexUsage = _codexUsage;
          f.step = 'done'; paint();
          fetchCodexUsage(st, paint, alive, { scheduled: false });
        } else {
          chk.disabled = false; chk.textContent = '승인 확인';
          flash('아직 승인되지 않았습니다 — 코드를 입력·승인하고 다시 확인하세요', 4000);
        }
      }).catch(function () { if (alive()) { chk.disabled = false; chk.textContent = '승인 확인'; } });
    });
    cbox.appendChild(mkBtnRow(chk,
      mkBtn('취소하고 기존 로그인 복구', 'danger', function () {
        postJson(API + 'codex-login-cancel', {}).then(function (rr) {
          if (!alive()) return;
          _codexOperationPending = false;
          if (rr && rr.ok) {
            if (f.backup) { st.codex = Object.assign({}, f.backup); st.codex.state = 'ok'; setCodexIdentity(st.codex); }
            else st.codex = { state: 'none' };
            st.codexUsage = null;
            flash(rr.restored ? '취소했습니다 — 기존 로그인을 복구했습니다' : '취소했습니다', 2500);
            st.flow = null; paint();
          } else flash('취소하지 못했습니다' + (rr && rr.error ? ': ' + rr.error : ''), 3000);
        }).catch(function () {});
      })));
  } else if (f.step === 'check') {
    cbox.appendChild(mk('div', 'step', '③ 확인 중'));
    cbox.appendChild(mk('div', 'prog', '⟳ 새 로그인 확인 중…'));
  } else {
    cbox.appendChild(mk('div', 'step', '④ 완료'));
    cbox.appendChild(mk('div', 'flow-done', '✓ ' + ((st.codex && st.codex.email) || '') + ' 으로 다시 로그인했습니다 · 사용량은 새 계정 것으로 다시 읽습니다'));
    cbox.appendChild(mkBtnRow(mkBtn('완료', 'p', function () { st.flow = null; paint(); })));
  }
  box.appendChild(cbox);
}

// xAI section removed (POPUP_SHELL rework, 사람 결정 9dac31a6 팝업에서 제거):
// the backend xai-* routes stay, but this shell no longer lists, fetches or
// flows them. The section below used to live here; deleting it outright keeps
// a removed section from ever reading as a passing one.
function startFlow(st, paint, sec, kind, extra) {
  if (st.flow) { flash('진행 중인 작업을 먼저 끝내거나 취소하세요', 2500); return; }
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
      if (!fresh || !fresh.usage || fresh.usage.err
          || (fresh.usage.use5h == null && fresh.usage.use7d == null)) return;
      ((st.claude && st.claude.accounts) || []).forEach(function (a) {
        if (a.email === fresh.email && a.kind === fresh.kind) a.usage = fresh.usage;
      });
      paint();
    }).catch(function () {});
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
    st.codex = { state: 'unknown', reason: '조회 실패' }; paint();
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
  const needs = mk('div', 'needs', '조치 필요 확인 중…');
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
      needs.appendChild(mk('span', '', '조치 필요 확인 중…'));
    } else if (!iss.length) {
      needs.appendChild(mk('span', '', '조치 필요 없음'));
    } else {
      needs.appendChild(mk('span', '', '조치 필요 ' + iss.length + '건 · '));
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
        if (!st.agy && !st.agyFailed) S.body.appendChild(mk('div', 'dots', '확인 중…'));
        else if (st.agyFailed) S.body.appendChild(mk('div', 'dots', '사용량을 읽지 못했습니다'));
        else if (st.agy && st.agy.enabled === false) S.body.appendChild(mk('div', 'dots', '이 박스에 없음'));
        else renderAgyBody(S.body, st.agy || {}, function () {
          st.agy = null; st.agyFailed = false; paint();
          fetchAgy(st, paint, alive);
        });
      }
      else if (key === 'muse') {
        S.body.textContent = '';
        if (!st.muse && !st.museFailed) S.body.appendChild(mk('div', 'dots', '확인 중…'));
        else if (st.museFailed) S.body.appendChild(mk('div', 'dots', 'Muse 키를 읽지 못했습니다'));
        else if (st.muse && st.muse.enabled === false) S.body.appendChild(mk('div', 'dots', '이 박스에 없음'));
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
  list.appendChild(mk('div', 'dots', '계정·사용량 확인 중…')); pop.appendChild(list);
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
