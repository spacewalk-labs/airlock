// SPDX-License-Identifier: AGPL-3.0-only
// Behavior check for provider-subagent-stream-filter.mjs.
//
// Normal use:
//   node provider-subagent-stream-filter.test.mjs <patched-session.js>
// Self-contained synthetic fixture:
//   node provider-subagent-stream-filter.test.mjs --self-test <patcher.mjs>
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const CLIENT_CAPS = {
    providerSubagents: "provider_subagents",
    selectiveAgentTimeline: "selective_agent_timeline",
};

function extractPatchedMethod(source) {
    const sentinel = "[paseo-provider-subagent-stream-filter]";
    if (!source.includes(sentinel)) {
        throw new Error("target is not patched: sentinel missing");
    }
    const start = source.indexOf("    forwardProviderSubagentUpdate(update) {");
    const end = source.indexOf("\n    emitProjectUpdate(update) {", start);
    if (start < 0 || end < 0) {
        throw new Error("target is not patched: forwarding method extraction failed");
    }
    return source.slice(start, end);
}

function buildHarness(source, options = {}) {
    const method = extractPatchedMethod(source);
    const Harness = new Function("CLIENT_CAPS", `
        return class Harness {
            constructor(options) {
                this.clientCapabilities = new Set(options.globalCapabilities ?? []);
                this.clientCapabilitiesBySource = new Map(
                    (options.sources ?? []).map(([source, capabilities]) => [source, new Set(capabilities)]),
                );
                this.viewedTimelineAgentIds = new Set(options.viewedParents ?? []);
                this.viewedTimelineAgentIdsBySource = new Map(
                    (options.sourceViews ?? []).map(([source, parents]) => [source, new Set(parents)]),
                );
                this.broadcast = [];
                this.direct = [];
                this.onMessageToSource = options.sourceTransport === false
                    ? null
                    : (source, message) => this.direct.push({ source, message });
            }
            supports(capability) {
                return this.clientCapabilities.has(capability);
            }
            usesSelectiveTimelineDelivery() {
                if (this.clientCapabilitiesBySource.size === 0) {
                    return this.supports(CLIENT_CAPS.selectiveAgentTimeline);
                }
                for (const capabilities of this.clientCapabilitiesBySource.values()) {
                    if (!capabilities.has(CLIENT_CAPS.selectiveAgentTimeline)) return false;
                }
                return true;
            }
            emit(message) {
                this.broadcast.push(message);
            }
${method}
        };
    `)(CLIENT_CAPS);
    return new Harness(options);
}

function updateFixtures(parentAgentId = "parent-a") {
    const subagent = {
        id: "child-1",
        parentAgentId,
        provider: "claude",
        title: "Child",
        description: null,
        status: "running",
        createdAt: "2026-08-15T00:00:00.000Z",
        updatedAt: "2026-08-15T00:00:01.000Z",
        toolCallId: "tool-1",
        cwd: "/tmp/work",
    };
    return [
        {
            kind: "upsert",
            update: { type: "upsert", subagent },
            expectedPayload: { kind: "upsert", subagent },
        },
        {
            kind: "timeline",
            update: {
                type: "timeline",
                parentAgentId,
                subagentId: subagent.id,
                provider: "claude",
                row: {
                    item: { type: "assistant_message", text: "progress" },
                    timestamp: "2026-08-15T00:00:02.000Z",
                    seq: 7,
                },
                epoch: "epoch-1",
            },
            expectedPayload: {
                kind: "timeline",
                parentAgentId,
                subagentId: subagent.id,
                provider: "claude",
                item: { type: "assistant_message", text: "progress" },
                timestamp: "2026-08-15T00:00:02.000Z",
                seq: 7,
                epoch: "epoch-1",
            },
        },
        {
            kind: "remove",
            update: { type: "remove", parentAgentId, subagentId: subagent.id },
            expectedPayload: { kind: "remove", parentAgentId, subagentId: subagent.id },
        },
    ];
}

