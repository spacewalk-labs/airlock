#!/usr/bin/env bash
# A successful install of this package would mean the intended failure was missed.
set -euo pipefail
: "${AIRLOCK_INSTALL_RECOVERY_MARKER_DIR:?}"
printf 'unexpected smoke execution\n' > "$AIRLOCK_INSTALL_RECOVERY_MARKER_DIR/smoke-reached.txt"
chmod 0600 "$AIRLOCK_INSTALL_RECOVERY_MARKER_DIR/smoke-reached.txt"
echo "install-recovery late package unexpectedly reached smoke" >&2
exit 95
