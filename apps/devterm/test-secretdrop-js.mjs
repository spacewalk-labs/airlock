#!/usr/bin/env node
/* Dependency-free contract checks for the Secret drop panel's window chrome.
 *
 * The bug this guards: the title bar is the *window's*, not the *close action's*.
 * secretdrop.js used to draw its own title + ✕ whenever it was handed a `close`
 * function, but panel.html hands one over precisely when it is EMBEDDED — and the
 * embedding widget already draws a header. So the header rendered twice, one inside
 * the other, and the inner copy ate enough height to put the body behind a scrollbar.
 *
 * Rendering is exercised for real (ui.js + secretdrop.js run in a vm against a DOM
 * shim) rather than grepped, so a future refactor that keeps the words but restores
 * the coupling still fails here.
 */
import fs from 'node:fs';
import vm from 'node:vm';

const failures = [];
function check(name, condition) {
  console.log(`${condition ? 'PASS' : 'FAIL'} ${name}`);
  if (!condition) failures.push(name);
}

function makeElement(tagName) {
  return {
    tagName: String(tagName).toUpperCase(),
    className: '', children: [], parentNode: null,
    style: { cssText: '' },
    textContent: '', value: '', disabled: false,
    appendChild(child) { this.children.push(child); child.parentNode = this; return child; },
    removeChild(child) {
      const i = this.children.indexOf(child);
      if (i >= 0) { this.children.splice(i, 1); child.parentNode = null; }
      return child;
    },
    remove() { if (this.parentNode) this.parentNode.removeChild(this); },
    setAttribute() {}, focus() {}, addEventListener() {}, removeEventListener() {},
  };
}

// Every node in the tree, so a title can be counted wherever it was appended.
function walk(node, out = []) {
  out.push(node);
  for (const child of node.children || []) walk(child, out);
  return out;
}
const textsOf = (root) => walk(root).map((n) => n.textContent).filter(Boolean);
const closeButtons = (root) => walk(root).filter((n) => n.tagName === 'BUTTON' && n.textContent === '✕');

function loadSandbox() {
  const document = {
    createElement: makeElement,
    body: makeElement('body'),
    addEventListener() {}, removeEventListener() {},
    getSelection: () => ({ rangeCount: 0, removeAllRanges() {}, addRange() {} }),
    execCommand: () => true,
  };
  const sandbox = {
    document, navigator: {}, console,
    setTimeout, clearTimeout, setInterval: () => 0, clearInterval,
    // The list load must not reach the network; an empty list is the quiet path.
    fetch: () => Promise.resolve({ json: () => Promise.resolve({ ok: true, secrets: [] }) }),
  };
  sandbox.window = sandbox;
  sandbox.isSecureContext = false;
  vm.createContext(sandbox);
  for (const f of ['./web/ui.js', './web/secretdrop.js']) {
    vm.runInContext(fs.readFileSync(new URL(f, import.meta.url), 'utf8'), sandbox, { filename: f });
  }
  return sandbox;
}

const deps = { flash() {}, postJson: () => Promise.resolve({ ok: true }) };

// 1) The embedded panel — the widget above it owns the header.
{
  const sandbox = loadSandbox();
  const api = sandbox.window.initSecretDrop(deps);
  const host = makeElement('div');
  api.renderSecretPanel(host, () => {});          // close IS supplied, as panel.html does when embed=1
  const titles = textsOf(host).filter((t) => t === 'Secret drop');
  check('embedded panel draws no title of its own', titles.length === 0);
  check('embedded panel draws no ✕ of its own', closeButtons(host).length === 0);
  check('embedded panel still offers the Close action', textsOf(host).includes('Close'));
}

// 2) Standalone panel — panel.html's own #top owns the header, and close is null.
{
  const sandbox = loadSandbox();
  const api = sandbox.window.initSecretDrop(deps);
  const host = makeElement('div');
  api.renderSecretPanel(host, null);
  check('standalone panel draws no title of its own', !textsOf(host).includes('Secret drop'));
}

// 3) devterm's modal — makeModal() draws no header, so this UI must draw exactly one.
{
  const sandbox = loadSandbox();
  const api = sandbox.window.initSecretDrop({ ...deps, sendInput() {} });
  api.openSecretDrop();
  const overlay = sandbox.document.body.children[sandbox.document.body.children.length - 1];
  const titles = textsOf(overlay).filter((t) => t === 'Secret drop');
  check('devterm modal draws exactly one title', titles.length === 1);
  check('devterm modal draws exactly one ✕', closeButtons(overlay).length === 1);
}

console.log(failures.length ? `\n${failures.length} FAILED` : '\nall checks passed');
process.exit(failures.length ? 1 : 0);
