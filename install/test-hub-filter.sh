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

# The pure functions prove the LOGIC; these greps prove the WIRING — a
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

# The settings gear's wiring, same reasoning as the three above: the badge
# arithmetic below is exercised in node against contract fixtures, and node
# cannot tell whether anything on the page ever calls it. Each of these is a
# deletion that would leave every assertion green and the launcher wrong.
grep -qF 'const count = airlockUpdateCount(d);' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the gear badge no longer computes its count from airlockUpdateCount"; exit 1; }
grep -qF 'badge.hidden = count === 0;' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the badge is no longer hidden at zero (a '0' badge is the bug)"; exit 1; }
grep -qF 'function renderDots(d) { wanted = new Set(airlockUpdateAppIds(d)); paintDots(); }' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the tile dots no longer read the same app list as the badge"; exit 1; }
# The panel rows read the SAME normaliser. `for (const a of d.apps)` on an
# `apps: {}` throws after the badge has been rewritten and before the dots have,
# which leaves a count and a set of dots that disagree and no error on screen.
grep -qF 'for (const a of airlockUpdateApps(d)) {' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the panel rows no longer read the same app list as the badge"; exit 1; }
# The strip's failure discipline, restated for this poller: 403/404 is the only
# state that removes the gear; every other failure keeps the last render. A
# collapsed `if (!r.ok)` would blank the badge on a 502 and read as "all done".
grep -qF 'if (r.status === 403 || r.status === 404) {' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the updates poll no longer hides the gear on 403/404"; exit 1; }
grep -qF 'if (!r.ok) return;                          // unexpected status' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the updates poll no longer keeps the last render on an unexpected status"; exit 1; }
# A 200 can carry `null` or a list. Rendering one blanks the badge on its way to
# throwing, which is the keep-the-last-render rule failing in the exact shape it
# exists to prevent — so a non-object payload is an unexpected payload.
grep -qF 'if (!d || typeof d !== "object" || Array.isArray(d)) return;' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the updates poll renders payloads that are not objects"; exit 1; }
# Taking the gear away has to take the tile dots with it, or the launcher keeps
# showing update marks for a feature the box no longer offers.
grep -qF 'renderDots(null);                         // and no orphaned tile dots either' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: hiding the gear on 403/404 no longer clears the tile dots"; exit 1; }
# The poll can win the race with the launcher's own tile rendering and find no
# tiles at all; without this the first dots would wait a full poll interval.
grep -qF 'new MutationObserver(paintDots).observe(secs, { childList: true, subtree: true });' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: tile dots are no longer re-applied to tiles that render late"; exit 1; }
# /whoami returns null for a dropped connection exactly as it does for "not the
# owner". Deciding once at load makes one bad moment cost the owner the gear
# until reload, so only a DEFINITE non-owner answer stops the poll.
grep -qF 'if (isOwner === false) { clearInterval(timer); return; }' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the settings poll no longer retries an unresolved identity"; exit 1; }
# UPD_EXEC arms the panel's buttons. Which actions are armed is the pure function
# exercised in node below; these prove it is what the DOM actually asks.
grep -qF 'b.disabled = !airlockUpdActionArmed(o.action);' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: settings buttons no longer decide arming from airlockUpdActionArmed"; exit 1; }
grep -qF 'const body = airlockUpdActionBody(button.dataset.updAction);' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the settings click handler no longer builds its body from airlockUpdActionBody"; exit 1; }
# HARNESS_PANEL's four rows, same reasoning: node can check the line each row
# prints, and cannot check that renderHarness still calls the function that
# prints it. Each of these is a deletion that leaves every assertion green.
for call in \
  'const claude = airlockClaudeLine(d);' \
  'const codex = airlockCodexLine(d);' \
  'const skills = airlockSkillsLine(d);' \
  '{ button: "지금 점검", kind: "see",' ; do
  grep -qF "$call" "$ROOT/hub/index.html" \
    || { echo "FAIL hub-filter: the harness section no longer calls: $call"; exit 1; }
