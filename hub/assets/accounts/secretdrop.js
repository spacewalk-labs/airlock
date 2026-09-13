'use strict';
/*
 * secretdrop.js — the secret drop: the value is typed into a modal, stored in a file on
 *   this box, and what leaves is a PATH TOKEN, never the value.
 *
 * Why it exists: handing an agent (or a shell) an API key by typing it into a prompt puts
 *   the secret into chat scrollback, terminal history and any log that captures either.
 *   A path is safe to repeat; the file behind it expires on its own.
 *
 * Owner: the PLATFORM (hub/assets/accounts/, served by the platform surface under
 *   /airlock-accounts/ — docs/tasks/active/platform-secret-drop.md). One implementation,
 *   two framings: panel.html on the hub origin (the Airlock widget's "Secret drop", no
 *   terminal) and devterm's terminal, which loads this same file through an nginx alias
 *   and injects only what a terminal knows — delivery and which box the session is on.
 *   The API paths below are RELATIVE on purpose: on the hub they resolve under
 *   /airlock-accounts/, on devterm's origin to its proxy of the same platform routes.
 *
 * DI factory: window.initSecretDrop(deps) -> { openSecretDrop, renderSecretPanel }
 *   deps = {
 *     flash, postJson,          // required
 *     sendInput,   // a function => TERMINAL MODE (devterm): type the token into the
 *                  //   terminal and copy it too. Absent => CLIPBOARD MODE (panel):
 *                  //   store, then copy the token — the user chooses where to paste.
 *     tokenTarget, // (path) => what the token should point at. For a remote devterm
 *                  //   session that is `ssh <box> cat <path>`. Default: path.
 *     readCmd,     // (path) => the shell command that reads the file. Default: cat <path>.
 *     refocus,     // () => where focus returns after a copy / close. Default: nothing.
 *   }
 * Self-contained: no page globals. It used to lean on devterm's ui.js, which made a
 * platform asset depend on one app's helper file being loaded first on every page that
 * shows it. The few primitives it needs are below, copied from that file at the move.
 */
