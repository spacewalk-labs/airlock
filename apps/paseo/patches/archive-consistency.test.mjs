// SPDX-License-Identifier: AGPL-3.0-only
// Behavior check for archive-consistency.mjs.
//
// Normal use:
//   node archive-consistency.test.mjs <patched-session.js> <patched-agent-updates-service.js>
// Self-test:
//   node archive-consistency.test.mjs --self-test <archive-consistency.mjs>
//
// The check drives both sides of the delivered contract: the initial
// live+persisted snapshot and the subsequent stored/live agent_update stream.
// It does not treat the patch sentinel as a substitute for behavior.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const SENTINEL = "[paseo-archive-consistency]";

// These are the official 0.8.0 method shapes in a compact, executable fixture.
// The fixture stays independent of patcher literals so an anchor edit cannot
// silently update the positive test with it.
const SYNTHETIC_SESSION_PRISTINE = `export class Session {
    async buildProjectPlacementForWorkspaceId(workspaceId) {
        const workspace = await this.workspaceRegistry.get(workspaceId);
        if (!workspace)
            return null;
        const project = await this.projectRegistry.get(workspace.projectId);
        if (!project)
            return null;
        return this.buildProjectPlacementForWorkspace(workspace, project);
    }
    /**
     * Main entry point for processing session messages
     */
    async listAgentPayloads(filter) {
        const includeArchived = filter?.includeArchived === true;
        const labelEntries = filter?.labels ? Object.entries(filter.labels) : [];
        const agentSnapshots = this.agentManager.listAgents();
        const liveAgents = await Promise.all(agentSnapshots.map((agent) => this.buildAgentPayload(agent)));
        const registryRecords = await this.agentStorage.list();
        const liveIds = new Set(agentSnapshots.map((a) => a.id));
        const registeredProviderIds = new Set(this.providerSnapshotManager.listRegisteredProviderIds());
        const persistedAgents = registryRecords
            .filter((record) => !liveIds.has(record.id) && !record.internal)
            .filter((record) => includeArchived || !record.archivedAt)
            .filter((record) => labelEntries.every(([key, value]) => record.labels?.[key] === value))
            .filter((record) => filter?.includeUnavailablePersisted === true ||
            isStoredAgentProviderAvailable(record, registeredProviderIds))
            .map((record) => this.buildStoredAgentPayload(record, registeredProviderIds));
        let agents = [...liveAgents, ...persistedAgents];
        agents = agents.filter((agent) => this.isProviderVisibleToClient(agent.provider));
        if (!includeArchived) {
            agents = agents.filter((agent) => !agent.archivedAt);
        }
        if (labelEntries.length > 0) {
            agents = agents.filter((agent) => labelEntries.every(([key, value]) => agent.labels[key] === value));
        }
        return agents;
    }
    async resolveAgentIdentifier(identifier) {
        return identifier;
    }
    async listFetchAgentsEntries(request) {
        const filter = request.filter;
        const placementByWorkspaceId = new Map();
        const getPlacement = (workspaceId) => {
            if (!workspaceId) {
                return Promise.resolve(null);
            }
            const existing = placementByWorkspaceId.get(workspaceId);
            if (existing) {
                return existing;
            }
            const placementPromise = this.buildProjectPlacementForWorkspaceId(workspaceId);
            placementByWorkspaceId.set(workspaceId, placementPromise);
            return placementPromise;
        };
        return getPlacement(request.workspaceId);
    }
}
`;