done
# 🔴 The hook row must stay display-only (owner decision HARNESS_V1). An armed
# action here would be the panel applying a hook, which is the one thing this
# row exists NOT to do — and it would pass every pure-function test below.
grep -qE 'action: "harness:(hooks|provision)' "$ROOT/hub/index.html" \
  && { echo "FAIL hub-filter: the hook row has grown a runnable action (HARNESS_V1)"; exit 1; }
# The two families are gated separately: an airlock-update in flight says nothing
# about whether the Codex CLI can be upgraded.
grep -qF 'b.disabled = !airlockHarnessActionArmed(b.dataset.harnessAction) || harnessBlocked;' \
  "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the harness buttons no longer have their own blocked gate"; exit 1; }
echo "ok   hub-filter: the harness section's call sites are wired"
grep -qF 'if (!body) return;                         // drawn, but not ours to run' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: a button this build does not run can now reach the execute route"; exit 1; }
# The whole reason completion is read from a record instead of from the response:
# the installer reloads nginx and restarts dev-monitor, so the POST's own connection
# is expected to die on a SUCCESSFUL run. A collapsed catch that reported failure
# there would call every working update a failure.
grep -qF 'scheduleRun(1500);                       // the answer was lost, not the request' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: a lost execute response is treated as a verdict again"; exit 1; }
grep -qF 'catch (_) { scheduleRun(5000); return; }   // mid-update disconnect: try again soon' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the run poll no longer survives the mid-update disconnect"; exit 1; }
# Rows are rebuilt from scratch on every snapshot render, which silently un-disables
# every button unless the run gate is re-applied after the rebuild.
grep -qF 'applyRunState();' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the run gate is no longer re-applied after rows are rebuilt"; exit 1; }
# These are WIRING, not behaviour: they prove the call sites and guards are
# present, not that the rendered page obeys them. The badge arithmetic below is
# the behavioural half that node can run; the DOM half (dots cleared on 404,
# last render kept through a 5xx) is measured with a browser against the same
# contract fixtures, and is recorded in the PR rather than run here — CI has no
# browser, and a suite that silently skips its only real assertion is worse than
# one that says where the assertion lives.
echo "ok   hub-filter: the settings gear, badge, dots and poll discipline are wired"

# ACCT_OWN: the identity pill is the entrance to subscription accounts, and the
# same three deletions apply — each would leave every node assertion below green
# and the pill inert or lying. The pill only becomes an entrance once /acct-alert
# has actually answered, so `arm()` inside the poll is the whole gate; hoisting it
# to load time would put a modal on a pill with nothing behind it.
grep -qF 'base = airlockAccountPanelBase(cfg && cfg.apps, cfg && cfg.fqdn, location.hostname);' \
  "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the pill no longer derives the account panel from webjson"; exit 1; }
grep -qF 'arm();                                            // it answered: there is a panel' \
  "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the pill is armed somewhere other than a successful /acct-alert"; exit 1; }
grep -qF 'if (!me || me.role !== "owner") return;           // collaborators draw no fetch' \
  "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the pill entrance no longer requires a verified owner"; exit 1; }
# One implementation, three hosts. The pill must open the platform panel by iframe,
# not grow a second copy of the account list on this origin.
grep -qF 'frame.src = base + "panel.html?p=accounts&embed=1";' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the pill no longer opens the platform account panel"; exit 1; }
# The close message is cross-origin by construction (the panel is on devterm's
# port). Without the origin comparison any framed page on the hub could close the
# modal — and accepting the legacy spelling here would be a new reason to keep an
# already-scheduled deletion alive.
grep -qF 'if (!base || e.data !== "airlock-panel-close") return;' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the pill accepts a close message it should not"; exit 1; }
grep -qF 'if (e.origin === want) closePanel();' "$ROOT/hub/index.html" \
  || { echo "FAIL hub-filter: the pill closes on a message from any origin"; exit 1; }
