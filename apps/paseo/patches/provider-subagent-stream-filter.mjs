// SPDX-License-Identifier: AGPL-3.0-only
// [paseo-provider-subagent-stream-filter] idempotent, all-or-nothing patcher.
//
// Target: @getpaseo/server .../server/session.js
//
// 0.8.0 note: upstream independently built forwardProviderSubagentUpdate — the
// per-capability, per-source delivery method the 0.2.5-era version of this patch
// had to add from scratch — but it still does not gate on the VIEWED parent
// agent: it forwards to every source that supports the providerSubagents
// capability, the same broadcast-within-capability shape the 0.2.5 patch closed
// for normal agent streams. forwardAgentStream (this file's sibling method) is
// the reference: it checks `usesSelectiveTimelineDelivery()` /
// `viewedTimelineAgentIds` (no-source path) and `viewedTimelineAgentIdsBySource`
// (per-source path) before delivering. This patch adds the same two checks to
// forwardProviderSubagentUpdate, keyed on the update's parentAgentId (a child's
// visibility follows its PARENT's viewed-agent subscription, not its own id —
// nothing subscribes to a subagent id directly).
//
// Contract: argv[2] = target session.js.
//   exit  0 = candidate written to <target>.paseo-new.mjs
//   exit 10 = already patched
//   exit 20 = the anchor is missing or duplicated; writes nothing
//   exit  1 = usage / IO / patch logic error
import fs from "node:fs";

const target = process.argv[2];
if (!target) {
    console.error("usage: provider-subagent-stream-filter.mjs <session.js>");
    process.exit(1);
}

const SENTINEL = "[paseo-provider-subagent-stream-filter]";
const lines = (...items) => items.join("\n");

let source;
try {
    source = fs.readFileSync(target, "utf8");
}
catch (error) {
    console.error(`read failed: ${String(error)}`);
    process.exit(1);
}

if (source.includes(SENTINEL)) {
    console.log("ALREADY");
    process.exit(10);
}

const METHOD_ANCHOR = lines(
    "    forwardProviderSubagentUpdate(update) {",
    "        let message;",
    "        if (update.type === \"upsert\") {",
    "            message = {",
    "                type: \"agent.provider_subagents.update\",",
    "                payload: { kind: \"upsert\", subagent: update.subagent },",
    "            };",
    "        }",
    "        else if (update.type === \"timeline\") {",
    "            message = {",
    "                type: \"agent.provider_subagents.update\",",
    "                payload: {",
    "                    kind: \"timeline\",",
    "                    parentAgentId: update.parentAgentId,",
    "                    subagentId: update.subagentId,",
    "                    provider: update.provider,",
    "                    item: update.row.item,",
    "                    timestamp: update.row.timestamp,",
    "                    seq: update.row.seq,",
    "                    epoch: update.epoch,",
    "                },",
    "            };",
    "        }",
    "        else {",
    "            message = {",
    "                type: \"agent.provider_subagents.update\",",
    "                payload: {",
    "                    kind: \"remove\",",
    "                    parentAgentId: update.parentAgentId,",
    "                    subagentId: update.subagentId,",
    "                },",
    "            };",
    "        }",
    "        if (this.clientCapabilitiesBySource.size === 0 || !this.onMessageToSource) {",
    "            if (this.supports(CLIENT_CAPS.providerSubagents) &&",
    "                (update.type !== \"timeline\" || this.supportsTimelineItem(update.row.item))) {",
    "                this.emit(message);",
    "            }",
    "            return;",
    "        }",
    "        for (const [source, capabilities] of this.clientCapabilitiesBySource) {",
    "            if (!capabilities.has(CLIENT_CAPS.providerSubagents))",
    "                continue;",
    "            if (update.type === \"timeline\" && !this.supportsTimelineItem(update.row.item, source))",
    "                continue;",
    "            this.onMessageToSource(source, message);",
    "        }",
    "    }",
);

const METHOD_REPLACEMENT = lines(
    "    forwardProviderSubagentUpdate(update) {",
    "        let message;",
    "        if (update.type === \"upsert\") {",
    "            message = {",
    "                type: \"agent.provider_subagents.update\",",
    "                payload: { kind: \"upsert\", subagent: update.subagent },",
    "            };",
    "        }",
    "        else if (update.type === \"timeline\") {",
    "            message = {",
    "                type: \"agent.provider_subagents.update\",",
    "                payload: {",
    "                    kind: \"timeline\",",
    "                    parentAgentId: update.parentAgentId,",
    "                    subagentId: update.subagentId,",
    "                    provider: update.provider,",
    "                    item: update.row.item,",
    "                    timestamp: update.row.timestamp,",
    "                    seq: update.row.seq,",
    "                    epoch: update.epoch,",
    "                },",
    "            };",
    "        }",
    "        else {",
    "            message = {",
    "                type: \"agent.provider_subagents.update\",",
    "                payload: {",
    "                    kind: \"remove\",",
    "                    parentAgentId: update.parentAgentId,",
    "                    subagentId: update.subagentId,",
    "                },",
    "            };",
    "        }",
    "        // [paseo-provider-subagent-stream-filter] a child's visibility follows its",
    "        // PARENT's viewed-agent subscription — nothing subscribes to a subagent id.",
    "        const parentAgentId = update.type === \"upsert\" ? update.subagent.parentAgentId : update.parentAgentId;",
    "        if (this.clientCapabilitiesBySource.size === 0 || !this.onMessageToSource) {",
    "            if (this.supports(CLIENT_CAPS.providerSubagents) &&",
    "                (update.type !== \"timeline\" || this.supportsTimelineItem(update.row.item))) {",
    "                if (!this.usesSelectiveTimelineDelivery() || this.viewedTimelineAgentIds.has(parentAgentId)) {",
    "                    this.emit(message);",
    "                }",
    "            }",
    "            return;",
    "        }",
    "        for (const [source, capabilities] of this.clientCapabilitiesBySource) {",
    "            if (!capabilities.has(CLIENT_CAPS.providerSubagents))",
    "                continue;",
    "            if (update.type === \"timeline\" && !this.supportsTimelineItem(update.row.item, source))",
    "                continue;",
    "            if (capabilities.has(CLIENT_CAPS.selectiveAgentTimeline) &&",
    "                !this.viewedTimelineAgentIdsBySource.get(source)?.has(parentAgentId)) {",
    "                continue;",
    "            }",
    "            this.onMessageToSource(source, message);",
    "        }",
    "    }",
);

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

const found = occurrences(source, METHOD_ANCHOR);
if (found !== 1) {
    console.error(`SKIP: anchors missing or duplicated (upstream drift?): provider_subagent branch=${found}`);
    process.exit(20);
}

const candidate = source.replace(METHOD_ANCHOR, METHOD_REPLACEMENT);
if (occurrences(candidate, METHOD_ANCHOR) !== 0 || !candidate.includes(METHOD_REPLACEMENT)) {
    console.error("replacement failed: method insertion");
    process.exit(1);
}
if (!candidate.includes(SENTINEL)) {
    console.error("sentinel absent after patching — logic error");
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
