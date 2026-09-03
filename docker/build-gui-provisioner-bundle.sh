#!/usr/bin/env bash
# Build the public Airlock tree consumed by the GUI provisioner, plus the exact
# default-five profile that selected it. The source revision and profile are two
# independently pinned inputs and both are recorded in the bundle manifest.
set -euo pipefail
# `tar -x` applies the caller's umask unless preservation is requested. Fix the
# build umask up front so archive extraction, generated metadata and the final
# output have the same modes whether the caller uses 022, 077 or something else.
umask 022

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PROFILE="$HERE/gui-default-profile.json"

usage() {
  echo "usage: $0 --output FILE [--revision REVISION] [--public-export]" >&2
  exit 2
}

output=""
revision="HEAD"
seen_output=0
seen_revision=0
public_export=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || usage
      [ "$seen_output" = 0 ] || usage
      output="$2"; seen_output=1; shift 2 ;;
    --revision)
      [ "$#" -ge 2 ] || usage
      [ "$seen_revision" = 0 ] || usage
      revision="$2"; seen_revision=1; shift 2 ;;
    --public-export)
      [ "$public_export" = 0 ] || usage
      public_export=1; shift ;;
    *) usage ;;
  esac
done
[ -n "$output" ] || usage

if [ -e "$output" ] || [ -L "$output" ]; then
  echo "gui bundle: refusing to replace existing output: $output" >&2
  exit 1
fi
[ -f "$PROFILE" ] || { echo "gui bundle: profile not found: $PROFILE" >&2; exit 1; }

source_sha="$(git -C "$ROOT" rev-parse --verify "${revision}^{commit}" 2>/dev/null)" \
  || { echo "gui bundle: revision is not a commit: $revision" >&2; exit 1; }
source_epoch="$(git -C "$ROOT" show -s --format=%ct "$source_sha")"
case "$source_epoch" in *[!0-9]*|'') echo "gui bundle: source commit has no valid timestamp" >&2; exit 1 ;; esac

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export_root="$scratch/airlock"
mkdir -p "$export_root"

# The release input is committed bytes only. The profile is deliberately a
# separate build input: the manifest binds its digest next to the source SHA.
git -C "$ROOT" archive --format=tar "$source_sha" \
  | tar -xf - -C "$export_root"

if [ "$public_export" = 1 ]; then
  # The public mirror has already crossed the private manifest boundary, so that
  # private-only checker is intentionally absent there. This mode is explicit and
  # refuses a private checkout instead of quietly skipping its audience gate.
  for private_marker in install/public-manifest.sh .github mac docs/tasks; do
    if [ -e "$export_root/$private_marker" ] || [ -L "$export_root/$private_marker" ]; then
      echo "gui bundle: --public-export received a tree with private marker: $private_marker" >&2
      exit 1
    fi
  done
else
  prune_list="$scratch/prune-list"
  # `--prune-list` intentionally prints only private paths; by itself it would leave
  # an unclassified path in the release. Check the complete archived tree first, then
  # prune that same tree, so neither omission nor over-sharing is silent.
  bash "$export_root/install/public-manifest.sh" --check --dir "$export_root" >/dev/null
  bash "$export_root/install/public-manifest.sh" --prune-list --dir "$export_root" \
    > "$prune_list"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in /*|../*|*/../*|*/..) echo "gui bundle: unsafe prune path: $path" >&2; exit 1 ;; esac
    rm -f -- "$export_root/$path"
  done < "$prune_list"
  find "$export_root" -depth -type d -empty -delete
fi

# Profile validation is intentionally exact. A new app or a changed default is a
# product decision, not something a release should infer from a nearby catalog.
install -D -m 0644 "$PROFILE" "$export_root/docker/gui-default-profile.json"
catalog="$scratch/catalog.json"
(cd "$export_root" && AIRLOCK_CONFIG=/dev/null python3 bin/airlock-config catalog) \
  > "$catalog"
