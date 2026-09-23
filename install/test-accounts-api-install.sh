#!/usr/bin/env bash
# Hermetic install/uninstall contract for the platform account surface service.
# Shaped after install/test-secret-timer.sh: scratch HOME, scratch systemctl, no live
# user manager and no live unit.
#
# 🔴 Why this suite exists at the size it does. The helper shipped with NO test, and the
# assertion it added — `systemctl --user is-active` — is a verb the established test
# shims did not answer. Four suites that run the real platform installer answer
# `list-timers` (because the timer helpers assert on it) and returned empty for
# is-active, so the helper read "not active", died, and took the whole installer with it.
# CI went red in two jobs for a reason that had nothing to do with the service itself.
# T4/T5 below are that defect, turned into checks.
set -uo pipefail

# Names a real app installer in its text (via the orchestrator check below), so
# render-parity's paseo RAM pin gate counts this suite. Pinning keeps it host-independent.
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
HOME_DIR="$TMP/home"; BIN_DIR="$TMP/bin"; LOG="$TMP/systemctl.log"
UNIT_DIR="$HOME_DIR/.config/systemd/user"
mkdir -p "$HOME_DIR" "$BIN_DIR"

CFG="$TMP/airlock.toml"
printf '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[apps.hub]\n' > "$CFG"

pass=0 fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }

# The shim answers is-active with whatever the test puts in $TMP/is-active.
mk_shim() {
  cat > "$BIN_DIR/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$AIRLOCK_SYSTEMCTL_LOG"
case "$*" in
  *is-active*) [ -f "$AIRLOCK_SHIM_STATE/is-active" ] && cat "$AIRLOCK_SHIM_STATE/is-active" ;;
esac
exit 0
SH
  chmod 0755 "$BIN_DIR/systemctl"
}
mk_shim
printf 'active\n' > "$TMP/is-active"

run() {
  env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" AIRLOCK_SYSTEMCTL_LOG="$LOG" \
      AIRLOCK_SHIM_STATE="$TMP" AIRLOCK_CONFIG="$CFG" AIRLOCK_ROOT="$ROOT" \
      bash "$ROOT/install/airlock-accounts-api.sh" "$@"
}

# ---- T1: a real install renders the unit and completes ----
: > "$LOG"
if run install >"$TMP/out" 2>&1; then
  ok "T1 installer completes against an isolated user manager"
else
  bad "T1 installer completes against an isolated user manager: $(tail -3 "$TMP/out")"
fi
[ -f "$UNIT_DIR/airlock-accounts-api.service" ] \
  && ok "T1 the unit landed in the scratch unit directory" \
  || bad "T1 no unit file was written"

# ---- T2: no placeholder survives, and the port came from config not from the script ----
unit="$UNIT_DIR/airlock-accounts-api.service"
if [ -f "$unit" ]; then
  grep -q '@[A-Z_]*@' "$unit" \
    && bad "T2 an unsubstituted placeholder survived — the unit would fail at first request" \
    || ok "T2 no unsubstituted placeholder in the rendered unit"
  # 19904 is the shipped default in bin/airlock-config's APP_DEFAULTS["hub"]; the fixture
  # config above sets no port, so seeing it here proves the value was READ rather than
  # written into the unit template or the helper.
  grep -q 'AIRLOCK_HUB_ACCOUNTS_PORT=19904' "$unit" \
    && ok "T2 the port was read from config, not hard-coded in the helper" \
    || bad "T2 unexpected port in the unit: $(grep ACCOUNTS_PORT "$unit" || echo none)"
  # The secret drop's HTTP boundary lives in this service now, so the unit must carry
  # the D5 platform CLI path — the lib.sh default, never a devterm-supplied one.
  grep -qxF "Environment=AIRLOCK_SECRET_BIN=$ROOT/bin/airlock-secret" "$unit" \
    && ok "T2 the unit hands the platform secret CLI to the secret routes" \
    || bad "T2 the unit does not name the platform secret CLI: $(grep SECRET_BIN "$unit" || echo none)"
  grep -q '^X-Airlock-Owner=airlock-install$' "$unit" \
    && ok "T2 the rendered unit carries its owner marker (so the sweep can reclaim it)" \
    || bad "T2 the rendered unit has no X-Airlock-Owner — a revert would leave it behind"
fi

# ---- T3: it asks systemd whether the service is RUNNING, not whether a file exists ----
grep -q 'is-active' "$LOG" \
  && ok "T3 the installer asked systemd for liveness" \
  || bad "T3 no is-active call — 'installed' was accepted as 'running'"
grep -q 'enable --now' "$LOG" \
  && ok "T3 the service was enabled and started" \
  || bad "T3 no 'enable --now'"

