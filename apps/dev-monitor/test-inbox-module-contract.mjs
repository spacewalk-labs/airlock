// One public Inbox module, mounted by the hub strip, the Dev Monitor tab and the
// return-widget iframe. This executes their single row builder without a browser.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

class ClassList {
  constructor(node) { this.node = node; }
  values() { return this.node.className.split(/\s+/).filter(Boolean); }
  add(...names) { this.node.className = [...new Set([...this.values(), ...names])].join(' '); }
  contains(name) { return this.values().includes(name); }
}
class Element {
  constructor(tag, doc) { this.tagName = tag; this.ownerDocument = doc; this.children = []; this.className = ''; this.classList = new ClassList(this); this.dataset = {}; this.events = {}; this.hidden = false; this._text = ''; }
  appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
  addEventListener(name, fn) { this.events[name] = fn; }
  setAttribute() {}
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text + this.children.map(x => x.textContent).join(''); }
}
function descendants(node) { return [node, ...node.children.flatMap(descendants)]; }
function rows(root) { return descendants(root).filter(node => node.classList.contains('ms-row')); }

const hub = readFileSync(new URL('../../hub/index.html', import.meta.url), 'utf8');
const monitor = readFileSync(new URL('./frontend/dev-monitor.html', import.meta.url), 'utf8');
const iframe = readFileSync(new URL('../../hub/inbox.html', import.meta.url), 'utf8');
for (const [name, html, mode] of [['hub', hub, 'strip'], ['monitor', monitor, 'full'], ['iframe', iframe, 'full']]) {
  assert.match(html, /href="\/assets\/devmon-inbox\.css(?:\?v=\d+)?"/, `${name} loads shared CSS`);
  assert.match(html, /src="\/assets\/devmon-inbox\.js(?:\?v=\d+)?"/, `${name} loads shared module`);
  assert.match(html, new RegExp(`DevmonInbox\\.mount[\\s\\S]*mode[\\s\\S]*${mode}`), `${name} mounts its requested mode`);
}
assert.match(iframe, /title:false/, 'iframe hides the module title');
assert.match(iframe, /Dev Monitor 에서 보기 ↗/, 'iframe keeps the wide-screen link');
assert.match(monitor, /id="devmon-inbox"/, 'monitor has a dedicated shared-module root');
assert.match(monitor, /new URLSearchParams\(location\.search\)/, 'monitor receives a run template query');
assert.match(monitor, /devmonInbox\.openTemplate\(/, 'monitor opens the shared RUN sheet without a card');
assert.doesNotMatch(monitor, /\.mcard|['"]mcard/, 'monitor no longer carries the old card-list shape');
assert.equal((readFileSync(new URL('../../hub/assets/devmon-inbox.js', import.meta.url), 'utf8').match(/'ms-row' \+ \(card\.read_at/g) || []).length, 1, 'the module has one row builder');

const document = {createElement(tag) { return new Element(tag, this); }};
const payload = {messages: [
  {card_id: 'a', source: 'cron', title: 'Repair', level: 'urgent', count: 2, last_at: new Date().toISOString(), read_at: null, run: {cwd: '/tmp', prompt: 'fix'}},
  {card_id: 'b', source: 'report', title: 'Read report', level: 'normal', count: 1, last_at: new Date().toISOString(), read_at: null, link: 'https://docs.example.test/r'},
  {card_id: 'c', source: 'cron', title: 'Third', level: 'normal', count: 3, last_at: new Date().toISOString(), read_at: null},
  {card_id: 'd', source: 'cron', title: 'Fourth', level: 'normal', count: 1, last_at: new Date().toISOString(), read_at: null}
], top: [], unread_count: 4, counts: {active: 4, unread: 4, urgent: 1, archived: 0}};
const fetches = [];
let templatePreviewStatus = 200;
let openedTemplate = null;
let cardOptions = null;
const window = {
  document, location: {pathname: '/monitor/', hostname: 'box.example.test'}, console,
  fetch: async (url, options = {}) => {
    fetches.push({url, options});
    if (url.includes('/run/template?')) {
      if (templatePreviewStatus === 404) return {status: 404, ok: false, json: async () => ({ok: false})};
      return {status: 200, ok: true, json: async () => ({ok: true, title: 'Fixture Template', run: {
        template: 'fixture-template', week: '2026-09-18', action: 'save',
        url: 'https://docs.example.test/r',
        cwd: '/home/me/workspace/wiki', prompt: 'Server-owned fixed prompt.',
        default_note: 'Prefilled owner note.',
        examples: ['First template note']
      }})};
    }
    if (url.endsWith('/run/template') || url.endsWith('/run/template/window')) {
      return {status: 200, ok: true, json: async () => ({ok: true, ran_at: 'now', window: '@1', session: 'devmon-exec', state: 'active'})};
    }
    return {status: 200, ok: true, json: async () => structuredClone(payload)};
  },
  setInterval() { return 1; }, clearInterval() {},
  DevmonCardUI: {create(options) { cardOptions = options; return {createActions(card, archive) {
    const actions = document.createElement('div');
    if (card.run) actions.appendChild(document.createElement('button')).textContent = 'Run';
    if (archive !== false) actions.appendChild(document.createElement('button')).textContent = 'Archive';
    return actions;
  }, openTitle() {}, openRun(card) { openedTemplate = card; }}; }}
};
const context = vm.createContext({window, document, globalThis: window, Date, Promise, Object, Array, String, Number, JSON, encodeURIComponent, console});
vm.runInContext(readFileSync(new URL('../../hub/assets/devmon-inbox.js', import.meta.url), 'utf8'), context);
const roots = [document.createElement('div'), document.createElement('div'), document.createElement('div')];
window.DevmonInbox.mount(roots[0], {mode: 'strip'});
window.DevmonInbox.mount(roots[1], {mode: 'full'});
window.DevmonInbox.mount(roots[2], {mode: 'full', title: false});
await new Promise(resolve => setImmediate(resolve));
assert.deepEqual(fetches.slice(0, 3).map(call => call.url), [
  '/monitor/api/owner/messages/preview',
  '/monitor/api/owner/messages?scope=active',
  '/monitor/api/owner/messages?scope=active'
], 'all hub-hosted consumers keep the /monitor API prefix');
assert.deepEqual(rows(roots[0]).map(row => row.dataset.cardId), ['a', 'b', 'c'], 'strip is exactly the top three rows');
assert.deepEqual(rows(roots[1]).map(row => row.dataset.cardId), ['a', 'b', 'c', 'd']);
assert.deepEqual(rows(roots[2]).map(row => row.dataset.cardId), ['a', 'b', 'c', 'd']);
assert.match(roots[0].textContent, /1 more/, 'strip reports the unread rows below its top three');
for (const root of roots) assert.ok(rows(root).every(row => row.children.some(child => child.classList.contains('ms-title'))));
const rowShape = row => row.children.map(child => `${child.tagName}:${child.className}`).join('|');
assert.equal(rowShape(rows(roots[0])[0]), rowShape(rows(roots[1])[0]), 'strip and Dev Monitor use the same row shape');
assert.equal(rowShape(rows(roots[1])[0]), rowShape(rows(roots[2])[0]), 'Dev Monitor and widget iframe use the same row shape');
assert.match(roots[1].textContent, /All.*Unread.*Urgent.*Archived/, 'full mode exposes every filter');
assert.equal(roots[0].textContent.includes('All'), false, 'strip mode does not expose full filters');

const templateRoot = document.createElement('div');
const templateInbox = window.DevmonInbox.mount(templateRoot, {mode: 'full'});
await templateInbox.openTemplate({template: 'fixture-template', week: '2026-09-18',
  action: 'save', url: 'https://docs.example.test/r'});
assert.equal(openedTemplate.run.template, 'fixture-template');
assert.equal(openedTemplate.run.prompt, 'Server-owned fixed prompt.');
assert.equal(openedTemplate.run.default_note, 'Prefilled owner note.');
const previewGet = fetches.find(call => call.url.includes('/run/template?'));
assert.match(previewGet.url, /action=save/);
assert.doesNotMatch(previewGet.url, /(?:^|[?&])note=/);
await cardOptions.run(openedTemplate, {}, 'owner note');
await cardOptions.selectWindow(openedTemplate);
const runPost = fetches.find(call => call.url.endsWith('/run/template'));
assert.deepEqual(JSON.parse(runPost.options.body), {
  template: 'fixture-template', week: '2026-09-18', action: 'save',
  url: 'https://docs.example.test/r', note: 'owner note'
});
assert.equal(Object.hasOwn(JSON.parse(runPost.options.body), 'cwd'), false);
assert.equal(Object.hasOwn(JSON.parse(runPost.options.body), 'prompt'), false);
const windowPost = fetches.find(call => call.url.endsWith('/run/template/window'));
assert.deepEqual(JSON.parse(windowPost.options.body), {
  template: 'fixture-template', week: '2026-09-18', action: 'save'
});

templatePreviewStatus = 404;
const offRoot = document.createElement('div');
const offInbox = window.DevmonInbox.mount(offRoot, {mode: 'full'});
await offInbox.openTemplate({template: 'fixture-template', week: '2026-09-18', action: 'prompt'});
assert.equal(offRoot.textContent, '이 박스는 실행 콘솔이 꺼져 있습니다');

const widget = readFileSync(new URL('../../hub/assets/airlock-return.js', import.meta.url), 'utf8');
assert.match(widget, /menuRow\("Go to Airlock"[\s\S]*menuRow\("Inbox · " \+ unreadCount \+ " unread"/, 'Inbox follows Go to Airlock');
assert.match(widget, /frame\.src = AIRLOCK \+ "inbox\.html"/, 'widget frames the hub Inbox page');
assert.match(widget, /height:88vh;width:min\(clamp\(360px,44vh,480px\),63vh,calc\(100vw - 16px\)\)/, 'Inbox modal has the agreed dimensions');
console.log('inbox module: ok');
console.log('template query adapter: ok (server preview, restricted POST, console-off notice)');
