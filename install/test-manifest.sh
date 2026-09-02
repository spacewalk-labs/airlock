#!/usr/bin/env bash
# install/test-manifest.sh — executable fixtures for the child-3
# manifest/lifecycle contract (D2/D3/D6/F4/F5/F10/F11/F12/F14).
#
# Every package fixture is staged below $TMP, never under the repository's
# apps/ tree. The real config, ledger, preflight, and nginx entry points run
# against scratch roots and small command shims.
set -uo pipefail
# Pin the RAM the paseo installer takes its memory share from (32GiB), so nothing in
# this suite depends on the RAM of whichever box runs it: the share is 11/16 of the
# box, so unpinned, every runner writes a different MemoryMax and the goldens bake in
# whichever the runner happened to have. install/test-render-parity.sh gates that every
# suite running a real app installer sets this — the gate does not reason about WHICH
# app a dynamic path resolves to, so suites that only run other apps carry it too; the
# seam is inert for them. (An intermediate design REFUSED below 8 GiB, which is what
# made this urgent. The refusal is gone — owner, 2026-08-17 — the pin is still right.)
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)" || { echo "FAIL could not create test directory" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

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

write_v1_store() {
  local record_id="${1:-legacy}"
  mkdir -p "$STATE"
  cat >"$STATE/app-ledger.json" <<EOF
{
  "version": 1,
  "entries": {
    "$record_id": {
      "committed": {
        "path": "$TMP/legacy-package",
        "digest": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "lifecycle": {"install": true, "smoke": true, "deactivate": true},
        "artifacts": {"units": [], "fragments": [], "webroot": [], "files": [], "serve_ports": []}
      }
    }
  }
}
EOF
}

write_v1_intent_store() {
  mkdir -p "$STATE"
  cat >"$STATE/app-ledger.json" <<EOF
{
  "version": 1,
  "entries": {
    "legacy": {
      "intent": {
        "path": "$TMP/legacy-package",
        "digest": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        "artifacts_declared": {"units": [], "fragments": [], "webroot": [], "files": [], "serve_ports": []},
        "serve_port_values": {},
        "lifecycle": {"install": true, "smoke": true, "deactivate": true},
        "roots": {
          "unit_user": "$UU",
          "unit_system": "$US",
          "confd": "$CONFD",
          "webroot": "$WEB",
          "home": "$FAKEHOME"
        }
      }
    }
  }
}
EOF
}

commit_packages() {
  local info="$1" id
  shift
  for id in "$@"; do
    ledger_run "$info" intent "$id" >/dev/null 2>&1 || return 1
    ledger_run "$info" commit "$id" >/dev/null 2>&1 || return 1
  done
}

# =============================================================================
# A. manifest schema (F10/F2/D2)
# =============================================================================

reset_box
pkg="$PKGROOT/a1-missing-contract"; mkpkg "$pkg" a1
pkg_manifest "$pkg" 'id = "a1"'
cfg="$CFGROOT/a1.toml"; make_pkg_cfg "$cfg" a1 "$pkg"
expect_fail "A1 missing contract is fatal" "missing 'contract'" run "$cfg" validate

reset_box
pkg="$PKGROOT/a2-bool-contract"; mkpkg "$pkg" a2
pkg_manifest "$pkg" 'contract = true' 'id = "a2"'
cfg="$CFGROOT/a2.toml"; make_pkg_cfg "$cfg" a2 "$pkg"
expect_fail "A2 boolean contract is fatal" "'contract' must be an integer" run "$cfg" validate

reset_box
pkg="$PKGROOT/a3-contract-version"; mkpkg "$pkg" a3
pkg_manifest "$pkg" 'contract = 2' 'id = "a3"'
cfg="$CFGROOT/a3.toml"; make_pkg_cfg "$cfg" a3 "$pkg"
expect_fail "A3 unsupported contract version is fatal" "unsupported contract version 2" run "$cfg" validate

reset_box
pkg="$PKGROOT/a4-missing-id"; mkpkg "$pkg" a4
pkg_manifest "$pkg" 'contract = 1'
cfg="$CFGROOT/a4.toml"; make_pkg_cfg "$cfg" a4 "$pkg"
expect_fail "A4 missing id is fatal" "missing 'id'" run "$cfg" validate

reset_box
pkg="$PKGROOT/a5-id-mismatch"; mkpkg "$pkg" a5
pkg_manifest "$pkg" 'contract = 1' 'id = "other"'
cfg="$CFGROOT/a5.toml"; make_pkg_cfg "$cfg" a5 "$pkg"
expect_fail "A5 manifest id must agree with package id" "must agree exactly (F2)" run "$cfg" validate

reset_box
pkg="$PKGROOT/a6-unknown-manifest"; mkpkg "$pkg" a6
pkg_manifest "$pkg" 'contract = 1' 'id = "a6"' 'unknown = "closed"'
cfg="$CFGROOT/a6.toml"; make_pkg_cfg "$cfg" a6 "$pkg"
expect_fail "A6 unknown manifest key is fatal" "fail-closed applies to the manifest too (F10)" run "$cfg" validate

reset_box
pkg="$PKGROOT/a7-unknown-config"; mkpkg "$pkg" a7
pkg_manifest "$pkg" 'contract = 1' 'id = "a7"' '[config]' 'bogus = true'
cfg="$CFGROOT/a7.toml"; make_pkg_cfg "$cfg" a7 "$pkg"
expect_fail "A7 unknown config schema key is fatal" "unknown [config] key(s)" run "$cfg" validate

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
pkg="$PKGROOT/a7c-deprecated-source"; mkpkg "$pkg" a7c
pkg_manifest "$pkg" 'contract = 1' 'id = "a7c"' \
  '[config.defaults]' 'new_key = ""' \
  '[config.deprecated.old_key]' 'replacement = "new_key"' 'remove_after = "2026-09-07"'
cfg="$CFGROOT/a7c.toml"; make_pkg_cfg "$cfg" a7c "$pkg"
expect_fail "A7c deprecated source must be declared" "not a declared scalar config key" run "$cfg" validate

reset_box
pkg="$PKGROOT/a7d-deprecated-shape"; mkpkg "$pkg" a7d
pkg_manifest "$pkg" 'contract = 1' 'id = "a7d"' \
  '[config.defaults]' 'old_key = ""' 'new_key = ""' \
  '[config.deprecated.old_key]' 'replacement = "missing"' 'remove_after = "not-a-date"'
cfg="$CFGROOT/a7d.toml"; make_pkg_cfg "$cfg" a7d "$pkg"
expect_fail "A7d deprecated replacement must be declared" \
  "must name a different declared scalar config key; got 'missing'" run "$cfg" validate

reset_box
pkg="$PKGROOT/a7d2-deprecated-self"; mkpkg "$pkg" a7d2
pkg_manifest "$pkg" 'contract = 1' 'id = "a7d2"' \
  '[config.defaults]' 'old_key = ""' \
  '[config.deprecated.old_key]' 'replacement = "old_key"' 'remove_after = "2026-09-07"'
cfg="$CFGROOT/a7d2.toml"; make_pkg_cfg "$cfg" a7d2 "$pkg"
expect_fail "A7d2 deprecated replacement must differ from source" \
  "must name a different declared scalar config key; got 'old_key'" run "$cfg" validate

reset_box
pkg="$PKGROOT/a7e-deprecated-date"; mkpkg "$pkg" a7e
pkg_manifest "$pkg" 'contract = 1' 'id = "a7e"' \
  '[config.defaults]' 'old_key = ""' 'new_key = ""' \
  '[config.deprecated.old_key]' 'replacement = "new_key"' 'remove_after = "2026-99-99"'
cfg="$CFGROOT/a7e.toml"; make_pkg_cfg "$cfg" a7e "$pkg"
expect_fail "A7e deprecated removal date must be real" "must be an ISO date" run "$cfg" validate

reset_box
pkg="$PKGROOT/a8-required-default"; mkpkg "$pkg" a8
pkg_manifest "$pkg" 'contract = 1' 'id = "a8"' '[config]' '[[config.required]]' 'name = "same"' 'type = "string"' '[config.defaults]' 'same = "value"'
cfg="$CFGROOT/a8.toml"; make_pkg_cfg "$cfg" a8 "$pkg"
expect_fail "A8 required and defaulted key is fatal" "both required and defaulted" run "$cfg" validate

reset_box
pkg="$PKGROOT/a9-float-type"; mkpkg "$pkg" a9
pkg_manifest "$pkg" 'contract = 1' 'id = "a9"' '[config]' '[[config.required]]' 'name = "value"' 'type = "float"'
cfg="$CFGROOT/a9.toml"; make_pkg_cfg "$cfg" a9 "$pkg"
expect_fail "A9 unsupported required type is fatal" "type must be one of" run "$cfg" validate

reset_box
pkg="$PKGROOT/a10-float-default"; mkpkg "$pkg" a10
pkg_manifest "$pkg" 'contract = 1' 'id = "a10"' '[config.defaults]' 'value = 1.5'
cfg="$CFGROOT/a10.toml"; make_pkg_cfg "$cfg" a10 "$pkg"
expect_fail "A10 float default is fatal" "string, integer, or boolean" run "$cfg" validate

reset_box
pkg="$PKGROOT/a11-empty-table"; mkpkg "$pkg" a11
pkg_manifest "$pkg" 'contract = 1' 'id = "a11"' '[config.tables.options]' 'allowed_keys = []'
cfg="$CFGROOT/a11.toml"; make_pkg_cfg "$cfg" a11 "$pkg"
expect_fail "A11 table allowed_keys must be distinct and non-empty" "non-empty list of distinct" run "$cfg" validate

reset_box
pkg="$PKGROOT/a12-scalar-table"; mkpkg "$pkg" a12
pkg_manifest "$pkg" 'contract = 1' 'id = "a12"' '[config.defaults]' 'options = "scalar"' '[config.tables.options]' 'allowed_keys = ["leaf"]'
cfg="$CFGROOT/a12.toml"; make_pkg_cfg "$cfg" a12 "$pkg"
expect_fail "A12 scalar and table declaration conflict" "both a scalar and a table" run "$cfg" validate

reset_box
pkg="$PKGROOT/a13-span-undeclared"; mkpkg "$pkg" a13
pkg_manifest "$pkg" 'contract = 1' 'id = "a13"' '[[config.port_spans]]' 'base = "missing"' 'count = "also_missing"'
cfg="$CFGROOT/a13.toml"; make_pkg_cfg "$cfg" a13 "$pkg"
expect_fail "A13 port span names undeclared key" "not a declared config key" run "$cfg" validate

reset_box
pkg="$PKGROOT/a14-prereq-control"; mkpkg "$pkg" a14
pkg_manifest "$pkg" 'contract = 1' 'id = "a14"' '[[prerequisites]]' 'command = "foo\tbar"' 'predicate = "present"' 'expected = "-"' 'fix = "fix"' 'note = "note"'
cfg="$CFGROOT/a14.toml"; make_pkg_cfg "$cfg" a14 "$pkg"
expect_fail "A14 prerequisite control character is fatal" "contains a control character" run "$cfg" validate

reset_box
pkg="$PKGROOT/a15-prereq-unknown"; mkpkg "$pkg" a15
pkg_manifest "$pkg" 'contract = 1' 'id = "a15"' '[[prerequisites]]' 'command = "foo"' 'predicate = "present"' 'expected = "-"' 'fix = "fix"' 'note = "note"' 'extra = "bad"'
cfg="$CFGROOT/a15.toml"; make_pkg_cfg "$cfg" a15 "$pkg"
expect_fail "A15 unknown prerequisite field is fatal" "unknown prerequisites[0] key(s)" run "$cfg" validate

reset_box
pkg="$PKGROOT/a16-tile-cat"; mkpkg "$pkg" a16
pkg_manifest "$pkg" 'contract = 1' 'id = "a16"' '[tile]' 'label = "A16"' 'sub = "sub"' 'cat = "misc"' 'glyph = "box"'
cfg="$CFGROOT/a16.toml"; make_pkg_cfg "$cfg" a16 "$pkg"
expect_fail "A16 tile category is closed" "cat must be one of" run "$cfg" validate

