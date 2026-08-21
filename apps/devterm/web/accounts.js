'use strict';
/*
 * devterm account pool — split out of app.js. Optional feature (the account icon is
 *   only shown when the accounts feature is enabled). Switch / usage / pool-login UI.
 *   Coupling to the terminal core is only the injected functions below (no core vars).
 * DI factory: window.initAccounts(deps) is the only global. deps =
 *   { flash, postJson, mkFocus, closeTabPops, placePop }; returns 4 API functions.
 * Load order: before app.js in index.html; app.js calls this factory while running.
 */
window.initAccounts = function initAccounts(deps) {
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
  if (d <= 0) return '⚠ Expired · re-login';
  if (d < 1) return '⚠ Expires today · re-login';
  return '⚠ Expires in ' + Math.floor(d) + ' days · re-login';
}
function acctTipText(u, a) {
  const L = [];
  if (u.use5h == null && u.use7d == null) {
    L.push(u.err === 'no data' ? 'Collecting usage\n(every minute)' : 'Query failed\n' + (u.err || '?'));
  } else {
    L.push('5h↻ ' + (u.reset5h ? fmtReset(u.reset5h, false) : '—') +
           '\n7d↺ ' + (u.reset7d ? fmtReset(u.reset7d, true) : '—') +
           (u.stale ? '\n(last value)' : ''));
  }
  // who holds it = the shared store's holders. Using the same account in two places burns 5h twice as fast.
  const h = (a && a.holders) || [];
  if (h.length) L.push('In use by\n' + h.map(function (x) { return '· ' + x.who; }).join('\n'));
  const d = rtLeft(a);
  if (d != null) {
    L.push(d <= rtWarnDays()
      ? rtWarnText(d) + '\n(expiry is fixed ~30 days after login —\n it does not extend with use)'
      : 'Login expires in ' + Math.floor(d) + ' days');
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
  fetch('/acct-alert', { cache: 'no-store' }).then(function (x) { return x.json(); }).then(function (j) {
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

// Load the pool from the backend (/accounts) into a popup (left = account, right = 5h/7d usage).
// Selecting one runs `claude-switch swap <name>` server-side. No secrets (plan, health, usage% only).
// Add account = completed inside the popup: the backend runs login-url/login-code; the human just
// approves the link and pastes the returned code.
function startAddAcct(list, addBtn, reflow) {
  postJson('/acct-login-url', {}).then(function (res) {
    if (!res || !res.ok || !res.url) {
      addBtn.disabled = false; addBtn.textContent = '+ Add account (login)';
      flash('Failed to issue login link' + (res && res.error ? ': ' + res.error : ''), 3000); return;
    }
    addBtn.remove();
    const hd = document.createElement('div'); hd.className = 'hd';
    hd.textContent = '(1) Approve the link -> (2) paste the code';
    const a = document.createElement('a'); a.className = 'acct-link';
    a.href = res.url; a.target = '_blank'; a.rel = 'noopener noreferrer';
    a.textContent = '🔗 Open in browser to log in / approve';
    const form = document.createElement('div'); form.className = 'addform';
    const inp = document.createElement('input');
    inp.type = 'text'; inp.placeholder = 'Code from the approval'; inp.autocomplete = 'off'; inp.spellcheck = false;
    const go = document.createElement('button'); go.textContent = 'Register';
    const submit = function () {
      const code = inp.value.trim();
      if (!code) { inp.focus(); return; }
      go.disabled = true; inp.disabled = true; go.textContent = 'Registering…';
      postJson('/acct-login-code', { code: code }).then(function (r) {
        if (r && r.ok) { closeTabPops(); flash('✓ ' + (r.msg || 'Account registered'), 4000); refreshAcctIcon(); mkFocus(); }
        else {
          go.disabled = false; inp.disabled = false; go.textContent = 'Register'; inp.value = '';
          // the code is one-time and short-lived -> on failure, start from the link again. Surface the reason.
          flash('Registration failed' + (r && r.error ? ': ' + r.error : '') + ' — press the link again for a new code', 6000);
        }
      }).catch(function () {
        go.disabled = false; inp.disabled = false; go.textContent = 'Register';
        flash('Registration request failed', 2500);
      });
    };
    go.onclick = submit;
    inp.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); submit(); } });
    form.appendChild(inp); form.appendChild(go);
    list.appendChild(hd); list.appendChild(a); list.appendChild(form);
    if (reflow) reflow();          // the link/form change the height -> re-place
    inp.focus();
  }).catch(function () {
    addBtn.disabled = false; addBtn.textContent = '+ Add account (login)';
    flash('Login link request failed', 2500);
  });
}
// ---- Codex (ChatGPT) — this box's single account. No pool/swap (Codex design) -> status + re-login + logout ----
// Codex usage is read from /codex-usage, which spawns an app-server behind a cache, so
// it is asked for separately from the identity (/claude-status) and only while the
// section is open. The identity string guards against showing a previous account's
// numbers: a reply that arrives after a logout/login is dropped.
let _codexIdentity = null, _codexUsage = null, _codexViewGeneration = 0,
    _codexOperationPending = false, _xaiOperationPending = false,
    _xaiViewGeneration = 0;
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
function fetchCodexUsage(box, cx, identity, reflow, alive, reaskState, revalidate) {
  alive = alive || function () { return true; };
  reaskState = reaskState || { scheduled: false };
  if (!alive() || _codexIdentity !== identity) return;
  const fetchOpts = { cache: 'no-store' };
  if (revalidate) fetchOpts.headers = { 'X-Airlock-Revalidate': 'wait' };
  fetch('/codex-usage', fetchOpts).then(function (x) { return x.json(); }).then(function (u) {
    if (!alive() || _codexIdentity !== identity) return;   // login state changed or section closed -> drop
    const hasValue = u && u.use7d != null;
    if (hasValue && (cx.state !== 'ok' || !cx.accountId || !u.accountId || cx.accountId !== u.accountId)) {
      // numbers we cannot tie to the account we are showing are not displayed at all
      _codexUsage = null;
      renderCodexBody(box, cx, { codexErr: 'account mismatch' });
    } else {
      _codexUsage = codexUsageView(u);
      renderCodexBody(box, cx, _codexUsage);
    }
    if (reflow) reflow();
    if (hasValue && u.stale && !reaskState.scheduled) {
      reaskState.scheduled = true;
      setTimeout(function () {
        if (!alive() || _codexIdentity !== identity) return;
        fetchCodexUsage(box, cx, identity, reflow, alive, reaskState, true);
      }, CODEX_STALE_REASK_MS);
    }
  }).catch(function () {
    if (!alive() || _codexIdentity !== identity) return;
    renderCodexBody(box, cx, { codexErr: 'query failed' });
    if (reflow) reflow();
  });
}

