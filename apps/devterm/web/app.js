/*
 * devterm custom client — modern xterm.js front for the ttyd PTY backend.
 *   - session tabs: lists the live local tmux sessions (/sessions); tap to switch
 *     (navigates ?arg=<name> -> devterm-shell -> tmux new -A -s <name>; fresh client, no nesting)
 *   - seamless auto-reconnect (no "press Enter"; resumes on foreground); tmux keeps the screen
 *   - Ctrl+C: Win/Linux copies if selection else SIGINT (Windows-Terminal style); Mac always SIGINT
 *   - clipboard: Mac=Cmd+C/V; Win/Linux=Ctrl+C(sel)/Ctrl+V + Ctrl+Shift+C/V (execCommand fallback on HTTP)
 *   - right-click(context-menu) suppressed, touch scroll, CJK width (unicode11)
 * ttyd WS protocol (subprotocol "tty"): first msg = JSON {AuthToken,columns,rows};
 * input='0'+data; resize='1'+json; server frames: '0'=output '1'=title.
 *
 * Site facts (ports, hub origin, feature flags) come from window.__DEVTERM, templated
 * in by the installer. Nothing is hardcoded. Optional features degrade cleanly:
 *   accounts  — Claude account pool + Codex login UI (needs the account tools)
 *   xai       — OpenCode xAI login UI
 *   markwand  — click a file path in the terminal to open it in markwand
 *   orca      — the Orca worktree sidebar layout
 */
'use strict';

// Runtime config + feature flags (see index.html). Absent keys => feature off.
const DT = window.__DEVTERM || {};
const FEAT = { accounts: !!DT.accounts, xai: !!DT.xai,
               markwand: !!DT.markwand, orca: !!DT.orca };