reset_box
pkg="$PKGROOT/a17-tile-icon-xor"; mkpkg "$pkg" a17
touch "$pkg/icon.svg"
pkg_manifest "$pkg" 'contract = 1' 'id = "a17"' '[tile]' 'label = "A17"' 'sub = "sub"' 'cat = "docs"' 'icon = "icon.svg"' 'glyph = "box"'
cfg="$CFGROOT/a17.toml"; make_pkg_cfg "$cfg" a17 "$pkg"
out_both="$(run "$cfg" validate 2>&1)"; rc_both=$?
pkg_manifest "$pkg" 'contract = 1' 'id = "a17"' '[tile]' 'label = "A17"' 'sub = "sub"' 'cat = "docs"'
out_neither="$(run "$cfg" validate 2>&1)"; rc_neither=$?
if [ "$rc_both" -ne 0 ] && [ "$rc_neither" -ne 0 ] \
   && grep -Fq "exactly one of" <<<"$out_both" \
   && grep -Fq "exactly one of" <<<"$out_neither"; then
  ok "A17 tile requires exactly one of icon or glyph"
else
  bad "A17 tile icon/glyph XOR"
  failure_detail "$out_both"
  failure_detail "$out_neither"
fi

# A17g/A17h: a glyph must name a <symbol> that actually exists in the hub
# sprite. Before this check, four invented names (`app-docs`, `app-files`,
# `app-system`, `app-notes`) passed validate, install, and smoke on
# 2026-08-25 and rendered as blank tiles — the browser resolves an unknown
# <use> reference to nothing, silently. Positive control on both sides:
# the invented name must FAIL and a real sprite id must PASS, so a broken
# sprite reader cannot go green either way.
reset_box
pkg="$PKGROOT/a17g-glyph-missing"; mkpkg "$pkg" a17g
pkg_manifest "$pkg" 'contract = 1' 'id = "a17g"' '[tile]' 'label = "A17g"' 'sub = "sub"' 'cat = "docs"' 'glyph = "app-docs"'
cfg="$CFGROOT/a17g.toml"; make_pkg_cfg "$cfg" a17g "$pkg"
out_g="$(run "$cfg" validate 2>&1)"; rc_g=$?
if [ "$rc_g" -ne 0 ] \
   && grep -Fq 'does not exist in the hub sprite' <<<"$out_g" \
   && grep -Fq 'a17g' <<<"$out_g" \
   && grep -Fq 'app-docs' <<<"$out_g" \
   && grep -Fq 'Available glyphs:' <<<"$out_g"; then
  ok "A17g tile glyph absent from the sprite is fatal and names app, glyph, candidates"
else
  bad "A17g tile glyph absent from the sprite (rc=$rc_g)"
  failure_detail "$out_g"
fi

reset_box
pkg="$PKGROOT/a17h-glyph-real"; mkpkg "$pkg" a17h
pkg_manifest "$pkg" 'contract = 1' 'id = "a17h"' '[tile]' 'label = "A17h"' 'sub = "sub"' 'cat = "docs"' 'glyph = "app-notepad"'
cfg="$CFGROOT/a17h.toml"; make_pkg_cfg "$cfg" a17h "$pkg"
expect_ok "A17h tile glyph naming a real sprite symbol validates" run "$cfg" validate

reset_box
pkg="$PKGROOT/a18-icon-path"; mkpkg "$pkg" a18
pkg_manifest "$pkg" 'contract = 1' 'id = "a18"' '[tile]' 'label = "A18"' 'sub = "sub"' 'cat = "docs"' 'icon = "../x.svg"'
cfg="$CFGROOT/a18.toml"; make_pkg_cfg "$cfg" a18 "$pkg"
expect_fail "A18 icon path rejects dot segments" "no '.'/'..' segments" run "$cfg" validate

# A18b/A18c: the OTHER tile axis. A17g closed `glyph` against the sprite; an
# `icon` is a file staged out of the package, and validate must refuse a name
# that points at nothing just as fail-closed. That check is wired through
# package_specs (_validate_icon_source strict-resolves the source, F4), but
# until these fixtures nothing pinned the VALIDATE axis — F53 exercises
# icon-src only, so moving the check off validate's path would have gone
# green. Positive control on both sides: a missing file must FAIL naming app
# and path, and a real file must PASS.
reset_box
pkg="$PKGROOT/a18b-icon-missing"; mkpkg "$pkg" a18b
pkg_manifest "$pkg" 'contract = 1' 'id = "a18b"' '[tile]' 'label = "A18b"' 'sub = "sub"' 'cat = "docs"' 'icon = "no-such.png"'
cfg="$CFGROOT/a18b.toml"; make_pkg_cfg "$cfg" a18b "$pkg"
out_i="$(run "$cfg" validate 2>&1)"; rc_i=$?
if [ "$rc_i" -ne 0 ] \
   && grep -Fq 'does not resolve to a file inside the package' <<<"$out_i" \
   && grep -Fq "package 'a18b'" <<<"$out_i" \
   && grep -Fq 'no-such.png' <<<"$out_i"; then
  ok "A18b tile icon naming a missing file is fatal at validate, naming app and path"
else
  bad "A18b tile icon naming a missing file (rc=$rc_i)"
  failure_detail "$out_i"
fi

reset_box
pkg="$PKGROOT/a18c-icon-real"; mkpkg "$pkg" a18c
printf 'icon\n' >"$pkg/icon.png"
pkg_manifest "$pkg" 'contract = 1' 'id = "a18c"' '[tile]' 'label = "A18c"' 'sub = "sub"' 'cat = "docs"' 'icon = "icon.png"'
cfg="$CFGROOT/a18c.toml"; make_pkg_cfg "$cfg" a18c "$pkg"
expect_ok "A18c tile icon naming a real package file validates" run "$cfg" validate

reset_box
pkg="$PKGROOT/a19-audience"; mkpkg "$pkg" a19
pkg_manifest "$pkg" 'contract = 1' 'id = "a19"' '[audience]' 'supported = ["public"]' 'default = "public"'
cfg="$CFGROOT/a19.toml"; make_pkg_cfg "$cfg" a19 "$pkg"
out_supported="$(run "$cfg" validate 2>&1)"; rc_supported=$?
pkg_manifest "$pkg" 'contract = 1' 'id = "a19"' '[audience]' 'supported = ["shared"]' 'default = "owner"'
out_default="$(run "$cfg" validate 2>&1)"; rc_default=$?
if [ "$rc_supported" -ne 0 ] && [ "$rc_default" -ne 0 ] \
   && grep -Fq "distinct values from" <<<"$out_supported" \
   && grep -Fq "default must be one of supported" <<<"$out_default"; then
  ok "A19 audience supported/default rules are fatal"
else
  bad "A19 audience supported/default validation"
  failure_detail "$out_supported"
  failure_detail "$out_default"
fi

reset_box
pkg="$PKGROOT/a20-serve-undeclared"; mkpkg "$pkg" a20
pkg_manifest "$pkg" 'contract = 1' 'id = "a20"' '[artifacts]' 'serve_ports = ["port"]'
cfg="$CFGROOT/a20.toml"; make_pkg_cfg "$cfg" a20 "$pkg"
expect_fail "A20 serve_ports names undeclared key" "not a declared config key" run "$cfg" validate

reset_box
pkg="$PKGROOT/a21-lifecycle-shapes"; mkpkg "$pkg" a21
target_manifest="$TMP/a21-target.toml"
printf 'contract = 1\nid = "a21"\n' >"$target_manifest"
rm "$pkg/airlock-app.toml"
ln -s "$target_manifest" "$pkg/airlock-app.toml"
cfg="$CFGROOT/a21.toml"; make_pkg_cfg "$cfg" a21 "$pkg"
out_manifest="$(run "$cfg" validate 2>&1)"; rc_manifest=$?
rm "$pkg/airlock-app.toml"
cp "$target_manifest" "$pkg/airlock-app.toml"
rm "$pkg/smoke.sh"
out_smoke="$(run "$cfg" validate 2>&1)"; rc_smoke=$?
cat >"$pkg/smoke.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$pkg/smoke.sh"
target_script="$TMP/a21-install-target.sh"
cat >"$target_script" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
rm "$pkg/install.sh"
ln -s "$target_script" "$pkg/install.sh"
out_install="$(run "$cfg" validate 2>&1)"; rc_install=$?
if [ "$rc_manifest" -ne 0 ] && grep -Fq "regular non-symlink" <<<"$out_manifest" \
   && [ "$rc_smoke" -ne 0 ] && grep -Fq "install.sh and smoke.sh are required" <<<"$out_smoke" \
   && [ "$rc_install" -ne 0 ] && grep -Fq "regular non-symlink" <<<"$out_install"; then
  ok "A21 manifest and lifecycle files require regular non-symlinks"
else
  bad "A21 manifest/lifecycle file shape checks"
  failure_detail "$out_manifest"
  failure_detail "$out_smoke"
  failure_detail "$out_install"
fi

reset_box
pkg="$PKGROOT/a22-core-owner"; mkpkg "$pkg" core
cfg="$CFGROOT/a22.toml"
{
  base_config
  printf '[packages.core]\npath = "%s"\n' "$pkg"
} >"$cfg"
expect_fail "A22 core package owner is reserved" "prerequisites pseudo-owner" run "$cfg" validate

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
pkg="$PKGROOT/b24-unknown-app-key"; mkpkg "$pkg" b24
pkg_manifest "$pkg" 'contract = 1' 'id = "b24"' '[config.defaults]' 'known = "ok"'
cfg="$CFGROOT/b24.toml"; make_pkg_cfg "$cfg" b24 "$pkg" 'unknown = "bad"'
expect_fail "B24 packaged app rejects undeclared config key" "unknown config key(s)" run "$cfg" validate

reset_box
pkg="$PKGROOT/b25-required-missing"; mkpkg "$pkg" b25
pkg_manifest "$pkg" 'contract = 1' 'id = "b25"' '[config]' '[[config.required]]' 'name = "required"' 'type = "string"'
cfg="$CFGROOT/b25.toml"; make_pkg_cfg "$cfg" b25 "$pkg"
expect_fail "B25 required app key must be configured" "is required by the package manifest" run "$cfg" validate

reset_box
pkg="$PKGROOT/b26-types"; mkpkg "$pkg" b26
pkg_manifest "$pkg" 'contract = 1' 'id = "b26"' '[config]' '[[config.required]]' 'name = "text"' 'type = "string"' '[config.defaults]' 'count = 3'
cfg="$CFGROOT/b26.toml"; make_pkg_cfg "$cfg" b26 "$pkg" $'text = 5\ncount = true'
out_string="$(run "$cfg" validate 2>&1)"; rc_string=$?
make_pkg_cfg "$cfg" b26 "$pkg" $'text = "ok"\ncount = true'
out_integer="$(run "$cfg" validate 2>&1)"; rc_integer=$?
if [ "$rc_string" -ne 0 ] && grep -Fq "must be a string (declared by the package manifest)" <<<"$out_string" \
   && [ "$rc_integer" -ne 0 ] && grep -Fq "must be a integer" <<<"$out_integer"; then
  ok "B26 required/defaulted values enforce declared types"
else
  bad "B26 packaged scalar typing"
  failure_detail "$out_string"
  failure_detail "$out_integer"
fi

reset_box
pkg="$PKGROOT/b27-nested-schema"; mkpkg "$pkg" b27
pkg_manifest "$pkg" 'contract = 1' 'id = "b27"' '[config.tables.options]' 'allowed_keys = ["leaf"]'
cfg="$CFGROOT/b27.toml"; make_pkg_cfg "$cfg" b27 "$pkg" $'[apps.b27.options]\nunknown = "bad"'
out_nested="$(run "$cfg" validate 2>&1)"; rc_nested=$?
make_pkg_cfg "$cfg" b27 "$pkg" 'options = "scalar"'
out_scalar="$(run "$cfg" validate 2>&1)"; rc_scalar=$?
if [ "$rc_nested" -ne 0 ] && grep -Fq "unknown config key(s)" <<<"$out_nested" \
   && [ "$rc_scalar" -ne 0 ] && grep -Fq "must be a table" <<<"$out_scalar"; then
  ok "B27 nested tables are closed and must remain tables"
else
  bad "B27 nested table schema enforcement"
  failure_detail "$out_nested"
  failure_detail "$out_scalar"
fi

reset_box
pkg="$PKGROOT/b28-shadow-publish"; mkpkg "$pkg" publish
pkg_manifest "$pkg" 'contract = 1' 'id = "publish"' '[config.defaults]' 'own_key = "x"'
cfg="$CFGROOT/b28.toml"
{
  base_config
  printf '[apps.publish.public_target]\nmode = "path"\n[packages.publish]\npath = "%s"\n' "$pkg"
} >"$cfg"
expect_fail "B28 shadowing package replaces publish schema" "unknown config key(s)" run "$cfg" validate

