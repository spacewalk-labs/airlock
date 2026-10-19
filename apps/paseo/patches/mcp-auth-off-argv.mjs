// SPDX-License-Identifier: AGPL-3.0-only
// The daemon injects its Agent MCP server into every seat's launch config with an
// `Authorization: Bearer <capability token>` header (agent/runtime-mcp-config.js).
// Two places then write that header where anything on the box can read it:
//   claude-query  the Agent SDK passes MCP servers to claude as inline JSON
//                 (`--mcp-config {...}`), so the header sits in argv (ps, /proc/<pid>/cmdline).
//                 claude also takes a file path there: write the JSON to a 0600 file in a
//                 fresh 0700 directory, pass the path, remove the directory when claude exits.
//   projections   providers describe their session with the launch config, so the stored
//                 agent record keeps metadata.mcpServers.paseo with the header. The daemon
//                 re-injects that server on every launch and resume, so drop it before the
//                 record reaches disk. User MCP servers stay.
// Exit 0 writes <target>.paseo-new.mjs, 10 means already applied, 20 means the
// anchors are missing or ambiguous and nothing was written.
import fs from "node:fs";
const [mode, target] = process.argv.slice(2);
const marker = "[airlock-mcp-auth-off-argv]";
const edits = {
    "claude-query": [
        ['import { query } from "@anthropic-ai/claude-agent-sdk";\n',
            'import { query } from "@anthropic-ai/claude-agent-sdk";\n'
            + 'import { mkdtempSync, rmSync, writeFileSync } from "node:fs";\n'
            + 'import { tmpdir } from "node:os";\n'
            + 'import { join } from "node:path";\n'],
        ["function isChildProcessWithStreams(child) {\n",
            `// ${marker} Inline --mcp-config JSON carries every MCP header into argv.\n`
            + "// claude reads the same JSON from a file path, so hand it a 0600 file instead.\n"
            + "function moveInlineMcpConfigToFile(args) {\n"
            + '    const index = args.indexOf("--mcp-config");\n'
            + "    const value = index === -1 ? undefined : args[index + 1];\n"
            + '    if (typeof value !== "string" || !value.trimStart().startsWith("{")) {\n'
            + "        return { args, cleanup: () => { } };\n"
            + "    }\n"
            + '    const dir = mkdtempSync(join(tmpdir(), "paseo-mcp-"));\n'
            + '    const file = join(dir, "mcp-config.json");\n'
            + "    writeFileSync(file, value, { mode: 0o600 });\n"
            + "    const next = [...args];\n"
            + "    next[index + 1] = file;\n"
            + "    return { args: next, cleanup: () => rmSync(dir, { recursive: true, force: true }) };\n"
            + "}\n"
            + "function isChildProcessWithStreams(child) {\n"],
        ["            const resolved = resolveClaudeSpawnCommand(spawnOptions, runtimeSettings);\n",
            "            const resolved = resolveClaudeSpawnCommand(spawnOptions, runtimeSettings);\n"
            + "            const mcpConfig = moveInlineMcpConfigToFile(resolved.args);\n"
            + "            resolved.args = mcpConfig.args;\n"],
        ["            onChildProcess?.(child);\n",
            '            child.once("exit", mcpConfig.cleanup);\n'
            + '            child.once("error", mcpConfig.cleanup);\n'
            + "            onChildProcess?.(child);\n"],
    ],
    projections: [
        ['import { isStoredAgentProviderAvailable, toAgentPersistenceHandle } from "../persistence-hooks.js";\n',
            'import { isStoredAgentProviderAvailable, toAgentPersistenceHandle } from "../persistence-hooks.js";\n'
            + 'import { stripInternalPaseoMcpServer } from "./runtime-mcp-config.js";\n'],
        ["    const metadata = sanitizeMetadata(handle.metadata);\n",
            "    const metadata = withoutInternalPaseoMcpServer(sanitizeMetadata(handle.metadata));\n"],
        ["function projectPersistenceHandleForWire(handle) {\n",
            `// ${marker} The stored record must not keep the daemon's own MCP server: its\n`
            + "// Authorization header is the capability token, and the daemon re-injects it on launch.\n"
            + "function withoutInternalPaseoMcpServer(metadata) {\n"
            + '    if (!metadata?.mcpServers || typeof metadata.mcpServers !== "object") {\n'
            + "        return metadata;\n"
            + "    }\n"
            + "    const { mcpServers } = stripInternalPaseoMcpServer({ mcpServers: metadata.mcpServers });\n"
            + "    const next = { ...metadata };\n"
            + "    if (mcpServers) {\n"
            + "        next.mcpServers = mcpServers;\n"
            + "    }\n"
            + "    else {\n"
            + "        delete next.mcpServers;\n"
            + "    }\n"
            + "    return next;\n"
            + "}\n"
            + "function projectPersistenceHandleForWire(handle) {\n"],
    ],
}[mode];
if (!edits || !target) {
    console.error("usage: mcp-auth-off-argv.mjs <claude-query|projections> <target-js>");
    process.exit(1);
}
const source = fs.readFileSync(target, "utf8");
if (source.includes(marker)) {
    console.log("ALREADY");
    process.exit(10);
}
if (edits.some(([anchor]) => source.split(anchor).length !== 2)) {
    console.error(`SKIP: ${mode} anchors missing or ambiguous (upstream drift?)`);
    process.exit(20);
}
fs.writeFileSync(`${target}.paseo-new.mjs`, edits.reduce((text, [anchor, replacement]) => text.replace(anchor, () => replacement), source));
console.log("PATCHED");
