#!/usr/bin/env bash
# devterm deactivate — no app-specific stop step. The ledger's generic
# classes cover everything declared: "units" stops/disables/deletes both
# airlock-devterm.service (ttyd) and airlock-devterm-gate.service;
# "fragments" removes the servers.d nginx fragment; "files" removes ttyd,
# devterm-shell, the optional claude-switch/claude-status tools, and the
# web client's staged share dir; the ledger also retires the serve.https
# tailscale mapping and the plaintext_redirect row (orchestrator-owned,
# config-driven — nothing here to do for it either).
#
# Live tmux sessions ttyd/devterm-shell have spawned are deliberately left
# running, same call as dev-monitor's exec_session and for the same two
# reasons: the ttyd unit's own KillMode=process already established "do not
# kill live tmux sessions on a unit stop/restart" as this app's policy (see
# apps/devterm/install.sh's unit comment), and by the time this script runs
# [apps.devterm] is already gone from config, so there is no configured
# session to even look up. ~/.config/airlock-devterm/tabs.json (user tabs)
# is retained data — never declared, so never touched. Idempotent by
# construction (does nothing).
set -euo pipefail
exit 0
