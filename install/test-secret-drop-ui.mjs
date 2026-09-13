#!/usr/bin/env node
/* Dependency-free contract checks for the platform secret drop's frontend.
 *
 * Three things are pinned here, each exercised for real (the shipped files run in a vm
 * against a DOM shim) rather than grepped, so a refactor that keeps the words but
 * restores a coupling still fails:
 *
 *   1. Window chrome. The title bar is the *window's*, not the *close action's*.
 *      secretdrop.js once drew its own title + ✕ whenever it was handed a `close`, but
 *      panel.html hands one over precisely when EMBEDDED — and the embedding widget
 *      already draws a header — so the header rendered twice.
 *   2. Ownership (docs/tasks/active/platform-secret-drop.md). secretdrop.js is a
 *      platform asset: it must run with NO page globals (devterm's ui.js is not on the
 *      hub page), call the API by RELATIVE paths (the hub mount and devterm's proxy both
 *      depend on that), and take the session's target box only from its caller.
 *   3. Widget independence. The shared widget's "Secret drop" row comes from
 *      data-secret-panel (the platform surface) and never from data-panel (devterm), so
 *      devterm being absent removes at most the accounts row, never the secret one.
 *
 * AC-PSD-4 and AC-PSD-5 of the task card are the sections marked below.
 */
import fs from 'node:fs';
import vm from 'node:vm';

const failures = [];
function check(name, condition) {
  console.log(`${condition ? 'PASS' : 'FAIL'} ${name}`);
  if (!condition) failures.push(name);
}

const SECRETDROP = new URL('../hub/assets/accounts/secretdrop.js', import.meta.url);
const WIDGET = new URL('../hub/assets/airlock-return.js', import.meta.url);
const PANEL = new URL('../hub/assets/accounts/panel.html', import.meta.url);

function makeElement(tagName) {
  const listeners = {};
  return {
    tagName: String(tagName).toUpperCase(),
    className: '', children: [], parentNode: null, listeners,
    style: { cssText: '' }, dataset: {},
    textContent: '', value: '', disabled: false, type: '', src: '',
    offsetHeight: 0, offsetWidth: 0,
    appendChild(child) { this.children.push(child); child.parentNode = this; return child; },
    removeChild(child) {
      const i = this.children.indexOf(child);
      if (i >= 0) { this.children.splice(i, 1); child.parentNode = null; }
      return child;
    },
    remove() { if (this.parentNode) this.parentNode.removeChild(this); },
    contains(other) { return walk(this).includes(other); },
    setAttribute(k, v) { this[k] = v; }, focus() {}, select() {}, setSelectionRange() {},
    getBoundingClientRect() { return { left: 0, top: 0, right: 0, bottom: 0 }; },
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    removeEventListener() {},
  };
}
function walk(node, out = []) {
  out.push(node);
  for (const child of node.children || []) walk(child, out);
  return out;
}
const textsOf = (root) => walk(root).map((n) => n.textContent).filter(Boolean);
const closeButtons = (root) => walk(root).filter((n) => n.tagName === 'BUTTON' && n.textContent === '✕');
const buttonNamed = (root, label) => walk(root).find((n) => n.tagName === 'BUTTON' && n.textContent === label);
const flush = () => new Promise((r) => setImmediate(r));

// ---- secretdrop.js sandbox: ONLY that file, no ui.js, nothing else on the page ----
function loadSecretDrop({ secure = false } = {}) {
  const copied = [], fetched = [];
  const document = {
    createElement: makeElement,
    body: makeElement('body'),
    addEventListener() {}, removeEventListener() {},
    getSelection: () => ({ rangeCount: 0, removeAllRanges() {}, addRange() {} }),
    execCommand: () => true,
  };
  const sandbox = {
    document, console, setTimeout, clearTimeout, setInterval: () => 0, clearInterval,
    navigator: secure ? { clipboard: { writeText: (t) => { copied.push(t); return Promise.resolve(); } } } : {},
    isSecureContext: secure,
    // The list load must not reach the network; an empty list is the quiet path.
    fetch: (url) => { fetched.push(url); return Promise.resolve({ json: () => Promise.resolve({ ok: true, secrets: [] }) }); },
  };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(SECRETDROP, 'utf8'), sandbox, { filename: 'secretdrop.js' });
  return { sandbox, copied, fetched };
}
const deps = { flash() {}, postJson: () => Promise.resolve({ ok: true }) };

