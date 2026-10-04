#!/usr/bin/env bash
# Red-first contracts for OPERATOR_SURFACE: config ABI 2 and explicit-package
# grants. (This suite used to also cover the repository-root digest lock;
# that mechanism was deleted outright —
# docs/reports/2026-09-27_installer-gate-zero-base-revival.md, family (a):
# an admission-control checkpoint, not a security boundary, that caused more
# install failures in two weeks than it ever prevented.) This suite never
# touches the live checkout or services: it copies the checkout to a scratch
# repository, points every writable platform root at scratch, and
# PATH-shims all service commands.
set -uo pipefail
. "$(dirname "$0")/test-lib.sh"
airlock_pin_paseo_mem

HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)" || { echo "FAIL could not create test directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Keep every installer invocation inside the fixture root. A neutral cgroup
# prevents a test hosted by airlock-paseo.service from spawning a live unit.
airlock_set_fixture_root "$TMP"
airlock_neutral_selfkill_cgroup "$TMP"

airlock_test_counters_init

# A private checkout keeps uncommitted production edits in scope while
# developing this test, without ever running against the live checkout.
ROOT="$TMP/repo"
mkdir -p "$ROOT"
if ! (cd "$SOURCE_ROOT" && tar --exclude='./.git' --exclude='./airlock.lock' -cf - .) \
     | (cd "$ROOT" && tar -xf -); then
  echo "FAIL could not create scratch repository" >&2
  exit 1
fi
CFG="$ROOT/bin/airlock-config"
LEDGER="$ROOT/bin/airlock-ledger"

# ---- scratch platform roots -------------------------------------------------
STATE="$TMP/state"; WEB="$TMP/web"; CONFD="$TMP/confd"
UU="$TMP/units-user"; US="$TMP/units-system"
FAKEHOME="$TMP/home"; DATA="$TMP/data"; MARKERS="$TMP/markers"
export AIRLOCK_STATE_DIR="$STATE" AIRLOCK_WEBROOT="$WEB" AIRLOCK_CONFD="$CONFD"
export AIRLOCK_UNIT_DIR_USER="$UU" AIRLOCK_UNIT_DIR_SYSTEM="$US"
export AIRLOCK_TS_FQDN="box.example.ts.net"
export AIRLOCK_TEST_TMP="$TMP" AIRLOCK_TEST_MARKERS="$MARKERS"
export HOME="$FAKEHOME" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf"

reset_box() {
  rm -rf "$STATE" "$WEB" "$CONFD" "$UU" "$US" "$FAKEHOME" "$DATA" "$MARKERS"
  mkdir -p "$STATE" "$WEB/assets" "$CONFD/hub-locations.d" "$CONFD/servers.d" \
           "$UU" "$US" "$FAKEHOME" "$DATA" "$MARKERS"
  : >"$TMP/systemctl.log"
  : >"$TMP/tailscale.log"
  rm -f "$TMP/tailscale-plaintext.state"
  unset AIRLOCK_TEST_FAIL_INSTALL AIRLOCK_TEST_FAIL_SMOKE AIRLOCK_TEST_HTTP_CODE \
    AIRLOCK_TEST_FAIL_PLAINTEXT AIRLOCK_TEST_PLAINTEXT_STATEFUL
}

# ---- non-live command shims -------------------------------------------------
SHIM="$TMP/shim"; mkdir -p "$SHIM"
cat >"$SHIM/sudo" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac
done
exec "$@"
STUB
cat >"$SHIM/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AIRLOCK_TEST_TMP/systemctl.log"
case "$*" in *list-timers*) printf '%s\n' 'Mon 2026-09-02 00:00:00 KST 1d left airlock-update-detect.timer airlock-update-detect.service' ;; esac
# The platform account surface is a SERVICE, so its installer asks systemd whether it is
# running rather than whether a timer is scheduled ("installed" and "active" are
# different claims and only one serves a request). Answer it, for the same reason
# list-timers above is answered: an unanswered verb reads as a dead unit and the
# installer dies.
case "$*" in *is-active*) printf '%s\n' active ;; esac
# Ledger teardown verifies the stopped state before deleting any unit.
case "$*" in *show*) printf 'LoadState=loaded\nActiveState=inactive\nMainPID=0\nControlPID=0\n' ;; esac
exit 0
STUB
cat >"$SHIM/loginctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in show-user*) printf 'Linger=yes\n' ;; esac
exit 0
STUB
cat >"$SHIM/tailscale" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"BackendState":"Running","CertDomains":["example.ts.net"],"Self":{"DNSName":"box.example.ts.net."},"Health":[]}\n'
  exit 0