const SYNTHETIC_UPDATES_PRISTINE = `
function agentUpdateTargetId(update) {
    return update.kind === "remove" ? update.agentId : update.agent.id;
}
export function createAgentUpdatesService(deps) {
    let subscription = null;
    const sequence = (sub, payload, agent, project, agentId) =>
        deps.sequenceAgentUpdate(payload, agent, project, agentId, sub.syncEnabled === true);
    function bufferOrEmit(sub, payload) {
        if (payload.kind === "upsert" && !deps.isProviderVisibleToClient(payload.agent.provider)) {
            return;
        }
        if (sub.isBootstrapping) {
            sub.pendingUpdatesByAgentId.set(agentUpdateTargetId(payload), payload);
            return;
        }
        deps.emit({ type: "agent_update", payload });
    }
    function beginSubscription(input) {
        subscription = {
            subscriptionId: input.subscriptionId,
            syncEnabled: input.syncEnabled,
            filter: input.filter,
            isBootstrapping: true,
            pendingUpdatesByAgentId: new Map(),
        };
    }
    function flushBootstrapped(subscriptionId) {
        if (!subscription || subscription.subscriptionId !== subscriptionId || !subscription.isBootstrapping) {
            return;
        }
        subscription.isBootstrapping = false;
        const pending = Array.from(subscription.pendingUpdatesByAgentId.values());
        subscription.pendingUpdatesByAgentId.clear();
        for (const payload of pending) {
            deps.emit({ type: "agent_update", payload });
        }
    }
    async function includesLiveAgent(agent) {
        const activeSubscription = subscription;
        if (!activeSubscription)
            return false;
        const payload = await deps.enrichAgentPayload(toAgentPayload(agent));
        if (subscription !== activeSubscription || !deps.isProviderVisibleToClient(payload.provider)) {
            return false;
        }
        const project = payload.workspaceId
            ? await deps.buildProjectPlacementForWorkspaceId(payload.workspaceId)
            : null;
        return (subscription === activeSubscription &&
            project !== null &&
            matchesAgentUpdatesFilter({
                agent: payload,
                project,
                filter: activeSubscription.filter,
            }));
    }
    async function emitStoredRecord(record) {
        const payload = deps.buildStoredAgentPayload(record);
        const sub = subscription;
        if (!sub) {
            return payload;
        }
        const project = payload.workspaceId
            ? await deps.buildProjectPlacementForWorkspaceId(payload.workspaceId)
            : null;
        if (!project) {
            bufferOrEmit(sub, sequence(sub, { kind: "remove", agentId: payload.id }, null, null, payload.id));
            return payload;
        }
        const matches = matchesAgentUpdatesFilter({ agent: payload, project, filter: sub.filter });
        bufferOrEmit(sub, sequence(sub, matches
            ? { kind: "upsert", agent: payload, project }
            : { kind: "remove", agentId: payload.id }, payload, project, payload.id));
        return payload;
    }
    async function emitLiveAgentUpdate(payload) {
        try {
            const sub = subscription;
            payload = await deps.enrichAgentPayload(payload);
            if (sub) {
                const project = payload.workspaceId
                    ? await deps.buildProjectPlacementForWorkspaceId(payload.workspaceId)
                    : null;
                if (!project) {
                    bufferOrEmit(sub, sequence(sub, { kind: "remove", agentId: payload.id }, null, null, payload.id));
                }
                else {
                    const matches = matchesAgentUpdatesFilter({ agent: payload, project, filter: sub.filter });
                    bufferOrEmit(sub, sequence(sub, matches
                        ? { kind: "upsert", agent: payload, project }
                        : { kind: "remove", agentId: payload.id }, payload, project, payload.id));
                }
            }
            if (payload.workspaceId) {
                await deps.emitWorkspaceUpdateForWorkspaceId(payload.workspaceId);
            }
        }
        catch (error) {
            deps.logger.error({ err: error }, "Failed to emit agent update");
        }
    }
    function forwardLiveAgent(agent) {
        if (!subscription) {
            return Promise.resolve();
        }
        const payload = toAgentPayload(agent);
        return emitLiveAgentUpdate(payload);
    }
    return { beginSubscription, flushBootstrapped, includesLiveAgent, emitStoredRecord, forwardLiveAgent };
}
//# sourceMappingURL=agent-updates-service.js.map
`;

function extractBetween(source, startMarker, endMarker, label) {
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start + startMarker.length);
    assert.ok(start >= 0 && end > start, `${label} extraction failed`);
    return source.slice(start, end);
}

function extractListAgentPayloads(source) {
    assert.ok(source.includes(SENTINEL), "session target is not patched: sentinel missing");
    return extractBetween(
        source,
        "    async listAgentPayloads(filter) {",
        "\n    async resolveAgentIdentifier(",
        "listAgentPayloads",
    );
}