window.initSecretDrop = function initSecretDrop(deps) {
  const flash = deps.flash, postJson = deps.postJson;
  const sendInput = typeof deps.sendInput === 'function' ? deps.sendInput : null;
  const terminalMode = !!sendInput;
  const tokenTarget = deps.tokenTarget || function (path) { return path; };
  const readCmd = deps.readCmd || function (path) { return 'cat ' + path; };
  const refocus = typeof deps.refocus === 'function' ? deps.refocus : function () {};

  // ---- primitives (private; same tone as devterm's ui.js, owned here) ----
  const UI_FIELD = 'background:#171a24;color:#f2f5fa;border:1px solid #3a4254;border-radius:8px;';
  const UI_PANEL = 'background:#202431;border:1px solid #3a4254;border-radius:10px;box-shadow:0 16px 44px rgba(0,0,0,.42);box-sizing:border-box;';
  function uiTitle(text) { const d = document.createElement('div'); d.textContent = text; d.style.cssText = 'font:600 14.5px system-ui;color:#f2f5fa;'; return d; }
  function uiBtn(label, kind) {
    const b = document.createElement('button'); b.textContent = label;
    const base = 'height:36px;border-radius:8px;font:14px system-ui;border:1px solid ';
    if (kind === 'primary') b.style.cssText = base + '#5480b8;background:#3d6aa0;color:#fff;padding:0 18px;';
    else if (kind === 'danger') b.style.cssText = base + '#5a3330;background:#2b303b;color:#e06a5a;padding:0 14px;';
    else b.style.cssText = base + 'rgba(255,255,255,.12);background:#2b303b;color:#dde1e8;padding:0 14px;';
    return b;
  }
  function mkCloseBtn(onClose) {
    const x = document.createElement('button');
    x.type = 'button'; x.textContent = '✕';
    x.setAttribute('aria-label', 'Close'); x.title = 'Close (Esc)';
    x.style.cssText = 'flex:0 0 auto;display:flex;align-items:center;justify-content:center;width:40px;height:34px;background:#3a4254;border:none;border-radius:8px;color:#fff;font-size:20px;line-height:1;cursor:pointer;';
    x.addEventListener('click', onClose);
    return x;
  }
  // The overlay keeps devterm's `copy-overlay` class: devterm's terminal looks for it to
  // decide not to steal focus or keys while a modal is open (apps/devterm/web/app.js).
  function makeModal(z, boxCss) {
    const ov = document.createElement('div');
    ov.className = 'copy-overlay';
    ov.style.cssText = 'position:fixed;inset:0;display:flex;align-items:center;justify-content:center;padding:20px;background:rgba(0,0,0,.55);z-index:' + z + ';';
    const box = document.createElement('div');
    box.style.cssText = UI_PANEL + boxCss;
    return { ov: ov, box: box };
  }
  // On HTTP (non-secure) navigator.clipboard is blocked -> execCommand fallback. writeText
  // is called synchronously so the user-gesture context survives. Safari needs the
  // off-screen, readonly, setSelectionRange shape below — opacity:0 fakes success there.
  function copyText(text) {
    if (!text) return Promise.resolve(false);
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text).then(() => true, () => copyFallback(text));
    }
    return Promise.resolve(copyFallback(text));
  }
  function copyFallback(text) {
    const t = document.createElement('textarea');
    t.value = text;
    t.setAttribute('readonly', '');
    t.style.cssText = 'position:absolute;left:-9999px;top:0;font-size:12pt;';
    document.body.appendChild(t);
    const sel = document.getSelection();
    const prevSel = sel && sel.rangeCount > 0 ? sel.getRangeAt(0) : null;
    t.focus();
    t.select();
    try { t.setSelectionRange(0, text.length); } catch (e) {}
    let ok = false;
    try { ok = document.execCommand('copy'); } catch (e) {}
    document.body.removeChild(t);
    if (prevSel) { const g = document.getSelection(); g.removeAllRanges(); g.addRange(prevSel); }
    refocus();
    return ok;
  }

  const secretPath = (name) => '~/.devterm-secrets/' + name + '.txt';
  // The agent-facing token is not the value, it is where the value is — same markdown
  // link shape devterm already uses for uploads.
  const secretTokenStr = (name) => '[secret:' + name + '](' + tokenTarget(secretPath(name)) + ') ';
  // The shell-facing form reads the file into an env var. For a remote session readCmd
  // reaches the right box.
  const secretExportStr = (name) => 'export ' + name + '=$(' + readCmd(secretPath(name)) + ')';

  const remainText = (sec) => {
    const n = Math.max(0, Number(sec) || 0);
    return n >= 60 ? Math.ceil(n / 60) + ' min left' : n + 's left';
  };

  /* The UI body, drawn into `host`. close = how to dismiss (remove the modal / ask the
     parent to). ownsChrome = this UI draws its own title bar, which is true only when
     nothing above it already does. Terminal and clipboard mode differ in ONE place
     (delivery); saving, validation, the list and deletion are shared. */
  function renderSecretUI(host, close, ownsChrome) {
    let closed = false, busy = false;
    const deliveryBtns = [], deleteBtns = [];
    const markClosed = () => { closed = true; };

    // This container owns its own layout. Relying on the host's flex gap meant that when
    // drawn into a plain panel div (no gap) every label, field and button ran together
    // into one block. 14px between groups / 5px label-to-field is what makes a label
    // read as belonging to the field under it.
    const wrap = document.createElement('div');
    wrap.style.cssText = 'display:flex;flex-direction:column;gap:14px;';
    host.appendChild(wrap);
    const group = (gap) => {
      const g = document.createElement('div');
      g.style.cssText = 'display:flex;flex-direction:column;gap:' + (gap || 5) + 'px;';
      wrap.appendChild(g); return g;
    };
    const mkLabel = (text) => {
      const d = document.createElement('div'); d.textContent = text;
      d.style.cssText = 'color:#c3c9d4;font:600 12px system-ui;letter-spacing:.2px;';
      return d;
    };

    // Title only when this UI owns its window — devterm's modal, whose makeModal() draws
    // no header at all. Keyed on ownsChrome, NOT on `close`: the embedded panel is handed
    // a close action so its buttons work, but the widget's modal already draws the title
    // and the X above it, so keying on `close` drew both and the header appeared twice.
    const hd = document.createElement('div'); hd.style.cssText = 'display:flex;align-items:center;gap:10px;';
    if (ownsChrome) hd.appendChild(uiTitle('Secret drop'));
    const sub = document.createElement('div');
    sub.textContent = terminalMode ? 'The value stays in this modal; the terminal gets only a path'
                                   : 'The value stays in this window; only a path is copied out';
    sub.style.cssText = 'flex:1;color:#8a92a6;font:12.5px/1.45 system-ui;'; hd.appendChild(sub);
    if (ownsChrome && close) hd.appendChild(mkCloseBtn(close));
    wrap.appendChild(hd);

    const nameIn = document.createElement('input');
    nameIn.type = 'text'; nameIn.placeholder = 'GH_TOKEN';
    nameIn.autocomplete = 'off'; nameIn.autocorrect = 'off'; nameIn.autocapitalize = 'off'; nameIn.spellcheck = false;
    nameIn.style.cssText = 'width:100%;box-sizing:border-box;height:38px;padding:0 12px;' + UI_FIELD + 'font:14px ui-monospace,monospace;';
    const valueIn = document.createElement('textarea');
    valueIn.rows = 6; valueIn.autocomplete = 'off'; valueIn.autocorrect = 'off'; valueIn.autocapitalize = 'off'; valueIn.spellcheck = false;
    valueIn.style.cssText = 'width:100%;box-sizing:border-box;min-height:104px;resize:vertical;padding:10px 12px;' + UI_FIELD + 'font:13px ui-monospace,monospace;line-height:1.45;';
    const nameGroup = group(); nameGroup.appendChild(mkLabel('Name')); nameGroup.appendChild(nameIn);
    const valueGroup = group(); valueGroup.appendChild(mkLabel('Value')); valueGroup.appendChild(valueIn);
    const note = document.createElement('div');
    note.textContent = 'Stored only in ~/.devterm-secrets/ on this box and deleted automatically ' +
                       'when it expires. Surrounding whitespace is stripped; line endings become LF.';
    note.style.cssText = 'margin-top:-7px;color:#8a92a6;font:11.5px/1.5 system-ui;';
    valueGroup.appendChild(note);

    // Shown only when delivery failed (terminal disconnected / clipboard refused): keep
    // the token visible so it can be copied again. Failing quietly would leave the user
    // believing the secret was delivered.
    const fallback = document.createElement('div');
    fallback.style.cssText = 'display:none;align-items:center;gap:8px;flex-wrap:wrap;padding:8px 10px;border:1px solid #8a4b4b;border-radius:7px;background:#2c2025;';
    const fallbackMsg = document.createElement('span'); fallbackMsg.style.cssText = 'flex:1;min-width:220px;color:#ffb4ad;font:12px/1.4 system-ui;';
    const fallbackTok = document.createElement('input');
    fallbackTok.type = 'text'; fallbackTok.readOnly = true; fallbackTok.spellcheck = false;
    fallbackTok.style.cssText = 'flex:1 1 100%;box-sizing:border-box;height:32px;padding:0 10px;' + UI_FIELD + 'font:12px ui-monospace,monospace;';
    const fallbackCopy = uiBtn('Copy path token', 'ghost');
    fallback.appendChild(fallbackMsg); fallback.appendChild(fallbackTok); fallback.appendChild(fallbackCopy);

    const listEl = document.createElement('div'); listEl.style.cssText = 'display:flex;flex-direction:column;gap:6px;min-height:28px;';

    let exportBtn;
    const exportHint = document.createElement('div'); exportHint.style.cssText = 'color:#e2c37b;font:11px/1.4 system-ui;';
    const setBusy = (on) => {
      busy = on;
      deliveryBtns.forEach((b) => { b.disabled = on; });
      deleteBtns.forEach((b) => { b.disabled = on; });
      if (exportBtn) updateExportGuard();
    };
    const updateExportGuard = () => {
      const valid = /^[A-Za-z_][A-Za-z0-9_]*$/.test(nameIn.value);
      exportBtn.disabled = busy || !valid;
      // An EMPTY name is guidance, not a warning — nothing is wrong yet, so it stays
      // grey. Amber only once something was typed that a shell cannot accept.
      const empty = !nameIn.value;
      exportHint.style.color = empty || valid ? '#8a92a6' : '#e2c37b';
      exportHint.textContent = empty
        ? 'An export statement needs a shell variable name (A-Z, 0-9, _).'
        : valid
          ? (terminalMode ? 'An exported value outlives the file — it stays in this shell and its children.'
                          : 'Copies an export statement — the value stays in whatever shell you paste it into.')
          : 'Cannot export — use a shell variable name (A-Z, 0-9, _).';
    };
    const showFallback = (msg, token) => {
      fallback.style.display = 'flex';
      fallbackMsg.textContent = msg;
      fallbackTok.value = token;
      fallbackCopy.onclick = () => copyText(token).then((ok) => flash(
        ok ? 'Path token copied' : 'Copy failed — select the token above and copy it', 3200, ok ? undefined : 'error'));
    };
    const saveAndDeliver = async (kind) => {
      const name = nameIn.value, value = valueIn.value;
      setBusy(true);
      let j = null;
      try { j = await postJson('secret-put', { name: name, value: value }); } catch (e) {}
      if (closed) return;
      if (!j || !j.ok) {
        setBusy(false);
        // Do not swallow the reason: a bad name, an oversized value and a storage failure
        // each call for a different action.
        flash('Could not store the secret' + (j && j.error ? ': ' + j.error : ''), 3000, 'error');
        return;
      }
      const token = kind === 'export' ? secretExportStr(name) : secretTokenStr(name);
      if (terminalMode) {
        const sent = sendInput(token);
        if (!sent) {
          showFallback('Terminal disconnected — reconnect and deliver again.', token);
          copyText(token).then((ok) => flash(
            ok ? 'Disconnected — the path token was copied to the clipboard'
               : 'Disconnected — use the copy button below', 5200, 'error'));
        } else {
          if (valueIn.value === value) valueIn.value = '';
          // Copy it as well: the same token often has to go into another window too.
          // The clipboard gets the PATH TOKEN, never the secret itself.
          const base = kind === 'export' ? 'Sent the export to the shell' : 'Sent the path to the agent';
          copyText(token).then((ok) => flash(
            base + (ok ? ' · also copied' : ' (clipboard copy failed)'),
            ok ? 2200 : 3200, ok ? undefined : 'error'));
        }
      } else {
        // Clipboard mode (panel) — the user decides where it goes.
        const ok = await copyText(token);
        if (closed) return;
        if (ok) {
          if (valueIn.value === value) valueIn.value = '';
          fallback.style.display = 'none';
          flash((kind === 'export' ? 'Export statement' : 'Path token') + ' copied — paste it where you need it', 2600);
        } else {
          showFallback('The clipboard copy was refused — copy the token below.', token);
          flash('Stored · clipboard copy failed', 5200, 'error');
        }
      }
      setBusy(false);
      loadList();
    };

    // Buttons are only as wide as their label. With the export button on flex:1 it took
    // half the row and outranked the primary action.
    const actionGroup = group(8);
    const actions = document.createElement('div'); actions.style.cssText = 'display:flex;align-items:center;gap:8px;flex-wrap:wrap;';
    const agentBtn = uiBtn(terminalMode ? 'Send to agent' : 'Store and copy path', 'primary');
    agentBtn.onclick = () => saveAndDeliver('agent'); deliveryBtns.push(agentBtn);
    exportBtn = uiBtn(terminalMode ? 'Export in shell' : 'Copy export statement', 'ghost');
    exportBtn.onclick = () => saveAndDeliver('export'); deliveryBtns.push(exportBtn);
    actions.appendChild(agentBtn); actions.appendChild(exportBtn);
    if (close) { const cancelBtn = uiBtn('Close', 'ghost'); cancelBtn.onclick = close; actions.appendChild(cancelBtn); }
    actionGroup.appendChild(actions); actionGroup.appendChild(exportHint);
    wrap.appendChild(fallback);

    // The stored list is a different concern from the input above it, so a rule separates
    // them — spacing alone read as one continuous form.
    const listSec = group(7);
    const rule = document.createElement('div');
    rule.style.cssText = 'height:1px;background:rgba(255,255,255,.09);margin:2px 0 1px;';
    listSec.appendChild(rule);
    listSec.appendChild(mkLabel('Live secrets'));
    listSec.appendChild(listEl);
    nameIn.addEventListener('input', updateExportGuard); updateExportGuard();

    const loadList = async () => {
      deleteBtns.length = 0;
      listEl.textContent = 'Loading…';
      try {
        const j = await fetch('secret-list', { cache: 'no-store' }).then((r) => r.json());
        if (closed) return;
        if (!j || !j.ok) throw new Error('list');
        listEl.textContent = '';
        if (!Array.isArray(j.secrets) || !j.secrets.length) {
          const empty = document.createElement('div');
          empty.textContent = 'No stored secrets';
          empty.style.cssText = 'color:#7f8798;font:12px system-ui;padding:4px 0;';
          listEl.appendChild(empty);
          return;
        }
        for (const item of j.secrets) {
          const row = document.createElement('div');
          row.style.cssText = 'display:flex;align-items:center;gap:8px;padding:6px 8px;border:1px solid rgba(255,255,255,.08);border-radius:7px;background:#191d27;';
          const info = document.createElement('div'); info.style.cssText = 'flex:1;min-width:0;display:flex;flex-direction:column;gap:2px;';
          const nm = document.createElement('div'); nm.textContent = item.name;
          nm.style.cssText = 'color:#e6e6e6;font:13px ui-monospace,monospace;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';
          const meta = document.createElement('div');
          meta.textContent = String(item.bytes) + 'B · ' + remainText(item.remain_sec);
          meta.style.cssText = 'color:#8a92a6;font:11px system-ui;';
          info.appendChild(nm); info.appendChild(meta);
          // Re-fetch the path of an already-stored secret (to paste it somewhere else) —
          // the token only, never the value.
          const again = uiBtn('Copy path', 'ghost'); again.style.cssText += 'height:30px;padding:0 10px;font-size:12px;';
          again.onclick = () => copyText(secretTokenStr(item.name)).then((ok) => flash(
            ok ? 'Path token copied' : 'Copy failed', ok ? 1800 : 3000, ok ? undefined : 'error'));
          const del = uiBtn('Delete', 'danger'); del.style.cssText += 'height:30px;padding:0 10px;font-size:12px;'; del.disabled = busy;
          del.onclick = async () => {
            setBusy(true);
            let d = null;
            try { d = await postJson('secret-del', { name: item.name }); } catch (e) {}
            if (closed) return;
            if (!d || !d.ok) flash('Could not delete the secret', 3000, 'error');
            else flash('Secret deleted', 1500);
            await loadList();
            setBusy(false);
          };
          deleteBtns.push(del); row.appendChild(info); row.appendChild(again); row.appendChild(del);
          listEl.appendChild(row);
        }
      } catch (e) {
        if (closed) return;
        listEl.textContent = 'Could not load the list';
        listEl.style.cssText += 'color:#e06a5a;font:12px system-ui;';
      }
    };

    nameIn.focus();
    loadList();
    return { markClosed: markClosed };
  }

  // devterm — a modal (overlay + Esc + backdrop click).
  function openSecretDrop() {
    const { ov, box } = makeModal(24, 'padding:16px;width:100%;max-width:520px;display:flex;flex-direction:column;gap:10px;max-height:92vh;overflow:auto;');
    let ui = null, closed = false;
    const close = () => {
      if (closed) return;
      closed = true;
      if (ui) ui.markClosed();
      document.removeEventListener('keydown', onKey);
      try { document.body.removeChild(ov); } catch (e) {}
      refocus();
    };
    const onKey = (e) => { if (e.key === 'Escape') close(); };
    document.addEventListener('keydown', onKey);
    ui = renderSecretUI(box, close, true);   // makeModal draws no header — this UI is the window
    ov.addEventListener('mousedown', (e) => { if (e.target === ov) close(); });
    ov.appendChild(box); document.body.appendChild(ov);
  }

  // panel.html — never owns its own title bar. Embedded, the widget's modal draws it;
  // standalone, panel.html's own #top does. Either way ownsChrome is false, while `close`
  // still drives the Close button in the action row.
  function renderSecretPanel(container, close) { return renderSecretUI(container, close || null, false); }

  return { openSecretDrop: openSecretDrop, renderSecretPanel: renderSecretPanel };
};
