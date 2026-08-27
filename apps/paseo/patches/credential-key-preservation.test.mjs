// SPDX-License-Identifier: AGPL-3.0-only
//
// [paseo-cred-preserve] Behaviour check for the applied patch.
//
//   node credential-key-preservation.test.mjs <claude|codex> <.../quota-fetcher/providers/X.js>
//
// It does NOT test a copy of the logic: it slices the save method out of the *installed,
// patched* bundle and drives that text against an in-memory fs and fake credential
// fixtures, so a patch that applied but reassembled wrongly fails here. Textual anchors
// and `node --check` cannot tell us what actually survives a write-back, and this is a
// patch whose entire purpose is what survives. Exit 0 = all scenarios pass.
//
// Every token value below is invented. The check never touches a real credential file.
import fs from "node:fs";

const MODE = process.argv[2];
const F = process.argv[3];
if (!MODE || !F || (MODE !== "claude" && MODE !== "codex")) {
    console.error("usage: credential-key-preservation.test.mjs <claude|codex> <provider.js>");
    process.exit(1);
}
const src = fs.readFileSync(F, "utf8");

const slice = (startMarker) => {
    const a = src.indexOf(startMarker);
    if (a < 0) return null;
    // The save method is the last one in its class: it ends at the closing brace of the
    // method, which is the first "\n    }\n}" after the start.
    const b = src.indexOf("\n    }\n}", a);
    if (b < 0) return null;
    return src.slice(a, b + "\n    }".length);
};

let fail = 0;
const ok = (cond, msg) => { console.log((cond ? "  PASS " : "  FAIL ") + msg); if (!cond) fail++; };

// In-memory fs stand-in with the two methods' entire surface: readFile and writeFile.
const makeFs = (initial) => {
    const store = new Map(Object.entries(initial));
    return {
        store,
        api: {
            async readFile(p) {
                if (!store.has(p)) throw Object.assign(new Error("ENOENT"), { code: "ENOENT" });
                return store.get(p);
            },
            async writeFile(p, data) { store.set(p, data); },
        },
    };
};

if (MODE === "claude") {
    const method = slice("    async saveClaudeCredentials(credPath, oauth) {");
    if (!method) { console.error("could not slice saveClaudeCredentials out of the bundle"); process.exit(1); }
    // The sliced text closes over `fs` and `ClaudeCredentialsSchema` from module scope.
    // A schema that validates nothing is the honest stand-in here: the point of the patch
    // is that the schema's OUTPUT is no longer what gets written.
    const warns = [];
    const build = (fsApi) => new Function("fs", "ClaudeCredentialsSchema", `
      return class T {
        constructor(logger){ this.logger = logger; }
${method}
      };`)(fsApi, { parse: (v) => ({ claudeAiOauth: { accessToken: v?.claudeAiOauth?.accessToken } }) });

    const FIXTURE = {
        claudeAiOauth: {
            accessToken: "FAKE-access-old",
            refreshToken: "FAKE-refresh-old",
            expiresAt: 1893456000000,
            refreshTokenExpiresAt: 1924992000000,
            scopes: ["user:inference", "user:profile"],
            subscriptionType: "max",
            rateLimitTier: "default_claude_max_20x",
            providerExtension: { retained: true },
        },
        _meta: {
            email: "fixture@example.invalid", org: "Fixture Org", kind: "max",
            platformExtension: { retained: true },
        },
        futureTopLevel: { retained: true },
    };
    const P = "/fake/.credentials.json";
    const mem = makeFs({ [P]: JSON.stringify(FIXTURE, null, 2) });
    const t = new (build(mem.api))({ warn: (o, m) => warns.push(m) });
    await t.saveClaudeCredentials(P, {
        accessToken: "FAKE-access-new",
        refreshToken: "FAKE-refresh-new",
        subscriptionType: "max",
        rateLimitTier: "default_claude_max_20x",
    });
    const out = JSON.parse(mem.store.get(P));
    ok(out.claudeAiOauth.accessToken === "FAKE-access-new"
        && out.claudeAiOauth.refreshToken === "FAKE-refresh-new", "(1) refreshed tokens are written");
    ok(out.claudeAiOauth.expiresAt === FIXTURE.claudeAiOauth.expiresAt
        && out.claudeAiOauth.refreshTokenExpiresAt === FIXTURE.claudeAiOauth.refreshTokenExpiresAt
        && Array.isArray(out.claudeAiOauth.scopes) && out.claudeAiOauth.scopes.length === 2,
    "(2) expiresAt / refreshTokenExpiresAt / scopes survive the write-back");
    ok(out._meta && out._meta.email === FIXTURE._meta.email, "(3) the top-level _meta block survives");

    // schemas/credentials/pool-record-v1.json deliberately leaves all three objects
    // open. Drive the ACTUAL extracted save method, not a model of it: reconstructing
    // only today's named fields is still a contract violation even when every named
    // assertion above survives.
    ok(out.claudeAiOauth.providerExtension?.retained === true
        && out._meta?.platformExtension?.retained === true
        && out.futureTopLevel?.retained === true,
    "(4) unknown fields survive at the OAuth, metadata, and record levels");

    // A file the schema rejects must be left exactly as it was, and must say so.
    const mem2 = makeFs({ [P]: "{ not json" });
    const warns2 = [];
    const t2 = new (build(mem2.api))({ warn: (o, m) => warns2.push(m) });
    await t2.saveClaudeCredentials(P, { accessToken: "FAKE-access-new" });
    ok(mem2.store.get(P) === "{ not json", "(5) an unreadable credential file is not clobbered");
    ok(warns2.some((w) => String(w).includes("[paseo-cred-preserve]")), "(6) that failure warns instead of passing silently");
}