function renderCodexSection(list, reflow, parentAlive) {
  _codexOperationPending = false;        // a newly opened/redrawn section owns new work
  const sep = document.createElement('div'); sep.className = 'sep'; list.appendChild(sep);
  const hd = document.createElement('div'); hd.className = 'hd'; hd.textContent = 'Codex (ChatGPT) · this box';
  list.appendChild(hd);
  const box = document.createElement('div'); box.className = 'codex-box'; box.textContent = 'Loading…';
  list.appendChild(box);
  const generation = ++_codexViewGeneration;
  const alive = function () {
    return generation === _codexViewGeneration
      && (!parentAlive || parentAlive()) && document.body.contains(box);
  };
  const reaskState = { scheduled: false };
  fetch('/claude-status').then(function (x) { return x.json(); }).then(function (s) {
    if (!alive()) return;
    const cx = (s && s.codex) || { state: 'unknown' };
    const identity = setCodexIdentity(cx);
    renderCodexBody(box, cx, _codexUsage);       // cached numbers first (stay snappy)
    if (reflow) reflow();          // the Codex section changes the height -> re-place
    if (cx.state === 'ok') fetchCodexUsage(box, cx, identity, reflow, alive, reaskState);
  }).catch(function () {
    if (!alive()) return;
    box.textContent = 'Codex status query failed'; if (reflow) reflow();
  });
}
function renderCodexBody(box, cx, usage) {
  box.textContent = '';
  const ok = cx.state === 'ok';
  const row = document.createElement('div'); row.className = 'codex-row';
  const nm = document.createElement('span'); nm.className = 'nm';
  nm.textContent = ok ? (cx.email || '(logged in)')
                      : (cx.state === 'none' ? 'Not logged in' : (cx.reason || cx.state));
  if (!ok) nm.style.color = '#e6b34d';
  const pl = document.createElement('span'); pl.className = 'pl';
  pl.textContent = ok ? ((cx.plan ? cx.plan + ' · ' : '') + 'ChatGPT') : (cx.state === 'none' ? 'codex login required' : '');
  row.appendChild(nm); row.appendChild(pl); box.appendChild(row);
  if (ok) box.appendChild(codexUsageRow(usage));
  const btns = document.createElement('div'); btns.className = 'codex-btns';
  const relog = document.createElement('button'); relog.className = 'codex-btn';
  relog.textContent = ok ? 'Re-login' : 'Log in';
  relog.addEventListener('pointerdown', function (e) { e.preventDefault(); });
  relog.onclick = function () {
    _codexOperationPending = true;
    const generation = ++_codexViewGeneration;
    startCodexLogin(box, relog, function () {
      return generation === _codexViewGeneration && document.body.contains(box);
    });
  };
  btns.appendChild(relog);
  if (ok) {
    const lo = document.createElement('button'); lo.className = 'codex-btn danger'; lo.textContent = 'Log out';
    lo.addEventListener('pointerdown', function (e) { e.preventDefault(); });
    lo.onclick = function () {
      if (!window.confirm('Codex logout — auth.json will be removed.\nThe re-login button reconnects. Continue?')) return;
      _codexOperationPending = true;
      const generation = ++_codexViewGeneration;
      const alive = function () {
        return generation === _codexViewGeneration && document.body.contains(box);
      };
      lo.disabled = true; lo.textContent = '…';
      postJson('/codex-logout', {}).then(function (r) {
        if (!alive()) return;
        _codexOperationPending = false;
        if (r && r.ok) {
          setCodexIdentity({ state: 'none' });
          flash('Codex logged out', 2000); renderCodexBody(box, { state: 'none' });
        }
        else { lo.disabled = false; lo.textContent = 'Log out'; flash('Logout failed' + (r && r.error ? ': ' + r.error : ''), 3000); }
      }).catch(function () {
        if (!alive()) return;
        _codexOperationPending = false;
        lo.disabled = false; lo.textContent = 'Log out'; flash('Logout request failed', 2000);
      });
    };
    btns.appendChild(lo);
  }
  box.appendChild(btns);
}
// The 7d weekly window is the one Codex actually limits on; there is no 5h window to
// show. Graded against the same server thresholds as the Claude rows, so "amber" means
// the same thing in both sections.
function codexUsageRow(usage) {
  const row = document.createElement('div'); row.className = 'codex-row';
  const nm = document.createElement('span'); nm.className = 'nm';
  const pl = document.createElement('span'); pl.className = 'pl';
  const u7 = usage && usage.codexUse7d;
  // auth.json is still here (so the row above shows an email and a plan) but the token
  // behind it was revoked — the account line must say so, or the first symptom is an
  // agent dying with "please sign in again". Numbers, if any, are from before the death.
  if (usage && usage.codexErr === 'auth') {
    nm.textContent = 'sign-in revoked — Re-login';
    nm.style.color = C_RED;
    pl.textContent = 'logged out elsewhere, or signed in to another account';
    row.appendChild(nm); row.appendChild(pl);
    return row;
  }
  if (u7 == null) {
    nm.textContent = '7d usage';
    nm.style.color = C_GRAY;
    pl.textContent = usage && usage.codexErr ? String(usage.codexErr) : 'reading…';
  } else {
    nm.textContent = '7d ' + u7 + '%' + (usage.codexStale ? ' (last value)' : '');
    nm.style.color = levelColor(usageLevel('7d', u7));
    const bits = [];
    if (usage.codexReset7d) bits.push('resets ' + fmtReset(usage.codexReset7d, true));
    if (usage.codexCredits != null) bits.push(usage.codexCredits + ' credits');
    pl.textContent = bits.join(' · ');
  }
  row.appendChild(nm); row.appendChild(pl);
  return row;
}

