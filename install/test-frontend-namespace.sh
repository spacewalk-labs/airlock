#!/usr/bin/env bash
# The published frontend namespace, and the overlap it gets until 2026-09-07.
#
# hub/assets/airlock-return.js is injected into upstream bundles by the nginx gate,
# so its names are a contract with whatever page it lands in — including pages this
# repo does not contain. The 2026-08-07 rename dropped the company prefix this project
# used before it was open-sourced from the names we EMIT, while keeping both spellings
# of the names we RECEIVE until 2026-09-07. That asymmetry is the thing under test: a
# rename that also stops accepting the old input is a break, and an "overlap" that
# never emits the new name is a rename that did not happen.
#
# Same shape as install/test-hub-filter.sh: node exercises the pure rules lifted out
# of the file, greps prove they are actually wired into the widget. Either half alone
# passes while the widget is broken.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
JS="$ROOT/hub/assets/airlock-return.js"
PANEL="$ROOT/hub/assets/accounts/panel.html"

command -v node >/dev/null 2>&1 \
  || { echo "FAIL frontend-namespace: node is required (the widget is JS)"; exit 1; }

fail=0
bad() { echo "FAIL frontend-namespace: $1"; fail=1; }
ok()  { echo "ok   frontend-namespace: $1"; }

# ---- what we emit: the new spelling, and only the new spelling ----
grep -qF 'var ID = "airlock-return";'      "$JS" || bad "the button's element id is not the renamed one"
grep -qF 'var POS_KEY = "airlock:btn-pos-v1";' "$JS" || bad "the position key is not the renamed one"
grep -qF "window.parent.postMessage('airlock-panel-close', '*');" "$PANEL" \
  || bad "panel.html does not emit the renamed close message"
[ "$fail" = 0 ] && ok "emitted names carry no legacy prefix"

# ---- what we accept: both spellings, until the 2026-09-07 removal ----
grep -qF 'var LEGACY_ID = "swk-airlock-return";'          "$JS" || bad "the legacy element id is gone from the idempotency check"
grep -qF 'var LEGACY_SLOT = "#swk-airlock-slot";'         "$JS" || bad "the legacy slot selector is gone"
grep -qF 'var LEGACY_POS_KEY = "swk:airlock-btn-pos-v1";' "$JS" || bad "the legacy position key is gone"
grep -qF "window.parent.postMessage('swk-panel-close', '*');" "$PANEL" \
  || bad "panel.html no longer emits the legacy close message (an old parent stops closing)"

# ---- ACCT_OWN: platform consumers share one panel; devterm owns none ----
# The return widget and hub identity pill open the same platform account panel. Phase 4
# removes devterm's temporary account consumer, aliases, and account stylesheet surface.
HUB="$ROOT/hub/index.html"
DEVTERM_INDEX="$ROOT/apps/devterm/web/index.html"
DEVTERM_APP="$ROOT/apps/devterm/web/app.js"
DEVTERM_CONTROL="$ROOT/apps/devterm/web/platform-account-control.js"
# The widget takes one authority per destination. Both account and secret destinations
# now point at the platform prefix, but remain separate attributes; the split must not
# turn into a second panel implementation or make the legacy account alias grant secret.
grep -qF 'frame.src = base + "panel.html?p=" + which + "&embed=1";' "$JS" \
  || bad "the return widget no longer opens panel.html?p=<which>&embed=1"
grep -qF 'frame.src = base + "panel.html?p=accounts&embed=1";' "$HUB" \
  || bad "the hub pill no longer opens the same panel.html the widget does"
# ...and it opens it on the PLATFORM prefix (phase 2-2). Two consumers now name the
# same owner-gated mount — the widget by injected attribute, the pill by this literal —
# so a box without devterm has both entrances. The pill's is a relative path because
# the hub IS that origin; the widget's is absolute because it runs on another port.
grep -qF 'return "/airlock-accounts/";' "$HUB" \
  || bad "the hub pill no longer opens the platform account prefix"
# The widget's half is read off the RENDERED gate rather than the installer source:
# install/test-render-parity.sh's RAM pin gate scans any suite whose text names an app
# installer, and this suite runs no installer. The golden is the same fact one layer
# down — and it is a fixture layer, not proof of an installed box.
grep -qF 'data-account-panel="https://box.example.ts.net/airlock-accounts/"' \
  "$ROOT/install/golden/render/orca/installer-path/nginx.conf" \
  || bad "the return widget is no longer injected with the platform account prefix"
grep -qF 'data-secret-panel="https://box.example.ts.net/airlock-accounts/"' \
  "$ROOT/install/golden/render/orca/installer-path/nginx.conf" \
  || bad "the return widget is no longer injected with the platform secret prefix"
# Devterm no longer owns an account entrance. It must not load accounts.js or retain the
# thin phase-2 account adapter.
grep -qF '<script src="accounts.js"></script>' "$DEVTERM_INDEX" \
  && bad "devterm still loads accounts.js on its own origin" || true