// ---- 1) window chrome ----
{
  const { sandbox } = loadSecretDrop();
  const api = sandbox.window.initSecretDrop(deps);
  const host = makeElement('div');
  api.renderSecretPanel(host, () => {});          // close IS supplied, as panel.html does when embed=1
  check('embedded panel draws no title of its own', textsOf(host).filter((t) => t === 'Secret drop').length === 0);
  check('embedded panel draws no ✕ of its own', closeButtons(host).length === 0);
  check('embedded panel still offers the Close action', textsOf(host).includes('Close'));
}
{
  const { sandbox } = loadSecretDrop();
  const host = makeElement('div');
  sandbox.window.initSecretDrop(deps).renderSecretPanel(host, null);
  check('standalone panel draws no title of its own', !textsOf(host).includes('Secret drop'));
}
{
  const { sandbox } = loadSecretDrop();
  sandbox.window.initSecretDrop({ ...deps, sendInput() { return true; } }).openSecretDrop();
  const overlay = sandbox.document.body.children[sandbox.document.body.children.length - 1];
  check('devterm modal draws exactly one title', textsOf(overlay).filter((t) => t === 'Secret drop').length === 1);
  check('devterm modal draws exactly one ✕', closeButtons(overlay).length === 1);
  // devterm's terminal keys focus/keyboard suppression on this class (apps/devterm/web/app.js).
  check('devterm modal overlay keeps the copy-overlay class devterm keys on', overlay.className === 'copy-overlay');
}

