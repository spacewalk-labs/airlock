#!/usr/bin/env bash
# Offline updater contracts: source replacement, operator bytes/history, preview,
# installer status and retry. Recovery/provenance/mutex behavior was removed.
set -uo pipefail
. "$(dirname "$0")/test-lib.sh"
airlock_pin_paseo_mem
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATE="$ROOT/bin/airlock-update"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export GIT_CONFIG_GLOBAL="$scratch/gitconfig" GIT_CONFIG_NOSYSTEM=1
export AIRLOCK_SELFKILL_ESCAPED=1
git config -f "$GIT_CONFIG_GLOBAL" user.name airlock-test
git config -f "$GIT_CONFIG_GLOBAL" user.email airlock-test@localhost
passed=0 failed=0
ok() { printf 'ok %s\n' "$1"; passed=$((passed+1)); }
bad() { printf 'FAIL %s\n' "$1"; failed=$((failed+1)); }
REL="$scratch/release" BOX="$scratch/box"
mkdir -p "$REL/install" "$REL/docker"
printf 'old\n' > "$REL/source"
printf 'old other\n' > "$REL/other"
printf 'retired\n' > "$REL/retired"
printf 'airlock.toml\n' > "$REL/.gitignore"
printf '#!/bin/bash\nprintf "%%s" "$#" > "$AIRLOCK_TEST_ARGS"\nexit "${AIRLOCK_TEST_RC:-0}"\n' > "$REL/install/airlock-install.sh"
printf '#!/bin/bash\nprintf "%%s" "$AIRLOCK_MACHINE" > "$AIRLOCK_TEST_ARGS"\n' > "$REL/docker/orbstack-machine-setup.sh"
git -C "$REL" init -q -b main
git -C "$REL" add -A; git -C "$REL" commit -qm old
old="$(git -C "$REL" rev-parse HEAD)"
make_box() {
 rm -rf "$BOX"; mkdir -p "$BOX"
 git -C "$REL" archive "$old" | tar -x -C "$BOX"
 printf 'private config\n' > "$BOX/airlock.toml"
 printf 'private notes\n' > "$BOX/notes"
 git -C "$BOX" init -q -b main
 git -C "$BOX" add -A; git -C "$BOX" commit -qm initial
}
run_update() { AIRLOCK_DIR="$BOX" AIRLOCK_RELEASE_URL="$REL" AIRLOCK_TEST_ARGS="$scratch/args" bash "$UPDATE" "$@"; }
printf 'new\n' > "$REL/source"
printf 'new other\n' > "$REL/other"
printf 'new file\n' > "$REL/added"
rm "$REL/retired"
git -C "$REL" add -A; git -C "$REL" commit -qm new
make_box
before="$(git -C "$BOX" rev-parse HEAD)"
run_update --no-install > "$scratch/log" 2>&1
if [ "$(cat "$BOX/source")" = new ] && [ "$(cat "$BOX/notes")" = 'private notes' ] && [ "$(cat "$BOX/airlock.toml")" = 'private config' ] && git -C "$BOX" merge-base --is-ancestor "$before" HEAD; then ok 'release updates and operator history/files/config survive'; else bad 'basic update'; fi
if [ "$(git -C "$BOX" rev-list --count HEAD)" = 2 ] && [ ! -e "$scratch/args" ]; then ok 'one release commit and --no-install skips installer'; else bad 'release commit/no-install'; fi
# An unrelated initial operator commit is not a released source tree.
COLLISION_REL="$scratch/initial-collision-release" COLLISION_BOX="$scratch/initial-collision-box"
mkdir "$COLLISION_REL" "$COLLISION_BOX"
printf 'old source\n' > "$COLLISION_REL/source"
git -C "$COLLISION_REL" init -q -b main
git -C "$COLLISION_REL" add source; git -C "$COLLISION_REL" commit -qm first-release
cp "$COLLISION_REL/source" "$COLLISION_BOX/source"
printf 'operator private notes\n' > "$COLLISION_BOX/notes"
git -C "$COLLISION_BOX" init -q -b main
git -C "$COLLISION_BOX" add source notes; git -C "$COLLISION_BOX" commit -qm initial-operator
collision_before="$(git -C "$COLLISION_BOX" rev-parse HEAD)"
printf 'new source\n' > "$COLLISION_REL/source"
printf 'release notes\n' > "$COLLISION_REL/notes"
git -C "$COLLISION_REL" add source notes; git -C "$COLLISION_REL" commit -qm next-release
AIRLOCK_DIR="$COLLISION_BOX" AIRLOCK_RELEASE_URL="$COLLISION_REL" bash "$UPDATE" --no-install > "$scratch/collision-log" 2>&1; collision_rc=$?
if [ "$collision_rc" = 0 ] && [ "$(cat "$COLLISION_BOX/source")" = 'new source' ] && [ "$(cat "$COLLISION_BOX/notes")" = 'operator private notes' ] && git -C "$COLLISION_BOX" merge-base --is-ancestor "$collision_before" HEAD; then
 ok 'initial operator files survive new release path collisions while confirmed source updates'
else
 bad "initial operator collision rc=$collision_rc $(cat "$scratch/collision-log")"
fi
AIRLOCK_DIR="$COLLISION_BOX" AIRLOCK_RELEASE_URL="$COLLISION_REL" bash "$UPDATE" --no-install > "$scratch/collision-log" 2>&1; collision_rc=$?
[ "$collision_rc" = 0 ] && [ "$(cat "$COLLISION_BOX/notes")" = 'operator private notes' ] && ok 'initial operator collision stays preserved on the next update' || bad 'initial operator collision retry'
AIRLOCK_DIR="$COLLISION_BOX" AIRLOCK_RELEASE_URL="$COLLISION_REL" bash "$UPDATE" --dry-run --json > "$scratch/collision-json" 2> "$scratch/collision-log"; collision_rc=$?
if [ "$collision_rc" = 0 ] && python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); assert not v["available"] and v["changedCount"]==0' "$scratch/collision-json"; then
 ok 'preview excludes operator bytes that the completed update preserves'
