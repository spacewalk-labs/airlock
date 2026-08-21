// [paseo-orphan-guard] idempotent, all-or-nothing patcher (install.sh runs it right
// after the pinned npm install). Two independent targets, one per invocation:
//
//   node orphan-process-guard.mjs claude <.../providers/claude/agent.js>
//   node orphan-process-guard.mjs codex  <.../providers/codex-app-server-agent.js>
//
// Problem: paseo leaks the agent processes it spawns. Upstream tracks exactly one
// live child per session (`this.childProcess` / `this.client`) and kills it in
// close() behind an `if (handle)` guard. Three ways a running process escapes:
//
//   (1) close() sets `closed = true` and nulls the handle -- but neither
//       ensureQuery() (claude) nor connect() (codex) checks that flag. Any
//       control-plane call that lands during or after close (setMode, setModel,
//       listCommands, revertFiles, ensureFreshQuery / a codex reconnect) spawns a
//       REPLACEMENT process onto the already-closed session. Nothing will ever
//       close that session again, so the process runs until the box is rebooted.
//       The same race exists for the in-flight spawn: onChildProcess can fire
//       after close() has already walked past the kill block.
//   (2) a second spawn overwrites the single handle; the first process is dropped
//       on the floor while the handle still looks healthy (so a null-check fix
//       does not catch this one).
//   (3) both of the above are SILENT: the `if (handle)` guard has no else branch,
//       and the surrounding session_close.start/complete lines are logger.trace,
//       which the daemon's info-level logger never emits. close() reports success
//       having killed nothing.
//
// Fix (both providers, same shape):
//   - ownership becomes a Set of live handles, not one slot; every handle in it is
//     terminated at close and at query restart / reconnect,
//   - a closed-session gate on the spawn entry point (ensureQuery / connect) so a
//     dead session cannot give birth,
//   - a late-arrival path: a child that shows up after close is terminated on the
//     spot instead of being stored,
//   - logger.warn (level 40, actually emitted) on every one of those branches,
//     including "there was nothing to kill" -- so the next occurrence is visible
//     instead of inferred.
//
// Out of scope on purpose: `detached: true` + process-group kill. It would also
// cover MCP children orphaned when the leader exits first (terminateWithTreeKill
// returns "already-exited" and by then the descendants are reparented to PID 1),
// but it changes the signal/session semantics of the provider spawn and belongs in
// its own change with its own observation window. This patch logs that case loudly
// instead of silently accepting it.
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
    console.error("usage: orphan-process-guard.mjs <claude|codex> <agent.js>");
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
    '            if (this.childProcess) {',
    '                await terminateWithTreeKill(this.childProcess, {',
    '                    gracefulTimeoutMs: 2000,',
    '                    forceTimeoutMs: 2000,',
    '                }).catch(() => {',
    '                    /* process may already be dead */',
    '                });',
    '                this.childProcess = null;',
    '            }',
);
const C_NEW_RESTART_KILL = L(
    '            // [paseo-orphan-guard] Same termination path as close(): every live handle,',
    '            // not just the newest one. MCP children of a previous claude process used to',
    '            // survive here whenever the handle had been overwritten.',
    '            await this.terminateLiveChildren("query_restart");',
);

const C_OLD_ONCHILD = L(
    '            onChildProcess: (child) => {',
    '                this.childProcess = child;',
    '            },',
);
const C_NEW_ONCHILD = L(
    '            onChildProcess: (child) => {',
    '                this.adoptSpawnedChild(child); // [paseo-orphan-guard]',
    '            },',
);

// ----------------------------------------------------------------- codex ----

const K_OLD_FIELDS = L(
    '        this.currentThreadId = null;',
    '        this.currentTurnId = null;',
    '        this.client = null;',
    '        this.subscribers = new Set();',
);
const K_NEW_FIELDS = L(
    '        this.currentThreadId = null;',
    '        this.currentTurnId = null;',
    '        this.client = null;',
    '        this.sessionClosed = false; // [paseo-orphan-guard]',
    '        this.liveAppServerClients = new Set(); // [paseo-orphan-guard]',
    '        this.subscribers = new Set();',
);

const K_HELPERS = L(
    '    // [paseo-orphan-guard] Same defect as the claude provider: one `this.client` slot,',
    '    // an `if (this.client)` guard in close() with no else branch, and no closed-session',
    '    // gate on connect() — so an app-server spawned during or after close outlives the',
    '    // session with nobody holding its handle.',
    '    trackAppServerClient(client) {',
    '        if (!this.liveAppServerClients) {',
    '            this.liveAppServerClients = new Set();',
    '        }',
    '        this.liveAppServerClients.add(client);',
    '    }',
    '    async disposeLiveAppServerClients(reason) {',
    '        const targets = new Set(this.liveAppServerClients || []);',
    '        if (this.client) {',
    '            targets.add(this.client);',
    '        }',
    '        this.liveAppServerClients = new Set();',
    '        if (targets.size === 0) {',
    '            // Not a warning: a session that was created but never connected has nothing',
    '            // to dispose, and that is the common case (close() is idempotent too).',
    '            return;',
    '        }',
    '        if (targets.size > 1) {',
    '            this.logger.warn({ agentId: this.agentId, provider: "codex", reason, count: targets.size }, "[paseo-orphan-guard] more than one live app-server client at disposal");',
    '        }',
    '        for (const client of targets) {',
    '            try {',
    '                await client.dispose();',
    '            }',
    '            catch (err) {',
    '                this.logger.warn({ err, agentId: this.agentId, provider: "codex", reason }, "[paseo-orphan-guard] app-server dispose failed — the process tree may survive");',
    '            }',
    '        }',
    '    }',
);

