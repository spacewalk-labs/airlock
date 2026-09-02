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
#   A/B/C — the seams respond to the variables at all, in BOTH states
#     (artifacts present -> reported / probed; absent -> silent). Without
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
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

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

scan() {  # scan <hostdir> — adopt-scan against that fake host
  AIRLOCK_PLATFORM_ETC="$1/etc-airlock" \
  AIRLOCK_PLATFORM_OPT="$1/opt-airlock" \
  AIRLOCK_UNIT_DIR_SYSTEM="$1/unit-system" \
    "$ROOT/bin/airlock-config" adopt-scan
}

# ---- A: populated host -> the scan reports all three artifacts -------------
a_out="$(scan "$POP" 2>&1)"; a_rc=$?
a_want=("$POP/etc-airlock/dev-monitor-spool.nft"
        "$POP/opt-airlock/libexec/airlock-dev-monitor-spool-firewall"
        "$POP/unit-system/airlock-dev-monitor-spool-firewall.service")
a_missing=0
for p in "${a_want[@]}"; do
  # The scan prints realpath-canonical paths; canonicalise the expectation too.
  grep -qF "$(realpath "$p")" <<<"$a_out" || a_missing=$((a_missing+1))
done
if [ "$a_rc" = 0 ] && [ "$a_missing" = 0 ] \
    && grep -q "^ADOPT	dev-monitor	" <<<"$a_out"; then
  ok "adopt-scan reads the pinned roots: populated fake host -> ADOPT dev-monitor with all 3 artifact paths"
else
  bad "adopt-scan did not report the populated fake host (rc=$a_rc, missing=$a_missing): $a_out"
fi

# ---- B: empty host -> silence, from a scan A just proved alive -------------
b_out="$(scan "$EMPTY" 2>&1)"; b_rc=$?
if [ "$b_rc" = 0 ] && [ -z "$b_out" ]; then
  ok "adopt-scan on the empty fake host is silent (same scan that just reported, so silence is measured)"
else
  bad "adopt-scan on the empty fake host was not silent (rc=$b_rc): $b_out"
fi

# ---- C: the publish dry run's chmod lines follow the pinned probe root -----
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

# ---- D/E: the real harness neutralises inherited host state ----------------
pollute_and_run() {  # <hostdir>
  AIRLOCK_PLATFORM_ETC="$1/etc-airlock" \
  AIRLOCK_PLATFORM_OPT="$1/opt-airlock" \
  AIRLOCK_UNIT_DIR_SYSTEM="$1/unit-system" \
  AIRLOCK_DRY_RUN_FSROOT="$1/fsroot" \
    bash "$HERE/test-equivalence.sh"
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
