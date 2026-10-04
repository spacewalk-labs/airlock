// SPDX-License-Identifier: AGPL-3.0-only
//
// claude-model-prune — keep paseo's model dropdown to the current roster: drop
// superseded models and add ones released after the pinned manifest.
//
// Target: @getpaseo/server .../agent/providers/claude/model-manifest.js
//         (CLAUDE_MODEL_MANIFEST). This edits paseo's own bundle and is therefore
//         a derivative work of paseo — AGPL-3.0-only, see README.md.
//
// Why: the pinned manifest still carries Opus 4.7 / 4.6 and Sonnet 4.6, so the
//      picker is 13 rows deep when only a handful are ever chosen. Remove the
//      superseded entries (see PRUNE_IDS). The pin predates Opus 5.5 and Sonnet
//      5.5, so they are added (see ADD_BLOCKS) — the CLI already accepts their
//      ids; only the picker could not offer them.
//
// Safe for existing sessions: the manifest is NOT on the execution path. An
//      agent's model string is handed to the Claude Code CLI as-is (setModel ->
//      config.model -> query), and the manifest is read in exactly two places:
//      the picker, and findClaudeModel().contextWindowMaxTokens for the context
//      gauge. So a session already pinned to a removed model keeps running — only
//      its gauge loses the known maximum. Verified by running an agent on a
//      removed id after applying this patch.
//
// Contract: argv[2] = target model-manifest.js. One stdout line + exit code:
//   exit 10 = already patched (sentinel) -> skip
//   exit 20 = array/entry shape not recognised (upstream drift) -> write
//             nothing, skip
//   exit  0 = candidate written to <target>.paseo-new.mjs (install.sh runs
//             `node --check` before mv)
//   exit  1 = usage / IO / logic error
// All-or-nothing: if the array body cannot be decomposed into entry blocks that
// reassemble byte-for-byte, nothing is touched.
import fs from "node:fs";

const F = process.argv[2];
if (!F) { console.error("usage: claude-model-prune.mjs <model-manifest.js>"); process.exit(1); }

// Removed from the picker. Kept: opus-5(+1m), fable-5, sonnet-5, opus-4-8(+1m), haiku-4-5.
const PRUNE_IDS = [
    "claude-opus-4-7[1m]",
    "claude-opus-4-7",
    "claude-opus-4-6[1m]",
    "claude-opus-4-6",
    "claude-sonnet-4-6[1m]",
    "claude-sonnet-4-6",
];

// Added to the picker, each placed just before `before`. Capabilities are only the
// ones measured: the CLI accepts the id and a 1M context; thinking-off and fast mode
// are not advertised until someone has run them.
const ADD_BLOCKS = [
    {
        id: "claude-opus-5-5",
        before: "claude-opus-5",
        text: [
            "    {",
            '        id: "claude-opus-5-5",',
            '        label: "Opus 5.5",',
            '        description: "Opus 5.5 · Latest release",',
            "        contextWindowMaxTokens: 1000000,",
            "        effortLevels: CLAUDE_EFFORT_LEVELS.xhigh,",
            "    },",
            "",
        ].join("\n"),
    },
    {
        id: "claude-sonnet-5-5",
        before: "claude-sonnet-5",
        text: [
            "    {",
            '        id: "claude-sonnet-5-5",',
            '        label: "Sonnet 5.5",',
            '        description: "Sonnet 5.5 · Latest release",',
            "        contextWindowMaxTokens: 1000000,",
            "        effortLevels: CLAUDE_EFFORT_LEVELS.xhigh,",
            "    },",
            "",
        ].join("\n"),
    },
];
// Entries that stop being the latest once ADD_BLOCKS lands.
const RELABELS = [
    ["claude-opus-5", 'description: "Opus 5 · Latest release",', 'description: "Opus 5 · Previous release",'],
    ["claude-sonnet-5", 'description: "Sonnet 5 · Best for everyday tasks",', 'description: "Sonnet 5 · Previous release",'],
];