const K_OLD_CONNECT = L(
    '    async connect() {',
    '        if (this.connected)',
    '            return;',
    '        const child = await this.spawnAppServer();',
    '        this.client = new CodexAppServerClient(child, this.logger, () => this.traceContext());',
    '        this.client.setNotificationHandler((method, params) => this.handleNotification(method, params));',
);
const K_NEW_CONNECT = L(
    K_HELPERS,
    '    async connect() {',
    '        if (this.connected)',
    '            return;',
    '        // [paseo-orphan-guard] A closed session must not spawn an app-server.',
    '        if (this.sessionClosed) {',
    '            this.logger.warn({ agentId: this.agentId, provider: "codex" }, "[paseo-orphan-guard] connect() on a closed session — refusing to spawn an app-server");',
    '            throw new Error("Codex session is closed");',
    '        }',
    '        // A stale client here means a previous connect left a live app-server behind',
    '        // (connected === false but the handle is set). Dispose it before replacing it.',
    '        if (this.client || (this.liveAppServerClients && this.liveAppServerClients.size > 0)) {',
    '            this.logger.warn({ agentId: this.agentId, provider: "codex" }, "[paseo-orphan-guard] reconnecting over a live app-server client — disposing the previous one");',
    '            await this.disposeLiveAppServerClients("reconnect");',
    '            this.client = null;',
    '        }',
    '        const child = await this.spawnAppServer();',
    '        this.client = new CodexAppServerClient(child, this.logger, () => this.traceContext());',
    '        this.trackAppServerClient(this.client);',
    '        // The spawn above is awaited, so close() can have run in the meantime.',
    '        if (this.sessionClosed) {',
    '            this.logger.warn({ agentId: this.agentId, provider: "codex", pid: child ? child.pid : undefined }, "[paseo-orphan-guard] app-server arrived after close — disposing it immediately");',
    '            await this.disposeLiveAppServerClients("late_arrival");',
    '            this.client = null;',
    '            throw new Error("Codex session is closed");',
    '        }',
    '        this.client.setNotificationHandler((method, params) => this.handleNotification(method, params));',
);

// connect() cleans up after a failed spawn by calling its own close(), which now
// raises the closed flag. Without this edit a single transient spawn failure would
// brick the session: every later connect() would refuse. Restore the flag there —
// that path is internal cleanup, not a session close. (The late-arrival throw added
// above is raised before this try block, so it does not pass through here.)
const K_OLD_CONNECT_FAIL = L(
    '        catch (error) {',
    '            try {',
    '                await this.close();',
    '            }',
    '            catch (closeError) {',
    '                this.logger.warn({ err: closeError, connectError: error }, "Failed to close Codex app-server after connection failure");',
    '            }',
    '            throw error;',
    '        }',
);
const K_NEW_CONNECT_FAIL = L(
    '        catch (error) {',
    '            try {',
    '                await this.close();',
    '            }',
    '            catch (closeError) {',
    '                this.logger.warn({ err: closeError, connectError: error }, "Failed to close Codex app-server after connection failure");',
    '            }',
    '            // [paseo-orphan-guard] The close() above is cleanup after a failed spawn, not',
    '            // a session close. Leaving the flag raised would refuse every later retry.',
    '            this.sessionClosed = false;',
    '            throw error;',
    '        }',
);

const K_OLD_CLOSE = L(
    '        if (this.client) {',
    '            await this.client.dispose();',
    '        }',
    '        this.client = null;',
    '        this.connected = false;',
    '        this.currentThreadId = null;',
    '        this.currentTurnId = null;',
);
const K_NEW_CLOSE = L(
    '        // [paseo-orphan-guard] Flag first (connect() may be mid-spawn), then dispose every',
    '        // live app-server client — not just the one currently in this.client.',
    '        this.sessionClosed = true;',
    '        await this.disposeLiveAppServerClients("session_close");',
    '        this.client = null;',
    '        this.connected = false;',
    '        this.currentThreadId = null;',
    '        this.currentTurnId = null;',
);

// ------------------------------------------------------------------ apply ---

const EDITS = MODE === "claude"
    ? [
        ["fields", C_OLD_FIELDS, C_NEW_FIELDS],
        ["close-kill", C_OLD_CLOSE_KILL, C_NEW_CLOSE_KILL],
        ["ensure-query", C_OLD_ENSURE, C_NEW_ENSURE],
        ["restart-kill", C_OLD_RESTART_KILL, C_NEW_RESTART_KILL],
        ["on-child", C_OLD_ONCHILD, C_NEW_ONCHILD],
    ]
    : [
        ["fields", K_OLD_FIELDS, K_NEW_FIELDS],
        ["connect", K_OLD_CONNECT, K_NEW_CONNECT],
        ["connect-failure", K_OLD_CONNECT_FAIL, K_NEW_CONNECT_FAIL],
        ["close", K_OLD_CLOSE, K_NEW_CLOSE],
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
