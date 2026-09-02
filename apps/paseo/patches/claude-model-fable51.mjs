// SPDX-License-Identifier: AGPL-3.0-only
//
// claude-model-fable51 — add Fable 5.1 to paseo's model dropdown.
//
// Target: @getpaseo/server .../agent/providers/claude/model-manifest.js
//         (CLAUDE_MODEL_MANIFEST). This edits paseo's own bundle and is therefore
//         a derivative work of paseo — AGPL-3.0-only, see README.md.
//
// Why: the pinned manifest (paseo 0.2.5) predates Fable 5.1, so the picker cannot
//      offer it even though the installed Claude Code CLI runs it. This is the same
//      shape as the Opus 5 backport step that lived here until the pin caught up —
//      delete this patch once PASEO_VER ships a manifest that already lists it.
//
// Safe: the manifest is NOT on the execution path. An agent's model string is handed
//      to the CLI as-is; the manifest is read only by the picker and by
//      findClaudeModel().contextWindowMaxTokens for the context gauge. Adding an
//      entry therefore cannot change how an existing session runs.
//
// 🔴 Gate: `minimumClaudeCodeVersion` is set to the version this was MEASURED on
//      (2.1.258 answered a live `claude --model claude-fable-5-1` prompt). The true
//      floor is not published, so the floor is deliberately the verified one — the
//      row stays hidden on older CLIs rather than offering a spawn that may fail.
//
// Contract (same as claude-model-prune.mjs): argv[2] = target model-manifest.js.
//   exit 10 = already patched (sentinel) -> skip
//   exit 20 = shape not recognised, or the entries are already present (upstream
//             caught up) -> write nothing, skip
//   exit  0 = candidate written to <target>.paseo-new.mjs (install.sh runs
//             `node --check` before mv)
//   exit  1 = usage / IO / logic error
import fs from "node:fs";

const F = process.argv[2];
if (!F) { console.error("usage: claude-model-fable51.mjs <model-manifest.js>"); process.exit(1); }

const SENTINEL = "[airlock-model-fable51]";
// Anchor on the existing Fable 5 rows: the new generation sits directly above them,
// the way opus-5 sits above opus-4-8. Anchoring on a sibling (rather than on the
// array head) keeps the insert next to the family it belongs to even if upstream
// reorders the array.
const ANCHOR = /^ {4}\{\n {8}id: "claude-fable-5\[1m\]",\n/m;

// contextWindowMaxTokens mirrors the Fable 5 rows. It drives only the context gauge,
// so if 5.1 ships a different window the gauge is off by that much — not the run.
const ENTRIES = `    {
        id: "claude-fable-5-1[1m]",
        label: "Fable 5.1 1M",
        description: "Fable 5.1 with 1M context window",
        minimumClaudeCodeVersion: "2.1.258",
        contextWindowMaxTokens: 1000000,
        effortLevels: CLAUDE_EFFORT_LEVELS.xhigh,
    },
    {
        id: "claude-fable-5-1",
        label: "Fable 5.1",
        description: "Fable 5.1 \\u00b7 Most powerful model",
        minimumClaudeCodeVersion: "2.1.258",
        contextWindowMaxTokens: 200000,
        effortLevels: CLAUDE_EFFORT_LEVELS.xhigh,
    },
`;

let src;
try { src = fs.readFileSync(F, "utf8"); }
catch (err) { console.error("read failed: " + String(err)); process.exit(1); }

if (src.includes(SENTINEL)) { console.log("ALREADY"); process.exit(10); }
if (src.includes('id: "claude-fable-5-1"')) {
    console.error("SKIP: manifest already lists Fable 5.1 (pin caught up — delete this patch)");
    process.exit(20);
}
if (!src.includes("export const CLAUDE_MODEL_MANIFEST = [\n")) {
    console.error("SKIP: manifest array anchor missing"); process.exit(20);
}
if (!src.includes("CLAUDE_EFFORT_LEVELS")) {
    console.error("SKIP: CLAUDE_EFFORT_LEVELS symbol missing — entry would not evaluate");
    process.exit(20);
}
const m = ANCHOR.exec(src);
if (!m) { console.error("SKIP: Fable 5 anchor row missing (upstream drift)"); process.exit(20); }

const out = src.slice(0, m.index) + ENTRIES + src.slice(m.index)
    + `\n// ${SENTINEL} Fable 5.1 rows added by airlock (apps/paseo/patches/claude-model-fable51.mjs)\n`;

try { fs.writeFileSync(F + ".paseo-new.mjs", out); }
catch (err) { console.error("write failed: " + String(err)); process.exit(1); }
console.log("added claude-fable-5-1, claude-fable-5-1[1m]");