(async function main() {

const enc = (s) => new TextEncoder().encode(s);
const statusEl = document.getElementById('status');
let _statusHideT = null;
// showStatus/hideStatus cancel any pending flash auto-hide timer so a progress
// message ('Connecting…', 'Uploading…') is not hidden early by an earlier flash.
// flash = a transient toast (auto-hides after ms).
const showStatus = (t, variant) => { statusEl.textContent = t; statusEl.classList.toggle('status-error', variant === 'error'); statusEl.classList.toggle('status-notice', variant === 'notice'); statusEl.hidden = false; clearTimeout(_statusHideT); _statusHideT = null; };
const hideStatus = () => { statusEl.hidden = true; statusEl.classList.remove('status-error'); statusEl.classList.remove('status-notice'); clearTimeout(_statusHideT); _statusHideT = null; };
const flash = (t, ms = 2000, variant) => { showStatus(t, variant); _statusHideT = setTimeout(hideStatus, ms); };
statusEl.addEventListener('click', hideStatus);   // tap any toast to dismiss it immediately
// Clipboard hint (press ⧉ to copy) requires a human action, so it is blue (notice).
const CLIP_NOTICE_MS = 6000;
// Alongside the hint, gently pulse the copy icon (top sqbtn / bottom mk-icon) blue so
// it's obvious which icon to press. The toolbar is rebuilt per session, so query fresh.
function pulseCopyIcon() {
  document.querySelectorAll('.js-copy-icon').forEach(function (b) {
    b.classList.remove('copy-pulse');
    void b.offsetWidth;                 // force reflow so repeated hints re-trigger the animation
    b.classList.add('copy-pulse');
    setTimeout(function () { b.classList.remove('copy-pulse'); }, 3900);   // clean up after 1.25s x 3
  });
}
const JSON_HEADERS = { 'Content-Type': 'application/json' };
const postJson = (url, body) => fetch(url, { method: 'POST', headers: JSON_HEADERS, body: JSON.stringify(body) }).then((r) => r.json());
// This box's short hostname (FQDN -> first label). Fallback 'localhost' on odd values.
function uploadHost() {
  const h = (location.hostname || '').split('.')[0];
  return /^[a-z][a-z0-9_-]*$/i.test(h) ? h : 'localhost';
}
// Uploaded files live in THIS box's ~/uploads. A remote (*) session's agent runs on a
// different host and cannot read that path directly -> hand it a token link of
// 'ssh <this box> cat <path>' so the remote agent can pull the bytes on demand. Local
// sessions get the plain path (the agent reads it directly).
const uploadTokenStr = (label, n, path) => {   // build the token string only (terminal=insertUploadToken / copy-modal textarea inserts this string)
  const target = parseRemote(currentSession()) ? ('ssh ' + uploadHost() + ' cat ' + path) : path;
  return '[' + label + String(n).padStart(3, '0') + '](' + target + ') ';
};
const insertUploadToken = (label, n, path) => sendInput(uploadTokenStr(label, n, path));

function currentSession() {
  return new URLSearchParams(location.search).get('arg') || 'main';
}

let acct = null;   // account API (accounts.js initAccounts return) — injected below. seam: openAcctMenu / applyAcctIconCls / startAcctIconWatch / hideAcctTip

// ---- terminal color themes — popular classics + a couple of lights. xterm ITheme + localStorage. ----
const THEMES = {
  'airlock-navy': { name: 'Airlock Navy', xterm: {
    background: '#181b24', foreground: '#e6e6e6', cursor: '#e6e6e6', cursorAccent: '#181b24', selectionBackground: '#2a3352',
    black: '#2b3140', red: '#e06a5a', green: '#7fd6a0', yellow: '#e2c37b', blue: '#6aa0e0', magenta: '#b48ead', cyan: '#79c6c6', white: '#d7dce6',
    brightBlack: '#4a5266', brightRed: '#ff8672', brightGreen: '#9ff0bd', brightYellow: '#ffdd95', brightBlue: '#8bb8ff', brightMagenta: '#d0acdf', brightCyan: '#9ff0f0', brightWhite: '#f2f5fa' } },
  'dracula': { name: 'Dracula', xterm: {
    background: '#282a36', foreground: '#f8f8f2', cursor: '#f8f8f2', cursorAccent: '#282a36', selectionBackground: '#44475a',
    black: '#21222c', red: '#ff5555', green: '#50fa7b', yellow: '#f1fa8c', blue: '#bd93f9', magenta: '#ff79c6', cyan: '#8be9fd', white: '#f8f8f2',
    brightBlack: '#6272a4', brightRed: '#ff6e6e', brightGreen: '#69ff94', brightYellow: '#ffffa5', brightBlue: '#d6acff', brightMagenta: '#ff92df', brightCyan: '#a4ffff', brightWhite: '#ffffff' } },
  'catppuccin-mocha': { name: 'Catppuccin Mocha', xterm: {
    background: '#1e1e2e', foreground: '#cdd6f4', cursor: '#f5e0dc', cursorAccent: '#1e1e2e', selectionBackground: '#585b70',
    black: '#45475a', red: '#f38ba8', green: '#a6e3a1', yellow: '#f9e2af', blue: '#89b4fa', magenta: '#f5c2e7', cyan: '#94e2d5', white: '#bac2de',
    brightBlack: '#585b70', brightRed: '#f38ba8', brightGreen: '#a6e3a1', brightYellow: '#f9e2af', brightBlue: '#89b4fa', brightMagenta: '#f5c2e7', brightCyan: '#94e2d5', brightWhite: '#a6adc8' } },
  'gruvbox-dark': { name: 'Gruvbox Dark', xterm: {
    background: '#282828', foreground: '#ebdbb2', cursor: '#ebdbb2', cursorAccent: '#282828', selectionBackground: '#504945',
    black: '#282828', red: '#cc241d', green: '#98971a', yellow: '#d79921', blue: '#458588', magenta: '#b16286', cyan: '#689d6a', white: '#a89984',
    brightBlack: '#928374', brightRed: '#fb4934', brightGreen: '#b8bb26', brightYellow: '#fabd2f', brightBlue: '#83a598', brightMagenta: '#d3869b', brightCyan: '#8ec07c', brightWhite: '#ebdbb2' } },
  'nord': { name: 'Nord', xterm: {
    background: '#2e3440', foreground: '#d8dee9', cursor: '#d8dee9', cursorAccent: '#2e3440', selectionBackground: '#434c5e',
    black: '#3b4252', red: '#bf616a', green: '#a3be8c', yellow: '#ebcb8b', blue: '#81a1c1', magenta: '#b48ead', cyan: '#88c0d0', white: '#e5e9f0',
    brightBlack: '#4c566a', brightRed: '#bf616a', brightGreen: '#a3be8c', brightYellow: '#ebcb8b', brightBlue: '#81a1c1', brightMagenta: '#b48ead', brightCyan: '#8fbcbb', brightWhite: '#eceff4' } },
  'one-dark': { name: 'One Dark', xterm: {
    background: '#282c34', foreground: '#abb2bf', cursor: '#528bff', cursorAccent: '#282c34', selectionBackground: '#3e4451',
    black: '#282c34', red: '#e06c75', green: '#98c379', yellow: '#e5c07b', blue: '#61afef', magenta: '#c678dd', cyan: '#56b6c2', white: '#abb2bf',
    brightBlack: '#5c6370', brightRed: '#e06c75', brightGreen: '#98c379', brightYellow: '#e5c07b', brightBlue: '#61afef', brightMagenta: '#c678dd', brightCyan: '#56b6c2', brightWhite: '#ffffff' } },
  'pro': { name: 'Pro', xterm: {
    background: '#000000', foreground: '#f2f2f2', cursor: '#4d4d4d', cursorAccent: '#000000', selectionBackground: '#414141',
    black: '#000000', red: '#990000', green: '#00a600', yellow: '#999900', blue: '#0000b2', magenta: '#b200b2', cyan: '#00a6b2', white: '#bfbfbf',
    brightBlack: '#666666', brightRed: '#e50000', brightGreen: '#00d900', brightYellow: '#e5e500', brightBlue: '#0000ff', brightMagenta: '#e500e5', brightCyan: '#00e5e5', brightWhite: '#e5e5e5' } },
  'matrix': { name: 'Matrix', xterm: {
    background: '#020a02', foreground: '#33d17a', cursor: '#43e07f', cursorAccent: '#020a02', selectionBackground: '#0f3d24',
    black: '#0a2a12', red: '#d33131', green: '#33d17a', yellow: '#9ede4e', blue: '#1f8f5f', magenta: '#4fae7f', cyan: '#5fe0a0', white: '#a7e8bf',
    brightBlack: '#1f6b3f', brightRed: '#ff5b5b', brightGreen: '#57ff9e', brightYellow: '#c8ff7a', brightBlue: '#2fb87a', brightMagenta: '#7fd6a0', brightCyan: '#8fffcf', brightWhite: '#d8ffe8' } },
  'solarized-light': { name: 'Solarized Light', xterm: {
    background: '#fdf6e3', foreground: '#657b83', cursor: '#586e75', cursorAccent: '#fdf6e3', selectionBackground: '#eee8d5',
    black: '#073642', red: '#dc322f', green: '#859900', yellow: '#b58900', blue: '#268bd2', magenta: '#d33682', cyan: '#2aa198', white: '#586e75',
    brightBlack: '#002b36', brightRed: '#cb4b16', brightGreen: '#586e75', brightYellow: '#657b83', brightBlue: '#839496', brightMagenta: '#6c71c4', brightCyan: '#93a1a1', brightWhite: '#fdf6e3' } },
  'catppuccin-latte': { name: 'Catppuccin Latte', xterm: {
    background: '#eff1f5', foreground: '#4c4f69', cursor: '#dc8a78', cursorAccent: '#eff1f5', selectionBackground: '#acb0be',
    black: '#5c5f77', red: '#d20f39', green: '#40a02b', yellow: '#df8e1d', blue: '#1e66f5', magenta: '#ea76cb', cyan: '#179299', white: '#acb0be',
    brightBlack: '#6c6f85', brightRed: '#d20f39', brightGreen: '#40a02b', brightYellow: '#df8e1d', brightBlue: '#1e66f5', brightMagenta: '#ea76cb', brightCyan: '#179299', brightWhite: '#bcc0cc' } },
};
const THEME_ORDER = ['airlock-navy', 'dracula', 'catppuccin-mocha', 'gruvbox-dark', 'nord', 'one-dark', 'pro', 'matrix', 'solarized-light', 'catppuccin-latte'];
const DEFAULT_THEME = 'airlock-navy';
// Theme is stored in the same server source of truth as tab order/color (tabs.json)
// so it's identical on any device. TABS_KEY = its localStorage cache.
const TABS_KEY = 'devterm-tabs';
function savedThemeKey() { try { const p = JSON.parse(localStorage.getItem(TABS_KEY)) || {}; return THEMES[p.theme] ? p.theme : DEFAULT_THEME; } catch (e) { return DEFAULT_THEME; } }

const term = new Terminal({
  fontFamily: 'ui-monospace, "SF Mono", "SFMono-Regular", Menlo, Monaco, Consolas, "DejaVu Sans Mono", "Liberation Mono", monospace',
  fontSize: 14,
  lineHeight: 1.2,                 // starting placeholder — applyLineHeight() snaps to an integer CSS-px cell height per device dpr (wide spacing + crisp)
  cursorBlink: true,
  scrollback: 8000,
  scrollSensitivity: 5,            // mouse-wheel speed for the shell scrollback (normal buffer). alt-screen uses the custom wheel handler below
  fastScrollSensitivity: 12,       // Alt+wheel = fast scroll
  allowProposedApi: true,
  macOptionIsMeta: true,
  theme: THEMES[savedThemeKey()].xterm,   // saved theme (default airlock-navy). Runtime change = applyTheme()
});
const fit = new FitAddon.FitAddon();
term.loadAddon(fit);
try {
  const uni = new Unicode11Addon.Unicode11Addon();
  term.loadAddon(uni);
  term.unicode.activeVersion = '11';   // CJK width = 2 cells
} catch (e) { /* optional */ }

term.open(document.getElementById('term'));
// Suppress iOS autofill/predictive bar — the terminal textarea is not a form field.
try {
  const _ta = term.textarea;
  if (_ta) {
    _ta.setAttribute('autocomplete', 'off');
    _ta.setAttribute('autocorrect', 'off');
    _ta.setAttribute('autocapitalize', 'none');
    _ta.setAttribute('spellcheck', 'false');
    _ta.setAttribute('inputmode', 'text');   // CJK IMEs need text mode ('none' kills composition)
  }
} catch (e) {}
try { fit.fit(); } catch (e) {}

// Make URLs printed in the terminal clickable (new tab). Links tmux emits open too.
try {
  term.loadAddon(new WebLinksAddon.WebLinksAddon(function (event, uri) {
    window.open(uri, '_blank', 'noopener,noreferrer');
  }));
} catch (e) {}

// ---- click a file path (.md/.json/...) in the terminal -> open it in markwand (modal, new tab on failure) ----
// gate /resolve maps an absolute/~ path, or a path relative to the session pane cwd,
// into code_root -> /markwand/... URL. Optional (FEAT.markwand).
const VIEW_EXT = 'markdown|md|json|yaml|yml|toml|txt|log|csv|tsv|conf|cfg|ini|env|xml|html|htm|css|jsx|tsx|js|ts|py|bash|zsh|sh|rb|go|rs|sql|svg';
// path-form (with dirs) + bare filename (no dir) — the gate searches under the session cwd for a bare name.
// \p{L}\p{N} + u flag = unicode filenames recognized too (\w is ASCII-only).
const FILE_PATH_RE = new RegExp('(?:~\\/|\\/|\\.{1,2}\\/)?(?:[\\p{L}\\p{N}_.@+\\-]+\\/)*[\\p{L}\\p{N}_][\\p{L}\\p{N}_.@+\\-]*\\.(?:' + VIEW_EXT + ')(?![\\p{L}\\p{N}_])', 'gu');

// buffer line -> {string, per-char cell column}. Corrects underline alignment for CJK (2 cells / 1 char).
function lineCells(line) {
  let str = '';
  const colAt = [];
  const cols = line.length;
  for (let x = 0; x < cols; x++) {
    const cell = line.getCell(x);
    if (!cell) continue;
    if (cell.getWidth() === 0) continue;            // trailing spacer cell of a wide char
    const ch = cell.getChars() || ' ';
    for (let k = 0; k < ch.length; k++) colAt.push(x);
    str += ch;
  }
  return { str: str, colAt: colAt };
}

function hubBase() {
  // The hub is https on 443 (no port). Airlock serves nothing over plain http —
  // its plaintext ports only 301 here — so this never needs a scheme fallback.
  return 'https://' + location.hostname;
}

function resolveWhy(j, p) {
  const r = j && j.reason;
  if (r === 'ambiguous')    return j.count + ' candidates — path is ambiguous: ' + p;
  if (r === 'no_cwd')       return '⚠️ Could not read the session working dir (remote/abnormal session?) — retry with an absolute or ~/… path: ' + p;
  if (r === 'outside_code') return '⚠️ File exists but is outside code_root (the markwand root) — check it is symlinked under code_root: ' + p;
  if (r === 'notfound')     return '⚠️ Not found — no "' + (j.base || p) + '" under the session folder (' + (j.cwd || '?') + ')';
  if (r === 'empty')        return '⚠️ Empty path';
  if (r === 'disabled')     return '⚠️ File opening (markwand) is not enabled';
  return '⚠️ Cannot open in markwand: ' + p;
}

function openMarkwand(pathText) {
  const p = pathText.replace(/[),.;:]+$/, '');
  const qs = 'resolve?path=' + encodeURIComponent(p) + '&session=' + encodeURIComponent(currentSession());
  const amb = (j) => j && j.reason === 'ambiguous' && j.hits && j.hits.length;
  if (/\.html?$/i.test(p)) {
    // html = web page -> new tab. Popup-blocker workaround: open at click gesture, navigate after resolve.
    const w = window.open('about:blank', '_blank');
    fetch(qs, { cache: 'no-store' }).then((r) => r.json()).then((j) => {
      if (j && j.ok) { const u = hubBase() + j.url; if (w) w.location.href = u; else window.open(u, '_blank'); }
      else if (amb(j)) { if (w) w.close(); openPickerModal(p, j.hits); }
      else { if (w) w.close(); flash(resolveWhy(j, p), 8000, 'error'); }
    }).catch(() => { if (w) w.close(); flash('⚠️ resolve request failed (no gate response): ' + p, 8000, 'error'); });
    return;
  }
  // md/json/... = modal (loading) immediately on click -> fill iframe after resolve
  const m = openMarkwandModal(p);
  fetch(qs, { cache: 'no-store' }).then((r) => r.json()).then((j) => {
    if (j && j.ok) m.load(hubBase() + j.url, j.rel || p);
    else if (amb(j)) { m.close(); openPickerModal(p, j.hits); }
    else { m.close(); flash(resolveWhy(j, p), 8000, 'error'); }
  }).catch(() => { m.close(); flash('⚠️ resolve request failed (no gate response): ' + p, 8000, 'error'); });
}

// open by extension — html = new tab / else = markwand modal
function openResolvedHit(hit) {
  const url = hubBase() + hit.url;
  if (/\.html?$/i.test(hit.rel)) window.open(url, '_blank', 'noopener,noreferrer');
  else openMarkwandModal(hit.rel).load(url, hit.rel);
}

// several candidates -> pick from a newest-first list (top ★ = newest)
function openPickerModal(query, hits) {
  const { ov, box } = makeModal(31, 'padding:14px;width:100%;max-width:600px;display:flex;flex-direction:column;gap:10px;max-height:76vh;');
  const h = document.createElement('div');
  h.style.cssText = 'display:flex;align-items:center;gap:10px;flex:0 0 auto;';
  const htxt = document.createElement('span');
  htxt.textContent = hits.length + ' candidates — "' + query + '" (newest first, ★ = newest)';
  htxt.style.cssText = 'flex:1;min-width:0;font:13px sans-serif;color:#cdd3e0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';
  h.appendChild(htxt);
  const list = document.createElement('div');
  list.style.cssText = 'overflow-y:auto;display:flex;flex-direction:column;gap:6px;min-height:0;';
  function close() { try { document.body.removeChild(ov); } catch (e) {} document.removeEventListener('keydown', onKey); }
  function onKey(e) { if (e.key === 'Escape') close(); }
  h.appendChild(mkCloseBtn(close));   // large ✕ (iPad has no Esc key — a visual close is essential)
  document.addEventListener('keydown', onKey);
  ov.addEventListener('mousedown', (e) => { if (e.target === ov) close(); });
  hits.forEach(function (hit, i) {
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = (i === 0 ? '★ ' : '    ') + hit.rel;
    b.style.cssText = 'text-align:left;padding:8px 10px;border:1px solid #33384a;border-radius:7px;color:#e6e6e6;font:12px ui-monospace,monospace;cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;flex:0 0 auto;background:' + (i === 0 ? '#26304a' : '#1b1f2a') + ';';
    b.addEventListener('click', function () { close(); openResolvedHit(hit); });
    list.appendChild(b);
  });
  box.appendChild(h); box.appendChild(list);
  ov.appendChild(box); document.body.appendChild(ov);
}

// open a modal immediately (loading) and return an api — .load(url,title) fills the iframe / .close()
function openMarkwandModal(title) {
  const { ov, box } = makeModal(30, 'padding:0;width:96vw;max-width:1120px;height:88vh;display:flex;flex-direction:column;overflow:hidden;');
  const bar = document.createElement('div');
  bar.style.cssText = 'display:flex;align-items:center;gap:10px;padding:8px 12px;background:#222634;border-bottom:1px solid #33384a;flex:0 0 auto;';
  const ttl = document.createElement('div');
  ttl.textContent = title || '';
  ttl.style.cssText = 'flex:1;min-width:0;font:12px ui-monospace,monospace;color:#cdd3e0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';
  const tab = document.createElement('a');
  tab.target = '_blank'; tab.rel = 'noopener'; tab.textContent = 'New tab ↗';
  tab.style.cssText = 'flex:0 0 auto;color:#8ab4ff;font:12px sans-serif;text-decoration:none;';
  function close() { try { document.body.removeChild(ov); } catch (e) {} document.removeEventListener('keydown', onKey); }
  function onKey(e) { if (e.key === 'Escape') { e.stopPropagation(); close(); } }
  const x = mkCloseBtn(close);   // large ✕ touch target (iPad mini portrait)
  document.addEventListener('keydown', onKey);
  ov.addEventListener('mousedown', (e) => { if (e.target === ov) close(); });
  const bodyEl = document.createElement('div');
  bodyEl.style.cssText = 'flex:1 1 auto;position:relative;background:#fff;min-height:0;';
  const spin = document.createElement('div');
  spin.textContent = 'Loading…';
  spin.style.cssText = 'position:absolute;inset:0;display:flex;align-items:center;justify-content:center;color:#888;font:13px sans-serif;';
  const fr = document.createElement('iframe');
  fr.style.cssText = 'width:100%;height:100%;border:0;display:block;';
  fr.addEventListener('load', () => { if (fr.src && fr.src.indexOf('about:blank') < 0) spin.style.display = 'none'; });
  bodyEl.appendChild(fr); bodyEl.appendChild(spin);
  bar.appendChild(ttl); bar.appendChild(tab); bar.appendChild(x);
  box.appendChild(bar); box.appendChild(bodyEl);
  ov.appendChild(box); document.body.appendChild(ov);
  return {
    close: close,
    load: function (url, t) { if (t) ttl.textContent = t; tab.href = url; fr.src = url; },
  };
}

if (FEAT.markwand) try {
  term.registerLinkProvider({
    provideLinks: function (y, callback) {
      let line;
      try { line = term.buffer.active.getLine(y - 1); } catch (e) { line = null; }
      if (!line) { callback(undefined); return; }
      const lc = lineCells(line), s = lc.str, colAt = lc.colAt;
      const links = [];
      let m;
      FILE_PATH_RE.lastIndex = 0;
      while ((m = FILE_PATH_RE.exec(s)) !== null) {
        const start = m.index, txt = m[0];
        if (start > 0) { const pc = s[start - 1]; if (pc === '/' || pc === ':' || pc === '@') continue; }  // skip mid-URL / parent-path matches
        const c0 = colAt[start], c1 = colAt[start + txt.length - 1];
        if (c0 == null || c1 == null) continue;
        links.push({
          text: txt,
          range: { start: { x: c0 + 1, y: y }, end: { x: c1 + 1, y: y } },
          decorations: { underline: true, pointerCursor: true },
          activate: function (ev, t) { if (ev) ev.preventDefault(); openMarkwand(t); },
        });
        if (links.length > 40) break;
      }
      callback(links.length ? links : undefined);
    },
  });
} catch (e) {}

// ---- plain-click (no modifier) link open — works even when Claude Code/vim/tmux mouse mode grabs the click ----
// In the capture phase we decide directly whether a clean click (not a drag, no
// modifier) landed on a link -> if so, open it instead of forwarding to the app. If
// not a link (or coords fail), we do nothing (scroll/select/input unaffected).
const URL_RE = /https?:\/\/[^\s'"()\[\]{}<>]+/g;

function pixelToCell(ev) {
  try {
    const core = term._core;
    const dims = core && core._renderService && core._renderService.dimensions;
    if (!dims) return null;
    const cell = dims.css ? dims.css.cell : dims;
    const cw = (cell && cell.width) || dims.actualCellWidth;
    const ch = (cell && cell.height) || dims.actualCellHeight;
    if (!cw || !ch) return null;
    const screen = term.element.querySelector('.xterm-screen') || term.element;
    const rect = screen.getBoundingClientRect();
    const x = ev.clientX - rect.left, y = ev.clientY - rect.top;
    if (x < 0 || y < 0 || x > rect.width || y > rect.height) return null;
    return { col: Math.floor(x / cw), row: term.buffer.active.viewportY + Math.floor(y / ch) };
  } catch (e) { return null; }
}

// -- restore tmux-wrapped links --------------------------------------------------
// tmux draws panes with absolute cursor positioning, so a wrapped URL/path appears
// as two separate lines in the xterm buffer (isWrapped=false). Find the click cell's
// pane column range via the vertical separator (│), then stitch rows that fill to the
// right edge into one logical line. Covers full-width, vertical (│), and horizontal splits.
const TMUX_VSEP = '│';                                            // tmux vertical pane border (U+2502)
function isBoxCh(ch) { const c = ch ? ch.charCodeAt(0) : 0; return c >= 0x2500 && c <= 0x257f; }   // box-drawing = border

function rowLC(row) {
  let line;
  try { line = term.buffer.active.getLine(row); } catch (e) { return null; }
  return line ? lineCells(line) : null;                          // {str, colAt} — CJK width corrected
}
function colChar(lc, col) {                                      // char at that column (' ' if none)
  if (!lc) return ' ';
  for (let i = 0; i < lc.colAt.length; i++) if (lc.colAt[i] === col) return lc.str[i];
  return ' ';
}
function fillsRight(lc, R) {                                     // right edge (R) is a real char = wrap continues
  const c = colChar(lc, R);
  return c !== ' ' && !isBoxCh(c);
}

// logical-line text at click (row,col) + a per-char {row,col} map. Only stitch within the click's pane column range.
function logicalLineAt(clickRow, clickCol) {
  const base = rowLC(clickRow);
  if (!base) return null;
  let L = 0, R = (term.cols || 80) - 1;                          // pane column range: narrow to nearest │ on each side
  for (let i = 0; i < base.colAt.length; i++) {
    if (base.str[i] !== TMUX_VSEP) continue;
    const c = base.colAt[i];
    if (c < clickCol && c + 1 > L) L = c + 1;
    if (c > clickCol && c - 1 < R) R = c - 1;
  }
  let top = clickRow;                                            // upward: previous row full + this row starts with a real char = continued
  for (let k = 0; k < 8; k++) {
    const prev = rowLC(top - 1);
    if (!fillsRight(prev, R)) break;
    const startCh = colChar(top === clickRow ? base : rowLC(top), L);
    if (startCh === ' ' || isBoxCh(startCh)) break;
    top--;
  }
  let text = '';
  const map = [];
  for (let r = top, k = 0; k < 24; k++, r++) {                   // stitch segments downward from top
    const lc = (r === clickRow) ? base : rowLC(r);
    if (!lc) break;
    for (let i = 0; i < lc.colAt.length; i++) {
      const c = lc.colAt[i];
      if (c >= L && c <= R) { text += lc.str[i]; map.push({ row: r, col: c }); }
    }
    if (!fillsRight(lc, R)) break;                               // not full = end of logical line
    if (isBoxCh(colChar(rowLC(r + 1), L)) || colChar(rowLC(r + 1), L) === ' ') break;  // next row starts blank/border -> not continued
  }
  return { text: text, map: map };
}

function hitInMatch(map, a, b, row, col) {                       // is the click cell inside match [a,b]
  for (let i = a; i <= b && i < map.length; i++)
    if (map[i] && map[i].row === row && map[i].col === col) return true;
  return false;
}

function linkAtCell(row, col) {
  const lg = logicalLineAt(row, col);
  if (!lg) return null;
  const s = lg.text, map = lg.map;
  let m;
  URL_RE.lastIndex = 0;
  while ((m = URL_RE.exec(s)) !== null) {
    if (hitInMatch(map, m.index, m.index + m[0].length - 1, row, col)) return { kind: 'url', text: m[0] };
  }
  if (FEAT.markwand) {
    FILE_PATH_RE.lastIndex = 0;
    while ((m = FILE_PATH_RE.exec(s)) !== null) {
      const st = m.index;
      if (st > 0) { const pc = s[st - 1]; if (pc === '/' || pc === ':' || pc === '@') continue; }
      if (hitInMatch(map, st, st + m[0].length - 1, row, col)) return { kind: 'file', text: m[0] };
    }
  }
  return null;
}

// Never preventDefault on mousedown: that would stop xterm from forwarding the press
// to tmux, so a copy-mode drag selection could not start ("drag starting on a URL
// breaks"). So mousedown is never blocked; click-vs-drag is decided by distance at
// mouseup. Any movement (drag) = no link intervention; only a clean click opens a link.
(function plainClickLinks() {
  const el = term.element;
  if (!el) return;
  const DRAG_PX = 5;                                     // more than this = drag (selection), not a click
  let armed = null, dx = 0, dy = 0;
  el.addEventListener('mousedown', function (ev) {
    armed = null;
    if (ev.button !== 0 || ev.shiftKey || ev.altKey || ev.metaKey || ev.ctrlKey) return;   // modifier/right-click = default behavior
    const c = pixelToCell(ev);
    if (!c) return;
    const hit = linkAtCell(c.row, c.col);
    if (!hit) return;                                    // not a link = no intervention
    armed = hit; dx = ev.clientX; dy = ev.clientY;       // do NOT preventDefault here (keep drag selection alive)
  }, true);
  el.addEventListener('mousemove', function (ev) {
    if (armed && Math.abs(ev.clientX - dx) + Math.abs(ev.clientY - dy) > DRAG_PX) armed = null;  // movement = drag -> disarm link
  }, true);
  el.addEventListener('mouseup', function (ev) {
    const hit = armed; armed = null;
    if (!hit) return;                                    // was a drag -> no intervention (keep tmux selection)
    if (Math.abs(ev.clientX - dx) + Math.abs(ev.clientY - dy) > DRAG_PX) return;   // safety net (missed mousemove)
    if (hit.kind === 'url') window.open(hit.text, '_blank', 'noopener,noreferrer');
    else openMarkwand(hit.text);
  }, true);
})();

// iOS/iPad (touch) vs Safari (WebKit). Measured: desktop Safari fires composition
// events normally (like Chrome) -> native IME. Only iOS Safari omits them -> mirror needed.
const _UA = navigator.userAgent;
const IS_IOS = /iP(hone|ad|od)/.test(_UA) ||
               ((navigator.platform === 'MacIntel' || /Macintosh/.test(_UA)) && navigator.maxTouchPoints > 1);
// iPad (incl. mini) detection vs iPhone. iPadOS 13+ reports a desktop UA + touch.
const IS_IPAD = /iPad/.test(_UA) ||
                ((navigator.platform === 'MacIntel' || /Macintosh/.test(_UA)) && navigator.maxTouchPoints > 1);
const IS_MAC = /Mac|iPhone|iPad|iPod/.test(navigator.platform) || IS_IOS;   // platforms where Cmd(metaKey)=copy (Win/Linux false)
const NEEDS_IME_MIRROR = IS_IOS;              // only iOS/iPad (which omit composition events)
// Renderer = the DOM renderer (browser-native text pipeline). WebGL/canvas rasterize
// glyphs into an atlas and blend, drawing strokes heavier on a dark bg than native DOM
// text. DOM = thin like an IME overlay, and the integer cell-height grid alignment
// (applyLineHeight) keeps it crisp. Trade-off: lower throughput than WebGL on huge
// output, but plenty for a dev terminal.
// (DOM renderer = the xterm default when no WebGL/canvas addon is loaded.)

// tmux (set-clipboard on) sends OSC 52 on copy. xterm ignores it by default -> handle
// it here to write the system clipboard. On a non-secure (HTTP) context we cannot use
// navigator.clipboard, so we store to lastClip and try best-effort; the ⧉ button (a
// click gesture) then writes it for sure.
let lastClip = '';
let _pasteGuardAt = -Infinity;   // time of a Ctrl+V -> pasteFromClipboard call — guards against the browser also firing a native paste (double). -Infinity so the first native paste after load isn't swallowed
// iPad/mobile: our term.paste (⧉) and the browser native paste can both arrive = "twice".
// Remember the text we pasted and, if the same text arrives via native paste soon
// after, swallow only that one. Content match + within 900ms only -> unique pastes never lost.
let _lastPaste = { t: '', at: 0 };
function pasteText(t) { t = t || ''; _lastPaste = { t: t, at: performance.now() }; term.paste(t); }
try {
  term.parser.registerOscHandler(52, function (data) {
    const i = data.indexOf(';');
    if (i < 0) return true;
    try {
      const bytes = Uint8Array.from(atob(data.slice(i + 1)), function (c) { return c.charCodeAt(0); });
      lastClip = new TextDecoder().decode(bytes);
      const _n = lastClip.length;
      // best-effort auto-copy — success (Chrome etc) => no button needed / failure (Safari blocks gesture-less write) => ⧉ hint.
      copyText(lastClip).then(function (ok) {
        if (ok) flash('Copied ' + _n + ' chars — paste anywhere', 1800);
        else { flash('Clipboard received ' + _n + ' chars — press ⧉ to copy', CLIP_NOTICE_MS, 'notice'); pulseCopyIcon(); }
      });
    } catch (e) {}
    return true;
  });
} catch (e) {}

term.attachCustomKeyEventHandler((e) => {
  if (e.type !== 'keydown' && e.type !== 'keypress') return true;
  // Ctrl+Shift+C -> copy / Ctrl+Shift+V -> paste (Windows/Linux terminal standard — Mac uses Cmd+C/V).
  //   Explicit copy path: copies including lastClip (tmux OSC52 drag) regardless of selection.
  if (e.type === 'keydown' && e.ctrlKey && e.shiftKey && !e.metaKey && !e.altKey &&
      (e.key === 'c' || e.key === 'C' || e.code === 'KeyC')) {
    const s = term.getSelection() || lastClip;
    if (s) copyText(s).then((ok) => flash(ok ? 'Copied ' + s.length + ' chars' : 'Copy failed — use Cmd/Ctrl+C', ok ? 1200 : 2200));
    else flash('No selection — Shift+drag to select, then copy', 1400);
    e.preventDefault(); return false;
  }
  // Ctrl+V / Ctrl+Shift+V = paste (text + image). xterm consumes Ctrl+V as \x16 (SYN) on
  //   Win/Linux, so no native paste event fires -> read the clipboard directly here.
  if (e.type === 'keydown' && e.ctrlKey && !e.metaKey && !e.altKey &&
      (e.key === 'v' || e.key === 'V' || e.code === 'KeyV')) {
    // Non-secure (HTTP): clipboard.read/readText is blocked so pasteFromClipboard always fails.
    //   return false without preventDefault -> xterm won't send \x16, native paste survives, and
    //   the window 'paste' listener (via clipboardData, works on HTTP) inserts once.
    if (!window.isSecureContext) return false;
    e.preventDefault();
    _pasteGuardAt = performance.now();   // if the browser also fires native paste, the window 'paste' guard below blocks the double
    pasteFromClipboard();
    return false;
  }
  // Ctrl+C -> Win/Linux: copy if selection (Windows Terminal / VS Code style), else SIGINT.
  //          Mac: always SIGINT (copy is Cmd+C).
  //   selection = xterm native (Shift+drag). With tmux mouse on, a plain drag goes to tmux.
  if (e.type === 'keydown' && e.ctrlKey && !e.shiftKey && !e.metaKey && !e.altKey &&
      (e.key === 'c' || e.key === 'C' || e.code === 'KeyC')) {
    if (!IS_MAC && term.hasSelection()) {
      const s = term.getSelection();
      copyText(s).then((ok) => flash(ok ? 'Copied ' + s.length + ' chars' : 'Copy failed — use Cmd/Ctrl+C', ok ? 1000 : 2200));
      term.clearSelection();                              // clear selection after copy -> next Ctrl+C is SIGINT
      e.preventDefault(); return false;
    }
    sendInput('\x03'); e.preventDefault(); return false;
  }
  // Ctrl+1~9 = jump to the Nth visible tab. Cmd+1~9 is left alone (native browser tabs).
  //   Digit1~9 (physical) so it's layout-independent. Out of range = no-op, not sent to the shell.
  if (e.type === 'keydown' && e.ctrlKey && !e.metaKey && !e.shiftKey && !e.altKey &&
      e.code && /^Digit[1-9]$/.test(e.code)) {
    const target = visibleTabs[parseInt(e.code.slice(5), 10) - 1];
    if (target && target !== currentSession()) switchTo(target);
    e.preventDefault(); return false;
  }
  // iOS key: block xterm from sending printable single keys via keydown/keypress.
  //   Otherwise xterm sends the char itself (doubling for latin; breaking CJK composition).
  //   Blocked -> the browser default input/composition runs in the textarea and only the
  //   stable-prefix mirror below sends completed syllables. Enter/Backspace/Tab/Esc/arrows
  //   (key.length>1) and Ctrl/Meta/Alt combos keep xterm native handling.
  if (NEEDS_IME_MIRROR && !e.ctrlKey && !e.metaKey && !e.altKey && e.key && e.key.length === 1) {
    return false;
  }
  return true;
});
// ================= mobile accessory key bar (mobile-only, additive) =================
// Desktop (fine pointer) is unaffected: MK.active=false -> interceptors no-op, no DOM, no height change.
const MK = {
  active: false,                       // shown (capability + pref)
  ctrl: false, alt: false,             // armed one-shot
  hold: null,                          // 'ctrl'|'alt' hold-chain (pointer held)
  expanded: false,
  armT: null,                          // arm timeout
  guard: false,                        // a keydown consumed an armed mod -> drop the following 1 input char (double-send guard)
  el: null, btn: { ctrl: null, alt: null },
};
const MK_ARM_MS = 9000;

function mkPref() { try { return localStorage.getItem('devterm-mkeys') || 'auto'; } catch (e) { return 'auto'; } }
function mkSetPref(v) { try { localStorage.setItem('devterm-mkeys', v); } catch (e) {} }
function mkShouldShow() {
  const p = mkPref();
  if (p === 'on') return true;
  if (p === 'off') return false;
  // auto: iOS/iPadOS always (a physical keyboard still benefits from ESC/^C/Ctrl-Alt/tmux/zoom).
  //   Others (Android etc) only on a narrow (phone) screen. Turn off with pref 'off'.
  if (IS_IOS && navigator.maxTouchPoints > 0) return true;
  const touch = navigator.maxTouchPoints > 0 && matchMedia('(pointer:coarse)').matches;
  const compact = isCompact();
  return touch && compact;
}

// reflect armed visual state (arm = blue, hold = green)
function mkPaint() {
  for (const k of ['ctrl', 'alt']) {
    const b = MK.btn[k]; if (!b) continue;
    b.classList.toggle('mk-arm', MK[k] && MK.hold !== k);
    b.classList.toggle('mk-hold', MK.hold === k);
  }
}
// single teardown — every exit path calls this. keepHold=true keeps the hold-chain.
function clearMobileMods(reason, keepHold) {
  const had = MK.ctrl || MK.alt || (!keepHold && MK.hold);
  MK.ctrl = false; MK.alt = false;
  if (!keepHold) MK.hold = null;
  clearTimeout(MK.armT); MK.armT = null;
  if (had) { mkPaint(); hideStatus(); }
}
function mkArmTimeout() { clearTimeout(MK.armT); MK.armT = setTimeout(() => clearMobileMods('timeout'), MK_ARM_MS); }
function mkVibrate(ms) { try { navigator.vibrate && navigator.vibrate(ms); } catch (e) {} }

// arm-toggle a modifier (short tap). One at a time (ctrl+alt combos only via hold).
function mkToggleMod(which) {
  if (MK.hold === which) return;
  const on = !MK[which];
  MK.ctrl = false; MK.alt = false;
  MK[which] = on;
  if (on) { mkArmTimeout(); flash((which === 'ctrl' ? 'Ctrl' : 'Alt') + ' armed — applies to the next key', MK_ARM_MS); mkVibrate(10); }
  else { clearTimeout(MK.armT); hideStatus(); }
  mkPaint();
}

// apply armed (ctrl/alt) to a char -> bytes to send. null = not applicable.
function mkCtrlByte(ch) {
  const c = ch.toLowerCase();
  if (c >= 'a' && c <= 'z') return String.fromCharCode(c.charCodeAt(0) - 96);   // ^A=1 … ^Z=26
  const map = { ' ': '\x00', '@': '\x00', '[': '\x1b', '\\': '\x1c', ']': '\x1d', '^': '\x1e', '_': '\x1f', '?': '\x7f' };
  return Object.prototype.hasOwnProperty.call(map, ch) ? map[ch] : null;
}
function mkArmedCtrl() { return MK.ctrl || MK.hold === 'ctrl'; }
function mkArmedAlt() { return MK.alt || MK.hold === 'alt'; }
function mkApplyArmed(key) {
  const ctrl = mkArmedCtrl(), alt = mkArmedAlt();
  if (!ctrl && !alt) return null;
  let base = key;
  if (ctrl) { const b = mkCtrlByte(key); if (b === null) return null; base = b; }
  if (alt) base = '\x1b' + base;
  return base;
}
function mkConsumeOneShot() {                 // release one-shot after send (hold persists)
  if (MK.hold) return;
  if (MK.ctrl || MK.alt) { MK.ctrl = false; MK.alt = false; clearTimeout(MK.armT); mkPaint(); hideStatus(); }
}
function mkModParam() {
  const ctrl = mkArmedCtrl(), alt = mkArmedAlt();
  if (ctrl && alt) return 7; if (alt) return 3; if (ctrl) return 5; return 0;
}

// best-effort: armed + next real key (non-iOS soft key / desktop physical key). iOS goes via the IME-mirror input path.
if (term.element) {
  term.element.addEventListener('keydown', function (e) {
    if (!MK.active) return;
    if (!(MK.ctrl || MK.alt || MK.hold)) return;
    if (e.isComposing || e.keyCode === 229) return;                 // composing -> stay out
    const k = e.key;
    if (!k || k.length !== 1) return;
    const code = k.charCodeAt(0);
    if (code < 0x20 || code > 0x7e) return;
    const seq = mkApplyArmed(k);
    if (seq === null) {                                             // not mappable (e.g. armed ctrl + '5') -> stay out (browser default)
      if (!MK.hold) clearMobileMods('non-applicable-key', true);    //   but release one-shot arm here (matches iOS input path). HOLD persists.
      return;
    }
    sendInput(seq);
    e.preventDefault(); e.stopImmediatePropagation();
    MK.guard = true;                                                // drop the following 1 input char
    try { if (term.textarea) term.textarea.value = ''; } catch (_) {}
    setTimeout(function () { MK.guard = false; }, 60);
    mkConsumeOneShot();
  }, true);
}

// ---- bar DOM ----
function mkMakeBtn(label, cls) {
  const b = document.createElement('button');
  if (cls) b.className = cls;
  b.textContent = label;
  b.addEventListener('pointerdown', function (e) { e.preventDefault(); });   // keep focus / soft keyboard
  return b;
}
function mkKey(label, cls, handler) {
  const b = mkMakeBtn(label, cls);
  b.addEventListener('click', handler);
  return b;
}
function mkFocus() { try { term.focus(); } catch (e) {} }
function mkSendLit(ch) {                       // literal/symbol — apply armed if any, else as-is
  const seq = mkApplyArmed(ch);
  sendInput(seq !== null ? seq : ch);
  mkConsumeOneShot(); mkFocus();
}
function mkSendCtl(byte) { sendInput(byte); clearMobileMods('ctl'); mkFocus(); }   // ^C etc — a complete action
function mkNav(kind) {
  const mod = mkModParam();
  const arrows = { up: 'A', down: 'B', right: 'C', left: 'D' };
  const tilde = { pgup: '5', pgdn: '6', del: '3' };
  // DECCKM (application cursor keys) ON -> arrows/Home/End use SS3 (ESC O), OFF -> CSI (ESC [).
  // TUIs (claude/vim) turn DECCKM on, so a fixed CSI would break arrows there.
  const ss3 = !!(term.modes && term.modes.applicationCursorKeysMode);
  let seq;
  if (arrows[kind]) seq = mod ? '\x1b[1;' + mod + arrows[kind] : (ss3 ? '\x1bO' + arrows[kind] : '\x1b[' + arrows[kind]);
  else if (kind === 'home') seq = mod ? '\x1b[1;' + mod + 'H' : (ss3 ? '\x1bOH' : '\x1b[H');
  else if (kind === 'end') seq = mod ? '\x1b[1;' + mod + 'F' : (ss3 ? '\x1bOF' : '\x1b[F');
  else if (tilde[kind]) seq = mod ? '\x1b[' + tilde[kind] + ';' + mod + '~' : '\x1b[' + tilde[kind] + '~';
  else return;
  sendInput(seq); mkConsumeOneShot(); mkFocus();
}
function mkPaneNext() {
  const s = currentSession();
  postJson('pane', { session: s, action: 'next' }).then(function (j) { if (j && j.ok) updatePaneZoomBtn(j); }).catch(function () {});
  mkFocus();
}
// open the copy modal — default = tmux clipboard (paste buffer, filled by a drag copy).
// Empty -> fall back to session screen. Buttons inside re-load any source.
function mkSelectText() {
  const sel = (term.getSelection && term.getSelection()) || '';   // if there's a drag selection, take that to the modal (press ⧉ to copy)
  if (sel) { showCopyModal(sel, { session: currentSession(), source: 'selection' }); return; }
  const s = currentSession();
  fetchTmuxBuffer(s).then(function (buf) {
    if (buf) { showCopyModal(buf, { session: s, source: 'clip' }); return; }
    fetchSessionText(s).then(function (r) { showCopyModal(r.text, { session: s, source: r.source }); });
  }).catch(function () { flash('Request failed', 1600); });
}
// 'tmux clipboard' = the tmux paste buffer — a plain drag (tmux mouse) fills it. '' if empty.
function fetchTmuxBuffer(s) {
  return postJson('pane', { session: s, action: 'buffer' })
    .then(function (j) { return (j && j.ok) ? (j.text || '').replace(/\n+$/, '') : ''; });
}
// 'grab session' — Claude Code pane renders the session log conversation, else the screen + 100 lines above.
function fetchSessionText(s) {
  return postJson('pane', { session: s, action: 'capture', lines: 100 }).then(function (j) {
    if (j && j.ok) return { text: (j.text || '').replace(/\n+$/, ''), source: j.source || 'screen' };
    flash('Failed to grab session text' + (j && j.error ? ': ' + j.error : ''), 1800);
    return { text: '', source: 'screen' };
  }).catch(function () { flash('Request failed', 1600); return { text: '', source: 'screen' }; });
}

// Ctrl/Alt button — short tap = ARM toggle / long-press (>=250ms) = HOLD-chain (pointer capture ensures release)
function mkModButton(which, label) {
  const b = mkMakeBtn(label);
  MK.btn[which] = b;
  let holdT = null, didHold = false, pid = null;
  b.addEventListener('pointerdown', function (e) {
    pid = e.pointerId; didHold = false;
    holdT = setTimeout(function () {
      holdT = null;
      if (!MK.active || !b.isConnected) return;   // bar hidden/rebuilding -> don't revive hold
      didHold = true; MK.hold = which; MK.ctrl = false; MK.alt = false;
      clearTimeout(MK.armT); mkPaint(); mkVibrate(15);
      flash((which === 'ctrl' ? 'Ctrl' : 'Alt') + ' held — applies to multiple keys', 1600);
      try { b.setPointerCapture(pid); } catch (_) {}
    }, 250);
  });
  b.addEventListener('pointerup', function () {
    clearTimeout(holdT); holdT = null;
    if (didHold) { MK.hold = null; mkPaint(); hideStatus(); mkFocus(); }
    else { mkToggleMod(which); }
    didHold = false; pid = null;
  });
  b.addEventListener('pointercancel', function () { clearTimeout(holdT); holdT = null; if (didHold && MK.hold === which) { MK.hold = null; mkPaint(); } didHold = false; });
  b.addEventListener('lostpointercapture', function () { if (MK.hold === which) { MK.hold = null; mkPaint(); } });
  return b;
}

// icon button (zoom / more) — inside the bottom bar. handler gets (btn) as anchor.
function mkIconKey(svg, title, handler) {
  const b = document.createElement('button');
  b.className = 'mk-icon';
  b.innerHTML = svg; b.setAttribute('aria-label', title);
  b.addEventListener('pointerdown', function (e) { e.preventDefault(); });
  b.addEventListener('click', function () { handler(b); });
  return b;
}
// bottom bar = one horizontally-scrolling row. Front = most used (zoom -> more -> Esc -> Ctrl -> ^C -> arrows -> …).
// tablet key-bar collapse pref (default = collapsed). '0'=expanded / else(null,'1')=collapsed.
function mkCollapsedPref() { try { return localStorage.getItem('devterm-mkeys-collapsed') !== '0'; } catch (e) { return true; } }
function buildMobileKeys() {
  const host = document.getElementById('mkeys');
  if (!host) return;
  host.textContent = '';
  MK.el = host;
  MK.btn.ctrl = null; MK.btn.alt = null;
  const row = document.createElement('div'); row.className = 'mk-row';
  const add = function (el) { row.appendChild(el); };
  const addKeep = function (el) { el.classList.add('mk-keep'); row.appendChild(el); };   // stays when collapsed: function keys (zoom/select/more/A±), esc, ^end.
  // tablet (wide, top toolbar): many keyboard-substitute keys hide the terminal -> collapse to one button. Tap = expand/collapse (persisted).
  if (mkTopBar()) {   // iPad (incl. mini) / desktop (top bar) = expand/collapse toggle. Phone only = bottom bar (scroll all keys, no toggle).
    const tgl = mkIconKey(ICONS.keyboard, 'Expand / collapse keys', function () {
      const collapsed = appEl.classList.toggle('mkeys-collapsed');
      try { localStorage.setItem('devterm-mkeys-collapsed', collapsed ? '1' : '0'); } catch (e) {}
      tgl.classList.toggle('on', !collapsed);
      mkFocus();
    });
    tgl.classList.add('mk-toggle');
    if (!mkCollapsedPref()) tgl.classList.add('on');
    add(tgl);
  }
  // function buttons (zoom / select / more / tmux / A±) = shared desktop+mobile -> always shown (addKeep).
  paneZoomBtn = mkIconKey(ICONS.paneZoom, 'Zoom pane (current only)', function () { paneZoomToggle(); });
  addKeep(paneZoomBtn);
  const mkCopyBtn = mkIconKey(ICONS.copy, 'Copy — copy modal (screen/selection, clipboard; text/image)', function () { mkSelectText(); });
  mkCopyBtn.classList.add('js-copy-icon');   // pulse target for the copy hint (pulseCopyIcon)
  addKeep(mkCopyBtn);
  // paste = touch-only direct path (soft keyboards / iPhone without Ctrl+V). Same pasteFromClipboard — text = sent, image = uploaded then a [imageNNN](path) token.
  addKeep(mkIconKey(ICONS.paste, 'Paste — clipboard (text/image) straight to the terminal (one tap, no keyboard)', function () { pasteFromClipboard(); }));
  addKeep(mkIconKey(ICONS.grid, 'More (font, theme, upload, annotate, settings, keys)', function (b) { openMobileMenu(b); }));
  addKeep(mkIconKey(ICONS.panes, 'tmux (split, kill pane, scroll)', function (b) { openTmuxMenu(b); }));
  if (FEAT.accounts || FEAT.xai) addKeep(mkIconKey(ICONS.claude, 'Switch account / subscriptions', function (b) { acct.openAcctMenu(b); }));
  addKeep(mkKey('A-', null, function () { stepFontSize(-1); mkFocus(); }));   // one step smaller
  addKeep(mkKey('A+', null, function () { stepFontSize(1); mkFocus(); }));    // one step larger (skips sizes that only thicken)
  addKeep(mkKey('esc', null, function () { sendInput('\x1b'); clearMobileMods('esc'); mkFocus(); }));   // esc — kept when collapsed (no ESC on some keyboards)
  add(mkModButton('ctrl', 'ctrl'));
  add(mkKey('^c', 'mk-mono', function () { mkSendCtl('\x03'); }));
  addKeep(mkKey('^end', 'mk-mono', function () { sendInput('\x1b[1;5F'); mkConsumeOneShot(); mkFocus(); }));   // ^end — kept when collapsed (common)
  add(mkKey('←', null, function () { mkNav('left'); }));
  add(mkKey('↓', null, function () { mkNav('down'); }));
  add(mkKey('↑', null, function () { mkNav('up'); }));
  add(mkKey('→', null, function () { mkNav('right'); }));
  add(mkKey('tab', null, function () { sendInput('\t'); mkConsumeOneShot(); mkFocus(); }));
  add(mkModButton('alt', 'alt'));
  add(mkKey('⏎', null, function () { sendInput('\r'); mkConsumeOneShot(); mkFocus(); }));
  [['^d', '\x04'], ['^l', '\x0c'], ['^r', '\x12'], ['^u', '\x15'], ['^w', '\x17'], ['^a', '\x01'], ['^e', '\x05'], ['^z', '\x1a'], ['^k', '\x0b']]
    .forEach(function (p) { add(mkKey(p[0], 'mk-mono', function () { mkSendCtl(p[1]); })); });
  ['/', '|', '~', '-', '_', ':', '$'].forEach(function (ch) { add(mkKey(ch, 'mk-mono', function () { mkSendLit(ch); })); });
  [['home', 'home'], ['end', 'end'], ['pgup', 'pgup'], ['pgdn', 'pgdn'], ['del', 'del']]
    .forEach(function (p) { add(mkKey(p[0], null, function () { mkNav(p[1]); })); });
  add(mkKey('pane', null, mkPaneNext));
  host.appendChild(row);
}

// toggle bar visibility — reset coords -> toggle class -> fit after double-rAF (final dims, no stale rows)
function setMobileKeysVisible(on) {
  MK.active = on;
  clearMobileMods('visibility');
  touchY = null; touchAcc = 0;
  appEl.classList.toggle('mkeys-on', on);
  // iPad (incl. mini) docks the bar under the top tabs (toolbar). Phone keeps it at the bottom.
  const top = on && mkTopBar();
  appEl.classList.toggle('mkeys-top', top);
  appEl.classList.toggle('mkeys-collapsed', top && mkCollapsedPref());   // tablet top bar = collapsed by default
  requestAnimationFrame(function () { requestAnimationFrame(function () { fitResize(); }); });
}

// ---- pane-zoom top button (live state; remote sessions inactive) ----
let paneZoomBtn = null;
let paneZoomed = false, panePanes = 0;   // live zoom / pane count (mobile horizontal-swipe arming)
function updatePaneZoomBtn(state) {
  if (!paneZoomBtn) return;
  paneZoomed = !!(state && state.zoomed);
  panePanes = (state && state.panes) || 0;
  paneZoomBtn.style.display = '';
  const zoomed = paneZoomed;
  paneZoomBtn.innerHTML = zoomed ? ICONS.paneUnzoom : ICONS.paneZoom;
  paneZoomBtn.classList.toggle('on', zoomed);
  paneZoomBtn.setAttribute('aria-label', zoomed ? 'Unzoom pane (restore split)' : 'Zoom pane (current only)');
}
function paneZoomToggle() {
  const s = currentSession();
  postJson('pane', { session: s, action: 'zoom' }).then(function (j) {
    if (j && j.ok) { updatePaneZoomBtn(j); flash(j.zoomed ? 'Zoomed — current pane only' : 'Restored split', 1400); }
    else flash('Zoom failed' + (j && j.error ? ': ' + j.error : ''), 1800);
  }).catch(function () { flash('pane request failed', 1600); });
}
// mobile horizontal swipe -> move zoom to the adjacent pane (cyclic). next=true -> right / false -> left.
function paneZoomSwipe(next) {
  const s = currentSession();
  mkVibrate(15);
  postJson('pane', { session: s, action: next ? 'zoom-next' : 'zoom-prev' }).then(function (j) {
    if (j && j.ok) updatePaneZoomBtn(j);
  }).catch(function () {});
}
function maybePaneHint(state) {
  if (!MK.active || !state || (state.panes || 0) <= 1) return;
  try { if (localStorage.getItem('devterm-panehint')) return; localStorage.setItem('devterm-panehint', '1'); } catch (e) {}
  flash('If a split is small, use the zoom button to enlarge the current pane', 4200);
}
function refreshPaneZoom() {
  if (!paneZoomBtn) return;
  const s = currentSession();
  postJson('pane', { session: s, action: 'state' }).then(function (j) { if (j && j.ok) { updatePaneZoomBtn(j); maybePaneHint(j); } }).catch(function () {});
}

// ---- mobile overflow (more) menu (utilities + key-bar pref) ----
function openMobileMenu(anchor) {
  closeTabPops();
  const pop = document.createElement('div'); pop.className = 'tab-pop';
  const item = function (label, fn) { const b = document.createElement('button'); b.textContent = label; b.onclick = function () { closeTabPops(); fn(anchor); }; pop.appendChild(b); };
  item('Font size', function (a) { openFontPopover(a); });
  item('Theme', openThemePicker);
  item('Upload file', pickAndUploadFile);
  item('Secret drop', openSecretDrop);
  item('Annotate image', openImageAnnotator);
  if (FEAT.orca) item('Settings (layout, agents)', function () { openSettings(); });
  const sep = document.createElement('div'); sep.className = 'sep'; pop.appendChild(sep);
  const hd = document.createElement('div'); hd.className = 'hd'; hd.textContent = 'Mobile keys'; pop.appendChild(hd);
  [['auto', 'Auto'], ['on', 'On'], ['off', 'Off']].forEach(function (o) {
    const b = document.createElement('button');
    b.textContent = (mkPref() === o[0] ? '✓ ' : '  ') + o[1];
    b.onclick = function () { closeTabPops(); mkSetPref(o[0]); applyMobileKeys(); };
    pop.appendChild(b);
  });
  const r = anchor.getBoundingClientRect();
  placePop(pop, r.right - 224, r.bottom + 6);
}

// shared pane op (split/kill) — after /pane, refresh zoom/panes. Surface failures.
function paneAction(action) {
  const s = currentSession();
  postJson('pane', { session: s, action: action }).then(function (j) {
    if (j && j.ok) { updatePaneZoomBtn(j); mkFocus(); }
    else flash('tmux action failed' + (j && j.error ? ': ' + j.error : ''), 1800);
  }).catch(function () { flash('pane request failed', 1600); });
}

// ---- mobile tmux menu (split left-right / top-bottom, kill pane, scroll) ----
// scroll = send PageUp/PageDown keys. alt-screen apps (claude) scroll their own transcript (documented).
function openTmuxMenu(anchor) {
  closeTabPops();
  const pop = document.createElement('div'); pop.className = 'tab-pop';
  const item = function (label, fn, cls) {
    const b = document.createElement('button'); b.textContent = label; if (cls) b.className = cls;
    b.onclick = function () { closeTabPops(); fn(); }; pop.appendChild(b);
  };
  // scroll items keep the menu open (repeat tap) + keep terminal focus (pointerdown preventDefault).
  const scrollItem = function (label, seq) {
    const b = document.createElement('button'); b.textContent = label;
    b.addEventListener('pointerdown', function (e) { e.preventDefault(); });
    b.onclick = function () { sendInput(seq); mkFocus(); }; pop.appendChild(b);
  };
  item('Split left/right (│)', function () { paneAction('split-h'); });
  item('Split top/bottom (─)', function () { paneAction('split-v'); });
  item('Equal widths (↔)', equalizeLayout);
  const sep = document.createElement('div'); sep.className = 'sep'; pop.appendChild(sep);
  scrollItem('▲ Scroll up', '\x1b[5~');
  scrollItem('▼ Scroll down', '\x1b[6~');
  const sep2 = document.createElement('div'); sep2.className = 'sep'; pop.appendChild(sep2);
  item('Close this pane (kill)', function () {
    if (confirm('Close the current pane? Its running processes will be terminated.\n(If it is the last pane, the session ends too.) Continue?')) paneAction('kill');
  }, 'danger');
  const r = anchor.getBoundingClientRect();
  placePop(pop, r.left, r.bottom + 6);
}

// ---- Claude account switch — code lives in accounts.js (DI boundary). Wire it here. ----
// If accounts.js fails to load, the terminal still works (no-op fallback).
acct = (window.initAccounts || function () { const n = function () {}; return { openAcctMenu: n, applyAcctIconCls: n, startAcctIconWatch: n, hideAcctTip: n }; })({ flash: flash, postJson: postJson, mkFocus: mkFocus, closeTabPops: closeTabPops, placePop: placePop });

// ---- secret drop (value -> a file on this box -> the terminal gets only a path token) ----
// The implementation is secretdrop.js (window.initSecretDrop): the Airlock widget shows
// the very same UI through panel.html, so only devterm's circumstances are injected here
// (delivery into the terminal, and reaching the right box for a remote session).
const secretUI = (window.initSecretDrop || function () {
  return { openSecretDrop: function () { flash('Secret drop unavailable — secretdrop.js not loaded', 3000, 'error'); } };
})({
  flash: flash, postJson: postJson,
  sendInput: sendInput,
  // A remote (*) session's agent runs on another host, so the token has to say how to
  // read this box's file — the same rule the upload token already follows.
  tokenTarget: function (path) {
    return parseRemote(currentSession()) ? ('ssh ' + uploadHost() + ' cat ' + path) : path;
  },
  readCmd: function (path) {
    return parseRemote(currentSession()) ? ('ssh ' + uploadHost() + ' cat ' + path) : ('cat ' + path);
  },
});
if (!window.initSecretDrop) console.warn('[devterm] secretdrop.js not loaded — secret drop disabled (the terminal is unaffected)');
function openSecretDrop() { secretUI.openSecretDrop(); }   // declaration: hoisted for the menu above
if (!window.initAccounts) console.warn('[devterm] accounts.js not loaded — account UI disabled (terminal still works)');

// activate (capability + pref) — build/show bar + rebuild top controls. Re-run on matchMedia change.
function applyMobileKeys() {
  const show = mkShouldShow();
  if (show) buildMobileKeys();          // always rebuild (refresh paneZoomBtn ref; safe on desktop<->mobile switch)
  setMobileKeysVisible(show);
  buildControls();
  refreshPaneZoom();
}

// ---- WS / ttyd protocol ----
let ws = null, connected = false, connecting = false, reconnectTimer = null, token = '', reconnectAttempts = 0;
let switching = false;   // reconnecting due to a session switch (suppresses the connect toast)
let pendingAgentCmd = null;   // agent launcher: CLI to run after a new session connects (consumed once in onopen)
let _openingSn = null, _openingT = null;   // 'opening session' state — held until real output (onMsg) for instant feedback
let _dimT = null;
// avoid the old screen looking frozen during the switch/reconnect gap — dim+spinner over #term (cleared on first output or after 6s).
function showTermDim() { clearTimeout(_dimT); const d = document.getElementById('termdim'); if (!d) return; _dimT = setTimeout(() => { d.hidden = false; setTimeout(hideTermDim, 6000); }, 140); }
function hideTermDim() { clearTimeout(_dimT); const d = document.getElementById('termdim'); if (d) d.hidden = true; }

function sendInput(str) {
  if (connected) { try { ws.send(enc('0' + str)); } catch (e) {} }
}
function sendResize() {
  if (connected) {
    try { ws.send(enc('1' + JSON.stringify({ columns: term.cols, rows: term.rows }))); } catch (e) {}
  }
}
function onMsg(ev) {
  const data = ev.data;
  if (typeof data === 'string') return;
  const arr = new Uint8Array(data);
  if (arr.length === 0) return;
  const cmd = arr[0];
  const body = arr.subarray(1);
  if (cmd === 48) {                                          // '0' OUTPUT
    if (_openingSn) { _openingSn = null; clearTimeout(_openingT); hideStatus(); }   // first output = session is up -> clear 'opening'
    hideTermDim();                                           // first output = screen is up -> clear dim
    term.write(body);
  }
  // cmd 49 (SET_WINDOW_TITLE) ignored — the tab title is fixed to 'dev-term'(+session)
}
function setTitle() {
  const s = currentSession();
  document.title = 'dev-term' + (s && s !== 'main' ? ' · ' + s : '');
}
setTitle();

let connectSeq = 0;   // connect() epoch — even if switchSession resets connecting, an old connect can't create a WS (no double WS)
async function connect() {
  // connecting flag (sync) — avoids a race where another connect() slips through during await fetch and makes 2 WS (double input).
  if (connecting) return;
  if (ws && (ws.readyState === WebSocket.CONNECTING || ws.readyState === WebSocket.OPEN)) return;
  connecting = true;
  const mySeq = ++connectSeq;
  clearTimeout(reconnectTimer);
  if (!switching) showStatus('Connecting…');   // session-switch reconnect is instant -> suppress toast (no flicker)
  try {
    const r = await fetch('token' + location.search, { cache: 'no-store' });
    token = (await r.json()).token || '';
  } catch (e) { token = ''; }
  if (mySeq !== connectSeq) return;   // a newer connect() started during await -> this one won't make a WS
  try {
    // wss only — the page is always loaded over TLS (plaintext ports just 301),
    // so a ws:// fallback could only ever downgrade a terminal session.
    ws = new WebSocket('wss://' + location.host + '/ws' + location.search, ['tty']);
  } catch (e) { connecting = false; scheduleReconnect(); return; }
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => {
    connecting = false; connected = true; switching = false; reconnectAttempts = 0;   // success -> reset backoff
    if (!_openingSn) hideStatus();   // hold 'opening' until real output -> no blank screen during agent boot
    try { ws.send(enc(JSON.stringify({ AuthToken: token, columns: term.cols, rows: term.rows }))); } catch (e) {}
    term.focus();
    if (pendingAgentCmd) {   // new agent session — run the CLI once the shell prompt is up (once)
      const c = pendingAgentCmd; pendingAgentCmd = null;
      setTimeout(() => { if (connected) sendInput(c + '\r'); }, 350);
    }
  };
  ws.onmessage = onMsg;
  ws.onclose = () => { switching = false; connecting = false; connected = false; scheduleReconnect(); };
  ws.onerror = () => { try { ws.close(); } catch (e) {} };
}
function scheduleReconnect() {
  clearMobileMods('reconnect');
  clearTimeout(reconnectTimer);
  // no flicker: first reconnect is quick (200ms) and the 'reconnecting' toast is hidden for short blips.
  // Backoff (200/400/800/1600/3200/4000ms); surface the toast only after ~1.4s of failure.
  const delay = Math.min(200 * (1 << Math.min(reconnectAttempts, 5)), 4000);
  reconnectAttempts += 1;
  if (reconnectAttempts >= 4) showStatus('Reconnecting…');
  reconnectTimer = setTimeout(connect, delay);
}

term.onData(sendInput);

// ---- session tabs (live tmux sessions) ----
const namesEl = document.getElementById('tabnames');   // left: session tabs + … + new + refresh
const ctrlsEl = document.getElementById('tabctrls');   // right: copy / A- / A+ / clip
const MAX_VISIBLE_TABS = 9;
const sidebarEl = document.getElementById('sidebar');   // experimental layout: left shell-session list
const DEFAULT_AGENTS = [{ label: 'Claude', cmd: 'claude' }, { label: 'Codex', cmd: 'codex' }];
// agent label -> tmux session name (slug). Same rule as devterm-shell ([^A-Za-z0-9_-]->_) so the front slug == the real name.
function agentSlug(label) { const s = String(label || '').replace(/[^A-Za-z0-9_-]/g, '_'); return s || 'agent'; }
function isCompact() { return matchMedia('(max-width:820px),(max-height:520px)').matches; }
function mkTopBar() { return IS_IPAD || !isCompact(); }   // top bar = all iPads (incl. mini) + desktop. Phone only = bottom
// The experimental sidebar (Orca worktree tree) is only for wide screens + Orca running.
function effectiveLayout() { return document.getElementById('app').classList.contains('sidebar-on') ? 'sidebar' : 'tabs'; }

// tab prefs persistence (order / hidden / color / theme) — localStorage cache + server (tabs.json) source of truth.
let tabPrefs = (() => { try { return JSON.parse(localStorage.getItem(TABS_KEY)) || {}; } catch (e) { return {}; } })();
// normalize types — a corrupt/old localStorage must not break boot in mergedOrder's .filter (same guard as the server load path).
tabPrefs.order = Array.isArray(tabPrefs.order) ? tabPrefs.order : [];
tabPrefs.hidden = Array.isArray(tabPrefs.hidden) ? tabPrefs.hidden : [];
tabPrefs.colors = (tabPrefs.colors && typeof tabPrefs.colors === 'object') ? tabPrefs.colors : {};
tabPrefs.theme = THEMES[tabPrefs.theme] ? tabPrefs.theme : DEFAULT_THEME;
tabPrefs.layout = tabPrefs.layout === 'sidebar' ? 'sidebar' : 'tabs';                        // experimental layout (default tabs)
tabPrefs.agents = Array.isArray(tabPrefs.agents) ? tabPrefs.agents : DEFAULT_AGENTS.slice();  // top agent-launcher list
// localStorage = instant cache / server (~/.config/airlock-devterm/tabs.json) = unified source of truth
let _prefsSaveTimer = null;
function saveTabPrefs(immediate) {
  try { localStorage.setItem(TABS_KEY, JSON.stringify(tabPrefs)); } catch (e) {}
  clearTimeout(_prefsSaveTimer);
  const post = () => fetch('tab-prefs', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(tabPrefs) }).catch(() => {});
  // theme etc use immediate=true so a reconnect during the 400ms debounce doesn't let the server keep the old value and clobber the local new one on reload. Only drag-order/color debounce.
  if (immediate) post();
  else _prefsSaveTimer = setTimeout(post, 400);
}
// on start, load server prefs -> take precedence over local (unified). Live-session reconciliation is renderTabs' mergedOrder.
(function loadServerPrefs() {
  fetch('tab-prefs', { cache: 'no-store' }).then((r) => r.json()).then((sp) => {
    if (!sp || typeof sp !== 'object') return;
    if (Array.isArray(sp.order)) tabPrefs.order = sp.order;
    if (Array.isArray(sp.hidden)) tabPrefs.hidden = sp.hidden;
    if (sp.colors && typeof sp.colors === 'object') tabPrefs.colors = sp.colors;
    if (sp.layout === 'sidebar' || sp.layout === 'tabs') tabPrefs.layout = sp.layout;   // server = source of truth (cross-device)
    if (Array.isArray(sp.agents)) tabPrefs.agents = sp.agents;
    if (THEMES[sp.theme] && sp.theme !== tabPrefs.theme) {   // server theme = source of truth -> apply (reflects changes from other devices)
      tabPrefs.theme = sp.theme;
      term.options.theme = THEMES[sp.theme].xterm;
      const el = document.getElementById('term'); if (el) el.style.background = THEMES[sp.theme].xterm.background;
    }
    try { localStorage.setItem(TABS_KEY, JSON.stringify(tabPrefs)); } catch (e) {}
    applyLayout();   // apply server prefs to layout class + re-render (internal loadSessions)
  }).catch(() => {});
})();

function switchTo(name) {
  if (!name || name === currentSession()) return;
  history.replaceState(null, '', location.pathname + '?arg=' + encodeURIComponent(name));   // update URL only (survives refresh)
  switchSession();
}
// reconnect the WS to a new session without a full page reload (no flicker). Clear the screen, re-attach tmux.
function switchSession() {
  // no reset: leave the previous frame, and let tmux re-attach's full redraw (erase-to-EOL each row) overwrite it -> no dark flash / buffer-switch bounce.
  switching = true;   // suppress the 'Connecting…' toast for this reconnect
  showTermDim();      // cover the frozen old screen during the switch/reconnect gap (cleared on first output)
  if (orcaTree) { const _wp = currentWtPath(); if (_wp) selectedWtPath = _wp; }   // keep the sidebar selection following the current session's worktree
  clearMobileMods('switch');
  if (ws) { try { ws.onclose = null; ws.onmessage = null; ws.close(); } catch (e) {} }
  ws = null; connected = false; connecting = false;
  clearTimeout(reconnectTimer);
  connect();
  loadSessions();     // refresh tab highlight (current)
  // a new session is created by tmux after the WS connects, so it may not be in /sessions yet -> re-poll briefly.
  setTimeout(loadSessions, 250); setTimeout(loadSessions, 700); setTimeout(loadSessions, 1500);
  refreshPaneZoom();  // pane zoom is per-session -> re-query on switch
}

// on entry, pick the session — explicit ?arg wins. Otherwise attach to the most-recently-active LOCAL session (don't force main). Create the default (main) only if there are no local sessions.
function initSession() {
  if (new URLSearchParams(location.search).get('arg')) { connect(); return; }
  fetch('sessions', { cache: 'no-store' }).then((r) => r.json()).then((s) => {
    const locals = (s.sessions || []).filter((x) => !x.host);
    if (locals.length) {
      locals.sort((a, b) => (b.activity || 0) - (a.activity || 0));
      history.replaceState(null, '', location.pathname + '?arg=' + encodeURIComponent(locals[0].name));
      setTitle();
    }
    connect();
  }).catch(() => connect());
}

// Shared UI primitives (modal tone + clipboard copy) live in ui.js, which is also
// loaded by panel.html — a page with no terminal. Only the post-copy focus target
// differs per page, so app.js supplies it through the uiRefocus hook.
window.uiRefocus = function () { if (typeof term !== 'undefined' && term) term.focus(); };

// ---- source-button badge — shows at a glance which source has content. Empty = disabled (grey).
//   state.kind: checking | text(n) | image | empty | unknown (unknown -> no badge, active)
function fmtChars(n) { return (n >= 10000 ? Math.round(n / 1000) + 'k' : n >= 1000 ? (n / 1000).toFixed(1) + 'k' : String(n)) + ' chars'; }
function bufState(buf) { return buf ? { kind: 'text', n: buf.length } : { kind: 'empty' }; }
function srcBadge(btn, base, state) {
  const k = (state && state.kind) || 'unknown';
  btn.textContent = base;
  btn.disabled = (k === 'empty');
  if (k === 'unknown') return;
  const s = document.createElement('span');
  s.style.cssText = 'margin-left:6px;font-size:11.5px;opacity:.72;';
  s.textContent = k === 'checking' ? 'checking' : k === 'empty' ? 'empty' : k === 'image' ? 'image' : fmtChars(state.n);
  btn.appendChild(s);
}
// probe the local clipboard — only read quietly when permission is already granted (don't
//   trigger a permission prompt when the modal opens). Unknown -> no badge, stays active.
function probeLocalClip() {
  const un = { kind: 'unknown' };
  if (!(window.isSecureContext && navigator.clipboard)) return Promise.resolve(un);
  const q = (navigator.permissions && navigator.permissions.query)
    ? navigator.permissions.query({ name: 'clipboard-read' }).catch(function () { return null; })
    : Promise.resolve(null);
  return q.then(function (st) {
    if (!st || st.state !== 'granted') return un;
    if (navigator.clipboard.read) {
      return navigator.clipboard.read().then(function (items) {
        for (const it of items) {
          if (it.types.some(function (t) { return t.indexOf('image/') === 0; })) return { kind: 'image' };
        }
        const ti = items.find(function (it) { return it.types.includes('text/plain'); });
        if (!ti) return { kind: 'empty' };
        return ti.getType('text/plain').then(function (b) { return b.text(); })
          .then(function (t) { return t ? { kind: 'text', n: t.length } : { kind: 'empty' }; });
      }, function () { return un; });
    }
    if (!navigator.clipboard.readText) return un;
    return navigator.clipboard.readText().then(function (t) { return t ? { kind: 'text', n: t.length } : { kind: 'empty' }; },
                                              function () { return un; });
  }).catch(function () { return un; });
}

// copy modal — text into a fully-selected textarea. Cmd/Ctrl+C or [Copy] (execCommand) copies on every browser + HTTP/HTTPS.
function showCopyModal(text, opts) {
  opts = opts || {};
  const { ov, box } = makeModal(20, 'padding:14px;max-width:680px;width:100%;');
  const ta = document.createElement('textarea'); ta.value = text || ''; ta.readOnly = true;   // read-only = no iOS keyboard
  // iOS sometimes blocks touch-selecting a readOnly textarea -> allow it explicitly.
  ta.style.cssText = 'width:100%;height:42vh;box-sizing:border-box;' + UI_FIELD + 'padding:10px;font:13px/1.5 ui-monospace,monospace;resize:none;-webkit-user-select:text;user-select:text;-webkit-touch-callout:default;';
  const row = document.createElement('div'); row.style.cssText = 'display:flex;flex-wrap:wrap;gap:8px;margin-top:10px;align-items:center;';
  const srcLabel = function (src) {
    return src === 'claude-log' ? 'Claude session log (recent)'
         : src === 'screen' || src === 'session' ? 'Session screen'
         : src === 'selection' ? 'Drag selection'
         : 'tmux clipboard';
  };
  const infoText = function (src, sel) {
    return srcLabel(src) + ' · ' + (sel ? 'all selected' : 'drag to select') + ' · Cmd/Ctrl+C or [Copy]';
  };
  const isClip = opts.source === 'clip' || opts.source === 'selection';   // tmux clipboard / drag selection = select all. Session grab = user chooses.
  const info = document.createElement('div'); info.textContent = infoText(opts.source, isClip);
  info.style.cssText = 'flex:1;min-width:140px;color:#8a92a6;font:12.5px system-ui;';
  // always jump to the bottom (most recent = what was on screen). sel=true selects all, false = cursor at end.
  const place = function (sel) {
    ta.focus();
    if (sel) ta.select(); else ta.setSelectionRange(ta.value.length, ta.value.length);
    ta.scrollTop = ta.scrollHeight;
  };
  const copyBtn = uiBtn('Copy to clipboard', 'primary');
  const close = () => { try { document.body.removeChild(ov); } catch (e) {} term.focus(); };
  // close = top-right X
  box.style.position = 'relative';
  const xBtn = document.createElement('button');
  xBtn.textContent = '✕'; xBtn.setAttribute('aria-label', 'Close');
  xBtn.style.cssText = 'position:absolute;top:6px;right:8px;background:none;border:0;color:#9aa3b2;font:20px/1 system-ui;cursor:pointer;padding:4px 8px;';
  xBtn.onclick = close; box.appendChild(xBtn);
  // iOS: a button tap blurs the textarea and drops the user's partial selection (all-copy symptom).
  //   Snapshot the selection on pointerdown; on secure context, writeText the substring directly.
  let _pickSel = null;
  copyBtn.addEventListener('pointerdown', function () { _pickSel = [ta.selectionStart, ta.selectionEnd]; });
  copyBtn.onclick = async () => {
    let a = ta.selectionStart, b = ta.selectionEnd;
    if (a === b && _pickSel && _pickSel[1] > _pickSel[0]) { a = _pickSel[0]; b = _pickSel[1]; }   // tap dropped the selection -> restore snapshot
    if (a === b) { a = 0; b = ta.value.length; }                                                   // no selection = all
    const selText = ta.value.substring(a, b);
    let ok = false;
    if (window.isSecureContext && navigator.clipboard && navigator.clipboard.writeText) {
      try { await navigator.clipboard.writeText(selText); ok = true; } catch (e) {}                // https = the sure path on iOS
    }
    if (!ok) { try { ta.focus(); ta.setSelectionRange(a, b); ok = document.execCommand('copy'); } catch (e) {} }  // http fallback
    if (ok) { flash('Copied ' + selText.length + ' chars — paste with Cmd+V', 1600); close(); }
    else flash('Copy failed — long-press to select, then copy', 2500);
  };
  ov.onclick = (e) => { if (e.target === ov) close(); };
  row.appendChild(info);
  if (opts.session) {
    // 'tmux clipboard' — reload what was just drag-copied (paste buffer). Explicit button, not auto.
    const clipBtn = uiBtn('tmux clipboard', 'ghost');
    srcBadge(clipBtn, 'tmux clipboard', { kind: 'checking' });        // query on open -> soon shows '342 chars' / 'empty'
    fetchTmuxBuffer(opts.session)
      .then(function (buf) { srcBadge(clipBtn, 'tmux clipboard', bufState(buf)); })
      .catch(function () { srcBadge(clipBtn, 'tmux clipboard', { kind: 'unknown' }); });   // query fail = unknown (stays active)
    clipBtn.onclick = function () {
      fetchTmuxBuffer(opts.session).then(function (buf) {
        srcBadge(clipBtn, 'tmux clipboard', bufState(buf));
        if (!buf) { flash('tmux clipboard is empty — drag in the terminal to copy', 2200); return; }
        ta.value = buf; info.textContent = infoText('clip', true);
        place(true);   // a fresh drag = likely used whole -> select all
      }).catch(function () { flash('Request failed', 1600); });
    };
    row.appendChild(clipBtn);
    // 'tmux session' — Claude pane = session-log conversation, else screen + 100 lines above.
    const grabBtn = uiBtn('tmux session', 'ghost');
    grabBtn.onclick = function () {
      fetchSessionText(opts.session).then(function (r) {
        ta.value = r.text; info.textContent = infoText(r.source, false);
        place(false);   // session grab = no auto select-all, jump to bottom
      });
    };
    row.appendChild(grabBtn);
  }
  const pasteBtn = uiBtn('Local clipboard', 'ghost');   // local clipboard (text/image) -> insert into this modal's textarea.
  probeLocalClip().then(function (n) { srcBadge(pasteBtn, 'Local clipboard', n); });   // char count / disabled only when permission is granted
  // clipboard -> insert into THIS modal's textarea (at the cursor), not the terminal.
  //   text = as-is / image = uploaded then a [imageNNN](path) token. Modal stays open.
  pasteBtn.onclick = async function () {
    const insertTa = function (s) {
      const a = ta.selectionStart, b = ta.selectionEnd;
      ta.value = ta.value.slice(0, a) + s + ta.value.slice(b);
      const pos = a + s.length; ta.focus(); ta.setSelectionRange(pos, pos); ta.scrollTop = ta.scrollHeight;
    };
    const tryText = async function () {   // readText fallback (iOS is sometimes more permissive than read())
      if (!(navigator.clipboard && navigator.clipboard.readText)) return false;
      const t = await navigator.clipboard.readText(); if (t) { insertTa(t); return true; } return false;
    };
    try {
      if (navigator.clipboard && navigator.clipboard.read && window.isSecureContext) {
        let items;
        try { items = await navigator.clipboard.read(); }
        catch (e1) { if (await tryText()) return; throw e1; }        // read() blocked (iOS) -> at least readText
        for (const it of items) {                                    // image first -> upload then insert token
          const imgType = it.types.find(function (t) { return t.indexOf('image/') === 0; });
          if (imgType) {
            showStatus('Uploading image…');
            try {
              const res = await postJson('upload-image', { image: await blobToJpeg(await it.getType(imgType)) });
              hideStatus();
              if (res.ok) insertTa(uploadTokenStr('image', res.n, res.path));
              else flash('Upload failed: ' + (res.error || ''), 2500);
            } catch (e) { hideStatus(); flash('Upload error', 2500); }
            return;
          }
        }
        for (const it of items) {                                    // text
          if (it.types.includes('text/plain')) { const t = await (await it.getType('text/plain')).text(); if (t) insertTa(t); return; }
        }
        if (await tryText()) return;                                 // read succeeded but nothing found -> retry readText
        flash('Nothing to paste from the clipboard', 1400);
      } else if (navigator.clipboard && navigator.clipboard.readText) {
        if (!(await tryText())) flash('Clipboard is empty', 1400);
      } else flash('This browser lacks clipboard-button support — use Cmd+V', 2200);
    } catch (e) {   // show the real error name (iOS root-cause) — NotAllowedError=permission, else unsupported
      flash('Paste failed: ' + ((e && e.name) || '?') + ((e && e.message) ? ' — ' + e.message : '') + ' · try Cmd+V', 3500);
    }
  };
  row.appendChild(pasteBtn); row.appendChild(copyBtn);
  box.appendChild(ta); box.appendChild(row);
  ov.appendChild(box); document.body.appendChild(ov);
  setTimeout(function () { place(isClip); }, 0);   // clip=select all / session,claude-log=cursor only
}

// font size — safe range (8..28), remembered in localStorage.
const FONT_MIN = 8, FONT_MAX = 28;
// measure char height like xterm's CharSizeService (span "W"x32 offsetHeight = integer CSS px). Used for the size ladder.
let _measSpan = null;
function charHeightPx(px) {
  if (!_measSpan) {
    _measSpan = document.createElement('span');
    _measSpan.setAttribute('aria-hidden', 'true');
    _measSpan.style.cssText = 'position:absolute;left:-9999px;top:0;white-space:pre;font-kerning:none;font-family:' + term.options.fontFamily + ';';
    _measSpan.textContent = 'W'.repeat(32);
    document.body.appendChild(_measSpan);
  }
  _measSpan.style.fontSize = px + 'px';
  return _measSpan.offsetHeight;
}
// Wide line spacing but crisp glyphs — snap the cell height (css.cell.height) to an
// integer CSS px, else rows drift off the pixel grid and blur toward the bottom (a
// high-DPI DOM-renderer artifact). See the original design notes for the derivation.
const LINE_LEADING = 1.18;   // desired leading (~18%) — snapped to a dpr multiple below for wide + crisp.
let _lhKey = '';
function applyLineHeight() {
  const rows = document.querySelector('.xterm-rows');
  if (!rows || rows.children.length < 2) return;              // WebGL(canvas)/unrendered = no-op (already crisp there)
  const dpr = window.devicePixelRatio || 1;
  const key = term.options.fontSize + '/' + dpr;
  if (key === _lhKey) return;                                 // this size+dpr already tuned (avoid recompute per output)
  const cellCss = rows.children[1].getBoundingClientRect().top - rows.children[0].getBoundingClientRect().top;
  if (!(cellCss > 0)) return;
  const curLh = term.options.lineHeight || 1;
  const cellDevNow = Math.round(cellCss * dpr);              // xterm's actual device.cell.height (integer)
  // back out device.char: cellDevNow = floor(device.char x curLh). round can be off by 1 -> pin the exact integer c satisfying floor(c x curLh)===cellDevNow.
  let charDev = Math.round(cellDevNow / curLh);
  for (const c of [charDev, charDev + 1, charDev - 1]) {
    if (c > 0 && Math.floor(c * curLh) === cellDevNow) { charDev = c; break; }
  }
  if (!(charDev > 0)) return;
  let cellDev = Math.round(charDev * LINE_LEADING);
  cellDev = Math.round(cellDev / dpr) * dpr;                  // dpr multiple -> integer css.cell (grid aligned)
  if (cellDev < charDev) cellDev = Math.ceil(charDev / dpr) * dpr;
  const lh = Math.round(((cellDev + 0.5) / charDev) * 10000) / 10000;   // floor(charDev x lh)===cellDev
  _lhKey = key;                                              // set before applying (re-entry guard)
  if (Math.abs(lh - curLh) > 0.0005) {
    term.options.lineHeight = lh;
    try { fit.fit(); sendResize(); } catch (e) {}
  }
}
term.onRender(function () { applyLineHeight(); });
function setFontSize(px) {
  px = Math.max(FONT_MIN, Math.min(FONT_MAX, Math.round(px)));
  if (px === term.options.fontSize) return;
  term.options.fontSize = px;
  try { localStorage.setItem('devterm-fontsize', String(px)); } catch (e) {}
  try { fit.fit(); } catch (e) {}
  sendResize();
  // line-spacing re-alignment is handled by onRender(applyLineHeight) after the new size renders.
}
// size 'step' ladder — keep only sizes that actually grow the row height (not every px).
// If two adjacent sizes round to the same offsetHeight, stepping between them wouldn't grow
// the row (glyphs just get denser, looking 'thicker'). A+/A- skip those. Self-corrects per device/font.
let _fontLadder = null;
function fontLadder() {
  if (_fontLadder) return _fontLadder;
  const rungs = []; let last = -1;
  for (let px = FONT_MIN; px <= FONT_MAX; px++) {
    const h = charHeightPx(px);
    if (h !== last) { rungs.push(px); last = h; }
  }
  _fontLadder = rungs.length ? rungs : [FONT_MIN, FONT_MAX];
  return _fontLadder;
}
// one step larger (dir>0) / smaller — the first rung above/below current (skips thickening sizes).
function stepFontSize(dir) {
  const ladder = fontLadder(), cur = term.options.fontSize;
  let next = null;
  if (dir > 0) { for (let i = 0; i < ladder.length; i++) if (ladder[i] > cur) { next = ladder[i]; break; } if (next == null) next = ladder[ladder.length - 1]; }
  else { for (let i = ladder.length - 1; i >= 0; i--) if (ladder[i] < cur) { next = ladder[i]; break; } if (next == null) next = ladder[0]; }
  setFontSize(next);
  return next;
}
(function applySavedFont() {
  let px = parseInt((() => { try { return localStorage.getItem('devterm-fontsize'); } catch (e) { return null; } })(), 10);
  if (px >= FONT_MIN && px <= FONT_MAX) {
    const ladder = fontLadder();
    if (ladder.indexOf(px) < 0) {   // saved value is a thickening size -> snap to the nearest rung that grows
      px = ladder.reduce((a, b) => (Math.abs(b - px) < Math.abs(a - px) ? b : a), ladder[0]);
      try { localStorage.setItem('devterm-fontsize', String(px)); } catch (e) {}
    }
    term.options.fontSize = px;
  }
  try { fit.fit(); } catch (e) {}   // crispness correction happens on first render via onRender(applyLineHeight)
})();

// line icons (SVG stroke=currentColor)
const ICONS = {
  copy: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/></svg>',
  paste: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="8" y="2" width="8" height="4" rx="1.4"/><path d="M16 4h2a2 2 0 0 1 2 2v13a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/></svg>',
  fontDown: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 18L8 6l5 12M4.9 14h6.2"/><path d="M16 12h5"/></svg>',
  fontUp: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 18L8 6l5 12M4.9 14h6.2"/><path d="M18.5 9.5v5M16 12h5"/></svg>',
  clip: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M21 11.4l-8.6 8.6a5.2 5.2 0 0 1-7.4-7.4l8.6-8.6a3.4 3.4 0 0 1 4.9 4.9l-8.6 8.6a1.7 1.7 0 0 1-2.4-2.4l7.9-7.9"/></svg>',
  key: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="8" cy="15" r="3.5"/><path d="m10.5 12.5 8-8M15 7l2 2M17 5l2 2"/></svg>',
  plus: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M5 12h14"/></svg>',
  refresh: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20 11a8 8 0 1 0-.7 4M20 4v5h-5"/></svg>',
  folder: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>',
  // airlock = the porthole mark (dome + perspective floor grid), rendered via a CSS mask -> takes currentColor.
  airlock: '<span class="al-logo" aria-hidden="true"></span>',
  levelup: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M9 15l-4-4 4-4M5 11h10a4 4 0 0 1 4 4v3"/></svg>',
  pencil: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>',
  layoutH: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 5v14M12 6.5v11M20.5 5v14"/><path d="M6.5 12h11"/><path d="M8.2 9.8 6 12l2.2 2.2M15.8 9.8 18 12l-2.2 2.2"/></svg>',
  fontSize: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 17 7 6l4.5 11M3.8 13.4h6.4"/><path d="M14 17l3-8 3 8M14.9 14.5h4.2"/></svg>',
  theme: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3a9 9 0 1 0 0 18c1.6 0 2.4-1.3 1.9-2.5-.5-1.3.4-2.5 1.8-2.5H19a3 3 0 0 0 3-3 9 9 0 0 0-10-8z"/><circle cx="7.5" cy="12" r="1" fill="currentColor" stroke="none"/><circle cx="10" cy="7.6" r="1" fill="currentColor" stroke="none"/><circle cx="14.4" cy="7.6" r="1" fill="currentColor" stroke="none"/></svg>',
  paneZoom: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M8 3H5a2 2 0 0 0-2 2v3M16 3h3a2 2 0 0 1 2 2v3M8 21H5a2 2 0 0 1-2-2v-3M16 21h3a2 2 0 0 0 2-2v-3"/></svg>',
  paneUnzoom: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h4V4M20 8h-4V4M4 16h4v4M20 16h-4v4"/></svg>',
  dots: '<svg viewBox="0 0 24 24" fill="currentColor" stroke="none"><circle cx="5" cy="12" r="1.7"/><circle cx="12" cy="12" r="1.7"/><circle cx="19" cy="12" r="1.7"/></svg>',
  selectText: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8V6.4A2.4 2.4 0 0 1 6.4 4H8M16 4h1.6A2.4 2.4 0 0 1 20 6.4V8M20 16v1.6a2.4 2.4 0 0 1-2.4 2.4H16M8 20H6.4A2.4 2.4 0 0 1 4 17.6V16"/><path d="M7.8 10.7h8.4M7.8 13.8h5.2"/></svg>',
  grid: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="6.4" height="6.4" rx="1.6"/><rect x="13.6" y="4" width="6.4" height="6.4" rx="1.6"/><rect x="4" y="13.6" width="6.4" height="6.4" rx="1.6"/><rect x="13.6" y="13.6" width="6.4" height="6.4" rx="1.6"/></svg>',
  panes: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="4.5" width="17" height="15" rx="2"/><path d="M12 4.5v15M12 12h8.5"/></svg>',
  keyboard: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="6" width="19" height="12" rx="2"/><path d="M6 9.5h.01M9.5 9.5h.01M13 9.5h.01M16.5 9.5h.01M18 13h.01M6 13h.01M8.5 13h7"/></svg>',
  claude: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2.6v6.1M12 15.3v6.1M2.6 12h6.1M15.3 12h6.1M5.5 5.5l4.3 4.3M14.2 14.2l4.3 4.3M18.5 5.5l-4.3 4.3M9.8 14.2l-4.3 4.3"/></svg>',
  gear: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>',
};

// equal horizontal pane width — tmux select-layout even-horizontal (active window)
function equalizeLayout() {
  postJson('layout', { session: currentSession(), layout: 'even-horizontal' })
    .then((j) => flash(j && j.ok ? 'Panes set to equal widths ↔' : ('Layout failed: ' + ((j && j.error) || '')), 1600))
    .catch(() => flash('Layout failed', 1600));
}

// terminal theme — runtime apply + localStorage + sync #term padding color.
function applyTheme(key) {
  const t = THEMES[key] || THEMES[DEFAULT_THEME];
  term.options.theme = t.xterm;
  const el = document.getElementById('term'); if (el) el.style.background = t.xterm.background;
  tabPrefs.theme = key; saveTabPrefs(true);   // save to server immediately = source of truth, identical on every device
}
(function applySavedThemeBg() { const el = document.getElementById('term'); if (el) el.style.background = THEMES[savedThemeKey()].xterm.background; })();

// theme picker — mini preview cards. Click applies + remembers.
function openThemePicker() {
  const { ov, box } = makeModal(24, 'padding:16px;width:100%;max-width:440px;display:flex;flex-direction:column;gap:12px;');
  const close = () => { try { document.body.removeChild(ov); } catch (e) {} term.focus(); };
  const hd = document.createElement('div'); hd.style.cssText = 'display:flex;align-items:baseline;gap:10px;';
  hd.appendChild(uiTitle('Theme'));
  const sub = document.createElement('div'); sub.textContent = 'Terminal color theme — click to apply';
  sub.style.cssText = 'flex:1;color:#8a92a6;font:12.5px system-ui;'; hd.appendChild(sub);
  const grid = document.createElement('div');
  grid.style.cssText = 'display:grid;grid-template-columns:1fr 1fr;gap:8px;max-height:62vh;overflow:auto;';
  const cur = savedThemeKey();
  for (const key of THEME_ORDER) {
    const t = THEMES[key], x = t.xterm, on = key === cur;
    const c = document.createElement('button');
    c.style.cssText = 'display:flex;align-items:center;gap:9px;padding:8px;border-radius:9px;cursor:pointer;text-align:left;border:1.5px solid ' + (on ? '#5480b8' : 'rgba(255,255,255,.10)') + ';background:' + (on ? '#243046' : '#20242e') + ';';
    const pv = document.createElement('div');
    pv.style.cssText = 'flex:0 0 auto;width:48px;height:36px;border-radius:5px;padding:6px;box-sizing:border-box;display:flex;flex-direction:column;justify-content:center;gap:3px;background:' + x.background + ';border:1px solid rgba(0,0,0,.35);';
    [[x.green, '62%'], [x.blue, '82%'], [x.red, '48%'], [x.foreground, '72%']].forEach(function (cw2) {
      const bar = document.createElement('div'); bar.style.cssText = 'height:3px;border-radius:2px;width:' + cw2[1] + ';background:' + cw2[0] + ';'; pv.appendChild(bar);
    });
    const lbl = document.createElement('div'); lbl.textContent = t.name;
    lbl.style.cssText = 'flex:1;color:#e6e6e6;font:13px system-ui;' + (on ? 'font-weight:600;' : '');
    c.appendChild(pv); c.appendChild(lbl);
    if (on) { const chk = document.createElement('span'); chk.textContent = '✓'; chk.style.cssText = 'color:#7fd6a0;font:600 13px system-ui;'; c.appendChild(chk); }
    c.onclick = function () { applyTheme(key); close(); flash('Theme: ' + t.name, 1400); };
    grid.appendChild(c);
  }
  const row = document.createElement('div'); row.style.cssText = 'display:flex;justify-content:flex-end;';
  const closeBtn = uiBtn('Close', 'ghost'); closeBtn.onclick = close; row.appendChild(closeBtn);
  box.appendChild(hd); box.appendChild(grid); box.appendChild(row);
  ov.addEventListener('mousedown', (e) => { if (e.target === ov) close(); });
  ov.appendChild(box); document.body.appendChild(ov);
}

// font size — small popover under the button: A- / current / A+
function openFontPopover(anchor) {
  closeTabPops();
  const pop = document.createElement('div'); pop.className = 'tab-pop';
  pop.style.cssText += 'padding:8px;display:flex;align-items:center;gap:8px;';
  const val = document.createElement('div'); val.style.cssText = 'min-width:52px;text-align:center;color:#e6e6e6;font:13px system-ui;';
  const upd = () => { val.textContent = term.options.fontSize + ' px'; };
  const mkb = (txt, fn) => {
    const b = document.createElement('button'); b.textContent = txt;
    b.style.cssText = 'display:inline-flex;align-items:center;justify-content:center;width:42px;height:34px;padding:0;border-radius:7px;border:1px solid rgba(255,255,255,.12);background:#2b303b;color:#dde1e8;font:16px system-ui;cursor:pointer;';
    b.onclick = () => { fn(); upd(); };
    return b;
  };
  const dec = mkb('A-', () => stepFontSize(-1));
  const inc = mkb('A+', () => stepFontSize(1));
  upd();
  pop.appendChild(dec); pop.appendChild(val); pop.appendChild(inc);
  const r = anchor.getBoundingClientRect();
  placePop(pop, r.left, r.bottom + 6);
}
// fast custom tooltip (native title has ~1s delay -> 120ms)
let _tipEl = null, _tipT = null;
function hideTip() { clearTimeout(_tipT); _tipT = null; if (_tipEl) { try { document.body.removeChild(_tipEl); } catch (e) {} _tipEl = null; } }
// vertical clamp basis = the currently visible viewport height (visualViewport), so a
//   menu isn't hidden behind the soft keyboard.
function visViewH() { return window.visualViewport ? Math.round(window.visualViewport.height) : window.innerHeight; }
function showTip(el, text) {
  hideTip();
  const t = document.createElement('div');
  t.textContent = text;
  t.style.cssText = 'position:fixed;z-index:60;background:#0d1017;color:#e6e6e6;border:1px solid #333a49;padding:4px 8px;border-radius:6px;font:12px sans-serif;white-space:nowrap;pointer-events:none;box-shadow:0 4px 14px rgba(0,0,0,.4);';
  document.body.appendChild(t);
  const r = el.getBoundingClientRect(), tr = t.getBoundingClientRect();
  let left = Math.max(6, Math.min(r.left + r.width / 2 - tr.width / 2, window.innerWidth - tr.width - 6));
  let top = r.bottom + 6;
  if (top + tr.height > visViewH() - 4) top = r.top - tr.height - 6;
  t.style.left = left + 'px'; t.style.top = top + 'px';
  _tipEl = t;
}
function mkIconBtn(svg, title, onClick) {
  const b = document.createElement('button');
  b.className = 'sqbtn'; b.innerHTML = svg; b.setAttribute('aria-label', title);
  b.addEventListener('mouseenter', () => { _tipT = setTimeout(() => showTip(b, title), 120); });
  b.addEventListener('mouseleave', hideTip);
  b.addEventListener('pointerdown', (e) => e.preventDefault());
  b.addEventListener('click', () => { hideTip(); onClick(b); if (!document.querySelector('.copy-overlay')) term.focus(); });
  return b;
}

// pinned far-left Airlock button — return to the hub. Inserted once (idempotent).
// Sessions persist in tmux, so leaving the page won't kill them -> same-tab navigation.
function ensureAirlock() {
  if (document.getElementById('airlock')) return;
  const tabsEl = document.getElementById('tabs');
  if (!tabsEl) return;
  const b = mkIconBtn(ICONS.airlock, 'Airlock — hub home', () => { location.href = hubBase() + '/'; });
  b.id = 'airlock';
  b.style.position = 'relative';                 // unread-badge anchor
  // needs-action badge — Dev Monitor owner-message count. Hidden unless > 0 and reachable.
  const badge = document.createElement('span');
  badge.id = 'airlock-badge';
  badge.setAttribute('aria-hidden', 'true');
  badge.style.cssText = 'position:absolute;top:-3px;right:-3px;min-width:16px;height:16px;box-sizing:border-box;'
    + 'padding:0 4px;border-radius:8px;background:#6b7280;color:#fff;font:700 10px/16px system-ui,sans-serif;'
    + 'text-align:center;box-shadow:0 0 0 2px #1e2230;display:none;pointer-events:none;';
  b.appendChild(badge);
  tabsEl.insertBefore(b, tabsEl.firstChild);   // before #tabnames = far left
  startAirlockBadge(badge, b);
}

// unread badge polling (30s). Timer set once (idempotent).
let _airlockBadgeTimer = null;
function startAirlockBadge(badge, btn) {
  if (_airlockBadgeTimer) return;
  const url = hubBase() + '/monitor/api/owner/messages/preview';
  const tick = () => {
    fetch(url, { cache: 'no-store' })
      .then(r => {
        // 403 (not the owner) and 404 (messages feature not enabled) are real zeros;
        // any other failure (5xx, network, bad JSON) leaves the badge at its last known
        // value instead of lying to zero — see hub/assets/airlock-return.js's pollUnread
        // for why (the same fix, kept in step because both widgets read the same field).
        if (r.status === 403 || r.status === 404) return null;
        if (!r.ok) return undefined;
        return r.json();
      })
      .then(d => {
        if (d === null) { badge.style.display = 'none'; btn.setAttribute('aria-label', 'Airlock — hub home'); return; }
        if (d === undefined) return;                    // unexpected status — keep last known
        const n = (d && d.needs_action_count != null) ? d.needs_action_count : (d && d.unread_count) || 0;
        if (n > 0) {
          badge.textContent = n > 99 ? '99+' : String(n);
          badge.style.display = 'block';
          btn.setAttribute('aria-label', 'Airlock — ' + n + ' needs action');
        } else {
          badge.style.display = 'none';
          btn.setAttribute('aria-label', 'Airlock — hub home');
        }
      })
      .catch(() => {});                                  // network / bad JSON — keep last known
  };
  tick();
  _airlockBadgeTimer = setInterval(tick, 30000);
}

function buildControls() {   // right-side controls — square line icons
  ensureAirlock();           // left Airlock (once, idempotent) — before the MK.active early-return
  ctrlsEl.textContent = '';
  if (MK.active) return;                  // mobile: no top controls (all in the bottom bar). paneZoomBtn owned by buildMobileKeys.
  if (FEAT.accounts || FEAT.xai) {
    ctrlsEl.appendChild(mkIconBtn(ICONS.claude, 'Switch account / subscriptions', acct.openAcctMenu));
    if (FEAT.accounts) { acct.applyAcctIconCls(); acct.startAcctIconWatch(); }
  }
  // desktop: inline icons + pane-zoom
  paneZoomBtn = mkIconBtn(ICONS.paneZoom, 'Zoom pane (current only)', paneZoomToggle);
  const utils = [
    [ICONS.copy, 'Copy — stitch screen text into logical lines in a modal (keyboard = Mac Cmd+C / Win-Linux Ctrl+Shift+C; precise selection = drag)', () => mkSelectText()],
    [ICONS.fontSize, 'Font size (A- / A+)', (btn) => openFontPopover(btn)],
    [ICONS.theme, 'Theme', openThemePicker],
    [ICONS.clip, 'Upload file', pickAndUploadFile],
    [ICONS.key, 'Secret drop (auto-deleted after 30 min)', openSecretDrop],
    [ICONS.pencil, 'Annotate image', openImageAnnotator],
    [ICONS.layoutH, 'Equal pane widths (even-horizontal)', equalizeLayout],
  ];
  if (FEAT.orca) utils.push([ICONS.gear, 'Settings (layout, agents)', openSettings]);
  for (const u of utils) {
    const b = mkIconBtn(u[0], u[1], u[2]);
    if (u[0] === ICONS.copy) b.classList.add('js-copy-icon');   // pulse target for the copy hint
    ctrlsEl.appendChild(b);
  }
  ctrlsEl.appendChild(paneZoomBtn);
  updatePaneZoomBtn(null);
}

// ---- tab popups (right-click menu / overflow list) ----
let _popOpener = null;
let _popClosedAnchor = null;
function closeTabPops() { document.querySelectorAll('.tab-pop').forEach((p) => p.remove()); _popOpener = null; if (acct) acct.hideAcctTip(); }
document.addEventListener('pointerdown', (e) => {
  if (!e.target || !e.target.closest) return;
  if (e.target.closest('.tab-pop')) return;
  _popClosedAnchor = (_popOpener && _popOpener.contains && _popOpener.contains(e.target)) ? _popOpener : null;
  closeTabPops();
}, true);
function placePop(pop, x, y) {
  document.body.appendChild(pop);
  pop.style.left = Math.max(6, Math.min(x, window.innerWidth - pop.offsetWidth - 8)) + 'px';
  pop.style.top = Math.max(6, Math.min(y, visViewH() - pop.offsetHeight - 8)) + 'px';   // clamp above the keyboard (visViewH)
}
// palette — white-on-dark WCAG AA, even luminance, color-wheel order.
const TAB_COLORS = [
  { key: '#626a78', label: 'Slate' }, { key: '#8b403b', label: 'Brick' }, { key: '#84523a', label: 'Rust' },
  { key: '#76562e', label: 'Amber' }, { key: '#66642e', label: 'Olive' }, { key: '#4c7145', label: 'Sage' },
  { key: '#3f704d', label: 'Forest' }, { key: '#3a7070', label: 'Teal' }, { key: '#3e6f8e', label: 'Steel' },
  { key: '#496ca3', label: 'Blue' }, { key: '#5d5aa0', label: 'Indigo' }, { key: '#824a63', label: 'Plum' },
];
function applyTabColor(btn, name) {
  const c = tabPrefs.colors[name];
  if (c) { btn.classList.add('colored'); btn.style.setProperty('--tab-color', c); }   // no fill -> left accent bar only
}
// merge live sessions + saved order (drop gone ones, append new at the end).
function mergedOrder(liveNames) {
  const cur = currentSession();
  const present = new Set(liveNames); present.add(cur);
  tabPrefs.hidden = tabPrefs.hidden.filter((n) => present.has(n));   // keep only live sessions hidden (current can be hidden too)
  let ordered = tabPrefs.order.filter((n) => present.has(n));
  for (const n of liveNames) if (!ordered.includes(n)) ordered.push(n);
  if (!ordered.includes(cur)) ordered.push(cur);
  tabPrefs.order = ordered;
  return ordered;
}

let dragName = null;
// RMT__<host>__<session> = remote session tab id (won't collide with local). Display = '*' + session.
function parseRemote(name) {
  if (typeof name !== 'string' || name.indexOf('RMT__') !== 0) return null;
  const rest = name.slice(5), i = rest.indexOf('__');
  if (i < 0) return null;
  return { host: rest.slice(0, i), session: rest.slice(i + 2) };
}
function tabLabel(name) {
  const r = parseRemote(name);
  return r ? '*' + r.session : name;
}
function mkTab(name) {
  const r = parseRemote(name);
  // tabs don't preventDefault on pointerdown (unlike other buttons) so HTML5 drag (reorder) works
  const b = document.createElement('button');
  b.className = 'tab' + (name === currentSession() ? ' on' : '') + (r ? ' remote' : '');
  b.textContent = tabLabel(name); b.title = r ? ('ssh ' + r.host + ' · tmux ' + r.session) : ('tmux ' + name);
  applyTabColor(b, name);
  b.addEventListener('click', () => switchTo(name));
  b.oncontextmenu = (e) => { e.preventDefault(); showTabMenu(name, e.clientX, e.clientY); };
  b.draggable = true;
  b.addEventListener('dragstart', (e) => { dragName = name; b.classList.add('drag-src'); try { e.dataTransfer.effectAllowed = 'move'; e.dataTransfer.setData('text/plain', name); } catch (x) {} });
  b.addEventListener('dragend', () => { dragName = null; b.classList.remove('drag-src'); document.querySelectorAll('.drop-before,.drop-after').forEach((x) => x.classList.remove('drop-before', 'drop-after')); });
  b.addEventListener('dragover', (e) => {
    if (!dragName || dragName === name) return;
    e.preventDefault();
    const rect = b.getBoundingClientRect();
    const vert = !!(b.closest && b.closest('#sidebar'));       // sidebar (vertical list) judges before/after by Y
    const after = vert ? (e.clientY - rect.top) > rect.height / 2 : (e.clientX - rect.left) > rect.width / 2;   // right/bottom half = insert after
    b.classList.toggle('drop-after', after);
    b.classList.toggle('drop-before', !after);
  });
  b.addEventListener('dragleave', () => b.classList.remove('drop-before', 'drop-after'));
  b.addEventListener('drop', (e) => {
    e.preventDefault();
    const after = b.classList.contains('drop-after');
    b.classList.remove('drop-before', 'drop-after');
    reorderTab(dragName, name, after);
  });
  return b;
}
function reorderTab(from, to, after) {
  if (!from || from === to) return;
  const o = tabPrefs.order.filter((n) => n !== from);
  let i = o.indexOf(to);
  if (i < 0) i = o.length; else if (after) i += 1;
  o.splice(i, 0, from);
  tabPrefs.order = o; saveTabPrefs(); loadSessions();
}

function showTabMenu(name, x, y) {
  closeTabPops();
  const pop = document.createElement('div'); pop.className = 'tab-pop';
  const hide = document.createElement('button'); hide.textContent = 'Hide';
  hide.onclick = () => { if (!tabPrefs.hidden.includes(name)) tabPrefs.hidden.push(name); saveTabPrefs(); closeTabPops(); loadSessions(); };
  const rename = document.createElement('button'); rename.textContent = 'Rename';
  rename.onclick = () => { closeTabPops(); renameSession(name); };
  const kill = document.createElement('button'); kill.textContent = 'Kill session'; kill.className = 'danger';
  kill.onclick = () => { closeTabPops(); killSession(name); };
  const hd = document.createElement('div'); hd.className = 'hd'; hd.textContent = 'Color';
  const sw = document.createElement('div'); sw.className = 'swatches';
  for (const c of TAB_COLORS) {
    const s = document.createElement('span'); s.style.background = c.key; s.title = c.label;
    if (tabPrefs.colors[name] === c.key) s.className = 'sel';
    s.onclick = () => { tabPrefs.colors[name] = c.key; saveTabPrefs(); closeTabPops(); loadSessions(); };
    sw.appendChild(s);
  }
  const clr = document.createElement('button'); clr.textContent = 'Clear color';
  clr.onclick = () => { delete tabPrefs.colors[name]; saveTabPrefs(); closeTabPops(); loadSessions(); };
  const sep = document.createElement('div'); sep.className = 'sep';
  const sep2 = document.createElement('div'); sep2.className = 'sep';
  const rmt = parseRemote(name);   // remote session tabs hide rename/kill (managed on the remote host)
  pop.appendChild(hide);
  if (!rmt) pop.appendChild(rename);
  pop.appendChild(sep); pop.appendChild(hd); pop.appendChild(sw); pop.appendChild(clr);
  if (!rmt) { pop.appendChild(sep2); pop.appendChild(kill); }
  placePop(pop, x, y);
}

// rename a tmux session. If it's the current one, re-attach via URL arg. Migrate prefs too.
function renameSession(oldName) {
  const input = prompt('Rename session: "' + oldName + '" ->', oldName);
  if (input === null) return;
  const to = input.trim().replace(/[^A-Za-z0-9_-]/g, '_');
  if (!to || to === oldName) return;
  postJson('rename-session', { from: oldName, to: to }).then((j) => {
    if (!j.ok) { flash('Rename failed: ' + (j.error || '?'), 2500); return; }
    tabPrefs.order = tabPrefs.order.map((n) => (n === oldName ? to : n));
    tabPrefs.hidden = tabPrefs.hidden.map((n) => (n === oldName ? to : n));
    if (tabPrefs.colors[oldName] !== undefined) { tabPrefs.colors[to] = tabPrefs.colors[oldName]; delete tabPrefs.colors[oldName]; }
    saveTabPrefs();
    if (oldName === currentSession()) switchTo(to);   // re-attach to the same session under the new name (screen preserved)
    else loadSessions();
  }).catch((e) => flash('Rename failed: ' + e.message, 2500));
}

// kill a tmux session — unlike hiding a tab, this really ends the session (destructive).
function killSession(name) {
  if (!confirm('This does not just close the tab — it kills the tmux session "' + name + '".\nRunning processes will be terminated. Continue?')) return;
  const wasCurrent = name === currentSession();
  const ord = tabPrefs.order.slice();                  // snapshot for neighbor calc (before cleanup)
  postJson('kill-session', { name: name }).then((j) => {
    if (!j.ok) { flash('Kill failed: ' + (j.error || '?'), 2500); return; }
    delete tabPrefs.colors[name];                       // tidy color / hidden / order
    tabPrefs.hidden = tabPrefs.hidden.filter((n) => n !== name);
    tabPrefs.order = tabPrefs.order.filter((n) => n !== name);
    saveTabPrefs();
    if (!wasCurrent) { loadSessions(); return; }
    // killed the current session -> move to an adjacent (next then previous) live one. Avoid auto-recreating main.
    fetch('sessions', { cache: 'no-store' }).then((r) => r.json()).then((s) => {
      const live = (s.sessions || []).map((x) => x.name).filter((n) => n !== name);
      if (!live.length) { history.replaceState(null, '', location.pathname); switchSession(); return; }   // none left -> default (new main)
      const i = ord.indexOf(name);
      let target = null;
      for (let k = i + 1; k < ord.length && !target; k++) if (live.includes(ord[k])) target = ord[k];
      for (let k = i - 1; k >= 0 && !target; k--) if (live.includes(ord[k])) target = ord[k];
      switchTo(target || live[0]);
    }).catch(() => { history.replaceState(null, '', location.pathname); switchSession(); });
  }).catch((e) => flash('Kill failed: ' + e.message, 2500));
}

function showOverflowList(names, x, y) {
  closeTabPops();
  const pop = document.createElement('div'); pop.className = 'tab-pop';
  const hd = document.createElement('div'); hd.className = 'hd'; hd.textContent = 'Hidden / overflow (' + names.length + ') — click to show';
  pop.appendChild(hd);
  const cur = currentSession();
  for (const name of names) {
    const b = document.createElement('button');
    if (tabPrefs.colors[name]) {
      const dot = document.createElement('span');
      dot.style.cssText = 'display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:8px;vertical-align:middle;background:' + tabPrefs.colors[name];
      b.appendChild(dot);
    }
    b.appendChild(document.createTextNode(name + (name === cur ? '  (current)' : '')));
    b.onclick = () => {
      tabPrefs.hidden = tabPrefs.hidden.filter((n) => n !== name);                  // un-hide
      tabPrefs.order = tabPrefs.order.filter((n) => n !== name).concat([name]);      // append to end
      saveTabPrefs(); closeTabPops();
      if (name !== currentSession()) switchTo(name);   // other session -> go there (re-render)
      else loadSessions();                             // current -> no nav -> re-render directly
    };
    pop.appendChild(b);
  }
  placePop(pop, x, y);
}

// new session — modal (name + optional folder). No folder = default location.
function newSession() {
  let pickedDir = '';
  const { ov, box } = makeModal(22, 'padding:16px;width:100%;max-width:420px;');
  const title = uiTitle('New tmux session'); title.style.cssText += 'margin-bottom:12px;';
  const nameIn = document.createElement('input'); nameIn.placeholder = 'Session name';
  nameIn.autocapitalize = 'off'; nameIn.autocomplete = 'off'; nameIn.spellcheck = false;
  nameIn.style.cssText = 'width:100%;box-sizing:border-box;height:38px;padding:0 12px;' + UI_FIELD + 'font:14px system-ui;';
  const dirRow = document.createElement('div');
  dirRow.style.cssText = 'display:flex;align-items:center;gap:8px;margin-top:12px;';
  const dirLbl = document.createElement('div');
  dirLbl.style.cssText = 'flex:1;color:#8a92a6;font:12.5px system-ui;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';
  const setDirLbl = () => { dirLbl.textContent = pickedDir ? ('Folder: ' + pickedDir) : 'Folder: default location'; };
  setDirLbl();
  const pickBtn = uiBtn('Choose folder', 'ghost'); pickBtn.style.cssText += 'height:34px;flex:0 0 auto;font-size:13px;';
  pickBtn.onclick = () => openFolderPicker(pickedDir || '~', (p) => { pickedDir = p; setDirLbl(); });
  dirRow.appendChild(dirLbl); dirRow.appendChild(pickBtn);
  const btnRow = document.createElement('div');
  btnRow.style.cssText = 'display:flex;gap:8px;justify-content:flex-end;margin-top:16px;';
  const cancel = uiBtn('Cancel', 'ghost');
  const create = uiBtn('Create', 'primary');
  const close = () => { try { document.body.removeChild(ov); } catch (e) {} term.focus(); };
  cancel.onclick = close;
  const submit = () => {
    const n = nameIn.value.trim(); if (!n) { nameIn.focus(); return; }
    close();
    history.replaceState(null, '', location.pathname + '?arg=' + encodeURIComponent(n) + (pickedDir ? '&arg=' + encodeURIComponent(pickedDir) : ''));
    switchSession();   // to the new session without a reload
  };
  create.onclick = submit;
  nameIn.addEventListener('keydown', (e) => { if (e.key === 'Enter') submit(); });
  btnRow.appendChild(cancel); btnRow.appendChild(create);
  box.appendChild(title); box.appendChild(nameIn); box.appendChild(dirRow); box.appendChild(btnRow);
  ov.appendChild(box); document.body.appendChild(ov);
  setTimeout(() => nameIn.focus(), 0);
}

// server folder GUI browser — navigate directories (/list-dir) and select one
function openFolderPicker(startPath, onPick) {
  const { ov, box } = makeModal(24, 'padding:14px;width:100%;max-width:480px;display:flex;flex-direction:column;max-height:74vh;');
  ov.style.cssText += 'background:rgba(0,0,0,.6);';
  const title = uiTitle('Choose folder (' + ((location.hostname || '').split('.')[0] || '') + ')'); title.style.cssText += 'margin-bottom:8px;';
  const pathEl = document.createElement('div');
  pathEl.style.cssText = 'font:12px ui-monospace,monospace;color:#7fa8d8;margin-bottom:8px;overflow-x:auto;white-space:nowrap;';
  const listEl = document.createElement('div');
  listEl.style.cssText = 'flex:1;overflow-y:auto;' + UI_FIELD + 'padding:6px;min-height:200px;';
  const row = document.createElement('div');
  row.style.cssText = 'display:flex;gap:8px;justify-content:flex-end;margin-top:12px;';
  const cancel = uiBtn('Cancel', 'ghost'); cancel.style.cssText += 'height:34px;font-size:13px;';
  const pick = uiBtn('Select this folder', 'primary'); pick.style.cssText += 'height:34px;font-size:13px;';
  let curPath = startPath;
  const close = () => { try { document.body.removeChild(ov); } catch (e) {} };
  cancel.onclick = close;
  pick.onclick = () => { onPick(curPath); close(); };
  function mkDirRow(label, icon, onClick) {
    const d = document.createElement('button');
    d.style.cssText = 'display:flex;align-items:center;gap:9px;width:100%;height:34px;padding:0 8px;border:0;background:transparent;color:#dde1e8;border-radius:6px;font:13px system-ui;text-align:left;';
    const ic = document.createElement('span'); ic.style.cssText = 'color:#9aa4b8;flex:0 0 auto;display:inline-flex;';
    ic.innerHTML = icon.replace('<svg', '<svg width="17" height="17"');
    const tx = document.createElement('span'); tx.textContent = label;
    tx.style.cssText = 'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';
    d.appendChild(ic); d.appendChild(tx);
    d.onmouseenter = () => { d.style.background = '#333a49'; };
    d.onmouseleave = () => { d.style.background = 'transparent'; };
    d.onclick = onClick;
    return d;
  }
  async function load(p) {
    listEl.textContent = 'Loading…';
    let j = {};
    try {
      j = await postJson('list-dir', { path: p });
    } catch (e) {}
    if (!j.ok) { listEl.textContent = 'Cannot open: ' + (j.error || '?'); return; }
    curPath = j.path; pathEl.textContent = j.path;
    listEl.textContent = '';
    if (j.parent && j.parent !== j.path) listEl.appendChild(mkDirRow('Parent folder', ICONS.levelup, () => load(j.parent)));
    for (const nm of j.dirs) listEl.appendChild(mkDirRow(nm, ICONS.folder, () => load((j.path === '/' ? '' : j.path) + '/' + nm)));
    if (!j.dirs.length) { const e = document.createElement('div'); e.textContent = '(no subfolders)'; e.style.cssText = 'color:#777;padding:8px;font:13px system-ui'; listEl.appendChild(e); }
  }
  row.appendChild(cancel); row.appendChild(pick);
  box.appendChild(title); box.appendChild(pathEl); box.appendChild(listEl); box.appendChild(row);
  ov.appendChild(box); document.body.appendChild(ov);
  load(startPath);
}

let visibleTabs = [];   // tabs currently shown (left->right) — read by Ctrl/Cmd+1~9
let liveSessionNames = new Set();   // live tmux session names (agent 'running' / re-enter detection)
let liveSessions = [];              // most recent /sessions raw (for 'other sessions' grouping)
let orcaTree = null;                // /orca/tree cache: {ok, repos:[{id,name,path,worktrees:[...]}]}
let orcaReady = false;              // Orca runtime reachable (gates the sidebar worktree mode)
let selectedWtPath = null;          // selected worktree path — the top agent bar binds to it
let _wtSig = '', _abSig = '';        // sidebar / agent-bar render signatures — skip DOM rebuild when unchanged
let pendingSessions = new Map();     // sn -> expiry(ms): optimistic display — shown on the left immediately, cleared when /sessions confirms or on expiry
// layout dispatcher: sidebar = Orca worktree tree + the selected worktree's agents / tabs = top session tabs (default).
function renderTabs(list) {
  const names = list.map((s) => s.name);
  liveSessionNames = new Set(names);
  if (pendingSessions.size) {
    const now = Date.now();
    for (const [sn, exp] of pendingSessions) {
      if (names.includes(sn) || now > exp) pendingSessions.delete(sn);   // confirmed or expired -> drop optimistic
      else liveSessionNames.add(sn);                                     // unconfirmed -> keep optimistic (show left immediately)
    }
  }
  liveSessions = list;
  if (effectiveLayout() === 'sidebar') { renderWorktreeSidebar(); renderAgentBar(); return; }
  renderTopTabs(list);
}
function renderTopTabs(list) {
  const cur = currentSession();
  const ordered = mergedOrder(list.map((s) => s.name));
  const shown = ordered.filter((n) => !tabPrefs.hidden.includes(n));
  let visible = shown.slice(0, MAX_VISIBLE_TABS);
  if (!visible.length) visible = [cur];   // all hidden -> at least current (no empty bar)
  visibleTabs = visible;                  // keyboard-tab-switch snapshot
  const overflow = ordered.filter((n) => !visible.includes(n));   // hidden + beyond 9
  namesEl.textContent = '';
  for (const name of visible) namesEl.appendChild(mkTab(name));
  if (overflow.length) {
    const dots = document.createElement('button'); dots.className = 'mini dots';
    dots.textContent = '…'; dots.title = 'Hidden/overflow: ' + overflow.length;
    dots.addEventListener('pointerdown', (e) => e.preventDefault());
    dots.addEventListener('click', (e) => showOverflowList(overflow, e.clientX, e.clientY));
    namesEl.appendChild(dots);
  }
  namesEl.appendChild(mkIconBtn(ICONS.plus, 'New session (name + folder)', newSession));
  namesEl.appendChild(mkIconBtn(ICONS.refresh, 'Refresh list', loadSessions));
}

// ---- experimental layout: Orca worktree tree (left) + the selected worktree's launcher (top) ----
// worktree = Orca's real worktree (gate /orca/tree, same source as the Orca app). Launcher (shell/agent) = a tmux session in that worktree cwd.
// The session name is derived deterministically from the worktree PATH (basename) -> stable grouping + deterministic re-enter.
function wtBaseName(p) { return String(p || '').replace(/\/+$/, '').split('/').pop() || 'wt'; }
function wtKey(repoName, wtPath) { return agentSlug(repoName) + '__' + agentSlug(wtBaseName(wtPath)); }
// launchers to open in a worktree: shell (always) + configured agents. Each has a deterministic session name (sn).
function launchersFor(repoName, wtPath) {
  const base = wtKey(repoName, wtPath);
  const list = [{ label: 'Terminal', cmd: '', sn: 'sh__' + base }];
  for (const a of tabPrefs.agents) list.push({ label: a.label, cmd: a.cmd, sn: agentSlug(a.label) + '__' + base });
  return list;
}
function findWt(path) {
  const repos = (orcaTree && orcaTree.repos) || [];
  for (const r of repos) for (const w of r.worktrees) if (w.path === path) return Object.assign({}, w, { repoName: r.name, repoId: r.id });
  return null;
}
// the worktree path the current session belongs to (if its name matches one of that worktree's launchers). Else null.
function currentWtPath() {
  const cur = currentSession();
  for (const r of ((orcaTree && orcaTree.repos) || [])) for (const w of r.worktrees) {
    if (launchersFor(r.name, w.path).some((L) => L.sn === cur)) return w.path;
  }
  return null;
}
// ?arg=<session>&arg=<worktree dir> — devterm-shell creates a new session in that dir (existing -> attach, dir ignored).
function switchToDir(name, dir) {
  if (!name) return;
  history.replaceState(null, '', location.pathname + '?arg=' + encodeURIComponent(name) + (dir ? '&arg=' + encodeURIComponent(dir) : ''));
  switchSession();
}
async function refreshOrca() {
  if (!FEAT.orca) { orcaReady = false; return; }
  try { orcaReady = !!(await fetch('orca/status', { cache: 'no-store' }).then((r) => r.json())).ready; }
  catch (e) { orcaReady = false; }
  if (orcaReady) {
    try { orcaTree = await fetch('orca/tree', { cache: 'no-store' }).then((r) => r.json()); }
    catch (e) { orcaTree = null; }
    if (!orcaTree || !orcaTree.ok) orcaReady = false;
  }
}
// shared popup menu — items: [{hd}|{label,fn,cls}]. Reuses .tab-pop styling.
function simplePop(x, y, items) {
  closeTabPops();
  const pop = document.createElement('div'); pop.className = 'tab-pop';
  for (const it of items) {
    if (it.hd) { const h = document.createElement('div'); h.className = 'hd'; h.textContent = it.hd; pop.appendChild(h); continue; }
    const b = document.createElement('button'); b.textContent = it.label; if (it.cls) b.className = it.cls;
    b.onclick = () => { closeTabPops(); it.fn(); }; pop.appendChild(b);
  }
  placePop(pop, x, y);
}
const WT_STATUS_COLOR = { 'in-progress': '#e2c37b', 'in-review': '#6aa0e0', 'completed': '#7fd6a0', 'todo': '#6b7280' };
// left tree: project -> worktree (status dot) -> its live launcher sessions (shell/agent, right-click=kill). + 'Other sessions'.
function renderWorktreeSidebar() {
  const repos = (orcaTree && orcaTree.repos) || [];
  if (!selectedWtPath) selectedWtPath = currentWtPath() || (repos[0] && repos[0].worktrees[0] && repos[0].worktrees[0].path) || null;
  const cur = currentSession();
  const sig = selectedWtPath + '|' + cur + '|' + tabPrefs.agents.map((a) => a.label).join(',') + '|'
    + repos.map((r) => r.id + ':' + r.worktrees.map((w) => w.path + '~' + w.displayName + '~' + w.status + '~' + w.isMain).join(';')).join('||')
    + '|' + [...liveSessionNames].sort().join(',') + '|' + [...pendingSessions.keys()].sort().join(',');
  if (sig === _wtSig) return;   // unchanged -> skip DOM rebuild (no re-poll flicker)
  _wtSig = sig;
  const matched = new Set();
  const navSns = [];
  sidebarEl.textContent = '';
  // top 'Projects' header + add project (choose folder -> orca repo add). Always shown (add works with zero repos).
  const phd = document.createElement('div'); phd.className = 'side-repo side-projects';
  const pn = document.createElement('span'); pn.className = 'side-repo-name'; pn.textContent = 'Projects'; phd.appendChild(pn);
  const padd = mkIconBtn(ICONS.plus, 'Add project (choose folder -> register in Orca)', openAddProject);
  padd.classList.add('side-repo-add'); phd.appendChild(padd);
  sidebarEl.appendChild(phd);
  if (!repos.length) {
    const empty = document.createElement('div'); empty.className = 'side-hd';
    empty.textContent = 'No projects — use + to add a folder'; empty.style.color = '#7b8296';
    sidebarEl.appendChild(empty);
  }
  for (const repo of repos) {
    const rh = document.createElement('div'); rh.className = 'side-repo';
    const ric = document.createElement('span'); ric.className = 'side-repo-icon'; ric.innerHTML = ICONS.folder; rh.appendChild(ric);
    const rn = document.createElement('span'); rn.className = 'side-repo-name'; rn.textContent = repo.name; rh.appendChild(rn);
    const add = mkIconBtn(ICONS.plus, 'New worktree (' + repo.name + ')', () => openWorktreeCreate(repo));
    add.classList.add('side-repo-add'); rh.appendChild(add);
    sidebarEl.appendChild(rh);
    for (const wt of repo.worktrees) {
      const row = document.createElement('button'); row.className = 'wt' + (wt.path === selectedWtPath ? ' on' : '');
      const nm = document.createElement('div'); nm.className = 'wt-name';
      const dot = document.createElement('span'); dot.className = 'wt-dot';
      dot.style.background = WT_STATUS_COLOR[wt.status] || '#4a5266'; dot.title = wt.status || '';
      const lbl = document.createElement('span'); lbl.className = 'wt-label'; lbl.textContent = wt.displayName + (wt.isMain ? '  · main' : '');
      nm.appendChild(dot); nm.appendChild(lbl);
      const br = document.createElement('div'); br.className = 'wt-branch'; br.textContent = wt.branch;
      row.appendChild(nm); row.appendChild(br);
      const wtx = Object.assign({}, wt, { repoName: repo.name });
      row.addEventListener('click', () => {
        selectedWtPath = wt.path;
        _wtSig = ''; _abSig = ''; renderTabs(liveSessions);   // select highlight + top launcher immediately (sync)
        const Ls = launchersFor(repo.name, wt.path);
        const liveL = Ls.find((L) => liveSessionNames.has(L.sn));
        if (liveL) { if (liveL.sn !== currentSession()) launchInWt(liveL, wt); }   // live session -> go there
        else launchInWt(Ls[0], wt);   // no session -> auto-create + open the terminal (deterministic name -> re-click re-attaches)
      });
      row.oncontextmenu = (e) => { e.preventDefault(); showWtMenu(wtx, e.clientX, e.clientY); };
      sidebarEl.appendChild(row);
      for (const L of launchersFor(repo.name, wt.path)) {
        if (!liveSessionNames.has(L.sn)) continue;
        matched.add(L.sn); navSns.push(L.sn);
        const as = document.createElement('button'); as.className = 'wt-agent' + (L.sn === cur ? ' on' : '') + (pendingSessions.has(L.sn) ? ' starting' : '');
        as.textContent = L.label; as.title = 'click = open · right-click = kill';
        as.addEventListener('click', () => { selectedWtPath = wt.path; _wtSig = ''; _abSig = ''; renderTabs(liveSessions); launchInWt(L, wt); });
        as.oncontextmenu = (e) => { e.preventDefault(); simplePop(e.clientX, e.clientY, [{ hd: wt.displayName + ' / ' + L.label }, { label: 'Kill session', cls: 'danger', fn: () => killSession(L.sn) }]); };
        sidebarEl.appendChild(as);
      }
    }
  }
  const others = liveSessions.map((s) => s.name).filter((n) => !matched.has(n));   // sessions not tied to a worktree launcher
  if (others.length) {
    const oh = document.createElement('div'); oh.className = 'side-hd'; oh.textContent = 'Other sessions'; sidebarEl.appendChild(oh);
    for (const n of others) { sidebarEl.appendChild(mkTab(n)); navSns.push(n); }
  }
  visibleTabs = navSns.slice(0, MAX_VISIBLE_TABS);   // Ctrl/Cmd+1~9 = sessions visible in the tree
  const rr = document.createElement('div'); rr.className = 'side-row';
  rr.appendChild(mkIconBtn(ICONS.refresh, 'Refresh worktrees/sessions', applyLayout));
  sidebarEl.appendChild(rr);
}
// top = the selected worktree's launchers (shell + agents). Running = green dot + 'on'. Click = tmux attach-or-create in that cwd.
function renderAgentBar() {
  const wt = findWt(selectedWtPath);
  const cur = currentSession();
  const sig = (wt ? wt.path : '-') + '|' + cur + '|' + tabPrefs.agents.map((a) => a.label + ':' + a.cmd).join(',')
    + '|' + (wt ? launchersFor(wt.repoName, wt.path).map((L) => L.sn + (pendingSessions.has(L.sn) ? 'p' : (liveSessionNames.has(L.sn) ? '1' : '0'))).join(',') : '');
  if (sig === _abSig) return;
  _abSig = sig;
  namesEl.textContent = '';
  if (!wt) { const h = document.createElement('span'); h.className = 'agentbar-hint'; h.textContent = '← Select a worktree'; namesEl.appendChild(h); return; }
  const ctx = document.createElement('span'); ctx.className = 'agentbar-ctx';   // same status color dot as the left tree -> visual link
  const cdot = document.createElement('span'); cdot.className = 'ctx-dot'; cdot.style.background = WT_STATUS_COLOR[wt.status] || '#4a5266';
  ctx.appendChild(cdot); ctx.appendChild(document.createTextNode(wt.repoName + ' / ' + wt.displayName)); namesEl.appendChild(ctx);
  for (const L of launchersFor(wt.repoName, wt.path)) {
    const live = liveSessionNames.has(L.sn);
    const starting = pendingSessions.has(L.sn);
    const b = document.createElement('button');
    b.className = 'tab agent' + (L.sn === cur ? ' on' : '') + (starting ? ' starting' : (live ? ' live' : '')) + (L.cmd ? '' : ' shell');
    b.textContent = L.label;
    b.title = wt.displayName + ' — ' + (L.cmd || 'terminal') + (live ? ' · running' : ' · click to start');
    b.addEventListener('click', () => launchInWt(L, wt));
    namesEl.appendChild(b);
  }
  if (!tabPrefs.agents.length) {
    const hint = document.createElement('button'); hint.className = 'mini';
    hint.textContent = '+ Agent (settings)';
    hint.addEventListener('pointerdown', (e) => e.preventDefault());
    hint.addEventListener('click', openSettings);
    namesEl.appendChild(hint);
  }
}
// open a launcher: no session in that worktree -> create in cwd (run cmd after connect), else re-attach.
function launchInWt(L, wt) {
  if (L.sn === currentSession()) { term.focus(); return; }
  const fresh = !liveSessionNames.has(L.sn);
  if (fresh && L.cmd) pendingAgentCmd = L.cmd;
  if (fresh) pendingSessions.set(L.sn, Date.now() + 8000);   // optimistic: show left immediately (auto-cleared if /sessions doesn't confirm within 8s)
  _openingSn = L.sn; showStatus(L.cmd ? L.label + ' starting…' : 'Opening terminal…');   // instant feedback — cleared on output
  clearTimeout(_openingT);
  _openingT = setTimeout(() => {   // no output for 6s -> success/failure verdict (No Silent Failure)
    if (_openingSn !== L.sn) return;
    _openingSn = null; hideTermDim();
    if (fresh && !liveSessionNames.has(L.sn)) {   // no session at all = create failed
      pendingSessions.delete(L.sn); _wtSig = '';
      flash(L.label + ' failed to start — no session. Please retry.', 4500, 'error');
      loadSessions();
    } else hideStatus();
  }, 6000);
  switchToDir(L.sn, wt.path);
}
// worktree right-click — rename / kill all sessions / (non-main) delete.
function showWtMenu(wt, x, y) {
  const live = launchersFor(wt.repoName, wt.path).map((L) => L.sn).filter((sn) => liveSessionNames.has(sn));
  const items = [{ hd: wt.displayName + ' (' + wt.branch + ')' }, { label: 'Rename', fn: () => renameWorktree(wt) }];
  if (live.length) items.push({ label: 'Kill all sessions (' + live.length + ')', cls: 'danger', fn: () => killWtSessions(wt, live) });
  if (!wt.isMain) items.push({ label: 'Delete worktree (Orca + git)', cls: 'danger', fn: () => rmWorktree(wt) });
  simplePop(x, y, items);
}
async function renameWorktree(wt) {
  const to = prompt('Rename worktree: "' + wt.displayName + '" ->', wt.displayName);
  if (to === null) return;
  const dn = to.trim(); if (!dn || dn === wt.displayName) return;
  let j = {};
  try { j = await postJson('orca/worktree-set', { path: wt.path, displayName: dn }); } catch (e) {}
  if (j && j.ok) { flash('Renamed: ' + dn, 2000); applyLayout(); }
  else flash('Rename failed: ' + ((j && j.error) || '?'), 3000, 'error');
}
async function killWtSessions(wt, sns) {
  if (!confirm('Kill ' + sns.length + ' session(s) of ' + wt.displayName + '?\nRunning processes will be terminated. Continue?')) return;
  const cur = currentSession();
  for (const sn of sns) {
    try { await postJson('kill-session', { name: sn }); } catch (e) {}
    tabPrefs.hidden = tabPrefs.hidden.filter((n) => n !== sn);
    tabPrefs.order = tabPrefs.order.filter((n) => n !== sn);
    delete tabPrefs.colors[sn];
  }
  saveTabPrefs();
  flash(sns.length + ' session(s) killed', 2000);
  if (sns.includes(cur)) {   // don't re-attach (recreate) the killed current session -> move to another/default
    let live = [];
    try { live = ((await fetch('sessions', { cache: 'no-store' }).then((r) => r.json())).sessions || []).map((x) => x.name).filter((n) => !sns.includes(n)); } catch (e) {}
    if (live.length) switchTo(live[0]); else { history.replaceState(null, '', location.pathname); switchSession(); }
  } else loadSessions();
}
async function rmWorktree(wt) {
  if (!confirm('Delete worktree: ' + wt.displayName + '\nThe checkout/branch will be removed. Continue?')) return;
  let j = {};
  try { j = await postJson('orca/worktree-rm', { path: wt.path }); } catch (e) {}
  if (j && j.ok) { flash('Worktree deleted: ' + wt.displayName, 2000); if (selectedWtPath === wt.path) selectedWtPath = null; applyLayout(); }
  else flash('Delete failed: ' + ((j && j.error) || '?'), 3200, 'error');
}
// add a project — reuse the folder picker (/list-dir), then orca repo add. Appears in the tree afterward.
function openAddProject() {
  openFolderPicker('~', async (path) => {
    flash('Adding project… ' + path, 8000);
    let j = {};
    try { j = await postJson('orca/repo-add', { path: path }); } catch (e) {}
    if (j && j.ok) { flash('Project added', 2000); applyLayout(); }
    else flash('Add project failed: ' + ((j && j.error) || '?'), 4000, 'error');
  });
}
// new worktree (Orca creates it) — name (blank = auto) + base branch. Refresh + select after.
function openWorktreeCreate(repo) {
  const { ov, box } = makeModal(23, 'padding:16px;width:100%;max-width:420px;');
  const title = uiTitle('New worktree — ' + repo.name); title.style.cssText += 'margin-bottom:12px;';
  const nameIn = document.createElement('input'); nameIn.placeholder = 'Name (blank = auto, e.g. swift-otter)';
  nameIn.autocapitalize = 'off'; nameIn.autocomplete = 'off'; nameIn.spellcheck = false;
  nameIn.style.cssText = 'width:100%;box-sizing:border-box;height:38px;padding:0 12px;' + UI_FIELD + 'font:14px system-ui;';
  const baseIn = document.createElement('input'); baseIn.placeholder = 'Base branch (blank = repo default)';
  baseIn.autocapitalize = 'off'; baseIn.autocomplete = 'off'; baseIn.spellcheck = false;
  baseIn.style.cssText = 'width:100%;box-sizing:border-box;height:38px;margin-top:10px;padding:0 12px;' + UI_FIELD + 'font:13px ui-monospace,monospace;';
  const note = document.createElement('div'); note.textContent = 'Orca creates the worktree (git worktree add) — it also shows in the Orca app. Blank name = auto.';
  note.style.cssText = 'font:11.5px/1.5 system-ui;color:#7b8296;margin-top:10px;';
  const btnRow = document.createElement('div'); btnRow.style.cssText = 'display:flex;gap:8px;justify-content:flex-end;margin-top:16px;';
  const cancel = uiBtn('Cancel', 'ghost'); const create = uiBtn('Create', 'primary');
  const close = () => { try { document.body.removeChild(ov); } catch (e) {} term.focus(); };
  cancel.onclick = close;
  const submit = async () => {
    let name = nameIn.value.trim(); if (!name) name = randomWtName(repo);   // blank = auto (avoids collision)
    create.disabled = true; create.textContent = 'Creating…';
    let j = {};
    try { j = await postJson('orca/worktree-create', { repoId: repo.id, name: name, baseBranch: baseIn.value.trim() }); } catch (e) {}
    if (j && j.ok) {
      close(); flash('Worktree created: ' + name, 2000);
      const w = j.worktree || {};
      const p = w.path || (w.worktree && w.worktree.path) || (w.result && w.result.path);
      if (p) selectedWtPath = p;
      applyLayout();
    } else { create.disabled = false; create.textContent = 'Create'; flash('Create failed: ' + ((j && j.error) || '?'), 3500, 'error'); }
  };
  create.onclick = submit; nameIn.addEventListener('keydown', (e) => { if (e.key === 'Enter') submit(); });
  btnRow.appendChild(cancel); btnRow.appendChild(create);
  box.appendChild(title); box.appendChild(nameIn); box.appendChild(baseIn); box.appendChild(note); box.appendChild(btnRow);
  ov.appendChild(box); document.body.appendChild(ov);
  setTimeout(() => nameIn.focus(), 0);
}
// auto worktree name (adjective-animal, avoids collisions). Math.random is fine in a browser.
const WT_ADJ = ['swift', 'calm', 'bold', 'bright', 'keen', 'brave', 'lucid', 'vivid', 'nimble', 'sunny', 'cosmic', 'amber', 'jade', 'coral', 'misty', 'rapid', 'solar', 'lunar'];
const WT_NOUN = ['otter', 'falcon', 'marlin', 'heron', 'lynx', 'ibex', 'wren', 'tern', 'puma', 'crane', 'fox', 'newt', 'koi', 'orca', 'seal', 'hawk', 'elk', 'carp'];
function randomWtName(repo) {
  const taken = new Set(((repo && repo.worktrees) || []).map((w) => w.displayName));
  for (let i = 0; i < 40; i++) {
    const n = WT_ADJ[Math.floor(Math.random() * WT_ADJ.length)] + '-' + WT_NOUN[Math.floor(Math.random() * WT_NOUN.length)];
    if (!taken.has(n)) return n;
  }
  return 'wt-' + Math.floor(Math.random() * 100000);
}
// apply layout: sidebar wanted -> check Orca (async), set class + re-render tree/sessions + re-measure terminal.
async function applyLayout() {
  _wtSig = ''; _abSig = '';   // layout switch/refresh = force re-render
  const want = FEAT.orca && tabPrefs.layout === 'sidebar' && !isCompact();
  if (want) await refreshOrca();
  const on = want && orcaReady;
  document.getElementById('app').classList.toggle('sidebar-on', on);
  if (want && !orcaReady) flash('Orca not running — the worktree sidebar needs Orca. Showing top tabs.', 3500);
  loadSessions();
  requestAnimationFrame(() => { try { fit.fit(); sendResize(); } catch (e) {} });
}
// settings modal — layout toggle + agents (name / command) editor.
function openSettings() {
  closeTabPops();
  const { ov, box } = makeModal(23, 'padding:16px;width:100%;max-width:460px;display:flex;flex-direction:column;max-height:82vh;');
  const title = uiTitle('Settings'); title.style.cssText += 'margin-bottom:14px;flex:0 0 auto;';
  box.appendChild(title);
  let mode = tabPrefs.layout;
  const lhd = document.createElement('div'); lhd.textContent = 'Layout'; lhd.style.cssText = 'font:600 12px system-ui;color:#8a92a6;margin-bottom:7px;flex:0 0 auto;';
  box.appendChild(lhd);
  const seg = document.createElement('div'); seg.style.cssText = 'display:flex;gap:8px;margin-bottom:6px;flex:0 0 auto;';
  const segBtns = {};
  const setSel = (b, on) => {
    b.style.background = on ? '#3d6aa0' : '#2b303b';
    b.style.borderColor = on ? '#5480b8' : 'rgba(255,255,255,.12)';
    b.style.color = on ? '#fff' : '#dde1e8';
  };
  const mkSeg = (val, label) => {
    const b = document.createElement('button'); b.textContent = label;
    b.style.cssText = 'flex:1;height:38px;border-radius:8px;border:1px solid;font:13px system-ui;';
    setSel(b, mode === val);
    b.onclick = () => { mode = val; for (const k in segBtns) setSel(segBtns[k], k === mode); };
    segBtns[val] = b; return b;
  };
  seg.appendChild(mkSeg('tabs', 'Top tabs (default)'));
  seg.appendChild(mkSeg('sidebar', 'Sidebar + agents (experimental)'));
  box.appendChild(seg);
  const lnote = document.createElement('div');
  lnote.textContent = "Sidebar = Orca worktree tree; top = the selected worktree's agents. Only on boxes running Orca (else top tabs). Phones keep top tabs.";
  lnote.style.cssText = 'font:11.5px/1.5 system-ui;color:#7b8296;margin:0 0 16px;flex:0 0 auto;';
  box.appendChild(lnote);
  const ahd = document.createElement('div'); ahd.textContent = 'Agents (top tabs)'; ahd.style.cssText = 'font:600 12px system-ui;color:#8a92a6;margin-bottom:7px;flex:0 0 auto;';
  box.appendChild(ahd);
  const listWrap = document.createElement('div'); listWrap.style.cssText = 'flex:1 1 auto;overflow-y:auto;min-height:52px;';
  box.appendChild(listWrap);
  const rows = [];
  const addRow = (label, cmd) => {
    const r = document.createElement('div'); r.style.cssText = 'display:flex;gap:7px;margin-bottom:7px;align-items:center;';
    const li = document.createElement('input'); li.value = label || ''; li.placeholder = 'Name';
    li.style.cssText = 'flex:0 0 34%;box-sizing:border-box;height:34px;padding:0 10px;' + UI_FIELD + 'font:13px system-ui;';
    const ci = document.createElement('input'); ci.value = cmd || ''; ci.placeholder = 'Command (e.g. claude)';
    ci.style.cssText = 'flex:1 1 auto;box-sizing:border-box;height:34px;padding:0 10px;' + UI_FIELD + 'font:13px ui-monospace,monospace;';
    ci.autocapitalize = 'off'; ci.autocomplete = 'off'; ci.spellcheck = false;
    const del = uiBtn('✕', 'ghost'); del.style.cssText += 'height:34px;flex:0 0 auto;padding:0 12px;';
    const entry = { li, ci };
    del.onclick = () => { const i = rows.indexOf(entry); if (i >= 0) rows.splice(i, 1); r.remove(); };
    r.appendChild(li); r.appendChild(ci); r.appendChild(del);
    rows.push(entry); listWrap.appendChild(r);
  };
  for (const a of tabPrefs.agents) addRow(a.label, a.cmd);
  const addBtn = uiBtn('+ Add agent', 'ghost'); addBtn.style.cssText += 'height:34px;flex:0 0 auto;margin-top:2px;';
  addBtn.onclick = () => addRow('', '');
  box.appendChild(addBtn);
  const foot = document.createElement('div'); foot.style.cssText = 'display:flex;gap:8px;justify-content:flex-end;margin-top:16px;flex:0 0 auto;';
  const cancel = uiBtn('Cancel', 'ghost'); const save = uiBtn('Save', 'primary');
  const close = () => { try { document.body.removeChild(ov); } catch (e) {} term.focus(); };
  cancel.onclick = close;
  save.onclick = () => {
    tabPrefs.layout = mode;
    tabPrefs.agents = rows.map((e) => ({ label: e.li.value.trim(), cmd: e.ci.value.trim() })).filter((a) => a.label && a.cmd);
    saveTabPrefs(true);   // immediate server source of truth (like theme — avoids reconnect clobber)
    applyLayout();
    close();
  };
  foot.appendChild(cancel); foot.appendChild(save);
  box.appendChild(foot);
  ov.appendChild(box); document.body.appendChild(ov);
}
// ---- file upload (clip icon -> file picker -> server upload -> [fileNNN](path) inserted) ----
function pickAndUploadFile() {
  const inp = document.createElement('input');
  inp.type = 'file';
  inp.style.display = 'none';
  inp.onchange = () => { const f = inp.files && inp.files[0]; if (f) uploadFile(f); try { document.body.removeChild(inp); } catch (e) {} };
  document.body.appendChild(inp);
  inp.click();
}
async function uploadFile(file) {
  showStatus('Uploading… ' + file.name);
  try {
    const buf = await file.arrayBuffer();
    const r = await fetch('upload-file', {
      method: 'POST',
      headers: { 'Content-Type': 'application/octet-stream', 'X-Filename': encodeURIComponent(file.name) },
      body: buf,
    });
    const j = await r.json();
    hideStatus();
    // like image paste — insert a [fileNNN](path) token into the active session (for the agent to Read)
    if (j.path) { insertUploadToken('file', j.n, j.path); flash('Uploaded · inserted a token in the terminal', 1800); }
    else flash('Upload failed: ' + (j.error || 'unknown'), 2500);
  } catch (e) { flash('Upload failed: ' + e.message, 2500); }
}

// ---- image annotate — draw on a recent uploaded image -> save as a new image + insert a token ----
const PENCIL_COLORS = ['#ef4444', '#f59e0b', '#facc15', '#22c55e', '#3b82f6', '#a855f7', '#111827', '#ffffff'];
const PENCIL_SIZES = [3, 6, 12];

async function openImageAnnotator() {
  let images = [];
  try {
    const r = await fetch('recent-images', { cache: 'no-store' });
    images = (await r.json()).images || [];
  } catch (e) {}
  const { ov, box } = makeModal(23, 'padding:16px;width:100%;max-width:560px;display:flex;flex-direction:column;gap:12px;');
  const hd = document.createElement('div'); hd.style.cssText = 'display:flex;align-items:baseline;gap:10px;';
  hd.appendChild(uiTitle('Annotate image'));
  const sub = document.createElement('div'); sub.textContent = 'Recent uploaded images — click to draw';
  sub.style.cssText = 'flex:1;color:#8a92a6;font:12.5px system-ui;';
  hd.appendChild(sub); box.appendChild(hd);
  const close = () => { try { document.body.removeChild(ov); } catch (e) {} term.focus(); };
  if (!images.length) {
    const empty = document.createElement('div');
    empty.textContent = 'No recent uploaded images — paste an image or upload a file and it appears here.';
    empty.style.cssText = 'color:#9aa0ad;font:13px/1.6 system-ui;padding:8px 2px;';
    box.appendChild(empty);
  } else {
    const grid = document.createElement('div'); grid.style.cssText = 'display:grid;grid-template-columns:repeat(3,1fr);gap:10px;';
    for (const im of images) {
      const cell = document.createElement('button');
      cell.style.cssText = 'padding:0;border:1px solid #3a4254;border-radius:8px;overflow:hidden;background:#171a24;cursor:pointer;aspect-ratio:4/3;';
      const thumb = document.createElement('img');
      thumb.src = im.url; thumb.alt = im.name; thumb.loading = 'lazy';
      thumb.style.cssText = 'width:100%;height:100%;object-fit:cover;display:block;';
      cell.appendChild(thumb);
      cell.addEventListener('pointerdown', (e) => e.preventDefault());
      cell.onclick = () => { close(); openDrawModal(im); };
      grid.appendChild(cell);
    }
    box.appendChild(grid);
  }
  const row = document.createElement('div'); row.style.cssText = 'display:flex;justify-content:flex-end;';
  const closeBtn = uiBtn('Close', 'ghost'); closeBtn.onclick = close; row.appendChild(closeBtn); box.appendChild(row);
  ov.onclick = (e) => { if (e.target === ov) close(); };
  ov.appendChild(box); document.body.appendChild(ov);
}

function openDrawModal(im) {
  const { ov, box } = makeModal(24, 'padding:14px;width:100%;max-width:1600px;display:flex;flex-direction:column;gap:10px;max-height:95vh;');

  // toolbar — color / width / undo / clear
  const tools = document.createElement('div'); tools.style.cssText = 'display:flex;align-items:center;gap:14px;flex-wrap:wrap;';
  let color = PENCIL_COLORS[0], size = PENCIL_SIZES[1];
  const sw = document.createElement('div'); sw.style.cssText = 'display:flex;gap:6px;align-items:center;'; const swBtns = [];
  PENCIL_COLORS.forEach((c) => {
    const s = document.createElement('button');
    s.style.cssText = 'width:22px;height:22px;border-radius:50%;cursor:pointer;background:' + c + ';border:2px solid ' + (c === color ? '#e8edf8' : 'transparent') + ';box-shadow:0 0 0 1px rgba(0,0,0,.4);';
    s.addEventListener('pointerdown', (e) => e.preventDefault());
    s.onclick = () => { color = c; swBtns.forEach((b, i) => { b.style.borderColor = PENCIL_COLORS[i] === c ? '#e8edf8' : 'transparent'; }); };
    swBtns.push(s); sw.appendChild(s);
  });
  tools.appendChild(sw);
  const sz = document.createElement('div'); sz.style.cssText = 'display:flex;gap:6px;align-items:center;'; const szBtns = [];
  PENCIL_SIZES.forEach((v) => {
    const b = document.createElement('button');
    b.style.cssText = 'width:30px;height:26px;display:flex;align-items:center;justify-content:center;border-radius:6px;cursor:pointer;background:' + (v === size ? '#33405a' : '#2b303b') + ';border:1px solid ' + (v === size ? '#5480b8' : 'rgba(255,255,255,.12)') + ';';
    const dot = document.createElement('span'); dot.style.cssText = 'width:' + (v + 2) + 'px;height:' + (v + 2) + 'px;border-radius:50%;background:#dfe4ec;display:block;';
    b.appendChild(dot); b.addEventListener('pointerdown', (e) => e.preventDefault());
    b.onclick = () => { size = v; szBtns.forEach((x, i) => { const on = PENCIL_SIZES[i] === v; x.style.background = on ? '#33405a' : '#2b303b'; x.style.borderColor = on ? '#5480b8' : 'rgba(255,255,255,.12)'; }); };
    szBtns.push(b); sz.appendChild(b);
  });
  tools.appendChild(sz);
  const spacer = document.createElement('div'); spacer.style.cssText = 'flex:1;'; tools.appendChild(spacer);
  const undoBtn = uiBtn('Undo', 'ghost'); const clrBtn = uiBtn('Clear all', 'ghost');
  tools.appendChild(undoBtn); tools.appendChild(clrBtn); box.appendChild(tools);

  // canvas
  const wrap = document.createElement('div');
  wrap.style.cssText = 'flex:1;min-height:0;overflow:auto;display:flex;align-items:center;justify-content:center;background:#12141c;border:1px solid #2a3142;border-radius:8px;';
  const canvas = document.createElement('canvas');
  canvas.style.cssText = 'max-width:100%;max-height:84vh;display:block;touch-action:none;cursor:crosshair;';
  wrap.appendChild(canvas); box.appendChild(wrap);
  const ctx = canvas.getContext('2d');

  // save / close
  const foot = document.createElement('div'); foot.style.cssText = 'display:flex;gap:8px;align-items:center;';
  const info = document.createElement('div'); info.textContent = im.path;
  info.style.cssText = 'flex:1;color:#8a92a6;font:12px ui-monospace,monospace;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';
  const saveBtn = uiBtn('Save', 'primary'); const closeBtn = uiBtn('Close', 'ghost');
  foot.appendChild(info); foot.appendChild(closeBtn); foot.appendChild(saveBtn); box.appendChild(foot);

  const strokes = []; let cur = null;
  const img = new Image();
  img.onload = () => {
    const cap = 2000, sc = Math.min(1, cap / Math.max(img.naturalWidth, img.naturalHeight));
    canvas.width = Math.max(1, Math.round(img.naturalWidth * sc));
    canvas.height = Math.max(1, Math.round(img.naturalHeight * sc));
    redraw();
  };
  img.onerror = () => { info.textContent = 'Could not load the image'; };
  img.src = im.url;

  function drawStroke(s) {
    ctx.strokeStyle = s.color; ctx.lineWidth = s.w; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    const p = s.pts;
    if (p.length === 1) { ctx.beginPath(); ctx.arc(p[0].x, p[0].y, s.w / 2, 0, 6.2832); ctx.fillStyle = s.color; ctx.fill(); return; }
    ctx.beginPath(); ctx.moveTo(p[0].x, p[0].y);
    for (let i = 1; i < p.length; i++) ctx.lineTo(p[i].x, p[i].y);
    ctx.stroke();
  }
  function redraw() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    if (img.complete && img.naturalWidth) ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    for (const s of strokes) drawStroke(s);
    if (cur) drawStroke(cur);
  }
  function nat(e) {
    const r = canvas.getBoundingClientRect();
    return { x: (e.clientX - r.left) * (canvas.width / r.width), y: (e.clientY - r.top) * (canvas.height / r.height) };
  }
  canvas.addEventListener('pointerdown', (e) => {
    e.preventDefault();
    const r = canvas.getBoundingClientRect();
    cur = { color, w: size * (canvas.width / r.width), pts: [nat(e)] };   // keep on-screen width constant (native-px conversion)
    try { canvas.setPointerCapture(e.pointerId); } catch (_) {}
    redraw();
  });
  canvas.addEventListener('pointermove', (e) => {
    if (!cur) return;
    const p = nat(e); const prev = cur.pts[cur.pts.length - 1]; cur.pts.push(p);
    ctx.strokeStyle = cur.color; ctx.lineWidth = cur.w; ctx.lineCap = 'round'; ctx.lineJoin = 'round';
    ctx.beginPath(); ctx.moveTo(prev.x, prev.y); ctx.lineTo(p.x, p.y); ctx.stroke();   // incremental draw (responsive)
  });
  const endStroke = () => { if (cur) { strokes.push(cur); cur = null; } };
  canvas.addEventListener('pointerup', endStroke);
  canvas.addEventListener('pointercancel', endStroke);
  undoBtn.onclick = () => { strokes.pop(); redraw(); };
  clrBtn.onclick = () => { strokes.length = 0; redraw(); };

  const close = () => { try { document.body.removeChild(ov); } catch (e) {} term.focus(); };
  closeBtn.onclick = close;
  ov.onclick = (e) => { if (e.target === ov) close(); };
  saveBtn.onclick = async () => {
    endStroke();
    let dataUrl = '';
    try { dataUrl = canvas.toDataURL('image/jpeg', 0.85); } catch (e) { info.textContent = 'Save failed (image security restriction)'; return; }
    saveBtn.disabled = true; saveBtn.textContent = 'Saving…';
    try {
      const j = await postJson('upload-image', { image: dataUrl });
      if (j.ok) { close(); insertUploadToken('image', j.n, j.path); flash('Saved · inserted a token in the terminal', 1800); }
      else { info.textContent = 'Save failed: ' + (j.error || ''); saveBtn.disabled = false; saveBtn.textContent = 'Save'; }
    } catch (e) { info.textContent = 'Save failed (network)'; saveBtn.disabled = false; saveBtn.textContent = 'Save'; }
  };

  ov.appendChild(box); document.body.appendChild(ov);
}

