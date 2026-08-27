#!/usr/bin/env bash
# Pure-function test for the hub launcher's D7/F14 tile filter. The function is
# extracted from hub/index.html and exercised in node — no browser, no server.
# Fail-closed is the property under test: an owner-audience tile must be hidden
# for EVERY viewer state except a verified owner, including the fetch-failed
# and role-absent states.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

command -v node >/dev/null 2>&1 \
  || { echo "FAIL hub-filter: node is required (the hub filter is JS)"; exit 1; }

# The pure functions prove the LOGIC; these two greps prove the WIRING — a
# deleted call site would leave every node assertion green while rendering
# owner-audience tiles to collaborators.
grep -qF 'if (!airlockTileVisible(apps[name].audience, me && me.role)) continue;' \
  "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the airlockTileVisible call site is gone from the render loop"; exit 1; }
grep -qF 'const meta = airlockTileMeta(apps[name]);' \
  "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the airlockTileMeta call site is gone from the render loop"; exit 1; }
# The third call site. Without it the page still renders every tile, in one
# nameless grid — no error, no blank screen, just the sections silently gone,
# and with them the on-screen line saying which tiles leave the Airlock gate.
grep -qF 'for (const sec of airlockTileSections(apps, names)) {' \
  "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the airlockTileSections call site is gone from the render loop"; exit 1; }
echo "ok   hub-filter: all three call sites are wired into the render loop"

node - "$ROOT/hub/index.html" <<'JS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
const m = html.match(/function airlockTileVisible\([\s\S]*?\n\}/);
if (!m) { console.log("FAIL hub-filter: airlockTileVisible not found in hub/index.html"); process.exit(1); }
const airlockTileVisible = eval("(" + m[0] + ")");
const m2 = html.match(/function airlockTileMeta\([\s\S]*?\n\}/);
if (!m2) { console.log("FAIL hub-filter: airlockTileMeta not found in hub/index.html"); process.exit(1); }
const airlockTileMeta = eval("(" + m2[0] + ")");
const m3 = html.match(/function airlockTileSections\([\s\S]*?\n\}/);
if (!m3) { console.log("FAIL hub-filter: airlockTileSections not found in hub/index.html"); process.exit(1); }
// The function closes over the default-heading constant, so it has to be
// evaluated with it rather than around it — and reading it out of the page is
// also the assertion that the launcher still owns exactly one heading string.
const mC = html.match(/const AIRLOCK_TOOLS_SECTION = "[^"]*";/);
if (!mC) { console.log("FAIL hub-filter: AIRLOCK_TOOLS_SECTION not found in hub/index.html"); process.exit(1); }
const airlockTileSections = eval(
  "(function(){" + mC[0] + "\n" + m3[0] + "\nreturn airlockTileSections;})()");

let failed = 0;
function check(name, got, want) {
  if (got === want) { console.log("ok   hub-filter: " + name); }
  else { console.log("FAIL hub-filter: " + name + " (got " + got + ", want " + want + ")"); failed = 1; }
}

// no declared audience: owner-only, like any other non-"shared" value. This is
// the fail-closed default — an app that never said who it serves does not get
// the collaborator tier by omission.
check("undeclared audience, owner",        airlockTileVisible(undefined, "owner"), true);
check("undeclared audience, collaborator", airlockTileVisible(undefined, "collaborator"), false);
check("undeclared audience, whoami down",  airlockTileVisible(undefined, undefined), false);
// an audience string this launcher does not know is not a licence either
check("unknown audience, collaborator",    airlockTileVisible("everyone", "collaborator"), false);
check("shared audience, collaborator",     airlockTileVisible("shared", "collaborator"), true);
check("shared audience, whoami down",      airlockTileVisible("shared", undefined), true);

// owner audience: ONLY a verified owner sees the tile
check("owner audience, owner",             airlockTileVisible("owner", "owner"), true);
check("owner audience, collaborator",      airlockTileVisible("owner", "collaborator"), false);
check("owner audience, role null (also the me=null whoami-down shape)",
      airlockTileVisible("owner", null), false);
check("owner audience, role absent",       airlockTileVisible("owner", undefined), false);

// tile model selection (F14, child 4/P3: manifest webjson only — the built-in
// APPS registry and its name-fallback are gone): no [tile] renders NOTHING;
// a declared [tile] renders from the manifest fields alone.
check("no tile -> renders nothing", airlockTileMeta({}), null);
const t = airlockTileMeta({ tile:
      { label: "P", sub: "x", cat: "docs", glyph: "app-notepad" } });
check("tile -> label from manifest", t && t.label, "P");
check("tile -> glyph from manifest", t && t.glyph, "app-notepad");
const ti = airlockTileMeta({ tile:
      { label: "P", cat: "docs", icon: "/assets/apps/p/i.svg" } });
check("tile icon -> brand image path", ti && ti.brand, "/assets/apps/p/i.svg");

// Section grouping. `section` reaches the launcher only on a shortcut, always
// filled in by bin/airlock-config, so a tile without one is a package.
const SEC = {
  fileview: {},
  chat:  { shortcut: true, section: "Shared services" },
  drive: { shortcut: true, section: "Shared services" },
  board: { shortcut: true, section: "Shortcuts" },
};
const grouped = airlockTileSections(SEC, ["fileview", "chat", "drive", "board"]);
check("sections: one group per distinct heading", grouped.length, 3);
check("sections: packages keep the launcher's own heading", grouped[0].title, "Tools");
check("sections: a package lands under it", grouped[0].names.join(","), "fileview");
check("sections: shortcuts sharing a heading share a group",
      grouped[1].title + "=" + grouped[1].names.join(","), "Shared services=chat,drive");
check("sections: later headings follow in first-seen order", grouped[2].title, "Shortcuts");

// The pin. webjson is sorted by app id, so on most boxes the packages happen to
// come first and plain first-seen order looks correct — until one shortcut id
// sorts ahead of them and the launcher opens with the tiles that send you away.
const pinned = airlockTileSections(SEC, ["chat", "fileview", "board"]);
check("sections: the packages group is pinned first", pinned[0].title, "Tools");
check("sections: pinning does not reorder the rest",
      pinned.map(s => s.title).join(","), "Tools,Shared services,Shortcuts");
check("sections: no packages -> no empty Tools heading",
      airlockTileSections(SEC, ["chat", "board"]).map(s => s.title).join(","),
      "Shared services,Shortcuts");
check("sections: nothing to place -> nothing to draw",
      airlockTileSections(SEC, []).length, 0);

process.exit(failed);
JS
echo "---"
echo "hub-filter: all assertions passed"
