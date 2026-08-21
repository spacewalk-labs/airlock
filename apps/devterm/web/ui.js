'use strict';
/*
 * ui.js — devterm's shared UI primitives (modal tone + clipboard copy), moved verbatim
 *   out of app.js.
 *
 * Why it is separate: the same UI has to work on a page with no terminal — panel.html,
 *   which the Airlock return widget opens in an iframe to show the accounts / secret
 *   panels. app.js attaches a terminal as soon as it loads, so it cannot be used there,
 *   and duplicating the copy logic (Safari's execCommand fallback in particular) is how
 *   two copies of a subtle behaviour start to differ. One source, two pages.
 *
 * Shape: plain globals (classic script). app.js, accounts.js, secretdrop.js and
 *   panel.html all use them by name, so ui.js loads FIRST on every page.
 * The only per-page difference is where focus returns after a copy (devterm = the
 *   terminal, panel = the field), which is the uiRefocus hook.
 */

// Focus target after a copy. Each page overrides it; the default is a no-op so a page
// that never sets it still copies (it just does not move focus).
window.uiRefocus = window.uiRefocus || function () {};

// On HTTP (non-secure) navigator.clipboard is blocked -> execCommand fallback.
// Returns a Promise<boolean> (copy success). Callers consume via .then only — inside
// xterm's sync key handler, no await/async (an async handler makes return false a Promise,
// breaking SIGINT/paste/tab-switch/IME suppression). writeText is called synchronously
// here (before the first await), so the user-gesture context is preserved.
function copyText(text) {
  if (!text) return Promise.resolve(false);
  if (navigator.clipboard && window.isSecureContext) {
    return navigator.clipboard.writeText(text).then(() => true, () => copyFallback(text));
  }
  return Promise.resolve(copyFallback(text));
}
function copyFallback(text) {
  // Safari-compatible execCommand copy: opacity:0 makes Safari refuse (fake true) ->
  //   off-screen (left:-9999px) + readonly + setSelectionRange so it really copies.
  const t = document.createElement('textarea');
  t.value = text;
  t.setAttribute('readonly', '');
  t.style.cssText = 'position:absolute;left:-9999px;top:0;font-size:12pt;';   // 12pt avoids iOS auto-zoom
  document.body.appendChild(t);
  const prevSel = document.getSelection().rangeCount > 0 ? document.getSelection().getRangeAt(0) : null;
  t.focus();
  t.select();
  try { t.setSelectionRange(0, text.length); } catch (e) {}   // iOS/Safari need more than select()
  let ok = false;
  try { ok = document.execCommand('copy'); } catch (e) {}
  document.body.removeChild(t);
  if (prevSel) { const g = document.getSelection(); g.removeAllRanges(); g.addRange(prevSel); }   // restore prior selection
  uiRefocus();
  return ok;
}

// ---- shared modal tone ----
const UI_OVERLAY = 'position:fixed;inset:0;display:flex;align-items:center;justify-content:center;padding:20px;background:rgba(0,0,0,.55);';
const UI_PANEL = 'background:#202431;border:1px solid #3a4254;border-radius:10px;box-shadow:0 16px 44px rgba(0,0,0,.42);box-sizing:border-box;';
const UI_FIELD = 'background:#171a24;color:#f2f5fa;border:1px solid #3a4254;border-radius:8px;';
function uiOverlay(z) { const ov = document.createElement('div'); ov.className = 'copy-overlay'; ov.style.cssText = UI_OVERLAY + 'z-index:' + (z || 22) + ';'; return ov; }
function uiTitle(text) { const d = document.createElement('div'); d.textContent = text; d.style.cssText = 'font:600 14.5px system-ui;color:#f2f5fa;'; return d; }
function uiBtn(label, kind) {
  const b = document.createElement('button'); b.textContent = label;
  const base = 'height:36px;border-radius:8px;font:14px system-ui;border:1px solid ';
  if (kind === 'primary') b.style.cssText = base + '#5480b8;background:#3d6aa0;color:#fff;padding:0 18px;';
  else if (kind === 'danger') b.style.cssText = base + '#5a3330;background:#2b303b;color:#e06a5a;padding:0 14px;';
  else b.style.cssText = base + 'rgba(255,255,255,.12);background:#2b303b;color:#dde1e8;padding:0 14px;';
  return b;
}
// modal skeleton (overlay + panel box). close/backdrop/focus policy is up to the caller.
function makeModal(z, boxCss) {
  const ov = uiOverlay(z);
  const box = document.createElement('div');
  box.style.cssText = UI_PANEL + boxCss;
  return { ov, box };
}

// modal close (✕) — a large high-contrast touch target.
function mkCloseBtn(onClose) {
  const x = document.createElement('button');
  x.type = 'button';
  x.textContent = '✕';
  x.setAttribute('aria-label', 'Close');
  x.title = 'Close (Esc)';
  x.style.cssText = 'flex:0 0 auto;display:flex;align-items:center;justify-content:center;width:40px;height:34px;background:#3a4254;border:none;border-radius:8px;color:#fff;font-size:20px;line-height:1;cursor:pointer;';
  x.addEventListener('click', onClose);
  return x;
}