install -m 0644 "$catalog" "$export_root/docker/gui-catalog.json"
python3 - "$export_root/docker/gui-default-profile.json" "$catalog" <<'PY'
import json
import pathlib
import sys

profile_path, catalog_path = map(pathlib.Path, sys.argv[1:])
try:
    profile = json.loads(profile_path.read_text(encoding="utf-8"))
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"gui bundle: profile/catalog is not readable JSON: {exc}")

expected = {
    "schema": "airlock.gui-default-profile/v1",
    "always": ["hub"],
    "required": ["devterm", "fileview", "publish"],
    "default": ["paseo"],
    "install": ["devterm", "fileview", "publish", "paseo"],
}
if profile != expected:
    raise SystemExit("gui bundle: profile drifted from the approved default-five contract")

if catalog.get("unavailable"):
    raise SystemExit("gui bundle: catalog contains unavailable apps")
apps = catalog.get("apps")
if not isinstance(apps, list) or not apps:
    raise SystemExit("gui bundle: catalog app list is empty or invalid")
catalog_ids = set()
for app in apps:
    if not isinstance(app, dict) or not isinstance(app.get("id"), str):
        raise SystemExit("gui bundle: catalog contains an invalid app entry")
    if app["id"] in catalog_ids:
        raise SystemExit("gui bundle: catalog contains a duplicate app id")
    arch = app.get("arch") or []
    if not isinstance(arch, list) or any(not isinstance(value, str) for value in arch):
        raise SystemExit("gui bundle: catalog contains an invalid architecture list")
    catalog_ids.add(app["id"])
missing = sorted(set(profile["install"]) - catalog_ids)
if missing:
    raise SystemExit("gui bundle: profile app(s) absent from catalog: " + ", ".join(missing))
PY

apps_csv="$(python3 - "$export_root/docker/gui-default-profile.json" <<'PY'
import json, pathlib, sys
print(",".join(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["install"]))
PY
)"
validation_config="$scratch/airlock.toml"
(cd "$export_root" && python3 bin/airlock-config init \
  --owner gui-installer-validation@example.invalid --apps "$apps_csv") \
  > "$validation_config"
(cd "$export_root" && AIRLOCK_CONFIG="$validation_config" \
  python3 bin/airlock-config validate >/dev/null)

profile_sha="$(sha256sum "$export_root/docker/gui-default-profile.json" | awk '{print $1}')"
catalog_sha="$(sha256sum "$export_root/docker/gui-catalog.json" | awk '{print $1}')"
python3 - "$export_root/gui-provisioner-manifest.json" "$source_sha" \
  "$source_epoch" "$profile_sha" "$catalog_sha" <<'PY'
import json
import pathlib
import sys

path, source_sha, source_epoch, profile_sha, catalog_sha = sys.argv[1:]
manifest = {
    "schema": "airlock.gui-provisioner-bundle/v1",
    "source_sha": source_sha,
    "source_epoch": int(source_epoch),
    "profile_path": "docker/gui-default-profile.json",
    "profile_sha256": profile_sha,
    "catalog_path": "docker/gui-catalog.json",
    "catalog_sha256": catalog_sha,
}
pathlib.Path(path).write_text(
    json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
)
PY

output_parent="$(dirname "$output")"
mkdir -p "$output_parent"
partial="$output_parent/.gui-provisioner-bundle.$$.tmp"
trap 'rm -rf "$scratch"; rm -f "$partial"' EXIT
tar --sort=name --format=gnu --mtime="@$source_epoch" \
  --owner=0 --group=0 --numeric-owner -C "$scratch" -cf - airlock \
  | gzip -n > "$partial"
if ! ln -- "$partial" "$output" 2>/dev/null; then
  echo "gui bundle: output appeared while building; refusing to replace it: $output" >&2
  exit 1
fi
rm -f "$partial"
trap 'rm -rf "$scratch"' EXIT
printf 'gui bundle: wrote %s (source %s, profile %s)\n' \
  "$output" "$source_sha" "$profile_sha"