echo "ok   hub-filter: the identity pill entrance, its owner gate and its close message are wired"

node - "$ROOT/hub/index.html" <<'JS'
const fs = require("fs");
const html = fs.readFileSync(process.argv[2], "utf8");
let failed = 0;
function sourceCheck(name, condition) {
  if (condition) { console.log("ok   hub-filter: " + name); }
  else { console.log("FAIL hub-filter: " + name); failed = 1; }
}

// The owner explicitly removed recents, rather than merely hiding its section:
// no duplicate tile DOM, click tracking, or local-storage state remains. These
// sentinels make a future reintroduction a deliberate product decision.
sourceCheck("recent launcher state and markup are absent",
  !/AIRLOCK_RECENTS|renderRecents|airlockRememberRecent|recent-apps|id="recent"/.test(html));

// Descriptions stay in the tile model and DOM path, but the home screen hides
// them by default. The root attribute is the one-line opt-in for a future
// preference or long-press reveal; do not remove the data to obtain this look.
sourceCheck("tile descriptions default to hidden with an explicit opt-in",
  html.includes('.app .sub { display: none;') &&
  html.includes(':root[data-tile-descriptions="visible"] .app .sub { display: block;') &&
  html.includes('sub.textContent = meta.sub;') &&
  !html.includes('a.title = meta.sub;'));

// A phone keeps home-screen density — four icons, like an iPhone. It is a floor,
// not a cap: the 124px minimum the wider layout uses would give a 350px phone
// column two tiles, and that one width is the only place auto-fill cannot reach a
// sensible answer.
sourceCheck("phone layout is a four-column grid",
  html.includes('grid-template-columns: repeat(4, minmax(0, 1fr));'));

