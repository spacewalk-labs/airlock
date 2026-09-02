// SPDX-License-Identifier: AGPL-3.0-only
// What the injected storage adapter DOES, not just where it is anchored.
//
// patch-web-ui.test.js proves the anchor is unique and survives a migration; it
// cannot prove the replacement behaves, because the replacement is a string. This
// evaluates that exact string — the one the patcher writes into the bundle — against
// a stub AsyncStorage and a stub fetch, and pins the four behaviours the feature is:
// server-first reads, local fallback when there is no server answer, write-through on
// change, and never losing the local copy when the box has no ui-state backend.
//
//   node apps/paseo/test-uistate-adapter.mjs
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { SUBAGENT_STREAM_PATCHES } = require("./browse-host/bin/patch-web-ui.js");

const patch = SUBAGENT_STREAM_PATCHES.find((p) => p.name === "sidebar-order-shared-storage");
assert.ok(patch, "the sidebar-order anchor is gone — nothing to evaluate");

// Cut the adapter expression out of the replacement exactly as the bundle would
// evaluate it: everything the store passes to createJSONStorage.
const head = "storage:(0,n.createJSONStorage)(()=>";
const tail = "),partialize:";
const start = patch.repl.indexOf(head) + head.length;
const end = patch.repl.lastIndexOf(tail);
assert.ok(start > head.length - 1 && end > start, "could not locate the adapter expression");
const expression = patch.repl.slice(start, end);

const KEY = "sidebar-project-workspace-order";

function build({ respond }) {
  const local = new Map();
  const calls = [];
  const asyncStorage = {
    getItem: async (k) => (local.has(k) ? local.get(k) : null),
    setItem: async (k, v) => { local.set(k, v); },
    removeItem: async (k) => { local.delete(k); },
  };
  const fetchStub = async (url, init = {}) => {
    calls.push({ url, method: init.method ?? "GET", body: init.body });
    return respond(url, init);
  };
  // `g` is the bundle module's global parameter and `o.default` its AsyncStorage
  // import — the two free names the replacement leans on.
  const factory = new Function("g", "o", "fetch", `return (${expression});`);
  return { adapter: factory({}, { default: asyncStorage }, fetchStub), local, calls };
}

const ok = (body) => ({ ok: true, status: 200, text: async () => body });
const notFound = { ok: false, status: 404, text: async () => "" };
const unavailable = { ok: false, status: 503, text: async () => "" };

// 1. The server's copy wins — that IS the cross-device behaviour.
{
  const { adapter, local } = build({ respond: () => ok('{"from":"server"}') });
  local.set(KEY, '{"from":"device"}');
  assert.equal(await adapter.getItem(KEY), '{"from":"server"}');
  assert.equal(local.get(KEY), '{"from":"server"}', "a server read must refresh the offline fallback");
}

// 2. Nothing stored yet (404) falls back to this device instead of wiping it.
{
  const { adapter, local } = build({ respond: () => notFound });
  local.set(KEY, '{"from":"device"}');
  assert.equal(await adapter.getItem(KEY), '{"from":"device"}');
}

// 3. No backend at all (upstream paseo, or the service down) degrades to upstream
//    behaviour. This is the one that must never throw: a rejected hydrate would
//    leave the sidebar with no order at all.
{
  const { adapter, local } = build({ respond: () => { throw new Error("ECONNREFUSED"); } });
  local.set(KEY, '{"from":"device"}');
  assert.equal(await adapter.getItem(KEY), '{"from":"device"}');
  await adapter.setItem(KEY, '{"from":"reorder"}');
  assert.equal(local.get(KEY), '{"from":"reorder"}', "an offline write must still land locally");
  await adapter.removeItem(KEY);
  assert.equal(local.has(KEY), false);
}

// 4. A reorder writes through: local first (so it survives a failed request), then
//    the server, at the gated path, as a PUT carrying the same bytes.
{
  const { adapter, local, calls } = build({ respond: () => ok("") });
  await adapter.setItem(KEY, '{"from":"reorder"}');
  assert.equal(local.get(KEY), '{"from":"reorder"}');
  const put = calls.find((c) => c.method === "PUT");
  assert.ok(put, "no PUT reached the backend");
  assert.equal(put.url, `/airlock-ui-state/${KEY}`);
  assert.equal(put.body, '{"from":"reorder"}');

  await adapter.removeItem(KEY);
  const del = calls.find((c) => c.method === "DELETE");
  assert.ok(del, "no DELETE reached the backend");
  assert.equal(del.url, `/airlock-ui-state/${KEY}`);
  assert.equal(local.has(KEY), false);
}

// 5. The route is same-origin and per-key: a key with characters that would change
//    the path is encoded, not interpolated raw.
{
  const { adapter, calls } = build({ respond: () => notFound });
  await adapter.getItem("a/b?c");
  assert.equal(calls[0].url, "/airlock-ui-state/a%2Fb%3Fc");
}

// 6. A write made while the backend is down stays pending on the device. The next
// read retries it before accepting an older server value, then another device sees
// the recovered value. This is the exact 2026-09-01 unit-outage failure path.
{
  let online = false;
  let server = '{"from":"old-server"}';
  const respond = (_url, init = {}) => {
    const method = init.method ?? "GET";
    if (!online) return unavailable;
    if (method === "PUT") {
      server = init.body;
      return ok("");
    }
    return ok(server);
  };
  const first = build({ respond });
  await first.adapter.setItem(KEY, '{"from":"offline-reorder"}');
  assert.equal(first.local.get(KEY), '{"from":"offline-reorder"}');
  assert.equal(server, '{"from":"old-server"}');

  online = true;
  assert.equal(await first.adapter.getItem(KEY), '{"from":"offline-reorder"}');
  assert.equal(server, '{"from":"offline-reorder"}', "pending reorder was not retried");

  const second = build({ respond });
  assert.equal(await second.adapter.getItem(KEY), '{"from":"offline-reorder"}');
}

