// SPDX-License-Identifier: AGPL-3.0-only
// [paseo-idle-agent-unload] idempotent, all-or-nothing patcher for @getpaseo/server agent/agent-manager.js.
//
// Upstream keeps every loaded seat — and the full conversation timeline of every seat it ever
// loaded — in daemon memory. Nothing unloads an idle seat, and a plain close keeps the timeline
// (only archive drops it). On a busy box (~275 seats a day) the V8 heap followed the
// timeline row count up to the ~4GB default ceiling and the daemon died of "JavaScript heap out
// of memory" three times in four days (2026-10-16 21:51, 10-17 09:30, 10-20 07:36).
//
// Two changes, both reuse paths upstream already has:
//   1. A seat idle for PASEO_IDLE_UNLOAD_MINUTES (default 30; 0 = off) is unloaded: provider
//      session closed, timeline dropped. Its stored record is NOT touched — it stays `idle`, which
//      is exactly the state of a seat nobody has touched since a daemon restart. The next send,
//      timeline fetch or schedule tick goes through ensureAgentLoaded and resumes it from the
//      provider's own history, the same path every seat takes after a restart. Its id is kept so
//      an explicit close of an unloaded seat still records `closed` on the current stored record;
//      the id is dropped when the seat is loaded again, archived or deleted. The unload runs in
//      the per-seat lifecycle queue, so a concurrent close or load waits for it.
//   2. closeAgentRuntime also drops the timeline. A closed seat is no longer in `agents`, so (1)
//      never sees it; reopening it resumes and re-reads provider history.
//
// Contract: argv[2] = server agent/agent-manager.js.
//   exit  0 = candidate written to <target>.paseo-new.mjs
//   exit 10 = already patched (sentinel)
//   exit 20 = an anchor is missing or duplicated; writes nothing
//   exit  1 = usage / IO / patch logic error
import fs from "node:fs";

const target = process.argv[2];
if (!target) {
    console.error("usage: idle-agent-unload.mjs <server agent/agent-manager.js>");
    process.exit(1);
}

const SENTINEL = "[paseo-idle-agent-unload]";
const lines = (...items) => items.join("\n");

let source;
try {
    source = fs.readFileSync(target, "utf8");
}
catch (error) {
    console.error(`read failed (${target}): ${String(error)}`);
    process.exit(1);
}
if (source.includes(SENTINEL)) {
    console.log("ALREADY");
    process.exit(10);
}

// ── 1a. start the sweep at the end of the constructor (after this.logger exists) ──
const CTOR_ANCHOR = lines(
    "        this.updateProviderRegistry({",
    "            providerDefinitions: options.providerDefinitions ?? {},",
    "            clients: options.clients ?? {},",
    "        });",
    "    }",
    "    configurePaseoTools(options) {",
);
const CTOR_REPLACEMENT = lines(
    "        this.updateProviderRegistry({",
    "            providerDefinitions: options.providerDefinitions ?? {},",
    "            clients: options.clients ?? {},",
    "        });",
    `        // ${SENTINEL} Idle seats leave memory; the next touch resumes them from provider history.`,
    "        this.startIdleAgentUnload(options);",
    "    }",
    "    configurePaseoTools(options) {",
);

