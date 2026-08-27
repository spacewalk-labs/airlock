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

// 1. The server's copy wins — that IS the cross-device behaviour.
{
  const { adapter, local } = build({ respond: () => ok('{"from":"server"}') });
  local.set(KEY, '{"from":"device"}');
  assert.equal(await adapter.getItem(KEY), '{"from":"server"}');
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

console.log("paseo ui-state adapter: server-first, local fallback, write-through, and offline safety passed");
