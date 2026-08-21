#!/usr/bin/env bash
# notepad — a clipboard/scratchpad page that drops pasted images and attached
# files into ~/uploads (for a terminal/agent to pick up by path). It is a static
# page served by the hub; the upload endpoints are the SHARED publish backend, so
# notepad requires [apps.publish]. Same-origin subpath under the hub.
#
#   browser --> hub --(identity)--> hub nginx
#     /notepad/         -> notepad UI (static, from the hub webroot)
#     /publish/api/...  -> publish backend (upload-image / upload-file / cleanup)
#
# Config from airlock.toml. Honors AIRLOCK_DRY_RUN=1.
set -euo pipefail

# ABI (D5): the orchestrator sets AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID
# and runs this script with cwd = AIRLOCK_APP_DIR. Fall back to the
# $0-relative computation for a standalone invocation (a test harness that
# runs this script directly, outside install/airlock-install.sh) — both
# resolve to the same path when run through the orchestrator.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:-$(cd "$HERE/../.." && pwd)}"
HERE="${AIRLOCK_APP_DIR:-$HERE}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-notepad}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

# notepad's uploads use the publish backend — refuse to install a broken card.
airlock_config apps | grep -qx publish \
  || die "notepad requires [apps.publish] (it uses the publish backend for uploads). Add [apps.publish] to airlock.toml."

airlock_load notepad   # (no per-app keys today; validates the app is enabled)
WEBROOT="${AIRLOCK_WEBROOT:-/opt/airlock/hub}"

# --- manager UI into the hub webroot (served by the hub's static location /) ---
if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] install notepad.html -> $WEBROOT/notepad/index.html"
else
  install -d "$WEBROOT/notepad"
  install -m644 "$HERE/frontend/notepad.html" "$WEBROOT/notepad/index.html"
fi

# No nginx fragment: /notepad/ is served by the hub's static location / (gated at
# the server level), and its API calls hit /publish/api/* provided by publish.
log "notepad installed (owner: ${AIRLOCK_OWNER})"
