#!/usr/bin/env bash
# Install the example backend and its hub subpath. The orchestrator supplies
# the D5 ABI variables; do not infer the platform root from this package path.
set -euo pipefail

: "${AIRLOCK_ROOT:?AIRLOCK_ROOT is required (run through Airlock)}"
: "${AIRLOCK_APP_DIR:?AIRLOCK_APP_DIR is required (run through Airlock)}"
: "${AIRLOCK_APP_ID:?AIRLOCK_APP_ID is required (run through Airlock)}"

# shellcheck source=/dev/null
. "$AIRLOCK_ROOT/install/lib.sh"

require_cmd python3 systemctl sed
airlock_load hello-example

BACKEND_PORT="${AIRLOCK_HELLO_EXAMPLE_BACKEND_PORT:?}"
PACKAGE_DIR="$AIRLOCK_APP_DIR"
UNIT_DIR="${AIRLOCK_UNIT_DIR_USER:-$HOME/.config/systemd/user}"
CONFD="${AIRLOCK_CONFD:-/etc/airlock/nginx}"
UNIT="$UNIT_DIR/airlock-hello-example.service"
FRAGMENT="$CONFD/hub-locations.d/hello-example.conf"
PYTHON3="$(command -v python3)"

if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then
  log "[dry] write $UNIT (127.0.0.1:$BACKEND_PORT)"
  log "[dry] write $FRAGMENT"
else
  install -d "$UNIT_DIR" "$CONFD/hub-locations.d"

  unit_changed=0
  if write_if_changed "$UNIT" <<UNIT
[Unit]
Description=Airlock hello-example backend (127.0.0.1:${BACKEND_PORT})
After=network.target

[Service]
Type=simple
WorkingDirectory=${PACKAGE_DIR}
Environment=HELLO_EXAMPLE_BACKEND_PORT=${BACKEND_PORT}
ExecStart=${PYTHON3} backend.py
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
UNIT
  then
    unit_changed=1
  fi

  if sed "s/@BACKEND_PORT@/${BACKEND_PORT}/g" "$PACKAGE_DIR/hello-location.conf" \
      | write_if_changed "$FRAGMENT"; then
    log "wrote nginx fragment: $FRAGMENT"
  fi

  if [ "$unit_changed" = 1 ]; then
    airlock_run systemctl --user daemon-reload
    airlock_run systemctl --user enable airlock-hello-example.service
    airlock_run systemctl --user restart airlock-hello-example.service
  else
    airlock_run systemctl --user enable --now airlock-hello-example.service
  fi
fi

log "hello-example installed (backend: 127.0.0.1:$BACKEND_PORT)"
