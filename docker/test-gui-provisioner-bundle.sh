#!/usr/bin/env bash
# Offline contract test for the GUI provisioner bundle/profile.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

pass=0
fail=0
ok() { printf 'ok   gui-bundle: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL gui-bundle: %s\n' "$1"; fail=$((fail + 1)); }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
base_sha="$(git -C "$ROOT" rev-parse HEAD)"

# Exercise the scripts from a clean temporary repository while the source tree is
# still uncommitted during development. The bundle input itself remains that repo's
# committed HEAD; only the builder and its independent provisioner inputs are overlaid.
git clone -q --shared --no-checkout "$ROOT" "$repo" \
  || { echo "FAIL gui-bundle: could not make temporary repository" >&2; exit 2; }
git -C "$repo" checkout -q --detach "$base_sha" \
  || { echo "FAIL gui-bundle: could not check out HEAD" >&2; exit 2; }
install -m 0644 "$HERE/build-gui-provisioner-bundle.sh" "$repo/docker/build-gui-provisioner-bundle.sh"
install -m 0644 "$HERE/gui-default-profile.json" "$repo/docker/gui-default-profile.json"
install -m 0644 "$HERE/gui-provisioner.sh" "$repo/docker/gui-provisioner.sh"
install -m 0644 "$HERE/gui-version-relation.py" "$repo/docker/gui-version-relation.py"
install -m 0644 "$HERE/gui-provisioner-entrypoint.sh" "$repo/docker/gui-provisioner-entrypoint.sh"
install -m 0644 "$HERE/gui-installer.py" "$repo/docker/gui-installer.py"
install -m 0644 "$HERE/gui_installer_core.py" "$repo/docker/gui_installer_core.py"
install -m 0644 "$HERE/gui_selection.py" "$repo/docker/gui_selection.py"
install -m 0644 "$HERE/org.airlock.Installer.desktop" "$repo/docker/org.airlock.Installer.desktop"
install -m 0644 "$HERE/org.airlock.Installer.policy" "$repo/docker/org.airlock.Installer.policy"
# Development runs happen before these files have a repository revision. Make that
# exact candidate a temporary commit so the builder still consumes committed bytes;
# after merge this also proves omission of the guest runner from the archive.
git -C "$repo" add docker/build-gui-provisioner-bundle.sh docker/gui-default-profile.json \
  docker/gui-provisioner.sh docker/gui-version-relation.py \
  docker/gui-provisioner-entrypoint.sh docker/gui-installer.py docker/gui_installer_core.py
git -C "$repo" add docker/gui_selection.py
git -C "$repo" add docker/org.airlock.Installer.desktop docker/org.airlock.Installer.policy
if ! git -C "$repo" diff --cached --quiet; then
  git -C "$repo" -c user.name=gui-bundle-test -c user.email=gui-bundle-test@example.invalid \
    commit -q -m 'gui bundle test candidate'
fi
source_sha="$(git -C "$repo" rev-parse HEAD)"

one="$scratch/one.tgz"
two="$scratch/two.tgz"
if (umask 022; bash "$repo/docker/build-gui-provisioner-bundle.sh" \
    --output "$one" --revision HEAD \
    >"$scratch/build-one.out" 2>"$scratch/build-one.err"); then
  ok "builds the committed HEAD in a temporary repository"
else
  bad "could not build HEAD: $(tail -1 "$scratch/build-one.err")"
fi

extract="$scratch/extract"
mkdir -p "$extract"
if [ -f "$one" ] && tar -xzf "$one" -C "$extract" \
    && [ -f "$extract/airlock/gui-provisioner-manifest.json" ] \
    && [ -f "$extract/airlock/docker/gui-provisioner.sh" ] \
    && [ -f "$extract/airlock/docker/gui-provisioner-entrypoint.sh" ] \
    && [ -f "$extract/airlock/docker/gui-installer.py" ] \
    && [ -f "$extract/airlock/docker/gui_selection.py" ] \
    && [ -f "$extract/airlock/docker/gui-version-relation.py" ] \
    && bash -n "$extract/airlock/docker/gui-provisioner.sh"; then
  ok "archive contains the manifest and runnable provisioner/version gate"
else
  bad "archive is missing its manifest/provisioner/version gate or cannot be extracted"
fi

