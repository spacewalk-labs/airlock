#!/usr/bin/env bash
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
export AIRLOCK_STATE_DIR="$TMP/state"   # isolate the installed-state ledger from the dev box
pass=0 fail=0
ok(){ printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

make_config() {
  local path="$1"; shift
  {
    printf '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.dev"\n'
    for app in "$@"; do printf '[apps.%s]\n' "$app"; done
  } >"$path"
}

make_stub() {
  local dir="$1" cmd="$2"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/$cmd"
  chmod +x "$dir/$cmd"
}

TEST_HOME="$TMP/home"; mkdir -p "$TEST_HOME"

add_runtime_tools() {
  local dir="$1" cmd
  # mktemp, rm: not app prerequisites (no TSV/manifest row declares them),
  # but install/preflight.sh's F11 assembly path (`airlock-config prereqs`
  # + its temp-file cleanup trap, reached whenever ANY package/manifest is
  # configured) needs both to capture and discard the assembled inventory
  # — same category as bash/dirname/sort below, platform runtime tools the
  # sandbox must supply regardless of what this fixture's TSV-derived stub
  # list contains.
  for cmd in bash dirname sort mktemp rm; do
    ln -sf "$(command -v "$cmd")" "$dir/$cmd"
  done
}

run_preflight() {
  local config="$1" bin_path="$2"; shift 2
  HOME="$TEST_HOME" PATH="$bin_path" AIRLOCK_CONFIG="$config" \
    /bin/bash "$ROOT/bin/airlock-preflight" "$@"
}

run_engine_inventory() {
  local config="$1" bin_path="$2" inventory="$3"
  HOME="$TEST_HOME" PATH="$bin_path" AIRLOCK_CONFIG="$config" \
    /bin/bash -c \
      '. "$1/install/lib.sh"; AIRLOCK_PREREQUISITES="$2"; airlock_preflight --quiet' \
      _ "$ROOT" "$inventory"
}

BASE="$TMP/base"; mkdir -p "$BASE"
add_runtime_tools "$BASE"
ln -s "$(command -v python3)" "$BASE/python3"
for cmd in nginx sudo systemctl tailscale curl flock; do make_stub "$BASE" "$cmd"; done

make_config "$TMP/hub.toml" hub
satisfied="$(run_preflight "$TMP/hub.toml" "$BASE" 2>&1)" && sat_rc=0 || sat_rc=$?
case "$sat_rc:$satisfied" in
  0:*"prerequisite preflight passed"*) ok "satisfied preflight emits one success line" ;;
  *) bad "satisfied preflight failed (rc $sat_rc): $satisfied" ;;
esac
quiet="$(run_preflight "$TMP/hub.toml" "$BASE" --quiet 2>&1)" && quiet_rc=0 || quiet_rc=$?
if [ "$quiet_rc" = 0 ] && [ -z "$quiet" ]; then
  ok "--quiet suppresses satisfied output"
else
  bad "--quiet output/rc: rc=$quiet_rc out=$quiet"
fi

# The shared post-install smoke command runs even when only Hub is enabled.
# Its curl dependency therefore belongs to core, not only to app owners.
NOCURL="$TMP/no-curl"; cp -a "$BASE" "$NOCURL"; rm -f "$NOCURL/curl"
nocurl_rc=0
nocurl_out="$(run_preflight "$TMP/hub.toml" "$NOCURL" 2>&1)" || nocurl_rc=$?
if [ "$nocurl_rc" = 1 ] && [[ "$nocurl_out" == *curl*missing*core* ]]; then
  ok "hub-only preflight enforces shared smoke dependencies"
else
  bad "hub-only preflight missed core curl: rc=$nocurl_rc out=$nocurl_out"
fi

# Python is the one honest bootstrap exception: config cannot be parsed before
# it is present and new enough.
OLDPY="$TMP/old-python"; cp -a "$BASE" "$OLDPY"; rm -f "$OLDPY/python3"
cat >"$OLDPY/python3" <<'STUB'
#!/usr/bin/env bash
echo 3.10
STUB
chmod +x "$OLDPY/python3"
oldpy_rc=0
oldpy_out="$(HOME="$TEST_HOME" PATH="$OLDPY" /bin/bash -c \
  ". \"$ROOT/install/lib.sh\"; airlock_preflight_bootstrap" 2>&1)" || oldpy_rc=$?
