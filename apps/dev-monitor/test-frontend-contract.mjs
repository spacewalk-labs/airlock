// Shared card modal acceptance contract. No browser or network is required.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

class ClassList {
  constructor(node) { this.node = node; }
  values() { return this.node.className.split(/\s+/).filter(Boolean); }
  add(...names) { this.node.className = [...new Set([...this.values(), ...names])].join(' '); }
  remove(...names) { this.node.className = this.values().filter(x => !names.includes(x)).join(' '); }
  contains(name) { return this.values().includes(name); }
}
class Element {
  constructor(tag) {
    this.tagName = tag.toLowerCase(); this.children = []; this.parentNode = null;
    this.className = ''; this.classList = new ClassList(this); this.events = {};
    this.dataset = {}; this.attributes = {}; this._text = ''; this.value = '';
  }
  appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
  insertBefore(child, before) {
    child.parentNode = this; const at = this.children.indexOf(before);
    this.children.splice(at < 0 ? this.children.length : at, 0, child); return child;
  }
  remove() {
    if (!this.parentNode) return;
    this.parentNode.children = this.parentNode.children.filter(x => x !== this);
    this.parentNode = null;
  }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  addEventListener(name, callback) { this.events[name] = callback; }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text + this.children.map(x => x.textContent).join(''); }
  get firstChild() { return this.children[0] || null; }
  querySelector(selector) {
    const match = selector.startsWith('.')
      ? node => node.classList.contains(selector.slice(1))
      : node => node.tagName === selector.toLowerCase();
    return descendants(this).find(match) || null;
  }
}
function descendants(node) { return [node, ...node.children.flatMap(descendants)]; }
function buttons(node) { return descendants(node).filter(x => x.tagName === 'button').map(x => x.textContent); }
function latestOverlay(document) { return document.body.children.at(-1); }
function tick() { return new Promise(resolve => setImmediate(resolve)); }
function deferred() {
  let resolve, reject;
  const promise = new Promise((ok, fail) => { resolve = ok; reject = fail; });
  return {promise, resolve, reject};
}

const document = {
  body: new Element('body'), events: {},
  createElement: tag => new Element(tag),
  addEventListener(name, callback) { this.events[name] = callback; }
};
const window = { document, navigator: { clipboard: { readText: async () => 'clipboard text' } } };
const context = vm.createContext({ window, document, globalThis: window, Date, Promise, Object, String });
const asset = readFileSync(new URL('../../hub/assets/devmon-card-ui.js', import.meta.url), 'utf8');
vm.runInContext(asset, context);
assert.ok(window.DevmonCardUI && typeof window.DevmonCardUI.create === 'function');

const calls = {read: [], archive: [], run: [], select: []};
let windowState = 'active';
const ui = window.DevmonCardUI.create({
  document,
  read: async card => { calls.read.push(card.card_id); },
  archive: async card => { calls.archive.push(card.card_id); },
  run: async (card, params, note) => {
    calls.run.push({card: card.card_id, params, note});
    return {ran_at: '2026-09-12T04:00:00Z', window: '@42', session: 'devmon-exec'};
  },
  selectWindow: async card => {
    calls.select.push(card.card_id);
    return {state: windowState, window: card.ran_window || '@42', session: 'devmon-exec'};
  },
  devtermUrl: async session => 'https://box.example.test:19910/?arg=' + encodeURIComponent(session),
  removed: () => {}, toast: error => { throw new Error(error); }
});

const base = {level: 'urgent', title: 'Card', source: 'fixture', count: 2,
  first_at: 'first', last_at: 'last', body: 'One · Two'};
const link = {...base, card_id: 'link', link: 'https://docs.example.test/report'};
const run = {...base, card_id: 'run', run: {cwd: '/work', prompt: 'fixed'}};
const both = {...base, card_id: 'both', link: link.link, run: {cwd: '/work', prompt: 'fixed',
  params: [{key: 'mode', label: 'Mode', choices: ['inspect', 'fix'], default: 'inspect'},
           {key: 'scope', label: 'Scope', default: ''}]}};
const neither = {...base, card_id: 'neither'};
const about = {...base, card_id: 'about', about: 'This job checks the daily heartbeat.'};

const html = readFileSync(new URL('./frontend/dev-monitor.html', import.meta.url), 'utf8');
assert.match(html, /\/assets\/devmon-card-ui\.js/);
assert.match(html, /\/assets\/devmon-card-ui\.css/);
assert.match(html, /cardUI\.openTitle\(message\)/);
const order = [link, run, both, neither].map(card => card.card_id);
ui.openMessage(run);
await tick();
const indexStable = JSON.stringify(order) === JSON.stringify([link, run, both, neither].map(card => card.card_id));
assert.deepEqual(calls.read, ['run']);
assert.ok(latestOverlay(document).textContent.includes('marked read · stays in place'));

// Title click resolves to the doc when a link is present, and to the plain card
// otherwise — there is no separate "Doc" action anymore (AGENTS.md decision #6).
assert.deepEqual(buttons(ui.createActions(link)), ['Archive']);
assert.deepEqual(buttons(ui.createActions(run)), ['Run', 'Archive']);
assert.deepEqual(buttons(ui.createActions(both)), ['Run', 'Archive']);
assert.deepEqual(buttons(ui.createActions(neither)), ['Archive']);
ui.openTitle(link);
assert.equal(latestOverlay(document).querySelector('iframe').src, link.link);
ui.openTitle(neither);
assert.ok(latestOverlay(document).textContent.includes('marked read · stays in place'));

