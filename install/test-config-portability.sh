#!/usr/bin/env bash
# Relocated external payloads resolve only through explicit installed records.
# Missing recorded sources fail before hooks, and dry apply has no file effects.
set -uo pipefail
. "$(dirname "$0")/test-lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 1

airlock_test_counters_init

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
CFG="$ROOT/bin/airlock-config"
export HOME="$scratch/home" AIRLOCK_STATE_DIR="$scratch/state" XDG_CONFIG_HOME="$scratch/xdg"
mkdir -p "$HOME"
airlock_set_fixture_root "$scratch"
airlock_pin_paseo_mem

make_package() {
  local dir="$1" id="$2"
  mkdir -p "$dir"
  cat >"$dir/airlock-app.toml" <<EOF
contract = 1
id = "$id"
EOF
  # Explicit packages are deliberately not executed by a dry run. A loud
  # exit makes that safety property observable in the relocation oracle.
  printf '#!/usr/bin/env bash\nexit 97\n' >"$dir/install.sh"
  printf '#!/usr/bin/env bash\nexit 97\n' >"$dir/smoke.sh"
  chmod +x "$dir/install.sh" "$dir/smoke.sh"
}

source_bundle="$scratch/source-bundle"
relocated_bundle="$scratch/relocated/bundle"
broken_bundle="$scratch/broken/bundle"
mkdir -p "$source_bundle/packages" "$relocated_bundle" "$broken_bundle"
make_package "$source_bundle/packages/alpha" alpha
make_package "$source_bundle/packages/mu" mu
make_package "$source_bundle/packages/zed" zed
cat >"$source_bundle/airlock.toml" <<'EOF'
[site]
name = "PortableBundle"

[auth]
provider = "tailscale"
owner = "operator@sample.dev"

[apps.hub]
[apps.alpha]
[apps.mu]
[apps.zed]

[packages.alpha]
path = "packages/alpha"
[packages.mu]
path = "packages/mu"
[packages.zed]
path = "packages/zed"
EOF

# The release handoff is a directory relocation, not a config rewrite.
cp -a "$source_bundle/." "$relocated_bundle/"
cp "$source_bundle/airlock.toml" "$broken_bundle/airlock.toml"
if cmp -s "$source_bundle/airlock.toml" "$relocated_bundle/airlock.toml" \
   && diff -qr "$source_bundle/packages" "$relocated_bundle/packages" >/dev/null; then
  ok "relocation keeps the config and package payload byte-identical"
else
  bad "relocation changed bundle bytes"
fi

empty_shipped="$scratch/no-shipped-apps"
foreign_cwd="$scratch/foreign-cwd"
mkdir -p "$empty_shipped" "$foreign_cwd"
seed_bundle() {
  env -u AIRLOCK_APP_ID -u AIRLOCK_APP_DIR python3 - "$ROOT/bin/airlock-ledger" "$1" <<'PY_SEED'
from importlib.machinery import SourceFileLoader
from pathlib import Path
import sys
sys.dont_write_bytecode = True
ledger = SourceFileLoader("_portable_fixture_ledger", sys.argv[1]).load_module()
bundle = Path(sys.argv[2]).resolve()
ledger.write_installed({pid: {"repo": str(bundle / "packages" / pid), "commit": "", "artifacts": []}
                       for pid in ("alpha", "mu", "zed")})
PY_SEED
}
seed_bundle "$relocated_bundle"
pkginfo="$(cd "$foreign_cwd" && HOME="$scratch/positive-home" \
  AIRLOCK_CONFIG="$relocated_bundle/airlock.toml" \
  AIRLOCK_SHIPPED_APPS_ROOT="$empty_shipped" \
  python3 "$CFG" package-info 2>"$scratch/positive-package-info.err")"