# ---- T4 (positive control): a service that does not come up must FAIL the install ----
printf 'failed\n' > "$TMP/is-active"
rm -f "$unit"
if run install >"$TMP/out" 2>&1; then
  bad "T4 a service reporting 'failed' was accepted — the liveness assertion is decorative"
else
  grep -qi 'is failed' "$TMP/out" \
    && ok "T4 a service that does not come up fails the install, and says so" \
    || bad "T4 install failed but not for the stated reason: $(tail -2 "$TMP/out")"
fi

# ---- T5 (the CI defect, as a check): an UNANSWERED is-active must not pass silently ----
# This is the state every shimmed suite was in. The helper must still refuse — the fix
# belongs in the shims (which now answer), not in a weaker assertion here.
: > "$TMP/is-active"
rm -f "$unit"
if run install >"$TMP/out" 2>&1; then
  bad "T5 an unanswered is-active was treated as active — a dead service would install clean"
else
  ok "T5 an unanswered is-active still refuses (the shims must answer, not the helper relax)"
fi
# And the shims that run the real platform installer must answer it, or the installer
# dies inside them for a reason unrelated to what they test.
# 🔴 Comments stripped, and the match is the shim's `case` arm rather than the words
# "is-active" anywhere in the file. The first version of this check grepped for the bare
# string and passed while the shim arm was deleted — the comment two lines above the arm
# satisfied it. That is the same "a comment satisfies the check" defect
# test-render-parity.sh's RAM pin gate carries a note about, reproduced here.
shim_ok=1
for s in test-operator-surface test-builtin-migration test-manifest test-packages; do
  grep -qE '\*is-active\*\)' < <(grep -vE '^[[:space:]]*#' "$ROOT/install/$s.sh") \
    || { shim_ok=0; bad "T5 install/$s.sh runs the platform installer but its systemctl shim has no is-active arm"; }
done
[ "$shim_ok" = 1 ] && ok "T5 every suite that runs the platform installer answers is-active"

# ---- T6: uninstall is symmetric ----
printf 'active\n' > "$TMP/is-active"
run install >/dev/null 2>&1
: > "$LOG"
if run uninstall >"$TMP/out" 2>&1; then
  ok "T6 uninstall completes"
else
  bad "T6 uninstall failed: $(tail -2 "$TMP/out")"
fi
[ -f "$unit" ] && bad "T6 the unit file survived uninstall" || ok "T6 the unit file is gone"
grep -q 'disable --now' "$LOG" \
  && ok "T6 uninstall stopped the service rather than only unlinking it" \
  || bad "T6 no 'disable --now' during uninstall"

# ---- T7: the helper can be perfect and still be dead code ----
[ "$(grep -cF 'bash "$ROOT/install/airlock-accounts-api.sh" install' "$ROOT/install/airlock-install.sh")" -eq 1 ] \
  && ok "T7 the orchestrator invokes this installer exactly once" \
  || bad "T7 the orchestrator does not invoke this installer exactly once"
grep -q 'airlock-accounts-api.service' "$ROOT/install/airlock-install.sh" \
  && ok "T7 the unit is in the sweep's declared set (a revert reclaims it)" \
  || bad "T7 the unit is NOT declared to the sweep — the next install would delete it"

# ---- T9 (the second CI defect, as a check): the port is READ ONCE, upstream ----
# 🔴 The helper used to call `airlock_config env hub` unconditionally, making it a SECOND
# validation gate. The break-glass fixtures deliberately hold a package lock digest
# mismatch while an install proceeds, so that re-validation failed, the port came back
# empty, and the whole install died inside a helper that has no opinion about package
# locks. An invalid config with the port already in the environment must install clean.
printf 'active\n' > "$TMP/is-active"
rm -f "$unit"
: > "$TMP/broken.toml"          # not a valid config: `airlock_config env hub` cannot work
if env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" AIRLOCK_SYSTEMCTL_LOG="$LOG" \
       AIRLOCK_SHIM_STATE="$TMP" AIRLOCK_CONFIG="$TMP/broken.toml" AIRLOCK_ROOT="$ROOT" \
       AIRLOCK_HUB_ACCOUNTS_PORT=19904 \
       bash "$ROOT/install/airlock-accounts-api.sh" install >"$TMP/out" 2>&1; then
  # Installing clean is necessary but not sufficient: an unconditional re-read still
  # "works" whenever a value was handed in, so it would survive the check above. What
  # must be true is that config was not consulted AT ALL — measured by the absence of
  # the validator's own complaint about the broken file it was never asked to judge.
  if grep -qiE 'airlock-config:|lock digest|could not|invalid' "$TMP/out"; then
    bad "T9 the helper still read config (its error is in the output) — the second gate is back"
  else
    ok "T9 a handed-in port installs without re-reading config"
  fi
else
  bad "T9 the helper re-validated config it was not asked to judge: $(tail -2 "$TMP/out")"
