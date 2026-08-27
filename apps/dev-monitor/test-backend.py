#!/usr/bin/env python3
"""Offline checks for the dev-monitor BACKEND — the half test_devmon.py does not reach.

test_devmon.py covers the ported store/spool/owner/slack modules. This covers what the
backend itself adds on top of them: which origins may read a response, what the health
endpoint admits to, and the reaper paths that exist to stop a failed launch from locking
a card forever. Those are exactly the places a bug is invisible until someone is stuck.

    python3 apps/dev-monitor/test-backend.py

No install, no network, no tmux required.
"""
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import subprocess
import types
import unittest
from contextlib import redirect_stderr
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
BACKEND = os.path.join(HERE, 'backend')
sys.path.insert(0, BACKEND)
import action_runner
import devmon_cron


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


class ServiceRestartTest(unittest.TestCase):
    def setUp(self):
        self.saved_units = DM._airlock_user_units
        self.saved_check_call = DM.subprocess.check_call
        self.saved_run = DM.run

    def tearDown(self):
        DM._airlock_user_units = self.saved_units
        DM.subprocess.check_call = self.saved_check_call
        DM.run = self.saved_run

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
        for name in ('nginx', 'airlock-dev-monitor', 'airlock-alpha; reboot', '', None):
            self.assertEqual(DM.restart_svc(name),
                             (False, 'service restart is not allowed'))

    def test_timeout_is_reported_without_exception_or_command_output(self):
        DM._airlock_user_units = lambda: ['airlock-alpha', 'airlock-dev-monitor']
        DM.subprocess.check_call = lambda *a, **k: (_ for _ in ()).throw(
            DM.subprocess.TimeoutExpired(a[0], k.get('timeout')))
        self.assertEqual(DM.restart_svc('airlock-alpha'), (False, 'restart timeout'))

    def test_service_inventory_marks_user_only_as_actionable(self):
        DM._airlock_user_units = lambda: ['airlock-alpha', 'airlock-dev-monitor']
        DM.run = lambda argv, timeout=3: 'active' if 'is-active' in argv else ''
        services = DM.svc_info()
        user = next(item for item in services if item['name'] == 'airlock-alpha')
        own = next(item for item in services if item['name'] == 'airlock-dev-monitor')
        system = next(item for item in services if item['name'] == 'nginx')
        self.assertTrue(user['action_allowed'])
        self.assertFalse(own['action_allowed'])
        self.assertFalse(system['action_allowed'])


class CronActionTest(unittest.TestCase):
    def setUp(self):
        self.saved_known = devmon_cron.known_user_timers
        self.saved_service = devmon_cron.timer_service
        self.saved_run = devmon_cron.scan.run_cmd
        self.saved_invalidate = devmon_cron.scan.invalidate_snapshot_cache

    def tearDown(self):
        devmon_cron.known_user_timers = self.saved_known
        devmon_cron.timer_service = self.saved_service
        devmon_cron.scan.run_cmd = self.saved_run
        devmon_cron.scan.invalidate_snapshot_cache = self.saved_invalidate

    def test_run_pause_resume_use_shell_free_user_systemctl(self):
        devmon_cron.known_user_timers = lambda: {'backup.timer'}
        devmon_cron.timer_service = lambda unit: 'backup.service'
        calls, invalidations = [], []
        devmon_cron.scan.run_cmd = lambda argv, timeout=15: (calls.append(argv) or (0, '', ''))
        devmon_cron.scan.invalidate_snapshot_cache = lambda: invalidations.append(True)
        for action in ('run', 'pause', 'resume'):
            status, payload = devmon_cron.run_action(action, 'backup.timer')
            self.assertEqual((status, payload['ok']), (200, True), payload)
        self.assertEqual(calls, [
            ['systemctl', '--user', 'start', '--no-block', 'backup.service'],
            ['systemctl', '--user', 'stop', 'backup.timer'],
            ['systemctl', '--user', 'start', 'backup.timer'],
        ])
        self.assertEqual(len(invalidations), 3)

    def test_non_user_and_forged_units_fail_before_subprocess(self):
        devmon_cron.known_user_timers = lambda: {'mine.timer'}
        devmon_cron.scan.run_cmd = lambda *a, **k: self.fail('subprocess must not run')
        for unit, expected in [('system.timer', 403), ('mine.service', 400),
                               ('mine.timer; reboot', 400), (None, 400)]:
            status, payload = devmon_cron.run_action('pause', unit)
            self.assertEqual(status, expected, payload)

    def test_run_refuses_when_timer_target_cannot_be_measured(self):
        devmon_cron.known_user_timers = lambda: {'alias.timer'}
        for show_result in ((1, '', 'transient failure'), (0, 'Unit=\n', '')):
            with self.subTest(show_result=show_result):
                calls = []
                def fake_run(argv, timeout=15):
                    calls.append(argv)
                    if argv[:4] == ['systemctl', '--user', 'show', 'alias.timer']:
                        return show_result
                    self.fail('start must not be guessed')
                devmon_cron.scan.run_cmd = fake_run
                status, payload = devmon_cron.run_action('run', 'alias.timer')
                self.assertEqual(status, 503, payload)
                self.assertFalse(payload['ok'])
                self.assertEqual(calls, [[
                    'systemctl', '--user', 'show', 'alias.timer', '-p', 'Unit',
                ]])

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

    def test_owner_can_control_a_whitelisted_cron_timer(self):
        saved = DM.CRON.run_action
        try:
            seen = []
            DM.CRON.run_action = lambda action, unit: (
                seen.append((action, unit)) or (200, {'ok': True, 'message': 'done'}))
            status, payload = self._post('/api/owner/cron/pause', body=b'{"unit":"backup.timer"}')
            self.assertEqual((status, payload.get('ok')), (200, True), payload)
            self.assertEqual(seen, [('pause', 'backup.timer')])
        finally:
            DM.CRON.run_action = saved

    def test_cron_control_checks_owner_before_dispatch(self):
        saved = DM.CRON.run_action
        try:
            DM.CRON.run_action = lambda *a: self.fail('cron action must not run before owner gate')
            status, _ = self._post('/api/owner/cron/run', body=b'{"unit":"backup.timer"}',
                                   headers={'X-Devmon-Proxy-Secret': 'nope'})
            self.assertEqual(status, 403)
        finally:
            DM.CRON.run_action = saved


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


if __name__ == '__main__':
    unittest.main(verbosity=1)