// The regression this pins is not the column count, it is the CONDITION. The phone
// grid used to be selected by `(hover: none), (pointer: coarse)` alone — questions
// about the input, not the screen — so an iPad answered yes to both at 1366px and
// got three tiles stretched across the page with the rest of the row empty
// (owner, 2026-09-05). Counting columns would not have caught that; both layouts
// were present and correct, the wrong one was chosen. So assert that every touch
// test carries a width bound, which is the thing that was missing.
const phoneMedia = html.match(/@media \(max-width: 560px\),[\s\S]*?\{/);
sourceCheck("the phone grid is chosen by width, not by pointer type alone",
  !!phoneMedia &&
  /\(hover: none\) and \(max-width: \d+px\)/.test(phoneMedia[0]) &&
  /\(pointer: coarse\) and \(max-width: \d+px\)/.test(phoneMedia[0]) &&
  !/\(hover: none\)\s*,/.test(phoneMedia[0]) &&
  !/\(pointer: coarse\)\s*,/.test(phoneMedia[0]));

// The page column is one value, not five literals that have to be kept in step.
sourceCheck("the page column comes from a single token",
  html.includes('max-width: var(--airlock-page)') &&
  !html.includes('max-width: 880px'));
sourceCheck("search is icon-triggered and its controls meet the 44px target",
  html.includes('id="find-open"') && html.includes('id="find-close"') &&
  html.includes('width: 44px; height: 44px;') &&
  html.includes('findOpen.addEventListener("click"') &&
  html.includes('findClose.addEventListener("click"') &&
  html.includes('if (!find.value.trim()) closeFind();'));
// UPD_EXEC's arming decision. `review:` is the one that matters most: an external
// package's lock re-approval is a terminal procedure (owner decision LOCK_UI_V1), and
// this is the panel's half of refusing it. The backend refuses the same id too.
const mUpdArmed = html.match(/function airlockUpdActionArmed\([\s\S]*?\n\}/);
if (!mUpdArmed) { console.log("FAIL hub-filter: airlockUpdActionArmed not found in hub/index.html"); process.exit(1); }
const airlockUpdActionArmed = eval("(" + mUpdArmed[0] + ")");
const mUpdBody = html.match(/function airlockUpdActionBody\([\s\S]*?\n\}/);
if (!mUpdBody) { console.log("FAIL hub-filter: airlockUpdActionBody not found in hub/index.html"); process.exit(1); }
const airlockUpdActionBody = eval("(" + mUpdBody[0] + ")");
const mUpdStatus = html.match(/function airlockUpdStatusText\([\s\S]*?\n\}/);
if (!mUpdStatus) { console.log("FAIL hub-filter: airlockUpdStatusText not found in hub/index.html"); process.exit(1); }
const mUpdRun = html.match(/function airlockUpdRunLine\([\s\S]*?\n\}/);
if (!mUpdRun) { console.log("FAIL hub-filter: airlockUpdRunLine not found in hub/index.html"); process.exit(1); }
// airlockUpdRunLine closes over airlockUpdStatusText, so both are evaluated together.
const airlockUpdRunLine = eval(
  "(function(){" + mUpdStatus[0] + "\n" + mUpdRun[0] + "\nreturn airlockUpdRunLine;})()");

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

// ---- UPD_EXEC: which buttons run, and what the run line says ----------------
check("armed: the platform button runs",       airlockUpdActionArmed("platform"), true);
check("armed: a built-in app button runs",     airlockUpdActionArmed("app:notes"), true);
// The lock decision, as a test rather than a comment: an external package whose
// source digest moved gets review only, in v1, by owner decision (LOCK_UI_V1).
check("armed: a lock review button does NOT run", airlockUpdActionArmed("review:notes"), false);
// The harness actions are a separate namespace with a separate route and a separate
// run record: an airlock-update in flight must not take the Codex button away, and a
// Codex upgrade must not report over an update. They are asserted further down.
check("armed: a harness action is not an update action", airlockUpdActionArmed("harness:codex"), false);
check("armed: an empty app id is not an app",  airlockUpdActionArmed("app:"), false);
check("armed: an absent action runs nothing",  airlockUpdActionArmed(undefined), false);
check("body: platform",  JSON.stringify(airlockUpdActionBody("platform")), '{"action":"platform"}');
check("body: app id is carried whole",
      JSON.stringify(airlockUpdActionBody("app:dev-monitor")),
      '{"action":"app","id":"dev-monitor"}');
check("body: an unarmed action has no body", airlockUpdActionBody("review:notes"), null);

// The run line. `blocked` is what disables the buttons, so each of these is the
// difference between a second update being startable and not.
const RUNNING = { enabled: true, busy: null,
                  run: { status: "running", action: "app", appId: "notes" } };
check("run line: a run in flight blocks the buttons", airlockUpdRunLine(RUNNING).blocked, true);
check("run line: a run in flight names the app",
      airlockUpdRunLine(RUNNING).text.includes("notes"), true);
// busy=true covers an update started in a terminal, or the daily detection timer:
// both hold the updater's own mutex, and neither is ours to talk over.
check("run line: someone else's updater blocks",
      airlockUpdRunLine({ enabled: true, busy: true, run: null }).blocked, true);
// 🔴 The asymmetry that matters: an UNMEASURABLE lock is not a free one and not a
// held one. It must neither block the owner nor claim the box is idle.
check("run line: an unmeasured lock does not block",
      airlockUpdRunLine({ enabled: true, busy: null, run: null }).blocked, false);
check("run line: an unmeasured lock says nothing reassuring",
      airlockUpdRunLine({ enabled: true, busy: null, run: null }).text, "");
check("run line: no execution on this box blocks and says so",
      airlockUpdRunLine({ enabled: false, busy: null, run: null }).blocked, true);
const DONE = { enabled: true, busy: false, run: { status: "done", exitCode: 0,
  action: "platform", before: { revision: "1111111111111111" },
  after: { revision: "2222222222222222", rc: 0, verdict: "ok",
           counts: { fail: 0, warn: 0, unchecked: 0 } } } };
check("run line: a finished run stops blocking", airlockUpdRunLine(DONE).blocked, false);
check("run line: a moved revision is shown as a move",
      airlockUpdRunLine(DONE).detail.includes("111111111111 → 222222222222"), true);
const FAILED = { enabled: true, busy: false, run: { status: "failed", exitCode: 1,
  action: "platform", note: "설치가 실패했습니다.",
  recovery: { available: true, command: 'AIRLOCK_DIR="/r" bash "/g/airlock-update" --rollback' },
  after: { rc: 1, verdict: "fail", counts: { fail: 2, warn: 0, unchecked: 0 } } } };
// The card's second requirement: a failure has to put the recovery command on screen.
check("run line: a failure carries the rollback command",
      airlockUpdRunLine(FAILED).recovery.includes("--rollback"), true);
check("run line: a failure reads as a failure", airlockUpdRunLine(FAILED).bad, true);
check("run line: a failure does not block the next attempt",
      airlockUpdRunLine(FAILED).blocked, false);
// A window closed by hand leaves `running` on disk forever; the backend resolves it
// to `interrupted`, and the panel has to offer recovery for that too.
const INTERRUPTED = { enabled: true, busy: false, run: { status: "interrupted",
  action: "platform", exitCode: null, note: "결과를 남기지 못했습니다.",
  recovery: { available: false, command: "CMD", reason: "기준점 없음" } } };
check("run line: an interrupted run still offers recovery",
      airlockUpdRunLine(INTERRUPTED).recovery, "CMD");
check("run line: an interrupted run repeats why recovery may not apply",
      airlockUpdRunLine(INTERRUPTED).recoveryNote, "기준점 없음");
check("run line: a null state is total", airlockUpdRunLine(null).blocked, false);

// ---- the gear badge, against the update API's contract ---------------------
// The badge is the one number on the launcher a person acts on, and the backend
// that fills it (UPD_DETECT) is being written in parallel — so it is held here
// against fixtures shaped by the published contract rather than by a live box.
// Contract: docs/tasks/active/2026-09-01_airlock-platform-appstore.task.md.
const mU = html.match(/function airlockUpdateCount\([\s\S]*?\n\}/);
const mA = html.match(/function airlockUpdateAppIds\([\s\S]*?\n\}/);
const mN = html.match(/function airlockUpdateApps\([\s\S]*?\n\}/);
const mX = html.match(/function airlockCodexOutdated\([\s\S]*?\n\}/);
if (!mU || !mA || !mN || !mX) {
  console.log("FAIL hub-filter: the badge functions are not all in hub/index.html");
  process.exit(1);
}
// Evaluated together: they close over one another.
const badge = eval("(function(){" + mN[0] + "\n" + mA[0] + "\n" + mX[0] + "\n" + mU[0] +
  "\nreturn {count: airlockUpdateCount, ids: airlockUpdateAppIds," +
  " apps: airlockUpdateApps, codex: airlockCodexOutdated};})()");

// The confirmed mockup's own arithmetic: 본체 1 + 앱 2 + Codex CLI 1 = 4.
const FULL = {
  checkedAt: "2026-09-01T09:20:00Z",
  platform: { available: true, changedCount: 12, ref: "a1b2c3d" },
  apps: [{ id: "notes", action: "upgrade", sourceClass: "builtin" },
         { id: "learning", action: "lock-mismatch", sourceClass: "explicit" }],
  harness: { codex: { installed: "0.144.4", latest: "0.151.0" },
             hooksDrift: 1, skillsWired: true },
};
check("badge: the confirmed mockup's payload", badge.count(FULL), 4);
check("badge: a lock-mismatch app is counted (it needs a person, not a button)",
      badge.ids(FULL).join(","), "notes,learning");

// Nothing waiting. `platform: null` is the contract's shape when there is no
// platform answer at all, and the feature being OFF is a 404, never this.
const NONE = { checkedAt: "2026-09-01T09:20:00Z", platform: null, apps: [],
               harness: { codex: null, hooksDrift: 0, skillsWired: true } };
check("badge: nothing waiting -> 0 (the caller hides the badge)", badge.count(NONE), 0);
check("badge: platform present but not available -> 0",
      badge.count({ platform: { available: false, changedCount: 0 }, apps: [], harness: {} }), 0);

// Hook drift and skill wiring are states to look at, not items to apply. Adding
// them to the badge would make the number stop meaning "things you can apply".
check("badge: hook drift alone does not raise the badge",
      badge.count({ platform: null, apps: [],
                    harness: { codex: null, hooksDrift: 3, skillsWired: false } }), 0);

// Codex is the one harness binary that does not update itself — and the only
// one the badge counts. "Could not check" must not look like "up to date" OR
// like an update: an absent `latest` counts as nothing.
check("badge: codex at the latest version is not counted",
      badge.codex({ harness: { codex: { installed: "0.151.0", latest: "0.151.0" } } }), false);
check("badge: codex with an unknown latest is not counted (check did not run)",
      badge.codex({ harness: { codex: { installed: "0.144.4" } } }), false);
check("badge: codex absent from the payload is not counted",
      badge.codex({ harness: {} }), false);

// Total on junk: this runs on every poll, and a throw would freeze the badge at
// whatever it last showed while the box quietly went stale.
check("badge: no payload -> 0", badge.count(null), 0);
check("badge: empty payload -> 0", badge.count({}), 0);
check("badge: an app entry with no id is dropped, not counted as one",
      badge.count({ apps: [{ action: "upgrade" }, { id: "notes", action: "upgrade" }] }), 1);
// A half-written backend really does emit `apps` as an object or a null, and
// `{}.filter` throws — which takes the whole poll down and freezes the badge at
// a stale number with nothing on screen saying so.
check("badge: apps as an object does not throw, and counts nothing",
      badge.count({ platform: null, apps: {}, harness: {} }), 0);
check("badge: apps as null does not throw", badge.count({ platform: null, apps: null }), 0);
check("badge: apps as a string does not throw", badge.count({ apps: "two" }), 0);
check("badge: a platform that is not an object does not throw",
      badge.count({ platform: "yes", apps: [] }), 0);
// The panel rows iterate this same list, so it has to be an ARRAY for every
// junk shape — `for (const a of {})` throws where `{}.filter` also would.
check("apps normaliser: an object yields an empty array, never a throw",
      Array.isArray(badge.apps({ apps: {} })) && badge.apps({ apps: {} }).length, 0);
check("apps normaliser: entries without an id are dropped before the rows see them",
      badge.apps({ apps: [null, "notes", { action: "upgrade" }, { id: "notes" }] })
        .map(a => a.id).join(","), "notes");
check("apps normaliser: ids and rows come from the same list",
      badge.ids(FULL).join(",") === badge.apps(FULL).map(a => a.id).join(","), true);


// ---- HARNESS_PANEL: the four layers, and the one that can be pressed -------
// The section shows four things and can press one of them. That asymmetry is the
// contract, so it is tested rather than commented: the hook row has no action name
// at all, and the skills row counts per agent root instead of summing.
const mHA = html.match(/function airlockHarnessActionArmed\([\s\S]*?\n\}/);
const mHB = html.match(/function airlockHarnessBody\([\s\S]*?\n\}/);
const mHC = html.match(/function airlockClaudeLine\([\s\S]*?\n\}/);
const mHX = html.match(/function airlockCodexLine\([\s\S]*?\n\}/);
const mHS = html.match(/function airlockSkillsLine\([\s\S]*?\n\}/);
const mHR = html.match(/function airlockHarnessRunLine\([\s\S]*?\n\}/);
const mHW = html.match(/function airlockWhen\([\s\S]*?\n\}/);
if (!mHA || !mHB || !mHC || !mHX || !mHS || !mHR || !mHW) {
  console.log("FAIL hub-filter: the harness functions are not all in hub/index.html");
  process.exit(1);
}
// airlockCodexLine and airlockSkillsLine close over airlockCodexOutdated and
// airlockWhen, so the set is evaluated together.
const harness = eval("(function(){" + mX[0] + "\n" + mHW[0] + "\n" + mHA[0] + "\n" +
  mHB[0] + "\n" + mHC[0] + "\n" + mHX[0] + "\n" + mHS[0] + "\n" + mHR[0] +
  "\nreturn {armed: airlockHarnessActionArmed, body: airlockHarnessBody," +
  " claude: airlockClaudeLine, codex: airlockCodexLine, skills: airlockSkillsLine," +
  " run: airlockHarnessRunLine};})()");

check("harness: the Codex upgrade runs", harness.armed("harness:codex"), true);
check("harness: 지금 점검 runs",          harness.armed("harness:recheck"), true);
// 🔴 Owner decision HARNESS_V1. Reconciling a hook is a reviewed procedure, so there
// is no action name for it — not a disabled one, none.
check("harness: there is no hook action to arm", harness.armed("harness:hooks"), false);
check("harness: an update action is not a harness action",
      harness.armed("platform"), false);
check("harness: an absent action runs nothing", harness.armed(undefined), false);
check("harness body: codex", JSON.stringify(harness.body("harness:codex")), '{"action":"codex"}');
check("harness body: recheck", JSON.stringify(harness.body("harness:recheck")),
      '{"action":"recheck"}');
check("harness body: an unarmed action has no body", harness.body("harness:hooks"), null);

// The Claude row: self-updating, so it carries no comparison at all. The collector
// takes no `latest` for it, and nothing here may manufacture one.
check("harness: the Claude row shows a version and no comparison",
      harness.claude({ harness: { claude: { installed: "2.1.257" } } }),
      "2.1.257 · 자체 자동 업데이트로 최신 유지");
check("harness: no Claude reading draws no Claude row",
      harness.claude({ harness: {} }), "");

// The Codex row: three states, each named. 🔴 "could not ask npm" is NOT "current".
check("harness: a behind Codex offers the new version",
      harness.codex({ harness: { codex: { installed: "0.144.4", latest: "0.152.0" } } })
        .startsWith("0.144.4 → 0.152.0 새 버전"), true);
check("harness: a current Codex says so",
      harness.codex({ harness: { codex: { installed: "0.152.0", latest: "0.152.0" } } }),
      "0.152.0 · 최신");
check("harness: an unreachable registry says the check failed, not that it is current",
      harness.codex({ harness: { codex: { installed: "0.144.4" } } }),
      "0.144.4 · 최신 버전 확인 실패");

// The skills row. 🔴 Two counts, never a total: the roots belong to two different
// agents, and a skill wired for one and missing for the other triggers for neither
// error nor alarm — it simply never fires for that agent.
const SKILLS = { harness: { skills: { claude: 45, codex: 37,
  canon: { name: "shared-skills", wired: 70, syncedAt: null } } } };
check("harness: the skills row counts each agent root separately",
      harness.skills(SKILLS).startsWith("Claude 45 · Codex 37 배선"), true);
check("harness: the skills row names the repository the wiring points at",
      harness.skills(SKILLS).includes("shared-skills"), true);
// 🔴 The row reports two counts and makes NO verdict about their difference. Measured
// on a live box 2026-09-01: of the 8 names Claude had and the Codex CLI did not, 2 were
// opt-in canon and 6 were local copies with no canon at all — "one root has more" is
// not "the other is missing something", and this is asserted so that a future chip
// cannot quietly reintroduce that alarm here.
check("harness: an uneven pair of counts is reported, not judged",
      /루트에.*없음|미배선|누락/.test(harness.skills(SKILLS)), false);
check("harness: an older snapshot with no per-root split draws no skills row",
      harness.skills({ harness: { skillsWired: 82 } }), "");
check("harness: junk does not throw", harness.skills({ harness: { skills: "82" } }), "");

// The harness run line. It has no `busy`: npm takes no cross-process mutex, so there
// is no second updater to measure and this must never claim there is one.
check("harness run: a run in flight blocks the button",
      harness.run({ enabled: true, run: { status: "running", action: "codex" } }).blocked, true);
check("harness run: nothing recorded says nothing",
      harness.run({ enabled: true, run: null }).text, "");
check("harness run: no execution on this box blocks and names the manual command",
      harness.run({ enabled: false, run: null }).detail.includes("npm install -g"), true);
const MOVED = { enabled: true, run: { status: "done", exitCode: 0,
  before: { installed: "0.144.4" }, after: { installed: "0.152.0" }, note: "" } };
check("harness run: a successful upgrade shows the move",
      harness.run(MOVED).detail.includes("0.144.4 → 0.152.0"), true);
check("harness run: a successful upgrade does not read as a failure",
      harness.run(MOVED).bad, false);
// 🔴 The case npm's exit code cannot see: it installed, and the codex this box runs
// did not move. rc=0, and for the person at the panel it is still a failure.
const STUCK = { enabled: true, run: { status: "done", exitCode: 0,
  before: { installed: "0.144.4" }, after: { installed: "0.144.4" },
  note: "npm 은 성공했는데 실행되는 codex 의 버전이 그대로입니다 — …" } };
check("harness run: rc=0 with an unmoved version reads as a failure",
      harness.run(STUCK).bad, true);
check("harness run: and says the version did not move",
      harness.run(STUCK).text.includes("반영되지 않았습니다"), true);
check("harness run: a failure does not block the next attempt",
      harness.run({ enabled: true, run: { status: "failed", exitCode: 1 } }).blocked, false);
check("harness run: a null state is total", harness.run(null).blocked, false);

// ---- ACCT_OWN: where the pill sends you ----------------------------------
// The pill opens devterm's origin, and the cert covers the FQDN only: a short
// hostname or a missing port would produce a link the browser cannot verify or
// an entrance to nowhere. Both are "" here rather than a best guess, because the
// caller reads "" as "this box has no account panel" and leaves the pill alone.
const mB = html.match(/function airlockAccountPanelBase\([\s\S]*?\n  \}/);
if (!mB) { console.log("FAIL hub-filter: airlockAccountPanelBase not found in hub/index.html"); process.exit(1); }
const panelBase = eval("(" + mB[0] + ")");
check("panel base: devterm's public port on the measured FQDN",
      panelBase({ devterm: { port: 8443 } }, "box.tail.ts.net", "box"), "https://box.tail.ts.net:8443/");
check("panel base: no FQDN falls back to the origin's host",
      panelBase({ devterm: { port: 8443 } }, "", "box.tail.ts.net"), "https://box.tail.ts.net:8443/");
// A short hostname has no certificate — same rule as the tile hrefs above.
check("panel base: an undotted FQDN is not used",
      panelBase({ devterm: { port: 8443 } }, "box", "box.tail.ts.net"), "https://box.tail.ts.net:8443/");
check("panel base: no devterm on this box -> no entrance",
      panelBase({ paseo: { port: 8444 } }, "box.tail.ts.net", "box.tail.ts.net"), "");
check("panel base: devterm without a public port -> no entrance",
      panelBase({ devterm: {} }, "box.tail.ts.net", "box.tail.ts.net"), "");
check("panel base: a config that never arrived -> no entrance",
      panelBase(null, "box.tail.ts.net", "box.tail.ts.net"), "");
check("panel base: no host to be had -> no entrance, not a hostless URL",
      panelBase({ devterm: { port: 8443 } }, "", ""), "");

process.exit(failed);
JS
echo "---"
echo "hub-filter: all assertions passed"
