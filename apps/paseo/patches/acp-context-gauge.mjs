// [paseo-acp-context-gauge] idempotent, all-or-nothing patcher.
//
//   node acp-context-gauge.mjs <.../providers/acp-agent.js>
//
// agy runs over Paseo's generic ACP provider. Against the installed 0.8.0 dist,
// four things an ACP agent's session/update stream already reports never reach
// the UI or downstream config-derived state:
//
//   (1) usage_update is parsed and then dropped (`handleUsageUpdate` was
//       `void update;`) -- no context-window gauge, ever, for any ACP provider.
//   (2) handlePromptResponse's end-of-turn usage OVERWRITES currentTurnUsage
//       instead of merging, so even a turn that DID see usage_update mid-turn
//       loses the context-window fields the moment the turn ends.
//   (3) config_option_update unconditionally reassigns availableModes from
//       deriveModesFromACP(..., null, configOptions) -- a call with no mode
//       state (that argument is `null`) can only return the config-option-
//       derived fallback, so any provider whose modes came from session/new's
//       own advertised mode list (not a config option) loses that list on the
//       next model/thinking-only config update.
//   (4) an ACP agent's own advertised "unattended" mode carries the marker in
//       ACP's `_meta.paseo.isUnattended`, but deriveModesFromACP drops it --
//       so nothing downstream (including the create-config bypass
//       acp-cross-provider-mode-default.mjs relies on) can tell an unattended
//       mode from any other by inspecting the mode list alone. The provider
//       catalog probe also never surfaces the agent's own default mode.
//
// Fix: forward handleUsageUpdate's mapped usage as a real usage_updated event
// (merged into currentTurnUsage, not replacing it), preserve availableModes
// across a config-only update, carry isUnattended through the mode mapping,
// and add defaultModeId to the catalog probe result.
//
// Contract: argv[2] = target file. One stdout line + an exit code.
//   exit 10 = already patched (sentinel) -> skip
//   exit 20 = anchors missing or ambiguous (upstream drift) -> writes nothing
//   exit  0 = candidate written to <target>.paseo-new.mjs (install.sh runs
//             node --check then moves it)
//   exit  1 = usage / IO error
import fs from "node:fs";

const F = process.argv[2];
if (!F) {
    console.error("usage: acp-context-gauge.mjs <acp-agent.js>");
    process.exit(1);
}

const SENTINEL = "[paseo-acp-context-gauge]";
let src;
try { src = fs.readFileSync(F, "utf8"); }
catch (err) { console.error("read failed: " + String(err)); process.exit(1); }

if (src.includes(SENTINEL)) { console.log("ALREADY"); process.exit(10); }

const L = (...lines) => lines.join("\n");

// ── mode isUnattended passthrough ───────────────────────────────────────────
const OLD_MODE_MAP = L(
    '            modes: modeState.availableModes.map((mode) => ({',
    '                id: mode.id,',
    '                label: mode.name,',
    '                description: mode.description ?? undefined,',
    '            })),',
    '            currentModeId: modeState.currentModeId ?? null,',
);
const NEW_MODE_MAP = L(
    '            modes: modeState.availableModes.map((mode) => ({',
    '                id: mode.id,',
    '                label: mode.name,',
    '                description: mode.description ?? undefined,',
    `                // ${SENTINEL} Without an unattended mode, creating this provider's`,
    '                // agent from an unattended parent of another provider fails',
    '                // ("cannot inherit mode").',
    '                ...(mode._meta?.paseo?.isUnattended === true ? { isUnattended: true } : {}),',
    '            })),',
    '            currentModeId: modeState.currentModeId ?? null,',
);

// ── catalog probe: surface the agent's own default mode ────────────────────
const OLD_CATALOG_RETURN = L(
    '            return {',
    '                models: this.modelTransformer ? this.modelTransformer(models) : models,',
    '                modes: modeInfo.modes,',
    '            };',
);
const NEW_CATALOG_RETURN = L(
    '            return {',
    '                models: this.modelTransformer ? this.modelTransformer(models) : models,',
    '                modes: modeInfo.modes,',
    `                // ${SENTINEL} Lets the provider list show the agent's own default mode.`,
    '                ...(modeInfo.currentModeId ? { defaultModeId: modeInfo.currentModeId } : {}),',
    '            };',
);

// ── usage_update: forward the mapped event instead of dropping it ──────────
const OLD_USAGE_CASE = L(
    '            case "usage_update":',
    '                this.handleUsageUpdate(update);',
    '                return pendingUserEvents;',
);
const NEW_USAGE_CASE = L(
    '            case "usage_update":',
    `                // ${SENTINEL}`,
    '                return [...pendingUserEvents, ...this.handleUsageUpdate(update)];',
);