else
 bad "preserved operator preview $(cat "$scratch/collision-json")"
fi
make_box
printf 'committed edit\n' > "$BOX/source"
git -C "$BOX" add source; git -C "$BOX" commit -qm operator
printf 'staged edit\n' > "$BOX/source"; git -C "$BOX" add source
printf 'working edit\n' > "$BOX/source"
rm "$BOX/other"
printf 'untracked collision\n' > "$BOX/added"
run_update --no-install > "$scratch/log" 2>&1
if [ "$(cat "$BOX/source")" = 'working edit' ] && [ "$(git -C "$BOX" show :source)" = 'staged edit' ] && [ ! -e "$BOX/other" ] && [ "$(cat "$BOX/added")" = 'untracked collision' ]; then ok 'committed, staged, working, deleted and untracked conflicting bytes stay on disk'; else bad "operator preservation $(cat "$scratch/log")"; fi
make_box
printf 'committed edit\n' > "$BOX/source"; git -C "$BOX" add source; git -C "$BOX" commit -qm operator
run_update --no-install > "$scratch/log" 2>&1
[ "$(cat "$BOX/source")" = 'committed edit' ] && ok 'committed-only operator edit survives' || bad 'committed-only edit'
make_box
before="$(git -C "$BOX" rev-parse HEAD)"
find "$BOX/.git" -type f -exec sha256sum {} + | sort > "$scratch/git-before"
run_update --dry-run --json > "$scratch/json" 2> "$scratch/log"
find "$BOX/.git" -type f -exec sha256sum {} + | sort > "$scratch/git-after"
if python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); assert v["available"] and v["changedCount"]==4 and len(v["ref"])==40' "$scratch/json" && cmp -s "$scratch/git-before" "$scratch/git-after" && [ "$(cat "$BOX/source")" = old ]; then ok 'JSON preview compares release bytes and leaves original Git/files untouched'; else bad "preview $(cat "$scratch/log")"; fi
rm -rf "$BOX/.git"
run_update --dry-run --json > "$scratch/json" 2> "$scratch/log"
if [ ! -e "$BOX/.git" ] && python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["available"]' "$scratch/json"; then ok 'preview works without operator Git repository'; else bad 'non-git preview'; fi
make_box
# Staged operator rename/deletion outside release stay separate from release commit.
git -C "$BOX" mv notes renamed-notes
git -C "$BOX" rm -q other
run_update --no-install > "$scratch/log" 2>&1
if [ "$(git -C "$BOX" show :renamed-notes)" = 'private notes' ] && ! git -C "$BOX" cat-file -e :notes 2>/dev/null && ! git -C "$BOX" cat-file -e :other 2>/dev/null && [ ! -e "$BOX/other" ]; then ok 'staged rename/deletion retains operator index and disk state'; else bad 'staged rename/deletion'; fi
make_box
# Explicit old release receipt establishes ownership of retired source.
git -C "$BOX" commit --allow-empty -qm "airlock-update: 배포본 ${old:0:12} 으로 갱신"
run_update --no-install > "$scratch/log" 2>&1
[ ! -e "$BOX/retired" ] && ok 'recorded retired release source is removed' || bad 'retired source'
make_box
# Confirmed initial source participates in deletion without losing operator files.
run_update --no-install > "$scratch/initial-retired-log" 2>&1; retired_rc=$?
if [ "$retired_rc" = 0 ] && [ ! -e "$BOX/retired" ] && [ "$(cat "$BOX/notes")" = 'private notes' ]; then
 ok 'confirmed initial release files retire while initial operator notes remain'
else
 bad "initial source retirement rc=$retired_rc $(cat "$scratch/initial-retired-log")"
fi
run_update --no-install > "$scratch/initial-retired-log" 2>&1; retired_rc=$?
run_update --dry-run --json > "$scratch/initial-retired-json" 2> "$scratch/initial-retired-log"; preview_rc=$?
if [ "$retired_rc" = 0 ] && [ "$preview_rc" = 0 ] && [ ! -e "$BOX/retired" ] && [ "$(cat "$BOX/notes")" = 'private notes' ] && python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); assert not v["available"] and v["changedCount"]==0' "$scratch/initial-retired-json"; then
 ok 'initial retirement remains removed on retry and completed JSON preview'
else
 bad 'initial retirement retry/preview'
