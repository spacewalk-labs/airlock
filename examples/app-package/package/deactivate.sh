#!/usr/bin/env bash
# The ledger stops/removes the declared unit and fragment after this hook.
# This app creates no undeclared state or retained data of its own.
set -euo pipefail

: "${AIRLOCK_ROOT:?AIRLOCK_ROOT is required (run through Airlock)}"
: "${AIRLOCK_APP_DIR:?AIRLOCK_APP_DIR is required (run through Airlock)}"
: "${AIRLOCK_APP_ID:?AIRLOCK_APP_ID is required (run through Airlock)}"

# shellcheck source=/dev/null
. "$AIRLOCK_ROOT/install/lib.sh"

log "hello-example deactivated; Airlock will remove its declared artifacts"