fi
# ...and standalone (no upstream, nothing handed in) it still reads config rather than
# inventing a default.
rm -f "$unit"
if run install >/dev/null 2>&1 && grep -q 'AIRLOCK_HUB_ACCOUNTS_PORT=19904' "$unit"; then
  ok "T9 with nothing handed in it falls back to config"
else
  bad "T9 the standalone config fallback is broken"
fi
# A missing port must still be fatal — the fallback must not become a default.
rm -f "$unit"
if env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" AIRLOCK_SYSTEMCTL_LOG="$LOG" \
       AIRLOCK_SHIM_STATE="$TMP" AIRLOCK_CONFIG="$TMP/broken.toml" AIRLOCK_ROOT="$ROOT" \
       bash "$ROOT/install/airlock-accounts-api.sh" install >"$TMP/out" 2>&1; then
  bad "T9 an unresolvable port was accepted — the helper invented one"
else
  ok "T9 an unresolvable port is still fatal"
fi

# ---- T10: the orchestrator actually hands the port in ----
# Without this the helper silently takes the config path again on the real install, and
# the defect above returns with every check above still green.
grep -q 'AIRLOCK_HUB_ACCOUNTS_PORT="\$AIRLOCK_HUB_ACCOUNTS_PORT"' "$ROOT/install/airlock-install.sh" \
  && ok "T10 the orchestrator hands the resolved port to the helper" \
  || bad "T10 the orchestrator does not hand the port in — the helper would re-validate config"

# ---- T8: a bad mode is refused ----
run bogus >/dev/null 2>&1 && bad "T8 an unknown mode was accepted" || ok "T8 an unknown mode is refused"

# ---- T11: hub.xai decides whether the xAI routes get a CLI path ----
# The service answers {"enabled": false} whenever AIRLOCK_OPENCODE_BIN is empty, so an
# unwired flag is a login row that silently never appears (measured on a live box,
# 2026-09-15). Off: empty. On with the CLI on PATH: its absolute path. On without it:
# the install fails instead of shipping that silent panel.
# Orchestrator form: the port and flag arrive in the environment (the helper reads
# config itself only when run standalone, and the fixture config sets no xai).
orch() { AIRLOCK_HUB_ACCOUNTS_PORT=19904 run install; }
orch >"$TMP/out9" 2>&1 || bad "T11 baseline install failed: $(tail -2 "$TMP/out9")"
grep -qxF 'Environment=AIRLOCK_OPENCODE_BIN=' "$unit" \
  && ok "T11 xai off (the default) leaves the xAI routes disabled" \
  || bad "T11 xai off rendered: $(grep OPENCODE "$unit" || echo none)"
printf '#!/bin/sh\n' > "$BIN_DIR/opencode"; chmod 0755 "$BIN_DIR/opencode"
if AIRLOCK_HUB_XAI=true orch >"$TMP/out8" 2>&1 \
   && grep -qxF "Environment=AIRLOCK_OPENCODE_BIN=$BIN_DIR/opencode" "$unit"; then
  ok "T11 xai on hands the resolved opencode path to the service"
else
  bad "T11 xai on: $(grep OPENCODE "$unit" || tail -2 "$TMP/out8")"
fi
rm -f "$BIN_DIR/opencode"
if AIRLOCK_HUB_XAI=true PATH="$BIN_DIR:/usr/bin:/bin" orch >"$TMP/out8b" 2>&1; then
  bad "T11 xai on without an opencode CLI installed anyway"
else
  grep -q "opencode CLI was not found" "$TMP/out8b" \
    && ok "T11 xai on without an opencode CLI fails the install and says why" \
    || bad "T11 wrong failure: $(tail -2 "$TMP/out8b")"
fi

# ---- T12: a death after the unit lands does not strand a disabled service ----
# 2026-09-23: the backend died via a stop after disable --now and served 502
# until a human re-enabled it; Restart=on-failure never covers an intentional
# stop. The installer re-enables best-effort on any failing exit while the
# verdict stays failed. The shim fails the first enable --now only, so a green
# run here proves the recovery arm ran, not the initial call.
cat > "$BIN_DIR/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$AIRLOCK_SYSTEMCTL_LOG"
case "$*" in
  *is-active*) [ -f "$AIRLOCK_SHIM_STATE/is-active" ] && cat "$AIRLOCK_SHIM_STATE/is-active" ;;
esac
case "$*" in
  *enable\ --now*)
    if [ ! -f "$AIRLOCK_SHIM_STATE/enable-failed-once" ]; then
      : > "$AIRLOCK_SHIM_STATE/enable-failed-once"
      exit 1
    fi ;;
esac
exit 0
SH
chmod 0755 "$BIN_DIR/systemctl"
rm -f "$TMP/enable-failed-once" "$unit"
printf 'active\n' > "$TMP/is-active"
: > "$LOG"
if run install >"$TMP/out12" 2>&1; then
  bad "T12 a failed enable --now was reported as success"