grep -qF '<script src="platform-account-control.js"></script>' "$DEVTERM_INDEX" \
  && bad "devterm still loads its retired platform account consumer" || true
grep -qF "window.initPlatformAccountControl" "$DEVTERM_APP" \
  && bad "devterm app still wires its retired account consumer" || true
[ -e "$DEVTERM_CONTROL" ] && bad "devterm still ships its retired account control" || true
[ -e "$ROOT/apps/devterm/web/accounts.js" ] || [ -e "$ROOT/apps/devterm/web/panel.html" ] \
  && bad "devterm has a second copy of the account panel again" || true
# The secret drop UI is the platform's the same way (docs/tasks/active/platform-secret-
# drop.md): devterm's page loads the aliased hub/assets/accounts/secretdrop.js.
grep -qF '<script src="secretdrop.js"></script>' "$DEVTERM_INDEX" \
  || bad "devterm no longer loads the platform secret drop"
[ -e "$ROOT/apps/devterm/web/secretdrop.js" ] \
  && bad "devterm has a second copy of the secret drop UI again" || true
[ "$fail" = 0 ] && ok "widget and hub pill share one panel; devterm owns no account UI"

# ---- wiring: the rules are called, not merely defined ----
grep -qF 'if (document.getElementById(ID) || document.getElementById(LEGACY_ID)) return;' "$JS" \
  || bad "the idempotency check does not test both spellings"
grep -qF 'var slot = airlockResolveSlot(document, targetSelector, targetExplicit ? null : LEGACY_SLOT);' "$JS" \
  || bad "airlockResolveSlot is not the call site in mount()"
grep -qF 'if (airlockIsCloseMessage(e.data)) closeModal();' "$JS" \
  || bad "airlockIsCloseMessage is not the call site in the message listener"
grep -qF 'raw = localStorage.getItem(LEGACY_POS_KEY);' "$JS" \
  || bad "the position key migration does not read the legacy key"
[ "$fail" = 0 ] && ok "both compatibility rules are wired into the widget"

# Peek consumes the existing preview response; publish's badge opt-out gates that poll.
grep -qF 'if (d && Array.isArray(d.messages)) receivePeeks(d.messages);' "$JS" \
  || bad "Peek is not wired to the existing preview response"
grep -qF 'var next = airlockSelectPeeks(messages, peekSeen, peekQueue);' "$JS" \
  || bad "Peek selection is not used by the widget"
grep -qF 'var PEEK_KEY = "airlock:peek-seen-v1";' "$JS" \
  || bad "Peek watermark key changed"
# The two durations are a product decision (normal 10s, urgent 60s), not a detail:
# they are what the design record and the producer guidance promise.
grep -qF 'var peekNormalMs = 15000, peekUrgentMs = 90000;' "$JS" \
  || bad "shipped Peek durations are not the documented 15s / 90s"
# The control has to name itself somewhere a first-time reader will meet it.
grep -qF 'btn.title = "Porthole' "$JS" || bad "the button does not name Porthole"
grep -qF 'cap.textContent = "Porthole";' "$JS" || bad "the menu does not name Porthole"

# ---- the rules themselves, in node ----
node - "$JS" <<'JS' || fail=1
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
function lift(name) {
  const m = src.match(new RegExp("\\n  function " + name + "\\([\\s\\S]*?\\n  \\}"));
  if (!m) { console.log("FAIL frontend-namespace: " + name + " not found in airlock-return.js"); process.exit(1); }
  return m[0];
}
eval(lift("airlockResolveSlot") + lift("airlockIsCloseMessage"));
eval(lift("airlockPeekDuration") + lift("airlockPeekCompare") + lift("airlockSelectPeeks"));