reset_box
pkg="$PKGROOT/b29-audience"; mkpkg "$pkg" b29
pkg_manifest "$pkg" 'contract = 1' 'id = "b29"'
cfg="$CFGROOT/b29.toml"; make_pkg_cfg "$cfg" b29 "$pkg" 'audience = "owner"'
out_no_audience="$(run "$cfg" validate 2>&1)"; rc_no_audience=$?
pkg_manifest "$pkg" 'contract = 1' 'id = "b29"' '[audience]' 'supported = ["shared"]' 'default = "shared"'
make_pkg_cfg "$cfg" b29 "$pkg" 'audience = "owner"'
out_unsupported="$(run "$cfg" validate 2>&1)"; rc_unsupported=$?
pkg_manifest "$pkg" 'contract = 1' 'id = "b29"' '[audience]' 'supported = ["shared", "owner"]' 'default = "owner"'
make_pkg_cfg "$cfg" b29 "$pkg"
env_audience="$(run "$cfg" env b29 2>&1)"; rc_env=$?
if [ "$rc_no_audience" -ne 0 ] && grep -Fq "unknown config key(s)" <<<"$out_no_audience" \
   && [ "$rc_unsupported" -ne 0 ] && grep -Fq "supported audiences" <<<"$out_unsupported" \
   && [ "$rc_env" = 0 ] && grep -Fq "AUDIENCE=owner" <<<"$env_audience"; then
  ok "B29 audience schema rejects/exports effective defaults correctly"
else
  bad "B29 audience effective schema"
  failure_detail "$out_no_audience"
  failure_detail "$out_unsupported"
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
info_c32c="$(run "$cfg" package-info 2>/dev/null)"; rc_info_c32c=$?
commit_packages "$info_c32c" publish notepad; rc_commit_c32c=$?
drop_cfg_c32c="$CFGROOT/c32c-drop.toml"; base_config >"$drop_cfg_c32c"
drop_info_c32c="$(run "$drop_cfg_c32c" package-info 2>/dev/null)"
plan_c32c="$(ledger_run "$drop_info_c32c" plan 2>&1)"; rc_plan_c32c=$?
remove_ids_c32c="$(awk -F '\t' '$1 == "remove" {print $2}' <<<"$plan_c32c")"
if [ "$rc_info_c32c" = 0 ] && [ "$rc_commit_c32c" = 0 ] && [ "$rc_plan_c32c" = 0 ] \
   && [ "$remove_ids_c32c" = $'notepad\npublish' ]; then
  ok "C32c real notepad->publish edge removes notepad before publish (dependent-first, D38 direction)"
else
  bad "C32c real notepad/publish removal order (info=$rc_info_c32c commit=$rc_commit_c32c plan=$rc_plan_c32c)"
  printf '%s\n' "$plan_c32c" | sed 's/^/    /'
fi

# C32d (positive control for C32b/c): strip the edge from a SCRATCH COPY of
# notepad's manifest (the real repo file is never touched) and re-run the
# install-order assertion against that scratch shipped root — it must go RED
# (order reverts to plain TOML/C-collation order), proving C32b/c actually
# depend on the manifest edge and are not passing for some unrelated reason.
reset_box
NOEDGE_ROOT="$TMP/shipped-no-edge"; mkdir -p "$NOEDGE_ROOT"
cp -r "$ROOT/apps/notepad" "$ROOT/apps/publish" "$NOEDGE_ROOT/"
if grep -q '^\[dependencies\]$' "$NOEDGE_ROOT/notepad/airlock-app.toml"; then
  python3 -c '
import re, sys
p = sys.argv[1]
text = open(p).read()
text = re.sub(r"\[dependencies\]\napps = \[\"publish\"\]\n", "", text)
open(p, "w").write(text)
' "$NOEDGE_ROOT/notepad/airlock-app.toml"
fi
if grep -q '^\[dependencies\]$' "$NOEDGE_ROOT/notepad/airlock-app.toml"; then
  bad "C32d self-check: could not strip [dependencies] from the scratch notepad manifest copy (pattern stale?)"
else
  noedge_apps="$(AIRLOCK_SHIPPED_APPS_ROOT="$NOEDGE_ROOT" run "$cfg" apps 2>/dev/null)"; rc_noedge=$?
  if [ "$rc_noedge" = 0 ] && [ "$noedge_apps" != "$expected_apps" ]; then
    ok "C32d self-check: stripping the edge turns C32b's assertion red — it exercises the real edge, not a coincidence"
  else
    bad "C32d self-check FAILED: stripping the edge did NOT change the order (got: $noedge_apps) — C32b is not load-bearing on the edge"
  fi
fi

reset_box
pkg="$PKGROOT/c33-dep"; mkpkg "$pkg" dep33
pkg_manifest "$pkg" 'contract = 1' 'id = "dep33"' '[dependencies]' 'apps = ["ghost33"]'
cfg="$CFGROOT/c33.toml"
{
  base_config
  printf '[apps.dep33]\n[packages.dep33]\npath = "%s"\n' "$pkg"
} >"$cfg"
write_v1_store ghost33
expect_fail "C33 dependency needs configured app despite ledger record" "a ledger record alone does not satisfy it (D3)" run "$cfg" validate

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
# D. ledger store v2 (D6)
# =============================================================================

reset_box
write_v1_intent_store
before="$TMP/v1-before.json"; cp "$STATE/app-ledger.json" "$before"
plan36="$(ledger_run '{"packages":{}}' plan 2>&1)"; rc_plan36=$?
if [ "$rc_plan36" = 0 ] && cmp -s "$before" "$STATE/app-ledger.json"; then
  ok "D36 valid v1 store plans without rewriting its bytes"
else
  bad "D36 v1 store read-only plan (rc=$rc_plan36)"
  printf '%s\n' "$plan36" | sed 's/^/    /'
fi

reset_box
pkg="$PKGROOT/d37-intent"; mkpkg "$pkg" d37
cfg="$CFGROOT/d37.toml"; make_pkg_cfg "$cfg" d37 "$pkg"
info="$(run "$cfg" package-info 2>/dev/null)"; rc_info=$?
ledger_run "$info" intent d37 >/dev/null 2>&1; rc_intent=$?
version_deps=0
if [ -f "$STATE/app-ledger.json" ]; then
  python3 -c '
import json, sys
d=json.load(open(sys.argv[1]))
assert d["version"] == 6 and d["events"] == []
for e in d["entries"].values():
  for kind in ("committed", "intent"):
    if kind in e:
      assert "deps" in e[kind]
      assert e[kind]["container_runtime"] is None
' "$STATE/app-ledger.json" >/dev/null 2>&1 && version_deps=1
fi
if [ "$rc_info" = 0 ] && [ "$rc_intent" = 0 ] && [ "$version_deps" = 1 ]; then
  ok "D37 first intent mutation persists v2 records with deps"
else
  bad "D37 v2 intent migration (info=$rc_info intent=$rc_intent)"
fi

reset_box
base_pkg="$PKGROOT/d38-base"; mkpkg "$base_pkg" base
consumer_pkg="$PKGROOT/d38-consumer"; mkpkg "$consumer_pkg" consumer
pkg_manifest "$consumer_pkg" 'contract = 1' 'id = "consumer"' '[dependencies]' 'apps = ["base"]'
cfg="$CFGROOT/d38.toml"
{
  base_config
  printf '[apps.base]\n[apps.consumer]\n[packages.base]\npath = "%s"\n[packages.consumer]\npath = "%s"\n' "$base_pkg" "$consumer_pkg"
} >"$cfg"
info="$(run "$cfg" package-info 2>/dev/null)"; rc_info=$?
commit_packages "$info" base consumer; rc_commit=$?
drop_cfg="$CFGROOT/d38-drop.toml"; base_config >"$drop_cfg"
drop_info="$(run "$drop_cfg" package-info 2>/dev/null)"
plan38="$(ledger_run "$drop_info" plan 2>&1)"; rc_plan38=$?
remove_ids="$(awk -F '\t' '$1 == "remove" {print $2}' <<<"$plan38")"
if [ "$rc_info" = 0 ] && [ "$rc_commit" = 0 ] && [ "$rc_plan38" = 0 ] \
   && [ "$remove_ids" = $'consumer\nbase' ]; then
  ok "D38 removal plan removes dependent consumer before base"
else
  bad "D38 dependency-aware removal order (rc=$rc_plan38)"
  printf '%s\n' "$plan38" | sed 's/^/    /'
fi

reset_box
x_pkg="$PKGROOT/d39-x"; mkpkg "$x_pkg" x
a_pkg="$PKGROOT/d39-a"; mkpkg "$a_pkg" a
b_pkg="$PKGROOT/d39-b"; mkpkg "$b_pkg" b
pkg_manifest "$a_pkg" 'contract = 1' 'id = "a"' '[dependencies]' 'apps = ["x"]'
cfg="$CFGROOT/d39.toml"
{
  base_config
  printf '[apps.x]\n[apps.a]\n[apps.b]\n[packages.x]\npath = "%s"\n[packages.a]\npath = "%s"\n[packages.b]\npath = "%s"\n' "$x_pkg" "$a_pkg" "$b_pkg"
} >"$cfg"
info="$(run "$cfg" package-info 2>/dev/null)"
commit_packages "$info" x a b; rc_commit=$?
drop_cfg="$CFGROOT/d39-drop.toml"; base_config >"$drop_cfg"
drop_info="$(run "$drop_cfg" package-info 2>/dev/null)"
plan39="$(ledger_run "$drop_info" plan 2>&1)"; rc_plan39=$?
remove_ids="$(awk -F '\t' '$1 == "remove" {print $2}' <<<"$plan39")"
if [ "$rc_commit" = 0 ] && [ "$rc_plan39" = 0 ] && [ "$remove_ids" = $'b\na\nx' ]; then
  ok "D39 ranked removal uses ascending forward rank before reversal"
else
  bad "D39 reversed-whole-order removal sequence (rc=$rc_plan39)"
  printf '%s\n' "$plan39" | sed 's/^/    /'
fi

reset_box
a_pkg="$PKGROOT/d40-a"; mkpkg "$a_pkg" a40
b_pkg="$PKGROOT/d40-b"; mkpkg "$b_pkg" b40
pkg_manifest "$a_pkg" 'contract = 1' 'id = "a40"' '[dependencies]' 'apps = ["x40"]'
cfg="$CFGROOT/d40.toml"
{
  base_config
  printf '[apps.x40]\n[apps.a40]\n[apps.b40]\n[packages.a40]\npath = "%s"\n[packages.b40]\npath = "%s"\n' "$a_pkg" "$b_pkg"
} >"$cfg"
info="$(run "$cfg" package-info 2>/dev/null)"
commit_packages "$info" a40 b40; rc_commit=$?
drop_cfg="$CFGROOT/d40-drop.toml"; base_config >"$drop_cfg"
drop_info="$(run "$drop_cfg" package-info 2>/dev/null)"
plan40a="$(ledger_run "$drop_info" plan 2>&1)"; rc_plan40a=$?
plan40b="$(ledger_run "$drop_info" plan 2>&1)"; rc_plan40b=$?
remove_a="$(awk -F '\t' '$1 == "remove" {print $2}' <<<"$plan40a")"
if [ "$rc_commit" = 0 ] && [ "$rc_plan40a" = 0 ] && [ "$rc_plan40b" = 0 ] \
   && [ "$plan40a" = "$plan40b" ] && [ "$remove_a" = $'b40\na40' ]; then
  ok "D40 virtual dependency nodes sort first in ranked removal"
else
  bad "D40 virtual dependency removal plan"
  printf '%s\n' "$plan40a" | sed 's/^/    /'
  printf '%s\n' "$plan40b" | sed 's/^/    /'
fi

