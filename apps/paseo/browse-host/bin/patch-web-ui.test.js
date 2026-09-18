#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only
"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const {
  BROWSE_PATCHES,
  KNOWN_BUNDLE_SHAPES,
  PINNED_SHA,
  SIDEBAR_POLL_MS,
  SUBAGENT_STREAM_PATCHES,
  patchBundleContent,
  productionShasForEdits,
} = require("./patch-web-ui.js");

const sha = (source) => crypto.createHash("sha256").update(source).digest("hex");

// Pin the shipped groups BY NAME first. Everything below derives its fixture from
// these arrays, so a dropped or renamed anchor would shrink the fixture with it and
// leave every other assertion passing — measured: deleting the fourth browse patch
// kept this file green until these three lines existed.
assert.deepEqual(BROWSE_PATCHES.map((patch) => patch.name), [
  "new-browser-gate-vo",
  "new-browser-gate-Wo",
  "browserpane-marker",
]);
const byName = (name) => SUBAGENT_STREAM_PATCHES.find((patch) => patch.name === name);
assert.deepEqual(SUBAGENT_STREAM_PATCHES.map((patch) => patch.name), [
  "sidebar-order-atomic-reconcile",
  "sidebar-order-stable-identity",
  "provider-subagent-visible-parent",
  "appearance-default-font-sizes",
  "sidebar-order-shared-storage",
  "sidebar-order-rehydrate-on-visibility",
  "tooltip-hover-none-is-compact",
  "project-actions-coarse-pointer",
  "sidebar-tap-not-swallowed-on-web",
]);
// The tablet "+" fix belongs to the ALWAYS-ON group, not the optional browse group.
assert.ok(byName("project-actions-coarse-pointer"));
assert.ok(byName("project-actions-coarse-pointer").repl.includes("(pointer: coarse)"));
assert.ok(!BROWSE_PATCHES.some((patch) => patch.repl.includes("(pointer: coarse)")));
// The sidebar-tap fix is only a fix if it keeps BOTH halves: the web branch (or nothing
// changes) and the ORIGINAL handler untouched for native (or a native build loses its
// drag/menu suppression). Reusing `o.isWeb` matters — it is the exact predicate the
// hook's own long-press timers are already disabled by, so the edit is inert on native
// rather than a second, differently-spelled platform test.
{
  const patch = byName("sidebar-tap-not-swallowed-on-web");
  assert.ok(patch.repl.includes("o.isWeb?()=>{}:"));
  // Byte-for-byte: the only difference is the branch in front of the handler.
  assert.equal(patch.repl.replace("o.isWeb?()=>{}:", ""), patch.find);
  // The platform test MUST sit in the hook body, in front of the handler — never
  // inside it. The handler declares its own scratch locals for the current touch
  // point, so an `o.isWeb` written inside resolves to a local in its temporal dead
  // zone and throws on EVERY touchmove. Measured: the first draft of this edit did
  // exactly that. This assertion is what keeps a "tidy-up" from moving it back in.
  assert.ok(patch.repl.indexOf("o.isWeb") < patch.repl.indexOf("e=>{"));
}
// The tooltip gate is only a fix if it keeps BOTH halves: the app's own compact
// branch (or nothing changes) and the hover-capability test (or desktop loses its
// tooltips too). Asserted on the bytes — a rewrite to `(pointer: coarse)` would
// also catch a mouse-less touchscreen kiosk, which is not the reported failure.
assert.ok(byName("tooltip-hover-none-is-compact").repl.includes("useIsCompactFormFactor"));
assert.ok(byName("tooltip-hover-none-is-compact").repl.includes('matchMedia?.("(hover: none)")'));
// The sidebar-order edit is only worth anything if it keeps BOTH halves: the shared
// route (or the order stays per-browser) and the local fallback (or a box without the
// backend loses the order entirely instead of degrading to upstream behaviour).
assert.ok(byName("sidebar-order-shared-storage").repl.includes("/airlock-ui-state/"));
assert.ok(byName("sidebar-order-shared-storage").repl.includes("local.getItem(key)"));
assert.ok(byName("sidebar-order-shared-storage").repl.includes("await writeLocal(key,value)"));
// 0.8.0: the backing storage passes directly to createValidatedPersistStorage's first
// argument (no createJSONStorage factory wrapper) — our adapter is still the first arg.
assert.ok(byName("sidebar-order-shared-storage").find.includes("createValidatedPersistStorage"));
assert.ok(byName("sidebar-order-shared-storage").repl.includes("createValidatedPersistStorage"));
// An already-open second device must converge when the owner switches back to it;
// initial hydration alone only updates a device that performs a full page load.
assert.ok(byName("sidebar-order-rehydrate-on-visibility").find.includes("migrate:y"));
assert.ok(byName("sidebar-order-rehydrate-on-visibility").repl.includes('document.addEventListener("visibilitychange"'));
assert.ok(byName("sidebar-order-rehydrate-on-visibility").repl.includes('"visible"===document.visibilityState'));
assert.ok(byName("sidebar-order-rehydrate-on-visibility").repl.includes("P.persist.rehydrate()"));
{
  const patch = byName("sidebar-order-rehydrate-on-visibility");
  const start = patch.repl.indexOf('"undefined"!=typeof document');
  const end = patch.repl.indexOf("},3813,[", start);
  const expression = patch.repl.slice(start, end);
  const listeners = new Map();
  const windowListeners = new Map();
  const intervals = [];
  let rehydrates = 0;
  const syncs = [];
  const documentStub = {
    visibilityState: "hidden",
    addEventListener: (name, callback) => {
      listeners.set(name, callback);
    },
  };
  const windowStub = {
    addEventListener: (name, callback) => {
      windowListeners.set(name, callback);
    },
    setInterval: (callback, ms) => {
      intervals.push({ callback, ms });
      return intervals.length;
    },
  };
  const P = { persist: { rehydrate: () => { rehydrates += 1; } } };
  const g = { __airlockUiState: { sync: (key) => { syncs.push(key); } } };
  new Function("document", "window", "P", "g", `return (${expression});`)(documentStub, windowStub, P, g);
  const listener = listeners.get("visibilitychange");
  assert.ok(listener, "visibility listener was not registered");
  assert.ok(listeners.has("airlock-ui-state-stale"), "stale-write listener was not registered");
  listener();
  assert.equal(rehydrates, 0, "a hidden tab must not rehydrate");
  documentStub.visibilityState = "visible";
  listener();
  assert.equal(rehydrates, 1, "a returning tab must rehydrate shared order");
  listeners.get("airlock-ui-state-stale")();
  assert.equal(rehydrates, 2, "a rejected stale write must rehydrate shared order");
  // Device/window return and network return go through the revision check, never a
  // blind rehydrate: an unchanged tab must not re-render (and must not disturb a drag).
  for (const name of ["focus", "online"]) {
    const windowListener = windowListeners.get(name);
    assert.ok(windowListener, `${name} listener was not registered`);
    windowListener();
  }
  assert.equal(rehydrates, 2, "focus/online must not rehydrate blindly");
  assert.deepEqual(syncs, ["sidebar-project-workspace-order", "sidebar-project-workspace-order"]);
  // One poll, at the named interval, that only checks while the tab is visible.
  assert.equal(intervals.length, 1, "exactly one poll interval");
  assert.equal(intervals[0].ms, SIDEBAR_POLL_MS);
  assert.ok(SIDEBAR_POLL_MS >= 30000, "the poll is low-frequency by design");
  documentStub.visibilityState = "hidden";
  intervals[0].callback();
  assert.equal(syncs.length, 2, "a hidden tick must do nothing");
  documentStub.visibilityState = "visible";
  intervals[0].callback();
  intervals[0].callback();
  assert.equal(syncs.length, 4, "a visible tick syncs once per interval");
  assert.equal(rehydrates, 2, "the poll itself never rehydrates; only the stale event does");
}
{
  const patch = byName("sidebar-order-rehydrate-on-visibility");
  const head = patch.find.slice(0, "partialize:e=>".length);
  const tail = "},3813,[1587,3401,3404,3313,3553]);";
  assert.ok(patch.find.endsWith(tail));
  assert.ok(patch.repl.startsWith(head), "rehydrate replacement lost the anchor head");
  assert.ok(patch.repl.endsWith(tail), "rehydrate replacement lost the anchor tail");
  assert.equal(patch.repl.split(head).length - 1, 1, "rehydrate replacement duplicates the anchor head");
}
// The adapter half: the poll needs the revision check the storage exposes.
assert.ok(byName("sidebar-order-shared-storage").repl.includes("sync:key=>"));
// The default the user sees on a device that has never saved settings. Asserted on
// the bytes, not the name: a silent revert to upstream's stock defaults is the
// failure mode. 0.8.0's ui default is a function call (N(E.isNative)), not a bare
// literal — the patch replaces the call outright with our literal default.
assert.ok(byName("appearance-default-font-sizes").find.includes("const R=N(E.isNative)"));
assert.ok(byName("appearance-default-font-sizes").repl.includes("const R=18"));
assert.ok(byName("appearance-default-font-sizes").find.includes(",B=12,"));
assert.ok(byName("appearance-default-font-sizes").repl.includes(",B=14,"));