if [ "$oldpy_rc" = 1 ] && [[ "$oldpy_out" == *"python3 >=3.11"*wrong-version* ]]; then
  ok "Python below 3.11 fails at bootstrap"
else
  bad "old Python bootstrap result: rc=$oldpy_rc out=$oldpy_out"
fi
cat >"$OLDPY/python3" <<'STUB'
#!/usr/bin/env bash
echo 999999999999999999999.11
STUB
overflow_rc=0
overflow_out="$(HOME="$TEST_HOME" PATH="$OLDPY" /bin/bash -c \
  ". \"$ROOT/install/lib.sh\"; airlock_preflight_bootstrap" 2>&1)" || overflow_rc=$?
if [ "$overflow_rc" = 1 ] && [[ "$overflow_out" == *wrong-version* ]] \
  && [[ "$overflow_out" != *"value too great"* ]]; then
  ok "bootstrap rejects oversized versions without arithmetic overflow"
else
  bad "oversized Python version result: rc=$overflow_rc out=$overflow_out"
fi
if bash -c ". \"$ROOT/install/lib.sh\"; ! airlock_preflight_version_ge 3.9 3.11 \
  && airlock_preflight_version_ge 3.11 3.11 \
  && airlock_preflight_version_ge 20 3.11"; then
  ok "major/minor versions compare component-wise"
else
  bad "version comparison treated dotted versions as decimals"
fi

# Enabled code-server and paseo share core rows. Leave nginx and the download
# tools absent, and provide Node 18, so one report must contain every gap.
# nginx is deliberately NOT asserted absent below: it is a daemon, so
# preflight also looks in the sbin directories and a runner that genuinely has
# nginx installed would report it present no matter what this PATH contains.
# Asserting on it would make the result depend on the box running the suite.
GAPS="$TMP/gaps"; cp -a "$BASE" "$GAPS"; rm "$GAPS/nginx" "$GAPS/curl"
cat >"$GAPS/node" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  -p) echo 18 ;;
  *) echo v18.0.0 ;;
esac
STUB
chmod +x "$GAPS/node"
make_config "$TMP/gaps.toml" hub code-server devterm paseo
gaps="$(run_preflight "$TMP/gaps.toml" "$GAPS" 2>&1)" && gaps_rc=0 || gaps_rc=$?
header_count="$(printf '%s\n' "$gaps" | grep -c '^requirement' || true)"
if [ "$gaps_rc" = 1 ] && [ "$header_count" = 1 ] \
  && [[ "$gaps" == *curl*missing* ]] \
  && [[ "$gaps" == *sha256sum*missing* ]] \
  && [[ "$gaps" == *tar*missing* ]] \
  && [[ "$gaps" == *"node >=20"*wrong-version* ]]; then
  ok "missing and wrong-version requirements are aggregated once"
else
  bad "aggregate report incomplete (rc $gaps_rc headers $header_count)"
  printf '%s\n' "$gaps" | sed 's/^/    /'
fi
if [[ "$gaps" == *"code-server,devterm"* || "$gaps" == *"devterm,code-server"* ]]; then
  ok "duplicate owners merge into one requirement"
else
  bad "merged owners missing from aggregate report"
fi

# A disabled app must not contribute its requirements.
disabled_rc=0
disabled="$(run_preflight "$TMP/hub.toml" "$BASE" 2>&1)" || disabled_rc=$?
if [ "$disabled_rc" = 0 ] && [[ "$disabled" != *npm* && "$disabled" != *tmux* ]]; then
  ok "disabled apps do not contribute prerequisites"
else
  bad "disabled app isolation failed: rc=$disabled_rc out=$disabled"
fi

