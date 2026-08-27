#!/usr/bin/env python3
"""Cron/timer integration for dev-monitor.

The scanner is the ported cron-console collector.  This module is the read-only HTTP
face of it: it narrows the measured snapshot to the fields the dashboard may see, and
it exposes no way to start, stop or otherwise change a job.  Scheduled jobs are observed
here and changed only on the box itself.
"""

from __future__ import annotations

import devmon_cron_scan as scan


_PUBLIC_JOB_FIELDS = frozenset({
    "id", "scope", "kind", "name", "unit", "description", "schedule",
    "enabled", "unitFileState", "activeState", "lastRun", "nextRun",
    "lastResult", "exitStatus", "conditionMet", "durationSec", "execution",
    "timeliness", "lastDue", "lastSignal", "lastSignalKind", "matchQuality",
    "reboot", "logs",
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