if (MODE === "codex") {
    const method = slice("    async saveCodexAuth(authPath, original, refreshed) {");
    if (!method) { console.error("could not slice saveCodexAuth out of the bundle"); process.exit(1); }
    const build = (fsApi) => new Function("fs", `
      return class T {
${method}
      };`)(fsApi);

    const FIXTURE = {
        auth_mode: "chatgpt",
        OPENAI_API_KEY: null,
        tokens: {
            id_token: "FAKE-id-token",
            access_token: "FAKE-access-old",
            refresh_token: "FAKE-refresh-old",
            account_id: "FAKE-account",
        },
        last_refresh: "2026-08-01T00:00:00.000Z",
    };
    // What CodexAuthSchema hands saveCodexAuth: three fields, nothing else.
    const stripped = { tokens: { access_token: "FAKE-access-old", refresh_token: "FAKE-refresh-old", account_id: "FAKE-account" } };
    const refreshed = { access_token: "FAKE-access-new", refresh_token: "FAKE-refresh-new" };

    const P = "/fake/auth.json";
    const mem = makeFs({ [P]: JSON.stringify(FIXTURE, null, 2) });
    await new (build(mem.api))().saveCodexAuth(P, stripped, refreshed);
    const out = JSON.parse(mem.store.get(P));
    ok(out.tokens.access_token === "FAKE-access-new" && out.tokens.refresh_token === "FAKE-refresh-new",
        "(1) refreshed tokens are written");
    ok(out.tokens.id_token === FIXTURE.tokens.id_token, "(2) tokens.id_token survives the write-back");
    ok(out.auth_mode === "chatgpt" && out.last_refresh === FIXTURE.last_refresh
        && Object.hasOwn(out, "OPENAI_API_KEY"), "(3) auth_mode / OPENAI_API_KEY / last_refresh survive");

    // A newer account_id on disk must win over the stale one carried in `original`.
    const mem2 = makeFs({ [P]: JSON.stringify({ ...FIXTURE, tokens: { ...FIXTURE.tokens, account_id: "FAKE-account-newer" } }, null, 2) });
    await new (build(mem2.api))().saveCodexAuth(P, stripped, refreshed);
    ok(JSON.parse(mem2.store.get(P)).tokens.account_id === "FAKE-account-newer",
        "(4) a fresher on-disk account_id is not clobbered by the stripped copy");

    // The refresh grant rotates the refresh token: a failed re-read must still write it.
    const mem3 = makeFs({});
    await new (build(mem3.api))().saveCodexAuth(P, stripped, refreshed);
    const out3 = mem3.store.has(P) ? JSON.parse(mem3.store.get(P)) : null;
    ok(out3 !== null && out3.tokens.refresh_token === "FAKE-refresh-new",
        "(5) an unreadable auth.json still gets the rotated refresh token (no re-login)");
}

console.log(fail === 0 ? "all scenarios passed" : `${fail} scenario(s) failed`);
process.exit(fail === 0 ? 0 : 1);
