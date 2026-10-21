// [paseo-reload-timeline-replacement] Behaviour check for the applied patch.
//
//   node reload-timeline-replacement.test.mjs <candidate agent/agent-manager.js>
//
// The candidate is copied into the installed server tree under a temporary name (relative and bare
// imports only resolve there) and the real AgentManager hydrates stub seats from stub provider
// history. It measures behaviour, not syntax:
//   ① a seat loaded again (history not primed) tells viewers to refetch: one timeline_replacement,
//     carrying the epoch the rebuilt rows live under                                    ← the defect
//   ② the replacement comes after hydration, so the epoch it names is final
//   ③ hydrating an already primed seat sends nothing (fetches of a loaded seat stay quiet)
//   ④ a forced hydration (rewind) sends nothing from here; rewind dispatches its own
// Exit 0 = every scenario passed.
import { copyFileSync, rmSync } from "node:fs";
import { join, dirname } from "node:path";

const F = process.argv[2];
if (!F) { console.error("usage: reload-timeline-replacement.test.mjs <agent/agent-manager.js candidate>"); process.exit(1); }

const probe = join(dirname(F), ".paseo-reload-timeline-replacement-test.mjs");
const fail = (message) => { console.error("FAIL: " + message); cleanup(); process.exit(1); };
function cleanup() {
    try { rmSync(probe, { force: true }); } catch { /* best effort */ }
}

const noop = () => {};
const logger = { child: () => logger, info: noop, warn: noop, error: noop, debug: noop, trace: noop };

function seat(id, historyPrimed) {
    return {
        id, provider: "claude", cwd: "/tmp", lifecycle: "idle", historyPrimed,
        session: {
            close: async () => {},
            describePersistence: () => null,
            async *streamHistory() {
                yield { type: "timeline", item: { type: "user_message", text: "hello" } };
                yield { type: "timeline", item: { type: "assistant_message", text: "hi" } };
            },
        },
        config: { provider: "claude", cwd: "/tmp" },
        createdAt: new Date(), updatedAt: new Date(),
        pendingPermissions: new Map(), bufferedPermissionResolutions: new Map(),
        inFlightPermissionResponses: new Set(), foregroundTurnWaiters: new Set(),
        finalizedForegroundTurnIds: new Set(), labels: {}, attention: { requiresAttention: false },
    };
}

try {
    copyFileSync(F, probe);
    const { AgentManager } = await import(probe);
    const m = new AgentManager({ logger, idleAgentUnloadMinutes: 0 });
    const replacements = [];
    m.subscribe((event) => { if (event.type === "timeline_replacement") replacements.push(event); });

    // ① + ② a reloaded seat: fresh store, history not primed
    const reloaded = seat("22222222-3333-4444-8555-000000000001", false);
    m.agents.set(reloaded.id, reloaded);
    m.timelineStore.initialize(reloaded.id, { timestamp: new Date().toISOString() });
    await m.hydrateTimelineFromProvider(reloaded.id, { broadcast: false });
    if (replacements.length !== 1) fail(`reloaded seat sent ${replacements.length} timeline_replacement, expected 1`);
    const epoch = m.timelineStore.getEpoch(reloaded.id);
    if (replacements[0].agentId !== reloaded.id || replacements[0].epoch !== epoch) {
        fail("timeline_replacement does not name the reloaded seat and its current epoch");
    }
    if (m.timelineStore.getRows(reloaded.id).length !== 2) fail("hydration did not rebuild the history rows");

    // ③ the same seat again: already primed
    await m.hydrateTimelineFromProvider(reloaded.id, { broadcast: false });
    if (replacements.length !== 1) fail("hydrating an already primed seat sent another timeline_replacement");

    // ④ forced hydration is rewind's business
    await m.hydrateTimelineFromProvider(reloaded.id, { force: true, broadcast: false, broadcastTimeline: false });
    if (replacements.length !== 1) fail("forced hydration sent a timeline_replacement from this patch");
}
catch (error) {
    fail(error?.stack ?? String(error));
}
cleanup();
console.log("OK");
process.exit(0);