function runBehaviorChecks(source) {
    const selective = [CLIENT_CAPS.providerSubagents, CLIENT_CAPS.selectiveAgentTimeline];
    const legacy = [CLIENT_CAPS.providerSubagents];
    const unsupported = [CLIENT_CAPS.selectiveAgentTimeline];
    const multiSource = buildHarness(source, {
        sources: [
            ["source-a", selective],
            ["source-b", selective],
            ["legacy", legacy],
            ["unsupported", unsupported],
        ],
        sourceViews: [
            ["source-a", ["parent-a"]],
            ["source-b", ["parent-b"]],
            ["legacy", []],
            ["unsupported", ["parent-a"]],
        ],
    });

    for (const fixture of updateFixtures()) {
        multiSource.direct.length = 0;
        multiSource.forwardProviderSubagentUpdate(fixture.update);
        assert.deepEqual(
            multiSource.direct.map(({ source: recipient }) => recipient),
            ["source-a", "legacy"],
            `${fixture.kind}: subscribed selective source and legacy source receive exactly once`,
        );
        for (const { message } of multiSource.direct) {
            assert.equal(message.type, "agent.provider_subagents.update");
            assert.deepEqual(message.payload, fixture.expectedPayload, `${fixture.kind}: wire payload preserved`);
        }
        assert.equal(multiSource.broadcast.length, 0, `${fixture.kind}: source-aware path does not broadcast`);
    }

    multiSource.direct.length = 0;
    multiSource.forwardProviderSubagentUpdate(updateFixtures("parent-b")[0].update);
    assert.deepEqual(
        multiSource.direct.map(({ source: recipient }) => recipient),
        ["source-b", "legacy"],
        "parent-b routes only to its selective subscriber plus legacy",
    );

    const selectiveFallback = buildHarness(source, {
        globalCapabilities: selective,
        viewedParents: ["parent-a"],
        sourceTransport: false,
    });
    selectiveFallback.forwardProviderSubagentUpdate(updateFixtures("parent-a")[1].update);
    selectiveFallback.forwardProviderSubagentUpdate(updateFixtures("parent-b")[1].update);
    assert.equal(selectiveFallback.broadcast.length, 1, "no-source selective fallback filters unseen parent");
    assert.equal(selectiveFallback.broadcast[0].payload.parentAgentId, "parent-a");

    const legacyFallback = buildHarness(source, {
        globalCapabilities: legacy,
        sourceTransport: false,
    });
    for (const fixture of updateFixtures("unseen-parent")) {
        legacyFallback.forwardProviderSubagentUpdate(fixture.update);
    }
    assert.equal(legacyFallback.broadcast.length, 3, "no-source legacy fallback preserves broadcast");

    const unsupportedFallback = buildHarness(source, {
        globalCapabilities: unsupported,
        viewedParents: ["parent-a"],
        sourceTransport: false,
    });
    unsupportedFallback.forwardProviderSubagentUpdate(updateFixtures()[0].update);
    assert.equal(unsupportedFallback.broadcast.length, 0, "no-source fallback honors provider capability");

    const aggregateSelectiveFallback = buildHarness(source, {
        globalCapabilities: selective,
        sources: [
            ["detached-a", selective],
            ["detached-b", selective],
        ],
        viewedParents: ["parent-a"],
        sourceTransport: false,
    });
    aggregateSelectiveFallback.forwardProviderSubagentUpdate(updateFixtures("parent-a")[0].update);
    aggregateSelectiveFallback.forwardProviderSubagentUpdate(updateFixtures("parent-b")[0].update);
    assert.equal(
        aggregateSelectiveFallback.broadcast.length,
        1,
        "aggregate fallback with source capabilities still filters by viewed-parent union",
    );

    const aggregateLegacyFallback = buildHarness(source, {
        globalCapabilities: legacy,
        sources: [
            ["detached-selective", selective],
            ["detached-legacy", legacy],
        ],
        sourceTransport: false,
    });
    aggregateLegacyFallback.forwardProviderSubagentUpdate(updateFixtures("unseen-parent")[0].update);
    assert.equal(
        aggregateLegacyFallback.broadcast.length,
        1,
        "aggregate fallback preserves broadcast when any source is legacy",
    );
}