let bad = 0;
const t = (name, got, want) => {
  if (got !== want) { console.log(`FAIL frontend-namespace: ${name} — got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); bad = 1; }
};
// A document stub that only answers querySelector, which is all the rule uses.
const doc = (present) => ({ querySelector: (s) => (present.includes(s) ? "el:" + s : null) });

// slot resolution
t("new slot wins when both exist",
  airlockResolveSlot(doc(["#airlock-slot", "#swk-airlock-slot"]), "#airlock-slot", "#swk-airlock-slot"), "el:#airlock-slot");
t("legacy slot is still accepted on its own",
  airlockResolveSlot(doc(["#swk-airlock-slot"]), "#airlock-slot", "#swk-airlock-slot"), "el:#swk-airlock-slot");
t("new slot alone resolves",
  airlockResolveSlot(doc(["#airlock-slot"]), "#airlock-slot", "#swk-airlock-slot"), "el:#airlock-slot");
t("neither present is null, not a throw",
  airlockResolveSlot(doc([]), "#airlock-slot", "#swk-airlock-slot"), null);
t("an explicit data-target gets no legacy fallback",
  airlockResolveSlot(doc(["#swk-airlock-slot"]), "#their-header", null), null);
t("a selector the browser rejects does not take the widget down",
  airlockResolveSlot({ querySelector: () => { throw new SyntaxError("bad selector"); } }, "#(", "#swk-airlock-slot"), null);

// close message
t("renamed close message accepted", airlockIsCloseMessage("airlock-panel-close"), true);
t("legacy close message still accepted", airlockIsCloseMessage("swk-panel-close"), true);
t("unrelated message ignored", airlockIsCloseMessage("panel-close"), false);
t("a structured-clone payload is not a close", airlockIsCloseMessage({ type: "airlock-panel-close" }), false);
t("undefined is not a close", airlockIsCloseMessage(undefined), false);

// Peek's pure rules: first visit, strict opt-in, total ordering and poll overlap.
const card = (id, at, extra = {}) => ({card_id: id, last_at: at, level: "normal", peek: true, read_at: null, ...extra});
const seen = {last_at: "2026-09-23T00:00:00.000000Z", card_id: "a"};
const at1 = "2026-09-23T00:00:01.000000Z", at2 = "2026-09-23T00:00:02.000000Z";
const ids = result => result.cards.map(c => c.card_id).join(",");
const cards = [card("normal", at1), card("urgent", at2, {level: "urgent"}),
  card("quiet", at2, {level: "urgent", peek: false}), card("read", at2, {read_at: at2})];
const first = airlockSelectPeeks(cards, null, []);
t("first visit does not replay existing cards", ids(first), "");
t("first watermark includes all cards", JSON.stringify(first.seen), JSON.stringify({last_at: at2, card_id: "urgent"}));
t("read and non-Peek cards seed the watermark too", airlockSelectPeeks([
  card("read", at1, {read_at: at1}), card("quiet", at2, {peek: false})], null, []).seen.card_id, "quiet");
const empty = airlockSelectPeeks([], null, []);
t("empty first visit still initializes", empty.seen.last_at, "");
t("first later arrival is shown", ids(airlockSelectPeeks([cards[0]], empty.seen, [])), "normal");
t("urgent before older normal; read and opt-out skipped", ids(airlockSelectPeeks(cards, seen, [])), "urgent,normal");
for (const level of ["normal", "urgent"]) {
  for (const peek of [undefined, false, "yes", 1]) {
    t(`${level} rejects peek=${peek}`, ids(airlockSelectPeeks([card("x", at1, {level, peek})], seen, [])), "");
  }
}
t("same timestamp uses card_id tie breaker", ids(airlockSelectPeeks([
  card("a", seen.last_at), card("b", seen.last_at), card("0", seen.last_at)], seen, [])), "b");
t("equal urgency is chronological with deterministic ties", ids(airlockSelectPeeks([
  card("z", at2), card("b", at1), card("a", at1)], seen, [])), "a,b,z");
const restored = JSON.parse(JSON.stringify({last_at: at2, card_id: "urgent"}));
t("refresh does not replay a shown card", ids(airlockSelectPeeks(cards, restored, [])), "");
t("coalescing can Peek again when unread and last_at advances", ids(airlockSelectPeeks([
  card("a", at1)], seen, [])), "a");
const pending = [cards[0]];
t("next poll retains older queued normal after urgent advanced watermark",
  ids(airlockSelectPeeks(cards, restored, pending)), "normal");
t("poll overlap does not duplicate pending cards",
  ids(airlockSelectPeeks([cards[0], cards[0]], seen, pending)), "normal");
t("selection leaves the supplied queue unchanged", pending.length, 1);
t("all five preview candidates are kept", airlockSelectPeeks(
  [1,2,3,4,5].map(n => card(String(n), at1)), seen, []).cards.length, 5);
for (const badValue of [undefined, "", "no", "0", "-1", "Infinity"]) {
  t("invalid duration keeps default: " + badValue, airlockPeekDuration(badValue, 15000), 15000);
}
t("normal duration override", airlockPeekDuration("1200", 15000), 1200);
t("urgent default", airlockPeekDuration(undefined, 90000, 90000), 90000);
t("urgent shorter override", airlockPeekDuration("8000", 90000, 90000), 8000);
t("urgent 90s ceiling", airlockPeekDuration("120000", 90000, 90000), 90000);
// Check the request boundary without simulating a browser DOM.
t("badge opt-out stays wired", src.includes('if (self.dataset.badge === "0") wantBadge = false;'), true);
t("preview polling remains badge-gated", /if \(wantBadge\) \{\s*pollUnread\(\);\s*setInterval\(pollUnread, POLL_MS\);\s*\}/.test(lift("mount")), true);
t("one preview fetch call site", (src.match(/fetch\(UNREAD_URL/g) || []).length, 1);
t("preview poll interval stays 30 seconds", src.includes("var POLL_MS = 30000;"), true);

if (bad) process.exit(1);
console.log("ok   frontend-namespace: compatibility + Peek selection/duration/poll rules");
JS

if [ "$fail" != 0 ]; then echo "---"; echo "frontend-namespace: FAILED"; exit 1; fi
echo "---"
echo "frontend-namespace: passed"
