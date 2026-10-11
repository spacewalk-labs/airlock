// SPDX-License-Identifier: AGPL-3.0-only
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { pathToFileURL } from "node:url";
// Run the installed reconciliation hook against the installed archive service:
// a stored, unarchived agent of the workspace must end up archived.
const source = fs.readFileSync(process.argv[2], "utf8");
const start = source.indexOf("        onWorkspaceArchived: async (workspaceId) => {");
assert.ok(start >= 0, "reconciliation hook is not patched");
const end = source.indexOf("\n        },", start) + "\n        }".length;
const { archiveWorkspaceContents } = await import(pathToFileURL(process.argv[3]).href);
const archived = [], torn = [], killed = [];
const records = [
    { id: "stale", workspaceId: "wks_gone", archivedAt: null },
    { id: "already", workspaceId: "wks_gone", archivedAt: "2026-01-01T00:00:00.000Z" },
    { id: "other", workspaceId: "wks_kept", archivedAt: null },
];
const context = {
    archiveWorkspaceContents,
    teardownArchivedWorkspaceRuntime: (id) => torn.push(id),
    agentManager: { listAgents: () => [], getAgent: () => null, archiveSnapshot: async (id) => { archived.push(id); } },
    agentStorage: { listByWorkspace: async (id) => records.filter((record) => record.workspaceId === id) },
    killTerminalsForWorkspace: async (_deps, id) => { killed.push(id); },
    terminalManager: {},
    logger: { warn() {} },
};
const hooks = vm.runInNewContext(`({\n${source.slice(start, end)}\n})`, context);
await hooks.onWorkspaceArchived("wks_gone");
assert.deepEqual(archived, ["stale"], "only the workspace's unarchived agents are archived");
assert.deepEqual(torn, ["wks_gone"], "runtime teardown still runs");
assert.deepEqual(killed, ["wks_gone"]);
console.log("PASS reconcile archives agents");
