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
# install/test-render-parity.sh gates that every suite whose text mentions an app
# installer pins the RAM the paseo installer takes its memory share from. This suite
# never installs anything, so the pin sits inert — cheaper than a gate clever enough to
# know that.
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
UPDATE="$ROOT/bin/airlock-update"

bootstrap_pins_current=1
for bootstrap_tool in bin/airlock-ledger install/lib.sh install/preflight.sh; do
  bootstrap_digest="$(sha256sum "$ROOT/$bootstrap_tool" | awk '{print $1}')"
  grep -q "$bootstrap_digest" "$UPDATE" || bootstrap_pins_current=0
done

pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

[ "$bootstrap_pins_current" = 1 ] \
  && ok "stream bootstrap pins the exact lease and escape tools shipped with this updater" \
  || bad "stream bootstrap tool digests drifted from this updater"

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
chmod 700 "$scratch"
printf '%s\n' 'airlock.live-box-fixture/v1' > "$scratch/.airlock-live-box-fixture-v1"
chmod 600 "$scratch/.airlock-live-box-fixture-v1"
export AIRLOCK_FIXTURE_LIVE_BOX_LEASE_DIR="$scratch/airlock-live-box"
mkdir -p "$scratch/home" "$scratch/state"
export HOME="$scratch/home" AIRLOCK_STATE_DIR="$scratch/state"
# This suite exercises update semantics, not the cgroup transport (that has its own
# focused fixture).  Pin a neutral cgroup so the host running the test cannot make
# every case escape through the suite's unrelated systemd-run shims.
printf '0::/fixture.scope\n' >"$scratch/cgroup"
export AIRLOCK_SELFKILL_CGROUP_FILE="$scratch/cgroup"
export GIT_CONFIG_GLOBAL="$scratch/gitconfig"   # never read the runner's identity
export GIT_CONFIG_NOSYSTEM=1
git config -f "$GIT_CONFIG_GLOBAL" user.name  airlock-test
git config -f "$GIT_CONFIG_GLOBAL" user.email airlock-test@localhost
git config -f "$GIT_CONFIG_GLOBAL" init.defaultBranch main

