#!/usr/bin/env python3
"""Platform nginx reload ordering and old-updater installed-row API seam."""
from importlib.machinery import SourceFileLoader
from pathlib import Path
import json
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ledger = SourceFileLoader('platform_ledger', str(Path(__file__).resolve().parents[1] / 'bin/airlock-ledger')).load_module()


class PlatformProjectionTest(unittest.TestCase):
    def projection(self, nginx_rc):
        calls = []
        def command(args, description):
            calls.append(args)
            return nginx_rc if args == ['sudo', 'nginx', '-t'] else 0
        with patch.object(ledger.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, '{}', '')), \
             patch.object(ledger, '_run_command', side_effect=command), \
             patch.object(ledger, '_project_hub_ingress', return_value=set()):
            if nginx_rc:
                with self.assertRaisesRegex(ledger.ApplyFailed, 'nginx configuration test failed'):
                    ledger.project([])
            else:
                ledger.project([])
        return calls

    def test_reload_follows_nginx_test(self):
        calls = self.projection(0)
        self.assertLess(calls.index(['sudo', 'nginx', '-t']),
                        calls.index(['sudo', 'systemctl', 'reload', 'nginx']))

    def test_failed_nginx_test_does_not_reload(self):
        self.assertNotIn(['sudo', 'systemctl', 'reload', 'nginx'], self.projection(1))

    def test_old_updater_can_snapshot_and_validate_release_ledger(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'state'
            state.mkdir()
            data = json.dumps({'fixture': {'repo': '/fixture/app', 'commit': '', 'artifacts': []}}).encode()
            (state / ledger.INSTALLED_FILENAME).write_bytes(data)
            snapshot = Path(directory) / 'snapshot.json'
            self.assertTrue(ledger.snapshot_installed(snapshot, state))
            self.assertEqual(snapshot.read_bytes(), data)
            self.assertEqual(ledger.validate_installed_bytes(snapshot.read_bytes()), json.loads(data))


if __name__ == '__main__':
    unittest.main()
