// AGPL-3.0-only. Refuse CLI deletion before connection or runtime cancellation.
// 0: candidate written; 10: already applied; 20: unknown/ambiguous target.
import fs from "node:fs";

const [mode, file] = process.argv.slice(2);
if (mode !== "cli" || !file) throw new Error("usage: guard.mjs cli <delete.js>");
const marker = "[paseo-agent-history-delete-guard]";
const anchor = "export async function runDeleteCommand(id, options, _command) {\n";
const guard = [
  `    // ${marker} Refuse before connecting or cancelling running agents.`,
  "    throw {",
  '        code: "PERMANENT_DELETE_DISABLED",',
  '        message: "CLI permanent agent deletion is disabled. Use paseo archive, or the browser for manual deletion.",',
  "    };",
  "",
].join("\n");
const source = fs.readFileSync(file, "utf8");
const expected = anchor + guard;
const count = (text) => source.split(text).length - 1;
if (count(anchor) !== 1 || (source.includes(marker) && count(expected) !== 1)) {
  console.error("SKIP: CLI delete target is missing, ambiguous, or partially patched");
  process.exit(20);
}
if (count(expected) === 1) {
  console.log("ALREADY");
  process.exit(10);
}
fs.writeFileSync(file + ".paseo-new.mjs", source.replace(anchor, expected));
console.log("PATCHED");
