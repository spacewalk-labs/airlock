#!/usr/bin/env bash
# Tests bin/airlock-update — the path that brings an already-installed box up to the
# released tree.
#
# Why this suite is worth its length: the script rewrites files in place on someone
# else's machine, and every way it can hurt them is silent.
#
#   1. It can destroy work. The operator's airlock.toml, their own files, and their
#      uncommitted edits must all survive. A run that quietly lost any of them would
#      still print "갱신했습니다" and still reach a working entrance.
#   2. On a Mac it can update the WRONG machine. docker/orbstack-machine-setup.sh
#      defaults to a machine called `airlock`, but the install guide has each operator
#      name theirs, so a default-named run does not update their box — it creates a
#      SECOND one and installs into that.
#   3. Its own safety net can fail and say nothing. The recovery it prints is only
#      worth the commit it points at.
#
# Four of the checks below exist because an adversarial review found the defect first
# and the suite passed anyway; each is marked with what it caught.
#
# The Mac branch cannot run on the Linux runner, so it is reached through the
# AIRLOCK_UPDATE_UNAME seam with a stub `orb` on PATH. The stub keys on the MARKER
# PATH, not just the machine name — keying on the name let the marker be replaced with
# a nonsense path while the suite stayed green.
#
# Offline: the "release" is a local git repository, reached as a path. No network.
set -uo pipefail
. "$(dirname "$0")/test-lib.sh"
airlock_pin_paseo_mem

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
UPDATE="$ROOT/bin/airlock-update"

airlock_test_counters_init

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
chmod 700 "$scratch"
airlock_set_fixture_root "$scratch"
mkdir -p "$scratch/home" "$scratch/state"
export HOME="$scratch/home" AIRLOCK_STATE_DIR="$scratch/state"
# This suite exercises update semantics, not the cgroup transport (that has its own
# focused fixture).  Pin a neutral cgroup so the host running the test cannot make
# every case escape through the suite's unrelated systemd-run shims.
airlock_neutral_selfkill_cgroup "$scratch"
export GIT_CONFIG_GLOBAL="$scratch/gitconfig"   # never read the runner's identity
export GIT_CONFIG_NOSYSTEM=1
git config -f "$GIT_CONFIG_GLOBAL" user.name  airlock-test
git config -f "$GIT_CONFIG_GLOBAL" user.email airlock-test@localhost
git config -f "$GIT_CONFIG_GLOBAL" init.defaultBranch main

# A5 for git: 41 of the 45 `bash "$UPDATE"` calls below pass no AIRLOCK_DIR on
# purpose (they exercise the no-AIRLOCK_DIR path), and bin/airlock-update then
# resolves ROOT to the checkout this script was started from and snapshots ITS
# history there. Record where we started, refuse any git write aimed at this
# checkout, and prove the guard is really installed before trusting it.
_p3e_guard_head="$(git -C "$ROOT" rev-parse HEAD)"
_p3e_guard_dirty="$(git -C "$ROOT" status --porcelain)"
airlock_guard_checkout_writes "$ROOT" "$scratch/guard"
if airlock_check_guard_fires "$ROOT" "guard self-test"; then
  ok "the git write guard refuses a commit aimed at this checkout (A5)"
  p3e_guard=1
else
  bad "the git write guard is NOT installed — this suite can commit into the checkout"
  p3e_guard=0
fi

# ---------------------------------------------------------------- fixtures
seed_tree() {   # seed_tree <dir> <marker>
  local d="$1" m="$2"
  mkdir -p "$d/bin" "$d/install" "$d/docker" "$d/apps/hub" "$d/examples/app-package"
  cp "$ROOT/bin/airlock-ledger" "$d/bin/airlock-ledger"
  printf '#!/bin/sh\n# %s\n' "$m" > "$d/bin/airlock-config"
  printf '#!/bin/sh\necho installed\n'                     > "$d/install/airlock-install.sh"
  printf '#!/bin/sh\necho "MACHINE=${AIRLOCK_MACHINE:-}"\n' > "$d/docker/orbstack-machine-setup.sh"
  printf 'version %s\n' "$m"                               > "$d/README.md"
  printf 'hub %s\n' "$m"                                   > "$d/apps/hub/manifest"
  # The real .gitignore's shape, including the negation that a 3-week-old box does NOT
  # have. That difference is the whole point of the at-risk pass.
  printf 'airlock.toml\nairlock.lock\n!examples/app-package/airlock.toml\n' > "$d/.gitignore"
  printf 'example config %s\n' "$m" > "$d/examples/app-package/airlock.toml"
}

REL="$scratch/release"
seed_tree "$REL" old
printf 'airlock.toml\n' > "$REL/.gitignore"
git -C "$REL" init -q -b main
git -C "$REL" add -A
git -C "$REL" commit -q -m "release old-ignore"
seed_tree "$REL" old
git -C "$REL" add -A
git -C "$REL" commit -q -m "release old"
seed_tree "$REL" new
printf 'brand new file\n' > "$REL/NOTICE"
git -C "$REL" add -A
git -C "$REL" commit -q -m "release new"

# The installed box, in the shape the install guide actually produces: the tree at an
# older revision, `git init`ed and committed (their own repository, no remote to us),
# plus their config and their own file. Local edits are archived outside Git history.
make_box() {   # make_box <dir> [--no-git] [--old-ignore]
  local b="$1"; shift
  local nogit=0 oldignore=0 a
  for a in "$@"; do case "$a" in --no-git) nogit=1 ;; --old-ignore) oldignore=1 ;; esac; done
  rm -rf "$b"; seed_tree "$b" old
  [ "$oldignore" = 1 ] && printf 'airlock.toml\n' > "$b/.gitignore"
  printf 'stale app left behind\n'  > "$b/apps/dropped-app"
  printf '[site]\nname = "My Box"\n' > "$b/airlock.toml"
  printf 'my notes\n'                > "$b/MY-NOTES.md"
  if [ "$nogit" = 0 ]; then
    git -C "$b" init -q -b main; git -C "$b" add -A; git -C "$b" commit -q -m "as installed"
  fi
}
BOX="$scratch/box"
run_update() { AIRLOCK_DIR="$BOX" AIRLOCK_RELEASE_URL="$REL" bash "$UPDATE" "$@" 2>&1; }
CONFIG='[site]
name = "My Box"'

# ---------------------------------------------------------------- 1) the safe update
make_box "$BOX"
out="$(run_update --no-install)"; rc=$?
[ "$rc" = 0 ] && ok "runs to completion on a real-shaped checkout" || bad "update exited $rc: $out"
[ "$(cat "$BOX/airlock.toml")" = "$CONFIG" ] \
  && ok "airlock.toml is untouched" || bad "the operator's configuration was rewritten"
[ -f "$BOX/MY-NOTES.md" ] && ok "the operator's own file survives" || bad "MY-NOTES.md was deleted"
grep -q 'version new' "$BOX/README.md" && ok "a changed file is now the released one" \
                                       || bad "README.md did not update"
[ -f "$BOX/NOTICE" ] && ok "a file new in the release arrives" || bad "NOTICE missing"
[ -f "$BOX/apps/dropped-app" ] && ok "a file absent from the release is kept, not deleted" \
                               || bad "the script removed a path it did not recognise"
printf '%s' "$out" | grep -q 'dropped-app' && ok "and it is named, not just counted" \
                                           || bad "the kept file was not named"
printf '%s' "$out" | grep -q 'README.md' && ok "changed files are named too" \
                                         || bad "only a count was printed"

# ---------------------------------------------------------------- 2) reversibility
sha="$(printf '%s' "$out" | sed -n 's/.*reset --hard \([0-9a-f]\{7,\}\).*/\1/p' | head -1)"
if [ -n "$sha" ]; then
  ok "the undo command is printed with a real revision"
  git -C "$BOX" reset --hard -q "$sha"
  grep -q 'version old' "$BOX/README.md" && ok "and it really restores the previous tree" \
                                         || bad "reset --hard did not bring back the old content"
  [ "$(cat "$BOX/airlock.toml")" = "$CONFIG" ] && ok "the undo leaves airlock.toml alone too" \
                                               || bad "the undo touched airlock.toml"
else
  bad "no undo revision was printed"
fi

# ---------------------------------------------------------------- 2b) uncommitted work
make_box "$BOX"
printf 'version old, then edited by hand\n' > "$BOX/README.md"
out2b="$(run_update --no-install)"
sha2b="$(printf '%s' "$out2b" | sed -n 's/.*reset --hard \([0-9a-f]\{7,\}\).*/\1/p' | head -1)"
if [ -n "$sha2b" ]; then
  git -C "$BOX" reset --hard -q "$sha2b"
  local_archive="$(printf '%s' "$out2b" | sed -n 's/.*로컬 파일 보관: //p' | head -1)"
  [ -n "$local_archive" ] && bash "$(dirname "$local_archive")/restore.sh" "$BOX"
  grep -q 'edited by hand' "$BOX/README.md" \
    && ok "an uncommitted edit is preserved and comes back on undo" \
    || bad "the operator's uncommitted edit was overwritten and is unrecoverable"
else
  bad "no undo revision printed for a box with uncommitted work"
fi

# Review2: one restoration path must preserve HEAD-only paths and node types.
restore_saved_files() {
  local command
  # Execute the actual combined checkout-and-files hint from our offline fixture.
  command="$(printf '%s' "$1" | sed -n 's/.*되돌리려면:  //p' | head -1)"
  [ -n "$command" ] && bash -c "$command"
}
archive_omits_children() {
  local archive
  archive="$(printf '%s' "$1" | sed -n 's/.*로컬 파일 보관: //p' | head -1)"
  python3 - "$archive" "$2" <<'NO_CHILDREN'
import json
from pathlib import Path
import sys, tarfile
archive, prefix = Path(sys.argv[1]), sys.argv[2] + "/"
with tarfile.open(archive) as saved:
    assert not any(name.startswith(prefix) for name in saved.getnames())
assert not any(name.startswith(prefix) for name in json.loads(archive.with_name("files.json").read_text())["absent"])
NO_CHILDREN
}

# Review4: staged bytes can differ from working bytes and be unreachable to GC.
# The saved index must also survive expiration of its split-index backing file.
make_box "$BOX"
printf 'PRECIOUS STAGED VERSION\n' >"$BOX/README.md"
git -C "$BOX" add README.md
manual_staged_blob="$(git -C "$BOX" rev-parse :README.md)"
git -C "$BOX" update-index --split-index
printf 'UNSTAGED WORKING VERSION\n' >"$BOX/README.md"
blob_undo="$(run_update --no-install --from-unknown)"; blob_undo_rc=$?
git -C "$BOX" update-index --no-split-index
git -C "$BOX" prune --expire now
find "$BOX/.git" -name 'sharedindex.*' -delete
[ "$blob_undo_rc" = 0 ] && ! git -C "$BOX" cat-file -e "$manual_staged_blob" 2>/dev/null \
  && restore_saved_files "$blob_undo" \
  && [ "$(git -C "$BOX" show :README.md)" = 'PRECIOUS STAGED VERSION' ] \
  && [ "$(cat "$BOX/README.md")" = 'UNSTAGED WORKING VERSION' ] \
  && ok "manual undo preserves distinct staged/working bytes after blob and shared-index expiry" \
  || bad "manual undo lost staged bytes after object cleanup: $blob_undo"
make_box "$BOX"
git -C "$BOX" rm -q MY-NOTES.md
staged_delete_before="$(git -C "$BOX" diff --cached --binary)"
staged_delete_out="$(run_update --no-install --from-unknown)"; staged_delete_rc=$?
[ "$staged_delete_rc" = 0 ] && restore_saved_files "$staged_delete_out" \
  && [ ! -e "$BOX/MY-NOTES.md" ] \
  && [ "$(git -C "$BOX" diff --cached --binary)" = "$staged_delete_before" ] \
  && ok "manual undo keeps staged deletion of a HEAD-only operator file outside the release" \
  || bad "manual undo resurrected a HEAD-only staged deletion: $staged_delete_out"

make_box "$BOX"
git -C "$BOX" mv MY-NOTES.md RENAMED-NOTES.md
staged_rename_before="$(git -C "$BOX" diff --cached --binary)"
rename_out="$(run_update --no-install --from-unknown)"; rename_rc=$?
[ "$rename_rc" = 0 ] && restore_saved_files "$rename_out" \
  && [ ! -e "$BOX/MY-NOTES.md" ] && [ "$(cat "$BOX/RENAMED-NOTES.md")" = 'my notes' ] \
  && [ "$(git -C "$BOX" diff --cached --binary)" = "$staged_rename_before" ] \
  && ok "manual undo preserves staged rename/deletion of operator files outside the release" \
  || bad "manual undo resurrected a staged-deleted operator path: $rename_out"

make_box "$BOX"
link_target="$scratch/directory-link-target"
mkdir -p "$link_target"
printf 'external operator target\n' >"$link_target/manifest"
rm -r "$BOX/apps/hub"
ln -s "$link_target" "$BOX/apps/hub"
link_out="$(run_update --no-install --from-unknown)"; link_rc=$?
[ "$link_rc" = 0 ] && archive_omits_children "$link_out" apps/hub && restore_saved_files "$link_out" \
  && [ -L "$BOX/apps/hub" ] && [ "$(readlink "$BOX/apps/hub")" = "$link_target" ] \
  && [ "$(cat "$link_target/manifest")" = 'external operator target' ] \
  && ok "manual undo restores a directory replaced by a symlink without archiving or changing its target" \
  || bad "directory-to-symlink undo lost its node type or changed its target: $link_out"

make_box "$BOX"
rm "$BOX/README.md"
mkdir "$BOX/README.md"
printf 'directory-local notes\n' >"$BOX/README.md/notes"
dir_out="$(run_update --no-install --from-unknown)"; dir_rc=$?
[ "$dir_rc" = 0 ] && restore_saved_files "$dir_out" \
  && [ -d "$BOX/README.md" ] && [ ! -L "$BOX/README.md" ] \
  && [ "$(cat "$BOX/README.md/notes")" = 'directory-local notes' ] \
  && ok "manual undo restores a file replaced by a directory and its original contents" \
  || bad "file-to-directory undo lost the operator's directory: $dir_out"

make_box "$BOX"
rm -r "$BOX/apps/hub"
printf 'operator flat file\n' >"$BOX/apps/hub"
flat_out="$(run_update --no-install --from-unknown)"; flat_rc=$?
[ "$flat_rc" = 0 ] && archive_omits_children "$flat_out" apps/hub && restore_saved_files "$flat_out" \
  && [ -f "$BOX/apps/hub" ] && [ ! -L "$BOX/apps/hub" ] \
  && [ "$(cat "$BOX/apps/hub")" = 'operator flat file' ] \
  && ok "manual undo restores a directory replaced by one regular file" \
  || bad "directory-to-file undo lost the operator's file: $flat_out"

make_box "$BOX"
file_link_target="$scratch/file-link-target"
printf 'external file bytes\n' >"$file_link_target"
rm "$BOX/README.md"
ln -s "$file_link_target" "$BOX/README.md"
file_link_out="$(run_update --no-install --from-unknown)"; file_link_rc=$?
[ "$file_link_rc" = 0 ] && restore_saved_files "$file_link_out" \
  && [ -L "$BOX/README.md" ] && [ "$(readlink "$BOX/README.md")" = "$file_link_target" ] \
  && [ "$(cat "$file_link_target")" = 'external file bytes' ] \
  && ok "manual undo restores a file replaced by a link and keeps the external target" \
  || bad "file-to-link undo lost its link or changed its target: $file_link_out"

make_box "$BOX"
rm "$BOX/README.md"
ln -s "$file_link_target" "$BOX/README.md"
git -C "$BOX" add README.md
git -C "$BOX" commit -qm 'operator link baseline'
rm "$BOX/README.md"
mkdir "$BOX/README.md"
printf 'link became directory\n' >"$BOX/README.md/notes"
mkdir "$BOX/README.md/empty"
link_dir_out="$(run_update --no-install --from-unknown)"; link_dir_rc=$?
[ "$link_dir_rc" = 0 ] && restore_saved_files "$link_dir_out" \
  && [ -d "$BOX/README.md" ] && [ ! -L "$BOX/README.md" ] \
  && [ "$(cat "$BOX/README.md/notes")" = 'link became directory' ] \
  && [ -d "$BOX/README.md/empty" ] \
  && [ "$(cat "$file_link_target")" = 'external file bytes' ] \
  && ok "manual undo restores a link replaced by a directory, including empty children" \
  || bad "link-to-directory undo lost its tree or followed the old target: $link_dir_out"

make_box "$BOX"
rm "$BOX/README.md"
ln -s "$file_link_target" "$BOX/README.md"
git -C "$BOX" add README.md
git -C "$BOX" commit -qm 'operator link baseline'
rm "$BOX/README.md"
printf 'link became file\n' >"$BOX/README.md"
link_file_out="$(run_update --no-install --from-unknown)"; link_file_rc=$?
[ "$link_file_rc" = 0 ] && restore_saved_files "$link_file_out" \
  && [ -f "$BOX/README.md" ] && [ ! -L "$BOX/README.md" ] \
  && [ "$(cat "$BOX/README.md")" = 'link became file' ] \
  && [ "$(cat "$file_link_target")" = 'external file bytes' ] \
  && ok "manual undo restores a link replaced by a regular file without changing its target" \
  || bad "link-to-file undo lost the operator bytes: $link_file_out"

make_box "$BOX"
rm -r "$BOX/apps/hub"
broken_target="$scratch/nonexistent-link-target"
ln -s "$broken_target" "$BOX/apps/hub"
broken_out="$(run_update --no-install --from-unknown)"; broken_rc=$?
[ "$broken_rc" = 0 ] && archive_omits_children "$broken_out" apps/hub && restore_saved_files "$broken_out" \
  && [ -L "$BOX/apps/hub" ] && [ "$(readlink "$BOX/apps/hub")" = "$broken_target" ] \
  && [ ! -e "$broken_target" ] \
  && ok "manual undo keeps dangling parent links and does not invent absent children under them" \
  || bad "dangling parent link undo replaced the operator link: $broken_out"

# Removed public apps must not return through checkout catalogue discovery. This
# release changes ONLY deletions, while the operator has both committed and staged
# edits in retired source and a separate file in the same app directory.
RETIRED_REL="$scratch/retired-release"
seed_tree "$RETIRED_REL" old
mkdir -p "$RETIRED_REL/apps/notes" "$RETIRED_REL/apps/slack"
printf 'released notes manifest\n' >"$RETIRED_REL/apps/notes/app.toml"
printf 'released notes installer\n' >"$RETIRED_REL/apps/notes/install.sh"
printf 'released slack manifest\n' >"$RETIRED_REL/apps/slack/app.toml"
git -C "$RETIRED_REL" init -q -b main
git -C "$RETIRED_REL" add -A
git -C "$RETIRED_REL" commit -q -m 'release before app retirement'
retired_base="$(git -C "$RETIRED_REL" rev-parse HEAD)"
make_box "$BOX"
cp -r "$RETIRED_REL/apps/notes" "$RETIRED_REL/apps/slack" "$BOX/apps/"
git -C "$BOX" add -A
git -C "$BOX" commit -q -m "airlock-update: 배포본 ${retired_base:0:12} 으로 갱신"
printf 'operator committed notes installer\n' >"$BOX/apps/notes/install.sh"
printf 'operator app-directory data\n' >"$BOX/apps/notes/my-data.txt"
git -C "$BOX" add -A
git -C "$BOX" commit -q -m 'operator work after release'
printf 'operator staged notes manifest\n' >"$BOX/apps/notes/app.toml"
git -C "$BOX" add apps/notes/app.toml
retired_staged="$(git -C "$BOX" diff --cached --binary)"
printf 'operator working notes manifest\n' >"$BOX/apps/notes/app.toml"
git -C "$RETIRED_REL" rm -q -r apps/notes apps/slack
git -C "$RETIRED_REL" commit -q -m 'release removes Notes and Slack'
retired_preview="$(AIRLOCK_DIR="$BOX" AIRLOCK_RELEASE_URL="$RETIRED_REL" bash "$UPDATE" --dry-run --json 2>"$scratch/retired-preview.err")"; retired_preview_rc=$?
[ "$retired_preview_rc" = 0 ] && printf '%s' "$retired_preview" | python3 -c 'import json,sys; value=json.load(sys.stdin); assert value["available"] and value["changedCount"] == 3' \
  && [ "$(cat "$BOX/apps/notes/app.toml")" = 'operator working notes manifest' ] \
  && ok "a deletion-only public release is detected without changing retired operator bytes" \
  || bad "retired source disappeared from update detection or preview changed it: $retired_preview"
retired_out="$(AIRLOCK_DIR="$BOX" AIRLOCK_RELEASE_URL="$RETIRED_REL" bash "$UPDATE" --no-install)"; retired_rc=$?
[ "$retired_rc" = 0 ] && [ ! -e "$BOX/apps/notes/app.toml" ] \
  && [ ! -e "$BOX/apps/notes/install.sh" ] && [ ! -e "$BOX/apps/slack/app.toml" ] \
  && [ "$(cat "$BOX/apps/notes/my-data.txt")" = 'operator app-directory data' ] \
  && [ -f "$BOX/apps/dropped-app" ] && [ -f "$BOX/MY-NOTES.md" ] \
  && ok "update removes only retired public source, keeping operator files even inside the retired app" \
  || bad "update resurrected retired apps or deleted operator-only paths: $retired_out"
[ "$retired_rc" = 0 ] && restore_saved_files "$retired_out" \
  && [ "$(cat "$BOX/apps/notes/app.toml")" = 'operator working notes manifest' ] \
  && [ "$(cat "$BOX/apps/notes/install.sh")" = 'operator committed notes installer' ] \
  && [ "$(git -C "$BOX" diff --cached --binary)" = "$retired_staged" ] \
  && ok "the existing recovery archive restores committed, staged and working edits in retired source" \
  || bad "retired-source cleanup lost operator edits or staging: $retired_out"

# The old file may now be a directory containing new public source. Retiring the
# exact old index entry must keep those new children and finish the update.
LAYOUT_REL="$scratch/layout-release"
seed_tree "$LAYOUT_REL" old
mkdir -p "$LAYOUT_REL/apps/notes"
printf 'old source file\n' >"$LAYOUT_REL/apps/notes/airlock-app.toml"
git -C "$LAYOUT_REL" init -q -b main
git -C "$LAYOUT_REL" add -A
git -C "$LAYOUT_REL" commit -q -m 'release has a file'
layout_base="$(git -C "$LAYOUT_REL" rev-parse HEAD)"
make_box "$BOX"
mkdir -p "$BOX/apps/notes"
cp "$LAYOUT_REL/apps/notes/airlock-app.toml" "$BOX/apps/notes/airlock-app.toml"
git -C "$BOX" add -A
git -C "$BOX" commit -q -m "airlock-update: 배포본 ${layout_base:0:12} 으로 갱신"
rm "$LAYOUT_REL/apps/notes/airlock-app.toml"
mkdir "$LAYOUT_REL/apps/notes/airlock-app.toml"
printf 'new public child\n' >"$LAYOUT_REL/apps/notes/airlock-app.toml/child"
git -C "$LAYOUT_REL" add -A
git -C "$LAYOUT_REL" commit -q -m 'release replaces file with directory'
layout_out="$(AIRLOCK_DIR="$BOX" AIRLOCK_RELEASE_URL="$LAYOUT_REL" bash "$UPDATE" --no-install)"; layout_rc=$?
[ "$layout_rc" = 0 ] && [ "$(cat "$BOX/apps/notes/airlock-app.toml/child")" = 'new public child' ] \
  && git -C "$BOX" ls-files --error-unmatch apps/notes/airlock-app.toml/child >/dev/null 2>&1 \
  && [ -z "$(git -C "$BOX" status --porcelain)" ] \
  && ok "retiring an old file keeps its new public directory children and completes the release" \
  || bad "file-to-directory retirement removed new source or aborted the update: $layout_out"

# ---------------------------------------------------------------- 2c) box state that rode into git
# airlock.lock is machine-written per-box approval state that once rode into the
# repository with a box commit. Every installed clone then read as permanently dirty,
# the hourly canonical-clone sweep skips dirty clones, and those clones went quietly
# stale. The release now declares the path ignored and no longer carries it, so the
# update must drop it from the INDEX and keep the BYTES — an already-tracked path does
# not stop being tracked just because a new .gitignore names it.
make_box "$BOX"
printf '[hello]\ndigest = "committed"\n' > "$BOX/airlock.lock"
git -C "$BOX" add -f airlock.lock
git -C "$BOX" commit -q -m "box: approval state rode in"
# …and then the box's own machinery rewrote it — that rewrite is the permanent dirt.
printf '[hello]\ndigest = "b0xstate"\n' > "$BOX/airlock.lock"
out2c="$(run_update --no-install)"; rc2c=$?
[ "$rc2c" = 0 ] || bad "update exited $rc2c on a box tracking release-declared state: $out2c"
grep -q 'b0xstate' "$BOX/airlock.lock" \
  && ok "the box's own approval bytes survive the update" \
  || bad "the update destroyed the box's package lock"
git -C "$BOX" ls-files --error-unmatch airlock.lock >/dev/null 2>&1 \
  && bad "the release declared it box state, but it is still tracked — the clone stays dirty forever" \
  || ok "a release-declared box-state path is dropped from the index"
[ -z "$(git -C "$BOX" status --porcelain --untracked-files=no)" ] \
  && ok "and the checkout is clean afterwards, so the sweep stops skipping it" \
  || bad "the checkout is still dirty: $(git -C "$BOX" status --porcelain --untracked-files=no)"
git -C "$BOX" ls-files --error-unmatch apps/dropped-app >/dev/null 2>&1 \
  && ok "a stale path the release does NOT declare ignored stays tracked" \
  || bad "an unrecognised operator path was untracked"
printf '%s' "$out2c" | grep -q '추적에서만 뺍니다' \
  && ok "the untracking is named, not silent" || bad "the index change was not reported"

# A committed operator edit must not erase the older release provenance.  The local
# repo is theirs; direction recovery walks its history instead of demanding that the
# newest local commit still be byte-identical to a public release.
make_box "$BOX"
printf 'version old, then committed by operator\n' >"$BOX/README.md"
git -C "$BOX" add README.md
git -C "$BOX" commit -q -m "operator note"
committed_json="$(AIRLOCK_DIR="$BOX" AIRLOCK_RELEASE_URL="$REL" \
  bash "$UPDATE" --dry-run --json 2>"$scratch/committed-edit.err")"; committed_json_rc=$?
