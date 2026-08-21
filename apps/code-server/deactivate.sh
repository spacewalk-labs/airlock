#!/usr/bin/env bash
# code-server deactivate — the ledger's generic "units" class only knows the
# TEMPLATE unit name (airlock-code-server@.service — D2's literal-unit-name
# grammar covers the "@" template form as one literal) and removes that one
# unit file; it cannot enumerate the NUMBERED slot instances
# (airlock-code-server@1.service, @2.service, ...) the slot manager starts
# on demand as the owner opens tabs (apps/code-server/manager/manager.py).
# Stop + disable every live instance here, before the ledger deletes the
# template file out from under them — an orphaned running instance is a
# unit systemd still remembers with no file left to reload against.
#
# Everything else declared is still removed by the generic classes: both
# unit files (this template + the manager, a literal non-templated name),
# the servers.d fragment + the code-server/ shell dir, the versioned
# code-server tree + symlink + slot launcher + manager binary, and
# config.yaml. ~/.local/share/airlock-code-server/ (extensions/, slots/),
# ~/.config/airlock-code-server/tabs.json, and the rest of
# ~/.config/code-server/ are retained user state — not declared, so never
# touched.
#
# bin/airlock-ledger never runs a deactivator under a dry run (it only logs
# "[dry] would run ..." — see _run_deactivator) — this script only ever
# executes for a real removal, so no AIRLOCK_DRY_RUN branch is needed here.
# Idempotent: no live slot instance -> the loop below does nothing.
set -uo pipefail
for u in $(systemctl --user list-units --all --no-legend 'airlock-code-server@*.service' 2>/dev/null | awk '{print $1}'); do
  systemctl --user stop "$u" 2>/dev/null || true
  systemctl --user disable "$u" 2>/dev/null || true
done
exit 0
