// SPDX-License-Identifier: AGPL-3.0-only
// [paseo-provider-subagent-stream-filter] idempotent, all-or-nothing patcher.
//
// Target: @getpaseo/server .../server/session.js
//
// Provider-owned subagent updates currently use Session.emit(), which broadcasts
// every update to every socket attached to a capable client session. Normal agent
// streams already use source-local capabilities and viewed-parent subscriptions.
// This patch gives provider-subagent updates the same delivery boundary without
// changing their wire shape.
//
// Contract: argv[2] = target session.js.
//   exit  0 = candidate written to <target>.paseo-new.mjs
//   exit 10 = already patched
//   exit 20 = a required anchor is missing or duplicated; writes nothing
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
    "    supportsForSource(capability, source) {",
    "        return (this.clientCapabilitiesBySource.get(source)?.has(capability) ?? this.supports(capability));",
    "    }",
    "    emitProjectUpdate(update) {",
);

const METHOD_REPLACEMENT = lines(
    "    supportsForSource(capability, source) {",
    "        return (this.clientCapabilitiesBySource.get(source)?.has(capability) ?? this.supports(capability));",
    "    }",
    "    // [paseo-provider-subagent-stream-filter] Keep provider-owned child streams",
    "    // inside the same source-local viewed-parent boundary as normal agent streams.",
    "    forwardProviderSubagentUpdate(update) {",
    "        const parentAgentId = update.type === \"upsert\"",
    "            ? update.subagent.parentAgentId",
    "            : update.parentAgentId;",
    "        const payload = update.type === \"upsert\"",
    "            ? { kind: \"upsert\", subagent: update.subagent }",
    "            : update.type === \"timeline\"",
    "                ? {",
    "                    kind: \"timeline\",",
    "                    parentAgentId: update.parentAgentId,",
    "                    subagentId: update.subagentId,",
    "                    provider: update.provider,",
    "                    item: update.row.item,",
    "                    timestamp: update.row.timestamp,",
    "                    seq: update.row.seq,",
    "                    epoch: update.epoch,",
    "                }",
    "                : {",
    "                    kind: \"remove\",",
    "                    parentAgentId: update.parentAgentId,",
    "                    subagentId: update.subagentId,",
    "                };",
    "        const message = { type: \"agent.provider_subagents.update\", payload };",
    "        if (this.clientCapabilitiesBySource.size === 0 || !this.onMessageToSource) {",
    "            if (!this.supports(CLIENT_CAPS.providerSubagents)) {",
    "                return;",
    "            }",
    "            if (this.usesSelectiveTimelineDelivery() &&",
    "                !this.viewedTimelineAgentIds.has(parentAgentId)) {",
    "                return;",
    "            }",
    "            this.emit(message);",
    "            return;",
    "        }",
    "        for (const [source, capabilities] of this.clientCapabilitiesBySource) {",
    "            if (!capabilities.has(CLIENT_CAPS.providerSubagents)) {",
    "                continue;",
    "            }",
    "            if (capabilities.has(CLIENT_CAPS.selectiveAgentTimeline) &&",
    "                !this.viewedTimelineAgentIdsBySource.get(source)?.has(parentAgentId)) {",
    "                continue;",
    "            }",
    "            this.onMessageToSource(source, message);",
    "        }",
    "    }",
    "    emitProjectUpdate(update) {",
);

const BRANCH_ANCHOR = lines(
    "            if (event.type === \"provider_subagent\") {",
    "                if (!this.supports(CLIENT_CAPS.providerSubagents)) {",
    "                    return;",
    "                }",
    "                const update = event.event;",
    "                if (update.type === \"upsert\") {",
    "                    this.emit({",
    "                        type: \"agent.provider_subagents.update\",",
    "                        payload: { kind: \"upsert\", subagent: update.subagent },",
    "                    });",
    "                }",
    "                else if (update.type === \"timeline\") {",
    "                    this.emit({",
    "                        type: \"agent.provider_subagents.update\",",
    "                        payload: {",
    "                            kind: \"timeline\",",
    "                            parentAgentId: update.parentAgentId,",
    "                            subagentId: update.subagentId,",
    "                            provider: update.provider,",
    "                            item: update.row.item,",
    "                            timestamp: update.row.timestamp,",
    "                            seq: update.row.seq,",
    "                            epoch: update.epoch,",
    "                        },",
    "                    });",
    "                }",
    "                else {",
    "                    this.emit({",
    "                        type: \"agent.provider_subagents.update\",",
    "                        payload: {",
    "                            kind: \"remove\",",
    "                            parentAgentId: update.parentAgentId,",
    "                            subagentId: update.subagentId,",
    "                        },",
    "                    });",
    "                }",
    "                return;",
    "            }",
);

const BRANCH_REPLACEMENT = lines(
    "            if (event.type === \"provider_subagent\") {",
    "                this.forwardProviderSubagentUpdate(event.event);",
    "                return;",
    "            }",
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

const anchors = [
    ["method insertion", METHOD_ANCHOR, METHOD_REPLACEMENT],
    ["provider_subagent branch", BRANCH_ANCHOR, BRANCH_REPLACEMENT],
];
const invalid = anchors
    .map(([name, anchor]) => [name, occurrences(source, anchor)])
    .filter(([, count]) => count !== 1);
if (invalid.length > 0) {
    console.error(`SKIP: anchors missing or duplicated (upstream drift?): ${invalid
        .map(([name, count]) => `${name}=${count}`)
        .join(", ")}`);
    process.exit(20);
}

let candidate = source;
for (const [name, anchor, replacement] of anchors) {
    candidate = candidate.replace(anchor, replacement);
    if (occurrences(candidate, anchor) !== 0 || !candidate.includes(replacement)) {
        console.error(`replacement failed: ${name}`);
        process.exit(1);
    }
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

