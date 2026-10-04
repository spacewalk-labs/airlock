// SPDX-License-Identifier: AGPL-3.0-only
//
// codex-model-roster — keep Paseo's Codex picker aligned with Airlock's roster.
//
// Targets:
//   feature  .../agent/providers/codex-feature-definitions.js
//   catalog  .../agent/providers/codex-app-server-agent.js
//
// Codex app-server owns availability and returns the live model list. This patch
// deliberately does not invent GPT-6 Sol/Luna picker rows before the account can
// use them. It does two narrower things: teaches Paseo that those live rows support
// Fast mode, and removes retired GPT-5.5 from the rows app-server returns.
//
// Contract: argv[2] = feature|catalog, argv[3] = target. The candidate is written
// to <target>.paseo-new.mjs. Exit 10 = already patched, 20 = anchor drift.
import fs from "node:fs";

const mode = process.argv[2];
const file = process.argv[3];
if (!file || !["feature", "catalog"].includes(mode)) {
    console.error("usage: codex-model-roster.mjs <feature|catalog> <target.js>");
    process.exit(1);
}

const SENTINEL = "[airlock-codex-model-roster]";
let source;
try { source = fs.readFileSync(file, "utf8"); }
catch (error) { console.error("read failed: " + String(error)); process.exit(1); }

if (source.includes(SENTINEL)) { console.log("ALREADY"); process.exit(10); }

const lines = (...value) => value.join("\n");
let output;

if (mode === "feature") {
    const oldRoster = lines(
        "const CODEX_FAST_MODE_SUPPORTED_MODELS = new Set([",
        '    "gpt-6-astra",',
        '    "gpt-5.6",',
        '    "gpt-5.6-sol",',
        '    "gpt-5.6-terra",',
        '    "gpt-5.6-luna",',
        '    "gpt-5.5",',
        '    "gpt-5.4",',
        "]);",
    );
    const newRoster = lines(
        `// ${SENTINEL} availability still comes from Codex model/list.`,
        'const RETIRED_CODEX_MODEL_IDS = new Set(["gpt-5.5"]);',
        "const CODEX_FAST_MODE_SUPPORTED_MODELS = new Set([",
        '    "gpt-6-astra",',
        '    "gpt-6-sol",',
        '    "gpt-6-luna",',
        '    "gpt-5.6",',
        '    "gpt-5.6-sol",',
        '    "gpt-5.6-terra",',
        '    "gpt-5.6-luna",',
        '    "gpt-5.4",',
        "]);",
        "export function filterCodexModelsForPicker(models) {",
        "    return models.filter((model) => !RETIRED_CODEX_MODEL_IDS.has(model?.id));",
        "}",
    );
    if (!source.includes(oldRoster)) {
        console.error("SKIP: Codex Fast roster anchor missing");
        process.exit(20);
    }
    output = source.replace(oldRoster, newRoster);
} else {
    const oldImport = 'import { buildCodexFeatures, codexModelSupportsFastMode } from "./codex-feature-definitions.js";';
    const newImport = 'import { buildCodexFeatures, codexModelSupportsFastMode, filterCodexModelsForPicker } from "./codex-feature-definitions.js";';
    const oldModels = "            const models = parsedResponse.success ? (parsedResponse.data.data ?? []) : [];";
    const newModels = lines(
        `            // ${SENTINEL} keep retired rows out; live availability remains app-server-owned.`,
        "            const models = filterCodexModelsForPicker(parsedResponse.success ? (parsedResponse.data.data ?? []) : []);",
    );
    if (!source.includes(oldImport) || !source.includes(oldModels)) {
        console.error("SKIP: Codex catalog anchors missing");
        process.exit(20);
    }
    output = source.replace(oldImport, newImport).replace(oldModels, newModels);
}

if (!output.includes(SENTINEL) || output === source) {
    console.error("patch did not land");
    process.exit(1);
}
try { fs.writeFileSync(file + ".paseo-new.mjs", output); }
catch (error) { console.error("tmp write failed: " + String(error)); process.exit(1); }
console.log(mode === "feature" ? "CODEX FEATURE ROSTER" : "CODEX CATALOG FILTER");

