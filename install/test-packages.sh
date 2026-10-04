#!/usr/bin/env bash
# install/test-packages.sh — executable fixtures for the app package contract,
# child 2 (docs/design/app-package-contract.md): F1 round trip, F2(a), F3,
# F7, F8, F9, F10's resolver cases, plus the D5 re-run rule and the dry-run /
# no-packages non-interference guarantees.
#
# Everything runs against scratch roots (state dir, webroot, confd, unit dirs)
# with permissive shims for sudo/systemctl/tailscale/nginx/curl — no live
# units, no real sudo, no network. Fixture packages live OUTSIDE the repo
# checkout (mktemp -d), so nothing can pass by accidentally resolving
# $ROOT/apps.
set -uo pipefail
. "$(dirname "$0")/test-lib.sh"
airlock_pin_paseo_mem

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(TMPDIR=/tmp mktemp -d)" || { echo "FAIL could not create test directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"
airlock_set_fixture_root "$TMP"
airlock_neutral_selfkill_cgroup "$TMP"

airlock_test_counters_init

CFG="$ROOT/bin/airlock-config"

# ---- scratch roots -----------------------------------------------------------
STATE="$TMP/state"; WEB="$TMP/web"; CONFD="$TMP/confd"
UU="$TMP/units-user"; US="$TMP/units-system"
FAKEHOME="$TMP/home"; DATA="$TMP/data"
export HOME="$FAKEHOME"
export AIRLOCK_STATE_DIR="$STATE" AIRLOCK_WEBROOT="$WEB" AIRLOCK_CONFD="$CONFD"
export AIRLOCK_UNIT_DIR_USER="$UU" AIRLOCK_UNIT_DIR_SYSTEM="$US"
export AIRLOCK_TS_FQDN="box.example.ts.net"

reset_box() {
  rm -rf "$STATE" "$WEB" "$CONFD" "$UU" "$US" "$FAKEHOME" "$DATA"
  rm -f "$TMP/previous-platform-root"
  mkdir -p "$WEB/assets" "$CONFD/hub-locations.d" "$CONFD/servers.d" \
           "$UU" "$US" "$FAKEHOME" "$DATA"
}

# ---- shims -------------------------------------------------------------------
# sudo execs its command (dropping -n/-u <user>); systemctl/tailscale log and
# succeed; nginx -t succeeds; curl answers 200 so the serve check passes.
SHIM="$TMP/shim"; mkdir -p "$SHIM"
cat >"$SHIM/sudo" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac
done
# Deterministic config A/B race seam for the orchestrator regression below.
# The first mutation command runs after the installer has frozen and fully
# preflighted A; replace the operator file with B before ledger reconcile.
if [ -n "${AIRLOCK_TEST_CONFIG_RACE_REPLACEMENT:-}" ] \
   && [ -n "${AIRLOCK_TEST_CONFIG_RACE_DONE:-}" ] \
   && [ ! -e "$AIRLOCK_TEST_CONFIG_RACE_DONE" ]; then
  cp "$AIRLOCK_TEST_CONFIG_RACE_REPLACEMENT" "$AIRLOCK_CONFIG"
  : > "$AIRLOCK_TEST_CONFIG_RACE_DONE"
fi
exec "$@"
STUB
cat >"$SHIM/systemctl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/systemctl.log"
if [ "\$*" = '--user show airlock-update-detect.service -p WorkingDirectory --value' ]; then
  [ ! -f "$TMP/previous-platform-root" ] || cat "$TMP/previous-platform-root"
  exit 0
fi
case "\$*" in *list-timers*) printf '%s\n' 'Mon 2026-09-02 00:00:00 KST 1d left airlock-update-detect.timer airlock-update-detect.service' ;; esac
# See the note in test-operator-surface.sh: a service installer asserts is-active.
case "\$*" in *is-active*) printf '%s\n' active ;; esac
# Ledger teardown verifies the stopped state before deleting any unit.
case "\$*" in *show*) printf 'LoadState=loaded\nActiveState=inactive\nMainPID=0\nControlPID=0\n' ;; esac
case "\$*" in *daemon-reload*) [ -e "$TMP/reload-fails" ] && exit 1 ;; esac
# Real systemd's \`disable\` REMOVES a symlinked unit file itself. Opt-in seam
# (flag file) so a test can model that; every other test sees the old shim.
if [ -e "$TMP/disable-removes-unit" ]; then
  case "\$*" in
    *disable*)
      for _a in "\$@"; do
        case "\$_a" in *.service|*.timer) rm -f "$UU/\$_a" ;; esac
      done ;;
  esac
fi
exit 0
STUB
cat >"$SHIM/tailscale" <<STUB
#!/usr/bin/env bash
if [ "\${1:-}" = status ] && [ "\${2:-}" = --json ]; then
  printf '{"BackendState":"Running","CertDomains":["example.ts.net"],"Self":{"DNSName":"box.example.ts.net."},"Health":[]}\n'
  exit 0
fi
if [ "\${1:-}" = serve ] && [ "\${2:-}" = status ]; then
  printf '{"TCP":{}}\n'; exit 0