if [ "$committed_json_rc" = 0 ] && printf '%s' "$committed_json" | python3 -c '
import json, sys
value = json.load(sys.stdin)
assert value["available"] is True, value
assert value["changedCount"] > 0, value
'; then
  ok "a committed operator edit keeps its older release provenance"
else
  bad "a committed operator edit made a forward release ambiguous: $committed_json"
fi

# ---------------------------------------------------------------- 2c) a failed release commit
# A stale ref lock leaves fetch/staging available but prevents the release record.
# HEAD must stay put, the installer must not run, and the private archive must make
# the operator's uncommitted bytes recoverable after undoing the checkout.
make_box "$BOX"
printf 'PRECIOUS UNCOMMITTED EDIT\n' > "$BOX/README.md"
failed_before="$(git -C "$BOX" rev-parse HEAD)"
: > "$BOX/.git/refs/heads/main.lock"
# Positive controls: the two steps BEFORE the commit must still work, or this fixture
# is testing something else and the assertion below means nothing.
(cd "$BOX" && git fetch -q "$REL" main >/dev/null 2>&1) \
  && ok "positive control: fetching still works, so the commit is what fails" \
  || bad "positive control: the fetch failed too — this fixture tests the wrong path"
(cd "$BOX" && git add -A >/dev/null 2>&1) \
  && ok "positive control: staging still works too" \
  || bad "positive control: staging failed too — this fixture tests the wrong path"
out2c="$(run_update --no-install)"; rc2c=$?
rm -f "$BOX/.git/refs/heads/main.lock"
[ "$rc2c" -ne 0 ] && [ "$(git -C "$BOX" rev-parse HEAD)" = "$failed_before" ] \
  && ok "a failed release record does not advance HEAD or report success" \
  || bad "a failed release record was reported as success or changed HEAD"
failed_archive="$(printf '%s' "$out2c" | sed -n 's/.*로컬 파일 보관: //p' | head -1)"
git -C "$BOX" reset --hard -q "$failed_before"
[ -n "$failed_archive" ] && bash "$(dirname "$failed_archive")/restore.sh" "$BOX"
grep -q 'PRECIOUS' "$BOX/README.md" \
  && ok "after a release-record failure, checkout undo plus the archive restores the operator edit" \
  || bad "the edit cannot be recovered after a release-record failure"
[ "$(stat -c %a "$failed_archive" 2>/dev/null)" = 600 ] \
  && [ "$(stat -c %a "$(dirname "$failed_archive")" 2>/dev/null)" = 700 ] \
  && ok "the local file archive is owner-private (file 600, directory 700)" \
  || bad "local file recovery exposes operator bytes outside the owner"

# ------------------------------------------------------------- 2c-ii) HARDWARE: a
# A pre-commit hook must not block the release record. Local edits are kept in a
# private file archive, with no pre-update authoring or snapshot commit.
make_box "$BOX"
mkdir -p "$BOX/.git/hooks"
printf '#!/bin/sh\necho "hook says no" >&2\nexit 1\n' > "$BOX/.git/hooks/pre-commit"
chmod 755 "$BOX/.git/hooks/pre-commit"
printf 'edited by hand, with a hook installed\n' > "$BOX/README.md"
# Positive control: the hook really would refuse an ordinary commit in this fixture.
if (cd "$BOX" && git add -A >/dev/null 2>&1 && git commit -q -m probe >/dev/null 2>&1); then
  bad "positive control: the fixture's pre-commit hook does not actually refuse"
  (cd "$BOX" && git reset -q --soft HEAD~1)
else
  ok "positive control: the fixture's pre-commit hook really does refuse a commit"
fi
out2cii="$(run_update --no-install)"; rc2cii=$?
[ "$rc2cii" = 0 ] && ok "a pre-commit hook does not block the update" \
                  || bad "a pre-commit hook stopped the update: $out2cii"
sha2cii="$(printf '%s' "$out2cii" | sed -n 's/.*reset --hard \([0-9a-f]\{7,\}\).*/\1/p' | head -1)"
if [ -n "$sha2cii" ]; then
  git -C "$BOX" reset --hard -q "$sha2cii"
  local_archive="$(printf '%s' "$out2cii" | sed -n 's/.*로컬 파일 보관: //p' | head -1)"
  [ -n "$local_archive" ] && bash "$(dirname "$local_archive")/restore.sh" "$BOX"
  grep -q 'with a hook installed' "$BOX/README.md" \
    && ok "and its private file archive restores the edit without a snapshot commit" \
    || bad "the run continued but its private archive did not contain the edit"
else
  bad "no undo revision printed on a box with a pre-commit hook"
fi
rm -f "$BOX/.git/hooks/pre-commit"

# ---------------------------------------------------------------- 2d) REVIEW: the
# .gitignore gap. A release path hidden by an older .gitignore must survive
# checkout undo through the private file archive. Reachable today: .gitignore gained
# `!examples/app-package/airlock.toml` on 2026-08-08.
make_box "$BOX" --old-ignore
printf 'MY OWN EDIT TO THE EXAMPLE\n' > "$BOX/examples/app-package/airlock.toml"
git -C "$BOX" check-ignore -q examples/app-package/airlock.toml \
  && ok "positive control: the old .gitignore really does hide that release path" \
  || bad "positive control failed — the fixture does not reproduce the gap"
out2d="$(run_update --no-install)"
printf '%s' "$out2d" | grep -q 'examples/app-package/airlock.toml' \
  && ok "the hidden-but-overwritten file is reported" \
  || bad "the file in the gap was overwritten silently"
sha2d="$(printf '%s' "$out2d" | sed -n 's/.*reset --hard \([0-9a-f]\{7,\}\).*/\1/p' | head -1)"
git -C "$BOX" reset --hard -q "$sha2d" 2>/dev/null
  local_archive="$(printf '%s' "$out2d" | sed -n 's/.*로컬 파일 보관: //p' | head -1)"
  [ -n "$local_archive" ] && bash "$(dirname "$local_archive")/restore.sh" "$BOX"
if [ -f "$BOX/examples/app-package/airlock.toml" ] \
   && grep -q 'MY OWN EDIT' "$BOX/examples/app-package/airlock.toml"; then
  ok "and the undo brings it back with the operator's content"
else
  bad "the undo deleted it — this is the data-loss path the review found"
fi

# A deleted tracked path must stay deleted after the printed checkout/file undo.
make_box "$BOX"
rm "$BOX/README.md"
deleted_out="$(run_update --no-install --from-unknown)"; deleted_rc=$?
deleted_before="$(printf '%s' "$deleted_out" | sed -n 's/.*reset --hard \([0-9a-f]\{7,\}\).*/\1/p' | head -1)"
deleted_archive="$(printf '%s' "$deleted_out" | sed -n 's/.*로컬 파일 보관: //p' | head -1)"
git -C "$BOX" reset --hard -q "$deleted_before"
bash "$(dirname "$deleted_archive")/restore.sh" "$BOX"
[ "$deleted_rc" = 0 ] && [ ! -e "$BOX/README.md" ] \
  && ok "checkout plus file recovery preserves an uncommitted deletion" \
  || bad "file recovery resurrected an operator-deleted path: $deleted_out"

# ---------------------------------------------------------------- 2e) no pre-update commits
for shape in "" "--no-git" "--old-ignore"; do
  make_box "$BOX" $shape
  printf 'private operator edit\n' > "$BOX/README.md"
  prior_count="$(git -C "$BOX" rev-list --count HEAD 2>/dev/null || printf 0)"
  update_args=(--no-install)
  [ "$shape" != --no-git ] || update_args+=(--from-unknown)
  no_snapshot_out="$(run_update "${update_args[@]}")"; no_snapshot_rc=$?
  after_count="$(git -C "$BOX" rev-list --count HEAD)"
  if [ "$no_snapshot_rc" = 0 ] && [ "$after_count" -eq "$((prior_count + 1))" ] \
     && ! git -C "$BOX" log --format=%s | grep -E '업데이트 전 (상태|자동 저장)' >/dev/null \
     && [ "$(cat "$BOX/MY-NOTES.md")" = 'my notes' ] \
     && [ "$(cat "$BOX/airlock.toml")" = "$CONFIG" ]; then
    ok "only the release advances HEAD for ${shape:-dirty checkout}; user file/config bytes survive"
  else
    bad "pre-update commit or user-data loss for ${shape:-dirty checkout}: $no_snapshot_out"
  fi
done

# ---------------------------------------------------------------- 3) idempotence
make_box "$BOX"
run_update --no-install >/dev/null
printf '%s' "$(run_update --no-install)" | grep -q '이미 최신' \
  && ok "a second run reports nothing to do" \
  || bad "the second run did not recognise an up-to-date tree"

# ---------------------------------------------------------------- 4) --dry-run
for shape in "" "--no-git"; do
  label="git 저장소"; [ -n "$shape" ] && label=".git 없는 체크아웃"
  # shellcheck disable=SC2086
  make_box "$BOX" $shape
  before_readme="$(cat "$BOX/README.md")"
  out3="$(run_update --dry-run)"; rc3=$?
  [ "$rc3" = 0 ] && ok "--dry-run succeeds on a $label" || bad "--dry-run exited $rc3 on a $label: $out3"
  [ "$(cat "$BOX/README.md")" = "$before_readme" ] \
    && ok "--dry-run changes no file on a $label" || bad "--dry-run modified a $label"
  printf '%s' "$out3" | grep -q 'README.md' \
    && ok "--dry-run names what would change on a $label" \
    || bad "--dry-run reported nothing on a $label — it may have died instead"
done
# REVIEW: this pair is why the shapes are separate. --dry-run used to skip `git init`
# and then run `git remote add` in a non-repository, so it died on exactly the boxes it
# was for — and three assertions passed anyway, because "died" and "changed nothing"
# look identical from outside.
make_box "$BOX" --no-git
run_update --dry-run >/dev/null 2>&1
[ -d "$BOX/.git" ] && bad "--dry-run created a repository in the operator's directory" \
                   || ok "--dry-run creates no repository"

# The update detector must consume a machine result, not scrape Korean progress text.
# This exercises the non-git path too: that is the reason the updater owns a scratch
# GIT_DIR during preview.
make_box "$BOX" --no-git
json_out="$(AIRLOCK_DIR="$BOX" AIRLOCK_RELEASE_URL="$REL" bash "$UPDATE" --dry-run --json 2>"$scratch/update-json.err")"; json_rc=$?
json_check="$(printf '%s' "$json_out" | python3 -c '
import json, sys
value = json.load(sys.stdin)
assert value["available"] is True, value
assert isinstance(value["changedCount"], int) and value["changedCount"] > 0, value
assert len(value["ref"]) == 40 and all(c in "0123456789abcdef" for c in value["ref"]), value
')"; json_check_rc=$?
[ "$json_rc" = 0 ] && [ "$json_check_rc" = 0 ] \
  && ok "--dry-run --json is a clean machine result on a non-git checkout" \
  || bad "--dry-run --json was not the detector contract (update=$json_rc json=$json_check_rc): $json_out"

# ------------------------------------------------------ 4b) release direction
# A content diff is symmetric: an older release differs from the installed tree just
# as a newer one does.  The updater must use release provenance, not changed files, to
# decide whether a badge/action is an update.  Keep the release commits in the box's
# object store, as a real prior airlock-update does, but make the operator's HEAD an
# unrelated operator commit — that is the installed checkout contract.
DIRECTION_REL="$scratch/direction-release"
seed_tree "$DIRECTION_REL" release-old
git -C "$DIRECTION_REL" init -q -b main
git -C "$DIRECTION_REL" add -A
git -C "$DIRECTION_REL" commit -q -m "release from test-source @ 1111111"
direction_old="$(git -C "$DIRECTION_REL" rev-parse HEAD)"
seed_tree "$DIRECTION_REL" release-current
git -C "$DIRECTION_REL" add -A
git -C "$DIRECTION_REL" commit -q -m "release from test-source @ 2222222"
direction_current="$(git -C "$DIRECTION_REL" rev-parse HEAD)"
git -C "$DIRECTION_REL" merge-base --is-ancestor "$direction_old" "$direction_current" \
  && ok "positive control: the rejected release is behind the installed release" \
  || bad "positive control: stale-release fixture has no forward release ancestry"

DIRECTION_BOX="$scratch/direction-box"
mkdir -p "$DIRECTION_BOX"
git -C "$DIRECTION_REL" archive "$direction_current" | tar -x -C "$DIRECTION_BOX"
git -C "$DIRECTION_BOX" init -q -b main
git -C "$DIRECTION_BOX" remote add airlock-release "$DIRECTION_REL"
git -C "$DIRECTION_BOX" fetch -q airlock-release "$direction_current"
git -C "$DIRECTION_BOX" add -A
git -C "$DIRECTION_BOX" commit -q \
  -m "airlock-update: 배포본 ${direction_current:0:12} 으로 갱신"
direction_before_head="$(git -C "$DIRECTION_BOX" rev-parse HEAD)"

direction_json="$(AIRLOCK_DIR="$DIRECTION_BOX" AIRLOCK_RELEASE_URL="$DIRECTION_REL" \
  AIRLOCK_RELEASE_REF="$direction_old" bash "$UPDATE" --dry-run --json \
  2>"$scratch/direction-json.err")"; direction_json_rc=$?
if [ "$direction_json_rc" = 0 ] && printf '%s' "$direction_json" | python3 -c '
import json, sys
value = json.load(sys.stdin)
assert value["available"] is False, value
assert value["changedCount"] == 0, value
'; then
  ok "a release behind the installed release produces no update badge"
else
  bad "a stale release was reported as available: $direction_json"
fi

direction_run_out="$(AIRLOCK_DIR="$DIRECTION_BOX" AIRLOCK_RELEASE_URL="$DIRECTION_REL" \
  AIRLOCK_RELEASE_REF="$direction_old" bash "$UPDATE" --no-install 2>&1)"
direction_run_rc=$?
if [ "$direction_run_rc" -ne 0 ] \
  && [ "$(git -C "$DIRECTION_BOX" rev-parse HEAD)" = "$direction_before_head" ] \
  && grep -q 'release-current' "$DIRECTION_BOX/README.md"; then
  ok "an explicit stale-release update is refused before changing the checkout"
else
  bad "a stale release changed or was allowed on the box (rc=$direction_run_rc): $direction_run_out"
fi

# A long-lived box accumulates one local marker commit per update.  The newest marker
# is enough to establish direction; scanning the rest through a truncating pipeline
# can make a normal forward measurement fail with SIGPIPE once the history outgrows
# the pipe buffer.
LONG_MARKER_BOX="$scratch/long-marker-box"
mkdir -p "$LONG_MARKER_BOX"
git -C "$DIRECTION_REL" archive "$direction_old" | tar -x -C "$LONG_MARKER_BOX"
git -C "$LONG_MARKER_BOX" init -q -b main
git -C "$LONG_MARKER_BOX" remote add airlock-release "$DIRECTION_REL"
git -C "$LONG_MARKER_BOX" fetch -q airlock-release "$direction_current"
git -C "$LONG_MARKER_BOX" add -A
long_marker_tree="$(git -C "$LONG_MARKER_BOX" write-tree)"
long_marker_parent=""
for _ in $(seq 1 1100); do
  if [ -n "$long_marker_parent" ]; then
    long_marker_parent="$(printf 'airlock-update: 배포본 %s 으로 갱신\n' \
      "${direction_old:0:12}" | git -C "$LONG_MARKER_BOX" commit-tree \
      "$long_marker_tree" -p "$long_marker_parent")"
  else
    long_marker_parent="$(printf 'airlock-update: 배포본 %s 으로 갱신\n' \
      "${direction_old:0:12}" | git -C "$LONG_MARKER_BOX" commit-tree "$long_marker_tree")"
  fi
done
git -C "$LONG_MARKER_BOX" update-ref refs/heads/main "$long_marker_parent"
[ "$(git -C "$LONG_MARKER_BOX" rev-list --count HEAD)" = 1100 ] \
  && ok "positive control: the long-lived box has 1100 update markers" \
  || bad "positive control: the long-lived box did not retain its marker history"
long_marker_json="$(AIRLOCK_DIR="$LONG_MARKER_BOX" AIRLOCK_RELEASE_URL="$DIRECTION_REL" \
  AIRLOCK_RELEASE_REF="$direction_current" bash "$UPDATE" --dry-run --json \
  2>"$scratch/long-marker.err")"; long_marker_rc=$?
if [ "$long_marker_rc" = 0 ] && printf '%s' "$long_marker_json" | python3 -c '
import json, sys
value = json.load(sys.stdin)
assert value["available"] is True, value
assert value["changedCount"] > 0, value
'; then
  ok "a long marker history still reports a forward release"
else
  bad "a long marker history turned a forward release into failure (rc=$long_marker_rc): $long_marker_json"
fi

# `git log --grep` searches the whole commit message, not only its subject.  An
# operator note whose body merely quotes a marker must not hide the older real marker.
git -C "$LONG_MARKER_BOX" commit -q --allow-empty -m "operator note" \
  -m "airlock-update: 배포본 ${direction_current:0:12} 으로 갱신"
if [ "$(git -C "$LONG_MARKER_BOX" log -1 --format=%s)" = "operator note" ] \
  && git -C "$LONG_MARKER_BOX" log -1 --format=%b \
    | grep -Fx "airlock-update: 배포본 ${direction_current:0:12} 으로 갱신" >/dev/null; then
  ok "positive control: a newer operator commit quotes a marker only in its body"
else
  bad "positive control: the operator commit does not exercise body-only marker text"
fi
marker_body_json="$(AIRLOCK_DIR="$LONG_MARKER_BOX" AIRLOCK_RELEASE_URL="$DIRECTION_REL" \
  AIRLOCK_RELEASE_REF="$direction_current" bash "$UPDATE" --dry-run --json \
  2>"$scratch/marker-body.err")"; marker_body_rc=$?
if [ "$marker_body_rc" = 0 ] && printf '%s' "$marker_body_json" | python3 -c '
import json, sys
value = json.load(sys.stdin)
assert value["available"] is True, value
assert value["changedCount"] > 0, value
'; then
  ok "body-only marker text cannot shadow the newest real marker"
else
  bad "body-only marker text hid the real marker (rc=$marker_body_rc): $marker_body_json"
fi

# FETCH_HEAD preserves an annotated tag object instead of peeling it.  The updater
# must normalize a release ref to its commit before writing the local marker, or the
# next detector run rejects the updater's own marker as a non-commit Source-Digest.
git -C "$DIRECTION_REL" tag -a release-current-tag \
  -m "annotated current release" "$direction_current"
direction_tag="$(git -C "$DIRECTION_REL" rev-parse refs/tags/release-current-tag)"
[ "$direction_tag" != "$direction_current" ] \
  && [ "$(git -C "$DIRECTION_REL" cat-file -t "$direction_tag")" = tag ] \
  && ok "positive control: the release ref is an annotated tag object" \
  || bad "positive control: the release ref did not preserve its tag object"
TAG_RELEASE_BOX="$scratch/tag-release-box"
mkdir -p "$TAG_RELEASE_BOX"
git -C "$DIRECTION_REL" archive "$direction_old" | tar -x -C "$TAG_RELEASE_BOX"
git -C "$TAG_RELEASE_BOX" init -q -b main
git -C "$TAG_RELEASE_BOX" remote add airlock-release "$DIRECTION_REL"
git -C "$TAG_RELEASE_BOX" fetch -q airlock-release "$direction_old"
git -C "$TAG_RELEASE_BOX" add -A
git -C "$TAG_RELEASE_BOX" commit -q \
  -m "airlock-update: 배포본 ${direction_old:0:12} 으로 갱신"
tag_update_out="$(AIRLOCK_DIR="$TAG_RELEASE_BOX" AIRLOCK_RELEASE_URL="$DIRECTION_REL" \
  AIRLOCK_RELEASE_REF=release-current-tag bash "$UPDATE" --no-install 2>&1)"; tag_update_rc=$?
[ "$tag_update_rc" = 0 ] && grep -q 'release-current' "$TAG_RELEASE_BOX/README.md" \
  && ok "an annotated release ref updates to its commit tree" \
  || bad "an annotated release ref did not update (rc=$tag_update_rc): $tag_update_out"
tag_second_json="$(AIRLOCK_DIR="$TAG_RELEASE_BOX" AIRLOCK_RELEASE_URL="$DIRECTION_REL" \
  AIRLOCK_RELEASE_REF=release-current-tag bash "$UPDATE" --dry-run --json \
  2>"$scratch/tag-second.err")"; tag_second_rc=$?
if [ "$tag_second_rc" = 0 ] && printf '%s' "$tag_second_json" | python3 -c '
import json, sys
value = json.load(sys.stdin)
assert value["available"] is False, value
assert value["changedCount"] == 0, value
'; then
  ok "an annotated release marker remains measurable on the next detection"
else
  bad "an annotated release poisoned its next detector result (rc=$tag_second_rc): $tag_second_json"
fi

# A deployment checkout has the private source graph, but its HEAD can be an
# unrelated-history merge wrapper.  Compare the release subject's source SHA with the
# checkout's merge-base against fresh private main; comparing it with HEAD directly
# would call the current release a rollback.
PRIVATE_PUBLIC_NAME=airlock
PRIVATE_SOURCE_NAME="${PRIVATE_PUBLIC_NAME}-work"
PRIVATE_ROOT="$scratch/private/spacewalk-labs"
PRIVATE_REL="$PRIVATE_ROOT/$PRIVATE_SOURCE_NAME"
private_name_probe="$scratch/private-name-probe"
printf '%s\n' "$PRIVATE_SOURCE_NAME" >"$private_name_probe"
grep -Fq "$PRIVATE_SOURCE_NAME" "$private_name_probe" \
  && ok "positive control: the private repository name probe is live" \
  || bad "positive control: the private repository name probe missed its fixture"
private_name_hits="$(grep -Fn "$PRIVATE_SOURCE_NAME" "$UPDATE" "$ROOT/install/test-update.sh" 2>/dev/null || true)"
if [ -z "$private_name_hits" ]; then
  ok "public update files do not publish the private repository name"
else
  bad "public update files expose the private repository name: $private_name_hits"
fi
seed_tree "$PRIVATE_REL" private-old
git -C "$PRIVATE_REL" init -q -b main
git -C "$PRIVATE_REL" add -A
git -C "$PRIVATE_REL" commit -q -m "private old"
private_old="$(git -C "$PRIVATE_REL" rev-parse HEAD)"
seed_tree "$PRIVATE_REL" private-current
git -C "$PRIVATE_REL" add -A
git -C "$PRIVATE_REL" commit -q -m "private current"
private_current="$(git -C "$PRIVATE_REL" rev-parse HEAD)"
git -C "$PRIVATE_REL" checkout -q -b side-release "$private_old"
seed_tree "$PRIVATE_REL" private-side
git -C "$PRIVATE_REL" add -A
git -C "$PRIVATE_REL" commit -q -m "private side"
private_side="$(git -C "$PRIVATE_REL" rev-parse HEAD)"
git -C "$PRIVATE_REL" checkout -q main

PRIVATE_PUBLIC="$PRIVATE_ROOT/$PRIVATE_PUBLIC_NAME"
seed_tree "$PRIVATE_PUBLIC" private-old
git -C "$PRIVATE_PUBLIC" init -q -b main
git -C "$PRIVATE_PUBLIC" add -A
git -C "$PRIVATE_PUBLIC" commit -q \
  -m "release from ${PRIVATE_SOURCE_NAME} @ ${private_old:0:7}"
private_public_old="$(git -C "$PRIVATE_PUBLIC" rev-parse HEAD)"
seed_tree "$PRIVATE_PUBLIC" private-current
git -C "$PRIVATE_PUBLIC" add -A
git -C "$PRIVATE_PUBLIC" commit -q \
  -m "release from ${PRIVATE_SOURCE_NAME} @ ${private_current:0:7}"
private_public_current="$(git -C "$PRIVATE_PUBLIC" rev-parse HEAD)"
seed_tree "$PRIVATE_PUBLIC" private-side
git -C "$PRIVATE_PUBLIC" add -A
git -C "$PRIVATE_PUBLIC" commit -q \
  -m "release from ${PRIVATE_SOURCE_NAME} @ ${private_side:0:7}"
private_public_side="$(git -C "$PRIVATE_PUBLIC" rev-parse HEAD)"
seed_tree "$PRIVATE_PUBLIC" private-current
git -C "$PRIVATE_PUBLIC" add -A
git -C "$PRIVATE_PUBLIC" commit -q \
  -m "release from other-source @ ${private_current:0:7}"
private_public_mismatch="$(git -C "$PRIVATE_PUBLIC" rev-parse HEAD)"
seed_tree "$PRIVATE_PUBLIC" private-no-provenance
git -C "$PRIVATE_PUBLIC" add -A
git -C "$PRIVATE_PUBLIC" commit -q -m "release without provenance"
private_public_no_provenance="$(git -C "$PRIVATE_PUBLIC" rev-parse HEAD)"

PRIVATE_BOX="$scratch/private-deployment"
git clone -q "$PRIVATE_REL" "$PRIVATE_BOX"
canonical_private="https://github.com/spacewalk-labs/${PRIVATE_SOURCE_NAME}.git"
git -C "$PRIVATE_BOX" remote set-url origin "$canonical_private"
git -C "$PRIVATE_BOX" config "url.file://$PRIVATE_REL.insteadOf" "$canonical_private"
git -C "$PRIVATE_BOX" remote add airlock-release "$PRIVATE_PUBLIC"
git -C "$PRIVATE_BOX" fetch -q airlock-release "$private_public_current"
git -C "$PRIVATE_BOX" merge -q --allow-unrelated-histories -s ours \
  -m "deploy current release" FETCH_HEAD
private_deploy_head="$(git -C "$PRIVATE_BOX" rev-parse HEAD)"

# One detection may contact one repository.  Count the real `git fetch` argv rather
# than scraping progress text; the first fetch is also the positive control that the
# counter is live.  A private deployment used to fetch the public release here and
# then fetch private origin/main again inside release_direction().
FETCH_COUNT_BIN="$scratch/fetch-count-bin"
FETCH_COUNT_LOG="$scratch/private-fetches.log"
mkdir -p "$FETCH_COUNT_BIN"
# The pinned real git, not `command -v git`: by the time this shim is built the
# guard is already on PATH, so command -v would capture the guard and the two
# shims would call each other forever (install/test-lib.sh explains it).
real_git="$AIRLOCK_TEST_GUARD_REAL_GIT"
cat >"$FETCH_COUNT_BIN/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = fetch ]; then
    printf '%s\n' "\$*" >>"\$AIRLOCK_FETCH_COUNT_LOG"
    break
  fi
