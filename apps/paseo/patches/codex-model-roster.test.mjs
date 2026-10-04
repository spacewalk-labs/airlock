// SPDX-License-Identifier: AGPL-3.0-only
import assert from "node:assert/strict";
import path from "node:path";
import { pathToFileURL } from "node:url";

const featureFile = process.argv[2];
const catalogFile = process.argv[3];
if (!featureFile || !catalogFile) {
    throw new Error("usage: codex-model-roster.test.mjs <feature.js> <catalog.js>");
}

const feature = await import(pathToFileURL(path.resolve(featureFile)).href + `?t=${Date.now()}`);
assert.equal(feature.codexModelSupportsFastMode("gpt-6-astra"), true);
assert.equal(feature.codexModelSupportsFastMode("gpt-6-sol"), true);
assert.equal(feature.codexModelSupportsFastMode("gpt-6-luna"), true);
assert.equal(feature.codexModelSupportsFastMode("gpt-5.5"), false);

const input = [{ id: "gpt-6-sol" }, { id: "gpt-5.5" }, { id: "gpt-6-luna" }, { id: "future-model" }];
assert.deepEqual(feature.filterCodexModelsForPicker(input).map((model) => model.id), [
    "gpt-6-sol", "gpt-6-luna", "future-model",
]);
assert.equal(input.length, 4, "filter must not mutate the app-server response");

const catalog = await import("node:fs").then((fs) => fs.readFileSync(catalogFile, "utf8"));
assert.match(catalog, /filterCodexModelsForPicker\(parsedResponse\.success/);
assert.match(catalog, /import \{ buildCodexFeatures, codexModelSupportsFastMode, filterCodexModelsForPicker \}/);
console.log("codex model roster: GPT-6 Fast support and exact GPT-5.5 picker retirement passed");

