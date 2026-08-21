#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import shutil


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    'dev_monitor_cutover_nginx', HERE / 'dev-monitor-cutover-nginx.py')
assert SPEC and SPEC.loader
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


SITE = '''server {
    listen 127.0.0.1:1234;
    include @@INCLUDE_DIR@@/*.conf;
    location /monitor/api/owner/ {
        proxy_set_header X-Devmon-Proxy-Secret "has-{braces}";
    }
    location /monitor/api/ {
        proxy_pass http://127.0.0.1:4321;
    }
    root /old;
}
'''

CANONICAL = '''# canonical
location /monitor/api/ {
    proxy_pass http://127.0.0.1:4321;
}
location /monitor/api/owner/ {
    proxy_set_header X-Devmon-Proxy-Secret "replacement";
}
'''


class CutoverNginxTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.include = self.root / 'included'
        self.webroot = self.root / 'web'
        self.include.mkdir()
        (self.webroot / 'monitor').mkdir(parents=True)
        (self.webroot / 'monitor/index.html').write_text('ui')
        self.site = self.root / 'site.conf'
        self.site.write_text(SITE.replace('@@INCLUDE_DIR@@', str(self.include)))
        self.canonical = self.root / 'canonical.conf'
        self.canonical.write_text(CANONICAL)
        self.bridge = self.include / 'dev-monitor-airlock.conf'
        self.backup = self.root / 'private/site.conf.before'
        self.env = {
            'AIRLOCK_CUTOVER_NGINX_SITE': str(self.site),
            'AIRLOCK_CUTOVER_NGINX_BRIDGE': str(self.bridge),
            'AIRLOCK_CUTOVER_NGINX_INCLUDE_DIR': str(self.include),
            'AIRLOCK_CUTOVER_CANONICAL_FRAGMENT': str(self.canonical),
            'AIRLOCK_CUTOVER_WEBROOT': str(self.webroot),
            'AIRLOCK_CUTOVER_NGINX_BACKUP': str(self.backup),
        }

    def tearDown(self):
        self.tmp.cleanup()

    def test_plan_removes_only_legacy_blocks_and_adds_static_route(self):
        edited, bridge = MOD.plan(
            self.site.read_text(), self.canonical.read_text(),
            self.include, self.webroot)
        self.assertNotIn('has-{braces}', edited)
        self.assertIn('root /old;', edited)
        self.assertEqual(bridge.count('location /monitor/api/ {'), 1)
        self.assertEqual(bridge.count('location /monitor/api/owner/ {'), 1)
        self.assertIn('location = /monitor {', bridge)
        self.assertIn('location /monitor/ {', bridge)
        self.assertIn(f'root "{self.webroot}";', bridge)

    def test_duplicate_or_missing_legacy_location_fails_closed(self):
        text = self.site.read_text()
        with self.assertRaises(MOD.CutoverError):
            MOD.plan(text.replace('location /monitor/api/ {',
                                  'location /different/ {'),
                     self.canonical.read_text(), self.include, self.webroot)
        with self.assertRaises(MOD.CutoverError):
            MOD.plan(text + text, self.canonical.read_text(),
                     self.include, self.webroot)

    def test_apply_then_rollback_is_byte_exact(self):
        original = self.site.read_bytes()
        with mock.patch.dict(os.environ, self.env, clear=False), \
             mock.patch.object(MOD, '_nginx_test'):
            MOD.apply()
            self.assertEqual(self.backup.read_bytes(), original)
            self.assertNotIn('has-{braces}', self.site.read_text())
            self.assertEqual(self.bridge.stat().st_mode & 0o777, 0o600)
            MOD.rollback()
        self.assertEqual(self.site.read_bytes(), original)
        self.assertFalse(self.bridge.exists())
        self.assertTrue(self.backup.exists())

    def test_failed_nginx_test_restores_site_and_removes_bridge(self):
        original = self.site.read_bytes()
        with mock.patch.dict(os.environ, self.env, clear=False), \
             mock.patch.object(MOD, '_nginx_test',
                               side_effect=[MOD.CutoverError('bad config'), None]):
            with self.assertRaises(MOD.CutoverError):
                MOD.apply()
        self.assertEqual(self.site.read_bytes(), original)
        self.assertFalse(self.bridge.exists())
        self.assertEqual(self.backup.read_bytes(), original)

    def test_rollback_needs_no_canonical_fragment_or_webroot(self):
        original = self.site.read_bytes()
        with mock.patch.dict(os.environ, self.env, clear=False), \
             mock.patch.object(MOD, '_nginx_test'):
            MOD.apply()
            self.canonical.unlink()
            shutil.rmtree(self.webroot)
            MOD.rollback()
        self.assertEqual(self.site.read_bytes(), original)
        self.assertFalse(self.bridge.exists())

    def test_failed_rollback_validation_restores_pre_rollback_bytes(self):
        with mock.patch.dict(os.environ, self.env, clear=False), \
             mock.patch.object(MOD, '_nginx_test'):
            MOD.apply()
        applied_site = self.site.read_bytes()
        applied_bridge = self.bridge.read_bytes()
        with mock.patch.dict(os.environ, self.env, clear=False), \
             mock.patch.object(MOD, '_nginx_test', side_effect=[
                 MOD.CutoverError('rollback config bad'), None]):
            with self.assertRaises(MOD.CutoverError):
                MOD.rollback()
        self.assertEqual(self.site.read_bytes(), applied_site)
        self.assertEqual(self.bridge.read_bytes(), applied_bridge)

    def test_failed_backup_copy_never_publishes_partial_final(self):
        target = self.root / 'backup/site.conf'
        with mock.patch.object(MOD.shutil, 'copyfileobj',
                               side_effect=OSError('short write')):
            with self.assertRaises(OSError):
                MOD._exclusive_copy(self.site, target)
        self.assertFalse(target.exists())

    def test_symlink_and_wrong_include_directory_are_rejected(self):
        link = self.root / 'site-link.conf'
        link.symlink_to(self.site)
        env = dict(self.env, AIRLOCK_CUTOVER_NGINX_SITE=str(link))
        with mock.patch.dict(os.environ, env, clear=False):
            with self.assertRaises(MOD.CutoverError):
                MOD._paths()
        other = self.root / 'other'
        other.mkdir()
        env = dict(self.env, AIRLOCK_CUTOVER_NGINX_BRIDGE=str(other / 'x.conf'))
        with mock.patch.dict(os.environ, env, clear=False):
            with self.assertRaises(MOD.CutoverError):
                MOD._paths()


if __name__ == '__main__':
    unittest.main()
