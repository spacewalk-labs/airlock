#!/usr/bin/env bash
# install/test-builtin-migration.sh — child 4, P1 first half: the transitional
# shipped resolver and ledger store v3 (docs/tasks/active/app-pkg-c4-builtin-migration.md
# section "Approach", phase P1's "Resolver" + "Record extensions" bullets).
# The render/capture extract-verify-swap half (P1a/P1b) is a separate phase
# and is NOT covered here.
#
# Every fixture package lives under a scratch AIRLOCK_SHIPPED_APPS_ROOT or its
# own temp dir, never under the repository's real apps/ tree — the shipped
# resolver must never fire against $ROOT/apps in this test (equivalence with
# a manifest-less box is install/test-equivalence.sh's job, not this file's).
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
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CFG="$ROOT/bin/airlock-config"; LEDGER="$ROOT/bin/airlock-ledger"
pass=0 fail=0
ok(){ echo "ok   $1"; pass=$((pass+1)); }; bad(){ echo "FAIL $1"; fail=$((fail+1)); }
skip(){ echo "SKIP $1"; }   # counts as neither pass nor fail (environmentally inapplicable)

STATE="$TMP/state"; WEB="$TMP/web/hub"; CONFD="$TMP/confd"
UU="$TMP/uu"; US="$TMP/us"; FAKEHOME="$TMP/home"
PKGROOT="$TMP/apps"; CFGROOT="$TMP/configs"
mkdir -p "$PKGROOT" "$CFGROOT"
export AIRLOCK_STATE_DIR="$STATE" AIRLOCK_WEBROOT="$WEB" AIRLOCK_CONFD="$CONFD"
export AIRLOCK_UNIT_DIR_USER="$UU" AIRLOCK_UNIT_DIR_SYSTEM="$US" HOME="$FAKEHOME"
export AIRLOCK_TS_FQDN="box.example.ts.net"
export AIRLOCK_SHIPPED_APPS_ROOT="$PKGROOT"
export AIRLOCK_TEST_TMP="$TMP"
export AIRLOCK_TEST_CONFIG_TOOL="$CFG"

reset_box() {
  rm -rf "$STATE" "$WEB" "$CONFD" "$UU" "$US" "$FAKEHOME"
  mkdir -p "$STATE" "$WEB/assets" "$CONFD/hub-locations.d" "$CONFD/servers.d" "$UU" "$US" "$FAKEHOME"
  : >"$TMP/tailscale.log"
  : >"$TMP/systemctl.log"
}
reset_box

# ---- shims (sudo execs through; systemctl/tailscale log and succeed) --------
SHIM="$TMP/shim"; mkdir -p "$SHIM"
cat >"$SHIM/sudo" <<'STUB'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac; done
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
if [ "${1:-}" = serve ] && [ "${2:-}" = status ]; then printf '{"TCP":{}}\n'; exit 0; fi
printf '%s\n' "$*" >> "$AIRLOCK_TEST_TMP/tailscale.log"
exit 0
STUB
# The production bundle policy is deliberately immutable and exact for the
# repository's nine apps.  This suite predates that policy and exercises the
# shipped resolver with many scratch-only ids.  Keep those fixtures useful
# without adding a production override: only the test's PATH-scoped Python
# interpreter imports airlock-config, replaces the in-memory policy with the
# exact scratch-root id set, and invokes main().  All non-airlock-config Python
# calls exec the real interpreter, and calls against the repository's real
# apps/ root retain the real nine-entry policy.
cat >"$SHIM/python3" <<'STUB'
#!/usr/bin/python3
import importlib.util
import os
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path

tool = os.environ.get("AIRLOCK_TEST_CONFIG_TOOL", "")
if len(sys.argv) > 1 and tool and os.path.realpath(sys.argv[1]) == os.path.realpath(tool):
    sys.argv.pop(1)
    loader = SourceFileLoader("_airlock_config_test", tool)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    root = Path(os.environ.get("AIRLOCK_SHIPPED_APPS_ROOT", ""))
    production_root = Path(tool).resolve().parent.parent / "apps"
    if root and os.path.realpath(root) != os.path.realpath(production_root):
        fixture_ids = sorted(
            entry.name for entry in root.iterdir()
            if entry.is_dir() and not entry.is_symlink()
            and (entry / "airlock-app.toml").is_file()
            and not (entry / "airlock-app.toml").is_symlink()
            and module.PACKAGE_ID_RE.fullmatch(entry.name) is not None
            and entry.name not in module.RESERVED_PACKAGE_IDS
        ) if root.is_dir() else []
        module.BUNDLE_ENTITLEMENTS = {
            package_id: ("plaintext-redirect", "rooted-artifact", "system-unit")
            for package_id in fixture_ids
        }
        module.BUNDLE_ROOT = root
    raise SystemExit(module.main(sys.argv[1:]))
