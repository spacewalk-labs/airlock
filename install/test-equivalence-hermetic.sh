#!/usr/bin/env bash
# install/test-equivalence-hermetic.sh — the equivalence harness must be
# independent of the host's /etc/airlock, /opt/airlock and system unit dir.
#
# Measured 2026-08-25, on a box with airlock actually installed: the
# equivalence transcript gained dev-monitor's `pre-ledger artifact(s) found`
# line (adopt-scan globbing the real /etc/airlock, /opt/airlock/libexec and
# /etc/systemd/system) and lost `[dry] sudo chmod o+x /opt/airlock` (publish's
# mkdir_nginx_path probing whether the real /opt/airlock already exists). The
# dangerous failure mode is SUCCESS: a --regen there commits that box's state
# as the golden, CI goes green, and nothing ever says so. The fix pins both
# reads (AIRLOCK_PLATFORM_ETC / AIRLOCK_PLATFORM_OPT / AIRLOCK_UNIT_DIR_SYSTEM
# for the scan, AIRLOCK_DRY_RUN_FSROOT for the probe); this suite is the
# machine check that the pins exist and actually reach the reads.
#
# Two layers, because each is the other's positive control:
#   C — the certified installed-state publish probe responds in BOTH states
#     (/opt/airlock present and absent). Retired adopt-scan cases are removed. Without
#     these, the pollution runs below could pass vacuously — e.g. a renamed
#     variable would leave the harness green on CI while the leak returned
#     on every real box ("absence must be measured, not observed").
#   D/E — the REAL test-equivalence.sh, run with all four variables polluted
#     toward a populated fake host (D) and an empty one (E), must pass both
#     times: its own pins override whatever it inherits. Drop a pin from the
#     harness and D fails on any runner, CI included.
#
# Offline, dry-run only: no sudo, no systemctl, nothing outside mktemp dirs.
set -uo pipefail
. "$(dirname "$0")/test-lib.sh"
airlock_pin_paseo_mem

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

airlock_test_counters_init

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- fixed fixture, same shape as install/test-equivalence.sh --------------
mkdir -p "$TMP/home" "$TMP/web" "$TMP/confd" "$TMP/code" "$TMP/state" "$TMP/bin"
export HOME="$TMP/home"
export AIRLOCK_CONFIG="$TMP/airlock.toml"
export AIRLOCK_STATE_DIR="$TMP/state"
export AIRLOCK_WEBROOT="$TMP/web"
export AIRLOCK_CONFD="$TMP/confd"
export AIRLOCK_TS_FQDN="box.example.ts.net"
export AIRLOCK_DRY_RUN=1

cat > "$AIRLOCK_CONFIG" <<EOF
[site]
name = "Equivalence"

[auth]
provider = "tailscale"
owner = "owner@fixture.dev"

[paths]
code_root = "$TMP/code"

[apps.hub]
[apps.notepad]
[apps.publish]
[apps.devterm]
EOF

while IFS=$'\t' read -r _owner cmd _rest; do
  case "$cmd" in ""|\#*) continue ;; esac
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/$cmd"
    chmod +x "$TMP/bin/$cmd"
  fi
done < "$ROOT/install/prerequisites.tsv"
cat > "$TMP/bin/loginctl" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  show-user)     echo "Linger=no" ;;
  enable-linger) exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/loginctl"
export PATH="$TMP/bin:$PATH"

# ---- two fake hosts --------------------------------------------------------
# Populated: exactly the three dev-monitor artifacts the 2026-08-25 leak
# reported, plus an existing /opt/airlock for the publish probe.
POP="$TMP/host-populated"
mkdir -p "$POP/etc-airlock" "$POP/opt-airlock/libexec" "$POP/unit-system" \
         "$POP/fsroot/opt/airlock"
: > "$POP/etc-airlock/dev-monitor-spool.nft"
: > "$POP/opt-airlock/libexec/airlock-dev-monitor-spool-firewall"
: > "$POP/unit-system/airlock-dev-monitor-spool-firewall.service"

# Empty: nothing pre-installed; /opt exists but /opt/airlock does not (the
# state the committed goldens describe).
EMPTY="$TMP/host-empty"
mkdir -p "$EMPTY/etc-airlock" "$EMPTY/opt-airlock" "$EMPTY/unit-system" \
         "$EMPTY/fsroot/opt"