done
exec "$real_git" "\$@"
SH
chmod 755 "$FETCH_COUNT_BIN/git"
: >"$FETCH_COUNT_LOG"
private_fetch_json="$(PATH="$FETCH_COUNT_BIN:$PATH" AIRLOCK_FETCH_COUNT_LOG="$FETCH_COUNT_LOG" \
  AIRLOCK_DIR="$PRIVATE_BOX" AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" \
  AIRLOCK_RELEASE_REF="$private_public_current" bash "$UPDATE" --dry-run --json \
  2>"$scratch/private-fetch-count.err")"; private_fetch_json_rc=$?
private_fetch_count="$(wc -l <"$FETCH_COUNT_LOG" | tr -d ' ')"
[ "$private_fetch_count" -ge 1 ] \
  && ok "positive control: the fetch counter sees the release fetch" \
  || bad "positive control: the fetch counter saw no fetch"
[ "$private_fetch_json_rc" = 0 ] && [ "$private_fetch_count" = 1 ] \
  && ok "one private-deployment detection performs exactly one fetch" \
  || bad "one private-deployment detection performed $private_fetch_count fetches (rc=$private_fetch_json_rc): $private_fetch_json"

# If the local private-main evidence is unavailable, direction is unknown.  The
# detector must fail so devmon_updates leaves its last complete snapshot and original
# checkedAt untouched; successful {available:false} would overwrite that truth with a
# fresh-looking zero.  The git shim also prevents this fixture from reaching a private
# remote if the updater regresses to fetching it again.
PRIVATE_NO_TIP_BOX="$scratch/private-no-tip"
git clone -q "$PRIVATE_BOX" "$PRIVATE_NO_TIP_BOX"
git -C "$PRIVATE_NO_TIP_BOX" remote set-url origin "$canonical_private"
git -C "$PRIVATE_NO_TIP_BOX" config "url.file://$PRIVATE_REL.insteadOf" "$canonical_private"
git -C "$PRIVATE_NO_TIP_BOX" remote add airlock-release "$PRIVATE_PUBLIC"
git -C "$PRIVATE_NO_TIP_BOX" update-ref -d refs/remotes/origin/main
NO_PRIVATE_FETCH_BIN="$scratch/no-private-fetch-bin"
mkdir -p "$NO_PRIVATE_FETCH_BIN"
cat >"$NO_PRIVATE_FETCH_BIN/git" <<SH
#!/usr/bin/env bash
if [ "\$*" = "fetch -q origin main" ]; then
  exit 72
fi
exec "$real_git" "\$@"
SH
chmod 755 "$NO_PRIVATE_FETCH_BIN/git"
private_no_tip_json="$(PATH="$NO_PRIVATE_FETCH_BIN:$PATH" AIRLOCK_DIR="$PRIVATE_NO_TIP_BOX" \
  AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" AIRLOCK_RELEASE_REF="$private_public_current" \
  bash "$UPDATE" --dry-run --json 2>"$scratch/private-no-tip.err")"; private_no_tip_rc=$?
[ "$private_no_tip_rc" -ne 0 ] && [ -z "$private_no_tip_json" ] \
  && ok "missing private-main evidence fails detection instead of publishing a fresh zero" \
  || bad "missing private-main evidence became a fresh detector result (rc=$private_no_tip_rc): $private_no_tip_json"

# Reading the fetched candidate's provenance is itself part of the measurement.  A
# failed subject read must not look like a semantic source mismatch and publish a
# fresh zero/checkedAt through the collector.
CANDIDATE_LOG_FAIL_BIN="$scratch/candidate-log-fail-bin"
mkdir -p "$CANDIDATE_LOG_FAIL_BIN"
cat >"$CANDIDATE_LOG_FAIL_BIN/git" <<SH
#!/usr/bin/env bash
if [ "\${1-}" = log ] && [ "\${2-}" = -1 ] && [ "\${3-}" = --format=%s ] \
   && [ "\${4-}" = "$private_public_current" ]; then
  exit 72
fi
exec "$real_git" "\$@"
SH
chmod 755 "$CANDIDATE_LOG_FAIL_BIN/git"
candidate_log_fail_json="$(PATH="$CANDIDATE_LOG_FAIL_BIN:$PATH" AIRLOCK_DIR="$PRIVATE_BOX" \
  AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" AIRLOCK_RELEASE_REF="$private_public_current" \
  bash "$UPDATE" --dry-run --json 2>"$scratch/candidate-log-fail.err")"; candidate_log_fail_rc=$?
[ "$candidate_log_fail_rc" -ne 0 ] && [ -z "$candidate_log_fail_json" ] \
  && ok "a failed candidate provenance read preserves the previous detector snapshot" \
  || bad "a failed candidate provenance read published a fresh result (rc=$candidate_log_fail_rc): $candidate_log_fail_json"

# Missing origin configuration is a legitimate generic checkout; failure to read an
# existing private identity is not.  It must not bypass the private provenance path.
ORIGIN_CONFIG_FAIL_BIN="$scratch/origin-config-fail-bin"
mkdir -p "$ORIGIN_CONFIG_FAIL_BIN"
cat >"$ORIGIN_CONFIG_FAIL_BIN/git" <<SH
#!/usr/bin/env bash
if [ "\${1-}" = config ] && [ "\${2-}" = --get ] \
   && [ "\${3-}" = remote.origin.url ]; then
  exit 72
fi
exec "$real_git" "\$@"
SH
chmod 755 "$ORIGIN_CONFIG_FAIL_BIN/git"
origin_config_fail_json="$(PATH="$ORIGIN_CONFIG_FAIL_BIN:$PATH" AIRLOCK_DIR="$PRIVATE_BOX" \
  AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" AIRLOCK_RELEASE_REF="$private_public_current" \
  bash "$UPDATE" --dry-run --json 2>"$scratch/origin-config-fail.err")"; origin_config_fail_rc=$?
[ "$origin_config_fail_rc" -ne 0 ] && [ -z "$origin_config_fail_json" ] \
  && ok "a failed origin identity read preserves the previous detector snapshot" \
  || bad "a failed origin identity read published a fresh result (rc=$origin_config_fail_rc): $origin_config_fail_json"

# A present origin/main is not necessarily a current one.  Rewind only that tracking
# ref while keeping the S1+R1 deployment at HEAD; an R0 request must not mistake S0
# for the deployed source and overwrite S1 with the older release.
PRIVATE_REWIND_BOX="$scratch/private-rewind"
git clone -q "$PRIVATE_BOX" "$PRIVATE_REWIND_BOX"
git -C "$PRIVATE_REWIND_BOX" remote set-url origin "$canonical_private"
git -C "$PRIVATE_REWIND_BOX" config "url.file://$PRIVATE_REL.insteadOf" "$canonical_private"
git -C "$PRIVATE_REWIND_BOX" remote add airlock-release "$PRIVATE_PUBLIC"
git -C "$PRIVATE_REWIND_BOX" update-ref refs/remotes/origin/main "$private_old"
private_rewind_head="$(git -C "$PRIVATE_REWIND_BOX" rev-parse HEAD)"
private_rewind_out="$(AIRLOCK_DIR="$PRIVATE_REWIND_BOX" AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" \
  AIRLOCK_RELEASE_REF="$private_public_old" bash "$UPDATE" --no-install 2>&1)"; private_rewind_rc=$?
[ "$private_rewind_rc" -ne 0 ] \
  && [ "$(git -C "$PRIVATE_REWIND_BOX" rev-parse HEAD)" = "$private_rewind_head" ] \
  && grep -q 'private-current' "$PRIVATE_REWIND_BOX/README.md" \
  && ok "a stale private-main tracking ref cannot rewind a deployed checkout" \
  || bad "a stale private-main tracking ref rewound the deployment (rc=$private_rewind_rc): $private_rewind_out"

# A release records an object-id prefix, not a revision name.  A local branch with the
# same seven hexadecimal characters must not redirect provenance resolution to S0.
PRIVATE_PREFIX_REF_BOX="$scratch/private-prefix-ref"
git clone -q "$PRIVATE_BOX" "$PRIVATE_PREFIX_REF_BOX"
git -C "$PRIVATE_PREFIX_REF_BOX" remote set-url origin "$canonical_private"
git -C "$PRIVATE_PREFIX_REF_BOX" config "url.file://$PRIVATE_REL.insteadOf" "$canonical_private"
git -C "$PRIVATE_PREFIX_REF_BOX" remote add airlock-release "$PRIVATE_PUBLIC"
git -C "$PRIVATE_PREFIX_REF_BOX" update-ref refs/remotes/origin/main "$private_old"
git -C "$PRIVATE_PREFIX_REF_BOX" branch "${private_current:0:7}" "$private_old"
private_prefix_ref_head="$(git -C "$PRIVATE_PREFIX_REF_BOX" rev-parse HEAD)"
private_prefix_ref_out="$(AIRLOCK_DIR="$PRIVATE_PREFIX_REF_BOX" AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" \
  AIRLOCK_RELEASE_REF="$private_public_old" bash "$UPDATE" --no-install 2>&1)"; private_prefix_ref_rc=$?
[ "$private_prefix_ref_rc" -ne 0 ] \
  && [ "$(git -C "$PRIVATE_PREFIX_REF_BOX" rev-parse HEAD)" = "$private_prefix_ref_head" ] \
  && grep -q 'private-current' "$PRIVATE_PREFIX_REF_BOX/README.md" \
  && ok "a ref named like a source digest cannot redirect provenance or rewind" \
  || bad "a source-digest ref collision rewound the deployment (rc=$private_prefix_ref_rc): $private_prefix_ref_out"

# A failed installed-history read is failed provenance, not permission to fall back to
# a stale tracking ref.  The shim targets only that exact graph-read shape; release fetch
# and the candidate subject read remain live controls elsewhere in this fixture.
PRIVATE_LOG_FAIL_BOX="$scratch/private-log-fail"
git clone -q "$PRIVATE_BOX" "$PRIVATE_LOG_FAIL_BOX"
git -C "$PRIVATE_LOG_FAIL_BOX" remote set-url origin "$canonical_private"
git -C "$PRIVATE_LOG_FAIL_BOX" config "url.file://$PRIVATE_REL.insteadOf" "$canonical_private"
git -C "$PRIVATE_LOG_FAIL_BOX" remote add airlock-release "$PRIVATE_PUBLIC"
git -C "$PRIVATE_LOG_FAIL_BOX" update-ref refs/remotes/origin/main "$private_old"
private_log_fail_head="$(git -C "$PRIVATE_LOG_FAIL_BOX" rev-parse HEAD)"
LOG_FAIL_BIN="$scratch/history-log-fail-bin"
mkdir -p "$LOG_FAIL_BIN"
cat >"$LOG_FAIL_BIN/git" <<SH
#!/usr/bin/env bash
if [ "\${1-}" = rev-list ] && [ "\${2-}" = --first-parent ] \
   && [ "\${3-}" = --parents ] && [ "\${4-}" = "$private_log_fail_head" ]; then
  exit 72
fi
exec "$real_git" "\$@"
SH
chmod 755 "$LOG_FAIL_BIN/git"
private_log_fail_json="$(PATH="$LOG_FAIL_BIN:$PATH" AIRLOCK_DIR="$PRIVATE_LOG_FAIL_BOX" \
  AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" AIRLOCK_RELEASE_REF="$private_public_old" \
  bash "$UPDATE" --dry-run --json 2>"$scratch/private-log-fail.err")"; private_log_fail_json_rc=$?
[ "$private_log_fail_json_rc" -ne 0 ] && [ -z "$private_log_fail_json" ] \
  && ok "a failed installed-history read preserves the previous detector snapshot" \
  || bad "a failed installed-history read published a fresh result (rc=$private_log_fail_json_rc): $private_log_fail_json"
private_log_fail_out="$(PATH="$LOG_FAIL_BIN:$PATH" AIRLOCK_DIR="$PRIVATE_LOG_FAIL_BOX" \
  AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" AIRLOCK_RELEASE_REF="$private_public_old" \
  bash "$UPDATE" --no-install 2>&1)"; private_log_fail_rc=$?
[ "$private_log_fail_rc" -ne 0 ] \
  && [ "$(git -C "$PRIVATE_LOG_FAIL_BOX" rev-parse HEAD)" = "$private_log_fail_head" ] \
  && grep -q 'private-current' "$PRIVATE_LOG_FAIL_BOX/README.md" \
  && ok "a failed installed-history read cannot fall back to stale provenance" \
  || bad "a failed installed-history read rewound the deployment (rc=$private_log_fail_rc): $private_log_fail_out"

# Commit timestamps and a whole-graph `git log` do not identify which public release
# was deployed last.  Preserve two divergent public release parents under HEAD, make
# the older deployment's timestamp newer, and require the last deployment merge to
# win.  Otherwise requesting R0 can silently replace the later S1+R1 deployment.
DIVERGENT_PUBLIC="$scratch/private-divergent/$PRIVATE_PUBLIC_NAME"
seed_tree "$DIVERGENT_PUBLIC" private-old
git -C "$DIVERGENT_PUBLIC" init -q -b old
git -C "$DIVERGENT_PUBLIC" add -A
GIT_AUTHOR_DATE='2030-01-01T00:00:00Z' GIT_COMMITTER_DATE='2030-01-01T00:00:00Z' \
  git -C "$DIVERGENT_PUBLIC" commit -q \
  -m "release from ${PRIVATE_SOURCE_NAME} @ ${private_old:0:7}"
divergent_public_old="$(git -C "$DIVERGENT_PUBLIC" rev-parse HEAD)"
git -C "$DIVERGENT_PUBLIC" checkout -q --orphan current
git -C "$DIVERGENT_PUBLIC" rm -q -rf .
seed_tree "$DIVERGENT_PUBLIC" private-current
git -C "$DIVERGENT_PUBLIC" add -A
GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' \
  git -C "$DIVERGENT_PUBLIC" commit -q \
  -m "release from ${PRIVATE_SOURCE_NAME} @ ${private_current:0:7}"
divergent_public_current="$(git -C "$DIVERGENT_PUBLIC" rev-parse HEAD)"

PRIVATE_DIVERGENT_BOX="$scratch/private-divergent-deployment"
git clone -q "$PRIVATE_REL" "$PRIVATE_DIVERGENT_BOX"
git -C "$PRIVATE_DIVERGENT_BOX" checkout -q -b deployed-divergent "$private_old"
git -C "$PRIVATE_DIVERGENT_BOX" remote set-url origin "$canonical_private"
git -C "$PRIVATE_DIVERGENT_BOX" config "url.file://$PRIVATE_REL.insteadOf" "$canonical_private"
git -C "$PRIVATE_DIVERGENT_BOX" remote add airlock-release "$DIVERGENT_PUBLIC"
git -C "$PRIVATE_DIVERGENT_BOX" fetch -q airlock-release "$divergent_public_old"
git -C "$PRIVATE_DIVERGENT_BOX" merge -q --allow-unrelated-histories -s ours \
  -m "deploy old divergent release" FETCH_HEAD
git -C "$PRIVATE_DIVERGENT_BOX" merge -q \
  -m "advance private source" "$private_current"
git -C "$PRIVATE_DIVERGENT_BOX" fetch -q airlock-release "$divergent_public_current"
git -C "$PRIVATE_DIVERGENT_BOX" merge -q --allow-unrelated-histories -s ours \
  -m "deploy current divergent release" FETCH_HEAD
git -C "$PRIVATE_DIVERGENT_BOX" update-ref refs/remotes/origin/main "$private_old"
private_divergent_head="$(git -C "$PRIVATE_DIVERGENT_BOX" rev-parse HEAD)"
private_divergent_out="$(AIRLOCK_DIR="$PRIVATE_DIVERGENT_BOX" \
  AIRLOCK_RELEASE_URL="$DIVERGENT_PUBLIC" AIRLOCK_RELEASE_REF="$divergent_public_old" \
  bash "$UPDATE" --no-install 2>&1)"; private_divergent_rc=$?
[ "$private_divergent_rc" -ne 0 ] \
  && [ "$(git -C "$PRIVATE_DIVERGENT_BOX" rev-parse HEAD)" = "$private_divergent_head" ] \
  && grep -q 'private-current' "$PRIVATE_DIVERGENT_BOX/README.md" \
  && ok "the last deployment merge wins when public release histories diverge" \
  || bad "commit-date ordering selected an older divergent release (rc=$private_divergent_rc): $private_divergent_out"

# A ref can exist and still be too old.  Keep origin/main at the deployed source while
# making the newer source object available under no ref, so this distinguishes a real
# freshness check from a mere "does the ref exist?" check.
seed_tree "$PRIVATE_REL" private-future
git -C "$PRIVATE_REL" add -A
git -C "$PRIVATE_REL" commit -q -m "private future"
private_future="$(git -C "$PRIVATE_REL" rev-parse HEAD)"
seed_tree "$PRIVATE_PUBLIC" private-future
git -C "$PRIVATE_PUBLIC" add -A
git -C "$PRIVATE_PUBLIC" commit -q \
  -m "release from ${PRIVATE_SOURCE_NAME} @ ${private_future:0:7}"
private_public_future="$(git -C "$PRIVATE_PUBLIC" rev-parse HEAD)"
git -C "$PRIVATE_BOX" fetch -q "$PRIVATE_REL" "$private_future"
[ "$(git -C "$PRIVATE_BOX" rev-parse refs/remotes/origin/main)" = "$private_current" ] \
  && git -C "$PRIVATE_BOX" cat-file -e "${private_future}^{commit}" \
  && ok "positive control: private main is stale while the future source object exists" \
  || bad "positive control: stale private-main fixture is not discriminating"
private_old_tip_json="$(AIRLOCK_DIR="$PRIVATE_BOX" AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" \
  AIRLOCK_RELEASE_REF="$private_public_future" bash "$UPDATE" --dry-run --json \
  2>"$scratch/private-old-tip.err")"; private_old_tip_rc=$?
if [ "$private_old_tip_rc" = 0 ] && printf '%s' "$private_old_tip_json" | python3 -c '
import json, sys
value = json.load(sys.stdin)
assert value["available"] is True, value
assert value["changedCount"] > 0, value
'; then
  ok "public release ancestry keeps forward detection live with a stale private-main ref"
else
  bad "a stale private-main ref hid a forward release (rc=$private_old_tip_rc): $private_old_tip_json"
fi

# The normal future-release case does not have the future private source object at
# all.  Clone only reachable deployment refs after the object-only fetch above, then
# pin its remote-tracking main to the deployed source and prove the object is absent.
PRIVATE_NO_SOURCE_BOX="$scratch/private-no-source"
git clone -q --no-local "file://$PRIVATE_BOX" "$PRIVATE_NO_SOURCE_BOX"
git -C "$PRIVATE_NO_SOURCE_BOX" remote set-url origin "$canonical_private"
git -C "$PRIVATE_NO_SOURCE_BOX" config "url.file://$PRIVATE_REL.insteadOf" "$canonical_private"
git -C "$PRIVATE_NO_SOURCE_BOX" remote add airlock-release "$PRIVATE_PUBLIC"
git -C "$PRIVATE_NO_SOURCE_BOX" update-ref refs/remotes/origin/main "$private_current"
if git -C "$PRIVATE_NO_SOURCE_BOX" cat-file -e "${private_future}^{commit}" 2>/dev/null; then
  bad "positive control: the future private source leaked into the no-source fixture"
else
  ok "positive control: the future private source object is absent"
fi
private_no_source_json="$(AIRLOCK_DIR="$PRIVATE_NO_SOURCE_BOX" AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" \
  AIRLOCK_RELEASE_REF="$private_public_future" bash "$UPDATE" --dry-run --json \
  2>"$scratch/private-no-source.err")"; private_no_source_rc=$?
if [ "$private_no_source_rc" = 0 ] && printf '%s' "$private_no_source_json" | python3 -c '
import json, sys
value = json.load(sys.stdin)
assert value["available"] is True, value
assert value["changedCount"] > 0, value
'; then
  ok "public release ancestry detects forward without the future private source object"
else
  bad "a missing future private source object hid a forward release (rc=$private_no_source_rc): $private_no_source_json"
fi

# Candidate-history provenance must pass through the same unique-commit resolver as
# every other Source-Digest consumer.  A textual prefix match is not evidence when
# Git reports that the prefix names more than one object.
PRIVATE_AMBIGUOUS_HISTORY_BOX="$scratch/private-ambiguous-history"
git clone -q --no-local "file://$PRIVATE_NO_SOURCE_BOX" "$PRIVATE_AMBIGUOUS_HISTORY_BOX"
git -C "$PRIVATE_AMBIGUOUS_HISTORY_BOX" checkout -q -B installed-source "$private_current"
git -C "$PRIVATE_AMBIGUOUS_HISTORY_BOX" remote set-url origin "$canonical_private"
git -C "$PRIVATE_AMBIGUOUS_HISTORY_BOX" config \
  "url.file://$PRIVATE_REL.insteadOf" "$canonical_private"
git -C "$PRIVATE_AMBIGUOUS_HISTORY_BOX" remote add airlock-release "$PRIVATE_PUBLIC"
git -C "$PRIVATE_AMBIGUOUS_HISTORY_BOX" update-ref \
  refs/remotes/origin/main "$private_current"
[ "$(git -C "$PRIVATE_AMBIGUOUS_HISTORY_BOX" rev-parse HEAD)" = "$private_current" ] \
  && ! git -C "$PRIVATE_AMBIGUOUS_HISTORY_BOX" cat-file -e \
    "${private_future}^{commit}" 2>/dev/null \
  && ok "positive control: candidate history must recover the installed source" \
  || bad "positive control: another provenance path can decide the ambiguous-history fixture"
AMBIGUOUS_HISTORY_BIN="$scratch/ambiguous-history-bin"
mkdir -p "$AMBIGUOUS_HISTORY_BIN"
ambiguous_history_peer="${private_current:0:7}${private_old:7}"
cat >"$AMBIGUOUS_HISTORY_BIN/git" <<SH
#!/usr/bin/env bash
if [ "\${1-}" = rev-parse ] \
   && [ "\${2-}" = "--disambiguate=${private_current:0:7}" ]; then
  printf '%s\n' "$private_current" "$ambiguous_history_peer"
  exit 0
fi
exec "$real_git" "\$@"
SH
chmod 755 "$AMBIGUOUS_HISTORY_BIN/git"
ambiguous_history_objects="$(cd "$PRIVATE_AMBIGUOUS_HISTORY_BOX" \
  && PATH="$AMBIGUOUS_HISTORY_BIN:$PATH" \
  git rev-parse --disambiguate="${private_current:0:7}")"
printf '%s\n' "$ambiguous_history_objects" | awk \
  -v prefix="${private_current:0:7}" 'NF { count++; if (index($0, prefix) != 1) bad=1 } END { exit !(count == 2 && !bad) }' \
  && ok "positive control: the installed-source token resolves to two objects" \
  || bad "positive control: the installed-source token is not ambiguous"
ambiguous_history_json="$(PATH="$AMBIGUOUS_HISTORY_BIN:$PATH" \
  AIRLOCK_DIR="$PRIVATE_AMBIGUOUS_HISTORY_BOX" AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" \
  AIRLOCK_RELEASE_REF="$private_public_future" bash "$UPDATE" --dry-run --json \
  2>"$scratch/ambiguous-history.err")"; ambiguous_history_rc=$?
[ "$ambiguous_history_rc" -ne 0 ] && [ -z "$ambiguous_history_json" ] \
  && ok "an ambiguous candidate-history source digest preserves the detector snapshot" \
  || bad "an ambiguous candidate-history source digest became a fresh result (rc=$ambiguous_history_rc): $ambiguous_history_json"

# Zero matching objects is a normal consequence of the one-fetch design, but failure
# of the object lookup command is not.  Only the former may use public ancestry.
DISAMBIGUATE_FAIL_BIN="$scratch/disambiguate-fail-bin"
mkdir -p "$DISAMBIGUATE_FAIL_BIN"
cat >"$DISAMBIGUATE_FAIL_BIN/git" <<SH
#!/usr/bin/env bash
if [ "\${1-}" = rev-parse ] \
   && [ "\${2-}" = "--disambiguate=${private_future:0:7}" ]; then
  exit 72
fi
exec "$real_git" "\$@"
SH
chmod 755 "$DISAMBIGUATE_FAIL_BIN/git"
disambiguate_fail_json="$(PATH="$DISAMBIGUATE_FAIL_BIN:$PATH" \
  AIRLOCK_DIR="$PRIVATE_NO_SOURCE_BOX" AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" \
  AIRLOCK_RELEASE_REF="$private_public_future" bash "$UPDATE" --dry-run --json \
  2>"$scratch/disambiguate-fail.err")"; disambiguate_fail_rc=$?
[ "$disambiguate_fail_rc" -ne 0 ] && [ -z "$disambiguate_fail_json" ] \
  && ok "a failed object-prefix lookup preserves the previous detector snapshot" \
  || bad "an object-prefix lookup failure became a fresh result (rc=$disambiguate_fail_rc): $disambiguate_fail_json"

# A Source-Digest names a private commit.  If its unique object prefix peels only to
# a blob, public release ancestry must not reinterpret that malformed provenance as a
# merely absent future source and install it.
seed_tree "$PRIVATE_PUBLIC" private-invalid-source
printf 'not a commit\n' >"$PRIVATE_PUBLIC/invalid-source-object"
git -C "$PRIVATE_PUBLIC" add -A
invalid_source_blob="$(git -C "$PRIVATE_PUBLIC" hash-object invalid-source-object)"
git -C "$PRIVATE_PUBLIC" commit -q \
  -m "release from ${PRIVATE_SOURCE_NAME} @ ${invalid_source_blob:0:7}"
private_public_invalid_source="$(git -C "$PRIVATE_PUBLIC" rev-parse HEAD)"
PRIVATE_INVALID_SOURCE_BOX="$scratch/private-invalid-source"
git clone -q "$PRIVATE_BOX" "$PRIVATE_INVALID_SOURCE_BOX"
git -C "$PRIVATE_INVALID_SOURCE_BOX" remote set-url origin "$canonical_private"
git -C "$PRIVATE_INVALID_SOURCE_BOX" config "url.file://$PRIVATE_REL.insteadOf" "$canonical_private"
git -C "$PRIVATE_INVALID_SOURCE_BOX" remote add airlock-release "$PRIVATE_PUBLIC"
private_invalid_source_head="$(git -C "$PRIVATE_INVALID_SOURCE_BOX" rev-parse HEAD)"
private_invalid_source_out="$(AIRLOCK_DIR="$PRIVATE_INVALID_SOURCE_BOX" \
  AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" AIRLOCK_RELEASE_REF="$private_public_invalid_source" \
  bash "$UPDATE" --no-install 2>&1)"; private_invalid_source_rc=$?
