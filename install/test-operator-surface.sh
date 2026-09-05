#!/usr/bin/env bash
# Red-first contracts for OPERATOR_SURFACE: config ABI 2, explicit-package
# grants, and the repository-root digest lock.  This suite never touches the
# live checkout or services: it copies the checkout to a scratch repository,
# points every writable platform root at scratch, and PATH-shims all service
# commands.
set -uo pipefail
# Pin the RAM the paseo installer takes its memory share from (32GiB), so nothing in
# this suite depends on the RAM of whichever box runs it: the share is 15/16 of the
# box, so unpinned, every runner writes a different MemoryMax and the goldens bake in
# whichever the runner happened to have. install/test-render-parity.sh gates that every
# suite running a real app installer sets this — the gate does not reason about WHICH
# app a dynamic path resolves to, so suites that only run other apps carry it too; the
# seam is inert for them. (An intermediate design REFUSED below 8 GiB, which is what
# made this urgent. The refusal is gone — owner, 2026-08-17 — the pin is still right.)
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)" || { echo "FAIL could not create test directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

# A private checkout is necessary because airlock.lock deliberately belongs at
# the repository root.  Include uncommitted production edits while developing
# this red-first test, but never copy an existing lock or git administration.
ROOT="$TMP/repo"
mkdir -p "$ROOT"
if ! (cd "$SOURCE_ROOT" && tar --exclude='./.git' --exclude='./airlock.lock' -cf - .) \
     | (cd "$ROOT" && tar -xf -); then
  echo "FAIL could not create scratch repository" >&2
  exit 1
fi
CFG="$ROOT/bin/airlock-config"
LEDGER="$ROOT/bin/airlock-ledger"
LOCK="$ROOT/airlock.lock"

