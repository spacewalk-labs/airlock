// SPDX-License-Identifier: AGPL-3.0-only
// [paseo-reload-timeline-replacement] idempotent, all-or-nothing patcher for @getpaseo/server agent/agent-manager.js.
//
// A seat that is loaded again rebuilds its timeline from provider history under a fresh epoch
// (nothing wires the durable timeline store, so the seed is always new). Upstream only reloads
// seats at daemon start, when every client reconnects and refetches. idle-agent-unload now
// reloads seats while clients stay connected: the app still holds the old epoch, and its sequencing
// gate drops every live row of the new epoch whose seq is not 1 (`drop_epoch`). The seat answers,
// the open chat never shows it. Seen 2026-10-21: "오래된 세션이 말해도 반응이 없다" — all 992 sends
// since #928 were accepted by the daemon.
//
// Fix: when a load primes the timeline for the first time, dispatch `timeline_replacement` — the
// event rewind already uses. Clients viewing the seat refetch the tail and adopt the new epoch.
// It fires after hydration and before the caller's prompt, so the refetch covers the new turn.
// Keyed on the first prime, not on the unload set, so it also covers close → reopen and cannot
// race the unload sweep.
//
// Contract: argv[2] = server agent/agent-manager.js.
//   exit  0 = candidate written to <target>.paseo-new.mjs
//   exit 10 = already patched (sentinel)
//   exit 20 = the anchor is missing or duplicated; writes nothing
//   exit  1 = usage / IO / patch logic error
import fs from "node:fs";

const target = process.argv[2];
if (!target) {
    console.error("usage: reload-timeline-replacement.mjs <server agent/agent-manager.js>");
    process.exit(1);
}

const SENTINEL = "[paseo-reload-timeline-replacement]";
const lines = (...items) => items.join("\n");

let source;
try {
    source = fs.readFileSync(target, "utf8");
}
catch (error) {
    console.error(`read failed (${target}): ${String(error)}`);
    process.exit(1);
}
if (source.includes(SENTINEL)) {
    console.log("ALREADY");
    process.exit(10);
}

const ANCHOR = lines(
    "    async hydrateTimelineFromProvider(agentId, options) {",
    "        const agent = this.requireSessionAgent(agentId);",
    "        await this.hydrateTimelineFromLegacyProviderHistory(agent, options);",
    "    }",
);
const REPLACEMENT = lines(
    "    async hydrateTimelineFromProvider(agentId, options) {",
    "        const agent = this.requireSessionAgent(agentId);",
    `        // ${SENTINEL} A first prime starts a new epoch; viewers must refetch or they drop every row.`,
    "        const firstPrime = !agent.historyPrimed && !options?.force;",
    "        await this.hydrateTimelineFromLegacyProviderHistory(agent, options);",
    "        if (firstPrime && this.timelineStore.has(agentId)) {",
    "            this.dispatch({",
    '                type: "timeline_replacement",',
    "                agentId,",
    "                epoch: this.timelineStore.getEpoch(agentId),",
    "            });",
    "        }",
    "    }",
);

let count = 0;
for (let at = source.indexOf(ANCHOR); at >= 0; at = source.indexOf(ANCHOR, at + ANCHOR.length)) {
    count += 1;
}
if (count !== 1) {
    console.error(`SKIP: hydrateTimelineFromProvider anchor missing or duplicated (count=${count})`);
    process.exit(20);
}
const candidate = source.replace(ANCHOR, () => REPLACEMENT);
if (!candidate.includes(SENTINEL)) {
    console.error("replacement failed: sentinel missing");
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
process.exit(0);