[ "$private_invalid_source_rc" -ne 0 ] \
  && [ "$(git -C "$PRIVATE_INVALID_SOURCE_BOX" rev-parse HEAD)" = "$private_invalid_source_head" ] \
  && grep -q 'private-current' "$PRIVATE_INVALID_SOURCE_BOX/README.md" \
  && ok "a non-commit source digest cannot bypass provenance through public ancestry" \
  || bad "a release naming a blob as its source was installed (rc=$private_invalid_source_rc): $private_invalid_source_out"

# An annotated tag's object ID is not the commit it targets.  Source-Digest must
# name the commit object itself; accepting the tag object via ^{commit} would turn
# malformed provenance into a successful, fresh detector result.
git -C "$PRIVATE_INVALID_SOURCE_BOX" tag -a invalid-source-tag \
  -m "invalid source tag" "$private_current"
invalid_source_tag="$(git -C "$PRIVATE_INVALID_SOURCE_BOX" rev-parse refs/tags/invalid-source-tag)"
[ "$(git -C "$PRIVATE_INVALID_SOURCE_BOX" cat-file -t "$invalid_source_tag")" = tag ] \
  && ok "positive control: the invalid source digest names an annotated tag object" \
  || bad "positive control: the invalid source digest is not an annotated tag object"
seed_tree "$PRIVATE_PUBLIC" private-invalid-tag-source
git -C "$PRIVATE_PUBLIC" add -A
git -C "$PRIVATE_PUBLIC" commit -q \
  -m "release from ${PRIVATE_SOURCE_NAME} @ ${invalid_source_tag:0:12}"
private_public_invalid_tag_source="$(git -C "$PRIVATE_PUBLIC" rev-parse HEAD)"
private_invalid_tag_json="$(AIRLOCK_DIR="$PRIVATE_INVALID_SOURCE_BOX" \
  AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" AIRLOCK_RELEASE_REF="$private_public_invalid_tag_source" \
  bash "$UPDATE" --dry-run --json 2>"$scratch/private-invalid-tag.err")"; private_invalid_tag_rc=$?
[ "$private_invalid_tag_rc" -ne 0 ] && [ -z "$private_invalid_tag_json" ] \
  && ok "an annotated-tag source digest preserves the previous detector snapshot" \
  || bad "an annotated-tag source digest became a fresh result (rc=$private_invalid_tag_rc): $private_invalid_tag_json"

private_stale_json="$(AIRLOCK_DIR="$PRIVATE_BOX" AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" \
  AIRLOCK_RELEASE_REF="$private_public_old" bash "$UPDATE" --dry-run --json \
  2>"$scratch/private-stale.err")"; private_stale_json_rc=$?
if [ "$private_stale_json_rc" = 0 ] && printf '%s' "$private_stale_json" | python3 -c '
import json, sys
value = json.load(sys.stdin)
assert value["available"] is False, value
assert value["changedCount"] == 0, value
'; then
  ok "a private deployment checkout hides a release behind its deployed source"
else
  bad "a private deployment checkout reported its older release as available: $private_stale_json"
fi
private_stale_out="$(AIRLOCK_DIR="$PRIVATE_BOX" AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" \
  AIRLOCK_RELEASE_REF="$private_public_old" bash "$UPDATE" --no-install 2>&1)"
private_stale_rc=$?
[ "$private_stale_rc" -ne 0 ] \
  && [ "$(git -C "$PRIVATE_BOX" rev-parse HEAD)" = "$private_deploy_head" ] \
  && grep -q 'private-current' "$PRIVATE_BOX/README.md" \
  && ok "a stale release cannot rewind a private deployment checkout" \
  || bad "a stale release mutated a private deployment checkout (rc=$private_stale_rc): $private_stale_out"

private_same_out="$(AIRLOCK_DIR="$PRIVATE_BOX" AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" \
  AIRLOCK_RELEASE_REF="$private_public_current" bash "$UPDATE" --no-install 2>&1)"; private_same_rc=$?
[ "$private_same_rc" = 0 ] \
  && [ "$(git -C "$PRIVATE_BOX" rev-parse HEAD)" = "$private_deploy_head" ] \
  && grep -q '이미 같은 배포본' <<<"$private_same_out" \
  && ok "a merge-wrapper deployment recognises its current release as current" \
  || bad "a merge-wrapper deployment mistook its current release for rollback: $private_same_out"

private_mismatch_json="$(AIRLOCK_DIR="$PRIVATE_BOX" AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" \
  AIRLOCK_RELEASE_REF="$private_public_mismatch" bash "$UPDATE" --dry-run --json \
  2>"$scratch/private-mismatch.err")"; private_mismatch_json_rc=$?
if [ "$private_mismatch_json_rc" = 0 ] && printf '%s' "$private_mismatch_json" | python3 -c '
import json, sys
value = json.load(sys.stdin)
assert value["available"] is False, value
assert value["changedCount"] == 0, value
'; then
  ok "a release naming another source produces no update badge"
else
  bad "a mismatched release source was offered as an update: $private_mismatch_json"
fi
private_mismatch_out="$(AIRLOCK_DIR="$PRIVATE_BOX" AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" \
  AIRLOCK_RELEASE_REF="$private_public_mismatch" bash "$UPDATE" --no-install 2>&1)"
private_mismatch_rc=$?
[ "$private_mismatch_rc" -ne 0 ] \
  && [ "$(git -C "$PRIVATE_BOX" rev-parse HEAD)" = "$private_deploy_head" ] \
  && grep -q 'private-current' "$PRIVATE_BOX/README.md" \
  && ok "a release naming another source is refused before checkout mutation" \
  || bad "a mismatched release source reached the checkout (rc=$private_mismatch_rc): $private_mismatch_out"

# A well-formed release naming another source is a measured semantic non-update,
# covered above.  A candidate with no source provenance is different: the detector
# cannot measure its direction and must leave the collector's last snapshot intact.
private_no_provenance_json="$(AIRLOCK_DIR="$PRIVATE_BOX" AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" \
  AIRLOCK_RELEASE_REF="$private_public_no_provenance" bash "$UPDATE" --dry-run --json \
  2>"$scratch/private-no-provenance.err")"; private_no_provenance_rc=$?
[ "$private_no_provenance_rc" -ne 0 ] && [ -z "$private_no_provenance_json" ] \
  && ok "a release without provenance preserves the previous detector snapshot" \
  || bad "a release without provenance published a fresh zero (rc=$private_no_provenance_rc): $private_no_provenance_json"

PRIVATE_OLD_BOX="$scratch/private-old-deployment"
git clone -q "$PRIVATE_REL" "$PRIVATE_OLD_BOX"
git -C "$PRIVATE_OLD_BOX" checkout -q -b deploy-old "$private_old"
git -C "$PRIVATE_OLD_BOX" remote set-url origin "$canonical_private"
git -C "$PRIVATE_OLD_BOX" config "url.file://$PRIVATE_REL.insteadOf" "$canonical_private"
private_old_head="$(git -C "$PRIVATE_OLD_BOX" rev-parse HEAD)"
private_side_json="$(AIRLOCK_DIR="$PRIVATE_OLD_BOX" AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" \
  AIRLOCK_RELEASE_REF="$private_public_side" bash "$UPDATE" --dry-run --json \
  2>"$scratch/private-side.err")"; private_side_json_rc=$?
if [ "$private_side_json_rc" = 0 ] && printf '%s' "$private_side_json" | python3 -c '
import json, sys
value = json.load(sys.stdin)
assert value["available"] is False, value
assert value["changedCount"] == 0, value
'; then
  ok "a release sourced outside private main is never offered as an update"
else
  bad "an off-main source was offered as a release: $private_side_json"
fi
private_side_out="$(AIRLOCK_DIR="$PRIVATE_OLD_BOX" AIRLOCK_RELEASE_URL="$PRIVATE_PUBLIC" \
  AIRLOCK_RELEASE_REF="$private_public_side" bash "$UPDATE" --no-install 2>&1)"
private_side_rc=$?
[ "$private_side_rc" -ne 0 ] \
  && [ "$(git -C "$PRIVATE_OLD_BOX" rev-parse HEAD)" = "$private_old_head" ] \
  && grep -q '배포본 방향이 모호' <<<"$private_side_out" \
  && ok "an off-main release source is refused before checkout mutation" \
  || bad "an off-main release source reached the checkout (rc=$private_side_rc): $private_side_out"

# A failed provenance measurement is not an empty diff.  Make only `git diff` fail;
# fetch and every other git operation remain live positive controls.
DIFF_FAIL_BIN="$scratch/diff-fail-bin"
mkdir -p "$DIFF_FAIL_BIN"
# The pinned real git, not `command -v git`: by the time this shim is built the
# guard is already on PATH, so command -v would capture the guard and the two
# shims would call each other forever (install/test-lib.sh explains it).
real_git="$AIRLOCK_TEST_GUARD_REAL_GIT"
cat >"$DIFF_FAIL_BIN/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  [ "\$arg" != diff ] || exit 72
done
exec "$real_git" "\$@"
SH
chmod 755 "$DIFF_FAIL_BIN/git"
make_box "$BOX"
diff_fail_head="$(git -C "$BOX" rev-parse HEAD)"
diff_fail_json="$(PATH="$DIFF_FAIL_BIN:$PATH" AIRLOCK_DIR="$BOX" \
  AIRLOCK_RELEASE_URL="$REL" bash "$UPDATE" --dry-run --json \
  2>"$scratch/diff-fail.err")"; diff_fail_json_rc=$?
[ "$diff_fail_json_rc" -ne 0 ] && [ -z "$diff_fail_json" ] \
  && ok "a failed direction diff preserves the previous detector snapshot" \
  || bad "a failed direction diff published a fresh result (rc=$diff_fail_json_rc): $diff_fail_json"
diff_fail_out="$(PATH="$DIFF_FAIL_BIN:$PATH" AIRLOCK_DIR="$BOX" \
  AIRLOCK_RELEASE_URL="$REL" bash "$UPDATE" --no-install 2>&1)"
diff_fail_rc=$?
[ "$diff_fail_rc" -ne 0 ] \
  && [ "$(git -C "$BOX" rev-parse HEAD)" = "$diff_fail_head" ] \
  && grep -q 'version old' "$BOX/README.md" \
  && ok "a failed direction diff is refused before checkout mutation" \
  || bad "a failed direction diff was treated as a match (rc=$diff_fail_rc): $diff_fail_out"

# A marker resolves direction without consulting the worktree diff above.  Exercise
# the later, final changed-file measurement independently: its failure must still be
# a detector failure, never a fresh-looking zero result.
MARKER_DIFF_BOX="$scratch/marker-diff-box"
mkdir -p "$MARKER_DIFF_BOX"
git -C "$DIRECTION_REL" archive "$direction_old" | tar -x -C "$MARKER_DIFF_BOX"
git -C "$MARKER_DIFF_BOX" init -q -b main
git -C "$MARKER_DIFF_BOX" remote add airlock-release "$DIRECTION_REL"
git -C "$MARKER_DIFF_BOX" fetch -q airlock-release "$direction_current"
git -C "$MARKER_DIFF_BOX" add -A
git -C "$MARKER_DIFF_BOX" commit -q \
  -m "airlock-update: 배포본 ${direction_old:0:12} 으로 갱신"
marker_diff_json="$(PATH="$DIFF_FAIL_BIN:$PATH" AIRLOCK_DIR="$MARKER_DIFF_BOX" \
  AIRLOCK_RELEASE_URL="$DIRECTION_REL" AIRLOCK_RELEASE_REF="$direction_current" \
  bash "$UPDATE" --dry-run --json 2>"$scratch/marker-diff.err")"; marker_diff_rc=$?
[ "$marker_diff_rc" -ne 0 ] && [ -z "$marker_diff_json" ] \
  && ok "a failed final diff after marker direction preserves the detector snapshot" \
  || bad "a failed final diff after marker direction published a fresh result (rc=$marker_diff_rc): $marker_diff_json"

AWK_FAIL_BIN="$scratch/awk-fail-bin"
mkdir -p "$AWK_FAIL_BIN"
cat >"$AWK_FAIL_BIN/awk" <<'SH'
#!/usr/bin/env bash
exit 72
SH
chmod 755 "$AWK_FAIL_BIN/awk"
marker_count_json="$(PATH="$AWK_FAIL_BIN:$PATH" AIRLOCK_DIR="$MARKER_DIFF_BOX" \
  AIRLOCK_RELEASE_URL="$DIRECTION_REL" AIRLOCK_RELEASE_REF="$direction_current" \
  bash "$UPDATE" --dry-run --json 2>"$scratch/marker-count.err")"; marker_count_rc=$?
[ "$marker_count_rc" -ne 0 ] && [ -z "$marker_count_json" ] \
  && ok "a failed final change count preserves the detector snapshot" \
  || bad "a failed final change count exited successfully (rc=$marker_count_rc): $marker_count_json"

JSON_FAIL_BIN="$scratch/json-fail-bin"
mkdir -p "$JSON_FAIL_BIN"
cat >"$JSON_FAIL_BIN/python3" <<SH
#!/usr/bin/env bash
if [ "\${1-}" = - ] && { [ "\${2-}" = 0 ] || [ "\${2-}" = 1 ]; }; then
  exit 72
fi
exec "$(command -v python3)" "\$@"
SH
chmod 755 "$JSON_FAIL_BIN/python3"
marker_json_fail_out="$(PATH="$JSON_FAIL_BIN:$PATH" AIRLOCK_DIR="$MARKER_DIFF_BOX" \
  AIRLOCK_RELEASE_URL="$DIRECTION_REL" AIRLOCK_RELEASE_REF="$direction_current" \
  bash "$UPDATE" --dry-run --json 2>"$scratch/marker-json-fail.err")"; marker_json_fail_rc=$?
[ "$marker_json_fail_rc" -ne 0 ] && [ -z "$marker_json_fail_out" ] \
  && ok "a failed JSON serialization is not reported as detector success" \
  || bad "a failed JSON serialization exited successfully (rc=$marker_json_fail_rc): $marker_json_fail_out"

# ---------------------------------------------------------------- 5) refuses strangers
notabox="$scratch/not-a-checkout"; mkdir -p "$notabox"; printf 'hi\n' > "$notabox/file"
AIRLOCK_DIR="$notabox" AIRLOCK_RELEASE_URL="$REL" bash "$UPDATE" --no-install >/dev/null 2>&1 \
  && bad "ran against a directory that is not an Airlock checkout" \
  || ok "refuses a directory that is not an Airlock checkout"
[ -d "$notabox/.git" ] && bad "it initialised a repository in a stranger's directory" \
                       || ok "and left that directory completely alone"

# ---------------------------------------------------------------- 6) REVIEW: truncation
# `curl … | bash` executes what has arrived. A cut-off transfer used to replace every
# file, skip the commit, skip the installer and exit 0 — and the .command wrapper then
# printed "끝났습니다". The body now lives in main(), called on the last line, so a
# truncated script is a syntax error instead of half an update.
bytes="$(wc -c < "$UPDATE")"
for frac in 30 60 90; do
  make_box "$BOX"
  head -c "$(( bytes * frac / 100 ))" "$UPDATE" > "$scratch/truncated"
  AIRLOCK_DIR="$BOX" AIRLOCK_RELEASE_URL="$REL" bash "$scratch/truncated" --no-install >/dev/null 2>&1
  trc=$?
  if [ "$trc" = 0 ]; then
    bad "a script truncated at ${frac}% exited 0"
  elif grep -q 'version new' "$BOX/README.md" 2>/dev/null; then
    bad "a script truncated at ${frac}% still replaced files"
  else
    ok "a script truncated at ${frac}% does nothing and fails loudly"
  fi
done

# ---------------------------------------------------------------- 7) the Mac branch
STUB="$scratch/stub"; mkdir -p "$STUB"
# Keys on the MARKER PATH as well as the name. REVIEW: keying on the name alone let a
# mutation replace /opt/airlock/hub with a nonsense path and stay green.
make_orb() {   # make_orb <machine-with-airlock>...
  { echo '#!/usr/bin/env bash'
    echo 'case "$1" in'
    echo '  list) printf "%s\n" "NAME  STATE" "alice-box  running" "bob-box  running" "scratch  running" "napping  stopped" ;;'
    echo '  run)  shift; [ "$1" = -m ] || exit 9; shift; m="$1"; shift'
    echo '        printf "%s\n" "$m" >> "${ORB_PROBE_LOG:-/dev/null}"'
    echo '        [ "$1" = test ] && [ "$2" = -d ] || exit 9'
    echo '        [ "$3" = "/opt/airlock/hub" ] || exit 1
        # The header word qualifies on purpose. Real `orb list` prints no header into a
        # pipe (measured), so the filter is defence in depth — and defence in depth that
        # nothing exercises is indistinguishable from defence that was deleted.
        [ "$m" = NAME ] && exit 0'
    printf '        case "$m" in %s) exit 0 ;; *) exit 1 ;; esac ;;\n' "$(IFS='|'; echo "$*")"
    echo '  *) exit 9 ;;'
    echo 'esac'
  } > "$STUB/orb"
  chmod 755 "$STUB/orb"
}
run_mac() { AIRLOCK_DIR="$BOX" AIRLOCK_RELEASE_URL="$REL" AIRLOCK_UPDATE_UNAME=Darwin \
            ORB_PROBE_LOG="${ORB_PROBE_LOG:-/dev/null}" \
            PATH="$STUB:$PATH" bash "$UPDATE" "$@" 2>&1; }

make_box "$BOX"; make_orb bob-box
out4="$(run_mac)"
printf '%s' "$out4" | grep -q 'MACHINE=bob-box' \
  && ok "detects the one machine that has Airlock and hands the installer its name" \
  || bad "the installer did not receive the detected machine name: $out4"
printf '%s' "$out4" | grep -qE 'MACHINE=airlock$' \
  && bad "it fell back to the default name — this would install into a second machine"
# The positive control for the check above.
make_box "$BOX"
printf '%s' "$(AIRLOCK_MACHINE= bash "$BOX/docker/orbstack-machine-setup.sh")" \
  | grep -q 'MACHINE=bob-box' \
  && bad "positive control: the fixture names bob-box unprompted, so the check proves nothing" \
  || ok "positive control: the fixture only reports a name when one is passed"
# And that the marker path is load-bearing, not decoration.
make_box "$BOX"; make_orb bob-box
printf '%s' "$(run_mac --machine scratch)" | grep -q 'MACHINE=scratch' \
  && bad "a machine WITHOUT the Airlock marker was accepted" \
  || ok "the marker, not the name, is what qualifies a machine"

# The header word qualifies in the stub, so a listing whose header reaches the probe
# sees two candidates and must stop.
#
# Two independent things keep it out: the `NAME` check and the running-state filter
# (a header's second column is not `running`). So deleting EITHER one alone leaves this
# green — that is redundancy, not a gap, and deleting both is caught. Recorded here
# because a mutation run will show the single-filter deletion surviving, and the next
# person should not spend an afternoon on it.
make_box "$BOX"; make_orb bob-box
printf '%s' "$(run_mac)" | grep -q 'MACHINE=bob-box' \
  && ok "the listing header is not mistaken for a machine" \
  || bad "a header line was treated as a machine name"

# A stopped machine must not be probed: `orb run` STARTS one, so probing everything
# would boot every OrbStack machine the operator owns as a side effect of a question.
make_box "$BOX"; make_orb bob-box
probe_log="$scratch/probes"; : > "$probe_log"
ORB_PROBE_LOG="$probe_log" run_mac >/dev/null 2>&1
grep -qx 'napping' "$probe_log" \
  && bad "a stopped machine was probed — that boots it" \
  || ok "stopped machines are not probed (probing would start them)"
grep -qx 'bob-box' "$probe_log" \
  && ok "positive control: running machines really were probed" \
  || bad "positive control: nothing was probed at all, so the check above proves nothing"

make_box "$BOX"; make_orb alice-box bob-box
out5="$(run_mac)"; rc5=$?
[ "$rc5" -ne 0 ] && ok "stops when more than one machine has Airlock" \
                 || bad "it picked one of two candidate machines by itself"
printf '%s' "$out5" | grep -q -- '--machine' \
  && ok "and names the option that resolves it" || bad "no guidance on how to choose"
# REVIEW: detection must run BEFORE the overwrite. Failing after it leaves the worst
# state — a new checkout against an old install, which is neither version.
grep -q 'version old' "$BOX/README.md" \
  && ok "and it stops before touching any file" \
  || bad "it overwrote the tree and only then discovered it could not proceed"

make_box "$BOX"; make_orb none-of-them
out6="$(run_mac)"; rc6=$?
[ "$rc6" -ne 0 ] && ok "stops when no machine has Airlock" \
                 || bad "it continued with no Airlock machine present"
printf '%s' "$out6" | grep -q 'MACHINE=' \
  && bad "it ran the setup script anyway — that would create a machine, not update one" \
  || ok "and does not reach the setup script"

# REVIEW: --machine is the documented escape from every failure above, and it used to
# be passed through unchecked. One typo and the setup script CREATES that machine.
make_box "$BOX"; make_orb bob-box
out7="$(run_mac --machine bob-boxx)"; rc7=$?
[ "$rc7" -ne 0 ] && ok "--machine with a typo is refused, not passed through" \
                 || bad "an unknown --machine reached the setup script: it would create it"
printf '%s' "$out7" | grep -q 'MACHINE=' \
  && bad "the setup script ran with an unverified machine name"
make_box "$BOX"; make_orb chosen-one
printf '%s' "$(run_mac --machine chosen-one)" | grep -q 'MACHINE=chosen-one' \
  && ok "--machine is honoured when the machine really has Airlock" \
  || bad "a valid --machine was rejected"

# `orb list` failing is not the same as "no machine has Airlock", and reporting the
# second sends the operator to --machine, the one path that can build a machine.
make_box "$BOX"
printf '#!/usr/bin/env bash\nexit 3\n' > "$STUB/orb"; chmod 755 "$STUB/orb"
out8="$(run_mac)"
printf '%s' "$out8" | grep -q 'OrbStack 이 켜져 있는지' \
  && ok "a failing orb list is reported as itself, not as 'no machine has Airlock'" \
  || bad "OrbStack being down was reported as 'no machine has Airlock' — that sends the operator to --machine"

# ---------------------------------------------------------------- 8) failed install rollback
# This fixture gives status one observable machine fact: the version marker the
# installer left.  A failed new installer writes "new-partial" and exits 42, so the
# no-rollback control is red; the old installer writes "old", so a real rollback can
# only turn green by actually running it.  No production-only fault switch is needed.
make_rollback_tree() { # make_rollback_tree <dir> <old|new> [keep-git]
  local d="$1" version="$2" keep_git="${3:-}"
  if [ "$keep_git" = keep-git ]; then
    find "$d" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf -- {} +
  else
    rm -rf "$d"
  fi
  seed_tree "$d" "$version"
  printf 'airlock.lock\n' >>"$d/.gitignore"
  # The updater treats installation state as an opaque ledger module contract.
  # This test double exposes the same API and records teardown invocations.
  cat >"$d/bin/airlock-ledger" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib

def installed_path():
    return pathlib.Path(os.environ["AIRLOCK_STATE_DIR"]) / "installed-apps.json"

def load_installed():
    return json.loads(installed_path().read_text()) if installed_path().exists() else {}

def read_installed_bytes():
    return installed_path().read_bytes() if installed_path().exists() else None

def validate_installed_bytes(raw):
    value = json.loads(raw)
    assert isinstance(value, dict)
    return value

def snapshot_installed(target):
    raw = read_installed_bytes()
    if raw is None:
        return False
    target.write_bytes(raw)
    return True

def restore_installed(source):
    if source is None:
        installed_path().unlink(missing_ok=True)
    else:
        installed_path().write_bytes(source.read_bytes())

def teardown_installed(core_root=None):
    assert pathlib.Path(core_root).is_dir()
    store = load_installed()
    for app in sorted(store):
        with open(os.environ["AIRLOCK_TEST_TEARDOWN_LOG"], "a") as handle:
            handle.write(app + "\n")
        (pathlib.Path(os.environ["AIRLOCK_TEST_ARTIFACT_DIR"]) / app).unlink(missing_ok=True)
    installed_path().write_text("{}\n")
    return 0
PY
  if [ "$version" = old ]; then
    # This predecessor exposes no new consumer API. The updater must use its
    # preserved release module rather than silently relying on this checkout.
    cat >"$d/bin/airlock-ledger" <<'PY_OLD_LEDGER'
import json, os, pathlib

def load_store():
    path = pathlib.Path(os.environ["AIRLOCK_STATE_DIR"]) / "app-ledger.json"
    return json.loads(path.read_text()) if path.exists() else {"version": 7, "entries": {}}
PY_OLD_LEDGER
  fi
  # 🔴 This stub OPENS THE TARGET THE WAY THE REAL TOOL DOES, and that is its whole
  # job here. bin/airlock-config's install-snapshot uses O_WRONLY|O_TRUNC|O_NOFOLLOW
  # and deliberately NO O_CREAT, so the caller must supply an already-created private
  # regular file; refusing to create is what stops it becoming a general write
  # primitive. This stub used to write_bytes() instead, which CREATES — so it accepted
  # a caller the real tool rejects, and bin/airlock-update shipped a path that passed a
  # never-created name and died fail-closed on every real box (2026-09-01, reproduced
  # 100%) while this suite stayed green. A stub looser than the contract it stands in
  # for tests the stub, not the caller.
  cat >"$d/bin/airlock-config" <<'PY'
#!/usr/bin/env python3
import hashlib, json, os, pathlib, stat, sys
if sys.argv[1:2] != ["install-snapshot"] or len(sys.argv) != 3:
    raise SystemExit(2)
source = pathlib.Path(os.environ.get("AIRLOCK_CONFIG", "airlock.toml")).resolve()
target = pathlib.Path(sys.argv[2])
data = source.read_bytes()
try:
    flags = os.O_WRONLY | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(target, flags)
    with os.fdopen(fd, "wb") as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            sys.stderr.write("fixture: install snapshot target is not a regular non-symlink file\n")
            raise SystemExit(2)
        os.fchmod(handle.fileno(), 0o600)
        handle.write(data)
except OSError as exc:
    sys.stderr.write("fixture: cannot freeze install config -> %s: %s\n" % (target, exc))
    raise SystemExit(2)
print(json.dumps({"config_path": str(source), "sha256": hashlib.sha256(data).hexdigest()}))
PY
  # `validate` answers because every real release's config tool does — the update's
  # preflight asks it before writing anything. Every other command still fails, so a
  # flow that leans on the NEW tool after the overwrite stays caught.
  if [ "$version" = new ]; then
    cat >"$d/bin/airlock-config" <<'PY'
#!/usr/bin/env python3
import sys
if sys.argv[1:] == ["validate"]:
    print("ok: config valid")
    raise SystemExit(0)
sys.stderr.write("fixture: the failed new release config command is unavailable\n")
raise SystemExit(91)
PY
  fi
  cat >"$d/bin/airlock-status" <<PY
#!/usr/bin/env python3
import json, os, pathlib, sys
want = "$version"
got = pathlib.Path(os.environ["AIRLOCK_TEST_RUNTIME"]).read_text().strip()
forced = int(os.environ.get("AIRLOCK_TEST_STATUS_RC", "-1"))
expected_state = os.environ.get("AIRLOCK_TEST_EXPECT_STATE_DIR", "")
expected_config = os.environ.get("AIRLOCK_TEST_EXPECT_CONFIG", "")
state_ok = not expected_state or os.environ.get("AIRLOCK_STATE_DIR") == expected_state
actual_config = pathlib.Path(os.environ.get("AIRLOCK_CONFIG", "airlock.toml")).resolve()
config_ok = not expected_config or actual_config == pathlib.Path(expected_config).resolve()
rc = forced if forced >= 0 else (0 if got == want and state_ok and config_ok else 1)
verdict = "ok" if rc == 0 else ("incomplete" if rc == 3 else "fail")
print(json.dumps({"schema_version": 1, "verdict": verdict, "exit_code": rc,
                  "checks": [{"id": "fixture.runtime", "status": verdict,
                              "detail": got},
                             {"id": "fixture.context", "status": verdict,
                              "detail": f"state={state_ok} config={config_ok}"}]}))
raise SystemExit(rc)
PY
  if [ "$version" = old ]; then
    cat >"$d/install/airlock-install.sh" <<'SH'
#!/usr/bin/env bash
[ ! -e /proc/$$/fd/8 ] || exit 88
test "$AIRLOCK_STATE_DIR" = "$AIRLOCK_TEST_EXPECT_STATE_DIR"
test "$AIRLOCK_CONFIG" = "$AIRLOCK_TEST_EXPECT_CONFIG"
printf 'old\n' >"$AIRLOCK_TEST_RUNTIME"
printf 'old\n' >>"$AIRLOCK_TEST_INSTALL_LOG"
SH
  else
    cat >"$d/install/airlock-install.sh" <<'SH'
#!/usr/bin/env bash
[ ! -e /proc/$$/fd/8 ] || exit 88
printf 'new-partial\n' >"$AIRLOCK_TEST_RUNTIME"
printf 'new\n' >>"$AIRLOCK_TEST_INSTALL_LOG"
mkdir -p "$AIRLOCK_TEST_ARTIFACT_DIR"
printf 'parent\n' >"$AIRLOCK_TEST_ARTIFACT_DIR/a-parent"
printf 'child\n' >"$AIRLOCK_TEST_ARTIFACT_DIR/z-child"
printf '{"a-parent":{"repo":"/fixture/parent","commit":"","artifacts":[]},"z-child":{"repo":"/fixture/child","commit":"","artifacts":[]}}\n' \
  >"$AIRLOCK_STATE_DIR/installed-apps.json"
printf '{"version":1,"entries":[{"package":"fixture","listen":444,"target":445}]}\n' \
  >"$AIRLOCK_STATE_DIR/plaintext-retirement.json"
[ "${AIRLOCK_TEST_INSTALL_FAIL:-1}" != 0 ] || {
  printf 'new\n' >"$AIRLOCK_TEST_RUNTIME"
  exit 0
}
exit 42
SH
  fi
}

