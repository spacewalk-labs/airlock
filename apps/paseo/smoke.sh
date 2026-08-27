#!/usr/bin/env bash
# paseo smoke — against a live install (after orchestrator render + reload).
# paseo may answer / with a redirect, so 200 OR 302 both count as reachable.
set -uo pipefail
# ABI (D5): the caller sets AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID and runs
# this script with cwd = AIRLOCK_APP_DIR. AIRLOCK_ROOT is REQUIRED: the platform
# root cannot be derived from $0, because "$0/../.." is only the platform when the
# package happens to sit in the platform's own apps/ tree — the arrangement the
# apps/ cutover ends. $0-relative self-location (this file's own directory) stays
# fine and is what AIRLOCK_APP_DIR falls back to.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run this through install/airlock-install.sh (or bin/airlock-smoke), or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID yourself. There is deliberately no \$0-relative fallback — this package does not have to live inside the platform tree.}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-paseo}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

airlock_load paseo
GATE="$AIRLOCK_PASEO_GATE_PORT"
BACKEND="$AIRLOCK_PASEO_BACKEND_PORT"
HDR="$AIRLOCK_IDENTITY_HEADER"
OWNER="${AIRLOCK_OWNER%%,*}"

code() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$@"; }
c_be=$(code   "http://127.0.0.1:${BACKEND}/")
c_own=$(code  -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${GATE}/")
c_deny=$(code -H "${HDR}: nobody@example.com" "http://127.0.0.1:${GATE}/")
c_no=$(code                                    "http://127.0.0.1:${GATE}/")

# --- cross-device ui-state route ---
# Two answers matter and they are different failures: the owner must be able to READ
# the shared sidebar order (404 counts — nothing stored yet is the normal first state,
# and the patched bundle falls back to the device's own copy), and a non-owner must be
# refused. A route that answered everyone would put the owner's workspace layout, and
# a writable store, in front of every identity the tailnet lets reach this gate.
UISTATE_KEY=sidebar-project-workspace-order
c_ui_own=$(code  -H "${HDR}: ${OWNER}"           "http://127.0.0.1:${GATE}/airlock-ui-state/${UISTATE_KEY}")
c_ui_deny=$(code -H "${HDR}: nobody@example.com" "http://127.0.0.1:${GATE}/airlock-ui-state/${UISTATE_KEY}")

# --- installed paseo version vs this tree's pin ---
# install.sh dies on a version mismatch, but only on the path where it just
# installed — it short-circuits whenever the binary already reports the pin. So an
# already-installed box has no way to say what it is running, and a box never re-run
# after a version bump looks exactly like one that was.
#
# Read the version out of the installed package.json, never by running the binary:
# paseo's shebang is `#!/usr/bin/env -S node --disable-warning=DEP0040`, which dies
# with `node: bad option` under an older node. Running it measures the caller's PATH,
# not the installation, and reports a broken measurement as a broken install.
SVC=airlock-paseo.service
exec_start=$(systemctl --user show -p ExecStart --value "$SVC" 2>/dev/null)
paseo_bin=$(printf '%s' "$exec_start" | grep -oE '/[^ ]*/bin/paseo' | head -1)
pkg=""; ver=""
if [ -n "$paseo_bin" ]; then
  pkg="${paseo_bin%/bin/paseo}/lib/node_modules/@getpaseo/cli/package.json"
  [ -f "$pkg" ] && ver=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$pkg" 2>/dev/null)
fi
pin=$(sed -n 's/^PASEO_VER="\${AIRLOCK_PASEO_VERSION:-\([^}]*\)}".*/\1/p' "$HERE/install.sh" 2>/dev/null | head -1)

echo "[paseo smoke] backend=${c_be}/200|302 owner=${c_own}/200|302 deny=${c_deny}/403 no-header=${c_no}/403 ui-state=${c_ui_own}/200|404,${c_ui_deny}/403 paseo=${ver:-?}/${pin:-?}"
fail=0
# Not-measured and measured-wrong are different answers. Only the second is a FAIL —
# but "the unit is running and I cannot read its version" is the first masquerading
# as the second, so it fails too: on a box running the daemon that means a broken
# install or a moved dist layout, not an unmeasurable one.
where="expected $pkg"
[ -n "$paseo_bin" ] || where="ExecStart names no */bin/paseo: $exec_start"
if [ -z "$pin" ]; then
  echo "WARN version pin unreadable from $HERE/install.sh — installed version not compared"
elif [ -z "$exec_start" ]; then
  echo "WARN paseo not installed here ($SVC has no ExecStart) — version not compared"
elif [ -n "$ver" ]; then
  [ "$ver" = "$pin" ] || { echo "FAIL paseo version: installed ${ver}, pinned ${pin} (re-run apps/paseo/install.sh)"; fail=1; }
elif systemctl --user is-active --quiet "$SVC" 2>/dev/null; then
  echo "FAIL paseo version unreadable while $SVC is active — $where"; fail=1
else
  echo "WARN paseo version unreadable and $SVC is not active — version not compared ($where)"
fi
{ [ "$c_be" = 200 ] || [ "$c_be" = 302 ]; }   || { echo "FAIL backend (paseo daemon not reachable on 127.0.0.1:${BACKEND})"; fail=1; }
{ [ "$c_own" = 200 ] || [ "$c_own" = 302 ]; } || { echo "FAIL owner"; fail=1; }
[ "$c_deny" = 403 ] || { echo "FAIL deny (gate hole)"; fail=1; }
[ "$c_no"   = 403 ] || { echo "FAIL no-header (gate hole)"; fail=1; }
{ [ "$c_ui_own" = 200 ] || [ "$c_ui_own" = 404 ]; } \
  || { echo "FAIL ui-state (cross-device sidebar order not reachable through the gate: ${c_ui_own})"; fail=1; }
[ "$c_ui_deny" = 403 ] || { echo "FAIL ui-state deny (gate hole: ${c_ui_deny})"; fail=1; }
[ "$fail" = 0 ]