os.execv("/usr/bin/python3", ["/usr/bin/python3", *sys.argv[1:]])
STUB
chmod +x "$SHIM"/*
PATH="$SHIM:$PATH"; export PATH

# ---- helpers ------------------------------------------------------------
run() { AIRLOCK_CONFIG="$1" python3 "$CFG" "${@:2}"; }
ledger_run() { local info="$1"; shift; printf '%s' "$info" | "$LEDGER" "$@"; }
base_config() { printf '[auth]\nprovider = "tailscale"\nowner = "x@y.z"\n[apps.hub]\n'; }
make_pkg_cfg() {
  local path="$1" pid="$2" pkg="$3" extra_apps="${4:-}"
  { base_config
    [ -z "$extra_apps" ] || printf '%s\n' "$extra_apps"
    printf '[apps.%s]\n[packages.%s]\npath = "%s"\n' "$pid" "$pid" "$pkg"
  } >"$path"
}
pkg_manifest() { local dir="$1"; shift; printf '%s\n' "$@" >"$dir/airlock-app.toml"; }
scripts_ok() {
  local dir="$1"
  printf '#!/bin/sh\nexit 0\n' >"$dir/install.sh"
  cp "$dir/install.sh" "$dir/smoke.sh"; cp "$dir/install.sh" "$dir/deactivate.sh"
  chmod +x "$dir"/*.sh
}
mkpkg() { local dir="$1" id="$2"; shift 2; mkdir -p "$dir"; pkg_manifest "$dir" "$@"; scripts_ok "$dir"; }
# No deactivate.sh: lifecycle.deactivate stays false, which is the ONLY way
# to reach command_commit's record-diff upgrade branch (D6: a recorded entry
# WITHOUT a deactivator upgrades via the diff; one WITH a deactivator goes
# through a separate remove --for-upgrade + fresh install instead, never
# touching the diff branch at all).
scripts_no_deactivate() {
  local dir="$1"
  printf '#!/bin/sh\nexit 0\n' >"$dir/install.sh"
  cp "$dir/install.sh" "$dir/smoke.sh"
  chmod +x "$dir"/*.sh
}
mkpkg_nd() { local dir="$1" id="$2"; shift 2; mkdir -p "$dir"; pkg_manifest "$dir" "$@"; scripts_no_deactivate "$dir"; }
commit_packages() {
  local info="$1"; shift
  for id in "$@"; do
    ledger_run "$info" intent "$id" >/dev/null 2>&1 || return 1
    ledger_run "$info" commit "$id" >/dev/null 2>&1 || return 1
  done
}
failure_detail() { printf '%s\n' "$1" | sed 's/^/    /' | tail -n 8; }
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

# =============================================================================
# Resolver: shipped packages resolve alongside explicit ones (D-pkgdir).
# =============================================================================

reset_box
APP="$PKGROOT/c4fixture"; mkdir -p "$APP"
pkg_manifest "$APP" 'contract = 1' 'id = "c4fixture"' \
  '[config.defaults]' 'port = 19001' \
  '[artifacts]' 'units = [{name = "x.service", scope = "system"}]' \
  'rooted = ["${webroot_parent}/bundle/"]' 'serve_ports = ["port"]'
scripts_ok "$APP"
cat >"$TMP/cfg.toml" <<EOF
[auth]
provider = "tailscale"
owner = "x@y.z"
[apps.hub]
[apps.c4fixture]
EOF
info="$(AIRLOCK_CONFIG="$TMP/cfg.toml" "$CFG" package-info 2>/dev/null)"
if python3 -c 'import json,sys; p=json.load(sys.stdin)["packages"]["c4fixture"]; assert p["source_class"] == "shipped"' <<<"$info"; then
  ok "shipped resolver and source class"
else
  bad "shipped resolver and source class"
fi

mkdir -p "$TMP/override"
pkg_manifest "$TMP/override" 'contract = 1' 'id = "c4fixture"' \
  '[config.defaults]' 'port = 19001' \
  '[artifacts]' 'units = [{name = "x.service", scope = "user"}]' 'serve_ports = ["port"]'
scripts_ok "$TMP/override"
printf '\n[packages.c4fixture]\npath = "%s"\n' "$TMP/override" >>"$TMP/cfg.toml"
info="$(AIRLOCK_CONFIG="$TMP/cfg.toml" "$CFG" package-info 2>/dev/null)"
if python3 -c 'import json,sys; p=json.load(sys.stdin)["packages"]["c4fixture"]; assert p["source_class"] == "explicit"' <<<"$info"; then
  ok "explicit shadows shipped"
else
  bad "explicit shadows shipped"
fi

# =============================================================================
# Capability admission: a bundled id is not itself a grant.
#
# These are intentionally red-first contracts.  The unmodified v4 tree derives
# system-unit directly from the manifest unit scope, so the first two cases
# below expose that an external package (including an `orca` shadow) can mint
# the claim it needs merely by declaring scope=system.  Plaintext redirect and
# closed config shape were already fail-closed; keep them here to ensure the
# single admission refactor does not weaken those boundaries.
# =============================================================================

reset_box
ext_system="$TMP/external-system"; mkpkg "$ext_system" external-system \
  'contract = 1' 'id = "external-system"' \
  '[artifacts]' 'units = [{name = "external-system.service", scope = "system"}]'
cfg_ext_system="$TMP/cfg-external-system.toml"
make_pkg_cfg "$cfg_ext_system" external-system "$ext_system"
expect_fail "capability admission: external system unit needs an entitlement" \
  "system-unit" run "$cfg_ext_system" package-info

reset_box
orca_shadow="$TMP/orca-shadow"; mkpkg "$orca_shadow" orca \
  'contract = 1' 'id = "orca"' \
  '[artifacts]' 'units = [{name = "orca-shadow.service", scope = "system"}]'
cfg_orca_shadow="$TMP/cfg-orca-shadow.toml"
make_pkg_cfg "$cfg_orca_shadow" orca "$orca_shadow"
expect_fail "capability admission: explicit orca shadow gets no bundle system-unit entitlement" \
  "system-unit" run "$cfg_orca_shadow" package-info

reset_box
devterm_shadow="$TMP/devterm-shadow"; mkpkg "$devterm_shadow" devterm \
  'contract = 1' 'id = "devterm"' \
  '[config.defaults]' 'public_port = 16411' 'redirect_port = 16412' \
  '[plaintext_redirect]' 'public_port = "redirect_port"'
cfg_devterm_shadow="$TMP/cfg-devterm-shadow.toml"
make_pkg_cfg "$cfg_devterm_shadow" devterm "$devterm_shadow"
expect_fail "capability admission: explicit devterm shadow gets no plaintext entitlement" \
  "plaintext" run "$cfg_devterm_shadow" package-info

# An admitted, non-privileged explicit shadow must also carry no immutable
# bundle build certification.  Use manifests without elevated requests so the
# output contract itself, rather than the admission error above, is exercised.
reset_box
orca_plain="$TMP/orca-plain"; mkpkg "$orca_plain" orca \
  'contract = 1' 'id = "orca"'
devterm_plain="$TMP/devterm-plain"; mkpkg "$devterm_plain" devterm \
  'contract = 1' 'id = "devterm"'
cfg_plain_shadows="$TMP/cfg-plain-shadows.toml"
{ base_config
  printf '[apps.orca]\n[apps.devterm]\n[packages.orca]\npath = "%s"\n[packages.devterm]\npath = "%s"\n' \
    "$orca_plain" "$devterm_plain"
} >"$cfg_plain_shadows"
shadow_info="$(run "$cfg_plain_shadows" package-info 2>/dev/null)"
if python3 -c '
import json, sys
packages = json.load(sys.stdin)["packages"]
for package_id in ("orca", "devterm"):
    package = packages[package_id]
    assert package["source_class"] == "explicit"
    assert package["certifications"] == []
' <<<"$shadow_info" 2>/dev/null; then
  ok "capability admission: explicit built-in-id shadows get no bundle certification"
else
  bad "capability admission: explicit built-in-id shadows get no bundle certification"
fi

# Operator config cannot extend or replace the repository-owned entitlement
# table, either through a new top-level section or a package-local key.
cfg_policy_override="$TMP/cfg-policy-override.toml"
{ base_config
  printf '[bundle_entitlements]\norca = ["system-unit"]\n'
} >"$cfg_policy_override"
expect_fail "capability admission: top-level entitlement override is refused" \
  "unknown config section" run "$cfg_policy_override" validate

cfg_package_override="$TMP/cfg-package-policy-override.toml"
{ base_config
  printf '[apps.orca]\n[packages.orca]\npath = "%s"\nentitlements = ["system-unit"]\n' \
    "$orca_plain"
} >"$cfg_package_override"
expect_fail "capability admission: package-local entitlement override is refused" \
  "unknown key(s) in [packages.orca]: entitlements" run "$cfg_package_override" validate

# Stable output is part of the capability boundary, not presentation sugar:
# downstream release tooling must consume these bytes without parsing TOML.
# Use the real bundle root so the visible table is the production nine-entry
# contract, while dev-monitor gives the important honest empty-surfaces case.
reset_box
cfg_capability_json="$TMP/cfg-capability-json.toml"
{ base_config
  printf '[apps.dev-monitor]\n[apps.orca]\n'
} >"$cfg_capability_json"
capability_json="$(AIRLOCK_SHIPPED_APPS_ROOT="$ROOT/apps" AIRLOCK_CONFIG="$cfg_capability_json" \
  python3 "$CFG" json 2>/dev/null)"
if python3 -c '
import json, sys
contract = json.load(sys.stdin)["capability_contract"]
assert contract["schema_version"] == 1
assert contract["bundle_entitlements"] == {
    "code-server": [], "dev-monitor": ["rooted-artifact", "system-unit"],
    "devterm": [], "feedback": [], "learning": [],
    "fileview": [], "notepad": [], "notes": [],
    "orca": ["rooted-artifact", "system-unit"],
    "paseo": [], "publish": [],
}
dev_monitor = contract["packages"]["dev-monitor"]
assert dev_monitor == {
    "capabilities": ["rooted-artifact", "system-unit"],
    "certifications": ["dry-run-exec", "strict-config-scan"],
    "effective_capabilities": ["rooted-artifact", "system-unit"],
    "requested_capabilities": ["rooted-artifact", "system-unit"],
    "surface_classifications": {
        "rooted-artifact": "elevated-capability",
        "system-unit": "elevated-capability",
    },
    "surfaces": ["rooted-artifact", "system-unit"],
}
orca = contract["packages"]["orca"]
assert orca["requested_capabilities"] == ["rooted-artifact", "system-unit"]
assert orca["effective_capabilities"] == ["rooted-artifact", "system-unit"]
assert orca["capabilities"] == ["rooted-artifact", "system-unit"]
assert orca["surfaces"] == ["rooted-artifact", "serve-https", "serve-port", "system-unit"]
assert orca["surface_classifications"] == {
    "rooted-artifact": "elevated-capability",
    "serve-https": "baseline-mediated-mapping",
    "serve-port": "baseline-mediated-mapping",
    "system-unit": "elevated-capability",
}
' <<<"$capability_json" 2>/dev/null; then
  ok "capability output: json exposes exact bundle policy and effective package facts"
else
  bad "capability output: json exposes exact bundle policy and effective package facts"
fi

canonical_sha=0123456789abcdef0123456789abcdef01234567
canonical_expected="{\"package_id\":\"dev-monitor\",\"schema_version\":1,\"source_repository_id\":\"example-org/example-work\",\"source_sha\":\"$canonical_sha\",\"surface_classifications\":{\"rooted-artifact\":\"elevated-capability\",\"system-unit\":\"elevated-capability\"},\"surfaces\":[\"rooted-artifact\",\"system-unit\"]}"
canonical_one="$(AIRLOCK_SHIPPED_APPS_ROOT="$ROOT/apps" AIRLOCK_CONFIG="$cfg_capability_json" \
  python3 "$CFG" canonical-package-info dev-monitor example-org/example-work "$canonical_sha" 2>/dev/null)"
canonical_two="$(AIRLOCK_SHIPPED_APPS_ROOT="$ROOT/apps" AIRLOCK_CONFIG="$cfg_capability_json" \
  python3 "$CFG" canonical-package-info dev-monitor example-org/example-work "$canonical_sha" 2>/dev/null)"
if [ "$canonical_one" = "$canonical_expected" ] && [ "$canonical_two" = "$canonical_expected" ]; then
  ok "capability output: canonical package-info is exact, compact, deterministic, and carries dev-monitor hardening surfaces"
else
  bad "capability output: canonical package-info is exact, compact, deterministic, and carries dev-monitor hardening surfaces"
  failure_detail "$canonical_one"
fi
expect_fail "capability output: canonical package-info requires a full lowercase 40-hex SHA" \
  "full lowercase 40-hex" env AIRLOCK_SHIPPED_APPS_ROOT="$ROOT/apps" \
  AIRLOCK_CONFIG="$cfg_capability_json" python3 "$CFG" canonical-package-info \
  dev-monitor example-org/example-work deadbeef
expect_fail "capability output: canonical package-info requires a configured package" \
  "is not a configured package" env AIRLOCK_SHIPPED_APPS_ROOT="$ROOT/apps" \
  AIRLOCK_CONFIG="$cfg_capability_json" python3 "$CFG" canonical-package-info \
  notepad example-org/example-work "$canonical_sha"

# =============================================================================
# Store v3 shape: required exact-shape, v1/v2 read-normalize.
# =============================================================================

reset_box
printf '{"version":3,"entries":{"x":{"committed":{"path":"/x","digest":"%064d","lifecycle":{"install":true,"smoke":true,"deactivate":true},"deps":[],"artifacts":{"units":[],"fragments":[],"webroot":[],"files":[],"rooted":[],"serve_ports":[]}}}}}\n' 0 >"$STATE/app-ledger.json"
out_v3all="$(printf '{}' | "$LEDGER" list 2>&1)"; rc_v3all=$?
if [ "$rc_v3all" -ne 0 ] && grep -q "invalid committed record shape" <<<"$out_v3all"; then
  ok "malformed v3 (all sidecar fields absent) is fatal"
else
  bad "malformed v3 (all sidecar fields absent) is fatal (rc=$rc_v3all)"
  failure_detail "$out_v3all"
fi

reset_box
python3 - "$STATE/app-ledger.json" <<PY
import json
d = {"version": 3, "entries": {"badv3": {"committed": {
    "path": "/x", "digest": "b" * 64,
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "deps": [],
    "artifacts": {"units": [], "fragments": [], "webroot": [], "files": [], "rooted": [], "serve_ports": []},
    "serve_mappings": {}, "unit_scopes": {},
    # "order" deliberately omitted — a v3 record missing exactly ONE of the
    # required sidecar fields must not pass as legacy (D6 child-4 amendment).
}}}}
json.dump(d, open("$STATE/app-ledger.json", "w"))
PY
out_v3order="$(printf '{}' | "$LEDGER" list 2>&1)"; rc_v3order=$?
if [ "$rc_v3order" -ne 0 ] && grep -q "invalid committed record shape" <<<"$out_v3order"; then
  ok "malformed v3 (order missing) is fatal"
else
  bad "malformed v3 (order missing) is fatal (rc=$rc_v3order)"
  failure_detail "$out_v3order"
fi

reset_box
printf '{"version":2,"entries":{}}\n' >"$STATE/app-ledger.json"
if printf '{}' | "$LEDGER" list >/dev/null 2>&1; then ok "v2 ride-through"; else bad "v2 ride-through"; fi

# v1 committed ride-through: read-normalises without writing, and the
# explicit teardown path removes it unchanged (no v3 fields ever declared).
reset_box
python3 - "$STATE/app-ledger.json" <<PY
import json
d = {"version": 1, "entries": {"v1ride": {"committed": {
    "path": "/nonexistent/v1ride-pkg", "digest": "a" * 64,
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "artifacts": {"units": [], "fragments": [], "webroot": [], "files": ["$TMP/v1-marker"],
                  "serve_ports": []},
}}}}
json.dump(d, open("$STATE/app-ledger.json", "w"))
PY
mkdir -p "$TMP"; : >"$TMP/v1-marker"
td_out="$(ledger_run '{"packages":{}}' teardown v1ride 2>&1)"; td_rc=$?
if [ "$td_rc" = 0 ] && [ ! -e "$TMP/v1-marker" ] \
   && ! ledger_run '{}' list 2>/dev/null | grep -q '^v1ride'; then
  ok "v1 committed record read-normalises and tears down unchanged"
else
  bad "v1 committed ride-through+teardown (rc=$td_rc)"
  failure_detail "$td_out"
fi
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["version"] == 6 and d["events"] == []' "$STATE/app-ledger.json"; then
  ok "v1 ride-through's teardown persisted the store as v6 with empty audit history"
else
  bad "store was not rewritten as v6 after the v1 teardown"
fi

# v2 committed ride-through: same, through the ordinary remove path (deps
# required at v2, no v3 fields) — proves v2 records need no migration to
# behave exactly as before.
reset_box
mkdir -p "$TMP/v2data"; : >"$TMP/v2data/marker"
python3 - "$STATE/app-ledger.json" <<PY
import json
d = {"version": 2, "entries": {"v2ride": {"committed": {
    "path": "/nonexistent/v2ride-pkg", "digest": "b" * 64,
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "deps": [],
    "artifacts": {"units": [], "fragments": [], "webroot": [], "files": ["$TMP/v2data/marker"],
                  "serve_ports": []},
}}}}
json.dump(d, open("$STATE/app-ledger.json", "w"))
PY
rm_out="$(ledger_run '{"packages":{}}' remove v2ride 2>&1)"; rm_rc=$?
if [ "$rm_rc" = 0 ] && [ ! -e "$TMP/v2data/marker" ] \
   && ! ledger_run '{}' list 2>/dev/null | grep -q '^v2ride'; then
  ok "v2 committed record read-normalises and tears down unchanged"
else
  bad "v2 committed ride-through+teardown (rc=$rm_rc)"
  failure_detail "$rm_out"
fi

# v2 INTENT ride-through (previously untested — only v1 intent and v1/v2
# committed were covered): a v2 intent (deps + anchors, no v3 sidecar
# fields) read-normalises and tears down unchanged via the explicit
# teardown path.
reset_box
mkdir -p "$TMP/v2intent-data"; : >"$TMP/v2intent-data/marker"
python3 - "$STATE/app-ledger.json" <<PY
import json
d = {"version": 2, "entries": {"v2intent": {"intent": {
    "path": "/nonexistent/v2intent-pkg", "digest": "f" * 64,
    "artifacts_declared": {"units": [], "fragments": [], "webroot": [],
                           "files": ["$TMP/v2intent-data/marker"], "serve_ports": []},
    "serve_port_values": {},
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "deps": [], "anchors": {},
    "roots": {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
              "webroot": "$WEB", "home": "$FAKEHOME"},
}}}}
json.dump(d, open("$STATE/app-ledger.json", "w"))
PY
td_out="$(ledger_run '{"packages":{}}' teardown v2intent 2>&1)"; td2_rc=$?
if [ "$td2_rc" = 0 ] && [ ! -e "$TMP/v2intent-data/marker" ] \
   && ! ledger_run '{}' list 2>/dev/null | grep -q '^v2intent'; then
  ok "v2 intent record read-normalises and tears down unchanged"
else
  bad "v2 intent ride-through+teardown (rc=$td2_rc)"
  failure_detail "$td_out"
fi

# v3 -> v6 normalisation, PERSISTED. Tearing the v3 record down would prove
# nothing: teardown drops the entry, so its current shape never reaches disk and a
# normalisation that forgot `capabilities` entirely would still go green. The
# mutation is therefore driven through a DIFFERENT app, so the record under
# test survives the write and can be read back.
#
# The fixture is hand-written in the v3 format on purpose — one generated by
# the new writer would test the writer twice and the reader never. Its unit
# scope says "user" while the recorded absolute path sits in the SYSTEM unit
# dir: the recorded path is the ground truth a scope map only summarises, and
# the derivation must read the record's OWN roots snapshot to see it. The
# mutation runs with AIRLOCK_UNIT_DIR_SYSTEM moved elsewhere, so a derivation
# that consulted the live environment instead would find no match and drop the
# system-unit claim.
reset_box
MOVED_US="$TMP/moved-us"; mkdir -p "$MOVED_US"
v3drv="$PKGROOT/v3drv"
mkpkg "$v3drv" v3drv 'contract = 1' 'id = "v3drv"' \
  '[config.defaults]' 'listen_port = 18701' \
  '[artifacts]' 'serve_ports = ["listen_port"]'
cfg_v3="$CFGROOT/v3drv.toml"; make_pkg_cfg "$cfg_v3" v3drv "$v3drv"
info_v3="$(run "$cfg_v3" package-info 2>/dev/null)"
python3 - "$STATE/app-ledger.json" <<PY
import json
d = {"version": 3, "entries": {"v3keep": {"committed": {
    "path": "/nonexistent/v3keep-pkg", "digest": "d" * 64,
    "lifecycle": {"install": True, "smoke": True, "deactivate": False},
    "deps": [],
    "artifacts": {"units": ["$US/v3keep.service"], "fragments": [], "webroot": [],
                  "files": [], "rooted": ["/etc/airlock/v3keep-drop-in"],
                  "serve_ports": []},
    "serve_mappings": {}, "unit_scopes": {"v3keep.service": "user"}, "order": None,
    "roots": {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
              "webroot": "$WEB", "home": "$FAKEHOME"},
    "source_class": "shipped",
}}}}
json.dump(d, open("$STATE/app-ledger.json", "w"))
PY
v3i_out="$(AIRLOCK_UNIT_DIR_SYSTEM="$MOVED_US" ledger_run "$info_v3" intent v3drv 2>&1)"; rc_v3i=$?
v3c_out="$(AIRLOCK_UNIT_DIR_SYSTEM="$MOVED_US" ledger_run "$info_v3" commit v3drv 2>&1)"; rc_v3c=$?
v3_disk="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
r = d["entries"]["v3keep"]["committed"]
print(d["version"], r["digest"] == "d" * 64, json.dumps(r["capabilities"]))
' "$STATE/app-ledger.json" 2>&1)"
if [ "$rc_v3i" = 0 ] && [ "$rc_v3c" = 0 ] \
   && [ "$v3_disk" = '6 True ["rooted-artifact", "system-unit"]' ]; then
  ok "v3 record normalises through v4 capabilities to v6 ON DISK"
else
  bad "v3 -> v6 persist (intent=$rc_v3i commit=$rc_v3c disk=$v3_disk)"
  failure_detail "$v3i_out
$v3c_out"
fi

# =============================================================================
# Serve off-guard: (mode, listen) identity, not (mode, listen, target).
# =============================================================================

# A package upgraded in place (same id, same listen, NEW target) must never
# fire the off command for its own listen address — off is a (mode, listen)
# address wipe, so a target-sensitive guard would kill the very mapping the
# upgrade just installed. (Note: the platform's own port-disjointness check
# — bin/airlock-config's _recorded_claims — already refuses to let a
# DIFFERENT id configure a still-recorded id's port, so "currently
# configured" cross-id reuse of a (mode, listen) is unreachable through the
# validated config path; the store-wide "any OTHER live record" case below
# is what that half of the guard actually protects in practice.)
reset_box
og_a="$PKGROOT/og-a"
mkpkg "$og_a" og-a 'contract = 1' 'id = "og-a"' \
  '[config.defaults]' 'listen_port = 18443' 'target_port = 18080' \
  '[artifacts]' 'serve_ports = ["listen_port"]' \
  '[serve.https]' 'listen_port = "target_port"'
cfg_a="$CFGROOT/og-a.toml"; make_pkg_cfg "$cfg_a" og-a "$og_a"
info_a="$(run "$cfg_a" package-info 2>/dev/null)"
commit_packages "$info_a" og-a; rc_commit_a=$?
# Re-target: same id, same package path, listen_port unchanged, target_port
# changed — the manifest edit changes the digest, so this is a genuine
# upgrade through command_commit's record-diff path.
mkpkg "$og_a" og-a 'contract = 1' 'id = "og-a"' \
  '[config.defaults]' 'listen_port = 18443' 'target_port = 28080' \
  '[artifacts]' 'serve_ports = ["listen_port"]' \
  '[serve.https]' 'listen_port = "target_port"'
info_a2="$(run "$cfg_a" package-info 2>/dev/null)"
commit_packages "$info_a2" og-a; rc_upgrade_a=$?
final_json="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d["entries"]["og-a"]["committed"]["serve_mappings"]))' "$STATE/app-ledger.json" 2>/dev/null)"
if [ "$rc_commit_a" = 0 ] && [ "$rc_upgrade_a" = 0 ] \
   && ! grep -q -- '--https=18443 off' "$TMP/tailscale.log" \
   && grep -q '"target": 28080' <<<"$final_json"; then
  ok "off-guard: a re-targeted successor mapping on (mode, listen) is protected"
else
  bad "off-guard: same-id re-target upgrade (commit=$rc_commit_a upgrade=$rc_upgrade_a final=$final_json)"
  cat "$TMP/tailscale.log" | sed 's/^/    ts: /'
fi

# Same guard, but the OTHER occupant is not in current config at all — a
# separate ledger record no run has reconciled yet. Only the store-wide scan
# (not "currently configured") can see this.
reset_box
og_a2="$PKGROOT/og-a2"
mkpkg "$og_a2" og-a2 'contract = 1' 'id = "og-a2"' \
  '[config.defaults]' 'listen_port = 18543' 'target_port = 18080' \
  '[artifacts]' 'serve_ports = ["listen_port"]' \
  '[serve.https]' 'listen_port = "target_port"'
cfg_a2="$CFGROOT/og-a2.toml"; make_pkg_cfg "$cfg_a2" og-a2 "$og_a2"
info_a2="$(run "$cfg_a2" package-info 2>/dev/null)"
commit_packages "$info_a2" og-a2; rc_commit_a2=$?
# og-c coexists as BOTH committed and intent, with DIFFERENT ports on each —
# the committed mapping (19999) is a decoy; the INTENT mapping (18543, the
# same address og-a2 owns) is what must protect og-a2's removal. A guard
# that only ever looked at "committed or intent" (preferring committed)
# would see 19999 and miss 18543 entirely.
python3 - "$STATE/app-ledger.json" <<PY
import json
p = "$STATE/app-ledger.json"
d = json.load(open(p))
common_roots = {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
                "webroot": "$WEB", "home": "$FAKEHOME"}
d["entries"]["og-c"] = {
    "committed": {
        "path": "/nonexistent/og-c", "digest": "c" * 64,
        "lifecycle": {"install": True, "smoke": True, "deactivate": False},
        "deps": [],
        "artifacts": {"units": [], "fragments": [], "webroot": [], "files": [], "rooted": [], "serve_ports": []},
        "serve_mappings": {"k": {"listen": 19999, "mode": "https", "target": 1}},
        "unit_scopes": {}, "order": None, "roots": common_roots, "source_class": "explicit",
        "capabilities": [], "container_runtime": None,
    },
    "intent": {
        "path": "/nonexistent/og-c", "digest": "e" * 64,
        "artifacts_declared": {"units": [], "fragments": [], "webroot": [], "files": [], "rooted": [], "serve_ports": []},
        "serve_port_values": {}, "lifecycle": {"install": True, "smoke": True, "deactivate": False},
        "deps": [], "anchors": {}, "roots": common_roots,
        "serve_mappings": {"k": {"listen": 18543, "mode": "https", "target": 2}},
        "unit_scopes": {}, "order": None, "source_class": "explicit",
        "capabilities": [], "container_runtime": None,
    },
}
json.dump(d, open(p, "w"))
PY
rm_out="$(ledger_run '{"packages":{}}' remove og-a2 2>&1)"; rm_rc=$?
if [ "$rc_commit_a2" = 0 ] && [ "$rm_rc" = 0 ] \
   && ! grep -q -- '--https=18543 off' "$TMP/tailscale.log" \
   && ! ledger_run '{}' list 2>/dev/null | grep -q '^og-a2' \
   && ledger_run '{}' list 2>/dev/null | grep -q '^og-c'; then
  ok "off-guard: another live (unconfigured) record on (mode, listen) is protected"
else
  bad "off-guard: other-live-record protection (commit=$rc_commit_a2 remove=$rm_rc)"
  failure_detail "$rm_out"
  cat "$TMP/tailscale.log" | sed 's/^/    ts: /'
fi

# The coexist case in the OTHER direction: the OTHER id's COMMITTED record
# (not intent) is the one sharing the address — proves committed is checked
# too, not just intent, when both exist.
reset_box
og_a3="$PKGROOT/og-a3"
mkpkg "$og_a3" og-a3 'contract = 1' 'id = "og-a3"' \
  '[config.defaults]' 'listen_port = 18643' 'target_port = 18080' \
  '[artifacts]' 'serve_ports = ["listen_port"]' \
  '[serve.https]' 'listen_port = "target_port"'
cfg_a3="$CFGROOT/og-a3.toml"; make_pkg_cfg "$cfg_a3" og-a3 "$og_a3"
info_a3="$(run "$cfg_a3" package-info 2>/dev/null)"
commit_packages "$info_a3" og-a3; rc_commit_a3=$?
python3 - "$STATE/app-ledger.json" <<PY
import json
p = "$STATE/app-ledger.json"
d = json.load(open(p))
common_roots = {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
                "webroot": "$WEB", "home": "$FAKEHOME"}
d["entries"]["og-d"] = {
    "committed": {
        "path": "/nonexistent/og-d", "digest": "c" * 64,
        "lifecycle": {"install": True, "smoke": True, "deactivate": False},
        "deps": [],
        "artifacts": {"units": [], "fragments": [], "webroot": [], "files": [], "rooted": [], "serve_ports": []},
        "serve_mappings": {"k": {"listen": 18643, "mode": "https", "target": 1}},
        "unit_scopes": {}, "order": None, "roots": common_roots, "source_class": "explicit",
        "capabilities": [], "container_runtime": None,
    },
    "intent": {
        "path": "/nonexistent/og-d", "digest": "e" * 64,
        "artifacts_declared": {"units": [], "fragments": [], "webroot": [], "files": [], "rooted": [], "serve_ports": []},
        "serve_port_values": {}, "lifecycle": {"install": True, "smoke": True, "deactivate": False},
        "deps": [], "anchors": {}, "roots": common_roots,
        "serve_mappings": {"k": {"listen": 29999, "mode": "https", "target": 2}},
        "unit_scopes": {}, "order": None, "source_class": "explicit",
        "capabilities": [], "container_runtime": None,
    },
}
json.dump(d, open(p, "w"))
PY
rm_out="$(ledger_run '{"packages":{}}' remove og-a3 2>&1)"; rm_rc=$?
if [ "$rc_commit_a3" = 0 ] && [ "$rm_rc" = 0 ] \
   && ! grep -q -- '--https=18643 off' "$TMP/tailscale.log" \
   && ! ledger_run '{}' list 2>/dev/null | grep -q '^og-a3' \
   && ledger_run '{}' list 2>/dev/null | grep -q '^og-d'; then
  ok "off-guard: coexisting committed+intent — the COMMITTED half protects too"
else
  bad "off-guard: coexist committed-side protection (commit=$rc_commit_a3 remove=$rm_rc)"
  failure_detail "$rm_out"
  cat "$TMP/tailscale.log" | sed 's/^/    ts: /'
fi

# =============================================================================
# Positive serve-teardown: an off IS actually issued for a dropped mapping.
# All the checks above are negative (off must NOT fire) — a _teardown_ports
# that silently does nothing would still pass every one of them, which is
# exactly how the diff-based off-Blocker survived review. These are the
# mechanical proof the OTHER direction works too.
# =============================================================================

# Upgrade, http: a package without deactivate.sh (the ONLY way to reach
# command_commit's record-diff branch, D6) drops one of two declared plain
# http ports across an upgrade. The dropped port's own off must be issued —
# nothing else protects it (it is no longer declared, so it drops out of
# "currently configured" too).
reset_box
up_http="$PKGROOT/up-http"
mkpkg_nd "$up_http" up-http 'contract = 1' 'id = "up-http"' \
  '[config.defaults]' 'a_port = 15801' 'b_port = 15802' \
  '[artifacts]' 'serve_ports = ["a_port", "b_port"]'
cfg_uh="$CFGROOT/up-http.toml"; make_pkg_cfg "$cfg_uh" up-http "$up_http"
info_uh="$(run "$cfg_uh" package-info 2>/dev/null)"
commit_packages "$info_uh" up-http; rc_uh1=$?
mkpkg_nd "$up_http" up-http 'contract = 1' 'id = "up-http"' \
  '[config.defaults]' 'a_port = 15801' 'b_port = 15802' \
  '[artifacts]' 'serve_ports = ["a_port"]'
info_uh2="$(run "$cfg_uh" package-info 2>/dev/null)"
commit_packages "$info_uh2" up-http; rc_uh2=$?
if [ "$rc_uh1" = 0 ] && [ "$rc_uh2" = 0 ] \
   && grep -q -- '--http=15802 off' "$TMP/tailscale.log"; then
  ok "off-issued: an upgrade that drops a plain http port actually offs it"
else
  bad "off-issued: http upgrade-diff off (commit1=$rc_uh1 commit2=$rc_uh2)"
  cat "$TMP/tailscale.log" | sed 's/^/    ts: /'
fi

# Upgrade, https: the SAME key's listen number changes (18443 -> 18444) —
# the Blocker's exact repro. The old listen must be offed; the new one must
# not be (it is the record's own live mapping, protected as "currently
# configured").
reset_box
up_https="$PKGROOT/up-https"
mkpkg_nd "$up_https" up-https 'contract = 1' 'id = "up-https"' \
  '[config.defaults]' 'listen_port = 15901' 'target_port = 15801' \
  '[artifacts]' 'serve_ports = ["listen_port"]' \
  '[serve.https]' 'listen_port = "target_port"'
cfg_us="$CFGROOT/up-https.toml"; make_pkg_cfg "$cfg_us" up-https "$up_https"
info_us="$(run "$cfg_us" package-info 2>/dev/null)"
commit_packages "$info_us" up-https; rc_us1=$?
mkpkg_nd "$up_https" up-https 'contract = 1' 'id = "up-https"' \
  '[config.defaults]' 'listen_port = 15902' 'target_port = 15801' \
  '[artifacts]' 'serve_ports = ["listen_port"]' \
  '[serve.https]' 'listen_port = "target_port"'
info_us2="$(run "$cfg_us" package-info 2>/dev/null)"
commit_packages "$info_us2" up-https; rc_us2=$?
if [ "$rc_us1" = 0 ] && [ "$rc_us2" = 0 ] \
   && grep -q -- '--https=15901 off' "$TMP/tailscale.log" \
   && ! grep -q -- '--https=15902 off' "$TMP/tailscale.log"; then
  ok "off-issued: an https upgrade that moves the listen number offs the OLD one"
else
  bad "off-issued: https upgrade-diff off (commit1=$rc_us1 commit2=$rc_us2)"
  cat "$TMP/tailscale.log" | sed 's/^/    ts: /'
fi

# Stale-intent sweep: an intent journaled but never committed (a crashed
# install), repaired by a re-run whose declaration dropped one of the two
# ports the crashed intent named — the dropped port's off must be issued by
# the STALE-INTENT path (command_intent), not just the commit-diff path.
reset_box
si_a="$PKGROOT/si-a"
mkpkg_nd "$si_a" si-a 'contract = 1' 'id = "si-a"' \
  '[config.defaults]' 'a_port = 16001' 'b_port = 16002' \
  '[artifacts]' 'serve_ports = ["a_port", "b_port"]'
cfg_si="$CFGROOT/si-a.toml"; make_pkg_cfg "$cfg_si" si-a "$si_a"
info_si="$(run "$cfg_si" package-info 2>/dev/null)"
ledger_run "$info_si" intent si-a >/dev/null 2>&1; rc_si1=$?   # crash: no commit
mkpkg_nd "$si_a" si-a 'contract = 1' 'id = "si-a"' \
  '[config.defaults]' 'a_port = 16001' 'b_port = 16002' \
  '[artifacts]' 'serve_ports = ["a_port"]'
info_si2="$(run "$cfg_si" package-info 2>/dev/null)"
ledger_run "$info_si2" intent si-a >/dev/null 2>&1; rc_si2=$?  # repair run
if [ "$rc_si1" = 0 ] && [ "$rc_si2" = 0 ] \
   && grep -q -- '--http=16002 off' "$TMP/tailscale.log"; then
  ok "off-issued: the stale-intent sweep offs a port the repaired declaration dropped"
else
  bad "off-issued: stale-intent sweep off (intent1=$rc_si1 intent2=$rc_si2)"
  cat "$TMP/tailscale.log" | sed 's/^/    ts: /'
fi

# =============================================================================
# MAJOR C: the stale-intent sweep guard must compare the FULL recorded
# surface, not just the P1-era fields (roots/artifacts_declared/
# serve_port_values) — the fixture above only drops a serve_ports KEY,
# which mutates artifacts_declared, so it exercises only the TRUE branch.
# unit_scopes and serve_mappings can each change while those three stay
# byte-identical; these are the FALSE-branch repros.
# =============================================================================

# Repro 1: a crashed intent's unit scope flips user -> system. The bare
# unit NAME (and so artifacts_declared) is unchanged — only unit_scopes
# differs. Before the fix this silently replaced the old record with zero
# teardown calls, orphaning the enabled USER unit with no record naming it
# (D6's orphan rule broken by the exact mechanism meant to enforce it).
reset_box
sc_a="$PKGROOT/sc-a"
mkpkg_nd "$sc_a" sc-a 'contract = 1' 'id = "sc-a"' \
  '[artifacts]' 'units = [{name = "sc-a.service", scope = "user"}]'
cfg_sc="$CFGROOT/sc-a.toml"; { base_config; printf '[apps.sc-a]\n'; } >"$cfg_sc"
info_sc="$(run "$cfg_sc" package-info 2>/dev/null)"
ledger_run "$info_sc" intent sc-a >/dev/null 2>&1; rc_sc1=$?   # crash: no commit
: >"$UU/sc-a.service"   # what the crashed install actually created
mkpkg_nd "$sc_a" sc-a 'contract = 1' 'id = "sc-a"' \
  '[artifacts]' 'units = [{name = "sc-a.service", scope = "system"}]'
info_sc2="$(run "$cfg_sc" package-info 2>/dev/null)"
ledger_run "$info_sc2" intent sc-a >/dev/null 2>&1; rc_sc2=$?  # repair run
sc_caps="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d["entries"]["sc-a"]["intent"]["capabilities"]))' "$STATE/app-ledger.json" 2>/dev/null)"
if [ "$rc_sc1" = 0 ] && [ "$rc_sc2" = 0 ] && [ ! -e "$UU/sc-a.service" ] \
   && [ "$sc_caps" = '["system-unit"]' ] \
   && grep -q -- '--user disable --now sc-a.service' "$TMP/systemctl.log"; then
  ok "MAJOR C: a unit scope flip (user -> system) between two crashed intents is caught"
else
  bad "MAJOR C: unit-scope stale-intent regression (intent1=$rc_sc1 intent2=$rc_sc2 caps=$sc_caps unit=$([ -e "$UU/sc-a.service" ] && echo present || echo GONE))"
  cat "$TMP/systemctl.log" | sed 's/^/    sc: /'
fi

# Repro 2: adding [serve.https] to a crashed intent flips (http,19001) ->
# (https,19001) — the KEY and its raw resolved value are unchanged, so
# artifacts_declared/serve_port_values stay byte-identical; only
# serve_mappings' mode differs. Before the fix, the old http mapping was
# never offed — _dropped_serve_mappings is correct but unreachable when
# the guard that gates it never fires.
reset_box
sc_b="$PKGROOT/sc-b"
mkpkg_nd "$sc_b" sc-b 'contract = 1' 'id = "sc-b"' \
  '[config.defaults]' 'listen_port = 19001' \
  '[artifacts]' 'serve_ports = ["listen_port"]'
cfg_scb="$CFGROOT/sc-b.toml"; make_pkg_cfg "$cfg_scb" sc-b "$sc_b"
info_scb="$(run "$cfg_scb" package-info 2>/dev/null)"
ledger_run "$info_scb" intent sc-b >/dev/null 2>&1; rc_scb1=$?  # crash: no commit
mkpkg_nd "$sc_b" sc-b 'contract = 1' 'id = "sc-b"' \
  '[config.defaults]' 'listen_port = 19001' 'target_port = 19002' \
  '[artifacts]' 'serve_ports = ["listen_port"]' \
  '[serve.https]' 'listen_port = "target_port"'
info_scb2="$(run "$cfg_scb" package-info 2>/dev/null)"
ledger_run "$info_scb2" intent sc-b >/dev/null 2>&1; rc_scb2=$?  # repair run
if [ "$rc_scb1" = 0 ] && [ "$rc_scb2" = 0 ] && grep -q -- '--http=19001 off' "$TMP/tailscale.log"; then
  ok "MAJOR C: a serve mode flip (http -> https, same key/port) between two crashed intents is caught"
else
  bad "MAJOR C: serve-mode stale-intent regression (intent1=$rc_scb1 intent2=$rc_scb2)"
  cat "$TMP/tailscale.log" | sed 's/^/    ts: /'
fi

# =============================================================================
# CONTRACT DECISION + MAJOR A&B: unit claims are LITERAL NAMES ONLY — a glob
# wedges commit permanently (unit_scopes is keyed by expanded basenames,
# never equal to a pattern) and "*.service" globs the WHOLE system unit dir
# at teardown (reproduced disabling and removing nginx.service and
# sshd.service against scratch decoys). Fatal at validate; the ledger
# refuses a pattern-shaped name at record load too (defence in depth — a
# hand-edited record must not reach expansion). The literal @-template form
# (airlock-code-server@.service) is NOT a glob and must keep working.
# =============================================================================

reset_box
gu_a="$PKGROOT/gu-a"
mkpkg "$gu_a" gu-a 'contract = 1' 'id = "gu-a"' \
  '[artifacts]' 'units = ["airlock-uscope-*.service"]'
cfg_gua="$CFGROOT/gu-a.toml"
{ base_config; printf '[apps.gu-a]\n'; } >"$cfg_gua"
expect_fail "MAJOR A&B: a glob unit name is fatal at validate" \
  "not a glob" run "$cfg_gua" validate

reset_box
python3 - "$STATE/app-ledger.json" <<PY
import json
p = "$STATE/app-ledger.json"
d = {"version": 3, "entries": {"gu-b": {"intent": {
    "path": "/nonexistent/gu-b-pkg", "digest": "f" * 64,
    "artifacts_declared": {"units": ["airlock-uscope-*.service"], "fragments": [], "webroot": [],
                           "files": [], "rooted": [], "serve_ports": []},
    "serve_port_values": {},
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "deps": [], "anchors": {},
    "roots": {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
              "webroot": "$WEB", "home": "$FAKEHOME"},
    "serve_mappings": {}, "unit_scopes": {"airlock-uscope-*.service": "user"}, "order": None,
    "source_class": "explicit",
}}}}
json.dump(d, open(p, "w"))
PY
out_gub="$(printf '{}' | "$LEDGER" list 2>&1)"; rc_gub=$?
if [ "$rc_gub" -ne 0 ] && grep -q "without globs" <<<"$out_gub"; then
  ok "MAJOR A&B: a glob unit in a hand-written intent is refused at load"
else
  bad "MAJOR A&B: hand-written glob-unit intent not refused (rc=$rc_gub)"
  failure_detail "$out_gub"
fi

reset_box
python3 - "$STATE/app-ledger.json" <<PY
import json
p = "$STATE/app-ledger.json"
d = {"version": 3, "entries": {"gu-c": {"intent": {
    "path": "/nonexistent/gu-c-pkg", "digest": "f" * 64,
    "artifacts_declared": {"units": ["*.service"], "fragments": [], "webroot": [],
                           "files": [], "rooted": [], "serve_ports": []},
    "serve_port_values": {},
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "deps": [], "anchors": {},
    "roots": {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
              "webroot": "$WEB", "home": "$FAKEHOME"},
    "serve_mappings": {}, "unit_scopes": {"*.service": "system"}, "order": None,
    "source_class": "explicit",
}}}}
json.dump(d, open(p, "w"))
PY
: >"$US/decoy-nginx.service"   # a scratch decoy — must never be touched
out_guc="$(ledger_run '{"packages":{}}' remove gu-c 2>&1)"; rc_guc=$?
if [ "$rc_guc" -ne 0 ] && grep -q "without globs" <<<"$out_guc" \
   && [ -e "$US/decoy-nginx.service" ] && [ ! -s "$TMP/systemctl.log" ]; then
  ok "MAJOR A&B: '*.service' system-scope is refused before touching systemctl/sudo"
else
  bad "MAJOR A&B: glob system-scope sweep reached the shim (rc=$rc_guc)"
  failure_detail "$out_guc"
  cat "$TMP/systemctl.log" | sed 's/^/    sc: /'
fi

reset_box
at_a="$PKGROOT/at-a"
mkpkg "$at_a" at-a 'contract = 1' 'id = "at-a"' \
  '[artifacts]' 'units = ["airlock-code-server@.service"]'
cfg_ata="$CFGROOT/at-a.toml"
{ base_config; printf '[apps.at-a]\n'; } >"$cfg_ata"
: >"$UU/airlock-code-server@.service"
info_ata="$(run "$cfg_ata" package-info 2>/dev/null)"
commit_packages "$info_ata" at-a; rc_ata1=$?
units_ata="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d["entries"]["at-a"]["committed"]["artifacts"]["units"]))' "$STATE/app-ledger.json" 2>/dev/null)"
drop_ata="$CFGROOT/at-a-drop.toml"; base_config >"$drop_ata"
drop_info_ata="$(run "$drop_ata" package-info 2>/dev/null)"
rm_out_ata="$(ledger_run "$drop_info_ata" remove at-a 2>&1)"; rc_ata2=$?
if [ "$rc_ata1" = 0 ] && grep -q "airlock-code-server@.service" <<<"$units_ata" \
   && [ "$rc_ata2" = 0 ] && [ ! -e "$UU/airlock-code-server@.service" ]; then
  ok "MAJOR A&B: a literal @-template unit name still validates, commits, and tears down"
else
  bad "MAJOR A&B: @-template unit regression (commit=$rc_ata1 remove=$rc_ata2 units=$units_ata)"
  failure_detail "$rm_out_ata"
fi

# A hand-written v3 COMMITTED record with a glob unit path must be refused at
# load, before teardown basenames it into `systemctl disable --now` (round 6:
# the intent-side wildcard check used declared=True only, so a forged
# committed record reached the shim with '*.service').
reset_box
python3 - "$STATE/app-ledger.json" <<PY
import json
p = "$STATE/app-ledger.json"
d = {"version": 3, "entries": {"gu-d": {"committed": {
    "path": "/nonexistent/gu-d-pkg", "digest": "f" * 64,
    "artifacts": {"units": ["$US/*.service"], "fragments": [], "webroot": [],
                  "files": [], "rooted": [], "serve_ports": []},
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "deps": [],
    "roots": {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
              "webroot": "$WEB", "home": "$FAKEHOME"},
    "serve_mappings": {}, "unit_scopes": {"*.service": "system"}, "order": None,
    "source_class": "explicit",
}}}}
json.dump(d, open(p, "w"))
PY
: >"$US/decoy-nginx.service"   # a scratch decoy — must never be touched
out_gud="$(ledger_run '{"packages":{}}' remove gu-d 2>&1)"; rc_gud=$?
if [ "$rc_gud" -ne 0 ] && grep -q "literal unit path" <<<"$out_gud" \
   && [ -e "$US/decoy-nginx.service" ] && [ ! -s "$TMP/systemctl.log" ]; then
  ok "round 6: a glob unit in a hand-written v3 COMMITTED record is refused at load"
else
  bad "round 6: v3 committed glob unit not refused before the shim (rc=$rc_gud)"
  failure_detail "$out_gud"
  cat "$TMP/systemctl.log" | sed 's/^/    sc: /'
fi

# The same via the legacy path: a v1 committed record read-normalises, so a
# glob planted there must be just as load-fatal — normalisation must not
# launder it past the v3 rule.
reset_box
python3 - "$STATE/app-ledger.json" <<PY
import json
p = "$STATE/app-ledger.json"
d = {"version": 1, "entries": {"gu-e": {"committed": {
    "path": "/nonexistent/gu-e-pkg", "digest": "f" * 64,
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "artifacts": {"units": ["$US/*.service"], "fragments": [], "webroot": [],
                  "files": [], "serve_ports": []},
}}}}
json.dump(d, open(p, "w"))
PY
: >"$US/decoy-nginx.service"
out_gue="$(ledger_run '{"packages":{}}' teardown gu-e 2>&1)"; rc_gue=$?
if [ "$rc_gue" -ne 0 ] && grep -q "literal unit path" <<<"$out_gue" \
   && [ -e "$US/decoy-nginx.service" ] && [ ! -s "$TMP/systemctl.log" ]; then
  ok "round 6: a glob unit in a LEGACY committed record is refused at load"
else
  bad "round 6: legacy committed glob unit not refused before the shim (rc=$rc_gue)"
  failure_detail "$out_gue"
  cat "$TMP/systemctl.log" | sed 's/^/    sc: /'
fi

# =============================================================================
# Typed unit claims: v3 declared scope, legacy dual-probe.
# =============================================================================

# A v3 record's system-scope unit resolves ONLY the system path — the
# both-paths probe could otherwise adopt a same-named user unit. A committed
# record's unit_scopes must map exactly what got RECORDED (the D6 "expanded
# artifact list", same rule the legacy normalisation uses), so a declared
# unit that resolves to nothing is not itself commit-able — the meaningful
# assertion is a same-named DECOY under the wrong scope that must be
# ignored, with the real one under the correct scope still recorded.
reset_box
tu_sys="$PKGROOT/tu-sys"
mkpkg "$tu_sys" tu-sys 'contract = 1' 'id = "tu-sys"' \
  '[artifacts]' 'units = [{name = "tu-sys.service", scope = "system"}]'
cfg_tu="$CFGROOT/tu-sys.toml"; { base_config; printf '[apps.tu-sys]\n'; } >"$cfg_tu"
: >"$UU/tu-sys.service"   # a same-named USER decoy — must never be probed
: >"$US/tu-sys.service"   # the real SYSTEM unit — must be the only match
info_tu="$(run "$cfg_tu" package-info 2>/dev/null)"
commit_packages "$info_tu" tu-sys; rc_tu=$?
units_json="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d["entries"]["tu-sys"]["committed"]["artifacts"]["units"]))' "$STATE/app-ledger.json" 2>/dev/null)"
want_sys="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$US/tu-sys.service")"
if [ "$rc_tu" = 0 ] && [ "$units_json" = "[\"$want_sys\"]" ]; then
  ok "typed units: v3 system-scope unit never probes the user path"
else
  bad "typed units: system-scope leaked into (or missed) the user path (rc=$rc_tu units=$units_json want=$want_sys)"
fi
rm_tu="$(ledger_run "$info_tu" remove tu-sys 2>&1)"; rc_rm_tu=$?
if [ "$rc_rm_tu" = 0 ] && [ ! -e "$US/tu-sys.service" ] \
   && [ -e "$UU/tu-sys.service" ] \
   && grep -q -- '^disable --now tu-sys.service$' "$TMP/systemctl.log"; then
  ok "typed units: a valid system-unit claim reaches remove and never touches the user decoy"
else
  bad "typed units: claimed system-unit removal failed or crossed scope (rc=$rc_rm_tu)"
  failure_detail "$rm_tu"
fi

# A legacy (no unit_scopes) intent normalises to scope "both" and keeps
# today's dual-probe — an interrupted old install's system unit must not be
# orphaned by the v3 migration.
reset_box
: >"$US/legacy.service"   # ONLY under system — never declared a scope
python3 - "$STATE/app-ledger.json" <<PY
import json
d = {"version": 1, "entries": {"legacyunits": {"intent": {
    "path": "/nonexistent/legacyunits-pkg", "digest": "d" * 64,
    "artifacts_declared": {"units": ["legacy.service"], "fragments": [], "webroot": [],
                           "files": [], "serve_ports": []},
    "serve_port_values": {},
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "roots": {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
              "webroot": "$WEB", "home": "$FAKEHOME"},
}}}}
json.dump(d, open("$STATE/app-ledger.json", "w"))
PY
rm_out="$(ledger_run '{"packages":{}}' remove legacyunits 2>&1)"; rm_rc=$?
if [ "$rm_rc" = 0 ] && [ ! -e "$US/legacy.service" ]; then
  ok "typed units: a legacy record normalised to scope 'both' keeps the dual-probe"
else
  bad "typed units: legacy dual-probe regression (rc=$rm_rc)"
  failure_detail "$rm_out"
fi

# =============================================================================
# D-order rank tie-break: virtual nodes first, ascending rank, name-order
# fallback on any duplicate.
# =============================================================================

reset_box
rk_x="$PKGROOT/rk-x"; mkpkg "$rk_x" rk-x 'contract = 1' 'id = "rk-x"'
rk_y="$PKGROOT/rk-y"; mkpkg "$rk_y" rk-y 'contract = 1' 'id = "rk-y"'
rk_z="$PKGROOT/rk-z"; mkpkg "$rk_z" rk-z 'contract = 1' 'id = "rk-z"'
cfg_rk="$CFGROOT/rk.toml"
{ base_config; printf '[apps.rk-x]\n[apps.rk-y]\n[apps.rk-z]\n[packages.rk-x]\npath = "%s"\n[packages.rk-y]\npath = "%s"\n[packages.rk-z]\npath = "%s"\n' "$rk_x" "$rk_y" "$rk_z"; } >"$cfg_rk"
info_rk="$(run "$cfg_rk" package-info 2>/dev/null)"
commit_packages "$info_rk" rk-x rk-y rk-z; rc_rk=$?
drop_rk="$CFGROOT/rk-drop.toml"; base_config >"$drop_rk"
drop_info_rk="$(run "$drop_rk" package-info 2>/dev/null)"
plan_rk="$(ledger_run "$drop_info_rk" plan 2>&1)"; rc_plan_rk=$?
remove_rk="$(awk -F '\t' '$1 == "remove" {print $2}' <<<"$plan_rk")"
if [ "$rc_rk" = 0 ] && [ "$rc_plan_rk" = 0 ] && [ "$remove_rk" = $'rk-z\nrk-y\nrk-x' ]; then
  ok "rank tie-break: single-generation all-ranked store removes in exact reverse install order"
else
  bad "rank tie-break: single-generation reverse-install order (rc=$rc_plan_rk)"
  failure_detail "$plan_rk"
fi

reset_box
rk_dep="$PKGROOT/rk-a"; mkpkg "$rk_dep" rk-a 'contract = 1' 'id = "rk-a"' \
  '[dependencies]' 'apps = ["rk-x-virtual"]'
rk_b="$PKGROOT/rk-b"; mkpkg "$rk_b" rk-b 'contract = 1' 'id = "rk-b"'
cfg_rk2="$CFGROOT/rk2.toml"
{ base_config; printf '[apps.rk-x-virtual]\n[apps.rk-a]\n[apps.rk-b]\n[packages.rk-a]\npath = "%s"\n[packages.rk-b]\npath = "%s"\n' "$rk_dep" "$rk_b"; } >"$cfg_rk2"
info_rk2="$(run "$cfg_rk2" package-info 2>/dev/null)"
commit_packages "$info_rk2" rk-a rk-b; rc_rk2=$?
drop_rk2="$CFGROOT/rk2-drop.toml"; base_config >"$drop_rk2"
drop_info_rk2="$(run "$drop_rk2" package-info 2>/dev/null)"
plan_rk2a="$(ledger_run "$drop_info_rk2" plan 2>&1)"; rc_plan_rk2a=$?
plan_rk2b="$(ledger_run "$drop_info_rk2" plan 2>&1)"; rc_plan_rk2b=$?
remove_rk2="$(awk -F '\t' '$1 == "remove" {print $2}' <<<"$plan_rk2a")"
if [ "$rc_rk2" = 0 ] && [ "$rc_plan_rk2a" = 0 ] && [ "$rc_plan_rk2b" = 0 ] \
   && [ "$plan_rk2a" = "$plan_rk2b" ] && [ "$remove_rk2" = $'rk-b\nrk-a' ]; then
  ok "rank tie-break: a virtual dependency node sorts first"
else
  bad "rank tie-break: virtual dependency node ordering"
  failure_detail "$plan_rk2a"
fi

reset_box
dr_a="$PKGROOT/dr-a"; mkpkg "$dr_a" dr-a 'contract = 1' 'id = "dr-a"'
dr_b="$PKGROOT/dr-b"; mkpkg "$dr_b" dr-b 'contract = 1' 'id = "dr-b"'
dr_c="$PKGROOT/dr-c"; mkpkg "$dr_c" dr-c 'contract = 1' 'id = "dr-c"'
cfg_dr="$CFGROOT/dr.toml"
{ base_config; printf '[apps.dr-a]\n[apps.dr-b]\n[apps.dr-c]\n[packages.dr-a]\npath = "%s"\n[packages.dr-b]\npath = "%s"\n[packages.dr-c]\npath = "%s"\n' "$dr_a" "$dr_b" "$dr_c"; } >"$cfg_dr"
info_dr="$(run "$cfg_dr" package-info 2>/dev/null)"
# Install order b, c, a (ranks 1, 2, 3) — then hand-force a DUPLICATE rank
# (b and c both 1, a stays 3). If duplicate detection were broken and rank
# still applied, ascending-rank order would give b,c (tie->name),a reversed
# = a,c,b — DIFFERENT from the required name-order fallback c,b,a, so this
# assertion actually distinguishes the two outcomes.
commit_packages "$info_dr" dr-b dr-c dr-a; rc_dr=$?
python3 - "$STATE/app-ledger.json" <<PY
import json
p = "$STATE/app-ledger.json"
d = json.load(open(p))
d["entries"]["dr-c"]["committed"]["order"] = d["entries"]["dr-b"]["committed"]["order"]
json.dump(d, open(p, "w"))
PY
drop_dr="$CFGROOT/dr-drop.toml"; base_config >"$drop_dr"
drop_info_dr="$(run "$drop_dr" package-info 2>/dev/null)"
plan_dr="$(ledger_run "$drop_info_dr" plan 2>&1)"; rc_plan_dr=$?
remove_dr="$(awk -F '\t' '$1 == "remove" {print $2}' <<<"$plan_dr")"
if [ "$rc_dr" = 0 ] && [ "$rc_plan_dr" = 0 ] && [ "$remove_dr" = $'dr-c\ndr-b\ndr-a' ]; then
  ok "rank tie-break: duplicate ranks demote the whole selection to name-order"
else
  bad "rank tie-break: duplicate-rank demotion (rc=$rc_plan_dr)"
  failure_detail "$plan_dr"
fi

# A rank fixture where rank order DISAGREES with name order — every prior
# rank fixture happened to have names and ranks in the same order, so a
# comparator that silently fell back to plain name-order (ignoring rank
# entirely) would still have passed all of them. Install "zz-early" (rank 1)
# before "aa-late" (rank 2): ascending-rank forward is zz-early, aa-late,
# reversed = aa-late, zz-early — the OPPOSITE of what plain alphabetical
# forward+reverse would give (zz-early, aa-late).
reset_box
rk_zz="$PKGROOT/rk-zz"; mkpkg "$rk_zz" zz-early 'contract = 1' 'id = "zz-early"'
rk_aa="$PKGROOT/rk-aa"; mkpkg "$rk_aa" aa-late 'contract = 1' 'id = "aa-late"'
cfg_rko="$CFGROOT/rko.toml"
{ base_config; printf '[apps.zz-early]\n[apps.aa-late]\n[packages.zz-early]\npath = "%s"\n[packages.aa-late]\npath = "%s"\n' "$rk_zz" "$rk_aa"; } >"$cfg_rko"
info_rko="$(run "$cfg_rko" package-info 2>/dev/null)"
commit_packages "$info_rko" zz-early aa-late; rc_rko=$?
drop_rko="$CFGROOT/rko-drop.toml"; base_config >"$drop_rko"
drop_info_rko="$(run "$drop_rko" package-info 2>/dev/null)"
plan_rko="$(ledger_run "$drop_info_rko" plan 2>&1)"; rc_plan_rko=$?
remove_rko="$(awk -F '\t' '$1 == "remove" {print $2}' <<<"$plan_rko")"
if [ "$rc_rko" = 0 ] && [ "$rc_plan_rko" = 0 ] && [ "$remove_rko" = $'aa-late\nzz-early' ]; then
  ok "rank tie-break: rank order (not name order) governs when they disagree"
else
  bad "rank tie-break: rank-vs-name contrast (rc=$rc_plan_rko, got: $remove_rko)"
  failure_detail "$plan_rko"
fi

# =============================================================================
# Rooted artifacts: explicit grant, allowlist, \${webroot_parent} substitution.
# =============================================================================

reset_box
rt_explicit="$TMP/rt-explicit"
mkpkg "$rt_explicit" rt-explicit 'contract = 1' 'id = "rt-explicit"' \
  '[artifacts]' 'rooted = ["/opt/airlock/rt-explicit-bundle/"]'
cfg_rte="$CFGROOT/rt-explicit.toml"; make_pkg_cfg "$cfg_rte" rt-explicit "$rt_explicit"
expect_fail "rooted: an explicit-manifest rooted declaration is fatal at validate" \
  "missing capability grant(s): ['rooted-artifact']" run "$cfg_rte" validate

reset_box
rt_bad="$PKGROOT/rt-bad"
mkpkg "$rt_bad" rt-bad 'contract = 1' 'id = "rt-bad"' \
  '[artifacts]' 'rooted = ["/srv/rt-bad-outside/marker"]'
cfg_rtb="$CFGROOT/rt-bad.toml"; make_pkg_cfg "$cfg_rtb" rt-bad "$rt_bad"
expect_fail "rooted: an allowlist-violating pattern is fatal at validate" \
  "outside the rooted allowlist" run "$cfg_rtb" validate

reset_box
rt_web="$PKGROOT/rt-web"
mkpkg "$rt_web" rt-web 'contract = 1' 'id = "rt-web"' \
  '[artifacts]' 'rooted = ["${webroot_parent}/rt-web-bundle/marker"]'
mkdir -p "$(dirname "$WEB")/rt-web-bundle"
: >"$(dirname "$WEB")/rt-web-bundle/marker"
# rt-web declares `rooted`, which is fatal for an explicit package (proven
# above) — it must resolve SHIPPED, so no [packages.rt-web] line: the id
# resolves implicitly under AIRLOCK_SHIPPED_APPS_ROOT ($PKGROOT).
cfg_rtw="$CFGROOT/rt-web.toml"
{ base_config; printf '[apps.rt-web]\n'; } >"$cfg_rtw"
info_rtw="$(run "$cfg_rtw" package-info 2>/dev/null)"
commit_packages "$info_rtw" rt-web; rc_rtw=$?
want_marker="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$(dirname "$WEB")/rt-web-bundle/marker")"
rooted_json="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d["entries"]["rt-web"]["committed"]["artifacts"]["rooted"]))' "$STATE/app-ledger.json" 2>/dev/null)"
if [ "$rc_rtw" = 0 ] && [ "$rooted_json" = "[\"$want_marker\"]" ]; then
  ok "rooted: \${webroot_parent} resolves against the recorded webroot parent"
else
  bad "rooted: webroot_parent substitution (rc=$rc_rtw rooted=$rooted_json want=$want_marker)"
fi
drop_rtw="$CFGROOT/rt-web-drop.toml"; base_config >"$drop_rtw"
drop_info_rtw="$(run "$drop_rtw" package-info 2>/dev/null)"
rm_out="$(ledger_run "$drop_info_rtw" remove rt-web 2>&1)"; rc_rm_rtw=$?
if [ "$rc_rtw" = 0 ] && [ "$rc_rm_rtw" = 0 ] && [ ! -e "$want_marker" ]; then
  ok "rooted: removal re-checks allowlist containment and deletes the artifact"
else
  bad "rooted: removal of a webroot_parent-anchored artifact (rc=$rc_rm_rtw)"
  failure_detail "$rm_out"
fi

# =============================================================================
# Cross-class upgrade-diff: a path migrating files<->rooted must never be
# torn down as "old-only" (bin/airlock-ledger:_artifact_difference unions
# ALL path classes, rooted included, when deciding what is "still owned" —
# these fixtures pin both directions). webroot<->rooted cannot collide by
# construction (webroot patterns are strictly under $WEBROOT; rooted's
# ${webroot_parent} anchor is strictly webroot's PARENT, a disjoint tree),
# so only files<->rooted is a reachable cross-class fixture.
# =============================================================================

reset_box
cc_a="$PKGROOT/cc-a"
cc_marker="$(dirname "$WEB")/cc-a-marker"
mkdir -p "$(dirname "$cc_marker")"; : >"$cc_marker"
mkpkg_nd "$cc_a" cc-a 'contract = 1' 'id = "cc-a"' \
  "[artifacts]" "files = [\"$cc_marker\"]"
cfg_cc="$CFGROOT/cc-a.toml"
{ base_config; printf '[apps.cc-a]\n'; } >"$cfg_cc"
info_cc="$(run "$cfg_cc" package-info 2>/dev/null)"
commit_packages "$info_cc" cc-a; rc_cc1=$?
mkpkg_nd "$cc_a" cc-a 'contract = 1' 'id = "cc-a"' \
  '[artifacts]' 'rooted = ["${webroot_parent}/cc-a-marker"]'
info_cc2="$(run "$cfg_cc" package-info 2>/dev/null)"
commit_packages "$info_cc2" cc-a; rc_cc2=$?
cc_json="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); a=d["entries"]["cc-a"]["committed"]["artifacts"]; print(json.dumps({"files": a["files"], "rooted": a["rooted"]}))' "$STATE/app-ledger.json" 2>/dev/null)"
if [ "$rc_cc1" = 0 ] && [ "$rc_cc2" = 0 ] && [ -e "$cc_marker" ] \
   && grep -q '"files": \[\]' <<<"$cc_json" && grep -q 'cc-a-marker' <<<"$cc_json"; then
  ok "cross-class: files -> rooted upgrade-diff never tears down the migrated path"
else
  bad "cross-class: files->rooted (commit1=$rc_cc1 commit2=$rc_cc2 marker=$([ -e "$cc_marker" ] && echo present || echo GONE) json=$cc_json)"
fi

reset_box
cc_b="$PKGROOT/cc-b"
cc_marker2="$(dirname "$WEB")/cc-b-marker"
mkdir -p "$(dirname "$cc_marker2")"; : >"$cc_marker2"
mkpkg_nd "$cc_b" cc-b 'contract = 1' 'id = "cc-b"' \
  '[artifacts]' 'rooted = ["${webroot_parent}/cc-b-marker"]'
cfg_cc2="$CFGROOT/cc-b.toml"
{ base_config; printf '[apps.cc-b]\n'; } >"$cfg_cc2"
info_ccb="$(run "$cfg_cc2" package-info 2>/dev/null)"
commit_packages "$info_ccb" cc-b; rc_ccb1=$?
mkpkg_nd "$cc_b" cc-b 'contract = 1' 'id = "cc-b"' \
  "[artifacts]" "files = [\"$cc_marker2\"]"
info_ccb2="$(run "$cfg_cc2" package-info 2>/dev/null)"
commit_packages "$info_ccb2" cc-b; rc_ccb2=$?
ccb_json="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); a=d["entries"]["cc-b"]["committed"]["artifacts"]; print(json.dumps({"files": a["files"], "rooted": a["rooted"]}))' "$STATE/app-ledger.json" 2>/dev/null)"
if [ "$rc_ccb1" = 0 ] && [ "$rc_ccb2" = 0 ] && [ -e "$cc_marker2" ] \
   && grep -q '"rooted": \[\]' <<<"$ccb_json" && grep -q 'cc-b-marker' <<<"$ccb_json"; then
  ok "cross-class: rooted -> files upgrade-diff never tears down the migrated path"
else
  bad "cross-class: rooted->files (commit1=$rc_ccb1 commit2=$rc_ccb2 marker=$([ -e "$cc_marker2" ] && echo present || echo GONE) json=$ccb_json)"
fi

# =============================================================================
# BLOCKER A: plaintext rows are MODE-derived, not class/key-derived. A
# package's HTTPS listen must never get a plaintext (http) row just because
# its port lives in the same declared serve_ports key space.
# =============================================================================

reset_box
pa_https="$TMP/pa-https"
mkpkg "$pa_https" pa-https 'contract = 1' 'id = "pa-https"' \
  '[config.defaults]' 'listen_port = 16201' 'target_port = 16202' \
  '[artifacts]' 'serve_ports = ["listen_port"]' \
  '[serve.https]' 'listen_port = "target_port"'
cfg_pah="$CFGROOT/pa-https.toml"; make_pkg_cfg "$cfg_pah" pa-https "$pa_https"
plain_pah="$(run "$cfg_pah" plaintext 2>&1)"
if ! grep -q '^pa-https' <<<"$plain_pah"; then
  ok "BLOCKER A: an https-only package emits no plaintext row"
else
  bad "BLOCKER A: https-only package wrongly got a plaintext row"
  failure_detail "$plain_pah"
fi

reset_box
pa_mixed="$TMP/pa-mixed"
mkpkg "$pa_mixed" pa-mixed 'contract = 1' 'id = "pa-mixed"' \
  '[config.defaults]' 'a_port = 16301' 'a_target = 16302' 'b_port = 16303' \
  '[artifacts]' 'serve_ports = ["a_port", "b_port"]' \
  '[serve.https]' 'a_port = "a_target"'
cfg_pam="$CFGROOT/pa-mixed.toml"; make_pkg_cfg "$cfg_pam" pa-mixed "$pa_mixed"
plain_pam="$(run "$cfg_pam" plaintext 2>&1)"
if [ "$(grep -c '^pa-mixed' <<<"$plain_pam")" = 1 ] && grep -q $'pa-mixed\t16303\t16303' <<<"$plain_pam"; then
  ok "BLOCKER A: a mixed http+https package emits only the http row"
else
  bad "BLOCKER A: mixed http+https parity"
  failure_detail "$plain_pam"
fi

# =============================================================================
# BLOCKER B: plaintext_redirect is shipped-only, and its public port stays
# sweepable even after the app is fully removed from config (the manifest
# persists in-tree; a shipped default is always knowable, matching
# APP_DEFAULTS' backstop for a removed built-in today).
# =============================================================================

reset_box
pr_explicit="$TMP/pr-explicit"
mkpkg "$pr_explicit" pr-explicit 'contract = 1' 'id = "pr-explicit"' \
  '[config.defaults]' 'public_port = 16401' 'redirect_port = 16402' \
  '[plaintext_redirect]' 'public_port = "redirect_port"'
cfg_pre="$CFGROOT/pr-explicit.toml"; make_pkg_cfg "$cfg_pre" pr-explicit "$pr_explicit"
expect_fail "BLOCKER B: an explicit-manifest plaintext_redirect is fatal at validate" \
  "plaintext_redirect is available only to shipped packages" run "$cfg_pre" validate

reset_box
pr_a="$PKGROOT/pr-a"
mkpkg "$pr_a" pr-a 'contract = 1' 'id = "pr-a"' \
  '[config.defaults]' 'public_port = 16101' 'redirect_port = 16102' \
  '[plaintext_redirect]' 'public_port = "redirect_port"'
cfg_pr="$CFGROOT/pr-a.toml"
{ base_config; printf '[apps.pr-a]\n'; } >"$cfg_pr"
known_out="$(run "$cfg_pr" plaintext-known 2>&1)"
plain_out="$(run "$cfg_pr" plaintext 2>&1)"
if grep -qx '16101' <<<"$known_out" && grep -q $'pr-a\t16101\t16102' <<<"$plain_out"; then
  ok "plaintext_redirect: a shipped app's public port is mapped AND sweepable as known"
else
  bad "plaintext_redirect: known/plaintext parity"
  failure_detail "known: $known_out"
  failure_detail "plaintext: $plain_out"
fi

# The app is now removed from config ENTIRELY (no [apps.pr-a], no ledger
# record) — the manifest is still on disk under the shipped root, so its
# DEFAULT public port must still be swept.
drop_pr="$CFGROOT/pr-a-drop.toml"; base_config >"$drop_pr"
known_after="$(run "$drop_pr" plaintext-known 2>&1)"
if grep -qx '16101' <<<"$known_after"; then
  ok "BLOCKER B: a shipped app removed from config still sweeps its default public port"
else
  bad "BLOCKER B: shipped plaintext_redirect default lost after removal"
  failure_detail "$known_after"
fi

# =============================================================================
# source_class rides into webjson too (D1: "trust is a property of the
# source and must be visible ... into every consumer").
# =============================================================================

reset_box
wj_a="$PKGROOT/wj-a"
mkpkg "$wj_a" wj-a 'contract = 1' 'id = "wj-a"' \
  '[tile]' 'label = "WJ"' 'cat = "docs"' 'glyph = "wj-a"'
cfg_wj="$CFGROOT/wj-a.toml"
{ base_config; printf '[apps.wj-a]\n'; } >"$cfg_wj"
webjson_out="$(run "$cfg_wj" webjson 2>&1)"
if python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["apps"]["wj-a"]["source_class"] == "shipped"' <<<"$webjson_out" 2>/dev/null; then
  ok "webjson: source_class rides into the launcher-facing consumer"
else
  bad "webjson: source_class missing or wrong"
  failure_detail "$webjson_out"
fi

# =============================================================================
# BLOCKER C: rooted execution must never trust record-supplied roots as
# authorization. Repro: a hand-written v3 intent claims
# roots.webroot=/etc/attacker-hub and a rooted pattern /etc/passwd — a
# record-derived allowlist would accept it (dirname(/etc/attacker-hub) is
# /etc, which equals dirname(/etc/passwd)). The live-environment allowlist
# must refuse it regardless of what the record claims, at BOTH validate-time
# ("at plan" — any command that loads the store) and, independently,
# execution-time (defense in depth: the same live-env check runs again
# right before the actual removal).
# =============================================================================

reset_box
evil_roots='{"unit_user": "'"$UU"'", "unit_system": "'"$US"'", "confd": "'"$CONFD"'", "webroot": "/etc/attacker-hub", "home": "'"$FAKEHOME"'"}'
python3 - "$STATE/app-ledger.json" <<PY
import json
p = "$STATE/app-ledger.json"
d = {"version": 3, "entries": {"evil": {"intent": {
    "path": "/nonexistent/evil-pkg", "digest": "f" * 64,
    "artifacts_declared": {"units": [], "fragments": [], "webroot": [], "files": [],
                           "rooted": ["/etc/passwd"], "serve_ports": []},
    "serve_port_values": {},
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "deps": [], "anchors": {},
    "roots": $evil_roots,
    "serve_mappings": {}, "unit_scopes": {}, "order": None,
    "source_class": "shipped",
}}}}
json.dump(d, open(p, "w"))
PY
plan_evil="$(ledger_run '{"packages":{}}' plan 2>&1)"; rc_plan_evil=$?
remove_evil="$(ledger_run '{"packages":{}}' remove evil 2>&1)"; rc_remove_evil=$?
if [ "$rc_plan_evil" -ne 0 ] && grep -q "rooted allowlist" <<<"$plan_evil" \
   && [ "$rc_remove_evil" -ne 0 ] && grep -q "rooted allowlist" <<<"$remove_evil"; then
  ok "BLOCKER C: the /etc/passwd repro (fake roots.webroot) is refused at plan and execution"
else
  bad "BLOCKER C: /etc/passwd repro not refused (plan_rc=$rc_plan_evil remove_rc=$rc_remove_evil)"
  failure_detail "$plan_evil"
  failure_detail "$remove_evil"
fi

# A v3 record that is explicit-class AND declares rooted is still refused
# outright. This can only be reached by hand-writing the store, and it is kept
# on the v3 path deliberately: in v3, source_class WAS the authorisation
# record, so no legitimate writer of that version could produce this record,
# and a grant cannot exist inside one. Store v4 replaces the assertion for v4
# records only — see the section below.
reset_box
python3 - "$STATE/app-ledger.json" <<PY
import json
p = "$STATE/app-ledger.json"
d = {"version": 3, "entries": {"evil2": {"intent": {
    "path": "/nonexistent/evil2-pkg", "digest": "f" * 64,
    "artifacts_declared": {"units": [], "fragments": [], "webroot": [], "files": [],
                           "rooted": ["/opt/airlock/legit-looking"], "serve_ports": []},
    "serve_port_values": {},
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "deps": [], "anchors": {},
    "roots": {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
              "webroot": "$WEB", "home": "$FAKEHOME"},
    "serve_mappings": {}, "unit_scopes": {}, "order": None,
    "source_class": "explicit",
}}}}
json.dump(d, open(p, "w"))
PY
out_evil2="$(printf '{}' | "$LEDGER" list 2>&1)"; rc_evil2=$?
if [ "$rc_evil2" -ne 0 ] && grep -q "artifacts_declared.rooted is shipped-only" <<<"$out_evil2"; then
  ok "BLOCKER C: a v3 explicit-class record with rooted is still refused"
else
  bad "BLOCKER C: a v3 explicit-class record with rooted was not refused (rc=$rc_evil2)"
  failure_detail "$out_evil2"
fi

# =============================================================================
# Store v4: the rooted gates read the RECORD, not source_class
# (docs/tasks/active/ledger-record-schema.md, phase P3). For a v4 record the
# load-time shipped-only assertion is gone on purpose: it re-decided POLICY
# against a config that may have granted the capability since, so the first
# granted rooted install wrote a record the next run refused to READ — the box
# died on its next install, before it could tear anything down. What replaces
# it is a check the record can prove about itself. The v3 path above keeps the
# old assertion, because there the premise it rests on is still true.
#
# These fixtures are hand-written stores, which is the only way to reach the
# ledger's own defense — bin/airlock-config still refuses an explicit
# manifest that declares rooted (proven above at validate, and again through
# package-info below).
# =============================================================================

# $1 = artifacts_declared.rooted as a Python/JSON list literal
# $2 = capabilities as a Python/JSON list literal
v4_rooted_fixture() {
  python3 - <<PY
import json
p = "$STATE/app-ledger.json"
d = {"version": 4, "entries": {"evil2": {"intent": {
    "path": "/nonexistent/evil2-pkg", "digest": "f" * 64,
    "artifacts_declared": {"units": [], "fragments": [], "webroot": [], "files": [],
                           "rooted": $1, "serve_ports": []},
    "serve_port_values": {},
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "deps": [], "anchors": {},
    "roots": {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
              "webroot": "$WEB", "home": "$FAKEHOME"},
    "serve_mappings": {}, "unit_scopes": {}, "order": None,
    "source_class": "explicit",
    "capabilities": $2,
}}}}
json.dump(d, open(p, "w"))
PY
}

reset_box
v4_rooted_fixture '["/opt/airlock/legit-looking"]' '[]'
out_v4a="$(printf '{}' | "$LEDGER" list 2>&1)"; rc_v4a=$?
if [ "$rc_v4a" -ne 0 ] \
   && grep -Fq "artifacts_declared.rooted is non-empty but capabilities does not claim 'rooted-artifact'" <<<"$out_v4a"; then
  ok "v4: a rooted DECLARATION with no capability claim is refused at load"
else
  bad "v4: declaration without claim was not refused (rc=$rc_v4a)"
  failure_detail "$out_v4a"
fi

reset_box
v4_rooted_fixture '[]' '["rooted-artifact"]'
out_v4b="$(printf '{}' | "$LEDGER" list 2>&1)"; rc_v4b=$?
if [ "$rc_v4b" -ne 0 ] \
   && grep -Fq "capabilities claims 'rooted-artifact' but artifacts_declared.rooted is empty" <<<"$out_v4b"; then
  ok "v4: a rooted-artifact CLAIM the declaration cannot prove is refused at load"
else
  bad "v4: claim without declaration was not refused (rc=$rc_v4b)"
  failure_detail "$out_v4b"
fi

reset_box
v4_rooted_fixture '[]' '["root"]'
out_v4c="$(printf '{}' | "$LEDGER" list 2>&1)"; rc_v4c=$?
if [ "$rc_v4c" -ne 0 ] && grep -Fq "unknown capability 'root'" <<<"$out_v4c"; then
  ok "v4: a capability name outside the vocabulary is refused at load"
else
  bad "v4: unknown capability name was not refused (rc=$rc_v4c)"
  failure_detail "$out_v4c"
fi

# The /etc/passwd repro above, restated as a record that claims the
# capability outright rather than one that claims source_class=shipped. Both
# are equally forgeable by a unix user who could edit the tree anyway; what
# stops them is the allowlist, not the claim. This is the LOAD-time half
# only (main() loads the store before dispatching, so an intent record's
# declared pattern never survives to execution); the execution-time half is
# the rc-web case below, the only shape that reaches it — a COMMITTED
# record, whose artifacts are recorded paths no declaration re-validates.
reset_box
python3 - <<PY
import json
p = "$STATE/app-ledger.json"
d = {"version": 4, "entries": {"evil3": {"intent": {
    "path": "/nonexistent/evil3-pkg", "digest": "f" * 64,
    "artifacts_declared": {"units": [], "fragments": [], "webroot": [], "files": [],
                           "rooted": ["/etc/passwd"], "serve_ports": []},
    "serve_port_values": {},
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "deps": [], "anchors": {},
    "roots": $evil_roots,
    "serve_mappings": {}, "unit_scopes": {}, "order": None,
    "source_class": "shipped",
    "capabilities": ["rooted-artifact"],
}}}}
json.dump(d, open(p, "w"))
PY
plan_v4e="$(ledger_run '{"packages":{}}' plan 2>&1)"; rc_plan_v4e=$?
rm_v4e="$(ledger_run '{"packages":{}}' remove evil3 2>&1)"; rc_rm_v4e=$?
if [ "$rc_plan_v4e" -ne 0 ] && grep -Fq "is outside the rooted allowlist" <<<"$plan_v4e" \
   && [ "$rc_rm_v4e" -ne 0 ] && grep -Fq "is outside the rooted allowlist" <<<"$rm_v4e" \
   && [ -e /etc/passwd ]; then
  ok "v4: claiming rooted-artifact buys nothing outside the allowlist (refused at load, before any command runs)"
else
  bad "v4: allowlist not enforced for a capability-claiming record (plan_rc=$rc_plan_v4e remove_rc=$rc_rm_v4e)"
  failure_detail "$plan_v4e"
  failure_detail "$rm_v4e"
fi

# The three EXECUTION-path gates (expand_declared, _committed_artifacts,
# _remove_rooted_artifact_path) are belt-and-braces: _validate_record refuses
# their input first, so no CLI fixture can reach them and an end-to-end test
# claiming to cover them would be a false green. Probed directly instead —
# otherwise "the check exists" is all this suite would prove about them.
reset_box
probe_out="$(python3 - "$LEDGER" <<'PY' 2>&1
import importlib.util, sys
from importlib.machinery import SourceFileLoader
# Same loader dance as bin/airlock-config._ledger_module: the tool has no
# .py suffix, so spec_from_file_location alone finds no loader for it.
loader = SourceFileLoader("_airlock_ledger", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
sys.dont_write_bytecode = True
loader.exec_module(m)
p = "/opt/airlock/probe-bundle/marker"
declared = {"units": [], "fragments": [], "webroot": [], "files": [],
            "rooted": [p], "serve_ports": []}


def refuses(label, fn):
    try:
        fn()
    except m.LedgerError as exc:
        print(f"{label}: REFUSED: {exc}")
    else:
        print(f"{label}: ALLOWED")


refuses("expand", lambda: m.expand_declared(declared, {}, capabilities=[]))
refuses("expand-claimed",
        lambda: m.expand_declared(declared, {}, capabilities=["rooted-artifact"]))
refuses("committed", lambda: m._committed_artifacts(
    {"artifacts": dict(declared), "capabilities": []}))
refuses("committed-claimed", lambda: m._committed_artifacts(
    {"artifacts": dict(declared), "capabilities": ["rooted-artifact"]}))
print("remove-unclaimed:", m._remove_rooted_artifact_path(p, True, []))
print("remove-claimed:", m._remove_rooted_artifact_path(p, True, ["rooted-artifact"]))
PY
)"
if grep -Fq "expand: REFUSED: artifacts_declared.rooted: the record does not claim the 'rooted-artifact' capability" <<<"$probe_out" \
   && grep -Fq "expand-claimed: ALLOWED" <<<"$probe_out" \
   && grep -Fq "committed: REFUSED: committed.artifacts.rooted: the record does not claim the 'rooted-artifact' capability" <<<"$probe_out" \
   && grep -Fq "committed-claimed: ALLOWED" <<<"$probe_out" \
   && grep -Fq "remove-unclaimed: False" <<<"$probe_out" \
   && grep -Fq "remove-claimed: True" <<<"$probe_out"; then
  ok "v4: expansion, committed expansion and rooted removal each refuse a record that does not claim the capability (and each allow one that does)"
else
  bad "v4: the three execution-path capability gates did not behave as a matched refuse/allow pair"
  failure_detail "$probe_out"
fi

# Round trip on a REAL record: intent -> load -> expand -> commit -> teardown,
# with the capability on disk and the artifact actually gone at the end.
reset_box
rt_cap="$PKGROOT/rt-cap"
rt_cap_marker="$(dirname "$WEB")/rt-cap-bundle/marker"
mkdir -p "$(dirname "$rt_cap_marker")"; : >"$rt_cap_marker"
mkpkg "$rt_cap" rt-cap 'contract = 1' 'id = "rt-cap"' \
  '[artifacts]' 'rooted = ["${webroot_parent}/rt-cap-bundle/marker"]'
cfg_rtc="$CFGROOT/rt-cap.toml"
{ base_config; printf '[apps.rt-cap]\n'; } >"$cfg_rtc"
info_rtc="$(run "$cfg_rtc" package-info 2>/dev/null)"
commit_packages "$info_rtc" rt-cap; rc_rtc=$?
caps_rtc="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d["entries"]["rt-cap"]["committed"]["capabilities"]))' "$STATE/app-ledger.json" 2>&1)"
val_rtc="$(run "$cfg_rtc" validate 2>&1)"; rc_val_rtc=$?
drop_rtc="$CFGROOT/rt-cap-drop.toml"; base_config >"$drop_rtc"
drop_info_rtc="$(run "$drop_rtc" package-info 2>/dev/null)"
rm_rtc="$(ledger_run "$drop_info_rtc" remove rt-cap 2>&1)"; rc_rm_rtc=$?
if [ "$rc_rtc" = 0 ] && [ "$caps_rtc" = '["rooted-artifact"]' ] && [ "$rc_val_rtc" = 0 ] \
   && [ "$rc_rm_rtc" = 0 ] && [ ! -e "$rt_cap_marker" ]; then
  ok "v4: a rooted record round-trips intent -> commit -> teardown on its own capability claim"
else
  bad "v4: rooted round trip (commit=$rc_rtc caps=$caps_rtc validate=$rc_val_rtc remove=$rc_rm_rtc marker=$([ -e "$rt_cap_marker" ] && echo present || echo gone))"
  failure_detail "$val_rtc"
  failure_detail "$rm_rtc"
fi

# THE crux of P3: an installed record is HISTORY. Commit it, then rewrite the
# stored source_class to "explicit" — the value the old load-time gate keyed
# on, and the value a revoked grant would leave behind. Load and teardown
# must both still succeed, because neither reads it any more.
reset_box
hp_cap="$PKGROOT/hp-cap"
hp_marker="$(dirname "$WEB")/hp-cap-bundle/marker"
mkdir -p "$(dirname "$hp_marker")"; : >"$hp_marker"
mkpkg "$hp_cap" hp-cap 'contract = 1' 'id = "hp-cap"' \
  '[artifacts]' 'rooted = ["${webroot_parent}/hp-cap-bundle/marker"]'
cfg_hpc="$CFGROOT/hp-cap.toml"
{ base_config; printf '[apps.hp-cap]\n'; } >"$cfg_hpc"
info_hpc="$(run "$cfg_hpc" package-info 2>/dev/null)"
commit_packages "$info_hpc" hp-cap; rc_hpc=$?
python3 - "$STATE/app-ledger.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["entries"]["hp-cap"]["committed"]["source_class"] = "explicit"
json.dump(d, open(p, "w"))
PY
list_hpc="$(printf '{}' | "$LEDGER" list 2>&1)"; rc_list_hpc=$?
drop_hpc="$CFGROOT/hp-cap-drop.toml"; base_config >"$drop_hpc"
drop_info_hpc="$(run "$drop_hpc" package-info 2>/dev/null)"
rm_hpc="$(ledger_run "$drop_info_hpc" remove hp-cap 2>&1)"; rc_rm_hpc=$?
if [ "$rc_hpc" = 0 ] && [ "$rc_list_hpc" = 0 ] && [ "$rc_rm_hpc" = 0 ] && [ ! -e "$hp_marker" ]; then
  ok "v4: history, not policy — a committed rooted record loads and tears down with source_class hand-edited to explicit"
else
  bad "v4: history-not-policy (commit=$rc_hpc list=$rc_list_hpc remove=$rc_rm_hpc marker=$([ -e "$hp_marker" ] && echo present || echo gone))"
  failure_detail "$list_hpc"
  failure_detail "$rm_hpc"
fi

# The conditional rooted artifact the one-way committed rule exists for: the
# declaration claims the capability, the installer never creates the path, so
# artifacts.rooted commits EMPTY (the found set) beside a non-empty claim. A
# biconditional on the committed record would refuse this healthy commit.
reset_box
cond_cap="$PKGROOT/cond-cap"
cond_marker="$(dirname "$WEB")/cond-cap-bundle/marker"
mkpkg "$cond_cap" cond-cap 'contract = 1' 'id = "cond-cap"' \
  '[artifacts]' 'rooted = ["${webroot_parent}/cond-cap-bundle/marker"]'
cfg_cond="$CFGROOT/cond-cap.toml"
{ base_config; printf '[apps.cond-cap]\n'; } >"$cfg_cond"
info_cond="$(run "$cfg_cond" package-info 2>/dev/null)"
commit_packages "$info_cond" cond-cap; rc_cond=$?
cond_json="$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["entries"]["cond-cap"]["committed"]; print(json.dumps([c["artifacts"]["rooted"], c["capabilities"]]))' "$STATE/app-ledger.json" 2>&1)"
list_cond="$(printf '{}' | "$LEDGER" list 2>&1)"; rc_list_cond=$?
if [ "$rc_cond" = 0 ] && [ "$cond_json" = '[[], ["rooted-artifact"]]' ] && [ "$rc_list_cond" = 0 ] \
   && [ ! -e "$cond_marker" ]; then
  ok "v4: a conditional rooted artifact commits with rooted:[] beside its claim, and the record loads"
else
  bad "v4: conditional rooted commit (commit=$rc_cond json=$cond_json list=$rc_list_cond)"
  failure_detail "$list_cond"
fi

# remove --for-upgrade drops the committed record (tearing the rooted
# artifact down through the OLD record's claim), and the reinstall writes a
# fresh one — the upgrade round trip design record §7 names by hand.
reset_box
up_cap="$PKGROOT/up-cap"
up_marker="$(dirname "$WEB")/up-cap-bundle/marker"
mkdir -p "$(dirname "$up_marker")"; : >"$up_marker"
mkpkg "$up_cap" up-cap 'contract = 1' 'id = "up-cap"' \
  '[artifacts]' 'rooted = ["${webroot_parent}/up-cap-bundle/marker"]'
cfg_up="$CFGROOT/up-cap.toml"
{ base_config; printf '[apps.up-cap]\n'; } >"$cfg_up"
info_up="$(run "$cfg_up" package-info 2>/dev/null)"
commit_packages "$info_up" up-cap; rc_up1=$?
up_rm="$(ledger_run "$info_up" remove up-cap --for-upgrade 2>&1)"; rc_up_rm=$?
# Asserted BEFORE the reinstall recreates it: the for-upgrade teardown ran on
# the old committed record's own claim, so the artifact must be gone here or
# a removal that quietly returned success would read as a pass.
up_gone=$([ -e "$up_marker" ] && echo present || echo gone)
: >"$up_marker"
commit_packages "$info_up" up-cap; rc_up2=$?
up_caps="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d["entries"]["up-cap"]["committed"]["capabilities"]))' "$STATE/app-ledger.json" 2>&1)"
if [ "$rc_up1" = 0 ] && [ "$rc_up_rm" = 0 ] && [ "$up_gone" = gone ] && [ "$rc_up2" = 0 ] \
   && [ "$up_caps" = '["rooted-artifact"]' ]; then
  ok "v4: remove --for-upgrade then reinstall round-trips a rooted record"
else
  bad "v4: for-upgrade round trip (commit1=$rc_up1 remove=$rc_up_rm marker=$up_gone commit2=$rc_up2 caps=$up_caps)"
  failure_detail "$up_rm"
fi

# command_commit's record-diff branch is the one rewritten teardown call site
# that needs a package WITHOUT a deactivator (D6: only those upgrade through
# the diff), and it tears down using the OLD committed record's claim. A
# rooted path dropped between two commits must actually go.
reset_box
dc_pkg="$PKGROOT/dc-cap"
dc_keep="$(dirname "$WEB")/dc-cap-bundle/keep"
dc_drop="$(dirname "$WEB")/dc-cap-bundle/drop"
mkdir -p "$(dirname "$dc_keep")"; : >"$dc_keep"; : >"$dc_drop"
mkpkg_nd "$dc_pkg" dc-cap 'contract = 1' 'id = "dc-cap"' \
  '[artifacts]' 'rooted = ["${webroot_parent}/dc-cap-bundle/keep", "${webroot_parent}/dc-cap-bundle/drop"]'
cfg_dc="$CFGROOT/dc-cap.toml"
{ base_config; printf '[apps.dc-cap]\n'; } >"$cfg_dc"
info_dc1="$(run "$cfg_dc" package-info 2>/dev/null)"
commit_packages "$info_dc1" dc-cap; rc_dc1=$?
mkpkg_nd "$dc_pkg" dc-cap 'contract = 1' 'id = "dc-cap"' \
  '[artifacts]' 'rooted = ["${webroot_parent}/dc-cap-bundle/keep"]'
info_dc2="$(run "$cfg_dc" package-info 2>/dev/null)"
commit_packages "$info_dc2" dc-cap; rc_dc2=$?
if [ "$rc_dc1" = 0 ] && [ "$rc_dc2" = 0 ] && [ -e "$dc_keep" ] && [ ! -e "$dc_drop" ]; then
  ok "v4: the upgrade record-diff reclaims a dropped rooted path through the old committed record's claim"
else
  bad "v4: record-diff rooted teardown (commit1=$rc_dc1 commit2=$rc_dc2 keep=$([ -e "$dc_keep" ] && echo present || echo GONE) drop=$([ -e "$dc_drop" ] && echo PRESENT || echo gone))"
fi

# The v3 read path: a LEGITIMATE v3 rooted record — shipped-class, which the
# v3 assertion above guarantees is the only kind that can exist — carries no
# capability list, so normalisation derives the claim from the declaration the
# record does carry. That is the same evidence the v4 biconditional checks, so
# what loads is self-consistent, and the allowlist still bounds it. Both halves
# of the v3 path are pinned: this record loads and tears down, the explicit one
# above does not load at all.
reset_box
python3 - <<PY
import json
p = "$STATE/app-ledger.json"
d = {"version": 3, "entries": {"v3rooted": {"intent": {
    "path": "/nonexistent/v3rooted-pkg", "digest": "f" * 64,
    "artifacts_declared": {"units": [], "fragments": [], "webroot": [], "files": [],
                           "rooted": ["/opt/airlock/v3rooted-bundle/"], "serve_ports": []},
    "serve_port_values": {},
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "deps": [], "anchors": {},
    "roots": {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
              "webroot": "$WEB", "home": "$FAKEHOME"},
    "serve_mappings": {}, "unit_scopes": {}, "order": None,
    "source_class": "shipped",
}}}}
json.dump(d, open(p, "w"))
PY
list_v3r="$(printf '{}' | "$LEDGER" list 2>&1)"; rc_v3r=$?
rm_v3r="$(ledger_run '{"packages":{}}' remove v3rooted 2>&1)"; rc_rm_v3r=$?
caps_v3r="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(list(d["entries"]))' "$STATE/app-ledger.json" 2>&1)"
if [ "$rc_v3r" = 0 ] && [ "$rc_rm_v3r" = 0 ] && [ "$caps_v3r" = "[]" ]; then
  ok "v3 read path: a rooted record normalises to a self-consistent v4 claim and tears down"
else
  bad "v3 read path: rooted record (list=$rc_v3r remove=$rc_rm_v3r entries=$caps_v3r)"
  failure_detail "$list_v3r"
  failure_detail "$rm_v3r"
fi

# The stale-intent sweep reclaims a crashed install's rooted artifact from
# the OLD intent's capability list, not from the new declaration or from any
# config: command_intent's teardown_artifacts call is the one path where the
# record being acted on is already superseded.
reset_box
si_cap="$PKGROOT/si-cap"
si_marker="$(dirname "$WEB")/si-cap-bundle/marker"
mkdir -p "$(dirname "$si_marker")"; : >"$si_marker"
mkpkg "$si_cap" si-cap 'contract = 1' 'id = "si-cap"' \
  '[artifacts]' 'rooted = ["${webroot_parent}/si-cap-bundle/marker"]'
cfg_si="$CFGROOT/si-cap.toml"
{ base_config; printf '[apps.si-cap]\n'; } >"$cfg_si"
info_si1="$(run "$cfg_si" package-info 2>/dev/null)"
si_out1="$(ledger_run "$info_si1" intent si-cap 2>&1)"; rc_si1=$?
# The install "crashes" (no commit) and the declaration is then repaired to
# drop the rooted path entirely.
mkpkg "$si_cap" si-cap 'contract = 1' 'id = "si-cap"'
info_si2="$(run "$cfg_si" package-info 2>/dev/null)"
si_out2="$(ledger_run "$info_si2" intent si-cap 2>&1)"; rc_si2=$?
if [ "$rc_si1" = 0 ] && [ "$rc_si2" = 0 ] && [ ! -e "$si_marker" ]; then
  ok "v4: the stale-intent sweep reclaims a rooted artifact through the old record's claim"
else
  bad "v4: stale-intent sweep with rooted (intent1=$rc_si1 intent2=$rc_si2 marker=$([ -e "$si_marker" ] && echo present || echo gone))"
  failure_detail "$si_out2"
fi

# Admission stays in bin/airlock-config: the policy moved out of the ledger's
# LOAD path, not out of the product. package-info is the ledger's only input,
# and an explicit package without an operator grant remains shut.
reset_box
adm_x="$TMP/adm-explicit"
mkpkg "$adm_x" adm-explicit 'contract = 1' 'id = "adm-explicit"' \
  '[artifacts]' 'rooted = ["/opt/airlock/adm-bundle/"]'
cfg_adm="$CFGROOT/adm-explicit.toml"; make_pkg_cfg "$cfg_adm" adm-explicit "$adm_x"
expect_fail "admission: an explicit manifest declaring rooted is still fatal at package-info" \
  "missing capability grant(s): ['rooted-artifact']" run "$cfg_adm" package-info

# What the ledger kept when the policy stayed in bin/airlock-config: a
# CONSISTENCY check on the facts it was handed. A producer that derives a
# capability list its own artifacts contradict is loud here, at the ledger's
# entrance, rather than writing a record the next load would refuse.
reset_box
pf_pkg="$PKGROOT/pf-cap"
mkpkg "$pf_pkg" pf-cap 'contract = 1' 'id = "pf-cap"'
pf_info='{"packages":{"pf-cap":{"dir":"'"$pf_pkg"'","artifacts":{"units":[],"fragments":[],"webroot":[],"files":[],"rooted":["/opt/airlock/pf-bundle/"],"serve_ports":[]},"serve_port_values":{},"lifecycle":{"install":true,"smoke":true,"deactivate":true},"deps":[],"source_class":"shipped","capabilities":[]}}}'
expect_fail "v4: package facts whose rooted declaration and capability claim disagree are refused at the ledger's entrance" \
  "'rooted-artifact' capability disagree" ledger_run "$pf_info" intent pf-cap

# =============================================================================
# Store v4 system-unit contract (capability-one-place P1, red-first).
#
# A unit's requested scope and the system-unit claim are two spellings of the
# same effective fact. Package-info and an INTENT can prove both directions,
# so they must agree exactly. A COMMITTED record carries the found set, so the
# rule is intentionally one-way there: any system/both scope OR any recorded
# path under the record's own system-unit root requires the claim. These
# checks are ledger consistency, not package admission policy.
# =============================================================================

system_package_info() {
  local id="$1" scope="$2" capabilities="$3"
  printf '%s' '{"packages":{"'"$id"'":{"dir":"'"$PKGROOT/$id"'","artifacts":{"units":["probe.service"],"fragments":[],"webroot":[],"files":[],"rooted":[],"serve_ports":[]},"serve_port_values":{},"unit_scopes":{"probe.service":"'"$scope"'"},"lifecycle":{"install":false,"smoke":false,"deactivate":false},"deps":[],"source_class":"explicit","capabilities":'"$capabilities"'}}}'
}

reset_box
mkdir -p "$PKGROOT/su-pkg-missing"
su_pkg_missing="$(system_package_info su-pkg-missing system '[]')"
expect_fail "v4 system-unit: package-info refuses a system scope without its claim" \
  "unit_scopes has system/both but capabilities does not claim 'system-unit'" \
  ledger_run "$su_pkg_missing" intent su-pkg-missing

reset_box
mkdir -p "$PKGROOT/su-pkg-spurious"
su_pkg_spurious="$(system_package_info su-pkg-spurious user '["system-unit"]')"
expect_fail "v4 system-unit: package-info refuses a claim with only user-scoped units" \
  "capabilities claims 'system-unit' but unit_scopes has no system/both" \
  ledger_run "$su_pkg_spurious" intent su-pkg-spurious

# $1 = record kind, $2 = unit scope, $3 = capabilities JSON, $4 = recorded
# unit path. The exact v4 shape is generated in one place so a malformed
# fixture cannot create a false red unrelated to the system-unit invariant.
v4_system_fixture() {
  python3 - "$1" "$2" "$3" "$4" <<PY
import json
import sys

kind, scope, capabilities_json, unit_path = sys.argv[1:]
artifacts = {"units": [unit_path], "fragments": [], "webroot": [], "files": [],
             "rooted": [], "serve_ports": []}
common = {
    "path": "/nonexistent/system-unit-probe", "digest": "f" * 64,
    "lifecycle": {"install": False, "smoke": False, "deactivate": False},
    "deps": [], "serve_mappings": {},
    "unit_scopes": {"probe.service": scope}, "order": None,
    "source_class": "explicit", "capabilities": json.loads(capabilities_json),
}
if kind == "intent":
    record = dict(common,
                  artifacts_declared=artifacts,
                  serve_port_values={}, anchors={},
                  roots={"unit_user": "$UU", "unit_system": "$US",
                         "confd": "$CONFD", "webroot": "$WEB",
                         "home": "$FAKEHOME"})
else:
    record = dict(common, artifacts=artifacts,
                  roots={"unit_user": "$UU", "unit_system": "$US",
                         "confd": "$CONFD", "webroot": "$WEB",
                         "home": "$FAKEHOME"})
json.dump({"version": 4, "entries": {"su-record": {kind: record}}},
          open("$STATE/app-ledger.json", "w"))
PY
}

reset_box
v4_system_fixture intent system '[]' probe.service
expect_fail "v4 system-unit: an intent with system scope and no claim is refused at load" \
  "unit_scopes has system/both but capabilities does not claim 'system-unit'" \
  ledger_run '{"packages":{}}' list

reset_box
v4_system_fixture intent user '["system-unit"]' probe.service
expect_fail "v4 system-unit: an intent with a spurious claim is refused at load" \
  "capabilities claims 'system-unit' but unit_scopes has no system/both" \
  ledger_run '{"packages":{}}' list

reset_box
v4_system_fixture committed system '[]' "$US/probe.service"
expect_fail "v4 system-unit: a committed system scope without its claim is refused at load" \
  "unit_scopes has system/both but capabilities does not claim 'system-unit'" \
  ledger_run '{"packages":{}}' list

# A committed record contains the found set, not the full declaration. A
# conditional system unit may be absent while the admitted claim remains;
# requiring the reverse direction here would strand a healthy record.
reset_box
python3 - "$STATE/app-ledger.json" <<PY
import json
record = {
    "path": "/nonexistent/conditional-system-unit", "digest": "f" * 64,
    "lifecycle": {"install": False, "smoke": False, "deactivate": False},
    "deps": [], "serve_mappings": {}, "unit_scopes": {}, "order": None,
    "roots": {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
              "webroot": "$WEB", "home": "$FAKEHOME"},
    "source_class": "explicit", "capabilities": ["system-unit"],
    "artifacts": {"units": [], "fragments": [], "webroot": [], "files": [],
                  "rooted": [], "serve_ports": []},
}
json.dump({"version": 4, "entries": {"su-conditional": {"committed": record}}},
          open("$STATE/app-ledger.json", "w"))
PY
conditional_out="$(ledger_run '{"packages":{}}' list 2>&1)"; conditional_rc=$?
if [ "$conditional_rc" = 0 ] && grep -q '^su-conditional' <<<"$conditional_out"; then
  ok "v4 system-unit: a conditional absent committed unit may retain its admitted claim"
else
  bad "v4 system-unit: conditional absent claim was rejected (rc=$conditional_rc)"
  failure_detail "$conditional_out"
fi

# Path truth is an independent backstop: a hand-edited committed record may
# lie that a path under unit_system has user scope. Removal must reject the
# missing claim while the record, unit file, and empty systemctl log prove no
# lifecycle/filesystem/systemd side effect happened first.
reset_box
: >"$US/probe.service"
v4_system_fixture committed user '[]' "$US/probe.service"
su_remove_out="$(ledger_run '{"packages":{}}' teardown su-record 2>&1)"; su_remove_rc=$?
if [ "$su_remove_rc" -ne 0 ] \
   && grep -Fq "artifacts.units contains a system unit but capabilities does not claim 'system-unit'" <<<"$su_remove_out" \
   && [ -e "$US/probe.service" ] \
   && [ ! -s "$TMP/systemctl.log" ] \
   && python3 -c 'import json,sys; assert "su-record" in json.load(open(sys.argv[1]))["entries"]' \
        "$STATE/app-ledger.json"; then
  ok "v4 system-unit: recorded system path without a claim is refused before teardown side effects"
else
  bad "v4 system-unit: missing path claim was not preflighted (rc=$su_remove_rc unit=$([ -e "$US/probe.service" ] && echo present || echo REMOVED) systemctl=$([ -s "$TMP/systemctl.log" ] && echo CALLED || echo empty))"
  failure_detail "$su_remove_out"
fi

# A LEGITIMATE shipped rooted record, refused (loud, nothing deleted) after
# a genuine webroot change — the accepted trade-off: fail-closed over
# trusting the record's own roots snapshot.
reset_box
rc_web="$PKGROOT/rc-web"
rc_marker="$(dirname "$WEB")/rc-web-marker"
mkdir -p "$(dirname "$rc_marker")"; : >"$rc_marker"
mkpkg "$rc_web" rc-web 'contract = 1' 'id = "rc-web"' \
  '[artifacts]' 'rooted = ["${webroot_parent}/rc-web-marker"]'
cfg_rcw="$CFGROOT/rc-web.toml"
{ base_config; printf '[apps.rc-web]\n'; } >"$cfg_rcw"
info_rcw="$(run "$cfg_rcw" package-info 2>/dev/null)"
commit_packages "$info_rcw" rc-web; rc_rcw1=$?
# The webroot moves — a real, legitimate reconfiguration.
NEW_WEB="$TMP/web2/hub"; mkdir -p "$NEW_WEB/assets"
drop_rcw="$CFGROOT/rc-web-drop.toml"; base_config >"$drop_rcw"
drop_info_rcw="$(AIRLOCK_WEBROOT="$NEW_WEB" run "$drop_rcw" package-info 2>/dev/null)"
rm_out_rcw="$(AIRLOCK_WEBROOT="$NEW_WEB" ledger_run "$drop_info_rcw" remove rc-web 2>&1)"; rc_rm_rcw=$?
if [ "$rc_rcw1" = 0 ] && [ "$rc_rm_rcw" -ne 0 ] && grep -q "restore the webroot" <<<"$rm_out_rcw" \
   && [ -e "$rc_marker" ] \
   && ledger_run '{}' list 2>/dev/null | grep -q '^rc-web'; then
  ok "BLOCKER C: a legitimate record is refused (loud, nothing deleted) after a webroot change"
else
  bad "BLOCKER C: webroot-change refusal (commit=$rc_rcw1 remove=$rc_rm_rcw marker=$([ -e "$rc_marker" ] && echo present || echo GONE))"
  failure_detail "$rm_out_rcw"
fi

# =============================================================================
# MAJOR D: a same-listen MODE flip (http -> https, same port number) must
# not be invisible to the diff — a numeric-only port diff sees no change at
# all, since the number survives in both the old and new sets.
# =============================================================================

reset_box
md_a="$PKGROOT/md-a"
mkpkg_nd "$md_a" md-a 'contract = 1' 'id = "md-a"' \
  '[config.defaults]' 'listen_port = 16501' \
  '[artifacts]' 'serve_ports = ["listen_port"]'
cfg_md="$CFGROOT/md-a.toml"
{ base_config; printf '[apps.md-a]\n'; } >"$cfg_md"
info_md="$(run "$cfg_md" package-info 2>/dev/null)"
commit_packages "$info_md" md-a; rc_md1=$?
mkpkg_nd "$md_a" md-a 'contract = 1' 'id = "md-a"' \
  '[config.defaults]' 'listen_port = 16501' 'target_port = 16502' \
  '[artifacts]' 'serve_ports = ["listen_port"]' \
  '[serve.https]' 'listen_port = "target_port"'
info_md2="$(run "$cfg_md" package-info 2>/dev/null)"
commit_packages "$info_md2" md-a; rc_md2=$?
if [ "$rc_md1" = 0 ] && [ "$rc_md2" = 0 ] && grep -q -- '--http=16501 off' "$TMP/tailscale.log"; then
  ok "MAJOR D: a same-listen http -> https mode flip offs the old http mapping"
else
  bad "MAJOR D: same-listen mode flip (commit1=$rc_md1 commit2=$rc_md2)"
  cat "$TMP/tailscale.log" | sed 's/^/    ts: /'
fi

# =============================================================================
# MINOR E: committed and intent coexisting, both mapping the SAME (mode,
# listen), must issue exactly ONE off — not two independent attempts from
# two separate teardown_artifacts calls.
# =============================================================================

reset_box
python3 - "$STATE/app-ledger.json" <<PY
import json
p = "$STATE/app-ledger.json"
common_roots = {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
                "webroot": "$WEB", "home": "$FAKEHOME"}
d = {"version": 3, "entries": {"dup": {
    "committed": {
        "path": "/nonexistent/dup-pkg", "digest": "a" * 64,
        "lifecycle": {"install": True, "smoke": True, "deactivate": False},
        "deps": [],
        "artifacts": {"units": [], "fragments": [], "webroot": [], "files": [], "rooted": [], "serve_ports": []},
        "serve_mappings": {"k": {"listen": 16601, "mode": "https", "target": 1}},
        "unit_scopes": {}, "order": None, "roots": common_roots, "source_class": "explicit",
    },
    "intent": {
        "path": "/nonexistent/dup-pkg", "digest": "b" * 64,
        "artifacts_declared": {"units": [], "fragments": [], "webroot": [], "files": [], "rooted": [], "serve_ports": []},
        "serve_port_values": {}, "lifecycle": {"install": True, "smoke": True, "deactivate": False},
        "deps": [], "anchors": {}, "roots": common_roots,
        "serve_mappings": {"k": {"listen": 16601, "mode": "https", "target": 1}},
        "unit_scopes": {}, "order": None, "source_class": "explicit",
    },
}}}
json.dump(d, open(p, "w"))
PY
td_dup="$(ledger_run '{"packages":{}}' teardown dup 2>&1)"; rc_td_dup=$?
off_count="$(grep -c -- '--https=16601 off' "$TMP/tailscale.log")"
if [ "$rc_td_dup" = 0 ] && [ "$off_count" = 1 ]; then
  ok "MINOR E: a (mode, listen) both committed and intent map gets exactly one off"
else
  bad "MINOR E: dedup across committed+intent (rc=$rc_td_dup off_count=$off_count)"
  failure_detail "$td_dup"
  cat "$TMP/tailscale.log" | sed 's/^/    ts: /'
fi

# =============================================================================
# ROUND 3 BLOCKER 1: serve surfaces (serve_ports/serve.https vs
# plaintext_redirect) must be pairwise disjoint per app — both structurally
# (same key in two surfaces) and by resolved value (two different keys that
# happen to share one config value).
# =============================================================================

reset_box
bl1_a="$PKGROOT/bl1-a"
mkpkg "$bl1_a" bl1-a 'contract = 1' 'id = "bl1-a"' \
  '[config.defaults]' 'public_port = 16701' 'redirect_port = 16702' \
  '[artifacts]' 'serve_ports = ["public_port"]' \
  '[plaintext_redirect]' 'public_port = "redirect_port"'
cfg_bl1a="$CFGROOT/bl1-a.toml"
{ base_config; printf '[apps.bl1-a]\n'; } >"$cfg_bl1a"
expect_fail "BLOCKER 1: the SAME key in serve_ports and plaintext_redirect is fatal" \
  "declared in both artifacts.serve_ports and plaintext_redirect" run "$cfg_bl1a" validate

reset_box
# Key names deliberately do NOT end in "_port": the pre-existing D8 global
# port-uniqueness sweep (_validate_ports) already catches any collision
# between two "*_port"-suffixed keys BEFORE this check is ever reached — to
# actually exercise the NEW resolved-value disjointness check (not just
# rediscover the older, broader one), the colliding keys must dodge that
# suffix, the same way a real manifest's [config] schema legitimately can
# (the grammar allows any [a-z0-9_]+ name).
bl1_b="$PKGROOT/bl1-b"
mkpkg "$bl1_b" bl1-b 'contract = 1' 'id = "bl1-b"' \
  '[config.defaults]' 'pub = 16401' 'red = 16402' 'other = 16401' \
  '[artifacts]' 'serve_ports = ["other"]' \
  '[plaintext_redirect]' 'pub = "red"'
cfg_bl1b="$CFGROOT/bl1-b.toml"
{ base_config; printf '[apps.bl1-b]\n'; } >"$cfg_bl1b"
expect_fail "BLOCKER 1: the reproduced double-declaration (16401/16402 then 16401/16401) is fatal" \
  "resolve to port 16401" run "$cfg_bl1b" validate

# A CLEAN mixed manifest (disjoint: a 301 pair, an https listen, a bare http
# key, none sharing a key or a value) must still emit exactly its http rows —
# the fix must not have made legitimate mixed manifests collateral damage.
reset_box
bl1_c="$PKGROOT/bl1-c"
mkpkg "$bl1_c" bl1-c 'contract = 1' 'id = "bl1-c"' \
  '[config.defaults]' 'pub = 16801' 'red = 16802' 'https_listen = 16803' \
  'https_target = 16804' 'bare_http = 16805' \
  '[artifacts]' 'serve_ports = ["https_listen", "bare_http"]' \
  '[serve.https]' 'https_listen = "https_target"' \
  '[plaintext_redirect]' 'pub = "red"'
cfg_bl1c="$CFGROOT/bl1-c.toml"
{ base_config; printf '[apps.bl1-c]\n'; } >"$cfg_bl1c"
plain_bl1c="$(run "$cfg_bl1c" plaintext 2>&1)"
if [ "$(grep -c '^bl1-c' <<<"$plain_bl1c")" = 2 ] \
   && grep -q $'bl1-c\t16801\t16802' <<<"$plain_bl1c" \
   && grep -q $'bl1-c\t16805\t16805' <<<"$plain_bl1c" \
   && ! grep -q '16803' <<<"$plain_bl1c"; then
  ok "BLOCKER 1: a clean mixed manifest still emits exactly its http rows"
else
  bad "BLOCKER 1: clean mixed manifest regression"
  failure_detail "$plain_bl1c"
fi

# =============================================================================
# ROUND 3 BLOCKER 2: a webroot placed directly under / collapses
# webroot_parent to "/" — the dynamic rooted anchor must be refused, not
# unioned into the allowlist as "the whole filesystem".
# =============================================================================

reset_box
python3 - "$STATE/app-ledger.json" <<PY
import json
p = "$STATE/app-ledger.json"
d = {"version": 3, "entries": {"evil3": {"intent": {
    "path": "/nonexistent/evil3-pkg", "digest": "f" * 64,
    "artifacts_declared": {"units": [], "fragments": [], "webroot": [], "files": [],
                           "rooted": ["/etc/passwd"], "serve_ports": []},
    "serve_port_values": {},
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "deps": [], "anchors": {},
    "roots": {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
              "webroot": "/hub", "home": "$FAKEHOME"},
    "serve_mappings": {}, "unit_scopes": {}, "order": None,
    "source_class": "shipped",
}}}}
json.dump(d, open(p, "w"))
PY
plan_hub="$(AIRLOCK_WEBROOT=/hub ledger_run '{"packages":{}}' plan 2>&1)"; rc_plan_hub=$?
remove_hub="$(AIRLOCK_WEBROOT=/hub ledger_run '{"packages":{}}' remove evil3 2>&1)"; rc_remove_hub=$?
if [ "$rc_plan_hub" -ne 0 ] && grep -q "rooted allowlist" <<<"$plan_hub" \
   && [ "$rc_remove_hub" -ne 0 ] && grep -q "rooted allowlist" <<<"$remove_hub"; then
  ok "BLOCKER 2: AIRLOCK_WEBROOT=/hub (webroot_parent=/) is refused at plan and execution"
else
  bad "BLOCKER 2: webroot=/hub collapse not refused (plan_rc=$rc_plan_hub remove_rc=$rc_remove_hub)"
  failure_detail "$plan_hub"
  failure_detail "$remove_hub"
fi

# The SAME check, at the manifest-validate layer (bin/airlock-config has its
# own independent copy of the rooted allowlist, applied before the ledger
# ever sees anything).
reset_box
bl2_hub="$PKGROOT/bl2-hub"
mkpkg "$bl2_hub" bl2-hub 'contract = 1' 'id = "bl2-hub"' \
  '[artifacts]' 'rooted = ["${webroot_parent}/evil-bundle"]'
cfg_bl2h="$CFGROOT/bl2-hub.toml"
{ base_config; printf '[apps.bl2-hub]\n'; } >"$cfg_bl2h"
bl2h_out="$(AIRLOCK_WEBROOT=/hub run "$cfg_bl2h" validate 2>&1)"; rc_bl2h=$?
if [ "$rc_bl2h" -ne 0 ] && grep -q "protected system directory" <<<"$bl2h_out"; then
  ok "BLOCKER 2: manifest-validate also refuses webroot=/hub's collapsed anchor"
else
  bad "BLOCKER 2: manifest-validate did not refuse webroot=/hub (rc=$rc_bl2h)"
  failure_detail "$bl2h_out"
fi

# The default /opt/airlock/... webroot layout must still authorize
# ${webroot_parent} rooted claims (orca's real shape: the bundle lands
# beside the webroot, e.g. /opt/airlock/orca-web next to /opt/airlock/hub).
reset_box
python3 - "$STATE/app-ledger.json" <<PY
import json
p = "$STATE/app-ledger.json"
d = {"version": 3, "entries": {"good-orca": {"intent": {
    "path": "/nonexistent/good-orca-pkg", "digest": "f" * 64,
    "artifacts_declared": {"units": [], "fragments": [], "webroot": [], "files": [],
                           "rooted": ["\${webroot_parent}/orca-web"], "serve_ports": []},
    "serve_port_values": {},
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "deps": [], "anchors": {},
    "roots": {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
              "webroot": "/opt/airlock/hub", "home": "$FAKEHOME"},
    "serve_mappings": {}, "unit_scopes": {}, "order": None,
    "source_class": "shipped",
}}}}
json.dump(d, open(p, "w"))
PY
plan_orca="$(AIRLOCK_WEBROOT=/opt/airlock/hub ledger_run '{"packages":{}}' plan 2>&1)"; rc_plan_orca=$?
if [ "$rc_plan_orca" = 0 ]; then
  ok "BLOCKER 2: the default /opt/airlock webroot layout still authorizes \${webroot_parent}/orca-web"
else
  bad "BLOCKER 2: /opt/airlock webroot_parent wrongly refused (rc=$rc_plan_orca)"
  failure_detail "$plan_orca"
fi

# =============================================================================
# MINOR D: the dynamic rooted anchor guard is a RULE (>= 2 path components),
# not an enumeration. AIRLOCK_WEBROOT=/opt/hub collapses webroot_parent to
# "/opt" (1 component) — one level narrower than round 3's "/" collapse but
# just as dangerous (any top-level /opt entry), and was NOT on the old
# denylist (only "/opt/airlock" was ever meant to be safe).
# =============================================================================

reset_box
python3 - "$STATE/app-ledger.json" <<PY
import json
p = "$STATE/app-ledger.json"
d = {"version": 3, "entries": {"evil-opt": {"intent": {
    "path": "/nonexistent/evil-opt-pkg", "digest": "f" * 64,
    "artifacts_declared": {"units": [], "fragments": [], "webroot": [], "files": [],
                           "rooted": ["\${webroot_parent}/some-other-vendor-dir"], "serve_ports": []},
    "serve_port_values": {},
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "deps": [], "anchors": {},
    "roots": {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
              "webroot": "/opt/hub", "home": "$FAKEHOME"},
    "serve_mappings": {}, "unit_scopes": {}, "order": None,
    "source_class": "shipped",
}}}}
json.dump(d, open(p, "w"))
PY
out_optcol="$(AIRLOCK_WEBROOT=/opt/hub ledger_run '{"packages":{}}' plan 2>&1)"; rc_optcol=$?
if [ "$rc_optcol" -ne 0 ] && grep -q "rooted allowlist" <<<"$out_optcol"; then
  ok "MINOR D: AIRLOCK_WEBROOT=/opt/hub (webroot_parent=/opt) is refused"
else
  bad "MINOR D: /opt collapse not refused (rc=$rc_optcol)"
  failure_detail "$out_optcol"
fi

reset_box
d_opt="$PKGROOT/d-opt"
mkpkg "$d_opt" d-opt 'contract = 1' 'id = "d-opt"' \
  '[artifacts]' 'rooted = ["${webroot_parent}/evil-bundle"]'
cfg_dopt="$CFGROOT/d-opt.toml"
{ base_config; printf '[apps.d-opt]\n'; } >"$cfg_dopt"
out_doptv="$(AIRLOCK_WEBROOT=/opt/hub run "$cfg_dopt" validate 2>&1)"; rc_doptv=$?
if [ "$rc_doptv" -ne 0 ] && grep -q "rooted allowlist" <<<"$out_doptv"; then
  ok "MINOR D: manifest-validate also refuses AIRLOCK_WEBROOT=/opt/hub"
else
  bad "MINOR D: manifest-validate did not refuse /opt collapse (rc=$rc_doptv)"
  failure_detail "$out_doptv"
fi

# /opt/airlock/web (2 components, the legitimate depth) still authorizes
# ${webroot_parent}/orca-web.
reset_box
python3 - "$STATE/app-ledger.json" <<PY
import json
p = "$STATE/app-ledger.json"
d = {"version": 3, "entries": {"good-orca2": {"intent": {
    "path": "/nonexistent/good-orca2-pkg", "digest": "f" * 64,
    "artifacts_declared": {"units": [], "fragments": [], "webroot": [], "files": [],
                           "rooted": ["\${webroot_parent}/orca-web"], "serve_ports": []},
    "serve_port_values": {},
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "deps": [], "anchors": {},
    "roots": {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
              "webroot": "/opt/airlock/web", "home": "$FAKEHOME"},
    "serve_mappings": {}, "unit_scopes": {}, "order": None,
    "source_class": "shipped",
}}}}
json.dump(d, open(p, "w"))
PY
plan_orca2="$(AIRLOCK_WEBROOT=/opt/airlock/web ledger_run '{"packages":{}}' plan 2>&1)"; rc_plan_orca2=$?
if [ "$rc_plan_orca2" = 0 ]; then
  ok "MINOR D: /opt/airlock/web still authorizes \${webroot_parent}/orca-web"
else
  bad "MINOR D: legitimate 2-component webroot wrongly refused (rc=$rc_plan_orca2)"
  failure_detail "$plan_orca2"
fi

# =============================================================================
# ROUND 3 MINOR 3: one corrupt-bytes shipped manifest must not crash the
# whole plaintext-known sweep — the healthy defaults still come through.
# =============================================================================

reset_box
mn_a="$PKGROOT/mn-a"
mkpkg "$mn_a" mn-a 'contract = 1' 'id = "mn-a"' \
  '[config.defaults]' 'public_port = 16901' 'redirect_port = 16902' \
  '[plaintext_redirect]' 'public_port = "redirect_port"'
mn_corrupt="$PKGROOT/mn-corrupt"; mkdir -p "$mn_corrupt"
python3 -c "open('$mn_corrupt/airlock-app.toml', 'wb').write(b'contract = 1\nid = \"mn-corrupt\"\n\xff\xfe not valid utf-8\n')"
cfg_mn="$CFGROOT/mn.toml"; base_config >"$cfg_mn"   # neither app configured — a pure disk scan
known_mn="$(run "$cfg_mn" plaintext-known 2>&1)"; rc_mn=$?
if [ "$rc_mn" = 0 ] && grep -qx '16901' <<<"$known_mn"; then
  ok "MINOR 3: a corrupt-bytes manifest is skipped; the sweep still returns healthy defaults"
else
  bad "MINOR 3: corrupt manifest crashed the sweep or hid the healthy default (rc=$rc_mn)"
  failure_detail "$known_mn"
fi

# =============================================================================
# ROUND 4 MAJOR N1: plaintext_redirect ports join the SAME ownership pool as
# serve ports for CROSS-APP and BUILT-IN disjointness — round 3's fix only
# checked within one manifest's own boundary.
# =============================================================================

reset_box
n1_pa="$PKGROOT/n1-pa"
mkpkg "$n1_pa" n1-pa 'contract = 1' 'id = "n1-pa"' \
  '[config.defaults]' 'pub = 16950' 'red = 16951' \
  '[plaintext_redirect]' 'pub = "red"'
n1_pb="$PKGROOT/n1-pb"
mkpkg "$n1_pb" n1-pb 'contract = 1' 'id = "n1-pb"' \
  '[config.defaults]' 'listen = 16950' \
  '[artifacts]' 'serve_ports = ["listen"]'
cfg_n1ab="$CFGROOT/n1-ab.toml"
{ base_config; printf '[apps.n1-pa]\n[apps.n1-pb]\n'; } >"$cfg_n1ab"
expect_fail "MAJOR N1: package-vs-package collision (redirect public vs serve port) is fatal" \
  "16950" run "$cfg_n1ab" validate

reset_box
n1_hub="$PKGROOT/n1-hub"
mkpkg "$n1_hub" n1-hub 'contract = 1' 'id = "n1-hub"' \
  '[config.defaults]' 'pub = 19901' 'red = 16961' \
  '[plaintext_redirect]' 'pub = "red"'
cfg_n1hub="$CFGROOT/n1-hub.toml"
{ base_config; printf '[apps.n1-hub]\n'; } >"$cfg_n1hub"
expect_fail "MAJOR N1: package-vs-built-in collision (redirect public vs hub's 19901) is fatal" \
  "built-in app's plaintext mapping already owns" run "$cfg_n1hub" validate

reset_box
n1_pc="$PKGROOT/n1-pc"
mkpkg "$n1_pc" n1-pc 'contract = 1' 'id = "n1-pc"' \
  '[config.defaults]' 'pub = 16970' 'red = 16971' \
  '[plaintext_redirect]' 'pub = "red"'
cat >"$n1_pc/install.sh" <<'EOF'
#!/bin/sh
pub="$(airlock_config get apps.n1-pc.pub)"
red="$(airlock_config get apps.n1-pc.red)"
test "$pub" -ne "$red"
EOF
chmod +x "$n1_pc/install.sh"
n1_pd="$PKGROOT/n1-pd"
mkpkg "$n1_pd" n1-pd 'contract = 1' 'id = "n1-pd"' \
  '[config.defaults]' 'listen = 16980' \
  '[artifacts]' 'serve_ports = ["listen"]'
cat >"$n1_pd/install.sh" <<'EOF'
#!/bin/sh
listen="$(airlock_config get apps.n1-pd.listen)"
test "$listen" -gt 0
EOF
chmod +x "$n1_pd/install.sh"
cfg_n1cd="$CFGROOT/n1-cd.toml"
{ base_config; printf '[apps.n1-pc]\n[apps.n1-pd]\n'; } >"$cfg_n1cd"
out_n1cd="$(run "$cfg_n1cd" validate 2>&1)"; rc_n1cd=$?
if [ "$rc_n1cd" = 0 ]; then
  ok "MAJOR N1: two distinct listens (control case) still validate"
else
  bad "MAJOR N1: control case wrongly refused (rc=$rc_n1cd)"
  failure_detail "$out_n1cd"
fi

# =============================================================================
# ROUND 4 MINOR N2: within ONE manifest, two plaintext_redirect pairs cannot
# share a public port (one row would silently vanish), and a key cannot
# redirect to itself (listen == target, a redirect loop).
# =============================================================================

reset_box
n2_a="$PKGROOT/n2-a"
mkpkg "$n2_a" n2-a 'contract = 1' 'id = "n2-a"' \
  '[config.defaults]' 'pub1 = 17001' 'red1 = 17002' 'pub2 = 17001' 'red2 = 17003' \
  '[plaintext_redirect]' 'pub1 = "red1"' 'pub2 = "red2"'
cfg_n2a="$CFGROOT/n2-a.toml"
{ base_config; printf '[apps.n2-a]\n'; } >"$cfg_n2a"
expect_fail "MINOR N2: two plaintext_redirect pairs sharing one public port is fatal" \
  "both resolve to port 17001" run "$cfg_n2a" validate

reset_box
n2_b="$PKGROOT/n2-b"
mkpkg "$n2_b" n2-b 'contract = 1' 'id = "n2-b"' \
  '[config.defaults]' 'pub = 17011' \
  '[plaintext_redirect]' 'pub = "pub"'
cfg_n2b="$CFGROOT/n2-b.toml"
{ base_config; printf '[apps.n2-b]\n'; } >"$cfg_n2b"
expect_fail "MINOR N2: a self-redirect (public == redirect key) is fatal" \
  "redirect to themselves" run "$cfg_n2b" validate

# =============================================================================
# ROUND 4 MINOR N3: invalid UTF-8 dies cleanly (not a raw traceback) at every
# tomllib.load call site, not just the one round 3 fixed.
# =============================================================================

reset_box
n3_pkg="$PKGROOT/n3-corrupt"; mkdir -p "$n3_pkg"
python3 -c "open('$n3_pkg/airlock-app.toml', 'wb').write(b'contract = 1\nid = \"n3-corrupt\"\n\xff\xfe bad utf8\n')"
scripts_ok "$n3_pkg"
cfg_n3pkg="$CFGROOT/n3-pkg.toml"
{ base_config; printf '[apps.n3-corrupt]\n'; } >"$cfg_n3pkg"
out_n3pkg="$(run "$cfg_n3pkg" validate 2>&1)"; rc_n3pkg=$?
if [ "$rc_n3pkg" -ne 0 ] && grep -q "invalid TOML" <<<"$out_n3pkg" && ! grep -q "Traceback" <<<"$out_n3pkg"; then
  ok "MINOR N3: a corrupt-bytes CONFIGURED manifest dies cleanly at validate"
else
  bad "MINOR N3: package manifest load crashed instead of a clean die (rc=$rc_n3pkg)"
  failure_detail "$out_n3pkg"
fi

reset_box
cfg_n3toml="$CFGROOT/n3-toml.toml"
python3 -c "open('$cfg_n3toml', 'wb').write(b'[auth]\nprovider = \"tailscale\"\nowner = \"x@y.z\"\n[apps.hub]\n\xff\xfe bad utf8\n')"
out_n3toml="$(run "$cfg_n3toml" validate 2>&1)"; rc_n3toml=$?
if [ "$rc_n3toml" -ne 0 ] && grep -q "invalid TOML" <<<"$out_n3toml" && ! grep -q "Traceback" <<<"$out_n3toml"; then
  ok "MINOR N3: a corrupt-bytes airlock.toml dies cleanly (not a traceback)"
else
  bad "MINOR N3: airlock.toml load crashed instead of a clean die (rc=$rc_n3toml)"
  failure_detail "$out_n3toml"
fi

# =============================================================================
# ROUND 4 MINOR N4: the two parallel rooted-anchor implementations must agree
# — same expansion (tilde), same realpath discipline.
# =============================================================================

reset_box
n4_tilde="$PKGROOT/n4-tilde"
mkdir -p "$FAKEHOME/n4-bundle"; : >"$FAKEHOME/n4-bundle/marker"
mkpkg "$n4_tilde" n4-tilde 'contract = 1' 'id = "n4-tilde"' \
  '[artifacts]' 'rooted = ["${webroot_parent}/n4-bundle/marker"]'
cfg_n4t="$CFGROOT/n4-tilde.toml"
{ base_config; printf '[apps.n4-tilde]\n'; } >"$cfg_n4t"
out_n4t="$(AIRLOCK_WEBROOT="~/hub" run "$cfg_n4t" validate 2>&1)"; rc_n4t=$?
if [ "$rc_n4t" = 0 ]; then
  ok "MINOR N4: AIRLOCK_WEBROOT=~/hub expands (not a literal '~') at manifest-validate"
else
  bad "MINOR N4: config-side tilde expansion regression (rc=$rc_n4t)"
  failure_detail "$out_n4t"
fi

# The SAME env var, resolved by the LEDGER's own intent+commit — must find
# and record the real (expanded) marker, proving both files resolve the
# IDENTICAL anchor, not two different ones (which is exactly what the
# missing expanduser() on the config side used to cause).
info_n4t="$(AIRLOCK_WEBROOT="~/hub" run "$cfg_n4t" package-info 2>/dev/null)"
AIRLOCK_WEBROOT="~/hub" ledger_run "$info_n4t" intent n4-tilde >/dev/null 2>&1; rc_i_n4t=$?
commit_n4t="$(AIRLOCK_WEBROOT="~/hub" ledger_run "$info_n4t" commit n4-tilde 2>&1)"; rc_commit_n4t=$?
rooted_n4t="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d["entries"]["n4-tilde"]["committed"]["artifacts"]["rooted"]))' "$STATE/app-ledger.json" 2>/dev/null)"
if [ "$rc_i_n4t" = 0 ] && [ "$rc_commit_n4t" = 0 ] && grep -q "n4-bundle/marker" <<<"$rooted_n4t"; then
  ok "MINOR N4: the ledger resolves the SAME tilde-expanded anchor as the manifest validator"
else
  bad "MINOR N4: ledger-side tilde expansion mismatch (intent=$rc_i_n4t commit=$rc_commit_n4t rooted=$rooted_n4t)"
fi
# (The other N4 divergence — /opt/airlock or /etc/airlock itself being a
# symlink — is fixed identically in both files (realpath at comparison
# time, not a literal-string compare), but is not independently fixture-
# tested here: both anchors are hardcoded, not env-overridable, so
# reproducing the divergence would require an actual symlink at a real
# system path outside this sandbox's control.)

# =============================================================================
# MINOR F: the shipped-resolver containment guard (a symlinked apps/<id> is
# excluded, not shipped) — correct since round 2 but previously unfixtured,
# so a regression there would have been invisible.
# =============================================================================

reset_box
outside_app="$TMP/outside-shipped-app"
mkpkg "$outside_app" sym-app 'contract = 1' 'id = "sym-app"'
ln -s "$outside_app" "$PKGROOT/sym-app"
cfg_sym="$CFGROOT/sym-app.toml"
{ base_config; printf '[apps.sym-app]\n'; } >"$cfg_sym"
info_sym="$(run "$cfg_sym" package-info 2>/dev/null)"
if python3 -c 'import json,sys; d=json.load(sys.stdin); assert "sym-app" not in d["packages"]' <<<"$info_sym" 2>/dev/null; then
  ok "MINOR F: a symlinked apps/<id> directory is excluded from shipped resolution"
else
  bad "MINOR F: symlinked shipped app dir was wrongly resolved"
  failure_detail "$info_sym"
fi
rm -f "$PKGROOT/sym-app"

# =============================================================================
# MINOR F: the three D-order fixtures the plan promised but the suite never
# had — cross-generation ranks conflicting with deps (deps win), mixed
# ranked+legacy (falls back to name-order), legacy-only (today's plain
# name-order, unaffected by the rank feature existing at all).
# =============================================================================

# cg-a depends on cg-b (installed b, then a: natural ranks b=1, a=2). The
# ranks are then INVERTED by hand, contradicting the natural install order
# — the removal order must still respect the dependency edge (dependent
# before dependency) regardless of what the (now-corrupted) ranks say.
reset_box
cg_b="$PKGROOT/cg-b"; mkpkg "$cg_b" cg-b 'contract = 1' 'id = "cg-b"'
cg_a="$PKGROOT/cg-a"; mkpkg "$cg_a" cg-a 'contract = 1' 'id = "cg-a"' \
  '[dependencies]' 'apps = ["cg-b"]'
cfg_cg="$CFGROOT/cg.toml"
{ base_config; printf '[apps.cg-b]\n[apps.cg-a]\n[packages.cg-b]\npath = "%s"\n[packages.cg-a]\npath = "%s"\n' "$cg_b" "$cg_a"; } >"$cfg_cg"
info_cg="$(run "$cfg_cg" package-info 2>/dev/null)"
commit_packages "$info_cg" cg-b cg-a; rc_cg=$?
python3 - "$STATE/app-ledger.json" <<PY
import json
p = "$STATE/app-ledger.json"
d = json.load(open(p))
d["entries"]["cg-b"]["committed"]["order"], d["entries"]["cg-a"]["committed"]["order"] = \
    d["entries"]["cg-a"]["committed"]["order"], d["entries"]["cg-b"]["committed"]["order"]
json.dump(d, open(p, "w"))
PY
drop_cg="$CFGROOT/cg-drop.toml"; base_config >"$drop_cg"
drop_info_cg="$(run "$drop_cg" package-info 2>/dev/null)"
plan_cg="$(ledger_run "$drop_info_cg" plan 2>&1)"; rc_plan_cg=$?
remove_cg="$(awk -F '\t' '$1 == "remove" {print $2}' <<<"$plan_cg")"
if [ "$rc_cg" = 0 ] && [ "$rc_plan_cg" = 0 ] && [ "$remove_cg" = $'cg-a\ncg-b' ]; then
  ok "order: cross-generation ranks conflicting with deps — deps win"
else
  bad "order: deps-vs-rank conflict (rc=$rc_plan_cg, got: $remove_cg)"
  failure_detail "$plan_cg"
fi

# One v3 (ranked) record alongside one v1 (legacy, order=None) record, no
# deps between them — the rank refinement applies only when EVERY selected
# record carries a rank, so this must fall back to plain name-order for
# BOTH, not just the legacy one. Names are chosen so name-order and a
# (buggy) "default a missing rank to 0" order would DISAGREE, so the
# assertion actually distinguishes correct from wrong.
reset_box
mkdir -p "$STATE"
python3 - "$STATE/app-ledger.json" <<PY
import json
d = {"version": 1, "entries": {"mix-z-legacy": {"committed": {
    "path": "/nonexistent/mix-z-legacy-pkg", "digest": "a" * 64,
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "artifacts": {"units": [], "fragments": [], "webroot": [], "files": [], "serve_ports": []},
}}}}
json.dump(d, open("$STATE/app-ledger.json", "w"))
PY
mix_r="$PKGROOT/mix-a-ranked"; mkpkg "$mix_r" mix-a-ranked 'contract = 1' 'id = "mix-a-ranked"'
cfg_mixr="$CFGROOT/mix-a-ranked.toml"
{ base_config; printf '[apps.mix-a-ranked]\n[packages.mix-a-ranked]\npath = "%s"\n' "$mix_r"; } >"$cfg_mixr"
info_mixr="$(run "$cfg_mixr" package-info 2>/dev/null)"
commit_packages "$info_mixr" mix-a-ranked; rc_mixr=$?
drop_mix="$CFGROOT/mix-drop.toml"; base_config >"$drop_mix"
drop_info_mix="$(run "$drop_mix" package-info 2>/dev/null)"
plan_mix="$(ledger_run "$drop_info_mix" plan 2>&1)"; rc_plan_mix=$?
remove_mix="$(awk -F '\t' '$1 == "remove" {print $2}' <<<"$plan_mix")"
if [ "$rc_mixr" = 0 ] && [ "$rc_plan_mix" = 0 ] && [ "$remove_mix" = $'mix-z-legacy\nmix-a-ranked' ]; then
  ok "order: a mixed ranked+legacy selection falls back to name-order"
else
  bad "order: mixed ranked+legacy (rc=$rc_plan_mix, got: $remove_mix)"
  failure_detail "$plan_mix"
fi

# All-legacy selection: today's plain reverse name-order, unaffected by the
# rank feature existing at all (no v3 record in the mix to engage it).
reset_box
mkdir -p "$STATE"
python3 - "$STATE/app-ledger.json" <<PY
import json
mk = lambda i: {"committed": {
    "path": f"/nonexistent/leg-{i}-pkg", "digest": "a" * 64,
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "artifacts": {"units": [], "fragments": [], "webroot": [], "files": [], "serve_ports": []},
}}
d = {"version": 1, "entries": {"leg-a": mk("a"), "leg-b": mk("b"), "leg-c": mk("c")}}
json.dump(d, open("$STATE/app-ledger.json", "w"))
PY
plan_leg="$(ledger_run '{"packages":{}}' plan 2>&1)"; rc_plan_leg=$?
remove_leg="$(awk -F '\t' '$1 == "remove" {print $2}' <<<"$plan_leg")"
if [ "$rc_plan_leg" = 0 ] && [ "$remove_leg" = $'leg-c\nleg-b\nleg-a' ]; then
  ok "order: an all-legacy selection removes in reverse name-order"
else
  bad "order: legacy-only removal order (rc=$rc_plan_leg, got: $remove_leg)"
  failure_detail "$plan_leg"
fi

# =============================================================================
# ADDENDUM (independent mutation-testing pass, 5 survivors folded into round
# 5): BLIND SPOT 1(b), BLIND SPOT 2(a)/(b), DEFECT 3.
# =============================================================================

# BLIND SPOT 1(b): the shipped-resolver canonical-containment guard has a
# SEPARATE, independently-implemented copy inside
# _shipped_plaintext_redirect_defaults() (bin/airlock-config) — used by the
# plaintext-known stale-sweep, which scans $AIRLOCK_SHIPPED_APPS_ROOT
# directly off disk, bypassing config entirely. MINOR F only fixtured the
# package_specs()/package-info copy; this copy had zero coverage, so a
# regression letting a symlinked shipped app's default port back into the
# sweep would have been invisible.
reset_box
pr_outside="$TMP/pr-outside-shipped"
mkpkg "$pr_outside" pr-sym 'contract = 1' 'id = "pr-sym"' \
  '[config.defaults]' 'public_port = 18801' 'redirect_port = 18802' \
  '[plaintext_redirect]' 'public_port = "redirect_port"'
ln -s "$pr_outside" "$PKGROOT/pr-sym"
cfg_prsym="$CFGROOT/pr-sym.toml"; base_config >"$cfg_prsym"
known_prsym="$(run "$cfg_prsym" plaintext-known 2>&1)"
if ! grep -qx '18801' <<<"$known_prsym"; then
  ok "ADDENDUM 1(b): a symlinked shipped app is excluded from the plaintext-known disk sweep"
else
  bad "ADDENDUM 1(b): symlinked shipped app's plaintext_redirect default was wrongly swept"
  failure_detail "$known_prsym"
fi
rm -f "$PKGROOT/pr-sym"

# BLIND SPOT 2(a): the v1(no serve_mappings)->v3 legacy INTENT normalisation
# (bin/airlock-ledger:_validate_store) synthesises serve_mappings from
# serve_port_values, but no prior fixture ever gave it a NON-EMPTY port to
# synthesise — a positive assertion of the exact `tailscale serve --http=
# <port> off` call, not just rc=0, is the only thing that actually exercises
# the synthesis line rather than its (already-covered) empty-dict shape.
reset_box
python3 - "$STATE/app-ledger.json" <<PY
import json
d = {"version": 1, "entries": {"bs2a": {"intent": {
    "path": "/nonexistent/bs2a-pkg", "digest": "1" * 64,
    "artifacts_declared": {"units": [], "fragments": [], "webroot": [], "files": [],
                           "serve_ports": ["public_port"]},
    "serve_port_values": {"public_port": 16601},
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "roots": {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
              "webroot": "$WEB", "home": "$FAKEHOME"},
}}}}
json.dump(d, open("$STATE/app-ledger.json", "w"))
PY
td_bs2a="$(ledger_run '{"packages":{}}' teardown bs2a 2>&1)"; rc_bs2a=$?
if [ "$rc_bs2a" = 0 ] && grep -q -- '--http=16601 off' "$TMP/tailscale.log"; then
  ok "ADDENDUM 2(a): a v1 intent's synthesised serve_mappings actually offs its port"
else
  bad "ADDENDUM 2(a): v1 intent serve_mappings synthesis (rc=$rc_bs2a)"
  failure_detail "$td_bs2a"
  cat "$TMP/tailscale.log" | sed 's/^/    ts: /'
fi

# BLIND SPOT 2(b): the same normalisation for a legacy COMMITTED record
# (keyed by port value, not config key) — same gap, same positive assertion.
reset_box
python3 - "$STATE/app-ledger.json" <<PY
import json
d = {"version": 1, "entries": {"bs2b": {"committed": {
    "path": "/nonexistent/bs2b-pkg", "digest": "2" * 64,
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "artifacts": {"units": [], "fragments": [], "webroot": [], "files": [],
                  "serve_ports": [16701]},
}}}}
json.dump(d, open("$STATE/app-ledger.json", "w"))
PY
td_bs2b="$(ledger_run '{"packages":{}}' teardown bs2b 2>&1)"; rc_bs2b=$?
if [ "$rc_bs2b" = 0 ] && grep -q -- '--http=16701 off' "$TMP/tailscale.log"; then
  ok "ADDENDUM 2(b): a v1 committed record's synthesised serve_mappings actually offs its port"
else
  bad "ADDENDUM 2(b): v1 committed serve_mappings synthesis (rc=$rc_bs2b)"
  failure_detail "$td_bs2b"
  cat "$TMP/tailscale.log" | sed 's/^/    ts: /'
fi

# DEFECT 3: _rooted_contains's prefix match is `parent == root or
# parent.startswith(root + os.sep)` — the `+ os.sep` is what refuses a
# SIBLING directory whose name merely starts with an anchor's name (e.g.
# "/opt/airlock-backup" is not "/opt/airlock" or anything under it, but a
# bare `.startswith(root)` would wrongly say yes). Static anchor first,
# manifest-validate layer — no env tricks needed, "/opt/airlock" is
# hardcoded.
reset_box
dfct_static="$PKGROOT/dfct-static"
mkpkg "$dfct_static" dfct-static 'contract = 1' 'id = "dfct-static"' \
  '[artifacts]' 'rooted = ["/opt/airlock-backup/marker"]'
cfg_dfcts="$CFGROOT/dfct-static.toml"
{ base_config; printf '[apps.dfct-static]\n'; } >"$cfg_dfcts"
expect_fail "ADDENDUM 3: a sibling dir sharing the /opt/airlock NAME PREFIX (no separator) is refused" \
  "outside the rooted allowlist" run "$cfg_dfcts" validate

# Same near-miss, ledger plan layer (hand-crafted intent, matching the
# BLOCKER-2/MINOR-D fixture style above).
reset_box
python3 - "$STATE/app-ledger.json" <<PY
import json
p = "$STATE/app-ledger.json"
d = {"version": 3, "entries": {"dfct-static2": {"intent": {
    "path": "/nonexistent/dfct-static2-pkg", "digest": "3" * 64,
    "artifacts_declared": {"units": [], "fragments": [], "webroot": [], "files": [],
                           "rooted": ["/opt/airlock-backup/marker"], "serve_ports": []},
    "serve_port_values": {},
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "deps": [], "anchors": {},
    "roots": {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
              "webroot": "$WEB", "home": "$FAKEHOME"},
    "serve_mappings": {}, "unit_scopes": {}, "order": None,
    "source_class": "shipped",
}}}}
json.dump(d, open(p, "w"))
PY
out_dfcts2="$(ledger_run '{"packages":{}}' plan 2>&1)"; rc_dfcts2=$?
if [ "$rc_dfcts2" -ne 0 ] && grep -q "rooted allowlist" <<<"$out_dfcts2"; then
  ok "ADDENDUM 3: ledger plan also refuses the /opt/airlock-backup sibling near-miss"
else
  bad "ADDENDUM 3: /opt/airlock-backup near-miss not refused at plan layer (rc=$rc_dfcts2)"
  failure_detail "$out_dfcts2"
fi

# Same near-miss against the DYNAMIC anchor: AIRLOCK_WEBROOT=/opt/hub/live
# gives webroot_parent=/opt/hub (2 components, passes MINOR D's floor); a
# rooted pattern of "${webroot_parent}-backup/marker" substitutes to
# "/opt/hub-backup/marker" — a sibling of /opt/hub, not a descendant.
reset_box
python3 - "$STATE/app-ledger.json" <<PY
import json
p = "$STATE/app-ledger.json"
d = {"version": 3, "entries": {"dfct-dyn": {"intent": {
    "path": "/nonexistent/dfct-dyn-pkg", "digest": "4" * 64,
    "artifacts_declared": {"units": [], "fragments": [], "webroot": [], "files": [],
                           "rooted": ["\${webroot_parent}-backup/marker"], "serve_ports": []},
    "serve_port_values": {},
    "lifecycle": {"install": True, "smoke": True, "deactivate": True},
    "deps": [], "anchors": {},
    "roots": {"unit_user": "$UU", "unit_system": "$US", "confd": "$CONFD",
              "webroot": "/opt/hub/live", "home": "$FAKEHOME"},
    "serve_mappings": {}, "unit_scopes": {}, "order": None,
    "source_class": "shipped",
}}}}
json.dump(d, open(p, "w"))
PY
out_dfctdyn="$(AIRLOCK_WEBROOT=/opt/hub/live ledger_run '{"packages":{}}' plan 2>&1)"; rc_dfctdyn=$?
if [ "$rc_dfctdyn" -ne 0 ] && grep -q "rooted allowlist" <<<"$out_dfctdyn"; then
  ok "ADDENDUM 3: the \${webroot_parent}-backup sibling near-miss is refused (dynamic anchor)"
else
  bad "ADDENDUM 3: \${webroot_parent}-backup near-miss not refused (rc=$rc_dfctdyn)"
  failure_detail "$out_dfctdyn"
fi


# =============================================================================
# P2/P3 mixed-state matrix (docs/tasks/active/app-pkg-c4-builtin-migration.md,
# "Approach" P2: "after each app's commit, a nine-app dry run asserts
# migrated apps executed via the package path, unmigrated apps via the
# legacy branch, an explicit-shadow fixture package still skipped"). Child
# 4/P3 retires the legacy branch and AIRLOCK_MIGRATED_APPS — all nine are
# shipped AND migrated now, so this matrix asserts the single remaining
# path (every real built-in takes the shipped-package dry run) plus the
# explicit-shadow case, which stays load-bearing (D4 unchanged). Unlike
# every fixture above, this section deliberately points
# AIRLOCK_SHIPPED_APPS_ROOT at the REAL $ROOT/apps tree (per-invocation
# override of the file-wide scratch export) — the whole point is to prove
# the REAL migrated built-ins take the package path under a real dry run of
# install/airlock-install.sh, which no fixture package can stand in for.
# =============================================================================
reset_box
MM="$TMP/mixed-matrix"; mkdir -p "$MM/home" "$MM/web" "$MM/confd" "$MM/code" "$MM/state" "$MM/shim"
MMCFG="$MM/airlock.toml"
cat >"$MMCFG" <<EOF
[site]
name = "MixedMatrix"

[auth]
provider = "tailscale"
owner = "owner@fixture.dev"

[paths]

[apps.hub]
[apps.code-server]
[apps.dev-monitor]
[apps.devterm]
[apps.feedback]
[apps.fileview]
[apps.notepad]
[apps.orca]
[apps.paseo]
[apps.publish]
EOF
# Shim every prerequisite command this box lacks — TSV rows AND migrated
# apps' manifest rows (F11 assembly), so an app that moved its prerequisite
# out of the TSV is still covered. AIRLOCK_SHIPPED_APPS_ROOT must point at
# the REAL $ROOT/apps here too (same override run_mixed_matrix uses below,
# not the file-wide $PKGROOT scratch export from the top of this file) — a
# prereqs assembly against the scratch root finds none of the real shipped
# manifests, so it "succeeds" (rc=0) with an inventory silently missing
# every migrated app's manifest-only commands (nft, npm, ...), and the
# fallback below never triggers to catch that.
MMPREREQS="$MM/prereqs.tsv"
AIRLOCK_CONFIG="$MMCFG" AIRLOCK_SHIPPED_APPS_ROOT="$ROOT/apps" \
  python3 "$CFG" prereqs >"$MMPREREQS" 2>/dev/null \
  || cp "$ROOT/install/prerequisites.tsv" "$MMPREREQS"
while IFS=$'\t' read -r _owner cmd _rest; do
  case "$cmd" in ""|\#*) continue ;; esac
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf '#!/bin/sh\nexit 0\n' >"$MM/shim/$cmd"; chmod +x "$MM/shim/$cmd"
  fi
done <"$MMPREREQS"

run_mixed_matrix() {
  local cfg="$1" home="$2" web="$3" confd="$4" state="$5"
  AIRLOCK_SHIPPED_APPS_ROOT="$ROOT/apps" \
  HOME="$home" AIRLOCK_CONFIG="$cfg" AIRLOCK_STATE_DIR="$state" \
  AIRLOCK_WEBROOT="$web" AIRLOCK_CONFD="$confd" AIRLOCK_TS_FQDN="box.example.ts.net" \
  AIRLOCK_DRY_RUN=1 AIRLOCK_UNIT_DIR_USER="$UU" AIRLOCK_UNIT_DIR_SYSTEM="$US" \
  PATH="$MM/shim:$PATH" \
    bash "$ROOT/install/airlock-install.sh" 2>&1
}

out_mm="$(run_mixed_matrix "$MMCFG" "$MM/home" "$MM/web" "$MM/confd" "$MM/state")"; rc_mm=$?
if [ "$rc_mm" -eq 0 ]; then
  ok "mixed-matrix: nine-app real dry run completes"
else
  bad "mixed-matrix: nine-app real dry run exited $rc_mm"
  failure_detail "$out_mm"
fi

# Child 4/P3: AIRLOCK_MIGRATED_APPS and the legacy (no-manifest) branch are
# both retired — all nine built-ins are shipped AND migrated, unconditionally
# (source_class == shipped alone gates dry-run execution now), so every one
# of them takes the SAME single path: the migrated-shipped package dry run.
# There is no more "shipped but not yet migrated" or "no manifest" case to
# distinguish among real built-in ids.
for id in code-server dev-monitor devterm feedback fileview notepad orca paseo publish; do
  [ -f "$ROOT/apps/$id/airlock-app.toml" ] \
    || bad "mixed-matrix: $id has no shipped manifest — the nine-built-in premise broke"
  if grep -qF "[dry] installing packaged app: $id (" <<<"$out_mm"; then
    ok "mixed-matrix: $id (shipped) dry-runs via the package path"
  else
    bad "mixed-matrix: $id (shipped) did not take the shipped-package dry-run path"
    failure_detail "$out_mm"
  fi
done

# Explicit-shadow: an operator's own [packages.notepad] must NEVER dry-run
# execute, even though notepad is shipped AND migrated (D4: explicit
# packages are never dry-run-executed, migrated id or not).
SHADOW_DIR="$MM/shadow-notepad"
mkpkg "$SHADOW_DIR" notepad 'contract = 1' 'id = "notepad"' \
  '[artifacts]' 'webroot = ["notepad-shadow/"]'
MMCFG_SHADOW="$MM/airlock-shadow.toml"
{ cat "$MMCFG"; printf '[packages.notepad]\npath = "%s"\n' "$SHADOW_DIR"; } >"$MMCFG_SHADOW"
mkdir -p "$MM/home-shadow" "$MM/web-shadow" "$MM/confd-shadow" "$MM/state-shadow"
out_shadow="$(run_mixed_matrix "$MMCFG_SHADOW" "$MM/home-shadow" "$MM/web-shadow" \
  "$MM/confd-shadow" "$MM/state-shadow")"; rc_shadow=$?
if [ "$rc_shadow" -eq 0 ] \
  && grep -qF "[dry] would install packaged app: notepad from $SHADOW_DIR (script not run)" <<<"$out_shadow"; then
  ok "mixed-matrix: an explicit [packages.notepad] shadow is still skipped under dry run"
else
  bad "mixed-matrix: explicit shadow of a migrated app was not skipped (rc=$rc_shadow)"
  failure_detail "$out_shadow"
fi
if grep -qF "[dry] installing packaged app: notepad (" <<<"$out_shadow"; then
  bad "mixed-matrix: explicit shadow's install.sh was executed under dry run (D4 violation)"
else
  ok "mixed-matrix: explicit shadow's install.sh was never executed under dry run"
fi

# =============================================================================
# P4 — gates: known-builtins / --adopt, ledger gate widening, artifact
# inventory audit, F13a/b/c + retirement confirmation, red transcript.
# (docs/tasks/active/app-pkg-c4-builtin-migration.md "Approach" P4; the F15
# amendment in P0 is the detection/--adopt spec of record.)
#
# Its own shipped root (P4APPS/P4EMPTY) — never $PKGROOT, which by this point
# in the file carries fixture packages from every section above: a
# known-builtins/adopt-scan listing must see EXACTLY "shipped root, minus
# hub/core/shadowed", nothing accumulated from an unrelated fixture.
# =============================================================================
P4APPS="$TMP/p4-apps"; P4EMPTY="$TMP/p4-empty"
mkdir -p "$P4APPS" "$P4EMPTY"

p4_reset() { reset_box; rm -rf "$P4APPS"; mkdir -p "$P4APPS"; }
p4_run() { local cfg="$1"; shift; AIRLOCK_SHIPPED_APPS_ROOT="$P4APPS" AIRLOCK_CONFIG="$cfg" python3 "$CFG" "$@"; }
p4_teardown() { local cfg="$1"; shift; AIRLOCK_SHIPPED_APPS_ROOT="$P4APPS" AIRLOCK_CONFIG="$cfg" bash "$ROOT/bin/airlock-teardown" "$@"; }
p4_ledger_run() { local cfg="$1"; shift; local info; info="$(p4_run "$cfg" package-info)"; printf '%s' "$info" | "$LEDGER" "$@"; }
p4_cfg_hubonly() { base_config > "$1"; }

# alpha: a well-formed shipped app with one file artifact + one serve port —
# the base fixture most of A/B reuse.
p4_mkalpha() {
  mkpkg "$P4APPS/alpha" alpha 'contract = 1' 'id = "alpha"' \
    '[config.defaults]' 'port = 19601' \
    '[artifacts]' 'files = ["~/.local/bin/alpha-bin"]' 'serve_ports = ["port"]'
}

# =============================================================================
# A) `airlock-config known-builtins` — listing contract: shipped ids with
# parseable regular non-symlink manifests, hub/core excluded, shadowed
# excluded (F15 amendment).
# =============================================================================

p4_reset; p4_mkalpha
P4CFG="$TMP/p4-cfg.toml"; p4_cfg_hubonly "$P4CFG"

out="$(p4_run "$P4CFG" known-builtins 2>&1)"
[ "$out" = alpha ] && ok "A: known-builtins lists a well-formed shipped id" \
  || { bad "A: base listing -> $out"; }

# hub/core: excluded even when a stray dir with that name sits under the
# shipped root (RESERVED_PACKAGE_IDS, not just [apps.*] reservation).
mkpkg "$P4APPS/hub" hub 'contract = 1' 'id = "hub"' '[artifacts]' 'files = ["~/.local/bin/hub-decoy"]'
mkpkg "$P4APPS/core" core 'contract = 1' 'id = "core"' '[artifacts]' 'files = ["~/.local/bin/core-decoy"]'
out="$(p4_run "$P4CFG" known-builtins 2>&1)"
[ "$out" = alpha ] && ok "A: hub/core directories under the shipped root are excluded" \
  || { bad "A: hub/core exclusion -> $out"; }
rm -rf "$P4APPS/hub" "$P4APPS/core"

# symlinked manifest -> excluded ("regular non-symlink" per the contract).
mkdir -p "$P4APPS/betasym"
ln -s "$P4APPS/alpha/airlock-app.toml" "$P4APPS/betasym/airlock-app.toml"
out="$(p4_run "$P4CFG" known-builtins 2>&1)"
[ "$out" = alpha ] && ok "A: a symlinked manifest is excluded" \
  || { bad "A: symlinked-manifest exclusion -> $out"; }
rm -rf "$P4APPS/betasym"

# symlinked app DIRECTORY -> excluded (mirrors package_specs's own shipped-
# detection: canonical containment, not a link into the shipped root).
mkdir -p "$TMP/p4-outside/gammareal"
pkg_manifest "$TMP/p4-outside/gammareal" 'contract = 1' 'id = "gamma"'
scripts_ok "$TMP/p4-outside/gammareal"
ln -s "$TMP/p4-outside/gammareal" "$P4APPS/gamma"
out="$(p4_run "$P4CFG" known-builtins 2>&1)"
[ "$out" = alpha ] && ok "A: a symlinked app directory is excluded" \
  || { bad "A: symlinked-app-dir exclusion -> $out"; }
rm -f "$P4APPS/gamma"

# unparseable manifest -> excluded, best-effort (must not crash the scan —
# this command must stay usable to diagnose a box where some OTHER shipped
# app's manifest happens to be broken).
mkdir -p "$P4APPS/delta"
printf 'contract = 1\nid = "delta"\n[artifacts\n' > "$P4APPS/delta/airlock-app.toml"
scripts_ok "$P4APPS/delta"
out="$(p4_run "$P4CFG" known-builtins 2>/dev/null)"; rc=$?
err="$(p4_run "$P4CFG" known-builtins 2>&1 >/dev/null)"
if [ "$rc" = 0 ] && [ "$out" = alpha ] && grep -qF "delta" <<<"$err"; then
  ok "A: a manifest that fails to parse is excluded, not fatal (a diagnostic still names it on stderr)"
else
  bad "A: parse-error exclusion (rc=$rc, stdout=$out)"; failure_detail "$err"
fi
rm -rf "$P4APPS/delta"

# invalid package-id-shaped directory name -> excluded (PACKAGE_ID_RE).
mkdir -p "$P4APPS/UpperCase"
pkg_manifest "$P4APPS/UpperCase" 'contract = 1' 'id = "UpperCase"'
scripts_ok "$P4APPS/UpperCase"
out="$(p4_run "$P4CFG" known-builtins 2>&1)"
[ "$out" = alpha ] && ok "A: a non-lowercase directory name is excluded" \
  || { bad "A: invalid-id-shape exclusion -> $out"; }
rm -rf "$P4APPS/UpperCase"

# unknown id: adopt-write names exactly what is wrong.
out="$(p4_run "$P4CFG" adopt-write nosuchid 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "not a known built-in" <<<"$out" \
  && ok "A: adopt-write on an unknown id refuses by name" \
  || { bad "A: unknown-id refusal (rc=$rc)"; failure_detail "$out"; }
out="$(p4_run "$P4CFG" adopt-write hub 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "reserved platform core" <<<"$out" \
  && ok "A: adopt-write on 'hub' refuses (RESERVED_PACKAGE_IDS)" \
  || { bad "A: hub refusal (rc=$rc)"; failure_detail "$out"; }

# shadowed: an explicit [packages.alpha] override excludes it from the
# known-builtins listing (F15 amendment: "shadowed excluded").
mkdir -p "$TMP/p4-explicit-alpha"
pkg_manifest "$TMP/p4-explicit-alpha" 'contract = 1' 'id = "alpha"' \
  '[artifacts]' 'files = ["~/.local/bin/explicit-alpha-bin"]'
scripts_ok "$TMP/p4-explicit-alpha"
P4CFG_SHADOW="$TMP/p4-cfg-shadow.toml"
{ base_config; printf '[apps.alpha]\n[packages.alpha]\npath = "%s"\n' "$TMP/p4-explicit-alpha"; } > "$P4CFG_SHADOW"
out="$(p4_run "$P4CFG_SHADOW" known-builtins 2>&1)"
[ -z "$out" ] && ok "A: an explicitly-shadowed id is excluded from known-builtins" \
  || { bad "A: shadowed exclusion -> $out"; }

# =============================================================================
# B) `bin/airlock-teardown --adopt <id>` — the exclusion predicate IS the
# admission predicate (one function, two call sites): detection's ADOPT/
# EXCLUDE verdict and --adopt's own re-check under the lock always agree.
# =============================================================================

# B1) detection -> admitted --adopt -> ordinary teardown reclaims it. The
# synthetic intent is unranked (D-order) and shipped-class.
p4_reset; p4_mkalpha
mkdir -p "$FAKEHOME/.local/bin"; : > "$FAKEHOME/.local/bin/alpha-bin"
p4_cfg_hubonly "$P4CFG"
out="$(p4_run "$P4CFG" adopt-scan 2>&1)"
case "$out" in
  ADOPT$'\t'alpha$'\t'*alpha-bin*) ok "B1: adopt-scan reports alpha as an ADOPT candidate with its path" ;;
  *) bad "B1: adopt-scan candidate line -> $out" ;;
esac
adopt_out="$(p4_run "$P4CFG" adopt-write alpha 2>&1)"; adopt_rc=$?
[ "$adopt_rc" = 0 ] && ok "B1: the printed --adopt line the scan named is admitted (never refused for a reason detection could see)" \
  || { bad "B1: adopt-write alpha (rc=$adopt_rc)"; failure_detail "$adopt_out"; }
order_val="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["entries"]["alpha"]["intent"]["order"])' "$STATE/app-ledger.json" 2>&1)"
[ "$order_val" = None ] && ok "B1: the synthetic intent is written UNRANKED (order=null, D-order)" \
  || bad "B1: synthetic intent order -> $order_val"
src_class="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["entries"]["alpha"]["intent"]["source_class"])' "$STATE/app-ledger.json" 2>&1)"
[ "$src_class" = shipped ] && ok "B1: the synthetic intent carries source_class=shipped" \
  || bad "B1: synthetic intent source_class -> $src_class"
# The adopt path builds its package dict by hand — it never goes through
# _normalise_package — so it is the producer most likely to ship a record
# with no capability list at all (a KeyError at _intent_record, or worse a
# record the next load refuses). It copies the manifest spec's list.
adopt_caps="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d["entries"]["alpha"]["intent"]["capabilities"]))' "$STATE/app-ledger.json" 2>&1)"
[ "$adopt_caps" = '[]' ] && ok "B1: the synthetic intent carries the manifest spec's capability list" \
  || bad "B1: synthetic intent capabilities -> $adopt_caps"
td_out="$(p4_teardown "$P4CFG" alpha 2>&1)"; td_rc=$?
[ "$td_rc" = 0 ] && [ ! -e "$FAKEHOME/.local/bin/alpha-bin" ] \
  && ok "B1: the ordinary teardown machinery reclaims the adopted artifact" \
  || { bad "B1: ordinary teardown after adopt (rc=$td_rc)"; failure_detail "$td_out"; }
entries_after="$(python3 -c 'import json; print(json.load(open("'"$STATE"'/app-ledger.json"))["entries"])' 2>/dev/null)"
[ "$entries_after" = "{}" ] && ok "B1: the ledger entry is dropped after teardown" \
  || bad "B1: ledger entries after teardown -> $entries_after"

# The hand-built adopt producer must preserve a system-unit claim too, not
# merely the empty-list alpha case above. The ordinary teardown then proves
# that the synthetic intent's claim authorizes exactly the system unit found.
p4_reset
mkpkg "$P4APPS/alpha-system" alpha-system 'contract = 1' 'id = "alpha-system"' \
  '[artifacts]' 'units = [{name = "alpha-system.service", scope = "system"}]'
: >"$US/alpha-system.service"
p4_cfg_hubonly "$P4CFG"
system_scan="$(p4_run "$P4CFG" adopt-scan 2>&1)"
system_adopt="$(p4_run "$P4CFG" adopt-write alpha-system 2>&1)"; system_adopt_rc=$?
system_caps="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d["entries"]["alpha-system"]["intent"]["capabilities"]))' "$STATE/app-ledger.json" 2>/dev/null)"
system_td="$(p4_teardown "$P4CFG" alpha-system 2>&1)"; system_td_rc=$?
if grep -q $'^ADOPT\talpha-system\t' <<<"$system_scan" \
   && [ "$system_adopt_rc" = 0 ] && [ "$system_caps" = '["system-unit"]' ] \
   && [ "$system_td_rc" = 0 ] && [ ! -e "$US/alpha-system.service" ] \
   && grep -q -- '^disable --now alpha-system.service$' "$TMP/systemctl.log"; then
  ok "B1: system-unit adoption preserves the claim through ordinary teardown"
else
  bad "B1: system-unit adopt/teardown (adopt=$system_adopt_rc caps=$system_caps teardown=$system_td_rc)"
  failure_detail "$system_scan"
  failure_detail "$system_adopt"
  failure_detail "$system_td"
fi

# B2) a clean box (nothing on disk) is silent — F15 never reports what it
# has nothing to report.
p4_reset; p4_mkalpha
p4_cfg_hubonly "$P4CFG"
out="$(p4_run "$P4CFG" adopt-scan 2>&1)"
[ -z "$out" ] && ok "B2: a clean box (nothing on disk) is silent" || bad "B2: clean-box scan -> $out"

# B3) a currently-CONFIGURED id refuses --adopt (the ordinary install path
# applies, D5's idempotent re-run rule).
p4_reset; p4_mkalpha
P4CFG_CONF="$TMP/p4-cfg-conf.toml"
{ base_config; printf '[apps.alpha]\n'; } > "$P4CFG_CONF"
out="$(p4_run "$P4CFG_CONF" adopt-write alpha 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "is configured in airlock.toml" <<<"$out" \
  && ok "B3: adopt-write on a currently-configured id refuses" \
  || { bad "B3: configured-id refusal (rc=$rc)"; failure_detail "$out"; }

# B4-B6) an EXISTING record — committed-only, intent-only, or coexisting
# (mid-upgrade) — refuses --adopt with the pinned retry message, and the
# retry path (the ORDINARY teardown command) converges on removing it.
for kind in committed-only intent-only coexisting; do
  p4_reset; p4_mkalpha
  mkdir -p "$FAKEHOME/.local/bin"; : > "$FAKEHOME/.local/bin/alpha-bin"
  { base_config; printf '[apps.alpha]\n'; } > "$P4CFG_CONF"
  case "$kind" in
    committed-only) p4_ledger_run "$P4CFG_CONF" intent alpha >/dev/null
                    p4_ledger_run "$P4CFG_CONF" commit alpha >/dev/null ;;
    intent-only)    p4_ledger_run "$P4CFG_CONF" intent alpha >/dev/null ;;
    coexisting)     p4_ledger_run "$P4CFG_CONF" intent alpha >/dev/null
                    p4_ledger_run "$P4CFG_CONF" commit alpha >/dev/null
                    p4_ledger_run "$P4CFG_CONF" intent alpha >/dev/null ;;
  esac
  p4_cfg_hubonly "$P4CFG"   # alpha removed from config — the state --adopt's retry UX addresses
  out="$(p4_run "$P4CFG" adopt-write alpha 2>&1)"; rc=$?
  if [ "$rc" != 0 ] && grep -qF "record exists — run bin/airlock-teardown alpha" <<<"$out"; then
    ok "B: adopt-write refuses ($kind) — 'record exists' message pinned"
  else
    bad "B: adopt-write should refuse ($kind, rc=$rc)"; failure_detail "$out"
  fi
  td_out="$(p4_teardown "$P4CFG" alpha 2>&1)"; td_rc=$?
  [ "$td_rc" = 0 ] && [ ! -e "$FAKEHOME/.local/bin/alpha-bin" ] \
    && ok "B: retry converges on the ordinary teardown machinery ($kind)" \
    || { bad "B: convergence failed ($kind, rc=$td_rc)"; failure_detail "$td_out"; }
done

# B7) configured-UNRECORDED overlap: an app installed this very run has
# claims before its record lands (D6 amendment) — a candidate colliding
# with its DECLARED (not recorded) artifacts is excluded, and a forced
# --adopt is refused for the identical reason.
p4_reset; p4_mkalpha
mkdir -p "$FAKEHOME/.local/bin"; : > "$FAKEHOME/.local/bin/alpha-bin"
mkpkg "$P4APPS/beta" beta 'contract = 1' 'id = "beta"' \
  '[artifacts]' 'files = ["~/.local/bin/alpha-bin"]'
P4CFG_BETA="$TMP/p4-cfg-beta.toml"
{ base_config; printf '[apps.beta]\n'; } > "$P4CFG_BETA"
out="$(p4_run "$P4CFG_BETA" adopt-scan 2>&1)"
case "$out" in
  EXCLUDE$'\t'alpha$'\t'*) ok "B7: configured-unrecorded overlap excludes alpha from the report" ;;
  *) bad "B7: configured-unrecorded exclusion -> $out" ;;
esac
out2="$(p4_run "$P4CFG_BETA" adopt-write alpha 2>&1)"; rc2=$?
[ "$rc2" != 0 ] && grep -qF "overlaps configured app 'beta'" <<<"$out2" \
  && ok "B7: a forced --adopt is refused for the identical reason" \
  || { bad "B7: forced adopt-write not refused (rc=$rc2)"; failure_detail "$out2"; }

# B8) existing-path overlap with another id's COMMITTED record.
p4_reset; p4_mkalpha
mkdir -p "$FAKEHOME/.local/bin"; : > "$FAKEHOME/.local/bin/alpha-bin"
mkpkg "$P4APPS/gamma" gamma 'contract = 1' 'id = "gamma"' \
  '[artifacts]' 'files = ["~/.local/bin/alpha-bin"]'
P4CFG_GAMMA="$TMP/p4-cfg-gamma.toml"
{ base_config; printf '[apps.gamma]\n'; } > "$P4CFG_GAMMA"
p4_ledger_run "$P4CFG_GAMMA" intent gamma >/dev/null
p4_ledger_run "$P4CFG_GAMMA" commit gamma >/dev/null
p4_cfg_hubonly "$P4CFG"   # gamma removed from config, but its COMMITTED record still owns the path
out="$(p4_run "$P4CFG" adopt-scan 2>&1)"
case "$out" in
  EXCLUDE$'\t'alpha$'\t'*) ok "B8: an existing-path overlap with another id's COMMITTED record excludes alpha" ;;
  *) bad "B8: committed-record-overlap exclusion -> $out" ;;
esac
out2="$(p4_run "$P4CFG" adopt-write alpha 2>&1)"; rc2=$?
[ "$rc2" != 0 ] && ok "B8: a forced --adopt is refused too" \
  || { bad "B8: forced adopt-write not refused (rc=$rc2)"; failure_detail "$out2"; }

# B9) overlap via an ABSENT declared pattern: alpha2's ONLY on-disk (hence
# detectable) path is unrelated; the collision is through a SECOND declared
# pattern that has nothing on disk at all — still excluded, because
# admission checks the FULL prospective claim set, not just what exists.
p4_reset
mkpkg "$P4APPS/alpha2" alpha2 'contract = 1' 'id = "alpha2"' \
  '[config.defaults]' 'port = 19602' \
  '[artifacts]' 'files = ["~/.local/bin/alpha2-real", "~/.local/bin/alpha2-ghost"]' 'serve_ports = ["port"]'
mkdir -p "$FAKEHOME/.local/bin"; : > "$FAKEHOME/.local/bin/alpha2-real"
mkpkg "$P4APPS/gamma2" gamma2 'contract = 1' 'id = "gamma2"' \
  '[artifacts]' 'files = ["~/.local/bin/alpha2-ghost"]'
P4CFG_G2="$TMP/p4-cfg-gamma2.toml"
{ base_config; printf '[apps.gamma2]\n'; } > "$P4CFG_G2"
p4_ledger_run "$P4CFG_G2" intent gamma2 >/dev/null   # intent alone: _recorded_claims projects intent-declared patterns too
p4_cfg_hubonly "$P4CFG"
out="$(p4_run "$P4CFG" adopt-scan 2>&1)"
case "$out" in
  EXCLUDE$'\t'alpha2$'\t'*) ok "B9: overlap via an ABSENT declared pattern still excludes (full claim set, not just what's on disk)" ;;
  *) bad "B9: absent-declared-pattern exclusion -> $out" ;;
esac

# B10) overlap via a serve (mode, listen) collision.
p4_reset
mkpkg "$P4APPS/alpha3" alpha3 'contract = 1' 'id = "alpha3"' \
  '[config.defaults]' 'port = 19603' \
  '[artifacts]' 'files = ["~/.local/bin/alpha3-bin"]' 'serve_ports = ["port"]'
mkdir -p "$FAKEHOME/.local/bin"; : > "$FAKEHOME/.local/bin/alpha3-bin"
mkpkg "$P4APPS/gamma3" gamma3 'contract = 1' 'id = "gamma3"' \
  '[config.defaults]' 'gport = 19603' '[artifacts]' 'serve_ports = ["gport"]'
P4CFG_G3="$TMP/p4-cfg-gamma3.toml"
{ base_config; printf '[apps.gamma3]\n'; } > "$P4CFG_G3"
p4_ledger_run "$P4CFG_G3" intent gamma3 >/dev/null
p4_cfg_hubonly "$P4CFG"
out="$(p4_run "$P4CFG" adopt-scan 2>&1)"
case "$out" in
  EXCLUDE$'\t'alpha3$'\t'*) ok "B10: a serve (mode, listen) collision with another id's record excludes alpha3" ;;
  *) bad "B10: serve-collision exclusion -> $out" ;;
esac

# B11) overlap via a ROOTED-class claim (shipped-only; static allowlist
# path, not env-dependent, so this stays sandbox-safe with no real /etc
# writes).
p4_reset
mkpkg "$P4APPS/alpha4" alpha4 'contract = 1' 'id = "alpha4"' \
  '[artifacts]' 'files = ["~/.local/bin/alpha4-bin"]' 'rooted = ["/etc/airlock/p4-shared-thing"]'
mkdir -p "$FAKEHOME/.local/bin"; : > "$FAKEHOME/.local/bin/alpha4-bin"
mkpkg "$P4APPS/gamma4" gamma4 'contract = 1' 'id = "gamma4"' \
  '[artifacts]' 'rooted = ["/etc/airlock/p4-shared-thing"]'
P4CFG_G4="$TMP/p4-cfg-gamma4.toml"
{ base_config; printf '[apps.gamma4]\n'; } > "$P4CFG_G4"
p4_ledger_run "$P4CFG_G4" intent gamma4 >/dev/null
p4_cfg_hubonly "$P4CFG"
out="$(p4_run "$P4CFG" adopt-scan 2>&1)"
case "$out" in
  EXCLUDE$'\t'alpha4$'\t'*) ok "B11: a rooted-class overlap with another id's record excludes alpha4" ;;
  *) bad "B11: rooted-overlap exclusion -> $out" ;;
esac

# B12) platform-claim overlap: alpha5 declares the hub's own webroot entry.
p4_reset
mkpkg "$P4APPS/alpha5" alpha5 'contract = 1' 'id = "alpha5"' '[artifacts]' 'webroot = ["index.html"]'
: > "$WEB/index.html"
p4_cfg_hubonly "$P4CFG"
out="$(p4_run "$P4CFG" adopt-scan 2>&1)"
case "$out" in
  EXCLUDE$'\t'alpha5$'\t'*) ok "B12: a platform-owned webroot claim (index.html) excludes alpha5" ;;
  *) bad "B12: platform-claim exclusion -> $out" ;;
esac
out2="$(p4_run "$P4CFG" adopt-write alpha5 2>&1)"; rc2=$?
[ "$rc2" != 0 ] && grep -qF "overlaps the platform's own" <<<"$out2" \
  && ok "B12: a forced --adopt is refused for the platform overlap too" \
  || { bad "B12: forced adopt-write not refused (rc=$rc2)"; failure_detail "$out2"; }

# B13) customized-port limitation: a declared serve_ports key with NO
# [config.defaults] value cannot be constructed into a synthetic
# serve_mappings entry at all — detection excludes it (never prints an
# unconstructable --adopt line), and a forced --adopt refuses cleanly
# (never an uncaught traceback: adversarial review round caught this as a
# real defect — detection said ok, enforcement crashed).
p4_reset
mkdir -p "$P4APPS/alpha6"
pkg_manifest "$P4APPS/alpha6" 'contract = 1' 'id = "alpha6"' \
  '[[config.required]]' 'name = "port"' 'type = "integer"' \
  '[artifacts]' 'files = ["~/.local/bin/alpha6-bin"]' 'serve_ports = ["port"]'
scripts_ok "$P4APPS/alpha6"
mkdir -p "$FAKEHOME/.local/bin"; : > "$FAKEHOME/.local/bin/alpha6-bin"
p4_cfg_hubonly "$P4CFG"
out="$(p4_run "$P4CFG" adopt-scan 2>&1)"
case "$out" in
  EXCLUDE$'\t'alpha6$'\t'*"config.defaults"*) ok "B13: an undefaulted serve_ports key excludes alpha6 (customized-port limitation)" ;;
  *) bad "B13: undefaulted-serve-key exclusion -> $out" ;;
esac
out2="$(p4_run "$P4CFG" adopt-write alpha6 2>&1)"; rc2=$?
b13_forced_ok=0
if [ "$rc2" != 0 ] && grep -qF "cannot be adopted" <<<"$out2" \
   && ! grep -qF "Traceback" <<<"$out2"; then
  b13_forced_ok=1
fi

# B13b) a default-off conditional HTTPS listener stays absent when a shipped
# package is adopted. The ordinary resolver already omits it; adoption must
# not synthesize the HTTPS mapping back into the ledger from defaults.
p4_reset
mkdir -p "$P4APPS/alpha7"
pkg_manifest "$P4APPS/alpha7" 'contract = 1' 'id = "alpha7"' \
  '[config.defaults]' 'listen = 19607' 'target = 19608' 'enabled = false' \
  '[artifacts]' 'files = ["~/.local/bin/alpha7-bin"]' 'serve_ports = ["listen"]' \
  '[serve.https]' 'listen = { target = "target", enabled = "enabled" }'
scripts_ok "$P4APPS/alpha7"
mkdir -p "$FAKEHOME/.local/bin"; : > "$FAKEHOME/.local/bin/alpha7-bin"
p4_cfg_hubonly "$P4CFG"
out="$(p4_run "$P4CFG" adopt-write alpha7 2>&1)"; rc=$?
adopted_conditional="$(python3 -c '
import json, sys
r = json.load(open(sys.argv[1]))["entries"]["alpha7"]["intent"]
print(len(r["serve_mappings"]), len(r["serve_port_values"]),
      len(r["artifacts_declared"]["serve_ports"]))
' "$STATE/app-ledger.json" 2>/dev/null)"
if [ "$b13_forced_ok" = 1 ] && [ "$rc" = 0 ] \
   && [ "$adopted_conditional" = "0 0 0" ]; then
  ok "B13/B13b: forced adoption fails cleanly and default-off serve stays unclaimed"
else
  bad "B13/B13b: adoption contract drifted (forced_rc=$rc2 off_rc=$rc shape=$adopted_conditional)"
  failure_detail "$out2"
  failure_detail "$out"
fi

# B14) admission/scan unification (round-2 review): the on-disk existence
# probe (expand_declared) used to run ONLY inside cmd_adopt_scan — a
# symlinked intermediate directory that makes a glob match escape its
# platform root raises a LedgerError the scan caught and excluded, but a
# FORCED adopt-write never called expand_declared at all, so it could admit
# and journal exactly what the scan would have refused. Both call sites now
# share the identical expand_declared probe inside _known_builtin_admission
# itself — this proves they still agree on the identical failure, byte for
# byte in the reason text.
p4_reset
mkdir -p "$P4APPS/epsilon" "$TMP/p4-escape-target"
: > "$TMP/p4-escape-target/file1"
ln -s "$TMP/p4-escape-target" "$WEB/escape"
pkg_manifest "$P4APPS/epsilon" 'contract = 1' 'id = "epsilon"' \
  '[artifacts]' 'webroot = ["escape/*"]'
scripts_ok "$P4APPS/epsilon"
p4_cfg_hubonly "$P4CFG"
scan_out="$(p4_run "$P4CFG" adopt-scan 2>&1)"
write_out="$(p4_run "$P4CFG" adopt-write epsilon 2>&1)"; write_rc=$?
scan_reason="${scan_out#EXCLUDE$'\t'epsilon$'\t'}"
if [ "$write_rc" != 0 ] && grep -qF "artifact expansion failed" <<<"$scan_out" \
   && grep -qF "artifact expansion failed" <<<"$write_out" \
   && grep -qF "$scan_reason" <<<"$write_out"; then
  ok "B14: a symlink-escape LedgerError refuses identically at scan (EXCLUDE) and at forced adopt-write — same reason text"
else
  bad "B14: admission/scan unification for a symlink-escape probe failure"
  failure_detail "scan: $scan_out"
  failure_detail "write: $write_out"
fi
rm -f "$WEB/escape"

# B15) lost-update race (round-2 review Blocker): `adopt-write` is directly
# CLI-dispatchable (main's dispatch table has no caller-identity check —
# "ORCHESTRATOR-INTERNAL" in a docstring is not an execution boundary), and
# used to take NO lock of its own when invoked that way — two concurrent
# bare `adopt-write` calls both read-modify-wrote the ledger store with no
# serialisation, and `write_store`'s atomic os.replace prevents a CORRUPT
# file but not a LOST UPDATE (the second writer's os.replace silently wins,
# dropping the first writer's entry entirely). adopt-write now self-locks
# (the same ledger lock file, real flock(2)) whenever it is not already
# running under bin/airlock-teardown's own lock. Reproduced directly: 30
# concurrent `adopt-write zeta1` + 30 concurrent `adopt-write zeta2` (60
# total) must leave EXACTLY ONE winner per id and BOTH ids present in the
# final store — zero lost updates, whether the race is won by success or by
# a clean "record exists"/"lock held" refusal.
p4_reset
mkpkg "$P4APPS/zeta1" zeta1 'contract = 1' 'id = "zeta1"' \
  '[artifacts]' 'files = ["~/.local/bin/zeta1-race-bin"]'
mkpkg "$P4APPS/zeta2" zeta2 'contract = 1' 'id = "zeta2"' \
  '[artifacts]' 'files = ["~/.local/bin/zeta2-race-bin"]'
mkdir -p "$FAKEHOME/.local/bin"
: > "$FAKEHOME/.local/bin/zeta1-race-bin"; : > "$FAKEHOME/.local/bin/zeta2-race-bin"
p4_cfg_hubonly "$P4CFG"
race_pids=""
for _i in $(seq 1 30); do
  ( AIRLOCK_SHIPPED_APPS_ROOT="$P4APPS" AIRLOCK_CONFIG="$P4CFG" python3 "$CFG" adopt-write zeta1 >/dev/null 2>&1 ) &
  race_pids="$race_pids $!"
  ( AIRLOCK_SHIPPED_APPS_ROOT="$P4APPS" AIRLOCK_CONFIG="$P4CFG" python3 "$CFG" adopt-write zeta2 >/dev/null 2>&1 ) &
  race_pids="$race_pids $!"
done
race_ok=0
for _p in $race_pids; do
  wait "$_p" && race_ok=$((race_ok + 1))
done
survivors="$(python3 -c 'import json,sys; print(sorted(json.load(open(sys.argv[1]))["entries"]))' "$STATE/app-ledger.json")"
if [ "$race_ok" = 2 ] && [ "$survivors" = "['zeta1', 'zeta2']" ]; then
  ok "B15: 60 concurrent bare adopt-write calls (30x2 ids), zero lost updates — both entries survive, exactly one winner per id"
else
  bad "B15: lost-update race (ok_count=$race_ok, survivors=$survivors — expected 2 and both ids present)"
fi

# B16) wrapper-path regression: the self-locking fix must not touch the
# `bin/airlock-teardown --adopt` path's own behaviour at all — it already
# holds the lock and sets AIRLOCK_LEDGER_LOCK_HELD=1, so adopt-write must
# skip self-locking there (self-locking on the SAME already-held file would
# deadlock). Full end-to-end through the actual wrapper CLI surface (every
# earlier B fixture called `airlock-config adopt-write` directly, never
# `bin/airlock-teardown --adopt` itself): dry-run preview, then a real
# adopt + the ordinary teardown machinery reclaiming the artifact.
p4_reset
mkpkg "$P4APPS/eta" eta 'contract = 1' 'id = "eta"' \
  '[artifacts]' 'files = ["~/.local/bin/eta-bin"]'
mkdir -p "$FAKEHOME/.local/bin"; : > "$FAKEHOME/.local/bin/eta-bin"
p4_cfg_hubonly "$P4CFG"
dry_out="$(timeout 10 env AIRLOCK_DRY_RUN=1 AIRLOCK_SHIPPED_APPS_ROOT="$P4APPS" AIRLOCK_CONFIG="$P4CFG" \
  bash "$ROOT/bin/airlock-teardown" --adopt eta 2>&1)"; dry_rc=$?
[ "$dry_rc" = 0 ] && [ ! -e "$STATE/app-ledger.json" ] \
  && ok "B16: wrapper --adopt dry-run previews without a deadlock and without writing" \
  || { bad "B16: wrapper --adopt dry-run (rc=$dry_rc)"; failure_detail "$dry_out"; }
real_out="$(timeout 10 env AIRLOCK_SHIPPED_APPS_ROOT="$P4APPS" AIRLOCK_CONFIG="$P4CFG" \
  bash "$ROOT/bin/airlock-teardown" --adopt eta 2>&1)"; real_rc=$?
[ "$real_rc" = 0 ] && [ ! -e "$FAKEHOME/.local/bin/eta-bin" ] \
  && ok "B16: wrapper --adopt end-to-end (no deadlock) — adopts and the ordinary teardown machinery reclaims it" \
  || { bad "B16: wrapper --adopt end-to-end (rc=$real_rc)"; failure_detail "$real_out"; }
entries_eta="$(python3 -c 'import json; print(json.load(open("'"$STATE"'/app-ledger.json"))["entries"])' 2>/dev/null)"
[ "$entries_eta" = "{}" ] && ok "B16: ledger entry dropped after wrapper --adopt teardown" \
  || bad "B16: ledger entries after wrapper --adopt teardown -> $entries_eta"

# =============================================================================
# C) ledger gate widening (install/airlock-install.sh): ANY box with a known
# builtin — even zero configured packages, zero ledger file — now enters
# the ledger-locked path (F15 amendment: closing the hub-only escape).
# =============================================================================

p4_reset; p4_mkalpha
P4CFG_BOGUS="$TMP/p4-cfg-bogus.toml"
{ base_config; printf '[apps.bogus]\n'; } > "$P4CFG_BOGUS"   # dies at validate — reached only AFTER the gate
out="$(AIRLOCK_SHIPPED_APPS_ROOT="$P4APPS" AIRLOCK_CONFIG="$P4CFG_BOGUS" \
  AIRLOCK_NGINX_SITE="$TMP/p4-nginx-site.conf" bash "$ROOT/install/airlock-install.sh" 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ -e "$STATE/app-ledger.lock" ] \
  && ok "C: a hub-only box with a known builtin present enters the ledger gate" \
  || { bad "C: gate did not open with a known builtin present (rc=$rc)"; failure_detail "$out"; }

p4_reset   # control: no known builtins anywhere (empty shipped root) -> gate stays closed
out="$(AIRLOCK_SHIPPED_APPS_ROOT="$P4EMPTY" AIRLOCK_CONFIG="$P4CFG_BOGUS" \
  AIRLOCK_NGINX_SITE="$TMP/p4-nginx-site.conf" bash "$ROOT/install/airlock-install.sh" 2>&1)"; rc=$?
[ "$rc" != 0 ] && [ ! -e "$STATE/app-ledger.lock" ] \
  && ok "C: control — no known builtins, no packages, no ledger file: the gate stays closed" \
  || { bad "C: control gate should stay closed (rc=$rc)"; failure_detail "$out"; }

# E2E wiring: a VALID hub-only config (reaches past validate, unlike the
# 'bogus' probe above) with an unconfigured known builtin that has an
# on-disk artifact actually logs the F15 sweep line during a real run —
# the gate opening (above) is necessary but not sufficient; this proves the
# sweep is actually CALLED from install/airlock-install.sh, not just that
# the lock is taken. Needs an `nginx` shim too (preflight's own
# `command -v nginx` check runs before step 1b, unlike the 'bogus' probe
# above which never reaches preflight at all) — a stub that always exits 0,
# same shape as install/test-packages.sh's own nginx shim; the run still
# dies later at "sudo nginx -t"'s real config check, irrelevant here since
# the sweep runs at step 1b, well before nginx render/reload.
printf '#!/usr/bin/env bash\nexit 0\n' > "$SHIM/nginx"; chmod +x "$SHIM/nginx"
p4_reset; p4_mkalpha
mkdir -p "$FAKEHOME/.local/bin"; : > "$FAKEHOME/.local/bin/alpha-bin"
P4CFG_VALID="$TMP/p4-cfg-valid.toml"; p4_cfg_hubonly "$P4CFG_VALID"
out="$(AIRLOCK_SHIPPED_APPS_ROOT="$P4APPS" AIRLOCK_CONFIG="$P4CFG_VALID" \
  AIRLOCK_NGINX_SITE="$TMP/p4-nginx-site2.conf" bash "$ROOT/install/airlock-install.sh" 2>&1 || true)"
grep -qF "pre-ledger artifact(s) found for known builtin 'alpha'" <<<"$out" \
  && grep -qF "bin/airlock-teardown --adopt alpha" <<<"$out" \
  && ok "C: the F15 sweep is actually wired into install/airlock-install.sh and logs the --adopt line" \
  || { bad "C: sweep line not found in a real orchestrator run"; failure_detail "$out"; }

# =============================================================================
# D) artifact inventory audit — per app, every REAL rendered destination
# (independently sourced from install/test-render-parity.sh's
# run_installer_path captures — an actual install.sh execution — plus the
# task doc's Appendix for non-rendered artifacts) must be claimed by that
# app's [artifacts] patterns; every retained-data path must NOT be. A
# self-test proves the check actually catches an injected under-declaration
# (not a vacuous pass). Pure string/pattern comparison — no real filesystem
# writes under the fixed /AUDIT/* root set, so this needs no sandbox beyond
# reading the real $ROOT/apps/*/airlock-app.toml manifests.
# =============================================================================