function extractPlacementMethod(source) {
    return extractBetween(
        source,
        "    async buildProjectPlacementForWorkspaceId(",
        "\n    /**",
        "buildProjectPlacementForWorkspaceId",
    );
}

function buildSessionHarness(source, input) {
    const placementMethod = extractPlacementMethod(source);
    const listMethod = extractListAgentPayloads(source);
    const Harness = new Function("isStoredAgentProviderAvailable", `
        return class Harness {
            constructor(input) {
                this.liveAgents = input.liveAgents;
                this.persistedAgents = input.persistedAgents;
                this.workspaceRecords = input.workspaceRecords;
                this.projects = new Map([["project-active", { projectId: "project-active" }],
                    ["project-archived", { projectId: "project-archived" }]]);
                this.workspaceListCalls = 0;
                this.agentManager = { listAgents: () => this.liveAgents };
                this.agentStorage = { list: async () => this.persistedAgents };
                this.providerSnapshotManager = {
                    listRegisteredProviderIds: () => new Set(["claude"]),
                };
                this.workspaceRegistry = {
                    list: async () => {
                        this.workspaceListCalls += 1;
                        return this.workspaceRecords;
                    },
                    get: async (workspaceId) => this.workspaceRecords.find((record) => record.workspaceId === workspaceId) ?? null,
                };
                this.projectRegistry = {
                    get: async (projectId) => this.projects.get(projectId) ?? null,
                };
            }
            async buildAgentPayload(agent) {
                return { ...agent, projectedFrom: "live" };
            }
            buildStoredAgentPayload(record) {
                return { ...record, projectedFrom: "persisted" };
            }
            buildProjectPlacementForWorkspace(workspace, project) {
                return { projectKey: project.projectId, workspaceId: workspace.workspaceId };
            }
            isProviderVisibleToClient() {
                return true;
            }
${placementMethod}
${listMethod}
        };
    `)(() => true);
    return new Harness(input);
}

function agent(id, workspaceId, extra = {}) {
    const result = { id, provider: "claude", archivedAt: null, ...extra };
    if (workspaceId !== undefined) {
        result.workspaceId = workspaceId;
    }
    return result;
}

async function runSnapshotChecks(source) {
    const liveAgents = [
        agent("live-active", "ws-active"),
        agent("live-archived-workspace", "ws-archived"),
        agent("live-null", null),
        agent("live-undefined", undefined),
        agent("live-unknown", "ws-missing"),
        agent("live-self-archived", "ws-active", { archivedAt: "2026-09-23T00:00:00.000Z" }),
    ];
    const persistedAgents = [
        agent("persisted-active", "ws-active"),
        agent("persisted-archived-workspace", "ws-archived"),
        agent("persisted-null", null),
        agent("persisted-unknown", "ws-missing"),
        agent("persisted-self-archived", "ws-active", { archivedAt: "2026-09-23T00:00:00.000Z" }),
        // The upstream merge excludes persisted records whose id is already live.
        agent("live-active", "ws-archived"),
    ];
    const workspaceRecords = [
        { workspaceId: "ws-active", projectId: "project-active", archivedAt: null },
        { workspaceId: "ws-archived", projectId: "project-archived", archivedAt: "2026-09-23T00:00:00.000Z" },
    ];
    const input = { liveAgents, persistedAgents, workspaceRecords };

    const defaultHarness = buildSessionHarness(source, input);
    const defaultResult = await defaultHarness.listAgentPayloads();
    assert.deepEqual(
        defaultResult.map((item) => item.id),
        ["live-active", "live-null", "live-undefined", "live-unknown",
            "persisted-active", "persisted-null", "persisted-unknown"],
        "default snapshot hides archived-workspace and self-archived agents after merge",
    );
    assert.equal(defaultResult.find((item) => item.id === "live-active").projectedFrom, "live");
    assert.equal(defaultResult.find((item) => item.id === "persisted-active").projectedFrom, "persisted");
    assert.equal(defaultHarness.workspaceListCalls, 1, "default snapshot reads workspace registry once");

    const archivedHarness = buildSessionHarness(source, input);
    const archivedResult = await archivedHarness.listAgentPayloads({ includeArchived: true });
    assert.deepEqual(
        archivedResult.map((item) => item.id),
        ["live-active", "live-archived-workspace", "live-null", "live-undefined", "live-unknown",
            "live-self-archived", "persisted-active", "persisted-archived-workspace",
            "persisted-null", "persisted-unknown", "persisted-self-archived"],
        "includeArchived=true preserves upstream merged results",
    );
    assert.equal(archivedHarness.workspaceListCalls, 0, "includeArchived=true does not apply workspace filtering");

    // The placement helper has an explicit archive-filter flag. Omitted callers
    // retain the old placement behavior; list/subscription callers pass false.
    const placementDefault = await defaultHarness.buildProjectPlacementForWorkspaceId("ws-archived");
    assert.ok(placementDefault, "legacy placement callers still resolve archived workspace");
    assert.equal(await defaultHarness.buildProjectPlacementForWorkspaceId("ws-archived", false), null);
    assert.ok(await defaultHarness.buildProjectPlacementForWorkspaceId("ws-archived", true));
}