async function loadSessions() {
  let list = [];
  try {
    const r = await fetch('sessions', { cache: 'no-store' });
    list = (await r.json()).sessions || [];
  } catch (e) {}
  renderTabs(list);
}
// in sidebar (worktree) mode only, poll lightly so session creates/kills elsewhere show live on the left.
setInterval(() => { if (FEAT.orca && connected && effectiveLayout() === 'sidebar') loadSessions(); }, 2500);
// low-frequency worktree-tree refresh — reflect external worktree changes + fall back to top tabs if Orca dies.
setInterval(async () => {
  if (!(FEAT.orca && connected && tabPrefs.layout === 'sidebar' && !isCompact())) return;
  await refreshOrca();
  if (!orcaReady) { applyLayout(); return; }
  _wtSig = ''; renderTabs(liveSessions);
}, 9000);

// ---- touch scroll (one finger) — TOUCH_SCROLL multiplier + fractional accumulation for smoothness ----
const termEl = document.getElementById('term');
const TOUCH_SCROLL = 3.2;   // swipe-distance -> scroll multiplier
// zoom-state horizontal swipe -> move zoom to the adjacent pane. Axis-split from vertical scroll; edge starts ignored (iOS back).
const SWIPE_MIN = 45;       // horizontal-swipe threshold (px) — this much + 1.5x the vertical delta
const SWIPE_EDGE = 24;      // swipes starting within this many px of a screen edge are not armed (edge back-gesture)
let touchY = null, touchAcc = 0, touchPageAcc = 0, touchWheelAcc = 0;   // touchPageAcc=PageUp accumulator; touchWheelAcc=wheel fractional accumulator (3 lines=1 wheel)
let swipeX0 = 0, swipeY0 = 0, swipeState = 0, swipeArmed = false;       // swipeState: 0=undecided 1=horizontal / armed=zoomed+multi-pane+not-edge
termEl.addEventListener('touchstart', (e) => {
  if (e.touches.length === 1) {
    touchY = e.touches[0].clientY; touchAcc = 0; touchPageAcc = 0; touchWheelAcc = 0;
    swipeX0 = e.touches[0].clientX; swipeY0 = e.touches[0].clientY; swipeState = 0;
    const ew = window.innerWidth || document.documentElement.clientWidth || 0;
    swipeArmed = paneZoomed && panePanes > 1 && swipeX0 > SWIPE_EDGE && swipeX0 < ew - SWIPE_EDGE;
  }
}, { passive: true });
termEl.addEventListener('touchmove', (e) => {
  if (touchY === null || e.touches.length !== 1) return;
  e.preventDefault();             // block iOS native scroll/bounce — this handler owns touch scroll (non-passive required)
  if (swipeState === 1) return;   // this gesture is a horizontal swipe -> ignore vertical scroll
  if (swipeArmed) {
    const dx = e.touches[0].clientX - swipeX0, dy = e.touches[0].clientY - swipeY0;
    if (Math.abs(dx) >= SWIPE_MIN && Math.abs(dx) > 1.5 * Math.abs(dy)) {
      swipeState = 1;                 // horizontal confirmed -> move zoom once (right dx>0 = next pane)
      paneZoomSwipe(dx > 0);
      return;
    }
  }
  const y = e.touches[0].clientY;
  const lineH = Math.max(8, termEl.clientHeight / term.rows);
  touchAcc += ((touchY - y) / lineH) * TOUCH_SCROLL;     // apply multiplier + fractional accumulation (don't drop small moves)
  touchY = y;
  const lines = Math.trunc(touchAcc);
  if (lines === 0) return;
  if (MK.ctrl || MK.alt) clearMobileMods('scroll', true);   // start scrolling = release one-shot armed (hold persists)
  touchAcc -= lines;                                     // consume only the whole part; keep the fraction for next move
  if (term.buffer.active.type === 'normal') {
    term.scrollLines(lines);                             // normal screen: xterm scrollback
  } else if (term.modes && term.modes.mouseTrackingMode && term.modes.mouseTrackingMode !== 'none') {
    // alt-screen (tmux/fullscreen) + app has mouse tracking ON -> touch to wheel escapes -> tmux scroll.
    // claude etc scroll ~3 lines per wheel -> accumulate in wheel units (3 lines=1 wheel) for smoothness.
    touchWheelAcc += lines / 3;
    const raw = Math.trunc(touchWheelAcc);
    if (raw !== 0) {
      const send = Math.min(Math.abs(raw), 8);            // per-frame wheel cap (avoid runaway)
      const nW = raw < 0 ? -send : send;
      touchWheelAcc -= nW;                                // consume only what we sent -> carry the excess to the next frame
      const rect = termEl.getBoundingClientRect();
      const t = e.touches[0];
      const col = Math.max(1, Math.min(term.cols, Math.ceil((t.clientX - rect.left) / Math.max(1, termEl.clientWidth / term.cols))));
      const row = Math.max(1, Math.min(term.rows, Math.ceil((t.clientY - rect.top) / lineH)));
      const btn = nW < 0 ? 64 : 65;                       // 64=wheel up (back), 65=wheel down
      let out = '';
      for (let i = 0; i < send; i++) out += '\x1b[<' + btn + ';' + col + ';' + row + 'M';
      sendInput(out);
    }
  } else {
    // alt-screen but the app has mouse tracking OFF (claude non-interactive/dumb; vim/less/man mouse off).
    // Wheel escapes are ignored + alt-screen has no tmux scrollback -> use PageUp/PageDown keys.
    touchPageAcc += lines;
    const thr = Math.max(3, Math.floor(term.rows / 2));
    if (Math.abs(touchPageAcc) >= thr) {
      sendInput(touchPageAcc < 0 ? '\x1b[5~' : '\x1b[6~');   // 5~=PageUp (back) · 6~=PageDown
      touchPageAcc = 0;
    }
  }
}, { passive: false });   // non-passive so preventDefault works
termEl.addEventListener('touchend', () => { touchY = null; touchAcc = 0; touchPageAcc = 0; touchWheelAcc = 0; swipeState = 0; swipeArmed = false; }, { passive: true });

