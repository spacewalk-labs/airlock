#!/usr/bin/env python3
"""Offline checks for the dev-monitor BACKEND — the half test_devmon.py does not reach.

test_devmon.py covers the ported store/spool/owner/slack modules. This covers what the
backend itself adds on top of them: which origins may read a response, what the health
endpoint admits to, and the reaper paths that exist to stop a failed launch from locking
a card forever. Those are exactly the places a bug is invisible until someone is stuck.

    python3 apps/dev-monitor/test-backend.py

No install, no network, no tmux required.
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import subprocess
import time
import types
import unittest
from contextlib import redirect_stderr
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.join(HERE, 'backend')
sys.path.insert(0, BACKEND)
import action_runner
import devmon_cron
import devmon_update_exec as UPX
import devmon_harness as HARNESS


def _load_backend():
    """The backend's filename has a hyphen, so it cannot be imported by name."""
    spec = importlib.util.spec_from_file_location(
        'airlock_dev_monitor', os.path.join(BACKEND, 'airlock-dev-monitor.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DM = _load_backend()
MSG = DM.MSG

# The platform CLI has no .py extension. Importing it runs no command because main()
# is guarded; tests can point its whitelisted raw extractor at scratch credentials.
_status_loader = importlib.machinery.SourceFileLoader(
    'platform_accounts_status', os.path.join(os.path.dirname(HERE), '..', 'bin',
                                             'airlock-accounts-status'))
sys.path.insert(0, os.path.abspath(os.path.join(HERE, '..', '..', 'bin')))
_status_spec = importlib.util.spec_from_loader('platform_accounts_status', _status_loader)
PLATFORM_STATUS = importlib.util.module_from_spec(_status_spec)
_status_loader.exec_module(PLATFORM_STATUS)


class _FakeHandler(DM.Handler):
    """A Handler with just enough of one to answer _cors_origin, and no socket."""

    def __init__(self, origin=None):
        self.headers = {} if origin is None else {'Origin': origin}


class CorsTest(unittest.TestCase):
    """Identity here is injected by the ingress, so an echoed origin can read owner data
    with the owner's authority. The comparison must be against a whole hostname."""

    def setUp(self):
        self._saved = DM.CORS_HOSTS
        DM.CORS_HOSTS = frozenset({'box', 'box.tailnet.example'})

    def tearDown(self):
        DM.CORS_HOSTS = self._saved

    def _origin(self, value):
        return _FakeHandler(value)._cors_origin()

    def test_same_box_any_port_is_echoed(self):
        self.assertEqual(self._origin('https://box.tailnet.example:8443'),
                         'https://box.tailnet.example:8443')
        self.assertEqual(self._origin('http://box:9900'), 'http://box:9900')

    def test_case_is_not_a_boundary(self):
        self.assertEqual(self._origin('https://BOX.Tailnet.Example'), 'https://BOX.Tailnet.Example')

    def test_no_origin_is_not_echoed(self):
        self.assertIsNone(self._origin(None))

    def test_prefix_lookalike_is_refused(self):
        # The bug this test exists for: comparing only the first label let any domain whose
        # first label happened to match the box read the owner's messages.
        self.assertIsNone(self._origin('https://box.attacker.example'))
        self.assertIsNone(self._origin('https://box.tailnet.example.attacker.example'))

    def test_other_node_on_the_same_tailnet_is_refused(self):
        # Tailnet domains are public suffixes, so "same site" is not a boundary here.
        self.assertIsNone(self._origin('https://other.tailnet.example'))

    def test_suffix_lookalike_is_refused(self):
        self.assertIsNone(self._origin('https://notbox.tailnet.example'))
        self.assertIsNone(self._origin('https://evil-box'))

    def test_garbage_origin_is_refused(self):
        for bad in ('', 'null', 'https://', '://x', 'https://[', 'file:///etc/passwd'):
            self.assertIsNone(self._origin(bad), bad)


class MessagesStateTest(unittest.TestCase):
    """The banner and /api/health must report what started, never what was requested."""

    def setUp(self):
        self._saved_owner = DM.OWNER_CONFIG
        self._saved_state = DM._MESSAGES_STATE

    def tearDown(self):
        DM.OWNER_CONFIG = self._saved_owner
        DM._MESSAGES_STATE = self._saved_state

    def test_off_without_a_loaded_config(self):
        DM.OWNER_CONFIG = None
        DM._MESSAGES_STATE = 'off'
        self.assertEqual(DM._messages_state(), 'off')

    def test_loaded_config_alone_does_not_claim_startup_succeeded(self):
        DM.OWNER_CONFIG = {'owner': 'me@example.test', 'secret': 's', 'spool': '/x', 'db': '/y'}
        DM._MESSAGES_STATE = 'off'
        self.assertEqual(DM._messages_state(), 'off')

    def test_on_once_startup_records_success(self):
        DM.OWNER_CONFIG = {'owner': 'me@example.test', 'secret': 's', 'spool': '/x', 'db': '/y'}
        DM._MESSAGES_STATE = 'on'
        self.assertEqual(DM._messages_state(), 'on')


class TmuxProbeTest(unittest.TestCase):
    """A box with no tmux must be distinguishable from a session that is simply absent."""

    def test_missing_binary_is_unknown_not_absent(self):
        saved = DM.subprocess.call
        try:
            DM.subprocess.call = lambda *a, **k: (_ for _ in ()).throw(FileNotFoundError('tmux'))
            self.assertIsNone(DM._tmux_has_session('anything'))
        finally:
            DM.subprocess.call = saved

    def test_exit_one_means_definitely_absent(self):
        saved = DM.subprocess.call
        try:
            DM.subprocess.call = lambda *a, **k: 1
            self.assertEqual(DM._tmux_has_session('anything'), 1)
        finally:
            DM.subprocess.call = saved

    def test_alive_keys_are_unknown_when_tmux_is_unreachable(self):
        # None here means "do not reap"; an empty set would mean "reap everything".
        saved_tmux, saved_call = DM._tmux, DM.subprocess.call
        try:
            DM._tmux = lambda *a, **k: None
            DM.subprocess.call = lambda *a, **k: (_ for _ in ()).throw(FileNotFoundError('tmux'))
            self.assertIsNone(DM._exec_alive_keys('devmon-exec'))
        finally:
            DM._tmux, DM.subprocess.call = saved_tmux, saved_call


class _ExecBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = self.tmp.name
        self.cwd = os.path.join(root, 'project')
        os.makedirs(self.cwd)
        MSG.init_db(os.path.join(root, 'messages.db'))
        self._saved_exec, self._saved_owner = DM.EXEC_CONFIG, DM.OWNER_CONFIG
        DM.EXEC_CONFIG = {
            'cwd_root': root,
            'session': 'devmon-test',
            'runner': os.path.join(BACKEND, 'action_runner.py'),
            'plan_dir': os.path.join(root, 'plans'),
            'sentinel_dir': os.path.join(root, 'sentinels'),
        }
        for key in ('plan_dir', 'sentinel_dir'):
            os.makedirs(DM.EXEC_CONFIG[key], exist_ok=True)
        DM.OWNER_CONFIG = {'owner': 'me@example.test', 'secret': 's',
                           'spool': root, 'db': os.path.join(root, 'messages.db')}

    def tearDown(self):
        DM.EXEC_CONFIG, DM.OWNER_CONFIG = self._saved_exec, self._saved_owner
        MSG._local.__dict__.clear()
        MSG._DB_PATH = None
        self.tmp.cleanup()

    def _approved_run(self, age_seconds=0):
        """An action card taken all the way to a run row in 'starting' with no window."""
        MSG.ingest({
            'schema_version': 1, 'event_id': 'e%d' % age_seconds, 'group_key': 'g%d' % age_seconds,
            'source': 'test', 'kind': 'action', 'urgency': 'normal', 'title': 'Do the thing',
            'created_at': MSG.iso(MSG.now_utc()),
            'recommended_action': {'cwd': self.cwd, 'prompt': 'do it', 'explain': 'because'},
        })
        card_id = MSG.feed('active')['messages'][0]['card_id']
        appr = MSG.issue_approval(card_id, DM.EXEC_CONFIG)
        run_id = MSG.redeem_approval(card_id, appr['nonce'], DM.EXEC_CONFIG)['run_id']
        if age_seconds:
            old = MSG.iso(datetime.now(timezone.utc) - timedelta(seconds=age_seconds))
            conn = MSG._conn()
            conn.execute('UPDATE runs SET created_at=? WHERE run_id=?', (old, run_id))
            conn.commit()
        return card_id, run_id


class StuckLaunchTest(_ExecBase):
    """devmon_messages deliberately leaves a targetless run alone, which is right — but it
    left no way out at all. These pin the escape: proof of no window, never a bare timeout."""

    def _reap(self, live_names, session_present=True):
        saved_tmux, saved_has = DM._tmux, DM._tmux_has_session
        try:
            DM._tmux = lambda *a, **k: ('\n'.join(live_names) if live_names is not None else None)
            DM._tmux_has_session = lambda name: (0 if session_present else 1)
            DM._reap_stuck_starting(DM.EXEC_CONFIG['session'])
        finally:
            DM._tmux, DM._tmux_has_session = saved_tmux, saved_has

    def test_stuck_run_is_released_once_its_window_is_provably_absent(self):
        card_id, run_id = self._approved_run(age_seconds=DM.STARTING_GRACE_S + 60)
        self._reap(live_names=[])
        self.assertNotEqual(MSG.get_run(run_id)['status'], 'starting')
        # The card lock is what the owner actually feels: it must be gone. Look the card up
        # BY ID — terminating a run ingests a result card that sorts first, and a brand new
        # card's run_id is always NULL, so asserting on messages[0] passes unconditionally.
        card = [m for m in MSG.feed('active')['messages'] if m['card_id'] == card_id]
        self.assertEqual(len(card), 1)
        self.assertIsNone(card[0]['run_id'])

    def test_a_young_run_is_left_alone(self):
        # Still inside the grace period: the launch may be mid-flight under the tmux lock.
        card_id, run_id = self._approved_run(age_seconds=0)
        self._reap(live_names=[])
        self.assertEqual(MSG.get_run(run_id)['status'], 'starting')

    def test_a_run_whose_window_exists_is_left_alone(self):
        card_id, run_id = self._approved_run(age_seconds=DM.STARTING_GRACE_S + 60)
        self._reap(live_names=[MSG.run_window_name(run_id)])
        self.assertEqual(MSG.get_run(run_id)['status'], 'starting')

    def test_unreachable_tmux_reaps_nothing(self):
        # Knowing nothing must never be read as "nothing is running" — that would end a
        # live run and unlock its card, permitting a second execution.
        card_id, run_id = self._approved_run(age_seconds=DM.STARTING_GRACE_S + 60)
        self._reap(live_names=None, session_present=True)
        self.assertEqual(MSG.get_run(run_id)['status'], 'starting')


class CompletedRunLifecycleTest(_ExecBase):
    """The completed Claude pane is retained for 24h, then all of its resources leave together."""

    def _completed_run(self, target='p1:@1', age_seconds=None, exec_plan=False):
        card_id, run_id = self._approved_run()
        MSG.run_mark_running(run_id, target)
        if exec_plan:
            conn = MSG._conn()
            conn.execute('UPDATE runs SET plan_json=? WHERE run_id=?',
                         (json.dumps({'cwd': self.cwd, 'exec': ['/bin/true']}), run_id))
            conn.commit()
        MSG.run_finish(run_id, 0)
        now = MSG.now_utc()
        if age_seconds is not None:
            ended = MSG.iso(now - timedelta(seconds=age_seconds))
            conn = MSG._conn()
            conn.execute('UPDATE runs SET ended_at=? WHERE run_id=?', (ended, run_id))
            conn.commit()
        return card_id, run_id, target, now

    def _sentinels(self, run_id):
        paths = action_runner.run_sentinel_paths(DM.EXEC_CONFIG['sentinel_dir'], run_id)
        for path in paths:
            with open(path, 'w') as fh:
                fh.write('owned by this run')
        return paths

    def _reap(self, alive, now):
        calls = []
        saved = DM._tmux
        try:
            DM._tmux = lambda *args, **kwargs: calls.append(args) or ''
            with redirect_stderr(io.StringIO()) as err:
                DM._reap_completed_runs(alive, now=now)
            return calls, err.getvalue()
        finally:
            DM._tmux = saved

    def test_expired_run_reclaims_process_window_and_sentinels_together(self):
        _, run_id, target, now = self._completed_run(
            age_seconds=DM.RUN_RETENTION_S)
        paths = self._sentinels(run_id)
        calls, log = self._reap({target}, now)
        self.assertEqual(calls, [('kill-window', '-t', '@1')])
        self.assertTrue(MSG.get_run(run_id)['reclaimed_at'])
        self.assertTrue(all(not os.path.exists(path) for path in paths))
        self.assertIn('reclaimed expired run=' + run_id, log)
        self.assertIn('reason=turn ended more than 24h ago', log)
        self.assertIn('process=tmux-pane', log)
        self.assertIn('sentinels=removed', log)

    def test_run_inside_24_hours_is_not_reclaimed(self):
        _, run_id, target, now = self._completed_run(
            age_seconds=DM.RUN_RETENTION_S - 1)
        paths = self._sentinels(run_id)
        calls, _ = self._reap({target}, now)
        self.assertEqual(calls, [])
        self.assertIsNone(MSG.get_run(run_id)['reclaimed_at'])
        self.assertTrue(all(os.path.exists(path) for path in paths))

    def test_keep_exempts_an_expired_run(self):
        _, run_id, target, now = self._completed_run(
            age_seconds=DM.RUN_RETENTION_S + 1)
        paths = self._sentinels(run_id)
        self.assertEqual(MSG.run_keep(run_id), (True, None))
        calls, _ = self._reap({target}, now)
        self.assertEqual(calls, [])
        run = MSG.get_run(run_id)
        self.assertTrue(run['keep'])
        self.assertIsNone(run['reclaimed_at'])
        self.assertTrue(all(os.path.exists(path) for path in paths))

    def test_exec_plan_is_outside_claude_retention_reaper(self):
        _, run_id, target, now = self._completed_run(
            age_seconds=DM.RUN_RETENTION_S + 1, exec_plan=True)
        paths = self._sentinels(run_id)
        calls, _ = self._reap({target}, now)
        self.assertEqual(calls, [])
        self.assertIsNone(MSG.get_run(run_id)['reclaimed_at'])
        self.assertTrue(all(os.path.exists(path) for path in paths))


class PlanFileTest(_ExecBase):
    """The plan file holds the approved cwd and prompt. devmon_messages drops the same
    content from `approvals` after a day; leaving a copy on disk forever undoes that."""

    def _plan_path(self, run_id):
        return os.path.join(DM.EXEC_CONFIG['plan_dir'], run_id + '.json')

    def test_plan_of_a_finished_run_is_deleted(self):
        card_id, run_id = self._approved_run()
        with open(self._plan_path(run_id), 'w') as fh:
            fh.write(json.dumps({'cwd': self.cwd}))
        MSG.run_mark_running(run_id, '1:@1')
        MSG.run_finish(run_id, 0)
        DM._reap_plan_files()
        self.assertFalse(os.path.exists(self._plan_path(run_id)))

    def test_plan_of_a_live_run_is_kept(self):
        card_id, run_id = self._approved_run()
        with open(self._plan_path(run_id), 'w') as fh:
            fh.write(json.dumps({'cwd': self.cwd}))
        MSG.run_mark_running(run_id, '1:@1')
        DM._reap_plan_files()
        self.assertTrue(os.path.exists(self._plan_path(run_id)))

    def test_foreign_files_are_left_alone(self):
        stray = os.path.join(DM.EXEC_CONFIG['plan_dir'], 'notes.txt')
        with open(stray, 'w') as fh:
            fh.write('not ours')
        DM._reap_plan_files()
        self.assertTrue(os.path.exists(stray))


class LaunchWithoutTmuxTest(_ExecBase):
    """No tmux is a definite answer, not an ambiguous one: nothing started, so the card
    must unlock. Reporting it as ambiguous is what left cards stuck forever."""

    def test_missing_tmux_reports_nowindow_and_writes_no_plan(self):
        saved = DM.shutil.which
        try:
            DM.shutil.which = lambda name: None
            outcome, target = DM._launch_run('run-x', {'cwd': self.cwd, 'prompt': 'p', 'explain': 'e'})
        finally:
            DM.shutil.which = saved
        self.assertEqual((outcome, target), ('nowindow', None))
        self.assertEqual(os.listdir(DM.EXEC_CONFIG['plan_dir']), [])



class ManyRunsTest(_ExecBase):
    """Both reapers used list_runs(), which pages at 50. A stuck run is by definition an
    old one, so the escape hatch vanished as soon as the box had 50 newer runs — and the
    plan cleanup started deleting the plan files of runs that were still alive."""

    def _bulk_runs(self, n):
        """n finished runs, so the one run we care about is off the first page."""
        conn = MSG._conn()
        for i in range(n):
            conn.execute(
                'INSERT INTO runs(run_id, card_id, plan_sha256, plan_json, status, created_at, ended_at) '
                'VALUES(?,?,?,?,?,?,?)',
                ('run-filler-%03d' % i, 'c%d' % i, 'sha', '{}', 'done',
                 MSG.iso(MSG.now_utc()), MSG.iso(MSG.now_utc())))
        conn.commit()

    def test_stuck_run_is_still_found_behind_fifty_newer_runs(self):
        card_id, run_id = self._approved_run(age_seconds=DM.STARTING_GRACE_S + 60)
        self._bulk_runs(60)
        saved_tmux, saved_has = DM._tmux, DM._tmux_has_session
        try:
            DM._tmux = lambda *a, **k: ''
            DM._tmux_has_session = lambda name: 0
            DM._reap_stuck_starting(DM.EXEC_CONFIG['session'])
        finally:
            DM._tmux, DM._tmux_has_session = saved_tmux, saved_has
        self.assertNotEqual(MSG.get_run(run_id)['status'], 'starting')

    def test_plan_file_of_a_live_run_survives_behind_fifty_newer_runs(self):
        card_id, run_id = self._approved_run()
        MSG.run_mark_running(run_id, '1:@1')
        path = os.path.join(DM.EXEC_CONFIG['plan_dir'], run_id + '.json')
        with open(path, 'w') as fh:
            fh.write('{}')
        self._bulk_runs(60)
        DM._reap_plan_files()
        # Deleting this would make the runner fail to open its own plan: the approved
        # action reports failed having never run.
        self.assertTrue(os.path.exists(path))


class ExecRootTest(_ExecBase):
    """A systemd EnvironmentFile writes an empty value for an unset key, and canonical_plan
    reads a falsy root as 'no bound at all' — so DEV_MONITOR_CWD_ROOT= removed the boundary."""

    def _cwd_root(self, value):
        saved = os.environ.get('DEV_MONITOR_CWD_ROOT')
        try:
            if value is None:
                os.environ.pop('DEV_MONITOR_CWD_ROOT', None)
            else:
                os.environ['DEV_MONITOR_CWD_ROOT'] = value
            return DM._build_exec_config()['cwd_root']
        finally:
            if saved is None:
                os.environ.pop('DEV_MONITOR_CWD_ROOT', None)
            else:
                os.environ['DEV_MONITOR_CWD_ROOT'] = saved

    def test_empty_falls_back_to_home_rather_than_no_bound(self):
        self.assertEqual(self._cwd_root(''), DM.HOME)

    def test_unset_falls_back_to_home(self):
        self.assertEqual(self._cwd_root(None), DM.HOME)

    def test_a_real_value_is_honoured(self):
        self.assertEqual(self._cwd_root('/srv/projects'), '/srv/projects')


class ApprovalSiblingTest(_ExecBase):
    """One click approves ONE execution. A preview opened and cancelled must not leave a
    second capability alive, redeemable with no further click once the first run ends."""

    def test_redeeming_one_nonce_burns_the_card_s_other_approvals(self):
        MSG.ingest({
            'schema_version': 1, 'event_id': 'sib', 'group_key': 'sib', 'source': 'test',
            'kind': 'action', 'urgency': 'normal', 'title': 'Do it',
            'created_at': MSG.iso(MSG.now_utc()),
            'recommended_action': {'cwd': self.cwd, 'prompt': 'p', 'explain': 'e'},
        })
        card_id = MSG.feed('active')['messages'][0]['card_id']
        first = MSG.issue_approval(card_id, DM.EXEC_CONFIG)['nonce']
        second = MSG.issue_approval(card_id, DM.EXEC_CONFIG)['nonce']
        run_id = MSG.redeem_approval(card_id, second, DM.EXEC_CONFIG)['run_id']
        MSG.run_mark_running(run_id, '1:@1')
        MSG.run_finish(run_id, 0)
        self.assertEqual(MSG.redeem_approval(card_id, first, DM.EXEC_CONFIG),
                         {'ok': False, 'error': 'nonce_used'})


class ServiceHealthTest(unittest.TestCase):
    HEALTHY_DAEMON = '''Type=simple
Result=success
NRestarts=0
ExecMainStatus=0
Id=airlock-learning.service
LoadState=loaded
ActiveState=active
SubState=running
UnitFileState=enabled
ActiveEnterTimestamp=
'''
    SUCCESSFUL_ONESHOT = '''Type=oneshot
Result=success
NRestarts=0
ExecMainStatus=0
Id=claude-fleet-usage.service
LoadState=loaded
ActiveState=inactive
SubState=dead
UnitFileState=static
ActiveEnterTimestamp=
'''
    FAILED_ONESHOT = '''Type=oneshot
Result=exit-code
NRestarts=0
ExecMainStatus=1
Id=skill-wiring-check.service
LoadState=loaded
ActiveState=failed
SubState=failed
UnitFileState=static
ActiveEnterTimestamp=
'''
    DISABLED_DAEMON = '''Type=notify
Result=success
NRestarts=0
ExecMainStatus=0
Id=ssh.service
LoadState=loaded
ActiveState=inactive
SubState=dead
UnitFileState=disabled
ActiveEnterTimestamp=
'''

    def test_actual_success_and_failure_controls(self):
        healthy = DM._service_from_show('airlock-learning', 'user', self.HEALTHY_DAEMON)
        completed = DM._service_from_show(
            'claude-fleet-usage', 'user', self.SUCCESSFUL_ONESHOT)
        failed = DM._service_from_show('skill-wiring-check', 'user', self.FAILED_ONESHOT)
        disabled = DM._service_from_show('ssh', 'system', self.DISABLED_DAEMON)

        self.assertFalse(healthy['attention'])
        self.assertFalse(completed['attention'], 'successful inactive oneshot is healthy')
        self.assertTrue(failed['attention'])
        self.assertIn('exit-code', failed['attention_reason'])
        self.assertFalse(disabled['attention'], 'disabled inactive daemon is intentional')
        self.assertEqual(completed['active_state'], 'inactive')
        self.assertEqual(completed['sub_state'], 'dead')
        self.assertEqual(completed['n_restarts'], 0)

    def test_restart_count_alerts_even_after_service_is_active_again(self):
        restarted = self.HEALTHY_DAEMON.replace('NRestarts=0', 'NRestarts=31780')
        item = DM._service_from_show('airlock-learning', 'user', restarted)
        self.assertTrue(item['attention'])
        self.assertIn('31780', item['attention_reason'])

    def test_nonzero_systemctl_status_does_not_discard_typed_output(self):
        saved_run = DM.subprocess.run
        calls = []
        try:
            DM.subprocess.run = lambda argv, **kwargs: (
                calls.append((argv, kwargs)) or
                types.SimpleNamespace(returncode=3, stdout=self.SUCCESSFUL_ONESHOT))
            raw, error = DM._systemctl_show('claude-fleet-usage', 'user')
        finally:
            DM.subprocess.run = saved_run
        self.assertIsNone(error)
        self.assertIn('ActiveState=inactive', raw)
        self.assertEqual(calls[0][0][0:2], ['systemctl', '--user'])
        self.assertEqual(calls[0][1]['stderr'], DM.subprocess.DEVNULL)
        self.assertEqual(calls[0][1]['timeout'], 1)

    def test_rc1_partial_show_is_failure_and_cannot_grant_restart(self):
        saved_run = DM.subprocess.run
        saved_inventory = DM._airlock_user_inventory
        try:
            DM._airlock_user_inventory = lambda: (['airlock-alpha'], None)
            DM.subprocess.run = lambda _argv, **_kwargs: types.SimpleNamespace(
                returncode=1, stdout='Id=airlock-alpha.service\n')
            self.assertEqual(DM._airlock_user_units(), [])
        finally:
            DM.subprocess.run = saved_run
            DM._airlock_user_inventory = saved_inventory

    def test_systemctl_timeout_is_typed_collection_failure(self):
        saved_run = DM.subprocess.run
        try:
            DM.subprocess.run = lambda argv, **kwargs: (_ for _ in ()).throw(
                DM.subprocess.TimeoutExpired(argv, kwargs['timeout']))
            raw, error = DM._systemctl_show(['airlock-learning'], 'user')
        finally:
            DM.subprocess.run = saved_run
        self.assertEqual(raw, '')
        self.assertEqual(error, 'collection failed')

    def test_missing_and_enabled_inactive_units_alert(self):
        missing = self.DISABLED_DAEMON.replace('LoadState=loaded', 'LoadState=not-found')
        enabled = self.DISABLED_DAEMON.replace('UnitFileState=disabled',
                                               'UnitFileState=enabled')
        self.assertTrue(DM._service_from_show('missing', 'user', missing)['attention'])
        self.assertTrue(DM._service_from_show('expected-daemon', 'user', enabled)['attention'])

    def test_actual_inventory_shape_excludes_template_and_includes_live_instance(self):
        saved_command = DM._service_command
        unit_files = '''airlock-code-server-manager.service enabled enabled
airlock-code-server@.service indirect enabled
airlock-learning.service enabled enabled
'''
        loaded = '''  airlock-code-server-manager.service loaded active running manager
● airlock-code-server@1.service loaded failed failed slot one
  airlock-learning.service loaded active running learning
'''
        calls = []
        try:
            DM._service_command = lambda argv: (
                calls.append(argv) or
                (loaded if 'list-units' in argv else unit_files, None))
            units, error = DM._observed_user_inventory()
        finally:
            DM._service_command = saved_command
        self.assertIsNone(error)
        self.assertNotIn('airlock-code-server@', units)
        self.assertIn('airlock-code-server@1', units)
        self.assertIn('airlock-learning', units)
        self.assertIn('--plain', next(argv for argv in calls if 'list-units' in argv))

    def test_live_box_inventory_reaches_enabled_timer_and_failed_non_airlock_units(self):
        """Replay verbatim public-safe rows from the live systemctl outputs."""
        fixture = os.path.join(
            HERE, '..', '..', 'install', 'fixtures',
            'dev-monitor-service-inventory-live-20260831')
        with open(os.path.join(fixture, 'unit-files.txt'), encoding='utf-8') as f:
            unit_files = f.read()
        with open(os.path.join(fixture, 'loaded.txt'), encoding='utf-8') as f:
            loaded = f.read()
        with open(os.path.join(fixture, 'timers.txt'), encoding='utf-8') as f:
            timers = f.read()
        saved_command = DM._service_command
        saved_show = DM._systemctl_show
        calls = []
        try:
            def command(argv):
                calls.append(argv)
                if 'list-unit-files' in argv:
                    return unit_files, None
                if 'list-timers' in argv:
                    return timers, None
                return loaded, None

            DM._service_command = command
            units, error = DM._observed_user_inventory()

            def show(names, _scope):
                blocks = []
                for name in names:
                    if name == 'skill-wiring-check':
                        blocks.append(self.FAILED_ONESHOT)
                    else:
                        blocks.append(self.HEALTHY_DAEMON.replace(
                            'Id=airlock-learning.service', 'Id=' + name + '.service'))
                return '\n\n'.join(blocks), None

            DM._systemctl_show = show
            services = DM.svc_info()
        finally:
            DM._service_command = saved_command
            DM._systemctl_show = saved_show

        self.assertIsNone(error)
        self.assertIn('airlock-code-server@1', units)
        self.assertIn('learning-manager', units)
        self.assertIn('session-migration', units)
        self.assertIn('claude-fleet-usage', units)
        self.assertIn('skill-wiring-check', units)
        self.assertIn('wiki-secret-audit', units)
        self.assertNotIn('dbus', units)
        self.assertNotIn('gpg-agent', units)
        self.assertNotIn('airlock-code-server@', units)
        self.assertTrue(any('list-timers' in argv for argv in calls))
        by_name = {item['name']: item for item in services}
        self.assertTrue(by_name['skill-wiring-check']['attention'])
        self.assertIn('Result=exit-code',
                      by_name['skill-wiring-check']['attention_reason'])
        self.assertFalse(by_name['skill-wiring-check']['action_allowed'])
        self.assertFalse(by_name['learning-manager']['attention'])
        self.assertFalse(by_name['learning-manager']['action_allowed'])
        self.assertTrue(by_name['airlock-learning']['action_allowed'])
        self.assertEqual(DM._services_payload(services)['attention_count'], 1)

    def test_each_broad_inventory_source_contributes_independently(self):
        saved_command = DM._service_command
        outputs = {
            'list-unit-files': '''runtime-only.service enabled-runtime enabled
healthy-static.service static -
''',
            'list-units': '''failed-without-timer.service loaded failed failed failed job
healthy-static.service loaded inactive dead incidental helper
''',
            'list-timers': '''- - - - timer-only.timer timer-only.service
''',
        }
        try:
            DM._service_command = lambda argv: (
                next(value for key, value in outputs.items() if key in argv), None)
            units, error = DM._observed_user_inventory()
        finally:
            DM._service_command = saved_command
        self.assertIsNone(error)
        self.assertEqual(units, ['failed-without-timer', 'runtime-only', 'timer-only'])

    def test_partial_nonzero_inventory_output_is_fail_visible(self):
        saved_run = DM.subprocess.run
        try:
            DM.subprocess.run = lambda _argv, **_kwargs: types.SimpleNamespace(
                returncode=1, stdout='learning-manager.service enabled enabled\n')
            raw, error = DM._service_command(
                ['systemctl', '--user', 'list-unit-files', '--type=service'])
        finally:
            DM.subprocess.run = saved_run
        self.assertIn('learning-manager.service', raw)
        self.assertEqual(error, 'collection failed')

    def test_partial_and_total_inventory_failure_are_visible(self):
        saved_command = DM._service_command
        unit_files = 'airlock-learning.service enabled enabled\n'
        try:
            DM._service_command = lambda argv: (
                ('', 'collection failed') if 'list-units' in argv else (unit_files, None))
            units, error = DM._observed_user_inventory()
            self.assertEqual(units, ['airlock-learning'])
            self.assertEqual(error, 'inventory collection failed')

            DM._service_command = lambda _argv: ('', 'collection failed')
            units, error = DM._observed_user_inventory()
            self.assertEqual(units, [])
            self.assertEqual(error, 'inventory collection failed')
        finally:
            DM._service_command = saved_command

    def test_inventory_failure_becomes_an_attention_row(self):
        saved_inventory = DM._observed_user_inventory
        saved_show = DM._systemctl_show

        def show(names, _scope):
            blocks = []
            for name in names:
                blocks.append(self.HEALTHY_DAEMON.replace(
                    'Id=airlock-learning.service', 'Id=' + name + '.service'))
            return '\n\n'.join(blocks), None

        try:
            DM._observed_user_inventory = lambda: ([], 'inventory collection failed')
            DM._systemctl_show = show
            services = DM.svc_info()
        finally:
            DM._observed_user_inventory = saved_inventory
            DM._systemctl_show = saved_show
        inventory = next(item for item in services
                         if item['name'] == 'airlock-user-inventory')
        self.assertTrue(inventory['attention'])
        self.assertFalse(inventory['action_allowed'])

    def test_health_collection_is_one_batch_per_nonempty_scope(self):
        saved_show = DM._systemctl_show
        calls = []

        def show(names, scope):
            calls.append((list(names), scope))
            blocks = [self.HEALTHY_DAEMON.replace(
                'Id=airlock-learning.service', 'Id=' + name + '.service')
                      for name in names]
            return '\n\n'.join(blocks), None

        try:
            DM._systemctl_show = show
            rows = DM._service_group_info(['airlock-one', 'airlock-two'], 'user')
        finally:
            DM._systemctl_show = saved_show
        self.assertEqual(calls, [(['airlock-one', 'airlock-two'], 'user')])
        self.assertEqual([row['name'] for row in rows], ['airlock-one', 'airlock-two'])
        self.assertTrue(all(not row['attention'] for row in rows))

    def test_payload_counts_attention_without_messages(self):
        rows = [
            {'name': 'ok', 'attention': False},
            {'name': 'restart', 'attention': True},
            {'name': 'failed', 'attention': True},
        ]
        self.assertEqual(DM._services_payload(rows),
                         {'services': rows, 'attention_count': 2})

    def test_service_panel_orders_attention_before_healthy_rows(self):
        with open(os.path.join(HERE, 'frontend', 'dev-monitor.html'), encoding='utf-8') as f:
            frontend = f.read()
        sort = frontend.index('Number(Boolean(b.attention))')
        render = frontend.index("svcs.forEach(function (s)", sort)
        self.assertLess(sort, render)


class ServiceRestartTest(unittest.TestCase):
    def setUp(self):
        self.saved_units = DM._airlock_user_units
        self.saved_inventory = DM._airlock_user_inventory
        self.saved_observed = DM._observed_user_inventory
        self.saved_check_call = DM.subprocess.check_call
        self.saved_run = DM.run
        self.saved_show = DM._systemctl_show

    def tearDown(self):
        DM._airlock_user_units = self.saved_units
        DM._airlock_user_inventory = self.saved_inventory
        DM._observed_user_inventory = self.saved_observed
        DM.subprocess.check_call = self.saved_check_call
        DM.run = self.saved_run
        DM._systemctl_show = self.saved_show

    def test_only_discovered_user_units_are_restartable_with_shell_free_argv(self):
        DM._airlock_user_units = lambda: ['airlock-alpha']
        calls = []
        DM.subprocess.check_call = lambda argv, **kwargs: calls.append((argv, kwargs))
        self.assertEqual(DM.restart_svc('airlock-alpha'), (True, 'restarted: airlock-alpha'))
        self.assertEqual(calls[0][0],
                         ['systemctl', '--user', 'restart', '--', 'airlock-alpha'])
        self.assertEqual(calls[0][1]['timeout'], 10)

    def test_system_service_and_forged_name_are_refused_before_subprocess(self):
        DM._airlock_user_units = lambda: ['airlock-alpha', 'airlock-dev-monitor']
        DM.subprocess.check_call = lambda *a, **k: self.fail('subprocess must not run')
        for name in ('nginx', 'learning-manager', 'skill-wiring-check',
                     'airlock-dev-monitor', 'airlock-alpha; reboot', '', None):
            self.assertEqual(DM.restart_svc(name),
                             (False, 'service restart is not allowed'))

    def test_timeout_is_reported_without_exception_or_command_output(self):
        DM._airlock_user_units = lambda: ['airlock-alpha', 'airlock-dev-monitor']
        DM.subprocess.check_call = lambda *a, **k: (_ for _ in ()).throw(
            DM.subprocess.TimeoutExpired(a[0], k.get('timeout')))
        self.assertEqual(DM.restart_svc('airlock-alpha'), (False, 'restart timeout'))

    def test_service_inventory_keeps_observed_non_airlock_units_read_only(self):
        DM._airlock_user_units = lambda: ['airlock-alpha', 'airlock-dev-monitor']
        DM._observed_user_inventory = lambda: (
            ['airlock-alpha', 'airlock-dev-monitor', 'learning-manager'], None)
        DM._systemctl_show = lambda names, _scope: ('\n\n'.join(
            ServiceHealthTest.HEALTHY_DAEMON.replace(
                'Id=airlock-learning.service', 'Id=' + name + '.service')
            for name in names), None)
        services = DM.svc_info()
        user = next(item for item in services if item['name'] == 'airlock-alpha')
        own = next(item for item in services if item['name'] == 'airlock-dev-monitor')
        private = next(item for item in services if item['name'] == 'learning-manager')
        system = next(item for item in services if item['name'] == 'nginx')
        self.assertTrue(user['action_allowed'])
        self.assertFalse(own['action_allowed'])
        self.assertFalse(private['action_allowed'])
        self.assertFalse(system['action_allowed'])

    def test_restart_allowlist_requires_canonical_id_and_rejects_aliases(self):
        DM._airlock_user_inventory = lambda: (
            ['airlock-alpha', 'airlock-bridge', 'airlock-self-alias'], None)
        DM._systemctl_show = lambda _names, _scope: ('''
Id=airlock-alpha.service

Id=learning-manager.service

Id=airlock-dev-monitor.service
''', None)
        self.assertEqual(DM._airlock_user_units(), ['airlock-alpha'])

    def test_timer_only_airlock_name_is_observed_but_never_restartable(self):
        saved_command = DM._service_command
        saved_show = DM._systemctl_show
        try:
            def command(argv):
                if 'list-timers' in argv:
                    return '- - - - airlock-ghost.timer airlock-ghost.service\n', None
                return '', None

            DM._service_command = command
            DM._systemctl_show = lambda names, _scope: ('\n\n'.join(
                ServiceHealthTest.HEALTHY_DAEMON.replace(
                    'Id=airlock-learning.service', 'Id=' + name + '.service')
                for name in names), None)
            services = DM.svc_info()
        finally:
            DM._service_command = saved_command
            DM._systemctl_show = saved_show
        ghost = next(item for item in services if item['name'] == 'airlock-ghost')
        self.assertFalse(ghost['action_allowed'])


class CronReadOnlyTest(unittest.TestCase):
    # Scheduled jobs are observed, never changed, from the dashboard. This asserts the
    # absence directly: a regression that restores any of these entrypoints — or the
    # snapshot field that decided which rows got buttons — fails here, before any route
    # or template has to notice.
    def test_module_exposes_no_way_to_change_a_job(self):
        for name in ('run_action', 'known_user_timers', 'timer_service', '_ACTIONS'):
            self.assertFalse(hasattr(devmon_cron, name),
                             f'cron write surface is back: devmon_cron.{name}')
        self.assertNotIn('controllable', devmon_cron._PUBLIC_JOB_FIELDS)

    def test_public_snapshot_omits_commands_origins_and_raw_parse_failures(self):
        original = devmon_cron.scan.snapshot
        try:
            devmon_cron.scan.snapshot = lambda: {
                'schemaVersion': 3, 'hostname': 'box', 'counts': {'total': 1},
                'notes': ['safe'], 'privateTop': 'Bearer-TOP-SECRET',
                'jobs': [{
                    'id': 'user:secret.timer', 'scope': 'user', 'kind': 'systemd',
                    'name': 'secret', 'unit': 'secret.timer', 'schedule': 'daily',
                    'execution': 'observed', 'timeliness': 'on-time',
                    'lastResult': 'success', 'reboot': 'safe', 'controllable': True,
                    'command': 'curl -H Authorization:Bearer-REFUTE-SECRET',
                    'origin': {'path': '/home/owner/private/job.sh'},
                    'source': '/home/owner/private/secret.timer',
                }],
                'sources': [{
                    'scope': 'crontab', 'kind': 'crontab -l', 'ok': False,
                    'count': 0, 'error': 'permission denied',
                    'unparsed': ['* * * * * curl Bearer-SOURCE-SECRET'],
                    'definitionMtimeSource': '/home/owner/private/crontab',
                }],
            }
            payload = devmon_cron.snapshot()
        finally:
            devmon_cron.scan.snapshot = original
        rendered = json.dumps(payload, sort_keys=True)
        self.assertNotIn('SECRET', rendered)
        self.assertNotIn('/home/owner', rendered)
        self.assertEqual(payload['jobs'][0]['unit'], 'secret.timer')
        self.assertEqual(payload['sources'][0], {
            'scope': 'crontab', 'kind': 'crontab -l', 'ok': False,
            'count': 0, 'error': 'permission denied',
        })


class OwnerRouteTest(unittest.TestCase):
    """Drives the real HTTP handler. This is the layer the module tests never reach — and
    it is where card ids arrive percent-encoded by the browser."""

    @classmethod
    def setUpClass(cls):
        import http.server, threading
        cls.tmp = tempfile.TemporaryDirectory()
        root = cls.tmp.name
        cls.cwd = os.path.join(root, 'project')
        os.makedirs(cls.cwd)
        MSG.init_db(os.path.join(root, 'messages.db'))
        DM.OWNER_CONFIG = {'owner': 'me@example.test', 'secret': 's3cr3t',
                           'spool': root, 'db': os.path.join(root, 'messages.db')}
        DM.UPDATES_OWNER_CONFIG = {'owner': 'me@example.test', 'secret': 's3cr3t'}
        DM.EXEC_CONFIG = {
            'cwd_root': root, 'session': 'devmon-test',
            'runner': os.path.join(BACKEND, 'action_runner.py'),
            'plan_dir': os.path.join(root, 'plans'), 'sentinel_dir': os.path.join(root, 'sentinels'),
        }
        for key in ('plan_dir', 'sentinel_dir'):
            os.makedirs(DM.EXEC_CONFIG[key], exist_ok=True)
        # An event_id shaped exactly like the one the shipped producer generates: it
        # contains colons, which encodeURIComponent turns into %3A.
        cls.card_id = 'disk-2026-08-01T01:20:37Z-299b'
        MSG.ingest({
            'schema_version': 1, 'event_id': cls.card_id, 'group_key': 'disk:cleanup',
            'source': 'disk', 'kind': 'action', 'urgency': 'normal', 'title': 'Clean up',
            'created_at': MSG.iso(MSG.now_utc()),
            'recommended_action': {'cwd': cls.cwd, 'prompt': 'clean', 'explain': 'disk is full'},
        })
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), DM.Handler)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        DM.OWNER_CONFIG = None
        DM.UPDATES_OWNER_CONFIG = None
        DM.EXEC_CONFIG = None
        MSG._local.__dict__.clear()
        MSG._DB_PATH = None
        cls.tmp.cleanup()

    def _post(self, path, body=b'{}', headers=None, origin=True):
        import http.client
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        h = {'X-Devmon-Owner': 'me@example.test', 'X-Devmon-Proxy-Secret': 's3cr3t',
             'Content-Type': 'application/json'}
        if origin:
            h['Origin'] = 'http://127.0.0.1:%d' % self.port
        h.update(headers or {})
        conn.request('POST', path, body=body, headers=h)
        r = conn.getresponse()
        data = r.read()
        conn.close()
        return r.status, json.loads(data or b'{}')

    def _get(self, path, headers=None):
        import http.client
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        conn.request('GET', path, headers=headers or {})
        r = conn.getresponse()
        data = r.read()
        conn.close()
        return r.status, json.loads(data or b'{}')

    def _owner_get(self, path):
        return self._get(path, {
            'X-Devmon-Owner': 'me@example.test',
            'X-Devmon-Proxy-Secret': 's3cr3t',
        })

    def test_percent_encoded_card_id_reaches_the_card(self):
        # What the browser actually sends. Before the fix this answered 404/card_not_found
        # for every card the shipped producer creates, so nothing could be read or run.
        import urllib.parse as up
        quoted = up.quote(self.card_id, safe='')
        self.assertIn('%3A', quoted)
        status, payload = self._post('/api/owner/messages/%s/plan' % quoted)
        self.assertEqual((status, payload.get('ok')), (200, True), payload)
        self.assertIn('nonce', payload)

    def test_percent_encoded_card_id_also_works_for_read(self):
        import urllib.parse as up
        status, payload = self._post('/api/owner/messages/%s/read' % up.quote(self.card_id, safe=''))
        self.assertEqual((status, payload.get('ok')), (200, True), payload)

    def test_a_wrong_secret_is_refused(self):
        status, _ = self._post('/api/owner/messages/x/read', headers={'X-Devmon-Proxy-Secret': 'nope'})
        self.assertEqual(status, 403)

    def test_a_non_ascii_header_is_refused_not_crashed(self):
        # http.server decodes headers as latin-1 and hmac.compare_digest refuses non-ASCII
        # str, so this used to raise pre-auth and reset the connection.
        status, _ = self._post('/api/owner/messages/x/read',
                               headers={'X-Devmon-Owner': 'caf\u00e9'.encode('utf-8').decode('latin-1')})
        self.assertEqual(status, 403)

    def test_a_cross_origin_post_is_refused(self):
        status, _ = self._post('/api/owner/messages/x/read',
                               headers={'Origin': 'https://evil.example'})
        self.assertEqual(status, 403)

    def test_owner_can_restart_an_allowed_service(self):
        saved = DM.restart_svc
        try:
            seen = []
            DM.restart_svc = lambda name: (seen.append(name) or True, 'restarted: ' + name)
            status, payload = self._post('/api/owner/service/restart',
                                         body=b'{"name":"airlock-alpha"}')
            self.assertEqual((status, payload.get('ok')), (200, True), payload)
            self.assertEqual(seen, ['airlock-alpha'])
        finally:
            DM.restart_svc = saved

    def test_restart_checks_owner_before_dispatch(self):
        saved = DM.restart_svc
        try:
            DM.restart_svc = lambda name: self.fail('restart must not run before owner gate')
            status, _ = self._post('/api/owner/service/restart',
                                   body=b'{"name":"airlock-alpha"}',
                                   headers={'X-Devmon-Proxy-Secret': 'nope'})
            self.assertEqual(status, 403)
        finally:
            DM.restart_svc = saved

    def test_restart_is_not_exposed_outside_the_owner_route(self):
        status, payload = self._post('/api/service/restart',
                                     body=b'{"name":"airlock-alpha"}')
        self.assertEqual(status, 404, payload)

    def test_cron_write_routes_do_not_exist_for_a_fully_authorised_owner(self):
        # The discriminating case. A request that clears every gate — owner identity,
        # proxy secret, same origin, JSON body — must still find nothing here. A live
        # route would answer 200/400/403 from the action handler instead.
        for action in ('run', 'pause', 'resume'):
            status, payload = self._post('/api/owner/cron/' + action,
                                         body=b'{"unit":"backup.timer"}')
            self.assertEqual(status, 404, (action, payload))

    def test_cron_reading_is_untouched_by_the_write_removal(self):
        saved = DM.CRON.snapshot
        try:
            DM.CRON.snapshot = lambda: {'jobs': [], 'counts': {}, 'sources': []}
            status, payload = self._get('/api/cron/jobs')
            self.assertEqual((status, payload.get('jobs')), (200, []), payload)
        finally:
            DM.CRON.snapshot = saved

    def test_updates_are_owner_scoped_and_keep_the_collector_contract(self):
        saved = DM.UPDATES
        try:
            class Snapshot:
                @staticmethod
                def read_snapshot():
                    return {
                        'checkedAt': '2026-09-01T00:00:00Z',
                        'platform': {'available': True, 'changedCount': 2, 'ref': 'main'},
                        'apps': [{'id': 'notes', 'action': 'upgrade', 'sourceClass': 'shipped'}],
                        'harness': {'codex': None, 'hooksDrift': True, 'skillsWired': 0},
                    }

            DM.UPDATES = Snapshot
            status, payload = self._owner_get('/api/owner/updates')
            self.assertEqual(status, 200, payload)
            self.assertEqual(payload['platform']['changedCount'], 2)
            self.assertEqual(payload['apps'][0]['action'], 'upgrade')
            status, _ = self._get('/api/owner/updates')
            self.assertEqual(status, 403)
        finally:
            DM.UPDATES = saved

    def test_updates_keep_their_owner_gate_when_messages_are_off(self):
        """The settings panel is useful on observability-only boxes too."""
        saved_updates, saved_messages = DM.UPDATES, DM.OWNER_CONFIG
        try:
            class Snapshot:
                @staticmethod
                def read_snapshot():
                    return {
                        'checkedAt': '2026-09-01T00:00:00Z',
                        'platform': None, 'apps': [],
                        'harness': {'codex': None, 'hooksDrift': False, 'skillsWired': 0},
                    }

            DM.UPDATES = Snapshot
            DM.OWNER_CONFIG = None
            status, payload = self._owner_get('/api/owner/updates')
            self.assertEqual((status, payload['checkedAt']), (200, '2026-09-01T00:00:00Z'))
            status, payload = self._owner_get('/api/owner/messages/preview')
            self.assertEqual((status, payload['error']), (404, 'messages feature not enabled'))
        finally:
            DM.UPDATES, DM.OWNER_CONFIG = saved_updates, saved_messages

    def test_updates_return_404_until_a_complete_snapshot_exists(self):
        saved = DM.UPDATES
        try:
            class Empty:
                @staticmethod
                def read_snapshot():
                    return None

            DM.UPDATES = Empty
            status, payload = self._owner_get('/api/owner/updates')
            self.assertEqual(status, 404, payload)
            self.assertIn('snapshot', payload['error'])
        finally:
            DM.UPDATES = saved

    def test_updates_return_404_when_the_collector_module_is_absent(self):
        saved = DM.UPDATES
        try:
            DM.UPDATES = None
            status, payload = self._owner_get('/api/owner/updates')
            self.assertEqual(status, 404, payload)
            self.assertIn('not enabled', payload['error'])
        finally:
            DM.UPDATES = saved


