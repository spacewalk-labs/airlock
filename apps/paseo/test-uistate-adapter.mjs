// SPDX-License-Identifier: AGPL-3.0-only
// Evaluate the exact adapter and rehydrate listener injected into Paseo's bundle.
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const patcher = require("./browse-host/bin/patch-web-ui.js");
const patch = patcher.SUBAGENT_STREAM_PATCHES.find((p) => p.name === "sidebar-order-shared-storage");
assert.ok(patch, "the sidebar-order anchor is gone — nothing to evaluate");
const head = "storage:(0,n.createJSONStorage)(()=>";
const tail = "),partialize:";
const start = patch.repl.indexOf(head) + head.length;
const end = patch.repl.lastIndexOf(tail);
assert.ok(start > head.length - 1 && end > start, "could not locate the adapter expression");
const expression = patch.repl.slice(start, end);
const KEY = "sidebar-project-workspace-order";

function response(status, body = "", revision = null) {
  return {
    ok: status >= 200 && status < 300,
    status,
    text: async () => body,
    headers: { get: (name) => name.toLowerCase() === "x-airlock-revision" ? revision : null },
  };
}

function revisionServer(initial = null, initialRevision = initial === null ? 0 : 1) {
  let value = initial;
  let revision = initialRevision;
  const respond = async (_url, init = {}) => {
    const method = init.method ?? "GET";
    if (method === "GET") return response(value === null ? 404 : 200, value ?? "", String(revision));
    const base = init.headers?.["X-Airlock-Base-Revision"];
    if (base !== String(revision)) return response(409, value ?? "", String(revision));
    value = method === "DELETE" ? null : init.body;
    revision += 1;
    return response(204, "", String(revision));
  };
  return { respond, value: () => value, revision: () => revision };
}

function eventDocument() {
  const listeners = new Map();
  return {
    visibilityState: "visible",
    addEventListener(name, callback) {
      const values = listeners.get(name) ?? [];
      values.push(callback);
      listeners.set(name, values);
    },
    dispatchEvent(event) {
      for (const callback of listeners.get(event.type) ?? []) callback(event);
    },
  };
}

function build({ respond, document = eventDocument(), local = new Map(), beforeGet = async () => {} }) {
  const calls = [];
  const asyncStorage = {
    getItem: async (key) => { await beforeGet(key); return local.has(key) ? local.get(key) : null; },
    setItem: async (key, value) => { local.set(key, value); },
    removeItem: async (key) => { local.delete(key); },
  };
  const fetchStub = async (url, init = {}) => {
    calls.push({ url, method: init.method ?? "GET", headers: init.headers ?? {}, body: init.body });
    return respond(url, init);
  };
  const factory = new Function("g", "o", "fetch", "document", "Event", `return (${expression});`);
  return { adapter: factory({}, { default: asyncStorage }, fetchStub, document, Event), local, calls, document };
}

const tick = () => new Promise((resolve) => setImmediate(resolve));

// Shared server wins on load and its revision is remembered locally.
{
  const server = revisionServer('{"from":"server"}');
  const { adapter, local } = build(server);
  local.set(KEY, '{"from":"device"}');
  assert.equal(await adapter.getItem(KEY), '{"from":"server"}');
  assert.equal(local.get(KEY), '{"from":"server"}');
}

// First deployment seeds a truly new server (revision 0) from existing local order.
{
  const server = revisionServer();
  const { adapter, local } = build(server);
  local.set(KEY, '{"from":"pre-revision-device"}');
  assert.equal(await adapter.getItem(KEY), '{"from":"pre-revision-device"}');
  assert.equal(server.value(), '{"from":"pre-revision-device"}');
  assert.equal(server.revision(), 1);
}

// A local reorder during the first revision-0 seed is newer than the seed snapshot.
// Hydration returns that live value, then its rebased outbox becomes revision 2.
{
  let value = null, revision = 0;
  const releases = [];
  const respond = async (_url, init = {}) => {
    if ((init.method ?? "GET") === "GET") return response(404, "", "0");
    const base = init.headers["X-Airlock-Base-Revision"];
    return new Promise((resolve) => releases.push(() => {
      assert.equal(base, String(revision));
      value = init.body;
      revision += 1;
      resolve(response(204, "", String(revision)));
    }));
  };
  const { adapter, local } = build({ respond });
  local.set(KEY, '{"order":"seed"}');
  const read = adapter.getItem(KEY);
  await tick();
  const write = adapter.setItem(KEY, '{"order":"new-user"}');
  await tick();
  releases.shift()();
  assert.equal(await read, '{"order":"new-user"}');
  await tick();
  releases.shift()();
  await write;
  assert.equal(value, '{"order":"new-user"}');
  assert.equal(revision, 2);
}

