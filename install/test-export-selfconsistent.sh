#!/usr/bin/env bash
# install/test-export-selfconsistent.sh — the tree we PUBLISH has to be able to run
# itself.
#
# The boundary in install/public-manifest.sh is per-file, and that is right for deciding
# audience. But some invariants live ACROSS files, and a per-file decision cannot see
# them. One of them is fatal:
#
#   bin/airlock-config carried BUNDLE_ENTITLEMENTS, a table that a parity check
#   required to match apps/ EXACTLY, fail-closed (parity check removed 2026-09-28).
#
# So holding one app directory back while shipping bin/ — two individually reasonable
# calls — produced a public tree whose own validator refuses to start:
#
#   airlock-config: bundled entitlement table does not exactly match apps/:
#   policy entries without bundled apps: ['learning']
#
# 🔴 That shipped. Measured 2026-08-22 on a real operator's box: the update replaced the
# files, the installer died at the first validate, and the box was left with the new tree
# and the old services. Every box that took that release stopped at the same line — and
# the private CI was green throughout, because the private tree HAS apps/learning.
#
# What this gate adds is the one question no per-file check can ask: after pruning, does
# the artefact still work? It builds the export the release actually builds and runs the
# real validator on it.
#
# Offline: git archive + the repo's own scripts. No network, nothing installed.
set -uo pipefail
. "$(dirname "$0")/test-lib.sh"
airlock_pin_paseo_mem

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

airlock_test_counters_init "export: "

scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT
EXPORT="$scratch/export"; mkdir -p "$EXPORT"

# The same two steps the release performs, in the same order.
git -C "$ROOT" archive HEAD | tar -x -C "$EXPORT" 2>/dev/null \
  || { echo "FAIL export: could not build the export tree" >&2; exit 2; }
while IFS= read -r p; do rm -f "${EXPORT:?}/$p"; done \
  < <(bash "$EXPORT/install/public-manifest.sh" --prune-list --dir "$EXPORT")
find "$EXPORT" -type d -empty -delete

[ -x "$EXPORT/bin/airlock-config" ] || [ -f "$EXPORT/bin/airlock-config" ] \
  || { echo "FAIL export: the export has no bin/airlock-config to run" >&2; exit 2; }

# `catalog` is the right probe: it is the one subcommand that answers with no
# airlock.toml. A command that
# needed a config would fail for a reason that has nothing to do with the export.
out="$(cd "$EXPORT" && AIRLOCK_CONFIG=/dev/null timeout 60 python3 bin/airlock-config catalog 2>&1)"
rc=$?
if [ "$rc" = 0 ]; then
  ok "the pruned tree can run its own airlock-config"
else
  bad "the pruned tree cannot run its own airlock-config (rc=$rc): $(printf '%s' "$out" | head -2)"
fi

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
