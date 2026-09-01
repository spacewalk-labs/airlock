#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only
"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const {
  BROWSE_PATCHES,
  KNOWN_BUNDLE_SHAPES,
  PINNED_SHA,
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
  "tooltip-hover-none-is-compact",
  "project-actions-coarse-pointer",
]);
// The tablet "+" fix belongs to the ALWAYS-ON group. It rode on the optional browse
// group until 2026-09-01, which meant a box with `browse = false` — the default —
// silently never got it. Asserted on the group membership, not just the bytes: moving
// it back would restore a touch fix nobody with the default config receives.
assert.ok(byName("project-actions-coarse-pointer"));
assert.ok(byName("project-actions-coarse-pointer").repl.includes("(pointer: coarse)"));
assert.ok(!BROWSE_PATCHES.some((patch) => patch.repl.includes("(pointer: coarse)")));
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
assert.ok(byName("sidebar-order-shared-storage").repl.includes("l.getItem(e)"));
assert.ok(byName("sidebar-order-shared-storage").repl.includes("await l.setItem(e,t)"));
// The default the user sees on a device that has never saved settings. Asserted on
// the bytes, not the name: a silent revert to upstream's 16/12 is the failure mode.
assert.ok(byName("appearance-default-font-sizes").find.includes("_=16,O=11,T=24,F=12"));
assert.ok(byName("appearance-default-font-sizes").repl.includes("_=18,O=11,T=24,F=14"));

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
  for (const edit of shape.edits) {
    assert.ok(ALL_EDITS.includes(edit), `shape names an unknown edit: ${edit}`);
  }
}
assert.equal(
  new Set(KNOWN_BUNDLE_SHAPES.map((shape) => key(shape.edits))).size,
  KNOWN_BUNDLE_SHAPES.length,
);
assert.equal(
  new Set(KNOWN_BUNDLE_SHAPES.map((shape) => shape.sha)).size,
  KNOWN_BUNDLE_SHAPES.length,
);

// The four shapes the installer must be able to name, or a box in that state refuses.
assert.deepEqual(productionShasForEdits([]), [PINNED_SHA]);
// Fully patched, and the browse-less box this revision creates. Both must exist.
assert.equal(productionShasForEdits(ALL_EDITS).length, 1);
assert.equal(productionShasForEdits(GENERAL_EDITS).length, 1);
assert.equal(productionShasForEdits(BROWSE_EDITS).length, 1);
// The shape THIS box carried when the bug was found: the whole general group as it
// stood before the move, no browse. Completing it is the entire point of the change.
assert.equal(
  productionShasForEdits(GENERAL_EDITS.filter((e) => e !== "project-actions-coarse-pointer")).length,
  1,
);
// Every pre-move browse box holds the coarse-pointer edit already, beside a general
// group that is one, two, three or four edits old. All four must remain nameable.
for (const revision of [1, 2, 3, 4]) {
  const edits = [
    ...GENERAL_EDITS.filter((e) => e !== "project-actions-coarse-pointer").slice(0, revision),
    ...BROWSE_EDITS,
    "project-actions-coarse-pointer",
  ];
  assert.equal(productionShasForEdits(edits).length, 1, `pre-move browse revision ${revision}`);
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
for (const revision of [1, 2, 3, 4]) {
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