// ---- mouse wheel — alt-screen (claude/vim/less): xterm default is 1 line per notch (slow).
//      Same strategy as touch: mouse ON = multi wheel escapes / mouse OFF = PageUp/PageDown.
//      normal buffer (shell scrollback) = xterm default (return true).
const WHEEL_ALT = 1.6;                                   // alt-screen wheel multiplier
let wheelAcc = 0, wheelPageAcc = 0;
term.attachCustomWheelEventHandler((ev) => {
  if (term.buffer.active.type === 'normal') return true;   // shell scrollback = xterm default (scrollSensitivity)
  const lineH = Math.max(8, termEl.clientHeight / term.rows);
  const dLines = (ev.deltaMode === 1 ? ev.deltaY : ev.deltaY / lineH) * WHEEL_ALT;   // normalize line/pixel delta
  if (term.modes && term.modes.mouseTrackingMode && term.modes.mouseTrackingMode !== 'none') {
    wheelAcc += dLines;                                  // fractional accumulation (don't drop trackpad micro-moves)
    const n = Math.trunc(wheelAcc);
    if (n !== 0) {
      wheelAcc -= n;
      const rect = termEl.getBoundingClientRect();
      const col = Math.max(1, Math.min(term.cols, Math.ceil((ev.clientX - rect.left) / Math.max(1, termEl.clientWidth / term.cols))));
      const row = Math.max(1, Math.min(term.rows, Math.ceil((ev.clientY - rect.top) / lineH)));
      const btn = n < 0 ? 64 : 65;                        // 64=wheel up (back) · 65=wheel down
      let out = '';
      for (let i = 0; i < Math.min(Math.abs(n), 12); i++) out += '\x1b[<' + btn + ';' + col + ';' + row + 'M';
      sendInput(out);
    }
  } else {
    wheelPageAcc += dLines;                              // mouse OFF (claude not reporting etc) -> PageUp/PageDown
    const thr = Math.max(3, Math.floor(term.rows / 2));
    if (Math.abs(wheelPageAcc) >= thr) {
      sendInput(wheelPageAcc < 0 ? '\x1b[5~' : '\x1b[6~');
      wheelPageAcc = 0;
    }
  }
  return false;                                          // suppress xterm default (we handle it)
});