const SENTINEL = "[airlock-model-prune]";
let src;
try { src = fs.readFileSync(F, "utf8"); }
catch (err) { console.error("read failed: " + String(err)); process.exit(1); }

const START = "export const CLAUDE_MODEL_MANIFEST = [\n";
const startIdx = src.indexOf(START);
if (startIdx < 0) { console.error("SKIP: manifest array start anchor missing"); process.exit(20); }
const bodyStart = startIdx + START.length;
const endIdx = src.indexOf("\n];", bodyStart);
if (endIdx < 0) { console.error("SKIP: manifest array end anchor missing"); process.exit(20); }
const body = src.slice(bodyStart, endIdx + 1); // through the final "    },\n"

// An entry block = (leading comment lines) + "    {" … "    }," — a comment rides
// along with the entry it introduces, so removing the entry removes its comment.
const BLOCK = /(?:^ {4}\/\/[^\n]*\n)*^ {4}\{\n(?:[^\n]*\n)*?^ {4}\},\n/gm;
const blocks = body.match(BLOCK) ?? [];
// Decomposition check: the blocks must reassemble into exactly the array body.
if (blocks.length === 0 || blocks.join("") !== body) {
    console.error("SKIP: array body did not decompose into entries (upstream format drift)");
    process.exit(20);
}

const idOf = (block) => block.match(/^ {8}id: "([^"]+)",$/m)?.[1] ?? null;
// Our own note is regenerated below, so an earlier run's copy is dropped here —
// that is what lets a manifest pruned by the previous version gain ADD_BLOCKS.
const stripNote = (block) => block.split("\n").filter((l) => !l.includes(SENTINEL)).join("\n");
let kept = blocks.filter((b) => !PRUNE_IDS.includes(idOf(b))).map(stripNote);
const removed = blocks.length - kept.length;
let added = 0;
for (const add of ADD_BLOCKS) {
    if (kept.some((b) => idOf(b) === add.id)) continue;
    const at = kept.findIndex((b) => idOf(b) === add.before);
    if (at < 0) { console.error(`SKIP: anchor entry ${add.before} missing (upstream drift)`); process.exit(20); }
    kept.splice(at, 0, add.text);
    added += 1;
}
kept = kept.map((b) => {
    const relabel = RELABELS.find(([id]) => idOf(b) === id);
    return relabel ? b.replace(relabel[1], relabel[2]) : b;
});
if (src.includes(SENTINEL) && removed === 0 && added === 0) { console.log("ALREADY"); process.exit(10); }
if (kept.length < 3) { console.error(`only ${kept.length} models would remain — refusing`); process.exit(1); }

const note = `    // ${SENTINEL} picker roster: superseded models removed, ${ADD_BLOCKS.map((a) => a.id).join(", ")} added (picker only — execution does not consult the manifest).\n`;
const out = src.slice(0, bodyStart) + note + kept.join("") + src.slice(endIdx + 1);

// Assert the default survived rather than asserting a count: upstream 0.2.x marks
// the default with defaultPriority, where zero isDefault entries is correct.
// Count only array entries (8-space indent) — getClaudeManifestModels() spreads
// the same literal, so a plain substring count overcounts.
const countDefaults = (s) => (s.match(/^ {8}isDefault: true,$/gm) ?? []).length;
const defaultsBefore = countDefaults(blocks.join(""));
const defaultsAfter = countDefaults(kept.join(""));
if (defaultsAfter !== defaultsBefore) {
    console.error(`default model was removed (isDefault ${defaultsBefore} -> ${defaultsAfter})`);
    process.exit(1);
}

try { fs.writeFileSync(F + ".paseo-new.mjs", out); }
catch (err) { console.error("tmp write failed: " + String(err)); process.exit(1); }
console.log(`PRUNED ${removed} ADDED ${added}`);
process.exit(0);
