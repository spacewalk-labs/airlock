/* The file tree renders every item it is given — nothing is hidden.

   fileview promises that `.env` and every other dotfile is an ordinary file: it
   lists, opens, edits and saves like anything else. Two layers can break that.
   The server layer is pinned by apps/fileview/smoke.sh, which creates a dotfile and
   asserts the API lists it (and so also pins filebrowser's real `hideDotfiles`
   setting). This is the other layer: the client.

   A grep asserting "no .filter( appears in the render path" would be theatre — it
   passes for the wrong reasons and fails on a rename. So the actual renderer is
   extracted and run against a minimal DOM, and the assertion is a count: rows out
   equals items in.

   Run: node install/test-fileview-tree.mjs */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const src = fs.readFileSync(
  new URL('../apps/fileview/static/app.js', import.meta.url), 'utf8');
const start = src.indexOf('/* TESTABLE:tree');
const end = src.indexOf('/* :TESTABLE */');
assert.ok(start >= 0 && end > start, 'tree markers missing from apps/fileview/static/app.js');

// A DOM small enough to read in one sitting. Only what renderNode touches.
function makeElement(tag) {
  const el = {
    tagName: tag, className: '', textContent: '', dataset: {}, children: [],
    attributes: {},
    appendChild(child) { this.children.push(child); return child; },
    setAttribute(k, v) { this.attributes[k] = String(v); },
    getAttribute(k) { return k in this.attributes ? this.attributes[k] : null; },
    addEventListener() {},
  };
  return el;
}
const context = {
  document: { createElement: makeElement },
  // Referenced only inside the click handler, which this test never fires.
  toggleDir() {}, openFile() {},
};
vm.runInNewContext(
  src.slice(start, end) + '\nthis.api = { sortItems, renderNode };', context);
const { sortItems, renderNode } = context.api;

const item = (name, isDir = false) => ({ name, path: '/' + name, isDir, size: 1, modified: 'x' });

// The population deliberately includes everything anyone has ever been tempted to
// hide: the secret-looking dotfile, a dot directory, build output, a VCS directory,
// and a dependency tree.
const items = [
  item('.env'), item('.gitignore'), item('.bashrc'),
  item('.git', true), item('.venv', true), item('node_modules', true),
  item('dist', true), item('__pycache__', true), item('.DS_Store'),
  item('README.md'), item('main.py'), item('a.pyc'),
];

const sorted = sortItems(items);
assert.equal(sorted.length, items.length, 'sortItems dropped an item');

const rows = sorted.map((i) => renderNode(i, 0));
assert.equal(rows.length, items.length,
  'the tree rendered a different number of rows than it was given');

const names = rows.map((node) => {
  const row = node.children[0];
  return row.children.find((c) => c.className === 'ms-name').textContent;
});
for (const i of items) {
  assert.ok(names.includes(i.name), `${i.name} is missing from the rendered tree`);
}
assert.equal(new Set(names).size, items.length, 'a row was rendered twice');

// Not merely present: present as an ORDINARY row. A "shown but marked" dotfile is
// the same regression wearing a different hat.
//
// Comparing class names alone was not enough to pin that. An icon span whose
// TEXT differs per file type — the emoji set this app used to carry, or a
// monochrome redraw of it — keeps every class name identical and sails through.
// So the comparison is of everything the row says about the file except its
// name: class names, data attributes, inline styles, and the text of every part.
const decoration = (name) => {
  const node = rows[names.indexOf(name)];
  const row = node.children[0];
  const part = (c) => ({
    cls: c.className,
    text: c.textContent === '' ? '' : (c.className === 'ms-name' ? '<name>' : c.textContent),
    data: c.dataset,
    attrs: c.attributes,
    style: c.style || null,
  });
  return JSON.stringify({
    node: node.className,
    isdir: node.dataset.isdir,
    row: row.className,
    rowAttrs: row.attributes,
    parts: row.children.map(part),
  });
};
assert.equal(decoration('.env'), decoration('main.py'),
  '.env renders with different decoration than an ordinary file');
assert.equal(decoration('.git'), decoration('node_modules'),
  'a dot directory renders differently from an ordinary directory');

// The same claim, made once more where it cannot be satisfied by accident: every
// file in the fixture — .env, a Python file, a compiled object, a .DS_Store —
// produces the identical decoration. Two files agreeing could be luck; ten
// agreeing is the rule.
const fileNames = items.filter((i) => !i.isDir).map((i) => i.name);
for (const n of fileNames) {
  assert.equal(decoration(n), decoration('main.py'),
    `${n} is decorated differently from an ordinary file`);
}

// And the row carries no per-file decoration slot at all: a disclosure triangle
// and the name. A slot that exists is a slot something eventually fills.
const parts = rows[names.indexOf('main.py')].children[0].children.map((c) => c.className);
assert.deepEqual(parts.map((c) => c.split(' ')[0]), ['ms-chev', 'ms-name'],
  'the tree row grew a part beyond the disclosure triangle and the name');

// Positive control for the decoration comparison itself: it must be able to SEE a
// per-type mark. Without this, a comparison that always returned the same string
// would pass every assertion above.
const marked = JSON.parse(decoration('main.py'));
marked.parts[1].text = 'config';
assert.notEqual(JSON.stringify(marked), decoration('main.py'),
  'positive control failed: the decoration comparison cannot see a per-type mark');

// Positive control: the harness can tell the difference. If it could not, every
// assertion above would pass against a renderer that dropped everything.
const dropped = sortItems(items.filter((i) => !i.name.startsWith('.')));
assert.notEqual(dropped.length, items.length,
  'positive control failed: the fixture has no dotfiles to lose');

let pass = 0;
const ok = (m) => { pass += 1; console.log('ok   ' + m); };
ok(`the tree renders all ${items.length} items it is given`);
ok('.env, .gitignore, .bashrc and .DS_Store are all present');
ok('.git, .venv, node_modules, dist and __pycache__ are all present');
ok('a dotfile row is decorated identically to an ordinary file row');
ok(`all ${fileNames.length} files in the fixture share one decoration`);
ok('the row has no part beyond the disclosure triangle and the name');
ok('positive control: the decoration comparison can see a per-type mark');
ok('positive control: a filtered list is detectably shorter');
console.log('---');
console.log(`passed=${pass} failed=0`);
