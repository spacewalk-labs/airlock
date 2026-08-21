// SPDX-License-Identifier: AGPL-3.0-only
//
// [paseo-cred-preserve] idempotent, all-or-nothing patcher (install.sh runs it right
// after the pinned npm install). Two independent targets, one per invocation:
//
//   node credential-key-preservation.mjs claude <.../quota-fetcher/providers/claude.js>
//   node credential-key-preservation.mjs codex  <.../quota-fetcher/providers/codex.js>
//
// Problem: paseo's quota fetchers refresh the OAuth token when the usage API answers
// 401/403, and they write the refreshed token back through a zod `z.object`. A
// `z.object` STRIPS unknown keys, at every level — so the write-back does not update
// the credential file, it REPLACES it with the four fields the schema happens to name.
//
//   claude.js — ClaudeCredentialsSchema keeps only claudeAiOauth.{accessToken,
//     refreshToken, subscriptionType, rateLimitTier}. saveClaudeCredentials() re-reads
//     ~/.claude/.credentials.json, `.parse()`s it, assigns the new oauth object, and
//     writes the PARSED result. Erased: claudeAiOauth.expiresAt,
//     claudeAiOauth.refreshTokenExpiresAt, claudeAiOauth.scopes, and the whole
//     top-level `_meta` block (email/org/kind) our account switcher reads.
//   codex.js — CodexAuthSchema keeps only tokens.{access_token, refresh_token,
//     account_id}, and saveCodexAuth() spreads that stripped object. Erased:
//     tokens.id_token, and the top-level auth_mode, OPENAI_API_KEY, last_refresh.
//     (last_refresh is the field that tells us whether a green Codex panel is backed
//     by a token that is actually alive — losing it is losing the liveness signal.)
//
// Both write paths are wrapped in a bare `catch {}`, so the damage is silent: the next
// thing to read the file simply finds a credential record with holes in it.
//
// Fix (both providers, same shape): merge the refreshed token fields into the ORIGINAL
// object parsed from disk instead of into zod's stripped output. The schema is still
// parsed — for validation — but its output is no longer what gets written.
//
// Deliberately out of scope: refresh timing, the 401/403 trigger, and recomputing
// claudeAiOauth.expiresAt from the refresh response. Preserving the previous (now
// stale) expiresAt is strictly better than dropping the field — a past expiry makes
// Claude Code refresh on its own next call, an absent one makes its state ambiguous —
// and writing a new expiry is a behaviour change, not data preservation.
//
// Contract: argv[2] = mode, argv[3] = target file. One stdout line + an exit code.
//   exit 10 = already patched (sentinel) -> skip
//   exit 20 = anchors missing or ambiguous (upstream drift) -> writes nothing
//   exit  0 = candidate written to <target>.paseo-new.mjs (install.sh runs
//             node --check then moves it)
//   exit  1 = usage / IO error
import fs from "node:fs";

const MODE = process.argv[2];
const F = process.argv[3];
if (!MODE || !F || (MODE !== "claude" && MODE !== "codex")) {
    console.error("usage: credential-key-preservation.mjs <claude|codex> <provider.js>");
    process.exit(1);
}

const SENTINEL = "[paseo-cred-preserve]";
let src;
try { src = fs.readFileSync(F, "utf8"); }
catch (err) { console.error("read failed: " + String(err)); process.exit(1); }

if (src.includes(SENTINEL)) { console.log("ALREADY"); process.exit(10); }

const L = (...lines) => lines.join("\n");

// ---------------------------------------------------------------- claude ----

const C_OLD_SAVE = L(
    '    async saveClaudeCredentials(credPath, oauth) {',
    '        try {',
    '            const existing = ClaudeCredentialsSchema.parse(JSON.parse(await fs.readFile(credPath, "utf8")));',
    '            existing.claudeAiOauth = oauth;',
    '            await fs.writeFile(credPath, JSON.stringify(existing, null, 2), { mode: 0o600 });',
    '        }',
    '        catch {',
    '            // Non-fatal; Claude Code can refresh again on its own next time.',
    '        }',
    '    }',
);
const C_NEW_SAVE = L(
    '    async saveClaudeCredentials(credPath, oauth) {',
    '        try {',
    '            // [paseo-cred-preserve] Merge into the RAW on-disk JSON, never into zod output.',
    '            // ClaudeCredentialsSchema is a z.object naming four token fields, so the upstream',
    '            // parse -> mutate -> write round trip did not update the credential file, it',
    '            // replaced it with those four fields: claudeAiOauth.expiresAt /',
    '            // refreshTokenExpiresAt / scopes and the top-level _meta block (email/org/kind)',
    '            // were all dropped. Parse for validation, write the original object.',
    '            const existing = JSON.parse(await fs.readFile(credPath, "utf8"));',
    '            ClaudeCredentialsSchema.parse(existing);',
    '            existing.claudeAiOauth = { ...(existing.claudeAiOauth ?? {}), ...oauth };',
    '            await fs.writeFile(credPath, JSON.stringify(existing, null, 2), { mode: 0o600 });',
    '        }',
    '        catch (err) {',
    '            // Non-fatal; Claude Code can refresh again on its own next time. Upstream',
    '            // swallowed this without a word — a failed write of the credential file is',
    '            // exactly the event that should be greppable afterwards.',
    '            this.logger.warn({ err }, "[paseo-cred-preserve] could not write refreshed Claude credentials");',
    '        }',
    '    }',
);

