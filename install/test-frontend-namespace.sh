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

# ---- ACCT_OWN: three hosts, one panel ----
# The return widget, the hub's identity pill and devterm's own page must open the SAME
# account panel — that is what "promoted, not copied" means, and it is a property no
# single file's test can see. All three are asserted here because the URL is built
# independently in two places and loaded by a third, and a drift in any one of them is
# a second implementation nobody decided to create.
HUB="$ROOT/hub/index.html"
DEVTERM_INDEX="$ROOT/apps/devterm/web/index.html"
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
# devterm loads the aliased platform file, not a copy of its own. `src="accounts.js"`
# resolves to /accounts.js from the gate's root page, which is the alias.
grep -qF '<script src="accounts.js"></script>' "$DEVTERM_INDEX" \
  || bad "devterm no longer loads the platform account list"
[ -e "$ROOT/apps/devterm/web/accounts.js" ] || [ -e "$ROOT/apps/devterm/web/panel.html" ] \
  && bad "devterm has a second copy of the account panel again" || true
# The secret drop UI is the platform's the same way (docs/tasks/active/platform-secret-
# drop.md): devterm's page loads the aliased hub/assets/accounts/secretdrop.js.
grep -qF '<script src="secretdrop.js"></script>' "$DEVTERM_INDEX" \
  || bad "devterm no longer loads the platform secret drop"
[ -e "$ROOT/apps/devterm/web/secretdrop.js" ] \
  && bad "devterm has a second copy of the secret drop UI again" || true
[ "$fail" = 0 ] && ok "widget, hub pill and devterm all open one account panel"

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

if (bad) process.exit(1);
console.log("ok   frontend-namespace: 11 rule cases");
JS

# The card's machine verdict for the consumer half: two independent consumers name the
# same owner-gated mount, and the panel they open is still one implementation.
#
# The evidence strings are the MATCHES, not a line count. `grep -c f1 f2` prints one
# line per file whether anything matched or not, so piping that to `wc -l` produced a
# constant 2 that read like a finding (independent review of ae1b504). The verdict was
# never wrong — the `grep -qF` gates above decide it — but an observed value that
# cannot vary is not an observation.
printf 'AC-DTI-P2F | expected: hub pill base == "/airlock-accounts/" && widget account+secret bases == https://<fqdn>/airlock-accounts/ && both open one panel.html | observed: pill_base=%s,widget_golden=%s,panel_paths=%s | verdict: %s | signal: fixture | evidence: install/test-frontend-namespace.sh\n' \
  "$(grep -o 'return "/airlock-accounts/";' "$HUB" | wc -l | tr -d ' ')" \
  "$(grep -o 'data-\(account\|secret\)-panel="[^"]*"' "$ROOT/install/golden/render/orca/installer-path/nginx.conf" | sort -u | tr '\n' ' ')" \
  "hub=$(grep -ho 'panel\.html?p=[^;]*embed=1' "$HUB" | sort -u | tr -d '\n') widget=$(grep -ho 'panel\.html?p=[^;]*embed=1' "$JS" | sort -u | tr -d '\n')" \
  "$([ "$fail" = 0 ] && echo PASS || echo FAIL)"

if [ "$fail" != 0 ]; then echo "---"; echo "frontend-namespace: FAILED"; exit 1; fi
echo "---"
echo "frontend-namespace: passed"