# F11 assembly (`airlock-config prereqs`) merges the raw TSV with every
# migrated app's manifest-declared [[prerequisites]] rows (a migrated app's
# TSV row is deleted in the same commit that adds its manifest row, per the
# P2 migration) — so every stub list and drift oracle below is built from
# this ASSEMBLED inventory, not the raw TSV alone, or a prerequisite that
# moved into a manifest (e.g. paseo's npm, code-server's tar/sha256sum, once
# neither app has a TSV row left at all) reads as newly undeclared/unstubbed.
ASSEMBLED_PREREQS_CFG="$TMP/assembled-prereqs.toml"
make_config "$ASSEMBLED_PREREQS_CFG" \
  $(find "$ROOT/apps" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
ASSEMBLED_PREREQS="$TMP/assembled-prereqs.tsv"
AIRLOCK_CONFIG="$ASSEMBLED_PREREQS_CFG" python3 "$ROOT/bin/airlock-config" prereqs \
  >"$ASSEMBLED_PREREQS" || {
    bad "could not assemble the F11 prerequisites inventory for the drift oracles"
  }

# Constraints merge only across enabled owners. Paseo needs node >=20; fileview
# needs no node at all since markserv was deleted, so a disabled Paseo must not
# leave a node constraint standing for an app that never asked for one.
MW="$TMP/fileview-bin"; mkdir -p "$MW"
add_runtime_tools "$MW"
while IFS= read -r cmd; do make_stub "$MW" "$cmd"; done \
  < <(awk -F '\t' 'NF >= 2 {print $2}' "$ASSEMBLED_PREREQS" | sort -u)
rm -f "$MW/python3" "$MW/node"
ln -s "$(command -v python3)" "$MW/python3"
cat >"$MW/node" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in -p) echo 18 ;; *) echo v18.0.0 ;; esac
STUB
chmod +x "$MW/node"
cat >"$TMP/fileview.toml" <<'TOML'
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[paths]
[apps.hub]
[apps.fileview]
TOML
fileview_rc=0
run_preflight "$TMP/fileview.toml" "$MW" --quiet >/dev/null 2>&1 || fileview_rc=$?
if [ "$fileview_rc" = 0 ]; then
  ok "disabled app version constraints do not leak into enabled apps"
else
  bad "disabled Paseo tightened File Viewer's node requirement"
fi

# Paseo's nvm hook (child-4 P2b STEP 3): install/preflight.sh:203-209
# (pre-existing, from child 3 — unchanged by this migration) DELIBERATELY
# skips the shared airlock_load_nvm preflight hook once paseo is PACKAGED:
# "a packaged paseo declares its own runtime through its manifest, and this
# hook would act on a contract that package never made." So a preflight
# report for a packaged paseo, run against an ambient-only Node 18 with a
# real Node 20 available only via nvm, must legitimately show the wrong-
# version/missing gaps below (proving the documented boundary is real, not
# just commented) — the RESPONSIBILITY for nvm resolution shifted onto
# paseo's own install.sh, which still calls airlock_load_nvm itself
# unconditionally (apps/paseo/install.sh:78, untouched by this migration)
# at actual install time. Both halves are asserted: preflight's negative
# (still gap-reporting) and install.sh's positive (still nvm-resolving).
NVM_ALL="$TMP/nvm-ambient"; mkdir -p "$NVM_ALL"
while IFS= read -r cmd; do make_stub "$NVM_ALL" "$cmd"; done \
  < <(awk -F '\t' 'NF >= 2 {print $2}' "$ASSEMBLED_PREREQS" | sort -u)
add_runtime_tools "$NVM_ALL"
rm -f "$NVM_ALL/python3" "$NVM_ALL/node"
ln -s "$(command -v python3)" "$NVM_ALL/python3"
cat >"$NVM_ALL/node" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in -p) echo 18 ;; *) echo v18.0.0 ;; esac
STUB
chmod +x "$NVM_ALL/node"
NVM_HOME="$TMP/nvm-home"; mkdir -p "$NVM_HOME/.nvm" "$NVM_HOME/nvm-bin"
cat >"$NVM_HOME/nvm-bin/node" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in -p) echo 20 ;; *) echo v20.0.0 ;; esac
STUB
make_stub "$NVM_HOME/nvm-bin" npm
chmod +x "$NVM_HOME/nvm-bin/node"
cat >"$NVM_HOME/.nvm/nvm.sh" <<'STUB'
PATH="$HOME/nvm-bin:$PATH"
export PATH
STUB
make_config "$TMP/paseo.toml" hub paseo
nvm_pf_rc=0
nvm_pf_out="$(HOME="$NVM_HOME" PATH="$NVM_ALL" AIRLOCK_CONFIG="$TMP/paseo.toml" \
  /bin/bash "$ROOT/bin/airlock-preflight" --quiet 2>&1)" || nvm_pf_rc=$?
