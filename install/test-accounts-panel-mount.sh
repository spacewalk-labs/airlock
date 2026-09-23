#!/usr/bin/env bash
# Phase 1 of DEVTERM_INDEPENDENCE: the account panel is served by the platform surface,
# under the owner-gated /airlock-accounts/ prefix, without devterm. Since 2026-09-13 the
# same page's secret-drop view is the platform's too (docs/tasks/active/platform-secret-
# drop.md, AC-PSD-6): the mount serves panel.html verbatim, secret view and secretdrop.js
# included, and the old "secret is refused here" predicates are inverted on purpose.
#
# Everything here is loopback against a scratch instance of bin/airlock-accounts-api with
# a temporary panel directory. No installed unit, no live account, no credential file,
# no devterm. The gate itself belongs to install/test-render.sh and install/test-hub-filter.sh;
# what this file owns is the mount: what it serves, what it refuses, and that its absence
# is visible (the negative control at the end).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"; [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null' EXIT

pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }

# Counters the AC rows are computed from. A prose "it passed" is not a measurement: each
# row below prints its predicate, the observed numbers and the exact revision they were
# taken at, so an acceptance reader re-runs one command and compares values.
served_panel=0 account_markup=0 secret_view_linked=0 assets_served=0 script_type=0 no_store=0 refs_resolvable=0 missing_asset_detected=0
secret_view_served=0 devterm_assets_absent=0 symlink_refused=0 escapes_refused=0 json_404=0
unconfigured_refused=0 negative_control=0
rev="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"

# The layout under test is the SHIPPED one, staged the way the installer stages it:
# hub/assets/accounts/ is what `cp -r hub/assets/.` puts in the webroot, and popup.css is
# read from apps/devterm/web/ in this checkout. An earlier version of this file invented
# its own assets, so it passed while three of the five whitelisted names could not exist
# on a real box. Copying from the repository is what keeps that from happening again.
panel_dir="$TMP/webroot/assets/accounts"
style_dir="$TMP/checkout/install/accounts-panel"
mkdir -p "$panel_dir" "$style_dir"
cp "$ROOT/hub/assets/accounts/panel.html" "$ROOT/hub/assets/accounts/accounts.js" \
   "$ROOT/hub/assets/accounts/secretdrop.js" "$panel_dir/" \
  || { echo "FAIL cannot stage the shipped account assets"; exit 1; }
cp "$ROOT/install/accounts-panel/popup.css" "$style_dir/" \
  || { echo "FAIL cannot stage the shipped panel stylesheet"; exit 1; }
ln -s /etc/passwd "$panel_dir/accounts.js.link" 2>/dev/null
cp "$panel_dir/accounts.js" "$TMP/outside.js"

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }

start_server() {  # start_server <cli> <panel-dir-or-empty> [style-dir] -> sets PORT/SERVER_PID
  local cli="$1" dir="$2" style="${3-$style_dir}"
  PORT="$(free_port)"
  AIRLOCK_HUB_ACCOUNTS_PORT="$PORT" AIRLOCK_ACCOUNTS_PANEL_DIR="$dir" \
    AIRLOCK_ACCOUNTS_PANEL_STYLE_DIR="$style" \
    AIRLOCK_ACCOUNTS_STATUS_BIN="/bin/true" AIRLOCK_ACCOUNTS_BIN="/bin/true" \
    python3 "$cli" >"$TMP/server.log" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/accounts" && return 0
    kill -0 "$SERVER_PID" 2>/dev/null || { echo "server died:"; cat "$TMP/server.log"; return 1; }
    sleep 0.1
  done
  return 1
}
stop_server() { [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""; }

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@"; }
body() { curl -s --max-time 5 "$@"; }
header() { curl -s -D - -o /dev/null --max-time 5 "$2" | tr -d '\r' | grep -i "^$1:" | head -1; }

start_server "$ROOT/bin/airlock-accounts-api" "$panel_dir" || { bad "scratch server did not start"; exit 1; }
B="http://127.0.0.1:$PORT"

# --- what the mount serves -------------------------------------------------------
[ "$(code "$B/panel.html")" = 200 ] \
  && { served_panel=1; ok "panel.html is served by the platform surface"; } \
  || bad "panel.html is not served (got $(code "$B/panel.html"))"

panel="$(body "$B/panel.html")"
case "$panel" in
  *구독?계정*) account_markup=1; ok "the served panel is the account view" ;;
  *) bad "the served panel lost its account markup" ;;
