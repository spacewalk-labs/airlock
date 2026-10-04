#!/usr/bin/env bash
# install/test-manifest.sh — executable fixtures for the child-3
# manifest/lifecycle contract (D2/D3/D6/F4/F5/F10/F11/F12/F14).
#
# Every package fixture is staged below $TMP, never under the repository's
# apps/ tree. The real config, ledger, preflight, and nginx entry points run
# against scratch roots and small command shims.
set -uo pipefail
. "$(dirname "$0")/test-lib.sh"
airlock_pin_paseo_mem

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)" || { echo "FAIL could not create test directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
airlock_set_fixture_root "$TMP"
airlock_neutral_selfkill_cgroup "$TMP"

airlock_test_counters_init

CFG="$ROOT/bin/airlock-config"
LEDGER="$ROOT/bin/airlock-ledger"

# ---- scratch roots -----------------------------------------------------------
STATE="$TMP/state"; WEB="$TMP/web"; CONFD="$TMP/confd"
UU="$TMP/units-user"; US="$TMP/units-system"
FAKEHOME="$TMP/home"; DATA="$TMP/data"
PKGROOT="$TMP/packages"; CFGROOT="$TMP/configs"
mkdir -p "$PKGROOT" "$CFGROOT"
export AIRLOCK_STATE_DIR="$STATE" AIRLOCK_WEBROOT="$WEB" AIRLOCK_CONFD="$CONFD"
export AIRLOCK_UNIT_DIR_USER="$UU" AIRLOCK_UNIT_DIR_SYSTEM="$US"
export AIRLOCK_TS_FQDN="box.example.ts.net"
export AIRLOCK_TEST_TMP="$TMP"
export AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf"
export HOME="$FAKEHOME"

reset_box() {
  rm -rf "$STATE" "$WEB" "$CONFD" "$UU" "$US" "$FAKEHOME" "$DATA"
  mkdir -p "$WEB/assets" "$CONFD/hub-locations.d" "$CONFD/servers.d" \
           "$UU" "$US" "$FAKEHOME" "$DATA"
  : >"$TMP/systemctl.log"
  : >"$TMP/tailscale.log"
}

# ---- shims -------------------------------------------------------------------
SHIM="$TMP/shim"
mkdir -p "$SHIM"
cat >"$SHIM/sudo" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac
done
exec "$@"
STUB
cat >"$SHIM/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AIRLOCK_TEST_TMP/systemctl.log"
case "$*" in *list-timers*) printf '%s\n' 'Mon 2026-09-02 00:00:00 KST 1d left airlock-update-detect.timer airlock-update-detect.service' ;; esac
# The platform account surface is a SERVICE, so its installer asks systemd whether it is
# running rather than whether a timer is scheduled ("installed" and "active" are
# different claims and only one serves a request). Answer it, for the same reason
# list-timers above is answered: an unanswered verb reads as a dead unit and the
# installer dies.
case "$*" in *is-active*) printf '%s\n' active ;; esac
exit 0
STUB
cat >"$SHIM/tailscale" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"BackendState":"Running","CertDomains":["example.ts.net"],"Self":{"DNSName":"box.example.ts.net."},"Health":[]}\n'
  exit 0
fi
if [ "${1:-}" = serve ] && [ "${2:-}" = status ]; then
  printf '{"TCP":{}}\n'
  exit 0
