// SPDX-License-Identifier: AGPL-3.0-only
// usage: mcp-auth-off-argv.test.mjs <claude/query.js> <agent/agent-projections.js>
// Drives the shipped modules: a real child spawned through claudeQuery must see a file
// path (0600, JSON intact) instead of inline --mcp-config JSON, and the file must be gone
// after the child exits; a stored agent record must keep user MCP servers and lose only
// the daemon's own /mcp/agents server.
import assert from "node:assert/strict";
import fs from "node:fs";
import { pathToFileURL } from "node:url";
const [queryJs, projectionsJs] = process.argv.slice(2);
const { claudeQuery } = await import(pathToFileURL(queryJs).href);
const { toStoredAgentRecord } = await import(pathToFileURL(projectionsJs).href);

const inline = JSON.stringify({ mcpServers: { paseo: { type: "http", url: "http://127.0.0.1:1/mcp/agents?callerAgentId=a", headers: { Authorization: "Bearer test-token" } } } });
let child;
claudeQuery({ prompt: "", options: {} }, {
    queryFactory: ({ options }) => {
        child = options.spawnClaudeCodeProcess({
            command: "/bin/sh",
            args: ["-c", 'stat -c %a "$2"; cat "$2"', "sh", "--mcp-config", inline],
            cwd: process.cwd(),
            env: process.env,
        });
    },
});
let out = "";
child.stdout.on("data", (chunk) => { out += chunk; });
const exited = new Promise((resolve) => child.once("exit", resolve));
assert.ok(!child.spawnargs.some((arg) => arg.includes("test-token")), "the bearer is not in argv");
const file = child.spawnargs.at(-1);
await exited;
assert.equal(out, `600\n${inline}`, "claude reads the same JSON from a 0600 file");
await new Promise((resolve) => setImmediate(resolve));
assert.ok(!fs.existsSync(file), "the file is removed when claude exits");

const now = new Date();
const record = toStoredAgentRecord({
    id: "a", provider: "claude", cwd: "/tmp", createdAt: now, updatedAt: now, labels: {},
    lifecycle: "idle", config: { provider: "claude", cwd: "/tmp" }, features: [],
    attention: { requiresAttention: false },
    persistence: { provider: "claude", sessionId: "s", metadata: { cwd: "/tmp", mcpServers: {
        ...JSON.parse(inline).mcpServers,
        mine: { type: "http", url: "https://example.test/mcp", headers: { "X-Keep": "1" } },
    } } },
});
assert.deepEqual(Object.keys(record.persistence.metadata.mcpServers), ["mine"], "only the daemon's own server is dropped");
assert.ok(!JSON.stringify(record).includes("test-token"), "the stored record carries no bearer");
console.log("PASS mcp auth off argv");