// Normal reorder uses the observed revision and remembers the committed revision.
{
  const server = revisionServer('{"order":0}');
  const { adapter, local, calls } = build(server);
  await adapter.getItem(KEY);
  await adapter.setItem(KEY, '{"order":1}');
  assert.equal(server.value(), '{"order":1}');
  const put = calls.find((call) => call.method === "PUT");
  assert.equal(put.url, `/airlock-ui-state/v2/${KEY}`);
  assert.equal(put.headers["X-Airlock-Base-Revision"], "1");
}

// A -> B while A is in flight rebases B onto A's committed revision.
{
  let value = '{"order":0}', revision = 1;
  const releases = [];
  const respond = async (_url, init = {}) => {
    if ((init.method ?? "GET") === "GET") return response(200, value, String(revision));
    const base = init.headers["X-Airlock-Base-Revision"];
    return new Promise((resolve) => releases.push(() => {
      assert.equal(base, String(revision));
      value = init.body;
      revision += 1;
      resolve(response(204, "", String(revision)));
    }));
  };
  const { adapter, local, calls } = build({ respond });
  await adapter.getItem(KEY);
  const first = adapter.setItem(KEY, '{"order":1}');
  await tick();
  const second = adapter.setItem(KEY, '{"order":2}');
  await tick();
  assert.equal(local.get(KEY), '{"order":2}');
  assert.equal(calls.filter((call) => call.method === "PUT").length, 1);
  releases.shift()();
  await tick();
  assert.equal(calls.filter((call) => call.method === "PUT").length, 2);
  releases.shift()();
  await Promise.all([first, second]);
  assert.equal(value, '{"order":2}');
  assert.equal(revision, 3);
}

// A GET begun before a local reorder may finish afterwards. Its old response must
// not overwrite the immediately durable local value or cancel the queued mutation.
{
  let releaseGet, reads = 0;
  const server = revisionServer('{"order":"old"}');
  const respond = (url, init = {}) => {
    if ((init.method ?? "GET") !== "GET") return server.respond(url, init);
    reads += 1;
    if (reads === 1) return response(200, '{"order":"old"}', "1");
    return new Promise((resolve) => { releaseGet = () => resolve(response(200, '{"order":"old"}', "1")); });
  };
  const { adapter, local } = build({ respond });
  await adapter.getItem(KEY);
  const read = adapter.getItem(KEY);
  await tick();
  const write = adapter.setItem(KEY, '{"order":"new"}');
  await tick();
  assert.equal(local.get(KEY), '{"order":"new"}');
  releaseGet();
  assert.equal(await read, '{"order":"new"}');
  await write;
  assert.equal(server.value(), '{"order":"new"}');
}

// On first hydration there is no per-tab proof of what the visible UI was based on.
// Even equal bytes in shared localStorage may have come from another tab, so an
// overlapping gesture yields to the existing shared server value.
{
  let releaseGet;
  const server = revisionServer('{"order":"same-base"}');
  const respond = (url, init = {}) => {
    if ((init.method ?? "GET") !== "GET") return server.respond(url, init);
    return new Promise((resolve) => { releaseGet = () => resolve(response(200, '{"order":"same-base"}', "1")); });
  };
  const local = new Map([[KEY, '{"order":"same-base"}']]);
  const { adapter } = build({ respond, local });
  const read = adapter.getItem(KEY);
  await tick();
  const write = adapter.setItem(KEY, '{"order":"new-on-first-load"}');
  await tick();
  releaseGet();
  assert.equal(await read, '{"order":"same-base"}');
  await write;
  assert.equal(server.value(), '{"order":"same-base"}');
}

// If that first GET reveals a different shared snapshot, the local gesture was
// derived from stale UI and must be discarded rather than blessed with the revision.
{
  let releaseGet;
  const server = revisionServer('{"order":"fresh-server"}');
  const respond = (url, init = {}) => {
    if ((init.method ?? "GET") !== "GET") return server.respond(url, init);
    return new Promise((resolve) => { releaseGet = () => resolve(response(200, '{"order":"fresh-server"}', "1")); });
  };
  const local = new Map([[KEY, '{"order":"stale-local"}']]);
  const built = build({ respond, local });
  const read = built.adapter.getItem(KEY);
  await tick();
  const write = built.adapter.setItem(KEY, '{"order":"stale-derived"}');
  await tick();
  releaseGet();
  assert.equal(await read, '{"order":"fresh-server"}');
  await write;
  assert.equal(server.value(), '{"order":"fresh-server"}');
  assert.equal(built.calls.filter((call) => call.method === "PUT").length, 0);
}