// ---- clipboard image paste -> server upload (~/uploads, 24h) -> insert the path token ----
async function uploadPastedImage(blob) {
  showStatus('Uploading image…');
  try {
    const jpeg = await blobToJpeg(blob);
    const res = await postJson('upload-image', { image: jpeg });
    if (res.ok) {                                                   // insert [imageNNN](path) -> the agent can Read it
      hideStatus();
      insertUploadToken('image', res.n, res.path);
    }
    else flash('Upload failed: ' + (res.error || ''), 2500);
  } catch (e) { flash('Upload error', 2500); }
  term.focus();
}
// Ctrl+V direct paste — image first, else text. xterm consumes the Ctrl+V keydown so no
//   native paste event fires -> read the clipboard directly via the API.
async function pasteFromClipboard() {
  if (!(navigator.clipboard && navigator.clipboard.read && window.isSecureContext)) {
    if (navigator.clipboard && navigator.clipboard.readText) {       // HTTP: try text only
      try { const t = await navigator.clipboard.readText(); if (t) pasteText(t); return; } catch (e) {}
    }
    flash('Paste needs a secure (HTTPS) context — limited over HTTP', 1800);
    return;
  }
  try {
    const items = await navigator.clipboard.read();
    for (const it of items) {                                        // image first
      const imgType = it.types.find((t) => t.indexOf('image/') === 0);
      if (imgType) { uploadPastedImage(await it.getType(imgType)); return; }
    }
    for (const it of items) {                                        // text
      if (it.types.includes('text/plain')) {
        const t = await (await it.getType('text/plain')).text();
        if (t) pasteText(t);
        return;
      }
    }
  } catch (e) {
    try { const t = await navigator.clipboard.readText(); if (t) pasteText(t); }
    catch (_) { flash('Clipboard access denied — allow it, then tap again', 2400); }
  }
}
function blobToJpeg(blob) {                                          // canvas -> JPEG(0.8), max 2000px
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(blob);
    const img = new Image();
    img.onload = () => {
      URL.revokeObjectURL(url);
      let { width, height } = img;
      const s = Math.min(1, 2000 / Math.max(width, height));
      width = Math.max(1, Math.round(width * s)); height = Math.max(1, Math.round(height * s));
      const c = document.createElement('canvas');
      c.width = width; c.height = height;
      c.getContext('2d').drawImage(img, 0, 0, width, height);
      resolve(c.toDataURL('image/jpeg', 0.8));
    };
    img.onerror = () => { URL.revokeObjectURL(url); reject(new Error('decode')); };
    img.src = url;
  });
}
window.addEventListener('paste', (e) => {                            // capture: before xterm's text-paste
  // This handler owns TERMINAL-targeted paste only. Paste into edit fields (copy-modal
  //   textarea, rename prompt) must go to native handling, so we leave those alone.
  const _toTerm = e.target && e.target.closest && e.target.closest('.xterm');
  if (!_toTerm) return;
  // Ctrl+V is already handled above via pasteFromClipboard. If the browser also fires a
  //   native paste, xterm would insert again ("twice"). If the guard is recent, swallow it.
  if (performance.now() - _pasteGuardAt < 600) { e.preventDefault(); e.stopPropagation(); return; }
  // iPad/mobile double: ⧉ etc already pasted via our pasteText; if native paste brings the
  //   same text soon after, swallow it. Content match + within 900ms only (unique pastes pass through).
  const _pt = e.clipboardData && e.clipboardData.getData && e.clipboardData.getData('text/plain');
  if (_pt && _pt === _lastPaste.t && performance.now() - _lastPaste.at < 900) { e.preventDefault(); e.stopPropagation(); return; }
  const items = (e.clipboardData && e.clipboardData.items) || [];
  for (const it of items) {
    if (it.type && it.type.indexOf('image/') === 0) {
      const blob = it.getAsFile();
      if (blob) { e.preventDefault(); e.stopPropagation(); uploadPastedImage(blob); }
      return;
    }
  }
  // Single-source the text (iPad Cmd+V / long-press double): intercept, preventDefault
  //   (block insert) + stopPropagation (block xterm's own paste) then pasteText once.
  if (_pt) { e.preventDefault(); e.stopPropagation(); pasteText(_pt); }
}, true);