if [ "$nvm_pf_rc" = 1 ] && [[ "$nvm_pf_out" == *"node"*wrong-version* ]]; then
  ok "packaged paseo's preflight no longer auto-loads nvm (its manifest owns its own runtime declaration — install/preflight.sh:203-209)"
else
  bad "packaged paseo preflight/nvm boundary changed: rc=$nvm_pf_rc out=$nvm_pf_out"
fi
# The other half of the boundary: install.sh's OWN airlock_load_nvm call
# (apps/paseo/install.sh:78) still resolves nvm's node/npm at actual install
# time, unaffected by the preflight-side change above.
#
# An earlier version of this fixture sourced install/lib.sh and called
# airlock_load_nvm DIRECTLY — that proves only that the loader function
# works in isolation, never that apps/paseo/install.sh actually calls it.
# Adversarial review (round 2) reverted install.sh:78 alone and reran this
# suite: still passed=32 failed=0, because nothing here ever executed the
# installer. Fixed by running the REAL apps/paseo/install.sh end to end
# under AIRLOCK_DRY_RUN=1 (a full, isolated dry run — no network, no real
# npm install: PASEO_BIN does not exist yet, so the provision step only
# logs) against the SAME ambient-v18/nvm-v20 environment as the preflight
# negative above (PATH="$NVM_ALL:$PATH" — prepended, not exclusive, the
# same convention install/test-render-parity.sh's run_installer_path uses,
# so generic utilities the installer needs beyond its own declared
# prerequisites — readlink, install, sed, tr — still resolve). The
# installer's own gate (`[ "${NODE_MAJOR:-0}" -ge 20 ] || die "paseo needs
# node >= 20 ..."`, right after airlock_load_nvm) can only be passed if
# that call actually ran and put nvm's node 20 ahead of the ambient v18 on
# PATH — so a clean rc=0 dry run IS the positive signal.
NVM_INSTALL_CFG="$TMP/paseo-nvm-install.toml"
make_config "$NVM_INSTALL_CFG" hub paseo
run_paseo_install() {
  # $1 = install.sh to execute; the D5 ABI env vars decouple "which file
  # bash runs" from "which directory the script treats as its own package
  # dir" — the scratch copy the self-check below runs still resolves
  # render.sh, web/, etc. from the REAL apps/paseo, only its own top-level
  # statements differ.
  local script="$1" state; state="$(mktemp -d -p "$TMP")"
  HOME="$NVM_HOME" PATH="$NVM_ALL:$PATH" \
    AIRLOCK_CONFIG="$NVM_INSTALL_CFG" AIRLOCK_ROOT="$ROOT" \
    AIRLOCK_APP_DIR="$ROOT/apps/paseo" AIRLOCK_APP_ID="paseo" \
    AIRLOCK_CONFD="$(mktemp -d -p "$TMP")" AIRLOCK_STATE_DIR="$state" \
    AIRLOCK_DRY_RUN=1 /bin/bash "$script" 2>&1
}
nvm_install_rc=0
nvm_install_out="$(run_paseo_install "$ROOT/apps/paseo/install.sh")" || nvm_install_rc=$?
if [ "$nvm_install_rc" = 0 ] && [[ "$nvm_install_out" != *"needs node"* ]]; then
  ok "the REAL apps/paseo/install.sh (not just the loader function) resolves node 20 via its own airlock_load_nvm call and completes its dry run"
else
  bad "apps/paseo/install.sh no longer resolves nvm's node at its own call site: rc=$nvm_install_rc out=$nvm_install_out"
