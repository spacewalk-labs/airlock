#!/usr/bin/env bash
# install/test-lib.sh — shared scaffolding for install/test-*.sh.
#
# Every suite under install/ hand-rolled the same handful of setup lines: a
# pass/fail counter pair with ok()/bad(), the paseo RAM pin (with its own copy
# of the same explanatory comment), a neutral self-kill cgroup fixture, and the
# AIRLOCK_FIXTURE_ROOT export. None of that is suite-specific — the divergence
# lived only in incidental formatting, not behavior — so it is collected here
# once. A suite's actual fixtures, shims, and assertions stay in the suite.
#
# Source this file, don't execute it: `. "$(dirname "$0")/test-lib.sh"`. It
# defines functions and, via airlock_test_counters_init, the `pass`/`fail`
# globals a suite's own assertions increment through ok()/bad().
set -uo pipefail

# ---- counters -----------------------------------------------------------
# Sets the pass/fail globals every suite reports at the end, and defines
# ok()/bad() to increment them. Call once, near the top, after sourcing.
airlock_test_counters_init() {
  pass=0
  fail=0
}
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }
# For a bad() call that needs to show more than one line of context without
# cramming it onto the FAIL line itself.
failure_detail() { printf '     %s\n' "$1"; }

# ---- paseo RAM pin --------------------------------------------------------
# install/test-render-parity.sh gates that every suite whose text names a real
# app installer (apps/*/install.sh or airlock-install.sh) pins the RAM the
# paseo installer takes its memory share from (32GiB): that share is 15/16 of
# the box, so unpinned, every runner writes a different MemoryMax and the
# goldens bake in whichever RAM the runner happened to have. The gate is a
# text scan, not a call-graph — it does not reason about WHICH app a dynamic
# path resolves to — so suites that never install paseo carry the pin too and
# it sits inert. Cheaper than a gate that tries to be clever about which
# mention counts. (An intermediate design REFUSED below 8 GiB; that refusal is
# gone — owner, 2026-08-17 — the pin is still right.)
#
# A suite that sources this file and calls airlock_pin_paseo_mem satisfies the
# gate exactly as if it had the literal `export AIRLOCK_PASEO_MEM_CAP_BYTES=`
# in its own text — the gate's scan for test-lib.sh's own pin is what makes
# that true; see the "sourced pin" branch in test-render-parity.sh.
airlock_pin_paseo_mem() {
  export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368
}

# ---- neutral self-kill cgroup ---------------------------------------------
# install/lib.sh's airlock_escape_selfkill_cgroup only escapes a real
# airlock-*.service --user scope; any other content is neutral. Writes a
# fixture cgroup file under $1 (a scratch dir) and exports
# AIRLOCK_SELFKILL_CGROUP_FILE to point at it, so a suite invoking the real
# installer from inside this box's own airlock-paseo.service does not trip
# the escape it is not testing.
airlock_neutral_selfkill_cgroup() {
  local scratch="$1"
  printf '0::/fixture.scope\n' > "$scratch/cgroup"
  export AIRLOCK_SELFKILL_CGROUP_FILE="$scratch/cgroup"
}

# ---- fixture root -----------------------------------------------------
# Fixture mode (AGENTS.md refusal 5) requires every written path to live under
# AIRLOCK_FIXTURE_ROOT. Export it once a suite has its scratch dir.
airlock_set_fixture_root() {
  export AIRLOCK_FIXTURE_ROOT="$1"
}

