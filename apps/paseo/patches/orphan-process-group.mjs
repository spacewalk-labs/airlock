// [paseo-process-group] idempotent, all-or-nothing patcher. Layers on top of
// orphan-process-guard.mjs — apply that one FIRST (this patch anchors on text it
// introduces; if it is absent this exits 20 and skips, which is the correct
// degradation rather than a half-fix).
//
//   node orphan-process-group.mjs claude-agent    <.../providers/claude/agent.js>
//   node orphan-process-group.mjs claude-query    <.../providers/claude/query.js>
//   node orphan-process-group.mjs codex-transport <.../providers/codex/app-server-transport.js>
//
// Problem this closes (the one orphan-process-guard deliberately left open):
// when the agent LEADER exits before we terminate it, `terminateWithTreeKill`
// returns "already-exited" and stops — and by then the leader's MCP children have
// been reparented away, so a ppid-walking tree-kill can no longer find them. They
// survive as orphans. Measured on the pilot box 2026-08-05/06.
//
// Fix: give the leader its own PROCESS GROUP and kill the group, not the tree.
// A process group outlives its leader, so `kill(-pgid)` reaches the descendants
// even though the ppid chain is gone.
//
// Verified by controlled experiment (2026-08-06, pilot box):
//
//   detached=false  pgid != pid   leader kill -> grandchild ORPHANED
//                                 kill(-pid) -> ESRCH (no such group; harmless)
//   detached=true   pgid == pid   leader kill -> grandchild orphaned
//                                 kill(-pgid) -> grandchild DIES
//   both cases      child cgroup == airlock-paseo.service  (detached does NOT escape
//                   the cgroup, so `KillMode=control-group` still sweeps on restart)
//
// The ESRCH result is what makes the kill safe when the spawn edit did not apply:
// a process group id equals its leader's pid, so `kill(-pid)` can only ever reach
// the group led by that very process. If it is not a group leader, no such group
// exists and the call fails harmlessly instead of hitting anything else. We still
// refuse to signal our own group explicitly.
//
// Note: codex ALREADY spawns its app-server with `detached: true` upstream — it
// just never kills the group. So codex needs the sweep only; claude needs both.
//
// Contract: argv[2] = mode, argv[3] = target file. Exit codes as in
// orphan-process-guard.mjs (10 already / 20 drift / 0 written / 1 error).
import fs from "node:fs";

const MODE = process.argv[2];
const F = process.argv[3];
const MODES = ["claude-agent", "claude-query", "codex-transport"];
if (!MODE || !F || !MODES.includes(MODE)) {
    console.error("usage: orphan-process-group.mjs <" + MODES.join("|") + "> <file.js>");
    process.exit(1);
}

const SENTINEL = "[paseo-process-group]";
let src;
try { src = fs.readFileSync(F, "utf8"); }
catch (err) { console.error("read failed: " + String(err)); process.exit(1); }

if (src.includes(SENTINEL)) { console.log("ALREADY"); process.exit(10); }

const L = (...lines) => lines.join("\n");

// The group sweep, emitted verbatim into each target. Kept as one small function so
// the three call sites cannot drift apart.
const SWEEP_FN = (indent, name, providerLabel) => L(
    indent + "// [paseo-process-group] Kill the leader's PROCESS GROUP, not just its tree.",
    indent + "// A tree-kill walks ppid links, which are already gone once the leader exits —",
    indent + "// its MCP children get reparented and survive. The process group outlives the",
    indent + "// leader, so this reaches them. Safe when the spawn is NOT detached: a group id",
    indent + "// equals its leader's pid, so kill(-pid) can only ever hit the group led by that",
    indent + "// same process; if it leads none, the call fails with ESRCH and touches nothing.",
    indent + "//",
    indent + "// Why there is no \"is this my own group?\" check: a process group id IS the pid of",
    indent + "// its leader, and pids are unique among live processes — so a group we spawned can",
    indent + "// never share an id with the group this daemon sits in. (An earlier draft guarded",
    indent + "// with process.getpgrp(); that function does not exist in Node 22, so the branch was",
    indent + "// dead code pretending to be a safety net. Removed rather than left lying.)",
    indent + "// Residual, accepted: if the leader died and its pid were recycled by an unrelated",
    indent + "// group leader between the tree-kill and this call (sub-millisecond), we would signal",
    indent + "// that group. Closing it would need a liveness handle we no longer have by then.",
    indent + name + "(pid, reason) {",
    indent + "    if (!pid || pid <= 1 || pid === process.pid) {",
    indent + "        return;",
    indent + "    }",
    indent + "    try {",
    indent + "        process.kill(-pid, \"SIGKILL\");",
    indent + "        this.logger.warn({ pgid: pid, reason, provider: " + providerLabel + " }, \"[paseo-process-group] swept the leader's process group — descendants had outlived the tree-kill\");",
    indent + "    }",
    indent + "    catch (err) {",
    indent + "        if (err && err.code !== \"ESRCH\") {   // ESRCH = 그룹 없음(정상: 이미 전멸했거나 비-detached)",
    indent + "            this.logger.warn({ err, pgid: pid, reason, provider: " + providerLabel + " }, \"[paseo-process-group] process-group sweep failed\");",
    indent + "        }",
    indent + "    }",
    indent + "}",
);

