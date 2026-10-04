// SPDX-License-Identifier: AGPL-3.0-only
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { pathToFileURL } from "node:url";
// Execute the installed Session methods, including the actual delivery branch.
const source = fs.readFileSync(process.argv[2], "utf8");
const names = ["shouldSkipWorkspaceRemoval", "emitWorkspaceUpdateBatch"];
const methods = names.map(name => {
    const start = source.indexOf(`    ${name === "emitWorkspaceUpdateBatch" ? "async " : ""}${name}(`);
    assert.ok(start >= 0, `missing ${name}`);
    const end = source.indexOf("\n    }", start) + 6;
    return source.slice(start, end);
});
const Session = vm.runInNewContext(`(class { ${methods.join("\n")} })`, { equal: (a, b) => JSON.stringify(a) === JSON.stringify(b) });
const session = new Session();
assert.equal(session.shouldSkipWorkspaceRemoval(undefined, undefined), false, "changes-only bootstrap must deliver deletion of cached row");
assert.equal(session.shouldSkipWorkspaceRemoval({ kind: "remove" }, undefined), true, "duplicate removal remains deduplicated");
assert.equal(session.shouldSkipWorkspaceRemoval({ kind: "remove", removedProjectId: "old" }, "new"), false);
assert.equal(session.shouldSkipWorkspaceRemoval({ kind: "upsert" }, undefined), false);
const browserRows = new Map([["cached", { id: "cached" }]]);
const subscription = { lastEmittedByWorkspaceId: new Map(), syncEnabled: true };
session.workspaceUpdatesSubscription = subscription;
session.buildWorkspaceDescriptorMap = async () => new Map(); // registry has archived the row
session.workspaceGitObserver = { recordDescriptorState() {} };
session.applyOptimisticWorkspaceStatus = value => value;
session.buildWorkspaceRemoveUpdatePayload = async id => ({ kind: "remove", id });
let sequenced = 0;
const realSync = process.argv[3]
    ? new (await import(pathToFileURL(process.argv[3]).href)).DirectorySyncService("test-generation")
    : null;
let cursor;
if (realSync) {
    const initial = realSync.synchronizeWorkspaces([{ id: "cached" }], {});
    cursor = { generation: initial.sync.generation, afterSeq: initial.sync.headSeq };
    const reconnect = realSync.synchronizeWorkspaces([{ id: "cached" }], cursor);
    assert.equal(reconnect.sync.mode, "changes");
    assert.equal(reconnect.entries.length, 0, "reconnect emits no unchanged rows to seed subscription");
}
session.directorySync = { sequenceWorkspaceUpdate(...args) {
    sequenced++;
    return realSync ? realSync.sequenceWorkspaceUpdate(...args) : args[0];
} };
session.bufferOrEmitWorkspaceUpdate = (sub, payload) => {
    sub.lastEmittedByWorkspaceId.set(payload.id, payload);
    browserRows.delete(payload.id);
};
await session.emitWorkspaceUpdateBatch(["cached"], subscription);
assert.equal(browserRows.size, 0, "archive removes existing browser row after empty changes-only bootstrap");
await session.emitWorkspaceUpdateBatch(["cached"], subscription);
assert.equal(sequenced, 1, "repeated notifications do not flood removals");
if (realSync) {
    const afterArchive = realSync.synchronizeWorkspaces([], cursor);
    assert.equal(afterArchive.sync.removals[0].id, "cached", "removal is persisted into the reconnect sequence");
}
console.log("PASS workspace removal delivery");
