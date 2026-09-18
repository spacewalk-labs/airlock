// Exercise the shipped handlers with deterministic pointer events and timers.
const { readFileSync } = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = readFileSync(require('node:path').join(__dirname, '../hub/index.html'), 'utf8');
const start = html.indexOf('  // Long press and');
const code = html.slice(start, html.indexOf('\n})();', start));
class Element {
  constructor() { this.listeners = {}; this.dataset = {}; this.hidden = true; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  emit(type, event = {}) {
    event.target ||= this;
    event.preventDefault ||= () => { event.defaultPrevented = true; };
    for (const fn of this.listeners[type] || []) fn(event);
    return event;
  }
  focus() {}
}
function setup(role = 'owner', withSecond = false) {
  const secs = new Element(), doc = new Element(), win = new Element();
  const edit = new Element(), done = new Element(), root = new Element();
  const tile = new Element();
  const other = new Element(); other.dataset.appName = 'b';
  other.closest = selector => selector === '.app' ? other : null;
  for (const node of [tile, other]) node.getBoundingClientRect = () => ({ left: 0, top: 0 });
  const children = withSecond ? [tile, other] : [tile];
  const grid = new Element(); grid.querySelectorAll = () => children;
  grid.insertBefore = (node, target) => {
    children.splice(children.indexOf(node), 1);
    children.splice(target ? children.indexOf(target) : children.length, 0, node);
  };
  for (const node of children) {
    node.parentElement = grid;
    Object.defineProperty(node, 'nextSibling', { get: () => children[children.indexOf(node) + 1] || null });
  }
  const saved = []; let captured = false;
  tile.dataset.appName = 'a';
  tile.classList = { add() {}, remove() {} };
  tile.setPointerCapture = () => { captured = true; };
  tile.hasPointerCapture = () => captured;
  tile.releasePointerCapture = () => { captured = false; };
  tile.cloneNode = () => ({ style: {}, remove() {} });
  tile.closest = selector => selector === '.app' ? tile : null;
  secs.contains = node => node === tile;
  secs.querySelectorAll = () => children;
  doc.elementFromPoint = () => other;
  doc.body = { appendChild() {} };
  doc.documentElement = root;
  doc.getElementById = id => id === 'home-edit-open' ? edit : done;
  const timers = new Map(); let timerId = 0;
  const context = { me: { role }, secs, document: doc, window: win,
    homeOrder: withSecond ? ['a', 'b'] : ['a'],
    fetch: async (url, init) => { saved.push(JSON.parse(init.body)); return { ok: false }; },
    setTimeout: fn => { timers.set(++timerId, fn); return timerId; },
    clearTimeout: id => timers.delete(id) };
  vm.runInNewContext(code, context);
  const pointer = (type, x = 0, extra = {}) => {
    const event = { target: tile, pointerId: 1, pointerType: 'touch', isPrimary: true,
      button: 0, buttons: 1, clientX: x, clientY: 0, ...extra };
    return (type === 'pointerdown' ? secs : doc).emit(type, event);
  };
  const tick = () => { for (const [id, fn] of [...timers]) { timers.delete(id); fn(); } };
  return { secs, doc, win, tile, edit, done, root, pointer, tick, timers, saved,
    captured: () => captured, order: () => children.map(node => node.dataset.appName) };
}
for (const role of ['collaborator', null]) {
  const h = setup(role); h.pointer('pointerdown'); h.tick();
  assert.equal(h.root.dataset.homeEdit, undefined);
  assert.equal(h.edit.hidden, true);
}
{
  const h = setup(); h.pointer('pointerdown'); h.pointer('pointermove', 10); h.tick();
  assert.equal(h.root.dataset.homeEdit, '1');
  assert.equal(h.secs.emit('click', { target: h.tile }).defaultPrevented, true);
  h.pointer('pointerup'); h.done.emit('click');
  assert.equal(h.root.dataset.homeEdit, '0');
  h.edit.emit('click'); h.doc.emit('keydown', { key: 'Escape' });
  assert.equal(h.root.dataset.homeEdit, '0');
}
for (const [pointerType, movement] of [['touch', 17], ['mouse', 7]]) {
  const h = setup(); h.pointer('pointerdown', 0, { pointerType });
  h.pointer('pointermove', movement, { pointerType }); h.tick();
  assert.equal(h.root.dataset.homeEdit, undefined);
}
for (const type of ['pointerup', 'pointercancel']) {
  const h = setup(); h.pointer('pointerdown');
  h.pointer(type, 0, { pointerId: 2 });
  assert.equal(h.timers.size, 1, 'another pointer must not cancel the press');
  h.pointer(type); h.tick();
  assert.equal(h.root.dataset.homeEdit, undefined);
}
{
  const h = setup(); h.edit.emit('click'); h.pointer('pointerdown');
  assert.equal(h.captured(), true);
  h.pointer('pointerup', 0, { pointerId: 2 });
  assert.equal(h.captured(), true);
  assert.equal(h.saved.length, 0);
  h.pointer('pointerup');
  assert.equal(h.captured(), false);
  assert.equal(JSON.stringify(h.saved), '[{"order":["a"]}]');
  h.secs.emit('lostpointercapture', { pointerId: 1 });
  assert.equal(h.saved.length, 1, 'capture loss after release must not save twice');
}
{
  const h = setup('owner', true); h.edit.emit('click');
  h.pointer('pointerdown'); h.pointer('pointermove', 30); h.pointer('pointerup');
  assert.deepEqual(h.order(), ['b', 'a'], 'dragging the first tile onto the second must move it after the target');
  assert.equal(JSON.stringify(h.saved), '[{"order":["b","a"]}]');
  h.pointer('pointerdown'); h.pointer('pointermove', 30); h.pointer('pointerup');
  assert.deepEqual(h.order(), ['a', 'b'], 'dragging back must insert before the earlier target');
}
{
  const h = setup(); h.pointer('pointerdown'); h.win.emit('blur'); h.tick();
  assert.equal(h.root.dataset.homeEdit, undefined);
  h.pointer('pointerdown', 0, { button: 2 }); h.tick();
  assert.equal(h.root.dataset.homeEdit, undefined);
  assert.equal(h.secs.emit('click', { target: h.tile }).defaultPrevented, undefined);
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
console.log('PASS hub home edit: permission, slop, cancellation, buttons, click and standalone navigation');