reset_box
a_pkg="$PKGROOT/d41-a"; mkpkg "$a_pkg" a41
b_pkg="$PKGROOT/d41-b"; mkpkg "$b_pkg" b41
pkg_manifest "$a_pkg" 'contract = 1' 'id = "a41"' '[dependencies]' 'apps = ["b41"]'
pkg_manifest "$b_pkg" 'contract = 1' 'id = "b41"' '[dependencies]' 'apps = ["a41"]'
cfg="$CFGROOT/d41.toml"
{
  base_config
printf '[apps.a41]\n[apps.b41]\n[packages.a41]\npath = "%s"\n[packages.b41]\npath = "%s"\n' "$a_pkg" "$b_pkg"
} >"$cfg"
info="$(cat <<EOF
{
  "packages": {
    "a41": {"dir": "$a_pkg", "artifacts": {"units": [], "fragments": [], "webroot": [], "files": [], "serve_ports": []}, "serve_port_values": {}, "lifecycle": {"install": true, "smoke": true, "deactivate": true}, "deps": ["b41"], "capabilities": []},
    "b41": {"dir": "$b_pkg", "artifacts": {"units": [], "fragments": [], "webroot": [], "files": [], "serve_ports": []}, "serve_port_values": {}, "lifecycle": {"install": true, "smoke": true, "deactivate": true}, "deps": ["a41"], "capabilities": []}
  }
}
EOF
)"
ledger_run "$info" intent a41 >/dev/null 2>&1; rc_a_intent=$?
ledger_run "$info" intent b41 >/dev/null 2>&1; rc_b_intent=$?
ledger_run "$info" commit a41 >/dev/null 2>&1; rc_a_commit=$?
drop_cfg="$CFGROOT/d41-drop.toml"; base_config >"$drop_cfg"
drop_info="$(run "$drop_cfg" package-info 2>/dev/null)"
cycle41="$(ledger_run "$drop_info" plan 2>&1)"; rc_cycle41=$?
if [ "$rc_a_intent" = 0 ] && [ "$rc_b_intent" = 0 ] && [ "$rc_a_commit" = 0 ] \
   && [ "$rc_cycle41" -ne 0 ] \
   && grep -Fq "cyclic dependency in removal plan involving" <<<"$cycle41"; then
  ok "D41 cyclic committed/intent dependency selection is fatal"
else
  bad "D41 cyclic removal dependency (rc=$rc_cycle41)"
  failure_detail "$cycle41"
fi

reset_box
mkdir -p "$STATE"
cat >"$STATE/app-ledger.json" <<EOF
{
  "version": 2,
  "entries": {
    "missingdeps": {
      "committed": {
        "path": "$TMP/missingdeps-package",
        "digest": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        "lifecycle": {"install": true, "smoke": true, "deactivate": true},
        "artifacts": {"units": [], "fragments": [], "webroot": [], "files": [], "serve_ports": []}
      }
    }
  }
}
EOF
expect_fail "D42 v2 records missing deps are invalid" "invalid committed record shape" ledger_run '{}' plan

reset_box
pkg="$PKGROOT/d43-roundtrip"; mkpkg "$pkg" d43
cfg="$CFGROOT/d43.toml"; make_pkg_cfg "$cfg" d43 "$pkg"
info="$(run "$cfg" package-info 2>/dev/null)"
ledger_run "$info" intent d43 >/dev/null 2>&1; rc_intent=$?
ledger_run "$info" commit d43 >/dev/null 2>&1; rc_commit=$?
plan43="$(ledger_run "$info" plan 2>&1)"; rc_plan43=$?
if [ "$rc_intent" = 0 ] && [ "$rc_commit" = 0 ] && [ "$rc_plan43" = 0 ] \
   && [ "$plan43" = $'reinstall\td43' ]; then
  ok "D43 v2 intent/commit round trip has no spurious plan actions"
else
  bad "D43 v2 round trip plan (rc=$rc_plan43)"
  printf '%s\n' "$plan43" | sed 's/^/    /'
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

reset_box
pkg="$PKGROOT/e47-corrupt-copy"; mkpkg "$pkg" e47
cfg="$CFGROOT/e47.toml"; make_pkg_cfg "$cfg" e47 "$pkg"
bad_tsv="$TMP/prerequisites-five.tsv"
printf 'core\tpython3\tmajor-gte\t3.11\tfix\n' >"$bad_tsv"
run_prereqs() {
  local tsv="$1"
  shift
  AIRLOCK_PREREQUISITES="$tsv" run "$@"
}
expect_fail_code "E47 corrupted TSV has exact rc 2 and six-field message" 2 "six non-empty" run_prereqs "$bad_tsv" "$cfg" prereqs

reset_box
pkg="$PKGROOT/e48-corrupt-preflight"; mkpkg "$pkg" e48
cfg="$CFGROOT/e48.toml"; make_pkg_cfg "$cfg" e48 "$pkg"
info="$(run "$cfg" package-info 2>/dev/null)"
preflight_pkg() {
  local config="$1" tsv="$2" pkg_info="$3"
  HOME="$FAKEHOME" PATH="$PATH" AIRLOCK_CONFIG="$config" \
    AIRLOCK_PKG_INFO="$pkg_info" /bin/bash -c \
      '. "$1/install/lib.sh"; AIRLOCK_PREREQUISITES="$2"; airlock_preflight --quiet' \
      _ "$ROOT" "$tsv"
}
preflight_corrupt="$(preflight_pkg "$cfg" "$bad_tsv" "$info" 2>&1)"; rc_preflight=$?
if [ "$rc_preflight" = 2 ] && grep -Fq "prerequisite assembly failed" <<<"$preflight_corrupt"; then
  ok "E48 preflight propagates corrupted package prerequisite assembly"
else
  bad "E48 preflight corrupted TSV (rc=$rc_preflight)"
  failure_detail "$preflight_corrupt"
fi

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
pkg="$PKGROOT/f50-icon-escape"; mkpkg "$pkg" f50
outside="$TMP/f50-outside.svg"; printf 'outside\n' >"$outside"
ln -s "$outside" "$pkg/icon.svg"
pkg_manifest "$pkg" 'contract = 1' 'id = "f50"' '[tile]' 'label = "F50"' 'sub = "sub"' 'cat = "docs"' 'icon = "icon.svg"'
cfg="$CFGROOT/f50.toml"; make_pkg_cfg "$cfg" f50 "$pkg"
expect_fail "F50 icon symlink cannot escape package root" "outside the canonical package root" run "$cfg" validate

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
pkg="$PKGROOT/f52-hub-webroot"; mkpkg "$pkg" f52
pkg_manifest "$pkg" 'contract = 1' 'id = "f52"' '[artifacts]' 'webroot = ["assets/x.css"]'
cfg="$CFGROOT/f52.toml"; make_pkg_cfg "$cfg" f52 "$pkg"
expect_fail "F52 manifest cannot claim hub-owned assets" "never manifest-claimable directly" run "$cfg" validate

# Even the package's OWN id-scoped icon directory is not directly claimable —
# the synthetic claim is the platform's, added after grammar validation.
reset_box
pkg="$PKGROOT/f52b-own-assets"; mkpkg "$pkg" f52b
printf 'icon\n' >"$pkg/icon.svg"
pkg_manifest "$pkg" 'contract = 1' 'id = "f52b"' \
  '[tile]' 'label = "F"' 'cat = "docs"' 'icon = "icon.svg"' \
  '[artifacts]' 'webroot = ["assets/apps/f52b"]'
cfg="$CFGROOT/f52b.toml"; make_pkg_cfg "$cfg" f52b "$pkg"
expect_fail "F52b a package cannot claim even its own assets/apps/<id> directly" \
  "never manifest-claimable directly" run "$cfg" validate

reset_box
pkg="$PKGROOT/f53-icon-src"; mkpkg "$pkg" f53
printf 'icon\n' >"$pkg/icon.svg"
pkg_manifest "$pkg" 'contract = 1' 'id = "f53"' '[tile]' 'label = "F53"' 'sub = "sub"' 'cat = "docs"' 'icon = "icon.svg"'
cfg="$CFGROOT/f53.toml"; make_pkg_cfg "$cfg" f53 "$pkg"
icon_out="$(run "$cfg" icon-src f53 2>/dev/null)"; rc_icon=$?
icon_expected="$pkg/icon.svg"$'\n'"assets/apps/f53/icon.svg"
rm "$pkg/icon.svg"
icon_after="$(run "$cfg" icon-src f53 2>&1)"; rc_icon_after=$?
if [ "$rc_icon" = 0 ] && [ "$icon_out" = "$icon_expected" ] \
   && [ "$rc_icon_after" = 1 ] \
   && grep -Fq "does not resolve to a file inside the package" <<<"$icon_after"; then
  ok "F53 icon-src prints source/destination and rechecks TOCTOU"
else
  bad "F53 icon-src output/TOCTOU (first=$rc_icon second=$rc_icon_after)"
  printf '%s\n' "$icon_out" | sed 's/^/    /'
  failure_detail "$icon_after"
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

# =============================================================================
# G. F12 scan
# =============================================================================

reset_box
pkg="$PKGROOT/g55-env-undeclared"; mkpkg "$pkg" g55
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$AIRLOCK_G55_NOPE" >/dev/null
EOF
chmod +x "$pkg/install.sh"
cfg="$CFGROOT/g55.toml"; make_pkg_cfg "$cfg" g55 "$pkg"
out55="$(run "$cfg" validate 2>&1)"; rc55=$?
if [ "$rc55" = 0 ] \
   && grep -Fq "is neither a declared config key nor a declared [config].runtime_env name" <<<"$out55" \
   && grep -Fq "install.sh:2" <<<"$out55"; then
  ok "G55 F12 flags an undeclared AIRLOCK env token with file:line"
else
  bad "G55 undeclared AIRLOCK token scan (rc=$rc55)"
  failure_detail "$out55"
fi

reset_box
pkg="$PKGROOT/g56-get-undeclared"; mkpkg "$pkg" g56
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
airlock_config get apps.g56.nope >/dev/null
EOF
chmod +x "$pkg/install.sh"
cfg="$CFGROOT/g56.toml"; make_pkg_cfg "$cfg" g56 "$pkg"
out56="$(run "$cfg" validate 2>&1)"; rc56=$?
chain_pkg="$PKGROOT/g56-chain"; mkpkg "$chain_pkg" chain56
cat >"$chain_pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
airlock_config get apps.chain56.a.b.c >/dev/null
EOF
chmod +x "$chain_pkg/install.sh"
chain_cfg="$CFGROOT/g56-chain.toml"; make_pkg_cfg "$chain_cfg" chain56 "$chain_pkg"
chain_out56="$(run "$chain_cfg" validate 2>&1)"; chain_rc56=$?
if [ "$rc56" = 0 ] && grep -Fq "which the manifest does not declare" <<<"$out56" \
   && [ "$chain_rc56" = 0 ] && grep -Fq "apps.chain56.a.b.c" <<<"$chain_out56" \
   && grep -Fq "does not declare" <<<"$chain_out56"; then
  ok "G56 F12 reports scalar and three-deep undeclared get reads"
else
  bad "G56 undeclared get scan (rc=$rc56 chain=$chain_rc56)"
  failure_detail "$out56"
  failure_detail "$chain_out56"
fi

reset_box
pkg="$PKGROOT/g57-never-read"; mkpkg "$pkg" g57
pkg_manifest "$pkg" 'contract = 1' 'id = "g57"' '[config.defaults]' 'unused = "value"'
cfg="$CFGROOT/g57.toml"; make_pkg_cfg "$cfg" g57 "$pkg"
out57="$(run "$cfg" validate 2>&1)"; rc57=$?
if [ "$rc57" = 0 ] && grep -Fq "never read" <<<"$out57"; then
  ok "G57 declared-but-unread keys warn while validation succeeds"
else
  bad "G57 unread declaration warning (rc=$rc57)"
  failure_detail "$out57"
fi

