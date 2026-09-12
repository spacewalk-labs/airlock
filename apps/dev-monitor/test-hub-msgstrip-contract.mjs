// Hub message-strip contract. Runs the shipped inline caller against a fixture DOM/API.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';

class ClassList {
  constructor(node) { this.node = node; }
  values() { return this.node.className.split(/\s+/).filter(Boolean); }
  add(...names) { this.node.className = [...new Set([...this.values(), ...names])].join(' '); }
  remove(...names) { this.node.className = this.values().filter(name => !names.includes(name)).join(' '); }
  contains(name) { return this.values().includes(name); }
}

class Element {
  constructor(tag) {
    this.tagName = tag.toLowerCase();
    this.children = [];
    this.parentNode = null;
    this.className = '';
    this.classList = new ClassList(this);
    this.dataset = {};
    this.attributes = {};
    this.events = {};
    this.hidden = false;
    this.href = '';
    this._text = '';
  }
  appendChild(child) {
    if (typeof child === 'string') child = new TextNode(child);
    child.parentNode = this;
    this.children.push(child);
    return child;
  }
  append(...children) { children.forEach(child => this.appendChild(child)); }
  addEventListener(name, callback) { this.events[name] = callback; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  remove() {
    if (!this.parentNode) return;
    this.parentNode.children = this.parentNode.children.filter(child => child !== this);
    this.parentNode = null;
  }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
}

class TextNode extends Element {
  constructor(text) { super('#text'); this._text = String(text); }
}

function descendants(node) { return [node, ...node.children.flatMap(descendants)]; }
function serialize(node) {
  return JSON.stringify({
    tag: node.tagName,
    className: node.className,
    hidden: node.hidden,
    href: node.href,
    dataset: node.dataset,
    text: node._text,
    children: node.children.map(child => JSON.parse(serialize(child)))
  });
}
function tick() { return new Promise(resolve => setImmediate(resolve)); }
async function click(node) {
  assert.ok(node && node.events.click, 'fixture node must be clickable');
  await node.events.click({stopPropagation() {}});
  await tick();
}

const html = readFileSync(new URL('../../hub/index.html', import.meta.url), 'utf8');
const marker = html.indexOf('// Message strip —');
assert.ok(marker > 0, 'message strip script marker must exist');
const scriptStart = html.lastIndexOf('<script>', marker);
const scriptEnd = html.indexOf('</script>', marker);
const stripScript = html.slice(scriptStart + '<script>'.length, scriptEnd);

assert.match(html, /<link rel="stylesheet" href="\/assets\/devmon-card-ui\.css">/);
assert.match(html, /<script src="\/assets\/devmon-card-ui\.js"><\/script>/);
assert.match(stripScript, /DevmonCardUI\.create\(/);
assert.doesNotMatch(stripScript, /function\s+(?:openMessage|openDoc|openRun|openWindow)\s*\(/);
assert.doesNotMatch(stripScript, /className\s*=\s*['"]dmc-|createElement\(['"]iframe/);

const strip = new Element('div');
strip.hidden = true;
const document = {
  createElement: tag => new Element(tag),
  getElementById: id => id === 'msgstrip' ? strip : null
};

const now = Date.now();
const ago = seconds => new Date(now - seconds * 1000).toISOString();
const cards = [
  {card_id: 'doc', group: 'g-doc', source: 'docs', level: 'urgent', title: 'Read report',
   body: 'Report body', link: 'https://docs.example.test/report', run: null, count: 4,
   first_at: ago(7200), last_at: ago(300), read_at: null},
  {card_id: 'run', group: 'g-run', source: 'jobs', level: 'normal', title: 'Run repair',
   body: 'Repair body', link: null, run: {cwd: '/work', prompt: 'fixed'}, count: 2,
   first_at: ago(10800), last_at: ago(7200), read_at: null},
  {card_id: 'both', group: 'g-both', source: 'review', level: 'urgent', title: 'Review and run',
   body: 'Review body', link: 'https://docs.example.test/decision',
   run: {cwd: '/work', prompt: 'fixed'}, count: 1, first_at: ago(259200),
   last_at: ago(259200), read_at: null, ran_at: '2026-09-12T04:00:00Z', ran_window: '@42'},
  {card_id: 'heartbeat:2026-09-12', group: 'heartbeat', source: 'heartbeat', level: 'urgent',
   title: 'Alive', body: 'alive', link: null, run: null, count: 1,
   first_at: ago(3600), last_at: ago(3600), read_at: ago(3500)}
];
const payload = {messages: cards, top: cards.slice(0, 3), unread_count: 4,
  collected_at: ago(60), collected_age_seconds: 60};

let previewStatus = 200;
const requests = [];
async function fetch(url, options = {}) {
  requests.push({url, method: options.method || 'GET', body: options.body || ''});
  if (url === '/monitor/api/owner/messages/preview') {
    return {status: previewStatus, ok: previewStatus === 200,
      json: async () => structuredClone(payload)};
  }
  if (url === '/monitor/api/owner/run') {
    return {status: 200, ok: true, json: async () => ({ok: true, ran_at: ago(0), window: '@55', session: 'devmon-exec'})};
  }
  if (url === '/monitor/api/owner/run/window') {
    return {status: 200, ok: true, json: async () => ({ok: true, state: 'active', window: '@42', session: 'devmon-exec'})};
  }
  if (/\/monitor\/api\/owner\/messages\/[^/]+\/(?:read|archive)$/.test(url)) {
    return {status: 200, ok: true, json: async () => ({ok: true, unread_count: 3})};
  }
  throw new Error('unexpected fetch ' + url);
}

const uiCalls = {message: [], doc: [], run: [], view: [], archive: []};
let injected = null;
const DevmonCardUI = {
  create(options) {
    injected = options;
    function button(label, callback) {
      const node = document.createElement('button');
      node.textContent = label;
      node.addEventListener('click', callback);
      return node;
    }
    return {
      createActions(card) {
        const actions = document.createElement('div');
        if (card.run && card.ran_at && card.ran_window) {
          actions.appendChild(button('View', async () => {
            uiCalls.view.push(card.card_id); await options.selectWindow(card);
          }));
        } else if (card.run) {
          actions.appendChild(button('Run', async () => {
            uiCalls.run.push(card.card_id); await options.run(card, {}, 'fixture note');
          }));
        }
        actions.appendChild(button('Archive', async () => {
          uiCalls.archive.push(card.card_id); await options.archive(card);
        }));
        return actions;
      },
      openMessage(card) { uiCalls.message.push(card.card_id); return options.read(card); },
      openTitle(card) {
        if (card.link) { uiCalls.doc.push(card.card_id); return options.read(card); }
        uiCalls.message.push(card.card_id); return options.read(card);
      }
    };
  }
};

let intervalCallback = null;
const context = vm.createContext({
  document,
  window: {DevmonCardUI},
  DevmonCardUI,
  fetch,
  Date,
  Promise,
  JSON,
  Object,
  String,
  URL,
  console,
  setInterval(callback) { intervalCallback = callback; return 1; },
  j: async url => url === '/whoami'
    ? {role: 'owner'}
    : {fqdn: 'box.example.test', apps: {devterm: {port: 19910}}}
});
vm.runInContext(stripScript, context);
await tick(); await tick();

assert.equal(strip.hidden, false);
assert.ok(injected, 'hub must instantiate the shared component');
const rows = descendants(strip).filter(node => node.classList.contains('ms-row'));
assert.deepEqual(rows.map(node => node.dataset.cardId), ['doc', 'run', 'both']);
assert.match(strip.textContent, /4 unread/);
assert.doesNotMatch(strip.textContent, /URGENT|NORMAL/);
assert.equal(descendants(rows[0]).find(node => node.classList.contains('ms-mark')).textContent, '!');
assert.match(rows[0].textContent, /docs · ×4 · 5m/);
assert.equal(descendants(rows[1]).find(node => node.classList.contains('ms-mark')).textContent, '');
assert.match(rows[1].textContent, /jobs · ×2 · 2h/);
assert.match(rows[2].textContent, /3d/);
assert.match(strip.textContent, /Inbox/);
assert.match(strip.textContent, /Open ./);
assert.match(strip.textContent, /1 more group/);
assert.match(strip.textContent, /heartbeat alive 2026-09-12/);
const archiveButtons = rows.map(node => descendants(node).find(n => n.tagName === 'button' && n.textContent === '×'));
assert.ok(archiveButtons.every(Boolean), 'every row must carry an × archive icon button');
assert.equal(archiveButtons[0].attributes['aria-label'], 'Archive');

const exactBeforeFailure = serialize(strip);
previewStatus = 500;
await intervalCallback(); await tick();
assert.equal(serialize(strip), exactBeforeFailure, '5xx must preserve the exact previous DOM');
previewStatus = 403;
await intervalCallback(); await tick();
assert.equal(strip.hidden, true);
assert.equal(strip.textContent, '');
previewStatus = 200;
await intervalCallback(); await tick();
assert.equal(strip.hidden, false);
previewStatus = 404;
await intervalCallback(); await tick();
assert.equal(strip.hidden, true);
assert.equal(strip.textContent, '');
previewStatus = 200;
await intervalCallback(); await tick();

const activeRows = descendants(strip).filter(node => node.classList.contains('ms-row'));
for (const row of activeRows) {
  const title = descendants(row).find(node => node.classList.contains('ms-title'));
  await click(title);
}
const actions = activeRows.flatMap(row => descendants(row).filter(node => node.tagName === 'button'));
for (const label of ['Run', 'View', '×']) {
  await click(actions.find(node => node.textContent === label));
}
assert.deepEqual(uiCalls.message, ['run']);
assert.deepEqual(uiCalls.doc, ['doc', 'both']);
assert.deepEqual(uiCalls.run, ['run']);
assert.deepEqual(uiCalls.view, ['both']);
assert.deepEqual(uiCalls.archive, ['doc']);
assert.ok(requests.some(request => request.url === '/monitor/api/owner/run'));
assert.ok(requests.some(request => request.url === '/monitor/api/owner/run/window'));
assert.ok(requests.some(request => request.url.endsWith('/doc/archive')));
assert.equal(await injected.devtermUrl('devmon-exec'), 'https://box.example.test:19910/?arg=devmon-exec');

const revision = execFileSync('git', ['rev-parse', '--short=12', 'HEAD'], {encoding: 'utf8'}).trim();
console.log(`AC-16 | expected: shared_loaded==1&&cards==3&&counts==1&&badges==1&&ages==1&&actions==4&&heartbeat==1&&hide_403_404==1&&preserve_5xx==1 | observed: shared_loaded=1,cards=${rows.length},counts=1,badges=1,ages=1,actions=4,heartbeat=1,hide_403_404=1,preserve_5xx=1 | verdict: PASS | signal: fixture | evidence: apps/dev-monitor/test-hub-msgstrip-contract.mjs@${revision}`);
