// SPDX-License-Identifier: AGPL-3.0-only
// [paseo-send-keep-pending-permissions] idempotent, all-or-nothing three-file patcher.
//
// Targets (guarded 0.8.0):
//   @getpaseo/protocol  dist/messages.js                      (SendAgentMessageRequestSchema)
//   @getpaseo/server    dist/server/server/session.js         (handleSendAgentMessageRequest)
//   @getpaseo/client    dist/daemon-client.js                 (sendAgentMessage)
//
// Upstream hard-codes `clearPendingPermissions: true` in the send_agent_message_request handler, so an
// automatic inter-session message (session-delivery, activeTurnBehavior "steer") denies the permission
// request the receiving seat was waiting on. The request now carries an optional boolean
// `clearPendingPermissions`; the server uses `msg.clearPendingPermissions ?? true`, so every caller that
// does not send it (the browser UI, a human) keeps today's behaviour. zod strips unknown keys, so the
// schema must learn the field or the value never reaches the handler; the client must forward it.
// The other clearPendingPermissions site (Session.sendText, a human typing/speaking) is not touched.
//
// Contract: argv[2] = protocol messages.js; argv[3] = server session.js; argv[4] = client daemon-client.js.
//   exit  0 = three candidates written to <target>.paseo-new.mjs
//   exit 10 = all three targets already patched (sentinel)
//   exit 20 = mixed state or any anchor missing/duplicated; writes no candidates
//   exit  1 = usage / IO / patch logic error
import fs from "node:fs";

const [messagesTarget, sessionTarget, clientTarget] = process.argv.slice(2);
if (!messagesTarget || !sessionTarget || !clientTarget) {
    console.error("usage: send-keep-pending-permissions.mjs <protocol messages.js> <server session.js> <client daemon-client.js>");
    process.exit(1);
}

const SENTINEL = "[paseo-send-keep-pending-permissions]";
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

// ── protocol messages.js ───────────────────────────────────────────────────
const SCHEMA_ANCHOR = lines(
    '    type: z.literal("send_agent_message_request"),',
    "    requestId: z.string(),",
    "    /** Accepts full ID, unique prefix, or exact full title (server resolves). */",
    "    agentId: z.string(),",
    "    text: z.string(),",
    "    messageId: z.string().optional(), // Client-provided ID for deduplication",
    "    guard: AgentMessageSendGuardSchema.optional(),",
    "    activeTurnBehavior: ActiveTurnBehaviorSchema.optional(),",
);
const SCHEMA_REPLACEMENT = lines(
    SCHEMA_ANCHOR,
    `    // ${SENTINEL} Absent = server default (true: a message answers pending permissions).`,
    "    clearPendingPermissions: z.boolean().optional(),",
);

// ── server session.js ──────────────────────────────────────────────────────
const SERVER_ANCHOR = lines(
    '                activeTurnBehavior: msg.activeTurnBehavior ?? "interrupt",',
    "                clearPendingPermissions: true,",
    "                logger: this.sessionLogger,",
);
const SERVER_REPLACEMENT = lines(
    '                activeTurnBehavior: msg.activeTurnBehavior ?? "interrupt",',
    `                // ${SENTINEL} Automatic senders pass false; everyone else keeps the default true.`,
    "                clearPendingPermissions: msg.clearPendingPermissions ?? true,",
    "                logger: this.sessionLogger,",
);

// ── client daemon-client.js ────────────────────────────────────────────────
const CLIENT_ANCHOR = lines(
    "            ...(options?.guard ? { guard: options.guard } : {}),",
    "            ...(options?.activeTurnBehavior ? { activeTurnBehavior: options.activeTurnBehavior } : {}),",
    "            ...(options?.images ? { images: options.images } : {}),",
);
const CLIENT_REPLACEMENT = lines(
    "            ...(options?.guard ? { guard: options.guard } : {}),",
    "            ...(options?.activeTurnBehavior ? { activeTurnBehavior: options.activeTurnBehavior } : {}),",
    `            // ${SENTINEL}`,
    '            ...(typeof options?.clearPendingPermissions === "boolean" ? { clearPendingPermissions: options.clearPendingPermissions } : {}),',
    "            ...(options?.images ? { images: options.images } : {}),",
);

const targets = [
    { name: "protocol schema", file: messagesTarget, anchor: SCHEMA_ANCHOR, replacement: SCHEMA_REPLACEMENT },
    { name: "server handler", file: sessionTarget, anchor: SERVER_ANCHOR, replacement: SERVER_REPLACEMENT },
    { name: "client sendAgentMessage", file: clientTarget, anchor: CLIENT_ANCHOR, replacement: CLIENT_REPLACEMENT },
];
for (const target of targets) {
    target.source = readTarget(target.file);
}

const patchedCount = targets.filter((target) => target.source.includes(SENTINEL)).length;
if (patchedCount === targets.length) {
    console.log("ALREADY");
    process.exit(10);
}
if (patchedCount !== 0) {
    console.error("SKIP: send-keep-pending-permissions targets are mixed (some targets are already patched)");
    process.exit(20);
}

for (const target of targets) {
    const found = occurrences(target.source, target.anchor);
    if (found !== 1) {
        console.error(`SKIP: ${target.name} anchor missing or duplicated (count=${found})`);
        process.exit(20);
    }
    target.candidate = target.source.replace(target.anchor, () => target.replacement);
    if (!target.candidate.includes(SENTINEL) || target.candidate.length <= target.source.length) {
        console.error(`replacement failed: ${target.name}`);
        process.exit(1);
    }
}

const written = [];
try {
    for (const target of targets) {
        const candidatePath = `${target.file}.paseo-new.mjs`;
        fs.writeFileSync(candidatePath, target.candidate);
        written.push(candidatePath);
    }
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