const ALL_EDITS = [
  ...SUBAGENT_STREAM_PATCHES.map((patch) => patch.name),
  ...BROWSE_PATCHES.map((patch) => patch.name),
];
const GENERAL_EDITS = SUBAGENT_STREAM_PATCHES.map((patch) => patch.name);
const BROWSE_EDITS = BROWSE_PATCHES.map((patch) => patch.name);
const key = (edits) => [...edits].sort().join("|");

// ---------------------------------------------------------------- the shape table
// A shape naming an edit that no longer exists is dead weight that would silently
// accept nothing; a duplicated edit set would make the lookup order-dependent.
for (const shape of KNOWN_BUNDLE_SHAPES) {
  assert.match(shape.sha, /^[0-9a-f]{64}$/);
  for (const legacySha of shape.legacyShas ?? []) assert.match(legacySha, /^[0-9a-f]{64}$/);
  for (const edit of shape.edits) {
    assert.ok(ALL_EDITS.includes(edit), `shape names an unknown edit: ${edit}`);
  }
}
assert.equal(
  new Set(KNOWN_BUNDLE_SHAPES.map((shape) => key(shape.edits))).size,
  KNOWN_BUNDLE_SHAPES.length,
);
assert.equal(
  new Set(KNOWN_BUNDLE_SHAPES.flatMap((shape) => [shape.sha, ...(shape.legacyShas ?? [])])).size,
  KNOWN_BUNDLE_SHAPES.reduce((count, shape) => count + 1 + (shape.legacyShas?.length ?? 0), 0),
);
// Pre-identity fleet bytes remain accepted alongside the two upgraded shapes.
assert.equal(KNOWN_BUNDLE_SHAPES.length, 5);
assert.deepEqual(KNOWN_BUNDLE_SHAPES[0].edits, []);
const PRE_IDENTITY = name => !name.startsWith("sidebar-order-stable-") && name !== "sidebar-order-atomic-reconcile";
assert.equal(key(KNOWN_BUNDLE_SHAPES[1].edits), key(GENERAL_EDITS.filter(PRE_IDENTITY)));
assert.equal(key(KNOWN_BUNDLE_SHAPES[2].edits), key(ALL_EDITS.filter(PRE_IDENTITY)));
assert.equal(key(KNOWN_BUNDLE_SHAPES[3].edits), key(GENERAL_EDITS));
assert.equal(key(KNOWN_BUNDLE_SHAPES[4].edits), key(ALL_EDITS));

