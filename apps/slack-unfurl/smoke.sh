#!/usr/bin/env bash
# Mode 644: the orchestrator invokes lifecycle scripts with bash.
set -uo pipefail

ROOT="${AIRLOCK_ROOT:?required by the D5 app ABI: run through bin/airlock-smoke, or set AIRLOCK_ROOT/AIRLOCK_APP_DIR/AIRLOCK_APP_ID explicitly}"
AIRLOCK_APP_ID="${AIRLOCK_APP_ID:-slack-unfurl}"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"

airlock_load slack-unfurl

SECRET_ENV_FILE="$HOME/.config/airlock-slack-unfurl.env"
if [ -L "$SECRET_ENV_FILE" ] || [ ! -f "$SECRET_ENV_FILE" ] \
  || [ ! -O "$SECRET_ENV_FILE" ] \
  || [ "$(stat -c '%a' -- "$SECRET_ENV_FILE" 2>/dev/null)" != 600 ]; then
  echo "slack-unfurl smoke: FAILED (token EnvironmentFile must be an owner-owned regular file with mode 0600)"
  exit 1
fi

if systemctl --user is-active --quiet airlock-slack-unfurl.service; then
  echo "slack-unfurl smoke: ok (unit active)"
else
  echo "slack-unfurl smoke: FAILED (airlock-slack-unfurl.service is not active)"
  exit 1
fi