// Shift+drag etc (xterm native selection) auto-copy (HTTPS secure context only).
function autoCopySelection() {
  if (!(navigator.clipboard && window.isSecureContext)) return;
  const s = term.getSelection();
  if (s) navigator.clipboard.writeText(s).catch(function () {});
}
term.onSelectionChange(autoCopySelection);   // Chrome etc: auto-copy on selection change (quietly)
// Safari blocks gesture-less clipboard writes -> drag auto-copy fails and execCommand 'lies'.
//   So don't assume success; point to the sure path (⧉ = a click gesture that opens the selection in a modal).
if (term.element) term.element.addEventListener('mouseup', function () {
  const s = term.getSelection();
  if (!s) return;                               // plain click / tmux drag (no xterm selection) -> nothing
  if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(s).catch(function () {});   // best-effort — Chrome already copied here (Safari fails silently)
  flash('Selected ' + s.length + ' chars — press ⧉ to copy', CLIP_NOTICE_MS, 'notice');   // ⧉ opens this selection in a modal (a click, sure on Safari)
  pulseCopyIcon();
});
// Cmd+C (copy) — put the xterm selection on the copy event. Works on every browser + HTTP/HTTPS (Safari OK).
document.addEventListener('copy', function (e) {
  // Cmd+C in an edit field (copy-modal textarea etc, outside the terminal) is owned by that field.
  const t = e.target;
  if (t && t.closest && t.closest('.copy-overlay, input, textarea') && !t.closest('.xterm')) return;
  const s = term.getSelection();
  if (s && e.clipboardData) { e.clipboardData.setData('text/plain', s); e.preventDefault(); }
});