function buildUpdatesFactory(source) {
    assert.ok(source.includes(SENTINEL), "agent-updates target is not patched: sentinel missing");
    const body = extractBetween(
        source,
        "export function createAgentUpdatesService(deps) {",
        "\n//# sourceMappingURL",
        "createAgentUpdatesService",
    ).replace("export function", "function");
    return new Function("toAgentPayload", "agentUpdateTargetId", "matchesAgentUpdatesFilter", `${body}\nreturn createAgentUpdatesService;`)(
        (agentValue) => ({ ...agentValue }),
        (update) => update.kind === "remove" ? update.agentId : update.agent.id,
        ({ agent: agentValue, filter }) => filter?.includeArchived === true || !agentValue.archivedAt,
    );
}

async function runUpdateScenario(source, includeArchived) {
    const placements = [];
    const events = [];
    const workspaceUpdates = [];
    const service = buildUpdatesFactory(source)({
        emit: (message) => events.push(message),
        enrichAgentPayload: async (payload) => ({ ...payload }),
        buildStoredAgentPayload: (record) => ({ ...record }),
        isProviderVisibleToClient: () => true,
        buildProjectPlacementForWorkspaceId: async (workspaceId, requestedIncludeArchived) => {
            placements.push({ workspaceId, requestedIncludeArchived });
            if (workspaceId === "ws-active") {
                return { projectKey: "project-active" };
            }
            if (workspaceId === "ws-archived" && requestedIncludeArchived === true) {
                return { projectKey: "project-archived" };
            }
            return null;
        },
        sequenceAgentUpdate: (payload) => payload,
        emitWorkspaceUpdateForWorkspaceId: async (workspaceId) => workspaceUpdates.push(workspaceId),
        logger: { error: () => {} },
    });
    service.beginSubscription({
        subscriptionId: "sub",
        syncEnabled: false,
        filter: { includeArchived },
    });
    const flushOne = () => {
        service.flushBootstrapped("sub");
        assert.equal(events.length, 1, `includeArchived=${includeArchived}: expected one agent_update`);
        const event = events.pop();
        return event.payload;
    };
    const storedArchived = await service.emitStoredRecord(agent("stored-archived", "ws-archived"));
    assert.equal(storedArchived.id, "stored-archived");
    const storedPayload = flushOne();
    const liveArchived = await service.forwardLiveAgent(agent("live-archived", "ws-archived"));
    assert.equal(liveArchived, undefined);
    const livePayload = flushOne();
    const selfArchivedResult = await service.includesLiveAgent(
        agent("live-self-archived", "ws-active", { archivedAt: "2026-09-23T00:00:00.000Z" }),
    );
    const activeResult = await service.includesLiveAgent(agent("live-active", "ws-active"));
    const nullResult = await service.includesLiveAgent(agent("live-null", null));
    const unknownResult = await service.includesLiveAgent(agent("live-unknown", "ws-missing"));
    return {
        storedPayload,
        livePayload,
        selfArchivedResult,
        activeResult,
        nullResult,
        unknownResult,
        placements,
        workspaceUpdates,
    };
}

