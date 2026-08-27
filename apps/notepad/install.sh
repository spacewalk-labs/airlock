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

# ABI (D5): the caller sets AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID and runs
# this script with cwd = AIRLOCK_APP_DIR. AIRLOCK_ROOT is REQUIRED: the platform
# root cannot be derived from $0, because "$0/../.." is only the platform when the
# package happens to sit in the platform's own apps/ tree — the arrangement the
# apps/ cutover ends. $0-relative self-location (this file's own directory) stays
# fine and is what AIRLOCK_APP_DIR falls back to.
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run this through install/airlock-install.sh (or bin/airlock-smoke), or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID yourself. There is deliberately no \$0-relative fallback — this package does not have to live inside the platform tree.}"
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