// codex login --device-auth = headless device auth: no port-forward/callback. Open the link, enter the code.
// Starting re-login wipes auth.json immediately (backend backs it up) -> [Cancel] restores it if not completed.
function startCodexLogin(box, btn, alive) {
  alive = alive || function () { return document.body.contains(box); };
  btn.disabled = true; btn.textContent = 'codex login…';
  postJson('/codex-login-start', {}).then(function (r) {
    if (!alive()) return;
    if (!r || !r.ok || !r.code) { btn.disabled = false; btn.textContent = 'Re-login';
      _codexOperationPending = false;
      flash('codex login failed to start' + (r && r.error ? ': ' + r.error : ''), 4500); return; }
    box.textContent = '';
    const g = document.createElement('div'); g.className = 'codex-guide';
    const warn = document.createElement('div'); warn.className = 'cg-step'; warn.style.color = '#e6b34d';
    warn.textContent = '⚠ Current login is cleared — finish, or press [Cancel] to restore.';
    const s1 = document.createElement('div'); s1.className = 'cg-step'; s1.textContent = '(1) Open in a browser:';
    const a = document.createElement('a'); a.className = 'acct-link'; a.href = r.url; a.target = '_blank'; a.rel = 'noopener noreferrer';
    a.textContent = '🔗 ' + r.url;
    const s2 = document.createElement('div'); s2.className = 'cg-step'; s2.textContent = '(2) Enter this code (within 15 min · click to copy):';
    const codeEl = document.createElement('code'); codeEl.className = 'cg-cmd'; codeEl.textContent = r.code; codeEl.title = 'click to copy';
    codeEl.onclick = function () { if (navigator.clipboard) { navigator.clipboard.writeText(r.code); flash('Copied', 1200); } };
    const s3 = document.createElement('div'); s3.className = 'cg-step'; s3.textContent = '(3) After logging in / approving:';
    const brow = document.createElement('div'); brow.className = 'codex-btns';
    const chk = document.createElement('button'); chk.className = 'codex-btn'; chk.textContent = 'Check';
    chk.addEventListener('pointerdown', function (e) { e.preventDefault(); });
    chk.onclick = function () {
      chk.disabled = true; chk.textContent = 'Checking…';
      fetch('/claude-status').then(function (x) { return x.json(); }).then(function (st) {
        if (!alive()) return;
        const cx = (st && st.codex) || {};
        if (cx.state === 'ok') {
          _codexOperationPending = false;
          flash('✓ Codex login complete: ' + (cx.email || ''), 3000);
          // new identity -> drop any cached numbers and read this account's own
          const identity = setCodexIdentity(cx);
          renderCodexBody(box, cx, _codexUsage);
          fetchCodexUsage(box, cx, identity, null, alive, { scheduled: false });
        }
        else { chk.disabled = false; chk.textContent = 'Check'; flash('Not logged in yet — enter the code / approve, then check again', 4000); }
      }).catch(function () { if (alive()) { chk.disabled = false; chk.textContent = 'Check'; } });
    };
    const cancel = document.createElement('button'); cancel.className = 'codex-btn danger'; cancel.textContent = 'Cancel (restore)';
    cancel.addEventListener('pointerdown', function (e) { e.preventDefault(); });
    cancel.onclick = function () {
      cancel.disabled = true; cancel.textContent = '…';
      postJson('/codex-login-cancel', {}).then(function (rr) {
        if (!alive()) return;
        if (rr && rr.ok) {
          _codexOperationPending = false;
          flash(rr.restored ? 'Cancelled — previous login restored' : 'Cancelled', 2500);
          fetch('/claude-status').then(function (x) { return x.json(); })
            .then(function (st) {
              if (!alive()) return;
              const rcx = (st && st.codex) || { state: 'unknown' };
              const identity = setCodexIdentity(rcx);
              renderCodexBody(box, rcx, _codexUsage);
              if (rcx.state === 'ok') fetchCodexUsage(box, rcx, identity, null, alive, { scheduled: false });
            }).catch(function () {});
        } else { cancel.disabled = false; cancel.textContent = 'Cancel (restore)'; flash('Cancel failed' + (rr && rr.error ? ': ' + rr.error : ''), 3000); }
      }).catch(function () { if (alive()) { cancel.disabled = false; cancel.textContent = 'Cancel (restore)'; } });
    };
    brow.appendChild(chk); brow.appendChild(cancel);
    g.appendChild(warn); g.appendChild(s1); g.appendChild(a); g.appendChild(s2); g.appendChild(codeEl); g.appendChild(s3); g.appendChild(brow);
    box.appendChild(g);
  }).catch(function () {
    if (!alive()) return;
    _codexOperationPending = false;
    btn.disabled = false; btn.textContent = 'Re-login'; flash('codex login request failed', 2000);
  });
}

