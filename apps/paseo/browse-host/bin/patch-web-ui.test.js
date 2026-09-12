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
  SIDEBAR_REHYDRATE_REVISIONED,
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
  "provider-subagent-visible-parent",
  "appearance-default-font-sizes",
  "sidebar-order-shared-storage",
  "sidebar-order-rehydrate-on-visibility",
  "tooltip-hover-none-is-compact",
  "project-actions-coarse-pointer",
  "sidebar-tap-not-swallowed-on-web",
]);
// The tablet "+" fix belongs to the ALWAYS-ON group. It rode on the optional browse
// group until 2026-09-01, which meant a box with `browse = false` — the default —
// silently never got it. Asserted on the group membership, not just the bytes: moving
// it back would restore a touch fix nobody with the default config receives.
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
  // inside it. The handler declares its own `const o={x:c,y:u}` for the current touch
  // point, so an `o.isWeb` written inside resolves to that local in its temporal dead
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
// An already-open second device must converge when the owner switches back to it;
// initial hydration alone only updates a device that performs a full page load.
assert.ok(byName("sidebar-order-rehydrate-on-visibility").find.includes("migrate:j"));
assert.ok(byName("sidebar-order-rehydrate-on-visibility").repl.includes('document.addEventListener("visibilitychange"'));
assert.ok(byName("sidebar-order-rehydrate-on-visibility").repl.includes('"visible"===document.visibilityState'));
assert.ok(byName("sidebar-order-rehydrate-on-visibility").repl.includes("f.persist.rehydrate()"));
{
  const patch = byName("sidebar-order-rehydrate-on-visibility");
  const start = patch.repl.indexOf('"undefined"!=typeof document');
  const end = patch.repl.indexOf("},3544,[", start);
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
  const f = { persist: { rehydrate: () => { rehydrates += 1; } } };
  const g = { __airlockUiState: { sync: (key) => { syncs.push(key); } } };
  new Function("document", "window", "f", "g", `return (${expression});`)(documentStub, windowStub, f, g);
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
// Every replacement for the rehydrate anchor — current or legacy — must carry the
// anchor's own head and tail bytes, because the patcher swaps a legacy replacement for
// the current one verbatim. A legacy string that is only the injected expression would
// duplicate the surrounding `partialize:…}));` on a real installed bundle while this
// fixture (which is built from the same strings) still came out equal. Caught on a live
// box, 2026-09-12.
{
  const patch = byName("sidebar-order-rehydrate-on-visibility");
  const head = patch.find.slice(0, "partialize:e=>".length);
  const tail = "},3544,[3368,3273,3276]);";
  assert.ok(patch.find.endsWith(tail));
  for (const candidate of [patch.repl, ...patch.legacyRepls]) {
    assert.ok(candidate.startsWith(head), "rehydrate replacement lost the anchor head");
    assert.ok(candidate.endsWith(tail), "rehydrate replacement lost the anchor tail");
    assert.equal(candidate.split(head).length - 1, 1, "rehydrate replacement duplicates the anchor head");
  }
}
// The adapter half: the poll needs the revision check the storage exposes.
assert.ok(byName("sidebar-order-shared-storage").repl.includes("sync:key=>"));
// The default the user sees on a device that has never saved settings. Asserted on
// the bytes, not the name: a silent revert to upstream's 16/12 is the failure mode.
assert.ok(byName("appearance-default-font-sizes").find.includes("_=16,O=11,T=24,F=12"));
assert.ok(byName("appearance-default-font-sizes").repl.includes("_=18,O=11,T=24,F=14"));

const ALL_EDITS = [
  ...SUBAGENT_STREAM_PATCHES.map((patch) => patch.name),
  ...BROWSE_PATCHES.map((patch) => patch.name),
];
const GENERAL_EDITS = SUBAGENT_STREAM_PATCHES.map((patch) => patch.name);
// The general group as it stood one revision back — the shape every already-installed
// browse-less box carries when this revision reaches it.
const PREVIOUS_GENERAL_EDITS = GENERAL_EDITS.filter(
  (edit) => edit !== "sidebar-tap-not-swallowed-on-web",
);
// ...and as it stood before the visibility-rehydrate revision, which is the era every
// pre-move browse shape below belongs to.
const PRE_REHYDRATE_GENERAL_EDITS = PREVIOUS_GENERAL_EDITS.filter(
  (edit) => edit !== "sidebar-order-rehydrate-on-visibility",
);
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

// The four shapes the installer must be able to name, or a box in that state refuses.
assert.deepEqual(productionShasForEdits([]), [PINNED_SHA]);
// Fully patched, and the browse-less box this revision creates. Both must exist.
assert.ok(productionShasForEdits(ALL_EDITS).length >= 1);
assert.ok(productionShasForEdits(GENERAL_EDITS).length >= 1);
assert.equal(productionShasForEdits(BROWSE_EDITS).length, 1);
// The shape THIS box carried when the bug was found: the whole general group as it
// stood before the move, no browse. Completing it is the entire point of the change.
assert.ok(
  productionShasForEdits(PRE_REHYDRATE_GENERAL_EDITS.filter((e) => e !== "project-actions-coarse-pointer")).length >= 1,
);
// Both complete general shapes behind this revision stay nameable: the one before the
// visibility rehydrate edit, and the one this revision's sidebar-tap fix migrates from.
assert.ok(productionShasForEdits(PRE_REHYDRATE_GENERAL_EDITS).length >= 1);
assert.ok(productionShasForEdits(PREVIOUS_GENERAL_EDITS).length >= 1);
// Every pre-move browse box holds the coarse-pointer edit already, beside a general
// group that is one, two, three or four edits old. All four must remain nameable.
for (const revision of [1, 2, 3, 4]) {
  const edits = [
    ...PRE_REHYDRATE_GENERAL_EDITS.filter((e) => e !== "project-actions-coarse-pointer").slice(0, revision),
    ...BROWSE_EDITS,
    "project-actions-coarse-pointer",
  ];
  assert.ok(productionShasForEdits(edits).length >= 1, `pre-move browse revision ${revision}`);
}
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

// pristine -> browse-only -> combined. The browse group no longer carries the
// coarse-pointer edit, so a browse-only bundle must still be waiting for it.
const browseOnly = apply(pristine, "browse", [sha(pristine)]);
assert.equal(browseOnly.alreadyPatched, false);
for (const patch of SUBAGENT_STREAM_PATCHES) assert.ok(browseOnly.source.includes(patch.find));
assert.ok(!browseOnly.source.includes("(pointer: coarse)"));
const combinedFromBrowse = apply(browseOnly.source, "subagent-stream", [sha(browseOnly.source)]);
assert.equal(combinedFromBrowse.source, combinedFromGeneral.source);

// The migration this revision exists for: a box carrying the general group as it stood
// BEFORE the move must end up with the coarse-pointer edit, not with none and not with
// a marker that claims success.
const preMoveGeneral = SUBAGENT_STREAM_PATCHES
  .filter((patch) => patch.name !== "project-actions-coarse-pointer")
  .reduce((source, patch) => source.replace(patch.find, patch.repl), pristine);
const migratedMove = apply(preMoveGeneral, "subagent-stream", [sha(preMoveGeneral)]);
assert.equal(migratedMove.alreadyPatched, false);
assert.equal(migratedMove.states["subagent-stream"], "partial");
assert.equal(migratedMove.source, general.source);
assert.ok(migratedMove.source.includes("(pointer: coarse)"));

// The migration THIS revision exists for: a box carrying the general group as it stood
// one revision back must come out with the sidebar-tap fix, not with a marker that
// claims success. This is the state every installed browse-less box is actually in.
const preTapGeneral = SUBAGENT_STREAM_PATCHES
  .filter((patch) => patch.name !== "sidebar-tap-not-swallowed-on-web")
  .reduce((source, patch) => source.replace(patch.find, patch.repl), pristine);
const migratedTap = apply(preTapGeneral, "subagent-stream", [sha(preTapGeneral)]);
assert.equal(migratedTap.alreadyPatched, false);
assert.equal(migratedTap.states["subagent-stream"], "partial");
assert.equal(migratedTap.source, general.source);
assert.ok(migratedTap.source.includes(byName("sidebar-tap-not-swallowed-on-web").repl));

// PR #256's adapter is a migration source, not an ambiguous foreign bundle. It
// already counts as the shared-storage edit for shape lookup, but running the
// current group must replace it with the durable outbox/queue adapter and add the
// visibility rehydrate edit.
const storagePatch = byName("sidebar-order-shared-storage");
assert.equal(storagePatch.legacyRepls.length, 3);
const rehydratePatch = byName("sidebar-order-rehydrate-on-visibility");
assert.equal(rehydratePatch.legacyRepls.length, 2);
for (const legacyStorage of storagePatch.legacyRepls) {
  for (const legacyRehydrate of rehydratePatch.legacyRepls) {
  const legacyGeneral = general.source
    .replace(storagePatch.repl, legacyStorage)
    .replace(rehydratePatch.repl, legacyRehydrate);
  const migratedStorage = apply(legacyGeneral, "subagent-stream", [sha(legacyGeneral)]);
  assert.equal(migratedStorage.alreadyPatched, false);
  assert.equal(migratedStorage.states["subagent-stream"], "partial");
  assert.equal(migratedStorage.source, general.source);
  assert.ok(!migratedStorage.source.includes(legacyStorage));
  assert.ok(!migratedStorage.source.includes(legacyRehydrate));
  }
}

// ...and the mirror case: a PRE-move browse box already holds the coarse-pointer edit,
// so running the general group there must complete the rest around it and reach the
// same bytes rather than trip on an edit it did not apply itself.
const preMoveBrowse = [...BROWSE_PATCHES, byName("project-actions-coarse-pointer")]
  .reduce((source, patch) => source.replace(patch.find, patch.repl), pristine);
const migratedBrowseBox = apply(preMoveBrowse, "subagent-stream", [sha(preMoveBrowse)]);
assert.equal(migratedBrowseBox.alreadyPatched, false);
assert.equal(migratedBrowseBox.states["subagent-stream"], "partial");
assert.equal(migratedBrowseBox.source, combinedFromGeneral.source);

// Every earlier revision of the general group is still completable.
for (const revision of [1, 2, 3, 4, 5, 6]) {
  const older = SUBAGENT_STREAM_PATCHES.slice(0, revision).reduce(
    (source, patch) => source.replace(patch.find, patch.repl),
    pristine,
  );
  const migratedGeneral = apply(older, "subagent-stream", [sha(older)]);
  assert.equal(migratedGeneral.alreadyPatched, false);
  assert.equal(migratedGeneral.states["subagent-stream"], "partial");
  assert.equal(migratedGeneral.source, general.source);
  for (const patch of SUBAGENT_STREAM_PATCHES) assert.ok(migratedGeneral.source.includes(patch.repl));
}

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
// diffing 15MB of minified JS to find out what state the box is in.
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

console.log("patch-web-ui: shape table, state transitions, preservation, idempotence, and refusal controls passed");