fi
printf '%s\n' "$*" >> "$AIRLOCK_TEST_TMP/tailscale.log"
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
chmod +x "$SHIM"/*
PATH="$SHIM:$PATH"
export PATH

# ---- helpers -----------------------------------------------------------------
# Keep this helper identical to install/test-packages.sh.
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

ledger_run() {
  local info="$1"
  shift
  printf '%s' "$info" | "$LEDGER" "$@"
}

base_config() {
  printf '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n[apps.hub]\n'
}

make_pkg_cfg() {
  local path="$1" pid="$2" pkg="$3" app_body="${4:-}"
  {
    base_config
    printf '[apps.%s]\n' "$pid"
    [ -z "$app_body" ] || printf '%s\n' "$app_body"
    printf '[packages.%s]\npath = "%s"\n' "$pid" "$pkg"
  } >"$path"
  seed_apps "$pid" "$pkg"
}

mkpkg() {
  local dir="$1" id="$2"
  mkdir -p "$dir"
  cat >"$dir/airlock-app.toml" <<EOF
contract = 1
id = "$id"
EOF
  cat >"$dir/install.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$dir/smoke.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$dir/deactivate.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$dir"/*.sh
}

pkg_manifest() {
  local dir="$1"
  shift
  printf '%s\n' "$@" >"$dir/airlock-app.toml"
}

failure_detail() {
  local out="$1"
  printf '%s\n' "$out" | sed 's/^/    /' | tail -n 8
}

expect_fail() {
  local label="$1" fragment="$2" out rc=0
  shift 2
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && grep -Fq -- "$fragment" <<<"$out"; then
    ok "$label"
  else
    bad "$label (expected failure/message; rc=$rc)"
    failure_detail "$out"
  fi
}

expect_fail_code() {
  local label="$1" want_rc="$2" fragment="$3" out rc=0
  shift 3
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" = "$want_rc" ] && grep -Fq -- "$fragment" <<<"$out"; then
    ok "$label"
  else
    bad "$label (expected rc=$want_rc/message; rc=$rc)"
    failure_detail "$out"
  fi
}

expect_warn() {
  local label="$1" fragment="$2" out rc=0
  shift 2
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" = 0 ] && grep -Fq -- "$fragment" <<<"$out"; then
    ok "$label"
  else
    bad "$label (expected rc 0 + warning; rc=$rc)"
    failure_detail "$out"
  fi
}

expect_ok() {
  local label="$1" out rc=0
  shift
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" = 0 ]; then
    ok "$label"
  else
    bad "$label (rc=$rc)"
    failure_detail "$out"
  fi
}

# =============================================================================
# A. manifest schema (F10/F2/D2)
# =============================================================================

reset_box
pkg="$PKGROOT/a7b-deprecated"; mkpkg "$pkg" a7b
pkg_manifest "$pkg" 'contract = 1' 'id = "a7b"' \
  '[config.defaults]' 'old_key = ""' 'new_key = ""' \
  '[config.deprecated.old_key]' 'replacement = "new_key"' 'remove_after = "2026-09-07"'
cfg="$CFGROOT/a7b.toml"; make_pkg_cfg "$cfg" a7b "$pkg" 'old_key = "legacy"'
out="$(run "$cfg" validate 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c 'apps.a7b.old_key is deprecated' <<<"$out" || true)" = 1 ] \
    && grep -q 'apps.a7b.new_key' <<<"$out" && grep -q '2026-09-07' <<<"$out"; then
  ok "A7b manifest deprecation metadata emits one data-driven warning"
else
  bad "A7b manifest deprecation metadata emits one data-driven warning"
fi

reset_box
pkg="$PKGROOT/a23-full"; mkpkg "$pkg" full
touch "$pkg/full.svg"
pkg_manifest "$pkg" \
  'contract = 1' \
  'id = "full"' \
  '[dependencies]' \
  'apps = ["publish"]' \
  '[config]' \
  '[[config.required]]' \
  'name = "required_text"' \
  'type = "string"' \
  '[config.defaults]' \
  'default_num = 7' \
  'base_port = 19000' \
  'span_count = 2' \
  'serve_port = 19010' \
  '[config.tables.options]' \
  'allowed_keys = ["leaf"]' \
  '[[config.port_spans]]' \
  'base = "base_port"' \
  'count = "span_count"' \
  '[[prerequisites]]' \
  'command = "fullcmd"' \
  'predicate = "present"' \
  'expected = "-"' \
  'fix = "install fullcmd"' \
  'note = "full package"' \
  '[artifacts]' \
  'units = ["full.service"]' \
  'fragments = ["full.conf"]' \
  'webroot = ["full/"]' \
  'files = ["~/full.state"]' \
  'serve_ports = ["serve_port"]' \
  '[tile]' \
  'label = "Full"' \
  'sub = "Complete"' \
  'cat = "docs"' \
  'glyph = "app-default"' \
  '[audience]' \
  'supported = ["shared", "owner"]' \
  'default = "shared"'
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
airlock_config get apps.full.required_text >/dev/null
airlock_config get apps.full.default_num >/dev/null
base_port="$(airlock_config get apps.full.base_port)"
span_count="$(airlock_config get apps.full.span_count)"
serve_port="$(airlock_config get apps.full.serve_port)"
test "$base_port" -gt 0
test "$span_count" -gt 0
test "$serve_port" -gt 0
airlock_config get apps.full.options.leaf >/dev/null
EOF
chmod +x "$pkg/install.sh"
cat >"$pkg/smoke.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$pkg/smoke.sh"
cfg="$CFGROOT/a23.toml"
{
  base_config
  printf '[apps.publish]\n[apps.full]\nrequired_text = "hello"\n[apps.full.options]\nleaf = "value"\n'
  printf '[packages.full]\npath = "%s"\n' "$pkg"
} >"$cfg"
seed_apps full "$pkg"
full_validate_out="$(run "$cfg" validate 2>&1)"; full_validate_rc=$?
full_info="$(run "$cfg" package-info 2>/dev/null)"; full_info_rc=$?
full_roundtrip=0
if [ "$full_info_rc" = 0 ]; then
  printf '%s' "$full_info" | python3 -c '
import json, sys
d = json.load(sys.stdin)["packages"]["full"]
assert d["contract"] == 1
assert d["deps"] == ["publish"]
assert d["schema"]["required"]["required_text"] == "string"
assert d["schema"]["defaults"] == {
    "default_num": 7, "base_port": 19000, "span_count": 2, "serve_port": 19010
}
assert d["schema"]["tables"] == {"options": ["leaf"]}
assert d["schema"]["port_spans"] == [{"base":"base_port", "count":"span_count"}]
assert d["prerequisites"] == [{
    "command": "fullcmd", "predicate": "present", "expected": "-",
    "fix": "install fullcmd", "note": "full package"
}]
assert d["artifacts"] == {
    "units": ["full.service"], "fragments": ["full.conf"],
    "webroot": ["full/"], "files": ["~/full.state"],
    "rooted": [], "containers": [],
    "serve_ports": ["serve_port"]
}
assert d["unit_scopes"] == {"full.service": "user"}
assert d["source_class"] == "explicit"
assert d["tile"] == {
    "label": "Full", "sub": "Complete", "cat": "docs",
    "path": None, "icon": None, "glyph": "app-default"
}
assert d["audience"] == {"supported": ["shared", "owner"], "default": "shared"}
' >/dev/null 2>&1 && full_roundtrip=1
fi
if [ "$full_validate_rc" = 0 ] && [ "$full_roundtrip" = 1 ]; then
  ok "A23 full manifest validates and package-info round-trips every field"
else
  bad "A23 full manifest validation/package-info round trip (rc=$full_validate_rc info=$full_info_rc)"
  failure_detail "$full_validate_out"
fi

# =============================================================================
# B. effective schema / typing
# =============================================================================

reset_box
pkg="$PKGROOT/b29-audience"; mkpkg "$pkg" b29
pkg_manifest "$pkg" 'contract = 1' 'id = "b29"' '[audience]' 'supported = ["shared", "owner"]' 'default = "owner"'
cfg="$CFGROOT/b29.toml"; make_pkg_cfg "$cfg" b29 "$pkg"
env_audience="$(run "$cfg" env b29 2>&1)"; rc_env=$?
if [ "$rc_env" = 0 ] && grep -Fq "AUDIENCE=owner" <<<"$env_audience"; then
  ok "B29 audience exports the manifest's effective default"
else
  bad "B29 audience effective default"
  failure_detail "$env_audience"
fi

# =============================================================================
# C. ordering (F5/D3)
# =============================================================================

reset_box
cfg="$CFGROOT/c30-builtins.toml"
{
  base_config
  printf '[apps.paseo]\n[apps.publish]\n[apps.notepad]\n'
} >"$cfg"
expected_apps=$'hub\npaseo\npublish\nnotepad'
actual_apps="$(run "$cfg" apps 2>/dev/null)"; rc_apps=$?
if [ "$rc_apps" = 0 ] && [ "$actual_apps" = "$expected_apps" ]; then
  ok "C30 built-in apps preserve TOML input order byte-for-byte"
else
  bad "C30 built-in app order"
  printf '%s\n' "$actual_apps" | sed 's/^/    /'
fi

reset_box
pkg="$PKGROOT/c31-alpha"; mkpkg "$pkg" alpha
pkg_manifest "$pkg" 'contract = 1' 'id = "alpha"' '[dependencies]' 'apps = ["publish"]'
cfg="$CFGROOT/c31.toml"
{
  base_config
  printf '[apps.publish]\n[apps.alpha]\n[packages.alpha]\npath = "%s"\n' "$pkg"
} >"$cfg"
seed_apps alpha "$pkg"
expected_apps=$'hub\npublish\nalpha'
actual_apps="$(run "$cfg" apps 2>/dev/null)"; rc_apps=$?
validate_out="$(run "$cfg" validate 2>&1)"; rc_validate=$?
if [ "$rc_validate" = 0 ] && [ "$rc_apps" = 0 ] && [ "$actual_apps" = "$expected_apps" ]; then
  ok "C31 dependency-compatible package order validates and stays in input order"
else
  bad "C31 package order with publish dependency"
  failure_detail "$validate_out"
fi

# C32 (child 4/P3, D3 demotion): a manifest edge that DISAGREES with the
# [apps.*] input order used to be fatal — the synthetic input-order chain
# made the union cyclic. That chain is gone (D3 demotion: Kahn over real
# manifest edges only, ties broken by input order) — a real edge simply
# reorders the box; a previously-invalid config is now ordered, deliberately.
reset_box
pkg="$PKGROOT/c32-alpha"; mkpkg "$pkg" alpha32
pkg_manifest "$pkg" 'contract = 1' 'id = "alpha32"' '[dependencies]' 'apps = ["publish"]'
cfg="$CFGROOT/c32.toml"
{
  base_config
  printf '[apps.alpha32]\n[apps.publish]\n[packages.alpha32]\npath = "%s"\n' "$pkg"
} >"$cfg"
seed_apps alpha32 "$pkg"
expected_apps=$'hub\npublish\nalpha32'
actual_apps="$(run "$cfg" apps 2>/dev/null)"; rc_apps=$?
validate_out="$(run "$cfg" validate 2>&1)"; rc_validate=$?
if [ "$rc_validate" = 0 ] && [ "$rc_apps" = 0 ] && [ "$actual_apps" = "$expected_apps" ]; then
  ok "C32 a real dependency edge against [apps.*] input order reorders (D3 demotion), no longer a cycle"
else
  bad "C32 D3-demotion reorder"
  failure_detail "$validate_out"
  printf '%s\n' "$actual_apps" | sed 's/^/    /'
fi

# C32b/C32c (child 4/P3): notepad's REAL manifest now declares
# [dependencies].apps = ["publish"] (apps/notepad/airlock-app.toml — added
# this same commit, per the plan's "D3 demotion + notepad edge"). These use
# the real shipped tree (AIRLOCK_SHIPPED_APPS_ROOT is not overridden in this
# file, so package_specs resolves apps/notepad and apps/publish for real,
# no [packages.*] line needed) — the fixture that matters is the actual
# shipped manifest, not a stand-in. TOML lists notepad BEFORE publish
# (install/test-equivalence.sh's adversarial ordering, C30's context: "boxes
# may list notepad first") specifically to prove the edge — not TOML
# position — decides the order.
reset_box
cfg="$CFGROOT/c32b-real-notepad.toml"
{
  base_config
  printf '[apps.notepad]\n[apps.publish]\n'
} >"$cfg"
expected_apps=$'hub\npublish\nnotepad'
actual_apps="$(run "$cfg" apps 2>/dev/null)"; rc_apps=$?
validate_out="$(run "$cfg" validate 2>&1)"; rc_validate=$?
if [ "$rc_validate" = 0 ] && [ "$rc_apps" = 0 ] && [ "$actual_apps" = "$expected_apps" ]; then
  ok "C32b real notepad->publish edge installs publish before notepad, despite TOML listing notepad first"
else
  bad "C32b real notepad/publish install order"
  failure_detail "$validate_out"
  printf '%s\n' "$actual_apps" | sed 's/^/    /'
fi

reset_box
pub="$PKGROOT/c34-publish"; mkpkg "$pub" publish
alpha="$PKGROOT/c34-alpha"; mkpkg "$alpha" alpha34
pkg_manifest "$pub" 'contract = 1' 'id = "publish"'
pkg_manifest "$alpha" 'contract = 1' 'id = "alpha34"' '[dependencies]' 'apps = ["publish"]'
cfg="$CFGROOT/c34.toml"
{
  base_config
  printf '[apps.publish]\n[apps.alpha34]\n[packages.publish]\npath = "%s"\n[packages.alpha34]\npath = "%s"\n' "$pub" "$alpha"
} >"$cfg"
seed_apps publish "$pub" alpha34 "$alpha"
c34_validate="$(run "$cfg" validate 2>&1)"; rc_c34_validate=$?
c34_apps="$(run "$cfg" apps 2>/dev/null)"; rc_c34_apps=$?
if [ "$rc_c34_validate" = 0 ] && [ "$rc_c34_apps" = 0 ] \
    && [ "$c34_apps" = $'hub\npublish\nalpha34' ]; then
  ok "C34 dependency on publish accepts a shadowing publish package"
else
  bad "C34 shadowing publish dependency behavior (validate=$rc_c34_validate apps=$rc_c34_apps)"
  failure_detail "$c34_validate"
  printf '%s\n' "$c34_apps" | sed 's/^/    /'
fi

reset_box
pkg="$PKGROOT/c35-alpha"; mkpkg "$pkg" alpha35
pkg_manifest "$pkg" 'contract = 1' 'id = "alpha35"' '[dependencies]' 'apps = ["publish"]'
cfg="$CFGROOT/c35.toml"
{
  base_config
  printf '[apps.publish]\n[apps.alpha35]\n[packages.alpha35]\npath = "%s"\n' "$pkg"
} >"$cfg"
seed_apps alpha35 "$pkg"
info="$(run "$cfg" package-info 2>/dev/null)"; rc_info=$?
order_ok=0
if [ "$rc_info" = 0 ]; then
  printf '%s' "$info" | python3 -c 'import json,sys; assert json.load(sys.stdin)["order"] == ["hub","publish","alpha35"]' >/dev/null 2>&1 && order_ok=1
fi
if [ "$order_ok" = 1 ]; then
  ok "C35 package-info carries the resolved app order"
else
  bad "C35 package-info order"
  printf '%s\n' "$info" | sed 's/^/    /'
fi

# =============================================================================
# E. F11 prerequisites
# =============================================================================

reset_box
pkg="$PKGROOT/e44-zero-prereq"; mkpkg "$pkg" e44
cfg="$CFGROOT/e44.toml"; make_pkg_cfg "$cfg" e44 "$pkg"
raw_rows="$(awk '$1 !~ /^#/ && NF {print}' "$ROOT/install/prerequisites.tsv")"
actual_rows="$(run "$cfg" prereqs 2>/dev/null)"; rc_prereqs=$?
if [ "$rc_prereqs" = 0 ] && [ "$actual_rows" = "$raw_rows" ]; then
  ok "E44 zero-prereq package preserves raw TSV data rows"
else
  bad "E44 prerequisite pass-through (rc=$rc_prereqs)"
  printf '%s\n' "$actual_rows" | sed 's/^/    /'
fi

reset_box
pkg="$PKGROOT/e45-shadow-publish"; mkpkg "$pkg" publish
cfg="$CFGROOT/e45.toml"; make_pkg_cfg "$cfg" publish "$pkg"
shadow_rows="$(run "$cfg" prereqs 2>/dev/null)"; rc_shadow=$?
raw_nonpublish=$(awk '$1 !~ /^#/ && NF && $1 != "publish"' "$ROOT/install/prerequisites.tsv" | wc -l)
if [ "$rc_shadow" = 0 ] && ! grep -q '^publish[[:space:]]' <<<"$shadow_rows" \
   && [ "$(printf '%s\n' "$shadow_rows" | sed '/^$/d' | wc -l)" = "$raw_nonpublish" ]; then
  ok "E45 shadowing publish replaces all publish prerequisite rows"
else
  bad "E45 shadowing publish prerequisite rows"
  printf '%s\n' "$shadow_rows" | sed 's/^/    /'
fi

reset_box
pkg="$PKGROOT/e46-two-prereqs"; mkpkg "$pkg" e46
pkg_manifest "$pkg" \
  'contract = 1' \
  'id = "e46"' \
  '[[prerequisites]]' \
  'command = "one"' \
  'predicate = "present"' \
  'expected = "-"' \
  'fix = "fix one"' \
  'note = "first"' \
  '[[prerequisites]]' \
  'command = "two"' \
  'predicate = "present"' \
  'expected = "-"' \
  'fix = "fix two"' \
  'note = "second"'
cfg="$CFGROOT/e46.toml"; make_pkg_cfg "$cfg" e46 "$pkg"
rows46="$(run "$cfg" prereqs 2>/dev/null)"; rc46=$?
expected46=$'e46\tone\tpresent\t-\tfix one\tfirst\ne46\ttwo\tpresent\t-\tfix two\tsecond'
actual46="$(grep -F $'e46\t' <<<"$rows46" || true)"
if [ "$rc46" = 0 ] && [ "$actual46" = "$expected46" ]; then
  ok "E46 two manifest prerequisite rows append with six owner columns"
else
  bad "E46 manifest prerequisite cardinality/shape"
  printf '%s\n' "$actual46" | sed 's/^/    /'
fi

preflight_pkg() {
  local config="$1" tsv="$2" pkg_info="$3"
  HOME="$FAKEHOME" PATH="$PATH" AIRLOCK_CONFIG="$config" \
    AIRLOCK_PKG_INFO="$pkg_info" /bin/bash -c \
      '. "$1/install/lib.sh"; AIRLOCK_PREREQUISITES="$2"; airlock_preflight --quiet' \
      _ "$ROOT" "$tsv"
}

reset_box
pkg="$PKGROOT/e49-publish-shadow"; mkpkg "$pkg" publish
cfg="$CFGROOT/e49.toml"; make_pkg_cfg "$cfg" publish "$pkg"
info="$(run "$cfg" package-info 2>/dev/null)" \
  || { bad "E49 package-info failed"; info=""; }
preflight_shadow="$(preflight_pkg "$cfg" "$ROOT/install/prerequisites.tsv" "$info" 2>&1)"; rc_shadow_preflight=$?
if [ "$rc_shadow_preflight" = 0 ] \
   && [[ "$preflight_shadow" != *"enabled app has no prerequisite declaration"* ]]; then
  ok "E49 packaged owners and zero-prereq publish shadow pass preflight"
else
  bad "E49 packaged owner/preflight rule (rc=$rc_shadow_preflight)"
  failure_detail "$preflight_shadow"
fi

# =============================================================================
# F. F4 icon
# =============================================================================

reset_box
pkg="$PKGROOT/f51-icon-artifact"; mkpkg "$pkg" f51
printf 'icon\n' >"$pkg/icon.svg"
pkg_manifest "$pkg" 'contract = 1' 'id = "f51"' '[tile]' 'label = "F51"' 'sub = "sub"' 'cat = "docs"' 'icon = "icon.svg"'
cfg="$CFGROOT/f51.toml"; make_pkg_cfg "$cfg" f51 "$pkg"
info51="$(run "$cfg" package-info 2>/dev/null)"; rc_info51=$?
artifact51=0
if [ "$rc_info51" = 0 ]; then
  printf '%s' "$info51" | python3 -c 'import json,sys; assert "assets/apps/f51" in json.load(sys.stdin)["packages"]["f51"]["artifacts"]["webroot"]' >/dev/null 2>&1 && artifact51=1
fi
if [ "$artifact51" = 1 ]; then
  ok "F51 package-info records the synthetic per-app icon webroot artifact"
else
  bad "F51 icon synthetic artifact (rc=$rc_info51)"
  printf '%s\n' "$info51" | sed 's/^/    /'
fi

reset_box
pkg="$PKGROOT/f53-icon-src"; mkpkg "$pkg" f53
printf 'icon\n' >"$pkg/icon.svg"
pkg_manifest "$pkg" 'contract = 1' 'id = "f53"' '[tile]' 'label = "F53"' 'sub = "sub"' 'cat = "docs"' 'icon = "icon.svg"'
cfg="$CFGROOT/f53.toml"; make_pkg_cfg "$cfg" f53 "$pkg"
icon_out="$(run "$cfg" icon-src f53 2>/dev/null)"; rc_icon=$?
icon_expected="$pkg/icon.svg"$'\n'"assets/apps/f53/icon.svg"
if [ "$rc_icon" = 0 ] && [ "$icon_out" = "$icon_expected" ]; then
  ok "F53 icon-src prints source/destination"
else
  bad "F53 icon-src output (rc=$rc_icon)"
  printf '%s\n' "$icon_out" | sed 's/^/    /'
fi

reset_box
pkg="$PKGROOT/f54-no-icon"; mkpkg "$pkg" f54
cfg="$CFGROOT/f54.toml"; make_pkg_cfg "$cfg" f54 "$pkg"
no_icon_out="$(run "$cfg" icon-src f54 2>/dev/null)"; rc_no_icon=$?
if [ "$rc_no_icon" = 0 ] && [ -z "$no_icon_out" ]; then
  ok "F54 icon-src is empty and successful for a no-icon package"
else
  bad "F54 no-icon icon-src (rc=$rc_no_icon)"
  printf '%s\n' "$no_icon_out" | sed 's/^/    /'
fi

# The D4 obligation end to end: the package's OWN installer selects its gate
# from the exported audience value; flipping [apps.X].audience and re-running
# the orchestrator must change the emitted gate with no manual step.
reset_box
pkg="$PKGROOT/h64-audflip"; mkpkg "$pkg" h64
pkg_manifest "$pkg" 'contract = 1' 'id = "h64"' \
  '[audience]' 'supported = ["shared", "owner"]' 'default = "shared"'
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
eval "$("$AIRLOCK_ROOT/bin/airlock-config" env "$AIRLOCK_APP_ID")"
case "$AIRLOCK_H64_AUDIENCE" in
  owner)  gate='if ($owner_ok = 0) { return 403; }' ;;
  shared) gate='if ($hub_ok = 0) { return 403; }' ;;
  *) echo "unexpected audience: $AIRLOCK_H64_AUDIENCE" >&2; exit 1 ;;
esac
printf '%s\n' "$gate" >"$AIRLOCK_CONFD/servers.d/h64-gate.conf"
EOF
cat >"$pkg/smoke.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$pkg"/*.sh
cfg="$CFGROOT/h64.toml"; make_pkg_cfg "$cfg" h64 "$pkg"
out64a="$(env AIRLOCK_CONFIG="$cfg" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
  "$LEDGER" apply h64 --source "$pkg" 2>&1)"; rc64a=$?
gate_a="$(cat "$CONFD/servers.d/h64-gate.conf" 2>/dev/null)"
make_pkg_cfg "$cfg" h64 "$pkg" 'audience = "owner"'
out64b="$(env AIRLOCK_CONFIG="$cfg" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
  "$LEDGER" apply h64 --source "$pkg" 2>&1)"; rc64b=$?
gate_b="$(cat "$CONFD/servers.d/h64-gate.conf" 2>/dev/null)"
if [ "$rc64a" = 0 ] && [ "$rc64b" = 0 ] \
   && grep -Fq 'hub_ok' <<<"$gate_a" && grep -Fq 'owner_ok' <<<"$gate_b"; then
  ok "H64 audience flip re-renders the package gate on the next run"
else
  bad "H64 audience flip (rc=$rc64a/$rc64b; a=${gate_a:-none} b=${gate_b:-none})"
  failure_detail "$out64a"
  failure_detail "$out64b"
fi

# ---- A24b: post-validation symlink swap fails the run, never follows --------
# Layered defence (F6/D6): a smoke.sh swapped to a symlink after the initial
# validation is refused by whichever layer sees it first — the render step's
# re-validation (package_specs lstat) or the execution-time lstat re-checks in
# the orchestrator/airlock-smoke/deactivator. The property under test is that
# NO layer follows the symlink and the run fails loudly.
reset_box
pkg="$PKGROOT/a24-swap"; mkpkg "$pkg" swapapp
cat >"$pkg/install.sh" <<EOF
#!/usr/bin/env bash
rm -f "$PKGROOT/a24-swap/smoke.sh"
ln -s "$TMP/outside-smoke.sh" "$PKGROOT/a24-swap/smoke.sh"
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/outside-smoke.sh"
chmod +x "$pkg/install.sh" "$TMP/outside-smoke.sh"
cfg="$CFGROOT/a24.toml"; make_pkg_cfg "$cfg" swapapp "$pkg"
# This case judges the post-validation script re-check, not the independent
# self-kill escape.  A suite hosted by airlock-*.service would otherwise move
# the inner run to a transient service whose diagnostics correctly go to the
# journal, outside this command substitution.  Use the escape's cgroup test
# seam for this invocation only; H64 above remains a real cross-layer canary
# for the caller-environment forwarding contract.
printf '0::/user.slice/user-1000.slice/user@1000.service/session.slice/airlock-test.scope\n' \
  >"$TMP/a24-neutral-cgroup"
out24="$(env AIRLOCK_SELFKILL_CGROUP_FILE="$TMP/a24-neutral-cgroup" \
  AIRLOCK_CONFIG="$cfg" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
  bash -c '"$1" apply swapapp --source "$2" && bash "$3/bin/airlock-smoke"' \
    _ "$LEDGER" "$pkg" "$ROOT" 2>&1)"; rc24=$?
if [ "$rc24" -ne 0 ] && grep -Fq "regular non-symlink file" <<<"$out24" \
   && ! grep -Fq "smoke: swapapp" <<<"$out24"; then
  ok "A24b smoke.sh swapped to a symlink after validation fails the run"
else
  bad "A24b symlink swap (rc=$rc24)"
  failure_detail "$out24"
fi

# ---- review round 1 regressions (sol/opus majors) ---------------------------

# C36b: a dependency on a legacy-grammar app id must round-trip through the
# ledger — validate-green must never wedge plan (and with it the documented
# per-app teardown escape hatch).
reset_box
pkg="$PKGROOT/c36b-legacy-dep"; mkpkg "$pkg" c36b
pkg_manifest "$pkg" 'contract = 1' 'id = "c36b"' \
  '[dependencies]' 'apps = ["My_App"]'
cfg="$CFGROOT/c36b.toml"
{
  base_config
  printf '[apps.My_App]\n[apps.c36b]\n[packages.c36b]\npath = "%s"\n' "$pkg"
} >"$cfg"
seed_apps c36b "$pkg"
info="$(run "$cfg" package-info 2>/dev/null)"; rc_info36=$?
plan36="$(ledger_run "$info" plan 2>&1)"; rc_plan36=$?
if [ "$rc_info36" = 0 ] && [ "$rc_plan36" = 0 ] \
   && grep -q $'^reinstall\tc36b$' <<<"$plan36"; then
  ok "C36b legacy-grammar dependency id round-trips through ledger plan"
else
  bad "C36b legacy dep grammar (info=$rc_info36 plan=$rc_plan36)"
  failure_detail "$plan36"
fi

# D44 used to assert that a span must respect another id's RECORDED (ledger)
# serve ports until the record is removed. Validate-time's cross-check
# against ledger-recorded claims was dropped 2026-09-27 — gate-zero revival
# K7, docs/reports/2026-09-27_installer-gate-zero-base-revival.md — leaving
# only a check between the CURRENTLY DECLARED candidates, so this scenario
# is no longer fatal at validate and the case is retired.

# E50: the standalone entry point evaluates PACKAGED prerequisites too — a
# bin/airlock-preflight that never assembles would report green for a
# requirement the installer would fail on.
reset_box
pkg="$PKGROOT/e50-standalone"; mkpkg "$pkg" e50
pkg_manifest "$pkg" 'contract = 1' 'id = "e50"' \
  '[[prerequisites]]' 'command = "definitely-absent-xyz"' \
  'predicate = "present"' 'expected = "-"' \
  'fix = "apt install nothing"' 'note = "E50 probe"'
cfg="$CFGROOT/e50.toml"; make_pkg_cfg "$cfg" e50 "$pkg"
out50="$(AIRLOCK_CONFIG="$cfg" bash "$ROOT/bin/airlock-preflight" 2>&1)"; rc50=$?
if [ "$rc50" -ne 0 ] && grep -Fq "definitely-absent-xyz" <<<"$out50"; then
  ok "E50 standalone preflight evaluates packaged prerequisites"
else
  bad "E50 standalone preflight assembly (rc=$rc50)"
  failure_detail "$out50"
fi
pkg_manifest "$pkg" 'contract = 1' 'id = "e50"' \
  '[[prerequisites]]' 'command = "bash"' \
  'predicate = "present"' 'expected = "-"' \
  'fix = "apt install bash"' 'note = "E50 probe"'
out50b="$(AIRLOCK_CONFIG="$cfg" bash "$ROOT/bin/airlock-preflight" --quiet 2>&1)"; rc50b=$?
if [ "$rc50b" = 0 ]; then
  ok "E50b standalone preflight passes when the packaged prerequisite is met"
else
  bad "E50b standalone preflight satisfied prereq (rc=$rc50b)"
  failure_detail "$out50b"
fi

# H62: a package may project an arbitrary-size HTTPS mapping set from one
# operator-owned `[apps.<id>.<table>]` config table. The exact rows, including
# extra installer fields and the source digest, ride in package-info; the ledger
# therefore owns the same point-in-time mapping the lifecycle consumes.
reset_box
pkg="$PKGROOT/h62-registry-https"; mkpkg "$pkg" h62
pkg_manifest "$pkg" 'contract = 1' 'id = "h62"' \
  '[config.tables.vaults]' 'allowed_keys = ["vaults"]' \
  '[[serve.https_registry]]' \
  'table = "vaults"' \
  'entries = "vaults"' 'key = "id"' 'enabled = "writable"' \
  'listen = "editor.https_port"' 'target = "editor.gate_port"' \
  'fields = { path = "path", backend_port = "editor.backend_port" }'
read -r -d '' h62_table <<'EOF' || true
[apps.h62.vaults]
vaults = [
  { id = "read-only", path = "$HOME/wiki", writable = false },
  { id = "personal", path = "$HOME/notes", writable = true, editor = { https_port = 28448, gate_port = 28823, backend_port = 26769 } },
  { id = "shared", path = "$HOME/shared", writable = true, editor = { https_port = 28449, gate_port = 28824, backend_port = 26770 } },
]
EOF
cfg="$CFGROOT/h62.toml"; make_pkg_cfg "$cfg" h62 "$pkg" "$h62_table"
h62_info="$(run "$cfg" package-info 2>/dev/null)"; h62_rc=$?
h62_projection="$(printf '%s' "$h62_info" | python3 -c '
import hashlib,json,sys,tomllib
p=json.load(sys.stdin)["packages"]["h62"]
rows=p["serve_registry_rows"]
table=tomllib.load(open(sys.argv[1],"rb"))["apps"]["h62"]["vaults"]
digest=hashlib.sha256(
    json.dumps(table, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()
assert [r["key"] for r in rows] == ["personal", "shared"]
assert rows[0]["fields"] == {"path":"$HOME/notes", "backend_port":26769}
assert rows[0]["source"] == "apps.h62.vaults"
assert rows[0]["source_sha256"] == digest
assert p["serve_mappings"][rows[1]["mapping_key"]] == {
    "listen":28449,"mode":"https","target":28824}
assert p["serve_port_values"] == {
    row["mapping_key"]:row["listen"] for row in rows}
assert p["artifacts"]["serve_ports"] == sorted(p["serve_port_values"])
assert all(__import__("re").fullmatch(r"[a-z0-9_]+", key)
           for key in p["serve_port_values"])
print("ok")
' "$cfg" 2>/dev/null)"
if [ "$h62_rc" = 0 ] && [ "$h62_projection" = ok ]; then
  ok "H62 registry HTTPS projects exact enabled rows into package-info"
else
  bad "H62 registry HTTPS package-info projection (rc=$h62_rc)"
fi

h62_apply="$(AIRLOCK_CONFIG="$cfg" "$LEDGER" apply h62 --source "$pkg" 2>&1)"; h62_apply_rc=$?
if [ "$h62_apply_rc" = 0 ]; then
  read -r -d '' h62_reduced_table <<'EOF' || true
[apps.h62.vaults]
vaults = [
  { id = "read-only", path = "$HOME/wiki", writable = false },
  { id = "personal", path = "$HOME/notes", writable = true, editor = { https_port = 28448, gate_port = 28823, backend_port = 26769 } },
]
EOF
  reduced_cfg="$CFGROOT/h62-reduced.toml"
  make_pkg_cfg "$reduced_cfg" h62 "$pkg" "$h62_reduced_table"
  : >"$TMP/tailscale.log"
  h62_reapply="$(AIRLOCK_CONFIG="$reduced_cfg" "$LEDGER" apply h62 2>&1)"; h62_reapply_rc=$?
  if [ "$h62_reapply_rc" = 0 ] \
      && grep -Fq 'serve --https=28449 off' "$TMP/tailscale.log" \
      && ! grep -Fq 'serve --https=28448 off' "$TMP/tailscale.log"; then
    ok "H62b same-package registry shrink retracts only the dropped mapping"
  else
    bad "H62b registry shrink teardown (apply=$h62_reapply_rc)"
    failure_detail "$h62_reapply"
  fi
  : >"$TMP/tailscale.log"
  h62_remove="$(AIRLOCK_CONFIG="$reduced_cfg" "$LEDGER" remove h62 2>&1)"; h62_remove_rc=$?
  if [ "$h62_remove_rc" = 0 ] \
      && grep -Fq 'serve --https=28448 off' "$TMP/tailscale.log" \
      && ! grep -Fq 'serve --https=28449 off' "$TMP/tailscale.log"; then
    ok "H62b2 package removal retracts every remaining registry HTTPS mapping"
  else
    bad "H62b2 registry HTTPS ledger teardown (rc=$h62_remove_rc)"
    failure_detail "$h62_remove"
  fi
else
  bad "H62b registry HTTPS ledger setup"
  failure_detail "$h62_apply"
fi

reset_box
pkg="$PKGROOT/h62-optional"; mkpkg "$pkg" h62optional
pkg_manifest "$pkg" 'contract = 1' 'id = "h62optional"' \
  '[config.tables.vaults]' 'allowed_keys = ["vaults"]' \
  '[[serve.https_registry]]' 'table = "vaults"' \
  'entries = "vaults"' 'key = "id"' 'enabled = "writable"' \
  'listen = "editor.https_port"' 'target = "editor.gate_port"' 'optional = true'
cfg="$CFGROOT/h62-optional.toml"; make_pkg_cfg "$cfg" h62optional "$pkg"
h62_optional="$(run "$cfg" package-info 2>/dev/null | python3 -c '
import json,sys
p=json.load(sys.stdin)["packages"]["h62optional"]
print(len(p["serve_mappings"]), len(p["serve_registry_rows"]))
')"
[ "$h62_optional" = "0 0" ] \
  && ok "H62c an explicitly optional unset registry table is an empty projection" \
  || bad "H62c optional registry projection was $h62_optional"

reset_box
pkg="$PKGROOT/h62-undeclared"; mkpkg "$pkg" h62undeclared
pkg_manifest "$pkg" 'contract = 1' 'id = "h62undeclared"' \
  '[[serve.https_registry]]' 'table = "vaults"' \
  'entries = "vaults"' 'key = "id"' 'enabled = "writable"' \
  'listen = "editor.https_port"' 'target = "editor.gate_port"'
cfg="$CFGROOT/h62-undeclared.toml"; make_pkg_cfg "$cfg" h62undeclared "$pkg" \
  '[apps.h62undeclared.vaults]
vaults = [{ id = "personal", path = "$HOME/notes", writable = true, editor = { https_port = 28448, gate_port = 28823 } }]'
h62_undeclared="$(run "$cfg" package-info 2>&1)" && h62_undeclared_rc=0 \
  || h62_undeclared_rc=$?
if [ "$h62_undeclared_rc" != 0 ] \
    && grep -Fq 'apps.h62undeclared.vaults' <<<"$h62_undeclared" \
    && grep -Fq 'config.tables' <<<"$h62_undeclared"; then
  ok "H62g a registry naming an undeclared config table fails loudly"
else
  bad "H62g undeclared registry table (rc=$h62_undeclared_rc)"
  failure_detail "$h62_undeclared"
fi

# H63: lifecycle data such as sync=true is a separate question from HTTPS
# ownership. A package can project those rows through the same
# package-info projection without inventing a route or re-reading the live table.
reset_box
pkg="$PKGROOT/h63-registry-data"; mkpkg "$pkg" h63
pkg_manifest "$pkg" 'contract = 1' 'id = "h63"' \
  '[config.tables.vaults]' 'allowed_keys = ["vaults"]' \
  '[[serve.https_registry]]' \
  'table = "vaults"' \
  'entries = "vaults"' 'key = "id"' 'enabled = "writable"' \
  'listen = "editor.https_port"' 'target = "editor.gate_port"' \
  '[[registry]]' 'name = "sync_vaults"' 'table = "vaults"' \
  'entries = "vaults"' 'key = "id"' 'enabled = "sync"' 'enabled_default = false' \
  'fields = { path = "path" }'
read -r -d '' h63_table <<'EOF' || true
[apps.h63.vaults]
vaults = [
  { id = "read-only-sync", path = "$HOME/wiki", writable = false, sync = true },
  { id = "write-no-sync", path = "$HOME/notes", writable = true, sync = false, editor = { https_port = 28448, gate_port = 28823 } },
  { id = "both", path = "$HOME/shared", writable = true, sync = true, editor = { https_port = 28449, gate_port = 28824 } },
  { id = "neither", path = "$HOME/archive", writable = false },
]
EOF
cfg="$CFGROOT/h63.toml"; make_pkg_cfg "$cfg" h63 "$pkg" "$h63_table"
h63_info="$(run "$cfg" package-info 2>/dev/null)"; h63_rc=$?
h63_projection="$(printf '%s' "$h63_info" | python3 -c '
import hashlib,json,sys,tomllib
p=json.load(sys.stdin)["packages"]["h63"]
projections=p["registry_projections"]
assert set(projections) == {"sync_vaults"}
projection=projections["sync_vaults"]
table=tomllib.load(open(sys.argv[1],"rb"))["apps"]["h63"]["vaults"]
digest=hashlib.sha256(
    json.dumps(table, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()
assert projection["source"] == "apps.h63.vaults"
assert projection["present"] is True
assert projection["source_sha256"] == digest
assert projection["rows"] == [
    {"key":"read-only-sync", "fields":{"path":"$HOME/wiki"}},
    {"key":"both", "fields":{"path":"$HOME/shared"}}]
assert [row["key"] for row in p["serve_registry_rows"]] == ["write-no-sync", "both"]
assert {row["source_sha256"] for row in p["serve_registry_rows"]} == {
    projection["source_sha256"]}
print("ok")
' "$cfg" 2>/dev/null)"
if [ "$h63_rc" = 0 ] && [ "$h63_projection" = ok ]; then
  ok "H63 lifecycle sync and HTTPS writable projections stay independent on one snapshot"
else
  bad "H63 lifecycle registry projection (rc=$h63_rc)"
fi

read -r -d '' h63_quiet_table <<'EOF' || true
[apps.h63.vaults]
vaults = [{ id = "none", path = "$HOME/none", writable = false, sync = false }]
EOF
quiet_cfg="$CFGROOT/h63-quiet.toml"; make_pkg_cfg "$quiet_cfg" h63 "$pkg" "$h63_quiet_table"
h63_empty="$(run "$quiet_cfg" package-info 2>/dev/null | python3 -c '
import json,sys
p=json.load(sys.stdin)["packages"]["h63"]["registry_projections"]
projection=p["sync_vaults"]
print(len(p), len(projection["rows"]), bool(projection["source_sha256"]))
')"
[ "$h63_empty" = "1 0 True" ] \
  && ok "H63 empty enabled set retains its source digest" \
  || bad "H63 empty projection lost source authority: $h63_empty"

reset_box
pkg="$PKGROOT/h63-optional"; mkpkg "$pkg" h63optional
pkg_manifest "$pkg" 'contract = 1' 'id = "h63optional"' \
  '[config.tables.rows]' 'allowed_keys = []' \
  '[[registry]]' 'name = "optional_rows"' \
  'table = "rows"' 'entries = "rows"' \
  'key = "id"' 'enabled = "enabled"' 'optional = true'
cfg="$CFGROOT/h63-optional.toml"; make_pkg_cfg "$cfg" h63optional "$pkg"
h63_optional="$(run "$cfg" package-info 2>/dev/null | python3 -c '
import json,sys
p=json.load(sys.stdin)["packages"]["h63optional"]["registry_projections"]
assert p["optional_rows"] == {
    "source":"apps.h63optional.rows", "present":False,
    "source_sha256":None, "rows":[]}
print("ok")
')"
[ "$h63_optional" = ok ] \
  && ok "H63 optional unset table retains its named empty envelope" \
  || bad "H63 optional projection envelope was $h63_optional"

reset_box
pkg="$PKGROOT/h63-duplicate"; mkpkg "$pkg" h63duplicate
pkg_manifest "$pkg" 'contract = 1' 'id = "h63duplicate"' \
  '[config.tables.a]' 'allowed_keys = []' \
  '[config.tables.b]' 'allowed_keys = []' \
  '[[registry]]' 'name = "same"' 'table = "a"' 'entries = "rows"' 'key = "id"' \
  'enabled = "enabled"' \
  '[[registry]]' 'name = "same"' 'table = "b"' 'entries = "rows"' 'key = "id"' \
  'enabled = "enabled"'
cfg="$CFGROOT/h63-duplicate.toml"; make_pkg_cfg "$cfg" h63duplicate "$pkg" \
  '[apps.h63duplicate.a]
rows = [{ id = "one", enabled = true }]
[apps.h63duplicate.b]
rows = [{ id = "two", enabled = true }]'
h63_duplicate="$(run "$cfg" package-info 2>/dev/null | python3 -c '
import json,sys
p=json.load(sys.stdin)["packages"]["h63duplicate"]["registry_projections"]
print(len(p), p["same"]["source"], p["same"]["rows"][0]["key"])
')"
[ "$h63_duplicate" = "1 apps.h63duplicate.b two" ] \
  && ok "H63 a repeated projection name keeps the later declaration" \
  || bad "H63 repeated projection name resolved to: $h63_duplicate"


# C09: example-box's installed legacy perlite registries have no config table binding.
reset_box
pkg="$PKGROOT/legacy-perlite"; mkpkg "$pkg" perlite
pkg_manifest "$pkg" 'contract = 1' 'id = "perlite"' \
  '[[serve.https_registry]]' 'path = "~/.config/perlite/vaults.json"' \
  'entries = "vaults"' 'key = "id"' 'enabled = "enabled"' \
  'listen = "https_port"' 'target = "gate_port"' \
  '[[registry]]' 'name = "vaults"' 'path = "~/.config/perlite/vaults.json"' \
  'entries = "vaults"' 'key = "id"' 'enabled = "enabled"' 'enabled_default = true'
cfg="$CFGROOT/legacy-perlite.toml"; make_pkg_cfg "$cfg" perlite "$pkg"
legacy_info="$(run "$cfg" package-info 2>/dev/null)"; legacy_rc=$?
if [ "$legacy_rc" = 0 ] && printf '%s' "$legacy_info" | python3 -c '
import json,sys
p=json.load(sys.stdin)["packages"]["perlite"]
assert p["serve_registry_rows"] == [] and p["registry_projections"] == {}, p
'; then
  ok "C09 table-less installed legacy registries skip projection"
else bad "C09 legacy registry projection still blocks unrelated install"; fi

printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