class UpdatesCollectorTest(unittest.TestCase):
    """The timer reads existing engines; these pin the translation, not a second plan."""

    def setUp(self):
        self.updates = DM.UPDATES
        self.saved_run = self.updates._run
        self.saved_find_bin = self.updates.bin_discovery.find_bin
        self.saved_first_line = self.updates._first_line

    def tearDown(self):
        self.updates._run = self.saved_run
        self.updates.bin_discovery.find_bin = self.saved_find_bin
        self.updates._first_line = self.saved_first_line

    def _stub_clis(self, versions):
        """Route every CLI probe through a fixture. Returns (find_calls, argv_calls)."""
        find_calls, command_calls = [], []

        def find_bin(command):
            find_calls.append(command)
            return '/fixture/home/.local/bin/' + command, {
                'searched': 1, 'path': '/usr/bin', 'rejected': []}

        def first_line(argv, **_kwargs):
            command_calls.append(argv)
            for name, line in versions.items():
                if argv == ['/fixture/home/.local/bin/' + name, '--version']:
                    return line
            if argv[:3] == ['npm', 'view', '@openai/codex']:
                return versions.get('npm')
            return 'claude-hook-wiring: ok'

        self.updates.bin_discovery.find_bin = find_bin
        self.updates._first_line = first_line
        return find_calls, command_calls

    def test_harness_resolves_clis_outside_the_service_path(self):
        """The collector must run the discovered absolute binaries, not bare names."""
        find_calls, command_calls = self._stub_clis(
            {'codex': 'codex-cli 0.144.4', 'claude': '2.1.257 (Claude Code)',
             'npm': '0.152.0'})
        harness = self.updates._harness()
        self.assertEqual(find_calls, ['codex', 'claude'])
        self.assertIn(['/fixture/home/.local/bin/codex', '--version'], command_calls)
        self.assertIn(['/fixture/home/.local/bin/claude', '--version'], command_calls)

    def test_harness_compares_versions_and_not_version_lines(self):
        """The regression this exists for, measured on a live snapshot 2026-09-01.

        `codex --version` prints "codex-cli 0.144.4" and `npm view` prints "0.152.0",
        so comparing the raw lines answered "outdated" for a STRUCTURAL reason: the
        strings could never be equal no matter what was installed, and the badge would
        have kept counting 1 after a successful upgrade — the exact click this card
        arms. Both sides are reduced to the version itself.
        """
        self._stub_clis({'codex': 'codex-cli 0.144.4', 'claude': '2.1.257 (Claude Code)',
                         'npm': '0.152.0'})
        harness = self.updates._harness()
        self.assertEqual(harness['codex'], {'installed': '0.144.4', 'latest': '0.152.0'})
        self.assertEqual(harness['claude'], {'installed': '2.1.257'})

        # The positive control: an up-to-date box has to read as up to date, which the
        # old comparison could not do for any input at all.
        self._stub_clis({'codex': 'codex-cli 0.152.0', 'claude': '2.1.257 (Claude Code)',
                         'npm': '0.152.0'})
        current = self.updates._harness()
        self.assertEqual(current['codex']['installed'], current['codex']['latest'])

    def test_harness_reports_an_unreadable_version_as_absent(self):
        """A line with no version in it is 'we could not read it', never a version.

        Returning the raw line would put it into the panel's comparison, where an
        unreadable reading would render as an upgrade offer from nonsense to a number.
        """
        self._stub_clis({'codex': 'command not found', 'claude': '', 'npm': None})
        harness = self.updates._harness()
        self.assertIsNone(harness['codex'])
        self.assertIsNone(harness['claude'])

    def test_harness_counts_skill_roots_separately(self):
        """Per agent, never one total: the two roots belong to two different agents.

        A skill wired for Claude Code and missing for the Codex CLI raises no error
        anywhere — it simply never triggers for that agent — so a summed count is the
        one shape that cannot show it.
        """
        self._stub_clis({'codex': 'codex-cli 0.152.0', 'npm': '0.152.0'})
        with tempfile.TemporaryDirectory() as tmp:
            claude_root = Path(tmp) / 'claude'
            codex_root = Path(tmp) / 'codex'
            for root, names in ((claude_root, ('alpha', 'beta', 'gamma')),
                                (codex_root, ('alpha',))):
                for name in names:
                    (root / name).mkdir(parents=True)
                    (root / name / 'SKILL.md').write_text('name: %s\n' % name)
            # A directory with no SKILL.md is not a skill and must not be counted.
            (claude_root / 'notaskill').mkdir()
            saved = self.updates._skill_roots
            self.updates._skill_roots = lambda: (claude_root, codex_root)
            try:
                harness = self.updates._harness()
            finally:
                self.updates._skill_roots = saved
        self.assertEqual(harness['skills']['claude'], 3)
        self.assertEqual(harness['skills']['codex'], 1)
        # 🔴 Counts only, no verdict about the difference. Measured on a live box
        # 2026-09-01: of the 8 names Claude had and the Codex CLI did not, 2 were
        # opt-in canon (no wiring obligation) and 6 were local copies with no canon
        # at all. Which names a root is OWED is a judgment about the canon, and the
        # collector does not read the canon.
        self.assertNotIn('onlyClaude', harness['skills'])
        # The old total keeps its old meaning so an older reader is not broken by
        # the split that was added beside it.
        self.assertEqual(harness['skillsWired'], 4)

    def test_platform_and_plan_become_the_public_contract(self):
        calls = []
        package_info = {'packages': {
            'notes': {'source_class': 'shipped'},
            'external': {'source_class': 'explicit'},
        }}
        package_info_text = json.dumps(package_info)

        def run(argv, **kwargs):
            calls.append((argv, kwargs))
            if argv[1].endswith('airlock-update'):
                return types.SimpleNamespace(returncode=0,
                                             stdout='{"available":true,"changedCount":2,"ref":"main"}\n',
                                             stderr='')
            if argv[1].endswith('airlock-config'):
                return types.SimpleNamespace(returncode=0, stderr='', stdout=package_info_text)
            if argv[1].endswith('airlock-ledger'):
                self.assertEqual(kwargs['input_text'], package_info_text)
                return types.SimpleNamespace(returncode=0, stderr='',
                                             stdout='reinstall\tnotes\nupgrade-diff\tnotes\nupgrade-deactivate\texternal\n')
            self.fail('unexpected command: %r' % (argv,))

        self.updates._run = run
        root = Path('/fixture')
        self.assertEqual(self.updates._platform(root),
                         {'available': True, 'changedCount': 2, 'ref': 'main'})
        self.assertEqual(self.updates._apps(root), [
            {'id': 'external', 'action': 'upgrade', 'sourceClass': 'explicit'},
            {'id': 'notes', 'action': 'upgrade', 'sourceClass': 'shipped'},
        ])

    def test_explicit_lock_refusal_is_display_only_lock_mismatch(self):
        self.updates._run = lambda _argv, **_kwargs: types.SimpleNamespace(
            returncode=2, stdout='', stderr="package 'third-party': package lock digest mismatch\n")
        self.assertEqual(self.updates._apps(Path('/fixture')), [
            {'id': 'third-party', 'action': 'lock-mismatch', 'sourceClass': 'explicit'},
        ])

    def test_partial_or_malformed_snapshot_is_never_served(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'updates.json'
            self.updates.write_snapshot(path, {'checkedAt': '2026-09-01T00:00:00Z'})
            self.assertIsNone(self.updates.read_snapshot(path))
            path.write_text('{not-json', encoding='utf-8')
            self.assertIsNone(self.updates.read_snapshot(path))
            self.updates.write_snapshot(path, {
                'checkedAt': '2026-09-01T00:00:00Z',
                'platform': {'available': True, 'changedCount': True, 'ref': 'a' * 40},
                'apps': [], 'harness': {'codex': None, 'hooksDrift': False, 'skillsWired': True},
            })
            self.assertIsNone(self.updates.read_snapshot(path))

    def test_collection_failure_leaves_the_last_complete_snapshot_byte_for_byte(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'updates.json'
            old = {'checkedAt': '2026-09-01T00:00:00Z',
                   'platform': {'available': False, 'changedCount': 0, 'ref': 'a' * 40},
                   'apps': [],
                   'harness': {'codex': None, 'hooksDrift': False, 'skillsWired': 2}}
            self.updates.write_snapshot(path, old)
            original = path.read_bytes()
            saved_platform, saved_apps, saved_harness = (self.updates._platform,
                                                          self.updates._apps,
                                                          self.updates._harness)
            try:
                self.updates._platform = lambda _root: (_ for _ in ()).throw(RuntimeError('fetch failed'))
                self.updates._apps = lambda _root: self.fail('must stop after platform failure')
                self.updates._harness = lambda: self.fail('must stop after platform failure')
                with self.assertRaisesRegex(RuntimeError, 'fetch failed'):
                    self.updates.collect(Path('/fixture'), path)
            finally:
                self.updates._platform, self.updates._apps, self.updates._harness = (
                    saved_platform, saved_apps, saved_harness)
            self.assertEqual(path.read_bytes(), original)


import devmon_tokens as TOK  # noqa: E402  (imported here to sit with its own tests)
import devmon_accounts as TOKEN_ACCOUNTS  # noqa: E402

# Every credential fixture below carries this string where the real file carries a token.
# Nothing the checker returns may contain it — see NoTokenLeakTest, which is the reason
# the sentinel is a single constant rather than a different literal per fixture.
SENTINEL = 'sk-ant-FAKE-DO-NOT-LEAK-0123456789'


def _ms(dt):
    return int(dt.timestamp() * 1000)


class TokenFixtureMixin:
    """Writes FAKE credential files into a scratch dir. Never reads a real one."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.now = datetime(2026, 8, 9, 12, 0, tzinfo=timezone.utc)

    def _write(self, name, payload):
        path = os.path.join(self.tmp.name, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'w') as f:
            f.write(payload if isinstance(payload, str) else json.dumps(payload))
        return path

    def _claude(self, **oauth):
        base = {'accessToken': SENTINEL, 'refreshToken': SENTINEL,
                'scopes': ['user:inference'], 'subscriptionType': 'max'}
        base.update(oauth)
        return self._write('.credentials.json', {'claudeAiOauth': base})

    def _codex(self, last_refresh, auth_mode='chatgpt', nested=False):
        """The REAL layout: last_refresh sits at the top level, NOT inside `tokens`.

        Transcribed from an actual ~/.codex/auth.json rather than from where the field
        looks like it belongs. The first version of this fixture invented the nested
        shape, the checker was written to match the fixture, and the whole suite passed
        green against a checker that would have reported `unknown` on every real box.
        `nested=True` covers the fallback path only.
        """
        payload = {'OPENAI_API_KEY': None, 'auth_mode': auth_mode,
                   'tokens': {'id_token': SENTINEL, 'access_token': SENTINEL,
                              'refresh_token': SENTINEL, 'account_id': SENTINEL}}
        if nested:
            payload['tokens']['last_refresh'] = last_refresh
        else:
            payload['last_refresh'] = last_refresh
        return self._write('auth.json', payload)

    def _platform_raw(self, claude=None, codex=None):
        saved = PLATFORM_STATUS.LIVE, PLATFORM_STATUS.CODEX_AUTH
        try:
            PLATFORM_STATUS.LIVE = claude or os.path.join(self.tmp.name, 'missing-claude')
            PLATFORM_STATUS.CODEX_AUTH = codex or os.path.join(self.tmp.name, 'missing-codex')
            return PLATFORM_STATUS._raw_deadlines()
        finally:
            PLATFORM_STATUS.LIVE, PLATFORM_STATUS.CODEX_AUTH = saved

    def _provider_raw(self, provider, claude=None, codex=None):
        return self._platform_raw(claude, codex)['providers'][provider]


class ClaudeFreshnessTest(TokenFixtureMixin, unittest.TestCase):

    def test_plenty_of_time_is_ok(self):
        path = self._claude(expiresAt=_ms(self.now + timedelta(hours=6)),
                            refreshTokenExpiresAt=_ms(self.now + timedelta(days=20)))
        v = TOK.check_claude(self._provider_raw('claude', claude=path), self.now,
                             warn_hours=24)
        self.assertEqual(v['status'], TOK.OK)
        # The access token turning over in six hours is normal and must NOT warn; the
        # refresh deadline is what a person has to act on.
        self.assertEqual(v['deadline_field'], 'refreshTokenExpiresAt')

    def test_refresh_deadline_inside_the_window_is_expiring_soon(self):
        path = self._claude(expiresAt=_ms(self.now + timedelta(hours=3)),
                            refreshTokenExpiresAt=_ms(self.now + timedelta(hours=10)))
        v = TOK.check_claude(self._provider_raw('claude', claude=path), self.now,
                             warn_hours=24)
        self.assertEqual(v['status'], TOK.EXPIRING)
        self.assertEqual(v['seconds_remaining'], 10 * 3600)

    def test_past_deadline_is_expired(self):
        path = self._claude(expiresAt=_ms(self.now - timedelta(days=2)),
                            refreshTokenExpiresAt=_ms(self.now - timedelta(hours=1)))
        v = TOK.check_claude(self._provider_raw('claude', claude=path), self.now,
                             warn_hours=24)
        self.assertEqual(v['status'], TOK.EXPIRED)
        self.assertLess(v['seconds_remaining'], 0)

    def test_no_refresh_field_falls_back_to_the_access_deadline(self):
        path = self._claude(expiresAt=_ms(self.now + timedelta(hours=2)))
        v = TOK.check_claude(self._provider_raw('claude', claude=path), self.now,
                             warn_hours=24)
        self.assertEqual((v['status'], v['deadline_field']), (TOK.EXPIRING, 'expiresAt'))

    def test_a_missing_file_is_unknown_and_never_ok(self):
        v = TOK.check_claude(self._provider_raw('claude'), self.now)
        self.assertEqual(v['status'], TOK.UNKNOWN)
        self.assertEqual(v['reason'], 'missing')
        self.assertNotEqual(v['status'], TOK.OK)

    def test_malformed_json_is_unknown_not_a_crash(self):
        path = self._write('.credentials.json', '{"claudeAiOauth": {"expiresAt":')
        v = TOK.check_claude(self._provider_raw('claude', claude=path), self.now)
        self.assertEqual((v['status'], v['reason']), (TOK.UNKNOWN, 'malformed JSON'))

    def test_a_present_file_with_no_expiry_field_is_unknown(self):
        path = self._claude()      # tokens but no timestamps at all
        v = TOK.check_claude(self._provider_raw('claude', claude=path), self.now)
        self.assertEqual(v['status'], TOK.UNKNOWN)

    def test_a_boolean_is_not_a_timestamp(self):
        # json.loads turns `true` into a Python bool, which is an int. Read as epoch ms it
        # would be 1970 — i.e. a token that reads as long expired for the wrong reason.
        path = self._claude(expiresAt=True)
        raw = self._provider_raw('claude', claude=path)
        self.assertEqual(TOK.check_claude(raw, self.now)['status'], TOK.UNKNOWN)


class CodexFreshnessTest(TokenFixtureMixin, unittest.TestCase):

    def test_a_recent_refresh_is_ok(self):
        path = self._codex((self.now - timedelta(hours=2)).isoformat())
        v = TOK.check_codex(self._provider_raw('codex', codex=path), self.now,
                            stale_hours=24)
        self.assertEqual(v['status'], TOK.OK)
        # Pinned, because reading the wrong one of these two is invisible: it produces a
        # permanent `unknown` that looks exactly like "codex is not set up here".
        self.assertEqual(v['last_refresh_field'], 'last_refresh')

    def test_the_nested_layout_is_still_accepted(self):
        path = self._codex((self.now - timedelta(hours=2)).isoformat(), nested=True)
        v = TOK.check_codex(self._provider_raw('codex', codex=path), self.now,
                            stale_hours=24)
        self.assertEqual((v['status'], v['last_refresh_field']),
                         (TOK.OK, 'tokens.last_refresh'))

    def test_a_file_with_tokens_but_no_last_refresh_is_unknown(self):
        # The exact shape the field-name bug produced on every real box.
        path = self._write('auth.json', {'auth_mode': 'chatgpt',
                                         'tokens': {'access_token': SENTINEL}})
        raw = self._provider_raw('codex', codex=path)
        self.assertEqual(TOK.check_codex(raw, self.now)['status'], TOK.UNKNOWN)

    def test_a_stale_refresh_warns(self):
        path = self._codex((self.now - timedelta(days=4)).isoformat())
        v = TOK.check_codex(self._provider_raw('codex', codex=path), self.now,
                            stale_hours=24)
        self.assertEqual(v['status'], TOK.EXPIRING)

    def test_staleness_never_claims_expired(self):
        # last_refresh cannot prove death, only silence. Claiming `expired` from it would
        # be a verdict the data does not support.
        path = self._codex((self.now - timedelta(days=400)).isoformat())
        raw = self._provider_raw('codex', codex=path)
        self.assertEqual(TOK.check_codex(raw, self.now)['status'], TOK.EXPIRING)

    def test_api_key_mode_has_no_clock_to_age(self):
        path = self._codex((self.now - timedelta(days=400)).isoformat(), auth_mode='apikey')
        v = TOK.check_codex(self._provider_raw('codex', codex=path), self.now,
                            stale_hours=24)
        self.assertEqual(v['status'], TOK.OK)
        self.assertIn('api-key', v['detail'])

    def test_a_missing_file_is_unknown(self):
        v = TOK.check_codex(self._provider_raw('codex'), self.now)
        self.assertEqual((v['status'], v['reason']), (TOK.UNKNOWN, 'missing'))

    def test_malformed_json_is_unknown(self):
        path = self._write('auth.json', 'not json at all')
        raw = self._provider_raw('codex', codex=path)
        self.assertEqual(TOK.check_codex(raw, self.now)['status'], TOK.UNKNOWN)

    def test_a_future_refresh_is_unknown_not_freshest_possible(self):
        path = self._codex((self.now + timedelta(hours=3)).isoformat())
        raw = self._provider_raw('codex', codex=path)
        self.assertEqual(TOK.check_codex(raw, self.now)['status'], TOK.UNKNOWN)


class WorstStatusTest(unittest.TestCase):

    def test_unknown_outranks_ok(self):
        self.assertEqual(TOK.worst_status([{'status': TOK.OK}, {'status': TOK.UNKNOWN}]),
                         TOK.UNKNOWN)

    def test_expired_outranks_everything(self):
        self.assertEqual(
            TOK.worst_status([{'status': TOK.UNKNOWN}, {'status': TOK.EXPIRED},
                              {'status': TOK.EXPIRING}]), TOK.EXPIRED)


class NoTokenLeakTest(TokenFixtureMixin, unittest.TestCase):
    """The rule the whole module is built around, asserted rather than assumed.

    Not a review checklist item: a future contributor adding a 'raw' field for debugging
    would put a live credential into a JSON route, a dashboard card and a spool payload
    in one commit. This test is what stops that.
    """

    def test_no_credential_value_reaches_the_verdict(self):
        claude = self._claude(expiresAt=_ms(self.now + timedelta(hours=1)),
                              refreshTokenExpiresAt=_ms(self.now + timedelta(hours=2)))
        codex = self._codex((self.now - timedelta(days=9)).isoformat())
        raw = self._platform_raw(claude, codex)
        self.assertNotIn(SENTINEL, json.dumps(raw))
        snap = TOK.check_all(raw, now=self.now)
        blob = json.dumps(snap)
        self.assertNotIn(SENTINEL, blob)
        # Not just the sentinel: no field whose NAME says token may carry a value either.
        for provider in snap['providers']:
            for key, value in provider.items():
                if 'token' in key.lower():
                    self.assertNotIsInstance(value, str, key)

    def test_platform_cli_json_carries_no_token_value(self):
        # This is the boundary test, not a hand-written sanitized fixture: the real
        # platform command reads scratch credential files containing the sentinel and
        # its captured stdout becomes dev-monitor's input. Captured bytes are never
        # included in an assertion message.
        claude = self._claude(expiresAt=_ms(self.now + timedelta(hours=1)),
                               refreshTokenExpiresAt=_ms(self.now + timedelta(hours=2)))
        codex = self._codex(self.now.isoformat())
        binary = os.path.abspath(os.path.join(HERE, '..', '..', 'bin',
                                               'airlock-accounts-status'))
        # Exercise the public dispatch and captured stdout, not the extractor helper.
        # HOME/CODEX_HOME point at this test's scratch tree, so the real CLI opens only
        # fake fixtures while using exactly the argv that production consumers use.
        fake_home = os.path.join(self.tmp.name, 'home')
        claude_dir = os.path.join(fake_home, '.claude')
        codex_dir = os.path.join(fake_home, '.codex')
        os.makedirs(claude_dir)
        os.makedirs(codex_dir)
        shutil.copy2(claude, os.path.join(claude_dir, os.path.basename(claude)))
        shutil.copy2(codex, os.path.join(codex_dir, os.path.basename(codex)))
        env = dict(os.environ, HOME=fake_home, CODEX_HOME=codex_dir)
        proc = subprocess.run(
            [sys.executable, binary, 'raw-deadlines', '--json'], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=10)
        self.assertEqual(proc.returncode, 0)
        self.assertNotIn(SENTINEL.encode(), proc.stdout)
        raw = json.loads(proc.stdout.decode('utf-8'))
        self.assertNotIn(SENTINEL, json.dumps(TOK.check_all(raw, now=self.now)))

    def test_nominal_raw_string_fields_cannot_smuggle_a_token(self):
        codex = self._write('auth.json', {
            'auth_mode': SENTINEL, 'last_refresh': SENTINEL,
            'tokens': {'last_refresh': SENTINEL, 'access_token': SENTINEL}})
        raw = self._platform_raw(codex=codex)
        self.assertNotIn(SENTINEL, json.dumps(raw))
        fields = raw['providers']['codex']['fields']
        self.assertTrue(all(field['present'] for field in fields.values()))
        self.assertTrue(all(field['value'] is None for field in fields.values()))

    def test_the_snapshot_written_to_disk_carries_no_credential(self):
        claude = self._claude(expiresAt=_ms(self.now - timedelta(hours=1)))
        raw = self._platform_raw(claude, self._codex('nonsense'))
        snap = TOK.check_all(raw, now=self.now)
        path = os.path.join(self.tmp.name, 'state', 'token-freshness.json')
        TOK.write_snapshot(path, snap)
        with open(path) as f:
            self.assertNotIn(SENTINEL, f.read())
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)


class SnapshotTest(TokenFixtureMixin, unittest.TestCase):

    def test_a_never_written_snapshot_reads_as_none(self):
        self.assertIsNone(TOK.read_snapshot(os.path.join(self.tmp.name, 'absent.json')))

    def test_age_is_reported_so_a_dead_checker_shows_as_stale(self):
        path = os.path.join(self.tmp.name, 'snap.json')
        old = TOK.now_utc() - timedelta(hours=30)
        TOK.write_snapshot(path, {'checked_at': TOK.iso(old), 'providers': []})
        got = TOK.read_snapshot(path)
        self.assertGreater(got['age_seconds'], 29 * 3600)


class TokenRouteTest(TokenFixtureMixin, unittest.TestCase):
    """The route's gate, exercised through the handler's own dispatch decision."""

    def test_state_is_off_unless_configured(self):
        saved = DM.TOKEN_FRESHNESS
        try:
            DM.TOKEN_FRESHNESS = False
            self.assertEqual(DM._token_state(), 'off')
            DM.TOKEN_FRESHNESS = True
            self.assertEqual(DM._token_state(), 'on' if DM.TOKENS else 'unavailable')
        finally:
            DM.TOKEN_FRESHNESS = saved

    def test_requested_but_unimportable_is_unavailable_not_on(self):
        saved_flag, saved_mod = DM.TOKEN_FRESHNESS, DM.TOKENS
        try:
            DM.TOKEN_FRESHNESS, DM.TOKENS = True, None
            self.assertEqual(DM._token_state(), 'unavailable')
        finally:
            DM.TOKEN_FRESHNESS, DM.TOKENS = saved_flag, saved_mod

    def test_a_bad_threshold_falls_back_instead_of_taking_the_route_down(self):
        os.environ['AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS_WARN_HOURS'] = 'soon-ish'
        self.addCleanup(os.environ.pop, 'AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS_WARN_HOURS', None)
        self.assertEqual(
            DM._token_hours('AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS_WARN_HOURS', 24), 24)

    def test_live_route_preserves_a_platform_transport_failure_as_unknown(self):
        saved_tokens, saved_accounts = DM.TOKENS, DM.TOKEN_ACCOUNTS
        try:
            DM.TOKENS = TOK
            DM.TOKEN_ACCOUNTS = types.SimpleNamespace(
                raw_deadlines=lambda: (None, 'command-failed'))
            got = DM.token_freshness_info()
            self.assertEqual(got['source_error'], 'command-failed')
            self.assertEqual(got['worst'], TOK.UNKNOWN)
            self.assertTrue(all(v['status'] == TOK.UNKNOWN for v in got['providers']))
        finally:
            DM.TOKENS, DM.TOKEN_ACCOUNTS = saved_tokens, saved_accounts


class TokenAccountsTransportTest(TokenFixtureMixin, unittest.TestCase):
    """The subprocess ABI validates the public platform shape, not merely JSON syntax."""

    def _binary(self, payload):
        path = self._write('platform-status', '#!/usr/bin/env python3\n'
                           'import json\nprint(%r)\n' % json.dumps(payload))
        os.chmod(path, 0o700)
        return path

    def test_valid_platform_shape_crosses_the_d5_transport(self):
        payload = self._platform_raw()
        got, error = TOKEN_ACCOUNTS.raw_deadlines(
            {'AIRLOCK_DEV_MONITOR_ACCOUNTS_STATUS_BIN': self._binary(payload)})
        self.assertIsNone(error)
        self.assertEqual(got, payload)

    def test_bool_schema_and_missing_provider_are_rejected(self):
        for payload in ({'schema_version': True, 'providers': {'claude': {}, 'codex': {}}},
                        {'schema_version': 1, 'providers': {'claude': {}}}):
            got, error = TOKEN_ACCOUNTS.raw_deadlines(
                {'AIRLOCK_DEV_MONITOR_ACCOUNTS_STATUS_BIN': self._binary(payload)})
            self.assertIsNone(got)
            self.assertEqual(error, 'invalid-shape')


class TokenTimerCliTest(TokenFixtureMixin, unittest.TestCase):
    """The periodic half: what it writes, and what it publishes."""

    def _runner(self, raw, source_error=None):
        spec = importlib.util.spec_from_file_location(
            'token_freshness_cli', os.path.join(HERE, 'token-freshness.py'))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.ACCOUNTS = types.SimpleNamespace(
            raw_deadlines=lambda: (raw, source_error))
        return module

    def _spool(self):
        spool = os.path.join(self.tmp.name, 'spool')
        for d in ('tmp', 'new', 'processing', 'bad'):
            os.makedirs(os.path.join(spool, d), mode=0o700)
        return spool

    def test_it_writes_a_snapshot_and_publishes_only_what_needs_attention(self):
        spool = self._spool()
        snapshot = os.path.join(self.tmp.name, 'snap.json')
        claude = self._claude(refreshTokenExpiresAt=_ms(TOK.now_utc() - timedelta(hours=2)))
        codex = self._codex(TOK.iso(TOK.now_utc()))
        cli = self._runner(self._platform_raw(claude, codex))
        rc = cli.main(['--snapshot', snapshot, '--spool', spool, '--quiet'])
        self.assertEqual(rc, 0)
        published = os.listdir(os.path.join(spool, 'new'))
        # One card: claude is expired, codex was refreshed a moment ago.
        self.assertEqual(len(published), 1, published)
        with open(os.path.join(spool, 'new', published[0])) as f:
            card = json.load(f)
        MSG.validate_payload(card)          # the collector must accept what we publish
        self.assertEqual(card['urgency'], 'urgent')
        self.assertNotIn(SENTINEL, json.dumps(card))
        with open(snapshot) as f:
            self.assertEqual(json.load(f)['worst'], TOK.EXPIRED)

    def test_a_healthy_box_publishes_nothing_but_still_records_the_check(self):
        spool = self._spool()
        snapshot = os.path.join(self.tmp.name, 'snap.json')
        claude = self._claude(refreshTokenExpiresAt=_ms(TOK.now_utc() + timedelta(days=30)))
        codex = self._codex(TOK.iso(TOK.now_utc()))
        cli = self._runner(self._platform_raw(claude, codex))
        self.assertEqual(0, cli.main(['--snapshot', snapshot, '--spool', spool, '--quiet']))
        self.assertEqual(os.listdir(os.path.join(spool, 'new')), [])
        self.assertTrue(os.path.exists(snapshot))

    def test_an_absent_credentials_file_does_not_generate_a_daily_card(self):
        # It is still `unknown` in the snapshot — it just does not push. A provider that
        # was never set up on this box must not train the reader to ignore the channel.
        spool = self._spool()
        snapshot = os.path.join(self.tmp.name, 'snap.json')
        cli = self._runner(self._platform_raw())
        self.assertEqual(0, cli.main(['--snapshot', snapshot, '--spool', spool, '--quiet']))
        self.assertEqual(os.listdir(os.path.join(spool, 'new')), [])
        with open(snapshot) as f:
            self.assertEqual(json.load(f)['worst'], TOK.UNKNOWN)

    def test_platform_failure_writes_unknown_snapshot_then_exits_nonzero(self):
        snapshot = os.path.join(self.tmp.name, 'platform-failed.json')
        cli = self._runner(None, 'invoke-failed')
        self.assertEqual(
            cli.main(['--snapshot', snapshot, '--no-spool', '--quiet']), 1)
        with open(snapshot) as f:
            got = json.load(f)
        self.assertEqual(got['source_error'], 'invoke-failed')
        self.assertEqual(got['worst'], TOK.UNKNOWN)

    def test_an_unreadable_file_does_publish(self):
        spool = self._spool()
        broken = self._write('.credentials.json', '{oops')
        cli = self._runner(self._platform_raw(claude=broken))
        self.assertEqual(0, cli.main(['--snapshot', os.path.join(self.tmp.name, 's.json'),
                                      '--spool', spool, '--quiet']))
        self.assertEqual(len(os.listdir(os.path.join(spool, 'new'))), 1)


@contextlib.contextmanager
def live_wrapper():
    """A real, running process whose cmdline looks like the update wrapper's.

    devmon_update_exec.pid_alive matches on the command line, not on a bare signal
    probe, so a test that wants "the wrapper is alive" has to produce a process that
    would actually match. The extra argv element is the module name — the same token
    that appears in the real argv the backend builds.
    """
    proc = subprocess.Popen(
        [sys.executable, '-c', 'import time; time.sleep(30)', 'devmon_update_exec.py'])
    # Popen returns after the fork, and until the exec completes the child still shows
    # THIS process's command line. Yielding there made the assertion flaky (4 of 6 runs
    # measured, 2026-09-01) in the direction that hides a bug: the wrapper reads as
    # dead. Read /proc directly rather than calling pid_alive, so the helper does not
    # wait on the function the test is about to measure.
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            if b'devmon_update_exec' in Path('/proc/%d/cmdline' % proc.pid).read_bytes():
                break
        except OSError:
            pass
        time.sleep(0.02)
    else:
        proc.kill()
        proc.wait()
        raise unittest.SkipTest('could not observe a child command line on this box')
    try:
        yield proc.pid
    finally:
        proc.kill()
        proc.wait()


class UpdateExecModuleTest(unittest.TestCase):
    """devmon_update_exec on its own: the lock probe, liveness, argv and recovery.

    Every assertion here is about a claim the panel makes to a person, so the ones
    that matter most are the negative ones — "nothing is running", "there is nothing
    to roll back" — measured rather than assumed.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name) / 'update-run'
        UPX.ensure_dirs(self.dir)

    def tearDown(self):
        self.tmp.cleanup()

    # ---- the updater's mutex ------------------------------------------------
    def _repo(self):
        root = Path(self.tmp.name) / 'checkout'
        root.mkdir()
        rc = subprocess.call(['git', 'init', '-q', str(root)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if rc != 0:
            self.skipTest('git is not available')
        return root

    def test_the_lock_probe_has_a_positive_control(self):
        """The whole point of the probe is to be able to say 'busy'. Prove it can.

        Without this the free/busy answer is untestable in the direction that matters:
        a probe that always answered False would pass every other assertion here.
        """
        import fcntl
        root = self._repo()
        self.assertIs(UPX.updater_busy(root), False)         # control: free
        git = UPX.git_dir(root)
        self.assertIsNotNone(git)
        descriptor = os.open(str(git), os.O_RDONLY)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertIs(UPX.updater_busy(root), True)      # the same lock airlock-update takes
        finally:
            os.close(descriptor)
        self.assertIs(UPX.updater_busy(root), False)         # and it clears

    def test_the_probe_never_takes_the_lock_it_measures(self):
        """A probe that acquired the mutex would kill a real update started one tick later."""
        import fcntl
        root = self._repo()
        for _ in range(5):
            UPX.updater_busy(root)
        git = UPX.git_dir(root)
        descriptor = os.open(str(git), os.O_RDONLY)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)   # raises if we held it
        finally:
            os.close(descriptor)

    def test_a_directory_that_is_not_a_checkout_is_not_busy(self):
        self.assertIs(UPX.updater_busy(Path(self.tmp.name) / 'nowhere'), False)

    # ---- liveness -----------------------------------------------------------
    def test_a_record_with_no_pid_is_starting_then_interrupted(self):
        record = UPX.start_record('r1', 'platform', None)
        self.assertEqual(UPX.observed(record)['status'], 'starting')
        stale = dict(record, startedAt='2020-01-01T00:00:00Z')
        self.assertEqual(UPX.observed(stale)['status'], 'interrupted')

    def test_a_dead_pid_resolves_to_interrupted_and_a_live_one_does_not(self):
        record = dict(UPX.start_record('r1', 'platform', None), status='running')
        # pid 1 exists and is very much alive — and is not this wrapper. That is the
        # pid-reuse case, and the reason liveness is checked by cmdline rather than by
        # a bare kill(pid, 0): after a reboot the recorded pid belongs to something else.
        self.assertEqual(UPX.observed(dict(record, pid=1))['status'], 'interrupted')
        # This very process is alive too, and also is not the wrapper.
        self.assertEqual(UPX.observed(dict(record, pid=os.getpid()))['status'],
                         'interrupted')
        with live_wrapper() as pid:
            self.assertEqual(UPX.observed(dict(record, pid=pid))['status'], 'running')

    def test_a_terminal_record_is_returned_unchanged(self):
        record = dict(UPX.start_record('r1', 'platform', None),
                      status='done', exitCode=0, pid=1)
        self.assertEqual(UPX.observed(record), record)

    # ---- the plan -----------------------------------------------------------
    def test_the_app_id_is_recorded_but_never_placed_on_a_command_line(self):
        """Both buttons run the same command; the id is provenance, not an argument."""
        plan = UPX.build_plan(Path('/opt/airlock'), self.dir, 'r1', 'app', 'notes')
        self.assertNotIn('notes', ' '.join(plan['exec'][:1]))
        self.assertIn('--app', plan['exec'])
        self.assertTrue(os.path.isabs(plan['exec'][0]))
        self.assertEqual(plan['cwd'], plan['cwd_root'])

    def test_the_plan_pins_cwd_and_its_root_to_the_checkout(self):
        plan = UPX.build_plan(Path('/opt/airlock'), self.dir, 'r1', 'platform', None)
        self.assertEqual((plan['cwd'], plan['cwd_root']), ('/opt/airlock', '/opt/airlock'))
        self.assertNotIn('--app', plan['exec'])

    # ---- the record ---------------------------------------------------------
    def test_a_truncated_record_is_not_a_run(self):
        UPX.run_path(self.dir).write_text('{"runId": ')
        self.assertIsNone(UPX.read_record(self.dir))

    def test_a_superseded_wrapper_refuses_to_write_over_the_live_record(self):
        UPX.write_record(self.dir, UPX.start_record('current', 'platform', None))
        with self.assertRaises(SystemExit):
            UPX._claim(self.dir, 'older')
        self.assertEqual(UPX.read_record(self.dir)['runId'], 'current')

    # ---- summaries and recovery --------------------------------------------
    def _fake_status(self, body, code=0):
        root = Path(self.tmp.name) / 'fakeroot'
        (root / 'bin').mkdir(parents=True, exist_ok=True)
        (root / 'bin' / 'airlock-status').write_text(
            'import sys\nsys.stdout.write(%r)\nsys.exit(%d)\n' % (body, code))
        return root

    def test_a_status_summary_carries_the_revision_and_only_the_problems(self):
        document = json.dumps({
            'verdict': 'warn', 'exit_code': 0,
            'counts': {'ok': 13, 'warn': 1, 'fail': 0, 'unchecked': 0},
            'checks': [{'id': 'install.revision', 'status': 'ok', 'detail': 'abc123'},
                       {'id': 'units.active', 'status': 'warn', 'detail': 'one unit is old'},
                       {'id': 'gate.owner', 'status': 'ok', 'detail': 'fine'}],
        })
        got = UPX.status_summary(self._fake_status(document))
        self.assertEqual((got['rc'], got['verdict'], got['revision']), (0, 'warn', 'abc123'))
        self.assertEqual([p['id'] for p in got['problems']], ['units.active'])

    def test_a_status_tool_that_says_nothing_useful_is_a_value_not_a_crash(self):
        got = UPX.status_summary(self._fake_status('not json at all', code=2))
        self.assertEqual(got['rc'], 2)
        self.assertIn('JSON', got['error'])
        missing = UPX.status_summary(Path(self.tmp.name) / 'absent')
        self.assertEqual(missing['rc'], 127)

    def test_recovery_is_offered_only_where_the_updater_armed_it(self):
        root = self._repo()
        unarmed = UPX.recovery_hint(root)
        self.assertIs(unarmed['available'], False)
        self.assertIn('--rollback', unarmed['command'])
        self.assertIn('reason', unarmed)
        armed_dir = UPX.git_dir(root) / 'airlock-update-rollback'
        armed_dir.mkdir(parents=True)
        (armed_dir / 'airlock-update').write_text('#!/usr/bin/env bash\n')
        armed = UPX.recovery_hint(root)
        self.assertIs(armed['available'], True)
        self.assertIn(str(armed_dir / 'airlock-update'), armed['command'])
        self.assertIn('--rollback', armed['command'])


class UpdateExecRouteTest(unittest.TestCase):
    """The two new owner routes, driven through the real handler."""

    @classmethod
    def setUpClass(cls):
        import http.server, threading
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name) / 'checkout'
        (cls.root / 'bin').mkdir(parents=True)
        cls.dir = Path(cls.tmp.name) / 'update-run'
        DM.UPDATES_OWNER_CONFIG = {'owner': 'me@example.test', 'secret': 's3cr3t'}
        DM.UPDATE_EXEC_CONFIG = {
            'root': cls.root, 'dir': cls.dir,
            'plan_dir': str(UPX.plan_dir(cls.dir)),
            'sentinel_dir': str(UPX.sentinel_dir(cls.dir)),
            'session': 'devmon-test', 'cwd_root': str(cls.root), 'agent': {},
            'runner': os.path.join(BACKEND, 'action_runner.py'),
        }
        UPX.ensure_dirs(cls.dir)
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), DM.Handler)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        DM.UPDATES_OWNER_CONFIG = None
        DM.UPDATE_EXEC_CONFIG = None
        cls.tmp.cleanup()

    def setUp(self):
        self.launched = []
        self._launch = DM._launch_run
        DM._launch_run = lambda run_id, plan, cfg=None, name=None: (
            self.launched.append((run_id, plan, cfg, name)) or ('ok', '1:@7'))
        self._updates = DM.UPDATES
        DM.UPDATES = self._snapshot([{'id': 'notes', 'action': 'upgrade',
                                      'sourceClass': 'shipped'},
                                     {'id': 'orca', 'action': 'lock-mismatch',
                                      'sourceClass': 'explicit'}])
        try:
            UPX.run_path(self.dir).unlink()
        except FileNotFoundError:
            pass

    def tearDown(self):
        DM._launch_run = self._launch
        DM.UPDATES = self._updates

    @staticmethod
    def _snapshot(apps):
        class Snapshot:
            @staticmethod
            def read_snapshot():
                return {'checkedAt': '2026-09-01T00:00:00Z', 'platform': None,
                        'apps': apps,
                        'harness': {'codex': None, 'hooksDrift': False, 'skillsWired': 0}}
        return Snapshot

    def _req(self, method, path, body=None, owner=True, origin=True):
        import http.client
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        headers = {'Content-Type': 'application/json'}
        if owner:
            headers['X-Devmon-Owner'] = 'me@example.test'
            headers['X-Devmon-Proxy-Secret'] = 's3cr3t'
        if origin:
            headers['Origin'] = 'http://127.0.0.1:%d' % self.port
        conn.request(method, path, body=body, headers=headers)
        r = conn.getresponse()
        data = r.read()
        conn.close()
        return r.status, json.loads(data or b'{}')

    def _execute(self, payload, **kw):
        return self._req('POST', '/api/owner/updates/execute',
                         body=json.dumps(payload).encode(), **kw)

    # ---- the gate -----------------------------------------------------------
    def test_execution_is_reachable_on_a_box_with_the_message_console_off(self):
        """The reason this route exists at all — `messages = false` is the default.

        Before this, the panel showed an update it could not start: detection came
        through the split owner gate (#291) and execution was still behind the message
        console's, so on a default box the button was a 404.
        """
        saved = DM.OWNER_CONFIG
        DM.OWNER_CONFIG = None
        try:
            status, payload = self._req('GET', '/api/owner/updates/run')
            self.assertEqual(status, 200, payload)
            status, payload = self._execute({'action': 'platform'})
            self.assertEqual(status, 200, payload)
            self.assertEqual(len(self.launched), 1)
        finally:
            DM.OWNER_CONFIG = saved

    def test_a_stranger_reaches_neither_route(self):
        self.assertEqual(self._req('GET', '/api/owner/updates/run', owner=False)[0], 403)
        self.assertEqual(self._execute({'action': 'platform'}, owner=False)[0], 403)

    def test_a_cross_origin_post_is_refused_before_the_body_is_read(self):
        self.assertEqual(self._execute({'action': 'platform'}, origin=False)[0], 403)

    def test_both_routes_404_when_execution_is_not_configured(self):
        saved = DM.UPDATE_EXEC_CONFIG
        DM.UPDATE_EXEC_CONFIG = None
        try:
            self.assertEqual(self._req('GET', '/api/owner/updates/run')[0], 404)
            self.assertEqual(self._execute({'action': 'platform'})[0], 404)
        finally:
            DM.UPDATE_EXEC_CONFIG = saved

    # ---- what may be asked for ---------------------------------------------
    def test_the_platform_action_launches_the_updater(self):
        status, payload = self._execute({'action': 'platform'})
        self.assertEqual(status, 200, payload)
        run_id, plan, cfg, name = self.launched[0]
        self.assertEqual(name, run_id)
        self.assertEqual(plan['cwd'], str(self.root))
        self.assertTrue(plan['exec'][1].endswith('devmon_update_exec.py'))
        self.assertEqual(UPX.read_record(self.dir)['runId'], run_id)

    def test_a_pending_app_launches_the_same_command_and_records_which_row(self):
        status, payload = self._execute({'action': 'app', 'id': 'notes'})
        self.assertEqual(status, 200, payload)
        record = UPX.read_record(self.dir)
        self.assertEqual((record['action'], record['appId']), ('app', 'notes'))

    def test_a_lock_mismatch_app_cannot_be_executed(self):
        """🔴 Owner decision LOCK_UI_V1, enforced server-side and not only by a
        disabled button: re-approving a package lock is a terminal procedure."""
        status, payload = self._execute({'action': 'app', 'id': 'orca'})
        self.assertEqual((status, payload['error']), (409, 'app_not_pending'))
        self.assertEqual(self.launched, [])

    def test_an_app_the_snapshot_never_listed_is_refused(self):
        status, payload = self._execute({'action': 'app', 'id': 'invented'})
        self.assertEqual((status, payload['error']), (409, 'app_not_pending'))

    def test_a_malformed_app_id_is_refused_before_the_snapshot_is_consulted(self):
        for bad in ('../../etc', 'Notes', '', 'a' * 40, None, 5):
            status, payload = self._execute({'action': 'app', 'id': bad})
            self.assertEqual((status, payload['error']), (400, 'bad_app_id'), bad)
        self.assertEqual(self.launched, [])

    def test_an_unknown_action_runs_nothing(self):
        for body in ({'action': 'review'}, {'action': 'harness:codex'}, {}, {'action': None}):
            status, payload = self._execute(body)
            self.assertEqual((status, payload['error']), (400, 'bad_action'), body)
        self.assertEqual(self.launched, [])

    # ---- one at a time ------------------------------------------------------
    def test_a_live_run_refuses_a_second_launch(self):
        with live_wrapper() as pid:
            UPX.write_record(self.dir, dict(UPX.start_record('live', 'platform', None),
                                            status='running', pid=pid))
            status, payload = self._execute({'action': 'platform'})
            self.assertEqual((status, payload['error']), (409, 'run_active'))
            self.assertEqual(self.launched, [])

    def test_a_dead_run_does_not_block_forever(self):
        record = dict(UPX.start_record('dead', 'platform', None), status='running', pid=1)
        UPX.write_record(self.dir, record)
        self.assertEqual(self._execute({'action': 'platform'})[0], 200)

    def test_a_held_updater_mutex_refuses_a_launch(self):
        saved = UPX.updater_busy
        UPX.updater_busy = lambda root: True
        try:
            status, payload = self._execute({'action': 'platform'})
            self.assertEqual((status, payload['error']), (409, 'updater_busy'))
            self.assertEqual(self.launched, [])
        finally:
            UPX.updater_busy = saved

    def test_an_unmeasurable_mutex_does_not_take_the_button_away(self):
        """`None` is 'we could not look'. Treating it as 'held' would disable the one
        control on a box whose /proc is unavailable, for no measured reason."""
        saved = UPX.updater_busy
        UPX.updater_busy = lambda root: None
        try:
            self.assertEqual(self._execute({'action': 'platform'})[0], 200)
        finally:
            UPX.updater_busy = saved

    # ---- a launch that never produced a window ------------------------------
    def test_a_failed_launch_closes_its_own_record(self):
        DM._launch_run = lambda *a, **k: ('nowindow', None)
        status, payload = self._execute({'action': 'platform'})
        self.assertEqual((status, payload['error']), (500, 'launch_failed'))
        record = UPX.read_record(self.dir)
        self.assertEqual(record['status'], 'failed')
        self.assertIn('tmux', record['note'])
        # And the next attempt is not blocked by the corpse of the last one.
        DM._launch_run = lambda run_id, plan, cfg=None, name=None: ('ok', '1:@7')
        self.assertEqual(self._execute({'action': 'platform'})[0], 200)

    def test_an_ambiguous_launch_is_a_503_and_says_so_in_the_record(self):
        DM._launch_run = lambda *a, **k: ('ambiguous', None)
        status, _ = self._execute({'action': 'platform'})
        self.assertEqual(status, 503)
        self.assertEqual(UPX.read_record(self.dir)['status'], 'failed')

    # ---- reading the state --------------------------------------------------
    def test_the_run_route_reports_liveness_rather_than_the_last_written_status(self):
        UPX.write_record(self.dir, dict(UPX.start_record('gone', 'platform', None),
                                        status='running', pid=1))
        status, payload = self._req('GET', '/api/owner/updates/run')
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload['run']['status'], 'interrupted')
        self.assertIn('busy', payload)

    def test_the_run_route_answers_with_no_run_at_all(self):
        status, payload = self._req('GET', '/api/owner/updates/run')
        self.assertEqual((status, payload['run']), (200, None))