// 7. Persist may call setItem again before the prior fetch completes. Only one PUT
// may be in flight for this key, or an older request that completes last can undo the
// newest drag on the shared server.
{
  let server = null;
  const releases = [];
  const { adapter, local, calls } = build({
    respond: (_url, init = {}) => {
      if ((init.method ?? "GET") !== "PUT") return notFound;
      return new Promise((resolve) => {
        releases.push(() => {
          server = init.body;
          resolve(ok(""));
        });
      });
    },
  });
  const first = adapter.setItem(KEY, '{"order":1}');
  await new Promise((resolve) => setImmediate(resolve));
  const second = adapter.setItem(KEY, '{"order":2}');
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(calls.filter((call) => call.method === "PUT").length, 1, "PUTs were not serialized");
  assert.equal(local.get(KEY), '{"order":2}', "stalled PUT delayed the newest local fallback");
  assert.equal(local.get(`@airlock-pending:${KEY}`), '{"order":2}', "stalled PUT delayed the newest outbox");

  releases.shift()();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(calls.filter((call) => call.method === "PUT").length, 2);
  releases.shift()();
  await Promise.all([first, second]);
  assert.equal(server, '{"order":2}');
}

// 8. A GET begun before a reorder may finish after setItem was invoked. Its stale
// response must not roll the local cache or the value returned to rehydrate back.
{
  let releaseGet;
  let server = '{"order":"old"}';
  const { adapter, local } = build({
    respond: (_url, init = {}) => {
      const method = init.method ?? "GET";
      if (method === "GET") {
        const snapshot = server;
        return new Promise((resolve) => { releaseGet = () => resolve(ok(snapshot)); });
      }
      server = init.body;
      return ok("");
    },
  });
  const read = adapter.getItem(KEY);
  await new Promise((resolve) => setImmediate(resolve));
  const write = adapter.setItem(KEY, '{"order":"new"}');
  releaseGet();
  assert.equal(await read, '{"order":"new"}', "stale GET reached visibility rehydrate");
  await write;
  assert.equal(local.get(KEY), '{"order":"new"}');
  assert.equal(server, '{"order":"new"}');
}

// 9. Two GETs share the same operation queue, so an older delayed response cannot
// land after a newer one and poison the next offline fallback.
{
  let releaseFirst;
  let server = '{"order":1}';
  let reads = 0;
  const { adapter, local } = build({
    respond: () => {
      reads += 1;
      const snapshot = server;
      if (reads === 1) return new Promise((resolve) => { releaseFirst = () => resolve(ok(snapshot)); });
      return ok(snapshot);
    },
  });
  const first = adapter.getItem(KEY);
  await new Promise((resolve) => setImmediate(resolve));
  server = '{"order":2}';
  const second = adapter.getItem(KEY);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(reads, 1, "GETs overlapped outside the operation queue");
  releaseFirst();
  assert.equal(await first, '{"order":1}');
  assert.equal(await second, '{"order":2}');
  assert.equal(local.get(KEY), '{"order":2}');
}

// 10. Equal values are different generations. A -> B -> A while the first request
// is held must skip B but still send the final A; value equality alone cannot tell
// the first and third operations apart.
{
  const releases = [];
  const bodies = [];
  const { adapter } = build({
    respond: (_url, init = {}) => new Promise((resolve) => {
      bodies.push(init.body);
      releases.push(() => resolve(ok("")));
    }),
  });
  const first = adapter.setItem(KEY, "A");
  await new Promise((resolve) => setImmediate(resolve));
  const middle = adapter.setItem(KEY, "B");
  const last = adapter.setItem(KEY, "A");
  releases.shift()();
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(bodies, ["A", "A"]);
  releases.shift()();
  await Promise.all([first, middle, last]);
}

// 11. A stalled server read must not hold the durable local write behind its network
// queue. The tab can close before that GET resolves; by then both the visible fallback
// and the outbox must already contain the newest drag.
{
  let releaseGet;
  const { adapter, local, calls } = build({
    respond: (_url, init = {}) => {
      if ((init.method ?? "GET") === "GET") {
        return new Promise((resolve) => { releaseGet = () => resolve(ok('{"order":"old"}')); });
      }
      return ok("");
    },
  });
  const read = adapter.getItem(KEY);
  await new Promise((resolve) => setImmediate(resolve));
  const write = adapter.setItem(KEY, '{"order":"new"}');
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(calls.filter((call) => call.method === "GET").length, 1);
  assert.equal(calls.filter((call) => call.method === "PUT").length, 0);
  assert.equal(local.get(KEY), '{"order":"new"}', "stalled GET delayed the local fallback");
  assert.equal(local.get(`@airlock-pending:${KEY}`), '{"order":"new"}', "stalled GET delayed the durable outbox");

  releaseGet();
  assert.equal(await read, '{"order":"new"}');
  await write;
  assert.equal(local.has(`@airlock-pending:${KEY}`), false);
}

console.log("paseo ui-state adapter: immediate outbox, durable retry, generation ordering, serialization, and visibility safety passed");