assert.deepEqual(productionShasForEdits([]), [PINNED_SHA]);
assert.equal(productionShasForEdits(ALL_EDITS).length, 1);
assert.equal(productionShasForEdits(GENERAL_EDITS).length, 1);
assert.equal(productionShasForEdits(BROWSE_EDITS).length, 0, "browse alone, without the always-on group, is not a shape anything ships");
// The lookup is set equality, so a repeated name must not turn a known shape into an
// unknown one. Production cannot repeat a name today; the argument is a plain list and
// this is what keeps that an implementation detail rather than a latent refusal.
assert.deepEqual(
  productionShasForEdits([...GENERAL_EDITS, GENERAL_EDITS[0]]),
  productionShasForEdits(GENERAL_EDITS),
);
assert.deepEqual(
  productionShasForEdits([...ALL_EDITS].reverse()),
  productionShasForEdits(ALL_EDITS),
);
// A set nobody ever shipped is NOT waved through — it returns no accepted SHA, which
// is what turns into the refusal below.
assert.deepEqual(productionShasForEdits(["browserpane-marker"]), []);

// ------------------------------------------------------- state transitions (fixture)
const pristine = [
  ...BROWSE_PATCHES.map((patch) => patch.find),
  ...SUBAGENT_STREAM_PATCHES.map((patch) => patch.find),
].join("\n");

