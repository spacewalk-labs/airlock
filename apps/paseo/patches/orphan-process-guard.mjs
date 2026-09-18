// [paseo-orphan-guard] idempotent, all-or-nothing patcher (install.sh runs it right
// after the pinned npm install).
//
//   node orphan-process-guard.mjs claude <.../providers/claude/agent.js>
//
// Problem: the claude provider tracks exactly one live child per session
// (`this.childProcess`) and kills it in close() behind an `if (handle)` guard.
// Three ways a running process escapes:
//
//   (1) close() sets `closed = true` -- but ensureQuery() does not check that flag
//       (only startTurn()/startQueryPump() do, confirmed against 0.8.0 source). Any
//       control-plane call that lands during or after close (setMode, setModel,
//       listCommands, revertFiles, ensureFreshQuery) spawns a REPLACEMENT process
//       onto the already-closed session. Nothing will ever close that session
//       again, so the process runs until the box is rebooted.
//   (2) a second spawn overwrites the single handle; the first process is dropped
//       on the floor while the handle still looks healthy (so a null-check fix
//       does not catch this one).
//   (3) both of the above are SILENT: the `if (handle)` guard has no else branch,
//       and the surrounding session_close.start/complete lines are logger.trace,
//       which the daemon's info-level logger never emits. close() reports success
//       having killed nothing.
//
// Fix:
//   - ownership becomes a Set of live handles, not one slot; every handle in it is
//     terminated at close and at query restart,
//   - a closed-session gate on the spawn entry point (ensureQuery) so a dead
//     session cannot give birth,
//   - a late-arrival path: a child that shows up after close is terminated on the
//     spot instead of being stored,
//   - logger.warn (level 40, actually emitted) on every one of those branches,
//     including "there was nothing to kill" -- so the next occurrence is visible
//     instead of inferred.
//
// codex is intentionally NOT covered here anymore. Re-checked against 0.8.0
// (`codex-app-server-agent.js`): upstream rewrote CodexAppServerSession's
// connect()/close() lifecycle since the 0.2.5 fork this patch was ported from --
// connect() now gates on `this.closed` at three points (entry, post-spawn-before-
// adopting the client, post-setup-before-marking-connected), de-duplicates
// concurrent connect() calls through a single shared `connectionPromise` (so two
// overlapping callers cannot each spawn their own app-server), and every failure
// branch disposes the client it identity-checks against `this.client` before
// deciding whether it is still the live one. That is the same fix this patch
// makes for claude, already done upstream. Re-adding it would be dead code
// shadowing a fix that already shipped -- same triage call as Fable 5.1 /
// credential-preservation / finish-notification-queue in the 0.2.5 -> 0.8.0 bundle
// bump. orphan-process-group.mjs's `codex-transport` mode is unaffected: it closes
// a different gap (MCP grandchildren of an already-exited leader) that upstream's
// session-lifecycle rewrite does not touch.
//
// Out of scope on purpose: `detached: true` + process-group kill. It would also
// cover MCP children orphaned when the leader exits first (terminateWithTreeKill
// returns "already-exited" and by then the descendants are reparented to PID 1),
// but it changes the signal/session semantics of the provider spawn and belongs in
// its own change with its own observation window. This patch logs that case loudly
// instead of silently accepting it. (orphan-process-group.mjs is that change.)
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
if (!MODE || !F || MODE !== "claude") {
    console.error("usage: orphan-process-guard.mjs claude <agent.js>");
    process.exit(1);
}

const SENTINEL = "[paseo-orphan-guard]";
let src;
try { src = fs.readFileSync(F, "utf8"); }
catch (err) { console.error("read failed: " + String(err)); process.exit(1); }

if (src.includes(SENTINEL)) { console.log("ALREADY"); process.exit(10); }

const L = (...lines) => lines.join("\n");

// ---------------------------------------------------------------- claude ----

