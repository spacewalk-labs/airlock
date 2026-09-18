// SPDX-License-Identifier: AGPL-3.0-only
//
// opencode-grok-defaults — OpenCode picker order and per-model thinking defaults.
//
// Target: @getpaseo/server .../agent/providers/opencode-agent.js
//         (buildOpenCodeModelDefinition + fetchModelsFromClient). This edits
//         paseo's own bundle and is therefore a derivative work of paseo —
//         AGPL-3.0-only, see README.md.
//
// Why: OpenCode reports models in provider-catalog order (Gemini, then GPT, then
//      xAI, then opencode-go) and treats the first variant key as the thinking
//      default. Airlock's default seat is now opencode-go/muse-spark-1.3-contributor
//      at xhigh, with grok-4.6 (high) and grok-build immediately under it. Only
//      boxes that whitelist muse-spark-1.3-contributor in opencode.jsonc (box-local
//      config, not this patch) ever see it in the fetched model list, so this is a
//      no-op everywhere else.
//
// Safe for existing sessions: listModels is picker/create-form only. An already
//      running agent's model and thinkingOptionId stay on the session record.
//
// Contract: argv[2] = target opencode-agent.js. One stdout line + exit code:
//   exit 10 = already patched (sentinel) -> skip
//   exit 20 = anchors missing (upstream drift) -> write nothing, skip
//   exit  0 = candidate written to <target>.paseo-new.mjs (install.sh runs
//             `node --check` before mv)
//   exit  1 = usage / IO / logic error
// All-or-nothing: both anchors or none.
import fs from "node:fs";

const F = process.argv[2];
if (!F) { console.error("usage: opencode-grok-defaults.mjs <opencode-agent.js>"); process.exit(1); }

const SENTINEL = "[airlock-opencode-grok-defaults]";
let src;
try { src = fs.readFileSync(F, "utf8"); }
catch (err) { console.error("read failed: " + String(err)); process.exit(1); }

if (src.includes(SENTINEL)) { console.log("ALREADY"); process.exit(10); }

const L = (...lines) => lines.join("\n");

// 0.8.0 note: upstream restructured the thinking-option default from
// "index 0 of a plain rawVariants.map()" to "index 0 of [synthetic Default
// entry, ...rawVariants]", with defaultThinkingOptionId reading
// thinkingOptions[0].id (buildOpenCodeModelDefinition). Same mechanism
// (first element wins), different array shape — reorder the assembled
// array instead of rawVariants so a synthetic Default entry never steals
// the front slot from "high".
const OLD_THINKING = L(
    "    const rawVariants = model.variants ? Object.keys(model.variants) : [];",
    "    // OpenCode lists only overrides; its base model behavior is selected by omitting `variant`.",
    "    const thinkingOptions = rawVariants.length",
    "        ? [",
    '            { id: OPENCODE_DEFAULT_VARIANT_ID, label: "Default", isDefault: true },',
    "            ...rawVariants.map((id) => ({ id, label: id })),",
    "        ]",
    "        : [];",
);
const NEW_THINKING = L(
    "    const rawVariants = model.variants ? Object.keys(model.variants) : [];",
    "    // OpenCode lists only overrides; its base model behavior is selected by omitting `variant`.",
    "    let thinkingOptions = rawVariants.length",
    "        ? [",
    '            { id: OPENCODE_DEFAULT_VARIANT_ID, label: "Default", isDefault: true },',
    "            ...rawVariants.map((id) => ({ id, label: id })),",
    "        ]",
    "        : [];",
    `    // ${SENTINEL} grok-4.6 thinking default starts at high (defaultThinkingOptionId reads thinkingOptions[0]).`,
    '    if (provider.id === "xai" && modelId === "grok-4.6" && rawVariants.includes("high")) {',
    '        const high = thinkingOptions.find((option) => option.id === "high");',
    '        if (high) thinkingOptions = [high, ...thinkingOptions.filter((option) => option.id !== "high")];',
    "    }",
    `    // ${SENTINEL} muse-spark-1.3-contributor thinking default starts at xhigh (same mechanism as grok-4.6 above).`,
    '    if (provider.id === "opencode-go" && modelId === "muse-spark-1.3-contributor" && rawVariants.includes("xhigh")) {',
    '        const xhigh = thinkingOptions.find((option) => option.id === "xhigh");',
    '        if (xhigh) thinkingOptions = [xhigh, ...thinkingOptions.filter((option) => option.id !== "xhigh")];',
    "    }",
);

// 0.8.0 note: a context-window cache flush (modelContextWindows) now sits
// between the push loop and the return; anchor past it so the sort still
// runs on the fully-built array immediately before it leaves the function.
const OLD_RETURN = L(
    "                models.push(definition);",
    "            }",
    "        }",
    "        context?.signal.throwIfAborted();",
    "        this.modelContextWindows.clear();",
    "        for (const [key, value] of contextWindows)",
    "            this.modelContextWindows.set(key, value);",
    "        return models;",
);
const NEW_RETURN = L(
    "                models.push(definition);",
    "            }",
    "        }",
    "        context?.signal.throwIfAborted();",
    "        this.modelContextWindows.clear();",
    "        for (const [key, value] of contextWindows)",
    "            this.modelContextWindows.set(key, value);",
    `        // ${SENTINEL} picker order: muse-spark-1.3-contributor, grok-4.6, grok-build, then the rest.`,
    '        const preferred = ["opencode-go/muse-spark-1.3-contributor", "xai/grok-4.6", "xai/grok-build-0.1"];',
    "        models.sort((left, right) => {",
    "            const li = preferred.indexOf(left.id);",
    "            const ri = preferred.indexOf(right.id);",
    "            if (li === -1 && ri === -1) return 0;",
    "            if (li === -1) return 1;",
    "            if (ri === -1) return -1;",
    "            return li - ri;",
    "        });",
    "        return models;",
);

if (!src.includes(OLD_THINKING) || !src.includes(OLD_RETURN)) {
    console.error("SKIP: opencode model/thinking anchors missing (upstream drift)");
    process.exit(20);
}

const out = src.replace(OLD_THINKING, NEW_THINKING).replace(OLD_RETURN, NEW_RETURN);
if (!out.includes(SENTINEL) || out.includes(OLD_THINKING) || out.includes(OLD_RETURN)) {
    console.error("replace did not land both hunks");
    process.exit(1);
}

try { fs.writeFileSync(F + ".paseo-new.mjs", out); }
catch (err) { console.error("tmp write failed: " + String(err)); process.exit(1); }
console.log("GROK DEFAULTS");
process.exit(0);