fi
# Self-check (permanent regression guard for the round-2 finding above):
# the assertion must actually depend on install.sh:78's airlock_load_nvm
# call, not just on a generous environment. Remove that one line from a
# SCRATCH COPY (the real repo file is never touched), rerun the identical
# harness against the copy, and require the SAME die() the preflight
# negative above already pins ("needs node >= 20").
PASEO_ATTACK_SH="$TMP/paseo-install-no-nvm-hook.sh"
cp "$ROOT/apps/paseo/install.sh" "$PASEO_ATTACK_SH"
sed -i '/^airlock_load_nvm$/d' "$PASEO_ATTACK_SH"
# Match a real CALL, not a mention. install.sh's snap-node refusal explains, in
# prose, that it is placed after airlock_load_nvm and why — and a plain `grep -qF`
# for the name reported that comment as a failed strip. This is the same anchoring
# lesson install/test-shell-options.sh:83-85 already had to learn on a different
# scan: a check that cannot tell code from a sentence about code fails on the
# sentence.
if grep -qE '^[[:space:]]*airlock_load_nvm[[:space:]]*$' "$PASEO_ATTACK_SH"; then
  bad "self-check: could not strip install.sh's airlock_load_nvm call from the scratch copy (sed pattern stale — did the call site change shape?)"
else
  attack_rc=0
  attack_out="$(run_paseo_install "$PASEO_ATTACK_SH")" || attack_rc=$?
  if [ "$attack_rc" != 0 ] && [[ "$attack_out" == *"needs node"*">= 20"* ]]; then
    ok "self-check: stripping install.sh's airlock_load_nvm call turns the assertion above red — it exercises the real call site, not just the loader"
  else
    bad "self-check FAILED: stripping install.sh's airlock_load_nvm call did NOT turn it red (rc=$attack_rc out=$attack_out) — the positive assertion above is not load-bearing"
  fi
fi

# Child 4/P3: an unknown app is fatal at validate now (the local/custom-app
# escape hatch retired with the built-in registry) — bin/airlock-preflight
# calls `airlock_config validate` before anything else, so this dies there,
# exit 2, before preflight's own declaration-inventory logic ever runs.
make_config "$TMP/custom.toml" hub local-tool
custom_rc=0
custom_out="$(run_preflight "$TMP/custom.toml" "$BASE" 2>&1)" || custom_rc=$?
if [ "$custom_rc" = 2 ] && [[ "$custom_out" == *"unknown app"* ]]; then
  ok "unknown app is fatal at validate (built-in fallback retired)"
else
  bad "unknown app behavior changed: rc=$custom_rc out=$custom_out"
fi

# Declaration errors are contract errors (2), not host failures (1).
printf 'core\tnginx\tunknown\t-\tfix\tnote\n' >"$TMP/bad.tsv"
bad_decl_rc=0
run_engine_inventory "$TMP/hub.toml" "$BASE" "$TMP/bad.tsv" \
  >/dev/null 2>&1 || bad_decl_rc=$?
if [ "$bad_decl_rc" = 2 ]; then
  ok "invalid declaration exits 2"
else
  bad "invalid declaration exit was $bad_decl_rc"
fi
printf 'typo-app\tcurl\tpresent\t-\tfix\tnote\n' >"$TMP/bad-owner.tsv"
bad_owner_rc=0
run_engine_inventory "$TMP/hub.toml" "$BASE" "$TMP/bad-owner.tsv" \
  >/dev/null 2>&1 || bad_owner_rc=$?
if [ "$bad_owner_rc" = 2 ]; then
  ok "unknown declaration owner exits 2"
else
  bad "unknown declaration owner exit was $bad_owner_rc"
fi
printf 'core\tnginx\tpresent\t-\tfix\tnote\ncore\tnginx\tpresent\t-\tfix\tnote\n' >"$TMP/duplicate.tsv"
duplicate_rc=0
run_engine_inventory "$TMP/hub.toml" "$BASE" "$TMP/duplicate.tsv" \
  >/dev/null 2>&1 || duplicate_rc=$?
if [ "$duplicate_rc" = 2 ]; then
  ok "duplicate declaration exits 2"
else
  bad "duplicate declaration exit was $duplicate_rc"
fi
: >"$TMP/empty.tsv"
empty_rc=0
run_engine_inventory "$TMP/hub.toml" "$BASE" "$TMP/empty.tsv" \
  >/dev/null 2>&1 || empty_rc=$?
if [ "$empty_rc" = 2 ]; then
  ok "empty declaration file exits 2"
else
  bad "empty declaration file exit was $empty_rc"
