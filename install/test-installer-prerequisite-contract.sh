#!/usr/bin/env bash
# Regression and contract tests for installer command discovery.
set -uo pipefail
. "$(dirname "$0")/test-lib.sh"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

airlock_test_counters_init

case_name="${2:-${1:-all}}"
if [ "${1:-}" = --case ]; then
  case_name="${2:-}"
fi

mkdir -p "$TMP/empty" "$TMP/sbin"

# Source production code first. Tests may replace the fixed fallback only after
# sourcing, matching install/test-preflight.sh's existing test seam.
AIRLOCK_ROOT="$ROOT"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
make_exec() {
  printf '#!/bin/sh\nexit 0\n' > "$1"
  chmod +x "$1"
}

sbin_present() {
  make_exec "$TMP/sbin/nft"
  AIRLOCK_PREFLIGHT_SBIN_DIRS="$TMP/sbin"
  local central="" local_rc=0
  central="$(PATH="$TMP/empty" airlock_preflight_find nft 2>/dev/null)" || central=""
  (PATH="$TMP/empty"; require_cmd nft) >/dev/null 2>&1 || local_rc=$?
  if [ "$central" = "$TMP/sbin/nft" ] && [ "$local_rc" = 0 ]; then
    ok "sbin-present: preflight and require_cmd accept the same fallback executable"
  else
    bad "sbin-present mismatch (central=${central:-none} require_rc=$local_rc)"
  fi
}

sbin_absent() {
  rm -f "$TMP/sbin/nft"
  AIRLOCK_PREFLIGHT_SBIN_DIRS="$TMP/sbin"
  local central_rc=0 local_rc=0 marker="$TMP/mutated"
  PATH="$TMP/empty" airlock_preflight_find nft >/dev/null 2>&1 || central_rc=$?
  (PATH="$TMP/empty"; require_cmd nft; : > "$marker") >/dev/null 2>&1 || local_rc=$?
  if [ "$central_rc" != 0 ] && [ "$local_rc" != 0 ] && [ ! -e "$marker" ]; then
    ok "sbin-absent: both gates reject before the mutation marker"
  else
    bad "sbin-absent did not fail closed (central_rc=$central_rc require_rc=$local_rc marker=$([ -e "$marker" ] && echo yes || echo no))"
  fi
}

hidden_node() {
  AIRLOCK_PREFLIGHT_SBIN_DIRS="$TMP/empty"
  local found_rc=0
  PATH="$TMP/empty" airlock_find_cmd node >/dev/null 2>&1 || found_rc=$?
  if [ "$found_rc" != 0 ]; then
    ok "hidden-node: resolver does not append general system PATH directories"
  else
    bad "hidden-node: host node escaped the fixture PATH"
  fi
}

case "$case_name" in
  sbin-present) sbin_present ;;
  sbin-absent) sbin_absent ;;
  hidden-node) hidden_node ;;
  all)
    sbin_present
    sbin_absent
    hidden_node
    ;;
  *) bad "unknown case: $case_name" ;;
esac

printf '%s\n' "---" "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