// ---- 2) AC-PSD-4: ownership — self-contained, relative API, caller-owned target ----
{
  const src = fs.readFileSync(SECRETDROP, 'utf8');
  const code = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
  check('secretdrop.js calls the API by relative paths only',
    /'secret-put'/.test(code) && /'secret-list'/.test(code) && /'secret-del'/.test(code)
    && !/['"]\/secret-/.test(code) && !/airlock-accounts\//.test(code));
  check('secretdrop.js reads no page-global UI helper (no window.uiRefocus, no ui.js dependency)',
    !/window\.uiRefocus/.test(code) && !/window\.(copyText|uiBtn|makeModal)/.test(code));
  check('panel.html loads no devterm-only asset', (() => {
    const html = fs.readFileSync(PANEL, 'utf8');
    return !/src="ui\.js"/.test(html) && !/favicon\.svg/.test(html) && /src="secretdrop\.js"/.test(html);
  })());
}

// A random marker stands in for a value; it is compared, never printed.
const SENTINEL = 'sentinel-' + Math.random().toString(36).slice(2) + Date.now().toString(36);

async function deliver({ terminal, remote, secure, kind }) {
  const { sandbox, copied, fetched } = loadSecretDrop({ secure });
  const posted = [], typed = [], flashes = [];
  const d = {
    flash: (m) => flashes.push(m),
    postJson: (path, body) => { posted.push([path, body]); return Promise.resolve({ ok: true }); },
  };
  if (terminal) d.sendInput = (t) => { typed.push(t); return true; };
  if (remote) {
    d.tokenTarget = (p) => 'ssh devbox cat ' + p;
    d.readCmd = (p) => 'ssh devbox cat ' + p;
  }
  const host = makeElement('div');
  sandbox.window.initSecretDrop(d).renderSecretPanel(host, null);
  const nameIn = walk(host).find((n) => n.tagName === 'INPUT' && n.placeholder === 'GH_TOKEN');
  const valueIn = walk(host).find((n) => n.tagName === 'TEXTAREA');
  nameIn.value = 'GH_TOKEN';
  valueIn.value = SENTINEL;
  const label = kind === 'export'
    ? (terminal ? 'Export in shell' : 'Copy export statement')
    : (terminal ? 'Send to agent' : 'Store and copy path');
  await buttonNamed(host, label).onclick();
  await flush(); await flush();
  return { posted, typed, copied, fetched, flashes, valueLeft: valueIn.value };
}

{
  const r = await deliver({ terminal: true, remote: true, secure: true, kind: 'agent' });
  check('terminal mode stores through the relative secret-put path with the value in the body',
    r.posted.length === 1 && r.posted[0][0] === 'secret-put'
    && r.posted[0][1].name === 'GH_TOKEN' && r.posted[0][1].value === SENTINEL);
  check('terminal mode types the session-target token the caller supplied (remote box)',
    r.typed.length === 1 && r.typed[0] === '[secret:GH_TOKEN](ssh devbox cat ~/.devterm-secrets/GH_TOKEN.txt) ');
  check('terminal mode copies the same token, never the value', r.copied.length === 1 && r.copied[0] === r.typed[0]);
  check('the value field is cleared after delivery', r.valueLeft === '');
  check('the list is loaded from the relative secret-list path', r.fetched.every((u) => u === 'secret-list') && r.fetched.length >= 1);
  const out = JSON.stringify([r.typed, r.copied, r.flashes]);
  check('the value never reaches the terminal, the clipboard or a message', !out.includes(SENTINEL));
}
{
  const r = await deliver({ terminal: true, remote: true, secure: true, kind: 'export' });
  check('terminal export reads the file on the session box',
    r.typed[0] === 'export GH_TOKEN=$(ssh devbox cat ~/.devterm-secrets/GH_TOKEN.txt)');
}
{
  const r = await deliver({ terminal: false, remote: false, secure: true, kind: 'agent' });
  check('clipboard mode (hub panel) copies a this-box path token and types nothing',
    r.typed.length === 0 && r.copied.length === 1 && r.copied[0] === '[secret:GH_TOKEN](~/.devterm-secrets/GH_TOKEN.txt) ');
  check('clipboard mode never copies the value', !JSON.stringify([r.copied, r.flashes]).includes(SENTINEL));
}
{
  const r = await deliver({ terminal: false, remote: false, secure: false, kind: 'export' });
  check('clipboard fallback (no secure context) still delivers via execCommand without the value',
    r.flashes.some((m) => /copied/.test(m)) && !JSON.stringify(r.flashes).includes(SENTINEL));
}

// ---- 3) AC-PSD-5: widget independence ----
function loadWidget(dataset) {
  const body = makeElement('body');
  const docListeners = {}, winListeners = {}, fetched = [];
  const document = {
    body, documentElement: body,
    currentScript: { dataset },
    createElement: makeElement,
    getElementById: () => null,
    querySelector: () => null,
    addEventListener(t, fn) { (docListeners[t] = docListeners[t] || []).push(fn); },
    removeEventListener() {},
  };
  const location = { hostname: 'box.example.ts.net', href: '' };
  const sandbox = {
    document, location, console,
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0, clearInterval() {},
    innerWidth: 1200, innerHeight: 800,
    fetch: (u) => { fetched.push(u); return Promise.resolve({ status: 404, ok: false, json: () => Promise.resolve({}) }); },
    addEventListener(t, fn) { (winListeners[t] = winListeners[t] || []).push(fn); },
    removeEventListener() {},
  };
  sandbox.window = sandbox; sandbox.top = sandbox; sandbox.self = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(WIDGET, 'utf8'), sandbox, { filename: 'airlock-return.js' });
  const btn = body.children.find((c) => c.id === 'airlock-return');
  const ev = { preventDefault() {}, stopPropagation() {} };
  return {
    sandbox, body, btn, fetched,
    tap() { (btn.listeners.click || []).forEach((fn) => fn(ev)); },
    rows() {
      const menu = body.children.find((c) => c !== btn && /min-width:236px/.test(c.style.cssText));
      if (!menu) return null;
      return menu.children.map((b) => ({ label: b.children[0].textContent, click: () => b.listeners.click.forEach((fn) => fn(ev)) }));
    },
    frameSrc() {
      const f = walk(body).find((n) => n.tagName === 'IFRAME');
      return f ? f.src : null;
    },
  };
}
const HUB_SECRET = 'https://box.example.ts.net/airlock-accounts/';
const DEVTERM = 'https://box.example.ts.net:19300/';
{
  // devterm absent: the render carries only the platform destination.
  const w = loadWidget({ menu: '1', anchor: 'bottom-right', secretPanel: HUB_SECRET });
  w.tap();
  const rows = w.rows();
  check('without devterm the widget still opens a menu', !!rows);
  check('without devterm the menu offers Secret drop and no dead accounts row',
    !!rows && rows.some((r) => r.label === 'Secret drop') &&
      !rows.some((r) => r.label === 'Subscription accounts'));
  rows && rows.find((r) => r.label === 'Secret drop').click();
  check('Secret drop opens the platform panel on the hub prefix',
    w.frameSrc() === HUB_SECRET + 'panel.html?p=secret&embed=1');
  check('the panel iframe is delegated clipboard-write (the drop delivers by copying)',
    walk(w.body).find((n) => n.tagName === 'IFRAME').allow === 'clipboard-write');
  check('without devterm nothing polls a devterm endpoint', w.fetched.every((u) => !u.includes(':19300')));
}
{
  // devterm present AND platform: accounts go to devterm, the secret row never does.
  const w = loadWidget({ menu: '1', panel: DEVTERM, secretPanel: HUB_SECRET });
  w.tap();
  const rows = w.rows();
  check('with both destinations the menu has both rows',
    !!rows && rows.some((r) => r.label === 'Subscription accounts') &&
      rows.some((r) => r.label === 'Secret drop'));
  rows.find((r) => r.label === 'Secret drop').click();
  check('Secret drop never opens devterm even when devterm is configured',
    w.frameSrc() === HUB_SECRET + 'panel.html?p=secret&embed=1');
  const w2 = loadWidget({ menu: '1', panel: DEVTERM, secretPanel: HUB_SECRET });
  w2.tap(); w2.rows().find((r) => r.label === 'Subscription accounts').click();
  check('Subscription accounts keeps its own destination', w2.frameSrc() === DEVTERM + 'panel.html?p=accounts&embed=1');
}
{
  // An old render (only data-panel) must not turn devterm into the secret destination.
  const w = loadWidget({ menu: '1', panel: DEVTERM });
  w.tap();
  const rows = w.rows();
  check('a legacy data-panel never becomes a Secret drop row',
    !!rows && rows.some((r) => r.label === 'Subscription accounts') &&
      !rows.some((r) => r.label === 'Secret drop'));
}
{
  // Neither destination: a tap navigates instead of opening an empty menu.
  const w = loadWidget({ menu: '1' });
  w.tap();
  check('with no destination a tap navigates rather than opening a dead menu',
    w.rows() === null && w.sandbox.location.href === 'https://box.example.ts.net/');
}

console.log(failures.length ? `\n${failures.length} FAILED` : '\nall checks passed');
process.exit(failures.length ? 1 : 0);