const SYNTHETIC_PRISTINE = `
const CLIENT_CAPS = { providerSubagents: "provider_subagents", selectiveAgentTimeline: "selective_agent_timeline" };
export class Session {
    supportsForSource(capability, source) {
        return (this.clientCapabilitiesBySource.get(source)?.has(capability) ?? this.supports(capability));
    }
    emitProjectUpdate(update) {
        return update;
    }
    handleEvent(event) {
            if (event.type === "provider_subagent") {
                if (!this.supports(CLIENT_CAPS.providerSubagents)) {
                    return;
                }
                const update = event.event;
                if (update.type === "upsert") {
                    this.emit({
                        type: "agent.provider_subagents.update",
                        payload: { kind: "upsert", subagent: update.subagent },
                    });
                }
                else if (update.type === "timeline") {
                    this.emit({
                        type: "agent.provider_subagents.update",
                        payload: {
                            kind: "timeline",
                            parentAgentId: update.parentAgentId,
                            subagentId: update.subagentId,
                            provider: update.provider,
                            item: update.row.item,
                            timestamp: update.row.timestamp,
                            seq: update.row.seq,
                            epoch: update.epoch,
                        },
                    });
                }
                else {
                    this.emit({
                        type: "agent.provider_subagents.update",
                        payload: {
                            kind: "remove",
                            parentAgentId: update.parentAgentId,
                            subagentId: update.subagentId,
                        },
                    });
                }
                return;
            }
    }
}
`;

function runSelfTest(patcherPath) {
    assert.ok(patcherPath, "--self-test requires the patcher path");
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "paseo-subagent-stream-filter-"));
    try {
        const pristinePath = path.join(directory, "session.js");
        fs.writeFileSync(pristinePath, SYNTHETIC_PRISTINE);
        assert.throws(
            () => runBehaviorChecks(fs.readFileSync(pristinePath, "utf8")),
            /not patched/,
            "behavior check must reject a pristine target",
        );
        const patched = spawnSync(process.execPath, [patcherPath, pristinePath], { encoding: "utf8" });
        assert.equal(patched.status, 0, `synthetic patch failed: ${patched.stderr || patched.stdout}`);
        const candidatePath = `${pristinePath}.paseo-new.mjs`;
        const candidate = fs.readFileSync(candidatePath, "utf8");
        runBehaviorChecks(candidate);
        const syntax = spawnSync(process.execPath, ["--check", candidatePath], { encoding: "utf8" });
        assert.equal(syntax.status, 0, `synthetic candidate syntax failed: ${syntax.stderr || syntax.stdout}`);
        const alreadyPath = path.join(directory, "already.js");
        fs.copyFileSync(candidatePath, alreadyPath);
        const already = spawnSync(process.execPath, [patcherPath, alreadyPath], { encoding: "utf8" });
        assert.equal(already.status, 10, "patched target must return idempotent rc10");
        const missingPath = path.join(directory, "missing.js");
        fs.writeFileSync(missingPath, "export class Session {}\n");
        const missing = spawnSync(process.execPath, [patcherPath, missingPath], { encoding: "utf8" });
        assert.equal(missing.status, 20, "missing anchors must return rc20");
        assert.equal(fs.existsSync(`${missingPath}.paseo-new.mjs`), false, "rc20 must not write a candidate");
        const duplicatePath = path.join(directory, "duplicate.js");
        fs.writeFileSync(duplicatePath, `${SYNTHETIC_PRISTINE}\n${SYNTHETIC_PRISTINE}`);
        const duplicate = spawnSync(process.execPath, [patcherPath, duplicatePath], { encoding: "utf8" });
        assert.equal(duplicate.status, 20, "duplicate anchors must return rc20");
        assert.equal(fs.existsSync(`${duplicatePath}.paseo-new.mjs`), false, "duplicate rc20 must not write a candidate");
    }
    finally {
        fs.rmSync(directory, { recursive: true, force: true });
    }
}

const argument = process.argv[2];
if (argument === "--self-test") {
    runSelfTest(process.argv[3]);
    console.log("PASS synthetic fixture, extracted-method behavior, pristine rejection, rc10, missing/duplicate rc20");
}
else {
    if (!argument) {
        console.error("usage: provider-subagent-stream-filter.test.mjs <patched-session.js> | --self-test <patcher.mjs>");
        process.exit(1);
    }
    runBehaviorChecks(fs.readFileSync(argument, "utf8"));
    console.log("PASS provider subagent multi-source and fallback behavior");
}