cat > "$TMP/c4p4-audit.py" <<'PYEOF'
import importlib.util
import os
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path

ROOT = Path(sys.argv[1])
os.environ["AIRLOCK_SHIPPED_APPS_ROOT"] = str(ROOT / "apps")
loader = SourceFileLoader("_c4p4_audit_config", str(ROOT / "bin/airlock-config"))
_spec = importlib.util.spec_from_loader(loader.name, loader)
cfgmod = importlib.util.module_from_spec(_spec)
loader.exec_module(cfgmod)

ROOTS = {
    "unit_user": Path("/AUDIT/uu"), "unit_system": Path("/AUDIT/us"),
    "confd": Path("/AUDIT/confd"), "webroot": Path("/AUDIT/web"),
    "home": Path("/AUDIT/home"),
}
UU, US, CONFD, WEB, HOME = (str(ROOTS[k]) for k in
    ("unit_user", "unit_system", "confd", "webroot", "home"))
WEBP = os.path.dirname(WEB)

canon = cfgmod._canon_claim

POSITIVE = [
    ("code-server", f"{CONFD}/servers.d/code-server.conf", "nginx fragment"),
    ("code-server", f"{UU}/airlock-code-server@.service", "slot unit template"),
    ("code-server", f"{UU}/airlock-code-server-manager.service", "manager unit"),
    ("code-server", f"{HOME}/.local/lib/code-server-4.128.0-linux-amd64", "versioned tree (amd64)"),
    ("code-server", f"{HOME}/.local/lib/code-server-4.128.0-linux-arm64", "versioned tree (arm64)"),
    ("code-server", f"{HOME}/.local/bin/code-server", "code-server symlink"),
    ("code-server", f"{HOME}/.local/bin/airlock-code-server-slot", "slot launcher"),
    ("code-server", f"{HOME}/.local/bin/airlock-code-server-manager", "manager binary"),
    ("code-server", f"{HOME}/.config/code-server/config.yaml", "installer-generated config"),

    ("dev-monitor", f"{CONFD}/hub-locations.d/dev-monitor.conf", "nginx fragment"),
    ("dev-monitor", f"{UU}/airlock-dev-monitor.service", "unit"),
    ("dev-monitor", f"{WEB}/monitor/index.html", "dashboard webroot page"),
    ("dev-monitor", f"{HOME}/.config/airlock/dev-monitor.env", "unit EnvironmentFile"),

    ("devterm", f"{CONFD}/servers.d/devterm.conf", "nginx fragment"),
    ("devterm", f"{UU}/airlock-devterm.service", "ttyd unit"),
    ("devterm", f"{UU}/airlock-devterm-gate.service", "gate unit"),
    ("devterm", f"{HOME}/.local/bin/ttyd", "ttyd binary"),
    ("devterm", f"{HOME}/.local/bin/devterm-shell", "shell wrapper"),
    ("devterm", f"{HOME}/.local/bin/claude-switch", "account-switch tool"),
    ("devterm", f"{HOME}/.local/bin/claude-status", "account-status tool"),

    ("feedback", f"{CONFD}/hub-locations.d/feedback.conf", "nginx fragment"),
    ("feedback", f"{UU}/airlock-feedback.service", "unit"),

    ("fileview", f"{CONFD}/hub-locations.d/fileview.conf", "nginx fragment"),
    ("fileview", f"{UU}/airlock-fileview.service", "unit"),
    ("fileview", f"{WEB}/__fv", "static asset dir (one dir claim)"),
    ("fileview", f"{HOME}/.local/bin/filebrowser", "filebrowser binary"),
    ("fileview", f"{HOME}/.config/airlock-fileview", "filebrowser state dir (db)"),

    ("notepad", f"{WEB}/notepad/index.html",
     "clipboard page (apps/notepad/install.sh: install -m644 ... $WEBROOT/notepad/index.html)"),

    ("orca", f"{CONFD}/servers.d/orca.conf", "nginx fragment"),
    ("orca", f"{UU}/airlock-orca-xvfb.service", "xvfb unit"),
    ("orca", f"{UU}/airlock-orca.service", "serve unit"),
    ("orca", f"{US}/airlock-orca-firewall.service", "SYSTEM-scope firewall unit"),
    ("orca", f"{HOME}/.local/bin/airlock-orca-reap", "reap helper"),
    ("orca", "/etc/airlock/orca-loopback.nft", "rooted: static nft ruleset"),
    ("orca", f"{WEBP}/orca-web", "rooted: ${webroot_parent}/orca-web/ bundle"),
    ("orca", f"{HOME}/.local/share/airlock-orca", "AppImage/squashfs/serve.log dir"),
    ("orca", f"{HOME}/.config/orca/airlock-pairing-code", "pairing code file"),

    ("paseo", f"{CONFD}/servers.d/paseo.conf", "nginx fragment"),
    ("paseo", f"{CONFD}/paseo", "icon location fragments dir claim"),
    ("paseo", f"{UU}/airlock-paseo.service", "unit"),
    ("paseo", f"{UU}/airlock-paseo-browse-host.service", "browse-host unit (browse=true)"),
    ("paseo", f"{HOME}/.npm-global/bin/paseo", "npm bin symlink"),
    ("paseo", f"{HOME}/.npm-global/lib/node_modules/@getpaseo/cli", "npm-global cli tree"),
    ("paseo", f"{HOME}/.local/share/paseo-browse-host", "browse-host install dir"),

    ("publish", f"{CONFD}/hub-locations.d/publish.conf", "nginx fragment"),
    ("publish", f"{CONFD}/public-includes.d/publish-gated.conf",
     "mode-gated fragment (declared unconditionally so the ledger can reclaim it)"),
    ("publish", f"{UU}/airlock-publish.service", "backend unit"),
    ("publish", f"{UU}/airlock-publish-cleanup.service", "cleanup unit"),
    ("publish", f"{UU}/airlock-publish-cleanup.timer", "cleanup timer"),
    ("publish", f"{WEB}/publish/index.html", "manager webroot page"),
]

