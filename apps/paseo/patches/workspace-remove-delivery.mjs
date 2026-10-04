// SPDX-License-Identifier: AGPL-3.0-only
// A changes-only subscription has no lastEmitted entry for unchanged cached rows.
// Absence of an emitted upsert must not suppress their later removal.
import fs from "node:fs";
const target = process.argv[2];
if (!target) throw new Error("usage: workspace-remove-delivery.mjs <session.js>");
const source = fs.readFileSync(target, "utf8");
const marker = "[paseo-workspace-remove-delivery]";
if (source.includes(marker)) { console.log("ALREADY"); process.exit(10); }
const anchor = "        return !lastEmitted && !removedProjectId;";
if (source.split(anchor).length !== 2) { console.error("SKIP: removal anchor missing or ambiguous"); process.exit(20); }
fs.writeFileSync(`${target}.paseo-new.mjs`, source.replace(anchor,
    `        // ${marker} Cached rows may be absent from changes-only bootstrap.\n        return false;`));
console.log("PATCHED");
