#!/usr/bin/env bash
# Fail exactly one post-commit dev-monitor activation start in a disposable run.
set -euo pipefail

REAL_SYSTEMCTL="$(PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin command -v systemctl)"
[ -n "$REAL_SYSTEMCTL" ] || { echo "install-recovery-systemctl: real systemctl missing" >&2; exit 127; }

scenario="${AIRLOCK_INSTALL_RECOVERY_SCENARIO:-}"
state="${AIRLOCK_INSTALL_RECOVERY_STATE_DIR:-}"
token="${AIRLOCK_INSTALL_RECOVERY_FAULT_TOKEN:-}"
marker="${AIRLOCK_INSTALL_RECOVERY_FAULT_MARKER:-}"

is_target=0
if [ "$#" = 3 ] && [ "$1" = --user ] && [ "$2" = start ] \
    && [ "$3" = airlock-dev-monitor.service ]; then
  is_target=1
fi

if [ "$scenario" = r2 ] && [ "$is_target" = 1 ] \
    && [ -n "$state" ] && [ -n "$token" ] && [ -n "$marker" ] \
    && [ -f "$token" ] && [ ! -L "$token" ] \
    && [ "$(stat -c '%u:%a' "$token" 2>/dev/null || true)" = "$(id -u):600" ] \
    && [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
  verdict="$(python3 - "$state" <<'PY'
import json
import os
from pathlib import Path
import stat
import sys

state = Path(sys.argv[1])
tx_path = state / "install-transaction.json"
activation_path = state / "dev-monitor-activation.json"
try:
    tx_info = tx_path.lstat()
    activation_info = activation_path.lstat()
    if not stat.S_ISREG(tx_info.st_mode) or tx_path.is_symlink():
        raise ValueError("transaction-not-regular")
    if not stat.S_ISREG(activation_info.st_mode) or activation_path.is_symlink():
        raise ValueError("activation-not-regular")
    if tx_info.st_uid != os.getuid() or stat.S_IMODE(tx_info.st_mode) != 0o600:
        raise ValueError("transaction-not-private")
    if activation_info.st_uid != os.getuid() or stat.S_IMODE(activation_info.st_mode) != 0o600:
        raise ValueError("activation-not-private")
    tx = json.loads(tx_path.read_text(encoding="utf-8"))
    activation = json.loads(activation_path.read_text(encoding="utf-8"))
    if tx.get("phase") != "committed":
        raise ValueError("transaction-not-committed")
    if activation.get("transaction_id") != tx.get("id"):
        raise ValueError("activation-transaction-mismatch")
    print(tx["id"])
except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
    print(f"NO:{exc}")
PY
)"
  case "$verdict" in
    NO:*) ;;
    *)
      [[ "$verdict" =~ ^[0-9a-f]{32}$ ]] || exec "$REAL_SYSTEMCTL" "$@"
      consumed="${token}.consumed"
      if mv -T -- "$token" "$consumed" 2>/dev/null; then
        umask 077
        {
          printf 'scenario=r2\n'
          printf 'transaction_id=%s\n' "$verdict"
          printf 'argv=--user start airlock-dev-monitor.service\n'
          printf 'taken_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        } > "$marker"
        echo "install-recovery-systemctl: injected post-commit activation failure" >&2
        exit 86
      fi
      ;;
  esac
fi

exec "$REAL_SYSTEMCTL" "$@"
