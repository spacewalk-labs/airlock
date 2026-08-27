#!/usr/bin/env bash
# fileview smoke — against a live install (after orchestrator render + reload).
# fileview is a same-origin subpath, so the gate under test is the HUB nginx
# server (not a separate port): the /fileview/ locations inherit its server-level
# $hub_ok gate, which admits the owner AND the collaborators.
set -uo pipefail
# ABI (D5): prefer the orchestrator-supplied AIRLOCK_ROOT/AIRLOCK_APP_ID,
# falling back to $0-relative computation for a standalone invocation.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run this through install/airlock-install.sh (or bin/airlock-smoke), or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID yourself. There is deliberately no \$0-relative fallback — this package does not have to live inside the platform tree.}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-fileview}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

airlock_load fileview
FB="$AIRLOCK_FILEVIEW_FILEBROWSER_PORT"
airlock_load hub
HUB="$AIRLOCK_HUB_NGINX_PORT"
HDR="$AIRLOCK_IDENTITY_HEADER"
OWNER="${AIRLOCK_OWNER%%,*}"

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$@"; }
# filebrowser is headless: its API answers (401 without a token — it is up), and its
# own web UI is NOT proxied, so /fileview/ must NOT be reachable through the hub.
c_fb=$(code   "http://127.0.0.1:${FB}/fileview/api/resources/")
c_own=$(code  -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${HUB}/fileview/")
c_edit=$(code -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${HUB}/fileview/files/")
c_sub=$(code  -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${HUB}/fileview/README.md")
c_css=$(code  -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${HUB}/__fv/tokens.css")
c_hljs=$(code -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${HUB}/__fv/highlight.min.js")
c_deny=$(code -H "${HDR}: nobody@example.com" "http://127.0.0.1:${HUB}/fileview/")
c_no=$(code                                    "http://127.0.0.1:${HUB}/fileview/")

# End-to-end: exactly /fileview/ must serve the split-pane viewer (a static file
# that self-hosts highlight.js/marked/DOMPurify — proving the exact-match location
# and the vendored libs are wired, not just that the gate opened). A denied identity
# must NOT receive fileview markup — it gets the wrong-owner page.
own_body=$(curl -s --max-time 6 -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${HUB}/fileview/")
deny_body=$(curl -s --max-time 6 -H "${HDR}: nobody@example.com" "http://127.0.0.1:${HUB}/fileview/")
# Match with bash glob (no pipe): `printf | grep -q` on a ~64 KB body races the
# pipe buffer — grep -q closes the pipe on match, printf gets SIGPIPE, and under
# `set -o pipefail` (+ lib.sh's `set -e`) the pipeline reports failure so the
# `&& split=yes` never runs even though the marker is present (flaky by body size).
split=no;  [[ "$own_body"  == *"/__fv/highlight.min.js"* ]] && split=yes
denied=no; [[ "$deny_body" == *"isn't your Airlock"* ]]     && denied=yes

# --- API round trip: awkward filenames + dotfiles are ordinary files ---
# Two regressions this pins, both invisible to a status-code-only check:
#   1. Path encoding. Every API call builds its URL with encPath() now; before
#      that the raw path was concatenated and a name containing a space, '#',
#      '%' or '?' broke listing/read/save. Measured against the pinned binary:
#      '#' -> the URL truncates, '%' -> 400, '?' -> 404.
#   2. `.env` is an ordinary file. filebrowser has a real user setting,
#      --hideDotfiles, that would make dotfiles vanish server-side. The
#      installer pins it false; this asserts it stayed false.
# Writes only inside a mktemp -d it removes on exit. filebrowser serves `/`, so the
# temp directory's absolute path IS its API path — no prefix arithmetic. (There used
# to be some, keyed on AIRLOCK_CODE_ROOT; a stale value of that retired variable in
# the environment made it strip a prefix the server knew nothing about and fail a
# healthy install.)
api_rt=skip
RT_DIR=""
rt_cleanup() { [ -n "$RT_DIR" ] && rm -rf "$RT_DIR"; }
trap rt_cleanup EXIT
if RT_DIR=$(mktemp -d "/tmp/.airlock-smoke.XXXXXX" 2>/dev/null); then
  rt_rel="$RT_DIR"
  rt_odd='name with space #1.md'
  printf 'before\n' > "$RT_DIR/$rt_odd"
  printf 'SMOKE=1\n'  > "$RT_DIR/.env"
  rt_enc() { python3 -c 'import sys,urllib.parse as u;print("/".join(u.quote(s,safe="") for s in sys.argv[1].split("/")))' "$1"; }
  rt_jwt=$(curl -s --max-time 6 -X POST -H "${HDR}: ${OWNER}" -H 'content-type: application/json' -d '{}' \
                "http://127.0.0.1:${HUB}/fileview/api/login")
  rt_api="http://127.0.0.1:${HUB}/fileview/api"
  rt_list=$(curl -s --max-time 6 -H "${HDR}: ${OWNER}" -H "X-Auth: ${rt_jwt}" "${rt_api}/resources$(rt_enc "$rt_rel")/")
  rt_read=$(curl -s --max-time 6 -H "${HDR}: ${OWNER}" -H "X-Auth: ${rt_jwt}" "${rt_api}/raw$(rt_enc "$rt_rel/$rt_odd")?algo=none")
  rt_put=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 -X PUT -H "${HDR}: ${OWNER}" -H "X-Auth: ${rt_jwt}" \
                -H 'content-type: text/plain' --data-binary 'after' "${rt_api}/resources$(rt_enc "$rt_rel/$rt_odd")")
  api_rt=ok
  [[ "$rt_list" == *'"name":".env"'* ]]        || { echo "FAIL .env missing from the API listing (hideDotfiles regressed?)"; api_rt=bad; }
  [[ "$rt_list" == *"$rt_odd"* ]]              || { echo "FAIL awkward filename missing from the API listing"; api_rt=bad; }
  [ "$rt_read" = "before" ]                    || { echo "FAIL read of 'name with space #1.md' (got: ${rt_read:0:40})"; api_rt=bad; }
  [ "$rt_put" = 200 ]                          || { echo "FAIL save of 'name with space #1.md' (HTTP $rt_put)"; api_rt=bad; }
  [ "$(cat "$RT_DIR/$rt_odd")" = "after" ]     || { echo "FAIL save did not reach disk"; api_rt=bad; }
fi

echo "[fileview smoke] filebrowser=${c_fb}/401 owner=${c_own}/200 ui-not-proxied=${c_edit}/404 subpath=${c_sub}/404 css=${c_css}/200 hljs=${c_hljs}/200 deny=${c_deny}/403 no-header=${c_no}/403 split-viewer=${split}/yes denied-page=${denied}/yes api-roundtrip=${api_rt}/ok"
fail=0
[ "$c_fb"   = 401 ] || { echo "FAIL filebrowser API backend (want 401 = up and asking for a token, got $c_fb)"; fail=1; }
[ "$c_own"  = 200 ] || { echo "FAIL owner viewer"; fail=1; }
# filebrowser's own UI ships a settings page that can turn on hideDotfiles. Nothing
# links to it and nothing may serve it: the viewer is the only front end.
[ "$c_edit" = 404 ] || { echo "FAIL filebrowser web UI is reachable at /fileview/files/ (got $c_edit)"; fail=1; }
[ "$c_sub"  = 404 ] || { echo "FAIL /fileview/<file> should 404, not fall through to the hub (got $c_sub)"; fail=1; }
[ "$c_css"  = 200 ] || { echo "FAIL static asset"; fail=1; }
[ "$c_hljs" = 200 ] || { echo "FAIL vendored highlight.js asset"; fail=1; }
[ "$c_deny" = 403 ] || { echo "FAIL other identity not denied (GATE HOLE)"; fail=1; }
[ "$c_no"   = 403 ] || { echo "FAIL missing header not denied (GATE HOLE)"; fail=1; }
[ "$split"  = yes ] || { echo "FAIL /fileview/ did not serve the split-pane viewer"; fail=1; }
[ "$denied" = yes ] || { echo "FAIL denied identity did not get wrong-owner page"; fail=1; }
[ "$api_rt" != bad ] || fail=1
[ "$api_rt" != skip ] || { echo "FAIL could not create the round-trip temp dir in /tmp"; fail=1; }
[ "$fail" = 0 ]
