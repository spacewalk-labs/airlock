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
# installer pins the RAM the paseo installer picks its memory tier from. This suite
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
seed_tree "$REL" new
printf 'brand new file\n' > "$REL/NOTICE"
git -C "$REL" init -q -b main
git -C "$REL" add -A
git -C "$REL" commit -q -m "release"

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

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