fi
cp "$ROOT/install/prerequisites.tsv" "$TMP/empty-field.tsv"
printf 'core\tdefinitely-missing\tpresent\t-\t\tfix\tnote\n' >>"$TMP/empty-field.tsv"
empty_field_rc=0
empty_field_out="$(run_engine_inventory "$TMP/hub.toml" "$BASE" \
  "$TMP/empty-field.tsv" 2>&1)" || empty_field_rc=$?
if [ "$empty_field_rc" = 2 ] && [[ "$empty_field_out" == *"invalid declaration"* ]]; then
  ok "empty declaration fields fail before tab splitting"
else
  bad "empty declaration field was accepted: rc=$empty_field_rc out=$empty_field_out"
fi
apps_failure_rc=0
HOME="$TEST_HOME" PATH="$BASE" /bin/bash -c \
  ". \"$ROOT/install/lib.sh\"; airlock_config(){ return 42; }; airlock_preflight --quiet" \
  >/dev/null 2>&1 || apps_failure_rc=$?
if [ "$apps_failure_rc" = 2 ]; then
  ok "enabled-app discovery failure exits 2"
else
  bad "enabled-app discovery failure exit was $apps_failure_rc"
fi
# F11: with [packages.*] configured (AIRLOCK_PKG_INFO non-empty), preflight
# delegates ASSEMBLY to `airlock-config prereqs` and must check the producer's
# exit status directly — a failing assembly is the preflight contract surface,
# rc 2, never a truncated inventory evaluated as if complete.
assembly_rc=0
assembly_out="$(AIRLOCK_PKG_INFO='{"config_path":"/dev/null","order":[],"packages":{"p":{}}}' /bin/bash -c \
  ". \"$ROOT/install/lib.sh\"; airlock_config(){
     case \"\${1:-}\" in
       apps) printf 'hub\n' ;;
       prereqs) return 1 ;;
     esac
   }; airlock_preflight --quiet" 2>&1)" || assembly_rc=$?
# rc 2 alone cannot distinguish this from any other contract error — the
# message pins WHICH guard fired (a swallowed producer status would surface
# as 'declaration file contains no requirements' instead).
if [ "$assembly_rc" = 2 ] && grep -Fq "prerequisite assembly failed" <<<"$assembly_out"; then
  ok "failing prereqs assembly exits 2 (producer status checked directly)"
else
  bad "failing prereqs assembly exit was $assembly_rc"
fi

invalid_config_rc=0
run_preflight /dev/null "$BASE" --quiet >/dev/null 2>&1 || invalid_config_rc=$?
if [ "$invalid_config_rc" = 2 ]; then
  ok "standalone config contract errors exit 2"
else
  bad "standalone invalid config exit was $invalid_config_rc"
fi
installer_config_rc=0
HOME="$TEST_HOME" PATH="$BASE" AIRLOCK_CONFIG=/dev/null AIRLOCK_DRY_RUN=1 \
  /bin/bash "$ROOT/install/airlock-install.sh" >/dev/null 2>&1 || installer_config_rc=$?
if [ "$installer_config_rc" = 2 ]; then
  ok "installer config contract errors exit 2"
else
  bad "installer invalid config exit was $installer_config_rc"
fi
NOPY="$TMP/no-python"; cp -a "$BASE" "$NOPY"; rm -f "$NOPY/python3"
bootstrap_first_rc=0
bootstrap_first_out="$(run_preflight /dev/null "$NOPY" --quiet 2>&1)" || bootstrap_first_rc=$?
if [ "$bootstrap_first_rc" = 1 ] && [[ "$bootstrap_first_out" == *"python3 >=3.11"*missing* ]]; then
  ok "missing Python bootstrap precedes config parsing"
else
  bad "missing-Python bootstrap contract changed: rc=$bootstrap_first_rc out=$bootstrap_first_out"
fi
override_rc=0
HOME="$TEST_HOME" PATH="$BASE" AIRLOCK_CONFIG="$TMP/hub.toml" \
  AIRLOCK_PREREQUISITES="$TMP/empty.tsv" AIRLOCK_PREFLIGHT_PATH="$GAPS" \
  /bin/bash "$ROOT/bin/airlock-preflight" --quiet >/dev/null 2>&1 || override_rc=$?
if [ "$override_rc" = 0 ]; then
  ok "production ignores test-only inventory and PATH environment variables"
else
  bad "test-only environment changed production preflight: rc=$override_rc"