fi
make_box
printf 'operator changed retired source\n' > "$BOX/retired"
run_update --no-install > "$scratch/initial-retired-log" 2>&1; retired_rc=$?
[ "$retired_rc" = 0 ] && [ "$(cat "$BOX/retired")" = 'operator changed retired source' ] && ok 'operator changes to confirmed retiring source are preserved' || bad 'initial changed source retirement'
make_box
mkdir "$scratch/outside"
printf 'outside precious\n' > "$scratch/outside/source"
rm "$BOX/source"; ln -s "$scratch/outside/source" "$BOX/source"
run_update --no-install > "$scratch/log" 2>&1
if [ -L "$BOX/source" ] && [ "$(cat "$scratch/outside/source")" = 'outside precious' ]; then ok 'operator symlink is retained and outside bytes untouched'; else bad 'symlink preservation'; fi
make_box
mkdir -p "$scratch/outside-parent"
printf 'outside installer\n' > "$scratch/outside-parent/airlock-install.sh"
rm -rf "$BOX/install"; ln -s "$scratch/outside-parent" "$BOX/install"
run_update --no-install > "$scratch/log" 2>&1
if [ -L "$BOX/install" ] && [ "$(cat "$scratch/outside-parent/airlock-install.sh")" = 'outside installer' ]; then ok 'operator parent symlink stays on disk without outside writes'; else bad 'parent symlink'; fi
# File/directory transitions must update unchanged source, while operator nodes survive.
TRANS="$scratch/transition"
git clone -q "$REL" "$TRANS"
mkdir -p "$TRANS/dir"
printf 'child old\n' > "$TRANS/dir/child"
printf 'file old\n' > "$TRANS/flat"
git -C "$TRANS" add -A; git -C "$TRANS" commit -qm shapes
shape_old="$(git -C "$TRANS" rev-parse HEAD)"
rm -rf "$BOX"; mkdir "$BOX"
git -C "$TRANS" archive HEAD | tar -x -C "$BOX"
git -C "$BOX" init -q -b main; git -C "$BOX" add -A; git -C "$BOX" commit -qm initial
rm -rf "$TRANS/dir" "$TRANS/flat"
printf 'directory became file\n' > "$TRANS/dir"
mkdir "$TRANS/flat"; printf 'file became directory\n' > "$TRANS/flat/child"
git -C "$TRANS" add -A; git -C "$TRANS" commit -qm transitioned
AIRLOCK_DIR="$BOX" AIRLOCK_RELEASE_URL="$TRANS" bash "$UPDATE" --no-install > "$scratch/log" 2>&1
if [ "$(cat "$BOX/dir")" = 'directory became file' ] && [ "$(cat "$BOX/flat/child")" = 'file became directory' ]; then ok 'unmodified file/directory source transitions update'; else bad "transitions $(cat "$scratch/log")"; fi
make_box
AIRLOCK_TEST_RC=23 run_update > "$scratch/log" 2>&1; rc=$?
if [ "$rc" = 23 ] && [ "$(cat "$scratch/args")" = 0 ] && [ "$(cat "$BOX/source")" = new ]; then ok 'new installer gets no args and failure status returns directly'; else bad "installer status $rc $(cat "$scratch/log")"; fi
run_update > "$scratch/log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok 'retry after installer failure proceeds' || bad 'retry'
AIRLOCK_UPDATE_UNAME=Darwin run_update --machine chosen > "$scratch/log" 2>&1
[ "$(cat "$scratch/args")" = chosen ] && ok 'explicit machine reaches platform installer' || bad 'machine'
# A recorded release symlink to a directory is retired by unlinking the leaf.
LINK_REL="$scratch/link-release" LINK_BOX="$scratch/link-box"
mkdir "$scratch/link-outside"; printf 'outside remains\n' > "$scratch/link-outside/data"
git clone -q "$REL" "$LINK_REL"
ln -s "$scratch/link-outside" "$LINK_REL/managed-link"
git -C "$LINK_REL" add managed-link; git -C "$LINK_REL" commit -qm managed-directory-link
git clone -q "$LINK_REL" "$LINK_BOX"
rm "$LINK_REL/managed-link"; git -C "$LINK_REL" commit -qam retire-managed-link
AIRLOCK_DIR="$LINK_BOX" AIRLOCK_RELEASE_URL="$LINK_REL" bash "$UPDATE" --no-install > "$scratch/link-log" 2>&1; link_rc=$?
if [ "$link_rc" = 0 ] && [ ! -L "$LINK_BOX/managed-link" ] && [ "$(cat "$scratch/link-outside/data")" = 'outside remains' ]; then
 ok 'retiring a release symlink to an external directory unlinks only its recorded leaf'
else
 bad "directory symlink retirement $(cat "$scratch/link-log")"
fi
# A regular clone already carries release history. Its first update compares
# against the shared installed revision, rather than the upstream root commit.
CLONE_REL="$scratch/clone-release" CLONE_BOX="$scratch/clone-box"
git clone -q "$REL" "$CLONE_REL"
printf 'obsolete release leaf\n' > "$CLONE_REL/obsolete"
git -C "$CLONE_REL" add obsolete; git -C "$CLONE_REL" commit -qm obsolete
git clone -q "$CLONE_REL" "$CLONE_BOX"
rm "$CLONE_REL/obsolete"
printf 'third release\n' > "$CLONE_REL/source"
git -C "$CLONE_REL" add -A; git -C "$CLONE_REL" commit -qm third
AIRLOCK_DIR="$CLONE_BOX" AIRLOCK_RELEASE_URL="$CLONE_REL" bash "$UPDATE" --no-install > "$scratch/clone-log" 2>&1; clone_rc=$?
[ "$clone_rc" = 0 ] && [ "$(cat "$CLONE_BOX/source")" = 'third release' ] && [ ! -e "$CLONE_BOX/obsolete" ] \
 && ok 'first update of an unedited clone replaces the installed release bytes' || bad "clone baseline $(cat "$scratch/clone-log")"
clone_older="$(git -C "$CLONE_REL" rev-parse HEAD~1)"
rm -rf "$CLONE_BOX"; git clone -q "$CLONE_REL" "$CLONE_BOX"
AIRLOCK_DIR="$CLONE_BOX" AIRLOCK_RELEASE_URL="$CLONE_REL" AIRLOCK_RELEASE_REF="$clone_older" bash "$UPDATE" --no-install > "$scratch/clone-log" 2>&1; clone_rc=$?
if [ "$clone_rc" = 0 ] && [ "$(cat "$CLONE_BOX/source")" = new ] && [ -f "$CLONE_BOX/obsolete" ]; then
 ok 'first clone update installs an explicitly older release without treating newer release bytes as operator edits'