fi
if [ "${1:-}" = serve ] && [ "${2:-}" = status ]; then
  if [ "${AIRLOCK_TEST_PLAINTEXT_STATEFUL:-0}" = 1 ] \
     && [ -s "$AIRLOCK_TEST_TMP/tailscale-plaintext.state" ]; then
    IFS=$'\t' read -r port target <"$AIRLOCK_TEST_TMP/tailscale-plaintext.state"
    printf '{"TCP":{"%s":{"HTTP":true,"Web":{"/":{"Proxy":"http://127.0.0.1:%s"}}}}}\n' \
      "$port" "$target"
    exit 0
  fi
  printf '{"TCP":{}}\n'
  exit 0
fi
printf '%s\n' "$*" >>"$AIRLOCK_TEST_TMP/tailscale.log"
if [ "${1:-}" = serve ] && [ "${2:-}" = --bg ]; then
  port="${3#--http=}"
  target="${4##*:}"
  if [ "${AIRLOCK_TEST_FAIL_PLAINTEXT:-}" = "$port" ]; then
    exit 42
  fi
  if [ "${AIRLOCK_TEST_PLAINTEXT_STATEFUL:-0}" = 1 ]; then
    printf '%s\t%s\n' "$port" "$target" \
      >"$AIRLOCK_TEST_TMP/tailscale-plaintext.state"
  fi