NEGATIVE = [
    ("code-server", f"{HOME}/.config/airlock-code-server/tabs.json", "user tabs — retained"),
    ("code-server", f"{HOME}/.local/share/airlock-code-server", "extensions/slots — user state, retained"),
    ("dev-monitor", f"{HOME}/.local/state/airlock/dev-monitor", "spool/messages.db — retained"),
    ("devterm", f"{HOME}/.config/airlock-devterm/tabs.json", "user tabs — retained"),
    ("fileview", f"{HOME}/.config/filebrowser/fb.db", "filebrowser db — retained"),
    ("paseo", f"{HOME}/.paseo/config.json", "paseo config — retained, patched in place"),
    ("paseo", f"{HOME}/.cache/ms-playwright", "shared Playwright cache — never Airlock's alone"),
    ("publish", "/opt/airlock/share", "public share dir — retained data"),
    ("publish", f"{HOME}/uploads", "uploads — retained data"),
]

failures = []
specs = {}
for app in {a for a, _, _ in POSITIVE + NEGATIVE}:
    specs[app] = cfgmod._parse_manifest_spec(
        app, ROOT / "apps" / app, "shipped", bundle_principal=True)

for app, path, note in POSITIVE:
    claims = cfgmod._pattern_claims(specs[app]["artifacts"], ROOTS, specs[app]["unit_scopes"])
    cand = canon(path)
    if not any(cfgmod._may_contain(c, cand) for c in claims):
        failures.append(f"UNDER-DECLARED {app}: {path} ({note}) is not claimed by any [artifacts] pattern")