// ---- misc ----
window.addEventListener('contextmenu', (e) => e.preventDefault());
// #app height = the actually-visible viewport. Normally fixed to the layout viewport
// (innerHeight) so small changes (Safari toolbar collapse) don't jitter. Only when the
// bottom is largely covered (> KB_MIN, i.e. the soft keyboard) shrink to
// visualViewport.height so the bottom (TUI input line, #mkeys bar) rises above it.
const appEl = document.getElementById('app');
const vpt = window.visualViewport;
const KB_MIN = 150;                       // covered by more than this = 'keyboard' (toolbar/address bar collapse < 100px ignored)
function viewH() {
  const inner = window.innerHeight;
  if (!vpt) return inner;                 // no visualViewport -> keep innerHeight
  return (inner - vpt.height) > KB_MIN ? Math.round(vpt.height) : inner;   // shrink only while the keyboard is up
}
function fitResize() {
  appEl.style.height = viewH() + 'px';
  appEl.style.transform = '';             // no transform sliding — height only, top tabs stay put
  // measure after layout settles (rAF) — fitting right after a height change uses stale dims and clips the last row.
  requestAnimationFrame(function () {
    try {
      const d = fit.proposeDimensions();
      if (d && d.cols > 0 && d.rows > 0 && (d.cols !== term.cols || d.rows !== term.rows)) term.resize(d.cols, d.rows);
    } catch (e) {}
    sendResize();
  });
}
window.addEventListener('resize', fitResize);
window.addEventListener('orientationchange', () => { clearMobileMods('orient'); setTimeout(fitResize, 300); });
window.addEventListener('blur', () => clearMobileMods('blur'));
// keyboard open/close = visualViewport 'resize'. Debounce so we reflow once after the animation settles.
let vptTimer = null;
if (vpt) vpt.addEventListener('resize', function () {
  touchY = null; touchAcc = 0;
  clearTimeout(vptTimer);
  vptTimer = setTimeout(fitResize, 120);
});
fitResize();
document.addEventListener('visibilitychange', () => {
  if (document.hidden) { clearMobileMods('hidden'); return; }
  if (!connected) connect(); loadSessions(); refreshPaneZoom();
});
window.addEventListener('online', () => { if (!connected) connect(); });
window.addEventListener('focus', () => { if (!connected) connect(); });