class UpdateExecEndToEndTest(unittest.TestCase):
    """The wrapper, run as the process the tmux window really starts.

    Everything above this in the file is the backend's view of a run. This is the run:
    a scratch checkout, a real subprocess, and the record a person's panel then reads.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / 'checkout'
        (self.root / 'bin').mkdir(parents=True)
        if subprocess.call(['git', 'init', '-q', str(self.root)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) != 0:
            self.skipTest('git is not available')
        self.dir = Path(self.tmp.name) / 'update-run'
        UPX.ensure_dirs(self.dir)
        self.counter = Path(self.tmp.name) / 'revision'
        self.counter.write_text('rev-before')
        # `airlock-status` is invoked through the interpreter, `airlock-update` through
        # bash — the same two spellings the real ones use, so the stand-ins exercise the
        # real invocation and not a friendlier one.
        (self.root / 'bin' / 'airlock-status').write_text(
            'import json, pathlib, sys\n'
            'rev = pathlib.Path(%r).read_text()\n'
            'print(json.dumps({"verdict": "ok", "exit_code": 0,\n'
            '  "counts": {"ok": 14, "warn": 0, "fail": 0, "unchecked": 0},\n'
            '  "checks": [{"id": "install.revision", "status": "ok", "detail": rev}]}))\n'
            % str(self.counter))

    def tearDown(self):
        self.tmp.cleanup()

    def _updater(self, body):
        (self.root / 'bin' / 'airlock-update').write_text('#!/usr/bin/env bash\n' + body)

    def _run(self, run_id='e2e', action='platform', app_id=None):
        UPX.write_record(self.dir, UPX.start_record(run_id, action, app_id))
        proc = subprocess.run(
            UPX.build_exec_argv(self.root, self.dir, run_id, action, app_id),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=120)
        return proc, UPX.read_record(self.dir)

    def test_a_successful_run_records_the_before_and_after_status_and_the_new_revision(self):
        """The card's success condition, measured: rc=0, and install.revision moved."""
        self._updater('printf rev-after > %r\nexit 0\n' % str(self.counter))
        proc, record = self._run()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual((record['status'], record['exitCode']), ('done', 0))
        self.assertEqual(record['before']['rc'], 0)
        self.assertEqual(record['after']['rc'], 0)
        self.assertEqual(record['before']['revision'], 'rev-before')
        self.assertEqual(record['after']['revision'], 'rev-after')
        self.assertIsNone(record['recovery'])
        self.assertIsNotNone(record['endedAt'])

    def test_a_failing_run_carries_the_rollback_command_the_updater_armed(self):
        """The card's second requirement: a failure has to name its recovery."""
        armed = UPX.git_dir(self.root) / 'airlock-update-rollback'
        armed.mkdir(parents=True)
        (armed / 'airlock-update').write_text('#!/usr/bin/env bash\n')
        self._updater('echo "설치가 실패했습니다" >&2\nexit 1\n')
        proc, record = self._run()
        self.assertEqual(proc.returncode, 1)
        self.assertEqual((record['status'], record['exitCode']), ('failed', 1))
        self.assertIs(record['recovery']['available'], True)
        self.assertIn('--rollback', record['recovery']['command'])
        self.assertIn(str(armed / 'airlock-update'), record['recovery']['command'])
        # The after-status is still taken: a failed update leaves a box in some state,
        # and "what is it now" is the first thing the panel is asked.
        self.assertEqual(record['after']['rc'], 0)

    def test_a_failure_before_the_updater_armed_recovery_says_so(self):
        self._updater('exit 1\n')
        _proc, record = self._run()
        self.assertIs(record['recovery']['available'], False)
        self.assertIn('기준점', record['recovery']['reason'])

    def test_an_updater_that_cannot_run_is_a_recorded_failure_not_a_traceback(self):
        proc, record = self._run()                     # no bin/airlock-update at all
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(record['status'], 'failed')
        self.assertIsNotNone(record['after'])

    def test_a_superseded_wrapper_exits_without_touching_the_live_record(self):
        UPX.write_record(self.dir, dict(UPX.start_record('newer', 'platform', None),
                                        status='running', pid=4242))
        self._updater('exit 0\n')
        proc = subprocess.run(UPX.build_exec_argv(self.root, self.dir, 'older', 'platform', None),
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                              timeout=60)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn('superseded', proc.stderr)
        record = UPX.read_record(self.dir)
        self.assertEqual((record['runId'], record['status']), ('newer', 'running'))

    def test_the_run_is_visible_as_running_while_it_runs(self):
        """The panel's 'in progress' line is a real observation, not an optimistic guess."""
        gate = Path(self.tmp.name) / 'gate'
        self._updater('while [ ! -e %r ]; do sleep 0.05; done\nexit 0\n' % str(gate))
        UPX.write_record(self.dir, UPX.start_record('slow', 'platform', None))
        proc = subprocess.Popen(
            UPX.build_exec_argv(self.root, self.dir, 'slow', 'platform', None),
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 60
            seen = None
            while time.monotonic() < deadline:
                record = UPX.read_record(self.dir)
                if record and record.get('before') is not None:
                    seen = UPX.observed(record)
                    break
                time.sleep(0.05)
            self.assertIsNotNone(seen, 'the wrapper never reached its running state')
            self.assertEqual(seen['status'], 'running')
            self.assertEqual(seen['pid'], proc.pid)
        finally:
            gate.write_text('go')
            proc.wait(timeout=60)
        self.assertEqual(UPX.read_record(self.dir)['status'], 'done')


class UpdateExecThroughTmuxTest(unittest.TestCase):
    """The whole chain the owner's click really takes: plan file -> action_runner -> tmux.

    Skipped where tmux is absent, which is the honest answer rather than a green run
    that measured nothing: the same absence makes the feature itself unavailable, and
    the backend answers `launch_failed` for it (asserted in UpdateExecRouteTest).
    """

    def setUp(self):
        if shutil.which('tmux') is None:
            self.skipTest('tmux is not installed')
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / 'checkout'
        (self.root / 'bin').mkdir(parents=True)
        (self.root / 'bin' / 'airlock-status').write_text(
            'import json\nprint(json.dumps({"verdict": "ok", "exit_code": 0,\n'
            '  "counts": {"ok": 1, "warn": 0, "fail": 0, "unchecked": 0},\n'
            '  "checks": [{"id": "install.revision", "status": "ok", "detail": "abc"}]}))\n')
        (self.root / 'bin' / 'airlock-update').write_text('#!/usr/bin/env bash\nexit 0\n')
        self.dir = Path(self.tmp.name) / 'update-run'
        UPX.ensure_dirs(self.dir)
        self.session = 'devmon-e2e-%d' % os.getpid()

    def tearDown(self):
        subprocess.call(['tmux', 'kill-session', '-t', self.session],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.tmp.cleanup()

    def test_a_plan_launched_the_real_way_finishes_and_leaves_a_terminal_record(self):
        cfg = {'root': self.root, 'dir': self.dir,
               'plan_dir': str(UPX.plan_dir(self.dir)),
               'sentinel_dir': str(UPX.sentinel_dir(self.dir)),
               'session': self.session, 'cwd_root': str(self.root), 'agent': {},
               'runner': os.path.join(BACKEND, 'action_runner.py')}
        run_id = 'tmux-e2e'
        UPX.write_record(self.dir, UPX.start_record(run_id, 'platform', None))
        plan = UPX.build_plan(self.root, self.dir, run_id, 'platform', None)
        outcome, target = DM._launch_run(run_id, plan, cfg, run_id)
        self.assertEqual(outcome, 'ok', target)
        # Waits for the AFTER reading, not merely for a terminal status: the wrapper
        # publishes the exit code first and the after-status a moment later, so that a
        # panel refreshing in between still learns the run ended. (The panel tolerates
        # that gap — airlockUpdRunLine guards on `run.after` — but a test that stopped
        # at the status would race it and read `after: null`.)
        deadline = time.monotonic() + 120
        record = None
        while time.monotonic() < deadline:
            record = UPX.read_record(self.dir)
            if record and record.get('status') in ('done', 'failed') \
                    and record.get('after') is not None:
                break
            time.sleep(0.1)
        self.assertIsNotNone(record)
        self.assertEqual(record['status'], 'done', record)
        self.assertEqual(record['exitCode'], 0)
        self.assertEqual(record['after']['revision'], 'abc')
        # action_runner's own completion signal, on the same run.
        self.assertTrue((UPX.sentinel_dir(self.dir) / (run_id + '.done')).exists())




class HarnessRouteTest(unittest.TestCase):
    """The 하네스 section's two routes: what may be pressed, and what may not.

    Deliberately a separate fixture from UpdateExecRouteTest, mirroring the split in
    the code itself: a Codex CLI upgrade and `bin/airlock-update` share no mutex, no
    record and no failure, and a test that shared one would stop being able to show it.
    """

    @classmethod
    def setUpClass(cls):
        import http.server, threading
        cls.tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls.tmp.name) / 'checkout'
        (cls.root / 'bin').mkdir(parents=True)
        cls.dir = Path(cls.tmp.name) / 'harness-run'
        DM.UPDATES_OWNER_CONFIG = {'owner': 'me@example.test', 'secret': 's3cr3t'}
        DM.HARNESS_EXEC_CONFIG = {
            'root': cls.root, 'dir': cls.dir,
            'plan_dir': str(UPX.plan_dir(cls.dir)),
            'sentinel_dir': str(UPX.sentinel_dir(cls.dir)),
            'session': 'devmon-test', 'cwd_root': str(cls.root), 'agent': {},
            'runner': os.path.join(BACKEND, 'action_runner.py'),
        }
        UPX.ensure_dirs(cls.dir)
        cls.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), DM.Handler)
        cls.port = cls.server.server_address[1]
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        DM.UPDATES_OWNER_CONFIG = None
        DM.HARNESS_EXEC_CONFIG = None
        cls.tmp.cleanup()

    def setUp(self):
        self.launched = []
        self._launch = DM._launch_run
        DM._launch_run = lambda run_id, plan, cfg=None, name=None: (
            self.launched.append((run_id, plan, cfg, name)) or ('ok', '1:@7'))
        self.started = []
        self._check_call = DM.subprocess.check_call
        DM.subprocess.check_call = lambda argv, **kw: self.started.append(argv)
        try:
            UPX.run_path(self.dir).unlink()
        except FileNotFoundError:
            pass

    def tearDown(self):
        DM._launch_run = self._launch
        DM.subprocess.check_call = self._check_call

    def _req(self, method, path, body=None, owner=True, origin=True):
        import http.client
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        headers = {'Content-Type': 'application/json'}
        if owner:
            headers['X-Devmon-Owner'] = 'me@example.test'
            headers['X-Devmon-Proxy-Secret'] = 's3cr3t'
        if origin:
            headers['Origin'] = 'http://127.0.0.1:%d' % self.port
        conn.request(method, path, body=body, headers=headers)
        r = conn.getresponse()
        data = r.read()
        conn.close()
        return r.status, json.loads(data or b'{}')

    def _execute(self, payload, **kw):
        return self._req('POST', '/api/owner/harness/execute',
                         body=json.dumps(payload).encode(), **kw)

    # ---- the gate -----------------------------------------------------------
    def test_the_routes_work_with_the_message_console_off(self):
        """`messages = false` is the default, and the harness section is not a console
        feature: it hangs off the update detection gate, exactly as execution does."""
        saved = DM.OWNER_CONFIG
        DM.OWNER_CONFIG = None
        try:
            self.assertEqual(self._req('GET', '/api/owner/harness/run')[0], 200)
            self.assertEqual(self._execute({'action': 'codex'})[0], 200)
        finally:
            DM.OWNER_CONFIG = saved

    def test_a_stranger_reaches_neither_route(self):
        self.assertEqual(self._req('GET', '/api/owner/harness/run', owner=False)[0], 403)
        self.assertEqual(self._execute({'action': 'codex'}, owner=False)[0], 403)

    def test_a_cross_origin_post_is_refused_before_the_body_is_read(self):
        self.assertEqual(self._execute({'action': 'codex'}, origin=False)[0], 403)

    def test_both_routes_404_when_harness_execution_is_not_configured(self):
        saved = DM.HARNESS_EXEC_CONFIG
        DM.HARNESS_EXEC_CONFIG = None
        try:
            self.assertEqual(self._req('GET', '/api/owner/harness/run')[0], 404)
            self.assertEqual(self._execute({'action': 'codex'})[0], 404)
        finally:
            DM.HARNESS_EXEC_CONFIG = saved

    # ---- what may be asked for ---------------------------------------------
    def test_the_codex_action_launches_the_harness_wrapper(self):
        status, payload = self._execute({'action': 'codex'})
        self.assertEqual(status, 200, payload)
        run_id, plan, cfg, name = self.launched[0]
        self.assertEqual(name, run_id)
        self.assertTrue(plan['exec'][1].endswith('devmon_harness.py'))
        record = UPX.read_record(self.dir)
        self.assertEqual((record['runId'], record['action'], record['status']),
                         (run_id, 'codex', 'starting'))

    def test_the_hook_layer_has_no_action_at_all(self):
        """🔴 Owner decision HARNESS_V1, enforced server-side and not only by the
        absence of a button: reconciling a hook is a reviewed procedure, so there is
        no action name that reaches this route for it."""
        for action in ('hooks', 'harness:hooks', 'provision', 'skills'):
            status, payload = self._execute({'action': action})
            self.assertEqual((status, payload['error']), (400, 'bad_action'), action)
        self.assertEqual(self.launched, [])

    def test_a_second_run_is_refused_while_one_is_in_flight(self):
        self.assertEqual(self._execute({'action': 'codex'})[0], 200)
        status, payload = self._execute({'action': 'codex'})
        self.assertEqual((status, payload['error']), (409, 'run_active'))
        self.assertEqual(len(self.launched), 1)

    def test_an_update_in_flight_does_not_block_a_codex_upgrade(self):
        """The two runs are independent, and the server must not invent a link.

        `bin/airlock-update` holds a git mutex and restarts this backend; npm does
        neither. Refusing here would be a refusal on evidence about a different run.
        """
        saved = DM.UPDATE_EXEC_CONFIG
        DM.UPDATE_EXEC_CONFIG = {
            'root': self.root, 'dir': self.dir,
            'plan_dir': str(UPX.plan_dir(self.dir)),
            'sentinel_dir': str(UPX.sentinel_dir(self.dir)),
            'session': 'devmon-test', 'cwd_root': str(self.root), 'agent': {},
            'runner': os.path.join(BACKEND, 'action_runner.py'),
        }
        try:
            UPX.write_record(self.dir, dict(UPX.start_record('upd-x', 'platform', None),
                                            pid=os.getpid(), status='running'))
            status, payload = self._execute({'action': 'codex'})
        finally:
            DM.UPDATE_EXEC_CONFIG = saved
        self.assertEqual(status, 200, payload)

    # ---- 지금 점검 ----------------------------------------------------------
    def test_recheck_starts_the_detection_oneshot_without_blocking_on_it(self):
        """A collection runs airlock-update --dry-run, npm view and the hook check.
        A blocking start would hold the request open for a minute and the browser
        would call that a failure, so the panel watches `checkedAt` instead."""
        saved = DM.UPDATES
        DM.UPDATES = types.SimpleNamespace(read_snapshot=lambda: None)
        try:
            status, payload = self._execute({'action': 'recheck'})
        finally:
            DM.UPDATES = saved
        self.assertEqual(status, 200, payload)
        self.assertEqual(payload['unit'], 'airlock-update-detect.service')
        self.assertEqual(self.started, [['systemctl', '--user', 'start', '--no-block',
                                         '--', 'airlock-update-detect.service']])
        self.assertEqual(self.launched, [])            # no window, no run record

    def test_recheck_names_the_one_unit_and_takes_no_name_from_the_caller(self):
        saved = DM.UPDATES
        DM.UPDATES = types.SimpleNamespace(read_snapshot=lambda: None)
        try:
            self._execute({'action': 'recheck', 'unit': 'anything-else.service'})
        finally:
            DM.UPDATES = saved
        self.assertEqual(self.started[0][-1], 'airlock-update-detect.service')

    def test_recheck_says_so_when_the_detection_timer_was_never_installed(self):
        """A real state of a working box (the timer is a separate install step), and
        it must read as that rather than as a fault to retry into."""
        def refuse(argv, **kw):
            raise subprocess.CalledProcessError(5, argv)
        saved, DM.subprocess.check_call = DM.subprocess.check_call, refuse
        saved_updates, DM.UPDATES = DM.UPDATES, types.SimpleNamespace(read_snapshot=lambda: None)
        try:
            status, payload = self._execute({'action': 'recheck'})
        finally:
            DM.subprocess.check_call = saved
            DM.UPDATES = saved_updates
        self.assertEqual((status, payload['error']), (409, 'recheck_unavailable'))