esac
case "$panel" in
  *'src="secretdrop.js"'*) secret_view_linked=1; ok "the served panel carries the platform secret drop view" ;;
  *) bad "the served panel lost the secret drop view" ;;
esac

for asset in accounts.js popup.css secretdrop.js; do
  [ "$(code "$B/$asset")" = 200 ] && { assets_served=$((assets_served + 1)); ok "asset served: $asset"; } || bad "asset missing: $asset"
done
# Everything the page still asks for must be answerable by this mount. A reference the
# mount cannot serve is the defect this check exists for.
missing_ref=0
for ref in $(printf '%s' "$panel" | grep -oE '(src|href)="[a-z0-9._-]+"' | sed -E 's/.*="([^"]+)"/\1/' | sort -u); do
  case "$ref" in http*|//*) continue ;; esac
  got="$(code "$B/$ref")"
  [ "$got" = 200 ] || { missing_ref=$((missing_ref + 1)); bad "the served panel references $ref which the mount answers $got"; }
done
[ "$missing_ref" = 0 ] && { refs_resolvable=1; ok "every asset the served panel references is answerable by the mount"; }
gone_ok=0
for gone in ui.js favicon.svg; do
  [ "$(code "$B/$gone")" = 404 ] && { gone_ok=$((gone_ok + 1)); ok "devterm-only asset is not promised here: $gone"; } || bad "$gone is still whitelisted"
done
[ "$gone_ok" = 2 ] && devterm_assets_absent=1
case "$(header content-type "$B/accounts.js")" in *javascript*) script_type=1; ok "accounts.js keeps a script content type" ;; *) bad "accounts.js content type is wrong" ;; esac
case "$(header cache-control "$B/panel.html")" in *no-store*) no_store=1; ok "the panel is never a cached answer" ;; *) bad "the panel is missing no-store" ;; esac

# --- what it refuses -------------------------------------------------------------
[ "$(code "$B/panel.html?p=secret&embed=1")" = 200 ] \
  && [ "$(body "$B/panel.html?p=secret&embed=1")" = "$panel" ] \
  && { secret_view_served=1; ok "?p=secret is served on the hub: the same page, the platform's secret view"; } \
  || bad "?p=secret is not served on the platform mount (got $(code "$B/panel.html?p=secret&embed=1"))"

[ "$(code "$B/accounts.js.link")" = 404 ] \
  && { symlink_refused=1; ok "a symlinked asset is refused"; } \
  || bad "a symlinked asset was served (got $(code "$B/accounts.js.link"))"

for probe in "/../outside.js" "/..%2foutside.js" "/assets/accounts/panel.html" "/etc/passwd"; do
  got="$(code "$B$probe")"
  [ "$got" = 404 ] && { escapes_refused=$((escapes_refused + 1)); ok "path escape refused: $probe"; } || bad "path escape not refused: $probe (got $got)"
done

unknown="$(body "$B/nope.html")"
case "$unknown" in
  *"no such route"*) json_404=1; ok "an unknown name answers the surface's JSON 404, never index.html at 200" ;;
  *) bad "an unknown name did not answer the JSON 404 shape: $unknown" ;;
esac
stop_server

# --- a required asset absent from the staged layout ------------------------------
# The reviewed defect: the mount promised an asset the installed layout did not carry.
# With the stylesheet missing the page must NOT come out as if nothing were wrong -- the
# probe below is what turns that into a red AC row rather than an unstyled panel nobody
# measured. Degradation is not an accepted normal path here; the surface ships the asset.
mkdir -p "$TMP/empty-style"
start_server "$ROOT/bin/airlock-accounts-api" "$panel_dir" "$TMP/empty-style" || bad "server without a style dir did not start"
DEG="http://127.0.0.1:$PORT"
style_code="$(code "$DEG/popup.css")"
panel_code="$(code "$DEG/panel.html")"
[ "$style_code" != 200 ] && [ "$panel_code" != 200 ] \
  && { missing_asset_detected=1; ok "a missing shipped asset fails the mount loudly (panel $panel_code, stylesheet $style_code)"; } \
  || bad "a missing shipped asset was not caught (panel $panel_code, stylesheet $style_code)"
stop_server

