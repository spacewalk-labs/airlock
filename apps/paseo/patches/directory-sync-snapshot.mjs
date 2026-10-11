// SPDX-License-Identifier: AGPL-3.0-only
// A device whose cursor has passed a removal never receives it: a changes read
// returns only what is newer than the cursor, so an archived workspace or agent
// stays on that device until the daemon restarts. Workspace and agent directory
// reads answer with the full list instead; the client replaces its own list on
// a snapshot. Project reads keep their cursor.
import fs from "node:fs";
const target = process.argv[2];
if (!target) throw new Error("usage: directory-sync-snapshot.mjs <directory-sync/index.js>");
const source = fs.readFileSync(target, "utf8");
const marker = "[paseo-directory-sync-snapshot]";
if (source.includes(marker)) { console.log("ALREADY"); process.exit(10); }
const anchors = ["this.workspaces", "this.agents"].map((collection) => `        const read = this.read(${collection}, cursor);`);
if (anchors.some((anchor) => source.split(anchor).length !== 2)) { console.error("SKIP: directory read anchor missing or ambiguous"); process.exit(20); }
// Dropping afterSeq keeps upstream's own snapshot reasons (no_cursor / generation_changed).
const patched = anchors.reduce((text, anchor) => text.replace(anchor,
    `        // ${marker} A cursor is not proof the device applied every removal before it.\n${anchor.replace(", cursor)", ", { generation: cursor.generation })")}`), source);
fs.writeFileSync(`${target}.paseo-new.mjs`, patched);
console.log("PATCHED");
