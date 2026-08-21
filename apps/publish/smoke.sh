#!/usr/bin/env bash
# publish smoke — against a live install (after orchestrator render + reload).
# Same-origin subpath, so the gate under test is the HUB nginx server.
set -uo pipefail
# ABI (D5): prefer the orchestrator-supplied AIRLOCK_ROOT/AIRLOCK_APP_ID,
# falling back to $0-relative computation for a standalone invocation.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:-$(cd "$HERE/../.." && pwd)}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-publish}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

airlock_load publish
BACKEND="$AIRLOCK_PUBLISH_BACKEND_PORT"
airlock_load hub
HUB="$AIRLOCK_HUB_NGINX_PORT"
HDR="$AIRLOCK_IDENTITY_HEADER"
OWNER="${AIRLOCK_OWNER%%,*}"

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$@"; }
c_be=$(code   "http://127.0.0.1:${BACKEND}/api/health")
c_ui=$(code   -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${HUB}/publish/")
c_list=$(code -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${HUB}/publish/api/list")
c_files=$(code -H "${HDR}: ${OWNER}"          "http://127.0.0.1:${HUB}/publish/files/")
c_deny=$(code -H "${HDR}: nobody@example.com" "http://127.0.0.1:${HUB}/publish/api/list")
c_no=$(code                                    "http://127.0.0.1:${HUB}/publish/api/list")
# the list endpoint must return valid JSON with ok:true for the owner.
# Captured and matched in-shell, never `curl | grep -q`: grep -q closes the pipe
# at the first match, curl takes SIGPIPE, and under `set -o pipefail` the pipeline
# reports FAILURE — so okjson would read `no` exactly when the answer is yes, and
# only on the boxes whose list is big enough to fill a pipe buffer. markwand hit
# this on an HTTP body and wrote it down (apps/markwand/smoke.sh:37-41); orca hit
# it again on `ldconfig -p` and lost two installs to it. A list endpoint has no
# code-visible bound on its size at all, which is what makes it the same shape.
list_body="$(curl -s --max-time 6 -H "${HDR}: ${OWNER}" "http://127.0.0.1:${HUB}/publish/api/list")"
okjson=no; [[ "$list_body" =~ \"ok\":[[:space:]]*true ]] && okjson=yes
overlaps() {
  local left right
  left="$(readlink -f "$1" 2>/dev/null)"; right="$(readlink -f "$2" 2>/dev/null)"
  [ -n "$left" ] && [ -n "$right" ] && { [ "$left" = "$right" ] || [[ "$left/" == "$right/"* ]] || [[ "$right/" == "$left/"* ]]; }
}

# local public target (if configured): the public dir must exist, be writable by
# us, and must NOT be the tailnet-internal share — that overlap is the leak.
PUB_MODE="$(airlock_config get apps.publish.public_target.mode 2>/dev/null || true)"
[ -n "$PUB_MODE" ] || PUB_MODE=remote
PUB_MODE="$(python3 -c 'import sys; print(sys.argv[1].strip().lower())' "$PUB_MODE")"
localpub=n/a
if [ "$PUB_MODE" = local ]; then
  PUB_DIR="$(airlock_config get apps.publish.public_target.public_dir 2>/dev/null || true)"
  [ -n "$PUB_DIR" ] || PUB_DIR=/opt/airlock/share-public
  STATE_DIR="$HOME/.local/state/airlock"
  PD="$(readlink -f "$PUB_DIR" 2>/dev/null)"
  localpub=ok
  [ -d "$PUB_DIR" ] && [ -w "$PUB_DIR" ] || localpub="not-writable:$PUB_DIR"
  ! overlaps "$PUB_DIR" "${AIRLOCK_PUBLISH_SHARE_DIR:-/opt/airlock/share}" || localpub="OVERLAPS-SHARE:$PD"
  ! overlaps "$PUB_DIR" "$STATE_DIR" || [ "$localpub" != ok ] || localpub="OVERLAPS-STATE:$STATE_DIR"
  # the backend must actually report local mode (i.e. it did not refuse at startup)
  health_body="$(curl -s --max-time 6 "http://127.0.0.1:${BACKEND}/api/health")"
  [[ "$health_body" =~ \"public_enabled\":[[:space:]]*true ]] \
    || localpub="backend-disabled (check: journalctl --user -u airlock-publish)"
  GATED_DIR="$(airlock_config get apps.publish.public_target.gated_dir 2>/dev/null || true)"
  [ -n "$GATED_DIR" ] || GATED_DIR=/opt/airlock/share-gated
  GD="$(readlink -f "$GATED_DIR" 2>/dev/null)"
  [ -d "$GATED_DIR" ] && [ -w "$GATED_DIR" ] || [ "$localpub" != ok ] || localpub="gated-not-writable:$GATED_DIR"
  { ! overlaps "$GATED_DIR" "${AIRLOCK_PUBLISH_SHARE_DIR:-/opt/airlock/share}" && ! overlaps "$GATED_DIR" "$PUB_DIR" && ! overlaps "$GATED_DIR" "$STATE_DIR"; } \
    || [ "$localpub" != ok ] || localpub="GATED-OVERLAPS:$GD"
  AUTH_DIR="$(airlock_config get apps.publish.public_target.htpasswd_dir 2>/dev/null || true)"
  [ -n "$AUTH_DIR" ] || AUTH_DIR=/opt/airlock/publish-gated-auth
  [ -d "$AUTH_DIR" ] && [ -w "$AUTH_DIR" ] || [ "$localpub" != ok ] || localpub="auth-not-writable:$AUTH_DIR"
  { ! overlaps "$AUTH_DIR" "${AIRLOCK_PUBLISH_SHARE_DIR:-/opt/airlock/share}" && ! overlaps "$AUTH_DIR" "$PUB_DIR" && ! overlaps "$AUTH_DIR" "$GATED_DIR" && ! overlaps "$AUTH_DIR" "$STATE_DIR"; } \
    || [ "$localpub" != ok ] || localpub="AUTH-OVERLAPS:$AUTH_DIR"
  if id www-data >/dev/null 2>&1 && command -v sudo >/dev/null 2>&1; then
    sudo -n -u www-data test -x "$AUTH_DIR" 2>/dev/null || [ "$localpub" != ok ] || localpub="auth-not-readable-by-nginx:$AUTH_DIR"
    for auth_file in "$AUTH_DIR"/*.htpasswd; do
      [ -e "$auth_file" ] || continue
      sudo -n -u www-data test -r "$auth_file" 2>/dev/null || [ "$localpub" != ok ] || localpub="credential-not-readable-by-nginx:$auth_file"
    done
  fi
fi

echo "[publish smoke] backend=${c_be}/200 ui=${c_ui}/200 list=${c_list}/200 files=${c_files}/200 deny=${c_deny}/403 no-header=${c_no}/403 list-json=${okjson}/yes local-public=${localpub}"
fail=0
[ "$c_be"   = 200 ] || { echo "FAIL backend health"; fail=1; }
[ "$c_ui"   = 200 ] || { echo "FAIL manager UI"; fail=1; }
[ "$c_list" = 200 ] || { echo "FAIL list endpoint"; fail=1; }
{ [ "$c_files" = 200 ] || [ "$c_files" = 403 ] || [ "$c_files" = 404 ]; } || { echo "FAIL files location broken ($c_files)"; fail=1; }
[ "$c_deny" = 403 ] || { echo "FAIL other identity not denied (GATE HOLE)"; fail=1; }
[ "$c_no"   = 403 ] || { echo "FAIL missing header not denied (GATE HOLE)"; fail=1; }
[ "$okjson" = yes ] || { echo "FAIL list did not return ok:true json"; fail=1; }
{ [ "$localpub" = n/a ] || [ "$localpub" = ok ]; } || { echo "FAIL local public target: $localpub"; fail=1; }
[ "$fail" = 0 ]