fi
exit 0
STUB
cat >"$SHIM/nginx" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$SHIM/systemd-run" <<'STUB'
#!/usr/bin/env bash
echo "FAIL unexpected self-kill escape in operator-surface fixture" >&2
exit 99
STUB
cat >"$SHIM/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${AIRLOCK_TEST_HTTP_CODE:-200}"
exit 0
STUB
chmod +x "$SHIM"/*
PATH="$SHIM:$PATH"; export PATH

# ---- fixture helpers --------------------------------------------------------
# Record explicit fixture sources through the production installed-record writer.
seed_apps() {
  env -u AIRLOCK_APP_ID -u AIRLOCK_APP_DIR python3 - "$ROOT/bin/airlock-ledger" "$@" <<'PY_SEED'
from importlib.machinery import SourceFileLoader
from pathlib import Path
import sys
sys.dont_write_bytecode = True
ledger = SourceFileLoader("_fixture_ledger", sys.argv[1]).load_module()
rows = ledger.load_installed()
for pid, directory in zip(sys.argv[2::2], sys.argv[3::2]):
    repo = str(Path(directory).resolve())
    if pid not in rows or rows[pid]["repo"] != repo:
        rows[pid] = {"repo": repo, "commit": "", "artifacts": []}
ledger.write_installed(rows)
PY_SEED
}

run() { AIRLOCK_CONFIG="$1" python3 "$CFG" "${@:2}"; }

orch() {
  local cfg="$1"; shift
  env HOME="$FAKEHOME" AIRLOCK_CONFIG="$cfg" \
      AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
      "$@" bash "$ROOT/install/airlock-install.sh"
}

write_config() {
  # write_config <file> <id> <package-dir> <abi:legacy|2|3> [grant TOML value]
  local path="$1" id="$2" package="$3" abi="$4" grant="${5-__absent__}"
  {
    if [ "$abi" != legacy ]; then
      printf '[airlock]\nconfig_version = %s\n' "$abi"
    fi
    printf '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n'
    printf '[apps.hub]\n[apps.%s]\n[packages.%s]\npath = "%s"\n' \
      "$id" "$id" "$package"
    [ "$grant" = __absent__ ] || printf 'grant = %s\n' "$grant"
  } >"$path"
}

make_plain_package() {
  local dir="$1" id="$2"
  mkdir -p "$dir"
  cat >"$dir/airlock-app.toml" <<EOF
contract = 1
id = "$id"
EOF
  cat >"$dir/install.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'install\n' >>"$AIRLOCK_TEST_MARKERS/$AIRLOCK_APP_ID"
[ "${AIRLOCK_TEST_FAIL_INSTALL:-}" != "$AIRLOCK_APP_ID" ]
STUB
  cat >"$dir/smoke.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'smoke\n' >>"$AIRLOCK_TEST_MARKERS/$AIRLOCK_APP_ID"
[ "${AIRLOCK_TEST_FAIL_SMOKE:-}" != "$AIRLOCK_APP_ID" ]
STUB
  cat >"$dir/deactivate.sh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$dir"/*.sh
  printf 'payload\n' >"$dir/payload.txt"
}

make_privileged_package() {
  local dir="$1" id="$2"
  make_plain_package "$dir" "$id"
  cat >>"$dir/airlock-app.toml" <<'EOF'
[artifacts]
units = [{name = "operator-surface.service", scope = "system"}]
rooted = ["${webroot_parent}/operator-surface-root/"]
EOF
}

failure_detail() { printf '%s\n' "$1" | sed 's/^/    /' | tail -n 8; }

# =============================================================================
# Config ABI
# =============================================================================
ABI="$TMP/abi"; mkdir -p "$ABI"
make_plain_package "$ABI/pkg" abipkg
write_config "$ABI/v2.toml" abipkg "$ABI/pkg" 2
seed_apps abipkg "$ABI/pkg"
out="$(run "$ABI/v2.toml" validate 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "ABI: [airlock] config_version = 2 is accepted"
else
  bad "ABI: [airlock] config_version = 2 is accepted (rc=$rc)"
  failure_detail "$out"
fi

reset_box
write_config "$ABI/legacy.toml" abipkg "$ABI/pkg" legacy
python3 - "$LEDGER" "$ABI/pkg" <<'PY_INSTALLED'
from importlib.machinery import SourceFileLoader
import sys
sys.dont_write_bytecode = True
ledger = SourceFileLoader("_operator_test_ledger", sys.argv[1]).load_module()
ledger.write_installed({"abipkg": {"repo": sys.argv[2], "commit": "", "artifacts": []}})
PY_INSTALLED
out="$(AIRLOCK_CONFIG="$ABI/legacy.toml" "$LEDGER" apply abipkg 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "ABI: a legacy-config app with a recorded local source remains reinstallable"
else
  bad "ABI: legacy config succeeds (rc=$rc)"
  failure_detail "$out"
fi

# =============================================================================
# Explicit-package grant admission
# =============================================================================
GRANT="$TMP/grants"; mkdir -p "$GRANT"
make_privileged_package "$GRANT/priv" grantpkg
make_plain_package "$GRANT/plain" grantpkg

write_config "$GRANT/valid.toml" grantpkg "$GRANT/priv" 2 \
  '["rooted-artifact", "system-unit"]'
seed_apps grantpkg "$GRANT/priv"
out="$(run "$GRANT/valid.toml" package-info 2>&1)" && rc=0 || rc=$?
valid_caps="$(printf '%s' "$out" | python3 -c '
import json, sys
try:
    print(json.dumps(json.load(sys.stdin)["packages"]["grantpkg"]["capabilities"]))
except Exception:
    pass
' 2>/dev/null)"
if [ "$rc" -eq 0 ] && [ "$valid_caps" = '["rooted-artifact", "system-unit"]' ]; then
  ok "grant: known requested grants reach the existing admission seam"
else
  bad "grant: valid rooted/system grants are admitted (rc=$rc caps=$valid_caps)"
  failure_detail "$out"
fi


if python3 - "$ROOT/SECURITY.md" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
paragraph = """An admitted package's `install.sh` runs arbitrary bash as the operator, including sudo (D4).
A package that is admitted at all can therefore edit config, write system files and bind
ports directly. **This contract is admission control, not containment.** It stops mistakes
and over-reach by honest packages and it leaves an auditable record of what was authorised.
It does not stop a malicious package."""
grant = """A grant is the operator acknowledging what a package will be allowed to do. It is not a
boundary against an actor who can already write this file."""
raise SystemExit(0 if paragraph in text and grant in text
                 and text.index(paragraph) < text.index("## Trust model") else 1)
PY
then
  ok "honesty: SECURITY.md states non-containment first and calls grants acknowledgement"
else
  bad "honesty: SECURITY.md must carry the verbatim limitation before its protection claims"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