async function runUpdateChecks(source) {
    const defaultScenario = await runUpdateScenario(source, false);
    assert.equal(defaultScenario.storedPayload.kind, "remove", "default stored archived-workspace update removes");
    assert.equal(defaultScenario.storedPayload.agentId, "stored-archived");
    assert.equal(defaultScenario.livePayload.kind, "remove", "default live archived-workspace update removes");
    assert.equal(defaultScenario.livePayload.agentId, "live-archived");
    assert.equal(defaultScenario.selfArchivedResult, false, "default self-archived subscription excludes agent");
    assert.equal(defaultScenario.activeResult, true, "default active workspace subscription remains included");
    assert.equal(defaultScenario.nullResult, false, "default null workspace semantics remain unchanged");
    assert.equal(defaultScenario.unknownResult, false, "default unknown workspace semantics remain unchanged");
    assert.deepEqual(
        defaultScenario.placements,
        [
            { workspaceId: "ws-archived", requestedIncludeArchived: false },
            { workspaceId: "ws-archived", requestedIncludeArchived: false },
            { workspaceId: "ws-active", requestedIncludeArchived: false },
            { workspaceId: "ws-active", requestedIncludeArchived: false },
            { workspaceId: "ws-missing", requestedIncludeArchived: false },
        ],
        "default updates pass false to placement resolution and preserve null/unknown short-circuiting",
    );

    const includedScenario = await runUpdateScenario(source, true);
    assert.equal(includedScenario.storedPayload.kind, "upsert", "includeArchived stored update upserts");
    assert.equal(includedScenario.storedPayload.agent.id, "stored-archived");
    assert.equal(includedScenario.livePayload.kind, "upsert", "includeArchived live update upserts");
    assert.equal(includedScenario.livePayload.agent.id, "live-archived");
    assert.equal(includedScenario.selfArchivedResult, true, "includeArchived self-archived subscription includes agent");
    assert.equal(includedScenario.activeResult, true, "includeArchived active workspace remains included");
    assert.equal(includedScenario.nullResult, false, "includeArchived null workspace semantics remain unchanged");
    assert.equal(includedScenario.unknownResult, false, "includeArchived unknown workspace semantics remain unchanged");
    assert.deepEqual(
        includedScenario.placements,
        [
            { workspaceId: "ws-archived", requestedIncludeArchived: true },
            { workspaceId: "ws-archived", requestedIncludeArchived: true },
            { workspaceId: "ws-active", requestedIncludeArchived: true },
            { workspaceId: "ws-active", requestedIncludeArchived: true },
            { workspaceId: "ws-missing", requestedIncludeArchived: true },
        ],
        "includeArchived updates pass true to placement resolution",
    );
}

async function runBehaviorChecks(sessionSource, updatesSource) {
    await runSnapshotChecks(sessionSource);
    await runUpdateChecks(updatesSource);
}

function runPatcher(patcher, sessionTarget, updatesTarget) {
    return spawnSync(process.execPath, [patcher, sessionTarget, updatesTarget], { encoding: "utf8" });
}

function assertNoCandidates(sessionTarget, updatesTarget) {
    assert.equal(fs.existsSync(`${sessionTarget}.paseo-new.mjs`), false, "session drift wrote a candidate");
    assert.equal(fs.existsSync(`${updatesTarget}.paseo-new.mjs`), false, "update-service drift wrote a candidate");
}

