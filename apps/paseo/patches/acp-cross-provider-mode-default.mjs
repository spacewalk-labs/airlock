// [paseo-acp-cross-provider-mode-default] idempotent, all-or-nothing patcher.
//
//   node acp-cross-provider-mode-default.mjs <.../providers/generic-acp-agent.js>
//
// Target: @getpaseo/server .../agent/providers/generic-acp-agent.js
//   (GenericACPAgentClient, the class agy runs as).
//
// Problem: once a generic ACP agent (agy) advertises modes, `paseo run
// --provider agy` from an ATTENDED agent of a DIFFERENT provider, with no
// --mode, is refused: resolveAndValidateCreateAgentMode() (agent/create-agent
// -mode.js) throws "cannot inherit mode" whenever the parent's provider
// differs and neither side is unattended and the target has modes to choose
// from. The base ACPAgentClient already carries a bypass for this
// (resolveACPCreateConfig, set as an instance property in its own
// constructor) but only for an UNATTENDED create or an unattended parent --
// an attended cross-provider caller with no mode opinion still hits the
// throw.
//
// Fix would look like a plain method override on GenericACPAgentClient, but
// that is dead code against 0.8.0: ACPAgentClient's constructor does
// `this.resolveCreateConfig = resolveACPCreateConfig` as an OWN instance
// property (not a prototype method), and an instance property always shadows
// a subclass's same-named prototype method in the lookup chain -- so a
// subclass method literally never runs. Reusing the codebase's own pattern
// instead: capture the base's already-assigned function and wrap it, adding
// the attended-cross-provider bypass in front and falling through to the
// captured base behaviour (preserving its auto-accept feature-value
// injection for the unattended case) otherwise.
//
// Contract: argv[2] = target file. One stdout line + an exit code.
//   exit 10 = already patched (sentinel) -> skip
//   exit 20 = anchor missing (upstream drift) -> writes nothing
//   exit  0 = candidate written to <target>.paseo-new.mjs (install.sh runs
//             node --check then moves it)
//   exit  1 = usage / IO error
import fs from "node:fs";

const F = process.argv[2];
if (!F) {
    console.error("usage: acp-cross-provider-mode-default.mjs <generic-acp-agent.js>");
    process.exit(1);
}

const SENTINEL = "[paseo-acp-cross-provider-mode-default]";
let src;
try { src = fs.readFileSync(F, "utf8"); }
catch (err) { console.error("read failed: " + String(err)); process.exit(1); }

if (src.includes(SENTINEL)) { console.log("ALREADY"); process.exit(10); }

const L = (...lines) => lines.join("\n");

const OLD_CTOR_TAIL = L(
    '        });',
    '        this.command = options.command;',
);
const NEW_CTOR_TAIL = L(
    '        });',
    `        // ${SENTINEL} A generic ACP agent starts in its own default mode. Once it`,
    '        // lists modes, the base ACP bypass above only covers an unattended create',
    '        // or an unattended parent -- an ATTENDED agent of another provider with no',
    '        // --mode would still be refused ("cannot inherit mode"). Wrap the base',
    '        // resolver (captured before this overwrites it) rather than replacing it,',
    '        // so the unattended auto-accept feature-value injection it already does',
    '        // still runs for every case this does not need to change.',
    '        const baseResolveCreateConfig = this.resolveCreateConfig;',
    '        this.resolveCreateConfig = (input) => {',
    '            const parent = input.parent;',
    '            if (input.requestedMode === undefined &&',
    '                parent &&',
    '                parent.provider !== input.provider &&',
    '                !input.unattended &&',
    '                !parent.isUnattended) {',
    '                return { modeId: undefined, featureValues: input.featureValues };',
    '            }',
    '            return baseResolveCreateConfig(input);',
    '        };',
    '        this.command = options.command;',
);

const EDITS = [
    ["ctor-tail", OLD_CTOR_TAIL, NEW_CTOR_TAIL],
];

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