const C_OLD_FIELDS = L(
    '        this.query = null;',
    '        this.childProcess = null;',
    '        this.input = null;',
);
const C_NEW_FIELDS = L(
    '        this.query = null;',
    '        this.childProcess = null;',
    '        this.liveChildProcesses = new Set(); // [paseo-orphan-guard]',
    '        this.input = null;',
);

const C_HELPERS = L(
    '    // [paseo-orphan-guard] Ownership of the processes this session spawned.',
    '    // A Set, not a single slot: the SDK can spawn a replacement while the previous',
    '    // process is still alive, and the upstream single handle silently dropped the',
    '    // older one. Every branch that used to be silent now warns at level 40.',
    '    adoptSpawnedChild(child) {',
    '        const pid = child ? child.pid : undefined;',
    '        if (this.closed) {',
    '            this.logger.warn({ agentId: this.agentId, provider: "claude", pid }, "[paseo-orphan-guard] child process arrived after close — terminating it instead of adopting");',
    '            void terminateWithTreeKill(child, { gracefulTimeoutMs: 2000, forceTimeoutMs: 2000 }).catch(() => { });',
    '            return;',
    '        }',
    '        if (!this.liveChildProcesses) {',
    '            this.liveChildProcesses = new Set();',
    '        }',
    '        if (this.childProcess && this.childProcess !== child) {',
    '            this.logger.warn({ agentId: this.agentId, provider: "claude", pid, previousPid: this.childProcess.pid }, "[paseo-orphan-guard] a live child was replaced — the previous one stays tracked so close() still terminates it");',
    '        }',
    '        this.liveChildProcesses.add(child);',
    '        this.childProcess = child;',
    '        const forget = () => {',
    '            if (this.liveChildProcesses) {',
    '                this.liveChildProcesses.delete(child);',
    '            }',
    '            if (this.childProcess === child) {',
    '                this.childProcess = null;',
    '            }',
    '        };',
    '        if (child && typeof child.once === "function") {',
    '            child.once("exit", forget);',
    '        }',
    '    }',
    '    async terminateLiveChildren(reason) {',
    '        const targets = new Set(this.liveChildProcesses || []);',
    '        if (this.childProcess) {',
    '            targets.add(this.childProcess);',
    '        }',
    '        this.liveChildProcesses = new Set();',
    '        this.childProcess = null;',
    '        if (targets.size === 0) {',
    '            // Not a warning: close() ends stdin first, so the claude process usually',
    '            // exits on its own and the exit listener has already emptied the set. The',
    '            // leak this patch is after shows up at adopt/ensureQuery time, not here.',
    '            return;',
    '        }',
    '        if (targets.size > 1) {',
    '            this.logger.warn({ agentId: this.agentId, provider: "claude", reason, count: targets.size }, "[paseo-orphan-guard] more than one live child at termination");',
    '        }',
    '        for (const child of targets) {',
    '            const pid = child ? child.pid : undefined;',
    '            let result;',
    '            try {',
    '                result = await terminateWithTreeKill(child, {',
    '                    gracefulTimeoutMs: 2000,',
    '                    forceTimeoutMs: 2000,',
    '                });',
    '            }',
    '            catch (err) {',
    '                this.logger.warn({ err, agentId: this.agentId, provider: "claude", pid, reason }, "[paseo-orphan-guard] tree-kill threw — the process tree may survive");',
    '                continue;',
    '            }',
    '            if (result === "kill-timeout") {',
    '                this.logger.warn({ pid, agentId: this.agentId, reason }, "Claude process tree did not report exit after SIGKILL");',
    '            }',
    '            else if (result === "already-exited") {',
    '                this.logger.warn({ pid, agentId: this.agentId, provider: "claude", reason }, "[paseo-orphan-guard] leader had already exited — its MCP children were reparented to init and cannot be tree-killed from here");',
    '            }',
    '        }',
    '    }',
);

