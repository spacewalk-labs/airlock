#!/usr/bin/env bash
# airlock-orca daemon reap — ExecStopPost for airlock-orca.service. PID-reuse safe.
for f in "$HOME"/.config/orca/daemon/daemon-v*.pid; do
    [ -f "$f" ] || continue
    p=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' "$f" 2>/dev/null)
    [ -n "$p" ] || { rm -f "$f"; continue; }
    exe=$(readlink -f "/proc/$p/exe" 2>/dev/null)
    case "$exe" in
        *orca*) kill "$p" 2>/dev/null || true ;;   # only orca-family pids (PID-reuse guard)
    esac
    rm -f "$f"
done
# Reclaim self-detached scopes: killing the daemon leaves its app-orca-*.scope and
# the agent-browser child inside it, which otherwise accumulate one per restart.
# orca is single-instance and this only runs while the service is down, so every
# app-orca-* here belongs to the dying (or already-dead) instance -> stop them all.
systemctl --user stop 'app-orca-*.scope' 2>/dev/null || true
exit 0