// Two tabs share localStorage but must not share the revision each UI actually saw.
// Otherwise stale tab A can borrow tab B's rev2 and make its stale snapshot valid.
{
  const server = revisionServer('{"order":"initial"}');
  const local = new Map();
  const tabA = build({ respond: server.respond, local });
  const tabB = build({ respond: server.respond, local });
  await tabA.adapter.getItem(KEY);
  await tabB.adapter.getItem(KEY);
  await tabB.adapter.setItem(KEY, '{"order":"fresh-B"}');
  await tabA.adapter.setItem(KEY, '{"order":"stale-A"}');
  assert.equal(server.value(), '{"order":"fresh-B"}');
  assert.equal(local.get(KEY), '{"order":"fresh-B"}');
  assert.deepEqual(
    [...tabB.calls, ...tabA.calls].filter((call) => call.method === "PUT").map((call) => call.headers["X-Airlock-Base-Revision"]),
    ["1", "1"],
  );
}

// A delayed success from tab B must not clear tab A's newer shared outbox. The
// operation ID makes cleanup conditional on the exact pending record B sent.
{
  let value = '{"order":"initial"}', revision = 1, firstPut = true, releaseB;
  const respond = async (_url, init = {}) => {
    if ((init.method ?? "GET") === "GET") return response(200, value, String(revision));
    const base = init.headers["X-Airlock-Base-Revision"];
    if (base !== String(revision)) return response(409, value, String(revision));
    value = init.body;
    revision += 1;
    if (firstPut) {
      firstPut = false;
      return new Promise((resolve) => { releaseB = () => resolve(response(204, "", String(revision))); });
    }
    return response(204, "", String(revision));
  };
  const local = new Map();
  const tabB = build({ respond, local });
  await tabB.adapter.getItem(KEY);
  const writeB = tabB.adapter.setItem(KEY, '{"order":"B"}');
  await tick();
  assert.equal(value, '{"order":"B"}');
  assert.equal(revision, 2);

  let holdA = false, releaseARead;
  const tabA = build({
    respond,
    local,
    beforeGet: (key) => holdA && key === `@airlock-pending:${KEY}`
      ? new Promise((resolve) => { releaseARead = resolve; })
      : undefined,
  });
  assert.equal(await tabA.adapter.getItem(KEY), '{"order":"B"}');
  holdA = true;
  const writeA = tabA.adapter.setItem(KEY, '{"order":"A"}');
  await tick();
  assert.ok(releaseARead, "tab A did not pause after durably writing its outbox");
  releaseB();
  await tick();
  assert.match(local.get(`@airlock-pending:${KEY}`), /"value":"\{\\"order\\":\\"A\\"\}"/);
  holdA = false;
  releaseARead();
  await Promise.all([writeA, writeB]);
  assert.equal(value, '{"order":"A"}');
  assert.equal(revision, 3);
}

// A stale tab gets 409, keeps the other device's value, and rehydrates the store.
{
  const server = revisionServer('{"order":"old"}');
  const document = eventDocument();
  const { adapter, local } = build({ respond: server.respond, document });
  await adapter.getItem(KEY);
  await server.respond("", { method: "PUT", headers: { "X-Airlock-Base-Revision": "1" }, body: '{"order":"other-device"}' });
  let rehydrates = 0;
  const store = { persist: { rehydrate: () => { rehydrates += 1; return adapter.getItem(KEY); } } };
  new Function("f", "document", "Event", patcher.SIDEBAR_REHYDRATE_REVISIONED)(store, document, Event);
  await adapter.setItem(KEY, '{"order":"stale-tab"}');
  await tick();
  assert.equal(server.value(), '{"order":"other-device"}');
  assert.equal(local.get(KEY), '{"order":"other-device"}');
  assert.equal(rehydrates, 1);
}

// An offline outbox is rejected if another device advances its base revision.
{
  const server = revisionServer('{"order":0}');
  let online = true;
  const respond = (...args) => online ? server.respond(...args) : Promise.reject(new Error("offline"));
  const first = build({ respond });
  await first.adapter.getItem(KEY);
  online = false;
  await first.adapter.setItem(KEY, '{"order":"offline"}');
  assert.ok(first.local.has(`@airlock-pending:${KEY}`));
  online = true;
  await server.respond("", { method: "PUT", headers: { "X-Airlock-Base-Revision": "1" }, body: '{"order":"other-device"}' });
  assert.equal(await first.adapter.getItem(KEY), '{"order":"other-device"}');
  assert.equal(first.local.has(`@airlock-pending:${KEY}`), false);
}