# ---- scratch platform roots -------------------------------------------------
STATE="$TMP/state"; WEB="$TMP/web"; CONFD="$TMP/confd"
UU="$TMP/units-user"; US="$TMP/units-system"
FAKEHOME="$TMP/home"; DATA="$TMP/data"; MARKERS="$TMP/markers"
export AIRLOCK_STATE_DIR="$STATE" AIRLOCK_WEBROOT="$WEB" AIRLOCK_CONFD="$CONFD"
export AIRLOCK_UNIT_DIR_USER="$UU" AIRLOCK_UNIT_DIR_SYSTEM="$US"
export AIRLOCK_TS_FQDN="box.example.ts.net"
export AIRLOCK_TEST_TMP="$TMP" AIRLOCK_TEST_MARKERS="$MARKERS"

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
cat >"$SHIM/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${AIRLOCK_TEST_HTTP_CODE:-200}"
exit 0
STUB
chmod +x "$SHIM"/*
PATH="$SHIM:$PATH"; export PATH

# ---- fixture helpers --------------------------------------------------------
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

tree_digest() {
  python3 - "$LEDGER" "$1" <<'PY'
import importlib.machinery
import importlib.util
import sys

loader = importlib.machinery.SourceFileLoader("operator_surface_ledger", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
print(module.digest_tree(sys.argv[2]))
PY
}

finalize_with_dir_fsync_failure() {
  # finalize_with_dir_fsync_failure <config> <directory-fsync occurrence>
  AIRLOCK_CONFIG="$1" python3 - "$CFG" "$2" <<'PY'
import importlib.machinery
import importlib.util
import os
import stat
import sys

loader = importlib.machinery.SourceFileLoader("operator_surface_config", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
original = module.os.fsync
fail_at = int(sys.argv[2])
directory_calls = 0

def injected(fd):
    global directory_calls
    if stat.S_ISDIR(os.fstat(fd).st_mode):
        directory_calls += 1
        if directory_calls == fail_at:
            raise OSError(f"injected directory fsync failure {fail_at}")
    return original(fd)

module.os.fsync = injected
module.cmd_lock_finalize(module.load())
PY
}

lock_digest() {
  python3 - "$1" "$2" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    lock = tomllib.load(handle)
print(lock[sys.argv[2]]["digest"])
PY
}

write_sentinel_lock() {
  cat >"$LOCK" <<'EOF'
[keep]
digest = "0000000000000000000000000000000000000000000000000000000000000000"
EOF
}

marker_has() {
  local id="$1" stage="$2"
  grep -Fxq "$stage" "$MARKERS/$id" 2>/dev/null
}

ledger_committed() {
  local id="$1"
  python3 - "$STATE/app-ledger.json" "$id" <<'PY' 2>/dev/null
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    entry = json.load(handle)["entries"].get(sys.argv[2]) or {}
raise SystemExit(0 if "committed" in entry else 1)
PY
}

ledger_has_override_event() {
  # ledger_has_override_event <id> <recorded digest> <admitted digest>
  python3 - "$STATE/app-ledger.json" "$1" "$2" "$3" <<'PY' 2>/dev/null
import json
import sys

path, package_id, recorded, admitted = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    store = json.load(handle)
expected_flag = f"--dangerously-admit-unverified={package_id}"
for event in store.get("events", []):
    if (event.get("type") == "package-lock-override"
            and event.get("package_id") == package_id
            and event.get("argument") == expected_flag
            and event.get("recorded_digest") == recorded
            and event.get("admitted_digest") == admitted):
        raise SystemExit(0)
raise SystemExit(1)
PY
}

failure_detail() { printf '%s\n' "$1" | sed 's/^/    /' | tail -n 8; }

assert_lock_schema_rejected() {
  # assert_lock_schema_rejected <label> <config> <required diagnostic fragment>
  local label="$1" cfg="$2" fragment="$3" out rc
  out="$(run "$cfg" validate 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ] && grep -Eq 'airlock\.lock|package lock' <<<"$out" \
     && grep -Eq "$fragment" <<<"$out"; then
    ok "lock schema: $label is fatal"
  else
    bad "lock schema: $label is fatal with an actionable diagnostic (rc=$rc)"
    failure_detail "$out"
  fi
}

# =============================================================================
# Config ABI
# =============================================================================
ABI="$TMP/abi"; mkdir -p "$ABI"
make_plain_package "$ABI/pkg" abipkg
write_config "$ABI/v2.toml" abipkg "$ABI/pkg" 2
out="$(run "$ABI/v2.toml" validate 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  ok "ABI: [airlock] config_version = 2 is accepted"
else
  bad "ABI: [airlock] config_version = 2 is accepted (rc=$rc)"
  failure_detail "$out"
fi

write_config "$ABI/v3.toml" abipkg "$ABI/pkg" 3
out="$(run "$ABI/v3.toml" validate 2>&1)" && rc=0 || rc=$?
future_msg='airlock-config: config version 3 is newer than this Airlock core supports (maximum 2); upgrade the Airlock core before using this config'
if [ "$rc" -eq 1 ] && [ "$out" = "$future_msg" ]; then
  ok "ABI: a future config gets the tailored upgrade-the-core message"
else
  bad "ABI: future-version message is exact (rc=$rc)"
  failure_detail "$out"
fi

# A grant is part of ABI 2, not a key a legacy file may acquire silently.
write_config "$ABI/legacy-grant.toml" abipkg "$ABI/pkg" legacy '[]'
out="$(run "$ABI/legacy-grant.toml" validate 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] \
   && grep -Fq "[packages.abipkg].grant requires [airlock] config_version = 2" <<<"$out"; then
  ok "ABI: grant is rejected without the ABI 2 marker"
else
  bad "ABI: legacy grant is rejected by its version class (rc=$rc)"
  failure_detail "$out"
fi

rm -f "$LOCK"
reset_box
write_config "$ABI/legacy.toml" abipkg "$ABI/pkg" legacy
out="$(orch "$ABI/legacy.toml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$LOCK" ]; then
  ok "ABI: a legacy explicit-package install keeps pre-lock behavior"
else
  bad "ABI: legacy config succeeds without creating ABI-2 lock state (rc=$rc)"
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

write_config "$GRANT/not-list.toml" grantpkg "$GRANT/priv" 2 '"system-unit"'
out="$(run "$GRANT/not-list.toml" package-info 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] \
   && grep -Fq "[packages.grantpkg].grant must be a list of unique strings" <<<"$out"; then
  ok "grant: a scalar is rejected by the shape class"
else
  bad "grant: scalar has the list-of-unique-strings diagnostic (rc=$rc)"
  failure_detail "$out"
fi

write_config "$GRANT/duplicate.toml" grantpkg "$GRANT/priv" 2 \
  '["system-unit", "system-unit"]'
out="$(run "$GRANT/duplicate.toml" package-info 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] \
   && grep -Fq "[packages.grantpkg].grant must be a list of unique strings" <<<"$out"; then
  ok "grant: duplicate values are rejected by the shape class"
else
  bad "grant: duplicate has the list-of-unique-strings diagnostic (rc=$rc)"
  failure_detail "$out"
fi

write_config "$GRANT/unknown.toml" grantpkg "$GRANT/priv" 2 '["teleport"]'
out="$(run "$GRANT/unknown.toml" package-info 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && grep -Fq "package 'grantpkg'" <<<"$out" \
   && grep -Fq "unknown capability grant(s): ['teleport']" <<<"$out"; then
  ok "grant: an unknown name is fatal in its own diagnostic class"
else
  bad "grant: unknown name has the unknown class and package name (rc=$rc)"
  failure_detail "$out"
fi

write_config "$GRANT/surface-name.toml" grantpkg "$GRANT/priv" 2 '["serve-port"]'
out="$(run "$GRANT/surface-name.toml" package-info 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && grep -Fq "package 'grantpkg'" <<<"$out" \
   && grep -Fq "unknown capability grant(s): ['serve-port']" <<<"$out"; then
  ok "grant: a surface classification is not accepted as a capability name"
else
  bad "grant: surface names stay outside the closed grant vocabulary (rc=$rc)"
  failure_detail "$out"
fi

write_config "$GRANT/non-grantable.toml" grantpkg "$GRANT/priv" 2 \
  '["plaintext-redirect"]'
out="$(run "$GRANT/non-grantable.toml" package-info 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && grep -Fq "package 'grantpkg'" <<<"$out" \
   && grep -Fq "non-grantable capability grant(s): ['plaintext-redirect']" <<<"$out"; then
  ok "grant: a known non-grantable name is a distinct fatal class"
else
  bad "grant: non-grantable name is distinct from unknown (rc=$rc)"
  failure_detail "$out"
fi

write_config "$GRANT/undeclared.toml" grantpkg "$GRANT/plain" 2 \
  '["rooted-artifact"]'
out="$(run "$GRANT/undeclared.toml" package-info 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && grep -Fq "package 'grantpkg'" <<<"$out" \
   && grep -Fq "capability grant(s) not requested by manifest: ['rooted-artifact']" <<<"$out"; then
  ok "grant: a stale grant the manifest did not request is fatal"
else
  bad "grant: undeclared grant names its class, package, and value (rc=$rc)"
  failure_detail "$out"
fi

write_config "$GRANT/missing.toml" grantpkg "$GRANT/priv" 2 \
  '["rooted-artifact"]'
out="$(run "$GRANT/missing.toml" package-info 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && grep -Fq "package 'grantpkg'" <<<"$out" \
   && grep -Fq "missing capability grant(s): ['system-unit']" <<<"$out"; then
  ok "grant: a requested capability absent from grant is fatal"
else
  bad "grant: missing grant names its class, package, and value (rc=$rc)"
  failure_detail "$out"
fi

# =============================================================================
# Digest lock placement, admission, recording, and whole-run atomicity
# =============================================================================
LOCK_CASE="$TMP/lock-case"; mkdir -p "$LOCK_CASE/config"
make_plain_package "$LOCK_CASE/pkg" lockpkg
write_config "$LOCK_CASE/config/airlock.toml" lockpkg "$LOCK_CASE/pkg" 2
rm -f "$LOCK" "$LOCK_CASE/config/airlock.lock"
reset_box

# Read-only commands must not create a trust-on-first-use record.  The positive
# validate witness is part of the assertion, so an early ABI failure cannot
# make the negative half pass vacuously.
out="$(run "$LOCK_CASE/config/airlock.toml" validate 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$LOCK" ] && [ ! -e "$LOCK_CASE/config/airlock.lock" ]; then
  ok "lock: successful read-only validation does not write first-use state"
else
  bad "lock: read-only non-write requires a successful validation witness (rc=$rc)"
  failure_detail "$out"
fi

out="$(orch "$LOCK_CASE/config/airlock.toml" AIRLOCK_DRY_RUN=1 2>&1)" \
  && dry_rc=0 || dry_rc=$?
if [ "$dry_rc" -eq 0 ] && [ ! -e "$LOCK" ]; then
  ok "lock: a successful dry run does not record first-use state"
else
  bad "lock: dry run stays read-only at the trust boundary (rc=$dry_rc)"
  failure_detail "$out"
fi

cat >"$LOCK_CASE/bundle.toml" <<'EOF'
[airlock]
config_version = 2
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.hub]
[apps.dev-monitor]
EOF
out="$(run "$LOCK_CASE/bundle.toml" lock-finalize 2>&1)" && bundle_rc=0 || bundle_rc=$?
if [ "$bundle_rc" -eq 0 ] && [ ! -e "$LOCK" ]; then
  ok "lock: canonical bundled packages never receive lock entries"
else
  bad "lock: bundle-only finalization leaves airlock.lock absent (rc=$bundle_rc)"
  failure_detail "$out"
fi

expected="$(tree_digest "$LOCK_CASE/pkg" 2>/dev/null || true)"
out="$(orch "$LOCK_CASE/config/airlock.toml" 2>&1)" && rc=0 || rc=$?
recorded="$(lock_digest "$LOCK" lockpkg 2>/dev/null || true)"
if [ "$rc" -eq 0 ] && [ "$recorded" = "$expected" ] \
   && [[ "$recorded" =~ ^[0-9a-f]{64}$ ]]; then
  ok "lock: a successful real orchestrator records the exact ledger digest"
else
  bad "lock: success records exact bare digest (rc=$rc expected=$expected recorded=$recorded)"
  failure_detail "$out"
fi

# AIRLOCK_CONFIG is outside the scratch repository.  A successful-run witness
# already exists above; assert that only the repository-root location is used.
if [ "$rc" -eq 0 ] && [ -f "$LOCK" ] \
   && [ ! -e "$LOCK_CASE/config/airlock.lock" ]; then
  ok "lock: AIRLOCK_CONFIG outside the repo still writes repo-root airlock.lock"
else
  bad "lock: location is repository-root, not config directory"
fi

cp "$LOCK" "$TMP/lock-before-rerun" 2>/dev/null || : >"$TMP/lock-before-rerun"
out="$(orch "$LOCK_CASE/config/airlock.toml" 2>&1)" && rerun_rc=0 || rerun_rc=$?
if [ "$rerun_rc" -eq 0 ] && cmp -s "$TMP/lock-before-rerun" "$LOCK"; then
  ok "lock: a matching rerun is byte-stable"
else
  bad "lock: matching rerun succeeds without rewriting bytes (rc=$rerun_rc)"
  failure_detail "$out"
fi

# Change the package only after a positive successful first use.  The mismatch
# must identify both values as bare digests and stop before lifecycle code.
recorded="$expected"
printf 'changed\n' >>"$LOCK_CASE/pkg/payload.txt"
computed="$(tree_digest "$LOCK_CASE/pkg" 2>/dev/null || true)"
: >"$MARKERS/lockpkg"
out="$(run "$LOCK_CASE/config/airlock.toml" validate 2>&1)" && mismatch_rc=0 || mismatch_rc=$?
if [ "$mismatch_rc" -ne 0 ] && [ "$recorded" != "$computed" ] \
   && [[ "$recorded" =~ ^[0-9a-f]{64}$ ]] && [[ "$computed" =~ ^[0-9a-f]{64}$ ]] \
   && grep -Fq "package 'lockpkg'" <<<"$out" \
   && grep -Fq "recorded digest: $recorded" <<<"$out" \
   && grep -Fq "computed digest: $computed" <<<"$out" \
   && grep -Fq "re-approval means deliberately updating" <<<"$out" \
   && grep -Fq "grant is a separate decision" <<<"$out" \
   && ! grep -Fq 'sha256:' <<<"$out" \
   && [ ! -s "$MARKERS/lockpkg" ]; then
  ok "lock: mismatch names package plus recorded/computed bare digests"
else
  bad "lock: mismatch diagnostic and pre-lifecycle stop are exact (rc=$mismatch_rc)"
  failure_detail "$out"
fi

# Each failure fixture starts with meaningful existing bytes.  The assertion
# couples byte preservation to a stage marker, preventing a false green when
# admission fails before the intended lifecycle edge.
FAILS="$TMP/failures"; mkdir -p "$FAILS"

reset_box; write_sentinel_lock
make_plain_package "$FAILS/install-pkg" installfail
write_config "$FAILS/install.toml" installfail "$FAILS/install-pkg" 2
cp "$LOCK" "$TMP/install-before"
out="$(orch "$FAILS/install.toml" AIRLOCK_TEST_FAIL_INSTALL=installfail 2>&1)" \
  && install_rc=0 || install_rc=$?
if [ "$install_rc" -ne 0 ] && marker_has installfail install \
   && ! marker_has installfail smoke && cmp -s "$TMP/install-before" "$LOCK"; then
  ok "lock: an observed install failure preserves prior bytes"
else
  bad "lock: install-failure preservation has a real install witness (rc=$install_rc)"
  failure_detail "$out"
fi

reset_box; write_sentinel_lock
make_plain_package "$FAILS/smoke-pkg" smokefail
write_config "$FAILS/smoke.toml" smokefail "$FAILS/smoke-pkg" 2
cp "$LOCK" "$TMP/smoke-before"
out="$(orch "$FAILS/smoke.toml" AIRLOCK_TEST_FAIL_SMOKE=smokefail 2>&1)" \
  && smoke_rc=0 || smoke_rc=$?
if [ "$smoke_rc" -ne 0 ] && marker_has smokefail install \
   && marker_has smokefail smoke && cmp -s "$TMP/smoke-before" "$LOCK"; then
  ok "lock: an observed smoke failure preserves prior bytes"
else
  bad "lock: smoke-failure preservation has install+smoke witnesses (rc=$smoke_rc)"
  failure_detail "$out"
fi

reset_box; write_sentinel_lock
make_plain_package "$FAILS/final-pkg" finalfail
write_config "$FAILS/final.toml" finalfail "$FAILS/final-pkg" 2
cp "$LOCK" "$TMP/final-before"
out="$(orch "$FAILS/final.toml" AIRLOCK_TEST_HTTP_CODE=500 2>&1)" \
  && final_rc=0 || final_rc=$?
if [ "$final_rc" -ne 0 ] && marker_has finalfail install \
   && marker_has finalfail smoke \
   && grep -Fq "serve frontend is not" <<<"$out" \
   && cmp -s "$TMP/final-before" "$LOCK"; then
  ok "lock: an observed final serve-check failure preserves prior bytes"
else
  bad "lock: final-check preservation has all earlier witnesses (rc=$final_rc)"
  failure_detail "$out"
fi

# Whole-run atomicity: B is allowed to commit to the ledger while A's smoke
# fails, but neither pending first-use digest may enter the lock in that run.
reset_box; write_sentinel_lock
MULTI="$TMP/multi"; mkdir -p "$MULTI"
make_plain_package "$MULTI/a" a-fail
make_plain_package "$MULTI/b" b-ok
cat >"$MULTI/airlock.toml" <<EOF
[airlock]
config_version = 2
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.hub]
[apps.a-fail]
[packages.a-fail]
path = "$MULTI/a"
[apps.b-ok]
[packages.b-ok]
path = "$MULTI/b"
EOF
cp "$LOCK" "$TMP/multi-before"
out="$(orch "$MULTI/airlock.toml" AIRLOCK_TEST_FAIL_SMOKE=a-fail 2>&1)" \
  && multi_rc=0 || multi_rc=$?
lock_mentions_new=0
if grep -Eq '^\[(a-fail|b-ok)\]$' "$LOCK" 2>/dev/null; then lock_mentions_new=1; fi
if [ "$multi_rc" -ne 0 ] \
   && marker_has a-fail install && marker_has a-fail smoke \
   && marker_has b-ok install && marker_has b-ok smoke \
   && ledger_committed b-ok && [ "$lock_mentions_new" -eq 0 ] \
   && cmp -s "$TMP/multi-before" "$LOCK"; then
  ok "lock: multi-package first use is whole-run atomic despite B ledger commit"
else
  bad "lock: multi-package atomicity has both lifecycle and B-commit witnesses (rc=$multi_rc)"
  failure_detail "$out"
fi

# The recovery run is the positive half of whole-run atomicity: once every
# lifecycle succeeds, both previously pending facts appear together and retain
# the unrelated entry.  Comparing to digest_tree prevents a merely nonempty
# or hand-derived lock from satisfying the test.
out="$(orch "$MULTI/airlock.toml" 2>&1)" && recovery_rc=0 || recovery_rc=$?
digest_a="$(tree_digest "$MULTI/a" 2>/dev/null || true)"
digest_b="$(tree_digest "$MULTI/b" 2>/dev/null || true)"
locked_a="$(lock_digest "$LOCK" a-fail 2>/dev/null || true)"
locked_b="$(lock_digest "$LOCK" b-ok 2>/dev/null || true)"
locked_keep="$(lock_digest "$LOCK" keep 2>/dev/null || true)"
if [ "$recovery_rc" -eq 0 ] \
   && [ "$locked_a" = "$digest_a" ] && [ "$locked_b" = "$digest_b" ] \
   && [ "$locked_keep" = 0000000000000000000000000000000000000000000000000000000000000000 ]; then
  ok "lock: the next whole-run success records all pending entries together"
else
  bad "lock: recovery records both exact digests and preserves stale entries (rc=$recovery_rc)"
  failure_detail "$out"
fi

# =============================================================================
# Digest lock parser and exact digest-tree semantics
# =============================================================================
STRICT="$TMP/strict-lock"; mkdir -p "$STRICT"
make_plain_package "$STRICT/pkg" strictpkg
write_config "$STRICT/airlock.toml" strictpkg "$STRICT/pkg" 2
rm -f "$LOCK"
out="$(run "$STRICT/airlock.toml" validate 2>&1)" && strict_witness_rc=0 || strict_witness_rc=$?
if [ "$strict_witness_rc" -eq 0 ]; then
  ok "lock schema: fixture is valid before malformed lock cases"
else
  bad "lock schema: positive config witness failed (rc=$strict_witness_rc)"
  failure_detail "$out"
fi

printf '[broken\n' >"$LOCK"
assert_lock_schema_rejected "malformed TOML" "$STRICT/airlock.toml" "parse|invalid TOML"

cat >"$LOCK" <<'EOF'
["Bad.ID"]
digest = "0000000000000000000000000000000000000000000000000000000000000000"
EOF
assert_lock_schema_rejected "invalid package id" "$STRICT/airlock.toml" "Bad.ID"

cat >"$LOCK" <<'EOF'
not-table = "0000000000000000000000000000000000000000000000000000000000000000"
EOF
assert_lock_schema_rejected "non-table package entry" "$STRICT/airlock.toml" "not-table"

cat >"$LOCK" <<'EOF'
[strictpkg]
digest = "0000000000000000000000000000000000000000000000000000000000000000"
extra = true
EOF
assert_lock_schema_rejected "unknown package field" "$STRICT/airlock.toml" "extra"

cat >"$LOCK" <<'EOF'
[strictpkg]
digest = 7
EOF
assert_lock_schema_rejected "non-string digest" "$STRICT/airlock.toml" "digest"

cat >"$LOCK" <<'EOF'
[strictpkg]
digest = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
EOF
assert_lock_schema_rejected "uppercase digest" "$STRICT/airlock.toml" "digest"

cat >"$LOCK" <<'EOF'
[strictpkg]
digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000"
EOF
assert_lock_schema_rejected "prefixed digest" "$STRICT/airlock.toml" "digest"

# The initial successful record contains all three easy-to-accidentally-exclude
# facts.  Each fact is then changed alone and must trip the normal lock
# mismatch.  Restoring it must recover the original digest, so a failure cannot
# be blamed on some unrelated package mutation.
SEM="$TMP/digest-semantics"; mkdir -p "$SEM/pkg/.git"
make_plain_package "$SEM/pkg" sempkg
printf 'ref: refs/heads/main\n' >"$SEM/pkg/.git/HEAD"
chmod 0600 "$SEM/pkg/payload.txt"
ln -s target-a "$SEM/pkg/link"
write_config "$SEM/airlock.toml" sempkg "$SEM/pkg" 2
rm -f "$LOCK"
reset_box
semantic_expected="$(tree_digest "$SEM/pkg" 2>/dev/null || true)"
out="$(orch "$SEM/airlock.toml" 2>&1)" && semantic_rc=0 || semantic_rc=$?
semantic_locked="$(lock_digest "$LOCK" sempkg 2>/dev/null || true)"
if [ "$semantic_rc" -eq 0 ] && [ "$semantic_locked" = "$semantic_expected" ]; then
  ok "digest semantics: recorded value exactly equals digest_tree with .git, mode, and symlink"
else
  bad "digest semantics: composite positive witness records digest_tree exactly (rc=$semantic_rc)"
  failure_detail "$out"
fi

printf 'ref: refs/heads/other\n' >"$SEM/pkg/.git/HEAD"
git_computed="$(tree_digest "$SEM/pkg" 2>/dev/null || true)"
out="$(run "$SEM/airlock.toml" validate 2>&1)" && git_rc=0 || git_rc=$?
printf 'ref: refs/heads/main\n' >"$SEM/pkg/.git/HEAD"
if [ "$git_rc" -ne 0 ] && [ "$git_computed" != "$semantic_locked" ] \
   && grep -Fq "computed digest: $git_computed" <<<"$out" \
   && [ "$(tree_digest "$SEM/pkg" 2>/dev/null || true)" = "$semantic_locked" ]; then
  ok "digest semantics: .git bytes participate in lock admission"
else
  bad "digest semantics: .git-only mutation must produce the named mismatch (rc=$git_rc)"
  failure_detail "$out"
fi

chmod 0644 "$SEM/pkg/payload.txt"
mode_computed="$(tree_digest "$SEM/pkg" 2>/dev/null || true)"
out="$(run "$SEM/airlock.toml" validate 2>&1)" && mode_rc=0 || mode_rc=$?
chmod 0600 "$SEM/pkg/payload.txt"
if [ "$mode_rc" -ne 0 ] && [ "$mode_computed" != "$semantic_locked" ] \
   && grep -Fq "computed digest: $mode_computed" <<<"$out" \
   && [ "$(tree_digest "$SEM/pkg" 2>/dev/null || true)" = "$semantic_locked" ]; then
  ok "digest semantics: permission bits participate in lock admission"
else
  bad "digest semantics: mode-only mutation must produce the named mismatch (rc=$mode_rc)"
  failure_detail "$out"
fi

rm "$SEM/pkg/link"; ln -s target-b "$SEM/pkg/link"
link_computed="$(tree_digest "$SEM/pkg" 2>/dev/null || true)"
out="$(run "$SEM/airlock.toml" validate 2>&1)" && link_rc=0 || link_rc=$?
rm "$SEM/pkg/link"; ln -s target-a "$SEM/pkg/link"
if [ "$link_rc" -ne 0 ] && [ "$link_computed" != "$semantic_locked" ] \
   && grep -Fq "computed digest: $link_computed" <<<"$out" \
   && [ "$(tree_digest "$SEM/pkg" 2>/dev/null || true)" = "$semantic_locked" ]; then
  ok "digest semantics: symlink target strings participate in lock admission"
else
  bad "digest semantics: symlink-target-only mutation must produce the named mismatch (rc=$link_rc)"
  failure_detail "$out"
fi

cp "$LOCK" "$TMP/special-before"
mkfifo "$SEM/pkg/forbidden.fifo"
out_digest="$(tree_digest "$SEM/pkg" 2>&1)" && special_digest_rc=0 || special_digest_rc=$?
out="$(run "$SEM/airlock.toml" validate 2>&1)" && special_admit_rc=0 || special_admit_rc=$?
rm "$SEM/pkg/forbidden.fifo"
if [ "$special_digest_rc" -ne 0 ] && [ "$special_admit_rc" -ne 0 ] \
   && grep -Fq 'special file is not allowed in package tree' <<<"$out_digest" \
   && grep -Fq 'special file' <<<"$out" && cmp -s "$TMP/special-before" "$LOCK"; then
  ok "digest semantics: special files are fatal and preserve prior lock bytes"
else
  bad "digest semantics: special-file failure must be shared by digest and admission"
  failure_detail "$out_digest"
  failure_detail "$out"
fi

# A package rooted at the repository would digest airlock.lock itself.  It must
# be rejected as a staging error, not admitted into a lock that invalidates
# itself immediately after replacement.
SELF="$TMP/self-reference"; mkdir -p "$SELF"
make_plain_package "$ROOT" rootpkg
write_config "$SELF/airlock.toml" rootpkg "$ROOT" 2
write_sentinel_lock
cp "$LOCK" "$TMP/self-before"
out="$(run "$SELF/airlock.toml" validate 2>&1)" && self_rc=0 || self_rc=$?
if [ "$self_rc" -ne 0 ] && grep -Fq "package 'rootpkg'" <<<"$out" \
   && grep -Fq 'airlock.lock' <<<"$out" \
   && grep -Eq 'stag|self|repository lock' <<<"$out" \
   && cmp -s "$TMP/self-before" "$LOCK"; then
  ok "lock: an explicit tree containing repository airlock.lock is a staging error"
else
  bad "lock: self-reference is fatal, actionable, and byte-preserving (rc=$self_rc)"
  failure_detail "$out"
fi
rm -f "$ROOT/airlock-app.toml" "$ROOT/install.sh" "$ROOT/smoke.sh" \
      "$ROOT/deactivate.sh" "$ROOT/payload.txt"

# Two finalizers deliberately have disjoint HOME/state roots and configs, so
# only the shared repository-directory inode can serialize their read/merge/
# replace transaction.  Large payloads widen the overlap without relying on a
# production test hook.
RACE="$TMP/lock-race"; mkdir -p "$RACE/a" "$RACE/b" "$RACE/home-a" "$RACE/home-b" \
  "$RACE/state-a" "$RACE/state-b"
make_plain_package "$RACE/a" race-a
make_plain_package "$RACE/b" race-b
dd if=/dev/zero of="$RACE/a/large.bin" bs=1M count=12 status=none
dd if=/dev/zero of="$RACE/b/large.bin" bs=1M count=12 status=none
write_config "$RACE/a.toml" race-a "$RACE/a" 2
write_config "$RACE/b.toml" race-b "$RACE/b" 2
rm -f "$LOCK"
env HOME="$RACE/home-a" AIRLOCK_STATE_DIR="$RACE/state-a" \
  AIRLOCK_CONFIG="$RACE/a.toml" python3 "$CFG" lock-finalize \
  >"$RACE/a.out" 2>&1 & race_pid_a=$!
env HOME="$RACE/home-b" AIRLOCK_STATE_DIR="$RACE/state-b" \
  AIRLOCK_CONFIG="$RACE/b.toml" python3 "$CFG" lock-finalize \
  >"$RACE/b.out" 2>&1 & race_pid_b=$!
wait "$race_pid_a"; race_rc_a=$?
wait "$race_pid_b"; race_rc_b=$?
race_digest_a="$(tree_digest "$RACE/a" 2>/dev/null || true)"
race_digest_b="$(tree_digest "$RACE/b" 2>/dev/null || true)"
race_locked_a="$(lock_digest "$LOCK" race-a 2>/dev/null || true)"
race_locked_b="$(lock_digest "$LOCK" race-b 2>/dev/null || true)"
if [ "$race_rc_a" -eq 0 ] && [ "$race_rc_b" -eq 0 ] \
   && [ "$race_locked_a" = "$race_digest_a" ] \
   && [ "$race_locked_b" = "$race_digest_b" ]; then
  ok "lock: distinct HOME/state writers serialize without losing either entry"
else
  bad "lock: concurrent finalizers merge both exact entries (rc_a=$race_rc_a rc_b=$race_rc_b)"
  failure_detail "$(cat "$RACE/a.out")"
  failure_detail "$(cat "$RACE/b.out")"
fi

cp "$LOCK" "$TMP/race-before-rerun" 2>/dev/null || : >"$TMP/race-before-rerun"
env HOME="$RACE/home-a" AIRLOCK_STATE_DIR="$RACE/state-a" \
  AIRLOCK_CONFIG="$RACE/a.toml" python3 "$CFG" lock-finalize \
  >"$RACE/a-rerun.out" 2>&1 & race_pid_a=$!
env HOME="$RACE/home-b" AIRLOCK_STATE_DIR="$RACE/state-b" \
  AIRLOCK_CONFIG="$RACE/b.toml" python3 "$CFG" lock-finalize \
  >"$RACE/b-rerun.out" 2>&1 & race_pid_b=$!
wait "$race_pid_a"; race_rerun_rc_a=$?
wait "$race_pid_b"; race_rerun_rc_b=$?
if [ "$race_rerun_rc_a" -eq 0 ] && [ "$race_rerun_rc_b" -eq 0 ] \
   && cmp -s "$TMP/race-before-rerun" "$LOCK"; then
  ok "lock: serialized matching writers are byte-stable"
else
  bad "lock: concurrent matching rerun is a byte-stable no-op (rc_a=$race_rerun_rc_a rc_b=$race_rerun_rc_b)"
  failure_detail "$(cat "$RACE/a-rerun.out")"
  failure_detail "$(cat "$RACE/b-rerun.out")"
fi

# Force the real repository-root write path to fail without adding a public
# production test hook.  The pending package and successful validate witness
# prove lock-finalize had work to do; the old bytes must survive exactly.
ATOMIC="$TMP/atomic-failure"; mkdir -p "$ATOMIC/pkg"
make_plain_package "$ATOMIC/pkg" atomicpkg
write_config "$ATOMIC/airlock.toml" atomicpkg "$ATOMIC/pkg" 2
write_sentinel_lock
out="$(run "$ATOMIC/airlock.toml" validate 2>&1)" && atomic_witness_rc=0 || atomic_witness_rc=$?
cp "$LOCK" "$TMP/atomic-before"
root_mode="$(stat -c %a "$ROOT")"
chmod 0555 "$ROOT"
out="$(AIRLOCK_CONFIG="$ATOMIC/airlock.toml" python3 "$CFG" lock-finalize 2>&1)" \
  && atomic_rc=0 || atomic_rc=$?
chmod "$root_mode" "$ROOT"
atomic_recorded="$(lock_digest "$LOCK" atomicpkg 2>/dev/null || true)"
if [ "$atomic_witness_rc" -eq 0 ] && [ "$atomic_rc" -ne 0 ] \
   && grep -Eq 'airlock.lock|Permission denied|permission denied' <<<"$out" \
   && [ -z "$atomic_recorded" ] && cmp -s "$TMP/atomic-before" "$LOCK"; then
  ok "lock: repository replacement failure preserves prior bytes"
else
  bad "lock: a witnessed pending write fails atomically without changing bytes (rc=$atomic_rc)"
  failure_detail "$out"
fi


# A directory durability failure before os.replace is still reversible and
# therefore fatal with exact old bytes. A failure after os.replace has crossed
# the commit point: it must be a loud success, not a false failed-run report
# that leaves changed bytes behind.
FSYNC="$TMP/fsync-boundary"; mkdir -p "$FSYNC/pkg"
make_plain_package "$FSYNC/pkg" fsyncpkg
write_config "$FSYNC/airlock.toml" fsyncpkg "$FSYNC/pkg" 2
write_sentinel_lock
cp "$LOCK" "$TMP/fsync-before"
out="$(finalize_with_dir_fsync_failure "$FSYNC/airlock.toml" 1 2>&1)" \
  && fsync_pre_rc=0 || fsync_pre_rc=$?
temp_count="$(find "$ROOT" -maxdepth 1 -name '.airlock.lock.*' -print | wc -l)"
if [ "$fsync_pre_rc" -ne 0 ] && grep -Fq 'injected directory fsync failure 1' <<<"$out" \
   && cmp -s "$TMP/fsync-before" "$LOCK" && [ "$temp_count" -eq 0 ]; then
  ok "lock: pre-replace directory sync failure is fatal and byte-preserving"
else
  bad "lock: pre-commit directory sync failure preserves bytes and temp hygiene (rc=$fsync_pre_rc)"
  failure_detail "$out"
fi

write_sentinel_lock
out="$(finalize_with_dir_fsync_failure "$FSYNC/airlock.toml" 2 2>&1)" \
  && fsync_post_rc=0 || fsync_post_rc=$?
fsync_expected="$(tree_digest "$FSYNC/pkg" 2>/dev/null || true)"
fsync_recorded="$(lock_digest "$LOCK" fsyncpkg 2>/dev/null || true)"
if [ "$fsync_post_rc" -eq 0 ] && [ "$fsync_recorded" = "$fsync_expected" ] \
   && grep -Fq 'directory sync could not be confirmed' <<<"$out" \
   && grep -Fq 'treating the replacement as committed' <<<"$out"; then
  ok "lock: post-replace directory sync failure is a loud committed success"
else
  bad "lock: post-commit sync failure never reports a false failed run (rc=$fsync_post_rc)"
  failure_detail "$out"
fi

# =============================================================================
# HONESTY: explicit, package-scoped, auditable break-glass admission
# =============================================================================
HONESTY="$TMP/honesty"; mkdir -p "$HONESTY/pkg"
make_plain_package "$HONESTY/pkg" honestpkg
cat >"$HONESTY/pkg/install.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 0 ] || { printf 'unexpected lifecycle argv: %s\n' "$*" >&2; exit 44; }
. "$AIRLOCK_ROOT/install/lib.sh"
airlock_config get auth.owner >/dev/null
printf 'install\n' >>"$AIRLOCK_TEST_MARKERS/$AIRLOCK_APP_ID"
[ "${AIRLOCK_TEST_FAIL_INSTALL:-}" != "$AIRLOCK_APP_ID" ]
STUB
cat >"$HONESTY/pkg/smoke.sh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[ "$#" -eq 0 ] || { printf 'unexpected lifecycle argv: %s\n' "$*" >&2; exit 44; }
. "$AIRLOCK_ROOT/install/lib.sh"
airlock_config get auth.owner >/dev/null || exit 1
printf 'smoke\n' >>"$AIRLOCK_TEST_MARKERS/$AIRLOCK_APP_ID"
[ "${AIRLOCK_TEST_FAIL_SMOKE:-}" != "$AIRLOCK_APP_ID" ]
STUB
chmod +x "$HONESTY/pkg/install.sh" "$HONESTY/pkg/smoke.sh"
write_config "$HONESTY/airlock.toml" honestpkg "$HONESTY/pkg" 2
rm -f "$LOCK"
reset_box

# Establish a real recorded digest before creating the mismatch.  This witness
# prevents every override assertion below from passing on a missing-lock TOFU
# path rather than the exceptional path it is meant to pin.
out="$(orch "$HONESTY/airlock.toml" 2>&1)" && honesty_base_rc=0 || honesty_base_rc=$?
honesty_recorded="$(lock_digest "$LOCK" honestpkg 2>/dev/null || true)"
printf 'honesty-change\n' >>"$HONESTY/pkg/payload.txt"
honesty_admitted="$(tree_digest "$HONESTY/pkg" 2>/dev/null || true)"
cp "$LOCK" "$TMP/honesty-before-override"
reset_box

out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$HONESTY/airlock.toml" \
  AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
  bash "$ROOT/install/airlock-install.sh" \
  --dangerously-admit-unverified=honestpkg 2>&1)" \
  && honesty_override_rc=0 || honesty_override_rc=$?
honesty_locked="$(lock_digest "$LOCK" honestpkg 2>/dev/null || true)"
if [ "$honesty_base_rc" -eq 0 ] && [ "$honesty_recorded" != "$honesty_admitted" ] \
   && [ "$honesty_override_rc" -eq 0 ] \
   && marker_has honestpkg install && marker_has honestpkg smoke \
   && [ "$honesty_locked" = "$honesty_admitted" ] \
   && grep -Fq 'DANGEROUS: admitting unverified package lock mismatch' <<<"$out" \
   && grep -Fq -- '--dangerously-admit-unverified=honestpkg' <<<"$out" \
   && grep -Fq "recorded digest: $honesty_recorded" <<<"$out" \
   && grep -Fq "admitted digest: $honesty_admitted" <<<"$out"; then
  ok "honesty: exact package-scoped flag is loud and updates the lock after success"
else
  bad "honesty: exact flag admits lifecycle and atomically re-locks only after success (rc=$honesty_override_rc)"
  failure_detail "$out"
fi

honesty_success_event_count="$(python3 - "$STATE/app-ledger.json" <<'PY' 2>/dev/null
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(len(json.load(handle).get("events", [])))
PY
)"
if [ "$honesty_override_rc" -eq 0 ] && [ "$honesty_success_event_count" = 1 ] \
   && ledger_has_override_event honestpkg "$honesty_recorded" "$honesty_admitted"; then
  ok "honesty: one use appends exactly one ledger event with package, argument, and both digests"
else
  bad "honesty: successful override is exactly once and independently visible in the ledger"
fi

# Audit history is not package state.  Removing the package entry and then
# reinstalling it normally must preserve the exceptional event unchanged.
honesty_event_count_before="$(python3 - "$STATE/app-ledger.json" <<'PY' 2>/dev/null
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(len(json.load(handle).get("events", [])))
PY
)"
normal_info="$(run "$HONESTY/airlock.toml" package-info 2>/dev/null || true)"
printf '%s' "$normal_info" | "$LEDGER" teardown honestpkg >/dev/null 2>&1 \
  && honesty_teardown_rc=0 || honesty_teardown_rc=$?
out="$(orch "$HONESTY/airlock.toml" 2>&1)" && honesty_reinstall_rc=0 || honesty_reinstall_rc=$?
honesty_event_count_after="$(python3 - "$STATE/app-ledger.json" <<'PY' 2>/dev/null
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(len(json.load(handle).get("events", [])))
PY
)"
if [ "$honesty_teardown_rc" -eq 0 ] && [ "$honesty_reinstall_rc" -eq 0 ] \
   && [ "$honesty_event_count_before" = "$honesty_event_count_after" ] \
   && ledger_has_override_event honestpkg "$honesty_recorded" "$honesty_admitted"; then
  ok "honesty: teardown and normal reinstall preserve append-only override history"
else
  bad "honesty: package entry lifecycle cannot erase override events (teardown=$honesty_teardown_rc reinstall=$honesty_reinstall_rc)"
fi

# A later lifecycle failure still records that unverified bytes reached the
# intent boundary, but it must not move the repository lock.  That separates
# the append-only audit fact from the whole-run-success lock commit point.
printf 'honesty-second-change\n' >>"$HONESTY/pkg/payload.txt"
honesty_failed_admitted="$(tree_digest "$HONESTY/pkg" 2>/dev/null || true)"
cp "$LOCK" "$TMP/honesty-before-failed-run"
reset_box
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$HONESTY/airlock.toml" \
  AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" AIRLOCK_TEST_FAIL_SMOKE=honestpkg \
  bash "$ROOT/install/airlock-install.sh" \
  --dangerously-admit-unverified=honestpkg 2>&1)" \
  && honesty_fail_rc=0 || honesty_fail_rc=$?
if [ "$honesty_fail_rc" -ne 0 ] \
   && marker_has honestpkg install && marker_has honestpkg smoke \
   && cmp -s "$TMP/honesty-before-failed-run" "$LOCK" \
   && ledger_has_override_event honestpkg "$honesty_admitted" "$honesty_failed_admitted"; then
  ok "honesty: failed lifecycle preserves lock bytes but retains the override audit event"
else
  bad "honesty: failed override run is byte-preserving and auditable (rc=$honesty_fail_rc)"
  failure_detail "$out"
fi

# Historical audit rows are facts, not reusable authorization. In particular,
# an event left by the failed smoke above cannot be replayed by invoking the
# internal finalizer directly without this orchestrator run's secret receipt.
cp "$LOCK" "$TMP/honesty-before-replay"
out="$(AIRLOCK_CONFIG="$HONESTY/airlock.toml" \
  python3 "$CFG" --dangerously-admit-unverified=honestpkg lock-finalize 2>&1)" \
  && honesty_replay_rc=0 || honesty_replay_rc=$?
if [ "$honesty_replay_rc" -ne 0 ] \
   && grep -Eq 'current-run break-glass receipt is required|break-glass lock-finalize requires its current-run receipt' <<<"$out" \
   && cmp -s "$TMP/honesty-before-replay" "$LOCK"; then
  ok "honesty: a failed run's historical audit event cannot be replayed into the lock"
else
  bad "honesty: finalization requires a current-run audit receipt (rc=$honesty_replay_rc)"
  failure_detail "$out"
fi

if python3 - "$CFG" <<'PY'
import importlib.machinery
import importlib.util
import sys

loader = importlib.machinery.SourceFileLoader("honesty_config_state", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
module._parse_global_args(["--dangerously-admit-unverified=honestpkg", "validate"])
module._parse_global_args(["validate"])
raise SystemExit(0 if module._DANGEROUS_ADMIT_UNVERIFIED is None else 1)
PY
then
  ok "honesty: exceptional argv state cannot leak into a later same-process call"
else
  bad "honesty: parser resets exceptional state for every invocation"
fi

# The rejected environment-variable shape must never become an alternate
# public contract.  Even a value naming the mismatched package changes
# nothing: default admission remains fatal before lifecycle execution.
reset_box
: >"$MARKERS/honestpkg"
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$HONESTY/airlock.toml" \
  AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
  AIRLOCK_ADMIT_UNVERIFIED=honestpkg \
  bash "$ROOT/install/airlock-install.sh" 2>&1)" \
  && honesty_env_rc=0 || honesty_env_rc=$?
if [ "$honesty_env_rc" -ne 0 ] && grep -Fq "package 'honestpkg'" <<<"$out" \
   && grep -Fq 'package lock digest mismatch' <<<"$out" \
   && [ ! -s "$MARKERS/honestpkg" ]; then
  ok "honesty: an environment variable cannot activate break-glass admission"
else
  bad "honesty: rejected environment-variable shape has no effect (rc=$honesty_env_rc)"
  failure_detail "$out"
fi

# The private lifecycle wrapper path is not caller authority. The orchestrator
# must replace an ambient AIRLOCK_CONFIG_BIN before its first package-info read,
# otherwise a caller could smuggle the rejected selector through another env
# name and reach mutation without an audit event.
cat >"$TMP/ambient-config-wrapper.py" <<PY
import os
import sys
os.execv(sys.executable, [sys.executable, "$CFG",
    "--dangerously-admit-unverified=honestpkg", *sys.argv[1:]])
PY
reset_box
: >"$MARKERS/honestpkg"
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$HONESTY/airlock.toml" \
  AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
  AIRLOCK_CONFIG_BIN="$TMP/ambient-config-wrapper.py" \
  bash "$ROOT/install/airlock-install.sh" 2>&1)" \
  && honesty_ambient_bin_rc=0 || honesty_ambient_bin_rc=$?
if [ "$honesty_ambient_bin_rc" -ne 0 ] \
   && grep -Fq 'package lock digest mismatch' <<<"$out" \
   && [ ! -s "$MARKERS/honestpkg" ]; then
  ok "honesty: an ambient config wrapper cannot activate break-glass admission"
else
  bad "honesty: orchestrator pins its config reader before admission (rc=$honesty_ambient_bin_rc)"
  failure_detail "$out"
fi

# Cached/forged package-info is not authority either.  The orchestrator must
# re-read the config and lock from bytes before touching lifecycle code.
reset_box
: >"$MARKERS/honestpkg"
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$HONESTY/airlock.toml" \
  AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
  AIRLOCK_PKG_INFO='{"config_path":"forged","order":[],"packages":{}}' \
  bash "$ROOT/install/airlock-install.sh" 2>&1)" \
  && honesty_forged_rc=0 || honesty_forged_rc=$?
if [ "$honesty_forged_rc" -ne 0 ] \
   && grep -Fq 'package lock digest mismatch' <<<"$out" \
   && [ ! -s "$MARKERS/honestpkg" ]; then
  ok "honesty: forged or stale package-info cannot activate the escape hatch"
else
  bad "honesty: only exact argv can authorize a mismatch (rc=$honesty_forged_rc)"
  failure_detail "$out"
fi

# The argument is not a boolean.  Omitting '=package-id' must fail in the
# command parser, not fall through to the ordinary mismatch diagnostic.
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$HONESTY/airlock.toml" \
  AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
  bash "$ROOT/install/airlock-install.sh" \
  --dangerously-admit-unverified 2>&1)" \
  && honesty_bare_rc=0 || honesty_bare_rc=$?
if [ "$honesty_bare_rc" -ne 0 ] \
   && grep -Fq 'requires =<package-id>' <<<"$out"; then
  ok "honesty: the bare flag is rejected as missing its package selector"
else
  bad "honesty: the bare flag gets a package-selector diagnostic (rc=$honesty_bare_rc)"
  failure_detail "$out"
fi

for bad_args in \
  '--dangerously-admit-unverified=' \
  '--dangerously-admit-unverified=honestpkg --dangerously-admit-unverified=honestpkg' \
  '--ordinary-retry'; do
  # Intentional splitting: each row above is an argv vector, not one string.
  read -r -a parsed_args <<<"$bad_args"
  out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$HONESTY/airlock.toml" \
    AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
    bash "$ROOT/install/airlock-install.sh" "${parsed_args[@]}" 2>&1)" \
    && invalid_arg_rc=0 || invalid_arg_rc=$?
  if [ "$invalid_arg_rc" -ne 0 ] \
     && grep -Eq 'valid package id|accepted only once|unknown installer argument' <<<"$out"; then
    ok "honesty: invalid argv shape is rejected ($bad_args)"
  else
    bad "honesty: only one exact =package-id argument is accepted ($bad_args rc=$invalid_arg_rc)"
    failure_detail "$out"
  fi
done

# Naming a package outside the configured explicit-package set cannot create a
# global bypass or silently fall back to the first mismatch.
reset_box
: >"$MARKERS/honestpkg"
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$HONESTY/airlock.toml" \
  AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
  bash "$ROOT/install/airlock-install.sh" \
  --dangerously-admit-unverified=absentpkg 2>&1)" \
  && honesty_absent_rc=0 || honesty_absent_rc=$?
if [ "$honesty_absent_rc" -ne 0 ] \
   && grep -Fq "'absentpkg' does not name a configured explicit package" <<<"$out" \
   && [ ! -s "$MARKERS/honestpkg" ]; then
  ok "honesty: an absent selector is fatal before any package lifecycle"
else
  bad "honesty: selector must name a configured explicit package (rc=$honesty_absent_rc)"
  failure_detail "$out"
fi

# A matching or not-yet-recorded package does not need break glass.  Refusing
# both keeps the exceptional spelling from becoming a habitual install flag.
MATCHING="$TMP/honesty-matching"; mkdir -p "$MATCHING/pkg"
make_plain_package "$MATCHING/pkg" matchingpkg
write_config "$MATCHING/airlock.toml" matchingpkg "$MATCHING/pkg" 2
rm -f "$LOCK"
reset_box
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$MATCHING/airlock.toml" \
  AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
  bash "$ROOT/install/airlock-install.sh" \
  --dangerously-admit-unverified=matchingpkg 2>&1)" \
  && missing_target_rc=0 || missing_target_rc=$?
if [ "$missing_target_rc" -ne 0 ] && grep -Fq 'has no recorded lock digest' <<<"$out"; then
  ok "honesty: first use cannot normalize the break-glass flag"
else
  bad "honesty: a missing lock entry rejects break-glass (rc=$missing_target_rc)"
  failure_detail "$out"
fi
out="$(orch "$MATCHING/airlock.toml" 2>&1)" && matching_base_rc=0 || matching_base_rc=$?
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$MATCHING/airlock.toml" \
  AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
  bash "$ROOT/install/airlock-install.sh" \
  --dangerously-admit-unverified=matchingpkg 2>&1)" \
  && matching_target_rc=0 || matching_target_rc=$?
if [ "$matching_base_rc" -eq 0 ] && [ "$matching_target_rc" -ne 0 ] \
   && grep -Fq 'already matches its recorded lock digest' <<<"$out"; then
  ok "honesty: a matching lock rejects unnecessary break-glass use"
else
  bad "honesty: matching packages do not accept exceptional argv (rc=$matching_target_rc)"
  failure_detail "$out"
fi

write_config "$MATCHING/legacy.toml" matchingpkg "$MATCHING/pkg" legacy
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$MATCHING/legacy.toml" \
  AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
  bash "$ROOT/install/airlock-install.sh" \
  --dangerously-admit-unverified=matchingpkg 2>&1)" \
  && legacy_override_rc=0 || legacy_override_rc=$?
if [ "$legacy_override_rc" -ne 0 ] \
   && grep -Fq 'requires [airlock] config_version = 2' <<<"$out"; then
  ok "honesty: legacy ABI cannot enter the lock escape hatch"
else
  bad "honesty: break-glass belongs only to ABI 2 lock admission (rc=$legacy_override_rc)"
  failure_detail "$out"
fi

# Dry runs never execute an explicit lifecycle or mutate audit/lock state, but
# the exceptional selection remains visible in their log.
rm -rf "$STATE"
cp "$TMP/honesty-before-failed-run" "$LOCK"
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$HONESTY/airlock.toml" \
  AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" AIRLOCK_DRY_RUN=1 \
  bash "$ROOT/install/airlock-install.sh" \
  --dangerously-admit-unverified=honestpkg 2>&1)" \
  && honesty_dry_rc=0 || honesty_dry_rc=$?
if [ "$honesty_dry_rc" -eq 0 ] && [ ! -e "$STATE/app-ledger.json" ] \
   && cmp -s "$TMP/honesty-before-failed-run" "$LOCK" \
   && grep -Fq '[dry] DANGEROUS:' <<<"$out"; then
  ok "honesty: dry break-glass is loud but writes no audit or lock state"
else
  bad "honesty: dry run remains non-mutating at both state boundaries (rc=$honesty_dry_rc)"
  failure_detail "$out"
fi

# One selected mismatch does not weaken a sibling.  Both packages start from
# valid recorded entries and are then changed; admission must pass A only far
# enough to name B as the remaining fatal mismatch, before either installer.
SCOPED="$TMP/honesty-scoped"; mkdir -p "$SCOPED/a" "$SCOPED/b"
make_plain_package "$SCOPED/a" honesty-a
make_plain_package "$SCOPED/b" honesty-b
cat >"$SCOPED/airlock.toml" <<EOF
[airlock]
config_version = 2
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.hub]
[apps.honesty-a]
[packages.honesty-a]
path = "$SCOPED/a"
[apps.honesty-b]
[packages.honesty-b]
path = "$SCOPED/b"
EOF
rm -f "$LOCK"
reset_box
out="$(orch "$SCOPED/airlock.toml" 2>&1)" && scoped_base_rc=0 || scoped_base_rc=$?
printf 'changed-a\n' >>"$SCOPED/a/payload.txt"
printf 'changed-b\n' >>"$SCOPED/b/payload.txt"
reset_box
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$SCOPED/airlock.toml" \
  AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
  bash "$ROOT/install/airlock-install.sh" \
  --dangerously-admit-unverified=honesty-a 2>&1)" \
  && scoped_rc=0 || scoped_rc=$?
if [ "$scoped_base_rc" -eq 0 ] && [ "$scoped_rc" -ne 0 ] \
   && grep -Fq "package 'honesty-b': package lock digest mismatch" <<<"$out" \
   && ! marker_has honesty-a install && ! marker_has honesty-b install; then
  ok "honesty: selecting package A leaves package B's mismatch fatal"
else
  bad "honesty: the flag cannot disable sibling package lock gates (rc=$scoped_rc)"
  failure_detail "$out"
fi

# Finalization is a compare-and-swap against the exact pair audited before
# mutation.  A concurrent/inside-lifecycle third lock value must survive and
# make the run fail rather than being overwritten by the selected package.
CAS="$TMP/honesty-cas"; mkdir -p "$CAS/pkg"
make_plain_package "$CAS/pkg" caspkg
cat >"$CAS/pkg/install.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
. "$AIRLOCK_ROOT/install/lib.sh"
airlock_config get auth.owner >/dev/null
if [ "${AIRLOCK_TEST_WRITE_THIRD_LOCK:-0}" = 1 ]; then
  cat >"$AIRLOCK_ROOT/airlock.lock" <<'EOF'
[caspkg]
digest = "3333333333333333333333333333333333333333333333333333333333333333"
EOF
fi
if [ "${AIRLOCK_TEST_MUTATE_PACKAGE:-0}" = 1 ]; then
  printf 'post-admission mutation\n' >>"$AIRLOCK_APP_DIR/payload.txt"
fi
printf 'install\n' >>"$AIRLOCK_TEST_MARKERS/$AIRLOCK_APP_ID"
STUB
chmod +x "$CAS/pkg/install.sh"
write_config "$CAS/airlock.toml" caspkg "$CAS/pkg" 2
rm -f "$LOCK"
reset_box
out="$(orch "$CAS/airlock.toml" 2>&1)" && cas_base_rc=0 || cas_base_rc=$?
printf 'approved-change\n' >>"$CAS/pkg/payload.txt"
reset_box
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$CAS/airlock.toml" \
  AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" AIRLOCK_TEST_WRITE_THIRD_LOCK=1 \
  bash "$ROOT/install/airlock-install.sh" \
  --dangerously-admit-unverified=caspkg 2>&1)" \
  && cas_third_rc=0 || cas_third_rc=$?
cas_third_locked="$(lock_digest "$LOCK" caspkg 2>/dev/null || true)"
if [ "$cas_base_rc" -eq 0 ] && [ "$cas_third_rc" -ne 0 ] \
   && [ "$cas_third_locked" = 3333333333333333333333333333333333333333333333333333333333333333 ] \
   && grep -Fq 'package lock changed after break-glass admission' <<<"$out" \
   && grep -Fq 'preserving current lock bytes' <<<"$out"; then
  ok "honesty: finalization CAS preserves a concurrent third lock value"
else
  bad "honesty: break-glass cannot overwrite a post-admission lock value (rc=$cas_third_rc locked=$cas_third_locked)"
  failure_detail "$out"
fi

# Restore the original admitted lock, create a fresh mismatch, then let the
# lifecycle mutate its own tree.  Finalization must not pin bytes that differ
# from the tree actually admitted before execution.
rm -f "$LOCK"
reset_box
unset AIRLOCK_TEST_WRITE_THIRD_LOCK
out="$(orch "$CAS/airlock.toml" 2>&1)" && self_base_rc=0 || self_base_rc=$?
printf 'next-approved-change\n' >>"$CAS/pkg/payload.txt"
cp "$LOCK" "$TMP/self-mutation-lock-before"
reset_box
out="$(env HOME="$FAKEHOME" AIRLOCK_CONFIG="$CAS/airlock.toml" \
  AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" AIRLOCK_TEST_MUTATE_PACKAGE=1 \
  bash "$ROOT/install/airlock-install.sh" \
  --dangerously-admit-unverified=caspkg 2>&1)" \
  && self_mutation_rc=0 || self_mutation_rc=$?
if [ "$self_base_rc" -eq 0 ] && [ "$self_mutation_rc" -ne 0 ] \
   && cmp -s "$TMP/self-mutation-lock-before" "$LOCK" \
   && grep -Fq 'package tree changed after break-glass admission' <<<"$out" \
   && grep -Fq 'preserving current lock bytes' <<<"$out"; then
  ok "honesty: finalization refuses post-admission package self-mutation"
else
  bad "honesty: break-glass pins only the tree admitted before lifecycle (rc=$self_mutation_rc)"
  failure_detail "$out"
fi

# SECURITY.md is an exceptional disclosure surface; routine installation and
# operator guides must not teach the break-glass spelling.  Task/design/evidence
# records are excluded because they are the review trail, not ordinary use.
ordinary_flag_hits="$(find "$ROOT" -type f -name '*.md' \
  ! -path "$ROOT/SECURITY.md" \
  ! -path "$ROOT/docs/tasks/*" \
  ! -path "$ROOT/docs/design/*" \
  -exec grep -l -- '--dangerously-admit-unverified=' {} + 2>/dev/null || true)"
if [ -z "$ordinary_flag_hits" ]; then
  ok "honesty: ordinary-use documentation does not disclose the break-glass flag"
else
  bad "honesty: break-glass flag leaked into ordinary-use documentation"
  failure_detail "$ordinary_flag_hits"
fi

# Store v6 is closed and its timestamp/receipt fields are real types, while
# every historical top-level shape remains readable and normalizes to v6.
if python3 - "$LEDGER" <<'PY'
import importlib.machinery
import importlib.util
from pathlib import Path
import sys

loader = importlib.machinery.SourceFileLoader("honesty_ledger_schema", sys.argv[1])
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)
path = Path("fixture-ledger.json")
for version in range(1, 5):
    normalized = module._validate_store({"version": version, "entries": {}}, path)
    assert normalized == {"version": 6, "entries": {}, "events": []}
normalized_v5 = module._validate_store({"version": 5, "entries": {}, "events": []}, path)
assert normalized_v5 == {"version": 6, "entries": {}, "events": []}
event = {
    "type": "package-lock-override",
    "package_id": "honestpkg",
    "argument": "--dangerously-admit-unverified=honestpkg",
    "recorded_digest": "1" * 64,
    "admitted_digest": "2" * 64,
    "recorded_at": "2026-08-13T02:01:24Z",
    "receipt_sha256": "3" * 64,
}
module._validate_store({"version": 6, "entries": {}, "events": [event]}, path)
invalid = [
    {"version": 6, "entries": {}},
    {"version": 6, "entries": {}, "events": [], "extra": True},
    {"version": 5, "entries": {}},
    {"version": 4, "entries": {}, "events": []},
    {"version": 6, "entries": {}, "events": [{**event, "recorded_at": "garbageZ"}]},
    {"version": 6, "entries": {}, "events": [{**event, "receipt_sha256": "short"}]},
]
for candidate in invalid:
    try:
        module._validate_store(candidate, path)
    except module.LedgerError:
        continue
    raise AssertionError(f"accepted invalid v6 store: {candidate!r}")
PY
then
  ok "honesty: v1-v5 normalize and v6 audit schema is closed"
else
  bad "honesty: ledger version and audit-event shapes stay fail-closed"
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

# D-DEVTERM-9900 retired the shipped entitlement. A fixture that still
# declares [plaintext_redirect] must be refused at admission — it must not
# reach serve or write a sidecar row. Intent/commit order for *existing*
# sidecar rows is covered below and by test-retirement-record.sh.
RETIRE="$TMP/retirement-orchestrator"
mkdir -p "$RETIRE"
rm -rf "$ROOT/apps/devterm"
mkdir -p "$ROOT/apps/devterm"
make_plain_package "$ROOT/apps/devterm" devterm
cat >>"$ROOT/apps/devterm/airlock-app.toml" <<'EOF'

[config.defaults]
public_port = 45678
redirect_port = 45679

[plaintext_redirect]
public_port = "redirect_port"
EOF
cat >"$RETIRE/airlock.toml" <<'EOF'
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"

[apps.hub]
[apps.devterm]
public_port = 45678
redirect_port = 45679
EOF

reset_box
: >"$TMP/tailscale.log"
out="$(orch "$RETIRE/airlock.toml" AIRLOCK_TEST_PLAINTEXT_STATEFUL=1 \
  AIRLOCK_TEST_FAIL_PLAINTEXT=45678 2>&1)" && retire_fail_rc=0 || retire_fail_rc=$?
if [ "$retire_fail_rc" -ne 0 ] \
   && grep -Fq 'plaintext_redirect is available only to shipped packages with the plaintext-redirect entitlement' <<<"$out" \
   && ! grep -q 'serve --bg --http=45678' "$TMP/tailscale.log" \
   && [ ! -e "$STATE/plaintext-retirement.json" ]
then
  ok "retirement orchestration: retired entitlement refuses a new shipped plaintext_redirect"
else
  bad "retirement orchestration: new shipped plaintext_redirect must be refused (rc=$retire_fail_rc)"
  failure_detail "$out"
fi

out="$(orch "$RETIRE/airlock.toml" AIRLOCK_TEST_PLAINTEXT_STATEFUL=1 2>&1)" \
  && retire_retry_rc=0 || retire_retry_rc=$?
if [ "$retire_retry_rc" -ne 0 ] \
   && grep -Fq 'plaintext_redirect is available only to shipped packages with the plaintext-redirect entitlement' <<<"$out" \
   && [ ! -e "$STATE/plaintext-retirement.json" ]
then
  ok "retirement orchestration: refusal does not depend on the mapping-failure inject"
else
  bad "retirement orchestration: refusal must happen before mapping (rc=$retire_retry_rc)"
  failure_detail "$out"
fi

# A removed future explicit package can leave the sidecar as the only state
# witness: no configured package, ledger, or shipped builtin need remain. Its
# existence must still enter the normal whole-run writer lock.
RETIRE_LOCK="$TMP/retirement-lock"
mkdir -p "$RETIRE_LOCK/empty-apps"
cat >"$RETIRE_LOCK/airlock.toml" <<'EOF'
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.hub]
EOF
reset_box
cat >"$STATE/plaintext-retirement.json" <<'EOF'
{"entries":[{"listen":45678,"package":"removed","state":"committed","target":45679}],"version":1}
EOF
exec 8>>"$STATE/app-ledger.lock"
flock -n 8
out="$(orch "$RETIRE_LOCK/airlock.toml" \
  AIRLOCK_SHIPPED_APPS_ROOT="$RETIRE_LOCK/empty-apps" 2>&1)" \
  && retire_lock_rc=0 || retire_lock_rc=$?
flock -u 8
exec 8>&-
if [ "$retire_lock_rc" -ne 0 ] \
   && grep -Fq 'another airlock run holds the ledger lock' <<<"$out"; then
  ok "retirement orchestration: a sidecar-only box still takes the whole-run writer lock"
else
  bad "retirement orchestration: sidecar-only state must serialize writers (rc=$retire_lock_rc)"
  failure_detail "$out"
fi

# A hub-only box with no package, ledger, sidecar, or shipped builtin remains
# state-free. The no-op retirement recorder must not create a lock merely by
# being called on every real orchestration.
reset_box
rm -rf "$STATE"
out="$(orch "$RETIRE_LOCK/airlock.toml" \
  AIRLOCK_SHIPPED_APPS_ROOT="$RETIRE_LOCK/empty-apps" 2>&1)" \
  && retire_empty_rc=0 || retire_empty_rc=$?
if [ "$retire_empty_rc" -eq 0 ] && [ ! -e "$STATE" ]; then
  ok "retirement orchestration: an empty hub-only run creates no state or lock"
else
  bad "retirement orchestration: no-op recorder changed empty-box behavior (rc=$retire_empty_rc)"
  failure_detail "$out"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
