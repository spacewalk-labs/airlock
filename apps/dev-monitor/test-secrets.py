#!/usr/bin/env python3
"""Dedicated secret contract through the installer and the real backend.

--systemd also starts an isolated, uniquely named user unit; it never restarts the
installed monitor. The unit's %h is mapped to the scratch HOME for this rehearsal.
Only synthetic credentials are used. No input credential contents are printed.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

APP = Path(__file__).resolve().parent
ROOT = APP.parents[1]


def run(argv, **kwargs):
    return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          timeout=60, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--systemd', action='store_true')
    parser.add_argument('--orchestrator', action='store_true')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='devmon-secret-test-') as tmp:
        scratch = Path(tmp)
        home = scratch / 'home'
        private = home / '.config/airlock'
        private.mkdir(parents=True)
        secret_file = private / 'dev-monitor-secrets.env'
        sentinel = secrets.token_hex(24)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        config = scratch / 'airlock.toml'
        config.write_text('[auth]\nprovider="tailscale"\nowner="owner@example.test"\n'
                          '[apps.hub]\n[apps.dev-monitor]\nmessages=true\n'
                          f'backend_port={port}\nslack_webhook_urgent_env="TEST_DEVMON_HOOK"\n')
        # Use a minimal environment so ambient operator config and credentials cannot
        # influence either the installer or the directly launched backend.
        env = {'HOME': str(home), 'PATH': '/usr/local/bin:/usr/bin:/bin',
               'AIRLOCK_ROOT': str(ROOT), 'AIRLOCK_APP_DIR': str(APP),
               'AIRLOCK_APP_ID': 'dev-monitor', 'AIRLOCK_CONFIG': str(config),
               'AIRLOCK_DRY_RUN': '1', 'AIRLOCK_RENDER_DIR': str(scratch / 'render'),
               'AIRLOCK_TS_FQDN': 'box.example.test',
               'AIRLOCK_PASEO_MEM_CAP_BYTES': '8589934592',
               'TEST_DEVMON_HOOK': sentinel}
        command = ['bash', str(APP / 'install.sh')]
        refused = []
        cases = [('missing', None, 0o600), ('missing-name', 'OTHER=x\n', 0o600),
                 ('mode0644', f'TEST_DEVMON_HOOK={sentinel}\n', 0o644)]
        for label, content, mode in cases:
            if content is not None:
                secret_file.write_text(content)
                secret_file.chmod(mode)
            result = run(command, env=env)
            assert result.returncode != 0, label
            assert b'dev-monitor-secrets.env' in result.stdout, label
            assert sentinel.encode() not in result.stdout, label
            refused.append(label)
        secret_file.chmod(0o600)
        foreign_uid = 65534 if os.getuid() != 65534 else 0
        if args.systemd:
            # The explicit local rehearsal retains real ownership evidence.
            assert run(['sudo', '-n', 'chown', str(foreign_uid), str(secret_file)]).returncode == 0
            try:
                result = run(command, env=env)
                assert result.returncode != 0 and b'owned by the installing user' in result.stdout
            finally:
                assert run(['sudo', '-n', 'chown', str(os.getuid()), str(secret_file)]).returncode == 0
            print('OWNER: real chown mismatch refused; restored owner accepted below')
        else:
            # CI runners cannot chown arbitrarily. Intercept only the exact UID
            # lookup, forwarding every other stat invocation to the real binary.
            shim_dir = scratch / 'shim'
            shim_dir.mkdir()
            counter = scratch / 'owner-stat.calls'
            shim = shim_dir / 'stat'
            shim.write_text('#!' + sys.executable + "\n" +
                            "import os, sys\n"
                            "if sys.argv[1:] == ['-c', '%u', os.environ['DEVMON_TEST_SECRET_FILE']]:\n"
                            "    with open(os.environ['DEVMON_TEST_STAT_CALLS'], 'a') as log: log.write('hit\\n')\n"
                            "    print(os.environ['DEVMON_TEST_OWNER'])\n"
                            "else:\n"
                            "    os.execv('/usr/bin/stat', ['stat', *sys.argv[1:]])\n")
            shim.chmod(0o755)
            owner_env = dict(env, PATH=str(shim_dir) + ':' + env['PATH'],
                             DEVMON_TEST_SECRET_FILE=str(secret_file),
                             DEVMON_TEST_STAT_CALLS=str(counter),
                             DEVMON_TEST_OWNER=str(foreign_uid))
            result = run(command, env=owner_env)
            assert result.returncode != 0 and b'owned by the installing user' in result.stdout
            assert counter.read_text().splitlines() == ['hit']
            owner_env['DEVMON_TEST_OWNER'] = str(os.getuid())
            result = run(command, env=owner_env)
            assert result.returncode == 0, result.stdout.decode()
            assert counter.read_text().splitlines() == ['hit', 'hit']
            print('OWNER: CI exact-stat mismatch refused/match accepted; intercepts=2')
        refused.append('foreign-owner')
        # Controls in the dedicated file are refused before any unit is written.
        original = secret_file.read_bytes()
        with secret_file.open('a') as stream:
            stream.write('DEVMON_SLACK_WEBHOOK_NAME=ABSENT_NAME\nDEV_MONITOR_OWNER=\n')
        assert run(command, env=env).returncode != 0
        secret_file.write_bytes(original)
        # Poll the installer and its descendants, keeping command lines in memory.
        # A file-backed log prevents a full pipe from stalling the measured process.
        installer_log = scratch / 'installer.log'
        sampled = 0
        with installer_log.open('wb') as stream:
            installer = subprocess.Popen(command, env=env, stdout=stream, stderr=subprocess.STDOUT)
            while installer.poll() is None:
                pending = [installer.pid]
                while pending:
                    pid = pending.pop()
                    try:
                        argv = Path(f'/proc/{pid}/cmdline').read_bytes()
                        assert sentinel.encode() not in argv
                        sampled += 1
                        children = Path(f'/proc/{pid}/task/{pid}/children').read_text()
                        pending.extend(int(child) for child in children.split())
                    except (FileNotFoundError, ProcessLookupError):
                        pass  # Short-lived children may exit between reads.
                time.sleep(.005)
        result = subprocess.CompletedProcess(command, installer.returncode, installer_log.read_bytes())
        assert result.returncode == 0, result.stdout.decode()
        assert sampled > 0
        output = scratch / 'render'
        def scan_outputs():
            files = [installer_log, *[p for p in output.rglob('*') if p.is_file()]]
            return sum(sentinel.encode() in p.read_bytes() for p in files)
        assert scan_outputs() == 0
        # Mutation control through the same output scanner: model the old
        # installer accidentally persisting an ambient credential.
        copied = output / 'files/accidental-credential-copy.env'
        copied.write_text('OLD_SLACK_WEBHOOK=' + sentinel + '\n')
        assert scan_outputs() == 1
        copied.unlink()
        assert scan_outputs() == 0
        print('VERIFY 2 (static dry-run only; value semantics NOT RUN here): refused=' + ','.join(refused) + '; mode0600+value=accepted')
        print(f'VERIFY 1: generated files+installer log+argv sentinel_hits=0; argv_samples={sampled}; positive_control=1')
        generated = output / 'files/dev-monitor.env'
        unit = output / 'units/airlock-dev-monitor.service'
        assert 'EnvironmentFile=-%h/.config/airlock/dev-monitor-secrets.env' in unit.read_text()
        assert 'Environment=DEVMON_SLACK_WEBHOOK_NAME=TEST_DEVMON_HOOK' in unit.read_text()
        # Runtime without a webhook still collects and serves health; no sender starts.
        runtime = dict(env)
        runtime.pop('TEST_DEVMON_HOOK')
        for line in generated.read_text().splitlines():
            if line and not line.startswith('#'):
                key, value = line.split('=', 1)
                runtime[key] = value
        runtime.update(AIRLOCK_DEV_MONITOR_MESSAGES='true',
                       AIRLOCK_DEV_MONITOR_BACKEND_PORT=str(port))
        state = home / '.local/state/airlock/dev-monitor'
        state.mkdir(parents=True, exist_ok=True)
        state.chmod(0o710)
        for sub, mode in {'': 0o710, 'tmp': 0o3770, 'new': 0o3770,
                          'processing': 0o700, 'bad': 0o700}.items():
            directory = state / 'spool' / sub
            directory.mkdir(parents=True, exist_ok=True)
            directory.chmod(mode)
        backend = APP / 'backend/airlock-dev-monitor.py'
        def health():
            with urllib.request.urlopen(f'http://127.0.0.1:{port}/api/health', timeout=2) as response:
                return json.load(response)
        def wait_health():
            for _ in range(150):
                try:
                    return health()
                except (OSError, ValueError):
                    time.sleep(.1)
            raise AssertionError('backend did not become healthy within 15s')
        log = scratch / 'backend.log'
        with log.open('wb') as stream:
            proc = subprocess.Popen([sys.executable, str(backend)], env=runtime,
                                    stdout=stream, stderr=subprocess.STDOUT)
            try:
                h = wait_health()
                assert h['messages'] == 'on' and h['slack'] == 'not configured', log.read_text()
                assert h['pending_count'] == 0 and h['last_sent_at'] is None, h
                assert sentinel.encode() not in Path(f'/proc/{proc.pid}/cmdline').read_bytes()
                print('RUNTIME: slack=not configured; messages=on; no pending delivery; argv sentinel_hits=0')
            finally:
                proc.terminate()
                proc.wait(timeout=10)
        assert sentinel.encode() not in log.read_bytes()
        if args.systemd:
            # Only this scratch unit is linked into the real user manager.
            name = 'devmon-secret-test-' + secrets.token_hex(6) + '.service'
            (private / 'dev-monitor.env').write_bytes(generated.read_bytes())
            (private / 'dev-monitor.env').chmod(0o600)
            test_unit = scratch / name
            test_unit.write_text(unit.read_text().replace('%h', str(home)))
            try:
                assert run(['systemctl', '--user', 'link', str(test_unit)]).returncode == 0
                assert run(['systemctl', '--user', 'start', name]).returncode == 0
                h = wait_health()
                assert h['slack'] == 'configured' and h['messages'] == 'on', h
                pid = int(run(['systemctl', '--user', 'show', '-p', 'MainPID', '--value', name]).stdout)
                assert sentinel.encode() not in Path(f'/proc/{pid}/cmdline').read_bytes()
                journal = run(['journalctl', '--user', '-u', name, '--no-pager']).stdout
                assert sentinel.encode() not in journal
                print('SYSTEMD: EnvironmentFile loaded; slack=configured; argv+journal sentinel_hits=0')
            finally:
                run(['systemctl', '--user', 'disable', '--now', name])
                run(['systemctl', '--user', 'reset-failed', name])
                run(['systemctl', '--user', 'daemon-reload'])
        if args.orchestrator:
            env.update(AIRLOCK_CONFD=str(scratch / 'confd'),
                       AIRLOCK_WEBROOT=str(scratch / 'web'),
                       AIRLOCK_STATE_DIR=str(scratch / 'state'))
            result = run(['bash', str(ROOT / 'install/airlock-install.sh')], env=env)
            assert sentinel.encode() not in result.stdout
            if result.returncode:
                # Synthetic-only log: safe to retain for diagnosis, no live input.
                Path('/tmp/devmon-orchestrator-test.log').write_bytes(result.stdout)
                print('VERIFY 4: scratch orchestrator PATH=/usr/local/bin:/usr/bin:/bin; '
                      f'exit={result.returncode}; details=/tmp/devmon-orchestrator-test.log')
            else:
                print('VERIFY 4: scratch orchestrator PATH=/usr/local/bin:/usr/bin:/bin; completed (dry run)')
        print('secret contract: PASS')


if __name__ == '__main__':
    main()