fi
case "\$*" in serve\ --http=*\ off) [ -e "$TMP/serve-off-fails" ] && { printf '%s\n' "\$*" >> "$TMP/tailscale.log"; exit 1; } ;; esac
printf '%s\n' "\$*" >> "$TMP/tailscale.log"
exit 0
STUB
cat >"$SHIM/nginx" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$SHIM/curl" <<'STUB'
#!/usr/bin/env bash
case "$*" in *http_code*) printf 200 ;; esac
exit 0
STUB
cat >"$SHIM/systemd-run" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'FAIL fixture attempted to escape its neutral cgroup' >&2
exit 1
STUB
chmod +x "$SHIM"/*
PATH="$SHIM:$PATH"; export PATH

# ---- helpers -----------------------------------------------------------------
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

# mkcfg <path> <extra-toml...>
mkcfg() {
  local path="$1"; shift
  { printf '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[apps.hub]\n'
    printf '%s\n' "$@"; } >"$path"
}

# manifest <path> <id> [config-key ...] — write a minimal child-3 manifest
# header, then append the artifact body from stdin.  Most child-2 fixtures set
# backend_port in [apps.X], so that is the default declared key.
manifest() {
  local path="$1" id="$2" key
  shift 2
  [ "$#" -gt 0 ] || set -- backend_port
  {
    printf 'contract = 1\nid = "%s"\n' "$id"
    if [ "${1:-}" != "-" ]; then
      printf '[config.defaults]\n'
      for key in "$@"; do
        printf '%s = 18900\n' "$key"
      done
    fi
    cat
  } >"$path"
}

# mkpkg <dir> <id> [with_deactivate:1|0] — a minimal contract-conforming
# package. Its scripts use ONLY the D5 ABI variables and record how they were
# invoked, so the fixtures can assert env + cwd. install.sh writes one declared
# webroot marker and one data file; deactivate removes the marker, keeps data.
mkpkg() {
  local dir="$1" id="$2" deact="${3:-1}" env_id
  env_id="${id^^}"
  env_id="${env_id//-/_}"
  mkdir -p "$dir"
  cat >"$dir/airlock-app.toml" <<EOF
contract = 1
id = "$id"
[config.defaults]
backend_port = 18900
[artifacts]
webroot = ["$id/"]
serve_ports = ["backend_port"]
EOF
  cat >"$dir/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
. "\$AIRLOCK_ROOT/install/lib.sh"
airlock_load "\$AIRLOCK_APP_ID"
fixture_port="\${AIRLOCK_${env_id}_BACKEND_PORT:?}"
test "\$fixture_port" -gt 0
printf 'ROOT=%s DIR=%s ID=%s CWD=%s\n' "\$AIRLOCK_ROOT" "\$AIRLOCK_APP_DIR" "\$AIRLOCK_APP_ID" "\$PWD" >> "$TMP/invoke-\$AIRLOCK_APP_ID.log"
mkdir -p "\$AIRLOCK_WEBROOT/\$AIRLOCK_APP_ID"
printf 'marker\n' > "\$AIRLOCK_WEBROOT/\$AIRLOCK_APP_ID/marker"
printf 'data\n' >> "$DATA/\$AIRLOCK_APP_ID.data"
EOF
  cat >"$dir/smoke.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'SMOKE ID=%s CWD=%s\n' "\$AIRLOCK_APP_ID" "\$PWD" >> "$TMP/invoke-\$AIRLOCK_APP_ID.log"
[ -f "\$AIRLOCK_WEBROOT/\$AIRLOCK_APP_ID/marker" ]
EOF
  if [ "$deact" = 1 ]; then
    cat >"$dir/deactivate.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
rm -f "\$AIRLOCK_WEBROOT/\$AIRLOCK_APP_ID/marker"
rmdir "\$AIRLOCK_WEBROOT/\$AIRLOCK_APP_ID" 2>/dev/null || true
exit 0
EOF
  fi
  chmod +x "$dir"/*.sh 2>/dev/null || true
}

# orch <config> [VAR=val...] — the real orchestrator against the scratch box.
orch() {
  local cfg="$1"; shift
  local variables=() arguments=() value
  for value in "$@"; do
    case "$value" in --*) arguments+=("$value") ;; *) variables+=("$value") ;; esac
  done
  env HOME="$FAKEHOME" AIRLOCK_CONFIG="$cfg" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
      "${variables[@]}" bash "$ROOT/install/airlock-install.sh" "${arguments[@]}"
}

# The installation record is read through the engine module.
installed() {
  python3 - "$ROOT/bin/airlock-ledger" "$@" <<'PY_READ'
from importlib.machinery import SourceFileLoader
import json, sys
sys.dont_write_bytecode = True
m = SourceFileLoader("test_packages_ledger", sys.argv[1]).load_module()
print(json.dumps(m.load_installed(), sort_keys=True))
PY_READ
}
apply_source() {
  AIRLOCK_CONFIG="$1" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
    "$ROOT/bin/airlock-ledger" apply "$2" --source "$3"
}

# =============================================================================
# F10 resolver cases + artifact grammar (validate-time, no orchestrator run)
# =============================================================================
reset_box
PKGROOT="$TMP/pkgs"; mkdir -p "$PKGROOT"
mkpkg "$PKGROOT/good" t1 1

CFGDIR="$TMP/cfgs"; mkdir -p "$CFGDIR"

mkcfg "$CFGDIR/ok.toml" "[apps.t1]" "backend_port = 18900" "[packages.t1]" "path = \"$PKGROOT/good\""
seed_apps t1 "$PKGROOT/good"
if run "$CFGDIR/ok.toml" validate >/dev/null 2>&1; then
  ok "resolver: a conforming package validates"
else
  bad "resolver: a conforming package validates"
fi

preflight_a="$(run "$CFGDIR/ok.toml" install-preflight 2>/dev/null)" || preflight_a=""
preflight_b="$(run "$CFGDIR/ok.toml" install-preflight 2>/dev/null)" || preflight_b=""
if [[ "$preflight_a" =~ ^[0-9a-f]{64}$ ]] && [ "$preflight_a" = "$preflight_b" ]; then
  ok "candidate preflight: every static projection resolves to one deterministic digest"
else
  bad "candidate preflight: digest is missing or unstable ($preflight_a / $preflight_b)"
fi

# PRIVATE_RELEASE_PATH launcher oracle: these are explicit package manifests,
# with no [shortcuts] or other fallback catalog input. webjson must project the
# three private tiles verbatim (except the documented staged icon URL rewrite).
reset_box
TILES="$TMP/private-tiles"; mkdir -p "$TILES"
for private_id in vm-monitor slides-manager notes-stack; do
  mkpkg "$TILES/$private_id" "$private_id" 1
done
cat >>"$TILES/vm-monitor/airlock-app.toml" <<'EOF'
[tile]
label = "Windows VM"
sub = "Private Windows monitor"
cat = "system"
path = "/vm-monitor/"
glyph = "monitor"
EOF
printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' >"$TILES/slides-manager/tile.svg"
cat >>"$TILES/slides-manager/airlock-app.toml" <<'EOF'
[tile]
label = "Slides"
sub = "Private gallery"
cat = "docs"
path = "/slides/"
icon = "tile.svg"
EOF
cat >>"$TILES/notes-stack/airlock-app.toml" <<'EOF'
[tile]
label = "Notes"
sub = "Private notes"
cat = "docs"
path = "/notes/"
glyph = "note"
EOF
mkcfg "$TILES/airlock.toml" \
  "[apps.vm-monitor]" "backend_port = 18931" \
  "[apps.slides-manager]" "backend_port = 18932" \
  "[apps.notes-stack]" "backend_port = 18933" \
  "[packages.vm-monitor]" "path = \"$TILES/vm-monitor\"" \
  "[packages.slides-manager]" "path = \"$TILES/slides-manager\"" \
  "[packages.notes-stack]" "path = \"$TILES/notes-stack\""
seed_apps vm-monitor "$TILES/vm-monitor" slides-manager "$TILES/slides-manager" notes-stack "$TILES/notes-stack"
tiles_json="$(run "$TILES/airlock.toml" webjson 2>/dev/null)" && rc=0 || rc=$?
if [ "$rc" = 0 ] && printf '%s' "$tiles_json" | python3 -c '
import json, sys
apps = json.load(sys.stdin)["apps"]
assert {k for k, v in apps.items() if v.get("packaged")} == {
    "vm-monitor", "slides-manager", "notes-stack"
}
assert sum(bool(v.get("shortcut")) for v in apps.values()) == 0
assert apps["vm-monitor"]["tile"] == {
    "label": "Windows VM", "sub": "Private Windows monitor", "cat": "system",
    "path": "/vm-monitor/", "glyph": "monitor",
}
assert apps["slides-manager"]["tile"] == {
    "label": "Slides", "sub": "Private gallery", "cat": "docs",
    "path": "/slides/", "icon": "/assets/apps/slides-manager/tile.svg",
}
assert apps["notes-stack"]["tile"] == {
    "label": "Notes", "sub": "Private notes", "cat": "docs",
    "path": "/notes/", "glyph": "note",
}
' >/dev/null 2>&1; then
  ok "private tiles: vm-monitor/slides-manager/notes manifests project into webjson with fallback inputs=0"
else
  bad "private tiles: manifest-to-webjson projection drifted (rc=$rc)"
fi

# Two packages with distinct webroot prefixes validate.
reset_box
ovA="$PKGROOT/ovA"; mkpkg "$ovA" o1 1; ovB="$PKGROOT/ovB"; mkpkg "$ovB" o2 1
manifest "$ovA/airlock-app.toml" o1 - <<'EOF'
[artifacts]
webroot = ["shared/"]
EOF
manifest "$ovB/airlock-app.toml" o2 - <<'EOF'
[artifacts]
webroot = ["shared/"]
EOF
mkcfg "$CFGDIR/ov.toml" "[apps.o1]" "[apps.o2]" \
  "[packages.o1]" "path = \"$ovA\"" "[packages.o2]" "path = \"$ovB\""


seed_apps o1 "$ovA" o2 "$ovB"
# Distinct literal prefixes stay allowed (the conservative rule must not
# reject everything).
manifest "$ovA/airlock-app.toml" o1 - <<'EOF'
[artifacts]
webroot = ["o1/"]
EOF
manifest "$ovB/airlock-app.toml" o2 - <<'EOF'
[artifacts]
webroot = ["o2/"]
EOF
if run "$CFGDIR/ov.toml" validate >/dev/null 2>&1; then
  ok "F10: disjoint literal prefixes still validate"
else
  bad "F10: disjoint literal prefixes still validate"
fi

# P3E-19: leftover registration tables are inert even with a valid source.
reset_box
mkpkg "$PKGROOT/stale-foo" foo 1
mkpkg "$PKGROOT/stale-notepad" notepad 1
mkcfg "$CFGDIR/stale.toml" '[apps.foo]' '[apps.notepad]' '[apps.publish]' \
  '[packages.foo]' "path = \"$PKGROOT/stale-foo\"" \
  '[packages.notepad]' "path = \"$PKGROOT/stale-notepad\""
stale_info="$(run "$CFGDIR/stale.toml" package-info 2>/dev/null)" && stale_rc=0 || stale_rc=$?
if [ "$stale_rc" = 0 ] && python3 -c '
import json, sys
from pathlib import Path
p = json.load(sys.stdin)["packages"]
assert "foo" not in p
assert p["notepad"]["source_class"] == "shipped"
assert Path(p["notepad"]["dir"]).resolve() == (Path(sys.argv[1]) / "apps/notepad").resolve()
' "$ROOT" <<<"$stale_info"; then
  ok "P3E-19: leftover packages neither discover foo nor shadow shipped notepad"
else
  bad "P3E-19: leftover packages affected source resolution"
fi
stale_out="$(AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" AIRLOCK_CONFIG="$CFGDIR/stale.toml" "$ROOT/bin/airlock-ledger" apply foo 2>&1)" && stale_rc=0 || stale_rc=$?
if [ "$stale_rc" -ne 0 ] && grep -Fq 'no source for foo' <<<"$stale_out" \
   && [ ! -e "$TMP/invoke-foo.log" ] && [ ! -e "$STATE/installed-apps.json" ]; then
  ok "P3E-19: foo apply requires an explicit source and never runs its stale hook"
else
  bad "P3E-19: stale foo was installed or missing-source failure absent (rc=$stale_rc)"
fi

# Full box installs and direct app operations use the same app engine. An out-of-tree
# Personal source must first be explicitly supplied; [packages] is not source authority.
reset_box
PKG="$TMP/engine-personal"; mkpkg "$PKG" personal
CFGFILE="$TMP/engine-personal.toml"
mkcfg "$CFGFILE" '[apps.personal]' 'backend_port = 18900' '[packages.personal]' "path = \"$PKG\""
out="$(AIRLOCK_CONFIG="$CFGFILE" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" "$ROOT/bin/airlock-ledger" apply personal 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'no source for personal' <<<"$out" \
  && [ ! -e "$WEB/personal/marker" ] \
  && ok "Personal first install requires a source rather than packages.path" \
  || bad "Personal source authority changed: $out"
apply_source "$CFGFILE" personal "$PKG" >"$TMP/apply.log" 2>&1 \
  && ok "an explicit local source installs through the app engine" \
  || { bad "local source apply"; tail -8 "$TMP/apply.log"; }
[ -f "$WEB/personal/marker" ] && [ -f "$DATA/personal.data" ] \
  && grep -q "DIR=$PKG ID=personal CWD=$PKG" "$TMP/invoke-personal.log" \
  && ok "local hook receives the ABI, cwd, artifact roots and leaves user data" \
  || bad "local hook ABI/root behavior"
before_calls="$(wc -l <"$TMP/invoke-personal.log")"
out="$(AIRLOCK_CONFIG="$CFGFILE" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" "$ROOT/bin/airlock-ledger" apply personal 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(wc -l <"$TMP/invoke-personal.log")" = "$((before_calls + 1))" ] \
  && ! grep -q 'SMOKE' "$TMP/invoke-personal.log" \
  && ! grep -q 'platform secret TTL' <<<"$out" \
  && ok "direct apply changes only the target app, without box timers or smoke" \
  || bad "direct apply did extra work or failed: $out"

# Full core updates never replay or remove a Personal lifecycle.
personal_before="$(installed | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["personal"],sort_keys=True))')"
before_calls="$(wc -l <"$TMP/invoke-personal.log")"
CORE_ROOT="$TMP/shipped"; CORE_PKG="$CORE_ROOT/core-fixture"
mkpkg "$CORE_PKG" core-fixture
mkpkg "$CORE_ROOT/core-fixture-two" core-fixture-two
export AIRLOCK_SHIPPED_APPS_ROOT="$CORE_ROOT"
mkcfg "$CFGFILE" '[apps.core-fixture]' 'backend_port = 18901' \
  '[apps.core-fixture-two]' 'backend_port = 18902' \
  '[apps.personal]' 'backend_port = 18900' '[packages.personal]' "path = \"$PKG\""
apply_source "$CFGFILE" core-fixture "$CORE_PKG" >/dev/null 2>&1 || bad "core setup"
apply_source "$CFGFILE" core-fixture-two "$CORE_ROOT/core-fixture-two" >/dev/null 2>&1 || bad "second core setup"
core_calls="$(wc -l <"$TMP/invoke-core-fixture.log")"
second_core_calls="$(wc -l <"$TMP/invoke-core-fixture-two.log")"
out="$(orch "$CFGFILE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'SMOKE ID=core-fixture' "$TMP/invoke-core-fixture.log" \
  && grep -q 'SMOKE ID=core-fixture-two' "$TMP/invoke-core-fixture-two.log" \
  && [ "$(grep -c '^ROOT=' "$TMP/invoke-core-fixture-two.log")" = "$((second_core_calls + 1))" ] \
  && [ "$(grep -c '^ROOT=' "$TMP/invoke-core-fixture.log")" = "$((core_calls + 1))" ] \
  && [ "$(wc -l <"$TMP/invoke-personal.log")" = "$before_calls" ] \
  && [ "$(installed | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["personal"],sort_keys=True))')" = "$personal_before" ] \
  && ok "full install applies and smokes both core apps while preserving the Personal lifecycle" \
  || { bad "full install changed a non-core app or failed: $out"; }

# Config A is frozen before mutations: replacing it with B cannot remove A's core app.
mkcfg "$TMP/drop.toml"
out="$(orch "$CFGFILE" AIRLOCK_TEST_CONFIG_RACE_REPLACEMENT="$TMP/drop.toml" \
  AIRLOCK_TEST_CONFIG_RACE_DONE="$TMP/raced" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -f "$TMP/raced" ] && [ -f "$WEB/core-fixture/marker" ] \
  && [ "$(installed | python3 -c 'import json,sys; print("core-fixture" in json.load(sys.stdin))')" = True ] \
  && ok "box install uses frozen config A when the operator file changes to B" \
  || bad "box install mixed A/B configs: $out"
# Config B drops app inputs; ③ still owns installation membership.
config_before="$(cat "$CFGFILE")"
out="$(orch "$CFGFILE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -f "$WEB/core-fixture/marker" ] && [ -f "$WEB/core-fixture-two/marker" ] \
  && [ "$(cat "$CFGFILE")" = "$config_before" ] \
  && [ "$(wc -l <"$TMP/invoke-personal.log")" = "$before_calls" ] \
  && [ "$(installed | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["personal"],sort_keys=True))')" = "$personal_before" ] \
  && ok "platform preserves installed core apps without config tables and keeps config bytes" \
  || bad "platform treated config inputs as installation membership: $out"
# Removing an app preserves its inputs; Platform must not resurrect it.
mkcfg "$CFGFILE" '[apps.core-fixture]' 'backend_port = 18901'
AIRLOCK_CONFIG="$CFGFILE" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" "$ROOT/bin/airlock-ledger" remove core-fixture >/dev/null 2>&1 || bad "core removal setup"
core_calls="$(wc -l <"$TMP/invoke-core-fixture.log")"
config_before="$(cat "$CFGFILE")"
out="$(orch "$CFGFILE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$WEB/core-fixture" ] && [ -f "$DATA/core-fixture.data" ] \
  && [ "$(cat "$CFGFILE")" = "$config_before" ] \
  && [ "$(wc -l <"$TMP/invoke-core-fixture.log")" = "$core_calls" ] \
  && [ -f "$WEB/core-fixture-two/marker" ] \
  && ok "Remove then Platform keeps the removed core app absent despite retained inputs" \
  || bad "platform resurrected a removed core app: $out"
AIRLOCK_CONFIG="$CFGFILE" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" "$ROOT/bin/airlock-ledger" remove core-fixture-two >/dev/null 2>&1 || bad "second core cleanup"
unset AIRLOCK_SHIPPED_APPS_ROOT

# Reinstall without deactivate and direct removal also work.
mkcfg "$CFGFILE" '[apps.personal]' 'backend_port = 18900' '[packages.personal]' "path = \"$PKG\""
rm -f "$PKG/deactivate.sh"
apply_source "$CFGFILE" personal "$PKG" >/dev/null 2>&1 || bad "setup deactivator-free app"
mkcfg "$CFGFILE"
out="$(AIRLOCK_CONFIG="$CFGFILE" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" "$ROOT/bin/airlock-ledger" remove personal 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$WEB/personal" ] && [ -f "$DATA/personal.data" ] \
  && [ "$(installed)" = '{}' ] \
  && ok "direct removal works without a deactivator and leaves user data" \
  || bad "direct removal failed: $out"

# Dry previews never execute a Personal hook or alter its existing record.
mkcfg "$CFGFILE" '[apps.personal]' 'backend_port = 18900' '[packages.personal]' "path = \"$PKG\""
apply_source "$CFGFILE" personal "$PKG" >/dev/null 2>&1 || bad "dry setup"
record_before="$(installed)"; calls_before="$(wc -l <"$TMP/invoke-personal.log")"
out="$(orch "$CFGFILE" AIRLOCK_DRY_RUN=1 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(installed)" = "$record_before" ] \
  && [ "$(wc -l <"$TMP/invoke-personal.log")" = "$calls_before" ] \
  && ok "Personal dry preview changes neither record nor lifecycle bytes" \
  || bad "Personal dry preview changed state or failed: $out"

# A5 refuses escaping paths before either entry performs a mutation.
for entry in full apply; do
  calls_before="$(wc -l <"$TMP/invoke-personal.log")"
  if [ "$entry" = full ]; then
    out="$(orch "$CFGFILE" AIRLOCK_WEBROOT=/outside-fixture 2>&1)"; rc=$?
  else
    out="$(AIRLOCK_CONFIG="$CFGFILE" AIRLOCK_WEBROOT=/outside-fixture "$ROOT/bin/airlock-ledger" apply personal 2>&1)"; rc=$?
  fi
  [ "$rc" != 0 ] && grep -q 'fixture boundary:' <<<"$out" \
    && [ "$(wc -l <"$TMP/invoke-personal.log")" = "$calls_before" ] \
    && ok "A5 $entry rejects an outside webroot before lifecycle effects" \
    || bad "A5 $entry escaped or failed without boundary reason: $out"
done
out="$(AIRLOCK_CONFIG="$CFGFILE" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" "$ROOT/bin/airlock-ledger" apply ../personal 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -q 'not a valid app id' <<<"$out" \
  && ok "direct apply malformed id fails before effects" \
  || bad "direct apply malformed id reached effects: $out"

# Bootstrap is only an absent new AND old installation record.
reset_box
CORE_ROOT="$TMP/bootstrap-core"; mkpkg "$CORE_ROOT/bootstrap" bootstrap
export AIRLOCK_SHIPPED_APPS_ROOT="$CORE_ROOT"
CFGFILE="$TMP/bootstrap.toml"; mkcfg "$CFGFILE" '[site]' "company_repo = \"file://$TMP/absent-company\"" '[apps.bootstrap]'
config_before="$(cat "$CFGFILE")"
out="$(orch "$CFGFILE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -f "$WEB/bootstrap/marker" ] && [ "$(cat "$CFGFILE")" = "$config_before" ] \
  && ok "first install without either record bootstraps configured core apps" \
  || bad "first bootstrap failed: $out"
# A legacy registration must not shadow the source already recorded in ③.
mkcfg "$CFGFILE" '[apps.bootstrap]' '[packages.bootstrap]' "path = \"$CORE_ROOT/bootstrap\""
bootstrap_calls="$(wc -l <"$TMP/invoke-bootstrap.log")"
out="$(orch "$CFGFILE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(wc -l <"$TMP/invoke-bootstrap.log")" = "$((bootstrap_calls + 2))" ] \
  && ok "Platform updates a recorded core row even when legacy packages shadows its id" \
  || bad "legacy registration hid a recorded core app: $out"
# A Personal app with the same id as a shipped app keeps its recorded source.
reset_box
PERSONAL_CORE="$TMP/personal-core-name"; mkpkg "$PERSONAL_CORE" bootstrap
apply_source "$CFGFILE" bootstrap "$PERSONAL_CORE" >/dev/null 2>&1 || bad "same-id Personal setup"
same_id_before="$(installed)"; bootstrap_calls="$(wc -l <"$TMP/invoke-bootstrap.log")"
out="$(orch "$CFGFILE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(installed)" = "$same_id_before" ] \
  && [ "$(wc -l <"$TMP/invoke-bootstrap.log")" = "$bootstrap_calls" ] \
  && ok "Platform preserves a Personal row sharing a shipped core id without replaying it" \
  || bad "Platform replaced a same-id Personal source: $out"
# Moving the operator checkout must update cores recorded under the old tree.
reset_box
OLD_CORE_TREE="$TMP/previous-platform"
printf '%s\n' "$OLD_CORE_TREE" > "$TMP/previous-platform-root"
mkpkg "$OLD_CORE_TREE/apps/bootstrap" bootstrap
apply_source "$CFGFILE" bootstrap "$OLD_CORE_TREE/apps/bootstrap" >/dev/null 2>&1 \
  || bad "previous checkout core setup"
bootstrap_calls="$(wc -l <"$TMP/invoke-bootstrap.log")"
out="$(orch "$CFGFILE" 2>&1)"; rc=$?
[ "$rc" = 0 ] \
  && [ "$(installed | python3 -c 'import json,sys; print(json.load(sys.stdin)["bootstrap"]["repo"])')" = "$CORE_ROOT/bootstrap" ] \
  && [ "$(wc -l <"$TMP/invoke-bootstrap.log")" = "$((bootstrap_calls + 2))" ] \
  && [ -f "$DATA/bootstrap.data" ] \
  && ok "Platform rebinds an installed core from the previous checkout without removing its data" \
  || bad "Platform left a core running from the previous checkout: $out"
# apps/<id> alone does not turn a Personal package into a platform core.
reset_box
PERSONAL_CORE="$TMP/personal-tree/apps/bootstrap"; mkpkg "$PERSONAL_CORE" bootstrap
mkdir -p "$TMP/symlink-platform/apps"
ln -s "$PERSONAL_CORE" "$TMP/symlink-platform/apps/bootstrap"
printf '%s\n' "$TMP/symlink-platform" > "$TMP/previous-platform-root"
apply_source "$CFGFILE" bootstrap "$PERSONAL_CORE" >/dev/null 2>&1 || bad "Personal apps layout setup"
same_id_before="$(installed)"; bootstrap_calls="$(wc -l <"$TMP/invoke-bootstrap.log")"
out="$(orch "$CFGFILE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(installed)" = "$same_id_before" ] \
  && [ "$(wc -l <"$TMP/invoke-bootstrap.log")" = "$bootstrap_calls" ] \
  && ok "Platform preserves a Personal apps directory even when the previous platform symlinks to it" \
  || bad "Platform claimed a Personal package through the previous tree's symlink: $out"
# An existing empty record must remain empty, including preview projection.
reset_box; mkdir -p "$STATE"; printf '{}\n' > "$STATE/installed-apps.json"
bootstrap_calls="$(wc -l <"$TMP/invoke-bootstrap.log")"
out="$(orch "$CFGFILE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$WEB/bootstrap" ] && [ "$(installed)" = '{}' ] \
  && [ "$(wc -l <"$TMP/invoke-bootstrap.log")" = "$bootstrap_calls" ] \
  && ok "an explicit empty record never bootstraps configured apps" \
  || bad "empty record resurrected an app: $out"
mkdir -p "$TMP/preview"
# Observe the real renderer's webjson result, not a fabricated engine response.
mkdir -p "$TMP/projection-probe"
cat > "$TMP/projection-probe/sitecustomize.py" <<'PY_OBSERVE'
import json, os, pathlib, subprocess
_original_run = subprocess.run
def observe_run(args, *positional, **keywords):
    result = _original_run(args, *positional, **keywords)
    if isinstance(args, (list, tuple)) and len(args) >= 3 and str(args[1]).endswith('/bin/airlock-config') and args[2] == 'webjson':
        root = pathlib.Path(os.environ['AIRLOCK_PROJECTION_PROBE'])
        (root / 'preview-webjson.json').write_text(result.stdout)
        (root / 'preview-project-ids').write_text(keywords.get('env', os.environ).get('AIRLOCK_PROJECT_IDS', 'unset'))
    return result
subprocess.run = observe_run
PY_OBSERVE
out="$(orch "$CFGFILE" AIRLOCK_DRY_RUN=1 AIRLOCK_DRY_RUN_OUTPUT_DIR="$TMP/preview" \
    PYTHONPATH="$TMP/projection-probe" AIRLOCK_PROJECTION_PROBE="$TMP" 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ "$(cat "$TMP/preview-project-ids")" = '' ] \
    && python3 - "$TMP/preview-webjson.json" <<'PY_EMPTY'
import json, sys
assert json.load(open(sys.argv[1]))["apps"] == {}
PY_EMPTY
then
  ok "empty record preview explicitly projects an empty installed app set"
else
  bad "empty preview used config membership: $out"
fi
# v7 presence is installed state too, and an empty v7 cannot bootstrap.
reset_box; mkdir -p "$STATE"
printf '{"version":7,"entries":{}}\n' > "$STATE/app-ledger.json"
out="$(orch "$CFGFILE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$WEB/bootstrap" ] \
  && ok "an empty legacy v7 record is never a bootstrap request" \
  || bad "empty v7 bootstrapped: $out"
python3 - "$STATE/app-ledger.json" "$CORE_ROOT/bootstrap" <<'PY_V7'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({"version":7,"entries":{"bootstrap":{"committed":{"path":sys.argv[2],"artifacts":{}}}}})+"\n")
PY_V7
mkcfg "$CFGFILE"
out="$(orch "$CFGFILE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -f "$WEB/bootstrap/marker" ] && [ -f "$STATE/app-ledger.v7.json" ] \
  && ok "a committed v7 core row applies without a config table and converts on write" \
  || bad "committed v7 membership was lost: $out"
unset AIRLOCK_SHIPPED_APPS_ROOT

# A first dry bootstrap previews the dependency plan without pretending apps
# are installed. A real bootstrap then commits publish before notepad; later
# installed-box dry previews still execute certified hooks in private roots.
reset_box
CORE_ROOT="$TMP/bootstrap-deps"; mkpkg "$CORE_ROOT/publish" publish; mkpkg "$CORE_ROOT/notepad" notepad
export AIRLOCK_SHIPPED_APPS_ROOT="$CORE_ROOT"
python3 - "$CORE_ROOT/publish/airlock-app.toml" <<'PY_PUBLISH'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace('backend_port = 18900\n',
    'backend_port = 18900\nhttps_port = 19920\ngate_port = 19921\n'
    'share_dir = "~/.local/share/publish"\ntitle_meta = false\ntailnet_view = false\n'))
PY_PUBLISH
printf '\n[dependencies]\napps = ["publish"]\n' >> "$CORE_ROOT/notepad/airlock-app.toml"
for app in publish notepad; do
  python3 - "$CORE_ROOT/$app/install.sh" "$app" "$TMP" <<'PY_HOOK'
import pathlib, sys
path, app, scratch = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
source = path.read_text()
probe = (f'printf "{app}\\n" >> "{scratch}/bootstrap-order.log"\n'
         + ('airlock_app_installed publish || exit 1\n' if app == 'notepad' else '')
         + 'if [ "${AIRLOCK_DRY_RUN:-0}" = 1 ]; then\n'
         + f'  printf "{app}\\n" >> "{scratch}/bootstrap-dry-hooks.log"\n'
         + '  exit 0\nfi\n')
source = source.replace('airlock_load "$AIRLOCK_APP_ID"', probe + 'airlock_load "$AIRLOCK_APP_ID"')
path.write_text(source)
PY_HOOK
done
CFGFILE="$TMP/bootstrap-deps.toml"
mkcfg "$CFGFILE" '[apps.notepad]' 'backend_port = 18902' '[apps.publish]' 'backend_port = 18901'
mkdir -p "$STATE"
files_before="$(find "$WEB" "$CONFD" "$UU" "$US" "$FAKEHOME" "$DATA" "$STATE" -type f -exec md5sum {} + | sort)"
config_before="$(cat "$CFGFILE")"
out="$(orch "$CFGFILE" AIRLOCK_DRY_RUN=1 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$TMP/bootstrap-order.log" ] && [ ! -e "$STATE/installed-apps.json" ] \
  && grep -q 'would install packaged app: publish' <<<"$out" \
  && grep -q 'would install packaged app: notepad' <<<"$out" \
  && [ "$(cat "$CFGFILE")" = "$config_before" ] \
  && [ "$(find "$WEB" "$CONFD" "$UU" "$US" "$FAKEHOME" "$DATA" "$STATE" -type f -exec md5sum {} + | sort)" = "$files_before" ] \
  && ok "first publish+notepad dry bootstrap reports its plan without hooks or live-root file changes" \
  || bad "first dry bootstrap simulated installation or changed files: $out"
out="$(orch "$CFGFILE" 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$TMP/bootstrap-order.log")" = $'publish\nnotepad' ] \
  && ok "real bootstrap applies publish then notepad through the existing manifest dependency" \
  || bad "real bootstrap dependency order failed: $out"
record_before="$(installed)"
out="$(orch "$CFGFILE" AIRLOCK_DRY_RUN=1 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$TMP/bootstrap-dry-hooks.log" ] && [ "$(installed)" = "$record_before" ] \
  && [ "$(cat "$CFGFILE")" = "$config_before" ] \
  && ok "an installed-box dry preview still skips uncertified fixture hooks and preserves ③ and inputs" \
  || bad "uncertified installed-box dry hooks ran or changed state: $out"
unset AIRLOCK_SHIPPED_APPS_ROOT

# Directory-to-contents claims keep the tree just applied.
reset_box
PKG="$TMP/contained"; mkpkg "$PKG" contained
CFGFILE="$TMP/contained.toml"
mkcfg "$CFGFILE" '[apps.contained]' 'backend_port = 18900' '[packages.contained]' "path = \"$PKG\""
apply_source "$CFGFILE" contained "$PKG" >/dev/null 2>&1 || bad "contained setup"
printf 'operator bytes\n' >"$WEB/contained/user.db"
sed -i 's|webroot = \["contained/"\]|webroot = ["contained/*"]|' "$PKG/airlock-app.toml"
apply_source "$CFGFILE" contained "$PKG" >"$TMP/contained.log" 2>&1; rc=$?
if [ "$rc" = 0 ] && [ -f "$WEB/contained/marker" ] && [ -f "$WEB/contained/user.db" ]; then
  sed -i 's|webroot = \["contained/\*"\]|webroot = ["contained/"]|' "$PKG/airlock-app.toml"
  apply_source "$CFGFILE" contained "$PKG" >"$TMP/contained-back.log" 2>&1; back_rc=$?
  if [ "$back_rc" = 0 ] && [ -f "$WEB/contained/marker" ] \
     && [ "$(cat "$WEB/contained/user.db")" = 'operator bytes' ]; then
    ok "directory-to-contents and reverse upgrades keep the newly claimed tree"
  else
    bad "contents-to-directory upgrade deletes current resources (rc=$back_rc)"
  fi
else
  bad "directory-to-contents upgrade deletes current resources (rc=$rc marker=$([ -f "$WEB/contained/marker" ] && echo present || echo missing) user.db=$([ -f "$WEB/contained/user.db" ] && echo present || echo missing))"
fi


# Recorded membership/source consumer regressions (existing suite).
if python3 - "$ROOT" <<'PY_HOOK_MEMBERSHIP'
#!/usr/bin/env python3
"""Real dry hooks use installed dependencies, optional features and widgets."""
import json
import os
from pathlib import Path
import subprocess
import shutil
import hashlib
import tempfile

import sys
ROOT = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="airlock-hook-membership-") as scratch:
    base = Path(scratch)
    for name in ("home", "state", "data", "web", "confd", "units-user", "units-system", "shim"):
        (base / name).mkdir()
    for tool in ("sudo", "systemctl", "nginx", "tailscale"):
        path = base / "shim" / tool
        path.write_text('#!/bin/sh\necho "unexpected live command in dry hook" >&2\nexit 1\n')
        path.chmod(0o755)
    config = base / "airlock.toml"
    record = base / "state/installed-apps.json"
    auth = '[auth]\nprovider="tailscale"\nowner="fixture@test"\n[apps.hub]\n'
    env = {key: value for key, value in os.environ.items() if not key.startswith("AIRLOCK_")}
    env.update(HOME=str(base / "home"), AIRLOCK_ROOT=str(ROOT), AIRLOCK_CONFIG=str(config),
               AIRLOCK_FIXTURE_ROOT=str(base), AIRLOCK_STATE_DIR=str(base / "state"),
               AIRLOCK_DATA_DIR=str(base / "data"), AIRLOCK_WEBROOT=str(base / "web"),
               AIRLOCK_CONFD=str(base / "confd"), AIRLOCK_NGINX_SITE=str(base / "site.conf"),
               AIRLOCK_UNIT_DIR_USER=str(base / "units-user"),
               AIRLOCK_UNIT_DIR_SYSTEM=str(base / "units-system"),
               AIRLOCK_PLATFORM_ETC=str(base / "platform-etc"),
               AIRLOCK_PLATFORM_OPT=str(base / "platform-opt"),
               AIRLOCK_TS_FQDN="box.example.ts.net", AIRLOCK_DRY_RUN="1",
               PATH=str(base / "shim") + ":" + env["PATH"])

    def run(*args, extra=None):
        return subprocess.run(args, env=dict(env, **(extra or {})),
                              text=True, capture_output=True, timeout=60)

    def hook(app):
        return run("bash", str(ROOT / "apps" / app / "install.sh"),
                   extra={"AIRLOCK_APP_ID": app, "AIRLOCK_APP_DIR": str(ROOT / "apps" / app)})

    def panel():
        return run("bash", "-c", 'source "$AIRLOCK_ROOT/install/lib.sh"; airlock_panel_url')

    config.write_text(auth)
    rows = {app: {"repo": str(ROOT / "apps" / app), "commit": "", "artifacts": []}
            for app in ("publish", "devterm", "fileview", "orca")}
    record.write_text(json.dumps(rows))
    before_config, before_record = config.read_bytes(), record.read_bytes()
    result = hook("notepad")
    assert result.returncode == 0, (result.stdout, result.stderr)
    result = hook("devterm")
    assert result.returncode == 0 and "fileview=true, orca=true" in result.stderr, (result.stdout, result.stderr)
    result = panel()
    assert result.returncode == 0 and result.stdout.strip() == "https://box.example.ts.net:19910/", (result.stdout, result.stderr)
    assert config.read_bytes() == before_config and record.read_bytes() == before_record

    # Retained inputs cannot claim a dependency, feature or widget is installed.
    config.write_text(auth + ''.join(f'[apps.{app}]\n' for app in rows))
    record.write_text('{}\n')
    before_config, before_record = config.read_bytes(), record.read_bytes()
    result = hook("notepad")
    assert result.returncode != 0 and "requires the installed publish app" in result.stderr, (result.stdout, result.stderr)
    result = hook("devterm")
    assert result.returncode == 0 and "fileview=false, orca=false" in result.stderr, (result.stdout, result.stderr)
    result = panel()
    assert result.returncode == 0 and result.stdout == "", (result.stdout, result.stderr)
    assert config.read_bytes() == before_config and record.read_bytes() == before_record

    # Standalone smoke reads installed source identity, not candidate inputs or
    # an ambient current-hook source. Its frontend request is fixture-only.
    curl = base / "shim/curl"
    curl.write_text('#!/bin/sh\nprintf 200\n')
    curl.chmod(0o755)
    for name in ("recorded-smoke", "candidate-smoke"):
        directory = base / name
        directory.mkdir()
        (directory / "airlock-app.toml").write_text(
            'contract=1\nid="smoke-probe"\n[config.defaults]\nbackend_port=18970\n')
        (directory / "smoke.sh").write_text(
            '#!/bin/sh\nprintf "%s\\n" ' + name + ' >> "' + str(base / "smoke-invocations") + '"\n')
    configured = auth + '[packages.smoke-probe]\npath=' + json.dumps(str(base / 'candidate-smoke')) + '\n'
    config.write_text(configured)
    record.write_text(json.dumps({'smoke-probe': {'repo': str(base / 'recorded-smoke'),
                                                'commit': '', 'artifacts': []}}))
    before_config, before_record = config.read_bytes(), record.read_bytes()
    result = run('bash', str(ROOT / 'bin/airlock-smoke'), extra={
        'AIRLOCK_DRY_RUN': '0', 'AIRLOCK_APP_ID': 'smoke-probe',
        'AIRLOCK_APP_DIR': str(base / 'candidate-smoke')})
    assert result.returncode == 0, (result.stdout, result.stderr)
    calls = base / 'smoke-invocations'
    assert calls.read_text() == 'recorded-smoke\n', calls.read_text()
    assert config.read_bytes() == before_config and record.read_bytes() == before_record
    # A disappeared recorded source cannot be replaced by a same-id candidate.
    shutil.rmtree(base / 'recorded-smoke')
    result = run('bash', str(ROOT / 'bin/airlock-smoke'), extra={'AIRLOCK_DRY_RUN': '0'})
    assert result.returncode != 0 and 'recorded source directory is missing' in result.stderr, (result.stdout, result.stderr)
    assert calls.read_text() == 'recorded-smoke\n'
    assert config.read_bytes() == before_config and record.read_bytes() == before_record
    for command in (('env', 'smoke-probe'), ('get', 'apps.smoke-probe.backend_port')):
        probe = run(str(ROOT / 'bin/airlock-config'), *command)
        assert probe.returncode != 0 and 'recorded-smoke' in probe.stderr, (command, probe.stdout, probe.stderr)
        assert 'candidate-smoke' not in probe.stdout
    probe = run(str(ROOT / 'bin/airlock-config'), 'package-info')
    assert probe.returncode == 0 and 'smoke-probe' not in json.loads(probe.stdout)['packages'], (probe.stdout, probe.stderr)
    probe = run(str(ROOT / 'bin/airlock-config'), 'json')
    assert probe.returncode == 0 and 'smoke-probe' not in json.loads(probe.stdout)['apps'], (probe.stdout, probe.stderr)
    # An explicit current apply source can still supply its own manifest.
    probe = run(str(ROOT / 'bin/airlock-config'), 'env', 'smoke-probe', extra={
        'AIRLOCK_APP_ID': 'smoke-probe', 'AIRLOCK_APP_DIR': str(base / 'candidate-smoke')})
    assert probe.returncode == 0, (probe.stdout, probe.stderr)
    # Remote rows use the engine installation directory, never a config candidate.
    record.write_text(json.dumps({'smoke-probe': {'repo': 'https://example.invalid/company.git',
                                                'commit': 'a' * 40, 'artifacts': []}}))
    before_record = record.read_bytes()
    result = run('bash', str(ROOT / 'bin/airlock-smoke'), extra={'AIRLOCK_DRY_RUN': '0'})
    assert result.returncode != 0 and 'smoke-probe' in result.stderr, (result.stdout, result.stderr)
    assert calls.read_text() == 'recorded-smoke\n'
    assert config.read_bytes() == before_config and record.read_bytes() == before_record
    record.write_text('{}\n')
    config.write_text(configured + '[apps.smoke-probe]\n')
    before_config = config.read_bytes()
    result = run('bash', str(ROOT / 'bin/airlock-smoke'), extra={'AIRLOCK_DRY_RUN': '0'})
    assert result.returncode == 0 and 'no installed app smokes ran' in result.stderr, (result.stdout, result.stderr)
    assert calls.read_text() == 'recorded-smoke\n' and record.read_text() == '{}\n'
    record.unlink()
    result = run('bash', str(ROOT / 'bin/airlock-smoke'), extra={'AIRLOCK_DRY_RUN': '0'})
    assert result.returncode == 0 and calls.read_text() == 'recorded-smoke\n', (result.stdout, result.stderr)
    assert not record.exists() and config.read_bytes() == before_config

    # First bootstrap dry uses REAL certified Public sources but never runs
    # their runtime hooks against prospective installation membership.
    config.write_text(auth + '[apps.notepad]\n[apps.publish]\n')
    before_config = config.read_bytes()
    def files():
        return {str(path.relative_to(base)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in base.rglob('*') if path.is_file()}
    before_files = files()
    result = run('bash', str(ROOT / 'install/airlock-install.sh'))
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert 'would install packaged app: publish' in result.stderr
    assert 'would install packaged app: notepad' in result.stderr
    assert '(shipped app — dry run executes)' not in result.stderr
    assert not record.exists() and config.read_bytes() == before_config and files() == before_files

    # A Public notepad already installed depends on an installed Personal
    # publish source. The existing-box preview executes its certified hook.
    publish_source = base / 'installed-publish-source'
    shutil.copytree(ROOT / 'apps/publish', publish_source)
    rows = {'publish': {'repo': str(publish_source), 'commit': '', 'artifacts': []},
            'notepad': {'repo': str(ROOT / 'apps/notepad'), 'commit': '', 'artifacts': []}}
    record.write_text(json.dumps(rows))
    config.write_text(auth)
    before_config, before_record, before_files = config.read_bytes(), record.read_bytes(), files()
    result = run('bash', str(ROOT / 'install/airlock-install.sh'))
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert 'installing packaged app: notepad' in result.stderr and '(shipped app — dry run executes)' in result.stderr
    assert 'notepad installed (owner:' in result.stderr
    assert config.read_bytes() == before_config and record.read_bytes() == before_record and files() == before_files
    record.unlink()

    # The existing manifest dependency orders a first bootstrap; no extra apply.
    config.write_text(auth + '[apps.notepad]\n[apps.publish]\n')
    result = run("python3", str(ROOT / "bin/airlock-config"), "package-info")
    assert result.returncode == 0, (result.stdout, result.stderr)
    order = json.loads(result.stdout)["order"]
    assert order.index("publish") < order.index("notepad"), order

print("PASS real dry hooks and widget: installed without inputs, retained inputs without installation, bootstrap dependency")

PY_HOOK_MEMBERSHIP
then
  ok "hook membership uses recorded installation and source identity"
else
  bad "hook membership consumer regression"
fi

# Recorded membership/source consumer regressions (existing suite).
if python3 - "$ROOT" <<'PY_SOURCE_MEMBERSHIP'
#!/usr/bin/env python3
"""Recorded source identity survives missing paths and changed Company inputs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

import sys
ROOT = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='airlock-source-membership-') as scratch:
    base = Path(scratch)
    for name in ('home', 'state', 'data', 'web', 'confd', 'units-user', 'units-system', 'shim'):
        (base / name).mkdir()
    env = {k: v for k, v in os.environ.items() if not k.startswith('AIRLOCK_')}
    env.update(HOME=str(base / 'home'), AIRLOCK_ROOT=str(ROOT),
               AIRLOCK_CONFIG=str(base / 'airlock.toml'), AIRLOCK_FIXTURE_ROOT=str(base),
               AIRLOCK_STATE_DIR=str(base / 'state'), AIRLOCK_DATA_DIR=str(base / 'data'),
               AIRLOCK_WEBROOT=str(base / 'web'), AIRLOCK_CONFD=str(base / 'confd'),
               AIRLOCK_NGINX_SITE=str(base / 'site.conf'),
               AIRLOCK_UNIT_DIR_USER=str(base / 'units-user'), AIRLOCK_UNIT_DIR_SYSTEM=str(base / 'units-system'),
               AIRLOCK_TS_FQDN='box.example.ts.net', PATH=str(base / 'shim') + ':' + env['PATH'])
    for name in ('systemctl', 'nginx', 'tailscale'):
        p = base / 'shim' / name
        p.write_text('#!/bin/sh\nexit 0\n'); p.chmod(0o755)
    sudo = base / 'shim/sudo'
    sudo.write_text('#!/bin/sh\nwhile [ \"$1\" = -n ]; do shift; done\nexec \"$@\"\n'); sudo.chmod(0o755)
    config = base / 'airlock.toml'
    record = base / 'state/installed-apps.json'
    def run(*args, ok=True):
        result = subprocess.run(args, env=env, text=True, capture_output=True, timeout=90)
        if ok:
            assert result.returncode == 0, (args, result.stdout, result.stderr)
        return result
    def app(directory, app_id, marker):
        directory.mkdir(parents=True)
        (directory / 'airlock-app.toml').write_text(
            f'contract=1\nid="{app_id}"\n[config.defaults]\nbackend_port=18980\n[artifacts]\nwebroot=["{app_id}/"]\nserve_ports=["backend_port"]\n')
        (directory / 'install.sh').write_text(
            '#!/bin/sh\nmkdir -p "$AIRLOCK_WEBROOT/$AIRLOCK_APP_ID"\n'
            f'printf %s {marker} > "$AIRLOCK_WEBROOT/$AIRLOCK_APP_ID/marker"\n')
        (directory / 'smoke.sh').write_text('#!/bin/sh\nexit 0\n')
    def cfg(company=''):
        config.write_text('[auth]\nprovider="tailscale"\nowner="fixture@test"\n[site]\ncompany_repo=' + json.dumps(company)
                          + '\n[apps.hub]\n[packages.source-probe]\npath=' + json.dumps(str(base / 'candidate')) + '\n')
    def ledger(*args, ok=True):
        return run(str(ROOT / 'bin/airlock-ledger'), *args, ok=ok)
    def row(repo, commit=''):
        record.write_text(json.dumps({'source-probe': {'repo': repo, 'commit': commit, 'artifacts': []}}))
    app(base / 'original', 'source-probe', 'A')
    app(base / 'candidate', 'source-probe', 'B')
    app(base / 'other', 'other-probe', 'other')
    cfg()
    row(str(base / 'original'))
    shutil.rmtree(base / 'original')
    before_config, before_record = config.read_bytes(), record.read_bytes()
    result = ledger('apply', 'source-probe', ok=False)
    assert result.returncode != 0 and 'recorded source for source-probe is missing' in result.stderr, (result.stdout, result.stderr)
    assert not (base / 'web/source-probe').exists() and record.read_bytes() == before_record
    ledger('apply', 'other-probe', '--source', str(base / 'other'))
    assert (base / 'web/other-probe/marker').read_text() == 'other'
    ledger('remove', 'source-probe')
    assert 'source-probe' not in json.loads(record.read_text())
    row(str(base / 'original'))
    config.write_text(config.read_text() + '[apps.source-probe]\nbackend_port="wrong"\n')
    result = ledger('apply', 'source-probe', '--source', str(base / 'candidate'), ok=False)
    assert result.returncode != 0, (result.stdout, result.stderr)
    assert json.loads(record.read_text())['source-probe']['repo'] == str(base / 'original')
    config.write_bytes(before_config)
    ledger('apply', 'source-probe', '--source', str(base / 'candidate'))
    assert (base / 'web/source-probe/marker').read_text() == 'B'
    assert json.loads(record.read_text())['source-probe']['repo'] == str(base / 'candidate')
    assert config.read_bytes() == before_config

    # Both real repositories have the same id; ⑤ points at B while ③ points at A.
    commits = {}
    for name in ('company-a', 'company-b'):
        repo = base / name
        app(repo / 'apps/source-probe', 'source-probe', name)
        run('git', 'init', '-q', '-b', 'main', str(repo))
        run('git', '-C', str(repo), 'add', 'apps')
        run('git', '-C', str(repo), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@test', 'commit', '-qm', 'initial')
        commits[name] = run('git', '-C', str(repo), 'rev-parse', 'HEAD').stdout.strip()
    a_url, b_url = (base / 'company-a').as_uri(), (base / 'company-b').as_uri()
    # Two real Git fetches interleave: B legitimately overwrites FETCH_HEAD
    # after A's fetch but before A resolves its SHA. URL identity must survive.
    from importlib.machinery import SourceFileLoader
    sys.dont_write_bytecode = True
    old_data = os.environ.get('AIRLOCK_DATA_DIR')
    old_fixture = os.environ.get('AIRLOCK_FIXTURE_ROOT')
    os.environ['AIRLOCK_DATA_DIR'] = str(base / 'interleaving-data')
    os.environ['AIRLOCK_FIXTURE_ROOT'] = str(base)
    pin = SourceFileLoader('source_pin_fixture', str(ROOT / 'bin/airlock-ledger')).load_module()
    original_git = pin._git
    fetched_b = False
    def interleaved_git(args, *rest):
        global fetched_b
        if 'rev-parse' in args and not fetched_b:
            fetched_b = True
            run('git', '-C', str(pin.company_mirror_path()), 'fetch', '--quiet', b_url, 'main')
        return original_git(args, *rest)
    pin._git = interleaved_git
    try:
        a_sha = pin.pin_main({'company_repo': a_url})
        assert fetched_b and a_sha == commits['company-a'], (a_sha, commits)
        fetched_head = run('git', '-C', str(pin.company_mirror_path()), 'rev-parse', 'FETCH_HEAD').stdout.strip()
        assert fetched_head == commits['company-b'], fetched_head  # positive control
        marker = run('git', '-C', str(pin.company_mirror_path()), 'show', a_sha + ':apps/source-probe/install.sh').stdout
        assert 'company-a' in marker and 'company-b' not in marker, marker
        # Real simultaneous fetches both finish before either SHA read. Each
        # worker must still receive the commit for its own URL.
        from concurrent.futures import ThreadPoolExecutor
        from threading import Barrier
        ready = Barrier(2)
        def concurrent_git(args, *rest):
            if 'rev-parse' in args:
                ready.wait(timeout=30)
            return original_git(args, *rest)
        pin._git = concurrent_git
        with ThreadPoolExecutor(max_workers=2) as workers:
            a_result = workers.submit(pin.pin_main, {'company_repo': a_url})
            b_result = workers.submit(pin.pin_main, {'company_repo': b_url})
            assert a_result.result() == commits['company-a']
            assert b_result.result() == commits['company-b']
        print('PASS real interleaving and concurrent Git fetches preserve each URL SHA')
    finally:
        pin._git = original_git
        if old_data is None:
            os.environ.pop('AIRLOCK_DATA_DIR', None)
        else:
            os.environ['AIRLOCK_DATA_DIR'] = old_data
        if old_fixture is None:
            os.environ.pop('AIRLOCK_FIXTURE_ROOT', None)
        else:
            os.environ['AIRLOCK_FIXTURE_ROOT'] = old_fixture
    cfg(b_url)
    row(a_url, commits['company-a'])
    before_config = config.read_bytes()
    assert 'reinstall\tsource-probe' in ledger('plan').stdout
    a = base / 'company-a'
    (a / 'apps/source-probe/install.sh').write_text(
        '#!/bin/sh\nmkdir -p "$AIRLOCK_WEBROOT/$AIRLOCK_APP_ID"\nprintf A-updated > "$AIRLOCK_WEBROOT/$AIRLOCK_APP_ID/marker"\n')
    run('git', '-C', str(a), 'add', 'apps')
    run('git', '-C', str(a), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@test', 'commit', '-qm', 'update A')
    assert 'upgrade-diff\tsource-probe' in ledger('plan').stdout
    ledger('apply', 'source-probe')
    assert (base / 'web/source-probe/marker').read_text() == 'A-updated'
    assert json.loads(record.read_text())['source-probe']['repo'] == a_url
    ledger('apply', 'source-probe', '--source', 'company')
    assert (base / 'web/source-probe/marker').read_text() == 'company-b'
    assert json.loads(record.read_text())['source-probe']['repo'] == b_url
    assert config.read_bytes() == before_config
print('PASS missing recorded local source, unrelated apply, recorded remove, explicit replace, remote recorded repo apply/plan')

PY_SOURCE_MEMBERSHIP
then
  ok "source membership uses recorded installation and source identity"
else
  bad "source membership consumer regression"
fi

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
