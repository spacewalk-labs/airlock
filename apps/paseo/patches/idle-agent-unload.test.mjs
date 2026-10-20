// [paseo-idle-agent-unload] Behaviour check for the applied patch.
//
//   node idle-agent-unload.test.mjs <candidate agent/agent-manager.js>
//
// The candidate is copied into the installed server tree under a temporary name (relative and bare
// imports only resolve there) and the real AgentManager is driven with stub seats over the real
// AgentStorage in a temporary directory. It measures behaviour, not syntax:
//   ① a seat idle past the threshold is unloaded: out of `agents`, timeline gone, session closed,
//     and its stored record stays `idle` (the state of a seat untouched since a restart) ← the defect
//   ② a recently active seat, a running seat and a seat waiting on a permission all stay loaded
//   ③ closing a loaded seat drops its timeline                                         ← the defect
//   ④ a load waits for an unload in progress (waitForAgentClose)
//   ⑤ minutes = 0 starts no sweep
//   ⑥ closing an unloaded seat records `closed` and tells clients                      ← review 1
//   ⑦ a close that arrives while the unload is still closing the session is not lost  ← review 2
//   ⑧ closing an unloaded seat keeps metadata written after the unload                ← review 2
// Exit 0 = every scenario passed.
import { copyFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";

const F = process.argv[2];
if (!F) { console.error("usage: idle-agent-unload.test.mjs <agent/agent-manager.js candidate>"); process.exit(1); }

const probe = join(dirname(F), ".paseo-idle-unload-behaviour-test.mjs");
let home;
const fail = (message) => { console.error("FAIL: " + message); cleanup(); process.exit(1); };
function cleanup() {
    try { rmSync(probe, { force: true }); } catch { /* best effort */ }
    if (home) { try { rmSync(home, { recursive: true, force: true }); } catch { /* best effort */ } }
}

const MIN = 60000;
const ID = {
    stale: "11111111-2222-4333-8444-000000000001",
    fresh: "11111111-2222-4333-8444-000000000002",
    running: "11111111-2222-4333-8444-000000000003",
    asking: "11111111-2222-4333-8444-000000000004",
    racing: "11111111-2222-4333-8444-000000000005",
    relabel: "11111111-2222-4333-8444-000000000006",
};
const noop = () => {};
const logger = { child: () => logger, info: noop, warn: noop, error: noop, debug: noop, trace: noop };

function seat(id, { lifecycle = "idle", idleMs = 0, now, permissions = 0, closeGate } = {}) {
    const closed = { count: 0 };
    const agent = {
        id, provider: "claude", cwd: "/tmp", lifecycle,
        session: { close: async () => { await closeGate; closed.count += 1; }, describePersistence: () => null },
        config: { provider: "claude", cwd: "/tmp" },
        createdAt: new Date(now - idleMs), updatedAt: new Date(now - idleMs),
        pendingPermissions: new Map(Array.from({ length: permissions }, (_, i) => [`p${i}`, {}])),
        bufferedPermissionResolutions: new Map(), inFlightPermissionResponses: new Set(),
        activeForegroundTurnId: null, activeTurnId: null, activeTurnStartedAt: null,
        foregroundTurnWaiters: new Set(), finalizedForegroundTurnIds: new Set(),
        unsubscribeSession: null, persistence: null, labels: { tag: "before" },
        attention: { requiresAttention: false },
    };
    return { agent, closed };
}

try {
    copyFileSync(F, probe);
    const { AgentManager } = await import(probe);
    const { AgentStorage } = await import(join(dirname(F), "agent-storage.js"));
    home = mkdtempSync(join(tmpdir(), "paseo-idle-unload-"));
    const storage = new AgentStorage(home, logger);
    await storage.initialize();

    // ⑤ off switch
    const off = new AgentManager({ logger, idleAgentUnloadMinutes: 0 });
    if (off.idleAgentUnloadTimer) fail("minutes=0 still started a sweep");

    const m = new AgentManager({ logger, registry: storage, idleAgentUnloadMinutes: 30 });
    if (!m.idleAgentUnloadTimer) fail("default construction did not start the sweep");
    clearInterval(m.idleAgentUnloadTimer);
    const states = [];
    m.subscribe((event) => { if (event.type === "agent_state") states.push(event.agent); });

    const now = Date.now();
    let releaseRacingClose;
    const racingGate = new Promise((resolve) => { releaseRacingClose = resolve; });
    const seats = {
        stale: seat(ID.stale, { idleMs: 31 * MIN, now }),
        fresh: seat(ID.fresh, { idleMs: 5 * MIN, now }),
        running: seat(ID.running, { lifecycle: "running", idleMs: 60 * MIN, now }),
        asking: seat(ID.asking, { idleMs: 60 * MIN, now, permissions: 1 }),
        racing: seat(ID.racing, { idleMs: 60 * MIN, now, closeGate: racingGate }),
        relabel: seat(ID.relabel, { idleMs: 60 * MIN, now }),
    };
    for (const { agent } of Object.values(seats)) {
        await storage.applySnapshot(agent);
        m.agents.set(agent.id, agent);
        m.timelineStore.initialize(agent.id, { items: [{ type: "assistant_message", text: "x".repeat(1000) }] });
    }
    const status = async (id) => (await storage.get(id))?.lastStatus;

    // ① + ④ the stale seat leaves memory; a load waits for the unload
    const pending = m.unloadIdleAgent(ID.stale, now);
    const loadBarrier = m.waitForAgentClose(ID.stale).then(() => m.agents.has(ID.stale));
    if ((await pending) !== true) fail("stale idle seat was not unloaded");
    if ((await loadBarrier) !== false) fail("a load did not wait for the unload in progress");
    if (m.agents.has(ID.stale)) fail("unloaded seat is still in agents");
    if (m.timelineStore.has(ID.stale)) fail("unloaded seat kept its timeline");
    if (seats.stale.closed.count !== 1) fail(`provider session closed ${seats.stale.closed.count} times, expected 1`);
    if ((await status(ID.stale)) !== "idle") fail(`unload changed the stored status to ${await status(ID.stale)}`);

    // ② the sweep leaves the busy seats alone
    m.agents.delete(ID.racing);
    m.agents.delete(ID.relabel);
    const unloaded = await m.unloadIdleAgents(now);
    if (unloaded.length !== 0) fail(`sweep unloaded seats it must keep: ${unloaded.join(",")}`);
    for (const id of [ID.fresh, ID.running, ID.asking]) {
        if (!m.agents.has(id) || !m.timelineStore.has(id)) fail(`seat ${id} was unloaded`);
    }
    m.agents.set(ID.racing, seats.racing.agent);
    m.agents.set(ID.relabel, seats.relabel.agent);

    // ⑥ closing the unloaded seat records closed and tells clients
    await m.closeAgent(ID.stale);
    if ((await status(ID.stale)) !== "closed") fail("closing an unloaded seat did not record closed");
    if (!states.some((agent) => agent.id === ID.stale && agent.lifecycle === "closed")) {
        fail("closing an unloaded seat did not tell clients");
    }

    // ⑦ a close that lands while the unload is still closing the provider session
    const racingUnload = m.unloadIdleAgent(ID.racing, now);
    await new Promise((resolve) => setImmediate(resolve));
    const racingClose = m.closeAgent(ID.racing);
    releaseRacingClose();
    await racingUnload;
    await racingClose;
    if ((await status(ID.racing)) !== "closed") fail(`a close during the unload was lost (status ${await status(ID.racing)})`);

    // ⑧ metadata written after the unload survives the close
    await m.unloadIdleAgent(ID.relabel, now);
    await storage.queueRecordMutation(ID.relabel, (existing) => ({ ...existing, labels: { tag: "after" } }));
    await m.closeAgent(ID.relabel);
    const relabelled = await storage.get(ID.relabel);
    if (relabelled.lastStatus !== "closed") fail("closing the relabelled unloaded seat did not record closed");
    if (relabelled.labels?.tag !== "after") fail(`closing reverted labels written after the unload (${relabelled.labels?.tag})`);

    // ③ a plain close drops the timeline
    await m.closeAgent(ID.fresh);
    if (m.agents.has(ID.fresh)) fail("closed seat is still loaded");
    if (m.timelineStore.has(ID.fresh)) fail("closed seat kept its timeline");
}
catch (error) {
    fail(error?.stack ?? String(error));
}
cleanup();
console.log("OK");
process.exit(0);