/* ---- iOS Safari/WebKit CJK IME composition fix (send only completed syllables + settle) ----
 * iOS does not fire compositionstart/update/end for CJK (isComposing=false). Per keystroke the
 * textarea is re-composed via deleteContentBackward + insertText, so its value is always correct.
 * We forward only the completed, stable PREFIX to the PTY. The last (possibly still-composing)
 * syllable is held (KOREAN_TAIL) and flushed on the next char / space / Enter / navigation key.
 * A key's del+ins is merged with setTimeout(0) so mid-composition jitter doesn't send a bad DEL.
 * iOS-only, !isComposing (Japanese/Chinese use the xterm default).
 */
if (NEEDS_IME_MIRROR && term.textarea && term.element) {
  const ta = term.textarea;
  const host = term.element;
  let sent = '';                        // prefix forwarded to the PTY (grows on advance, shrinks only on backspace)
  let composing = false;
  let scheduled = false;

  // holds the last char if the value ends in a composable CJK (Jamo / Compat Jamo / Syllables)
  const KOREAN_TAIL = /[\u1100-\u11ff\u3130-\u318f\uac00-\ud7a3]$/;
  const TEXT_INPUTS = new Set(['insertText', 'insertReplacementText', 'deleteContentBackward']);
  const lcp = (a, b) => {
    const n = Math.min(a.length, b.length); let i = 0;
    while (i < n && a.charCodeAt(i) === b.charCodeAt(i)) i++;
    return i;
  };
  const stablePrefix = (v, force) => (force || !KOREAN_TAIL.test(v)) ? v : v.slice(0, -1);

  // preedit overlay — show the not-yet-sent composing syllable at the cursor (visual only).
  const preedit = document.createElement('span');
  preedit.style.cssText = 'position:absolute;z-index:5;pointer-events:none;white-space:pre;' +
    'color:#e6e6e6;text-decoration:underline;display:none;';
  preedit.style.font = (term.options.fontSize || 14) + 'px/1 ' +
    (term.options.fontFamily || 'monospace');
  (ta.parentElement || host).appendChild(preedit);
  const updatePreedit = () => {
    const composingText = ta.value.startsWith(sent) ? ta.value.slice(sent.length) : ta.value;
    if (composingText) {
      preedit.textContent = composingText;
      preedit.style.font = (term.options.fontSize || 14) + 'px/1 ' + (term.options.fontFamily || 'monospace');
      preedit.style.left = ta.style.left || '0px';
      preedit.style.top = ta.style.top || '0px';
      preedit.style.display = '';
    } else {
      preedit.style.display = 'none';
    }
  };

  const rebase = () => { sent = ''; try { ta.value = ''; } catch (e) {} preedit.style.display = 'none'; };

  function flushStable(force) {
    const held = stablePrefix(ta.value, force);
    if (held === sent) return;
    const common = lcp(sent, held);
    let out = '';
    if (common < sent.length) out += '\x7f'.repeat([...sent.slice(common)].length);  // real backspaces only
    out += held.slice(common);                                                       // newly confirmed syllables
    // iOS textarea may insert NBSP (U+00A0) etc as spaces, breaking bash word-splitting on the PTY. Normalize to ASCII space.
    if (out) sendInput(out.replace(/[\u00a0\u2000-\u200a\u202f\u205f\u3000\u2060\ufeff]/g, ' '));
    sent = held;
  }
  function scheduleFlush() {   // merge a key's del+ins (settle) so jitter doesn't cause a bad DEL
    if (scheduled) return;
    scheduled = true;
    setTimeout(() => {
      scheduled = false;
      flushStable(false);
      if (sent === ta.value && !KOREAN_TAIL.test(ta.value)) rebase();   // completed (space etc) -> shrink the buffer
      else updatePreedit();                                            // composing -> show it live
    }, 0);
  }

  ta.addEventListener('compositionstart', () => { composing = true; });
  ta.addEventListener('compositionend', () => { composing = false; });

  host.addEventListener('input', (ev) => {
    // if the keydown interceptor already consumed an armed mod (incl HOLD), drop this input — must come before the armed branch.
    if (MK.guard) { MK.guard = false; ev.stopImmediatePropagation(); rebase(); return; }
    // mobile armed modifiers (iOS deterministic path): iOS input is more reliable than keydown.
    if (MK.active && (MK.ctrl || MK.alt || MK.hold) && ev.inputType === 'insertText') {
      if (typeof ev.data === 'string' && ev.data.length === 1) {
        const code = ev.data.charCodeAt(0);
        if (code >= 0x20 && code <= 0x7e) {
          const seq = mkApplyArmed(ev.data);
          if (seq !== null) {
            sendInput(seq);
            ev.stopImmediatePropagation();
            rebase();                                    // reset textarea/sent/preedit (avoid double send)
            mkConsumeOneShot();
            return;
          }
        }
      }
      // armed but not applicable (CJK / multi / unmapped) -> release one-shot then normal input.
      if (!MK.hold) clearMobileMods('non-applicable-input', true);
    }
    if (ev.isComposing || composing) return;            // real IME (JP/CN) -> xterm
    if (!TEXT_INPUTS.has(ev.inputType)) return;          // control/paste -> xterm
    ev.stopPropagation();                                // block xterm textarea input send
    scheduleFlush();
  }, true);

  host.addEventListener('keydown', (ev) => {
    if (composing) return;
    if (ev.key === 'Backspace' || ev.keyCode === 8) {
      if (ta.value.length > 0) ev.stopPropagation();     // composing char present -> the input path handles DEL
      return;
    }
    if (['Enter', 'Tab', 'Escape', 'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End'].includes(ev.key)) {
      flushStable(true);                                 // force-flush the held syllable
      setTimeout(rebase, 0);
      return;
    }
    // printable single keys (latin/space/symbols) are also sent by xterm on keydown (esp. space) -> block in the DOM.
    if (!ev.ctrlKey && !ev.metaKey && !ev.altKey && ev.key && ev.key.length === 1) {
      ev.stopPropagation();
    }
  }, true);

  // Physical keyboards (desktop Safari etc) also send chars via keypress -> block in capture (avoid double send).
  host.addEventListener('keypress', (ev) => {
    if (composing) return;
    if (ev.ctrlKey || ev.metaKey || ev.altKey) return;
    if (ev.key && ev.key.length === 1) ev.stopPropagation();
  }, true);
}

applyMobileKeys();                     // decide mobile key bar + build top controls (pane-zoom, more)
try {                                  // re-decide on viewport/pointer change (rotate, resize, device change)
  matchMedia('(pointer:coarse)').addEventListener('change', applyMobileKeys);
  matchMedia('(max-width:820px)').addEventListener('change', applyMobileKeys);
  matchMedia('(max-width:820px)').addEventListener('change', applyLayout);    // auto-fallback sidebar<->top tabs on compact enter/exit
  matchMedia('(max-height:520px)').addEventListener('change', applyLayout);
} catch (e) {}
applyLayout();   // apply layout class + render session/agent bar (calls loadSessions inside)
initSession();
})();
