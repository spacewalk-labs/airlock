// Exercise the actual CLI entry point without connecting to a daemon.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import vm from "node:vm";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const [input] = process.argv.slice(2);
if (!input) throw new Error("usage: test.mjs <delete.js>");
const temp = fs.mkdtempSync(path.join(os.tmpdir(), "paseo-cli-delete-guard-"));
const original = fs.readFileSync(input, "utf8");
function patch(source, expected) {
  const file = path.join(temp, "delete.js");
  fs.writeFileSync(file, source);
  fs.rmSync(file + ".paseo-new.mjs", { force: true });
  const result = spawnSync(process.execPath, [path.join(here, "agent-history-delete-guard.mjs"), "cli", file], { encoding: "utf8" });
  assert.equal(result.status, expected, result.stderr);
  assert.equal(fs.readFileSync(file, "utf8"), source);
  if (expected !== 0) {
    assert.equal(fs.existsSync(file + ".paseo-new.mjs"), false);
    return source;
  }
  const candidate = file + ".paseo-new.mjs";
  assert.equal(spawnSync(process.execPath, ["--check", candidate]).status, 0);
  return fs.readFileSync(candidate, "utf8");
}
try {
  const guarded = patch(original, original.includes("[paseo-agent-history-delete-guard]") ? 10 : 0);
  patch(guarded, 10);
  patch(original.replace("runDeleteCommand(id, options, _command)", "changedDeleteCommand(id, options, _command)"), 20);
  patch(original + "\nexport async function runDeleteCommand(id, options, _command) {\n}\n", 20);
  patch(guarded.replace('code: "PERMANENT_DELETE_DISABLED"', 'code: "broken"'), 20);
  const start = guarded.indexOf("export async function runDeleteCommand(");
  const end = guarded.indexOf("\n//# sourceMappingURL", start);
  assert.ok(start >= 0);
  const body = guarded.slice(start, end < 0 ? undefined : end).replace("export async function", "async function");
  const runDelete = vm.runInNewContext(`(${body})`, {
    connectToDaemon: async () => { throw new Error("delete connected before refusal"); },
    getDaemonHost: () => { throw new Error("delete accessed configuration before refusal"); },
  });
  for (const [id, options] of [["one", {}], [undefined, { all: true }], [undefined, { cwd: "/workspace" }]]) {
    await assert.rejects(runDelete(id, options), (error) => error.code === "PERMANENT_DELETE_DISABLED");
  }
  console.log("PASS: single/bulk CLI deletes refuse before connecting/cancelling; idempotence and drift checks pass");
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