# --- unconfigured mount ----------------------------------------------------------
start_server "$ROOT/bin/airlock-accounts-api" "" || bad "server without a panel dir did not start"
got="$(code "http://127.0.0.1:$PORT/panel.html")"
[ "$got" = 503 ] \
  && { unconfigured_refused=1; ok "an unconfigured mount says so (503), never HTML and never 200"; } \
  || bad "an unconfigured mount answered $got"
stop_server

# --- negative control: remove the mount, the checks above must go red -------------
# The task document asks for exactly this: proof that these probes detect the mount's
# absence rather than passing on something else.
stripped="$TMP/airlock-accounts-api-no-mount"
python3 - "$ROOT/bin/airlock-accounts-api" "$stripped" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
start = text.index("AIRLOCK_ACCOUNTS_PANEL_MOUNT_BEGIN")
end = text.index("AIRLOCK_ACCOUNTS_PANEL_MOUNT_END")
head = text.rindex("    def _panel_route(self):", 0, start)
tail = text.index("\n", end) + 1
open(dst, "w", encoding="utf-8").write(
    text[:head] + "    def _panel_route(self):\n        return False\n\n" + text[tail:])
PY
start_server "$stripped" "$panel_dir" || bad "negative-control server did not start"
got="$(code "http://127.0.0.1:$PORT/panel.html")"
[ "$got" = 200 ] \
  && bad "negative control did not remove the mount — the probes above prove nothing" \
  || { negative_control=1; ok "negative control: without the mount panel.html stops being served (got $got)"; }
stop_server

verdict() { [ "$1" = 1 ] && printf PASS || printf FAIL; }

# AC rows: predicate, observed values, verdict, signal and the revision measured. The
# card's acceptance reads these, not the prose above.
mount_ok=0
[ "$served_panel" = 1 ] && [ "$account_markup" = 1 ] && [ "$secret_view_linked" = 1 ] \
  && [ "$assets_served" = 3 ] && [ "$refs_resolvable" = 1 ] && [ "$script_type" = 1 ] \
  && [ "$no_store" = 1 ] && mount_ok=1
refusals_ok=0
[ "$secret_view_served" = 1 ] && [ "$devterm_assets_absent" = 1 ] && [ "$symlink_refused" = 1 ] \
  && [ "$escapes_refused" = 4 ] && [ "$json_404" = 1 ] \
  && [ "$unconfigured_refused" = 1 ] && [ "$missing_asset_detected" = 1 ] && refusals_ok=1

printf '%s\n' "---"
printf 'AC-DTI-P1A | expected: served_panel==1 && account_markup==1 && secret_view_linked==1 && assets_served==3 && refs_resolvable==1 && script_type==1 && no_store==1 | observed: served_panel=%s,account_markup=%s,secret_view_linked=%s,assets_served=%s,refs_resolvable=%s,script_type=%s,no_store=%s | verdict: %s | signal: fixture | evidence: install/test-accounts-panel-mount.sh@%s\n' \
  "$served_panel" "$account_markup" "$secret_view_linked" "$assets_served" "$refs_resolvable" "$script_type" "$no_store" "$(verdict "$mount_ok")" "$rev"
printf 'AC-DTI-P1B | expected: secret_view_served==1 && devterm_assets_absent==1 && symlink_refused==1 && escapes_refused==4 && json_404==1 && unconfigured_refused==1 && missing_asset_detected==1 | observed: secret_view_served=%s,devterm_assets_absent=%s,symlink_refused=%s,escapes_refused=%s,json_404=%s,unconfigured_refused=%s,missing_asset_detected=%s | verdict: %s | signal: fixture | evidence: install/test-accounts-panel-mount.sh@%s\n' \
  "$secret_view_served" "$devterm_assets_absent" "$symlink_refused" "$escapes_refused" "$json_404" "$unconfigured_refused" "$missing_asset_detected" "$(verdict "$refusals_ok")" "$rev"
printf 'AC-DTI-P1C | expected: negative_control==1 | observed: negative_control=%s | verdict: %s | signal: fixture | evidence: install/test-accounts-panel-mount.sh@%s\n' \
  "$negative_control" "$(verdict "$negative_control")" "$rev"
printf '%s\n' "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] && [ "$mount_ok" = 1 ] && [ "$refusals_ok" = 1 ] && [ "$negative_control" = 1 ]
