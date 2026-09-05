#!/usr/bin/env bash
# Proves the private release contract at the consumer boundary: airlock.toml
# and packages/<id> move as one byte-identical bundle, while a partial copy is
# rejected once, before validate or hub installation can mutate a clean box.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 1

pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
CFG="$ROOT/bin/airlock-config"
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

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
  ok "package-info resolves every relative package under the relocated config"
else
  bad "relocated package-info failed (rc=$pkginfo_rc): $(head -1 "$scratch/positive-package-info.err")"
fi

# Keep the real orchestrator and preflight, but make command availability
# independent of the host image. AIRLOCK_DRY_RUN means none of these shims is
# invoked for a mutation; they only satisfy core prerequisite discovery.
shim="$scratch/shim"
mkdir -p "$shim"
for cmd in nginx sudo systemctl tailscale curl; do
  printf '#!/usr/bin/env bash\nexit 0\n' >"$shim/$cmd"
  chmod +x "$shim/$cmd"
done

positive_root="$scratch/positive-box"
mkdir -p "$positive_root/home" "$positive_root/state" "$positive_root/web" \
  "$positive_root/confd" "$positive_root/user-units" "$positive_root/system-units"
positive_out="$(HOME="$positive_root/home" \
  AIRLOCK_CONFIG="$relocated_bundle/airlock.toml" \
  AIRLOCK_SHIPPED_APPS_ROOT="$empty_shipped" \
  AIRLOCK_STATE_DIR="$positive_root/state" \
  AIRLOCK_WEBROOT="$positive_root/web" \
  AIRLOCK_CONFD="$positive_root/confd" \
  AIRLOCK_NGINX_SITE="$positive_root/nginx-site.conf" \
  AIRLOCK_UNIT_DIR_USER="$positive_root/user-units" \
  AIRLOCK_UNIT_DIR_SYSTEM="$positive_root/system-units" \
  AIRLOCK_TS_FQDN="clean-box.example.ts.net" \
  AIRLOCK_DRY_RUN=1 PATH="$shim:$PATH" \
  bash "$ROOT/install/airlock-install.sh" 2>&1)"
positive_rc=$?
if [ "$positive_rc" -eq 0 ] \
   && grep -Fq "done (dry run — nothing was changed)" <<<"$positive_out" \
   && grep -Fq "would install packaged app: alpha from $relocated_bundle/packages/alpha" <<<"$positive_out" \
   && grep -Fq "would install packaged app: mu from $relocated_bundle/packages/mu" <<<"$positive_out" \
   && grep -Fq "would install packaged app: zed from $relocated_bundle/packages/zed" <<<"$positive_out"; then
  ok "relocated bundle reaches the real dry orchestrator's final marker"
else
  bad "relocated dry orchestrator failed (rc=$positive_rc): $(tail -5 <<<"$positive_out" | tr '\n' ' ')"
fi

# A structural error still wins immediately, even when an earlier sorted id
# has a missing directory. Aggregation applies only to otherwise-valid paths.
sed 's|path = "packages/mu"|path = 17|' \
  "$broken_bundle/airlock.toml" >"$broken_bundle/structural.toml"
structural_out="$(HOME="$scratch/structural-home" \
  AIRLOCK_CONFIG="$broken_bundle/structural.toml" \
  AIRLOCK_SHIPPED_APPS_ROOT="$empty_shipped" \
  python3 "$CFG" package-info 2>&1)"
structural_rc=$?
if [ "$structural_rc" -ne 0 ] \
   && grep -Fq "[packages.mu].path must be a non-empty path string" <<<"$structural_out" \
   && ! grep -Fq "one or more packages" <<<"$structural_out"; then
  ok "structural package errors remain fail-fast ahead of path aggregation"
else
  bad "structural error did not remain fail-fast (rc=$structural_rc): $structural_out"
fi

# The broken bundle is the same config bytes with all three payload directories
# absent. Run the actual dry orchestrator to prove package-info stops it before
# the validate/hub boundary and leaves a clean-box filesystem unchanged.
negative_root="$scratch/negative-box"
mkdir -p "$negative_root/home" "$negative_root/state" "$negative_root/web" \
  "$negative_root/confd" "$negative_root/user-units" "$negative_root/system-units" \
  "$negative_root/tmp"
printf 'canary\n' >"$negative_root/home/canary"
find "$negative_root" -type f -exec sha256sum {} + | sort >"$scratch/negative-before.sums"
negative_out="$(HOME="$negative_root/home" TMPDIR="$negative_root/tmp" \
  AIRLOCK_CONFIG="$broken_bundle/airlock.toml" \
  AIRLOCK_SHIPPED_APPS_ROOT="$empty_shipped" \
  AIRLOCK_STATE_DIR="$negative_root/state" \
  AIRLOCK_WEBROOT="$negative_root/web" \
  AIRLOCK_CONFD="$negative_root/confd" \
  AIRLOCK_NGINX_SITE="$negative_root/nginx-site.conf" \
  AIRLOCK_UNIT_DIR_USER="$negative_root/user-units" \
  AIRLOCK_UNIT_DIR_SYSTEM="$negative_root/system-units" \
  AIRLOCK_TS_FQDN="clean-box.example.ts.net" \
  AIRLOCK_DRY_RUN=1 PATH="$shim:$PATH" \
  bash "$ROOT/install/airlock-install.sh" 2>&1)"
negative_rc=$?
find "$negative_root" -type f -exec sha256sum {} + | sort >"$scratch/negative-after.sums"

if [ "$negative_rc" -eq 2 ] && python3 - "$broken_bundle" "$negative_out" <<'PY'
import pathlib
import sys

bundle = pathlib.Path(sys.argv[1]).resolve()
text = sys.argv[2]
header = "[packages.*].path does not resolve to a directory for one or more packages:"
if text.count(header) != 1:
    raise SystemExit("missing-path header was absent or repeated")
expected = [
    f"  - id={package_id!r} raw={'packages/' + package_id!r} "
    f"resolved={str(bundle / 'packages' / package_id)!r}"
    for package_id in ("alpha", "mu", "zed")
]
try:
    positions = [text.index(line) for line in expected]
except ValueError as exc:
    raise SystemExit("a missing package coordinate was not reported") from exc
if positions != sorted(positions):
    raise SystemExit("missing package coordinates were not sorted by id")
if any(text.count(line) != 1 for line in expected):
    raise SystemExit("a missing package coordinate was repeated")
PY
then
  ok "three missing paths are reported once with sorted id/raw/resolved coordinates"
else
  bad "missing-path report was incomplete or unstable (rc=$negative_rc): $negative_out"
fi

if cmp -s "$scratch/negative-before.sums" "$scratch/negative-after.sums" \
   && ! grep -Fq "validating airlock.toml" <<<"$negative_out" \
   && ! grep -Fq "installing hub" <<<"$negative_out"; then
  ok "missing paths stop before validate/hub and leave clean-box files unchanged"
else
  bad "missing paths reached mutation boundary or changed clean-box files"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