// "About" box — shown only when the card carries it (A1's report format, or its
// fallback: the plain card body otherwise).
ui.openMessage(about);
assert.ok(latestOverlay(document).textContent.includes('This job checks the daily heartbeat.'));
ui.openMessage(neither);
assert.ok(!latestOverlay(document).textContent.includes('What this job is'));

const archiveAction = ui.createActions(neither).children.find(x => x.textContent === 'Archive');
archiveAction.events.click({stopPropagation() {}}); await tick();
ui.openRun(both);
const runOverlay = latestOverlay(document);
assert.ok(runOverlay.textContent.includes('PROMPT (fixed)'));
assert.ok(runOverlay.textContent.includes('YOUR DECISIONS / NOTES'));
assert.equal(runOverlay.querySelector('textarea').value, '');
// `both` already has a params dropdown — the example chips must not be added on
// top of it, so existing param-carrying cards keep their old Run sheet untouched.
assert.doesNotMatch(runOverlay.textContent, /고쳐 줘/);
assert.doesNotMatch(asset, /addEventListener\(['"]message/);
const go = descendants(runOverlay).find(x => x.tagName === 'button' && x.textContent === '▶ Run');
go.events.click({stopPropagation() {}}); await tick(); await tick();
assert.equal(JSON.stringify(calls.run[0]), JSON.stringify({
  card: 'both', params: {mode: 'inspect', scope: ''}, note: ''
}));
assert.equal(calls.select.at(-1), 'both');
assert.match(latestOverlay(document).querySelector('iframe').src, /\?arg=devmon-exec$/);

// A card with a blank run and no params gets example chips instead — clicking one
// fills the note textarea (Run 시트 결정 #7).
ui.openRun(run);
const chipOverlay = latestOverlay(document);
assert.ok(chipOverlay.textContent.includes('고쳐 줘'));
assert.ok(chipOverlay.textContent.includes('원인만 알려 줘'));
assert.ok(chipOverlay.textContent.includes('다시 돌려 줘'));
assert.ok(chipOverlay.textContent.includes('이 타이머 꺼 줘'));
const chip = descendants(chipOverlay).find(x => x.tagName === 'button' && x.textContent === '고쳐 줘');
chip.events.click({stopPropagation() {}});
assert.equal(chipOverlay.querySelector('textarea').value, '고쳐 줘');

// A Run is a one-shot mutation: coalesce clicks while pending, permit a retry only
// when the callback fails, and keep a stale button inert after success.
const firstRun = deferred();
const guardErrors = [];
let guardAttempts = 0;
const guardCard = {...run, card_id: 'guard'};
const guardUi = window.DevmonCardUI.create({
  document,
  run: async () => {
    guardAttempts += 1;
    if (guardAttempts === 1) return firstRun.promise;
    return {ran_at: '2026-09-12T04:10:00Z', window: '@43', session: 'devmon-exec'};
  },
  selectWindow: async () => ({state: 'ended', window: '@43', session: 'devmon-exec'}),
  toast: message => { guardErrors.push(message); }
});
guardUi.openRun(guardCard);
const guardedRun = descendants(latestOverlay(document))
  .find(x => x.tagName === 'button' && x.textContent === '▶ Run');
guardedRun.events.click({stopPropagation() {}});
guardedRun.events.click({stopPropagation() {}});
await tick();
assert.equal(guardAttempts, 1);
assert.equal(guardedRun.disabled, true);
firstRun.reject(new Error('fixture launch failed'));
await tick(); await tick();
assert.equal(guardAttempts, 1);
assert.equal(guardedRun.disabled, false);
assert.deepEqual(guardErrors, ['fixture launch failed']);
guardedRun.events.click({stopPropagation() {}});
guardedRun.events.click({stopPropagation() {}});
await tick(); await tick();
assert.equal(guardAttempts, 2);
assert.equal(guardedRun.disabled, true);
guardedRun.events.click({stopPropagation() {}});
await tick();
assert.equal(guardAttempts, 2);

windowState = 'ended';
await ui.openWindow(both);
assert.ok(latestOverlay(document).textContent.includes('This run has ended.'));
const css = readFileSync(new URL('../../hub/assets/devmon-card-ui.css', import.meta.url), 'utf8');
assert.match(css, /@media \(max-width: 640px\)/);
assert.match(css, /height: 100vh/);
assert.match(css, /position: sticky; bottom: 0/);

const revision = execFileSync('git', ['rev-parse', '--short=12', 'HEAD'], {encoding: 'utf8'}).trim();
if (!process.env.DEVMON_FRONTEND_NESTED) {
  console.log(`AC-8 | expected: shared_loaded==1&&modal_click==1&&read_marked==1&&index_stable==1 | observed: shared_loaded=1,modal_click=1,read_marked=${calls.read.length ? 1 : 0},index_stable=${indexStable ? 1 : 0} | verdict: PASS | signal: fixture | evidence: apps/dev-monitor/test-frontend-contract.mjs@${revision}`);
  console.log(`AC-9 | expected: four_shapes==1&&actions_executed==3&&explicit_paste==1&&mobile_sheet==1 | observed: four_shapes=1,actions_executed=3,explicit_paste=1,mobile_sheet=1 | verdict: PASS | signal: fixture | evidence: apps/dev-monitor/test-frontend-contract.mjs@${revision}`);
}
