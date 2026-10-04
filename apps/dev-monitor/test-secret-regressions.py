#!/usr/bin/env python3
"""Review regressions through scratch installer, backend, nginx, and public smoke CLI."""
import http.server
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request

APP = Path(__file__).resolve().parent
ROOT = APP.parents[1]


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


class SecretRegressionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='devmon-secret-regression-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home'
        self.private = self.home / '.config/airlock'
        self.private.mkdir(parents=True)
        self.file = self.private / 'dev-monitor-secrets.env'
        self.config = self.root / 'airlock.toml'
        self.backend_port, self.hub_port = port(), port()
        self.env = {'HOME': str(self.home), 'PATH': '/usr/local/bin:/usr/bin:/bin',
                    'AIRLOCK_ROOT': str(ROOT), 'AIRLOCK_APP_DIR': str(APP),
                    'AIRLOCK_APP_ID': 'dev-monitor', 'AIRLOCK_CONFIG': str(self.config),
                    'AIRLOCK_DRY_RUN': '1', 'AIRLOCK_RENDER_DIR': str(self.root / 'render'),
                    'AIRLOCK_STATE_DIR': str(self.home / '.local/state/airlock'),
                    'AIRLOCK_TS_FQDN': 'box.example.test',
                    'AIRLOCK_PASEO_MEM_CAP_BYTES': '8589934592',
                    **{key: os.environ[key] for key in ('XDG_RUNTIME_DIR', 'DBUS_SESSION_BUS_ADDRESS') if key in os.environ}}
        self.configure('urgent')

    def configure(self, lane):
        self.hook_name = ('AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT' if lane == 'legacy' else
                          'DEVMON_SLACK_WEBHOOK' if lane == 'shared' else 'REGRESSION_HOOK')
        selector = '' if lane == 'legacy' else self.hook_name
        self.config.write_text('[auth]\nprovider="tailscale"\nowner="owner@example.test"\n'
                               f'[apps.hub]\nnginx_port={self.hub_port}\n'
                               f'[apps.dev-monitor]\nmessages=true\nbackend_port={self.backend_port}\n'
                               f'slack_webhook_urgent_env="{selector}"\n')
    def install(self, value):
        self.file.write_text(self.hook_name + '=' + value + '\n')
        self.file.chmod(0o600)
        return subprocess.run(['bash', str(APP / 'install.sh')], env=self.env,
                              capture_output=True, timeout=45)

    def test_dry_run_does_not_claim_value_validation(self):
        for value in ('"   "', "'   '", '"\t \t"', "'\t \t'", '  " \t "  ',
                      '"\u00a0"', "'\u3000'", '"\r "'):
            with self.subTest(value_kind=ascii(value)):
                result = self.install(value)
                self.assertEqual(result.returncode, 0)
                self.assertIn(b'systemd value semantics NOT checked', result.stdout + result.stderr)
        for value in ('https://hooks.example.test/synthetic',
                      '"https://hooks.example.test/synthetic"',
                      "'https://hooks.example.test/synthetic'"):
            self.assertEqual(self.install(value).returncode, 0)

    def test_selector_control_collisions(self):
        selectors = ('DEVMON_SLACK_WEBHOOK_NAME', 'DEVMON_SLACK_BOT_TOKEN_NAME', 'DEVMON_INGEST_TOKEN_NAME',
                     'DEVMON_SMTP_PASSWORD_NAME')
        targets = (*selectors, 'DEV_MONITOR_OWNER', 'DEV_MONITOR_SMTP_HOST',
                   'DEV_MONITOR_DB', 'AIRLOCK_DEV_MONITOR_BACKEND_PORT',
                   'AIRLOCK_AGENT_BIN', 'HOME', 'DEVMON_SLACK_CHANNEL')
        for field, selector in zip(('slack_webhook_urgent_env', 'slack_bot_token_env'), selectors):
            for target in targets:
                with self.subTest(field=field, target=target):
                    self.configure('urgent')
                    self.config.write_text(self.config.read_text().replace(
                        'slack_webhook_urgent_env="REGRESSION_HOOK"', f'{field}="{target}"'))
                    self.file.write_text(f'{target}=https://hooks.example.test/synthetic\n')
                    self.file.chmod(0o600)
                    result = subprocess.run(['bash', str(APP / 'install.sh')], env=self.env,
                                            capture_output=True, timeout=45)
                    self.assertNotEqual(result.returncode, 0, 'control collision accepted by install')
                    self.assertIn(b'credential name must not be an app control variable', result.stderr + result.stdout)
                    # Direct render callers must refuse before emitting any bytes.
                    args = ['owner@example.test', 'synthetic-proxy', '/tmp/state', '/tmp',
                            'session', '', '', '', '', '', '', '', '', '']
                    args[5 if field == 'slack_webhook_urgent_env' else 8] = target
                    commands = [('render_dev_monitor_env', args)]
                    unit_args = ['19923', 'true', 'Tailscale-User-Login', '', '/tmp/env',
                                 'false', '24', '24', 'false', '', '', '', '', '', '']
                    unit_args[12 if field == 'slack_webhook_urgent_env' else 14] = target
                    commands.append(('render_dev_monitor_unit', unit_args))
                    for function, arguments in commands:
                        rendered = subprocess.run(
                            ['bash', '-c', '. "$1"; shift; "$@"', 'render', str(APP / 'render.sh'),
                             function, *arguments], env=self.env, capture_output=True, timeout=10)
                        self.assertEqual(rendered.returncode, 2)
                        self.assertEqual(rendered.stdout, b'')
                    # Direct runtime configuration bypassing install also fails before
                    # a control such as port/HOME can be interpreted as credential bytes.
                    runtime = dict(self.env, **{key: '' for key in selectors})
                    runtime[target] = 'https://hooks.example.test/synthetic'
                    runtime[selector] = target
                    backend = subprocess.run([sys.executable, str(APP / 'backend/airlock-dev-monitor.py')],
                                             env=runtime, capture_output=True, timeout=10)
                    self.assertNotEqual(backend.returncode, 0)
                    self.assertIn(b'credential name must not be an app control variable', backend.stderr)
                    self.assertNotIn(b'https://hooks.example.test/synthetic', backend.stdout + backend.stderr)
                    # Exercise the Slack resolver independently after startup, so
                    # the startup guard cannot hide a missing resolver guard.
                    direct = subprocess.run([sys.executable, '-c',
                        'import runpy,os,sys; m=runpy.run_path(sys.argv[1]); '
                        'os.environ[sys.argv[2]]=sys.argv[3]; m["_slack_sender"]()',
                        str(APP / 'backend/airlock-dev-monitor.py'), selector, target],
                        env=self.env, capture_output=True, timeout=10)
                    if selector != 'DEVMON_SMTP_PASSWORD_NAME':
                        self.assertNotEqual(direct.returncode, 0)
                        self.assertIn(b'app control variable', direct.stderr)
        print('COLLISION: webhook/bot install/runtime refusals; direct env/unit render stdout=0', flush=True)

    def test_ingest_assignment_name_only(self):
        for assignment in ('', 'DEVMON_INGEST_TOKEN=\n',
                           'DEVMON_INGEST_TOKEN=synthetic-ingest-token\n'):
            with self.subTest(declared=bool(assignment)):
                self.file.write_text('REGRESSION_HOOK=synthetic-hook\n' + assignment)
                self.file.chmod(0o600)
                result = subprocess.run(['bash', str(APP / 'install.sh')], env=self.env,
                                        capture_output=True, timeout=45)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                generated = (self.root / 'render/files/dev-monitor.env').read_text()
                selector = 'DEVMON_INGEST_TOKEN' if assignment else ''
                self.assertIn('DEVMON_INGEST_TOKEN_NAME=' + selector + '\n', generated)
                self.assertNotIn('synthetic-ingest-token', generated)
                self.assertTrue((self.root / 'render/confd/servers.d/dev-monitor.conf').is_file())
                package_info = subprocess.run([str(ROOT / 'bin/airlock-config'), 'package-info'],
                                              env=self.env, capture_output=True, timeout=15)
                self.assertEqual(package_info.returncode, 0, package_info.stderr.decode())
                mapping = json.loads(package_info.stdout)['packages']['dev-monitor']['serve_mappings']
                self.assertEqual(mapping['ingest_port'],
                                 {'listen': 19926, 'mode': 'https', 'target': 19926})
                if not assignment:
                    self.assertIn(b'HTTP ingest disabled', result.stdout + result.stderr)

    def test_bot_secret_file_and_rendered_names(self):
        self.config.write_text(self.config.read_text() +
                               'slack_bot_token_env="REGRESSION_BOT"\nslack_channel="C_TEST"\n')
        self.file.write_text('REGRESSION_HOOK=synthetic-hook\nREGRESSION_BOT=synthetic-bot\n'
                             'DEVMON_INGEST_TOKEN=synthetic-ingest\n')
        self.file.chmod(0o600)
        def install():
            return subprocess.run(['bash', str(APP / 'install.sh')], env=self.env,
                                  capture_output=True, timeout=45)
        result = install()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        generated = (self.root / 'render/files/dev-monitor.env').read_text()
        unit = (self.root / 'render/units/airlock-dev-monitor.service').read_text()
        self.assertIn('DEVMON_SLACK_BOT_TOKEN_NAME=REGRESSION_BOT\n', generated)
        self.assertIn('DEVMON_SLACK_CHANNEL="C_TEST"\n', generated)
        self.assertIn('DEVMON_INGEST_TOKEN_NAME=DEVMON_INGEST_TOKEN\n', generated)
        self.assertIn('Environment=DEVMON_SLACK_BOT_TOKEN_NAME=REGRESSION_BOT\n', unit)
        self.assertIn('Environment="DEVMON_SLACK_CHANNEL=C_TEST"\n', unit)
        for value in ('synthetic-hook', 'synthetic-bot', 'synthetic-ingest'):
            self.assertNotIn(value, generated + unit + result.stdout.decode() + result.stderr.decode())
        self.file.chmod(0o644)
        self.assertNotEqual(install().returncode, 0)
        self.file.chmod(0o600)
        target = self.private / 'fixture.env'
        self.file.rename(target)
        self.file.symlink_to(target)
        self.assertNotEqual(install().returncode, 0)
        self.file.unlink()
        self.file.write_text('REGRESSION_HOOK=synthetic-hook\n')
        self.file.chmod(0o600)
        self.assertNotEqual(install().returncode, 0)

    def test_smoke_bot_settings_with_messages_on_and_off(self):
        import io
        from unittest.mock import patch
        smoke = (APP / 'smoke.sh').read_text()
        script = smoke.split("<<'DEVMON_DELIVERY_PY'\n")[1].split('\nDEVMON_DELIVERY_PY')[0]
        self.config.write_text(self.config.read_text() +
                               'slack_bot_token_env="CONFIG_BOT"\nslack_channel="C_CONFIG"\n')
        # Run the real config-loading shell prelude: shell assignments alone do
        # not reach the Python probe unless the smoke command exports them.
        loaded = subprocess.run(['bash', '-c', smoke.split('code() {')[0] +
                                 'python3 -c \'import os,json; print(json.dumps(dict(os.environ)))\'',
                                 str(APP / 'smoke.sh')], env=self.env, capture_output=True, timeout=15)
        self.assertEqual(loaded.returncode, 0, loaded.stderr.decode())
        config_env = json.loads(loaded.stdout)
        health = {'slack': 'configured', 'pending_count': 0, 'failed_count': 0, 'last_sent_at': None}
        env_file = self.private / 'dev-monitor.env'
        for content, expected_name, expected_channel in (
                ('DEV_MONITOR_OWNER=owner@example.test\n', 'CONFIG_BOT', 'C_CONFIG'),
                ('DEVMON_SLACK_BOT_TOKEN_NAME=INSTALLED_BOT\nDEVMON_SLACK_CHANNEL="C_INSTALLED"\n',
                 'INSTALLED_BOT', 'C_INSTALLED')):
            env_file.write_text(content)
            with patch.dict(os.environ, config_env, clear=True), \
                    patch.object(sys, 'argv', ['smoke', '19923', str(env_file),
                                             str(APP / 'check-secrets.py'), str(self.file)]), \
                    patch('subprocess.run', return_value=subprocess.CompletedProcess([], 0)) as checker, \
                    patch('urllib.request.urlopen', return_value=io.BytesIO(json.dumps(health).encode())):
                exec(compile(script, str(APP / 'smoke.sh'), 'exec'), {})
                command = checker.call_args.args[0]
                self.assertEqual(command[command.index('--bot-selector') + 1], expected_name)
                self.assertEqual(command[command.index('--channel') + 1], expected_channel)

    def test_control_inventory_and_shared_default(self):
        sys.path.insert(0, str(APP / 'backend'))
        from devmon_secret_names import CONTROL_NAMES, validate_names
        import re
        # A newly generated control must enter the app boundary before it can be
        # selected as a secret. This checks the actual renderer's emitted keys.
        rendered = subprocess.run(['bash', '-c',
            '. "$1"; render_dev_monitor_env owner synthetic /tmp/state /tmp session "" "" ""; '
            'render_dev_monitor_unit 19923 true Tailscale-User-Login "" /tmp/env',
            'render', str(APP / 'render.sh')], env=self.env, capture_output=True, timeout=10)
        self.assertEqual(rendered.returncode, 0)
        keys = set(re.findall(r'^(?:Environment=)?([A-Z_]+)=', rendered.stdout.decode(), re.M))
        self.assertTrue(keys <= CONTROL_NAMES, keys - CONTROL_NAMES)
        for name in ('DEVMON_SLACK_WEBHOOK', 'SHARED_HOOK', 'DEV_MONITOR_SMTP_PASSWORD',
                     'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT'):
            validate_names(name)
        self.configure('urgent')
        self.config.write_text(self.config.read_text().replace('REGRESSION_HOOK', 'DEVMON_SLACK_WEBHOOK'))
        self.file.write_text('DEVMON_SLACK_WEBHOOK=https://hooks.example.test/synthetic\n')
        self.file.chmod(0o600)
        installed = subprocess.run(['bash', str(APP / 'install.sh')], env=self.env,
                                   capture_output=True, timeout=45)
        self.assertEqual(installed.returncode, 0)
        runtime = dict(self.env, DEVMON_SLACK_WEBHOOK='https://hooks.example.test/synthetic')
        for line in (self.root / 'render/files/dev-monitor.env').read_text().splitlines():
            if line and not line.startswith('#'):
                key, value = line.split('=', 1)
                runtime[key] = value.strip('"')
        probe = subprocess.run([sys.executable, '-c',
            'import runpy,sys; m=runpy.run_path(sys.argv[1]); '
            'from unittest.mock import patch; '
            '\nwith patch("devmon_slack.send") as send:\n'
            ' m["_slack_sender"]()("hello"); '
            'send.assert_called_once_with("https://hooks.example.test/synthetic", "hello")\n'
            'print("single webhook default resolved")', str(APP / 'backend/airlock-dev-monitor.py')],
            env=runtime, capture_output=True, timeout=10)
        self.assertEqual(probe.returncode, 0, probe.stderr.decode())
        print('CONTROL: emitted names covered; default Slack accepted; selected control names refused', flush=True)

    def start(self, command, env, label):
        log = (self.root / (label + '.log')).open('wb')
        self.addCleanup(log.close)
        process = subprocess.Popen(command, env=env, stdout=log, stderr=subprocess.STDOUT)
        def stop():
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
        self.addCleanup(stop)
        return process

    def check_public_smoke_and_health_for_each_supported_lane(self):
        class Recorder(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers['Content-Length']))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'ok')
            def log_message(self, *args):
                pass
        recorder = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Recorder)
        self.addCleanup(recorder.server_close)
        self.addCleanup(recorder.shutdown)
        threading.Thread(target=recorder.serve_forever, daemon=True).start()
        hook = f'http://127.0.0.1:{recorder.server_port}/synthetic-hook'
        nginx = shutil.which('nginx') or '/usr/sbin/nginx'
        self.assertTrue(Path(nginx).is_file(), 'nginx is required for the scratch smoke regression')
        for lane in ('urgent', 'legacy'):
            with self.subTest(lane=lane):
                self.configure(lane)
                self.assertEqual(self.install('"' + hook + '"').returncode, 0)
                generated = self.root / 'render/files/dev-monitor.env'
                (self.private / 'dev-monitor.env').write_bytes(generated.read_bytes())
                (self.private / 'dev-monitor.env').chmod(0o600)
                runtime = dict(self.env, **{self.hook_name: hook},
                               AIRLOCK_DEV_MONITOR_MESSAGES='true',
                               AIRLOCK_DEV_MONITOR_BACKEND_PORT=str(self.backend_port))
                for line in generated.read_text().splitlines():
                    if line and not line.startswith('#'):
                        key, value = line.split('=', 1)
                        runtime[key] = value.strip('"')
                state = self.home / '.local/state/airlock/dev-monitor'
                for path, mode in ((state, 0o710), (state / 'spool', 0o710),
                                   *[(state / 'spool' / name, mode) for name, mode in
                                     {'new': 0o3770, 'tmp': 0o3770, 'processing': 0o700, 'bad': 0o700}.items()]):
                    path.mkdir(parents=True, exist_ok=True)
                    path.chmod(mode)
                backend = self.start([sys.executable, str(APP / 'backend/airlock-dev-monitor.py')], runtime, lane)
                nginx_process = None
                try:
                    for _ in range(150):
                        try:
                            with urllib.request.urlopen(f'http://127.0.0.1:{self.backend_port}/api/health', timeout=2) as response:
                                health = json.load(response)
                            break
                        except OSError:
                            time.sleep(.1)
                    else:
                        self.fail('backend startup timeout')
                    self.assertEqual(health['slack'], 'configured')
                    # Run smoke even if scalar health is wrong, so both review findings reproduce.
                    nginx_config = self.root / 'nginx.conf'
                    fragment = self.root / 'render/confd/hub-locations.d/dev-monitor.conf'
                    (self.root / 'monitor').mkdir(exist_ok=True)
                    (self.root / 'monitor/index.html').write_text('scratch dashboard')
                    nginx_config.write_text(f'''daemon off;
master_process off;
pid {self.root}/nginx.pid;
error_log {self.root}/nginx.log;
events {{}}
http {{
 access_log off;
 client_body_temp_path {self.root}/client-body;
 proxy_temp_path {self.root}/proxy;
 server {{
  listen 127.0.0.1:{self.hub_port};
  root {self.root};
  if ($http_tailscale_user_login != "owner@example.test") {{ return 403; }}
  include {fragment};
  # Observation sampling is outside these message regressions.
  location = /monitor/api/cron/jobs {{ return 200 '{{"schemaVersion":3,"jobs":[],"counts":{{}},"sources":["scratch"]}}'; }}
 }}
}}
''')
                    nginx_process = self.start([nginx, '-c', str(nginx_config), '-p', str(self.root)], self.env, 'nginx-' + lane)
                    for _ in range(100):
                        try:
                            with socket.create_connection(('127.0.0.1', self.hub_port), timeout=.2):
                                break
                        except OSError:
                            time.sleep(.05)
                    smoke = subprocess.run(['bash', str(ROOT / 'bin/airlock-smoke')], env=self.env,
                                           capture_output=True, timeout=60)
                    output = smoke.stdout + smoke.stderr
                    print(f'REGRESSION {lane}: worker=on; slack={health["slack"]}; smoke_rc={smoke.returncode}', flush=True)
                    self.assertEqual(health['slack'], 'configured')
                    self.assertEqual(smoke.returncode, 3, output.decode())  # explicit scratch ingress skip
                    self.assertIn(b'delivery: single Slack configuration/outbox shape ok', output)
                    self.assertNotIn(hook.encode(), output)
                    # Same CLI must detect missing configured input against a still-running worker.
                    self.file.write_text(self.hook_name + '="   "\n')
                    negative = subprocess.run(['bash', str(ROOT / 'bin/airlock-smoke')], env=self.env,
                                              capture_output=True, timeout=60)
                    self.assertEqual(negative.returncode, 1)
                    self.assertIn(b'FAIL delivery health shape mismatch', negative.stdout + negative.stderr)
                    if lane == 'legacy':
                        # A selected-but-missing target must not borrow the present
                        # legacy value; the unchanged running worker is the negative control.
                        self.file.write_text(self.hook_name + '=' + hook + '\n')
                        (self.private / 'dev-monitor.env').write_text(generated.read_text().replace(
                            'DEVMON_SLACK_WEBHOOK_NAME=\n', 'DEVMON_SLACK_WEBHOOK_NAME=MISSING_TARGET\n'))
                        missing = subprocess.run(['bash', str(ROOT / 'bin/airlock-smoke')], env=self.env,
                                                 capture_output=True, timeout=60)
                        self.assertEqual(missing.returncode, 1)
                        self.assertIn(b'FAIL delivery health shape mismatch', missing.stdout + missing.stderr)
                        print('SMOKE LEGACY: blank selector + file legacy passes; blank value/missing selected target refuse', flush=True)
                finally:
                    if nginx_process is not None:
                        nginx_process.terminate()
                        nginx_process.wait(timeout=10)
                    backend.terminate()
                    backend.wait(timeout=10)


if __name__ == '__main__':
    live = '--systemd' in sys.argv
    if live: sys.argv.remove('--systemd')
    if live:
        SecretRegressionTest.test_public_smoke_and_health_for_each_supported_lane = (
            SecretRegressionTest.check_public_smoke_and_health_for_each_supported_lane)
    else:
        print('SYSTEMD smoke semantics: NOT RUN (use --systemd)', flush=True)
    unittest.main()
