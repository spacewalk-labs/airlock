#!/usr/bin/env python3
"""Run the real ledger against scratch records/files and a stateful systemctl.

No live manager, sudo, network or app lifecycle. The shim models reactivation,
linked-fragment removal and injected failures; assertions inspect files, the
persisted ledger and the command trace, not helper return values alone.

The installed-state engine reports residue with a failing exit status while
preserving its recorded-path-only removal boundary.
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader(
    "ledger_teardown_test", os.environ.get("LEDGER_TEST_TOOL", str(ROOT / "bin/airlock-ledger")))
spec = importlib.util.spec_from_loader(loader.name, loader)
ledger = importlib.util.module_from_spec(spec)
loader.exec_module(ledger)

SHIM = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['LEDGER_TEST_TMP'])
args = sys.argv[1:]
if Path(sys.argv[0]).name == 'tailscale':
    with (root / 'ingress-trace.jsonl').open('a') as f:
        f.write(json.dumps(args) + '\n')
    mappings = json.loads((root / 'serve.json').read_text())
    assert args[0] == 'serve' and args[-1] == 'off', args
    mode, port = args[1][2:].split('=')
    mappings.pop(mode + ':' + port, None)
    (root / 'serve.json').write_text(json.dumps(mappings))
    sys.exit(0)
if Path(sys.argv[0]).name == 'sudo':
    with (root / 'sudo.log').open('a') as f:
        f.write(json.dumps(args) + '\n')
    if args[0] == 'rm' and (root / 'rm-false-success').exists():
        sys.exit(0)
    os.execvp(args[0], args)
scope = 'user' if '--user' in args else 'system'
args = [a for a in args if a != '--user']
action = args[0]
name = next((a for a in args[1:] if not a.startswith('--')), '')
s = json.loads((root / 'manager.json').read_text())
key = scope + ':' + name
unit = s['units'].get(key)
count_key = action + ':' + key
s['calls'][count_key] = s['calls'].get(count_key, 0) + 1
fault = next((f['effect'] for f in s['faults']
              if f['action'] == action and f['key'] == key
              and f.get('nth', 1) == s['calls'][count_key]), '')
with (root / 'trace.jsonl').open('a') as f:
    f.write(json.dumps({'scope': scope, 'action': action, 'name': name,
                        'args': args, 'units': s['units'],
                        'fragments': [p for p in s['paths'] if os.path.lexists(p)]}) + '\n')
rc = 0
if fault == 'error':
    rc = 7
elif action == 'stop':
    if unit is None:
        rc = 5
    elif fault != 'lie':
        unit.update(active='inactive', pid='0', control='0')
        if name.endswith('.service') and any(
                u['active'] == 'active' and k.endswith(('.timer', '.socket', '.path'))
                for k, u in s['units'].items()):
            unit.update(active='active', pid='42')
    if fault == 'pid':
        unit.update(active='inactive', pid='42')
    if fault == 'control':
        unit.update(active='inactive', control='43')
    if fault == 'reactivate':
        next(u for k, u in s['units'].items() if k.endswith('.timer'))['active'] = 'active'
elif action == 'show':
    u = unit or dict(load='not-found', active='inactive', pid='0', control='0')
    if fault == 'reactivate':
        u.update(active='active', pid='42')
    if fault != 'empty':
        print('LoadState=' + ('error' if fault == 'bad-load' else u['load']))
        print('ActiveState=' + ('activating' if fault == 'unstable' else u['active']))
        if name.endswith('.service') and fault != 'missing-pid':
            print('MainPID=' + u['pid'])
            print('ControlPID=' + u['control'])
            if 'cgroup' in u:
                print('ControlGroup=' + u['cgroup'])
elif action == 'disable':
    # Legacy disable --now stops, but a still-active trigger can restart service.
    if unit and '--now' in args:
        unit.update(active='inactive', pid='0', control='0')
        if name.endswith('.service') and any(
                u['active'] == 'active' and k.endswith(('.timer', '.socket', '.path'))
                for k, u in s['units'].items()):
            unit.update(active='active', pid='42')
    # Without --no-reload a real disable also reloads; retain the argv oracle.
    # A linked fragment is removed by disable itself, even on partial failure.
    if unit and Path(unit['path']).is_symlink():
        Path(unit['path']).unlink()
    if fault == 'unlink-error':
        rc = 7
elif action == 'daemon-reload':
    pass
else:
    raise AssertionError('unexpected systemctl call: ' + repr(args))
(root / 'manager.json').write_text(json.dumps(s))
sys.exit(rc)
'''


class TeardownTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ledger-teardown-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.roots = {key: str(self.root / key) for key in
                      ('unit_user', 'unit_system', 'confd', 'webroot', 'home')}
        for directory in self.roots.values():
            Path(directory).mkdir()
        shim = self.root / 'shim'
        shim.mkdir()
        for name in ('sudo', 'systemctl', 'tailscale'):
            (shim / name).write_text(SHIM)
            (shim / name).chmod(0o755)
        (shim / 'nginx').write_text('#!/bin/sh\nexit 0\n')
        (shim / 'nginx').chmod(0o755)
        (self.root / 'serve.json').write_text('{}')
        env = dict(AIRLOCK_STATE_DIR=str(self.root / 'state'),
                   AIRLOCK_FIXTURE_ROOT=str(self.root),
                   AIRLOCK_DATA_DIR=str(self.root / 'data'),
                   AIRLOCK_NGINX_SITE=str(self.root / 'site/airlock.conf'),
                   AIRLOCK_UNIT_DIR_USER=self.roots['unit_user'],
                   AIRLOCK_UNIT_DIR_SYSTEM=self.roots['unit_system'],
                   AIRLOCK_CONFD=self.roots['confd'], AIRLOCK_WEBROOT=self.roots['webroot'],
                   HOME=self.roots['home'], AIRLOCK_DRY_RUN='0',
                   LEDGER_TEST_TMP=str(self.root), PATH=str(shim) + ':' + os.environ['PATH'])
        self.env = patch.dict(os.environ, env)
        self.env.start()
        self.addCleanup(self.env.stop)

    def fixture(self, suffixes=('service', 'timer', 'socket', 'path'), *,
                scope='user', absent=False, linked=False, inactive=False):
        units = {}
        paths = []
        for suffix in suffixes:
            path = Path(self.roots['unit_' + scope]) / ('probe.' + suffix)
            paths.append(str(path))
            if not absent:
                if linked:
                    target = self.root / ('source.' + suffix)
                    target.write_text('[Unit]\nDescription=scratch\n')
                    path.symlink_to(target)
                else:
                    path.write_text('[Unit]\nDescription=scratch\n')
                units[scope + ':' + path.name] = dict(
                    path=str(path), load='loaded', active='inactive' if inactive else 'active',
                    pid='0' if inactive or suffix != 'service' else '42', control='0')
        self.manager = dict(units=units, paths=paths, calls={}, faults=[])
        self.save_manager()
        self.artifacts = {name: [] for name in ledger.ARTIFACT_CLASSES}
        self.artifacts['units'] = paths
        marker = self.root / 'other-artifact'
        marker.write_text('keep until all units stop\n')
        self.artifacts['files'] = [str(marker)]
        self.caps = ['system-unit'] if scope == 'system' else []
        self.store = {'probe': {'repo': str(self.root / 'missing-package'),
                                'commit': '', 'artifacts': paths + [str(marker)]}}
        ledger.write_installed(self.store)
        self.before = ledger.installed_path().read_bytes()
        return paths

    def save_manager(self):
        (self.root / 'manager.json').write_text(json.dumps(self.manager))

    def fault(self, action, suffix='service', effect='error', nth=1, scope='user'):
        self.manager['faults'].append(dict(action=action, key=scope + ':probe.' + suffix,
                                           effect=effect, nth=nth))
        self.save_manager()

    def trace(self):
        path = self.root / 'trace.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def teardown(self, *, api='remove'):
        output = io.StringIO()
        with contextlib.redirect_stderr(output), patch.object(ledger, 'project') as project:
            try:
                result = (ledger.command_remove('probe') if api == 'remove'
                          else ledger.teardown_installed())
            except ledger.LedgerError as exc:
                output.write(str(exc))
                result = 1
        self.project_calls = project.call_count
        self.output = output.getvalue()
        return result

    def test_split_rows_stop_all_activation_units_before_services(self):
        paths = self.fixture(suffixes=('service', 'timer'))
        ledger.write_installed({
            'a-service': dict(self.store['probe'], artifacts=[paths[0]]),
            'z-timer': dict(self.store['probe'], artifacts=[paths[1]]),
            '../metadata': 'uninterpreted',
            'opaque': {'operator_note': 'preserve'},
        })
        self.assertEqual(self.teardown(api='teardown'), 0, self.output)
        self.assertFalse(any(Path(path).exists() for path in paths))
        stops = [event['name'] for event in self.trace() if event['action'] == 'stop']
        self.assertEqual(stops, ['probe.timer', 'probe.service'])
        self.assertEqual(ledger.load_installed(), {
            '../metadata': 'uninterpreted', 'opaque': {'operator_note': 'preserve'}})

    def test_uninterpretable_artifact_keeps_row_after_safe_cleanup(self):
        for api in ('remove', 'teardown', 'core'):
            with self.subTest(api=api):
                paths = self.fixture(suffixes=('service', 'timer'))
                self.store['probe']['repo'] = str(self.root / 'apps/probe')
                self.store['probe']['artifacts'].append(None)
                ledger.write_installed(self.store)
                if api == 'core':
                    with patch.object(ledger, 'project'):
                        result = ledger.teardown_installed(core_root=self.root)
                else:
                    result = self.teardown(api=api)
                self.assertEqual(result, 1)
                self.assertFalse(any(Path(path).exists() for path in paths))
                self.assertFalse((self.root / 'other-artifact').exists())
                self.assertEqual(ledger.load_installed(), self.store)

    def test_shrink_id_spelling_and_unit_glob_expand_to_literal_targets(self):
        paths = self.fixture()
        declared = {name: [] for name in ledger.ARTIFACT_CLASSES}
        declared['units'] = ['probe.*']
        expanded = ledger.expand_declared(declared, {},
                                          unit_scopes={'probe.*': 'user'})
        self.assertEqual(expanded['units'], sorted(paths))
        app_id = 'Alpha_' + 'x' * 40
        ledger.write_installed({app_id: dict(self.store['probe'], artifacts=expanded['units'])})
        with patch.object(ledger, 'project'):
            self.assertEqual(ledger.command_remove(app_id), 0)
        self.assertFalse(any(Path(path).exists() for path in paths))
        self.assertEqual(ledger.load_installed(), {})
        self.assertTrue(all('*' not in event['name'] for event in self.trace()))

    def test_shrink_unsafe_resource_does_not_block_safe_cleanup(self):
        paths = self.fixture()
        outside = self.root / 'outside'
        outside.mkdir()
        external = outside / 'operator.js'
        external.write_text('operator data')
        webroot = Path(self.roots['webroot'])
        (webroot / 'redirect').symlink_to(outside, target_is_directory=True)
        safe = webroot / 'safe.js'
        safe.write_text('owned')
        declared = {name: [] for name in ledger.ARTIFACT_CLASSES}
        declared['webroot'] = ['redirect/*', 'safe.js']
        expanded = ledger.expand_declared(declared, {})
        self.assertEqual(expanded['webroot'], [str(safe)])
        unsafe_unit = Path(self.roots['unit_user']) / '*.service'
        unsafe_unit.write_text('uninterpreted')
        self.store['probe']['artifacts'] += [str(safe), str(unsafe_unit), 'relative']
        ledger.write_installed(self.store)
        self.assertEqual(self.teardown(), 1, self.output)
        self.assertTrue(unsafe_unit.exists())
        self.assertEqual(external.read_text(), 'operator data')
        self.assertFalse(safe.exists())
        self.assertFalse((self.root / 'other-artifact').exists())
        self.assertFalse(any(Path(path).exists() for path in paths))
        self.assertIn('probe', ledger.load_installed())
        self.assertTrue(all('*' not in event['name'] for event in self.trace()))

    def test_old_service_first_record_race_and_reinstall_round_trip(self):
        for cycle in range(2):
            with self.subTest(cycle=cycle):
                paths = self.fixture()
                self.assertEqual(self.teardown(), 0, self.output)
                self.assertFalse(any(os.path.lexists(p) for p in paths))
                self.assertNotIn('probe', json.loads(ledger.installed_path().read_text()))
                events = self.trace()
                stops = [e['name'] for e in events if e['action'] == 'stop']
                self.assertEqual(stops[-4:], ['probe.path', 'probe.socket', 'probe.timer', 'probe.service'])
                for event in events:
                    if event['action'] == 'disable':
                        self.assertIn('--no-reload', event['args'])
                        self.assertNotIn('--now', event['args'])
                        self.assertTrue(all(u['active'] == 'inactive' and u['pid'] == '0'
                                            for u in event['units'].values()))
                first_disable = next(i for i, e in enumerate(events) if e['action'] == 'disable')
                self.assertEqual(len([e for e in events[:first_disable] if e['action'] == 'show']), 8)

    def test_stop_failure_keeps_ownership_until_retry_completes(self):
        for api in ('remove', 'teardown'):
            for action, effect in (('stop', 'error'), ('show', 'reactivate'), ('show', 'empty')):
                with self.subTest(api=api, action=action, effect=effect):
                    paths = self.fixture()
                    self.store['probe']['artifacts'].append('http:45678')
                    ledger.write_installed(self.store)
                    self.before = ledger.installed_path().read_bytes()
                    before_files = {p: Path(p).read_bytes() for p in
                                    paths + self.artifacts['files']}
                    mappings = {'http:45678': 'probe', 'http:9999': 'operator'}
                    (self.root / 'serve.json').write_text(json.dumps(mappings))
                    for name in ('trace.jsonl', 'ingress-trace.jsonl', 'sudo.log'):
                        (self.root / name).unlink(missing_ok=True)
                    self.fault(action, 'service', effect=effect)
                    self.assertEqual(self.teardown(api=api), 1, self.output)
                    self.assertEqual(self.project_calls, 0)
                    self.assertEqual(ledger.installed_path().read_bytes(), self.before)
                    for path, content in before_files.items():
                        self.assertTrue(Path(path).exists(), path)
                        self.assertEqual(Path(path).read_bytes(), content)
                    self.assertEqual(json.loads((self.root / 'serve.json').read_text()), mappings)
                    self.assertFalse(any(e['action'] in ('disable', 'daemon-reload')
                                         for e in self.trace()))
                    self.assertFalse((self.root / 'ingress-trace.jsonl').exists())
                    if action == 'stop':
                        self.assertIn('failed with exit 7', self.output)
                    # Faults fire once; the same API must finish its retry.
                    self.assertEqual(self.teardown(api=api), 0, self.output)
                    self.assertNotIn('probe', ledger.load_installed())
                    self.assertFalse(any(Path(p).exists() for p in before_files))
                    self.assertEqual(json.loads((self.root / 'serve.json').read_text()),
                                     {'http:9999': 'operator'})

    def test_disabled_existing_and_absent_units(self):
        for absent in (False, True):
            with self.subTest(absent=absent):
                paths = self.fixture(absent=absent, inactive=True)
                (self.root / 'trace.jsonl').unlink(missing_ok=True)
                self.assertEqual(self.teardown(), 0, self.output)
                self.assertFalse(any(os.path.lexists(p) for p in paths))
                if absent:
                    self.assertFalse(any(e['action'] in ('stop', 'disable') for e in self.trace()))
                self.assertEqual(sum(e['action'] == 'daemon-reload' for e in self.trace()), 1)

    def test_missing_fragment_with_loaded_service_is_stopped(self):
        paths = self.fixture(suffixes=('service',))
        Path(paths[0]).unlink()
        self.assertEqual(self.teardown(), 0, self.output)
        self.assertTrue(any(e['action'] == 'stop' for e in self.trace()))

    def test_linked_fragments_removed_after_stop(self):
        paths = self.fixture(linked=True)
        self.assertEqual(self.teardown(), 0, self.output)
        self.assertFalse(any(os.path.lexists(p) for p in paths))
        self.assertTrue(all((self.root / ('source.' + suffix)).exists()
                            for suffix in ('service', 'timer', 'socket', 'path')))

    def test_system_scope_uses_sudo(self):
        paths = self.fixture(scope='system')
        self.assertEqual(self.teardown(), 0, self.output)
        sudo = [json.loads(line) for line in (self.root / 'sudo.log').read_text().splitlines()]
        self.assertTrue(any(a[:2] == ['systemctl', 'stop'] for a in sudo))
        self.assertTrue(any(a[0] == 'rm' for a in sudo))

    def test_no_units_and_dry_run_do_not_call_systemctl(self):
        self.fixture(suffixes=())
        self.assertEqual(self.teardown(), 0, self.output)
        self.assertEqual(self.trace(), [])
        paths = self.fixture()
        with patch.dict(os.environ, AIRLOCK_DRY_RUN='1'):
            self.assertEqual(self.teardown(), 0, self.output)
        self.assertEqual(ledger.installed_path().read_bytes(), self.before)
        self.assertTrue(all(Path(p).exists() for p in paths))
        self.assertEqual(self.trace(), [])

    def test_same_basename_in_two_scopes_remains_distinct(self):
        self.fixture(suffixes=('service', 'timer'))
        system_timer = Path(self.roots['unit_system']) / 'probe.timer'
        system_timer.write_text('[Unit]\nDescription=system timer\n')
        self.store['probe']['artifacts'].append(str(system_timer))
        ledger.write_installed(self.store)
        self.manager['paths'].append(str(system_timer))
        self.manager['units']['system:probe.timer'] = dict(
            path=str(system_timer), load='loaded', active='active', pid='0', control='0')
        self.save_manager()
        self.assertEqual(self.teardown(), 0, self.output)
        for action in ('stop', 'disable'):
            scopes = [e['scope'] for e in self.trace()
                      if e['action'] == action and e['name'] == 'probe.timer']
            self.assertEqual(sorted(scopes), ['system', 'user'])

    def test_other_artifact_errors_keep_ownership_until_retry_completes(self):
        self.fixture(suffixes=())
        called = []
        def remove(path, dry):
            called.append(path)
            return False
        self.store['probe']['artifacts'].append(str(self.root / 'fragment'))
        ledger.write_installed(self.store)
        before = ledger.installed_path().read_bytes()
        with patch.object(ledger, '_remove_artifact_path', side_effect=remove), \
                patch.object(ledger, '_remove_rooted_artifact_path', side_effect=remove):
            self.assertEqual(self.teardown(), 1)
        self.assertIn("residue probe:", self.output)
        self.assertEqual(set(called), set(self.store['probe']['artifacts']))
        self.assertEqual(ledger.installed_path().read_bytes(), before)
        self.assertEqual(self.teardown(), 0, self.output)
        self.assertNotIn('probe', ledger.load_installed())


class InstalledRecordTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='installed-record-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = self.root / 'state'
        self.state.mkdir()
        self.row = {'probe': {'repo': str(self.root / 'app'), 'commit': '', 'artifacts': []}}
        self.env = patch.dict(os.environ, AIRLOCK_STATE_DIR=str(self.state))
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_snapshot_and_restore_preserve_new_record_bytes(self):
        raw = json.dumps(self.row, separators=(',', ':')).encode()
        ledger.installed_path().write_bytes(raw)
        snapshot = self.root / 'record.json'
        self.assertTrue(ledger.snapshot_installed(snapshot))
        ledger.write_installed({})
        ledger.restore_installed(snapshot)
        self.assertEqual(ledger.read_installed_bytes(), raw)
        self.assertEqual(ledger.load_installed(), self.row)
        ledger.restore_installed(None)
        self.assertIsNone(ledger.read_installed_bytes())

    def test_v7_read_only_conversion_and_exact_restore(self):
        legacy = {'version': 7, 'entries': {
            'probe': {'committed': {'path': self.row['probe']['repo'],
                                   'artifacts': {'files': [], 'serve_ports': [8448]},
                                   'serve_mappings': {'port': {'mode': 'https', 'listen': 8448,
                                                              'target': 9000}}}},
            'unfinished': {'intent': {'path': '/unused'}},
        }, 'events': []}
        raw = json.dumps(legacy).encode()
        ledger.legacy_ledger_path().write_bytes(raw)
        before = {p.name: p.read_bytes() for p in self.state.iterdir()}
        self.assertEqual(ledger.load_installed()['probe']['artifacts'], ['https:8448'])
        self.assertNotIn('unfinished', ledger.load_installed())
        self.assertEqual({p.name: p.read_bytes() for p in self.state.iterdir()}, before)
        snapshot = self.root / 'record.json'
        ledger.snapshot_installed(snapshot)
        ledger.write_installed(ledger.load_installed())
        self.assertTrue(ledger.legacy_archive_path().exists())
        self.assertFalse(ledger.legacy_ledger_path().exists())
        ledger.restore_installed(snapshot)
        self.assertFalse(ledger.installed_path().exists())
        self.assertEqual(ledger.legacy_ledger_path().read_bytes(), raw)

    def test_version_six_refused_without_mutation(self):
        raw = b'{"version":6,"entries":{},"events":[]}'
        ledger.legacy_ledger_path().write_bytes(raw)
        with self.assertRaises(ledger.LedgerError):
            ledger.load_installed()
        self.assertEqual(ledger.legacy_ledger_path().read_bytes(), raw)
        self.assertFalse(ledger.installed_path().exists())

    def test_leaf_symlink_and_directory_are_refused(self):
        outside = self.root / 'outside.json'
        outside.write_text(json.dumps(self.row))
        path = ledger.installed_path()
        path.symlink_to(outside)
        with self.assertRaises(ledger.LedgerError):
            ledger.read_installed_bytes()
        with self.assertRaises(ledger.LedgerError):
            ledger.restore_installed(None)
        self.assertTrue(path.is_symlink())
        path.unlink()
        path.mkdir()
        with self.assertRaises(ledger.LedgerError):
            ledger.load_installed()

    def test_semantic_helpers_keep_modes_and_unit_scopes(self):
        user = str(self.root / 'user')
        system = str(self.root / 'system')
        with patch.dict(os.environ, AIRLOCK_UNIT_DIR_USER=user, AIRLOCK_UNIT_DIR_SYSTEM=system):
            self.row['probe']['artifacts'] = ['https:8448', 'http:8000',
                                            user + '/probe.service', system + '/probe.timer']
            self.assertEqual(ledger.recorded_active_ports(self.row, mode='http'), {8000})
            self.assertEqual(ledger.recorded_active_ports(self.row, skip_id='probe'), set())
            self.assertEqual(ledger.installed_units(self.row),
                             [('probe.service', 'user'), ('probe.timer', 'system')])


if __name__ == '__main__':
    unittest.main(verbosity=2)