// ---- OpenCode xAI — a separate credential from Orca's ~/.grok/auth.json ----
function renderXaiSection(list, reflow, parentAlive) {
  _xaiOperationPending = false;
  const sep = document.createElement('div'); sep.className = 'sep'; list.appendChild(sep);
  const hd = document.createElement('div'); hd.className = 'hd'; hd.textContent = 'OpenCode xAI · this box';
  list.appendChild(hd);
  const box = document.createElement('div'); box.className = 'xai-box codex-box'; box.textContent = 'Loading…';
  list.appendChild(box);
  const generation = ++_xaiViewGeneration;
  const alive = function () {
    return generation === _xaiViewGeneration
      && (!parentAlive || parentAlive()) && document.body.contains(box);
  };
  fetch('/xai-status', { cache: 'no-store' }).then(function (x) { return x.json(); }).then(function (xai) {
    if (!alive()) return;
    if (xai && xai.enabled === false) {
      sep.remove(); hd.remove(); box.remove(); if (reflow) reflow(); return;
    }
    renderXaiBody(box, xai || { state: 'err', reason: 'query failed' }, alive);
    if (reflow) reflow();
  }).catch(function () {
    if (!alive()) return;
    renderXaiBody(box, { state: 'err', reason: 'query failed' }, alive);
    if (reflow) reflow();
  });
}

