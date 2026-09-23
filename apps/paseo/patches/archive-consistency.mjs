// SPDX-License-Identifier: AGPL-3.0-only
// [paseo-archive-consistency] idempotent, all-or-nothing two-file patcher.
//
// Targets: @getpaseo/server .../server/session.js and
//          .../session/agent-updates/agent-updates-service.js from guarded 0.8.0.
// A workspace archive can leave its agents unarchived. The snapshot read path
// and the live subscription path must agree without mutating stored records.
//
// Contract: argv[2] = session.js; argv[3] = agent-updates-service.js.
//   exit  0 = both candidates written to <target>.paseo-new.mjs
//   exit 10 = both targets already patched (sentinel)
//   exit 20 = mixed state or any anchor missing/duplicated; writes no candidates
//   exit  1 = usage / IO / patch logic error
import fs from "node:fs";

const sessionTarget = process.argv[2];
const updatesTarget = process.argv[3];
if (!sessionTarget || !updatesTarget) {
    console.error("usage: archive-consistency.mjs <session.js> <agent-updates-service.js>");
    process.exit(1);
}

const SENTINEL = "[paseo-archive-consistency]";
const lines = (...items) => items.join("\n");

function readTarget(target) {
    try {
        return fs.readFileSync(target, "utf8");
    }
    catch (error) {
        console.error(`read failed (${target}): ${String(error)}`);
        process.exit(1);
    }
}

const sessionSource = readTarget(sessionTarget);
const updatesSource = readTarget(updatesTarget);
const sessionPatched = sessionSource.includes(SENTINEL);
const updatesPatched = updatesSource.includes(SENTINEL);
if (sessionPatched && updatesPatched) {
    console.log("ALREADY");
    process.exit(10);
}
if (sessionPatched || updatesPatched) {
    console.error("SKIP: archive-consistency targets are mixed (one target is already patched)");
    process.exit(20);
}

// ── session.js ─────────────────────────────────────────────────────────────
const SESSION_PLACEMENT_ANCHOR = lines(
    "    async buildProjectPlacementForWorkspaceId(workspaceId) {",
    "        const workspace = await this.workspaceRegistry.get(workspaceId);",
    "        if (!workspace)",
    "            return null;",
    "        const project = await this.projectRegistry.get(workspace.projectId);",
    "        if (!project)",
    "            return null;",
    "        return this.buildProjectPlacementForWorkspace(workspace, project);",
    "    }",
);
const SESSION_PLACEMENT_REPLACEMENT = lines(
    "    async buildProjectPlacementForWorkspaceId(workspaceId, includeArchived) {",
    "        const workspace = await this.workspaceRegistry.get(workspaceId);",
    "        if (!workspace)",
    "            return null;",
    `        // ${SENTINEL} Omitted includeArchived preserves legacy callers; false filters archived workspaces.`,
    "        if (includeArchived === false && workspace.archivedAt != null)",
    "            return null;",
    "        const project = await this.projectRegistry.get(workspace.projectId);",
    "        if (!project)",
    "            return null;",
    "        return this.buildProjectPlacementForWorkspace(workspace, project);",
    "    }",
);

const SESSION_LIST_ANCHOR = lines(
    "        let agents = [...liveAgents, ...persistedAgents];",
    "        agents = agents.filter((agent) => this.isProviderVisibleToClient(agent.provider));",
    "        if (!includeArchived) {",
    "            agents = agents.filter((agent) => !agent.archivedAt);",
    "        }",
);
const SESSION_LIST_REPLACEMENT = lines(
    "        let agents = [...liveAgents, ...persistedAgents];",
    "        agents = agents.filter((agent) => this.isProviderVisibleToClient(agent.provider));",
    "        if (!includeArchived) {",
    `            // ${SENTINEL} Archived workspace records hide otherwise-live agents.`,
    "            const workspaceRecords = await this.workspaceRegistry.list();",
    "            const archivedWorkspaceIds = new Set(workspaceRecords",
    "                .filter((record) => record.archivedAt != null)",
    "                .map((record) => record.workspaceId));",
    "            agents = agents.filter((agent) => !agent.archivedAt &&",
    "                (agent.workspaceId == null || !archivedWorkspaceIds.has(agent.workspaceId)));",
    "        }",
);

const SESSION_PLACEMENT_CALL_ANCHOR = lines(
    "            const placementPromise = this.buildProjectPlacementForWorkspaceId(workspaceId);",
    "            placementByWorkspaceId.set(workspaceId, placementPromise);",
);
const SESSION_PLACEMENT_CALL_REPLACEMENT = lines(
    "            const placementPromise = this.buildProjectPlacementForWorkspaceId(",
    "                workspaceId,",
    "                filter?.includeArchived === true,",
    "            );",
    "            placementByWorkspaceId.set(workspaceId, placementPromise);",
);

