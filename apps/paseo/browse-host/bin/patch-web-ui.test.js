#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only
"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const {
  BROWSE_PATCHES,
  KNOWN_BUNDLE_SHAPES,
  PINNED_SHA,
  PRUNE_SIDEBAR_ORDER_SRC,
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
  "sidebar-order-workspace-list-complete",
  "sidebar-order-workspace-list-from-cache",
  "sidebar-order-stable-identity",
  "provider-subagent-visible-parent",
  "appearance-default-font-sizes",
  "sidebar-order-shared-storage",
  "sidebar-order-rehydrate-on-visibility",
  "tooltip-hover-none-is-compact",
  "project-actions-coarse-pointer",
  "workspace-hover-card-touch",
  "workspace-tab-close-touch",
  "workspace-menu-touch-slot",
  "workspace-menu-touch-trigger",
  "workspace-actions-coarse-pointer",
  "sidebar-tap-not-swallowed-on-web",
  "workspace-archive-request-timeout",
]);
// The tablet "+" fix belongs to the ALWAYS-ON group, not the optional browse group.
assert.ok(byName("project-actions-coarse-pointer"));
assert.ok(byName("project-actions-coarse-pointer").repl.includes("(pointer: coarse)"));
assert.ok(byName("workspace-actions-coarse-pointer").repl.includes("c=c||"));
assert.ok(byName("workspace-actions-coarse-pointer").repl.includes("(pointer: coarse)"));
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
{
  // Byte-for-byte: the archive request gains a timeout and nothing else. It must
  // outlast the measured 140 s archive, and must stay finite and positive — 0 means
  // "never time out" in this client and Infinity overflows setTimeout into ~1 ms.
  const patch = byName("workspace-archive-request-timeout");
  const added = ",timeout:6e5";
  assert.equal(patch.repl.split(added).length - 1, 1, "the archive request lost its timeout");
  assert.equal(patch.repl.replace(added, ""), patch.find);
  const ms = Number(added.slice(",timeout:".length));
  assert.ok(Number.isFinite(ms) && ms > 140000 && ms <= 0x7fffffff);
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
// Fleet bytes from before the bounded-sidebar-order upgrade remain accepted alongside the
// two rows that describe what the upgrade produces.
assert.equal(KNOWN_BUNDLE_SHAPES.length, 15);
assert.deepEqual(KNOWN_BUNDLE_SHAPES[0].edits, []);
const PRE_ARCHIVE_TIMEOUT = name => name !== "workspace-archive-request-timeout";
const PRE_ORDER_PRUNE = name => PRE_ARCHIVE_TIMEOUT(name) && !name.startsWith("sidebar-order-workspace-list-");
const PRE_TAB_CLOSE = name => name !== "workspace-tab-close-touch";
const PRE_TOUCH_TARGET = name => PRE_TAB_CLOSE(name) && !name.startsWith("workspace-menu-touch-") && name !== "workspace-hover-card-touch";
const PRE_IDENTITY = name => PRE_TOUCH_TARGET(name) && !name.startsWith("sidebar-order-stable-") && name !== "sidebar-order-atomic-reconcile" && name !== "workspace-actions-coarse-pointer";
// Every row below the two new ones predates the bounded-sidebar-order edit, so its
// filter has to drop that name too — an older shape is an older EDIT SET, not just an
// older byte string.
const PRE_ANY = extra => name => extra(name) && PRE_ORDER_PRUNE(name);
assert.equal(key(KNOWN_BUNDLE_SHAPES[1].edits), key(GENERAL_EDITS.filter(PRE_ANY(PRE_IDENTITY))));
assert.equal(key(KNOWN_BUNDLE_SHAPES[2].edits), key(ALL_EDITS.filter(PRE_ANY(PRE_IDENTITY))));
const PRE_WORKSPACE_MENU = name => PRE_TOUCH_TARGET(name) && name !== "workspace-actions-coarse-pointer";
assert.equal(key(KNOWN_BUNDLE_SHAPES[3].edits), key(GENERAL_EDITS.filter(PRE_ANY(PRE_WORKSPACE_MENU))));
assert.equal(key(KNOWN_BUNDLE_SHAPES[4].edits), key(ALL_EDITS.filter(PRE_ANY(PRE_WORKSPACE_MENU))));
assert.equal(key(KNOWN_BUNDLE_SHAPES[5].edits), key(GENERAL_EDITS.filter(PRE_ANY(PRE_TOUCH_TARGET))));
assert.equal(key(KNOWN_BUNDLE_SHAPES[6].edits), key(ALL_EDITS.filter(PRE_ANY(PRE_TOUCH_TARGET))));
assert.equal(key(KNOWN_BUNDLE_SHAPES[7].edits), key(GENERAL_EDITS.filter(PRE_ANY(PRE_TAB_CLOSE))));
assert.equal(key(KNOWN_BUNDLE_SHAPES[8].edits), key(ALL_EDITS.filter(PRE_ANY(PRE_TAB_CLOSE))));
assert.equal(key(KNOWN_BUNDLE_SHAPES[9].edits), key(GENERAL_EDITS.filter(PRE_ORDER_PRUNE)));
assert.equal(key(KNOWN_BUNDLE_SHAPES[10].edits), key(ALL_EDITS.filter(PRE_ORDER_PRUNE)));
assert.equal(key(KNOWN_BUNDLE_SHAPES[11].edits), key(GENERAL_EDITS.filter(PRE_ARCHIVE_TIMEOUT)));
assert.equal(key(KNOWN_BUNDLE_SHAPES[12].edits), key(ALL_EDITS.filter(PRE_ARCHIVE_TIMEOUT)));
assert.equal(key(KNOWN_BUNDLE_SHAPES[13].edits), key(GENERAL_EDITS));
assert.equal(key(KNOWN_BUNDLE_SHAPES[14].edits), key(ALL_EDITS));
// The two upgrade rows must stay MINE — the older row's sha IS the bytes a box already
// has, and reusing it for the post-upgrade bytes would refuse that box instead of fixing
// it. This is the shape of that mistake, in the one place it can be asserted.
assert.notEqual(KNOWN_BUNDLE_SHAPES[11].sha, KNOWN_BUNDLE_SHAPES[9].sha);
assert.notEqual(KNOWN_BUNDLE_SHAPES[12].sha, KNOWN_BUNDLE_SHAPES[10].sha);
assert.notEqual(KNOWN_BUNDLE_SHAPES[13].sha, KNOWN_BUNDLE_SHAPES[11].sha);
assert.notEqual(KNOWN_BUNDLE_SHAPES[14].sha, KNOWN_BUNDLE_SHAPES[12].sha);
// NOTE: `includes(name, other)` reads the second argument as fromIndex and silently
// checks ONE name — which is how a lifecycle edit could go missing from this table
// unnoticed. `some`/`every` is the only form that checks both.
const LIFECYCLE_EDITS = ["sidebar-order-workspace-list-complete", "sidebar-order-workspace-list-from-cache"];
const UPGRADE_SHAS = ["9677225d385f2d5c78461412c80f84b6358caf04986b71414a78d4fc47573c3e",
  "d9a3cbcb25807aaccda7897504ca3433e219384ad0033944553807263f38b127",
  "5749b20a3932fd100fb4534b162a49b734517e28921b858b79ac17479a311a47",
  "d022d9c7f9f2a1d5478a1db3f9fc5a7492acffa2e25552837f46459e58c9ae85"];
for (const shape of KNOWN_BUNDLE_SHAPES) {
  assert.equal(shape.edits.some(name => LIFECYCLE_EDITS.includes(name)),
    UPGRADE_SHAS.includes(shape.sha),
    "the bounded-sidebar-order edits and the rows that carry them are 1:1");
}
assert.deepEqual(
  KNOWN_BUNDLE_SHAPES.filter(shape => shape.edits.some(name => LIFECYCLE_EDITS.includes(name)))
    .map(shape => LIFECYCLE_EDITS.filter(name => shape.edits.includes(name))),
  [LIFECYCLE_EDITS, LIFECYCLE_EDITS, LIFECYCLE_EDITS, LIFECYCLE_EDITS],
  "both lifecycle edits travel together, on exactly the rows that carry them",
);

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

// ------------------------------------------------------- the bounded sidebar order
// Upstream only prepends and appends, so the shared value can only grow until the
// backend's 256 KiB cap refuses every write — measured 2026-10-03 as 4,213 stored keys
// for 96 live workspaces and 262 KB against a 256 KB budget. These are the boundaries
// the prune has to hold, each one a way the shrink could delete an order somebody still
// has. The shipped replacement string is evaluated, not re-implemented here.
const vm = require("node:vm");
const HISTORY = "@airlock:sidebar-placement-keys:v1";
function prune(state, live) {
  // A fresh context per call, so the input Maps are CROSS-REALM on purpose: the shipped
  // function must not depend on `instanceof`, which is exactly the bug a vm test hides.
  const context = {state, live};
  vm.createContext(context);
  vm.runInContext(`globalThis.pruneSidebarOrder = ${PRUNE_SIDEBAR_ORDER_SRC}`, context);
  return context.pruneSidebarOrder(state, live);
}
const serversOf = entries => new Map(Object.entries(entries).map(([id, keys]) => [id, new Set(keys)]));
// `hosts` is every server the visible list mentions, `serversOf` only the ones that
// earned the right to judge a key. Most fixtures have one host; the overlap cases say so.
const live = (servers, hosts, visibleProjects) => ({servers: serversOf(servers), hosts, visibleProjects: new Set(visibleProjects)});
const STALE = "s:archived";

// 1. Nothing authorises a removal: no `live` at all, an empty server map, or servers
// that never claimed a complete list. The caller uses identity to skip the write, so
// "changed nothing" has to mean the SAME OBJECT, not an equal copy.
for (const shape of [undefined, null, {}, {servers: new Map(), hosts: ["s"], visibleProjects: new Set(["p"])},
                    {servers: new Map([["s", undefined]]), hosts: ["s"], visibleProjects: new Set(["p"])},
                    {servers: serversOf({s: ["s:a"]}), hosts: [], visibleProjects: new Set(["p"])}]) {
  const state = {projectOrder: ["p"], pinnedWorkspaceOrder: [STALE], workspaceOrderByProject: {p: [STALE]}};
  assert.equal(prune(state, shape), state, `nothing may be removed for live=${JSON.stringify(shape)}`);
}
{
  const state = {projectOrder: ["p"], pinnedWorkspaceOrder: [STALE], workspaceOrderByProject: {p: [STALE]}};
  assert.equal(prune(state, {servers: new Map(), visibleProjects: new Set(["p"])}), state);
}
{
  // 5. Entries that are not workspace keys at all, and the placement history this patch's
  // own sibling edit maintains: none of them is ours to judge. The non-string entries are
  // here on purpose — a missing type guard does not remove them, it throws. The history
  // rows include a bare "s:archived": this bundle writes JSON arrays there, but the value
  // is shared with devices on other builds, so a row that happens to LOOK like a stale
  // workspace key has to survive the guard rather than the prefix test.
  const history = [JSON.stringify(["s", "repo", "p"]), "s:archived"];
  const state = {
    projectOrder: ["p", ""],
    pinnedWorkspaceOrder: ["", "no-colon", HISTORY],
    workspaceOrderByProject: {[HISTORY]: history, p: ["", "no-colon", STALE, null], empty: []},
  };
  const next = prune(state, live({s: ["s:a"]}, ["s"], ["p"]));
  assert.deepEqual(Array.from(next.workspaceOrderByProject.p), ["", "no-colon", null]);
  assert.deepEqual(Array.from(next.workspaceOrderByProject[HISTORY]), history);
  assert.deepEqual(Array.from(next.pinnedWorkspaceOrder), ["", "no-colon", HISTORY]);
  assert.deepEqual(Array.from(next.projectOrder), ["p", ""]);
  // A list that was ALREADY empty is not evidence about any server, so the record stays
  // on disk. Its projectOrder slot is a separate matter — see the two-pass case below.
  assert.deepEqual(Array.from(next.workspaceOrderByProject.empty), []);
}
{
  // Reviewer counterexample, first pass: a project whose last workspace disappeared while
  // it is STILL VISIBLE. Scoping the removal to the transition strands the projectOrder
  // slot forever — one accumulating entry per dead project, which is the same failure
  // this function exists to remove.
  //
  // The record is left exactly as it was, stale keys and all: those keys are what name
  // the complete server that owns them. An empty array would name no server and leave the
  // next pass nothing to act on. So this pass has nothing to write at all.
  const state = {projectOrder: ["p"], pinnedWorkspaceOrder: [],
    workspaceOrderByProject: {p: ["s:last"]}};
  const holding = prune(state, live({s: []}, ["s"], ["p"]));
  assert.equal(holding, state, "a visible project keeps its slot, its record, and the write");
  // ...and once it leaves the sidebar, the pass that removes the keys removes the slot in
  // the same step.
  const gone = prune(holding, live({s: []}, ["s"], []));
  assert.deepEqual(Array.from(gone.projectOrder), [],
    "once it is off the sidebar the slot goes with it");
  assert.equal(gone.workspaceOrderByProject.p, undefined, "and so does the record");
  assert.equal(prune(gone, live({s: []}, ["s"], [])), gone, "and it settles");
  // A projectOrder key with NO record at all is a project this device has no evidence
  // about, not one we emptied: untouched even once it is off the sidebar.
  const unknown = {projectOrder: ["q"], pinnedWorkspaceOrder: [],
    workspaceOrderByProject: {p: ["s:x"]}};
  assert.deepEqual(Array.from(prune(unknown, live({s: ["s:x"]}, ["s"], [])).projectOrder), ["q"]);
}
{
  // 4. What a complete list does authorise, and no more: a key the server no longer has
  // goes, a key it still has stays IN PLACE (this is a drag order, not a set), and the
  // pinned order is treated exactly like any other list.
  const state = {
    projectOrder: ["p"],
    pinnedWorkspaceOrder: ["s:gone", "s:a"],
    workspaceOrderByProject: {p: ["s:b", STALE, "s:a", "s:c"]},
  };
  const next = prune(state, live({s: ["s:a", "s:b", "s:c"]}, ["s"], ["p"]));
  assert.deepEqual(Array.from(next.workspaceOrderByProject.p), ["s:b", "s:a", "s:c"]);
  assert.deepEqual(Array.from(next.pinnedWorkspaceOrder), ["s:a"]);
}
{
  // 6. A visible project with zero workspaces keeps its slot. Dropping it would let the
  // next reconcile append it straight back and the run after that remove it again — a
  // write every time, for nothing. Prune -> reconcile -> prune must settle at zero
  // writes, which is counterexample 7 measured end to end through the real replacement.
  const state = {projectOrder: ["p", "q"], pinnedWorkspaceOrder: [], workspaceOrderByProject: {p: [STALE], q: ["s:a"]}};
  const next = prune(state, live({s: ["s:a"]}, ["s"], ["p", "q"]));
  assert.deepEqual(Array.from(next.projectOrder), ["p", "q"]);
  assert.deepEqual(Array.from(next.workspaceOrderByProject.p), [STALE],
    "the stale key stays as the marker while the project is still on screen");
  assert.equal(prune(next, live({s: ["s:a"]}, ["s"], ["p", "q"])), next,
    "a settled prune is idempotent by identity");
}
{
  // Reviewer counterexample, second pass: a record that was ALREADY empty names no server,
  // so it is not evidence that this device emptied anything. Treating it as such dropped
  // the projectOrder slot of a hidden project on the strength of some OTHER server's
  // prune — the same guess, one level removed.
  const state = {
    projectOrder: ["hidden", "p"],
    pinnedWorkspaceOrder: [],
    workspaceOrderByProject: {hidden: [], p: ["s:gone"]},
  };
  const next = prune(state, live({s: []}, ["s"], []));
  assert.deepEqual(Array.from(next.projectOrder), ["hidden"],
    "an already-empty record never costs a project its slot");
  assert.deepEqual(Array.from(next.workspaceOrderByProject.hidden), []);
  assert.equal(next.workspaceOrderByProject.p, undefined,
    "while the record that DOES name its server is cleaned up");
}
// 8. The pinned order, on its own: a stale key goes, another server's key stays.
{
  const state = {projectOrder: [], pinnedWorkspaceOrder: ["s:a", STALE, "t:x"], workspaceOrderByProject: {}};
  const next = prune(state, live({s: ["s:a"]}, ["s"], []));
  assert.deepEqual(Array.from(next.pinnedWorkspaceOrder), ["s:a", "t:x"]);
}
{
  // A server id that is a PREFIX of another server id. `a:b:w` is a key of server `a:b`,
  // not of `a`, and upstream resolves host prefixes longest-first for exactly that
  // reason. Judging "does any authorised server's prefix match" would charge it to `a`,
  // which is authorised, and delete it — while the server that still has the workspace
  // (`a:b`, hidden or not yet complete) is never asked.
  const state = {projectOrder: ["visible"], pinnedWorkspaceOrder: ["a:b:w"],
    workspaceOrderByProject: {visible: ["a:b:w", "a:x", "a:archived"]}};
  const next = prune(state, live({a: ["a:x"]}, ["a", "a:b"], ["visible"]));
  assert.deepEqual(Array.from(next.workspaceOrderByProject.visible), ["a:b:w", "a:x"]);
  assert.deepEqual(Array.from(next.pinnedWorkspaceOrder), ["a:b:w"]);
  // With `a:b` out of the picture entirely, the key falls to `a` and is judged there —
  // the longest match among the hosts we actually know.
  const alone = prune(state, live({a: ["a:x"]}, ["a"], ["visible"]));
  assert.deepEqual(Array.from(alone.workspaceOrderByProject.visible), ["a:x"]);
}

// The prune reads one signal; this edit is where that signal is produced, so it is run
// rather than asserted on its bytes. Upstream's own effects have to survive it — the
// returned snapshot and the hydration flag are what the rest of the app reads.
{
  const complete = byName("sidebar-order-workspace-list-complete", "sidebar-order-workspace-list-from-cache");
  const marked = [];
  const snapshotMarked = [];
  // One stub for both replicas: the class's two edits each call a different setter on the
  // same store, and the tests below interleave them on purpose.
  const context = {o: {useSessionStore: {getState: () => ({
    setHasHydratedWorkspaces: (serverId, value) => marked.push([serverId, value]),
    setHasWorkspaceDirectorySnapshot: (serverId, value) => snapshotMarked.push([serverId, value]),
  })}}};
  vm.createContext(context);
  vm.runInContext(`globalThis.replica = {${complete.repl}}`, context);
  const replica = Object.assign(context.replica, {
    serverId: "srv_one",
    replace: () => {},
    applyDelta: delta => [delta],
  });
  assert.deepEqual(Array.from(replica.commitSnapshot({}, [{id: "w"}])), [{id: "w"}]);
  assert.deepEqual(marked, [["srv_one", true]], "upstream's hydration flag must still be set");
  assert.equal(context.__airlockWorkspaceListComplete.has("srv_one"), true);
  // A second server accumulates alongside the first; the record is a set of servers, not
  // a single one, and re-sending a snapshot must not clear what came before.
  Object.assign(replica, {serverId: "srv_two"});
  replica.commitSnapshot({}, []);
  assert.deepEqual([...context.__airlockWorkspaceListComplete].sort(), ["srv_one", "srv_two"]);
  // The record is withdrawn when the list came from the LOCAL CACHE instead. This is the
  // whole point of the revoke: a page load that restores a checkpoint and never reaches
  // the box must not keep judging the box's workspaces by a list it has not refreshed.
  // Driven through the real replica so the anchor is exercised, not pattern-matched.
  const cached = byName("sidebar-order-workspace-list-from-cache");
  vm.runInContext(`globalThis.cacheReplica = {${cached.repl}}`, context);
  Object.assign(context.cacheReplica, {
    serverId: "srv_two",
    replace: () => {},
    workspaces: new Map(),
    projects: new Map(),
  });
  assert.equal(context.__airlockWorkspaceListComplete.has("srv_two"), true);
  context.cacheReplica.commitCached({workspaces: new Map(), projects: new Map()});
  assert.deepEqual(snapshotMarked, [["srv_two", true]], "upstream's snapshot flag must still be set");
  assert.equal(context.__airlockWorkspaceListComplete.has("srv_two"), false,
    "a cached restore withdraws the licence");
  assert.equal(context.__airlockWorkspaceListComplete.has("srv_one"), true,
    "one server's cache must not withdraw another's");
  // Ordering: a checkpoint read that resolves AFTER this replica already took a live
  // snapshot must not take the licence back. `commitCached` merges the checkpoint UNDER
  // the replica's own entries, so it can only add to the visible list — the direction in
  // which the prune keeps too much rather than deleting a live key. Revoking here would
  // leave the prune off for the rest of the page load, silently restoring the failure
  // this patch exists to remove. The state is per replica INSTANCE, so this has to be
  // literally the same object running both shipped methods.
  vm.runInContext(`globalThis.both = {${complete.repl}, ${cached.repl}}`, context);
  const both = Object.assign(context.both, {
    serverId: "srv_two",
    replace: () => {},
    applyDelta: () => [],
    workspaces: new Map(),
    projects: new Map(),
  });
  both.commitSnapshot({}, []);
  assert.equal(context.__airlockWorkspaceListComplete.has("srv_two"), true);
  both.commitCached({workspaces: new Map(), projects: new Map()});
  assert.equal(context.__airlockWorkspaceListComplete.has("srv_two"), true,
    "a cache merge after a live snapshot keeps the licence");
  // A FRESH replica for the same server starts unearned, so its cache restore still
  // withdraws — that is the page-load-from-checkpoint case the revoke exists for.
  vm.runInContext(`globalThis.freshReplica = {${cached.repl}}`, context);
  const fresh = Object.assign(context.freshReplica, {serverId: "srv_two", replace: () => {},
    workspaces: new Map(), projects: new Map()});
  fresh.commitCached({workspaces: new Map(), projects: new Map()});
  assert.equal(context.__airlockWorkspaceListComplete.has("srv_two"), false,
    "a fresh replica's cache restore withdraws the licence");
}

// 2, 3 and 7 are boundaries of the CALLER, not of the function: it only ever receives
// servers that were both recorded as complete and still visible, so "recorded", "visible"
// and "writes exactly once" have to be measured through the shipped replacement.
{
  const reconcile = byName("sidebar-order-atomic-reconcile");
  const project = (viewKey, hosts, keys = []) => ({
    viewKey, hosts, workspaces: keys.map(workspaceKey => ({workspaceKey})),
  });
  const stale = () => ({projectOrder: ["p"], pinnedWorkspaceOrder: ["s:archived"],
    workspaceOrderByProject: {p: ["s:a", "s:archived"]}});
  // `registered` is the hook's unfiltered host-id list; `projects` is the narrower,
  // host-filtered list the sidebar actually renders. They differ whenever a host filter
  // is on, which is the case key attribution has to survive.
  const run = (store, projects, complete, registered) => {
    const writes = [];
    vm.runInNewContext(reconcile.repl, {
      o: {projectOrder: null, workspaceOrders: []},
      t: store,
      J: projects,
      L: registered ?? [...new Set(projects.flatMap(item => item.hosts.map(host => host.serverId)))],
      globalThis: {__airlockWorkspaceListComplete: complete},
      f: {useSidebarOrderStore: {setState: value => writes.push(value)}},
    });
    return writes;
  };
  const visible = project("p", [{serverId: "s", projectId: "r"}], ["s:a"]);
  // 2. The server is on screen and its keys are in hand, but no complete list was ever
  // recorded for it. Nothing may go — otherwise a device that has just booted deletes
  // every key its owner created on another one.
  assert.deepEqual(run(stale(), [visible], new Set()), []);
  // 3. `t` DID hand over its whole list, and the sidebar no longer shows it. A host the
  // filter drops cannot be told apart from one the directory never mentioned, so it is
  // not touched either.
  assert.deepEqual(run(stale(), [project("p", [{serverId: "s", projectId: "r"}], ["s:a", "t:x"])], new Set(["t"])), []);
  // 7. Idempotence with nothing to do: a complete, visible server and a settled order
  // produce no write at all — not a same-value one.
  assert.deepEqual(run(stale(), [visible], new Set(["s"])).length, 1, "one write writes the stale key off");
  const settled = {projectOrder: ["p"], pinnedWorkspaceOrder: [],
    workspaceOrderByProject: {p: ["s:a"]}};
  assert.deepEqual(run(settled, [visible], new Set(["s"])), []);
  assert.deepEqual(run(settled, [visible], undefined), []);
  // Prefix-overlapping server ids, through the caller. The live set is built by prefix
  // too, so ownership has to be resolved longest-first exactly as upstream decodes the
  // key. `a:b` is a host the sidebar shows but that has not sent a complete list, and
  // `a:b:w` is in the stored order without being in the visible list — the shape a naive
  // "does any authorised prefix match" test deletes.
  const overlapping = {
    projectOrder: ["visible"],
    pinnedWorkspaceOrder: [],
    workspaceOrderByProject: {visible: ["a:b:w", "a:x"]},
  };
  const owners = project("visible", [{serverId: "a", projectId: "r"}, {serverId: "a:b", projectId: "r"}],
    ["a:x"]);
  assert.deepEqual(run(overlapping, [owners], new Set(["a"])), [],
    "a key owned by an unauthorised longer host must not be judged by the shorter prefix");
  // The moment `a:b` is authoritative too, the decision is ITS list that counts — and
  // `a:b` reports no workspaces, so the key is genuinely gone and is written off.
  const both = run(overlapping, [owners], new Set(["a", "a:b"]));
  assert.equal(both.length, 1);
  assert.deepEqual(both[0].workspaceOrderByProject.visible, ["a:x"]);
  // With `a:b` gone from the hosts entirely, `a:b:w` is `a`'s to judge and is stale.
  const alone = run(overlapping,
    [project("visible", [{serverId: "a", projectId: "r"}], ["a:x"])], new Set(["a"]));
  assert.equal(alone.length, 1);
  assert.deepEqual(alone[0].workspaceOrderByProject.visible, ["a:x"]);
  // The live set is built with the same prefix match, so it has to resolve owners the
  // same way. Filing `a:b:w` under `a` on the way in would leave `a:b` reporting an empty
  // list and the very next run would write the key off as stale.
  const bothVisible = project("visible",
    [{serverId: "a", projectId: "r"}, {serverId: "a:b", projectId: "r"}], ["a:x", "a:b:w"]);
  assert.deepEqual(run(overlapping, [bothVisible], new Set(["a", "a:b"])), [],
    "each host's live set must hold the keys it actually owns");
  // A HOST FILTER. `a:b` is registered but filtered out of the sidebar, so it is absent
  // from J entirely — attributing against J alone would charge its key to `a`, which is
  // authorised, and delete it. The registered id list is what protects it.
  const filtered = project("visible", [{serverId: "a", projectId: "r"}], ["a:x"]);
  assert.deepEqual(run(overlapping, [filtered], new Set(["a"]), ["a", "a:b"]), [],
    "a registered host hidden by a host filter still owns its keys");
  assert.deepEqual(run(overlapping, [filtered], new Set(["a", "a:b"]), ["a", "a:b"]), [],
    "and it is still judged only by its own complete list, which has no workspaces");
}

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
  // order and unrelated records remain in the merged Zustand state. With no server
  // marked as having sent a complete workspace list, the prune inside the same write
  // removes nothing — the assertion below would fail loudly if it ever did.
  const reconcile = byName("sidebar-order-atomic-reconcile");
  const writes = [];
  const runReconcile = (update, store, projects, complete = new Set()) => {
    vm.runInNewContext(reconcile.repl, {
      o: update,
      t: store,
      J: projects,
      L: [...new Set(projects.flatMap(item => item.hosts.map(host => host.serverId)))],
      globalThis: {__airlockWorkspaceListComplete: complete},
      f: {useSidebarOrderStore: {setState: value => writes.push(value)}},
    });
    return writes;
  };  runReconcile(replayed, {projectOrder: [], pinnedWorkspaceOrder: ["s:a"],
    workspaceOrderByProject: {...state.workspaceOrders, unrelated: ["keep"]}}, [], new Set());
  assert.equal(writes.length, 1);
  assert.deepEqual(Array.from(writes[0].workspaceOrderByProject.unrelated), ["keep"]);
  assert.ok(writes[0].workspaceOrderByProject[historyKey].length);
  assert.deepEqual(Array.from(writes[0].workspaceOrderByProject[eq]).slice(0, 2), ["s:a", "s:b"]);
  // The pinned order rides along untouched, and the SAME write is what shrinks the
  // order. This is the whole point of the edit: a second run with nothing new to
  // reconcile and nothing stale to remove must not write at all.
  const prunedProjects = [project(eq, [host("s", "repo")], ["s:b", "s:a"])];
  const store = {
    projectOrder: [eq, "s:gone-project"],
    pinnedWorkspaceOrder: ["s:a", "s:archived"],
    workspaceOrderByProject: {
      [eq]: ["s:b", "s:a", "s:archived"],
      "s:gone-project": ["s:archived"],
      [historyKey]: [JSON.stringify(["s", "repo", eq])],
    },
  };
  writes.length = 0;
  runReconcile({projectOrder: null, workspaceOrders: []}, store, prunedProjects, new Set(["s"]));
  assert.equal(writes.length, 1, "a stale key must be written off in one go");
  assert.deepEqual(Array.from(writes[0].workspaceOrderByProject[eq]), ["s:b", "s:a"]);
  assert.equal(writes[0].workspaceOrderByProject["s:gone-project"], undefined);
  assert.deepEqual(Array.from(writes[0].workspaceOrderByProject[historyKey]),
    [JSON.stringify(["s", "repo", eq])]);
  assert.deepEqual(Array.from(writes[0].pinnedWorkspaceOrder), ["s:a"]);
  assert.deepEqual(Array.from(writes[0].projectOrder), [eq]);
  writes.length = 0;
  runReconcile({projectOrder: null, workspaceOrders: []}, {
    projectOrder: [eq],
    pinnedWorkspaceOrder: ["s:a"],
    workspaceOrderByProject: {[eq]: ["s:b", "s:a"], [historyKey]: [JSON.stringify(["s", "repo", eq])]},
  }, prunedProjects, new Set(["s"]));
  assert.equal(writes.length, 0, "an unchanged sidebar must not write");
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

console.log("patch-web-ui: shape transitions, bounded sidebar order, sidebar identity/drag preservation, idempotence, and refusal controls passed");