for app, path, note in NEGATIVE:
    claims = cfgmod._pattern_claims(specs[app]["artifacts"], ROOTS, specs[app]["unit_scopes"])
    cand = canon(path)
    if any(cfgmod._may_contain(c, cand) for c in claims):
        failures.append(f"OVER-DECLARED {app}: {path} ({note}) IS claimed — retained data must never be removable")

bogus_app = "code-server"
bogus_path = f"{HOME}/.local/bin/totally-undeclared-c4p4-probe"
claims = cfgmod._pattern_claims(specs[bogus_app]["artifacts"], ROOTS, specs[bogus_app]["unit_scopes"])
if any(cfgmod._may_contain(c, canon(bogus_path)) for c in claims):
    failures.append("SELF-TEST FAILED: an intentionally undeclared path was not caught — the audit has no teeth")

if failures:
    print("\n".join(failures))
    sys.exit(1)
print(f"{len(POSITIVE)} rendered/appendix paths claimed, {len(NEGATIVE)} retained-data paths correctly "
      f"unclaimed, self-test caught an injected under-declaration, across {len(specs)} apps")
PYEOF

audit_out="$(python3 "$TMP/c4p4-audit.py" "$ROOT" 2>&1)"; audit_rc=$?
[ "$audit_rc" = 0 ] && ok "D: artifact inventory audit — $audit_out" \
  || { bad "D: artifact inventory audit failed"; failure_detail "$audit_out"; }

