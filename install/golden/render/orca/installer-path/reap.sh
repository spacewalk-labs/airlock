#!/usr/bin/env bash
# airlock-orca daemon reap — ExecStopPost for airlock-orca.service.
#
# Orca's daemon directory and app-orca scopes are also used by legacy stacks.
# INVOCATION_ID is injected by systemd and inherited by the detached daemon, so
# it is the ownership proof: never delete a pidfile or stop a scope merely
# because its name looks like Orca's.
invocation="${INVOCATION_ID:-}"
[ -n "$invocation" ] || exit 0
declare -a scopes=()
for f in "$HOME"/.config/orca/daemon/daemon-v*.pid; do
    [ -f "$f" ] || continue
    p=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' "$f" 2>/dev/null)
    [ -n "$p" ] || continue
    [ -r "/proc/$p/environ" ] || continue
    tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null \
        | grep -Fqx "INVOCATION_ID=$invocation" || continue
    exe=$(readlink -f "/proc/$p/exe" 2>/dev/null)
    case "$exe" in
        *orca*) ;;  # exact invocation + executable family: PID-reuse safe
        *) continue ;;
    esac
    unit=$(systemctl --user whoami "$p" 2>/dev/null || true)
    case "$unit" in
        app-orca-*.scope) scopes+=("$unit") ;;
    esac
    kill "$p" 2>/dev/null || true
    rm -f "$f"
done
# Reclaim only scopes measured from this invocation's daemon PID. A glob would
# also match a concurrently running legacy instance.
if [ "${#scopes[@]}" -gt 0 ]; then
    mapfile -t scopes < <(printf '%s\n' "${scopes[@]}" | sort -u)
    systemctl --user stop "${scopes[@]}" 2>/dev/null || true
fi
exit 0
