// Exercise the shipped handlers with deterministic pointer events and timers.
const { readFileSync } = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = readFileSync(require('node:path').join(__dirname, '../hub/index.html'), 'utf8');
const start = html.indexOf('  function visibleOrder() {');
const code = html.slice(start, html.indexOf('\n})();', start));

class Element {
  constructor() { this.listeners = {}; this.dataset = {}; this.hidden = false; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  emit(type, event = {}) {
    event.target ||= this;
    event.preventDefault ||= () => { event.defaultPrevented = true; };
    for (const fn of this.listeners[type] || []) fn(event);
    return event;
  }
  focus() {}
}

const ROW = '[data-home-row]';
function rowElement(id, extra = {}) {
  const node = new Element();
  node.dataset.appName = id;
  node.dataset.homeRow = '1';
  Object.assign(node.dataset, extra);
  node.classList = { add() {}, remove() {}, toggle() {}, contains: () => false };
  node.getBoundingClientRect = () => ({ left: 0, top: 0, width: 100, height: 100 });
  node.setPointerCapture = () => {};
  node.hasPointerCapture = () => false;
  node.releasePointerCapture = () => {};
  node.cloneNode = () => ({ style: {}, remove() {}, classList: node.classList });
  node.closest = (selector) => (selector === ROW ? node : null);
  return node;
}

function setup(role = 'owner', withSecond = false) {
  const home = new Element(), doc = new Element(), win = new Element();
  const root = new Element(), addline = new Element();
  const a = rowElement('a'), b = rowElement('b');
  const children = withSecond ? [a, b] : [a];
  // Real geometry, because "after the target" is a claim about the pointer's
  // side of the target's midpoint. Two rows that both report left:0 make that
  // question unanswerable, and an assertion over it is decoration.
  // `shift` slides the target's box the way a FLIP transition does, so a test
  // can reproduce the one input the guard exists for: a target still moving.
  let shift = 0;
  a.getBoundingClientRect = () => ({ left: 0, top: 0, width: 100, height: 100 });
  b.getBoundingClientRect = () => ({ left: 100 + shift, top: 0, width: 100, height: 100 });
  // 🔴 Real DOM semantics: insertBefore(node, target) puts node BEFORE target,
  // and a null target appends. The earlier mock inserted AFTER, so every drag
  // assertion in this file was passing against the opposite behaviour from the
  // one the page runs on.
  const insertBefore = (node, target) => {
    children.splice(children.indexOf(node), 1);
    children.splice(target ? children.indexOf(target) : children.length, 0, node);
  };
  for (const node of children) node.parentElement = home;
  home.querySelectorAll = (selector) => (selector === ROW ? children : []);
  home.contains = (node) => children.includes(node);
  home.insertBefore = insertBefore;
  home.querySelector = () => null;
  home.appendChild = (node) => { children.push(node); node.parentElement = home; return node; };
  home.remove = () => {
    for (const node of [a, b]) {
      const i = children.indexOf(node);
      if (i >= 0) children.splice(i, 1);
    }
  };
  doc.elementFromPoint = () => b;
  doc.body = { appendChild() {} };
  doc.documentElement = root;
  doc.activeElement = { blur() {} };
  doc.getElementById = (id) => (id === 'home-addline' ? addline : null);
  const timers = new Map();
  let timerId = 0;
  const saved = [];
  const context = {
    me: { role }, home, document: doc, window: win,
    apps: { a: {}, b: {} },
    installed: withSecond ? ['a', 'b'] : ['a'],
    homeOrder: withSecond ? ['a', 'b'] : ['a'],
    cfg: { apps: {} },
    AIRLOCK_HOME_LINES: 2,
    airlockHomeItems: (order, installed) => (Array.isArray(order) ? order : []),
    filterApps() {},
    renderHubTiles() {},
    requestAnimationFrame(fn) { fn(); },
    fetch: async (url, init) => { saved.push(JSON.parse(init.body)); return { ok: false }; },
    setTimeout: (fn) => { timers.set(++timerId, fn); return timerId; },
    clearTimeout: (id) => timers.delete(id),
  };
  vm.runInNewContext(code, context);
  const pointer = (type, x = 0, extra = {}) => {
    const event = { target: a, pointerId: 1, pointerType: 'touch', isPrimary: true,
      button: 0, buttons: 1, clientX: x, clientY: 0, cancelable: true, ...extra };
    return (type === 'pointerdown' ? home : doc).emit(type, event);
  };
  const tick = () => { for (const [id, fn] of [...timers]) { timers.delete(id); fn(); } };
  return { context, home, doc, win, a, b, addline, root, pointer, tick, timers, saved,
    slide: (by) => { shift = by; },
    order: () => children.map(node => node.dataset.appName) };
}

// 25 · the two buttons this card retired are gone from the document.
// The names are assembled, not written out: this file is inside the card's own
// deletion grep, and a literal here would match itself and fail the suite that
// exists to prove the deletion happened.
{
  const OPEN = 'home-edit-' + 'open';
  const DONE = 'home-edit-' + 'done';
  assert.equal(html.includes('id="' + OPEN + '"'), false);
  assert.equal(html.includes('id="' + DONE + '"'), false);
  assert.equal(html.includes(DONE), false);
  assert.equal(html.includes('.home-edit-' + 'done'), false);
}

// 26 · a collaborator has no edit mode at all: the long press is a no-op.
for (const role of ['collaborator', null]) {
  const h = setup(role); h.pointer('pointerdown'); h.tick();
  assert.equal(h.root.dataset.homeEdit, undefined);
  assert.equal(h.saved.length, 0);
}

// 21 · 🔴 500ms held WITHOUT lifting: the same gesture edits and drags, once.
{
  const h = setup('owner', true);
  h.pointer('pointerdown');
  h.tick();
  assert.equal(h.root.dataset.homeEdit, '1', 'the press must open edit mode');
  h.pointer('pointermove', 180);
  assert.deepEqual(h.order(), ['b', 'a'], 'the same pointer must carry the tile');
  assert.equal(h.saved.length, 0, 'nothing is written until the finger lifts');
  h.pointer('pointerup');
  assert.equal(JSON.stringify(h.saved), '[{"order":["b","a"]}]', 'exactly one POST');
  assert.equal(h.root.dataset.homeEdit, '1', 'the mode stays open after a drop');
  // Already editing, so this press drags immediately — no second 500ms wait.
  h.pointer('pointerdown');
  h.pointer('pointermove', 120);
  h.pointer('pointerup');
  assert.equal(h.saved.length, 2, 'a second drag writes its own order');
  // The pointer came back to the left of b's midpoint, so the tile belongs on
  // that side again. This is the mockup's "drag it back" case, and it only
  // holds under real insertBefore semantics.
  assert.deepEqual(h.saved[1].order, ['a', 'b']);
}

// A drag fires pointermove far more often than it changes anything. Repeating
// the same position must not shuffle the row back and forth: the FLIP slide
// animates the tiles for 160ms after each move, so a midpoint read taken mid
// animation can come back on the other side of the target. Deciding the insert
// from the pointer's own side, and refusing a move the list already satisfies,
// makes the oscillation structurally impossible rather than merely unlikely.
{
  const h = setup('owner', true);
  h.pointer('pointerdown'); h.tick();
  h.pointer('pointermove', 180);
  assert.deepEqual(h.order(), ['b', 'a']);
  for (let i = 0; i < 6; i++) h.pointer('pointermove', 180);
  assert.deepEqual(h.order(), ['b', 'a'], 'six more moves at the same point change nothing');
  // And the same in the other direction, from the other side.
  for (let i = 0; i < 6; i++) h.pointer('pointermove', 120);
  assert.deepEqual(h.order(), ['a', 'b'], 'and it settles, it does not oscillate');
  h.pointer('pointerup');
  assert.equal(h.saved.length, 1, 'one gesture is one write');
  assert.deepEqual(h.saved[0].order, ['a', 'b']);

  // The slide itself: with the row already on the right of the target, a target
  // box that is still animating under the pointer must not send it back.
  const g = setup('owner', true);
  g.pointer('pointerdown'); g.tick();
  g.pointer('pointermove', 180);
  assert.deepEqual(g.order(), ['b', 'a']);
  for (let i = 0; i < 8; i++) { g.slide(i % 2 ? 40 : -40); g.pointer('pointermove', 180); }
  assert.deepEqual(g.order(), ['b', 'a'], 'a sliding target does not move a settled row');
  g.pointer('pointerup');
  assert.deepEqual(g.saved[0].order, ['b', 'a']);
}

// 22 · lifting before 500ms is a plain tap: no edit mode, no drag, no block.
{
  const h = setup();
  h.pointer('pointerdown'); h.pointer('pointerup'); h.tick();
  assert.equal(h.root.dataset.homeEdit, undefined);
  assert.equal(h.saved.length, 0);
}

// 23 · moving past the slop before 500ms is a scroll, not a long press.
for (const [pointerType, movement] of [['touch', 17], ['mouse', 7]]) {
  const h = setup(); h.pointer('pointerdown', 0, { pointerType });
  h.pointer('pointermove', movement, { pointerType }); h.tick();
  assert.equal(h.root.dataset.homeEdit, undefined);
}

// 24 · the empty space ends the edit; a tile tap does not; Esc does.
{
  const h = setup('owner', true);
  h.pointer('pointerdown'); h.tick(); h.pointer('pointerup');
  assert.equal(h.root.dataset.homeEdit, '1');
  const before = h.order();
  h.doc.emit('click', { target: { closest: (s) => (s === '.app' ? h.a : null) } });
  assert.equal(h.root.dataset.homeEdit, '1', 'a tile tap must not end the edit');
  assert.deepEqual(h.order(), before, 'a tile tap must not move anything');
  h.doc.emit('click', { target: { closest: () => null } });
  assert.equal(h.root.dataset.homeEdit, '0', 'the empty space ends the edit');
  h.pointer('pointerdown'); h.tick(); h.pointer('pointerup');
  assert.equal(h.root.dataset.homeEdit, '1');
  h.doc.emit('keydown', { key: 'Escape' });
  assert.equal(h.root.dataset.homeEdit, '0', 'Escape ends the edit');
}

// 27 · a tap on a tile launches. The old build called preventDefault on every
// tile click, which made the launcher unusable for the owner it was built for.
{
  const h = setup();
  const tap = (target) => h.home.emit('click', { target });
  const node = { closest: (s) => (s === '.app' ? h.a : null) };
  assert.equal(tap(node).defaultPrevented, undefined, 'an ordinary tap must navigate');
  h.pointer('pointerdown'); h.tick();                     // now editing
  assert.equal(tap(node).defaultPrevented, true, 'an edit-mode tap must not navigate');
  h.pointer('pointerup');
}

// 28 · the line cap hides the one control that creates a line.
{
  const h = setup();
  const withLines = (count) => {
    h.context.homeOrder = ['a'];
    for (let i = 0; i < count; i++) h.context.homeOrder.push({ line: 'L' + i });
    h.pointer('pointerdown'); h.tick();
    const hidden = h.addline.hidden;
    h.doc.emit('keydown', { key: 'Escape' });
    return hidden;
  };
  assert.equal(withLines(0), false, 'one line: the control is there');
  assert.equal(withLines(1), false, 'one line: the control is there');
  assert.equal(withLines(2), true, 'two lines: the control is gone');
}

// The two line hooks must live in a scope the drawn line can reach, and the
// removal must ask the DOM what the list now says rather than filtering by name.
// Both were real defects: `persist` was unreachable from the input handler (the
// name changed on screen and was never saved), and the removal rebuilt the row
// before removing it, so nothing was removed at all.
{
  assert.ok(html.indexOf('let removeLine') < html.indexOf('function lineNode'),
            'the hooks must be declared before the line nodes that call them');
  assert.ok(!html.includes('row.line === node.dataset.homeLine'),
            'removal must not match on the name');
  assert.ok(html.includes('node.remove();') && html.includes('homeOrder = visibleOrder();'),
            'removal must take the row out and take the order from the DOM');
  assert.ok(html.includes('input.addEventListener("change", () => renameLine(node, input.value));'),
            'the input must save itself when it is created, not when it is clicked');
  assert.ok(!html.includes('input.onchange'));
}

// Execute the standalone navigation handler: cancelled editing clicks cannot navigate.
const navStart = html.indexOf('if (("standalone" in navigator)');
const navCode = html.slice(navStart, html.indexOf('\n</script>', navStart));
{
  const doc = new Element(), location = { href: 'https://example.test/', origin: 'https://example.test' };
  vm.runInNewContext(navCode, { document: doc, navigator: { standalone: true }, location, URL });
  const target = { closest: () => ({ href: 'https://example.test/app', target: '' }) };
  doc.emit('click', { target, defaultPrevented: true });
  assert.equal(location.href, 'https://example.test/');
  doc.emit('click', { target });
  assert.equal(location.href, 'https://example.test/app');
}
console.log('PASS hub home edit: long-press-then-drag, slop, tap-to-stop, the line cap, and standalone navigation');