// Legacy raw outboxes have no trustworthy base and are never transmitted.
{
  const server = revisionServer('{"order":"server"}', 7);
  const { adapter, local, calls } = build(server);
  local.set(KEY, '{"order":"legacy-pending"}');
  local.set(`@airlock-pending:${KEY}`, '{"order":"legacy-pending"}');
  assert.equal(await adapter.getItem(KEY), '{"order":"server"}');
  assert.equal(calls.some((call) => call.method !== "GET"), false);
  assert.equal(local.has(`@airlock-pending:${KEY}`), false);
}

// An old/headerless backend never receives PUT/DELETE, even around write-before-read.
{
  const respond = async (_url, init = {}) => response((init.method ?? "GET") === "GET" ? 200 : 204, '{"old":"backend"}');
  const { adapter, local, calls } = build({ respond });
  await adapter.setItem(KEY, '{"local":1}');
  await adapter.getItem(KEY);
  await adapter.setItem(KEY, '{"local":2}');
  await adapter.removeItem(KEY);
  assert.equal(calls.filter((call) => call.method !== "GET").length, 0);
  assert.equal(local.has(KEY), false);
}

// The versioned route encodes keys, and visibility still rehydrates only on return.
{
  const { adapter, calls } = build({ respond: async () => response(404, "", "0") });
  await adapter.getItem("a/b?c");
  assert.equal(calls[0].url, "/airlock-ui-state/v2/a%2Fb%3Fc");

  const document = eventDocument();
  document.visibilityState = "hidden";
  let rehydrates = 0;
  const store = { persist: { rehydrate: () => { rehydrates += 1; } } };
  new Function("f", "document", "Event", patcher.SIDEBAR_REHYDRATE_REVISIONED)(store, document, Event);
  document.dispatchEvent(new Event("visibilitychange"));
  assert.equal(rehydrates, 0);
  document.visibilityState = "visible";
  document.dispatchEvent(new Event("visibilitychange"));
  assert.equal(rehydrates, 1);
}

// ------------------------------------------------------------------ sync (poll)
// sync() is the revision check behind the visible-tab poll and the focus/online
// triggers. It never adopts a revision or touches the store itself: it only decides
// whether to raise the stale event that the existing rehydrate path answers.
function staleCounter(document) {
  let count = 0;
  document.addEventListener("airlock-ui-state-stale", () => { count += 1; });
  return () => count;
}

// Unchanged revision: one GET, no event, nothing re-rendered.
{
  const server = revisionServer('{"order":1}');
  const { adapter, calls, document } = build(server);
  const stale = staleCounter(document);
  await adapter.getItem(KEY);
  const before = calls.length;
  await adapter.sync(KEY);
  assert.equal(calls.length - before, 1);
  assert.equal(calls.at(-1).method, "GET");
  assert.equal(stale(), 0);
}

// Another device advanced the server: exactly one event, and the rehydrate that
// answers it reads the new value through the ordinary getItem path.
{
  const server = revisionServer('{"order":1}');
  const { adapter, local, document } = build(server);
  const stale = staleCounter(document);
  await adapter.getItem(KEY);
  await server.respond("/airlock-ui-state/v2/" + KEY, { method: "PUT", headers: { "X-Airlock-Base-Revision": "1" }, body: '{"order":2}' });
  await adapter.sync(KEY);
  assert.equal(stale(), 1);
  assert.equal(await adapter.getItem(KEY), '{"order":2}');
  assert.equal(local.get(KEY), '{"order":2}');
  await adapter.sync(KEY);
  assert.equal(stale(), 1, "a converged tab raises nothing more");
}

// Rolling-update recovery: first hydration met the old headerless backend, so no
// revision was ever observed. Once the backend answers with a revision the poll must
// request a full rehydrate rather than stay local forever.
{
  let capable = false;
  const respond = async (_url, init = {}) =>
    (init.method ?? "GET") === "GET" ? response(200, '{"order":1}', capable ? "7" : null) : response(204, "");
  const { adapter, calls, document } = build({ respond });
  const stale = staleCounter(document);
  await adapter.getItem(KEY);
  await adapter.sync(KEY);
  assert.equal(stale(), 0, "a headerless backend keeps the tab local");
  capable = true;
  await adapter.sync(KEY);
  assert.equal(stale(), 1, "the first revision-capable response requests rehydration");
  assert.equal(calls.filter((call) => call.method !== "GET").length, 0, "sync never writes");
}