// ── config_option_update: a config-only update must not blank the mode list ─
const OLD_CONFIG_MODES = L(
    '        const nextMode = modeInfo.currentModeId;',
    '        const nextModel = deriveCurrentConfigValue(this.configOptions, "model");',
    '        const nextThinkingOptionId = deriveCurrentConfigValue(this.configOptions, "thought_level");',
    '        this.availableModes = modeInfo.modes;',
);
const NEW_CONFIG_MODES = L(
    '        const nextMode = modeInfo.currentModeId;',
    '        const nextModel = deriveCurrentConfigValue(this.configOptions, "model");',
    '        const nextThinkingOptionId = deriveCurrentConfigValue(this.configOptions, "thought_level");',
    `        // ${SENTINEL} Modes that came from session/new (not from a mode config`,
    '        // option) survive an update that only touches model or thought level:',
    '        // deriveModesFromACP(..., null, configOptions) above has no mode state to',
    '        // read from, so nextMode is null and modeInfo.modes falls back to whatever',
    '        // the config options alone imply -- often nothing.',
    '        if (nextMode !== null) {',
    '            this.availableModes = modeInfo.modes;',
    '        }',
);

// ── handleUsageUpdate + handlePromptResponse: implement the gauge, merge ───
const OLD_USAGE_HANDLERS = L(
    '    handleUsageUpdate(update) {',
    '        void update;',
    '    }',
    '    handlePromptResponse(response, turnId) {',
    '        this.currentTurnUsage = mapACPUsage(response.usage) ?? this.currentTurnUsage;',
);
const NEW_USAGE_HANDLERS = L(
    `    // ${SENTINEL} ACP usage_update carries the context window (used/size) and`,
    '    // optional cost; it is what drives the context gauge, mid-turn included.',
    '    handleUsageUpdate(update) {',
    '        if (typeof update.used !== "number" || typeof update.size !== "number") {',
    '            return [];',
    '        }',
    '        this.currentTurnUsage = {',
    '            ...this.currentTurnUsage,',
    '            contextWindowUsedTokens: update.used,',
    '            contextWindowMaxTokens: update.size,',
    '            ...(update.cost?.currency === "USD" ? { totalCostUsd: update.cost.amount } : {}),',
    '        };',
    '        return [',
    '            {',
    '                type: "usage_updated",',
    '                provider: this.provider,',
    '                usage: { ...this.currentTurnUsage },',
    '                turnId: this.activeForegroundTurnId ?? undefined,',
    '            },',
    '        ];',
    '    }',
    '    handlePromptResponse(response, turnId) {',
    `        // ${SENTINEL} Keep the context-window fields from usage_update; the prompt`,
    '        // response only reports token counts.',
    '        const promptUsage = mapACPUsage(response.usage);',
    '        if (promptUsage) {',
    '            this.currentTurnUsage = { ...this.currentTurnUsage, ...promptUsage };',
    '        }',
);

const EDITS = [
    ["mode-map", OLD_MODE_MAP, NEW_MODE_MAP],
    ["catalog-return", OLD_CATALOG_RETURN, NEW_CATALOG_RETURN],
    ["usage-case", OLD_USAGE_CASE, NEW_USAGE_CASE],
    ["config-modes", OLD_CONFIG_MODES, NEW_CONFIG_MODES],
    ["usage-handlers", OLD_USAGE_HANDLERS, NEW_USAGE_HANDLERS],
];

// all-or-nothing: every anchor must be present AND unique. A duplicated anchor
// means String.replace would silently pick the first one -- that is a drift
// signal, not something to guess at.
const missing = EDITS.filter(([, oldStr]) => !src.includes(oldStr)).map(([name]) => name);
if (missing.length > 0) {
    console.error("SKIP: anchors missing (upstream drift?): " + missing.join(","));
    process.exit(20);
}
const ambiguous = EDITS
    .filter(([, oldStr]) => src.indexOf(oldStr) !== src.lastIndexOf(oldStr))
    .map(([name]) => name);
if (ambiguous.length > 0) {
    console.error("SKIP: anchors not unique (upstream drift?): " + ambiguous.join(","));
    process.exit(20);
}

let out = src;
for (const [name, oldStr, newStr] of EDITS) {
    const before = out;
    out = out.replace(oldStr, newStr);
    if (out === before) { console.error("replacement failed: " + name); process.exit(1); }
}
if (!out.includes(SENTINEL)) { console.error("sentinel absent after patching -- logic error"); process.exit(1); }

try { fs.writeFileSync(F + ".paseo-new.mjs", out); }
catch (err) { console.error("tmp write failed: " + String(err)); process.exit(1); }
console.log("PATCHED");
process.exit(0);