if python3 - "$extract/airlock" "$source_sha" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
want_sha = sys.argv[2]
manifest = json.loads((root / "gui-provisioner-manifest.json").read_text(encoding="utf-8"))
profile_path = root / manifest["profile_path"]
profile_bytes = profile_path.read_bytes()
catalog_path = root / manifest["catalog_path"]
catalog_bytes = catalog_path.read_bytes()
assert manifest["schema"] == "airlock.gui-provisioner-bundle/v1"
assert manifest["source_sha"] == want_sha and len(want_sha) == 40
assert isinstance(manifest["source_epoch"], int) and manifest["source_epoch"] > 0
assert manifest["profile_path"] == "docker/gui-default-profile.json"
assert manifest["profile_sha256"] == hashlib.sha256(profile_bytes).hexdigest()
assert manifest["catalog_path"] == "docker/gui-catalog.json"
assert manifest["catalog_sha256"] == hashlib.sha256(catalog_bytes).hexdigest()
profile = json.loads(profile_bytes)
assert profile == {
    "schema": "airlock.gui-default-profile/v1",
    "always": ["hub"],
    "required": ["devterm", "fileview", "publish"],
    "default": ["paseo"],
    "install": ["devterm", "fileview", "publish", "paseo"],
}
catalog = json.loads(catalog_bytes)
catalog_ids = {app["id"] for app in catalog["apps"]}
assert {"devterm", "fileview", "publish", "paseo"} <= catalog_ids
assert catalog.get("unavailable") == []
PY
then
  ok "manifest binds the full source SHA and exact profile/catalog digests"
else
  bad "manifest/profile contract is wrong"
fi

public_repo="$scratch/public-repo"
cp -a "$extract/airlock" "$public_repo"
rm -f "$public_repo/gui-provisioner-manifest.json"
git -C "$public_repo" init -q
git -C "$public_repo" add .
git -C "$public_repo" -c core.hooksPath=/dev/null \
  -c user.name=gui-bundle-test -c user.email=gui-bundle-test@example.invalid \
  commit -q -m 'public export fixture' \
  || { echo "FAIL gui-bundle: could not commit public fixture" >&2; exit 2; }
if bash "$public_repo/docker/build-gui-provisioner-bundle.sh" --public-export \
    --output "$scratch/public.tgz" --revision HEAD >/dev/null 2>"$scratch/public.err" \
  && tar -tzf "$scratch/public.tgz" >/dev/null; then
  ok "explicit public-export mode builds an already-pruned public tree"
else
  bad "public-export mode failed: $(tail -1 "$scratch/public.err")"
fi

if bash "$repo/docker/build-gui-provisioner-bundle.sh" --public-export \
    --output "$scratch/private-as-public.tgz" --revision HEAD \
    >"$scratch/private-as-public.out" 2>"$scratch/private-as-public.err"; then
  bad "public-export mode accepted a private source tree"
elif grep -q 'private marker' "$scratch/private-as-public.err"; then
  ok "public-export mode refuses a private tree instead of skipping its gate"
else
  bad "private-tree public-export refusal was not actionable"
fi

if [ ! -e "$extract/airlock/mac" ] \
    && [ ! -e "$extract/airlock/docs/tasks" ] \
    && [ -f "$extract/airlock/bin/airlock-config" ]; then
  ok "private paths are pruned and the runnable public config tool remains"
else
  bad "public-manifest pruning produced the wrong tree"
fi

config="$scratch/generated.toml"
if (cd "$extract/airlock" \
    && python3 bin/airlock-config init --owner owner@fixture.dev \
         --apps devterm,fileview,publish,paseo > "$config" \
    && AIRLOCK_CONFIG="$config" python3 bin/airlock-config validate >/dev/null) \
  && python3 - "$config" <<'PY'
import pathlib, sys, tomllib
cfg = tomllib.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert set(cfg.get("apps", {})) == {"hub", "devterm", "fileview", "publish", "paseo"}
PY
then
  ok "profile generates and validates exactly hub/devterm/fileview/publish/paseo"
else
  bad "generated default-five config did not validate exactly"
fi

if (umask 077; bash "$repo/docker/build-gui-provisioner-bundle.sh" \
    --output "$two" --revision HEAD \
    >"$scratch/build-two.out" 2>"$scratch/build-two.err") \
  && cmp -s "$one" "$two"; then
  ok "two builds under umask 022/077 are byte-identical"
else
  bad "repeated build was not deterministic"
fi

if bash "$repo/docker/build-gui-provisioner-bundle.sh" --output "$one" --revision HEAD \
    >"$scratch/existing.out" 2>"$scratch/existing.err"; then
  bad "builder replaced an existing output"
elif grep -q "refusing to replace existing output" "$scratch/existing.err"; then
  ok "builder refuses an existing output"
else
  bad "existing-output refusal was not actionable"
fi

python3 - "$repo/docker/gui-default-profile.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
profile = json.loads(path.read_text(encoding="utf-8"))
profile["default"] = []
path.write_text(json.dumps(profile) + "\n", encoding="utf-8")
PY
if bash "$repo/docker/build-gui-provisioner-bundle.sh" \
    --output "$scratch/drift.tgz" --revision HEAD \
    >"$scratch/drift.out" 2>"$scratch/drift.err"; then
  bad "builder accepted profile drift"
elif grep -q "profile drifted" "$scratch/drift.err"; then
  ok "builder rejects profile drift before packaging"
else
  bad "profile drift failed without the expected diagnostic"
fi

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
