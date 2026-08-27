#!/usr/bin/env python3
"""D5 transport for platform account metadata; returns JSON or a fixed error code.

The subprocess boundary is intentionally outside devmon_tokens: expiry verdicts remain
a pure function of (raw JSON, clock). stdout and stderr are never logged or reflected;
the platform output is parsed only after a bounded-size check.
"""
import json
import os
import subprocess

MAX_PLATFORM_JSON_BYTES = 64 * 1024


def raw_deadlines(env=None, timeout=10):
    env = os.environ if env is None else env
    binary = (env.get('AIRLOCK_DEV_MONITOR_ACCOUNTS_STATUS_BIN') or '').strip()
    if not binary:
        return None, 'not-wired'
    try:
        proc = subprocess.run(
            [binary, 'raw-deadlines', '--json'],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=timeout, check=False, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return None, 'invoke-failed'
    if proc.returncode != 0:
        return None, 'command-failed'
    if len(proc.stdout) > MAX_PLATFORM_JSON_BYTES:
        return None, 'oversize-output'
    try:
        payload = json.loads(proc.stdout.decode('utf-8'))
    except (UnicodeDecodeError, ValueError):
        return None, 'invalid-json'
    providers = payload.get('providers') if isinstance(payload, dict) else None
    if (not isinstance(payload, dict)
            or type(payload.get('schema_version')) is not int
            or payload.get('schema_version') != 1
            or not isinstance(providers, dict)
            or not isinstance(providers.get('claude'), dict)
            or not isinstance(providers.get('codex'), dict)):
        return None, 'invalid-shape'
    return payload, None
