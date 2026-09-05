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

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
