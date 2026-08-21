/* The inbox's needs-me rule and the buttons it allows, extracted from the page and run
   without a DOM.

   This file exists because the rule is written twice: as NEEDS_ME_SQL in
   backend/devmon_messages.py and as needsMe() in the page. Both are load-bearing — the
   server counts with one and the screen draws with the other — and the day they disagree a
   person is told two different things about the same card. The Python half is covered by
   backend/test_devmon.py; this is the other half.

   It lives in install/ rather than beside the app it tests, and that is deliberate. Under
   apps/ this repository and the public airlock-apps mirror are meant to hold the same files:
   of the six app test files here, five are in both trees, and the single work-only one sits in
   a batch install/apps-divergence-baseline.txt calls temporary. This test extracts markers
   from a page and could not be run against the mirror's copy, so putting it under apps/ would
   have meant widening that guard for a file that was never going to be mirrored.
   install/test-frontend-namespace.sh is the precedent: a repo-level check that reads app
   frontends and lives here.

   Run: node install/test-inbox-state.mjs */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(
  new URL('../apps/dev-monitor/frontend/dev-monitor.html', import.meta.url), 'utf8');
const start = html.indexOf('/* TESTABLE:inbox-state');
const end = html.indexOf('/* :TESTABLE */');
assert.ok(start >= 0 && end > start, 'inbox-state markers missing from dev-monitor.html');

const context = {};
vm.runInNewContext(
  html.slice(start, end) + '\nthis.api = { needsMe, isClosed, taskActionsFor };', context);
const { needsMe, isClosed, taskActionsFor } = context.api;

const HOUR = 3600 * 1000;
const later = new Date(Date.now() + 6 * HOUR).toISOString();
const passed = new Date(Date.now() - HOUR).toISOString();
const card = (extra) => Object.assign({ kind: 'info', needs_action: null, task_state: null }, extra);
// Array.from, not .map: taskActionsFor runs inside the vm realm and returns that realm's
// Array, which deepEqual refuses to match against one of ours even when the contents agree.
const labels = (c) => Array.from(taskActionsFor(c), (spec) => spec.label);
const actions = (c) => Array.from(taskActionsFor(c), (spec) => spec.action);

// ---- needs-me, matching NEEDS_ME_SQL clause for clause ----
assert.equal(needsMe(card({ needs_action: true })), true, 'declared and unstated reads as todo');
assert.equal(needsMe(card({ needs_action: true, task_state: 'todo' })), true);
assert.equal(needsMe(card({ needs_action: true, task_state: 'doing' })), false,
  'in flight is not "to do" — the badge is what is untouched');
assert.equal(needsMe(card({ needs_action: true, task_state: 'done' })), false);
assert.equal(needsMe(card({ needs_action: false })), false);
assert.equal(needsMe(card({ needs_action: null })), false, 'undeclared reads as a record');
assert.equal(needsMe(card({ needs_action: true, task_state: 'snoozed', snoozed_until: later })), false);
assert.equal(needsMe(card({ needs_action: true, task_state: 'snoozed', snoozed_until: passed })), true,
  'a snooze returns when its deadline passes, with nothing having swept');
assert.equal(needsMe(card({ needs_action: true, task_state: 'snoozed', snoozed_until: null })), true,
  'a snooze with no deadline is due now rather than never');

// The declaration is a boolean, and only `true` counts. A producer that sends a string, or
// the number 1, has not declared — the server rejects it, and the screen must not disagree.
for (const value of [1, 'true', {}, []]) {
  assert.equal(needsMe(card({ needs_action: value })), false, `needs_action ${JSON.stringify(value)}`);
}

// ---- what a record is never offered ----
// This is the phase's central claim, and it is asserted on the screen as well as in the
// backend because they fail differently: the server refusing is a 404 the person never sees,
// while a button that should not be there is the thing that puts a false completion in the
// count.
for (const state of [null, 'todo', 'doing', 'done', 'snoozed']) {
  for (const declared of [false, null, undefined]) {
    const c = card({ needs_action: declared, task_state: state });
    assert.deepEqual(labels(c), [], `record (${declared}/${state}) is offered nothing`);
    assert.equal(isClosed(c), true);
  }
}

// ---- the buttons a task is offered, per state ----
assert.deepEqual(labels(card({ needs_action: true })), ['Complete', 'Tomorrow', 'Not a task']);
assert.deepEqual(labels(card({ needs_action: true, task_state: 'todo' })),
  ['Complete', 'Tomorrow', 'Not a task']);
assert.deepEqual(labels(card({ needs_action: true, task_state: 'doing' })), ['Complete'],
  'a run in flight is stopped by the run controls, not by a task transition');
assert.deepEqual(labels(card({ needs_action: true, task_state: 'done' })), ['Reopen']);
assert.equal(isClosed(card({ needs_action: true, task_state: 'done' })), true);

// A snooze offers the way back; once its deadline passes it is an ordinary task again.
assert.deepEqual(actions(card({ needs_action: true, task_state: 'snoozed', snoozed_until: later })),
  ['complete', 'unsnooze', 'not_task']);
assert.deepEqual(actions(card({ needs_action: true, task_state: 'snoozed', snoozed_until: passed })),
  ['complete', 'snooze', 'not_task']);

// Every action the screen can emit must be one the backend's _CARD_ACTIONS table answers.
// A typo here is a button that 404s and looks like a broken console.
const SERVER_ACTIONS = new Set(['complete', 'reopen', 'snooze', 'unsnooze', 'not_task', 'start']);
for (const state of [null, 'todo', 'doing', 'done', 'snoozed']) {
  for (const spec of taskActionsFor(card({ needs_action: true, task_state: state }))) {
    assert.ok(SERVER_ACTIONS.has(spec.action), `unknown action ${spec.action}`);
  }
}

console.log('inbox state: ok');