else
 bad "clone older release $(cat "$scratch/clone-log")"
fi
rm -rf "$CLONE_BOX"; git clone -q "$CLONE_REL" "$CLONE_BOX"
printf 'committed operator edit\n' > "$CLONE_BOX/source"
git -C "$CLONE_BOX" add source; git -C "$CLONE_BOX" commit -qm operator
clone_head="$(git -C "$CLONE_BOX" rev-parse HEAD)"
printf 'fourth release\n' > "$CLONE_REL/source"
printf 'fourth other\n' > "$CLONE_REL/other"
git -C "$CLONE_REL" add -A; git -C "$CLONE_REL" commit -qm fourth
AIRLOCK_DIR="$CLONE_BOX" AIRLOCK_RELEASE_URL="$CLONE_REL" bash "$UPDATE" --no-install > "$scratch/clone-log" 2>&1; clone_rc=$?
if [ "$clone_rc" = 0 ] && [ "$(cat "$CLONE_BOX/source")" = 'committed operator edit' ] && [ "$(cat "$CLONE_BOX/other")" = 'fourth other' ] && git -C "$CLONE_BOX" merge-base --is-ancestor "$clone_head" HEAD; then
 ok 'first clone update keeps committed operator edits and history while updating other source'
else
 bad "clone operator edit $(cat "$scratch/clone-log")"
fi
# Release identity still gets a receipt when its source tree is unchanged.
EMPTY_REL="$scratch/empty-release" EMPTY_BOX="$scratch/empty-box"
git clone -q "$REL" "$EMPTY_REL"; git clone -q "$EMPTY_REL" "$EMPTY_BOX"
AIRLOCK_DIR="$EMPTY_BOX" AIRLOCK_RELEASE_URL="$EMPTY_REL" bash "$UPDATE" --no-install > "$scratch/empty-log" 2>&1
empty_before="$(git -C "$EMPTY_BOX" rev-list --count HEAD)"
git -C "$EMPTY_REL" commit -q --allow-empty -m unchanged-release
empty_release="$(git -C "$EMPTY_REL" rev-parse HEAD)"
AIRLOCK_DIR="$EMPTY_BOX" AIRLOCK_RELEASE_URL="$EMPTY_REL" bash "$UPDATE" --no-install > "$scratch/empty-log" 2>&1; empty_rc=$?
empty_after="$(git -C "$EMPTY_BOX" rev-list --count HEAD)"
AIRLOCK_DIR="$EMPTY_BOX" AIRLOCK_RELEASE_URL="$EMPTY_REL" bash "$UPDATE" --no-install >> "$scratch/empty-log" 2>&1; empty_again_rc=$?
if [ "$empty_rc" = 0 ] && [ "$empty_again_rc" = 0 ] && [ "$empty_after" = "$((empty_before + 1))" ] && [ "$(git -C "$EMPTY_BOX" rev-list --count HEAD)" = "$empty_after" ] && git -C "$EMPTY_BOX" log -1 --format=%s | rg -q "$empty_release"; then
 ok 'an unchanged release tree records its identity once and repeats without extra history'
else
 bad "same-tree receipt $(cat "$scratch/empty-log")"
fi
# Old updater remote configuration must not let ordinary fetches alter source metadata.
REMOTE_REL="$scratch/remote-release" REMOTE_BOX="$scratch/remote-box"
git clone -q "$REL" "$REMOTE_REL"; git clone -q "$REMOTE_REL" "$REMOTE_BOX"
git -C "$REMOTE_BOX" remote add airlock-release "$REMOTE_REL"
git -C "$REMOTE_BOX" fetch -q airlock-release
printf 'old updater operator edit\n' > "$REMOTE_BOX/source"
git -C "$REMOTE_BOX" add source; git -C "$REMOTE_BOX" commit -qm old-operator
remote_operator_head="$(git -C "$REMOTE_BOX" rev-parse HEAD)"
printf 'remote new other\n' > "$REMOTE_REL/other"
git -C "$REMOTE_REL" commit -qam remote-next
AIRLOCK_DIR="$REMOTE_BOX" AIRLOCK_RELEASE_URL="$REMOTE_REL" bash "$UPDATE" --no-install > "$scratch/remote-log" 2>&1; remote_rc=$?
remote_owned="$(git -C "$REMOTE_BOX" rev-parse refs/remotes/airlock-release/main)"
printf 'external fetch other\n' > "$REMOTE_REL/other"
git -C "$REMOTE_REL" commit -qam remote-external-fetch
git -C "$REMOTE_BOX" fetch -q --all
if [ "$remote_rc" = 0 ] && [ "$(cat "$REMOTE_BOX/source")" = 'old updater operator edit' ] && [ "$(cat "$REMOTE_BOX/other")" = 'remote new other' ] && ! git -C "$REMOTE_BOX" config --get-regexp '^remote\.airlock-release\.' >/dev/null && [ "$(git -C "$REMOTE_BOX" rev-parse refs/remotes/airlock-release/main)" = "$remote_owned" ] && git -C "$REMOTE_BOX" merge-base --is-ancestor "$remote_operator_head" HEAD; then
 ok 'old updater remote is retired while source ownership, operator history and ordinary fetch-all remain correct'
else
 bad "old remote ownership $(cat "$scratch/remote-log")"
