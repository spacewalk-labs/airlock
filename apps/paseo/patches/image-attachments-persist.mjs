// [paseo-attachments-persist] idempotent, all-or-nothing patcher (install.sh runs it
// right after the pinned npm install).
//
// Target: @getpaseo/server .../agent/providers/claude/agent.js — the claude provider's
//   toSdkUserMessage().
// Problem: an image pasted into paseo's web UI reaches the model ONLY as an inline base64
//   vision block. The model can see it, but there is no file on disk, so the agent's Read
//   tool has no path to open — "look at this screenshot and then edit the file" dead-ends.
// Fix: at the same point, persist the bytes under the session cwd
//   (<cwd>/.paseo-attachments/) and, leaving the inline vision block untouched, append a
//   sibling text block naming the absolute path. All three materialize paths converge on
//   this one function, so there is a single edit point.
//
// Contract: argv[2] = the target agent.js. One stdout line + an exit code for install.sh.
//   exit 10 = already patched (sentinel) -> skip
//   exit 20 = anchors missing (upstream drift) -> writes nothing, skips (the feature
//             degrades; the install continues)
//   exit  0 = candidate written to <target>.paseo-new.mjs (install.sh runs node --check
//             then moves it; the .mjs suffix is what makes an ESM syntax check possible)
//   exit  1 = usage / IO error
// all-or-nothing: all three anchors or none — never half a patch.
import fs from "node:fs";

const F = process.argv[2];
if (!F) { console.error("usage: image-attachments-persist.mjs <agent.js>"); process.exit(1); }

const SENTINEL = "[paseo-attachments-persist]";
let src;
try { src = fs.readFileSync(F, "utf8"); }
catch (err) { console.error("read failed: " + String(err)); process.exit(1); }

if (src.includes(SENTINEL)) { console.log("ALREADY"); process.exit(10); }

const L = (...lines) => lines.join("\n");

// -- anchors (OLD) / replacements (NEW). Every line is a single-quoted string, so the
// backticks and ${} below are literal text in the emitted bundle, not interpolation. --
const OLD_IMPORT = 'import { randomUUID } from "node:crypto";';
const NEW_IMPORT = 'import { randomUUID, createHash } from "node:crypto";';

const OLD_ISIMG = L(
    'function isImageMimeType(value) {',
    '    return (value === "image/jpeg" ||',
    '        value === "image/png" ||',
    '        value === "image/gif" ||',
    '        value === "image/webp");',
    '}',
);
const HELPER = L(
    '// [paseo-attachments-persist] Persist a pasted/uploaded image inside the session cwd',
    '// so the agent Read tool can open it by absolute path. The inline base64 vision block is',
    '// left alone (the model still sees it); a text block naming the path is appended beside it.',
    '// Files land in <cwd>/.paseo-attachments/, which self-ignores via its own .gitignore (*),',
    '// so git status stays clean. The name is content-addressed (sha256[:12]), which dedups a',
    '// re-paste or a replay. A failure is not swallowed: warn, and keep the inline block.',
    'const PASEO_IMG_EXT = { "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp" };',
    'function persistPastedImage(cwd, chunk, logger) {',
    '    if (typeof cwd !== "string" || cwd.length === 0) {',
    '        return null;',
    '    }',
    '    try {',
    '        const buf = Buffer.from(chunk.data, "base64");',
    '        const ext = PASEO_IMG_EXT[chunk.mimeType] ?? "img";',
    '        const dir = path.join(cwd, ".paseo-attachments");',
    '        fs.mkdirSync(dir, { recursive: true });',
    '        const gitignore = path.join(dir, ".gitignore");',
    '        if (!fs.existsSync(gitignore)) {',
    '            fs.writeFileSync(gitignore, "*\\n");',
    '        }',
    '        const name = `paste-${createHash("sha256").update(buf).digest("hex").slice(0, 12)}.${ext}`;',
    '        const abs = path.join(dir, name);',
    '        if (!fs.existsSync(abs)) {',
    '            fs.writeFileSync(abs, buf, { mode: 0o600 });',
    '        }',
    '        return abs;',
    '    }',
    '    catch (err) {',
    '        logger?.warn?.({ err: String(err) }, "paseo-attachments: could not persist pasted image");',
    '        return null;',
    '    }',
    '}',
);
const NEW_ISIMG = L(OLD_ISIMG, HELPER);

const OLD_BRANCH = L(
    '                else if (chunk.type === "image") {',
    '                    if (isImageMimeType(chunk.mimeType)) {',
    '                        content.push({',
    '                            type: "image",',
    '                            source: {',
    '                                type: "base64",',
    '                                media_type: chunk.mimeType,',
    '                                data: chunk.data,',
    '                            },',
    '                        });',
    '                    }',
    '                }',
);
const NEW_BRANCH = L(
    '                else if (chunk.type === "image") {',
    '                    if (isImageMimeType(chunk.mimeType)) {',
    '                        content.push({',
    '                            type: "image",',
    '                            source: {',
    '                                type: "base64",',
    '                                media_type: chunk.mimeType,',
    '                                data: chunk.data,',
    '                            },',
    '                        });',
    '                        const savedPath = persistPastedImage(this.config.cwd, chunk, this.logger);',
    '                        if (savedPath) {',
    '                            content.push({',
    '                                type: "text",',
    '                                text: `[Pasted image also saved to ${savedPath}]`,',
    '                            });',
    '                        }',
    '                    }',
    '                }',
);

const edits = [
    ["import", OLD_IMPORT, NEW_IMPORT],
    ["helper", OLD_ISIMG, NEW_ISIMG],
    ["branch", OLD_BRANCH, NEW_BRANCH],
];

// all-or-nothing: if any anchor is missing, skip the whole thing.
const missing = edits.filter(([, oldStr]) => !src.includes(oldStr)).map(([name]) => name);
if (missing.length > 0) {
    console.error("SKIP: anchors missing (upstream drift?): " + missing.join(","));
    process.exit(20);
}

let out = src;
for (const [name, oldStr, newStr] of edits) {
    const before = out;
    out = out.replace(oldStr, newStr);
    if (out === before) { console.error("replacement failed: " + name); process.exit(1); }
}
if (!out.includes(SENTINEL)) { console.error("sentinel absent after patching — logic error"); process.exit(1); }

try { fs.writeFileSync(F + ".paseo-new.mjs", out); }
catch (err) { console.error("tmp write failed: " + String(err)); process.exit(1); }
console.log("PATCHED");
process.exit(0);
