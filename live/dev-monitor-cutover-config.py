#!/usr/bin/env python3
"""Render the secret-free Airlock config used for a dev-monitor cutover.

Site-specific values come from environment variables. Slack values do not: this config
names the two environment variables the installer may resolve at cutover time, keeping
bearer credentials out of the generated TOML and process output.
"""
from __future__ import annotations

import json
import os
import sys


def required(name: str) -> str:
    value = os.environ.get(name, '').strip()
    if not value:
        raise SystemExit(f'{name} is required')
    if '\n' in value or '\r' in value:
        raise SystemExit(f'{name} must be one line')
    return value


def value(name: str, default: str) -> str:
    result = os.environ.get(name, default).strip()
    if '\n' in result or '\r' in result:
        raise SystemExit(f'{name} must be one line')
    return result


def q(raw: str) -> str:
    return json.dumps(raw, ensure_ascii=False)


def main() -> None:
    owner = required('AIRLOCK_CUTOVER_OWNER')
    site_name = value('AIRLOCK_CUTOVER_SITE_NAME', 'Airlock')
    code_root = value('AIRLOCK_CUTOVER_CODE_ROOT', os.path.expanduser('~'))
    roster = value('AIRLOCK_CUTOVER_ROSTER_PATH', '')
    compat_env_path = value('AIRLOCK_CUTOVER_COMPAT_ENV_PATH', '')
    urgent_env = value(
        'AIRLOCK_CUTOVER_SLACK_URGENT_ENV',
        'DEV_MONITOR_SLACK_WEBHOOK',
    )
    routine_env = value(
        'AIRLOCK_CUTOVER_SLACK_ROUTINE_ENV',
        'DEV_MONITOR_SLACK_WEBHOOK',
    )
    backend_port = value('AIRLOCK_CUTOVER_BACKEND_PORT', '19923')
    spool_writer_user = value(
        'AIRLOCK_CUTOVER_SPOOL_WRITER_USER', 'airlock-dev-monitor-writer')
    spool_writer_group = value(
        'AIRLOCK_CUTOVER_SPOOL_WRITER_GROUP', 'airlock-dev-monitor-writers')
    if not backend_port.isascii() or not backend_port.isdigit():
        raise SystemExit('AIRLOCK_CUTOVER_BACKEND_PORT must be decimal digits')

    sys.stdout.write(f'''[airlock]
config_version = 2

[site]
name = {q(site_name)}

[auth]
provider = "tailscale"
owner = {q(owner)}
collaborators = []

[paths]
code_root = {q(code_root)}
wiki = ""

[branding]
product = "Airlock"

[apps.hub]
https_port = 443
http_port = 19901
nginx_port = 19902
redirect_port = 19903

[apps.dev-monitor]
backend_port = {backend_port}
messages = true
token_freshness = true
slack_webhook_urgent_env = {q(urgent_env)}
slack_webhook_routine_env = {q(routine_env)}
roster_path = {q(roster)}
compat_env_path = {q(compat_env_path)}
spool_writer_user = {q(spool_writer_user)}
spool_writer_group = {q(spool_writer_group)}
''')


if __name__ == '__main__':
    main()