fi
# Inject one real Python filesystem write failure by its unique public content.
# The oracle reads disk and Git state after failure, then after an ordinary retry.
WRITE_REL="$scratch/write-release" WRITE_BOX="$scratch/write-box" FAULT="$scratch/write-fault"
git clone -q "$REL" "$WRITE_REL"
mkdir -p "$WRITE_REL/protected" "$FAULT"
printf 'old first\n' > "$WRITE_REL/a-first"
printf 'old late\n' > "$WRITE_REL/protected/late"
printf 'old early\n' > "$WRITE_REL/b-early"
printf 'old edit\n' > "$WRITE_REL/c-edit"
git -C "$WRITE_REL" add -A; git -C "$WRITE_REL" commit -qm write-baseline
git clone -q "$WRITE_REL" "$WRITE_BOX"
printf 'operator edit\n' > "$WRITE_BOX/a-first"
write_head="$(git -C "$WRITE_BOX" rev-parse HEAD)"
printf 'release first\n' > "$WRITE_REL/a-first"
printf 'release early\n' > "$WRITE_REL/b-early"
printf 'partial leaf\n' > "$WRITE_REL/b-new-partial"
printf 'release edit\n' > "$WRITE_REL/c-edit"
printf 'write-fault-fixture\n' > "$WRITE_REL/protected/late"
git -C "$WRITE_REL" add -A; git -C "$WRITE_REL" commit -qm write-release
cat > "$FAULT/sitecustomize.py" <<'PY_FAULT'
import os
from pathlib import Path
original = Path.write_bytes
marker = Path(os.environ['AIRLOCK_TEST_FAULT_MARKER'])
def write_bytes(path, content):
    if content in (b'write-fault-fixture\n', b'write-fault-fixture-2\n') and not marker.exists():
        marker.touch()
        raise PermissionError('one fixture release write failed')
    return original(path, content)
Path.write_bytes = write_bytes
PY_FAULT
fault_update() {
 PYTHONPATH="$FAULT" AIRLOCK_TEST_FAULT_MARKER="$scratch/write-fault-once" \
 AIRLOCK_DIR="$WRITE_BOX" AIRLOCK_RELEASE_URL="$WRITE_REL" bash "$UPDATE" --no-install
}
fault_update > "$scratch/write-log" 2>&1; write_rc=$?
if [ "$write_rc" != 0 ] && [ "$(cat "$WRITE_BOX/a-first")" = 'operator edit' ] && [ "$(cat "$WRITE_BOX/protected/late")" = 'old late' ] && [ "$(git -C "$WRITE_BOX" rev-parse HEAD)" = "$write_head" ]; then
 ok 'failed release write retains operator edits and the old leaf without recording a completed release'
else
 bad "failed write ownership $(cat "$scratch/write-log")"
fi
fault_update > "$scratch/write-log" 2>&1; write_rc=$?
if [ "$write_rc" = 0 ] && [ "$(cat "$WRITE_BOX/a-first")" = 'operator edit' ] && [ "$(cat "$WRITE_BOX/protected/late")" = 'write-fault-fixture' ] && git -C "$WRITE_BOX" merge-base --is-ancestor "$write_head" HEAD; then
 ok 'ordinary retry completes the interrupted source write and preserves operator bytes and history'
else
 bad "interrupted write retry $(cat "$scratch/write-log")"
fi
# The remote can advance between a failed update and an ordinary retry.
# Completed source writes belong to the fetched Git tree, including new leaves.
rm -rf "$WRITE_BOX"; git clone -q "$WRITE_REL" "$WRITE_BOX"
git -C "$WRITE_BOX" reset -q --hard "$write_head"
printf 'operator edit\n' > "$WRITE_BOX/a-first"
rm "$scratch/write-fault-once"
fault_update > "$scratch/write-log" 2>&1; write_rc=$?
partial_rc="$write_rc"
printf 'committed after failure\n' > "$WRITE_BOX/c-edit"
git -C "$WRITE_BOX" add c-edit; git -C "$WRITE_BOX" commit -qm operator-after-failure
post_failure_head="$(git -C "$WRITE_BOX" rev-parse HEAD)"
printf 'staged after failure\n' > "$WRITE_BOX/c-edit"
git -C "$WRITE_BOX" add c-edit
printf 'working after failure\n' > "$WRITE_BOX/c-edit"
printf 'advanced early\n' > "$WRITE_REL/b-early"
printf 'advanced late\n' > "$WRITE_REL/protected/late"
rm "$WRITE_REL/b-new-partial"
printf 'write-fault-fixture-2\n' > "$WRITE_REL/00-first"
git -C "$WRITE_REL" add -A; git -C "$WRITE_REL" commit -qm advanced-after-failure
rm "$scratch/write-fault-once"
fault_update > "$scratch/write-log" 2>&1; second_fault_rc=$?
printf 'final early\n' > "$WRITE_REL/b-early"
printf 'final late\n' > "$WRITE_REL/protected/late"
printf 'final first\n' > "$WRITE_REL/00-first"
git -C "$WRITE_REL" add -A; git -C "$WRITE_REL" commit -qm advanced-after-second-failure
fault_update > "$scratch/write-log" 2>&1; write_rc=$?
if [ "$partial_rc" != 0 ] && [ "$second_fault_rc" != 0 ] && [ "$write_rc" = 0 ] && [ "$(cat "$WRITE_BOX/a-first")" = 'operator edit' ] && [ "$(cat "$WRITE_BOX/b-early")" = 'final early' ] && [ "$(cat "$WRITE_BOX/protected/late")" = 'final late' ] && [ ! -e "$WRITE_BOX/b-new-partial" ]; then
 ok 'retry after two failed releases advance updates earlier partial writes and removes partial new leaves while preserving operator edits'
else
 bad "advanced interrupted write retry $(cat "$scratch/write-log")"
fi
if [ "$(cat "$WRITE_BOX/c-edit")" = 'working after failure' ] && [ "$(git -C "$WRITE_BOX" show :c-edit)" = 'staged after failure' ] && git -C "$WRITE_BOX" merge-base --is-ancestor "$post_failure_head" HEAD; then
 ok 'operator commit, index and working edits made after a partial failure survive later releases'