fi

# Defensive require_cmd declarations may be stricter than the aggregate check,
# but each command must retain that app as an explicit owner in the inventory.
discover_installers() {
  find "$1" -type f -name install.sh -print0
}

drift=0
drift_checked=0
INSTALLER_LIST="$TMP/installer-files"
if discover_installers "$ROOT/apps" >"$INSTALLER_LIST"; then
  while IFS= read -r -d '' installer; do
    relative="${installer#"$ROOT/apps/"}"
    owner="${relative%%/*}"
    while IFS= read -r cmd; do
      [ -n "$cmd" ] || continue
      drift_checked=$((drift_checked + 1))
      awk -F '\t' -v owner="$owner" -v cmd="$cmd" \
        '$1 == owner && $2 == cmd { found=1 } END { exit !found }' \
        "$ASSEMBLED_PREREQS" || {
          bad "require_cmd drift: $owner requires undeclared $cmd"; drift=1
        }
    done < <(sed -n 's/^[[:space:]]*require_cmd[[:space:]]\+//p' "$installer" | tr ' ' '\n')
  done <"$INSTALLER_LIST"
else
  bad "require_cmd drift discovery failed"
  drift=1
fi
if [ "$drift_checked" -eq 0 ]; then
  bad "require_cmd drift check inspected no commands"
elif [ "$drift" = 0 ]; then
  ok "require_cmd declarations are represented in inventory"
fi
if awk -F '\t' '$1 == "devterm" && $2 == "definitely-not-declared" { found=1 } END { exit !found }' \
  "$ASSEMBLED_PREREQS"; then
  bad "require_cmd drift oracle accepted an undeclared command"
else
  ok "require_cmd drift oracle rejects an undeclared command"
fi
if discover_installers "$TMP/definitely-not-an-apps-directory" \
  >"$TMP/unexpected-installers" 2>/dev/null; then
  bad "require_cmd discovery oracle accepted a missing tree"
else
  ok "require_cmd discovery failures propagate"
fi

# Shared scripts also have literal require_cmd guards. Keep those represented
# by core declarations so a hub-only preflight cannot pass and fail later.
core_drift=0
core_drift_checked=0
for shared in "$ROOT/install/lib.sh" "$ROOT/bin/airlock-smoke"; do
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    core_drift_checked=$((core_drift_checked + 1))
    awk -F '\t' -v cmd="$cmd" \
      '$1 == "core" && $2 == cmd { found=1 } END { exit !found }' \
      "$ROOT/install/prerequisites.tsv" || {
        bad "shared require_cmd drift: core does not declare $cmd"; core_drift=1
      }
  done < <(sed -n 's/^[[:space:]]*require_cmd[[:space:]]\+//p' "$shared" | tr ' ' '\n')
done
if [ "$core_drift_checked" -eq 0 ]; then
  bad "shared require_cmd drift check inspected no commands"
elif [ "$core_drift" = 0 ]; then
  ok "shared require_cmd declarations are represented by core"
fi

inventory_has_requirement() {
  local owner="$1" cmd="$2"
  awk -F '\t' -v owner="$owner" -v cmd="$cmd" \
    '$1 == owner && $2 == cmd { found=1 } END { exit !found }' \
    "$ASSEMBLED_PREREQS"
}

discover_smokes() {
  find "$1" -type f -name smoke.sh -print0
}

smoke_drift=0
smoke_checked=0
SMOKE_LIST="$TMP/smoke-files"
if discover_smokes "$ROOT/apps" >"$SMOKE_LIST"; then
  while IFS= read -r -d '' smoke; do
    grep -Eq '(^|[^[:alnum:]_])curl([^[:alnum:]_]|$)' "$smoke" || continue
    smoke_checked=$((smoke_checked + 1))
    relative="${smoke#"$ROOT/apps/"}"
    owner="${relative%%/*}"
    inventory_has_requirement "$owner" curl || {
      bad "smoke drift: $owner uses undeclared curl"; smoke_drift=1
    }
  done <"$SMOKE_LIST"
else
  bad "smoke drift discovery failed"
  smoke_drift=1
fi
if [ "$smoke_checked" -eq 0 ]; then
  bad "smoke drift check inspected no curl users"
