#!/usr/bin/env python3
"""Pure precedence/launcher contracts by default; actual loader with --systemd."""
import argparse
import importlib.util
import json
import secrets
import os
import runpy
import time
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

APP = Path(__file__).resolve().parent
ROOT = APP.parents[1]
sys.path.insert(0, str(APP / 'backend'))
from devmon_secrets import resolve, slack_webhooks
from devmon_secret_file import assignment_names
spec = importlib.util.spec_from_file_location('checker', APP / 'check-secrets.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class Pure(unittest.TestCase):
    def test_preexec_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / 'synthetic.env'
            for content in ('HOOK=synthetic\nPYTHONPATH=synthetic\n',
                            'HOOK=synthetic\nBASH_ENV=synthetic\n',
                            'HOOK=synthetic\nNODE_OPTIONS=synthetic\n',
                            'HOOK=synthetic\nUNSELECTED=synthetic\n',
                            "HOOK='unfinished", 'not an assignment\nHOOK=synthetic\n',
                            'HOOK=synthetic\0\nPYTHONPATH=synthetic\n'):
                file.write_text(content); file.chmod(0o600)
                with patch.object(checker.subprocess, 'run') as run:
                    self.assertFalse(checker.check_file(file, ['HOOK']))
                    run.assert_not_called()
            for name in ('PYTHONPATH', 'PYTHONHOME', 'PYTHONSTARTUP', 'LD_PRELOAD',
                         'LD_AUDIT', 'LD_LIBRARY_PATH', 'BASH_ENV', 'ENV', 'SHELLOPTS', 'NODE_OPTIONS'):
                with patch.object(checker.subprocess, 'run') as run:
                    with self.assertRaises(ValueError):
                        checker.check_file(file, [name])
                    run.assert_not_called()
        self.assertEqual(assignment_names("HOOK='fake\nPYTHONPATH=not-an-assignment\n'\nSECOND=x\n"), ('HOOK', 'SECOND'))
        self.assertEqual(assignment_names('HOOK=x\nHOOK=y\n'), ('HOOK', 'HOOK'))

    def test_precedence(self):
        for selector, expected in ((None, 'legacy'), ('', 'legacy'), ('   ', 'legacy'),
                                   ('HOOK', 'chosen'), ('MISSING', '')):
            env = {'HOOK': ' chosen ', 'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': ' legacy ',
                   'AIRLOCK_DEVMON_SLACK_WEBHOOK': 'alias'}
            if selector is not None:
                env.update(DEVMON_SLACK_WEBHOOK_NAME=selector)
            self.assertEqual(slack_webhooks(env), {'slack-urgent': expected})
        backend = runpy.run_path(str(APP / 'backend/airlock-dev-monitor.py'))
        for selector in (None, '', '   ', 'HOOK', 'MISSING'):
            runtime = {'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT': 'legacy', 'HOOK': 'chosen'}
            if selector is not None: runtime['DEVMON_SLACK_WEBHOOK_NAME'] = selector
            with patch.dict(os.environ, runtime, clear=True):
                self.assertEqual(backend['_slack_webhooks'](), slack_webhooks(runtime))
        self.assertEqual(slack_webhooks({'AIRLOCK_DEVMON_SLACK_WEBHOOK': 'alias'})['slack-urgent'], '')
        for value in ('', ' \n\t ', 'random-marker'):
            self.assertEqual(resolve({'HOOK': value}, 'HOOK', marker='random-marker'), '')
        with self.assertRaises(ValueError):
            resolve({}, 'DEVMON_SLACK_WEBHOOK_NAME')

    def test_launcher_timeout_cleanup_and_no_values(self):
        calls = []
        def timed_out(argv, **kwargs):
            calls.append((argv, kwargs))
            if argv[0] == 'systemd-run':
                raise subprocess.TimeoutExpired(argv, kwargs['timeout'])
            return subprocess.CompletedProcess(argv, 0)
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / 'synthetic.env'
            file.write_text('HOOK=synthetic\n'); file.chmod(0o600)
            with patch.object(checker.subprocess, 'run', side_effect=timed_out):
                self.assertFalse(checker.check_file(file, ['HOOK']))
        self.assertEqual([a[0][0] for a in calls], ['systemd-run', 'systemctl', 'systemctl'])
        command = calls[0][0]
        self.assertIn('RuntimeMaxSec=10', command)
        self.assertIn('--wait', command)
        self.assertIn('--collect', command)
        self.assertTrue(any(arg.startswith('Environment=HOOK=devmon-unset-') for arg in command))
        unit = next(arg.split('=', 1)[1] for arg in command if arg.startswith('--unit='))
        self.assertEqual(calls[1][0], ['systemctl', '--user', 'stop', unit])
        self.assertEqual(calls[2][0], ['systemctl', '--user', 'reset-failed', unit])
        self.assertTrue(all(kw['stdout'] == subprocess.DEVNULL and kw['stderr'] == subprocess.DEVNULL for _, kw in calls))
        with tempfile.TemporaryDirectory() as tmp:
            file = Path(tmp) / 'synthetic.env'
            file.write_text('HOOK=synthetic\n'); file.chmod(0o600)
            with patch.object(checker.subprocess, 'run', side_effect=OSError('manager unavailable')) as run:
                self.assertFalse(checker.check_file(file, ['HOOK']))
                self.assertEqual(run.call_count, 3)
        with patch.object(checker.subprocess, 'run') as run:
            with self.assertRaises(ValueError):
                checker.check_file('/scratch/synthetic.env', ['HOOK;touch INJECTED'])
            run.assert_not_called()


class Systemd(unittest.TestCase):
    def test_node_execution_boundary(self):
        # The backend launches npm (devmon_updates.codex_latest) with inherited
        # environment. Node applies --require before that child's program runs.
        with tempfile.TemporaryDirectory(prefix='devmon-node-boundary-') as tmp:
            root = Path(tmp)
            app = root / 'app'
            shutil.copytree(APP, app, ignore=shutil.ignore_patterns('__pycache__'))
            (app / 'install-spool-hardening.sh').write_text('#!/bin/sh\necho AFTER_VALIDATION\nexit 77\n')
            home = root / 'home'
            private = home / '.config/airlock'
            private.mkdir(parents=True)
            file = private / 'dev-monitor-secrets.env'
            hook, marker = root / 'hook.cjs', root / 'hook-ran'
            hook.write_text('require("fs").writeFileSync(' + json.dumps(str(marker)) + ', "hit");\n')
            content = 'HOOK=synthetic\nNODE_OPTIONS=--require=' + str(hook) + '\n'
            file.write_text(content); file.chmod(0o600)
            node = shutil.which('node')
            self.assertIsNotNone(node)
            positive = subprocess.run(['systemd-run', '--user', '--wait', '--collect', '--quiet',
                '--unit=devmon-node-control-' + secrets.token_hex(8),
                '-p', 'RuntimeMaxSec=10', '-p', 'EnvironmentFile=' + str(file),
                '-p', 'StandardOutput=null', '-p', 'StandardError=null', node, '-e', '0'],
                capture_output=True, timeout=15)
            self.assertEqual(positive.returncode, 0)
            self.assertEqual(positive.stdout + positive.stderr, b'')
            self.assertTrue(marker.exists())
            marker.unlink()
            config = root / 'airlock.toml'
            env = dict(os.environ)
            env.update({'HOME': str(home), 'AIRLOCK_ROOT': str(ROOT), 'AIRLOCK_APP_DIR': str(app),
                        'AIRLOCK_APP_ID': 'dev-monitor', 'AIRLOCK_CONFIG': str(config), 'AIRLOCK_DRY_RUN': '0',
                        'AIRLOCK_TS_FQDN': 'box.example.test', 'AIRLOCK_PASEO_MEM_CAP_BYTES': '8589934592'})
            env.pop('AIRLOCK_RENDER_DIR', None)
            for name in ('HOOK', 'NODE_OPTIONS'):
                config.write_text('[auth]\nprovider="tailscale"\nowner="owner@example.test"\n'
                                  '[apps.hub]\n[apps.dev-monitor]\nmessages=true\nslack_webhook_urgent_env="' + name + '"\n')
                checked = subprocess.run([sys.executable, str(APP / 'check-secrets.py'), '--file', str(file), name],
                                         capture_output=True, timeout=15)
                self.assertNotEqual(checked.returncode, 0)
                self.assertEqual(checked.stdout + checked.stderr, b'')
                result = subprocess.run(['bash', str(app / 'install.sh')], env=env, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 1)
                self.assertNotIn(b'AFTER_VALIDATION', result.stdout)
                self.assertFalse(marker.exists())
                self.assertFalse((home / '.config/systemd/user').exists())
            file.write_text('HOOK=synthetic\n')
            config.write_text(config.read_text().replace('NODE_OPTIONS', 'HOOK'))
            self.assertEqual(subprocess.run(['bash', str(app / 'install.sh')], env=env,
                                           capture_output=True, timeout=30).returncode, 77)
            print('NODE PREEXEC: actual loader positive hook=1; selected+extra checker/install refused; hook=0; unit files=0; normal credential accepted')

    def test_name_lexer_systemd_oracle(self):
        with tempfile.TemporaryDirectory(prefix='devmon-name-oracle-') as tmp:
            root = Path(tmp)
            file, output = root / 'synthetic.env', root / 'names.json'
            probe = root / 'probe.py'
            probe.write_text('import json,os,pathlib,sys\n'
                             'pathlib.Path(sys.argv[1]).write_text(json.dumps(sorted(os.environ)))\n')
            def oracle(content):
                file.write_bytes(content.encode()); file.chmod(0o600)
                cmd = ['systemd-run', '--user', '--wait', '--collect', '--quiet',
                       '--unit=devmon-name-oracle-' + secrets.token_hex(8),
                       '-p', 'RuntimeMaxSec=10', '-p', 'StandardOutput=null', '-p', 'StandardError=null',
                       '-p', 'EnvironmentFile=' + str(file), sys.executable, str(probe), str(output)]
                result = subprocess.run(cmd, capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stdout + result.stderr, b'')
                return set(json.loads(output.read_text()))
            baseline = oracle('')
            cases = [
                ('HOOK=synthetic\n', True),
                ("HOOK='synthetic\nFAKE_KEY=inside quote\n# comment inside quote\n'\nSECOND=x\n", True),
                ('HOOK="synthetic\nFAKE_KEY=inside quote\n"\nSECOND=x\n', True),
                ('HOOK=synthetic\\\nFAKE_KEY=continued\nSECOND=x\n', True),
                ('HOOK="synthetic\\\ncontinued"\nSECOND=x\n', True),
                ('HOOK=first\nHOOK=\n', False),
                ('HOOK=\nHOOK=last\n', True),
                ("HOOK=' \n \t '\n", False),
                (' # comment\\\nHOOK=x\n; other comment\nSECOND=y\n', True),
                ('HOOK="x"\r\nSECOND=y\r\n', True),
                ('HOOK=unquoted"literal\nSECOND=y\n', True),
                ('HOOK = "x" \'y\' z\nSECOND=y\n', True),
            ]
            for index, (content, nonempty) in enumerate(cases):
                with self.subTest(case=index):
                    names = assignment_names(content)
                    self.assertEqual(oracle(content) - baseline, set(names))
                    self.assertEqual(checker.check_file(file, ['HOOK'], allowed=['SECOND']), nonempty)
            print('NAME ORACLE: 12 systemd paired syntax/value cases; all assignment names match; output=0')

    def test_file_boundary_without_selectors(self):
        with tempfile.TemporaryDirectory(prefix='devmon-file-boundary-') as tmp:
            root = Path(tmp)
            app = root / 'app'
            shutil.copytree(APP, app, ignore=shutil.ignore_patterns('__pycache__'))
            (app / 'install-spool-hardening.sh').write_text('#!/bin/sh\necho REACHED_AFTER_SECRET_VALIDATION\nexit 77\n')
            home = root / 'home'
            private = home / '.config/airlock'
            private.mkdir(parents=True)
            file = private / 'dev-monitor-secrets.env'
            config = root / 'airlock.toml'
            base = '[auth]\nprovider="tailscale"\nowner="owner@example.test"\n[apps.hub]\n[apps.dev-monitor]\n'
            env = dict(os.environ)
            env.update({'HOME': str(home), 'AIRLOCK_ROOT': str(ROOT), 'AIRLOCK_APP_DIR': str(app),
                        'AIRLOCK_APP_ID': 'dev-monitor', 'AIRLOCK_CONFIG': str(config), 'AIRLOCK_DRY_RUN': '0',
                        'AIRLOCK_TS_FQDN': 'box.example.test', 'AIRLOCK_PASEO_MEM_CAP_BYTES': '8589934592'})
            env.pop('AIRLOCK_RENDER_DIR', None)
            def install():
                return subprocess.run(['bash', str(app / 'install.sh')], env=env, capture_output=True, timeout=30)
            legacy = 'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT=synthetic\n'
            for messages in ('true', 'false'):
                config.write_text(base + f'messages={messages}\n')
                if file.exists(): file.unlink()
                self.assertEqual(install().returncode, 77)  # optional absent file
                for mode in (0o644, 0o600):
                    file.write_text(legacy); file.chmod(mode)
                    with self.subTest(messages=messages, mode=oct(mode)):
                        self.assertEqual(install().returncode, 77 if mode == 0o600 else 1)
            foreign = 65534 if os.getuid() != 65534 else 0
            self.assertEqual(subprocess.run(['sudo', '-n', 'chown', str(foreign), str(file)], capture_output=True).returncode, 0)
            try:
                with self.subTest(owner='foreign'):
                    self.assertEqual(install().returncode, 1)
            finally:
                self.assertEqual(subprocess.run(['sudo', '-n', 'chown', str(os.getuid()), str(file)], capture_output=True).returncode, 0)
            self.assertEqual(install().returncode, 77)
            cases = ('AIRLOCK_DEV_MONITOR_BACKEND_PORT=not-a-number\n',
                     'AIRLOCK_DEV_MONITOR_BACKEND_PORT=19923\nAIRLOCK_DEV_MONITOR_BACKEND_PORT=broken\n',
                     "AIRLOCK_DEV_MONITOR_BACKEND_PORT='not\na-number'\n",
                     'AIRLOCK_DEV_MONITOR_BACKEND_PORT=broken\nAIRLOCK_DEV_MONITOR_BACKEND_PORT=19923\n',
                     'DEV_MONITOR_OWNER=synthetic\n', 'DEVMON_SLACK_WEBHOOK_NAME=HOOK\n')
            for selection in ('', 'slack_webhook_urgent_env="HOOK"\n'):
                config.write_text(base + 'messages=true\n' + selection)
                for extra in cases:
                    file.write_text(legacy + 'HOOK=synthetic\n' + extra); file.chmod(0o600)
                    with self.subTest(selected=bool(selection), extra=extra.split('=', 1)[0]):
                        result = install()
                        self.assertEqual(result.returncode, 1)
                        self.assertNotIn(b'not-a-number', result.stdout + result.stderr)
            hook = root / 'hook-ran'
            (root / 'sitecustomize.py').write_text(
                'import os,pathlib\npathlib.Path(' + repr(str(hook)) + ').touch()\nos._exit(0)\n')
            bash_hook = root / 'bash-hook.sh'
            bash_hook.write_text('touch ' + str(hook) + '\n')
            for name, value in (('PYTHONPATH', str(root)), ('BASH_ENV', str(bash_hook)),
                                ('LD_PRELOAD', str(root / 'synthetic.so'))):
                if name in ('PYTHONPATH', 'BASH_ENV'):
                    # Positive control: the real loader can execute this synthetic
                    # hook if the pre-exec name boundary is bypassed.
                    file.write_text('HOOK=\n' + name + '=' + value + '\n'); file.chmod(0o600)
                    child = [sys.executable, '-c', 'pass'] if name == 'PYTHONPATH' else ['/bin/bash', '-c', 'true']
                    command = ['systemd-run', '--user', '--wait', '--collect', '--quiet',
                               '--unit=devmon-hook-control-' + secrets.token_hex(8),
                               '-p', 'RuntimeMaxSec=10', '-p', 'EnvironmentFile=' + str(file),
                               '-p', 'StandardOutput=null', '-p', 'StandardError=null'] + child
                    positive = subprocess.run(command, capture_output=True, timeout=15)
                    self.assertEqual(positive.returncode, 0)
                    self.assertEqual(positive.stdout + positive.stderr, b'')
                    self.assertTrue(hook.exists())
                    hook.unlink()
                for selected in (False, True):
                    config.write_text(base + 'messages=true\nslack_webhook_urgent_env="' + (name if selected else 'HOOK') + '"\n')
                    file.write_text('HOOK=synthetic\n' + name + '=' + value + '\n'); file.chmod(0o600)
                    result = install()
                    self.assertEqual(result.returncode, 1)
                    self.assertFalse(hook.exists())
                    self.assertFalse((home / '.config/systemd/user').exists())
                    self.assertNotIn(b'REACHED_AFTER_SECRET_VALIDATION', result.stdout)
            config.write_text(base + 'messages=true\nslack_webhook_urgent_env="DEVMON_SLACK_WEBHOOK"\n'
                              '')
            file.write_text('DEVMON_SLACK_WEBHOOK=synthetic\n'); file.chmod(0o600)
            self.assertEqual(install().returncode, 77)
            print('PREEXEC: extra/selected PYTHONPATH+BASH_ENV+LD_PRELOAD refused; hook=0; positive hooks=2; unit files=0; single webhook default accepted')
            print('FILE BOUNDARY: optional absent accepted; legacy/no-selector 0644+foreign owner refused; 0600 accepted; 12 control pollution cases refused')

    def test_actual_loader_and_installer(self):
        with tempfile.TemporaryDirectory(prefix='devmon-resolution-') as tmp:
            root = Path(tmp)
            file = root / 'synthetic.env'
            # Preserve the actual installer/preflight; replace only the next
            # privileged side-effect stage with a stop marker. No production install.
            app = root / 'app'
            shutil.copytree(APP, app, ignore=shutil.ignore_patterns('__pycache__'))
            (app / 'install-spool-hardening.sh').write_text('#!/bin/sh\necho REACHED_AFTER_SECRET_VALIDATION\nexit 77\n')
            home = root / 'home'
            private = home / '.config/airlock'
            private.mkdir(parents=True)
            installed_file = private / 'dev-monitor-secrets.env'
            config = root / 'airlock.toml'
            config.write_text('[auth]\nprovider="tailscale"\nowner="owner@example.test"\n'
                              '[apps.hub]\n[apps.dev-monitor]\nmessages=true\nslack_webhook_urgent_env="HOOK"\n')
            env = dict(os.environ)
            env.update({'HOME': str(home), 'AIRLOCK_ROOT': str(ROOT), 'AIRLOCK_APP_DIR': str(app),
                        'AIRLOCK_APP_ID': 'dev-monitor', 'AIRLOCK_CONFIG': str(config), 'AIRLOCK_DRY_RUN': '0',
                        'AIRLOCK_TS_FQDN': 'box.example.test', 'AIRLOCK_PASEO_MEM_CAP_BYTES': '8589934592'})
            env.pop('AIRLOCK_RENDER_DIR', None)
            cases = [("HOOK=' \n \t '\n", False), ('HOOK=" \n "\n', False),
                     ('HOOK=\n', False), ('OTHER=synthetic\n', False),
                     ("HOOK='synthetic\nmultiline'\n", True), ('HOOK="synthetic"\n', True),
                     ('HOOK=synthetic\n', True), ('HOOK=$(touch SHOULD_NOT_EXIST)\n', True)]
            for content, good in cases:
                file.write_text(content); file.chmod(0o600)
                result = subprocess.run([sys.executable, str(APP / 'check-secrets.py'), '--file', str(file), 'HOOK'],
                                        capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0 if good else 1)
                self.assertEqual(result.stdout + result.stderr, b'')
                installed_file.write_text(content); installed_file.chmod(0o600)
                installed = subprocess.run(['bash', str(app / 'install.sh')], env=env,
                                           capture_output=True, timeout=30)
                self.assertEqual(installed.returncode, 77 if good else 1, installed.stderr.decode())
                self.assertEqual(b'REACHED_AFTER_SECRET_VALIDATION' in installed.stdout, good)
                self.assertFalse((app / 'SHOULD_NOT_EXIST').exists())
            print('SYSTEMD/INSTALL: multiline blank refused; valid multiline accepted; 8 paired cases; checker output=0')
            # Observe actual systemd value interpretation inside the loaded checker
            # process, including an inherited manager value that must be masked.
            import secrets
            name = 'DEVMON_INHERITED_' + secrets.token_hex(8).upper()
            try:
                self.assertEqual(subprocess.run(['systemctl', '--user', 'set-environment', name+'=synthetic'],
                                               capture_output=True).returncode, 0)
                file.write_text('')
                self.assertFalse(checker.check_file(file, [name]))
                file.write_text(name + "='synthetic\nmultiline'\n")
                self.assertTrue(checker.check_file(file, [name]))
                # Separate child probes exact interpreted value through the same loader.
                check = root / 'exact.py'
                check.write_text('import os,sys\nsys.exit(0 if os.environ.get(sys.argv[1]) == "synthetic\\nmultiline" else 1)\n')
                unit = 'devmon-resolution-exact-' + secrets.token_hex(8)
                cmd = ['systemd-run', '--user', '--wait', '--collect', '--quiet', '--unit='+unit,
                       '-p', 'RuntimeMaxSec=10', '-p', 'Environment='+name+'=marker',
                       '-p', 'EnvironmentFile='+str(file), '-p', 'StandardOutput=null', '-p', 'StandardError=null',
                       sys.executable, str(check), name]
                self.assertEqual(subprocess.run(cmd, capture_output=True, timeout=15).returncode, 0)
            finally:
                subprocess.run(['systemctl', '--user', 'unset-environment', name], capture_output=True)
            print('SYSTEMD ORDER: inherited value masked; file overrides marker; exact multiline preserved')
            # Unavailable manager is a real launcher failure, never regex fallback.
            dead = dict(env, DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent/devmon-bus')
            result = subprocess.run([sys.executable, str(APP / 'check-secrets.py'), '--file', str(file), name],
                                    env=dead, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout + result.stderr, b'')
            # A real stuck child must be bounded and collected by the launcher.
            delayed = app / 'check-secrets.py'
            delayed.write_text(delayed.read_text().replace(
                "    args = parser.parse_args()", "    args = parser.parse_args()\n    if args.loaded:\n        import time\n        time.sleep(30)"))
            started = time.monotonic()
            timed = subprocess.run([sys.executable, str(delayed), '--file', str(file), name],
                                   capture_output=True, timeout=30)
            self.assertEqual(timed.returncode, 1)
            self.assertEqual(timed.stdout + timed.stderr, b'')
            self.assertLess(time.monotonic() - started, 25)
            print('SYSTEMD TIMEOUT: stuck checker refused within 25s; output=0')
            units = subprocess.run(['systemctl', '--user', 'list-units', '--all', '--plain', '--no-legend',
                                    'airlock-devmon-secret-check-*'], capture_output=True)
            self.assertEqual(units.returncode, 0)
            self.assertEqual(units.stdout.strip(), b'')
            print('SYSTEMD: unavailable manager refused; random checker units cleaned up')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--systemd', action='store_true')
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(Pure)
    if args.systemd:
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(Systemd))
    else:
        print('SYSTEMD semantics/installer: NOT RUN (use --systemd)', flush=True)
    sys.exit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