# =============================================================================
# E) F13a/b/c gate confirmation, retirement assertions, SECURITY.md D4, and
# the red-transcript record. F13's actual byte/field comparisons live in
# install/test-render-parity.sh (F13a nginx + F13b units/fragments vs the
# P1a committed goldens under install/golden/render/, F13c tile projection
# vs manifest-driven webjson) — not re-implemented here (a second copy would
# drift from the one true comparison); confirmed WIRED instead: the goldens
# exist, and CI actually runs that suite as its own step.
# =============================================================================

for g in "$ROOT/install/golden/render/nginx/site.conf" \
         "$ROOT/install/golden/render/tile/projection.json"; do
  [ -s "$g" ] && ok "E: F13 baseline present: ${g#"$ROOT"/}" \
    || bad "E: F13 baseline missing or empty: ${g#"$ROOT"/}"
done
for app in code-server dev-monitor devterm feedback fileview orca paseo publish; do
  [ -d "$ROOT/install/golden/render/$app" ] \
    && ok "E: F13a/b per-app goldens present: $app" \
    || bad "E: F13a/b goldens missing for $app"
done
grep -q "install/test-render-parity.sh" "$ROOT/.github/workflows/ci.yml" \
  && ok "E: F13a/b/c gate (test-render-parity.sh) is wired into CI" \
  || bad "E: test-render-parity.sh is not a CI step"