// A mutation in flight owns the key: sync waits behind it on the network queue, so
// its GET observes the write's own revision and raises nothing.
{
  const releases = [];
  let revision = "1";
  const respond = async (_url, init = {}) => {
    if ((init.method ?? "GET") === "GET") return response(200, '{"order":1}', revision);
    return new Promise((resolve) => releases.push(() => { revision = "2"; resolve(response(204, "", "2")); }));
  };
  const { adapter, calls, document } = build({ respond });
  const stale = staleCounter(document);
  await adapter.getItem(KEY);
  const before = calls.length;
  const write = adapter.setItem(KEY, '{"order":"mine"}');
  await tick();
  const sync = adapter.sync(KEY);
  releases.forEach((release) => release());
  await write;
  await sync;
  const after = calls.slice(before).map((call) => call.method);
  assert.deepEqual(after, ["PUT", "GET"], "the poll's GET runs only after the write settled");
  assert.equal(stale(), 0);
}

// A mutation that begins while the poll's GET is outstanding wins: the GET result is
// dropped and no event is raised even though the revision moved underneath.
{
  let gate = null;
  const respond = async (_url, init = {}) => {
    if ((init.method ?? "GET") === "GET") {
      if (!gate) return response(200, '{"order":1}', "1");
      return new Promise((resolve) => { gate.release = () => resolve(response(200, '{"order":"other"}', "5")); });
    }
    return response(204, "", "6");
  };
  const { adapter, document } = build({ respond });
  const stale = staleCounter(document);
  await adapter.getItem(KEY);
  gate = {};
  const sync = adapter.sync(KEY);
  await tick();
  const write = adapter.setItem(KEY, '{"order":"mine"}');
  gate.release();
  await sync;
  await write;
  assert.equal(stale(), 0);
}

// A based outbox entry is replayed through the rehydrate path, not polled around.
{
  let online = false;
  const server = revisionServer('{"order":1}');
  const respond = async (url, init = {}) => {
    if (!online && (init.method ?? "GET") !== "GET") throw new Error("offline");
    return server.respond(url, init);
  };
  const { adapter, calls, local, document } = build({ respond });
  const stale = staleCounter(document);
  await adapter.getItem(KEY);
  await adapter.setItem(KEY, '{"order":"queued"}');
  assert.ok(local.has("@airlock-pending:" + KEY), "the failed write stays in the outbox");
  online = true;
  const before = calls.length;
  await adapter.sync(KEY);
  assert.equal(calls.length, before, "an outbox skips the GET");
  assert.equal(stale(), 1, "the outbox is replayed by rehydrate");
  assert.equal(await adapter.getItem(KEY), '{"order":"queued"}');
  assert.equal(server.value(), '{"order":"queued"}');
  assert.equal(local.has("@airlock-pending:" + KEY), false);
}

// A failed GET is swallowed; two overlapping syncs coalesce into one GET.
{
  let fail = true;
  let gate = null;
  const respond = async () => {
    if (fail) throw new Error("network");
    return new Promise((resolve) => { gate = () => resolve(response(200, '{"order":1}', "1")); });
  };
  const { adapter, calls, document } = build({ respond });
  const stale = staleCounter(document);
  await adapter.sync(KEY);
  assert.equal(stale(), 0);
  fail = false;
  const first = adapter.sync(KEY);
  const second = adapter.sync(KEY);
  await tick();
  const gets = calls.filter((call) => call.method === "GET").length;
  gate();
  await first;
  await second;
  assert.equal(gets, 2, "one failed GET plus one coalesced GET");
  assert.equal(stale(), 1, "no observed revision + capable response requests rehydration");
}

// End to end: the injected listener answers sync()'s stale event with a real rehydrate.
{
  const server = revisionServer('{"order":1}');
  const { adapter, document } = build(server);
  await adapter.getItem(KEY);
  let rehydrates = 0;
  const store = { persist: { rehydrate: () => { rehydrates += 1; return adapter.getItem(KEY); } } };
  new Function("f", "document", "Event", "g", patcher.SIDEBAR_REHYDRATE_REVISIONED)(store, document, Event, { __airlockUiState: adapter });
  await adapter.sync(KEY);
  assert.equal(rehydrates, 0);
  await server.respond("/airlock-ui-state/v2/" + KEY, { method: "PUT", headers: { "X-Airlock-Base-Revision": "1" }, body: '{"order":2}' });
  await adapter.sync(KEY);
  assert.equal(rehydrates, 1);
  await tick();
  assert.equal(await adapter.getItem(KEY), '{"order":2}');
}

console.log("paseo ui-state adapter: revision CAS, stale convergence, rolling safety, poll sync, and rehydrate wiring passed");