ROLLREL="$scratch/rollback-release"
make_rollback_tree "$ROLLREL" old
git -C "$ROLLREL" init -q -b main
git -C "$ROLLREL" add -A
git -C "$ROLLREL" commit -q -m "release old"
make_rollback_tree "$ROLLREL" new keep-git
git -C "$ROLLREL" add -A
git -C "$ROLLREL" commit -q -m "release new"

make_rollback_box() {
  make_rollback_tree "$BOX" old
  RCONFIG="$scratch/rollback-custom.toml"
  printf '[site]\nname = "Rollback Fixture"\n' >"$RCONFIG"
  git -C "$BOX" init -q -b main
  git -C "$BOX" add -A
  git -C "$BOX" commit -q -m old
  RUNTIME="$scratch/runtime"; INSTALL_LOG="$scratch/install.log"; RSTATE="$scratch/rollback-state"
  TEARDOWN_LOG="$scratch/teardown.log"; ARTIFACT_DIR="$scratch/current-artifacts"
  printf 'old\n' >"$RUNTIME"; : >"$INSTALL_LOG"; : >"$TEARDOWN_LOG"
  rm -rf "$RSTATE" "$ARTIFACT_DIR"; mkdir -p "$RSTATE"
  printf '{}\n' >"$RSTATE/installed-apps.json"
  printf '{"version":1,"entries":[]}\n' >"$RSTATE/plaintext-retirement.json"
  RBEFORE="$(git -C "$BOX" rev-parse HEAD)"
}
run_failed_update() {
  AIRLOCK_DIR="$BOX" AIRLOCK_RELEASE_URL="$ROLLREL" AIRLOCK_STATE_DIR="$RSTATE" AIRLOCK_CONFIG="$RCONFIG" \
    AIRLOCK_TEST_EXPECT_STATE_DIR="$RSTATE" AIRLOCK_TEST_EXPECT_CONFIG="$RCONFIG" \
    AIRLOCK_TEST_RUNTIME="$RUNTIME" AIRLOCK_TEST_INSTALL_LOG="$INSTALL_LOG" \
    AIRLOCK_TEST_TEARDOWN_LOG="$TEARDOWN_LOG" AIRLOCK_TEST_ARTIFACT_DIR="$ARTIFACT_DIR" \
    bash "$UPDATE" 2>&1
}
run_rollback() {
  AIRLOCK_DIR="$BOX" AIRLOCK_TEST_RUNTIME="$RUNTIME" \
    AIRLOCK_TEST_EXPECT_STATE_DIR="$RSTATE" AIRLOCK_TEST_EXPECT_CONFIG="$RCONFIG" \
    AIRLOCK_TEST_INSTALL_LOG="$INSTALL_LOG" \
    AIRLOCK_TEST_TEARDOWN_LOG="$TEARDOWN_LOG" AIRLOCK_TEST_ARTIFACT_DIR="$ARTIFACT_DIR" \
    bash "$BOX/.git/airlock-update-rollback/airlock-update" --rollback 2>&1
}
fixture_status() {
  (cd "$BOX" && AIRLOCK_STATE_DIR="$RSTATE" AIRLOCK_CONFIG="$RCONFIG" \
    AIRLOCK_TEST_RUNTIME="$RUNTIME" python3 bin/airlock-status --json >/dev/null 2>&1)
}

# A stale operator checkout must not stand in for the tree its cores run.
make_rollback_box
PREVIOUS_RUNTIME="$scratch/previous-runtime"
make_rollback_tree "$PREVIOUS_RUNTIME" old
mkdir -p "$PREVIOUS_RUNTIME/apps/core" "$scratch/runtime-root-shim"
python3 - "$RSTATE/installed-apps.json" "$PREVIOUS_RUNTIME/apps/core" <<'PY_RUNTIME_ROOT'
import json, pathlib, sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({"core": {"repo": sys.argv[2], "commit": "", "artifacts": []}}) + "\n")
PY_RUNTIME_ROOT
printf 'raise SystemExit(1)\n' > "$BOX/bin/airlock-status"
git -C "$BOX" add bin/airlock-status
git -C "$BOX" commit -q -m 'operator checkout has an obsolete status reader'
RBEFORE="$(git -C "$BOX" rev-parse HEAD)"
cat > "$scratch/runtime-root-shim/systemctl" <<SH_RUNTIME_ROOT
#!/usr/bin/env bash
if [ "\$*" = '--user show airlock-update-detect.service -p WorkingDirectory --value' ]; then
  printf '%s\n' '$PREVIOUS_RUNTIME'
fi
SH_RUNTIME_ROOT
chmod +x "$scratch/runtime-root-shim/systemctl"
cross_root_update="$(PATH="$scratch/runtime-root-shim:$PATH" run_failed_update)"; cross_root_rc=$?
cross_root_recorded="$(cat "$BOX/.git/airlock-update-rollback/runtime-root" 2>/dev/null)"
cross_root_rollback="$(PATH="$scratch/runtime-root-shim:$PATH" run_rollback)"; cross_root_rollback_rc=$?
[ "$cross_root_rc" = 42 ] && [ "$cross_root_recorded" = "$PREVIOUS_RUNTIME" ] \
  && [ "$cross_root_rollback_rc" = 0 ] && [ "$(cat "$RUNTIME")" = old ] \
  && [ "$(git -C "$BOX" rev-parse HEAD)" = "$RBEFORE" ] \
  && [ "$(tr '\n' ' ' <"$INSTALL_LOG")" = 'new old ' ] \
  && ok "update measures the running checkout and rollback reapplies that same installer despite an obsolete operator reader" \
  || bad "cross-root update/rollback used the wrong installation: $cross_root_update | $cross_root_rollback"

make_dirty_rollback_box() {
make_rollback_box
python3 - "$BOX" <<'DIRTY_RUNTIME'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for name in ['install/airlock-install.sh', 'bin/airlock-status']:
    path = root / name
    path.write_text(path.read_text().replace('old', 'custom'))
DIRTY_RUNTIME
printf 'custom\n' >"$RUNTIME"
}

make_dirty_rollback_box
dirty_update="$(run_failed_update)"; dirty_update_rc=$?
dirty_restore="$(run_rollback)"; dirty_restore_rc=$?
[ "$dirty_update_rc" = 42 ] && [ "$dirty_restore_rc" = 0 ] \
  && [ "$(cat "$RUNTIME")" = custom ] && fixture_status \
  && ok "failed rollback restores uncommitted installer/status bytes before recreating the starting runtime" \
  || bad "dirty runtime rollback restored HEAD instead of the starting runtime: $dirty_update | $dirty_restore"

make_dirty_rollback_box
printf 'PRECIOUS STAGED VERSION\n' >"$BOX/README.md"
git -C "$BOX" add README.md
rollback_staged_blob="$(git -C "$BOX" rev-parse :README.md)"
git -C "$BOX" update-index --split-index
printf 'UNSTAGED WORKING VERSION\n' >"$BOX/README.md"
blob_update="$(run_failed_update)"; blob_update_rc=$?
git -C "$BOX" update-index --no-split-index
git -C "$BOX" prune --expire now
find "$BOX/.git" -name 'sharedindex.*' -delete
if git -C "$BOX" cat-file -e "$rollback_staged_blob" 2>/dev/null; then
  blob_expired=0
else
  blob_expired=1
fi
blob_rollback="$(run_rollback)"; blob_rollback_rc=$?
[ "$blob_update_rc" = 42 ] && [ "$blob_expired" = 1 ] && [ "$blob_rollback_rc" = 0 ] && fixture_status \
  && [ "$(git -C "$BOX" show :README.md)" = 'PRECIOUS STAGED VERSION' ] \
  && [ "$(cat "$BOX/README.md")" = 'UNSTAGED WORKING VERSION' ] \
  && [ ! -e "$BOX/.git/airlock-update-rollback" ] \
  && ok "frozen automatic rollback restores readable staging and working bytes after object/shared-index expiry" \
  || bad "automatic rollback falsely succeeded with unreadable staging: $blob_update | $blob_rollback"

make_dirty_rollback_box
run_failed_update >/dev/null 2>&1
dirty_incomplete="$(AIRLOCK_TEST_STATUS_RC=3 run_rollback)"; dirty_incomplete_rc=$?
printf 'later operator edit\n' >>"$BOX/README.md"
dirty_retry_refuse="$(run_rollback)"; dirty_retry_refuse_rc=$?
[ "$dirty_incomplete_rc" = 3 ] && [ "$dirty_retry_refuse_rc" -ne 0 ] \
  && grep -q 'later operator edit' "$BOX/README.md" \
  && [ "$(wc -l <"$INSTALL_LOG")" = 2 ] \
  && ok "retry distinguishes restored pre-update edits from later operator work and preserves the latter" \
  || bad "dirty rollback retry overwrote later edits: $dirty_incomplete | $dirty_retry_refuse"
git -C "$BOX" checkout -- README.md
dirty_retry="$(run_rollback)"; dirty_retry_rc=$?
[ "$dirty_retry_rc" = 0 ] && [ "$(cat "$RUNTIME")" = custom ] && fixture_status \
  && [ ! -e "$BOX/.git/airlock-update-rollback" ] \
  && ok "the exact original dirty source can retry an incomplete rollback to its starting runtime" \
  || bad "the original dirty baseline blocked a safe retry: $dirty_retry"

make_dirty_rollback_box
printf 'operator staged addition\n' >"$BOX/staged-user.txt"
git -C "$BOX" add staged-user.txt
git -C "$BOX" rm -q README.md
staged_before="$(git -C "$BOX" diff --cached --binary)"
run_failed_update >/dev/null 2>&1
staged_incomplete="$(AIRLOCK_TEST_STATUS_RC=3 run_rollback)"; staged_incomplete_rc=$?
staged_retry="$(run_rollback)"; staged_retry_rc=$?
[ "$staged_incomplete_rc" = 3 ] && [ "$staged_retry_rc" = 0 ] \
  && [ "$(cat "$RUNTIME")" = custom ] && fixture_status \
  && [ ! -e "$BOX/README.md" ] \
  && [ "$(cat "$BOX/staged-user.txt")" = 'operator staged addition' ] \
  && [ "$(git -C "$BOX" diff --cached --binary)" = "$staged_before" ] \
  && ok "rollback and retry preserve staged additions/deletions as well as original runtime bytes" \
  || bad "restored staged operator work blocked retry or lost its staging: $staged_incomplete | $staged_retry"

# Review3: a later index-only edit must survive even if worktree bytes match.
make_dirty_rollback_box
run_failed_update >/dev/null 2>&1
index_incomplete="$(AIRLOCK_TEST_STATUS_RC=3 run_rollback)"; index_incomplete_rc=$?
cp "$BOX/README.md" "$scratch/readme-before-index-edit"
printf 'new staged operator content\n' >"$BOX/README.md"
git -C "$BOX" add README.md
cp "$scratch/readme-before-index-edit" "$BOX/README.md"
index_refuse="$(run_rollback)"; index_refuse_rc=$?
[ "$index_incomplete_rc" = 3 ] && [ "$index_refuse_rc" -ne 0 ] \
  && [ "$(git -C "$BOX" show :README.md)" = 'new staged operator content' ] \
  && cmp -s "$BOX/README.md" "$scratch/readme-before-index-edit" \
  && [ "$(wc -l <"$INSTALL_LOG")" = 2 ] \
  && ok "rollback retry refuses an index-only new edit without overwriting staged bytes or running hooks" \
  || bad "rollback lost a later index-only edit: $index_incomplete | $index_refuse"
git -C "$BOX" reset -q HEAD -- README.md
index_retry="$(run_rollback)"; index_retry_rc=$?
[ "$index_retry_rc" = 0 ] && fixture_status \
  && ok "restoring original staging permits retry despite refreshed index stat cache" \
  || bad "original staging no longer permitted a safe retry: $index_retry"

# Review3: reinstalling the same release may leave before == after. Phase, not
# that SHA equality, tells retry whether failed-state teardown is already done.
make_rollback_box
same_first="$(AIRLOCK_TEST_INSTALL_FAIL=0 run_failed_update)"; same_first_rc=$?
RBEFORE="$(git -C "$BOX" rev-parse HEAD)"
make_rollback_tree "$scratch/same-release-original" old
for name in install/airlock-install.sh bin/airlock-status bin/airlock-config; do
  cp "$scratch/same-release-original/$name" "$BOX/$name"
done
python3 - "$BOX" <<'SAME_RUNTIME'
from pathlib import Path
import sys
root = Path(sys.argv[1])
for name in ['install/airlock-install.sh', 'bin/airlock-status']:
    path = root / name
    path.write_text(path.read_text().replace('old', 'custom'))
SAME_RUNTIME
printf 'custom\n' >"$RUNTIME"
printf '{}\n' >"$RSTATE/installed-apps.json"
printf '{"version":1,"entries":[]}\n' >"$RSTATE/plaintext-retirement.json"
rm -rf "$ARTIFACT_DIR"
: >"$INSTALL_LOG"; : >"$TEARDOWN_LOG"
same_update="$(run_failed_update)"; same_update_rc=$?
same_after="$(cat "$BOX/.git/airlock-update-rollback/after")"
same_rollback="$(AIRLOCK_TEST_STATUS_RC=3 run_rollback)"; same_rollback_rc=$?
same_teardown_before="$(cat "$TEARDOWN_LOG")"
same_retry="$(run_rollback)"; same_retry_rc=$?
[ "$same_first_rc" = 0 ] && [ "$same_update_rc" = 42 ] \
  && [ "$RBEFORE" = "$same_after" ] && [ "$same_rollback_rc" = 3 ] \
  && [ "$same_retry_rc" = 0 ] && [ "$(cat "$RUNTIME")" = custom ] && fixture_status \
  && [ "$same_teardown_before" = $'a-parent\nz-child' ] \
  && [ "$(cat "$TEARDOWN_LOG")" = "$same_teardown_before" ] \
  && [ ! -e "$BOX/.git/airlock-update-rollback" ] \
  && ok "same-release dirty reinstall retries a status-failed rollback without repeating failed-state teardown" \
  || bad "same-release rollback retried completed teardown: $same_first | $same_update | $same_rollback | $same_retry"

make_dirty_rollback_box
printf 'operator tracked notes\n' >"$BOX/MY-NOTES.md"
git -C "$BOX" add MY-NOTES.md
git -C "$BOX" commit -qm 'operator notes baseline'
git -C "$BOX" mv MY-NOTES.md RENAMED-NOTES.md
rm "$BOX/README.md"
mkdir -p "$BOX/README.md/empty"
printf 'original nested bytes\n' >"$BOX/README.md/notes"
complex_staging="$(git -C "$BOX" diff --cached --binary)"
complex_update="$(run_failed_update)"; complex_update_rc=$?
complex_rollback="$(AIRLOCK_TEST_STATUS_RC=3 run_rollback)"; complex_rollback_rc=$?
rmdir "$BOX/README.md/empty"
complex_refuse="$(run_rollback)"; complex_refuse_rc=$?
[ "$complex_update_rc" = 42 ] && [ "$complex_rollback_rc" = 3 ] \
  && [ "$complex_refuse_rc" -ne 0 ] && [ ! -e "$BOX/README.md/empty" ] \
  && [ "$(wc -l <"$INSTALL_LOG")" = 2 ] \
  && ok "rollback retry notices a removed original empty directory and preserves the new edit" \
  || bad "rollback ignored an empty-directory deletion: $complex_update | $complex_rollback | $complex_refuse"
mkdir "$BOX/README.md/empty"
complex_directory_mode="$(stat -c %a "$BOX/README.md/empty")"
chmod 0700 "$BOX/README.md/empty"
complex_mode_refuse="$(run_rollback)"; complex_mode_refuse_rc=$?
[ "$complex_mode_refuse_rc" -ne 0 ] \
  && [ "$(stat -c %a "$BOX/README.md/empty")" = 700 ] \
  && [ "$(wc -l <"$INSTALL_LOG")" = 2 ] \
  && ok "rollback retry preserves a later permission edit on an original empty directory" \
  || bad "rollback overwrote a later directory permission edit: $complex_mode_refuse"
chmod "$complex_directory_mode" "$BOX/README.md/empty"
complex_retry="$(run_rollback)"; complex_retry_rc=$?
[ "$complex_retry_rc" = 0 ] && [ "$(cat "$RUNTIME")" = custom ] && fixture_status \
  && [ ! -e "$BOX/MY-NOTES.md" ] && [ -d "$BOX/README.md/empty" ] \
  && [ "$(cat "$BOX/RENAMED-NOTES.md")" = 'operator tracked notes' ] \
  && [ "$(cat "$BOX/README.md/notes")" = 'original nested bytes' ] \
  && [ "$(git -C "$BOX" diff --cached --binary)" = "$complex_staging" ] \
  && [ ! -e "$BOX/.git/airlock-update-rollback" ] \
  && ok "automatic rollback and retry restore original node types, staged rename and the actual starting runtime" \
  || bad "complex original source did not recover its runtime and Git state: $complex_retry"

make_dirty_rollback_box
run_failed_update >/dev/null 2>&1
printf ' \n' >>"$BOX/.git/airlock-update-rollback/local-files/files.json"
tampered_files="$(run_rollback)"; tampered_files_rc=$?
[ "$tampered_files_rc" -ne 0 ] && [ "$(cat "$RUNTIME")" = new-partial ] \
  && [ "$(cat "$INSTALL_LOG")" = new ] \
  && ok "changed local recovery metadata is refused before checkout or installer effects" \
  || bad "rollback consumed changed local recovery metadata: $tampered_files"

make_rollback_box
update_success_out="$(AIRLOCK_TEST_INSTALL_FAIL=0 run_failed_update)"; update_success_rc=$?
[ "$update_success_rc" = 0 ] && [ "$(cat "$RUNTIME")" = new ] \
  && [ ! -e "$BOX/.git/airlock-update-rollback" ] \
  && ! git -C "$BOX" show-ref --verify --quiet refs/airlock-update/rollback \
  && printf '%s' "$update_success_out" | grep -q 'airlock-status rc=0' \
  && ok "a healthy update verifies exactly and removes its armed recovery record" \
  || bad "a healthy update left recovery state behind or skipped exact status: $update_success_out"

make_rollback_box
update_lock_ready="$scratch/update-lock-ready"
rm -f "$update_lock_ready"
python3 - "$BOX/.git" "$update_lock_ready" <<'PY' &
import fcntl, os, pathlib, sys, time
descriptor = os.open(sys.argv[1], os.O_RDONLY)
fcntl.flock(descriptor, fcntl.LOCK_EX)
pathlib.Path(sys.argv[2]).touch()
time.sleep(2)
PY
update_lock_holder=$!
while [ ! -e "$update_lock_ready" ]; do sleep 0.01; done
update_lock_out="$(run_failed_update)"; update_lock_rc=$?
wait "$update_lock_holder"
[ "$update_lock_rc" -ne 0 ] && [ "$(git -C "$BOX" rev-parse HEAD)" = "$RBEFORE" ] \
  && [ ! -s "$INSTALL_LOG" ] && [ "$(cat "$RUNTIME")" = old ] \
  && ok "a second updater is refused by the git-dir mutex before checkout or install" \
  || bad "the update mutex admitted a concurrent updater: $update_lock_out"

# A ready file can exist between open/truncate and the keeper's write.
# Force that scheduling gap in the real helper; an empty file is not a reply.
mutex_race="$scratch/mutex-ready-race"
mkdir -p "$mutex_race/shim" "$mutex_race/gitdir"
{
  printf '#!%s\n' "$(command -v python3)"
  cat <<'PY'
import pathlib, sys, time
original_write = pathlib.Path.write_text

def delayed_write(self, data, *args, **kwargs):
    if data == "ok":
        self.touch()
        time.sleep(0.2)
    return original_write(self, data, *args, **kwargs)

pathlib.Path.write_text = delayed_write
sys.argv = sys.argv[1:]  # emulate python3 - <keeper arguments>
exec(compile(sys.stdin.read(), "<delayed-keeper>", "exec"))
PY
} > "$mutex_race/shim/python3"
chmod +x "$mutex_race/shim/python3"
{
  printf 'die() { printf "%%s\\n" "$*" >&2; exit 1; }\n'
  sed -n '/^acquire_update_mutex()/,/^}/p' "$UPDATE"
  sed -n '/^release_update_mutex()/,/^}/p' "$UPDATE"
  printf 'acquire_update_mutex "$1"\nrelease_update_mutex\n'
} > "$mutex_race/run.sh"
mutex_race_out="$(PATH="$mutex_race/shim:$PATH" bash "$mutex_race/run.sh" "$mutex_race/gitdir" 2>&1)"; mutex_race_rc=$?
[ "$mutex_race_rc" = 0 ] && ok "update mutex waits for the keeper reply after an empty ready file appears" \
  || bad "update mutex mistook an empty ready file for a reply: $mutex_race_out"

make_rollback_box
pre_incomplete_out="$(AIRLOCK_TEST_STATUS_RC=3 run_failed_update)"; pre_incomplete_rc=$?
[ "$pre_incomplete_rc" = 1 ] && [ "$(git -C "$BOX" rev-parse HEAD)" = "$RBEFORE" ] \
  && [ ! -s "$INSTALL_LOG" ] && [ "$(cat "$RUNTIME")" = old ] \
  && [ ! -e "$BOX/.git/airlock-update-rollback" ] \
  && printf '%s' "$pre_incomplete_out" | grep -q 'airlock-status rc=3' \
  && ok "pre-update status rc=3 refuses checkout and install before recovery is armed" \
  || bad "an incomplete pre-update status changed the box or was misreported: $pre_incomplete_out"

make_rollback_box
rollback_fail_out="$(run_failed_update)"; rollback_fail_rc=$?
[ "$rollback_fail_rc" = 42 ] && ok "an injected installer failure stays a failed update" \
  || bad "the injected installer failure exited $rollback_fail_rc, not 42: $rollback_fail_out"
fixture_status; no_rollback_status=$?
[ "$no_rollback_status" = 1 ] && ok "negative control: without rollback the mixed box is red" \
  || bad "negative control: a rollback that never ran looked green (status rc=$no_rollback_status)"
[ "$(cat "$INSTALL_LOG")" = new ] && ok "negative control: the old installer has not run yet" \
  || bad "negative control: rollback ran before it was requested"
rollback_out="$(run_rollback)"; rollback_rc=$?
[ "$rollback_rc" = 0 ] && ok "one rollback command restores and verifies the failed update" \
  || bad "rollback exited $rollback_rc: $rollback_out"
[ "$(git -C "$BOX" rev-parse HEAD)" = "$RBEFORE" ] \
  && [ "$(cat "$RUNTIME")" = old ] \
  && [ "$(tr '\n' ' ' <"$INSTALL_LOG")" = "new old " ] \
  && [ -z "$(git -C "$BOX" status --porcelain --untracked-files=all)" ] \
  && ok "rollback restores the old checkout and reruns the old installer" \
  || bad "rollback left checkout/runtime/install order mixed"