function renderXaiBody(box, xai, alive) {
  box.textContent = '';
  const state = xai && xai.state ? xai.state : 'err';
  const signed = state === 'ok' || state === 'expired';
  const row = document.createElement('div'); row.className = 'codex-row';
  const nm = document.createElement('span'); nm.className = 'nm';
  const pl = document.createElement('span'); pl.className = 'pl';
  if (state === 'ok') {
    nm.textContent = 'Signed in';
    const expiry = new Date(xai.expires);
    pl.textContent = xai.expires != null && !isNaN(expiry.getTime())
      ? 'access token expires ' + fmtReset(expiry.toISOString(), true)
      : 'OpenCode xAI';
  } else if (state === 'expired') {
    nm.textContent = 'Access token refresh needed'; nm.style.color = C_AMBER;
    pl.textContent = 'Signed in · OpenCode refreshes on use';
  } else if (state === 'none') {
    nm.textContent = 'Not signed in'; nm.style.color = C_AMBER;
    pl.textContent = 'OpenCode xAI login required';
  } else if (state === 'malformed') {
    nm.textContent = 'Credential unreadable'; nm.style.color = C_AMBER;
    pl.textContent = xai.reason || 'unexpected credential shape';
  } else {
    nm.textContent = 'Credential status error'; nm.style.color = C_AMBER;
    pl.textContent = xai.reason || 'query failed';
  }
  row.appendChild(nm); row.appendChild(pl); box.appendChild(row);

  const btns = document.createElement('div'); btns.className = 'codex-btns';
  if (state !== 'err') {
    const login = document.createElement('button'); login.className = 'codex-btn';
    login.textContent = state === 'none' ? 'Log in' : 'Re-login';
    login.addEventListener('pointerdown', function (e) { e.preventDefault(); });
    login.onclick = function () {
      _xaiOperationPending = true;
      const generation = ++_xaiViewGeneration;
      startXaiLogin(box, login, function () {
        return generation === _xaiViewGeneration && document.body.contains(box);
      });
    };
    btns.appendChild(login);
  }
  if (signed) {
    const logout = document.createElement('button'); logout.className = 'codex-btn danger';
    logout.textContent = 'Log out';
    logout.addEventListener('pointerdown', function (e) { e.preventDefault(); });
    logout.onclick = function () {
      if (!window.confirm('Log OpenCode out of xAI on this box?')) return;
      _xaiOperationPending = true;
      const generation = ++_xaiViewGeneration;
      const operationAlive = function () {
        return generation === _xaiViewGeneration && document.body.contains(box);
      };
      logout.disabled = true; logout.textContent = '…';
      postJson('/xai-logout', {}).then(function (res) {
        if (!operationAlive()) return;
        _xaiOperationPending = false;
        if (res && res.ok) {
          flash('OpenCode xAI logged out', 2000);
          renderXaiBody(box, { state: 'none' }, operationAlive);
        } else {
          logout.disabled = false; logout.textContent = 'Log out';
          flash('xAI logout failed' + (res && res.error ? ': ' + res.error : ''), 3000);
        }
      }).catch(function () {
        if (!operationAlive()) return;
        _xaiOperationPending = false;
        logout.disabled = false; logout.textContent = 'Log out';
        flash('xAI logout request failed', 2000);
      });
    };
    btns.appendChild(logout);
  }
  box.appendChild(btns);
}

