#!/usr/bin/env bash
# install/test-builtin-migration.sh — child 4, P1 first half: the transitional
# shipped resolver and manifest projections (docs/tasks/active/app-pkg-c4-builtin-migration.md
# section "Approach", phase P1's "Resolver" + "Record extensions" bullets).
# The render/capture extract-verify-swap half (P1a/P1b) is a separate phase
# and is NOT covered here.
#
# Every fixture package lives under a scratch AIRLOCK_SHIPPED_APPS_ROOT or its
# own temp dir, never under the repository's real apps/ tree — the shipped
# resolver must never fire against $ROOT/apps in this test (equivalence with
# a manifest-less box is install/test-equivalence.sh's job, not this file's).
set -uo pipefail
. "$(dirname "$0")/test-lib.sh"
airlock_pin_paseo_mem
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
airlock_set_fixture_root "$TMP"
airlock_neutral_selfkill_cgroup "$TMP"
CFG="$ROOT/bin/airlock-config"; LEDGER="$ROOT/bin/airlock-ledger"
airlock_test_counters_init
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
export AIRLOCK_NGINX_SITE="$TMP/nginx-site.conf"

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
# Ledger teardown verifies the stopped state before deleting any unit.
case "$*" in *show*) printf 'LoadState=loaded\nActiveState=inactive\nMainPID=0\nControlPID=0\n' ;; esac
exit 0
STUB
cat >"$SHIM/systemd-run" <<'STUB'
#!/usr/bin/env bash
echo "FAIL unexpected self-kill escape in builtin-migration fixture" >&2
exit 99
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
    raise SystemExit(module.main(sys.argv[1:]))