// ----------------------------------------------------------------- codex ----

const K_OLD_SAVE = L(
    '    async saveCodexAuth(authPath, original, refreshed) {',
    '        try {',
    '            const updated = {',
    '                ...original,',
    '                tokens: {',
    '                    ...original.tokens,',
    '                    access_token: refreshed.access_token ?? original.tokens?.access_token,',
    '                    refresh_token: refreshed.refresh_token ?? original.tokens?.refresh_token,',
    '                },',
    '            };',
    '            await fs.writeFile(authPath, JSON.stringify(updated, null, 2), { mode: 0o600 });',
    '        }',
    '        catch {',
    '            // Non-fatal; the next call can refresh again.',
    '        }',
    '    }',
);
const K_NEW_SAVE = L(
    '    async saveCodexAuth(authPath, original, refreshed) {',
    '        try {',
    '            // [paseo-cred-preserve] `original` came out of CodexAuthSchema, which keeps only',
    '            // tokens.{access_token,refresh_token,account_id} — spreading it wrote an auth.json',
    '            // without tokens.id_token and without the top-level auth_mode / OPENAI_API_KEY /',
    '            // last_refresh. Re-read the file and merge the refreshed fields over the raw JSON.',
    '            // The re-read has its own catch so a transient read failure falls back to the',
    '            // upstream write instead of silently dropping a rotated refresh token.',
    '            let onDisk;',
    '            try {',
    '                onDisk = JSON.parse(await fs.readFile(authPath, "utf8"));',
    '            }',
    '            catch {',
    '                onDisk = undefined;',
    '            }',
    '            if (!onDisk || typeof onDisk !== "object" || Array.isArray(onDisk)) {',
    '                // The re-read is a best effort, and its failure must not cost us the write:',
    '                // the OpenAI refresh grant ROTATES the refresh token, so the one still on',
    '                // disk is already invalidated server-side and dropping the new one would',
    '                // force a re-login. Fall back to upstream behaviour — write what we hold.',
    '                onDisk = { ...original };',
    '            }',
    '            const updated = {',
    '                ...onDisk,',
    '                tokens: {',
    '                    // No `...original.tokens` here: it is the stripped copy, and its only',
    '                    // field not overwritten below is a stale account_id that would clobber',
    '                    // a fresher one on disk.',
    '                    ...(onDisk.tokens ?? {}),',
    '                    access_token: refreshed.access_token ?? original.tokens?.access_token,',
    '                    refresh_token: refreshed.refresh_token ?? original.tokens?.refresh_token,',
    '                },',
    '            };',
    '            await fs.writeFile(authPath, JSON.stringify(updated, null, 2), { mode: 0o600 });',
    '        }',
    '        catch {',
    '            // Non-fatal; the next call can refresh again. Unlike the claude provider this',
    '            // one is constructed without a logger, so there is nothing to warn on. Only a',
    '            // failing writeFile reaches here now — the re-read has its own fallback above.',
    '        }',
    '    }',
);

// ------------------------------------------------------------------ apply ---

const EDITS = MODE === "claude"
    ? [["save-claude-credentials", C_OLD_SAVE, C_NEW_SAVE]]
    : [["save-codex-auth", K_OLD_SAVE, K_NEW_SAVE]];

// all-or-nothing: every anchor must be present AND unique. A duplicated anchor
// means String.replace would silently pick the first one — that is a drift signal,
// not something to guess at.
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
if (!out.includes(SENTINEL)) { console.error("sentinel absent after patching — logic error"); process.exit(1); }

try { fs.writeFileSync(F + ".paseo-new.mjs", out); }
catch (err) { console.error("tmp write failed: " + String(err)); process.exit(1); }
console.log("PATCHED");
process.exit(0);