# Incident control (2026-08-30): a package declared port=18832 while its unit
# and backend used a separate literal 18832. The declared value therefore
# looked globally unique but did not govern the listener. The bad fixture must
# be red, and adding the literal platform read must turn the same fixture green.
reset_box
pkg="$PKGROOT/g57-port-unread"; mkpkg "$pkg" g57port
pkg_manifest "$pkg" 'contract = 1' 'id = "g57port"' '[config.defaults]' 'port = 18832'
cfg="$CFGROOT/g57-port-unread.toml"; make_pkg_cfg "$cfg" g57port "$pkg"
expect_fail "G57a an unread port declaration is fatal" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
printf '%s\n' 'AIRLOCK_G57PORT_PORT' >"$pkg/.decoy-port-read"
expect_fail "G57b a hidden decoy token is not runtime read evidence" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/smoke.py" <<'PY'
"""The name AIRLOCK_G57PORT_PORT is documentation, not a read."""
probe = "AIRLOCK_G57PORT_PORT"
PY
expect_fail "G57b0 Python docstrings and inert strings are not port reads" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/smoke.py" <<'PY'
import os
os.environ["AIRLOCK_G57PORT_PORT"] = "9999"
PY
expect_fail "G57b0c a Python environment overwrite is not a read" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
printf '%s\n' '[Service]' 'Environment=PORT=$AIRLOCK_G57PORT_PORT' >"$pkg/decoy.service"
expect_fail "G57b0b a unit assignment that overwrites the name is not a read" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '$AIRLOCK_G57PORT_PORT'
EOF
chmod +x "$pkg/install.sh"
expect_fail "G57b0a a single-quoted shell token is not a port read" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
port=\$AIRLOCK_G57PORT_PORT
EOF
expect_fail "G57b0d an escaped shell token is not a port read" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "\$AIRLOCK_G57PORT_PORT"
EOF
expect_fail "G57b0d2 a double-quoted escaped argument is not a port read" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
cat <<'TEXT'
port=$AIRLOCK_G57PORT_PORT
TEXT
EOF
expect_fail "G57b0e a quoted heredoc token is not a port read" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
cat <<FIRST <<SECOND
first body
FIRST
renderer --api-port "${AIRLOCK_G57PORT_PORT:?}"
SECOND
EOF
expect_fail "G57b0e1 a second heredoc body is not command-argument evidence" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
port=$(printf 9999); printf '%s\n' "airlock_config get apps.g57port.port"
EOF
expect_fail "G57b0f a quoted get outside the assigned substitution is not a port read" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
rm -f "$pkg/smoke.py"
rm -f "$pkg/decoy.service"
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
: "${AIRLOCK_G57PORT_PORT:?}"
EOF
chmod +x "$pkg/install.sh"
expect_fail "G57b1 a shell no-op is not port consumption evidence" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
dummy=1; : "${AIRLOCK_G57PORT_PORT:?}"
EOF
expect_fail "G57b1a a prefixed shell no-op is not port consumption evidence" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
if true; then : "${AIRLOCK_G57PORT_PORT:?}"; fi
EOF
expect_fail "G57b1b a branch-contained shell no-op is not port consumption evidence" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
command : "${AIRLOCK_G57PORT_PORT:?}"
EOF
expect_fail "G57b1c a command-wrapped shell no-op is not port consumption evidence" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
builtin : "${AIRLOCK_G57PORT_PORT:?}"
EOF
expect_fail "G57b1d a builtin-wrapped shell no-op is not port consumption evidence" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
true --port "${AIRLOCK_G57PORT_PORT:?}"
EOF
expect_fail "G57b1da a true command argument is not port consumption evidence" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
IGNORED=1 true --port "${AIRLOCK_G57PORT_PORT:?}"
EOF
expect_fail "G57b1db an assignment-prefixed true argument is not port consumption evidence" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
env IGNORED=1 true --port "${AIRLOCK_G57PORT_PORT:?}"
EOF
expect_fail "G57b1dc an env-wrapped true argument is not port consumption evidence" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
env -i true --port "${AIRLOCK_G57PORT_PORT:?}"
EOF
expect_fail "G57b1dd an option-bearing env true wrapper is not consumption evidence" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
env -u IGNORED true --port "${AIRLOCK_G57PORT_PORT:?}"
EOF
expect_fail "G57b1de an env option value cannot hide a true no-op" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
env -S 'env -S true' --port "${AIRLOCK_G57PORT_PORT:?}"
EOF
expect_fail "G57b1df nested env split-string cannot synthesize a passing true no-op" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
/usr/bin/true --port "${AIRLOCK_G57PORT_PORT:?}"
EOF
expect_fail "G57b1dg a path-qualified true command is not consumption evidence" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
/usr/bin/env -i true --port "${AIRLOCK_G57PORT_PORT:?}"
EOF
expect_fail "G57b1dh a path-qualified env wrapper is not consumption evidence" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
env -i /usr/bin/true --port "${AIRLOCK_G57PORT_PORT:?}"
EOF
expect_fail "G57b1di env cannot hide a path-qualified true no-op" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
if : "${AIRLOCK_G57PORT_PORT:?}"; then true; fi
EOF
expect_fail "G57b1e a no-op condition is not port consumption evidence" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
case x in x) : "${AIRLOCK_G57PORT_PORT:?}";; esac
EOF
expect_fail "G57b1f a case-contained no-op is not port consumption evidence" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
airlock_config get apps.g57port.port >/dev/null
EOF
expect_fail "G57b2 a discarded config get is not port consumption evidence" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/smoke.py" <<'PY'
import os
port = int(os.environ["AIRLOCK_G57PORT_PORT"])
assert port > 0
PY
expect_ok "G57b3 a real Python environment read satisfies the contract" \
  run "$cfg" validate
rm -f "$pkg/smoke.py"
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
port="${AIRLOCK_G57PORT_PORT:?}"
printf 'Environment=PORT=%s\n' "$port" >"$TMPDIR/g57port.unit"
EOF
chmod +x "$pkg/install.sh"
expect_ok "G57c consuming the same declared port turns the fixture green" \
  run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${AIRLOCK_G57PORT_PORT:?}"
EOF
expect_fail "G57c1 an arbitrary command argument is not listener ownership evidence" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "diagnostic --port ${AIRLOCK_G57PORT_PORT:?}"
EOF
expect_fail "G57c2 a port-shaped phrase inside one quoted argument stays inert" \
  "declares port-ownership config key(s) its files never read: port" run "$cfg" validate

# Follow-up incident control (2026-08-30): claude-fleet passes the platform
# value straight to its package installer. This is the exact logical command
# shape from the out-of-tree claude-fleet install.sh, including the
# shell line continuations that the scanner normalises before classification.
reset_box
pkg="$PKGROOT/g57-claude-fleet-argv"; mkpkg "$pkg" claude-fleet
pkg_manifest "$pkg" 'contract = 1' 'id = "claude-fleet"' \
  '[config.defaults]' 'api_port = 18830' 'control_host = "control"' \
  'key_host = "key"' 'key_file = "/tmp/key"' 'smoke_box = "box"'
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
/usr/bin/python3 -B "$artifact/package.py" install --artifact "$artifact" \
  --api-port "${AIRLOCK_CLAUDE_FLEET_API_PORT:?}" \
  --control-host "${AIRLOCK_CLAUDE_FLEET_CONTROL_HOST:?}" \
  --key-host "${AIRLOCK_CLAUDE_FLEET_KEY_HOST:?}" \
  --key-file "${AIRLOCK_CLAUDE_FLEET_KEY_FILE:?}"
EOF
chmod +x "$pkg/install.sh"
cfg="$CFGROOT/g57-claude-fleet-argv.toml"
make_pkg_cfg "$cfg" claude-fleet "$pkg"
expect_ok "G57d claude-fleet multiline command argument consumes api_port" \
  run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
renderer --listen-port="${AIRLOCK_CLAUDE_FLEET_API_PORT:?}"
EOF
expect_ok "G57d0 an equals-form --*-port argument consumes api_port" \
  run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
renderer --listen-port="${AIRLOCK_CLAUDE_FLEET_API_PORT:?}-suffix"
EOF
expect_fail "G57d0a a modified port option value is not ownership evidence" \
  "declares port-ownership config key(s) its files never read: api_port" run "$cfg" validate
cat >"$pkg/smoke.sh" <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/python3 -B "$current/package.py" smoke \
  --box "${AIRLOCK_CLAUDE_FLEET_SMOKE_BOX:?}" \
  --port "${AIRLOCK_CLAUDE_FLEET_API_PORT:?}"
EOF
chmod +x "$pkg/smoke.sh"
expect_ok "G57d1 claude-fleet smoke --port argument consumes api_port" \
  run "$cfg" validate

# A bare `port` and the conventional `*_port` spelling join one ownership
# pool. Both packages really read their values, so this probes uniqueness
# independently of the unread-port gate above.
reset_box
left="$PKGROOT/g57-port-left"; mkpkg "$left" g57left
pkg_manifest "$left" 'contract = 1' 'id = "g57left"' '[config.defaults]' 'backend_port = 18832'
cat >"$left/install.sh" <<'EOF'
#!/usr/bin/env bash
port="${AIRLOCK_G57LEFT_BACKEND_PORT:?}"
test "$port" -gt 0
EOF
right="$PKGROOT/g57-port-right"; mkpkg "$right" g57right
pkg_manifest "$right" 'contract = 1' 'id = "g57right"' '[config.defaults]' 'port = 18832'
cat >"$right/install.sh" <<'EOF'
#!/usr/bin/env bash
port="${AIRLOCK_G57RIGHT_PORT:?}"
test "$port" -gt 0
EOF
chmod +x "$left/install.sh" "$right/install.sh"
cfg="$CFGROOT/g57-port-collision.toml"
{
  base_config
  printf '[apps.g57left]\n[apps.g57right]\n'
  printf '[packages.g57left]\npath = "%s"\n' "$left"
  printf '[packages.g57right]\npath = "%s"\n' "$right"
} >"$cfg"
expect_fail "G57d bare port collides with backend_port" \
  "port 18832 is used twice" run "$cfg" validate
sed -i 's/port = 18832/port = 18833/' "$right/airlock-app.toml"
expect_ok "G57e moving the bare port turns the collision fixture green" \
  run "$cfg" validate

# Port ownership can also be declared semantically under a non-port-shaped
# name. It must get the same read gate; checking names alone would leave the
# explicit manifest surfaces as a second escape route.
reset_box
pkg="$PKGROOT/g57-semantic-port"; mkpkg "$pkg" g57semantic
pkg_manifest "$pkg" 'contract = 1' 'id = "g57semantic"' \
  '[config.defaults]' 'listen = 18834' 'target = 18835' \
  '[artifacts]' 'serve_ports = ["listen"]' \
  '[serve.https]' 'listen = "target"'
semantic_pkg="$pkg"
cfg="$CFGROOT/g57-semantic-port.toml"; make_pkg_cfg "$cfg" g57semantic "$pkg"
expect_fail "G57f unread package-owned semantic target is fatal" \
  "files never read: target" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
target="${AIRLOCK_G57SEMANTIC_TARGET:?}"
test "$target" -gt 0
EOF
chmod +x "$pkg/install.sh"
expect_ok "G57g platform-owned listen needs no fake package read; consumed target is green" \
  run "$cfg" validate

# A key can be platform-owned as one HTTPS mapping's listen and package-owned
# as another mapping's target. Target ownership must win over the listen
# exemption or role overlap recreates the unread-listener escape.
reset_box
pkg="$PKGROOT/g57-overlap-port"; mkpkg "$pkg" g57overlap
pkg_manifest "$pkg" 'contract = 1' 'id = "g57overlap"' \
  '[config.defaults]' 'listen = 18837' 'target = 18838' 'backend = 18839' \
  '[artifacts]' 'serve_ports = ["listen", "target"]' \
  '[serve.https]' 'listen = "target"' 'target = "backend"'
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
backend="${AIRLOCK_G57OVERLAP_BACKEND:?}"
test "$backend" -gt 0
EOF
chmod +x "$pkg/install.sh"
cfg="$CFGROOT/g57-overlap-port.toml"; make_pkg_cfg "$cfg" g57overlap "$pkg"
expect_fail "G57g1 target/listen overlap keeps the package target fatal" \
  "files never read: target" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
target="${AIRLOCK_G57OVERLAP_TARGET:?}"
backend="${AIRLOCK_G57OVERLAP_BACKEND:?}"
test "$target" -ne "$backend"
EOF
expect_ok "G57g2 consuming the overlapping package target turns it green" \
  run "$cfg" validate

# The target is not named *_port, but [serve.https] makes it a real loopback
# target. It must collide with an ordinary backend_port just like two named
# port keys do.
other="$PKGROOT/g57-semantic-other"; mkpkg "$other" g57semanticother
pkg_manifest "$other" 'contract = 1' 'id = "g57semanticother"' \
  '[config.defaults]' 'backend_port = 18835'
cat >"$other/install.sh" <<'EOF'
#!/usr/bin/env bash
port="${AIRLOCK_G57SEMANTICOTHER_BACKEND_PORT:?}"
test "$port" -gt 0
EOF
chmod +x "$other/install.sh"
{
  base_config
  printf '[apps.g57semantic]\n[apps.g57semanticother]\n'
  printf '[packages.g57semantic]\npath = "%s"\n' "$semantic_pkg"
  printf '[packages.g57semanticother]\npath = "%s"\n' "$other"
} >"$cfg"
expect_fail "G57h semantic serve target collides with backend_port" \
  "port 18835 is used twice" run "$cfg" validate
sed -i 's/backend_port = 18835/backend_port = 18836/' "$other/airlock-app.toml"
expect_ok "G57i moving the semantic target peer turns the fixture green" \
  run "$cfg" validate

# Nested table leaves are still config-owned listeners. Without this control a
# package can move the exact same `port` spelling one level down and escape both
# the read gate and the global pool.
reset_box
pkg="$PKGROOT/g57-nested-port"; mkpkg "$pkg" g57nested
pkg_manifest "$pkg" 'contract = 1' 'id = "g57nested"' \
  '[config.tables.listener]' 'allowed_keys = ["port"]'
