#!/usr/bin/env bash
# Hermetic install/uninstall contract for the first platform-owned user timer. No live
# user manager is contacted: HOME and systemctl are both scratch fixtures.
set -uo pipefail

# This suite's text names a real app installer, so render-parity's paseo RAM pin gate
# counts it among the suites that must fix the memory ceiling paseo sizes from. Pinning
# keeps the run hermetic: without it the expected value would follow whatever RAM this
# machine happens to have, and the suite would pass or fail by host.
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"
BIN_DIR="$TMP/bin"
LOG="$TMP/systemctl.log"
mkdir -p "$HOME_DIR" "$BIN_DIR"

cat > "$BIN_DIR/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$AIRLOCK_SYSTEMCTL_LOG"
exit 0
SH
chmod 0755 "$BIN_DIR/systemctl"

pass=0 fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }

if env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" AIRLOCK_SYSTEMCTL_LOG="$LOG" \
    bash "$ROOT/install/airlock-secret-timer.sh" install >/dev/null 2>&1; then
  ok "platform timer installer completes against an isolated user manager"
else
  bad "platform timer installer completes against an isolated user manager"
fi

# The helper can be perfect and still be dead code. Pin its one production entry from
# the platform orchestrator; app installers intentionally remain outside this ownership
# path, and teardown has its separate exercised entry below.
if [ "$(grep -cF 'bash "$ROOT/install/airlock-secret-timer.sh" install' \
      "$ROOT/install/airlock-install.sh")" -eq 1 ]; then
  ok "platform orchestrator invokes the timer installer exactly once"
else
  bad "platform orchestrator invokes the timer installer exactly once"
fi

UNIT_DIR="$HOME_DIR/.config/systemd/user"
SERVICE="$UNIT_DIR/airlock-secret-sweep.service"
TIMER="$UNIT_DIR/airlock-secret-sweep.timer"
if [ -f "$SERVICE" ] && [ -f "$TIMER" ] \
   && grep -qF "ExecStart=\"$ROOT/bin/airlock-secret\" sweep" "$SERVICE" \
   && ! grep -q '@[A-Z_]*@' "$SERVICE" "$TIMER"; then
  ok "service renders the absolute platform CLI and leaves no placeholder"
else
  bad "service renders the absolute platform CLI and leaves no placeholder"
fi
if grep -qF 'PLATFORM unit' "$SERVICE" \
   && grep -qF 'when every consuming app is' "$SERVICE" \
   && grep -q '^Persistent=true$' "$TIMER" \
   && grep -q '^OnUnitActiveSec=1min$' "$TIMER"; then
  ok "unit comments and cadence pin app-independent TTL enforcement"
else
  bad "unit comments and cadence pin app-independent TTL enforcement"
fi
if grep -qxF -- '--user daemon-reload' "$LOG" \
   && grep -qxF -- '--user enable --now airlock-secret-sweep.timer' "$LOG"; then
  ok "install reloads and enables the platform timer"
else
  bad "install reloads and enables the platform timer"
fi

if env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" AIRLOCK_SYSTEMCTL_LOG="$LOG" \
    bash "$ROOT/bin/airlock-teardown" --platform-secret-timer >/dev/null 2>&1; then
  ok "airlock-teardown exposes the explicit platform timer exit"
else
  bad "airlock-teardown exposes the explicit platform timer exit"
fi
if [ ! -e "$SERVICE" ] && [ ! -e "$TIMER" ] \
   && grep -qxF -- '--user disable --now airlock-secret-sweep.timer' "$LOG" \
   && [ "$(grep -xcF -- '--user daemon-reload' "$LOG")" -eq 2 ]; then
  ok "teardown disables, removes, and reloads symmetrically"
else
  bad "teardown disables, removes, and reloads symmetrically"
fi

DRY_HOME="$TMP/dry-home"
mkdir "$DRY_HOME"
dry_out="$(env HOME="$DRY_HOME" PATH="$BIN_DIR:$PATH" AIRLOCK_SYSTEMCTL_LOG="$LOG" \
  AIRLOCK_DRY_RUN=1 bash "$ROOT/install/airlock-secret-timer.sh" install 2>&1)"
if [ ! -e "$DRY_HOME/.config/systemd/user" ] \
   && grep -qF '[dry] render platform secret units' <<<"$dry_out" \
   && grep -qF '[dry] systemctl --user enable --now airlock-secret-sweep.timer' <<<"$dry_out"; then
  ok "dry run reports the timer without touching HOME or systemd"
else
  bad "dry run reports the timer without touching HOME or systemd"
fi

printf 'secret-timer: %s ok, %s failed\n' "$pass" "$fail"
exit "$((fail != 0))"