pkginfo_rc=$?
printf '%s' "$pkginfo" >"$scratch/positive-package-info.json"
if [ "$pkginfo_rc" -eq 0 ] \
   && python3 - "$relocated_bundle" "$scratch/positive-package-info.json" <<'PY'
import json
import pathlib
import sys

bundle = pathlib.Path(sys.argv[1]).resolve()
with open(sys.argv[2], encoding="utf-8") as handle:
    doc = json.load(handle)
if pathlib.Path(doc["config_path"]) != bundle / "airlock.toml":
    raise SystemExit("package-info kept the pre-relocation config path")
if sorted(doc["packages"]) != ["alpha", "mu", "zed"]:
    raise SystemExit("package-info did not contain the three relocated packages")
for package_id, package in doc["packages"].items():
    if pathlib.Path(package["dir"]) != bundle / "packages" / package_id:
        raise SystemExit(f"{package_id}: package path escaped the relocated bundle")
PY
then
  ok "package-info uses the recorded absolute directories after relocation"
else
  bad "relocated package-info failed (rc=$pkginfo_rc): $(head -1 "$scratch/positive-package-info.err")"
fi

# Selected dry ingress preserves recorded sources and never executes exit-97 hooks.
positive_before="$(find "$scratch/state" -type f -exec sha256sum {} + | sort)"
positive_out="$(AIRLOCK_CONFIG="$relocated_bundle/airlock.toml" AIRLOCK_DRY_RUN=1 \
  "$ROOT/bin/airlock-ledger" apply alpha 2>&1)"; positive_rc=$?
if [ "$positive_rc" = 0 ] && grep -Fq '[dry]' <<<"$positive_out" \
   && [ "$positive_before" = "$(find "$scratch/state" -type f -exec sha256sum {} + | sort)" ]; then
  ok "recorded relocated app reaches selected dry apply without hook or record changes"
else
  bad "recorded source dry apply failed or changed records (rc=$positive_rc): $positive_out"
fi

# Mutation commands remain scratch shims even when source resolution fails early.
shim="$scratch/shim"
mkdir -p "$shim"
for command in sudo systemctl tailscale nginx curl; do
  printf '#!/usr/bin/env bash\nexit 97\n' >"$shim/$command"
  chmod +x "$shim/$command"
done
export PATH="$shim:$PATH"

# Missing candidate paths are inert; record a missing source to test actual failure.
negative_root="$scratch/negative-box"
mkdir -p "$negative_root/home" "$negative_root/state" "$negative_root/tmp"
printf 'canary\n' >"$negative_root/home/canary"
AIRLOCK_STATE_DIR="$negative_root/state" seed_bundle "$broken_bundle"
find "$negative_root" -type f -exec sha256sum {} + | sort >"$scratch/negative-before.sums"
negative_out="$(HOME="$negative_root/home" TMPDIR="$negative_root/tmp" \
  AIRLOCK_CONFIG="$broken_bundle/airlock.toml" \
  AIRLOCK_STATE_DIR="$negative_root/state" \
  AIRLOCK_WEBROOT="$negative_root/web" AIRLOCK_CONFD="$negative_root/confd" \
  AIRLOCK_UNIT_DIR_USER="$negative_root/units-user" AIRLOCK_UNIT_DIR_SYSTEM="$negative_root/units-system" \
  AIRLOCK_NGINX_SITE="$negative_root/nginx-site.conf" \
  "$ROOT/bin/airlock-ledger" apply alpha 2>&1)"; negative_rc=$?
find "$negative_root" -type f -exec sha256sum {} + | sort >"$scratch/negative-after.sums"
if [ "$negative_rc" -ne 0 ] && grep -Fq 'recorded source for alpha is missing' <<<"$negative_out" \
   && cmp -s "$scratch/negative-before.sums" "$scratch/negative-after.sums"; then
  ok "missing recorded source fails before its hook and leaves clean-box files unchanged"
else
  bad "missing recorded source failure or filesystem isolation failed: $negative_out"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