cfg="$CFGROOT/g57-nested-port.toml"
{
  base_config
  printf '[apps.g57nested]\n[apps.g57nested.listener]\nport = 19904\n'
  printf '[packages.g57nested]\npath = "%s"\n' "$pkg"
} >"$cfg"
expect_fail "G57j an unread nested port declaration is fatal" \
  "files never read: listener.port" run "$cfg" validate
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
port="$(airlock_config get apps.g57nested.listener.port)"
test "$port" -gt 0
EOF
chmod +x "$pkg/install.sh"
sed -i 's/port = 19904/port = 19902/' "$cfg"
expect_fail "G57k a nested port collides with a top-level port" \
  "port 19902 is used twice" run "$cfg" validate
sed -i 's/port = 19902/port = 19904/' "$cfg"
expect_ok "G57l moving the nested port turns the fixture green" \
  run "$cfg" validate

reset_box
pkg="$PKGROOT/g58-exclusions"; mkpkg "$pkg" g58
printf '%s\n' 'AIRLOCK_G58_NOPE' >"$pkg/README"
mkdir -p "$pkg/docs"
printf '%s\n' 'AIRLOCK_G58_NOPE' >"$pkg/docs/x.txt"
dd if=/dev/zero of="$pkg/large.txt" bs=1048577 count=1 2>/dev/null
printf '%s\n' 'AIRLOCK_G58_NOPE' >>"$pkg/large.txt"
printf '\377AIRLOCK_G58_NOPE\n' >"$pkg/nonutf8.bin"
excluded_target="$TMP/g58-target.txt"
printf '%s\n' 'AIRLOCK_G58_NOPE' >"$excluded_target"
ln -s "$excluded_target" "$pkg/linked.txt"
cfg="$CFGROOT/g58.toml"; make_pkg_cfg "$cfg" g58 "$pkg"
out58="$(run "$cfg" validate 2>&1)"; rc58=$?
if [ "$rc58" = 0 ]; then
  ok "G58 F12 excludes README/docs/large/binary/symlinked files"
else
  bad "G58 F12 exclusions (rc=$rc58)"
  failure_detail "$out58"
fi
# Positive control: the SAME token in an ordinary included file must be fatal
# — without this, gutting the scanner entirely would leave G58 green.
printf '%s\n' 'x="$AIRLOCK_G58_NOPE"' >"$pkg/included.txt"
expect_warn "G58b the same token in an included file is reported (scan is live)" \
  "is neither a declared config key nor a declared [config].runtime_env name" run "$cfg" validate
rm -f "$pkg/included.txt"

reset_box
pkg="$PKGROOT/g59-env-whole-table"; mkpkg "$pkg" g59
pkg_manifest "$pkg" 'contract = 1' 'id = "g59"' '[config.defaults]' 'unused = "value"'
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
airlock_config env g59 >/dev/null
EOF
chmod +x "$pkg/install.sh"
cfg="$CFGROOT/g59.toml"; make_pkg_cfg "$cfg" g59 "$pkg"
out59="$(run "$cfg" validate 2>&1)"; rc59=$?
if [ "$rc59" = 0 ] && grep -Fq "never read" <<<"$out59" \
    && ! grep -Fq "silently reads as nothing" <<<"$out59"; then
  ok "G59 whole-table env export is not an F12 read"
else
  bad "G59 whole-table env export F12 behavior (rc=$rc59)"
  failure_detail "$out59"
fi

# =============================================================================
# H. F14 webjson/render
# =============================================================================

reset_box
pkg="$PKGROOT/h60-glyph"; mkpkg "$pkg" h60
pkg_manifest "$pkg" 'contract = 1' 'id = "h60"' '[tile]' 'label = "H60"' 'sub = "Glyph"' 'cat = "coding"' 'glyph = "terminal"' '[audience]' 'supported = ["shared", "owner"]' 'default = "owner"'
cfg="$CFGROOT/h60-glyph.toml"; make_pkg_cfg "$cfg" h60 "$pkg"
glyph_json="$(run "$cfg" webjson 2>/dev/null)"; rc_glyph=$?
icon_pkg="$PKGROOT/h60-icon"; mkpkg "$icon_pkg" h60icon
printf 'icon\n' >"$icon_pkg/icon.svg"
pkg_manifest "$icon_pkg" 'contract = 1' 'id = "h60icon"' '[tile]' 'label = "H60 icon"' 'sub = "Icon"' 'cat = "docs"' 'icon = "icon.svg"' '[audience]' 'supported = ["shared"]' 'default = "shared"'
icon_cfg="$CFGROOT/h60-icon.toml"; make_pkg_cfg "$icon_cfg" h60icon "$icon_pkg"
icon_json="$(run "$icon_cfg" webjson 2>/dev/null)"; rc_icon_json=$?
webjson_ok=0
if [ "$rc_glyph" = 0 ] && [ "$rc_icon_json" = 0 ]; then
  printf '%s' "$glyph_json" | python3 -c 'import json,sys; e=json.load(sys.stdin)["apps"]["h60"]; assert e["audience"]=="owner"; assert e["tile"]=={"label":"H60","sub":"Glyph","cat":"coding","glyph":"terminal"}' >/dev/null 2>&1
  glyph_rc=$?
  printf '%s' "$icon_json" | python3 -c 'import json,sys; assert json.load(sys.stdin)["apps"]["h60icon"]["tile"]["icon"]=="/assets/apps/h60icon/icon.svg"' >/dev/null 2>&1
  icon_rc=$?
  [ "$glyph_rc" = 0 ] && [ "$icon_rc" = 0 ] && webjson_ok=1
fi
if [ "$webjson_ok" = 1 ]; then
  ok "H60 webjson carries audience/tile glyph and staged icon forms"
else
  bad "H60 webjson packaged tile/audience (glyph=$rc_glyph icon=$rc_icon_json)"
  printf '%s\n' "$glyph_json" | sed 's/^/    /'
  printf '%s\n' "$icon_json" | sed 's/^/    /'
fi

reset_box
pkg="$PKGROOT/h61-no-tile"; mkpkg "$pkg" h61
cfg="$CFGROOT/h61.toml"; make_pkg_cfg "$cfg" h61 "$pkg"
no_tile_json="$(run "$cfg" webjson 2>/dev/null)"; rc_no_tile=$?
no_tile_ok=0
if [ "$rc_no_tile" = 0 ]; then
  printf '%s' "$no_tile_json" | python3 -c 'import json,sys; assert "tile" not in json.load(sys.stdin)["apps"]["h61"]' >/dev/null 2>&1 && no_tile_ok=1
fi
if [ "$no_tile_ok" = 1 ]; then
  ok "H61 package without tile omits webjson tile key"
else
  bad "H61 no-tile webjson (rc=$rc_no_tile)"
  printf '%s\n' "$no_tile_json" | sed 's/^/    /'
fi

render_cfg() {
  local config="$1"
  AIRLOCK_CONFIG="$config" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
    "$ROOT/install/render-nginx.sh"
}

# Child 4/P3 flip: role is UNCONDITIONAL now (D7/F14 stage 4) — a hub-only,
# zero-package box carries the same role map/field as a box with an
# audience-declaring package. Stage 3's conditional behaviour (builtin_render
# carrying no $airlock_role) is gone.
reset_box
cfg="$CFGROOT/h62-builtins.toml"; base_config >"$cfg"
builtin_render="$(render_cfg "$cfg" 2>&1)"; rc_builtin_render=$?
role_pkg="$PKGROOT/h62-role"; mkpkg "$role_pkg" h62
pkg_manifest "$role_pkg" 'contract = 1' 'id = "h62"' '[audience]' 'supported = ["shared", "owner"]' 'default = "shared"'
role_cfg="$CFGROOT/h62-role.toml"; make_pkg_cfg "$role_cfg" h62 "$role_pkg"
role_render="$(render_cfg "$role_cfg" 2>&1)"; rc_role_render=$?
if [ "$rc_builtin_render" = 0 ] \
   && grep -Fq 'map $owner_ok $airlock_role' <<<"$builtin_render" \
   && grep -Fq '"role":"$airlock_role"' <<<"$builtin_render" \
   && [ "$rc_role_render" = 0 ] \
   && grep -Fq 'map $owner_ok $airlock_role' <<<"$role_render" \
   && grep -Fq '"role":"$airlock_role"' <<<"$role_render"; then
  ok "H62 nginx role map and whoami role are unconditional (present with and without an audience package)"
else
  bad "H62 unconditional nginx role (builtin=$rc_builtin_render role=$rc_role_render)"
  failure_detail "$builtin_render"
  failure_detail "$role_render"
fi

reset_box
pkg="$PKGROOT/h63-audience-render"; mkpkg "$pkg" h63
pkg_manifest "$pkg" 'contract = 1' 'id = "h63"' '[audience]' 'supported = ["shared"]' 'default = "shared"'
cfg="$CFGROOT/h63.toml"; make_pkg_cfg "$cfg" h63 "$pkg" 'audience = "owner"'
render_bad="$(render_cfg "$cfg" 2>&1)"; rc_render_bad=$?
if [ "$rc_render_bad" -ne 0 ] && grep -Fq "supported audiences" <<<"$render_bad"; then
  ok "H63 render fails when configured audience is unsupported"
else
  bad "H63 render unsupported audience (rc=$rc_render_bad)"
  failure_detail "$render_bad"
fi

