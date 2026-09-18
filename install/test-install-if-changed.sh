#!/usr/bin/env bash
# install_if_changed must not touch an identical destination (mtime included), and must
# still replace changed bytes or a changed mode. The ledger's rollback compares
# checkpoint archives with metadata, so an mtime-only rewrite degrades a transaction.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/install/lib.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }

printf 'unit\n' > "$TMP/src"; install -m 644 "$TMP/src" "$TMP/dest"
touch -d '2026-01-01 00:00:00' "$TMP/dest"; before="$(stat -c %Y "$TMP/dest")"
install_if_changed 644 "$TMP/src" "$TMP/dest"
[ "$(stat -c %Y "$TMP/dest")" = "$before" ] && ok "identical bytes and mode leave mtime untouched" \
  || bad "identical re-install rewrote the file"

printf 'unit v2\n' > "$TMP/src"
install_if_changed 644 "$TMP/src" "$TMP/dest"
cmp -s "$TMP/src" "$TMP/dest" && ok "changed bytes are installed" || bad "changed bytes were not installed"

chmod 600 "$TMP/dest"
install_if_changed 644 "$TMP/src" "$TMP/dest"
[ "$(stat -c %a "$TMP/dest")" = 644 ] && ok "a changed mode is corrected" || bad "mode stayed $(stat -c %a "$TMP/dest")"

rm -f "$TMP/dest"
install_if_changed 644 "$TMP/src" "$TMP/dest"
[ -f "$TMP/dest" ] && ok "a missing destination is created" || bad "missing destination not created"

if grep -nE '^\s*install -m 644 "\$run_final/(airlock-notes-editor\.service|notes\.conf)"' "$ROOT/apps/notes/install.sh"; then
  bad "notes install.sh still rewrites its committed unit/fragment unconditionally"
else
  ok "notes install.sh publishes its committed unit/fragment only when changed"
fi
printf -- '---\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
