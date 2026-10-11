// SPDX-License-Identifier: AGPL-3.0-only
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
// Execute the installed DirectorySyncService: a device holding a cursor that is
// already past an archive must still be told the archived row is gone.
const { DirectorySyncService } = await import(pathToFileURL(process.argv[2]).href);
const sync = new DirectorySyncService("test-generation");
const first = sync.synchronizeWorkspaces([{ id: "kept" }, { id: "archived" }], {});
assert.equal(first.sync.mode, "snapshot");
sync.sequenceWorkspaceUpdate({ kind: "remove", id: "archived" }, null, "archived", true);
const head = sync.synchronizeWorkspaces([{ id: "kept" }], {}).sync.headSeq;
for (const afterSeq of [first.sync.headSeq, head, 0]) {
    const read = sync.synchronizeWorkspaces([{ id: "kept" }], { generation: "test-generation", afterSeq });
    assert.equal(read.sync.mode, "snapshot", `afterSeq=${afterSeq} must answer with the full list`);
    assert.deepEqual(read.entries.map((entry) => entry.id), ["kept"]);
    assert.equal(read.sync.headSeq, head, "a read must not move the head");
}
const agents = sync.synchronizeAgents([{ agent: { id: "a" } }], {});
assert.equal(sync.synchronizeAgents([{ agent: { id: "a" } }], { generation: "test-generation", afterSeq: agents.sync.headSeq }).sync.mode, "snapshot");
// Projects are outside this patch and keep upstream's changes read.
const projects = sync.synchronizeProjects([{ projectId: "p" }], {});
assert.equal(sync.synchronizeProjects([{ projectId: "p" }], { generation: "test-generation", afterSeq: projects.sync.headSeq }).sync.mode, "changes");
console.log("PASS directory sync snapshot");
