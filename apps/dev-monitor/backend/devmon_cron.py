#!/usr/bin/env python3
"""Cron/timer integration for dev-monitor.

The scanner is the ported cron-console collector.  This module owns only the HTTP-facing
mutation boundary: current user timers are re-measured for every action, commands are
argv-only, and system timers/cron files remain read-only.
"""

from __future__ import annotations

import devmon_cron_scan as scan


_ACTIONS = frozenset({"run", "pause", "resume"})
_PUBLIC_JOB_FIELDS = frozenset({
    "id", "scope", "kind", "name", "unit", "description", "schedule",
    "enabled", "unitFileState", "activeState", "lastRun", "nextRun",
    "lastResult", "exitStatus", "conditionMet", "durationSec", "execution",
    "timeliness", "lastDue", "lastSignal", "lastSignalKind", "matchQuality",
    "reboot", "controllable", "logs",
})
_PUBLIC_SOURCE_FIELDS = frozenset({"scope", "kind", "ok", "count", "error"})
_PUBLIC_SNAPSHOT_FIELDS = frozenset({
    "schemaVersion", "now", "bootTime", "coverageStart", "coverageEnd",
    "hostname", "counts", "notes", "cached", "cachedAgeSec",
})


def snapshot() -> dict:
    """Return only fields the dashboard needs; raw commands and paths stay private."""
    measured = scan.snapshot()
    public = {key: value for key, value in measured.items()
              if key in _PUBLIC_SNAPSHOT_FIELDS}
    public["jobs"] = [
        {key: value for key, value in job.items() if key in _PUBLIC_JOB_FIELDS}
        for job in measured.get("jobs", []) if isinstance(job, dict)
    ]
    public["sources"] = [
        {key: value for key, value in source.items() if key in _PUBLIC_SOURCE_FIELDS}
        for source in measured.get("sources", []) if isinstance(source, dict)
    ]
    return public


def known_user_timers() -> set[str]:
    """Return the live user-timer allowlist; an unreadable list fails closed."""
    rc, out, _ = scan.run_cmd(
        ["systemctl", "--user", "list-timers", "--all", "--no-pager"], timeout=15
    )
    return set(scan.TIMER_RE.findall(out)) if rc == 0 else set()


def timer_service(unit: str) -> str | None:
    """Resolve the service a timer activates; an unreadable mapping fails closed."""
    rc, out, _ = scan.run_cmd(
        ["systemctl", "--user", "show", unit, "-p", "Unit"], timeout=15
    )
    if rc == 0:
        for block in scan.parse_show_blocks(out):
            value = scan.first(block, "Unit")
            if value:
                return value
    return None


def run_action(action: str, unit: object) -> tuple[int, dict]:
    """Apply one reversible action to a currently observed user timer."""
    if action not in _ACTIONS:
        return 404, {"ok": False, "error": "unknown cron action"}
    if not isinstance(unit, str) or not scan.UNIT_SAFE_RE.fullmatch(unit) or not unit.endswith(".timer"):
        return 400, {"ok": False, "error": "unit must be a systemd timer name"}
    if unit not in known_user_timers():
        return 403, {
            "ok": False,
            "error": "only a currently observed user timer can be changed; system timers and cron files are read-only",
        }

    if action == "run":
        service = timer_service(unit)
        if service is None:
            return 503, {
                "ok": False,
                "error": "timer target could not be measured; nothing was started",
            }
        argv = ["systemctl", "--user", "start", "--no-block", service]
        message = f"started {service}"
    elif action == "pause":
        argv = ["systemctl", "--user", "stop", unit]
        message = f"paused {unit} until restart or resume"
    else:
        argv = ["systemctl", "--user", "start", unit]
        message = f"resumed {unit}"

    rc, out, err = scan.run_cmd(argv, timeout=30)
    if rc != 0:
        detail = (err or out).strip()[:400] or f"systemctl exited {rc}"
        return 500, {"ok": False, "error": detail}
    scan.invalidate_snapshot_cache()
    return 200, {"ok": True, "unit": unit, "action": action, "message": message}