const C_OLD_CLOSE_KILL = L(
    '        // Terminate the entire process tree (claude + MCP children) to prevent',
    '        // orphan accumulation. The SDK\'s internal cleanup may only kill the',
    '        // direct child process.',
    '        if (this.childProcess) {',
    '            const result = await terminateWithTreeKill(this.childProcess, {',
    '                gracefulTimeoutMs: 2000,',
    '                forceTimeoutMs: 2000,',
    '            });',
    '            if (result === "kill-timeout") {',
    '                this.logger.warn({ pid: this.childProcess.pid, agentId: this.agentId }, "Claude process tree did not report exit after SIGKILL");',
    '            }',
    '            this.childProcess = null;',
    '        }',
);
const C_NEW_CLOSE_KILL = L(
    '        // [paseo-orphan-guard] Terminate every live process tree (claude + MCP children).',
    '        // Was: kill the one tracked handle, silently do nothing when it was absent.',
    '        await this.terminateLiveChildren("session_close");',
);

const C_OLD_ENSURE = L(
    '    async ensureQuery() {',
    '        if (this.query && !this.queryRestartNeeded) {',
    '            return this.query;',
    '        }',
);
const C_NEW_ENSURE = L(
    C_HELPERS,
    '    async ensureQuery() {',
    '        // [paseo-orphan-guard] A closed session must not spawn. close() sets this flag',
    '        // but upstream only honoured it in startTurn()/startQueryPump(); setMode,',
    '        // setModel, listCommands, revertFiles and ensureFreshQuery all reach here and',
    '        // would resurrect a process that nothing owns.',
    '        if (this.closed) {',
    '            this.logger.warn({ agentId: this.agentId, provider: "claude" }, "[paseo-orphan-guard] ensureQuery() on a closed session — refusing to spawn a replacement");',
    '            throw new Error("Claude session is closed");',
    '        }',
    '        if (this.query && !this.queryRestartNeeded) {',
    '            return this.query;',
    '        }',
);

const C_OLD_RESTART_KILL = L(
    '            // Tree-kill the old process tree now that the SDK has cleaned up.',
    '            // If we skip this, MCP children of the previous claude process can',
    '            // survive as orphans when the session spawns a replacement query.',
    '            if (retiredChild) {',
    '                await terminateWithTreeKill(retiredChild, {',
    '                    gracefulTimeoutMs: 2000,',
    '                    forceTimeoutMs: 2000,',
    '                }).catch(() => {',
    '                    /* process may already be dead */',
    '                });',
    '            }',
);
const C_NEW_RESTART_KILL = L(
    '            // [paseo-orphan-guard] Same termination path as close(): every live handle,',
    '            // not just the one retired here. MCP children of a previous claude process',
    '            // used to survive whenever the handle had been overwritten before restart.',
    '            await this.terminateLiveChildren("query_restart");',
);

const C_OLD_ONCHILD = L(
    '            onChildProcess: (child) => {',
    '                this.childProcess = child;',
    '                child.once("exit", (code, signal) => this.handleRuntimeExit(child, code, signal));',
    '            },',
);
const C_NEW_ONCHILD = L(
    '            onChildProcess: (child) => {',
    '                // [paseo-orphan-guard] Register upstream\'s own exit-triggered turn-failure',
    '                // handler FIRST -- adoptSpawnedChild\'s own exit listener also nulls',
    '                // this.childProcess, and handleRuntimeExit\'s guard',
    '                // (`this.childProcess !== child`) would otherwise see that null and skip',
    '                // reporting the crash.',
    '                child.once("exit", (code, signal) => this.handleRuntimeExit(child, code, signal));',
    '                this.adoptSpawnedChild(child);',
    '            },',
);

// ------------------------------------------------------------------ apply ---

const EDITS = [
    ["fields", C_OLD_FIELDS, C_NEW_FIELDS],
    ["close-kill", C_OLD_CLOSE_KILL, C_NEW_CLOSE_KILL],
    ["ensure-query", C_OLD_ENSURE, C_NEW_ENSURE],
    ["restart-kill", C_OLD_RESTART_KILL, C_NEW_RESTART_KILL],
    ["on-child", C_OLD_ONCHILD, C_NEW_ONCHILD],
];

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