# No-silent-failure hardening (adversarial review round): the F15 sweep's
# output must be captured with an explicit failure check, not a bare
# `done < <(...)` process substitution — bash never propagates a process
# substitution's exit status through `set -e`, so a failing sweep would
# otherwise vanish with no error at all.
grep -qF '_adopt_scan="$(airlock_config adopt-scan)" || die' "$ROOT/install/airlock-install.sh" \
  && ok "E: the F15 sweep's failure is checked explicitly, not silently dropped by set -e" \
  || bad "E: F15 sweep output is not captured with an explicit failure check"

grep -q "^## Package trust (D4)" "$ROOT/SECURITY.md" \
  && ok "E: SECURITY.md carries the D4 package-trust section" \
  || bad "E: SECURITY.md D4 section missing"
grep -qF "apps.zed" "$ROOT/install/test-packages.sh" \
  && ok "E: missing-manifest/unknown-app fatal is gated (install/test-packages.sh)" \
  || bad "E: missing-manifest fatal gate not found"

# Direct confirmation too (belt-and-braces, own scratch env): a configured
# id with no shipped manifest ANYWHERE is fatal at validate.
p4_reset
P4CFG_GHOST="$TMP/p4-cfg-ghost.toml"
{ base_config; printf '[apps.ghost]\n'; } > "$P4CFG_GHOST"
out="$(AIRLOCK_SHIPPED_APPS_ROOT="$P4EMPTY" AIRLOCK_CONFIG="$P4CFG_GHOST" python3 "$CFG" validate 2>&1)"; rc=$?
[ "$rc" != 0 ] && grep -qF "unknown app [apps.ghost]" <<<"$out" \
  && ok "E: a configured id with no shipped manifest anywhere is fatal at validate" \
  || { bad "E: missing-manifest-fatal confirmation (rc=$rc)"; failure_detail "$out"; }