function startXaiLogin(box, btn, alive) {
  const idleLabel = btn.textContent;
  btn.disabled = true; btn.textContent = 'OpenCode login…';
  postJson('/xai-login-start', {}).then(function (res) {
    if (!alive()) return;
    if (!res || !res.ok || !res.url || !res.code) {
      _xaiOperationPending = false;
      btn.disabled = false; btn.textContent = idleLabel;
      flash('OpenCode xAI login failed to start' +
            (res && res.error ? ': ' + res.error : ''), 4500);
      return;
    }
    box.textContent = '';
    const guide = document.createElement('div'); guide.className = 'codex-guide';
    const note = document.createElement('div'); note.className = 'cg-step';
    note.textContent = 'Existing OpenCode xAI credential stays active until login completes.';
    const s1 = document.createElement('div'); s1.className = 'cg-step'; s1.textContent = '(1) Open in a browser:';
    const a = document.createElement('a'); a.className = 'acct-link'; a.href = res.url;
    a.target = '_blank'; a.rel = 'noopener noreferrer'; a.textContent = '🔗 ' + res.url;
    const s2 = document.createElement('div'); s2.className = 'cg-step'; s2.textContent = '(2) Enter this code:';
    const code = document.createElement('code'); code.className = 'cg-cmd'; code.textContent = res.code;
    code.onclick = function () {
      if (navigator.clipboard) navigator.clipboard.writeText(res.code);
    };
    const buttons = document.createElement('div'); buttons.className = 'codex-btns';
    const check = document.createElement('button'); check.className = 'codex-btn'; check.textContent = 'Check';
    check.onclick = function () {
      check.disabled = true; check.textContent = 'Checking…';
      fetch('/xai-status', { cache: 'no-store' }).then(function (x) { return x.json(); }).then(function (status) {
        if (!alive()) return;
        if (status && status.loginState === 'succeeded'
            && (status.state === 'ok' || status.state === 'expired')) {
          _xaiOperationPending = false;
          flash('✓ OpenCode xAI login complete', 2500);
          renderXaiBody(box, status, alive);
        } else if (status && status.loginState === 'failed') {
          check.disabled = false; check.textContent = 'Check';
          flash('OpenCode xAI login failed — start Re-login again', 3500);
        } else {
          check.disabled = false; check.textContent = 'Check';
          flash('Not signed in yet — enter the code, approve, then check again', 3500);
        }
      }).catch(function () { if (alive()) { check.disabled = false; check.textContent = 'Check'; } });
    };
    const cancel = document.createElement('button'); cancel.className = 'codex-btn danger'; cancel.textContent = 'Cancel';
    cancel.onclick = function () {
      cancel.disabled = true; cancel.textContent = '…';
      postJson('/xai-login-cancel', {}).then(function (r) {
        if (!alive()) return;
        if (r && r.ok) {
          _xaiOperationPending = false;
          fetch('/xai-status', { cache: 'no-store' }).then(function (x) { return x.json(); })
            .then(function (status) { if (alive()) renderXaiBody(box, status, alive); });
        } else {
          cancel.disabled = false; cancel.textContent = 'Cancel';
          flash('xAI login cancel failed', 2500);
        }
      }).catch(function () { if (alive()) { cancel.disabled = false; cancel.textContent = 'Cancel'; } });
    };
    buttons.appendChild(check); buttons.appendChild(cancel);
    guide.appendChild(note); guide.appendChild(s1); guide.appendChild(a);
    guide.appendChild(s2); guide.appendChild(code); guide.appendChild(buttons);
    box.appendChild(guide);
  }).catch(function () {
    if (!alive()) return;
    _xaiOperationPending = false;
    btn.disabled = false; btn.textContent = idleLabel;
    flash('OpenCode xAI login request failed', 2000);
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
  const reflow = opts.reflow, reopen = opts.reopen;
  const alive = opts.alive || function () { return true; };
  const onSwitched = opts.onSwitched || function () {};
  const render = function (j) {
    list.textContent = '';
    if (j && j.enabled === false) {
      const d = document.createElement('div'); d.className = 'sep'; d.textContent = 'Account switching is disabled';
      list.appendChild(d); renderXaiSection(list, reflow, alive); reflow(); return;
    }
    const hd = document.createElement('div'); hd.className = 'hd';
    hd.textContent = 'Switch account · right = 5h / 7d usage';
    list.appendChild(hd);
    const accts = (j && j.accounts) || [];
    accts.forEach(function (a) {
      const dead = a.health && a.health.state === 'dead';
      const u = a.usage || {};
      const b = document.createElement('button'); b.className = 'acctrow' + (dead ? ' dead' : '');
      const L = document.createElement('div'); L.className = 'acct-l';
      // label = the real id (email) + kind (personal/team). Fall back to name if no email.
      const nm = document.createElement('span'); nm.className = 'nm';
      nm.textContent = (a.active ? '✓ ' : dead ? '❌ ' : '') + (a.email || a.name);
      const pl = document.createElement('span'); pl.className = 'pl';
      // a dead account shows its reason — without it the user can't act.
      pl.textContent = dead ? (a.health.reason || 'unavailable')
                            : (a.kind ? a.kind + ' · ' : '') + a.sub;
      // A persisted panel reading is display memory, not a fresh fleet observation.
      // Keep that qualifier inline on the prose side so touch and keyboard users see it.
      if (!dead && u.stale && (u.use5h != null || u.use7d != null)) {
        pl.textContent += ' · (last value)';
      }
      if (dead) b.title = a.health.reason || '';
      // still alive but expiring soon = re-login now to cross over without interruption.
      const rtd = dead ? null : rtLeft(a);
      if (rtd != null && rtd <= rtWarnDays()) {
        const w = document.createElement('span');
        w.style.color = rtd <= 2 ? C_RED : C_AMBER; w.style.fontWeight = '600';
        w.textContent = ' · ' + rtWarnText(rtd);
        pl.appendChild(w);
      }
      L.appendChild(nm); L.appendChild(pl);
      const R = document.createElement('div'); R.className = 'acct-r';
      if (dead) {
        R.style.color = C_AMBER;      // show the action, not usage (click = re-login flow)
        R.textContent = 'Re-login';
      } else if (u.use5h != null || u.use7d != null) {
        // exhaustion is judged only by utilization (429 is a query throttle, not an exhaustion signal).
        R.style.color = usageColor(u.use5h, u.use7d);
        R.textContent = '5h ' + (u.use5h == null ? '—' : u.use5h + '%') + '\n7d ' + (u.use7d == null ? '—' : u.use7d + '%');
      } else {
        R.style.color = '#8a92a6';
        R.textContent = u.err === 'no data' ? 'Collecting\n(<1 min)' : (u.err ? 'Query failed\n' + u.err : 'Usage\n—');
      }
      // hover = when it recovers + who holds it + expiry. Next to the cursor immediately.
      if (!dead) {
        b.addEventListener('mouseenter', function (e) { showAcctTip(e, u, a); });
        b.addEventListener('mousemove', placeAcctTip);
        b.addEventListener('mouseleave', hideAcctTip);
      }
      b.appendChild(L); b.appendChild(R);
      // remove (x) — non-active slots only (the CLI refuses active). Shown always (touch too).
      if (!a.active) {
        b.classList.add('removable');
        const x = document.createElement('span'); x.className = 'acct-x'; x.textContent = '✕';
        x.title = 'Remove this account from the pool';
        x.addEventListener('pointerdown', function (e) { e.preventDefault(); e.stopPropagation(); });
        x.addEventListener('click', function (e) {
          e.preventDefault(); e.stopPropagation();
          const label = a.email || a.name;
          if (!window.confirm('Remove account: ' + label + '\n\nDeleted from the pool.\nRe-login revives the same slot. Continue?')) return;
          hideAcctTip();
          postJson('/acct-remove', { name: a.name }).then(function (res) {
            if (res && res.ok) { flash('🗑 ' + label + ' removed', 2500); reopen(); refreshAcctIcon(); }
            else flash('Remove failed' + (res && res.error ? ': ' + res.error : ''), 3500);
          }).catch(function () { flash('Remove request failed', 2000); });
        });
        b.appendChild(x);
      }
      b.addEventListener('pointerdown', function (e) { e.preventDefault(); });
      b.onclick = function () {
        // dead account = switching would fail. Send to re-login instead — name = id, same slot revives.
        if (dead) { startAddAcct(list, b, reflow); return; }
        if (a.active) { onSwitched(); flash('Already using ' + a.name, 1400); return; }
        onSwitched();
        postJson('/acct-switch', { name: a.name }).then(function (res) {
          if (res && res.ok) { flash('✓ Switched to ' + (a.email || a.name) + ' (applies within ~1 min; restart the session for immediate effect)', 3000);
            refreshAcctIcon(); onSwitched(); }
          else flash('Switch failed' + (res && res.error ? ': ' + res.error : ''), 2800);
        }).catch(function () { flash('Switch request failed', 2000); });
      };
      list.appendChild(b);
    });
    const sep = document.createElement('div'); sep.className = 'sep'; list.appendChild(sep);
    const add = document.createElement('button'); add.className = 'addacct';
    add.textContent = '+ Add account (login)';
    add.addEventListener('pointerdown', function (e) { e.preventDefault(); });
    add.onclick = function () { add.disabled = true; add.textContent = 'Getting login link…'; startAddAcct(list, add, reflow); };
    list.appendChild(add);
    renderCodexSection(list, reflow, alive);   // Codex (ChatGPT) section under the Claude accounts
    renderXaiSection(list, reflow, alive);
    reflow();                           // re-place at the full rendered height (flip above from a bottom key bar)
  };
  fetch('/accounts').then(function (x) { return x.json(); }).then(function (j) {
    if (j && j.thresholds) setThresholds(j.thresholds);
    render(j);                       // draw with cached values first (stay snappy)
    if (j && j.enabled === false) return;
    // the value at the moment it opened — the timer polls active every minute, so it can be up to 1 min stale.
    postJson('/acct-usage-now', {}).then(function (fresh) {
      if (!alive()) return;                                  // already closed -> drop
      if (list.querySelector('.addform') || _codexOperationPending || _xaiOperationPending) return;
      // Both login flows temporarily own the section. Re-rendering the whole list here
      // can erase a captured device code (or a pending logout) after auth already moved.
      if (!fresh || !fresh.usage || fresh.usage.err) return;
      (j.accounts || []).forEach(function (a) {
        if (a.email === fresh.email && a.kind === fresh.kind) a.usage = fresh.usage;
      });
      render(j);
    }).catch(function () {});
  }).catch(function () {
    list.textContent = '';
    const d = document.createElement('div'); d.className = 'sep'; d.textContent = 'Failed to load list (check claude-switch)';
    list.appendChild(d);
  });
}

// devterm: the popup anchored to the account icon.
function openAcctMenu(anchor) {
  closeTabPops();
  const pop = document.createElement('div'); pop.className = 'tab-pop acct';
  const list = document.createElement('div');
  const loading = document.createElement('div'); loading.className = 'sep'; loading.textContent = 'Loading accounts / usage…';
  list.appendChild(loading); pop.appendChild(list);
  const r = anchor.getBoundingClientRect();
  placePop(pop, r.right - 320, r.bottom + 6);   // append to body first so we can measure
  const reflow = function () { placeAcctMenu(pop, anchor); };
  reflow();                                     // place from the loading state — flip above if near the bottom bar
  fillAcctList(list, {
    reflow: reflow,
    reopen: function () { openAcctMenu(anchor); },
    alive: function () { return document.body.contains(pop); },
    onSwitched: function () { closeTabPops(); mkFocus(); },
  });
}

// panel.html: the same list filling a container, with no popup framing. The panel does
// not close on a switch, so it redraws — otherwise the ✓ would stay on the old account.
function renderAcctPanel(container) {
  container.className = 'tab-pop acct acct-panel';
  container.textContent = '';
  const list = document.createElement('div');
  const loading = document.createElement('div'); loading.className = 'sep'; loading.textContent = 'Loading accounts / usage…';
  list.appendChild(loading); container.appendChild(list);
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
