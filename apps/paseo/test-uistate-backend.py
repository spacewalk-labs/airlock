#!/usr/bin/env python3
"""Offline checks for the paseo ui-state backend.

The backend is small, and its whole value is that it holds ONE thing for the owner
across devices. What can go wrong is therefore not arithmetic — it is scope: a key it
was never asked to store, a name that walks out of the state directory, a body that
fills the disk, or a half-written file that comes back as unparseable order and loses
the sidebar. Those are the cases below.

    python3 apps/paseo/test-uistate-backend.py

No install, no gate, no systemd. It binds an ephemeral loopback port.
"""
import http.client
import importlib.util
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = os.path.join(HERE, 'backend', 'airlock-paseo-uistate.py')

spec = importlib.util.spec_from_file_location('airlock_paseo_uistate', SOURCE)
uistate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(uistate)

KEY = 'sidebar-project-workspace-order'
ORDER = json.dumps({'state': {'projectOrder': ['b', 'a'], 'workspaceOrderByProject': {}}, 'version': 1})


class UiStateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ['AIRLOCK_PASEO_UISTATE_DIR'] = os.path.join(self.tmp.name, 'state')
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), uistate.Handler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        os.environ.pop('AIRLOCK_PASEO_UISTATE_DIR', None)
        self.tmp.cleanup()

    def request(self, method, path, body=None, revision=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        try:
            headers = {}
            if revision is not None:
                headers[uistate.BASE_REVISION_HEADER] = str(revision)
            conn.request(method, path, body=body, headers=headers)
            response = conn.getresponse()
            return response.status, response.read(), response.getheader(uistate.REVISION_HEADER)
        finally:
            conn.close()

    def test_absent_key_is_404_not_an_empty_success(self):
        # A device that has never synced must be able to tell "nothing stored yet"
        # from "stored empty" — the patched bundle falls back to its own copy on 404,
        # and an empty 200 would silently wipe the local order instead.
        status, _, revision = self.request('GET', f'/{KEY}')
        self.assertEqual(status, 404)
        self.assertEqual(revision, '0')

    def test_versioned_route_reaches_the_allowlisted_key(self):
        status, _, revision = self.request('PUT', f'/v2/{KEY}', ORDER, revision=0)
        self.assertEqual((status, revision), (204, '1'))
        status, body, revision = self.request('GET', f'/v2/{KEY}')
        self.assertEqual((status, revision), (200, '1'))
        self.assertEqual(json.loads(body), json.loads(ORDER))

    def test_round_trip_survives_a_restart(self):
        status, _, revision = self.request('PUT', f'/{KEY}', ORDER, revision=0)
        self.assertEqual(status, 204)
        self.assertEqual(revision, '1')
        status, body, revision = self.request('GET', f'/{KEY}')
        self.assertEqual(status, 200)
        self.assertEqual(revision, '1')
        self.assertEqual(json.loads(body), json.loads(ORDER))
        stored = Path(os.environ['AIRLOCK_PASEO_UISTATE_DIR']) / f'{KEY}.json'
        self.assertTrue(stored.is_file())
        self.assertEqual(stored.stat().st_mode & 0o777, 0o600)
        self.assertEqual(stored.parent.stat().st_mode & 0o777, 0o700)

        body, revision = uistate.read_record(stored)
        self.assertEqual(json.loads(body), json.loads(ORDER))
        self.assertEqual(revision, 1)

    def test_legacy_raw_file_is_revision_one_and_migrates_on_write(self):
        stored = Path(os.environ['AIRLOCK_PASEO_UISTATE_DIR']) / f'{KEY}.json'
        stored.parent.mkdir(parents=True)
        stored.write_text(ORDER)
        status, body, revision = self.request('GET', f'/{KEY}')
        self.assertEqual((status, revision), (200, '1'))
        self.assertEqual(json.loads(body), json.loads(ORDER))

        changed = json.dumps({'state': {'projectOrder': ['a', 'b']}, 'version': 1})
        status, _, revision = self.request('PUT', f'/{KEY}', changed, revision=1)
        self.assertEqual((status, revision), (204, '2'))
        record = json.loads(stored.read_text())
        self.assertEqual(record['revision'], 2)
        self.assertEqual(json.loads(record['value']), json.loads(changed))

    def test_unlisted_key_is_refused_on_every_verb(self):
        for method, body in (('GET', None), ('PUT', '{}'), ('DELETE', None)):
            status, _, _ = self.request(method, '/@paseo:daemon-registry', body)
            self.assertEqual(status, 404, method)

    def test_traversal_never_reaches_the_filesystem(self):
        outside = Path(self.tmp.name) / 'escaped.json'
        status, _, _ = self.request('PUT', '/..%2F..%2Fescaped', '{}')
        self.assertEqual(status, 404)
        status, _, _ = self.request('PUT', '/../../escaped', '{}')
        self.assertEqual(status, 404)
        status, _, _ = self.request('PUT', '/v2/..%2F..%2Fescaped', '{}', revision=0)
        self.assertEqual(status, 404)
        self.assertFalse(outside.exists())

    def test_oversized_body_is_refused_and_stores_nothing(self):
        status, _, _ = self.request('PUT', f'/{KEY}', '"' + 'x' * (uistate.MAX_BYTES + 16) + '"', revision=0)
        self.assertEqual(status, 413)
        status, _, _ = self.request('GET', f'/{KEY}')
        self.assertEqual(status, 404)

    def test_non_json_body_is_refused_and_leaves_the_previous_value(self):
        self.request('PUT', f'/{KEY}', ORDER, revision=0)
        status, _, _ = self.request('PUT', f'/{KEY}', 'not json{', revision=1)
        self.assertEqual(status, 400)
        status, body, revision = self.request('GET', f'/{KEY}')
        self.assertEqual(status, 200)
        self.assertEqual(revision, '1')
        self.assertEqual(json.loads(body), json.loads(ORDER))

    def test_delete_is_idempotent(self):
        self.request('PUT', f'/{KEY}', ORDER, revision=0)
        for base in (1, 2):
            status, _, revision = self.request('DELETE', f'/{KEY}', revision=base)
            self.assertEqual(status, 204)
            self.assertEqual(revision, str(base + 1))
        status, _, revision = self.request('GET', f'/{KEY}')
        self.assertEqual(status, 404)
        self.assertEqual(revision, '3')

    def test_unconditional_and_stale_mutations_are_rejected(self):
        status, _, revision = self.request('PUT', f'/{KEY}', ORDER)
        self.assertEqual((status, revision), (428, '0'))
        self.request('PUT', f'/{KEY}', ORDER, revision=0)
        status, body, revision = self.request('PUT', f'/{KEY}', '{}', revision=0)
        self.assertEqual((status, revision), (409, '1'))
        self.assertEqual(json.loads(body), json.loads(ORDER))
        status, body, revision = self.request('DELETE', f'/{KEY}', revision=0)
        self.assertEqual((status, revision), (409, '1'))
        self.assertEqual(json.loads(body), json.loads(ORDER))

    def test_tombstone_prevents_aba_after_delete_and_recreate(self):
        self.request('PUT', f'/{KEY}', ORDER, revision=0)
        self.request('DELETE', f'/{KEY}', revision=1)
        self.request('PUT', f'/{KEY}', '{}', revision=2)
        status, body, revision = self.request('PUT', f'/{KEY}', '[]', revision=1)
        self.assertEqual((status, revision), (409, '3'))
        self.assertEqual(json.loads(body), {})

    def test_two_writers_on_one_revision_only_one_succeeds(self):
        barrier = threading.Barrier(3)
        results = []

        def write(value):
            barrier.wait()
            results.append(self.request('PUT', f'/{KEY}', json.dumps(value), revision=0))

        threads = [threading.Thread(target=write, args=({'writer': i},)) for i in (1, 2)]
        for thread in threads:
            thread.start()
        barrier.wait()
        for thread in threads:
            thread.join(timeout=5)
        self.assertEqual(sorted(status for status, _, _ in results), [204, 409])
        self.assertEqual(sorted(revision for _, _, revision in results), ['1', '1'])

    def test_a_failed_write_leaves_no_temp_file_behind(self):
        self.request('PUT', f'/{KEY}', ORDER, revision=0)
        directory = Path(os.environ['AIRLOCK_PASEO_UISTATE_DIR'])
        self.assertEqual([p.name for p in directory.iterdir() if p.name.startswith('.tmp-')], [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
