/* Offline regression checks for the message console's bounded bulk runner.

   Run: node install/test-monitor-bulk.mjs */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(
  new URL('../apps/dev-monitor/frontend/dev-monitor.html', import.meta.url), 'utf8');
const start = html.indexOf('/* TESTABLE:monitor-bulk');
const end = html.indexOf('/* :TESTABLE */', start);
assert.ok(start >= 0 && end > start, 'monitor-bulk markers missing from dev-monitor.html');

const context = {};
vm.runInNewContext(
  html.slice(start, end) +
    '\nthis.api = { runLimited, bulkCardActions, failedBulkIds, nextBulkSelection, retryBulkItems, bulkActionsForScope };',
  context);
const {
  bulkCardActions, failedBulkIds, nextBulkSelection, retryBulkItems, bulkActionsForScope,
} = context.api;

let active = 0;
let peak = 0;
const seen = [];
const result = await bulkCardActions(
  Array.from({ length: 13 }, (_, index) => 'card-' + index), 'archive',
  async (cardId, action) => {
    assert.equal(action, 'archive');
    active += 1;
    peak = Math.max(peak, active);
    await new Promise((resolve) => setTimeout(resolve, 2));
    active -= 1;
    seen.push(cardId);
    if (cardId === 'card-5' || cardId === 'card-11') throw new Error('fixture failure');
    return { ok: true };
  }, 4);

assert.ok(peak <= 4, `bulk concurrency exceeded four: ${peak}`);
assert.equal(seen.length, 13, 'every selected card is attempted once');
assert.deepEqual(Array.from(failedBulkIds(result)), ['card-5', 'card-11'],
  'partial failures remain identifiable for selection and undo retry');
assert.equal(result.filter((item) => item.ok).length, 11);

const selected = Object.fromEntries(Array.from({ length: 13 }, (_, index) => ['card-' + index, true]));
selected['selected-in-another-filter'] = true;
const retained = nextBulkSelection(selected, result);
assert.deepEqual(Object.keys(retained).sort(),
  ['card-11', 'card-5', 'selected-in-another-filter'],
  'successful selections clear, failures and selections outside this batch remain');
const retryCards = retryBulkItems(
  Array.from({ length: 13 }, (_, index) => ({ card_id: 'card-' + index })), result);
assert.deepEqual(Array.from(retryCards, (card) => card.card_id), ['card-5', 'card-11'],
  'Undo retries retain only the cards whose restore failed');

const noOp = await bulkCardActions(['already-unpinned'], 'unpin', async () => ({ ok: true }), 4);
assert.equal(noOp[0].ok, true, 'a successful no-op is deselected like any other success');

const empty = await bulkCardActions([], 'dismiss', async () => assert.fail('must not run'), 4);
assert.deepEqual(Array.from(empty), []);

assert.deepEqual(Array.from(bulkActionsForScope('active')), ['unpin', 'archive', 'dismiss']);
assert.deepEqual(Array.from(bulkActionsForScope('archived')), ['unpin', 'dismiss'],
  'archive is not offered where the real transition would return 404');

console.log('monitor bulk: ok');