else
 bad 'post-failure operator history/index/working preservation'
fi
# A newer release can remove the leaf that made the previous write fail.
# It must apply directly; replaying that old source is an unnecessary admission gate.
OBSOLETE_REL="$scratch/obsolete-release" OBSOLETE_BOX="$scratch/obsolete-box" OBSOLETE_FAULT="$scratch/obsolete-fault"
git clone -q "$REL" "$OBSOLETE_REL"; git clone -q "$OBSOLETE_REL" "$OBSOLETE_BOX"
mkdir -p "$OBSOLETE_REL/z-blocked" "$OBSOLETE_FAULT"
printf 'source with obsolete failure\n' > "$OBSOLETE_REL/source"
printf 'obsolete-blocked-leaf\n' > "$OBSOLETE_REL/z-blocked/late"
git -C "$OBSOLETE_REL" add -A; git -C "$OBSOLETE_REL" commit -qm obsolete-blocked-source
cat > "$OBSOLETE_FAULT/sitecustomize.py" <<'PY_OBSOLETE'
from pathlib import Path
original = Path.write_bytes
def write_bytes(path, content):
    if content == b'obsolete-blocked-leaf\n':
        raise PermissionError('the obsolete source leaf still cannot be written')
    return original(path, content)
Path.write_bytes = write_bytes
PY_OBSOLETE
obsolete_update() {
 PYTHONPATH="$OBSOLETE_FAULT" AIRLOCK_DIR="$OBSOLETE_BOX" AIRLOCK_RELEASE_URL="$OBSOLETE_REL" bash "$UPDATE" --no-install
}
obsolete_update > "$scratch/obsolete-log" 2>&1; obsolete_first_rc=$?
rm -rf "$OBSOLETE_REL/z-blocked"
printf 'source after obsolete failure\n' > "$OBSOLETE_REL/source"
git -C "$OBSOLETE_REL" add -A; git -C "$OBSOLETE_REL" commit -qm removed-obsolete-failure
obsolete_update > "$scratch/obsolete-log" 2>&1; obsolete_next_rc=$?
if [ "$obsolete_first_rc" != 0 ] && [ "$obsolete_next_rc" = 0 ] && [ "$(cat "$OBSOLETE_BOX/source")" = 'source after obsolete failure' ] && [ ! -e "$OBSOLETE_BOX/z-blocked/late" ]; then
 ok 'a new release applies directly when it removes the still-unwritable obsolete leaf'
else
 bad "obsolete source replay first=$obsolete_first_rc next=$obsolete_next_rc $(cat "$scratch/obsolete-log")"
fi
# Real Git lock failures exercise filesystem/ref/index ordering without command mocks.
python3 -B - "$UPDATE" "$scratch/git-record-failures" <<'PY_GIT_FAILURES' > "$scratch/git-record-results" 2>&1
from pathlib import Path
import json, os, shutil, stat, subprocess, sys

update, base = Path(sys.argv[1]), Path(sys.argv[2])
base.mkdir()
env = {key: value for key, value in os.environ.items() if not key.startswith('AIRLOCK_')}
env['AIRLOCK_SELFKILL_ESCAPED'] = '1'

def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args], env=env).strip()

def write(root, name, content):
    path = root/name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content+'\n')

def commit(root, message):
    git(root, 'add', '-A')
    git(root, 'commit', '-qm', message)

def run(box, release, *args):
    result = subprocess.run(['bash', str(update), *args],
                            env={**env, 'AIRLOCK_DIR':str(box), 'AIRLOCK_RELEASE_URL':str(release)},
                            capture_output=True, text=True)
    (box.parent/'last-update.log').write_text(result.stdout+result.stderr)
    return result

def disk(root):
    entries = {}
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if relative.parts[0] == '.git':
            continue
        mode = path.lstat().st_mode
        entries[str(relative)] = (stat.S_IMODE(mode),
                                 ('link', os.readlink(path)) if stat.S_ISLNK(mode) else
                                 ('file', path.read_bytes()) if path.is_file() else ('dir',))
    return entries

def setup(name, shape='source'):
    folder=base/name
    release, box=folder/'release', folder/'box'
    release.mkdir(parents=True)
    write(release,'source','v1')
    if shape=='retired': write(release,'a-retired','retired v1')
    if shape=='file-to-dir': write(release,'a-parent','parent v1')
    if shape=='dir-to-file': write(release,'a-parent/child','child v1')
    git(release,'init','-q','-b','main')
    commit(release,'v1')
    subprocess.check_call(['git','clone','-q',str(release),str(box)],env=env)
    if shape=='source': write(release,'source','v2')
    elif shape=='retired': (release/'a-retired').unlink()
    elif shape=='file-to-dir':
        (release/'a-parent').unlink()
        write(release,'a-parent/child','child v2')
    elif shape=='dir-to-file':
        shutil.rmtree(release/'a-parent')
        write(release,'a-parent','parent v2')
    commit(release,'v2')
    return release,box

def lock(box, relative):
    path=box/'.git'/relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('real fixture lock\n')
    return path