else
  grep -q 'could not enable' "$TMP/out12" \
    && ok "T12 the failed install still fails loudly, with the reason" \
    || bad "T12 wrong failure: $(tail -2 "$TMP/out12")"
fi
[ "$(grep -c 'enable --now' "$LOG")" -ge 2 ] \
  && ok "T12 the exit trap re-enabled the service after the death" \
  || bad "T12 only one enable --now ran — the stranded unit was left disabled: $(grep . "$LOG" | tail -4)"
# The trap belongs to install only: removing the service must never resurrect it.
mk_shim
: > "$LOG"
run install >/dev/null 2>&1
: > "$LOG"
run uninstall >/dev/null 2>&1
grep -q 'enable --now' "$LOG" \
  && bad "T12 uninstall re-enabled the service it was removing" \
  || ok "T12 uninstall leaves no enable behind"

# ---- T13: handed-in Muse readers reach the unit; absent ones stay empty ----
# Reader paths and the brokered address arrive box-locally (vault and tool
# names do not ship), so the helper renders exactly what it was handed — but
# only for readers that actually execute. A handed-in path to nothing must
# leave the route disabled, not enabled-looking and empty.
printf '#!/bin/sh\nexit 0\n' > "$BIN_DIR/team-reader"; chmod 0755 "$BIN_DIR/team-reader"
printf '#!/bin/sh\nexit 0\n' > "$BIN_DIR/broker"; chmod 0755 "$BIN_DIR/broker"
rm -f "$unit"
if env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" AIRLOCK_SYSTEMCTL_LOG="$LOG" \
       AIRLOCK_SHIM_STATE="$TMP" AIRLOCK_CONFIG="$TMP/broken.toml" AIRLOCK_ROOT="$ROOT" \
       AIRLOCK_HUB_ACCOUNTS_PORT=19904 \
       AIRLOCK_MUSE_SECRET_BIN="$BIN_DIR/team-reader" AIRLOCK_MUSE_CHO_BIN="$BIN_DIR/broker" \
       AIRLOCK_MUSE_CHO_REF='op://fixture-vault/OPENCODE_MU_B_API_KEY/password' \
       bash "$ROOT/install/airlock-accounts-api.sh" install >"$TMP/out13" 2>&1; then
  wired=1
  grep -qxF "Environment=AIRLOCK_MUSE_KEYS_BIN=$ROOT/bin/airlock-muse-keys" "$unit" || wired=0
  grep -qxF "Environment=AIRLOCK_MUSE_SECRET_BIN=$BIN_DIR/team-reader" "$unit" || wired=0
  grep -qxF "Environment=AIRLOCK_MUSE_CHO_BIN=$BIN_DIR/broker" "$unit" || wired=0
  grep -qxF 'Environment=AIRLOCK_MUSE_CHO_REF=op://fixture-vault/OPENCODE_MU_B_API_KEY/password' "$unit" || wired=0
  [ "$wired" = 1 ] && ok "T13 handed-in Muse readers reach the unit verbatim" \
    || bad "T13 Muse wiring wrong: $(grep MUSE "$unit" || echo none)"
else
  bad "T13 install with handed-in readers failed: $(tail -2 "$TMP/out13")"
fi
rm -f "$unit"
if env HOME="$HOME_DIR" PATH="$BIN_DIR:$PATH" AIRLOCK_SYSTEMCTL_LOG="$LOG" \
       AIRLOCK_SHIM_STATE="$TMP" AIRLOCK_CONFIG="$TMP/broken.toml" AIRLOCK_ROOT="$ROOT" \
       AIRLOCK_HUB_ACCOUNTS_PORT=19904 \
       AIRLOCK_MUSE_SECRET_BIN=/definitely/missing AIRLOCK_MUSE_CHO_BIN=/also/missing \
       bash "$ROOT/install/airlock-accounts-api.sh" install >"$TMP/out13b" 2>&1; then
  grep -qxF 'Environment=AIRLOCK_MUSE_KEYS_BIN=' "$unit" \
    && ok "T13 missing readers leave the route disabled, not enabled-empty" \
    || bad "T13 missing readers rendered enablement: $(grep MUSE "$unit" || echo none)"
else
  bad "T13 install with missing readers failed: $(tail -2 "$TMP/out13b")"
fi
rm -f "$unit"
if run install >/dev/null 2>&1; then
  grep -qxF 'Environment=AIRLOCK_MUSE_KEYS_BIN=' "$unit" \
    && ok "T13 with no readers the route stays disabled, not broken" \
    || bad "T13 unexpected Muse wiring: $(grep MUSE "$unit" || echo none)"
else
  bad "T13 baseline reinstall failed"
fi

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
