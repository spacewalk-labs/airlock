import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const htmlPath = new URL('./frontend/publish.html', import.meta.url);
const html = fs.readFileSync(htmlPath, 'utf8');
const start = html.indexOf('// TESTABLE:BUNDLE_PLAN_STATE_START');
const end = html.indexOf('// TESTABLE:BUNDLE_PLAN_STATE_END');
assert.ok(start >= 0 && end > start, 'bundle plan state markers missing');

const source = html.slice(start, end)
  + '\nthis.api = { newBundlePlanState, startBundlePlan, acceptBundlePlanState,'
  + ' failBundlePlan, clearBundlePlanState, beginBundlePublishModal,'
  + ' closeBundlePublishModal, bundlePublishSelection, startBundlePublish,'
  + ' bundlePublishResponseState, isCurrentBundlePublish };';
const context = {};
vm.runInNewContext(source, context);
const api = context.api;

// The modal reuses the same checklist. A slow plan for document A can arrive
// after the person closes it and opens document B, so the token and name must
// reject that response before it can create B's preselected checkboxes.
const planState = api.newBundlePlanState();
const planA = api.startBundlePlan(planState, 'a.html');
const planB = api.startBundlePlan(planState, 'b.html');
assert.equal(
  api.acceptBundlePlanState(planState, planB, 'b.html', 'b.html', { plan_id: 'plan-b' }),
  true,
);
assert.equal(
  api.acceptBundlePlanState(planState, planA, 'a.html', 'b.html', { plan_id: 'plan-a' }),
  false,
);
assert.equal(planState.planId, 'plan-b');

// Publish stays blocked while planning; a recorded plan failure explicitly permits
// the documented entry-only fallback.
const planningState = api.newBundlePlanState();
const planningSeq = api.startBundlePlan(planningState, 'entry.html');
assert.equal(api.bundlePublishSelection(planningState, 'entry.html', []).ok, false);
assert.equal(api.failBundlePlan(planningState, planningSeq, 'entry.html', 'entry.html'), true);
assert.equal(api.bundlePublishSelection(planningState, 'entry.html', []).ok, true);

// Closing a modal must invalidate in-flight plan work and its capability.
// Otherwise reopening it could publish against a consumed or expired plan.
api.closeBundlePublishModal(planState);
assert.equal(planState.name, '');
assert.equal(planState.planId, '');
assert.equal(
  api.bundlePublishSelection(planState, 'b.html', ['child.html']).ok,
  false,
);

// Publishing is asynchronous too. If A's request finishes after B is open,
// accepting it would replace B's result, disable its controls, or show A's URL.
const publishState = api.newBundlePlanState();
api.beginBundlePublishModal(publishState, 'a.html');
api.startBundlePlan(publishState, 'a.html');
const publishA = api.startBundlePublish(publishState, 'a.html');
api.clearBundlePlanState(publishState);
api.beginBundlePublishModal(publishState, 'b.html');
api.startBundlePlan(publishState, 'b.html');
assert.equal(api.isCurrentBundlePublish(publishState, publishA, 'b.html'), false);

// Closing only hides the modal, so its current request is still reported as closed;
// reopening the modal advances the identity and makes that same response stale.
const closedState = api.newBundlePlanState();
api.beginBundlePublishModal(closedState, 'closed.html');
const closedPublish = api.startBundlePublish(closedState, 'closed.html');
api.closeBundlePublishModal(closedState);
assert.equal(api.bundlePublishResponseState(closedState, closedPublish, ''), 'closed');
assert.equal(api.isCurrentBundlePublish(closedState, closedPublish, ''), true);
api.beginBundlePublishModal(closedState, 'other.html');
assert.equal(api.bundlePublishResponseState(closedState, closedPublish, 'other.html'), 'stale');

// Remote mode never loads a bundle plan, so its open modal accepts a single-document response.
const remoteState = api.newBundlePlanState();
api.beginBundlePublishModal(remoteState, 'remote.html');
const remotePublish = api.startBundlePublish(remoteState, 'remote.html');
assert.equal(remoteState.name, '');
assert.equal(api.isCurrentBundlePublish(remoteState, remotePublish, 'remote.html'), true);

console.log('publish bundle plan state: ok');
