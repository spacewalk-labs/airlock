/* Offline checks for dev-monitor's always-visible service attention path.

   Run: node install/test-monitor-services.mjs */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync(
  new URL('../apps/dev-monitor/frontend/dev-monitor.html', import.meta.url), 'utf8');
const start = html.indexOf('/* TESTABLE:monitor-services');
const end = html.indexOf('/* :TESTABLE */', start);
assert.ok(start >= 0 && end > start,
  'monitor-services markers missing from dev-monitor.html');

const elements = {
  'nav-system-attention': { hidden: true, textContent: '' },
  'tb-system-attention': { hidden: true, textContent: '' },
  'services-section': { open: false },
  'svc-list': { innerHTML: '', querySelectorAll: () => [] },
};
const context = {
  API: '',
  document: { getElementById: (id) => elements[id] },
  escHTML: (value) => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;').replaceAll('"', '&quot;'),
  populateLogUnits: () => {},
  ownerFetch: () => assert.fail('no restart in this fixture'),
  ownerResponse: () => assert.fail('no restart in this fixture'),
  msgToast: () => {},
  window: { confirm: () => false },
};
vm.runInNewContext(
  html.slice(start, end) +
    '\nthis.api = { applyServiceAttention, serviceStateClass, serviceDetail, serviceJSON, loadServices };', context);
const { applyServiceAttention, serviceStateClass, serviceDetail, loadServices } = context.api;

applyServiceAttention(2);
for (const id of ['nav-system-attention', 'tb-system-attention']) {
  assert.equal(elements[id].hidden, false, `${id} is visible`);
  assert.equal(elements[id].textContent, '2', `${id} carries the API count`);
}
assert.equal(elements['services-section'].open, true,
  'attention opens the normally collapsed Services section');

applyServiceAttention(0);
assert.equal(elements['nav-system-attention'].hidden, true);
assert.equal(elements['tb-system-attention'].hidden, true);

const restarted = {
  attention: true, active_state: 'active', sub_state: 'running',
  result: 'success', n_restarts: 31780,
};
assert.equal(serviceStateClass(restarted), 'attention');
assert.match(serviceDetail(restarted), /active\/running/);
assert.match(serviceDetail(restarted), /Result=success/);
assert.match(serviceDetail(restarted), /NRestarts=31780/);

const completed = {
  attention: false, active_state: 'inactive', sub_state: 'dead',
  result: 'success', n_restarts: 0,
};
assert.equal(serviceStateClass(completed), 'inactive');
assert.match(serviceDetail(completed), /inactive\/dead/);
assert.equal(serviceStateClass({ state: 'active' }), '',
  'the additive API change keeps old service rows green during a rolling refresh');

let resolveRequest;
let requests = 0;
context.fetch = () => {
  requests += 1;
  return new Promise((resolve) => { resolveRequest = resolve; });
};
const first = loadServices();
const overlapping = loadServices();
assert.equal(first, overlapping, 'overlapping five-second refreshes share one request');
assert.equal(requests, 1);
resolveRequest({
  ok: true,
  status: 200,
  json: async () => ({
    attention_count: 1,
    services: [
      {
        name: 'aaa-healthy', scope: 'user', action_allowed: false,
        attention: false, attention_reason: '', uptime: '1m',
        active_state: 'active', sub_state: 'running', result: 'success', n_restarts: 0,
      },
      {
        name: '<img src=x>', scope: 'user', action_allowed: false,
        attention: true, attention_reason: '<restart storm>', uptime: '1m',
        active_state: 'active', sub_state: 'running', result: 'success', n_restarts: 31780,
      },
    ],
  }),
});
await first;
assert.equal(elements['services-section'].open, true);
assert.match(elements['svc-list'].innerHTML, /&lt;img src=x&gt;/,
  'service names are escaped in the integrated renderer');
assert.match(elements['svc-list'].innerHTML, /&lt;restart storm&gt;/,
  'attention reasons are escaped in the integrated renderer');
assert.doesNotMatch(elements['svc-list'].innerHTML, /<img src=x>/);
assert.ok(elements['svc-list'].innerHTML.indexOf('&lt;img src=x&gt;') <
  elements['svc-list'].innerHTML.indexOf('aaa-healthy'),
  'attention rows render before healthy rows even when the API sends them later');

context.fetch = async () => { throw new Error('<systemd offline>'); };
await loadServices();
assert.equal(elements['nav-system-attention'].textContent, '1');
assert.equal(elements['nav-system-attention'].hidden, false,
  'request failure is fail-visible on the System badge');
assert.match(elements['svc-list'].innerHTML, /&lt;systemd offline&gt;/);

context.fetch = async () => ({
  ok: false, status: 500,
  json: async () => assert.fail('a non-OK JSON body is not a successful empty payload'),
});
await loadServices();
assert.equal(elements['nav-system-attention'].hidden, false,
  'HTTP 500 with JSON remains fail-visible');
assert.match(elements['svc-list'].innerHTML, /HTTP 500/);

context.fetch = async () => ({ ok: true, status: 200, json: async () => ({ services: [] }) });
await loadServices();
assert.equal(elements['nav-system-attention'].hidden, true,
  'a missing additive count is backward-compatible and not NaN');

console.log('monitor services: ok');
