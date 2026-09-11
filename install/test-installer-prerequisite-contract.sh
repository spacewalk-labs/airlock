#!/usr/bin/env bash
# Regression and contract tests for installer command discovery.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0
ok() { printf 'ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }

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

receipt_drift() {
  make_exec "$TMP/sbin/nft"
  AIRLOCK_PREFLIGHT_SBIN_DIRS="$TMP/sbin"
  AIRLOCK_PREREQ_RECEIPT="$TMP/drift.receipt"
  AIRLOCK_INSTALL_PKG_INFO_SHA256="$(printf 'a%.0s' {1..64})"
  printf '# airlock-prerequisite-receipt-v1\nnft\t%s\tpresent\t-\tcore\n' \
    "$TMP/sbin/nft" > "$AIRLOCK_PREREQ_RECEIPT"
  rm -f "$TMP/sbin/nft"
  local rc=0 marker="$TMP/drift-mutated"
  (PATH="$TMP/empty"; require_cmd nft; : > "$marker") >/dev/null 2>&1 || rc=$?
  unset AIRLOCK_PREREQ_RECEIPT AIRLOCK_INSTALL_PKG_INFO_SHA256
  if [ "$rc" != 0 ] && [ ! -e "$marker" ]; then
    ok "receipt-drift: vanished approved executable is rejected before mutation"
  else
    bad "receipt-drift did not fail closed (rc=$rc marker=$([ -e "$marker" ] && echo yes || echo no))"
  fi
}

receipt_roundtrip() {
  local b="$TMP/receipt-bin" receipt="$TMP/roundtrip.receipt" inv="$TMP/prerequisites.tsv"
  mkdir -p "$b"
  for cmd in nginx sudo systemctl tailscale curl flock; do make_exec "$b/$cmd"; done
  cat > "$b/python3" <<'SH'
#!/bin/sh
case "$*" in *sys.version_info*) printf '3.11\n' ;; *) exit 0 ;; esac
SH
  chmod +x "$b/python3"
  for cmd in python3 nginx sudo systemctl tailscale curl flock; do
    predicate=present expected=-
    [ "$cmd" = python3 ] && { predicate=major-gte; expected=3.11; }
    printf 'core\t%s\t%s\t%s\tinstall fixture\tfixture requirement\n' \
      "$cmd" "$predicate" "$expected" >> "$inv"
  done
  AIRLOCK_PREFLIGHT_SBIN_DIRS="$TMP/empty"
  AIRLOCK_PREREQUISITES="$inv"
  AIRLOCK_PREREQ_RECEIPT="$receipt"
  AIRLOCK_PREREQ_CONTEXT="fixture=roundtrip"
  AIRLOCK_PKG_INFO=""
  airlock_config() { [ "$1" = apps ] && printf 'hub\n'; }
  local preflight_rc=0 require_rc=0 mode=""
  (PATH="$b:/usr/bin:/bin"; airlock_preflight --quiet) >/dev/null 2>&1 || preflight_rc=$?
  mode="$(stat -c %a "$receipt" 2>/dev/null || true)"
  AIRLOCK_INSTALL_PKG_INFO_SHA256="$(printf 'b%.0s' {1..64})"
  (PATH="$b:/usr/bin:/bin"; require_cmd python3 nginx sudo systemctl tailscale curl flock) \
    >/dev/null 2>&1 || require_rc=$?
  unset AIRLOCK_PREREQ_RECEIPT AIRLOCK_PREREQ_CONTEXT AIRLOCK_INSTALL_PKG_INFO_SHA256 AIRLOCK_PKG_INFO
  if [ "$preflight_rc" = 0 ] && [ "$require_rc" = 0 ] && [ "$mode" = 600 ] \
      && grep -q '^# context=fixture=roundtrip$' "$receipt"; then
    ok "receipt-roundtrip: preflight receipt is private and lifecycle require_cmd consumes it"
  else
    bad "receipt-roundtrip failed (preflight_rc=$preflight_rc require_rc=$require_rc mode=${mode:-missing})"
  fi
}

case "$case_name" in
  sbin-present) sbin_present ;;
  sbin-absent) sbin_absent ;;
  hidden-node) hidden_node ;;
  receipt-drift) receipt_drift ;;
  receipt-roundtrip) receipt_roundtrip ;;
  all)
    sbin_present
    sbin_absent
    hidden_node
    receipt_drift
    receipt_roundtrip
    ;;
  *) bad "unknown case: $case_name" ;;
esac

printf '%s\n' "---" "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