function apply(source, mode, acceptedShas) {
  return patchBundleContent(source, {
    mode,
    acceptedShas,
  });
}

// pristine -> general -> combined
const general = apply(pristine, "subagent-stream", [sha(pristine)]);
assert.equal(general.alreadyPatched, false);
assert.match(general.source, /provider_subagent/);
assert.ok(general.source.includes("(pointer: coarse)"));
assert.ok(general.source.includes(byName("sidebar-tap-not-swallowed-on-web").repl));
for (const patch of BROWSE_PATCHES) assert.ok(general.source.includes(patch.find));

const combinedFromGeneral = apply(general.source, "browse", [sha(general.source)]);
assert.equal(combinedFromGeneral.alreadyPatched, false);
for (const patch of BROWSE_PATCHES) assert.ok(combinedFromGeneral.source.includes(patch.repl));
for (const patch of SUBAGENT_STREAM_PATCHES) assert.ok(combinedFromGeneral.source.includes(patch.repl));

// pristine -> browse-only -> combined.
const browseOnly = apply(pristine, "browse", [sha(pristine)]);
assert.equal(browseOnly.alreadyPatched, false);
for (const patch of SUBAGENT_STREAM_PATCHES) assert.ok(browseOnly.source.includes(patch.find));
assert.ok(!browseOnly.source.includes("(pointer: coarse)"));
const combinedFromBrowse = apply(browseOnly.source, "subagent-stream", [sha(browseOnly.source)]);
assert.equal(combinedFromBrowse.source, combinedFromGeneral.source);

// Combined and each individual group are idempotent, and the other group survives.
assert.equal(apply(combinedFromGeneral.source, "browse", [sha(combinedFromGeneral.source)]).alreadyPatched, true);
assert.equal(apply(combinedFromGeneral.source, "subagent-stream", [sha(combinedFromGeneral.source)]).alreadyPatched, true);

// ------------------------------------------------------------- refusal controls
// A partial browse group that is NOT one of the named shapes stays refused: the
// state is readable, but nothing accepts its bytes, so the SHA pin is what stops it.
const halfBrowse = pristine.replace(BROWSE_PATCHES[0].find, BROWSE_PATCHES[0].repl);
assert.throws(
  () => patchBundleContent(halfBrowse, { mode: "subagent-stream" }),
  /bundle SHA mismatch/,
);
// The refusal has to say WHICH shape it could not place, or the operator is left
// diffing 20MB of minified JS to find out what state the box is in.
assert.throws(
  () => patchBundleContent(halfBrowse, { mode: "subagent-stream" }),
  /no known bundle shape holds exactly \[new-browser-gate-vo\]/,
);

// An unknown otherwise-pristine state cannot bypass the SHA pin.
const unknown = pristine + "\nunknown-change";
assert.throws(
  () => apply(unknown, "subagent-stream", [sha(pristine)]),
  /bundle SHA mismatch/,
);

const unknownCombined = combinedFromGeneral.source + "\nunknown-change";
assert.throws(
  () => apply(unknownCombined, "browse", [sha(combinedFromGeneral.source)]),
  /bundle SHA mismatch/,
);

// Preserve the historical `(source, expectedSha)` browse test seam.
const legacySeam = patchBundleContent(pristine, sha(pristine));
assert.equal(legacySeam.alreadyPatched, false);
for (const patch of BROWSE_PATCHES) assert.ok(legacySeam.source.includes(patch.repl));

