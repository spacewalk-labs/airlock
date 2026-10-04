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
