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
assert.deepEqual(SUBAGENT_STREAM_PATCHES.map((patch) => patch.name), [
  "provider-subagent-visible-parent",
]);

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