elif [ "$smoke_drift" = 0 ]; then
  ok "smoke command dependencies are represented in inventory"
fi
if inventory_has_requirement definitely-not-an-app curl; then
  bad "smoke drift oracle accepted an undeclared owner"
else
  ok "smoke drift oracle rejects an undeclared owner"
fi
if discover_smokes "$TMP/definitely-not-an-apps-directory" \
  >"$TMP/unexpected-smokes" 2>/dev/null; then
  bad "smoke discovery oracle accepted a missing tree"
else
  ok "smoke discovery failures propagate"
fi

# Run the real installer with a failed preflight. The target paths must remain
# absent, proving the failure happens before the first host mutation.
MUT="$TMP/mutation"; mkdir -p "$MUT"
mut_rc=0
mut_out="$(HOME="$TEST_HOME" PATH="$GAPS" AIRLOCK_CONFIG="$TMP/hub.toml" \
  AIRLOCK_DRY_RUN=1 AIRLOCK_WEBROOT="$MUT/web" AIRLOCK_CONFD="$MUT/confd" \
  /bin/bash "$ROOT/install/airlock-install.sh" 2>&1)" || mut_rc=$?
if [ "$mut_rc" = 1 ] && [ ! -e "$MUT/web" ] && [ ! -e "$MUT/confd" ] \
  && [[ "$mut_out" != *"installing hub"* ]]; then
  ok "failed installer preflight aborts before mutation"
else
  bad "installer crossed mutation boundary after failed preflight"
fi

# --- sbin fallback -----------------------------------------------------------
# nginx and nft live in the sbin directories, which are absent from an
# unprivileged PATH in some sessions (an agent session was the observed case,
# 2026-09-01). Before this fallback, preflight reported an installed and
# actively serving nginx as "missing" and the installer refused to run, telling
# the operator to apt-get install a package that was already there.
SBINFX="$TMP/sbinfx"; mkdir -p "$SBINFX"
make_stub "$SBINFX" faux-daemon
# shellcheck source=/dev/null
AIRLOCK_ROOT="$ROOT" . "$ROOT/install/preflight.sh"

# shellcheck disable=SC2034  # consumed by airlock_preflight_find, sourced above
AIRLOCK_PREFLIGHT_SBIN_DIRS="$SBINFX"
found="$(PATH="/nonexistent" airlock_preflight_find faux-daemon)" || found=""
if [ "$found" = "$SBINFX/faux-daemon" ]; then
  ok "preflight finds a daemon that is only in an sbin dir"
else
  bad "preflight missed an sbin-only daemon (got '${found:-<none>}')"
fi

# PATH still wins, so an operator override is not silently discarded.
PATHFX="$TMP/pathfx"; mkdir -p "$PATHFX"
make_stub "$PATHFX" faux-daemon
found="$(PATH="$PATHFX" airlock_preflight_find faux-daemon)" || found=""
if [ "$found" = "$PATHFX/faux-daemon" ]; then
  ok "PATH still takes precedence over the sbin fallback"
else
  bad "sbin fallback overrode PATH (got '${found:-<none>}')"
fi

# A genuinely absent command must still be absent -- the fallback must not
# turn every miss into a hit.
if PATH="/nonexistent" airlock_preflight_find no-such-daemon-anywhere \
  >/dev/null 2>&1; then
  bad "preflight reported a command that exists nowhere"
else
  ok "a command that exists nowhere is still reported missing"
fi

# The list is assigned unconditionally when preflight.sh is sourced, so an
# ambient value cannot redirect daemon discovery in a production run.
if out="$(AIRLOCK_PREFLIGHT_SBIN_DIRS="$SBINFX" AIRLOCK_ROOT="$ROOT" /bin/bash -c \
  '. "$1/install/preflight.sh"; printf %s "$AIRLOCK_PREFLIGHT_SBIN_DIRS"' _ "$ROOT")" \
  && [ "$out" = "/usr/local/sbin /usr/sbin /sbin" ]; then
  ok "an ambient sbin list does not reach production discovery"
else
  bad "ambient AIRLOCK_PREFLIGHT_SBIN_DIRS survived sourcing (got '$out')"
fi

echo "---"; echo "passed=$pass failed=$fail"; [ "$fail" -eq 0 ]
