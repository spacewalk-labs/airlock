#!/usr/bin/env python3
"""Run the real ledger against scratch records/files and a stateful systemctl.

No live manager, sudo, network or app lifecycle. The shim models reactivation,
linked-fragment removal and injected failures; assertions inspect files, the
persisted ledger and the command trace, not helper return values alone.
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
        for name in ('sudo', 'systemctl'):
            (shim / name).write_text(SHIM)
            (shim / name).chmod(0o755)
        env = dict(AIRLOCK_STATE_DIR=str(self.root / 'state'),
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
        record = dict(path=str(self.root / 'missing-package'), digest='f' * 64,
                      lifecycle=dict(install=False, smoke=False, deactivate=False), deps=[],
                      artifacts=self.artifacts, roots=self.roots,
                      unit_scopes={Path(p).name: scope for p in paths},
                      serve_mappings={}, order=None, source_class='explicit', capabilities=self.caps)
        # Deliberately use an old record and service-first artifact order.
        self.store = dict(version=4, entries={'probe': {'committed': record}})
        ledger.write_store(self.store)
        self.before = ledger.ledger_path().read_bytes()
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

    def teardown(self, *, remove=False):
        output = io.StringIO()
        with contextlib.redirect_stderr(output):
            try:
                if remove:
                    result = ledger.command_remove(self.store, {'packages': {}}, 'probe', False, None)
                else:
                    result = ledger.command_teardown(self.store, {'packages': {}}, 'probe', None)
            except ledger.LedgerError as exc:
                output.write(str(exc))
                result = 1
        self.output = output.getvalue()
        return result

    def assert_preserved(self, paths):
        self.assertEqual(self.teardown(), 1)
        self.assertEqual(ledger.ledger_path().read_bytes(), self.before)
        self.assertTrue(all(os.path.lexists(p) for p in paths))
        self.assertTrue(Path(self.artifacts['files'][0]).exists())
        self.assertFalse(any(e['action'] in ('disable', 'daemon-reload') for e in self.trace()))
        self.assertIn('kept', self.output)

    def test_old_service_first_record_race_and_reinstall_round_trip(self):
        for cycle in range(2):
            with self.subTest(cycle=cycle):
                paths = self.fixture()
                self.assertEqual(self.teardown(), 0, self.output)
                self.assertFalse(any(os.path.lexists(p) for p in paths))
                self.assertNotIn('probe', json.loads(ledger.ledger_path().read_text())['entries'])
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

    def test_each_stop_error_preserves_all_fragments_and_record(self):
        for suffix in ('timer', 'socket', 'path', 'service'):
            with self.subTest(suffix=suffix):
                paths = self.fixture()
                (self.root / 'trace.jsonl').unlink(missing_ok=True)
                self.fault('stop', suffix)
                self.assert_preserved(paths)
                self.assertIn('failed with exit 7', self.output)

    def test_each_lying_stop_preserves_all_fragments_and_record(self):
        for suffix in ('timer', 'socket', 'path', 'service'):
            with self.subTest(suffix=suffix):
                paths = self.fixture()
                (self.root / 'trace.jsonl').unlink(missing_ok=True)
                self.fault('stop', suffix, 'lie')
                self.assert_preserved(paths)
                self.assertIn('not proven stopped', self.output)

    def test_query_faults_after_stop_and_at_final_barrier(self):
        for suffix in ('timer', 'socket', 'path', 'service'):
            for nth in (1, 2):
                for effect in ('error', 'empty', 'bad-load', 'unstable'):
                    with self.subTest(suffix=suffix, nth=nth, effect=effect):
                        paths = self.fixture()
                        (self.root / 'trace.jsonl').unlink(missing_ok=True)
                        self.fault('show', suffix, effect, nth)
                        self.assert_preserved(paths)

    def test_service_pid_and_control_process_must_be_zero(self):
        for effect in ('pid', 'control'):
            with self.subTest(effect=effect):
                paths = self.fixture()
                (self.root / 'trace.jsonl').unlink(missing_ok=True)
                self.fault('stop', effect=effect)
                self.assert_preserved(paths)
        paths = self.fixture()
        (self.root / 'trace.jsonl').unlink(missing_ok=True)
        self.fault('show', effect='missing-pid')
        self.assert_preserved(paths)

    def test_failed_service_requires_explicitly_empty_control_group(self):
        for cgroup, allowed in (('', True),
                                ('/user.slice/residual.service', False),
                                (None, False)):
            with self.subTest(cgroup=cgroup, allowed=allowed):
                paths = self.fixture(suffixes=('service',))
                (self.root / 'trace.jsonl').unlink(missing_ok=True)
                unit = self.manager['units']['user:probe.service']
                unit.update(active='failed', pid='0', control='0')
                if cgroup is not None:
                    unit['cgroup'] = cgroup
                self.fault('stop', effect='lie')
                self.save_manager()
                if allowed:
                    self.assertEqual(self.teardown(), 0, self.output)
                    self.assertFalse(os.path.lexists(paths[0]))
                else:
                    self.assert_preserved(paths)

    def test_final_barrier_detects_reactivated_trigger(self):
        paths = self.fixture()
        self.fault('stop', effect='reactivate')
        self.assert_preserved(paths)

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

    def test_absent_unit_query_failure_preserves_record(self):
        self.fixture(absent=True)
        self.fault('show', 'path')
        self.assert_preserved([])

    def test_linked_fragments_survive_stop_failure_and_cleanup_succeeds(self):
        paths = self.fixture(linked=True)
        self.fault('stop')
        self.assert_preserved(paths)
        self.manager = json.loads((self.root / 'manager.json').read_text())
        self.manager['faults'] = []
        self.save_manager()
        self.assertEqual(self.teardown(), 0, self.output)
        self.assertFalse(any(os.path.lexists(p) for p in paths))
        self.assertTrue(all((self.root / ('source.' + suffix)).exists()
                            for suffix in ('service', 'timer', 'socket', 'path')))

    def test_disable_failure_retains_failed_fragment_and_record_then_retries(self):
        paths = self.fixture()
        self.fault('disable')
        self.assertEqual(self.teardown(), 1)
        self.assertTrue(Path(paths[0]).exists())
        self.assertFalse(any(os.path.lexists(p) for p in paths[1:]))
        self.assertEqual(ledger.ledger_path().read_bytes(), self.before)
        self.assertIn('no explicit fragment removal attempted', self.output)
        self.manager = json.loads((self.root / 'manager.json').read_text())
        self.manager['faults'] = []
        self.save_manager()
        self.assertEqual(self.teardown(), 0, self.output)

    def test_partial_linked_disable_failure_keeps_record_and_retries(self):
        paths = self.fixture(linked=True)
        self.fault('disable', effect='unlink-error')
        self.assertEqual(self.teardown(), 1)
        self.assertFalse(os.path.lexists(paths[0]))
        self.assertEqual(ledger.ledger_path().read_bytes(), self.before)
        self.assertIn('may already have removed links', self.output)
        self.manager = json.loads((self.root / 'manager.json').read_text())
        self.manager['faults'] = []
        self.save_manager()
        self.assertEqual(self.teardown(), 0, self.output)

    def test_system_scope_uses_sudo_and_claim_refusal_precedes_commands(self):
        paths = self.fixture(scope='system')
        self.assertEqual(self.teardown(), 0, self.output)
        sudo = [json.loads(line) for line in (self.root / 'sudo.log').read_text().splitlines()]
        self.assertTrue(any(a[:2] == ['systemctl', 'stop'] for a in sudo))
        self.assertTrue(any(a[0] == 'rm' for a in sudo))
        self.fixture(scope='system')
        (self.root / 'trace.jsonl').unlink()
        self.store['entries']['probe']['committed']['capabilities'] = []
        self.assertEqual(self.teardown(), 1)
        self.assertTrue(all(Path(p).exists() for p in paths))
        self.assertEqual(self.trace(), [])

    def test_system_remove_false_success_keeps_fragment_and_record(self):
        paths = self.fixture(suffixes=('service',), scope='system')
        marker = self.root / 'rm-false-success'
        marker.touch()
        self.assertEqual(self.teardown(), 1)
        self.assertTrue(Path(paths[0]).exists())
        self.assertEqual(ledger.ledger_path().read_bytes(), self.before)
        self.assertIn('still exists after removal', self.output)
        marker.unlink()
        self.assertEqual(self.teardown(), 0, self.output)

    def test_no_units_and_dry_run_do_not_call_systemctl(self):
        self.fixture(suffixes=())
        self.assertEqual(self.teardown(), 0, self.output)
        self.assertEqual(self.trace(), [])
        paths = self.fixture()
        with patch.dict(os.environ, AIRLOCK_DRY_RUN='1'):
            self.assertEqual(self.teardown(), 0, self.output)
        self.assertEqual(ledger.ledger_path().read_bytes(), self.before)
        self.assertTrue(all(Path(p).exists() for p in paths))
        self.assertEqual(self.trace(), [])

    def split_intent(self, *, system=False, duplicate=False):
        committed = self.store['entries']['probe']['committed']
        paths = list(committed['artifacts']['units'])
        committed['artifacts']['units'] = paths[:1]
        committed['unit_scopes'] = {Path(paths[0]).name: 'user'}
        timer = Path(paths[1])
        if system:
            replacement = Path(self.roots['unit_system']) / timer.name
            timer.rename(replacement)
            unit = self.manager['units'].pop('user:' + timer.name)
            unit['path'] = str(replacement)
            self.manager['units']['system:' + timer.name] = unit
            self.manager['paths'][1] = str(replacement)
            timer = replacement
        if duplicate:
            committed['artifacts']['units'].append(str(timer))
            committed['unit_scopes'][timer.name] = 'user'
        declared = {name: [] for name in ledger.ARTIFACT_CLASSES}
        declared['units'] = [timer.name]
        intent = {key: value for key, value in committed.items()
                  if key not in ('artifacts', 'unit_scopes')}
        intent.update(artifacts_declared=declared, serve_port_values={}, anchors={},
                      capabilities=['system-unit'] if system else [],
                      unit_scopes={timer.name: 'system' if system else 'user'})
        self.store['entries']['probe']['intent'] = intent
        ledger.write_store(self.store)
        self.before = ledger.ledger_path().read_bytes()
        self.save_manager()
        return [paths[0], str(timer)]

    def test_committed_intent_union_stops_before_either_record_deletes(self):
        for remove in (False, True):
            with self.subTest(remove=remove):
                self.fixture(suffixes=('service', 'timer'))
                (self.root / 'trace.jsonl').unlink(missing_ok=True)
                paths = self.split_intent(system=True)
                # Missing package forces generic recorded teardown in remove too.
                self.store['entries']['probe']['committed']['lifecycle']['deactivate'] = True
                self.assertEqual(self.teardown(remove=remove), 0, self.output)
                stops = [(e['scope'], e['name']) for e in self.trace() if e['action'] == 'stop']
                self.assertEqual(stops, [('system', 'probe.timer'), ('user', 'probe.service')])
                self.assertFalse(any(os.path.lexists(p) for p in paths))
                reloads = [e['scope'] for e in self.trace() if e['action'] == 'daemon-reload']
                self.assertEqual(sorted(reloads), ['system', 'user'])

    def test_either_records_missing_claim_prevents_all_commands(self):
        for bad_record in ('committed', 'intent'):
            for remove in (False, True):
                with self.subTest(bad_record=bad_record, remove=remove):
                    self.fixture(suffixes=('service', 'timer'))
                    (self.root / 'trace.jsonl').unlink(missing_ok=True)
                    paths = self.split_intent(system=True)
                    entry = self.store['entries']['probe']
                    if bad_record == 'committed':
                        entry['committed']['artifacts']['units'] = [paths[1]]
                        entry['committed']['unit_scopes'] = {'probe.timer': 'system'}
                    else:
                        entry['intent']['capabilities'] = []
                    entry['committed']['lifecycle']['deactivate'] = True
                    self.assertEqual(self.teardown(remove=remove), 1)
                    self.assertEqual(self.trace(), [])
                    self.assertTrue(all(Path(p).exists() for p in paths))
                    self.assertEqual(ledger.ledger_path().read_bytes(), self.before)

    def test_duplicate_unit_stops_and_disables_once(self):
        self.fixture(suffixes=('service', 'timer'))
        self.split_intent(duplicate=True)
        self.assertEqual(self.teardown(), 0, self.output)
        for action in ('stop', 'disable'):
            self.assertEqual(sum(e['action'] == action and e['name'] == 'probe.timer'
                                 for e in self.trace()), 1)

    def test_same_basename_in_two_scopes_remains_distinct(self):
        self.fixture(suffixes=('service', 'timer'))
        self.split_intent(system=True)
        user_timer = Path(self.roots['unit_user']) / 'probe.timer'
        user_timer.write_text('[Unit]\nDescription=user timer\n')
        committed = self.store['entries']['probe']['committed']
        committed['artifacts']['units'].append(str(user_timer))
        committed['unit_scopes']['probe.timer'] = 'user'
        self.manager['paths'].append(str(user_timer))
        self.manager['units']['user:probe.timer'] = dict(
            path=str(user_timer), load='loaded', active='active', pid='0', control='0')
        self.save_manager()
        self.assertEqual(self.teardown(), 0, self.output)
        for action in ('stop', 'disable'):
            scopes = [e['scope'] for e in self.trace()
                      if e['action'] == action and e['name'] == 'probe.timer']
            self.assertEqual(sorted(scopes), ['system', 'user'])

    def test_split_record_stop_failure_preserves_both_records_and_fragments(self):
        self.fixture(suffixes=('service', 'timer'))
        paths = self.split_intent(system=True)
        self.fault('stop', 'timer', scope='system')
        self.assert_preserved(paths)

    def test_reload_failure_after_removal_keeps_record_and_retries(self):
        paths = self.fixture()
        self.manager['faults'] = [dict(action='daemon-reload', key='user:', effect='error')]
        self.save_manager()
        self.assertEqual(self.teardown(), 1)
        self.assertFalse(any(os.path.lexists(p) for p in paths))
        self.assertEqual(ledger.ledger_path().read_bytes(), self.before)
        self.assertIn('daemon-reload failed with exit 7', self.output)
        # The absent fragments must not suppress the retry's scope reload.
        (self.root / 'trace.jsonl').unlink()
        self.assertEqual(self.teardown(), 0, self.output)
        self.assertEqual(sum(e['action'] == 'daemon-reload' for e in self.trace()), 1)

    def test_other_artifact_errors_are_aggregated_after_units_stop(self):
        self.fixture(suffixes=())
        called = []
        def remove(path, dry):
            called.append(path)
            return False
        self.artifacts['fragments'] = [str(self.root / 'fragment')]
        with patch.object(ledger, '_remove_artifact_path', side_effect=remove):
            self.assertEqual(self.teardown(), 1)
        self.assertEqual(set(called), {self.artifacts['files'][0], self.artifacts['fragments'][0]})
        self.assertEqual(ledger.ledger_path().read_bytes(), self.before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