async function runSelfTest(patcher) {
    assert.ok(patcher, "--self-test requires the patcher path");
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "paseo-archive-consistency-"));
    try {
        const sessionPath = path.join(directory, "session.js");
        const updatesPath = path.join(directory, "agent-updates-service.js");
        fs.writeFileSync(sessionPath, SYNTHETIC_SESSION_PRISTINE);
        fs.writeFileSync(updatesPath, SYNTHETIC_UPDATES_PRISTINE);

        const patched = runPatcher(patcher, sessionPath, updatesPath);
        assert.equal(patched.status, 0, patched.stderr || patched.stdout);
        const sessionCandidate = `${sessionPath}.paseo-new.mjs`;
        const updatesCandidate = `${updatesPath}.paseo-new.mjs`;
        assert.equal(spawnSync(process.execPath, ["--check", sessionCandidate]).status, 0, "session candidate syntax failed");
        assert.equal(spawnSync(process.execPath, ["--check", updatesCandidate]).status, 0, "update-service candidate syntax failed");
        await runBehaviorChecks(fs.readFileSync(sessionCandidate, "utf8"), fs.readFileSync(updatesCandidate, "utf8"));

        const alreadySession = path.join(directory, "already-session.js");
        const alreadyUpdates = path.join(directory, "already-updates.js");
        fs.copyFileSync(sessionCandidate, alreadySession);
        fs.copyFileSync(updatesCandidate, alreadyUpdates);
        const already = runPatcher(patcher, alreadySession, alreadyUpdates);
        assert.equal(already.status, 10, "both patched targets must return idempotent rc10");
        assertNoCandidates(alreadySession, alreadyUpdates);

        // Mixed state is not safe to repair heuristically: no candidate may be
        // emitted for either target.
        const mixedSession = path.join(directory, "mixed-session.js");
        const mixedUpdates = path.join(directory, "mixed-updates.js");
        fs.copyFileSync(sessionCandidate, mixedSession);
        fs.writeFileSync(mixedUpdates, SYNTHETIC_UPDATES_PRISTINE);
        const mixed = runPatcher(patcher, mixedSession, mixedUpdates);
        assert.equal(mixed.status, 20, "mixed patched/pristine targets must return rc20");
        assertNoCandidates(mixedSession, mixedUpdates);

        const missingSession = path.join(directory, "missing-session.js");
        const missingUpdates = path.join(directory, "missing-updates.js");
        fs.writeFileSync(missingSession, SYNTHETIC_SESSION_PRISTINE.replace(
            "            agents = agents.filter((agent) => !agent.archivedAt);",
            "            agents = agents.filter((agent) => true);",
        ));
        fs.writeFileSync(missingUpdates, SYNTHETIC_UPDATES_PRISTINE);
        const missingBefore = fs.readFileSync(missingSession, "utf8");
        const missing = runPatcher(patcher, missingSession, missingUpdates);
        assert.equal(missing.status, 20, "missing session anchor must return rc20");
        assert.equal(fs.readFileSync(missingSession, "utf8"), missingBefore, "missing-anchor session changed");
        assertNoCandidates(missingSession, missingUpdates);

        const duplicateSession = path.join(directory, "duplicate-session.js");
        const duplicateUpdates = path.join(directory, "duplicate-updates.js");
        fs.writeFileSync(duplicateSession, SYNTHETIC_SESSION_PRISTINE);
        fs.writeFileSync(duplicateUpdates, `${SYNTHETIC_UPDATES_PRISTINE}\n${SYNTHETIC_UPDATES_PRISTINE}`);
        const duplicate = runPatcher(patcher, duplicateSession, duplicateUpdates);
        assert.equal(duplicate.status, 20, "duplicate update anchors must return rc20");
        assertNoCandidates(duplicateSession, duplicateUpdates);
    }
    finally {
        fs.rmSync(directory, { recursive: true, force: true });
    }
}

const firstArgument = process.argv[2];
if (firstArgument === "--self-test") {
    await runSelfTest(process.argv[3]);
    console.log("PASS snapshot + stored/live updates, includeArchived, mixed/drift refusal, and idempotence");
}
else {
    const updatesArgument = process.argv[3];
    if (!firstArgument || !updatesArgument) {
        console.error("usage: archive-consistency.test.mjs <patched-session.js> <patched-agent-updates-service.js> | --self-test <patcher.mjs>");
        process.exit(1);
    }
    await runBehaviorChecks(fs.readFileSync(firstArgument, "utf8"), fs.readFileSync(updatesArgument, "utf8"));
    console.log("PASS archive consistency snapshot and live update behavior");
}
