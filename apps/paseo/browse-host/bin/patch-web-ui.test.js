#!/usr/bin/env node
// SPDX-License-Identifier: AGPL-3.0-only
"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const {
  BROWSE_PATCHES,
  BROWSE_ONLY_SHA,
  COMBINED_SHA,
  THREE_ANCHOR_BROWSE_ONLY_SHA,
  THREE_ANCHOR_COMBINED_SHA,
  ONE_ANCHOR_GENERAL_ONLY_SHA,
  ONE_ANCHOR_GENERAL_COMBINED_SHA,
  ONE_ANCHOR_GENERAL_THREE_ANCHOR_BROWSE_SHA,
  TWO_ANCHOR_GENERAL_ONLY_SHA,
  TWO_ANCHOR_GENERAL_COMBINED_SHA,
  TWO_ANCHOR_GENERAL_THREE_ANCHOR_BROWSE_SHA,
  SUBAGENT_STREAM_PATCHES,
  patchBundleContent,
  productionShasForStates,
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
  "project-actions-coarse-pointer",
]);
assert.ok(BROWSE_PATCHES.at(-1).repl.includes("(pointer: coarse)"));
const byName = (name) => SUBAGENT_STREAM_PATCHES.find((patch) => patch.name === name);
assert.deepEqual(SUBAGENT_STREAM_PATCHES.map((patch) => patch.name), [
  "provider-subagent-visible-parent",
  "appearance-default-font-sizes",
  "sidebar-order-shared-storage",
]);
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
for (const patch of BROWSE_PATCHES) assert.ok(general.source.includes(patch.find));

const combinedFromGeneral = apply(general.source, "browse", [sha(general.source)]);
assert.equal(combinedFromGeneral.alreadyPatched, false);
for (const patch of BROWSE_PATCHES) assert.ok(combinedFromGeneral.source.includes(patch.repl));
for (const patch of SUBAGENT_STREAM_PATCHES) assert.ok(combinedFromGeneral.source.includes(patch.repl));

// pristine -> legacy browse-only -> combined
const browseOnly = apply(pristine, "browse", [sha(pristine)]);
assert.equal(browseOnly.alreadyPatched, false);
for (const patch of SUBAGENT_STREAM_PATCHES) assert.ok(browseOnly.source.includes(patch.find));
const combinedFromBrowse = apply(browseOnly.source, "subagent-stream", [sha(browseOnly.source)]);
assert.equal(combinedFromBrowse.source, combinedFromGeneral.source);

// A fully patched browse group is the four-anchor shape; the three-anchor shape a
// previous revision of this patcher deployed is recognised separately, as partial.
assert.deepEqual(
  productionShasForStates({ "subagent-stream": "unpatched", browse: "patched" }),
  [BROWSE_ONLY_SHA],
);
assert.deepEqual(
  productionShasForStates({ "subagent-stream": "patched", browse: "patched" }),
  [COMBINED_SHA],
);
assert.deepEqual(
  productionShasForStates({ "subagent-stream": "unpatched", browse: "partial" }),
  [THREE_ANCHOR_BROWSE_ONLY_SHA],
);
assert.deepEqual(
  productionShasForStates({ "subagent-stream": "patched", browse: "partial" }),
  [THREE_ANCHOR_COMBINED_SHA],
);
// A box carrying only the first general anchor is a state, not a fault — one named
// SHA per browse shape it can be paired with.
assert.deepEqual(
  productionShasForStates({ "subagent-stream": "partial", browse: "unpatched" }),
  [ONE_ANCHOR_GENERAL_ONLY_SHA, TWO_ANCHOR_GENERAL_ONLY_SHA],
);
assert.deepEqual(
  productionShasForStates({ "subagent-stream": "partial", browse: "patched" }),
  [ONE_ANCHOR_GENERAL_COMBINED_SHA, TWO_ANCHOR_GENERAL_COMBINED_SHA],
);
assert.deepEqual(
  productionShasForStates({ "subagent-stream": "partial", browse: "partial" }),
  [ONE_ANCHOR_GENERAL_THREE_ANCHOR_BROWSE_SHA, TWO_ANCHOR_GENERAL_THREE_ANCHOR_BROWSE_SHA],
);
// Two revisions of the same group are both "partial", and a box carrying either must
// be completable. Asserting only one hash would leave the other shape refused —
// exactly the fleet-wide install failure the named states exist to prevent.
assert.equal(
  new Set(productionShasForStates({ "subagent-stream": "partial", browse: "patched" })).size,
  2,
);

// The migration this group's fourth anchor exists for: a box already carrying the
// first three edits must end up with all four, not with none and not with a marker
// that claims success. Both orderings of the two groups reach the same bytes.
const threeAnchors = BROWSE_PATCHES.slice(0, -1).reduce(
  (source, patch) => source.replace(patch.find, patch.repl),
  pristine,
);
const migratedBrowse = apply(threeAnchors, "browse", [sha(threeAnchors)]);
assert.equal(migratedBrowse.alreadyPatched, false);
assert.equal(migratedBrowse.states.browse, "partial");
assert.equal(migratedBrowse.source, browseOnly.source);
for (const patch of BROWSE_PATCHES) assert.ok(migratedBrowse.source.includes(patch.repl));

const threeAnchorsCombined = apply(threeAnchors, "subagent-stream", [sha(threeAnchors)]).source;
const migratedCombined = apply(threeAnchorsCombined, "browse", [sha(threeAnchorsCombined)]);
assert.equal(migratedCombined.alreadyPatched, false);
assert.equal(migratedCombined.source, combinedFromGeneral.source);

// The migration the general group's second anchor exists for: a box already carrying
// the subagent-stream edit must end up with the font-size defaults too.
for (const revision of [1, 2]) {
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

// A partial browse group that is NOT one of the named shapes stays refused: the
// state is readable, but nothing accepts its bytes, so the SHA pin is what stops it.
const halfBrowse = pristine.replace(BROWSE_PATCHES[0].find, BROWSE_PATCHES[0].repl);
assert.throws(
  () => patchBundleContent(halfBrowse, { mode: "subagent-stream" }),
  /bundle SHA mismatch/,
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

console.log("patch-web-ui: state transitions, preservation, idempotence, and refusal controls passed");