class HarnessWrapperTest(unittest.TestCase):
    """The wrapper's own contract: it reports what `codex --version` says afterwards."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        UPX.ensure_dirs(self.dir)
        self.saved = (HARNESS.upgrade_argv, HARNESS.codex_summary, HARNESS.subprocess.call)

    def tearDown(self):
        (HARNESS.upgrade_argv, HARNESS.codex_summary, HARNESS.subprocess.call) = self.saved
        self.tmp.cleanup()

    def _run(self, versions, exit_code=0):
        """versions: the installed reading before and after the upgrade call."""
        seen = iter(versions)
        HARNESS.codex_summary = lambda: {'installed': next(seen), 'latest': '0.152.0'}
        HARNESS.upgrade_argv = lambda: ['npm', 'install', '-g', '@openai/codex@latest']
        HARNESS.subprocess.call = lambda argv, **kw: exit_code
        UPX.write_record(self.dir, HARNESS.start_record('h-1', 'codex'))
        with contextlib.redirect_stdout(io.StringIO()):
            code = HARNESS.main(['--dir', str(self.dir), '--run', 'h-1', '--action', 'codex'])
        return code, UPX.read_record(self.dir)

    def test_a_successful_upgrade_records_the_version_it_moved_to(self):
        code, record = self._run(['0.144.4', '0.152.0'])
        self.assertEqual((code, record['status']), (0, 'done'))
        self.assertEqual((record['before']['installed'], record['after']['installed']),
                         ('0.144.4', '0.152.0'))
        self.assertEqual(record['note'], '')

    def test_npm_succeeding_without_the_version_moving_is_not_a_success(self):
        """🔴 The claim is "codex --version is now current", not "npm was happy".

        npm returns 0 having installed into a prefix this box does not resolve, and
        reading the exit code alone would report that as a completed upgrade to a
        person whose codex did not change.
        """
        code, record = self._run(['0.144.4', '0.144.4'])
        self.assertEqual((code, record['status']), (0, 'done'))
        self.assertIn('그대로', record['note'])

    def test_a_missing_npm_is_reported_and_nothing_is_run(self):
        HARNESS.codex_summary = lambda: {'installed': '0.144.4', 'latest': '0.152.0'}
        HARNESS.upgrade_argv = lambda: None
        ran = []
        HARNESS.subprocess.call = lambda argv, **kw: ran.append(argv) or 0
        UPX.write_record(self.dir, HARNESS.start_record('h-2', 'codex'))
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = HARNESS.main(['--dir', str(self.dir), '--run', 'h-2', '--action', 'codex'])
        record = UPX.read_record(self.dir)
        self.assertEqual((code, record['status'], ran), (127, 'failed', []))
        self.assertIn('npm', record['note'])

    def test_the_wrapper_refuses_to_write_over_another_launch(self):
        UPX.write_record(self.dir, HARNESS.start_record('h-other', 'codex'))
        with self.assertRaises(SystemExit):
            HARNESS.main(['--dir', str(self.dir), '--run', 'h-1', '--action', 'codex'])
        self.assertEqual(UPX.read_record(self.dir)['runId'], 'h-other')

    def test_liveness_asks_about_this_wrapper_and_not_the_update_one(self):
        """Both wrappers share the record format, so `observed()` has to ask about the
        right process: a stale pid that now belongs to the OTHER wrapper is still a
        dead run of this one."""
        record = dict(HARNESS.start_record('h-3', 'codex'), pid=os.getpid(),
                      status='running')
        self.assertEqual(HARNESS.observed(record)['status'], 'interrupted')
        self.assertEqual(UPX.observed(dict(record), b'python')['status'], 'running')


if __name__ == '__main__':
    unittest.main(verbosity=1)