# ---------------------------------------------------------------- fixtures
seed_tree() {   # seed_tree <dir> <marker>
  local d="$1" m="$2"
  mkdir -p "$d/bin" "$d/install" "$d/docker" "$d/apps/hub" "$d/examples/app-package"
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
# plus their config and their own file. An earlier version of this suite built the box
# WITHOUT .git — a shape no operator has — and that unrepresentative fixture is why a
# mutation that deleted the safety commit passed 24/24.
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
  grep -q 'edited by hand' "$BOX/README.md" \
    && ok "an uncommitted edit is preserved and comes back on undo" \
    || bad "the operator's uncommitted edit was overwritten and is unrecoverable"
else
  bad "no undo revision printed for a box with uncommitted work"
fi

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

# ---------------------------------------------------------------- 2c) REVIEW: a failed
# safety commit must stop the run.  Found by adversarial review: `commit || true` let a
# failure pass silently, the tree was overwritten with no backup, and the printed
# `reset --hard` pointed at a commit that never contained the operator's edit.
#
# The failure has to land on the COMMIT and nowhere else, which took two tries to get
# right. A read-only object store makes `git add` fail first; read-only `refs/` makes
# the FETCH fail first. Both made this check pass while never reaching the code the
# review found — and a mutation that re-swallowed the commit failure survived the suite
# with this file still claiming to cover it. A stale ref lock is surgical: fetch writes
# refs/remotes, staging writes the index, and only the commit needs this one lock.
make_box "$BOX"
printf 'PRECIOUS UNCOMMITTED EDIT\n' > "$BOX/README.md"
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
[ "$rc2c" -ne 0 ] && ok "stops when the safety commit genuinely cannot be written" \
                  || bad "a failed safety commit was reported as success"
grep -q 'PRECIOUS' "$BOX/README.md" \
  && ok "and the operator's uncommitted edit is still there" \
  || bad "the edit was destroyed after the safety commit failed"
printf '%s' "$out2c" | grep -q 'reset --hard' \
  && bad "it printed an undo command it cannot honour" \
  || ok "and it does not print an undo command it cannot honour"

# ------------------------------------------------------------- 2c-ii) HARDWARE: a
# pre-commit hook must NOT stop it.  Measured on the first real box this ran against:
# the checkout carried this repository's own leak-scan pre-commit hook, and two config
# backups the operator had made contained the box's hostname. The hook refused the
# safety commit and the update stopped — on a box that followed our own guidance, which
# is every box worth updating. These two commits are snapshots of what is already on
# disk, not contributions, so they bypass authoring hooks.
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
  grep -q 'with a hook installed' "$BOX/README.md" \
    && ok "and the snapshot it took is real — the undo restores the edit" \
    || bad "the run continued but the snapshot did not contain the edit"
else
  bad "no undo revision printed on a box with a pre-commit hook"
fi
rm -f "$BOX/.git/hooks/pre-commit"

# ---------------------------------------------------------------- 2d) REVIEW: the
# .gitignore gap.  `git add -A` obeys the box's OWN .gitignore; `git checkout -- .`
# obeys nothing. A release path that an older .gitignore happens to ignore was
# therefore overwritten with no backup — and, being staged by the checkout, DELETED by
# the very `reset --hard` offered as the undo. Reachable today: .gitignore gained
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
if [ -f "$BOX/examples/app-package/airlock.toml" ] \
   && grep -q 'MY OWN EDIT' "$BOX/examples/app-package/airlock.toml"; then
  ok "and the undo brings it back with the operator's content"
else
  bad "the undo deleted it — this is the data-loss path the review found"
fi

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
# unrelated safety commit — that is the installed checkout contract.
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
    | grep -Fxq "airlock-update: 배포본 ${direction_current:0:12} 으로 갱신"; then
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
real_git="$(command -v git)"
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
real_git="$(command -v git)"
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
  cat >"$d/bin/airlock-ledger" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys

def ledger_path():
    return pathlib.Path(os.environ["AIRLOCK_STATE_DIR"]) / "app-ledger.json"

def load_store():
    return json.loads(ledger_path().read_text())

def _removal_order(store, selected):
    entries = store["entries"]
    seen, ordered = set(), []
    def visit(app):
        if app in seen:
            return
        seen.add(app)
        for dependent, record in entries.items():
            if app in record.get("deps", []):
                visit(dependent)
        if app in selected:
            ordered.append(app)
    for app in selected:
        visit(app)
    return ordered

def main():
    if sys.argv[1:2] != ["teardown"] or len(sys.argv) != 3:
        raise SystemExit(2)
    app = sys.argv[2]
    store = load_store()
    with open(os.environ["AIRLOCK_TEST_TEARDOWN_LOG"], "a", encoding="utf-8") as handle:
        handle.write(app + "\n")
    (pathlib.Path(os.environ["AIRLOCK_TEST_ARTIFACT_DIR"]) / app).unlink(missing_ok=True)
    store["entries"].pop(app)
    ledger_path().write_text(json.dumps(store, sort_keys=True) + "\n")

if __name__ == "__main__":
    main()
PY
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
printf '{\n  "version": 6,\n  "entries": {"a-parent":{"deps":[]},"z-child":{"deps":["a-parent"]}},\n  "events": []\n}\n' \
  >"$AIRLOCK_STATE_DIR/app-ledger.json"
printf '{"version":1,"entries":[{"package":"fixture","listen":444,"target":445}]}\n' \
  >"$AIRLOCK_STATE_DIR/plaintext-retirement.json"
printf 'new partial lock\n' >airlock.lock
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
  printf '{"version":6,"entries":{},"events":[]}\n' >"$RSTATE/app-ledger.json"
  printf '{"version":1,"entries":[]}\n' >"$RSTATE/plaintext-retirement.json"
  printf 'old lock\n' >"$BOX/airlock.lock"
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
recovery_tools_error=""
for recovery_tool in bin/airlock-ledger install/lib.sh install/preflight.sh; do
  recovery_file="$BOX/.git/airlock-update-rollback/lease-tools/$recovery_tool"
  if [ ! -f "$recovery_file" ] || [ -L "$recovery_file" ] \
     || [ "$(sha256sum "$recovery_file" 2>/dev/null | awk '{print $1}')" != \
          "$(cat "$recovery_file.sha256" 2>/dev/null)" ]; then
    recovery_tools_error="$recovery_tool"
    break
  fi
done
[ -z "$recovery_tools_error" ] \
  && ok "rollback capsule preserves exact lease, escape, and preflight tools" \
  || bad "rollback capsule tool is missing or changed: $recovery_tools_error"
rollback_out="$(run_rollback)"; rollback_rc=$?
[ "$rollback_rc" = 0 ] && ok "one rollback command restores and verifies the failed update" \
  || bad "rollback exited $rollback_rc: $rollback_out"
[ "$(git -C "$BOX" rev-parse HEAD)" = "$RBEFORE" ] \
  && [ "$(cat "$RUNTIME")" = old ] \
  && [ "$(tr '\n' ' ' <"$INSTALL_LOG")" = "new old " ] \
  && [ -z "$(git -C "$BOX" status --porcelain --untracked-files=all)" ] \
  && ok "rollback restores the old checkout and reruns the old installer" \
  || bad "rollback left checkout/runtime/install order mixed"
[ "$(tr '\n' ' ' <"$TEARDOWN_LOG")" = "z-child a-parent " ] \
  && [ ! -e "$ARTIFACT_DIR/z-child" ] && [ ! -e "$ARTIFACT_DIR/a-parent" ] \
  && ok "rollback tears down current artifacts in dependent-before-dependency order" \
  || bad "rollback did not exercise the current ledger teardown order"
grep -qx '{"version":6,"entries":{},"events":\[\]}' "$RSTATE/app-ledger.json" \
  && [ "$(cat "$RSTATE/plaintext-retirement.json")" = '{"version":1,"entries":[]}' ] \
  && [ "$(cat "$BOX/airlock.lock")" = 'old lock' ] \
  && ok "rollback restores the pre-update ledger, retirement record, and package lock" \
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
printf ' \n' >>"$RSTATE/app-ledger.json" # still valid JSON; represents a later state writer
state_refuse_out="$(run_rollback)"; state_refuse_rc=$?
[ "$state_refuse_rc" -ne 0 ] && [ "$(cat "$INSTALL_LOG")" = new ] \
  && [ "$(cat "$RUNTIME")" = new-partial ] \
  && ok "rollback refuses installed-state changes made after the failed update" \
  || bad "rollback overwrote state changed after failure: $state_refuse_out"

make_rollback_box
run_failed_update >/dev/null 2>&1
lock_ready="$scratch/ledger-lock-ready"
rm -f "$lock_ready"
flock "$RSTATE/app-ledger.lock" bash -c 'touch "$1"; sleep 2' airlock-lock "$lock_ready" &
lock_holder=$!
while [ ! -e "$lock_ready" ]; do sleep 0.01; done
lock_refuse_out="$(run_rollback)"; lock_refuse_rc=$?
wait "$lock_holder"
[ "$lock_refuse_rc" -ne 0 ] && [ "$(cat "$INSTALL_LOG")" = new ] \
  && [ "$(cat "$RUNTIME")" = new-partial ] \
  && [ -e "$ARTIFACT_DIR/z-child" ] && [ -e "$ARTIFACT_DIR/a-parent" ] \
  && [ ! -s "$TEARDOWN_LOG" ] \
  && ok "rollback refuses a competing ledger writer before teardown or restore" \
  || bad "rollback mutated the box while another ledger writer held the lock: $lock_refuse_out"

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
make_prehistory_box; rm -rf "$BOX/.git"
ph_nogit_preview="$(run_update --dry-run)"; ph_nogit_preview_rc=$?
[ "$ph_nogit_preview_rc" = 0 ] && printf '%s' "$ph_nogit_preview" | grep -q -- '--from-unknown' \
  && [ ! -d "$BOX/.git" ] \
  && ok "a pre-history box without .git previews through the throwaway repository" \
  || bad "a pre-history box without .git did not preview cleanly (rc=$ph_nogit_preview_rc): $ph_nogit_preview"
ph_nogit_run="$(run_update --no-install --from-unknown)"; ph_nogit_run_rc=$?
[ "$ph_nogit_run_rc" = 0 ] && grep -q 'version new' "$BOX/README.md" \
  && [ "$(cat "$BOX/airlock.toml")" = "$CONFIG" ] \
  && git -C "$BOX" log --format=%s | grep -q '^airlock-update: 배포본 [0-9a-f]\{12\} 으로 갱신$' \
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
# ---------------------------------------------------------- U1 managed channel
# This is a real Linux user+mount namespace with a chroot whose fixed /etc, /opt,
# and /var/lib paths are owned by namespace root.  No product path override or
# approval seam exists: the updater sees the production paths verbatim.
u1_root="$scratch/u1-root"
u1_public="$u1_root/fixture/public"
u1_box="$u1_root/fixture/box"
u1_box_relative="$u1_root/fixture/box-relative"
mkdir -p "$u1_public" "$u1_box" "$u1_box_relative" \
  "$u1_root/usr" "$u1_root/dev" "$u1_root/proc" \
  "$u1_root/work" "$u1_root/root" "$u1_root/tmp" "$u1_root/etc/airlock" \
  "$u1_root/etc/alternatives" \
  "$u1_root/opt/airlock/libexec" "$u1_root/var/lib/airlock/managed"
chmod 0755 "$u1_root" "$u1_root/etc" "$u1_root/etc/airlock" \
  "$u1_root/opt" "$u1_root/opt/airlock" "$u1_root/opt/airlock/libexec" \
  "$u1_root/var" "$u1_root/var/lib" "$u1_root/var/lib/airlock" \
  "$u1_root/var/lib/airlock/managed"
chmod 1777 "$u1_root/tmp"
ln -s usr/bin "$u1_root/bin"
ln -s usr/sbin "$u1_root/sbin"
ln -s usr/lib "$u1_root/lib"
ln -s usr/lib64 "$u1_root/lib64"
ln -s /usr/bin/gawk "$u1_root/etc/alternatives/awk"
git -C "$ROOT" archive HEAD | tar -x -C "$u1_public"
cat >"$u1_public/bin/airlock-status" <<'PY'
#!/usr/bin/env python3
import json
print(json.dumps({"checks": [], "exit_code": 0, "schema_version": 1, "verdict": "ok"}))
PY
chmod 0755 "$u1_public/bin/airlock-status"
cat >"$u1_public/install/airlock-install.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if env | grep -Eq '^(AIRLOCK_MANAGED_|AIRLOCK_UPDATE_CHANNEL_)'; then
  echo "managed authority leaked through ambient environment" >&2
  exit 71
fi
exec 9>>/var/lib/airlock/managed/0/managed-state.json.lock
flock -n 9 || { echo "producer state lease is still held" >&2; exit 72; }
python3 - "$@" <<'PY'
import hashlib
import json
import os
import pathlib
import stat
import sys

arguments = sys.argv[1:]
if len(arguments) < 3:
    raise SystemExit("missing paired handoff/select argv")
if not arguments[0].startswith("--update-channel-handoff="):
    raise SystemExit("handoff path is not first")
if not arguments[1].startswith("--update-channel-handoff-sha256="):
    raise SystemExit("handoff digest is not second")
path = pathlib.Path(arguments[0].split("=", 1)[1])
expected_hash = arguments[1].split("=", 1)[1]
if not path.is_absolute():
    raise SystemExit("handoff path is not absolute")
selected = [item.split("=", 1)[1] for item in arguments[2:]
            if item.startswith("--select-app=")]
if len(selected) != len(arguments) - 2 or selected != sorted(set(selected)):
    raise SystemExit("selected app argv is not exact sorted unique")
raw = path.read_bytes()
value = json.loads(raw)
canonical = (json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n").encode()
if raw != canonical or hashlib.sha256(raw).hexdigest() != expected_hash:
    raise SystemExit("handoff bytes/hash are not canonical")
expected_keys = {
    "actor", "anchor_path", "anchor_sha256", "config_path", "config_sha256",
    "core_measurement_path", "core_measurement_sha256", "current_release_path",
    "current_release_sha256", "fetched_public_revision", "installed_measurer_sha256",
    "next_measurer_path", "next_measurer_sha256", "receipt_path", "receipt_sha256",
    "schema", "selected_apps",
}
if set(value) != expected_keys or value["schema"] != "airlock.update-channel.install-handoff/v1":
    raise SystemExit("handoff shape is not closed")
if value["actor"] != "update-channel" or value["anchor_path"] != "/etc/airlock/managed-channel.json":
    raise SystemExit("handoff actor/anchor is not fixed")
if value["selected_apps"] != selected:
    raise SystemExit("handoff and argv selected ids differ")
for path_key, hash_key in (
    ("config_path", "config_sha256"),
    ("core_measurement_path", "core_measurement_sha256"),
    ("current_release_path", "current_release_sha256"),
    ("next_measurer_path", "next_measurer_sha256"),
    ("receipt_path", "receipt_sha256"),
):
    payload = pathlib.Path(value[path_key])
    if not payload.is_absolute():
        raise SystemExit(f"handoff payload is not absolute: {path_key}")
    info = payload.lstat()
    if (not stat.S_ISREG(info.st_mode) or payload.is_symlink()
            or stat.S_IMODE(info.st_mode) != 0o600
            or hashlib.sha256(payload.read_bytes()).hexdigest() != value[hash_key]):
        raise SystemExit(f"handoff payload mismatch: {path_key}")
PY
printf '%s\n' "$@" > /fixture/installer-argv.log
printf 'installer-after-producer\n' > /fixture/install.log
SH
chmod 0755 "$u1_public/install/airlock-install.sh"
git -C "$u1_public" init -q -b main
git -C "$u1_public" add -A
u1_source_label="airlock""-work"
git -C "$u1_public" commit -q -m "release from $u1_source_label @ eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
u1_old="$(git -C "$u1_public" rev-parse HEAD)"
printf 'managed candidate\n' >>"$u1_public/README.md"
git -C "$u1_public" add README.md
git -C "$u1_public" commit -q -m "release from $u1_source_label @ eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
u1_new="$(git -C "$u1_public" rev-parse HEAD)"
git -C "$u1_public" archive "$u1_old" | tar -x -C "$u1_box"
git -C "$u1_public" archive "$u1_old" | tar -x -C "$u1_box_relative"
for u1_initial_box in "$u1_box" "$u1_box_relative"; do
  git -C "$u1_initial_box" init -q -b main
  git -C "$u1_initial_box" add -A
  git -C "$u1_initial_box" commit -q -m "airlock-update: 배포본 ${u1_old:0:12} 으로 갱신"
done

cat >"$u1_root/fixture/run-u1.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
new=$1
source_revision=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
git config --global user.name airlock-u1-test
git config --global user.email airlock-u1-test@example.invalid
measurement="$(python3 /work/bin/airlock-managed-release measure-public-core \
  --repository /fixture/public --revision "$new")"
core_digest="$(printf '%s\n' "$measurement" | python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])')"
python3 /work/install/test-managed-config-consumer.py --prepare-u1-fixture \
  /fixture/material /fixture/box "$source_revision" "$core_digest" \
  > /fixture/u1-fixture.json
cp /fixture/box/airlock.toml /fixture/box-relative/airlock.toml
chmod 0600 /fixture/box-relative/airlock.toml

before="$(git -C /fixture/box rev-parse HEAD)"
chmod 0600 /etc/airlock/managed-channel.json
if AIRLOCK_DIR=/fixture/box AIRLOCK_RELEASE_URL=/fixture/public \
     AIRLOCK_RELEASE_REF="$new" bash /work/bin/airlock-update >/fixture/mode.err 2>&1; then
  echo "invalid anchor mode passed" >&2; exit 81
fi
test "$(git -C /fixture/box rev-parse HEAD)" = "$before"
test ! -e /fixture/install.log
chmod 0644 /etc/airlock/managed-channel.json

mv /etc/airlock/managed-channel.json /etc/airlock/managed-channel.real
ln -s managed-channel.real /etc/airlock/managed-channel.json
if AIRLOCK_DIR=/fixture/box AIRLOCK_RELEASE_URL=/fixture/public \
     AIRLOCK_RELEASE_REF="$new" bash /work/bin/airlock-update >/fixture/symlink.err 2>&1; then
  echo "symlink anchor passed" >&2; exit 82
fi
test "$(git -C /fixture/box rev-parse HEAD)" = "$before"
rm /etc/airlock/managed-channel.json
mv /etc/airlock/managed-channel.real /etc/airlock/managed-channel.json

chmod 0755 /opt/airlock/libexec/airlock-managed-release
if AIRLOCK_DIR=/fixture/box AIRLOCK_RELEASE_URL=/fixture/public \
     AIRLOCK_RELEASE_REF="$new" bash /work/bin/airlock-update >/fixture/measurer-mode.err 2>&1; then
  echo "invalid installed measurer mode passed" >&2; exit 83
fi
test "$(git -C /fixture/box rev-parse HEAD)" = "$before"
chmod 0555 /opt/airlock/libexec/airlock-managed-release

AIRLOCK_DIR=/fixture/box AIRLOCK_RELEASE_URL=/fixture/public AIRLOCK_RELEASE_REF="$new" \
AIRLOCK_CONFIG=/fixture/box/airlock.toml AIRLOCK_MANAGED_STATE=/fixture/attacker-state \
AIRLOCK_MANAGED_RELEASE=/fixture/attacker-release \
AIRLOCK_MANAGED_AUTHORITY=/fixture/attacker-authority \
AIRLOCK_MANAGED_PROJECTOR_RELEASE_MODE=promoted-current \
AIRLOCK_MANAGED_RELEASE_VERIFY_MODE=promoted-current \
AIRLOCK_MANAGED_RELEASE_VERIFY_STORE=/fixture/copied-store \
AIRLOCK_MANAGED_RELEASE_VERIFY_CHANNEL=evil \
AIRLOCK_UPDATE_CHANNEL_HANDOFF=/fixture/attacker-handoff \
bash /work/bin/airlock-update > /fixture/positive.log 2>&1
test -f /fixture/install.log
test "$(git -C /fixture/box rev-parse HEAD)" != "$before"
grep -qx -- '--select-app=available-app' /fixture/installer-argv.log
grep -qx -- '--select-app=required-app' /fixture/installer-argv.log

relative_before="$(git -C /fixture/box-relative rev-parse HEAD)"
mkdir -m 0700 /fixture/box-relative/reltmp
rm -f /fixture/install.log /fixture/installer-argv.log
TMPDIR=reltmp AIRLOCK_DIR=/fixture/box-relative AIRLOCK_RELEASE_URL=/fixture/public \
AIRLOCK_RELEASE_REF="$new" AIRLOCK_CONFIG=/fixture/box-relative/airlock.toml \
bash /work/bin/airlock-update > /fixture/relative.log 2>&1
test -f /fixture/install.log
test "$(git -C /fixture/box-relative rev-parse HEAD)" != "$relative_before"
python3 - /fixture/installer-argv.log <<'PY'
import pathlib
import sys

rows = pathlib.Path(sys.argv[1]).read_text().splitlines()
handoff = pathlib.Path(rows[0].split("=", 1)[1])
if not handoff.is_absolute():
    raise SystemExit("relative TMPDIR produced a relative handoff")
PY
grep -qx -- '--select-app=available-app' /fixture/installer-argv.log
grep -qx -- '--select-app=required-app' /fixture/installer-argv.log
printf 'root_userns=1\nanchor_rejects=2\nmeasurer_rejects=1\nambient_scrub=1\nrelative_tmpdir=1\n'
SH
chmod 0755 "$u1_root/fixture/run-u1.sh"

u1_result="$(unshare -Ur -m bash -s -- "$u1_root" "$ROOT" "$u1_new" <<'SH'
set -euo pipefail
root=$1; source=$2; revision=$3
mount --make-rprivate /
mount --rbind /usr "$root/usr"
mount --rbind /dev "$root/dev"
mount --rbind /proc "$root/proc"
mount --bind "$source" "$root/work"
mount -o remount,bind,ro "$root/work"
/usr/sbin/chroot "$root" /usr/bin/env -i HOME=/root PATH=/usr/bin:/bin \
  GIT_CONFIG_GLOBAL=/fixture/gitconfig GIT_CONFIG_NOSYSTEM=1 \
  bash /fixture/run-u1.sh "$revision"
SH
)"; u1_rc=$?
if [ "$u1_rc" = 0 ] \
   && grep -qx 'root_userns=1' <<<"$u1_result" \
   && grep -qx 'anchor_rejects=2' <<<"$u1_result" \
   && grep -qx 'measurer_rejects=1' <<<"$u1_result" \
   && grep -qx 'ambient_scrub=1' <<<"$u1_result" \
   && grep -qx 'relative_tmpdir=1' <<<"$u1_result"; then
  ok "Linux managed U1 uses a real root user namespace and fixed anchor/measurer"
  u1_root_userns=1; u1_anchor_rejects=2; u1_measurer_rejects=1
  u1_ambient_scrub=1; u1_relative_tmpdir=1
else
  for u1_log in mode.err symlink.err measurer-mode.err positive.log relative.log; do
    if [ -f "$u1_root/fixture/$u1_log" ]; then
      printf '%s\n' "--- U1 $u1_log ---" >&2
      tail -40 "$u1_root/fixture/$u1_log" >&2
    fi
  done
  bad "Linux managed U1 root namespace fixture failed (rc=$u1_rc): $u1_result"
  u1_root_userns=0; u1_anchor_rejects=0; u1_measurer_rejects=0
  u1_ambient_scrub=0; u1_relative_tmpdir=0
fi
if [ -f "$u1_root/fixture/installer-argv.log" ] \
   && [ "$(sed -n '1p' "$u1_root/fixture/installer-argv.log")" = \
        "--update-channel-handoff=$(dirname "$(sed -n '1s/^--update-channel-handoff=//p' "$u1_root/fixture/installer-argv.log")")/update-channel-handoff.json" ] \
   && sed -n '2p' "$u1_root/fixture/installer-argv.log" | grep -Eq '^--update-channel-handoff-sha256=[0-9a-f]{64}$' \
   && [ "$(tail -n +3 "$u1_root/fixture/installer-argv.log" | sort)" = \
        $'--select-app=available-app\n--select-app=required-app' ]; then
  ok "managed producer exits and releases its lease before exact paired installer argv"
  u1_paired_argv=1
else
  bad "managed installer argv/order was not the closed paired handoff"
  u1_paired_argv=0
fi
printf 'AC-MAU-U1 | expected: root_userns==1 && anchor_rejects==2 && measurer_rejects==1 && ambient_scrub==1 && relative_tmpdir==1 && paired_argv==1 | observed: root_userns=%s,anchor_rejects=%s,measurer_rejects=%s,ambient_scrub=%s,relative_tmpdir=%s,paired_argv=%s | verdict: %s | signal: fixture | evidence: install/test-update.sh@%s\n' \
  "$u1_root_userns" "$u1_anchor_rejects" "$u1_measurer_rejects" \
  "$u1_ambient_scrub" "$u1_relative_tmpdir" "$u1_paired_argv" \
  "$([ "$u1_root_userns$u1_anchor_rejects$u1_measurer_rejects$u1_ambient_scrub$u1_relative_tmpdir$u1_paired_argv" = 121111 ] && printf PASS || printf FAIL)" \
  "$(git -C "$ROOT" rev-parse HEAD)"

timer_out="$(bash "$ROOT/install/test-update-timer.sh" 2>&1)"; timer_rc=$?
[ "$timer_rc" = 0 ] \
  && ok "daily update detector timer is rendered, installed and systemd-verified hermetically" \
  || bad "daily update detector timer contract failed: $timer_out"

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
