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

pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
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
  printf 'airlock.toml\n!examples/app-package/airlock.toml\n' > "$d/.gitignore"
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

PRIVATE_BOX="$scratch/private-deployment"
git clone -q "$PRIVATE_REL" "$PRIVATE_BOX"
canonical_private="https://github.com/spacewalk-labs/${PRIVATE_SOURCE_NAME}.git"
git -C "$PRIVATE_BOX" remote set-url origin "$canonical_private"
git -C "$PRIVATE_BOX" config "url.file://$PRIVATE_REL.insteadOf" "$canonical_private"
git -C "$PRIVATE_BOX" remote add airlock-release "$PRIVATE_PUBLIC"
git -C "$PRIVATE_BOX" fetch -q airlock-release main
git -C "$PRIVATE_BOX" merge -q --allow-unrelated-histories -s ours \
  -m "deploy current release" FETCH_HEAD
private_deploy_head="$(git -C "$PRIVATE_BOX" rev-parse HEAD)"

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
if [ "$diff_fail_json_rc" = 0 ] && printf '%s' "$diff_fail_json" | python3 -c '
import json, sys
value = json.load(sys.stdin)
assert value["available"] is False, value
assert value["changedCount"] == 0, value
'; then
  ok "a failed direction diff produces no update badge"
else
  bad "a failed direction diff became an available update: $diff_fail_json"
fi
diff_fail_out="$(PATH="$DIFF_FAIL_BIN:$PATH" AIRLOCK_DIR="$BOX" \
  AIRLOCK_RELEASE_URL="$REL" bash "$UPDATE" --no-install 2>&1)"
diff_fail_rc=$?
[ "$diff_fail_rc" -ne 0 ] \
  && [ "$(git -C "$BOX" rev-parse HEAD)" = "$diff_fail_head" ] \
  && grep -q 'version old' "$BOX/README.md" \
  && ok "a failed direction diff is refused before checkout mutation" \
  || bad "a failed direction diff was treated as a match (rc=$diff_fail_rc): $diff_fail_out"

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
  if [ "$version" = new ]; then
    cat >"$d/bin/airlock-config" <<'PY'
#!/usr/bin/env python3
import sys
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

timer_out="$(bash "$ROOT/install/test-update-timer.sh" 2>&1)"; timer_rc=$?
[ "$timer_rc" = 0 ] \
  && ok "daily update detector timer is rendered, installed and systemd-verified hermetically" \
  || bad "daily update detector timer contract failed: $timer_out"

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