# ---- checkout write guard ----------------------------------------------
# A5, for git rather than for paths: a test run must never write HISTORY into the
# checkout it is running from.
#
# Why this exists, measured rather than imagined: 41 of install/test-update.sh's
# 45 `bash "$UPDATE"` calls pass no AIRLOCK_DIR, because several of them exist
# precisely to exercise the no-AIRLOCK_DIR path. bin/airlock-update then falls
# back to "the directory the script lives in" as ROOT and its pre-update
# snapshot runs `git add -A; git commit` THERE. A suite that leaves a commit
# titled `airlock-update: 업데이트 전 상태` in a developer's worktree is not a
# slow test — it is the suite writing to the repo, silently, and the next
# `git status` is wrong because of it. Adding AIRLOCK_DIR to all 41 calls would
# buy a clean tree by deleting the coverage those calls exist for; this blocks
# the write instead and leaves every call alone.
#
# READ operations stay allowed: the suite legitimately asks the real checkout
# for its HEAD to stamp evidence lines.
airlock_guard_checkout_writes() {   # airlock_guard_checkout_writes <checkout-root> <shim-dir>
  local root="$1" shim="$2" real_git
  # Resolve the REAL git BEFORE the shim dir joins PATH, and pin its absolute
  # path. The shim must never look git up in $PATH at run time: a suite that
  # prepends its own git shim later (install/test-update.sh's fetch counter does
  # exactly that) would capture OUR shim as "real git", and our shim would then
  # capture theirs — two shims calling each other until the process is killed.
  # Measured, not theorised: that recursion is what stalled the first run.
  real_git="$(command -v git)" || return 0
  case "$real_git" in
    /*) ;;
    *) return 0 ;;
  esac
  mkdir -p "$shim"
  cat >"$shim/git" <<'SHIM'
#!/bin/sh
# AIRLOCK_TEST_GUARDED_CHECKOUT is the only thing this shim knows. It resolves
# The pinned real git, injected by the installer above. Never resolved here.
real="$AIRLOCK_TEST_GUARD_REAL_GIT"
[ -x "$real" ] || { echo "airlock-test-guard: pinned git $real is gone" >&2; exit 98; }

writes=no
dir=""
expect_dir=no
for arg in "$@"; do
  if [ "$expect_dir" = yes ]; then dir="$arg"; expect_dir=no; continue; fi
  case "$arg" in
    commit|merge|am) writes=yes ;;
    -C|--git-dir) expect_dir=yes ;;
  esac
done
[ "$writes" = yes ] || exec "$real" "$@"

toplevel="$("$real" ${dir:+-C "$dir"} rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$toplevel" ] || exit 0
# Compare resolved paths: a symlinked or relative spelling of the same
# directory must not slip past the guard.
target="$("$real" -C "$toplevel" rev-parse --show-toplevel 2>/dev/null)"
guarded="$("$real" -C "$AIRLOCK_TEST_GUARDED_CHECKOUT" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$guarded" ] || guarded="$AIRLOCK_TEST_GUARDED_CHECKOUT"
[ "$target" = "$guarded" ] || exec "$real" "$@"

echo "airlock-test-guard: refusing to $writes in the checkout under test ($target)." >&2
echo "  A test ran a git write against the real checkout. Pass AIRLOCK_DIR, or" >&2
echo "  point the command at a fixture tree under AIRLOCK_FIXTURE_ROOT." >&2
exit 97
SHIM
  chmod 755 "$shim/git"
  export AIRLOCK_TEST_GUARDED_CHECKOUT="$root" AIRLOCK_TEST_GUARD_DIR="$shim" \
         AIRLOCK_TEST_GUARD_REAL_GIT="$real_git"
  PATH="$shim:$PATH"
  export PATH
}

# The guard is a gate, so it is tested like one (L10): a suite that installs it
# proves it refuses the write it exists to refuse, in the checkout itself.
airlock_check_guard_fires() {   # airlock_check_guard_fires <checkout-root> <label>
  local root="$1" label="$2" out=""
  if out="$(cd "$root" && git commit --allow-empty -m guard-selftest 2>&1)"; then
    return 1   # the write went through: the guard is not installed
  fi
  case "$out" in
    *"airlock-test-guard: refusing"*) return 0 ;;
    *) return 1 ;;
  esac
}