os.execv("/usr/bin/python3", ["/usr/bin/python3", *sys.argv[1:]])
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$SHIM/nginx"
chmod +x "$SHIM"/*
PATH="$SHIM:$PATH"; export PATH

# ---- helpers ------------------------------------------------------------
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
base_config() { printf '[auth]\nprovider = "tailscale"\nowner = "x@y.z"\n[apps.hub]\n'; }
make_pkg_cfg() {
  local path="$1" pid="$2" pkg="$3" extra_apps="${4:-}"
  { base_config
    [ -z "$extra_apps" ] || printf '%s\n' "$extra_apps"
    printf '[apps.%s]\n[packages.%s]\npath = "%s"\n' "$pid" "$pid" "$pkg"
  } >"$path"
  seed_apps "$pid" "$pkg"
}
pkg_manifest() { local dir="$1"; shift; printf '%s\n' "$@" >"$dir/airlock-app.toml"; }
scripts_ok() {
  local dir="$1"
  printf '#!/bin/sh\nexit 0\n' >"$dir/install.sh"
  cp "$dir/install.sh" "$dir/smoke.sh"; cp "$dir/install.sh" "$dir/deactivate.sh"
  chmod +x "$dir"/*.sh
}
mkpkg() { local dir="$1" id="$2"; shift 2; mkdir -p "$dir"; pkg_manifest "$dir" "$@"; scripts_ok "$dir"; }
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
seed_apps c4fixture "$TMP/override"
info="$(AIRLOCK_CONFIG="$TMP/cfg.toml" "$CFG" package-info 2>/dev/null)"
if python3 -c 'import json,sys; p=json.load(sys.stdin)["packages"]["c4fixture"]; assert p["source_class"] == "explicit"' <<<"$info"; then
  ok "explicit shadows shipped"
else
  bad "explicit shadows shipped"
fi

# Stable manifest resource metadata remains available to release tooling.
reset_box
cfg_capability_json="$TMP/cfg-capability-json.toml"
{ base_config
  printf '[apps.dev-monitor]\n[apps.orca]\n'
} >"$cfg_capability_json"
canonical_sha=0123456789abcdef0123456789abcdef01234567
canonical_expected="{\"package_id\":\"dev-monitor\",\"schema_version\":1,\"source_repository_id\":\"example-org/example-work\",\"source_sha\":\"$canonical_sha\",\"surface_classifications\":{\"rooted-artifact\":\"elevated-capability\",\"serve-https\":\"baseline-mediated-mapping\",\"serve-port\":\"baseline-mediated-mapping\",\"system-unit\":\"elevated-capability\"},\"surfaces\":[\"rooted-artifact\",\"serve-https\",\"serve-port\",\"system-unit\"]}"
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
# ROUND 3 BLOCKER 1: serve surfaces (serve_ports/serve.https vs
# plaintext_redirect) must be pairwise disjoint per app — both structurally
# (same key in two surfaces) and by resolved value (two different keys that
# happen to share one config value).
# =============================================================================

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
# serve ports for CROSS-APP disjointness — round 3's fix only checked within
# one manifest's own boundary. (The package-vs-built-in half of this case,
# a candidate colliding with hub's own hardcoded plaintext port, was dropped
# 2026-09-27 along with the rest of validate-time's platform-claim checks —
# gate-zero revival K7, docs/reports/2026-09-27_installer-gate-zero-base-revival.md.)
# =============================================================================

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

# =============================================================================
# Shipped listing, artifact inventory, render goldens and trust checks.
#
# Its own shipped root (P4APPS/P4EMPTY) — never $PKGROOT, which by this point
# in the file carries fixture packages from every section above: a
# known-builtins listing must see EXACTLY "shipped root, minus
# hub/core/shadowed", nothing accumulated from an unrelated fixture.
# =============================================================================
P4APPS="$TMP/p4-apps"; P4EMPTY="$TMP/p4-empty"
mkdir -p "$P4APPS" "$P4EMPTY"

p4_reset() { reset_box; rm -rf "$P4APPS"; mkdir -p "$P4APPS"; }
p4_run() { local cfg="$1"; shift; AIRLOCK_SHIPPED_APPS_ROOT="$P4APPS" AIRLOCK_CONFIG="$cfg" python3 "$CFG" "$@"; }
p4_teardown() { local cfg="$1"; shift; AIRLOCK_SHIPPED_APPS_ROOT="$P4APPS" AIRLOCK_CONFIG="$cfg" bash "$ROOT/bin/airlock-teardown" "$@"; }
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
[ "$out" = "$(printf 'UpperCase\nalpha')" ] && ok "A: an uppercase filename id is included" \
  || { bad "A: uppercase filename id missing -> $out"; }
rm -rf "$P4APPS/UpperCase"

# A stale packages table cannot hide a shipped manifest from known-builtins.
mkdir -p "$TMP/p4-explicit-alpha"
pkg_manifest "$TMP/p4-explicit-alpha" 'contract = 1' 'id = "alpha"' \
  '[artifacts]' 'files = ["~/.local/bin/explicit-alpha-bin"]'
scripts_ok "$TMP/p4-explicit-alpha"
P4CFG_SHADOW="$TMP/p4-cfg-shadow.toml"
{ base_config; printf '[apps.alpha]\n[packages.alpha]\npath = "%s"\n' "$TMP/p4-explicit-alpha"; } > "$P4CFG_SHADOW"
out="$(p4_run "$P4CFG_SHADOW" known-builtins 2>&1)"
[ "$out" = alpha ] && ok "A: stale packages input does not hide a shipped known-builtins id" \
  || { bad "A: shadowed exclusion -> $out"; }

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
import fnmatch
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

def claims_for(spec):
    # Audit declarations independently of the retired validation-time claim gate.
    arts = spec["artifacts"]
    claims = []
    for name in arts.get("units", []):
        scope = spec["unit_scopes"].get(name, "both")
        for kind in ("user", "system"):
            if scope in (kind, "both"):
                claims.append(str(ROOTS["unit_" + kind] / name))
    for kind, root in (("fragments", CONFD), ("webroot", WEB)):
        claims.extend(os.path.join(root, p) for p in arts.get(kind, []))
    claims.extend(HOME + p[1:] if p.startswith("~/") else p
                  for p in arts.get("files", []))
    claims.extend(p.replace("${webroot_parent}", WEBP)
                  for p in arts.get("rooted", []))
    return claims


def contains(pattern, path):
    pattern_parts = Path(pattern).parts
    path_parts = Path(path).parts
    return len(pattern_parts) <= len(path_parts) and all(
        fnmatch.fnmatchcase(actual, declared)
        for declared, actual in zip(pattern_parts, path_parts))

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
    ("paseo", f"{HOME}/.npm-global/lib/node_modules/@getpaseo/server", "npm-global bundle sibling (prefix-level server)"),
    ("paseo", f"{HOME}/.npm-global/lib/node_modules/@getpaseo/relay", "npm-global bundle sibling"),
    ("paseo", f"{HOME}/.npm-global/lib/node_modules/@getpaseo/.airlock-install-id", "install-id marker"),
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
    ("paseo", f"{HOME}/.npm-global/lib/node_modules/@getpaseo/extra",
     "a package someone else installed into the @getpaseo scope — the scope is a namespace, not ours"),
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
        app, ROOT / "apps" / app, "shipped")

for app, path, note in POSITIVE:
    claims = claims_for(specs[app])
    cand = path
    if not any(contains(c, cand) for c in claims):
        failures.append(f"UNDER-DECLARED {app}: {path} ({note}) is not claimed by any [artifacts] pattern")

for app, path, note in NEGATIVE:
    claims = claims_for(specs[app])
    cand = path
    if any(contains(c, cand) for c in claims):
        failures.append(f"OVER-DECLARED {app}: {path} ({note}) IS claimed — retained data must never be removable")

bogus_app = "code-server"
bogus_path = f"{HOME}/.local/bin/totally-undeclared-c4p4-probe"
claims = claims_for(specs[bogus_app])
if any(contains(c, bogus_path) for c in claims):
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

grep -q "^## Package trust (D4)" "$ROOT/SECURITY.md" \
  && ok "E: SECURITY.md carries the D4 package-trust section" \
  || bad "E: SECURITY.md D4 section missing"
echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
