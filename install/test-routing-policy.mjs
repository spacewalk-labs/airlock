/* The routing policy the screen states, checked against the one the backend follows.

   This file exists because the table is written twice: as ROUTING in
   backend/devmon_messages.py, which decides what is actually enqueued, and as POLICY in the
   page, which is what a person reads. A screen that states a rule the box does not follow is
   worse than no screen at all — it is the one place somebody would go to check.

   It also covers laneTone, because "unconfigured" and "broken" are different answers and the
   settings screen exists to tell them apart. On 2026-07-30 a lane was neither: it looked
   healthy while four urgent cards sat in it for nine days.

   It lives in install/ rather than apps/ because apps/ mirrors the public airlock-apps
   tree, and this file can never be mirrored: it extracts markers from a page and a backend
   module by path. install/ is where this repository already keeps checks that read app files
   (install/test-frontend-namespace.sh does the same). Registering it in the divergence
   baseline instead would have widened a guard in the direction it exists to close — the
   reasoning is P2's, in the commit that moved test-inbox-state.mjs for the same reason.

   Run: node install/test-routing-policy.mjs */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(new URL('../apps/dev-monitor/frontend/dev-monitor.html', import.meta.url), 'utf8');
const start = html.indexOf('/* TESTABLE:routing-policy');
const end = html.indexOf('/* :TESTABLE */', start);
assert.ok(start >= 0 && end > start, 'routing-policy markers missing from dev-monitor.html');

const context = {};
vm.runInNewContext(
  html.slice(start, end) + '\nthis.api = { POLICY, laneTone };', context);
// Copied out of the vm realm rather than used directly: an array built in there is that
// realm's Array, and deepStrictEqual refuses to match it against one of ours even when the
// contents agree. test-inbox-state.mjs carries the same note for the same reason.
const { laneTone } = context.api;
const POLICY = Array.from(context.api.POLICY, (row) => ({
  severity: row.severity, means: row.means, channels: Array.from(row.channels),
}));

// ---- the backend's table, read from the source rather than restated ----
// Restating it here would make this test agree with itself. The point is to compare two
// files that are edited by different hands at different times.
const py = fs.readFileSync(new URL('../apps/dev-monitor/backend/devmon_messages.py', import.meta.url), 'utf8');
const block = py.match(/^ROUTING = \{$([\s\S]*?)^\}$/m);
assert.ok(block, 'ROUTING table not found in devmon_messages.py');
const backend = new Map();
for (const line of block[1].split('\n')) {
  const row = line.match(/^\s*'([a-z]+)':\s*\(([^)]*)\)/);
  if (!row) continue;
  backend.set(row[1], row[2].split(',').map((c) => c.trim().replace(/^'|'$/g, '')).filter(Boolean));
}
assert.ok(backend.size > 0, 'parsed no rows out of ROUTING — the positive control for this file');

// ---- the two tables are the same table ----
assert.deepEqual([...backend.keys()].sort(), POLICY.map((r) => r.severity).sort(),
  'the screen and the backend disagree about which severities exist');
for (const row of POLICY) {
  assert.deepEqual(row.channels, backend.get(row.severity),
    `the screen states ${row.severity} -> ${row.channels} but the backend routes it to ` +
    `${backend.get(row.severity)}`);
}

// ---- the properties, asserted on the screen's copy too ----
for (const row of POLICY) {
  assert.equal(row.channels[0], 'console',
    `${row.severity} does not lead with the console — the inbox column cannot be turned off`);
  assert.ok(row.means && row.means.trim(), `${row.severity} has no plain-language meaning`);
}
assert.deepEqual(POLICY.map((r) => r.severity), ['page', 'attention', 'record', 'digest'],
  'the table is ordered loudest first, which is the order somebody scans it in');

// ---- unconfigured is not broken ----
const lane = (extra) => Object.assign(
  { worker_state: 'on', delivery_state: 'idle', pending_count: 0, last_error: null }, extra);
assert.equal(laneTone(lane({ worker_state: 'off: no webhook configured' })), 'unknown');
assert.equal(laneTone(lane({ worker_state: 'off: no transport configured' })), 'unknown',
  'the email lane names its own remedy, and an unset one is not a failure');
// Any other non-`on` state is a worker that stopped without saying it was switched off,
// which is a failure. Bare 'off' is not asserted either way: the server emits 'on' or one of
// the two 'off: <remedy>' strings, and pinning a value it cannot produce would invent a rule.
assert.equal(laneTone(lane({ worker_state: 'crashed' })), 'bad');
assert.equal(laneTone(lane()), 'ok');
assert.equal(laneTone(lane({ delivery_state: 'failed' })), 'bad');
assert.equal(laneTone(lane({ delivery_state: 'unknown' })), 'unknown');

// A queue with a retry in it is normal. A queue with a retry AND an error is 2026-07-30, and
// it must not be green: a channel that is off does not go quiet, it fills up.
assert.equal(laneTone(lane({ pending_count: 3 })), 'ok');
assert.equal(laneTone(lane({ pending_count: 3, last_error: 'http 500' })), 'bad');
assert.equal(laneTone(lane({ pending_count: 0, last_error: 'http 500' })), 'ok',
  'an error with nothing waiting is a retry that already succeeded');

// ---- the bootstrap must not run before the table it draws exists ----
// Not a style rule. Opening the page straight on #routing calls renderPolicy synchronously,
// and `var POLICY` hoists as undefined until its assignment runs — so with the bootstrap
// above it, the tab came up with headers and no rows, and the throw also stopped loadLanes
// before its fetch, leaving delivery health on "loading…" indefinitely. A live open found
// that; nothing in this file's vm sandbox could have, because the sandbox never runs the
// page's own start-up order.
const declared = html.indexOf('var POLICY = [');
const bootstrap = html.indexOf("showTab(location.hash === '#messages'");
assert.ok(declared > 0 && bootstrap > 0, 'POLICY declaration or showTab bootstrap not found');
assert.ok(bootstrap > declared,
  'the showTab bootstrap runs before `var POLICY` is assigned — opening #routing directly ' +
  'will draw an empty policy table and stall the delivery health');

console.log('routing policy: ok');