# ---- G60b: a get read with an invalid key chain is fatal, not truncated -----
# `apps.<id>.port-bad` must not silently match a declared `port` prefix and
# pass validate for a read that fails at runtime.
reset_box
pkg="$PKGROOT/g60b-badchain"; mkpkg "$pkg" g60b
pkg_manifest "$pkg" 'contract = 1' 'id = "g60b"' '[config.defaults]' 'port = 18930'
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
airlock_config get apps.g60b.port-bad
EOF
printf '#!/usr/bin/env bash\nport="${AIRLOCK_G60B_PORT:?}"\ntest "$port" -gt 0\n' >"$pkg/smoke.sh"
chmod +x "$pkg"/*.sh
cfg="$CFGROOT/g60b.toml"; make_pkg_cfg "$cfg" g60b "$pkg"
expect_warn "G60b invalid key chain in a get read warns (no prefix truncation)" \
  "not a valid key chain" run "$cfg" validate
# The same truncation must be impossible with ANY punctuation, not just '-':
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
airlock_config get apps.g60b.port/evil
EOF
chmod +x "$pkg/install.sh"
expect_warn "G60c a slash tail cannot truncate-match a declared key either" \
  "not a valid key chain" run "$cfg" validate
# And a LEGITIMATE read inside command substitution must not false-fatal on
# the closing parenthesis:
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
p="$(airlock_config get apps.g60b.port)"
EOF
chmod +x "$pkg/install.sh"
expect_ok "G60d a declared read inside \$(...) is clean (no ')' capture)" \
  run "$cfg" validate
# G60e: every way of GLUING more text onto the argument is refused as
# unanalysable rather than analysed as its visible prefix — the scanner
# cannot expand shell quoting, so it must not guess.
# Literal glue: the joined key is what bash passes, so an undeclared one
# warns like any other literal read. (Backtick/$VAR forms are RUNTIME-built —
# see G60i: the scanner must not guess what they expand to.)
for tail in "port'evil'" 'port.' 'port,x' 'port"x"'; do
  cat >"$pkg/install.sh" <<EOF
#!/usr/bin/env bash
airlock_config get apps.g60b.$tail
EOF
  chmod +x "$pkg/install.sh"
  out60e="$(run "$cfg" validate 2>&1)"; rc60e=$?
  if [ "$rc60e" = 0 ] && grep -Eq "not a valid key chain|does not declare" <<<"$out60e"; then
    ok "G60e glued argument ${tail} is reported, not silently accepted"
  else
    bad "G60e glued argument ${tail} (rc=$rc60e)"
    failure_detail "$out60e"
  fi
done
for tail in 'port`printf evil`' 'port$X'; do
  cat >"$pkg/install.sh" <<EOF
#!/usr/bin/env bash
airlock_config get apps.g60b.$tail
EOF
  chmod +x "$pkg/install.sh"
  out60e="$(run "$cfg" validate 2>&1)"; rc60e=$?
  if [ "$rc60e" = 0 ] && grep -Fq "builds the key for apps.g60b." <<<"$out60e"; then
    ok "G60e runtime-built argument ${tail} warns"
  else
    bad "G60e runtime-built ${tail} (rc=$rc60e)"
    failure_detail "$out60e"
  fi
done
# ...and a continuation SPLICING two halves into one word is refused too.
printf '#!/usr/bin/env bash\nairlock_config get apps.g60b.port\\\nevil\n' >"$pkg/install.sh"
chmod +x "$pkg/install.sh"
# The splice joins the halves exactly as bash does, so the key really read
# (portevil) is what gets judged — undeclared, therefore fatal.
expect_warn "G60f a backslash-spliced argument is read as the joined key" \
  "reads apps.g60b.portevil" run "$cfg" validate
# G60g: a QUOTED plain literal is the same key as the unquoted form and must
# validate cleanly — fail-closed must not mean fail-noisy on correct code.
for form in '"apps.g60b.port"' "'apps.g60b.port'" 'apps.g60b."port"'; do
  cat >"$pkg/install.sh" <<EOF
#!/usr/bin/env bash
airlock_config get $form
EOF
  chmod +x "$pkg/install.sh"
  expect_ok "G60g quoted literal ${form} validates like the bare form" \
    run "$cfg" validate
done
# G60h: an escaped-but-literal argument reads the SAME key bash would, so an
# undeclared one must still be caught (a text matcher sees no call at all).
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
airlock_config get a\pps.g60b.port-bad
EOF
chmod +x "$pkg/install.sh"
expect_warn "G60h a backslash-escaped call site is still scanned" \
  "not a valid key chain" run "$cfg" validate
# G60i: a genuinely dynamic key is refused as unresolvable, not guessed.
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
k=port
airlock_config get apps.g60b.$k
EOF
chmod +x "$pkg/install.sh"
out60i="$(run "$cfg" validate 2>&1)"; rc60i=$?
if [ "$rc60i" = 0 ] && grep -Fq "builds the key for apps.g60b." <<<"$out60i"; then
  ok "G60i a runtime-built key still warns about its literal prefix"
else
  bad "G60i dynamic key handling (rc=$rc60i)"
  failure_detail "$out60i"
fi
# G60j: ANSI-C quoting yields a literal, so a bad key inside $'…' is caught.
cat >"$pkg/install.sh" <<'SH'
#!/usr/bin/env bash
airlock_config get $'apps.g60b.port-bad'
SH
chmod +x "$pkg/install.sh"
expect_warn "G60j an ANSI-C quoted bad key is still caught" \
  "not a valid key chain" run "$cfg" validate
# G60k: bash keeps a backslash before an ordinary char inside double quotes,
# so "po\rt" is NOT the declared 'port'.
printf '#!/usr/bin/env bash\nairlock_config get "apps.g60b.po\\rt"\n' >"$pkg/install.sh"
chmod +x "$pkg/install.sh"
expect_warn "G60k a backslash inside double quotes stays literal" \
  "not a valid key chain" run "$cfg" validate
# G60v: a nested subshell/process substitution inside "$( … )" must not end
# the substitution early — the call after it is still code.
cat >"$pkg/install.sh" <<'SH'
#!/usr/bin/env bash
p="$( cat <(printf x); airlock_config get apps.g60b.nested_missing )"
SH
chmod +x "$pkg/install.sh"
expect_warn "G60v a call after a nested subshell inside \"\$( )\" is scanned" \
  "which the manifest does not declare" run "$cfg" validate
# G60w: a MULTILINE quoted usage block is documentation on every line of it.
cat >"$pkg/install.sh" <<'SH'
#!/usr/bin/env bash
echo 'usage:
  airlock_config get apps.g60b.doc_line
'
port="$(airlock_config get apps.g60b.port)"
test "$port" -gt 0
SH
chmod +x "$pkg/install.sh"
expect_ok "G60w a multiline quoted usage block is not scanned" run "$cfg" validate

# G60t: an arithmetic shift is not a here-doc — the linter must keep working
# for the rest of the file.
cat >"$pkg/install.sh" <<'SH'
#!/usr/bin/env bash
mask=$(( 1 << 4 ))
airlock_config get apps.g60b.after_shift >/dev/null
SH
chmod +x "$pkg/install.sh"
expect_warn "G60t an arithmetic shift does not mask the rest of the file" \
  "which the manifest does not declare" run "$cfg" validate
# G60u: a backslash-quoted here-doc delimiter still masks its body.
cat >"$pkg/install.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null <<\USAGE
example: airlock_config get apps.g60b.doc_only
USAGE
port="$(airlock_config get apps.g60b.port)"
test "$port" -gt 0
SH
chmod +x "$pkg/install.sh"
expect_ok "G60u a <<\\DELIM here-doc body is not scanned" run "$cfg" validate

# G60p: the most common real call form — a command substitution inside a
# quoted assignment — must be SCANNED, not written off as quoted talk.
cat >"$pkg/install.sh" <<'SH'
#!/usr/bin/env bash
p="$(airlock_config get apps.g60b.nope_key)"
SH
chmod +x "$pkg/install.sh"
expect_warn "G60p a call inside \"\$(...)\" is scanned (not treated as talk)" \
  "which the manifest does not declare" run "$cfg" validate
# G60q: a here-STRING is not a here-doc, so the code after it stays scanned.
cat >"$pkg/install.sh" <<'SH'
#!/usr/bin/env bash
grep -q x <<<"marker" || true
airlock_config get apps.g60b.also_missing >/dev/null
SH
chmod +x "$pkg/install.sh"
expect_warn "G60q a here-string does not mask the code that follows" \
  "which the manifest does not declare" run "$cfg" validate
# G60r: an escaped quote inside a string must not desynchronise the reader.
cat >"$pkg/install.sh" <<'SH'
#!/usr/bin/env bash
echo "say \"hi"
airlock_config get apps.g60b.still_missing >/dev/null
SH
chmod +x "$pkg/install.sh"
expect_warn "G60r an escaped quote does not hide the next line's call" \
  "which the manifest does not declare" run "$cfg" validate
# G60s: an env reference in a COMMENT is talk; one inside a quoted string is
# a real expansion ("$AIRLOCK_X_Y" is how every script reads a value), so the
# two must be classified differently.
cat >"$pkg/install.sh" <<'SH'
#!/usr/bin/env bash
# example: AIRLOCK_G60B_DOC_ONLY
port="$(airlock_config get apps.g60b.port)"
test "$port" -gt 0
SH
chmod +x "$pkg/install.sh"
expect_ok "G60s an env reference in a comment is not a read" \
  run "$cfg" validate
cat >"$pkg/install.sh" <<'SH'
#!/usr/bin/env bash
echo "value is $AIRLOCK_G60B_QUOTED_KEY"
SH
chmod +x "$pkg/install.sh"
expect_warn "G60s2 an env expansion inside a quoted string IS a read" \
  "is neither a declared config key nor a declared [config].runtime_env name" run "$cfg" validate

# G60m: an ANSI-C escape inside the key is a C decoding this reader does not
# do, so it WARNS (never judged on the raw bytes).
cat >"$pkg/install.sh" <<'SH'
#!/usr/bin/env bash
airlock_config get $'apps.g60b.po\162t'
SH
chmod +x "$pkg/install.sh"
out60m="$(run "$cfg" validate 2>&1)"; rc60m=$?
if [ "$rc60m" = 0 ] && grep -Fq "builds the key for apps.g60b." <<<"$out60m"; then
  ok "G60m an ANSI-C escaped key warns instead of false-fataling"
else
  bad "G60m ANSI-C escape (rc=$rc60m)"
  failure_detail "$out60m"
fi
# G60n: a here-doc BODY is data, not code — a usage message that mentions an
# undeclared key must not fail the package.
cat >"$pkg/install.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null <<'USAGE'
example: airlock_config get apps.g60b.not_a_real_key
USAGE
port="$(airlock_config get apps.g60b.port)"
test "$port" -gt 0
SH
chmod +x "$pkg/install.sh"
expect_ok "G60n a here-doc body is not scanned as code" run "$cfg" validate
# G60o: an example inside a quoted string, and one after `;#`, are talk.
cat >"$pkg/install.sh" <<'SH'
#!/usr/bin/env bash
echo "usage: airlock_config get apps.g60b.some_key"
true ;# airlock_config get apps.g60b.other_key
port="$(airlock_config get apps.g60b.port)"
test "$port" -gt 0
SH
chmod +x "$pkg/install.sh"
expect_ok "G60o quoted and ;#-commented examples are not call sites" \
  run "$cfg" validate

# G60l: a commented-out example is not a call site.
cat >"$pkg/install.sh" <<'SH'
#!/usr/bin/env bash
# airlock_config get apps.g60b.example_key
port="$(airlock_config get apps.g60b.port)"
SH
chmod +x "$pkg/install.sh"
expect_ok "G60l a commented example is not scanned as a call" \
  run "$cfg" validate

# ---- H64: audience flip re-renders the package gate on the next run (F14) ---
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
  bash "$ROOT/install/airlock-install.sh" 2>&1)"; rc64a=$?
gate_a="$(cat "$CONFD/servers.d/h64-gate.conf" 2>/dev/null)"
make_pkg_cfg "$cfg" h64 "$pkg" 'audience = "owner"'
out64b="$(env AIRLOCK_CONFIG="$cfg" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
  bash "$ROOT/install/airlock-install.sh" 2>&1)"; rc64b=$?
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
out24="$(env AIRLOCK_CONFIG="$cfg" AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf" \
  bash "$ROOT/install/airlock-install.sh" 2>&1)"; rc24=$?
if [ "$rc24" -ne 0 ] && grep -Fq "regular non-symlink file" <<<"$out24" \
   && ! grep -Fq "smoke: swapapp" <<<"$out24"; then
  ok "A24b smoke.sh swapped to a symlink after validation fails the run"
else
  bad "A24b symlink swap (rc=$rc24)"
  failure_detail "$out24"
fi

# F57: intent teardown must not delete through a directory that became a
# symlink AFTER the artifact was created — expansion canonicalises the parent
# chain, so the evidence has to be caught while the raw match is in hand.
reset_box
pkg="$PKGROOT/f57-intent-redirect"; mkpkg "$pkg" f57
mkdir -p "$FAKEHOME/f57dir" "$TMP/f57-victim"
printf 'precious\n' >"$TMP/f57-victim/owned.txt"
pkg_manifest "$pkg" 'contract = 1' 'id = "f57"' \
  '[artifacts]' 'files = ["~/f57dir/owned.txt"]'
cfg="$CFGROOT/f57.toml"; make_pkg_cfg "$cfg" f57 "$pkg"
info="$(run "$cfg" package-info 2>/dev/null)"
ledger_run "$info" intent f57 >/dev/null 2>&1 || bad "F57 setup intent failed"
printf 'installed\n' >"$FAKEHOME/f57dir/owned.txt"
rm -rf "$FAKEHOME/f57dir"
ln -s "$TMP/f57-victim" "$FAKEHOME/f57dir"
drop_cfg="$CFGROOT/f57-drop.toml"; base_config >"$drop_cfg"
drop_info="$(run "$drop_cfg" package-info 2>/dev/null)"
out57="$(ledger_run "$drop_info" remove f57 2>&1)"; rc57=$?
if [ "$rc57" -ne 0 ] && grep -Fq "no longer names what it claimed" <<<"$out57" \
   && [ -f "$TMP/f57-victim/owned.txt" ]; then
  ok "F57 intent teardown refuses a redirected parent (victim untouched)"
else
  bad "F57 intent redirect (rc=$rc57, victim=$([ -f "$TMP/f57-victim/owned.txt" ] && echo kept || echo GONE))"
  failure_detail "$out57"
fi
rm -f "$FAKEHOME/f57dir"

# F58: a trailing slash in a webroot claim names the same object as the bare
# form, so an app that symlinks its OWN claimed directory must still tear down.
reset_box
pkg="$PKGROOT/f58-trailing"; mkpkg "$pkg" f58
pkg_manifest "$pkg" 'contract = 1' 'id = "f58"' \
  '[artifacts]' 'webroot = ["f58dir/"]'
cfg="$CFGROOT/f58.toml"; make_pkg_cfg "$cfg" f58 "$pkg"
info="$(run "$cfg" package-info 2>/dev/null)"
ledger_run "$info" intent f58 >/dev/null 2>&1 || bad "F58 setup intent failed"
mkdir -p "$TMP/f58-elsewhere"
ln -s "$TMP/f58-elsewhere" "$WEB/f58dir"
drop_cfg="$CFGROOT/f58-drop.toml"; base_config >"$drop_cfg"
drop_info="$(run "$drop_cfg" package-info 2>/dev/null)"
out58="$(ledger_run "$drop_info" remove f58 2>&1)"; rc58=$?
if [ "$rc58" = 0 ] && [ ! -e "$WEB/f58dir" ] && [ -d "$TMP/f58-elsewhere" ]; then
  ok "F58 a trailing-slash claim tears down (its own symlink is the leaf)"
else
  bad "F58 trailing-slash anchor (rc=$rc58)"
  failure_detail "$out58"
fi

# F58b: a record written by an intermediate build (which anchored a trailing-
# slash claim one level deeper) must still tear down — an unremovable record
# is the exact failure the anchor mechanism exists to prevent.
reset_box
pkg="$PKGROOT/f58b-legacy"; mkpkg "$pkg" f58b
pkg_manifest "$pkg" 'contract = 1' 'id = "f58b"' \
  '[artifacts]' 'webroot = ["f58bdir/"]'
cfg="$CFGROOT/f58b.toml"; make_pkg_cfg "$cfg" f58b "$pkg"
info="$(run "$cfg" package-info 2>/dev/null)"
ledger_run "$info" intent f58b >/dev/null 2>&1 || bad "F58b setup intent failed"
mkdir -p "$WEB/f58bdir"
python3 -c '
import json, os, sys
path = sys.argv[1]
d = json.load(open(path))
a = d["entries"]["f58b"]["intent"]["anchors"]
for k in list(a):
    a[k] = os.path.join(a[k], "f58bdir")
json.dump(d, open(path, "w"))
' "$STATE/app-ledger.json"
drop_cfg="$CFGROOT/f58b-drop.toml"; base_config >"$drop_cfg"
drop_info="$(run "$drop_cfg" package-info 2>/dev/null)"
out58b="$(ledger_run "$drop_info" remove f58b 2>&1)"; rc58b=$?
if [ "$rc58b" = 0 ] && [ ! -e "$WEB/f58bdir" ]; then
  ok "F58b a record with the older trailing-slash anchor still tears down"
else
  bad "F58b legacy anchor compatibility (rc=$rc58b)"
  failure_detail "$out58b"
fi

# ---- review round 1 regressions (sol/opus majors) ---------------------------

# A22b: 'audience' colliding into [config.defaults] must be fatal — otherwise
# the defaults branch of the type checker matches first and the D7 supported-
# membership check is silently skipped (fail-open on the gate value).
reset_box
pkg="$PKGROOT/a22b-aud-collision"; mkpkg "$pkg" a22b
pkg_manifest "$pkg" 'contract = 1' 'id = "a22b"' \
  '[audience]' 'supported = ["shared", "owner"]' 'default = "owner"' \
  '[config.defaults]' 'audience = "shared"'
cfg="$CFGROOT/a22b.toml"; make_pkg_cfg "$cfg" a22b "$pkg" 'audience = "anything-at-all"'
expect_fail "A22b audience declared in [config] is fatal (platform-owned key)" \
  "platform-owned config key" run "$cfg" validate

# A25: an out-of-range value on a declared NON-_port serve key still dies at
# the serve-value check (the range guard the F10 rewrite moved past).
reset_box
pkg="$PKGROOT/a25-range"; mkpkg "$pkg" a25 listen
pkg_manifest "$pkg" 'contract = 1' 'id = "a25"' \
  '[config.defaults]' 'listen = 70000' \
  '[artifacts]' 'serve_ports = ["listen"]'
cfg="$CFGROOT/a25.toml"; make_pkg_cfg "$cfg" a25 "$pkg"
expect_fail "A25 declared serve key with out-of-range value is fatal" \
  "not a port number 1-65535" run "$cfg" validate

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
info="$(run "$cfg" package-info 2>/dev/null)"; rc_info36=$?
plan36="$(ledger_run "$info" plan 2>&1)"; rc_plan36=$?
if [ "$rc_info36" = 0 ] && [ "$rc_plan36" = 0 ] \
   && grep -q $'^fresh\tc36b$' <<<"$plan36"; then
  ok "C36b legacy-grammar dependency id round-trips through ledger plan"
else
  bad "C36b legacy dep grammar (info=$rc_info36 plan=$rc_plan36)"
  failure_detail "$plan36"
fi

# D44: a span must respect another id's RECORDED serve ports until the record
# is removed (the same exclusivity serve values already had).
reset_box
pkg="$PKGROOT/d44-span-ledger"; mkpkg "$pkg" d44 backend_port
pkg_manifest "$pkg" 'contract = 1' 'id = "d44"' \
  '[config.defaults]' 'backend_port = 19000' 'slots = 2' \
  '[[config.port_spans]]' 'base = "backend_port"' 'count = "slots"'
mkdir -p "$STATE"
cat >"$STATE/app-ledger.json" <<EOF
{
  "version": 1,
  "entries": {
    "otherapp": {
      "committed": {
        "path": "$TMP/otherapp-package",
        "digest": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
        "lifecycle": {"install": true, "smoke": true, "deactivate": true},
        "artifacts": {"units": [], "fragments": [], "webroot": [], "files": [], "serve_ports": [19001]}
      }
    }
  }
}
EOF
cfg="$CFGROOT/d44.toml"; make_pkg_cfg "$cfg" d44 "$pkg"
expect_fail "D44 a port span covering another id's recorded serve port is fatal" \
  "port span covering 19001" run "$cfg" validate

# F55: icon staging refuses a symlinked destination component — mkdir -p/cp
# would follow assets/apps -> elsewhere and stage outside the id scope.
reset_box
pkg="$PKGROOT/f55-dest-symlink"; mkpkg "$pkg" f55
printf 'icon\n' >"$pkg/icon.svg"
pkg_manifest "$pkg" 'contract = 1' 'id = "f55"' \
  '[tile]' 'label = "F"' 'cat = "docs"' 'icon = "icon.svg"'
cfg="$CFGROOT/f55.toml"; make_pkg_cfg "$cfg" f55 "$pkg"
info="$(run "$cfg" package-info 2>/dev/null)"
ledger_run "$info" intent f55 >/dev/null 2>&1 \
  || bad "F55 setup intent failed"
mkdir -p "$WEB/assets" "$TMP/f55-outside"
ln -s "$TMP/f55-outside" "$WEB/assets/apps"
expect_fail "F55 icon staging refuses a symlinked destination component" \
  "is a symlink" run "$cfg" icon-stage f55
[ -e "$TMP/f55-outside/f55" ] \
  && bad "F55 staging followed the symlink and wrote outside the webroot" \
  || ok "F55 nothing was written through the symlink"
# F55b: the intent survives that refusal, so the REMOVAL path must not follow
# the same symlink either — expansion through a redirected parent would put an
# external directory in the record, and teardown removes recorded directories.
mkdir -p "$TMP/f55-outside/f55"
printf 'precious\n' >"$TMP/f55-outside/f55/keepme.txt"
drop_cfg="$CFGROOT/f55-drop.toml"; base_config >"$drop_cfg"
drop_info="$(run "$drop_cfg" package-info 2>/dev/null)"
teardown55="$(ledger_run "$drop_info" remove f55 2>&1)"; rc_td55=$?
if [ "$rc_td55" -ne 0 ] \
   && grep -Eq "outside the platform root|no longer names what it claimed" <<<"$teardown55" \
   && [ -f "$TMP/f55-outside/f55/keepme.txt" ]; then
  ok "F55b removal refuses to expand through the symlink (nothing outside deleted)"
else
  bad "F55b symlinked-parent teardown (rc=$rc_td55, keepme=$([ -f "$TMP/f55-outside/f55/keepme.txt" ] && echo kept || echo GONE))"
  failure_detail "$teardown55"
fi
rm -f "$WEB/assets/apps"

# F56: icon staging refuses a package that changed after the journaled intent
# — the copied artifact would otherwise be named by NO record, forever.
reset_box
pkg="$PKGROOT/f56-drift"; mkpkg "$pkg" f56
pkg_manifest "$pkg" 'contract = 1' 'id = "f56"'
cfg="$CFGROOT/f56.toml"; make_pkg_cfg "$cfg" f56 "$pkg"
info="$(run "$cfg" package-info 2>/dev/null)"
ledger_run "$info" intent f56 >/dev/null 2>&1 \
  || bad "F56 setup intent failed"
printf 'icon\n' >"$pkg/icon.svg"
pkg_manifest "$pkg" 'contract = 1' 'id = "f56"' \
  '[tile]' 'label = "F"' 'cat = "docs"' 'icon = "icon.svg"'
expect_fail "F56 icon staging refuses a package that gained an icon after the journal" \
  "digest mismatch" run "$cfg" icon-stage f56

# F56c: the claim-symmetry check is defence in depth BEHIND the digest — the
# only way to reach it is a hand-edited record, so build exactly that (same
# digest, synthetic claim stripped).
reset_box
pkg="$PKGROOT/f56c-symmetry"; mkpkg "$pkg" f56c
printf 'icon\n' >"$pkg/icon.svg"
pkg_manifest "$pkg" 'contract = 1' 'id = "f56c"' \
  '[tile]' 'label = "F"' 'cat = "docs"' 'icon = "icon.svg"'
cfg="$CFGROOT/f56c.toml"; make_pkg_cfg "$cfg" f56c "$pkg"
info="$(run "$cfg" package-info 2>/dev/null)"
ledger_run "$info" intent f56c >/dev/null 2>&1 || bad "F56c setup intent failed"
python3 - "$STATE/app-ledger.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
w = d["entries"]["f56c"]["intent"]["artifacts_declared"]["webroot"]
d["entries"]["f56c"]["intent"]["artifacts_declared"]["webroot"] = [
    x for x in w if x != "assets/apps/f56c"]
json.dump(d, open(p, "w"))
PY
expect_fail "F56c a record whose synthetic icon claim was stripped is refused" \
  "disagree about the tile icon" run "$cfg" icon-stage f56c

# F56b: the SAME guard must fire for a no-icon package whose tree was swapped
# after the journal — the early return used to skip the digest check entirely,
# so a replaced installer could run under the old record's artifact list and
# orphan everything it created.
reset_box
pkg="$PKGROOT/f56b-swap"; mkpkg "$pkg" f56b
pkg_manifest "$pkg" 'contract = 1' 'id = "f56b"' '[artifacts]' 'webroot = ["old56b/"]'
cfg="$CFGROOT/f56b.toml"; make_pkg_cfg "$cfg" f56b "$pkg"
info="$(run "$cfg" package-info 2>/dev/null)"
ledger_run "$info" intent f56b >/dev/null 2>&1 \
  || bad "F56b setup intent failed"
pkg_manifest "$pkg" 'contract = 1' 'id = "f56b"' '[artifacts]' 'webroot = ["new56b/"]'
expect_fail "F56b a no-icon package swapped after the journal is refused (digest)" \
  "digest mismatch" run "$cfg" icon-stage f56b

# G61c: a get read split across a shell line continuation is still a read.
reset_box
pkg="$PKGROOT/g61c-continuation"; mkpkg "$pkg" g61c
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
airlock_config get \
  apps.g61c.secret >/dev/null
EOF
chmod +x "$pkg/install.sh"
cfg="$CFGROOT/g61c.toml"; make_pkg_cfg "$cfg" g61c "$pkg"
expect_warn "G61c a line-continued undeclared get read is reported" \
  "which the manifest does not declare" run "$cfg" validate

# G61d: a different command that merely ENDS in the name is not a call site.
reset_box
pkg="$PKGROOT/g61d-prefix"; mkpkg "$pkg" g61d
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
notairlock_config get apps.g61d.secret || true
EOF
chmod +x "$pkg/install.sh"
cfg="$CFGROOT/g61d.toml"; make_pkg_cfg "$cfg" g61d "$pkg"
expect_ok "G61d a foreign command ending in the name is not a call site" \
  run "$cfg" validate

# G61e: platform exports that share the AIRLOCK_<ID>_ shape (a package named
# 'app' reads AIRLOCK_APP_DIR in every install.sh) are not config-key reads.
reset_box
pkg="$PKGROOT/g61e-platform-env"; mkpkg "$pkg" app
pkg_manifest "$pkg" 'contract = 1' 'id = "app"'
cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
cd "$AIRLOCK_APP_DIR"
EOF
chmod +x "$pkg/install.sh"
cfg="$CFGROOT/g61e.toml"; make_pkg_cfg "$cfg" app "$pkg"
expect_ok "G61e AIRLOCK_APP_DIR in a package named 'app' is not a config read" \
  run "$cfg" validate

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

printf 'passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
