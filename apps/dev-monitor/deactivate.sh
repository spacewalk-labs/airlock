#!/usr/bin/env bash
# dev-monitor deactivate — no app-specific stop step. The ledger's generic
# "units" class already stops/disables/deletes airlock-dev-monitor.service
# (D5 amendment), and the generic "files" class removes
# ~/.config/airlock/dev-monitor.env. The message/action console's tmux exec
# session is deliberately left running here for the same reason
# install.sh's own messages=true->false transition leaves it running
# (apps/dev-monitor/install.sh: "does not reach into a run that is already
# going") — and unlike that live-reconcile path, deactivate.sh runs with
# [apps.dev-monitor] already gone from config, so there is no configured
# exec_session name left to look up even to warn about it. Idempotent by
# construction (does nothing).
set -euo pipefail
exit 0
