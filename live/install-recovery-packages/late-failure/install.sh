#!/usr/bin/env bash
# Checked-in late failure used only by live/install-recovery-in-container.sh.
set -euo pipefail

: "${AIRLOCK_ROOT:?}"
: "${AIRLOCK_APP_ID:?}"
: "${AIRLOCK_INSTALL_RECOVERY_SCENARIO:?}"
: "${AIRLOCK_INSTALL_RECOVERY_MARKER_DIR:?}"

[ "$AIRLOCK_APP_ID" = zz-install-recovery-fail ] || exit 84
expected="$HOME/.local/state/airlock-install-recovery-driver"
[ "$(realpath -m "$AIRLOCK_INSTALL_RECOVERY_MARKER_DIR")" = "$expected" ] || exit 84
install -d -m 0700 "$expected"

case "$AIRLOCK_INSTALL_RECOVERY_SCENARIO" in
  r1)
    printf 'r1 late package reached before transaction commit\n' \
      > "$expected/late-package-r1.txt"
    chmod 0600 "$expected/late-package-r1.txt"
    exit 86
    ;;
  r3-forward|r3-refuse)
    spool="$HOME/.local/state/airlock/dev-monitor/spool"
    database="$HOME/.local/state/airlock/dev-monitor/messages.db"
    heartbeat_id="heartbeat:$(date -u +%Y-%m-%d)"
    (cd "$AIRLOCK_ROOT/apps/dev-monitor" \
      && PYTHONDONTWRITEBYTECODE=1 python3 heartbeat.py --spool "$spool") \
      > "$expected/heartbeat-producer.txt"
    chmod 0600 "$expected/heartbeat-producer.txt"
    consumed=0
    for _ in $(seq 1 60); do
      if python3 - "$database" "$heartbeat_id" <<'PY'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as connection:
    row = connection.execute("SELECT 1 FROM ledger WHERE id=?", (sys.argv[2],)).fetchone()
raise SystemExit(0 if row else 1)
PY
      then
        consumed=1
        break
      fi
      sleep 0.5
    done
    [ "$consumed" = 1 ] || {
      echo "late failure package: running dev-monitor did not consume the heartbeat" >&2
      exit 85
    }
    printf '%s\n' "$heartbeat_id" > "$expected/heartbeat-consumed-id.txt"
    chmod 0600 "$expected/heartbeat-consumed-id.txt"
    exit 86
    ;;
  *)
    echo "late failure package: unsupported recovery scenario" >&2
    exit 84
    ;;
esac