// Exercise the shipped replacement, with upstream append/prepend helpers. Each
// invocation below represents a committed sidebar effect, followed by a drag or
// daemon directory update. No storage schema or remote alias is involved.
{
  const vm = require("node:vm");
  function loadOrder(source) {
    const e = {};
    vm.runInNewContext(source, {
      e,
      K: ({currentOrder, visibleKeys}) => {
        const missing = visibleKeys.filter(key => !currentOrder.includes(key));
        return missing.length ? [...currentOrder, ...missing] : currentOrder;
      },
      I: ({currentOrder, visibleKeys}) => {
        const missing = visibleKeys.filter(key => !currentOrder.includes(key));
        return missing.length ? [...missing, ...currentOrder] : currentOrder;
      },
    });
    return e.computeSidebarOrderUpdates;
  }
  const patch = byName("sidebar-order-stable-identity");
  const host = (serverId, projectId) => ({serverId, projectId});
  const project = (viewKey, hosts, keys = []) => ({
    viewKey, hosts, workspaces: keys.map(workspaceKey => ({workspaceKey})),
  });
  const eq = "remote:github.com/team/repo";
  const placed = JSON.stringify(["s", "repo"]);
  const clone = JSON.stringify(["s", "clone"]);
  const primary = key => project(key, [host("s", "repo")], ["s:a", "s:b"]);
  const other = project("other", [host("s", "other")]);
  const duplicate = project(clone, [host("s", "clone")], ["s:clone"]);
  const run = compute => {
    const state = {projectOrder: [eq, "other", placed], workspaceOrders: {
      [eq]: ["s:b", "s:a"], [placed]: ["s:a", "s:b"],
    }};
    const effect = projects => {
      const update = compute({projects, persistedProjectOrder: state.projectOrder,
        getWorkspaceOrder: key => state.workspaceOrders[key] ?? []});
      if (update.projectOrder) state.projectOrder = Array.from(update.projectOrder);
      for (const {projectViewKey, order} of update.workspaceOrders)
        state.workspaceOrders[projectViewKey] = Array.from(order);
      return update;
    };
    effect([primary(eq), other]);
    effect([primary(placed), other, duplicate]);
    return {state, effect};
  };
  // Negative control: the unpatched function loses both orders even though the
  // incoming key already exists. A missing-key fallback would miss this case.
  const broken = run(loadOrder(patch.find));
  assert.equal(broken.state.projectOrder.indexOf(placed), 2);
  assert.deepEqual(broken.state.workspaceOrders[placed], ["s:a", "s:b"]);
  const {state, effect} = run(loadOrder(patch.repl));
  assert.deepEqual(state.projectOrder, [placed, "other", clone]);
  assert.deepEqual(state.workspaceOrders[placed], ["s:b", "s:a"]);
  assert.deepEqual(state.workspaceOrders[clone], ["s:clone"]);
  // Drag while duplicated; returning to a previously used key must carry the
  // latest outgoing order instead of reviving that key's old record.
  state.projectOrder = ["other", placed, clone];
  state.workspaceOrders[placed] = ["s:a", "s:b"];
  effect([primary(eq), other]);
  assert.deepEqual(state.projectOrder, ["other", eq, clone]);
  assert.deepEqual(state.workspaceOrders[eq], ["s:a", "s:b"]);
  // Repeat after both keys have records, then reconnect through an empty snapshot.
  state.workspaceOrders[eq] = ["s:b", "s:a"];
  effect([]);
  effect([primary(placed), other, duplicate]);
  assert.deepEqual(state.workspaceOrders[placed], ["s:b", "s:a"]);
  assert.deepEqual(state.projectOrder, ["other", placed, clone]);
  const unchanged = effect([primary(placed), other, duplicate]);
  assert.equal(unchanged.projectOrder, null);
  assert.equal(unchanged.workspaceOrders.length, 0);
  // New workspaces still prepend; genuinely new projects still append.
  effect([project(placed, [host("s", "repo")], ["s:a", "s:b", "s:new"]),
    other, duplicate, project("brand-new", [host("s", "new")])]);
  assert.deepEqual(state.workspaceOrders[placed], ["s:new", "s:b", "s:a"]);
  assert.equal(state.projectOrder.at(-1), "brand-new");
  // The same remote is not placement identity: replacement with a different clone
  // on first load or during a session gets no inherited slot or workspace order.
  const fresh = loadOrder(patch.repl);
  const historyKey = "@airlock:sidebar-placement-keys:v1";
  let history = [];
  fresh({projects: [primary(eq)], persistedProjectOrder: [eq],
    getWorkspaceOrder: key => key === historyKey ? [] : ["s:b", "s:a"]}).workspaceOrders
    .forEach(item => { if (item.projectViewKey === historyKey) history = Array.from(item.order); });
  const replaced = fresh({projects: [duplicate], persistedProjectOrder: [eq],
    getWorkspaceOrder: key => key === historyKey ? history : key === eq ? ["s:b", "s:a"] : []});
  assert.deepEqual(Array.from(replaced.projectOrder), [eq, clone]);
  assert.deepEqual(Array.from(replaced.workspaceOrders[0].order), ["s:clone"]);
  // Multi-host equivalence splits are ambiguous; never hand one shared slot to
  // an arbitrary clone. A still-visible source must also keep its slot.
  const multi = loadOrder(patch.repl);
  const multiOrders = {};
  const base = {persistedProjectOrder: [eq], getWorkspaceOrder: key => multiOrders[key] ?? []};
  const commit = update => update.workspaceOrders.forEach(item => {
    multiOrders[item.projectViewKey] = Array.from(item.order);
  });
  commit(multi({...base, projects: [project(eq, [host("s", "repo"), host("t", "repo")])]}));
  const split = multi({...base, projects: [primary(placed),
    project('t-placement', [host("t", "repo")])]});
  assert.deepEqual(Array.from(split.projectOrder), [eq, placed, "t-placement"]);
  const surviving = loadOrder(patch.repl);
  multiOrders[historyKey] = [];
  commit(surviving({...base, projects: [primary(eq)]}));
  const shared = surviving({...base, projects: [primary(placed),
    project(eq, [host("t", "repo")])]});
  assert.deepEqual(Array.from(shared.projectOrder), [eq, placed]);
  // Reviewer counterexample: a group that stayed visible throughout a split
  // must keep its project slot and interleaved multi-host workspace order on merge.
  commit(shared);
  multiOrders[eq] = ["t:x", "s:a"];
  multiOrders[placed] = ["s:a"];
  const merged = surviving({persistedProjectOrder: [placed, eq, clone],
    getWorkspaceOrder: key => multiOrders[key] ?? [],
    projects: [project(eq, [host("s", "repo"), host("t", "repo")], ["s:a", "t:x"])]});
  assert.equal(merged.projectOrder, null);
  assert.ok(!merged.workspaceOrders.some(item => item.projectViewKey === eq));
  // Reload using the saved state: no module-local history is needed. An unused
  // computation must also leave the next real reconciliation able to migrate.
  state.workspaceOrders[placed] = ["s:a", "s:b", "s:new"];
  const afterReload = loadOrder(patch.repl);
  const input = {projects: [primary(eq), other], persistedProjectOrder: state.projectOrder,
    getWorkspaceOrder: key => state.workspaceOrders[key] ?? []};
  const discarded = afterReload(input);
  const replayed = afterReload(input);
  assert.deepEqual(JSON.parse(JSON.stringify(replayed)), JSON.parse(JSON.stringify(discarded)));
  const inherited = replayed.workspaceOrders.find(item => item.projectViewKey === eq);
  assert.deepEqual(Array.from(inherited.order).slice(0, 2), ["s:a", "s:b"]);
  // One store write contains both order updates and the identity history; pinned
  // order and unrelated records remain in the merged Zustand state.
  const reconcile = byName("sidebar-order-atomic-reconcile");
  const writes = [];
  vm.runInNewContext(reconcile.repl, {
    o: replayed,
    t: {workspaceOrderByProject: {...state.workspaceOrders, unrelated: ["keep"]}},
    f: {useSidebarOrderStore: {setState: value => writes.push(value)}},
  });
  assert.equal(writes.length, 1);
  assert.deepEqual(Array.from(writes[0].workspaceOrderByProject.unrelated), ["keep"]);
  assert.ok(writes[0].workspaceOrderByProject[historyKey].length);
  assert.deepEqual(Array.from(writes[0].workspaceOrderByProject[eq]).slice(0, 2), ["s:a", "s:b"]);
  // A CAS-rejected transition does not consume module-local history. Rehydrate
  // another tab's successful transition and drag, then compute from that snapshot.
  const convergedOrders = {...state.workspaceOrders,
    ...Object.fromEntries(replayed.workspaceOrders.map(item => [item.projectViewKey, Array.from(item.order)])),
    [eq]: ["s:b", "s:a"],
  };
  const converged = loadOrder(patch.repl)({projects: [primary(eq), other],
    persistedProjectOrder: Array.from(replayed.projectOrder),
    getWorkspaceOrder: key => convergedOrders[key] ?? []});
  assert.equal(converged.projectOrder, null);
  assert.equal(converged.workspaceOrders.length, 0);
}

console.log("patch-web-ui: shape transitions, sidebar identity/drag preservation, idempotence, and refusal controls passed");