// ── agent-updates-service.js ────────────────────────────────────────────────
const ACTIVE_PLACEMENT_ANCHOR = lines(
    "        if (subscription !== activeSubscription || !deps.isProviderVisibleToClient(payload.provider)) {",
    "            return false;",
    "        }",
    "        const project = payload.workspaceId",
    "            ? await deps.buildProjectPlacementForWorkspaceId(payload.workspaceId)",
    "            : null;",
    "        return (subscription === activeSubscription &&",
);
const ACTIVE_PLACEMENT_REPLACEMENT = lines(
    "        if (subscription !== activeSubscription || !deps.isProviderVisibleToClient(payload.provider)) {",
    "            return false;",
    "        }",
    `        // ${SENTINEL} Default subscriptions must remove archived-workspace agents too.`,
    "        const project = payload.workspaceId",
    "            ? await deps.buildProjectPlacementForWorkspaceId(payload.workspaceId, activeSubscription.filter?.includeArchived === true)",
    "            : null;",
    "        return (subscription === activeSubscription &&",
);
const SUB_PLACEMENT_CALL = "await deps.buildProjectPlacementForWorkspaceId(payload.workspaceId)";
const SUB_PLACEMENT_REPLACEMENT = "await deps.buildProjectPlacementForWorkspaceId(payload.workspaceId, sub.filter?.includeArchived === true)";

function occurrences(haystack, needle) {
    let count = 0;
    let offset = 0;
    for (;;) {
        const found = haystack.indexOf(needle, offset);
        if (found < 0) {
            return count;
        }
        count += 1;
        offset = found + needle.length;
    }
}

function requireUnique(source, anchor, name) {
    const found = occurrences(source, anchor);
    if (found !== 1) {
        console.error(`SKIP: ${name} anchor missing or duplicated (count=${found})`);
        process.exit(20);
    }
}

requireUnique(sessionSource, SESSION_PLACEMENT_ANCHOR, "session placement");
requireUnique(sessionSource, SESSION_LIST_ANCHOR, "session list");
requireUnique(sessionSource, SESSION_PLACEMENT_CALL_ANCHOR, "session placement call");
requireUnique(updatesSource, ACTIVE_PLACEMENT_ANCHOR, "active subscription placement");
if (occurrences(updatesSource, SUB_PLACEMENT_CALL) !== 3) {
    console.error(`SKIP: stored/live placement calls missing or duplicated (count=${occurrences(updatesSource, SUB_PLACEMENT_CALL)})`);
    process.exit(20);
}

let sessionCandidate = sessionSource
    .replace(SESSION_PLACEMENT_ANCHOR, SESSION_PLACEMENT_REPLACEMENT)
    .replace(SESSION_LIST_ANCHOR, SESSION_LIST_REPLACEMENT)
    .replace(SESSION_PLACEMENT_CALL_ANCHOR, SESSION_PLACEMENT_CALL_REPLACEMENT);
let updatesCandidate = updatesSource
    .replace(ACTIVE_PLACEMENT_ANCHOR, ACTIVE_PLACEMENT_REPLACEMENT)
    .replaceAll(SUB_PLACEMENT_CALL, SUB_PLACEMENT_REPLACEMENT);

if (occurrences(sessionCandidate, SESSION_PLACEMENT_ANCHOR) !== 0 ||
    occurrences(sessionCandidate, SESSION_LIST_ANCHOR) !== 0 ||
    occurrences(sessionCandidate, SESSION_PLACEMENT_CALL_ANCHOR) !== 0 ||
    !sessionCandidate.includes(SENTINEL)) {
    console.error("replacement failed: session anchor/sentinel");
    process.exit(1);
}
if (occurrences(updatesCandidate, ACTIVE_PLACEMENT_ANCHOR) !== 0 ||
    occurrences(updatesCandidate, SUB_PLACEMENT_CALL) !== 0 ||
    !updatesCandidate.includes(SENTINEL)) {
    console.error("replacement failed: agent-updates anchor/sentinel");
    process.exit(1);
}

const sessionCandidatePath = `${sessionTarget}.paseo-new.mjs`;
const updatesCandidatePath = `${updatesTarget}.paseo-new.mjs`;
const written = [];
try {
    fs.writeFileSync(sessionCandidatePath, sessionCandidate);
    written.push(sessionCandidatePath);
    fs.writeFileSync(updatesCandidatePath, updatesCandidate);
    written.push(updatesCandidatePath);
}
catch (error) {
    for (const file of written) {
        fs.rmSync(file, { force: true });
    }
    console.error(`candidate write failed: ${String(error)}`);
    process.exit(1);
}
console.log("PATCHED");
process.exit(0);
