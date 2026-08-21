#!/usr/bin/env bash
# markwand smoke — against a live install (after orchestrator render + reload).
# markwand is a same-origin subpath, so the gate under test is the HUB nginx
# server (not a separate port): the /markwand/ locations inherit its server-level
# $hub_ok gate, which admits the owner AND the collaborators.
set -uo pipefail
# ABI (D5): prefer the orchestrator-supplied AIRLOCK_ROOT/AIRLOCK_APP_ID,
# falling back to $0-relative computation for a standalone invocation.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:-$(cd "$HERE/../.." && pwd)}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-markwand}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

airlock_load markwand
MS="$AIRLOCK_MARKWAND_MARKSERV_PORT"
FB="$AIRLOCK_MARKWAND_FILEBROWSER_PORT"
airlock_load hub
HUB="$AIRLOCK_HUB_NGINX_PORT"
HDR="$AIRLOCK_IDENTITY_HEADER"
OWNER="${AIRLOCK_OWNER%%,*}"

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$@"; }
c_ms=$(code   "http://127.0.0.1:${MS}/")
c_fb=$(code   "http://127.0.0.1:${FB}/markwand/edit/")
c_own=$(code  -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${HUB}/markwand/")
c_edit=$(code -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${HUB}/markwand/edit/")
c_css=$(code  -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${HUB}/__mw/markwand-tokens.css")
c_hljs=$(code -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${HUB}/__mw/highlight.min.js")
c_deny=$(code -H "${HDR}: nobody@example.com" "http://127.0.0.1:${HUB}/markwand/")
c_no=$(code                                    "http://127.0.0.1:${HUB}/markwand/")

# End-to-end: exactly /markwand/ must serve the split-pane viewer (a static file
# that self-hosts highlight.js/marked/DOMPurify — proving the exact-match location
# and the vendored libs are wired, not just that the gate opened). A denied identity
# must NOT receive markwand markup — it gets the wrong-owner page.
own_body=$(curl -s --max-time 6 -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${HUB}/markwand/")
deny_body=$(curl -s --max-time 6 -H "${HDR}: nobody@example.com" "http://127.0.0.1:${HUB}/markwand/")
# Match with bash glob (no pipe): `printf | grep -q` on a ~64 KB body races the
# pipe buffer — grep -q closes the pipe on match, printf gets SIGPIPE, and under
# `set -o pipefail` (+ lib.sh's `set -e`) the pipeline reports failure so the
# `&& split=yes` never runs even though the marker is present (flaky by body size).
split=no;  [[ "$own_body"  == *"/__mw/highlight.min.js"* ]] && split=yes
denied=no; [[ "$deny_body" == *"isn't your Airlock"* ]]     && denied=yes

echo "[markwand smoke] markserv=${c_ms}/200 filebrowser=${c_fb}/200 owner=${c_own}/200 edit=${c_edit}/200 css=${c_css}/200 hljs=${c_hljs}/200 deny=${c_deny}/403 no-header=${c_no}/403 split-viewer=${split}/yes denied-page=${denied}/yes"
fail=0
[ "$c_ms"   = 200 ] || { echo "FAIL markserv backend"; fail=1; }
{ [ "$c_fb" = 200 ] || [ "$c_fb" = 302 ]; } || { echo "FAIL filebrowser backend"; fail=1; }
[ "$c_own"  = 200 ] || { echo "FAIL owner viewer"; fail=1; }
{ [ "$c_edit" = 200 ] || [ "$c_edit" = 302 ]; } || { echo "FAIL owner editor"; fail=1; }
[ "$c_css"  = 200 ] || { echo "FAIL static asset"; fail=1; }
[ "$c_hljs" = 200 ] || { echo "FAIL vendored highlight.js asset"; fail=1; }
[ "$c_deny" = 403 ] || { echo "FAIL other identity not denied (GATE HOLE)"; fail=1; }
[ "$c_no"   = 403 ] || { echo "FAIL missing header not denied (GATE HOLE)"; fail=1; }
[ "$split"  = yes ] || { echo "FAIL /markwand/ did not serve the split-pane viewer"; fail=1; }
[ "$denied" = yes ] || { echo "FAIL denied identity did not get wrong-owner page"; fail=1; }
[ "$fail" = 0 ]