def finish(box, release, shape='source', operator=False):
    write(release,'source','v3')
    if shape=='file-to-dir': write(release,'a-parent/child','child v3')
    if shape=='dir-to-file': write(release,'a-parent','parent v3')
    commit(release,'v3')
    for repeat in range(2):
        result=run(box,release,'--no-install')
        assert result.returncode==0,result.stderr
        assert (box/'source').read_text()=='v3\n'
        assert git(box,'show','HEAD:source')==b'v3'
        assert git(box,'show',':source')==b'v3'
        if shape=='retired': assert not (box/'a-retired').exists()
        if shape=='file-to-dir': assert (box/'a-parent/child').read_text()=='child v3\n'
        if shape=='dir-to-file': assert (box/'a-parent').read_text()=='parent v3\n'
        if operator:
            assert (box/'operator').read_text()=='operator working\n'
            assert git(box,'show',':operator')==b'operator staged'
            assert git(box,'status','--porcelain')==b'MM operator'
        else:
            assert not git(box,'status','--porcelain')
    result=run(box,release,'--dry-run','--json')
    assert result.returncode==0,result.stderr
    preview=json.loads(result.stdout)
    assert not preview['available'] and preview['changedCount']==0,preview

for shape in ('source','retired','file-to-dir','dir-to-file'):
    release,box=setup('source-ref-'+shape,shape)
    old_disk=disk(box)
    old_head=git(box,'rev-parse','HEAD')
    old_index=(box/'.git/index').read_bytes()
    blocked=lock(box,'refs/remotes/airlock-release/main.lock')
    result=run(box,release,'--no-install')
    assert result.returncode==1,result.stderr
    assert disk(box)==old_disk,(shape,disk(box),old_disk)
    assert git(box,'rev-parse','HEAD')==old_head
    assert (box/'.git/index').read_bytes()==old_index
    blocked.unlink()
    finish(box,release,shape)
    print('PASS source ref failure restores '+shape+' node; direct v3, repeat and preview are clean',flush=True)

for operator in (False, True):
    release,box=setup('head-ref-'+str(operator))
    if operator:
        write(box,'operator','operator baseline')
        commit(box,'operator baseline')
        write(box,'operator','operator staged')
        git(box,'add','operator')
        write(box,'operator','operator working')
    old_head=git(box,'rev-parse','HEAD')
    old_index=(box/'.git/index').read_bytes()
    blocked=lock(box,'refs/heads/main.lock')
    result=run(box,release,'--no-install')
    assert result.returncode==1,result.stderr
    assert git(box,'rev-parse','HEAD')==old_head
    assert (box/'.git/index').read_bytes()==old_index
    blocked.unlink()
    finish(box,release,operator=operator)
    print('PASS HEAD ref failure leaves original index and operator edits='+str(operator)+'; direct v3, repeat and preview are clean',flush=True)
PY_GIT_FAILURES
git_record_rc=$?
while IFS= read -r record; do
 case "$record" in PASS\ *) ok "${record#PASS }" ;; esac
done < "$scratch/git-record-results"
if [ "$git_record_rc" != 0 ]; then
 bad "real Git record failure contracts $(cat "$scratch/git-record-results")"
fi

# Run the release's real installer loop against fixture platform consumers. The
# manifest parser and installed-row reader are production code; command shims
# replace host effects and expose the app-hook ordering/failure contract.
LOOP="$scratch/installer-loop"
mkdir -p "$LOOP"/{bin,install,apps/dev-monitor,hub,state,company,old/apps}
cp "$ROOT/install/airlock-install.sh" "$LOOP/install/"
cp "$ROOT/bin/airlock-config" "$LOOP/bin/"
cp "$ROOT/bin/airlock-ledger" "$LOOP/bin/ledger-engine"
cp "$ROOT/bin/airlock-app-engine" "$LOOP/bin/" 2>/dev/null || true
printf '<html>fixture</html>\n' > "$LOOP/hub/index.html"
cp "$LOOP/hub/index.html" "$LOOP/hub/wrong-owner.html"
: > "$LOOP/apps/dev-monitor/migration-lifecycle.sh"
cat > "$LOOP/install/lib.sh" <<'SH'
AIRLOCK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
log() { printf '%s\n' "$*"; }
airlock_escape_selfkill_cgroup() { :; }
airlock_pin_state_dir() { :; }
airlock_load() { AIRLOCK_HUB_ACCOUNTS_PORT=1; }
airlock_config() { :; }
airlock_run() { :; }
airlock_enable_linger() { :; }
airlock_entrance_url() { echo fixture; }
airlock_ingress_unverified() { :; }
SH
for script in airlock-secret-timer airlock-update-timer airlock-accounts-api; do
  printf 'printf "platform:%%s\\n" "${0##*/}" >> "$AIRLOCK_TEST_EVENTS"\n' > "$LOOP/install/$script.sh"
done
cat > "$LOOP/bin/airlock-ledger" <<'PY_LEDGER'
#!/usr/bin/env python3
from importlib.machinery import SourceFileLoader
from pathlib import Path
import os, subprocess, sys
sys.dont_write_bytecode = True
engine = SourceFileLoader("fixture_engine", str(Path(__file__).with_name("ledger-engine"))).load_module()
globals().update({name: value for name, value in vars(engine).items() if not name.startswith("__")})
if __name__ == "__main__":
    command, positional, _, _ = parse_cli(sys.argv[1:])
    with open(os.environ["AIRLOCK_TEST_EVENTS"], "a") as output:
        output.write("ledger:" + " ".join(sys.argv[1:]) + "\n")
    if command == "apply":
        row = load_installed()[positional[0]]
        sys.exit(subprocess.call(["bash", str(Path(row["repo"]) / "install.sh")]))
