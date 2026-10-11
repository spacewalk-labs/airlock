// SPDX-License-Identifier: AGPL-3.0-only
// When a worktree directory disappears outside Paseo, the periodic reconciliation
// archives the workspace record only. Its sessions keep no archive mark and stay
// listed as live. Reconciliation now archives them the way a UI archive does.
import fs from "node:fs";
const target = process.argv[2];
if (!target) throw new Error("usage: reconcile-archives-agents.mjs <server/bootstrap.js>");
const source = fs.readFileSync(target, "utf8");
const marker = "[paseo-reconcile-archives-agents]";
if (source.includes(marker)) { console.log("ALREADY"); process.exit(10); }
const importAnchor = "import { archiveByScope, archivePersistedWorkspaceRecord, killTerminalsForWorkspace, } from \"./workspace-archive-service.js\";";
const hookAnchor = "        onWorkspaceArchived: teardownArchivedWorkspaceRuntime,";
if ([importAnchor, hookAnchor].some((anchor) => source.split(anchor).length !== 2)) { console.error("SKIP: reconciliation archive anchor missing or ambiguous"); process.exit(20); }
const hook = [
    "        onWorkspaceArchived: async (workspaceId) => {",
    "            teardownArchivedWorkspaceRuntime(workspaceId);",
    `            // ${marker} A workspace archived for a missing directory archives its agents too.`,
    "            await archiveWorkspaceContents({",
    "                agentManager,",
    "                agentStorage,",
    "                sessionLogger: logger,",
    "                killTerminalsForWorkspace: (workspaceIdToKill) => killTerminalsForWorkspace({ terminalManager, sessionLogger: logger }, workspaceIdToKill),",
    "            }, workspaceId);",
    "        },",
].join("\n");
fs.writeFileSync(`${target}.paseo-new.mjs`, source
    .replace(importAnchor, importAnchor.replace("archivePersistedWorkspaceRecord,", "archivePersistedWorkspaceRecord, archiveWorkspaceContents,"))
    .replace(hookAnchor, hook));
console.log("PATCHED");
