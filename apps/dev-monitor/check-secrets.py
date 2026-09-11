#!/usr/bin/env python3
"""Check app credentials with systemd's own EnvironmentFile loader; emit no values."""
import argparse
import os
from pathlib import Path
import secrets
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent / 'backend'))
from devmon_secret_names import validate_names
from devmon_secrets import resolve, SLACK_CONFIG
from devmon_secret_file import inspect_file


def check_loaded(names, marker, lane=None, selector=''):
    if lane:
        return bool(resolve(os.environ, selector, SLACK_CONFIG[lane][1], marker=marker))
    return all(resolve(os.environ, name, marker=marker) for name in names)


def check_file(path, names, lane=None, selector='', allowed=(), static=False):
    selected = tuple(allowed) + tuple(names) + ((selector.strip(),) if lane else ())
    validate_names(*selected)
    try:
        declared = inspect_file(path, selected)
    except (OSError, ValueError):
        return False
    if not set(names) <= set(declared):
        return False
    if static:
        return True
    if lane:
        selector = selector.strip()
        names = [selector] if selector else list(SLACK_CONFIG[lane][1])
    unit = 'airlock-devmon-secret-check-' + secrets.token_hex(12) + '.service'
    marker = 'devmon-unset-' + secrets.token_hex(24)
    # EnvironmentFile overrides these markers. Without them an absent assignment
    # could be supplied by the user manager's inherited environment and pass.
    command = ['systemd-run', '--user', '--wait', '--collect', '--quiet', '--unit=' + unit,
               '-p', 'RuntimeMaxSec=10', '-p', 'StandardOutput=null', '-p', 'StandardError=null',
               '-p', 'EnvironmentFile=' + str(Path(path).absolute()).replace('%', '%%')]
    for name in dict.fromkeys(names):
        command += ['-p', 'Environment=' + name + '=' + marker]
    command += [sys.executable, str(Path(__file__).resolve()), '--loaded', '--marker', marker]
    if lane:
        command += ['--lane', lane, '--selector', selector]
    command += names
    try:
        return subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              timeout=15).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False
    finally:
        # Cleanup only the random unit this invocation owns, including timeout or
        # failed submission. Never touch an app service or the manager environment.
        for action in ('stop', 'reset-failed'):
            try:
                subprocess.run(['systemctl', '--user', action, unit], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--file')
    parser.add_argument('--loaded', action='store_true')
    parser.add_argument('--static', action='store_true')
    parser.add_argument('--allow', action='append', default=[])
    parser.add_argument('--marker')
    parser.add_argument('--lane', choices=tuple(SLACK_CONFIG))
    parser.add_argument('--selector', default='')
    parser.add_argument('names', nargs='*')
    args = parser.parse_args()
    try:
        validate_names(*args.names)
        if args.loaded:
            return 0 if args.marker and check_loaded(args.names, args.marker, args.lane, args.selector) else 1
        return 0 if args.file and check_file(args.file, args.names, args.lane, args.selector, args.allow, args.static) else 1
    except ValueError:
        return 2
    except Exception:
        # Even an unexpected decoder/configuration failure must not echo values.
        return 1


if __name__ == '__main__':
    sys.exit(main())
