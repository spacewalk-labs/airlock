// [paseo-acp-agy-shared-catalog] idempotent, all-or-nothing patcher.
//
//   node acp-agy-shared-catalog.mjs <.../agent/provider-registry.js>
//
// Target: @getpaseo/server .../agent/provider-registry.js
//
// Problem: a new workspace shows agy's models ~10s after claude/codex. The
// snapshot manager already loads every provider in parallel; the difference is
// caching. claude and codex answer getCatalogCacheKey() with "host", so every
// workspace shares one catalog. A generic ACP client has no key, so its catalog
// is keyed by workspace cwd and each new workspace re-probes agy: spawn agy-acp,
// `agy models` (~3s), then start a real agy conversation for session/new (~7s).
// agy-acp's catalog does not depend on cwd (`agy models` is host-wide, modes are
// static), so it can share the host catalog like claude/codex.
//
// Two edits, both needed:
//   1. wrapClientProvider drops getCatalogCacheKey. agy always goes through it
//      (inner.provider is "acp", the provider id is "agy"), so without this a key
//      on the client never reaches the snapshot manager.
//   2. The provider "agy" gets the "host" key. Other generic ACP providers are
//      left per-cwd: their catalog may depend on the project.
//
// Contract: argv[2] = target file. One stdout line + an exit code.
//   exit 10 = already patched (sentinel) -> skip
//   exit 20 = anchor missing (upstream drift) -> writes nothing
//   exit  0 = candidate written to <target>.paseo-new.mjs (install.sh runs
//             node --check and the behaviour test, then moves it)
//   exit  1 = usage / IO error
import fs from "node:fs";

const F = process.argv[2];
if (!F) {
    console.error("usage: acp-agy-shared-catalog.mjs <provider-registry.js>");
    process.exit(1);
}

const SENTINEL = "[paseo-acp-agy-shared-catalog]";
let src;
try { src = fs.readFileSync(F, "utf8"); }
catch (err) { console.error("read failed: " + String(err)); process.exit(1); }

if (src.includes(SENTINEL)) { console.log("ALREADY"); process.exit(10); }

const L = (...lines) => lines.join("\n");

const OLD_WRAP = L(
    '    const listFeatures = inner.listFeatures?.bind(inner);',
    '    return {',
    '        provider,',
    '        capabilities: inner.capabilities,',
);
const NEW_WRAP = L(
    '    const listFeatures = inner.listFeatures?.bind(inner);',
    '    return {',
    '        provider,',
    '        capabilities: inner.capabilities,',
    `        // ${SENTINEL} Keep the inner client's catalogue key, or a wrapped`,
    '        // provider (every custom ACP one) is re-probed for each workspace.',
    '        getCatalogCacheKey: inner.getCatalogCacheKey?.bind(inner),',
);

const OLD_GENERIC = '                    return new GenericACPAgentClient(acpOptions);';
const NEW_GENERIC = L(
    '                    const genericClient = new GenericACPAgentClient(acpOptions);',
    `                    // ${SENTINEL} agy-acp's catalogue is host-wide (\`agy models\`,`,
    '                    // static modes), so share it across workspaces like claude/codex.',
    '                    if (providerId === "agy") {',
    '                        genericClient.getCatalogCacheKey = async () => "host";',
    '                    }',
    '                    return genericClient;',
);

const EDITS = [
    ["wrap-forward-key", OLD_WRAP, NEW_WRAP],
    ["agy-host-key", OLD_GENERIC, NEW_GENERIC],
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