// ------------------------------------------------------- claude / agent.js ---
// Anchors on orphan-process-guard's own text (apply that first).

const CA_OLD_METHOD = "    async terminateLiveChildren(reason) {";
const CA_NEW_METHOD = L(
    SWEEP_FN("    ", "sweepProcessGroup", '"claude"'),
    "    async terminateLiveChildren(reason) {",
);

const CA_OLD_KILL = L(
    '            if (result === "kill-timeout") {',
    '                this.logger.warn({ pid, agentId: this.agentId, reason }, "Claude process tree did not report exit after SIGKILL");',
    '            }',
    '            else if (result === "already-exited") {',
    '                this.logger.warn({ pid, agentId: this.agentId, provider: "claude", reason }, "[paseo-orphan-guard] leader had already exited — its MCP children were reparented to init and cannot be tree-killed from here");',
    '            }',
);
const CA_NEW_KILL = L(
    '            if (result === "kill-timeout") {',
    '                this.logger.warn({ pid, agentId: this.agentId, reason }, "Claude process tree did not report exit after SIGKILL");',
    '            }',
    '            // [paseo-process-group] The tree-kill above cannot reach descendants of a leader',
    '            // that already exited (their ppid links are gone). Sweep the group unconditionally:',
    '            // when the tree-kill did succeed this is a no-op (ESRCH — nothing left in the group).',
    '            this.sweepProcessGroup(pid, reason);',
);

// ------------------------------------------------------- claude / query.js ---

const CQ_OLD_SPAWN = L(
    '                signal: spawnOptions.signal,',
    '                stdio: ["pipe", "pipe", "pipe"],',
);
const CQ_NEW_SPAWN = L(
    '                signal: spawnOptions.signal,',
    '                // [paseo-process-group] Give the claude leader its own process group so its',
    '                // MCP children can still be reached after the leader itself exits (a ppid',
    '                // tree-kill cannot — they are reparented by then). cgroup membership is',
    '                // unaffected, so systemd KillMode=control-group still sweeps everything.',
    '                // codex already spawns its app-server this way upstream.',
    '                detached: process.platform !== "win32",',
    '                stdio: ["pipe", "pipe", "pipe"],',
);

// -------------------------------------------- codex / app-server-transport ---

const KT_OLD_DISPOSE = L(
    '        if (result === "kill-timeout") {',
    '            this.logger.warn({ timeoutMs: APP_SERVER_FORCE_SHUTDOWN_TIMEOUT_MS }, "Codex app-server did not report exit after SIGKILL");',
    '        }',
    '    }',
);
const KT_NEW_DISPOSE = L(
    '        if (result === "kill-timeout") {',
    '            this.logger.warn({ timeoutMs: APP_SERVER_FORCE_SHUTDOWN_TIMEOUT_MS }, "Codex app-server did not report exit after SIGKILL");',
    '        }',
    '        // [paseo-process-group] The app-server is already spawned detached upstream, but',
    '        // nothing ever killed its group — so when it exited first, its children survived.',
    '        this.sweepProcessGroup(this.child ? this.child.pid : undefined, "dispose");',
    '    }',
    SWEEP_FN("    ", "sweepProcessGroup", '"codex"'),
);

// ------------------------------------------------------------------ apply ---

const EDITS = {
    "claude-agent": [
        ["sweep-fn", CA_OLD_METHOD, CA_NEW_METHOD],
        ["kill-site", CA_OLD_KILL, CA_NEW_KILL],
    ],
    "claude-query": [
        ["spawn-detached", CQ_OLD_SPAWN, CQ_NEW_SPAWN],
    ],
    "codex-transport": [
        ["dispose-sweep", KT_OLD_DISPOSE, KT_NEW_DISPOSE],
    ],
}[MODE];

const missing = EDITS.filter(([, o]) => !src.includes(o)).map(([n]) => n);
if (missing.length > 0) {
    console.error("SKIP: anchors missing (upstream drift, or orphan-process-guard not applied first): " + missing.join(","));
    process.exit(20);
}
const ambiguous = EDITS.filter(([, o]) => src.indexOf(o) !== src.lastIndexOf(o)).map(([n]) => n);
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