# The engine retired adopt-scan; its old populated/empty scan cases no longer
# describe an operator entry. Keep both host roots for the live fs probe and
# the harness's inherited-state controls below.

# ---- C: the publish dry run's chmod lines follow the pinned probe root -----
# This is an EXISTING installed box: only that preview may run certified hooks.
python3 - "$AIRLOCK_STATE_DIR/installed-apps.json" "$ROOT/apps/publish" <<'PY_PUBLISH_INSTALLED'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({"publish": {
    "repo": sys.argv[2], "commit": "", "artifacts": []}}))
PY_PUBLISH_INSTALLED
publish_record_before="$(cat "$AIRLOCK_STATE_DIR/installed-apps.json")"
install_with_fsroot() {  # <hostdir> <transcript>
  AIRLOCK_PLATFORM_ETC="$EMPTY/etc-airlock" \
  AIRLOCK_PLATFORM_OPT="$EMPTY/opt-airlock" \
  AIRLOCK_UNIT_DIR_SYSTEM="$EMPTY/unit-system" \
  AIRLOCK_DRY_RUN_FSROOT="$1/fsroot" \
    bash "$ROOT/install/airlock-install.sh" > "$2" 2>&1
}
oplus='[dry] sudo chmod o+x /opt/airlock'
o755='[dry] sudo chmod 755 /opt/airlock/share'
if install_with_fsroot "$EMPTY" "$TMP/c-empty.txt"; then
  if grep -qF "$oplus" "$TMP/c-empty.txt" && grep -qF "$o755" "$TMP/c-empty.txt"; then
    ok "probe root without /opt/airlock -> dry run creates it (chmod o+x line present)"
  else
    bad "probe root without /opt/airlock did not produce the expected chmod lines:
$(grep -F '[dry] sudo' "$TMP/c-empty.txt" || tail -5 "$TMP/c-empty.txt")"
  fi
else
  bad "dry install against the empty probe root failed: $(tail -5 "$TMP/c-empty.txt")"
fi
if install_with_fsroot "$POP" "$TMP/c-pop.txt"; then
  if ! grep -qF "$oplus" "$TMP/c-pop.txt" && grep -qF "$o755" "$TMP/c-pop.txt"; then
    ok "probe root with /opt/airlock -> chmod o+x line gone, share chmod still present (probe demonstrably read the pinned root, not the box)"
  else
    bad "probe root with /opt/airlock still produced (or lost) the wrong chmod lines:
$(grep -F '[dry] sudo' "$TMP/c-pop.txt" || tail -5 "$TMP/c-pop.txt")"
  fi
else
  bad "dry install against the populated probe root failed: $(tail -5 "$TMP/c-pop.txt")"
fi

if [ "$(cat "$AIRLOCK_STATE_DIR/installed-apps.json")" = "$publish_record_before" ]; then
  ok "installed-state certified dry hook preserves the installation record"
else
  bad "installed-state certified dry hook changed the installation record"
fi

# ---- D/E: the real harness neutralises inherited host state ----------------
pollute_and_run() {  # <hostdir>
  AIRLOCK_PLATFORM_ETC="$1/etc-airlock" \
  AIRLOCK_PLATFORM_OPT="$1/opt-airlock" \
  AIRLOCK_UNIT_DIR_SYSTEM="$1/unit-system" \
  AIRLOCK_DRY_RUN_FSROOT="$1/fsroot" \
    AIRLOCK_EQUIVALENCE_CORE_ONLY=1 bash "$HERE/test-equivalence.sh"
}
if d_out="$(pollute_and_run "$POP" 2>&1)"; then
  ok "test-equivalence.sh passes with all four variables polluted toward a populated host (its pins override them)"
else
  bad "test-equivalence.sh leaked the populated fake host through its pins:
$d_out"
fi
if e_out="$(pollute_and_run "$EMPTY" 2>&1)"; then
  ok "test-equivalence.sh passes with the variables polluted toward an empty host"
else
  bad "test-equivalence.sh failed under empty-host pollution:
$e_out"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
