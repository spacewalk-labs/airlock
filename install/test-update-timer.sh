#!/usr/bin/env bash
# Hermetic contract for the daily update detector timer.  The production installer
# must ask systemd for the next run; rendered files alone are not evidence of a job.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
BIN_DIR="$TMP/bin"
LOG="$TMP/systemctl.log"
# This suite names the real platform installer in its wiring assertion. Pin the
# paseo sizing seam as required for every such suite, even though its fixture
# only installs the detector timer, so a future orchestrator path remains
# hermetic across runners with different RAM.
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368
mkdir -p "$HOME_DIR" "$BIN_DIR"

cat > "$BIN_DIR/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$AIRLOCK_SYSTEMCTL_LOG"
case "$*" in *list-timers*) printf '%s\n' 'Mon 2026-09-02 00:00:00 KST 1d left airlock-update-detect.timer airlock-update-detect.service' ;; esac
SH
chmod 0755 "$BIN_DIR/systemctl"

pass=0 fail=0
ok() { printf 'ok   update-timer: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL update-timer: %s\n' "$1"; fail=$((fail + 1)); }

if env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" AIRLOCK_SYSTEMCTL_LOG="$LOG" \
  bash "$ROOT/install/airlock-update-timer.sh" install >/dev/null 2>&1; then
  ok "installer completes against an isolated user manager"
else
  bad "installer completes against an isolated user manager"
fi

UNIT_DIR="$HOME_DIR/.config/systemd/user"
SERVICE="$UNIT_DIR/airlock-update-detect.service"
TIMER="$UNIT_DIR/airlock-update-detect.timer"
if [ -f "$SERVICE" ] && [ -f "$TIMER" ] \
  && grep -qF "devmon_updates.py collect --root $ROOT" "$SERVICE" \
  && grep -q '^OnCalendar=daily$' "$TIMER" \
  && grep -q '^Persistent=true$' "$TIMER" \
  && ! grep -q '@[A-Z_]*@' "$SERVICE" "$TIMER"; then
  ok "units render a daily persistent collector without placeholders"
else
  bad "units did not render the expected collector contract"
fi
if command -v systemd-analyze >/dev/null 2>&1; then
  unit_check="$(systemd-analyze --user verify --recursive-errors=no "$SERVICE" "$TIMER" 2>&1)"
  unit_rc=$?
  if [ "$unit_rc" = 0 ]; then
    ok "systemd-analyze accepts the rendered units"
  else
    bad "systemd-analyze rejected the rendered units: $unit_check"
  fi
else
  echo "note update-timer: systemd-analyze absent — unit syntax was not parser-verified"
fi
if grep -qxF -- '--user daemon-reload' "$LOG" \
  && grep -qxF -- '--user enable --now airlock-update-detect.timer' "$LOG" \
  && grep -q 'list-timers airlock-update-detect.timer' "$LOG"; then
  ok "installer proves the timer through systemctl list-timers"
else
  bad "installer did not prove the timer through systemctl list-timers"
fi

if env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" AIRLOCK_SYSTEMCTL_LOG="$LOG" \
  bash "$ROOT/install/airlock-update-timer.sh" uninstall >/dev/null 2>&1 \
  && [ ! -e "$SERVICE" ] && [ ! -e "$TIMER" ]; then
  ok "uninstall disables and removes both units"
else
  bad "uninstall did not remove both units"
fi

DRY_HOME="$TMP/dry-home"; mkdir "$DRY_HOME"
dry_out="$(env HOME="$DRY_HOME" PATH="$BIN_DIR:$PATH" AIRLOCK_SYSTEMCTL_LOG="$LOG" \
  AIRLOCK_DRY_RUN=1 bash "$ROOT/install/airlock-update-timer.sh" install 2>&1)"
if [ ! -e "$DRY_HOME/.config/systemd/user" ] \
  && grep -qF '[dry] render platform update detector units' <<<"$dry_out"; then
  ok "dry run does not create units"
else
  bad "dry run wrote units"
fi

if [ "$(grep -cF 'bash "$ROOT/install/airlock-update-timer.sh" install' "$ROOT/install/airlock-install.sh")" -eq 1 ]; then
  ok "platform orchestrator wires the detector exactly once"
else
  bad "platform orchestrator does not wire the detector exactly once"
fi

printf 'update-timer: %s ok, %s failed\n' "$pass" "$fail"
exit "$((fail != 0))"