PY_LEDGER
chmod +x "$LOOP/bin/airlock-ledger"
LOOP="$LOOP" python3 - <<'PY_ROWS'
import json, os
from pathlib import Path
root = Path(os.environ['LOOP'])
rows = {}
# Deliberately list the dependant before its prerequisite.
for app, parent, deps in [('after', root/'apps', ['broken']),
                           ('broken', root/'apps', []),
                           ('external', root/'company', []),
                           ('oldcore', root/'old/apps', []),
                           ('--source', root/'apps', [])]:
    directory = parent/app
    directory.mkdir(parents=True, exist_ok=True)
    (directory/'airlock-app.toml').write_text('contract = 1\nid = "'+app+'"\n[dependencies]\napps = '+json.dumps(deps)+'\n')
    (directory/'install.sh').write_text('echo hook:'+app+' >> "$AIRLOCK_TEST_EVENTS"\n'+('exit 17\n' if app == 'broken' else 'exit 0\n'))
    rows[app] = {'repo': str(directory), 'commit': '', 'artifacts': []}
(root/'state/installed-apps.json').write_text(json.dumps(rows))
(root/'airlock.toml').write_text('[auth]\nowner = "fixture@example.com"\n')
PY_ROWS
export AIRLOCK_TEST_EVENTS="$scratch/loop-events"
run_loop() {
 AIRLOCK_PKG_INFO_FILE=/caller-stale AIRLOCK_CONFIG_SNAPSHOT=/caller-stale \
 AIRLOCK_APP_ID=caller-stale AIRLOCK_APP_DIR=/caller-stale \
 AIRLOCK_CONFIG="$LOOP/airlock.toml" AIRLOCK_STATE_DIR="$LOOP/state" \
 AIRLOCK_TS_FQDN=fixture.invalid AIRLOCK_WEBROOT="$LOOP/web" \
 AIRLOCK_CONFD="$LOOP/confd" AIRLOCK_NGINX_SITE="$LOOP/nginx.conf" \
 bash "$LOOP/install/airlock-install.sh"
}
run_loop > "$scratch/loop-log" 2>&1; loop_rc=$?
if [ "$loop_rc" = 1 ] && [ "$(grep '^hook:' "$AIRLOCK_TEST_EVENTS" | paste -sd,)" = 'hook:broken,hook:after,hook:--source' ] && grep -qx 'ledger:project' "$AIRLOCK_TEST_EVENTS" && [ "$(grep -c '^platform:' "$AIRLOCK_TEST_EVENTS")" = 3 ]; then
 ok 'real no-argument installer applies platform then current core rows in dependency order and continues after failure'
else
 bad "installer core loop rc=$loop_rc $(cat "$scratch/loop-log")"
fi
: > "$AIRLOCK_TEST_EVENTS"
run_loop > "$scratch/loop-log" 2>&1; loop_rc=$?
[ "$loop_rc" = 1 ] && [ "$(grep '^hook:' "$AIRLOCK_TEST_EVENTS" | paste -sd,)" = 'hook:broken,hook:after,hook:--source' ] \
 && ok 'installer retry repeats core rows and never applies Company or previous-checkout rows' || bad 'installer repeat'
# Update into a release containing the real installer, then execute the updater
# installed by that release on a second revision. Paths remain fixture-owned.
cp "$UPDATE" "$LOOP/bin/airlock-update"
printf 'state/\nairlock.toml\n' > "$LOOP/.gitignore"
git -C "$LOOP" init -q -b main
git -C "$LOOP" add -A; git -C "$LOOP" commit -qm fixture-platform
LOOP_RELEASE="$scratch/loop-release"
git clone -q "$LOOP" "$LOOP_RELEASE"
printf 'echo hook:broken >> "$AIRLOCK_TEST_EVENTS"\nexit 0\n' > "$LOOP_RELEASE/apps/broken/install.sh"
git -C "$LOOP_RELEASE" add -A; git -C "$LOOP_RELEASE" commit -qm fixed-app
run_platform_update() {
 AIRLOCK_PKG_INFO_FILE=/caller-stale AIRLOCK_CONFIG_SNAPSHOT=/caller-stale \
 AIRLOCK_APP_ID=caller-stale AIRLOCK_APP_DIR=/caller-stale \
 AIRLOCK_CONFIG="$LOOP/airlock.toml" AIRLOCK_STATE_DIR="$LOOP/state" \
 AIRLOCK_TS_FQDN=fixture.invalid AIRLOCK_WEBROOT="$LOOP/web" \
 AIRLOCK_CONFD="$LOOP/confd" AIRLOCK_NGINX_SITE="$LOOP/nginx.conf" \
 AIRLOCK_DIR="$LOOP" AIRLOCK_RELEASE_URL="$LOOP_RELEASE" bash "$1"
}
: > "$AIRLOCK_TEST_EVENTS"
run_platform_update "$UPDATE" > "$scratch/loop-update-log" 2>&1; loop_rc=$?
if [ "$loop_rc" = 0 ] && [ "$(grep '^hook:' "$AIRLOCK_TEST_EVENTS" | paste -sd,)" = 'hook:broken,hook:after,hook:--source' ]; then
 ok 'release replacement reaches its real no-argument installer and app hooks'
else
 bad "release-to-installer rc=$loop_rc $(cat "$scratch/loop-update-log")"
fi
printf 'second release\n' > "$LOOP_RELEASE/new-release"
git -C "$LOOP_RELEASE" add -A; git -C "$LOOP_RELEASE" commit -qm second-release
: > "$AIRLOCK_TEST_EVENTS"
run_platform_update "$LOOP/bin/airlock-update" > "$scratch/loop-update-log" 2>&1; loop_rc=$?
if [ "$loop_rc" = 0 ] && [ "$(cat "$LOOP/new-release")" = 'second release' ] && [ "$(grep '^hook:' "$AIRLOCK_TEST_EVENTS" | paste -sd,)" = 'hook:broken,hook:after,hook:--source' ]; then
 ok 'next execution uses installed updater and repeats the real installer successfully'
else
 bad "next installed updater rc=$loop_rc $(cat "$scratch/loop-update-log")"
fi
printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" = 0 ]
