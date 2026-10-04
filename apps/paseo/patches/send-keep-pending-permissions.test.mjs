// SPDX-License-Identifier: AGPL-3.0-only
// Behavior check for send-keep-pending-permissions.mjs.
//
//   node send-keep-pending-permissions.test.mjs <messages.js> <session.js> <daemon-client.js>
// Pass the three candidates (or installed, patched files). Drives, with stubs and no daemon:
//   schema  - the real zod schema keeps clearPendingPermissions (true/false) and accepts its absence
//   client  - the shipped sendAgentMessage puts a boolean on the wire, and nothing when it is absent
//   server  - the shipped handler hands sendPromptToAgent true when absent, false when false
// Also runs the patcher against the pristine inputs it can derive (drift and idempotence cases).
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import vm from "node:vm";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

const [messagesFile, sessionFile, clientFile] = process.argv.slice(2);
if (!messagesFile || !sessionFile || !clientFile) {
    throw new Error("usage: test.mjs <messages.js> <session.js> <daemon-client.js>");
}
const SENTINEL = "[paseo-send-keep-pending-permissions]";
for (const file of [messagesFile, sessionFile, clientFile]) {
    assert.ok(fs.readFileSync(file, "utf8").includes(SENTINEL), `not patched: ${file}`);
}

function method(source, startMarker, endMarker) {
    const start = source.indexOf(startMarker);
    const end = source.indexOf(endMarker, start);
    assert.ok(start >= 0 && end > start, `method not found: ${startMarker}`);
    return source.slice(start, end);
}

// ── schema ─────────────────────────────────────────────────────────────────
// The candidate sits beside the original, so its relative and package imports resolve.
const messages = await import(`${pathToFileURL(path.resolve(messagesFile)).href}?t=${Date.now()}`);
const base = { type: "send_agent_message_request", requestId: "r1", agentId: "a1", text: "hi", activeTurnBehavior: "steer" };
for (const schema of [messages.SendAgentMessageRequestSchema, messages.SessionInboundMessageSchema]) {
    assert.equal(schema.parse({ ...base, clearPendingPermissions: false }).clearPendingPermissions, false);
    assert.equal(schema.parse({ ...base, clearPendingPermissions: true }).clearPendingPermissions, true);
    assert.equal("clearPendingPermissions" in schema.parse(base), false);
    assert.throws(() => schema.parse({ ...base, clearPendingPermissions: "no" }));
}

// ── client ─────────────────────────────────────────────────────────────────
const clientSource = fs.readFileSync(clientFile, "utf8");
const clientText = method(clientSource, "    async sendAgentMessage(agentId, text, options) {", "    parseSendAgentMessagePayload(");
async function clientWire(options) {
    let wire;
    const client = vm.runInNewContext(`({ ${clientText} })`, {
        crypto: { randomUUID: () => "m1" },
        SessionInboundMessageSchema: messages.SessionInboundMessageSchema,
    });
    await client.sendAgentMessage.call({
        requireAgentMessageSendGuard() {},
        createRequestId: () => "r1",
        async sendRequest({ message }) {
            wire = message;
            return { accepted: true };
        },
        parseSendAgentMessagePayload() {},
    }, "a1", "hi", options);
    return wire;
}
assert.equal("clearPendingPermissions" in (await clientWire({ activeTurnBehavior: "steer" })), false);
assert.equal("clearPendingPermissions" in (await clientWire(undefined)), false);
assert.equal((await clientWire({ clearPendingPermissions: false })).clearPendingPermissions, false);
assert.equal((await clientWire({ clearPendingPermissions: true })).clearPendingPermissions, true);

// ── server ─────────────────────────────────────────────────────────────────
const sessionSource = fs.readFileSync(sessionFile, "utf8");
const serverText = method(sessionSource, "    async handleSendAgentMessageRequest(msg) {", "    async handleWaitForFinish(");
async function serverCall(wireMessage) {
    // Same path as production: the inbound message went through the real schema first.
    const msg = messages.SessionInboundMessageSchema.parse(wireMessage);
    const seen = [];
    const emitted = [];
    const session = vm.runInNewContext(`({ ${serverText} })`, {
        AgentMessageSendGuardRejectedError: class extends Error {},
        buildAgentPrompt: (text) => text,
        sendPromptToAgent: async (args) => {
            seen.push(args);
            return { disposition: "turn_started" };
        },
        ensureAgentLoaded: async () => {},
        waitForAgentRunStartWithTimeout: async () => {},
        isAgentMessageSendGuardRejectedError: () => false,
        errorToFriendlyMessage: String,
    });
    await session.handleSendAgentMessageRequest.call({
        resolveAgentIdentifier: async (id) => ({ ok: true, agentId: id }),
        sessionLogger: { trace() {} },
        agentManager: {},
        agentStorage: {},
        agentRequests: { send: async ({ prepare, send }) => { await prepare(); await send(); } },
        emit: (event) => emitted.push(event),
        handleAgentRunError() {},
    }, msg);
    assert.equal(emitted.at(-1).payload.accepted, true, JSON.stringify(emitted));
    assert.equal(seen.length, 1);
    return seen[0];
}
for (const extra of [{}, { messageId: "m1" }]) {
    assert.equal((await serverCall({ ...base, ...extra })).clearPendingPermissions, true);
    assert.equal((await serverCall({ ...base, ...extra, clearPendingPermissions: true })).clearPendingPermissions, true);
    const kept = await serverCall({ ...base, ...extra, clearPendingPermissions: false });
    assert.equal(kept.clearPendingPermissions, false);
    assert.equal(kept.activeTurnBehavior, "steer");
}

// ── patcher drift / mixed state (on copies of the patched files) ───────────
const patcher = path.join(path.dirname(new URL(import.meta.url).pathname), "send-keep-pending-permissions.mjs");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "paseo-send-keep-"));
try {
    const copies = [messagesFile, sessionFile, clientFile].map((file, index) => {
        const copy = path.join(temp, `t${index}.js`);
        fs.copyFileSync(file, copy);
        return copy;
    });
    const run = (files) => spawnSync(process.execPath, [patcher, ...files], { encoding: "utf8" });
    assert.equal(run(copies).status, 10, "all patched must be ALREADY");
    fs.writeFileSync(copies[1], fs.readFileSync(copies[1], "utf8").replaceAll(SENTINEL, "x"));
    const mixed = run(copies);
    assert.equal(mixed.status, 20, "mixed state must be refused");
    assert.deepEqual(fs.readdirSync(temp).filter((name) => name.endsWith(".paseo-new.mjs")), []);
}
finally {
    fs.rmSync(temp, { recursive: true, force: true });
}
console.log("PASS: schema keeps clearPendingPermissions; client forwards booleans only; server defaults true and honours false; mixed/ALREADY states handled");