[ "$(tr '\n' ' ' <"$TEARDOWN_LOG")" = "a-parent z-child " ] \
  && [ ! -e "$ARTIFACT_DIR/z-child" ] && [ ! -e "$ARTIFACT_DIR/a-parent" ] \
  && ok "rollback delegates teardown to the preserved ledger module" \
  || bad "rollback did not exercise the current ledger teardown order"
grep -qx '{}' "$RSTATE/installed-apps.json" \
  && [ "$(cat "$RSTATE/plaintext-retirement.json")" = '{"version":1,"entries":[]}' ] \
  && ok "rollback restores the pre-update ledger and retirement record" \
  || bad "rollback left a new installed-state record behind"
printf '%s' "$rollback_out" | grep -q 'airlock-status rc=0' \
  && ok "rollback success names the exact status verdict" \
  || bad "rollback did not record its rc=0 verification"
grep -q $'\tupdate-failed\t' "$BOX/.git/airlock-update.log" \
  && grep -q $'\trollback-ok\t' "$BOX/.git/airlock-update.log" \
  && [ ! -e "$BOX/.git/airlock-update-rollback" ] \
  && ! git -C "$BOX" show-ref --verify --quiet refs/airlock-update/rollback \
  && ok "failed update and successful rollback stay logged without a stale recovery ref" \
  || bad "rollback log or recovery metadata cleanup is incomplete"

make_rollback_box
run_failed_update >/dev/null 2>&1
printf '\n# changed after failure\n' >>"$RCONFIG"
config_refuse_out="$(run_rollback)"; config_refuse_rc=$?
[ "$config_refuse_rc" -ne 0 ] && [ "$(cat "$INSTALL_LOG")" = new ] \
  && [ "$(cat "$RUNTIME")" = new-partial ] \
  && ok "rollback refuses a changed ignored config before running the old installer" \
  || bad "rollback erased or used a config changed after the failure: $config_refuse_out"

make_rollback_box
run_failed_update >/dev/null 2>&1
alternate_config="$scratch/alternate/airlock.toml"
mkdir -p "$(dirname "$alternate_config")"
cp "$RCONFIG" "$alternate_config"
printf '%s' "$alternate_config" >"$BOX/.git/airlock-update-rollback/config-path"
path_refuse_out="$(run_rollback)"; path_refuse_rc=$?
[ "$path_refuse_rc" -ne 0 ] && [ "$(cat "$INSTALL_LOG")" = new ] \
  && [ "$(cat "$RUNTIME")" = new-partial ] \
  && ok "rollback refuses same-byte config metadata retargeted to another base directory" \
  || bad "rollback trusted tampered config-path metadata: $path_refuse_out"

make_rollback_box
run_failed_update >/dev/null 2>&1
printf '%s' "$scratch/other-state" >"$BOX/.git/airlock-update-rollback/state-dir"
state_path_refuse_out="$(run_rollback)"; state_path_refuse_rc=$?
[ "$state_path_refuse_rc" -ne 0 ] && [ "$(cat "$INSTALL_LOG")" = new ] \
  && [ "$(cat "$RUNTIME")" = new-partial ] \
  && ok "rollback refuses tampered destructive state-dir metadata" \
  || bad "rollback trusted tampered state-dir metadata: $state_path_refuse_out"

make_rollback_box
run_failed_update >/dev/null 2>&1
printf 'operator edit after failure\n' >>"$BOX/README.md"
dirty_refuse_out="$(run_rollback)"; dirty_refuse_rc=$?
[ "$dirty_refuse_rc" -ne 0 ] && [ "$(cat "$INSTALL_LOG")" = new ] \
  && ok "rollback refuses tracked work added after the failed update" \
  || bad "rollback discarded tracked work or ran the old installer: $dirty_refuse_out"

make_rollback_box
run_failed_update >/dev/null 2>&1
printf ' \n' >>"$RSTATE/installed-apps.json" # still valid JSON; represents a later state writer
state_refuse_out="$(run_rollback)"; state_refuse_rc=$?
[ "$state_refuse_rc" -ne 0 ] && [ "$(cat "$INSTALL_LOG")" = new ] \
  && [ "$(cat "$RUNTIME")" = new-partial ] \
  && ok "rollback refuses installed-state changes made after the failed update" \
  || bad "rollback overwrote state changed after failure: $state_refuse_out"

make_rollback_box
run_failed_update >/dev/null 2>&1
incomplete_out="$(AIRLOCK_TEST_STATUS_RC=3 run_rollback)"; incomplete_rc=$?
[ "$incomplete_rc" = 3 ] \
  && ! printf '%s' "$incomplete_out" | grep -q '검증도 통과' \
  && [ -d "$BOX/.git/airlock-update-rollback" ] \
  && git -C "$BOX" show-ref --verify --quiet refs/airlock-update/rollback \
  && ok "status rc=3 is never reported as a successful rollback" \
  || bad "an incomplete status became rollback success: $incomplete_out"
incomplete_retry_out="$(run_rollback)"; incomplete_retry_rc=$?
[ "$incomplete_retry_rc" = 0 ] \
  && [ ! -e "$BOX/.git/airlock-update-rollback" ] \
  && ! git -C "$BOX" show-ref --verify --quiet refs/airlock-update/rollback \
  && printf '%s' "$incomplete_retry_out" | grep -q 'airlock-status rc=0' \
  && ok "a rollback left incomplete can retry to exact status and clean recovery state" \
  || bad "an incomplete rollback could not be retried safely: $incomplete_retry_out"

# ---------------------------------------------------------------- 8b) older ledger API and non-core rollback
# The old checkout deliberately has the actual engine without the new consumer
# APIs. The real core-only installer runs on rollback; Personal and Company
# resources must survive without replaying their install hooks.
cross_version_rollback() (
  set -euo pipefail
  local_fixture="$scratch/cross-version"
  mkdir -p "$local_fixture"/{release,box,home,state,data,web,confd,site,units-user,units-system,shim,personal,company-source/apps/company}
  export HOME="$local_fixture/home" AIRLOCK_STATE_DIR="$local_fixture/state"
  export AIRLOCK_DATA_DIR="$local_fixture/data" AIRLOCK_WEBROOT="$local_fixture/web"
  export AIRLOCK_CONFD="$local_fixture/confd" AIRLOCK_NGINX_SITE="$local_fixture/site/airlock.conf"
  export AIRLOCK_UNIT_DIR_USER="$local_fixture/units-user" AIRLOCK_UNIT_DIR_SYSTEM="$local_fixture/units-system"
  export AIRLOCK_PLATFORM_ETC="$local_fixture/platform-etc" AIRLOCK_PLATFORM_OPT="$local_fixture/platform-opt"
  export AIRLOCK_TS_FQDN=box.example.ts.net
  export PATH="$local_fixture/shim:$PATH"
  export AIRLOCK_CONFIG="$local_fixture/airlock.toml"
  export AIRLOCK_DIR="$local_fixture/box" AIRLOCK_RELEASE_URL="$local_fixture/release"
  unset AIRLOCK_ROOT AIRLOCK_APP_ID AIRLOCK_APP_DIR AIRLOCK_CONFIG_BIN
  cat >"$local_fixture/shim/sudo" <<'SH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in -n) shift ;; -u) shift 2 ;; *) break ;; esac
done
exec "$@"
SH
  cat >"$local_fixture/shim/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *is-active*) printf 'active\n' ;;
  *list-timers*) printf 'Mon 2026-10-03 00:00:00 KST 1d left airlock-update-detect.timer airlock-update-detect.service\n' ;;
  *show*) printf 'LoadState=loaded\nActiveState=inactive\nMainPID=0\nControlPID=0\n' ;;
esac
SH
  cat >"$local_fixture/shim/tailscale" <<'SH'
#!/usr/bin/env python3
import json, pathlib, sys
home = pathlib.Path.home()
args = sys.argv[1:]
with (home / "serve-calls.jsonl").open("a") as trace:
    trace.write(json.dumps(args) + "\n")
state_path = home / "serve.json"
state = json.loads(state_path.read_text()) if state_path.exists() else {}
if args == ["status", "--json"]:
    print('{"BackendState":"Running","Self":{"DNSName":"box.example.ts.net."}}')
elif args == ["serve", "status", "--json"]:
    print(json.dumps({"TCP": {token.split(":")[1]: {
        "HTTP" if token.startswith("http:") else "HTTPS": True} for token in state}}))
elif args and args[0] == "serve":
    flag = next(arg for arg in args if arg.startswith(("--http=", "--https=")))
    mode, port = flag[2:].split("=")
    token = mode + ":" + port
    if args[-1] == "off":
        state.pop(token, None)
    else:
        state[token] = args[-1]
    state_path.write_text(json.dumps(state))