# Red transcript (Verification: "red-first where the base can express it") —
# checked directly against the actual base commit, not asserted from memory:
# install/test-builtin-migration.sh did not exist at c647340 at all, and
# none of the CLI surface P4 adds (known-builtins/adopt-scan/adopt-write,
# --adopt) existed in bin/airlock-config or bin/airlock-teardown there.
# A shallow CI checkout (actions/checkout defaults to fetch-depth 1) does not
# carry the base commit; fetch it on demand before deciding the base can't
# express the transcript. Only when it is genuinely unreachable (no network)
# do we SKIP — the plan's "where the base can express it" caveat — rather than
# fail a green tree on an environmental limitation.
if ! git -C "$ROOT" cat-file -e c647340 2>/dev/null; then
  git -C "$ROOT" fetch -q --depth=1 origin c647340 2>/dev/null \
    || git -C "$ROOT" fetch -q origin c647340 2>/dev/null || true
fi
if git -C "$ROOT" cat-file -e c647340 2>/dev/null; then
  base_suite_missing=1
  git -C "$ROOT" show c647340:install/test-builtin-migration.sh >/dev/null 2>&1 && base_suite_missing=0
  base_cfg_hits="$(git -C "$ROOT" show c647340:bin/airlock-config 2>/dev/null \
    | grep -c "known-builtins\|known_builtin_specs\|adopt-write\|adopt-scan" || true)"
  base_td_hits="$(git -C "$ROOT" show c647340:bin/airlock-teardown 2>/dev/null | grep -c -- "--adopt" || true)"
  if [ "$base_suite_missing" = 1 ] && [ "${base_cfg_hits:-0}" = 0 ] && [ "${base_td_hits:-0}" = 0 ]; then
    ok "E: red transcript confirmed — this suite and the known-builtins/--adopt surface it gates did not exist at base c647340"
  else
    bad "E: red-transcript check found P4 surface already at c647340 (suite_missing=$base_suite_missing cfg_hits=$base_cfg_hits td_hits=$base_td_hits)"
  fi
else
  skip "E: red-transcript check — base commit c647340 not present in this (shallow) checkout and could not be fetched; the transcript is verified where the base is reachable"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