// ── 1b. the unload itself, next to the other retained-state helpers ──
const METHOD_ANCHOR = "    discardRetainedAgentState(agentId) {";
const METHOD_REPLACEMENT = lines(
    `    // ${SENTINEL}`,
    "    startIdleAgentUnload(options) {",
    "        // Ids only: an explicit close of an unloaded seat records `closed` on the current stored record.",
    "        this.idleUnloadedAgentIds = new Set();",
    "        const minutes = Number(options?.idleAgentUnloadMinutes ?? process.env.PASEO_IDLE_UNLOAD_MINUTES ?? 30);",
    "        if (!Number.isFinite(minutes) || minutes <= 0) {",
    "            return;",
    "        }",
    "        this.idleAgentUnloadMs = minutes * 60000;",
    "        this.idleAgentUnloadTimer = setInterval(() => {",
    "            this.unloadIdleAgents().catch((error) => {",
    '                this.logger.warn({ err: error }, "agent.manager.idle_unload.failed");',
    "            });",
    "        }, Math.min(this.idleAgentUnloadMs, 5 * 60000));",
    "        this.idleAgentUnloadTimer.unref?.();",
    "    }",
    "    isIdleUnloadable(agent, nowMs) {",
    "        return Boolean(agent) &&",
    '            agent.lifecycle === "idle" &&',
    "            !this.hasInFlightRun(agent.id) &&",
    "            agent.pendingPermissions.size === 0 &&",
    "            nowMs - agent.updatedAt.getTime() >= this.idleAgentUnloadMs;",
    "    }",
    "    async unloadIdleAgents(nowMs = Date.now()) {",
    "        for (const agentId of this.idleUnloadedAgentIds) {",
    "            if (this.agents.has(agentId)) {",
    "                this.idleUnloadedAgentIds.delete(agentId);",
    "            }",
    "        }",
    "        const unloaded = [];",
    "        for (const agent of [...this.agents.values()]) {",
    "            if (this.isIdleUnloadable(agent, nowMs) && (await this.unloadIdleAgent(agent.id, nowMs))) {",
    "                unloaded.push(agent.id);",
    "            }",
    "        }",
    "        if (unloaded.length > 0) {",
    '            this.logger.info({ count: unloaded.length, agentIds: unloaded }, "agent.manager.idle_unload");',
    "        }",
    "        return unloaded;",
    "    }",
    "    unloadIdleAgent(agentId, nowMs = Date.now()) {",
    "        // The per-seat lifecycle queue orders it against close and load (waitForAgentClose awaits it).",
    "        return this.runLifecycleMutation(agentId, async () => {",
    "            if (!this.isIdleUnloadable(this.agents.get(agentId), nowMs)) {",
    "                return false;",
    "            }",
    "            await this.drainSessionEvents(agentId);",
    "            const agent = this.agents.get(agentId);",
    "            if (!this.isIdleUnloadable(agent, nowMs)) {",
    "                return false;",
    "            }",
    "            // No persist and no emit: the stored record stays idle, as after a daemon restart.",
    '            this.prepareAgentForClosure(agent, "agent unloaded while idle");',
    "            this.idleUnloadedAgentIds.add(agentId);",
    "            try {",
    "                await agent.session.close();",
    "            }",
    "            catch (error) {",
    '                this.logger.warn({ err: error, agentId }, "agent.manager.idle_unload.session_close_failed");',
    "            }",
    "            this.timelineStore.delete(agentId);",
    "            this.providerSubagents.deleteParent(agentId);",
    "            return true;",
    "        });",
    "    }",
    "    async closeIdleUnloadedAgent(agentId) {",
    "        this.idleUnloadedAgentIds.delete(agentId);",
    "        const stored = await this.registry?.get(agentId);",
    '        if (!stored || stored.archivedAt || stored.lastStatus === "closed") {',
    "            return;",
    "        }",
    "        // Mutate the record as it is now, so metadata written after the unload survives.",
    "        let closedRecord = null;",
    "        await this.registry.queueRecordMutation(agentId, (existing) => {",
    '            closedRecord = { ...(existing ?? stored), lastStatus: "closed" };',
    "            return closedRecord;",
    "        });",
    "        this.dispatchStoredAgentState(closedRecord);",
    "    }",
    METHOD_ANCHOR,
    "        this.idleUnloadedAgentIds?.delete(agentId);",
);

// ── 1c. an explicit close of an unloaded seat records `closed` from the kept snapshot ──
const CLOSE_CMD_ANCHOR = lines(
    "            if (this.agents.has(agentId))",
    "                await this.closeAgentRuntime(agentId);",
);
const CLOSE_CMD_REPLACEMENT = lines(
    CLOSE_CMD_ANCHOR,
    `            // ${SENTINEL} An idle-unloaded seat is not in agents; close it from its snapshot.`,
    "            else if (this.idleUnloadedAgentIds?.has(agentId))",
    "                await this.closeIdleUnloadedAgent(agentId);",
);

// ── 2. a closed seat drops its timeline too ──
const CLOSE_ANCHOR = lines(
    "        this.emitClosedAgent(closedAgent, { persist: false });",
    "        this.logger.trace({",
);
const CLOSE_REPLACEMENT = lines(
    "        this.emitClosedAgent(closedAgent, { persist: false });",
    `        // ${SENTINEL} Reopening resumes and re-reads provider history; nothing reads a closed timeline.`,
    "        this.timelineStore.delete(agentId);",
    "        this.logger.trace({",
);

function occurrences(haystack, needle) {
    let count = 0;
    for (let at = haystack.indexOf(needle); at >= 0; at = haystack.indexOf(needle, at + needle.length)) {
        count += 1;
    }
    return count;
}

const edits = [
    { name: "constructor", anchor: CTOR_ANCHOR, replacement: CTOR_REPLACEMENT },
    { name: "retained-state helpers", anchor: METHOD_ANCHOR, replacement: METHOD_REPLACEMENT },
    { name: "closeAgent", anchor: CLOSE_CMD_ANCHOR, replacement: CLOSE_CMD_REPLACEMENT },
    { name: "closeAgentRuntime", anchor: CLOSE_ANCHOR, replacement: CLOSE_REPLACEMENT },
];
let candidate = source;
for (const edit of edits) {
    const found = occurrences(candidate, edit.anchor);
    if (found !== 1) {
        console.error(`SKIP: ${edit.name} anchor missing or duplicated (count=${found})`);
        process.exit(20);
    }
    candidate = candidate.replace(edit.anchor, () => edit.replacement);
}
if (occurrences(candidate, SENTINEL) !== 4) {
    console.error("replacement failed: expected four sentinels");
    process.exit(1);
}

try {
    fs.writeFileSync(`${target}.paseo-new.mjs`, candidate);
}
catch (error) {
    console.error(`candidate write failed: ${String(error)}`);
    process.exit(1);
}
console.log("PATCHED");
process.exit(0);