SH
  printf '#!/bin/sh\nexit 0\n' >"$local_fixture/shim/nginx"
  printf '#!/bin/sh\nprintf 200\n' >"$local_fixture/shim/curl"
  printf '#!/bin/sh\nprintf "Linger=yes\\n"\n' >"$local_fixture/shim/loginctl"
  chmod 755 "$local_fixture/shim"/*

  # Start with the production installer/config/engine, including uncommitted
  # fixes under test, while keeping both fixture revisions outside this checkout.
  (cd "$ROOT" && tar --exclude='./.git' --exclude='./airlock.toml' -cf - .) \
    | tar -C "$local_fixture/release" -xf -
  mkdir -p "$local_fixture/release/apps/p3core"
  for id in p3core personal company; do
    case "$id" in
      p3core) directory="$local_fixture/release/apps/$id" ;;
      personal) directory="$local_fixture/personal" ;;
      company) directory="$local_fixture/company-source/apps/$id" ;;
    esac
    cat >"$directory/airlock-app.toml" <<TOML
contract = 1
id = "$id"
[artifacts]
files = ["~/$id.marker"]
TOML
    printf '#!/bin/sh\nprintf "%s-old\\n" >"$HOME/%s.marker"\nprintf "%s\\n" >>"$HOME/install-hooks"\n' "$id" "$id" "$id" >"$directory/install.sh"
    printf '#!/bin/sh\nexit 0\n' >"$directory/smoke.sh"
    chmod 755 "$directory"/*.sh
  done
  cat >"$local_fixture/release/bin/airlock-status" <<'PY'
import json, os, pathlib
home = pathlib.Path.home()
healthy = all((home / f"{app}.marker").read_text().strip() == f"{app}-old"
              for app in ("p3core", "personal", "company"))
rc = int(os.environ.get("AIRLOCK_TEST_STATUS_RC", "0")) if healthy else 1
print(json.dumps({"schema_version": 1, "verdict": "ok" if rc == 0 else "incomplete" if rc == 3 else "fail", "exit_code": rc, "checks": []}))
raise SystemExit(rc)
PY
  # Remove only the new module-facing consumer APIs from the predecessor.
  # Its apply/list/project commands remain real, so the old full installer runs.
  python3 - "$local_fixture/release/bin/airlock-ledger" <<'PY'
import ast, pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
lines = text.splitlines(keepends=True)
names = {"read_installed_bytes", "snapshot_installed", "restore_installed",
         "validate_installed_bytes", "teardown_installed"}
for node in sorted((node for node in ast.parse(text).body if isinstance(node, ast.FunctionDef) and node.name in names), key=lambda node: node.lineno, reverse=True):
    del lines[node.lineno - 1:node.end_lineno]
path.write_text("".join(lines))
PY
  git -C "$local_fixture/release" init -q -b main
  git -C "$local_fixture/release" add -A
  git -C "$local_fixture/release" commit -q -m 'predecessor without consumer APIs'
  git -C "$local_fixture/release" archive HEAD | tar -C "$local_fixture/box" -xf -
  git -C "$local_fixture/box" init -q -b main
  git -C "$local_fixture/box" add -A
  git -C "$local_fixture/box" commit -q -m 'old installed core'
  cross_before="$(git -C "$local_fixture/box" rev-parse HEAD)"

  git -C "$local_fixture/company-source" init -q -b main
  git -C "$local_fixture/company-source" add -A
  git -C "$local_fixture/company-source" commit -q -m 'Company fixture'
  git clone -q --bare "$local_fixture/company-source" "$local_fixture/company.git"
  cat >"$AIRLOCK_CONFIG" <<TOML
[site]
name = "Cross version"
company_repo = "file://$local_fixture/company.git"
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.hub]
TOML
  for id in p3core personal; do
    directory="$local_fixture/box/apps/p3core"
    [ "$id" != personal ] || directory="$local_fixture/personal"
    printf '{}' | "$local_fixture/box/bin/airlock-ledger" apply "$id" --source "$directory"
  done
  printf '{"company_repo":"file://%s/company.git"}' "$local_fixture" \
    | "$local_fixture/box/bin/airlock-ledger" apply company --source company
  cat >>"$AIRLOCK_CONFIG" <<'TOML'
[apps.p3core]
[apps.personal]
[apps.company]
TOML
  # A real v7 record is the pre-transition input. The conversion keeps Company
  # paths local, exactly as it does for the measured legacy Company installs.
  python3 - "$AIRLOCK_STATE_DIR" "$AIRLOCK_DATA_DIR" <<'PY'
import json, pathlib, sys
state, data = map(pathlib.Path, sys.argv[1:])
rows = json.loads((state / "installed-apps.json").read_bytes())
entries = {app: {"committed": {"path": row["repo"] if row["repo"].startswith("/") else str(data / "apps" / app),
                            "artifacts": {"files": row["artifacts"]}}} for app, row in rows.items()}
for app in ("p3core", "personal"):
    entries[app]["committed"]["artifacts"]["serve_ports"] = [45678]
(state / "app-ledger.json").write_text(json.dumps({"version": 7, "entries": entries, "events": []}) + "\n")
(state / "installed-apps.json").unlink()
PY
  printf '%s\n' '{"http:45678":"personal-owned"}' >"$HOME/serve.json"
  cp "$AIRLOCK_STATE_DIR/app-ledger.json" "$local_fixture/v7-before.json"
  cp "$ROOT/bin/airlock-ledger" "$local_fixture/release/bin/airlock-ledger"
  printf '#!/bin/sh\nprintf "core-partial\\n" >"$HOME/p3core.marker"\nexit 42\n' \
    >"$local_fixture/release/apps/p3core/install.sh"
  git -C "$local_fixture/release" add -A
  git -C "$local_fixture/release" commit -q -m 'new engine and failing core hook'
  python3 - "$local_fixture/box/bin/airlock-ledger" <<'PY'
from importlib.machinery import SourceFileLoader
import sys
sys.dont_write_bytecode = True
old = SourceFileLoader("_old_cross_ledger", sys.argv[1]).load_module()
assert not hasattr(old, "snapshot_installed")
PY
  set +e
  bash "$UPDATE" >"$local_fixture/update.log" 2>&1
  update_rc=$?
  set -e
  [ "$update_rc" != 0 ]
  recovery="$local_fixture/box/.git/airlock-update-rollback"
  [ -f "$recovery/airlock-ledger" ]
  cmp -s "$local_fixture/v7-before.json" "$recovery/install-record.json"
  set +e
  AIRLOCK_TEST_STATUS_RC=3 bash "$recovery/airlock-update" --rollback >"$local_fixture/rollback.log" 2>&1
  rollback_rc=$?
  set -e
  [ "$rollback_rc" = 3 ]
  [ "$(git -C "$local_fixture/box" rev-parse HEAD)" = "$cross_before" ]
  for id in p3core personal company; do
    [ "$(cat "$HOME/$id.marker")" = "$id-old" ]
  done
  python3 - "$HOME" <<'PY'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
assert json.loads((home / "serve.json").read_text())["http:45678"] == "personal-owned"
assert not any("--http=45678" in call and call[-1] == "off"
               for call in map(json.loads, (home / "serve-calls.jsonl").read_text().splitlines()))
PY
  # The target checkout is old again, yet the recovery reader still provides
  # snapshot/matches/restore. This also catches a retry that imports target code.
  . <(sed -n '/^installed_record()/,/^}/p' "$UPDATE")
  installed_record "$recovery/airlock-ledger" snapshot "$local_fixture/restored-record.json"
  installed_record "$recovery/airlock-ledger" matches "$local_fixture/restored-record.json"
  installed_record "$recovery/airlock-ledger" restore "$local_fixture/restored-record.json"
  # OrbStack exposes the host's preserved module under /mnt/mac, just like
  # its config and recovery snapshots. Execute that transport with a path-only
  # orb shim; the target checkout still has no snapshot API.
  . <(sed -n '/^snapshot_regular()/,/^snapshot_box_state()/p' "$UPDATE" | sed '$d')
  . <(sed -n '/^validate_target_shape()/,/^rollback_update()/p' "$UPDATE" | sed '$d')
  platform() { printf Darwin; }
  die() { printf '%s\n' "$*" >&2; return 1; }
  orb() {
    [ "$1" = -m ]; shift 2
    [ "$1" = env ]; shift
    mapped=()
    for argument in "$@"; do
      case "$argument" in /mnt/mac/*) argument="${argument#/mnt/mac}" ;; esac
      mapped+=("$argument")
    done
    command env "${mapped[@]}"
  }
  record_engine="$recovery/airlock-ledger"
  remote_snapshot="$local_fixture/remote-snapshot"
  mkdir "$remote_snapshot"
  snapshot_remote_state "$record_engine" fixture "$AIRLOCK_STATE_DIR" "$remote_snapshot"
  printf '%s' "$AIRLOCK_STATE_DIR" >"$remote_snapshot/state-dir"
  teardown_and_restore_box_state "$local_fixture/box" fixture "$AIRLOCK_STATE_DIR" "$remote_snapshot" "$remote_snapshot"
  [ "$(cat "$HOME/personal.marker")" = personal-old ]
  [ "$(cat "$HOME/company.marker")" = company-old ]
  python3 - "$HOME" <<'PY'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
assert json.loads((home / "serve.json").read_text())["http:45678"] == "personal-owned"
assert not any("--http=45678" in call and call[-1] == "off"
               for call in map(json.loads, (home / "serve-calls.jsonl").read_text().splitlines()))
PY
  bash "$recovery/airlock-update" --rollback >"$local_fixture/retry.log" 2>&1
  [ ! -e "$recovery" ]
  [ "$(grep -cx personal "$HOME/install-hooks")" = 1 ]
  [ "$(grep -cx company "$HOME/install-hooks")" = 1 ]
  for id in p3core personal company; do
    [ "$(cat "$HOME/$id.marker")" = "$id-old" ]
  done
  python3 - "$HOME" <<'PY'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
assert json.loads((home / "serve.json").read_text())["http:45678"] == "personal-owned"
assert not any("--http=45678" in call and call[-1] == "off"
               for call in map(json.loads, (home / "serve-calls.jsonl").read_text().splitlines()))
PY
)
cross_version_rollback >"$scratch/cross-version.log" 2>&1; cross_version_rc=$?
if [ "$cross_version_rc" = 0 ]; then
  ok "a v7 predecessor without snapshot APIs updates, then restores its real core installer while Personal/Company resources and the Linux/Darwin recovery reader survive"
else
  tail -30 "$scratch/cross-version.log" >&2
  for log in update rollback retry; do
    [ ! -f "$scratch/cross-version/$log.log" ] || tail -30 "$scratch/cross-version/$log.log" >&2
  done
  bad "cross-version core rollback lost its reader or a non-core installed resource"
fi

# ---------------------------------------------------------------- pre-history box
# The public history starts at 2026-08-21. A box installed from an earlier tree holds
# files no published release has — measured on a real one installed 2026-07-29: the
# nearest release differed in 327 files. Its direction was "ambiguous" and the
# documented update path refused with nothing to type next.
make_prehistory_box() {
  rm -rf "$BOX"; seed_tree "$BOX" ancient
  printf '[site]\nname = "My Box"\n' > "$BOX/airlock.toml"
  printf 'my notes\n'                > "$BOX/MY-NOTES.md"
  git -C "$BOX" init -q -b main; git -C "$BOX" add -A; git -C "$BOX" commit -q -m "init: copy"
}
make_prehistory_box
ph_head="$(git -C "$BOX" rev-parse HEAD)"
ph_json="$(AIRLOCK_DIR="$BOX" AIRLOCK_RELEASE_URL="$REL" \
  bash "$UPDATE" --dry-run --json 2>/dev/null)"; ph_json_rc=$?
[ "$ph_json_rc" = 0 ] && printf '%s' "$ph_json" | python3 -c '
import json, sys
v = json.load(sys.stdin)
assert v["available"] is False and v["changedCount"] == 0, v' \
  && ok "the daily detector's answer for a pre-history box is unchanged (no update, rc 0)" \
  || bad "the detector contract changed for a pre-history box (rc=$ph_json_rc): $ph_json"
ph_preview="$(run_update --dry-run)"; ph_preview_rc=$?
[ "$ph_preview_rc" = 0 ] && printf '%s' "$ph_preview" | grep -q 'README.md' \
  && printf '%s' "$ph_preview" | grep -q -- '--from-unknown' \
  && grep -q 'version ancient' "$BOX/README.md" \
  && ok "a person's preview of a pre-history box lists the changes and names --from-unknown" \
  || bad "the preview of a pre-history box hid the changes or the way forward: $ph_preview"
ph_refuse="$(run_update --no-install)"; ph_refuse_rc=$?
[ "$ph_refuse_rc" -ne 0 ] && grep -q 'version ancient' "$BOX/README.md" \
  && [ "$(git -C "$BOX" rev-parse HEAD)" = "$ph_head" ] \
  && printf '%s' "$ph_refuse" | grep -q -- '--from-unknown' \
  && ok "without --from-unknown a pre-history box is refused and left exactly as it was" \
  || bad "a pre-history box was changed without --from-unknown (rc=$ph_refuse_rc): $ph_refuse"
ph_run="$(run_update --no-install --from-unknown)"; ph_run_rc=$?
[ "$ph_run_rc" = 0 ] && grep -q 'version new' "$BOX/README.md" \
  && [ "$(cat "$BOX/airlock.toml")" = "$CONFIG" ] && [ -f "$BOX/MY-NOTES.md" ] \
  && ok "--from-unknown updates a pre-history box and keeps its config and own files" \
  || bad "--from-unknown did not update a pre-history box cleanly (rc=$ph_run_rc): $ph_run"
REL_NEXT="$scratch/release-next"
git clone -q "$REL" "$REL_NEXT"
printf 'version next\n' > "$REL_NEXT/README.md"
git -C "$REL_NEXT" add -A; git -C "$REL_NEXT" commit -q -m "release next"
ph_next="$(AIRLOCK_DIR="$BOX" AIRLOCK_RELEASE_URL="$REL_NEXT" \
  bash "$UPDATE" --dry-run --json 2>/dev/null)"; ph_next_rc=$?
[ "$ph_next_rc" = 0 ] && printf '%s' "$ph_next" | python3 -c '
import json, sys
v = json.load(sys.stdin)
assert v["available"] is True and v["changedCount"] > 0, v' \
  && ok "after one --from-unknown run the next release is detected with no flag" \
  || bad "the box still could not place itself after --from-unknown (rc=$ph_next_rc): $ph_next"

make_prehistory_box
git -C "$REL" branch -f pinned-old HEAD~1
ph_pin="$(AIRLOCK_DIR="$BOX" AIRLOCK_RELEASE_URL="$REL" AIRLOCK_RELEASE_REF=pinned-old \
  bash "$UPDATE" --no-install --from-unknown 2>&1)"; ph_pin_rc=$?
git -C "$REL" branch -D -q pinned-old
[ "$ph_pin_rc" -ne 0 ] && grep -q 'version ancient' "$BOX/README.md" \
  && ok "--from-unknown does not unlock a pinned ref, which may be older than the box" \
  || bad "--from-unknown installed a pinned ref over an unplaceable box: $ph_pin"
# The oldest boxes may never have run `git init` at all.
# Consume all git log output: grep -q can close early and make git return
# SIGPIPE (141), a false failure under this suite's pipefail.
make_prehistory_box; rm -rf "$BOX/.git"
ph_nogit_preview="$(run_update --dry-run)"; ph_nogit_preview_rc=$?
[ "$ph_nogit_preview_rc" = 0 ] && printf '%s' "$ph_nogit_preview" | grep -q -- '--from-unknown' \
  && [ ! -d "$BOX/.git" ] \
  && ok "a pre-history box without .git previews through the throwaway repository" \
  || bad "a pre-history box without .git did not preview cleanly (rc=$ph_nogit_preview_rc): $ph_nogit_preview"
ph_nogit_run="$(run_update --no-install --from-unknown)"; ph_nogit_run_rc=$?
[ "$ph_nogit_run_rc" = 0 ] && grep -q 'version new' "$BOX/README.md" \
  && [ "$(cat "$BOX/airlock.toml")" = "$CONFIG" ] \
  && git -C "$BOX" log --format=%s | grep '^airlock-update: 배포본 [0-9a-f]\{12\} 으로 갱신$' >/dev/null \
  && ok "and --from-unknown updates it, leaving a repository that records its release" \
  || bad "a pre-history box without .git did not update cleanly (rc=$ph_nogit_run_rc): $ph_nogit_run"

ph_rb="$(run_update --rollback --from-unknown)"; ph_rb_rc=$?
[ "$ph_rb_rc" -ne 0 ] && printf '%s' "$ph_rb" | grep -q '함께 쓸 수 없습니다' \
  && ok "--from-unknown cannot ride along with --rollback" \
  || bad "--rollback accepted --from-unknown: $ph_rb"

# ---------------------------------------------------------------- config preflight
# The installer validates airlock.toml with the new release's rules only after the files
# are overwritten. Measured on the same 2026-07-29 box: its [apps.markwand] (renamed
# fileview) would have stopped the installer with the new tree on disk and old services
# running, on a box too old to have airlock-status, so no rollback was armed.
RELC="$scratch/release-config"
git clone -q "$REL" "$RELC"
cat > "$RELC/bin/airlock-config" <<'PY'
#!/usr/bin/env python3
import pathlib, sys
if sys.argv[1:2] == ["validate"]:
    if "[apps.markwand]" in pathlib.Path("airlock.toml").read_text():
        sys.stderr.write("airlock-config: unknown app [apps.markwand]\n")
        sys.exit(1)
    print("ok: config valid")
PY
git -C "$RELC" add -A; git -C "$RELC" commit -q -m "release with a stricter config"
run_update_c() { AIRLOCK_DIR="$BOX" AIRLOCK_RELEASE_URL="$RELC" bash "$UPDATE" "$@" 2>&1; }

make_box "$BOX"
printf '\n[apps.markwand]\nmarkserv_port = 1\n' >> "$BOX/airlock.toml"
pc_head="$(git -C "$BOX" rev-parse HEAD)"
pc_preview="$(run_update_c --dry-run)"; pc_preview_rc=$?
[ "$pc_preview_rc" = 0 ] && printf '%s' "$pc_preview" | grep -q 'apps.markwand' \
  && grep -q 'version old' "$BOX/README.md" \
  && ok "the preview names a config the new release will reject" \
  || bad "the preview did not surface the config problem (rc=$pc_preview_rc): $pc_preview"
pc_json="$(AIRLOCK_DIR="$BOX" AIRLOCK_RELEASE_URL="$RELC" \
  bash "$UPDATE" --dry-run --json 2>/dev/null)"; pc_json_rc=$?
[ "$pc_json_rc" = 0 ] && printf '%s' "$pc_json" | python3 -c '
import json, sys
assert json.load(sys.stdin)["available"] is True' \
  && ok "the detector's JSON is not affected by the config preflight" \
  || bad "the config preflight leaked into the detector (rc=$pc_json_rc): $pc_json"
pc_run="$(run_update_c)"; pc_run_rc=$?
[ "$pc_run_rc" -ne 0 ] && grep -q 'version old' "$BOX/README.md" \
  && [ "$(git -C "$BOX" rev-parse HEAD)" = "$pc_head" ] \
  && ! printf '%s' "$pc_run" | grep -q '설치기를 다시 돌립니다' \
  && ok "a config the new installer rejects stops the update before any file changes" \
  || bad "the update overwrote files despite a config the installer rejects (rc=$pc_run_rc): $pc_run"
printf '%s\n' "$CONFIG" > "$BOX/airlock.toml"
pc_fixed="$(run_update_c)"; pc_fixed_rc=$?
[ "$pc_fixed_rc" = 0 ] && grep -q 'version new' "$BOX/README.md" \
  && printf '%s' "$pc_fixed" | grep -q '^installed$' \
  && ok "once the config is fixed the same update runs through the installer" \
  || bad "a valid config still did not update (rc=$pc_fixed_rc): $pc_fixed"
timer_out="$(bash "$ROOT/install/test-update-timer.sh" 2>&1)"; timer_rc=$?
[ "$timer_rc" = 0 ] \
  && ok "daily update detector timer is rendered, installed and systemd-verified hermetically" \
  || bad "daily update detector timer contract failed: $timer_out"


# =============================================================================
# 9) P3E — one app: apply, restore, remove
#
# The engine (bin/airlock-ledger apply / remove / list) owns the whole flow
# for ONE app: ③ installed-apps.json is the only record of "installed", the
# Company source is ⑤'s one git URL read through this box's OWN bare mirror at a
# pinned main SHA, and A4 restore is "run the same apply once more against the
# (repo, commit) the row had when we started". No lock, no journal.
#
# Everything below runs against a real remote repository over file://, the real
# install/render-nginx.sh and the real bin/airlock-config. Only the four tools
# that cross into systemd / nginx / Tailscale are PATH stubs, all under
# AIRLOCK_FIXTURE_ROOT — the boundary the engine itself proves (A5) before it
# writes anything. The mirror the engine builds is the one under test: the
# fixture's own repository is a bare clone the engine never reads past its URL.
# -----------------------------------------------------------------------------
LEDGER="$ROOT/bin/airlock-ledger"

# The engine reads no TOML: airlock-config package-info on stdin IS its whole
# configuration input, the same JSON the installer pipes in. ⑤ rides along in
# it (site.company_repo), so the fixture's config edit in P3E-14 is the only
# thing that can add or remove the Company source.
p3e() { AIRLOCK_CONFIG="$P3E/airlock.toml" "$ROOT/bin/airlock-config" package-info; }

p3e_stubs() {
  local d="$1"
  mkdir -p "$d"
  cat >"$d/sudo" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$P3E/calls.log"
exec "$@"
STUB
  # `systemctl show` is how the engine proves a unit stopped; a stub that said
  # nothing would make every removal look unsafe and the A3 cases would pass for
  # the wrong reason. It answers the SHAPE, never the truth — the assertions are
  # about which paths were removed.
  cat >"$d/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$P3E/calls.log"
if [ "$*" = 'reload nginx' ] && [ -e "$P3E/reload-once-fails" ]; then
  rm -f "$P3E/reload-once-fails"
  exit 1
fi
case "$*" in
  *show*)
    printf 'LoadState=loaded\nActiveState=inactive\nMainPID=0\nControlPID=0\nControlGroup=\n'
    ;;
esac
exit 0
STUB
  cat >"$d/nginx" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$P3E/calls.log"
exit 0
STUB
  cat >"$d/tailscale" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$P3E/serve.log"
exit 0
STUB
  chmod 755 "$d/sudo" "$d/systemctl" "$d/nginx" "$d/tailscale"
}

p3e_env() {   # p3e_env — one isolated box; re-callable, resets everything
  P3E="$scratch/p3e"
  rm -rf "$P3E"
  mkdir -p "$P3E"/{home,state,data,web,confd/hub-locations.d,confd/servers.d,site,bin}
  : >"$P3E/calls.log"; : >"$P3E/serve.log"
  export P3E
  p3e_stubs "$P3E/bin"
  export PATH="$P3E/bin:$PATH"
  export HOME="$P3E/home" AIRLOCK_STATE_DIR="$P3E/state" AIRLOCK_DATA_DIR="$P3E/data"
  export AIRLOCK_WEBROOT="$P3E/web" AIRLOCK_CONFD="$P3E/confd"
  export AIRLOCK_NGINX_SITE="$P3E/site/airlock.conf" AIRLOCK_ROOT="$ROOT"
  export AIRLOCK_TS_FQDN=box.example.ts.net AIRLOCK_CONFIG="$P3E/airlock.toml"
  mkdir -p "$P3E/home/.config/systemd/user"
  cat >"$P3E/airlock.toml" <<'TOML'
[site]
name = "P3E Hub"
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.hub]
TOML
}

# p3e_company <message> — build the fixture's bare remote from $P3E/src/apps and
# point ⑤ at it. Nothing outside the fixture root is ever read.
p3e_company() {
  rm -rf "$P3E/work" "$P3E/remote.git"
  git init --quiet -b main "$P3E/work"
  mkdir -p "$P3E/work/apps"
  cp -R "$P3E/src/apps/." "$P3E/work/apps/"
  git -C "$P3E/work" add -A
  git -C "$P3E/work" commit --quiet -m "$1"
  git clone --quiet --bare "$P3E/work" "$P3E/remote.git"
  # Under [site], next to name — a line appended at the end of the file lands in
  # whatever table happens to be last, which is the drift ⑤ must be immune to.
  python3 - "$P3E/airlock.toml" "$P3E/remote.git" <<'PY'
import pathlib, sys
path, url = pathlib.Path(sys.argv[1]), sys.argv[2]
out = []
for line in path.read_text().splitlines():
    out.append(line)
    if line.startswith("name = "):
        out.append('company_repo = "file://%s"' % url)
path.write_text("\n".join(out) + "\n")
PY
}

p3e_manifest() {   # p3e_manifest <id> <listen-port>
  cat <<TOML
contract = 1
id = "$1"

[artifacts]
units = ["p3e-$1.service"]
fragments = ["hub-locations.d/$1.conf"]
files = ["~/.local/share/airlock/p3e-$1/data.conf",
         "~/.local/share/airlock/p3e-$1/extra.conf"]
serve_ports = ["p3e_$1_port"]

[config.defaults]
p3e_$1_port = $2

[tile]
label = "$1"
sub = "fixture"
cat = "apps"
path = "/$1/"
TOML
}

p3e_app_source() { # p3e_app_source <id> [extra-hook-body] — listen port = 18900+len(id)
  local id="$1" body="${2:-}"
  local port="$((18900 + ${#id}))"
  mkdir -p "$P3E/src/apps/$id"
  p3e_manifest "$id" "$port" >"$P3E/src/apps/$id/airlock-app.toml"
  cat >"$P3E/src/apps/$id/install.sh" <<HOOK
#!/usr/bin/env bash
set -u
mkdir -p "\$HOME/.local/share/airlock/p3e-$id"
printf 'installed %s\n' "\$(cat "\$AIRLOCK_APP_DIR/VERSION" 2>/dev/null || echo unknown)" \\
  > "\$HOME/.local/share/airlock/p3e-$id/data.conf"
mkdir -p "\$AIRLOCK_CONFD/hub-locations.d"
printf '# p3e %s\nlocation /$1/ { proxy_pass http://127.0.0.1:%s; }\n' "$id" "$port" \\
  > "\$AIRLOCK_CONFD/hub-locations.d/$id.conf"
mkdir -p "\$HOME/.config/systemd/user"
printf '[Unit]\nDescription=p3e %s\n' "$id" \\
  > "\$HOME/.config/systemd/user/p3e-$1.service"
$body
HOOK
  printf 'v1\n' >"$P3E/src/apps/$id/VERSION"
}

# p3e_commit_app <id> <message> [extra-hook-body] — a new commit on the fixture's
# bare remote, i.e. a new Company main the engine has never seen.
p3e_commit_app() {
  p3e_app_source "$1" "${3:-}"
  rm -rf "$P3E/work/apps"
  mkdir -p "$P3E/work/apps"
  cp -R "$P3E/src/apps/." "$P3E/work/apps/"
  git -C "$P3E/work" add -A
  git -C "$P3E/work" commit --quiet -m "$2"
  git -C "$P3E/work" push --quiet "$P3E/remote.git" main:main
}

p3e_commit_outside() {   # p3e_commit_outside <message> — Company main moves,
                         # apps/<id> does not. This is the case a tree digest
                         # cannot tell from a real app change.
  printf '%s\n' "$1" >"$P3E/work/NOTES.md"
  git -C "$P3E/work" add -A
  git -C "$P3E/work" commit --quiet -m "$1"
  git -C "$P3E/work" push --quiet "$P3E/remote.git" main:main
}

p3e_sha() { git -C "$P3E/remote.git" rev-parse main; }
p3e_store() { cat "$P3E/state/installed-apps.json" 2>/dev/null; }
p3e_has() {
  [ -e "$P3E/state/installed-apps.json" ] \
    && python3 -c 'import json,sys;print(sys.argv[1] in json.load(open(sys.argv[2])))' \
         "$1" "$P3E/state/installed-apps.json" || echo False
}

# --- P3E-1: apply beta, then alpha. Isolation, and what ③ records -------------
p3e_env
p3e_app_source alpha
p3e_app_source beta
p3e_company "seed alpha beta"
p3e | "$LEDGER" apply beta >"$P3E/apply-beta.log" 2>&1; beta_rc=$?
beta_row="$(p3e_store | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["beta"],sort_keys=True))')"
# __airlock.json is the WHOLE-store projection: alpha must be added there.
# Keep every other file (including the shared Company mirror) byte-identical,
# and compare beta's actual projected entry separately below.
cp "$P3E/web/__airlock.json" "$scratch/p3e-hub-before.json"
beta_before="$(find "$P3E/web" "$P3E/confd" "$P3E/home" "$P3E/data" -type f \
  -not -path '*alpha*' -not -path "$P3E/web/__airlock.json" -exec md5sum {} + | sort | md5sum)"
p3e | "$LEDGER" apply alpha >"$P3E/apply-alpha.log" 2>&1; alpha_rc=$?
alpha_row="$(p3e_store | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["alpha"],sort_keys=True))')"
beta_after="$(find "$P3E/web" "$P3E/confd" "$P3E/home" "$P3E/data" -type f \
  -not -path '*alpha*' -not -path "$P3E/web/__airlock.json" -exec md5sum {} + | sort | md5sum)"
alpha_sha="$(p3e_sha)"
if [ "$beta_rc" = 0 ] && [ "$alpha_rc" = 0 ] \
   && printf '%s' "$alpha_row" | python3 -c '
import json, sys
row = json.load(sys.stdin)
assert set(row) == {"repo", "commit", "artifacts"}, row
assert row["commit"] == sys.argv[1], row
assert row["repo"].startswith("file://"), row
arts = set(row["artifacts"])
paths = {a for a in arts if a.startswith("/")}
tokens = {a for a in arts if not a.startswith("/")}
assert all(t.startswith(("http:", "https:")) for t in tokens), tokens
assert any(a.endswith("p3e-alpha.service") for a in paths), arts
assert any(a.endswith("hub-locations.d/alpha.conf") for a in paths), arts
assert any(a.endswith("p3e-alpha/data.conf") for a in paths), arts
assert any(a.endswith("/data/apps/alpha") for a in paths), arts
assert tokens == {"http:18905"}, tokens
' "$alpha_sha"; then
  ok "P3E-1 apply writes one ③ row: Company URL, pinned main SHA, unit+fragment+data+app dir+ingress"
  p3e1_shape=1
else
  bad "P3E-1 ③ row shape wrong: $alpha_row"
  p3e1_shape=0
fi
if [ "$beta_before" = "$beta_after" ] \
   && [ "$(p3e_store | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["beta"],sort_keys=True))')" = "$beta_row" ] \
   && python3 - "$scratch/p3e-hub-before.json" "$P3E/web/__airlock.json" <<'P3E_HUB'
import json, sys
before, after = [json.load(open(path)) for path in sys.argv[1:]]
assert set(before["apps"]) == {"beta"}, before
assert set(after["apps"]) == {"alpha", "beta"}, after
assert after["apps"]["beta"] == before["apps"]["beta"], (before, after)
assert after["apps"]["alpha"]["tile"]["path"] == "/alpha/", after
assert {k: v for k, v in after.items() if k != "apps"} == {k: v for k, v in before.items() if k != "apps"}
P3E_HUB
then
  ok "P3E-1 alpha adds its Hub tile while beta's row, tile, artifacts and shared mirror bytes stay identical"
  p3e1_isolation=1
else
  bad "P3E-1 applying alpha disturbed beta or projected the wrong Hub app set"
  p3e1_isolation=0
fi
if grep -q 'hub-locations.d/alpha.conf' "$P3E/site/airlock.conf" \
   && grep -q 'hub-locations.d/beta.conf' "$P3E/site/airlock.conf" \
   && grep -q 'systemctl reload nginx' "$P3E/calls.log" \
   && grep -q -- '--http=18905' "$P3E/serve.log" ; then
  ok "P3E-1 apply projects the nginx site from ③ and creates this app's ingress"
  p3e1_projection=1
else
  bad "P3E-1 projections missing (site/ingress/reload)"
  p3e1_projection=0
fi

# --- P3E-2: plan reads the commit, not a tree digest --------------------------
p3e_commit_outside "docs-only change outside apps/alpha"
p3e | "$LEDGER" plan >"$P3E/plan-outside.txt" 2>/dev/null
p3e_commit_app alpha "change inside apps/alpha" 'printf "v2\n" >VERSION'
p3e | "$LEDGER" plan >"$P3E/plan-inside.txt" 2>/dev/null
if grep -qx 'reinstall	alpha' "$P3E/plan-outside.txt" \
   && grep -qx 'upgrade-diff	alpha' "$P3E/plan-inside.txt" \
   && grep -qx 'reinstall	beta' "$P3E/plan-outside.txt" ; then
  ok "P3E-2 plan: reinstall when only files outside apps/<id> moved, upgrade-diff when the app did"
  p3e2=1
else
  bad "P3E-2 plan rules wrong: [$(cat "$P3E/plan-outside.txt" | tr '\n' '|')] [$(cat "$P3E/plan-inside.txt" | tr '\n' '|')]"
  p3e2=0
fi
p3e | "$LEDGER" apply alpha >/dev/null 2>&1
v2_sha="$(p3e_sha)"
alpha_v2="$(cat "$P3E/data/apps/alpha/VERSION" 2>/dev/null)"

# --- P3E-3: A4 — a failing hook restores the previous commit, once ------------
p3e_commit_app alpha "install.sh now fails" 'exit 1'
p3e | "$LEDGER" apply alpha >"$P3E/p3e3.log" 2>&1; p3e3_rc=$?
p3e3_row="$(p3e_store | python3 -c 'import json,sys;print(json.load(sys.stdin)["alpha"]["commit"])')"
if [ "$p3e3_rc" != 0 ] && [ "$p3e3_row" = "$v2_sha" ] && [ "$alpha_v2" = "v2" ] \
   && grep -q "restored alpha $v2_sha\$" "$P3E/p3e3.log" ; then
  ok "P3E-3 a failing hook leaves the previous commit in place and says restored"
  p3e3=1
else
  bad "P3E-3 A4 restore wrong (rc=$p3e3_rc row=$p3e3_row want=$v2_sha tree=$alpha_v2)"
  p3e3=0
fi

# --- P3E-4: a reload failure restores only this app and its old commit ------
p3e_env
p3e_app_source alpha
p3e_app_source beta
p3e_company "reload baseline"
p3e | "$LEDGER" apply beta >/dev/null 2>&1
p3e | "$LEDGER" apply alpha >/dev/null 2>&1
old_sha="$(p3e_sha)"
beta_bytes="$(p3e_store | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["beta"],sort_keys=True))')"
p3e_commit_app alpha "reload candidate" 'printf "v2\n" > "$AIRLOCK_APP_DIR/VERSION"'
: >"$P3E/reload-once-fails"
p3e | "$LEDGER" apply alpha >"$P3E/p3e4.log" 2>&1; reload_rc=$?
if [ "$reload_rc" != 0 ] && grep -q "restored alpha $old_sha\$" "$P3E/p3e4.log" \
   && [ "$(cat "$P3E/data/apps/alpha/VERSION")" = v1 ] \
   && [ "$(p3e_store | python3 -c 'import json,sys;print(json.load(sys.stdin)["alpha"]["commit"])')" = "$old_sha" ] \
   && [ "$(p3e_store | python3 -c 'import json,sys;print(json.dumps(json.load(sys.stdin)["beta"],sort_keys=True))')" = "$beta_bytes" ]; then
  ok "P3E-4 a failed nginx reload restores the previous alpha commit and keeps beta"
else
  bad "P3E-4 reload recovery failed (rc=$reload_rc): $(tail -6 "$P3E/p3e4.log")"
fi

# --- P3E-5b: both hooks fail; replay exactly once and leave ③ unchanged -------
p3e_env
p3e_app_source alpha 'printf "hook\n" >> "$P3E/hook-count"; [ ! -e "$P3E/old-hook-fails" ] || exit 1'
p3e_company "restore baseline"
p3e | "$LEDGER" apply alpha >/dev/null 2>&1
before_store="$(p3e_store)"
p3e_commit_app alpha "failing candidate" 'printf "hook\n" >> "$P3E/hook-count"; exit 1'
: >"$P3E/old-hook-fails"; : >"$P3E/hook-count"
p3e | "$LEDGER" apply alpha >"$P3E/p3e5b.log" 2>&1; both_rc=$?
if [ "$both_rc" != 0 ] && [ "$(wc -l <"$P3E/hook-count")" = 2 ] \
   && [ "$(p3e_store)" = "$before_store" ] \
   && grep -q '^airlock-ledger: residue alpha:' "$P3E/p3e5b.log"; then
  ok "P3E-5 both hooks failing replays exactly once and keeps the installation record"
else
  bad "P3E-5 replay count or record changed (rc=$both_rc): $(tail -6 "$P3E/p3e5b.log")"
fi

# --- P3E-16: concurrent app writes leave one complete JSON document ---------
# Prepare the mirror once so this checks the installation record's atomic writer.
p3e_env
p3e_app_source alpha
p3e_app_source beta
p3e_company "concurrent applications"
p3e | "$LEDGER" apply alpha >/dev/null 2>&1
p3e | "$LEDGER" remove alpha >/dev/null 2>&1
p3e | "$LEDGER" apply alpha >"$P3E/concurrent-alpha.log" 2>&1 & p3e_alpha_pid=$!
p3e | "$LEDGER" apply beta >"$P3E/concurrent-beta.log" 2>&1 & p3e_beta_pid=$!
wait "$p3e_alpha_pid"; p3e_alpha_rc=$?
wait "$p3e_beta_pid"; p3e_beta_rc=$?
if p3e_store | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d and set(d) <= {"alpha","beta"}; assert all(set(r)=={"repo","commit","artifacts"} for r in d.values())'; then
  ok "P3E-16 concurrent calls leave a complete installation record (app rc=$p3e_alpha_rc/$p3e_beta_rc; no success guarantee across shared source fetches)"
else
  bad "P3E-16 concurrent write failed or tore JSON (rc=$p3e_alpha_rc/$p3e_beta_rc)"
fi

# --- P3E-5: a hook that always fails — residue, and nothing recorded ----------
p3e_env
mkdir -p "$P3E/work/apps"
p3e_app_source alpha 'exit 1'
p3e_app_source beta
p3e_company "bad alpha, good beta"
: >"$P3E/hook-count"
p3e | "$LEDGER" apply alpha >"$P3E/p3e5.log" 2>&1; p3e5_rc=$?
if [ "$p3e5_rc" != 0 ] && [ "$(p3e_has alpha)" = False ] \
   && ! ls "$P3E/data/apps/alpha" >/dev/null 2>&1 \
   && ! grep -q '^restored ' "$P3E/p3e5.log" ; then
  ok "P3E-5 a first install whose hook always fails records nothing and leaves no app directory"
  p3e5=1
else
  bad "P3E-5 wrong (rc=$p3e5_rc alpha=$(p3e_has alpha))"
  p3e5=0
fi

# --- P3E-6: a failed FIRST install removes only what it created (C11) --------
p3e_env
p3e_app_source alpha 'exit 1'
p3e_company "alpha whose hook fails"
kept="$P3E/home/.local/share/airlock/p3e-alpha/extra.conf"
mkdir -p "$(dirname "$kept")"
printf 'operator data\n' >"$kept"
p3e | "$LEDGER" apply alpha >"$P3E/p3e6.log" 2>&1; p3e6_rc=$?
p3e6_units="$(find "$P3E/home/.config/systemd/user" -name 'p3e-alpha.service' | wc -l)"
p3e6_frag="$(find "$P3E/confd" -name 'alpha.conf' | wc -l)"
p3e6_dir="$(ls -d "$P3E/data/apps/alpha" 2>/dev/null | wc -l)"
if [ "$p3e6_rc" != 0 ] && [ "$p3e6_units" = 0 ] && [ "$p3e6_frag" = 0 ] \
   && [ "$p3e6_dir" = 0 ] && [ "$(p3e_has alpha)" = False ] \
   && [ "$(cat "$kept" 2>/dev/null)" = "operator data" ] ; then
  ok "P3E-6 a failed first install removes only what it created and keeps the operator's file"
  p3e6=1
else
  bad "P3E-6 wrong (rc=$p3e6_rc units=$p3e6_units frag=$p3e6_frag dir=$p3e6_dir row=$(p3e_has alpha) kept=$(cat "$kept" 2>/dev/null))"
  p3e6=0
fi

# --- P3E-7: remove takes ③'s artifacts and nothing else -------------------
p3e_env
p3e_app_source alpha
p3e_company "alpha"
p3e | "$LEDGER" apply alpha >/dev/null 2>&1
printf 'user data\n' >"$P3E/home/operator-notes.md"
: >"$P3E/serve.log"
p3e | "$LEDGER" remove alpha >"$P3E/p3e7.log" 2>&1; p3e7_rc=$?
p3e7_left="$(find "$P3E/home/.config/systemd/user" "$P3E/confd" "$P3E/home/.local" \
              "$P3E/data" -type f -name '*alpha*' 2>/dev/null | wc -l)"
# `grep -c` prints its 0 AND exits 1, so `|| echo 0` would make this "0\n0" and
# every comparison against it would be false for the wrong reason.
p3e7_site="$(grep -c 'hub-locations.d/alpha.conf' "$P3E/site/airlock.conf" 2>/dev/null || true)"
if [ "$p3e7_rc" = 0 ] && [ "$p3e7_left" = 0 ] && [ "$(p3e_has alpha)" = False ] \
   && [ "$p3e7_site" = 0 ] && [ -f "$P3E/home/operator-notes.md" ] \
   && grep -q -- '--http=18905 off' "$P3E/serve.log" ; then
  ok "P3E-7 remove deletes ③'s artifacts and the ingress, keeps unrecorded data"
  p3e7=1
else
  bad "P3E-7 wrong (rc=$p3e7_rc left=$p3e7_left row=$(p3e_has alpha) site=$p3e7_site serve=[$(tr '\n' '|' <"$P3E/serve.log")])"
  p3e7=0
fi

# --- P3E-8: A3 — a recorded path that is itself a symlink --------------------
p3e_env
p3e_app_source alpha
p3e_company "alpha"
p3e | "$LEDGER" apply alpha >/dev/null 2>&1
printf 'outside\n' >"$P3E/home/leaf-target.conf"
frag="$P3E/confd/hub-locations.d/alpha.conf"
rm -f "$frag" && ln -s "$P3E/home/leaf-target.conf" "$frag"
p3e | "$LEDGER" remove alpha >"$P3E/p3e8.log" 2>&1; p3e8_rc=$?
if [ "$p3e8_rc" = 0 ] && [ ! -e "$frag" ] && [ ! -L "$frag" ] \
   && [ -f "$P3E/home/leaf-target.conf" ] ; then
  ok "P3E-8 A3: a recorded path that became a symlink is removed as the LINK it now is; its target is not"
  p3e8=1
else
  bad "P3E-8 wrong (rc=$p3e8_rc link=$([ -L "$frag" ] && echo present || echo gone) target=$([ -f "$P3E/home/leaf-target.conf" ] && echo kept || echo lost))"
  p3e8=0
fi

# --- P3E-9: A3 — a recorded path whose ANCESTOR was swapped for a symlink -----
p3e_env
p3e_app_source alpha
p3e_company "alpha"
p3e | "$LEDGER" apply alpha >/dev/null 2>&1
mv "$P3E/home/.local/share/airlock/p3e-alpha" "$P3E/home/elsewhere-alpha"
ln -s "$P3E/home/elsewhere-alpha" "$P3E/home/.local/share/airlock/p3e-alpha"
cp "$P3E/state/installed-apps.json" "$P3E/p3e9-before.json"
p3e | "$LEDGER" remove alpha >"$P3E/p3e9.log" 2>&1; p3e9_rc=$?
if [ "$p3e9_rc" != 0 ] \
   && grep -q '^airlock-ledger: residue alpha:' "$P3E/p3e9.log" \
   && [ -f "$P3E/home/elsewhere-alpha/data.conf" ] \
   && cmp -s "$P3E/p3e9-before.json" "$P3E/state/installed-apps.json" ; then
  ok "P3E-9 A3: a swapped ancestor is refused as residue; outside data and retry ownership are preserved"
  p3e9=1
else
  bad "P3E-9 wrong (rc=$p3e9_rc row=$(p3e_has alpha) target=$([ -f "$P3E/home/elsewhere-alpha/data.conf" ] && echo kept || echo lost))"
  p3e9=0
fi

# --- P3E-10/11/12/13: bad input stops before any effect ----------------------
p3e_env
p3e_app_source alpha
p3e_company "alpha"
printf '{}' >"$P3E/state/installed-apps.json"
p3e | "$LEDGER" remove gamma >"$P3E/p3e10.log" 2>&1; p3e10_rc=$?
p3e | "$LEDGER" remove alpha >>"$P3E/p3e10.log" 2>&1; p3e10b_rc=$?
p3e | "$LEDGER" apply alpha >/dev/null 2>&1; p3e11_rc=$?
rm -f "$P3E/state/installed-apps.json"
p3e | "$LEDGER" apply alpha >/dev/null 2>&1; p3e11b_rc=$?
printf '{not json' >"$P3E/state/installed-apps.json"
malformed_bytes="$(cat "$P3E/state/installed-apps.json")"
p3e | "$LEDGER" apply alpha >"$P3E/p3e12.log" 2>&1; p3e12_rc=$?
p3e | "$LEDGER" remove alpha >>"$P3E/p3e12.log" 2>&1; p3e12b_rc=$?
bad_id_rc=0
for bad_id in "" "../x" "A/B"; do
  p3e | "$LEDGER" apply "$bad_id" >/dev/null 2>&1 && bad_id_rc=1
done
if [ "$p3e10_rc" != 0 ] && [ "$p3e10b_rc" != 0 ] \
   && [ "$p3e11_rc" = 0 ] && [ "$p3e11b_rc" = 0 ] \
   && [ "$p3e12_rc" != 0 ] && [ "$p3e12b_rc" != 0 ] \
   && [ "$bad_id_rc" = 0 ] \
   && [ "$(cat "$P3E/state/installed-apps.json")" = "$malformed_bytes" ] ; then
  ok "P3E-10/11/12/13 a missing row, an absent/empty/malformed ③ and blank or malformed ids all refuse before any effect"
  p3e_input=1
else
  bad "P3E-10..13 wrong (10=$p3e10_rc/$p3e10b_rc 11=$p3e11_rc/$p3e11b_rc 12=$p3e12_rc/$p3e12b_rc id=$bad_id_rc)"
  p3e_input=0
fi

# --- P3E-14: no ⑤ line is a plain error; a local --source is its own source -
p3e_env
p3e_app_source alpha
p3e_company "alpha"
p3e | "$LEDGER" apply alpha >/dev/null 2>&1
python3 - "$P3E/airlock.toml" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text("\n".join(l for l in path.read_text().splitlines()
                           if not l.startswith("company_repo")) + "\n")
PY
p3e | "$LEDGER" apply beta >"$P3E/p3e14.log" 2>&1; p3e14_rc=$?
mkdir -p "$P3E/local/delta" "$P3E/local/epsilon"
p3e_app_source delta
cp "$P3E/src/apps/delta/install.sh" "$P3E/local/delta/install.sh"
p3e_manifest delta 18906 >"$P3E/local/delta/airlock-app.toml"
printf 'v1\n' >"$P3E/local/delta/VERSION"
git init --quiet -b main "$P3E/local/delta"
git -C "$P3E/local/delta" add -A
git -C "$P3E/local/delta" commit --quiet -m delta
p3e | "$LEDGER" apply delta --source "$P3E/local/delta" >"$P3E/p3e14b.log" 2>&1
p3e14b_rc=$?
delta_head="$(git -C "$P3E/local/delta" rev-parse HEAD)"
cp "$P3E/src/apps/delta/install.sh" "$P3E/local/epsilon/install.sh"
p3e_manifest epsilon 18907 >"$P3E/local/epsilon/airlock-app.toml"
p3e | "$LEDGER" apply epsilon --source "$P3E/local/epsilon" >"$P3E/p3e14c.log" 2>&1
p3e14c_rc=$?
delta_row="$(p3e_store | python3 -c '
import json, sys
row = json.load(sys.stdin)["delta"]
print(row["repo"], row["commit"])')"
epsilon_row="$(p3e_store | python3 -c '
import json, sys
print(repr(json.load(sys.stdin)["epsilon"]["commit"]))')"
if [ "$p3e14_rc" != 0 ] && grep -q 'no source for beta' "$P3E/p3e14.log" \
   && [ "$p3e14b_rc" = 0 ] && [ "$p3e14c_rc" = 0 ] \
   && [ "${delta_row%% *}" = "$P3E/local/delta" ] && [ "${delta_row##* }" = "$delta_head" ] \
   && [ "$epsilon_row" = "''" ] ; then
  ok "P3E-14 with no ⑤ line a Company apply is a plain error; --source <dir> records that path, its HEAD, or '' when it is not git"
  p3e14=1
else
  bad "P3E-14 wrong (rc=$p3e14_rc/$p3e14b_rc/$p3e14c_rc delta=[$delta_row] epsilon=$epsilon_row)"
  p3e14=0
fi

# --- P3E-15: a manifest that will not parse is a refusal, not a half-install -
p3e_env
p3e_app_source alpha
printf 'this is not = = toml\n' >"$P3E/src/apps/alpha/airlock-app.toml"
p3e_company "alpha with a broken manifest"
p3e | "$LEDGER" apply alpha >"$P3E/p3e15.log" 2>&1; p3e15_rc=$?
p3e15_dir="$(ls -d "$P3E/data/apps/alpha" 2>/dev/null | wc -l)"
if [ "$p3e15_rc" != 0 ] && [ "$p3e15_dir" = 0 ] \
   && [ ! -e "$P3E/state/installed-apps.json" ] ; then
  ok "P3E-15 an unparseable manifest stops before the hook and leaves no app directory and no ③"
  p3e15=1
else
  bad "P3E-15 wrong (rc=$p3e15_rc dir=$p3e15_dir)"
  p3e15=0
fi

# --- P3E-17: A5 — a write target outside the fixture root is refused ---------
p3e_env
p3e_app_source alpha
p3e_company "alpha"
( export AIRLOCK_WEBROOT=/var/www/airlock-escape
  p3e | "$LEDGER" apply alpha >"$P3E/p3e17.log" 2>&1 )
p3e17_rc=$?
if [ "$p3e17_rc" != 0 ] \
   && grep -q '^airlock-ledger: fixture boundary:' "$P3E/p3e17.log" \
   && [ ! -e "$P3E/data/apps/alpha" ] ; then
  ok "P3E-17 a write target outside AIRLOCK_FIXTURE_ROOT is refused before any effect"
  p3e17=1
else
  bad "P3E-17 wrong (rc=$p3e17_rc)"
  p3e17=0
fi

# --- P3E-18: the v7 ledger converts on the first WRITE, never on a read ------
p3e_env
mkdir -p "$P3E/v7/app" "$P3E/plain"
p3e_app_source alpha
cp -R "$P3E/src/apps/alpha/." "$P3E/v7/app/"
p3e_manifest beta 18901 >"$P3E/plain/airlock-app.toml"
printf '#!/bin/sh\nexit 0\n' >"$P3E/plain/install.sh"
printf 'v7\n' >"$P3E/v7/app/VERSION"
git init --quiet -b main "$P3E/v7/app"
git -C "$P3E/v7/app" add -A
git -C "$P3E/v7/app" commit --quiet -m v7
python3 - "$P3E/state/app-ledger.json" "$P3E/v7/app" "$P3E/plain" <<'PY'
import json, sys
path, repo, plain = sys.argv[1], sys.argv[2], sys.argv[3]
store = {"version": 7, "events": [], "entries": {
    "alpha": {"committed": {
        "path": repo, "digest": "0" * 64,
        "artifacts": {"units": [], "fragments": [], "webroot": [], "files": [],
                      "rooted": [], "serve_ports": [18900]},
        "serve_mappings": {}, "capabilities": [],
        "lifecycle": {"install": True, "smoke": False, "deactivate": False},
        "order": 1, "source_class": "explicit", "unit_scopes": {},
        "serve_port_values": {"p": 18900}, "deps": [],
        "container_runtime": None,
        "roots": {"confd": "", "webroot": "", "home": "", "unit_user": "",
                  "unit_system": ""},
        "anchors": {}}},
    "beta": {"committed": {
        "path": plain, "digest": "0" * 64,
        "artifacts": {"units": [], "fragments": [], "webroot": [], "files": [],
                      "rooted": [], "serve_ports": [18901]},
        "serve_mappings": {"p": {"listen": 18901, "mode": "https", "target": 18901}},
        "serve_port_values": {"p": 18901},
        "capabilities": [], "order": 2, "source_class": "explicit",
        "unit_scopes": {}, "deps": [], "container_runtime": None,
        "lifecycle": {"install": True, "smoke": False, "deactivate": False},
        "roots": {"confd": "", "webroot": "", "home": "", "unit_user": "",
                  "unit_system": ""},
        "anchors": {}}},
    "gamma": {"intent": {
        "path": plain, "digest": "0" * 64, "order": 3, "deps": [],
        "source_class": "explicit", "capabilities": [],
        "container_runtime": None, "unit_scopes": {},
        "serve_port_values": {}, "serve_mappings": {},
        "artifacts_declared": {"units": [], "fragments": [], "webroot": [],
                               "files": [], "rooted": [], "serve_ports": []},
        "lifecycle": {"install": True, "smoke": False, "deactivate": False},
        "roots": {"confd": "", "webroot": "", "home": "", "unit_user": "",
                  "unit_system": ""},
        "anchors": {}}},
}}
open(path, "w").write(json.dumps(store, indent=2, sort_keys=True) + "\n")
PY
legacy_before="$(md5sum <"$P3E/state/app-ledger.json")"
alpha_head="$(git -C "$P3E/v7/app" rev-parse HEAD)"
# Two reads that both go through load_installed()'s v7 conversion: `list`
# lists the converted rows, `plan` answers from them. Neither may touch the box.
"$LEDGER" list >"$P3E/p3e18-apps.txt" 2>&1; p3e18_apps_rc=$?
printf '{"packages":{}}' | "$LEDGER" plan >"$P3E/p3e18-plan.txt" 2>&1; p3e18_plan_rc=$?
legacy_after_plan="$(md5sum <"$P3E/state/app-ledger.json")"
legacy_names="$(ls "$P3E/state" | sort | tr '\n' ' ')"
p3e | "$LEDGER" apply alpha >"$P3E/p3e18.log" 2>&1; p3e18_write_rc=$?   # the first WRITE
p3e18_rows="$(p3e_store)"
p3e18_names="$(ls "$P3E/state" | sort | tr '\n' ' ')"
p3e | "$LEDGER" apply alpha >/dev/null 2>&1
p3e18_again="$(p3e_store)"
printf '{"version": 6, "entries": {}, "events": []}' >"$P3E/state/app-ledger.json"
rm -f "$P3E/state/app-ledger.v7.json" "$P3E/state/installed-apps.json"
v6_bytes="$(md5sum <"$P3E/state/app-ledger.json")"
p3e | "$LEDGER" remove beta >"$P3E/p3e18b.log" 2>&1; p3e18_v6_rc=$?
if [ "$p3e18_apps_rc" = 0 ] && grep -q '^alpha	' "$P3E/p3e18-apps.txt" \
   && grep -q "^reinstall	alpha$" "$P3E/p3e18-plan.txt" \
   && [ "$p3e18_write_rc" = 0 ] \
   && [ "$p3e18_plan_rc" = 0 ] \
   && [ "$legacy_before" = "$legacy_after_plan" ] \
   && [ "$legacy_names" = "app-ledger.json " ] \
   && [ "$p3e18_names" = "app-ledger.v7.json installed-apps.json " ] \
   && printf '%s' "$p3e18_rows" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert set(rows) == {"alpha", "beta"}, rows
assert rows["alpha"]["commit"] == sys.argv[2], rows["alpha"]
assert rows["beta"]["repo"] == sys.argv[1], rows["beta"]
assert rows["beta"]["commit"] == "", rows["beta"]
assert "https:18901" in rows["beta"]["artifacts"], rows["beta"]
assert "http:18905" in rows["alpha"]["artifacts"], rows["alpha"]
' "$P3E/plain" "$alpha_head" \
   && [ "$p3e18_again" = "$p3e18_rows" ] \
   && [ "$p3e18_v6_rc" != 0 ] \
   && [ "$(md5sum <"$P3E/state/app-ledger.json")" = "$v6_bytes" ] ; then
  ok "P3E-18 list reads the v7 ledger converted in memory and plan still answers from it; neither writes anything; the first write archives it as app-ledger.v7.json, keeps each port's mode, drops intent-only rows, and a version 6 ledger is a plain error"
  p3e18=1
else
  bad "P3E-18 wrong (names=[$legacy_names]->[$p3e18_names] apps_rc=$p3e18_apps_rc plan_rc=$p3e18_plan_rc plan=[$(tr "\n" "|" <"$P3E/p3e18-plan.txt")] apps=[$(tr '\n' '|' <"$P3E/p3e18-apps.txt")] v6_rc=$p3e18_v6_rc) rows=[$(tr '\n' '|' <<<"$p3e18_rows")] again_eq=$([ "$p3e18_again" = "$p3e18_rows" ] && echo y || echo n) v6bytes_ok=$([ "$(md5sum <"$P3E/state/app-ledger.json")" = "$v6_bytes" ] && echo y || echo n)"
  p3e18=0
fi

# --- P3E-20: an upgrade whose manifest dropped a file takes that file with it
p3e_env
p3e_app_source alpha
p3e_company "alpha v1"
extra="$P3E/home/.local/share/airlock/p3e-alpha/extra.conf"
mkdir -p "$(dirname "$extra")"
printf 'v1 only\n' >"$extra"
p3e | "$LEDGER" apply alpha >/dev/null 2>&1
python3 - "$P3E/work/apps/alpha/airlock-app.toml" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace(
    ',\n         "~/.local/share/airlock/p3e-alpha/extra.conf"]', ']'))
PY
git -C "$P3E/work" add -A
git -C "$P3E/work" commit --quiet -m "alpha v2 no longer declares extra.conf"
git -C "$P3E/work" push --quiet "$P3E/remote.git" main:main
p3e | "$LEDGER" apply alpha >"$P3E/p3e20.log" 2>&1; p3e20_rc=$?
p3e20_gone="$( [ -e "$extra" ] && echo present || echo gone)"
p3e20_recorded="$(p3e_store | python3 -c '
import json, sys
arts = json.load(sys.stdin)["alpha"]["artifacts"]
print("yes" if any(a.endswith("extra.conf") for a in arts) else "no")')"
if [ "$p3e20_rc" = 0 ] && [ "$p3e20_gone" = gone ] && [ "$p3e20_recorded" = no ] ; then
  ok "P3E-20 an upgrade whose manifest no longer declares a file removes it and stops recording it"
  p3e20=1
else
  bad "P3E-20 wrong (rc=$p3e20_rc file=$p3e20_gone recorded=$p3e20_recorded)"
  p3e20=0
fi

# --- P3E-21: the Company archive is a BINARY stream, not text ---------------
# A tar header is ASCII and NUL, both of which decode as UTF-8; only the file
# BODIES break it. So an all-text fixture passes and a real app with an asset
# in it does not — which is exactly the shape of a bug that ships green.
p3e_env
p3e_app_source alpha
printf '\x89PNG\r\n\x1a\n\xff\xfe\x00\x80binary\xff' > "$P3E/src/apps/alpha/logo.bin"
p3e_company "alpha with a non-UTF-8 asset"
p3e | "$LEDGER" apply alpha >"$P3E/p3e21.log" 2>&1; p3e21_rc=$?
p3e21_tree="$( [ -f "$P3E/data/apps/alpha/logo.bin" ] && echo present || echo gone)"
if [ "$p3e21_rc" = 0 ] && [ "$p3e21_tree" = present ] \
   && cmp -s "$P3E/src/apps/alpha/logo.bin" "$P3E/data/apps/alpha/logo.bin" ; then
  ok "P3E-21 git archive is read as bytes: an app with non-UTF-8 bytes installs byte-identically"
  p3e21=1
else
  bad "P3E-21 wrong (rc=$p3e21_rc asset=$p3e21_tree)"
  p3e21=0
fi

# Company source packages use a shared runtime, then carry it beside package.py
# in their detached artifacts. Exercise the real install hook through apply.
p3e_env
p3e_app_source alpha 'python3 -B "$AIRLOCK_APP_DIR/package.py"'
p3e_company "alpha shared runtime fixture"
mkdir -p "$P3E/work/tools"
cat >"$P3E/work/tools/package_runtime.py" <<'PY'
from pathlib import Path
def install():
    # The real package builder rejects group/other-writable source files.
    root = Path(__file__).resolve().parent
    assert not any(p.stat().st_mode & 0o022 for p in root.rglob('*') if p.is_file())
    assert (root / "install.sh").stat().st_mode & 0o111
    print("shared runtime loaded")
PY
cat >"$P3E/work/apps/alpha/package.py" <<'PY'
from pathlib import Path
import sys
here = Path(__file__).resolve().parent
for candidate in (here, here.parents[1] / "tools"):
    if (candidate / "package_runtime.py").is_file():
        sys.path.insert(0, str(candidate))
        break
from package_runtime import install
install()
PY
chmod 755 "$P3E/work/apps/alpha/install.sh"
git -C "$P3E/work" add apps/alpha/package.py apps/alpha/install.sh tools/package_runtime.py
git -C "$P3E/work" commit --quiet -m "shared package runtime"
git -C "$P3E/work" push --quiet "$P3E/remote.git" main:main
p3e | "$LEDGER" apply alpha --source company >"$P3E/shared-runtime.log" 2>&1; shared_rc=$?
if [ "$shared_rc" = 0 ] && [ "$(p3e_has alpha)" = True ] \
   && grep -q 'shared runtime loaded' "$P3E/shared-runtime.log" \
   && cmp -s "$P3E/work/tools/package_runtime.py" "$P3E/data/apps/alpha/package_runtime.py"; then
  ok "Company apply installs a source package that imports the pinned shared package runtime"
else
  bad "Company shared package runtime install failed (rc=$shared_rc)"
fi

# --- P3E-22: a projection that fails must say WHY, not raise ----------------
p3e_env
p3e_app_source alpha
p3e_company "alpha"
p3e | "$LEDGER" apply alpha >/dev/null 2>&1
# Dropping [apps.hub] is the projection failure a real operator can have: the
# renderer resolves the hub's nginx_port from that table and refuses to render
# a site without an entrance.
python3 - "$P3E/airlock.toml" <<'BREAKCFG'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text("\n".join(l for l in path.read_text().splitlines()
                           if l != "[apps.hub]") + "\n")
BREAKCFG
p3e_commit_app alpha "second commit" 'printf "v2\n" >VERSION'
p3e | "$LEDGER" apply alpha >"$P3E/p3e22.log" 2>&1; p3e22_rc=$?
p3e22_reason="$(grep -m1 '^airlock-ledger: restored\|^airlock-ledger: residue' "$P3E/p3e22.log")"
if [ "$p3e22_rc" != 0 ] \
   && ! grep -q 'Traceback' "$P3E/p3e22.log" \
   && grep -q 'render-nginx.sh failed:' "$P3E/p3e22.log" \
   && [ -n "$p3e22_reason" ] ; then
  ok "P3E-22 a projection failure is reported as a plain reason line and never as a traceback"
  p3e22=1
else
  bad "P3E-22 wrong (rc=$p3e22_rc reason=[$p3e22_reason] log=[$(tail -4 "$P3E/p3e22.log" | tr '\n' '|')])"
  p3e22=0
fi

# --- P3E-23: a restore that itself fails is residue, never `restored` -------
p3e_env
p3e_app_source alpha
p3e_company "alpha v1"
p3e | "$LEDGER" apply alpha >/dev/null 2>&1
v1_sha="$(p3e_sha)"
# v2's hook fails, so A4 replays v1 — and the box is in a state where that
# replay cannot finish either (the same broken config). The restore attempt's
# own return value is what must decide the answer.
# Dropping [apps.hub] is the projection failure a real operator can have: the
# renderer resolves the hub's nginx_port from that table and refuses to render
# a site without an entrance.
python3 - "$P3E/airlock.toml" <<'BREAKCFG'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text("\n".join(l for l in path.read_text().splitlines()
                           if l != "[apps.hub]") + "\n")
BREAKCFG
p3e_commit_app alpha "v2's hook fails too" 'exit 1'
p3e | "$LEDGER" apply alpha >"$P3E/p3e23.log" 2>&1; p3e23_rc=$?
p3e23_row="$(p3e_store | python3 -c 'import json,sys;print(json.load(sys.stdin)["alpha"]["commit"])')"
if [ "$p3e23_rc" != 0 ] && [ "$p3e23_row" = "$v1_sha" ] \
   && ! grep -q "^restored alpha $v1_sha\$" "$P3E/p3e23.log" \
   && grep -q '^airlock-ledger: residue alpha:' "$P3E/p3e23.log" ; then
  ok "P3E-23 a restore whose own apply fails reports residue and never claims restored"
  p3e23=1
else
  bad "P3E-23 wrong (rc=$p3e23_rc row=$p3e23_row want=$v1_sha log=[$(tail -6 "$P3E/p3e23.log" | tr '\n' '|')])"
  p3e23=0
fi

# --- P3E-24: __airlock.json membership follows ③, not airlock.toml ----------
# The launcher payload used to answer "which apps exist" from config alone, so
# an app that is in ③ and rendered into the nginx site could still be missing
# from the hub, and a configured-but-removed app could still be listed.
# `airlock-config webjson` now takes the engine's id list; without
# AIRLOCK_PROJECT_IDS it reads config exactly as before, which is every caller
# except the engine.
p3e_env
p3e_app_source alpha
p3e_app_source beta
p3e_company "alpha beta"
python3 - "$P3E/airlock.toml" <<'P3ECFG'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text(path.read_text().replace("[apps.hub]",
                                        "[apps.hub]\n[apps.alpha]\n[apps.ghost]"))
P3ECFG
p3e | "$LEDGER" apply alpha >/dev/null 2>&1
p3e24_config="$("$ROOT/bin/airlock-config" webjson 2>/dev/null)"
p3e24_engine="$(AIRLOCK_PROJECT_IDS=alpha "$ROOT/bin/airlock-config" webjson 2>/dev/null)"
p3e24_keys_config="$(printf '%s' "$p3e24_config" | python3 -c 'import json,sys;print(" ".join(sorted(json.load(sys.stdin)["apps"])))')"
p3e24_keys_engine="$(printf '%s' "$p3e24_engine" | python3 -c 'import json,sys;print(" ".join(sorted(json.load(sys.stdin)["apps"])))')"
if [ "$p3e24_keys_config" = "alpha ghost hub" ] && [ "$p3e24_keys_engine" = "alpha" ] ; then
  ok "P3E-24 __airlock.json lists exactly the id list the engine passes; without it config decides as before"
  p3e24=1
else
  bad "P3E-24 wrong (with id list: [$p3e24_keys_engine] without: [$p3e24_keys_config])"
  p3e24=0
fi

printf 'P3E | expected: every P3E case 1,2,3,5,6,7,8,9,10-13,14,15,17,18,20,21,22,23,24 == 1 | observed: p3e1_shape=%s p3e1_isolation=%s p3e1_projection=%s p3e2=%s p3e3=%s p3e5=%s p3e6=%s p3e7=%s p3e8=%s p3e9=%s p3e_input=%s p3e14=%s p3e15=%s p3e17=%s p3e18=%s p3e20=%s p3e21=%s p3e22=%s p3e23=%s p3e24=%s | verdict: %s | signal: fixture | evidence: install/test-update.sh@%s\n' \
  "$p3e1_shape" "$p3e1_isolation" "$p3e1_projection" "$p3e2" "$p3e3" "$p3e5" \
  "$p3e6" "$p3e7" "$p3e8" "$p3e9" "$p3e_input" "$p3e14" "$p3e15" "$p3e17" \
  "$p3e18" "$p3e20" "$p3e21" "$p3e22" "$p3e23" "$p3e24" \
  "$([ "$p3e1_shape$p3e1_isolation$p3e1_projection$p3e2$p3e3$p3e5$p3e6$p3e7$p3e8$p3e9$p3e_input$p3e14$p3e15$p3e17$p3e18$p3e20$p3e21$p3e22$p3e23$p3e24" = "11111111111111111111" ] && printf PASS || printf FAIL)" \
  "$(git -C "$ROOT" rev-parse HEAD)"

# The app engine must retire owned HTTP ingress through its apply/remove CLI,
# preserve other owners, and compensate partial failed upgrades.
if AIRLOCK_INGRESS_TEST_SCRATCH="$scratch/ingress" python3 "$HERE/test-ledger-ingress.py" >"$scratch/ingress.log" 2>&1; then
  ok "legacy HTTP ownership, Hub retirement, retry and A4 ingress compensation"
else
  bad "HTTP ownership or ingress compensation failed"
  cat "$scratch/ingress.log"
fi

# Pin the SHA from this fetch, including concurrent fetches into the same mirror.
if AIRLOCK_COMPANY_PIN_TEST_SCRATCH="$scratch/company-pin" python3 -B "$HERE/test-ledger-company-pin.py" >"$scratch/company-pin.log" 2>&1; then
  ok "Company pin keeps its own fetched SHA across repository and main interleavings"
else
  bad "Company pin returned another fetch SHA or left a temporary ref"
  cat "$scratch/company-pin.log"
fi

# The last word on A5: whatever the suite did, this checkout is where it started.
_p3e_end_head="$(git -C "$ROOT" rev-parse HEAD)"
_p3e_end_dirty="$(git -C "$ROOT" status --porcelain)"
if [ "$_p3e_guard_head" = "$_p3e_end_head" ] && [ "$_p3e_guard_dirty" = "$_p3e_end_dirty" ] ; then
  ok "the checkout under test is byte-identical to how the suite found it (no commit, no file)"
  p3e_clean=1
else
  bad "the suite moved the checkout under test: HEAD $_p3e_guard_head -> $_p3e_end_head"
  [ "$_p3e_guard_dirty" = "$_p3e_end_dirty" ] \
    || bad "the suite left files behind: [$(printf '%s' "$_p3e_end_dirty" | head -5 | tr '\n' '|')]"
  p3e_clean=0
fi

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
