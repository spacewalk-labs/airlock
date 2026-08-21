#!/usr/bin/env python3
"""Import legacy dev-monitor state without mutating its database.

Database migration is deliberately copy based: after the caller attests that DB writers
and spool producers are stopped, take a SQLite backup, clone that backup to a temporary
target, migrate the clone, then atomically publish it.  The backup is retained as the
rollback artifact.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import stat
import sys
import tempfile
from urllib.parse import quote


TABLES = (
    'occurrences', 'cards', 'runs', 'approvals', 'deliveries', 'events',
    'ingest_errors',
)
SQLITE_SIDECARS = ('-wal', '-shm', '-journal')


class MigrationError(RuntimeError):
    pass


def _resolved(path: str | Path) -> Path:
    return Path(path).expanduser().resolve(strict=False)


def _contains(parent: Path, child: Path) -> bool:
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def _validate_roots(legacy_root: Path, canonical_root: Path) -> None:
    if legacy_root == canonical_root or _contains(legacy_root, canonical_root) \
            or _contains(canonical_root, legacy_root):
        raise MigrationError('legacy and canonical roots must not overlap')


def _validate_backup_path(backup: Path, legacy_root: Path,
                          canonical_root: Path) -> None:
    _validate_backup_location(backup, legacy_root, canonical_root)
    if (backup.exists() or _manifest_path(backup).exists()
            or _target_marker_path(backup).exists()):
        raise MigrationError('database backup already exists')


def _validate_backup_location(backup: Path, legacy_root: Path,
                              canonical_root: Path) -> None:
    if _contains(legacy_root, backup) or _contains(canonical_root, backup):
        raise MigrationError('database backup must be outside both state roots')


def _mkdir_private(path: Path) -> None:
    existed = path.exists()
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.is_dir():
        raise MigrationError('expected a directory')
    if not existed:
        os.chmod(path, 0o700)


def _fsync_file(path: Path) -> None:
    with path.open('rb') as handle:
        os.fsync(handle.fileno())


def _fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | getattr(os, 'O_DIRECTORY', 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def _manifest_path(backup: Path) -> Path:
    return backup.with_name(backup.name + '.manifest.json')


def _target_marker_path(backup: Path) -> Path:
    return backup.with_name(backup.name + '.target.json')


def _write_backup_manifest(backup: Path, source: Path) -> None:
    manifest = _manifest_path(backup)
    if manifest.exists():
        raise MigrationError('database backup manifest already exists')
    fd, raw_temp = tempfile.mkstemp(
        prefix='.messages-manifest.', suffix='.json', dir=backup.parent)
    temp = Path(raw_temp)
    try:
        payload = {
            'version': 1,
            'source': str(source),
            'backup_sha256': _file_sha256(backup),
        }
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            json.dump(payload, handle, sort_keys=True)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        fd = -1
        os.chmod(temp, 0o600)
        try:
            os.link(temp, manifest)
        except FileExistsError as exc:
            raise MigrationError('database backup manifest already exists') from exc
        _fsync_dir(backup.parent)
    finally:
        if fd >= 0:
            os.close(fd)
        if temp.exists():
            temp.unlink()


def _verify_backup_manifest(backup: Path, source: Path) -> None:
    manifest = _manifest_path(backup)
    try:
        payload = json.loads(manifest.read_text(encoding='utf-8'))
    except (OSError, ValueError) as exc:
        raise MigrationError('--resume requires a valid database backup manifest') from exc
    if (payload.get('version') != 1 or payload.get('source') != str(source)
            or payload.get('backup_sha256') != _file_sha256(backup)):
        raise MigrationError('database backup manifest does not match this import')


def _verify_source_unchanged(source: Path, backup: Path) -> None:
    """Refuse an online snapshot if writers changed the source while approval waited."""
    fd, raw_temp = tempfile.mkstemp(
        prefix='.messages-current.', suffix='.db', dir=backup.parent)
    os.close(fd)
    current = Path(raw_temp)
    current.unlink()
    try:
        _sqlite_backup(source, current, exclusive=False)
        if _file_sha256(current) != _file_sha256(backup):
            raise MigrationError('source changed since database backup')
    finally:
        if current.exists():
            current.unlink()
        for suffix in SQLITE_SIDECARS:
            sidecar = Path(str(current) + suffix)
            if sidecar.exists():
                sidecar.unlink()


def _target_marker_payload(backup: Path, target_sha256: str) -> dict[str, object]:
    return {
        'version': 1,
        'backup_sha256': _file_sha256(backup),
        'target_sha256': target_sha256,
    }


def _write_target_marker(backup: Path, target_sha256: str) -> None:
    marker = _target_marker_path(backup)
    expected = _target_marker_payload(backup, target_sha256)
    if marker.exists():
        try:
            actual = json.loads(marker.read_text(encoding='utf-8'))
        except (OSError, ValueError) as exc:
            raise MigrationError('canonical target marker is invalid') from exc
        if actual != expected:
            raise MigrationError('canonical target marker does not match the migration')
        return

    fd, raw_temp = tempfile.mkstemp(
        prefix='.messages-target.', suffix='.json', dir=backup.parent)
    temp = Path(raw_temp)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            json.dump(expected, handle, sort_keys=True)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        fd = -1
        os.chmod(temp, 0o600)
        try:
            os.link(temp, marker)
        except FileExistsError:
            actual = json.loads(marker.read_text(encoding='utf-8'))
            if actual != expected:
                raise MigrationError(
                    'canonical target marker does not match the migration')
        _fsync_dir(backup.parent)
    finally:
        if fd >= 0:
            os.close(fd)
        if temp.exists():
            temp.unlink()


def _verify_target_marker(backup: Path, target: Path) -> None:
    marker = _target_marker_path(backup)
    try:
        actual = json.loads(marker.read_text(encoding='utf-8'))
    except (OSError, ValueError) as exc:
        raise MigrationError('--resume requires a valid canonical target marker') from exc
    expected = _target_marker_payload(backup, _file_sha256(target))
    if actual != expected:
        raise MigrationError('existing canonical database does not match the backup')


def _open_source(path: Path) -> sqlite3.Connection:
    return sqlite3.connect('file:%s?mode=ro' % quote(path.as_posix()), uri=True)


def _backup_into(source: Path, target: Path) -> None:
    source_conn = None
    target_conn = None
    try:
        source_conn = _open_source(source)
        target_conn = sqlite3.connect(target)
        source_conn.backup(target_conn)
    except Exception:
        if target.exists():
            target.unlink()
        raise
    finally:
        if target_conn is not None:
            target_conn.close()
        if source_conn is not None:
            source_conn.close()
    os.chmod(target, 0o600)
    _fsync_file(target)


def _make_standalone(path: Path) -> None:
    """Normalize a SQLite snapshot so it never depends on adjacent journal state."""
    conn = sqlite3.connect(path)
    try:
        result = conn.execute('PRAGMA integrity_check').fetchone()
        if result is None or result[0] != 'ok':
            raise MigrationError('SQLite integrity check failed')
        conn.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        conn.execute('PRAGMA journal_mode=DELETE')
    finally:
        conn.close()
    for suffix in SQLITE_SIDECARS:
        sidecar = Path(str(path) + suffix)
        if sidecar.exists():
            sidecar.unlink()
    os.chmod(path, 0o600)
    _fsync_file(path)


def _sqlite_backup(source: Path, target: Path, *, exclusive: bool) -> None:
    _mkdir_private(target.parent)
    if not exclusive:
        if target.exists():
            target.unlink()
        _backup_into(source, target)
        _make_standalone(target)
        _fsync_dir(target.parent)
        return

    if target.exists():
        raise MigrationError('database backup already exists')
    fd, raw_temp = tempfile.mkstemp(
        prefix='.messages-backup.', suffix='.db', dir=target.parent)
    os.close(fd)
    temp = Path(raw_temp)
    try:
        _backup_into(source, temp)
        _make_standalone(temp)
        # link(2) is the no-clobber atomic publish Python exposes on the same filesystem.
        # A crash before this point leaves only a hidden temp, never a plausible rollback.
        os.link(temp, target)
        os.chmod(target, 0o600)
        _fsync_file(target)
    except FileExistsError as exc:
        raise MigrationError('database backup already exists') from exc
    finally:
        if temp.exists():
            temp.unlink()
        for suffix in SQLITE_SIDECARS:
            sidecar = Path(str(temp) + suffix)
            if sidecar.exists():
                sidecar.unlink()
    _fsync_dir(target.parent)


def _integrity(path: Path) -> None:
    conn = _open_source(path)
    try:
        result = conn.execute('PRAGMA integrity_check').fetchone()
        if result is None or result[0] != 'ok':
            raise MigrationError('SQLite integrity check failed')
    finally:
        conn.close()


def _counts(path: Path) -> dict[str, int]:
    conn = _open_source(path)
    try:
        present = {
            row[0] for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'")
        }
        missing = set(TABLES) - present
        if missing:
            raise MigrationError('database is missing required tables')
        return {
            table: int(conn.execute('SELECT COUNT(*) FROM %s' % table).fetchone()[0])
            for table in TABLES
        }
    finally:
        conn.close()


def _require_canonical_columns(path: Path) -> None:
    required = {
        'cards': {
            'severity': ('TEXT', 0, None), 'owner': ('TEXT', 0, None),
            'needs_action': ('INTEGER', 0, None), 'task_state': ('TEXT', 0, None),
            'snoozed_until': ('TEXT', 0, None), 'runbook': ('TEXT', 0, None),
        },
        'runs': {
            'keep_requested': ('INTEGER', 1, '0'), 'kept_at': ('TEXT', 0, None),
            'reclaimed_at': ('TEXT', 0, None),
        },
        'deliveries': {
            'claimed_by': ('TEXT', 0, None), 'lease_until': ('TEXT', 0, None),
            'created_at': ('TEXT', 0, None), 'last_error_at': ('TEXT', 0, None),
        },
    }
    required_indexes = {
        'ux_deliveries_open', 'idx_deliveries_claim', 'idx_deliveries_sent',
        'idx_deliveries_watchdog_notice', 'idx_deliveries_health_sent_v3',
        'idx_deliveries_health_error_valid_v3',
        'idx_deliveries_health_failed_v3',
        'idx_deliveries_health_bad_timestamp_v3', 'idx_cards_probe',
        'idx_cards_watchdog_group_created', 'idx_events_card_kind',
    }
    conn = _open_source(path)
    try:
        for table, expected in required.items():
            actual = {
                row[1]: (str(row[2]).upper(), int(row[3]), row[4])
                for row in conn.execute('PRAGMA table_info(%s)' % table)
            }
            if any(actual.get(name) != definition
                   for name, definition in expected.items()):
                raise MigrationError('database does not have the canonical schema')
        indexes = {
            row[0] for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='index'")
        }
        if not required_indexes.issubset(indexes):
            raise MigrationError('database does not have the canonical indexes')
    finally:
        conn.close()


def _load_messages():
    backend = Path(__file__).resolve().parent / 'backend'
    sys.path.insert(0, str(backend))
    try:
        return importlib.import_module('devmon_messages')
    finally:
        sys.path.pop(0)


def _migrate_clone(path: Path) -> None:
    messages = _load_messages()
    messages.init_db(str(path))
    conn = sqlite3.connect(path)
    try:
        conn.execute('BEGIN IMMEDIATE')
        unexpected = conn.execute(
            "SELECT 1 FROM cards WHERE severity IS NULL "
            "AND urgency NOT IN ('urgent','normal') LIMIT 1").fetchone()
        if unexpected is not None:
            raise MigrationError('legacy database has an unsupported urgency value')
        conn.execute(
            "UPDATE cards SET severity=CASE urgency "
            "WHEN 'urgent' THEN 'page' ELSE 'record' END WHERE severity IS NULL")
        conn.commit()
        result = conn.execute('PRAGMA integrity_check').fetchone()
        if result is None or result[0] != 'ok':
            raise MigrationError('SQLite integrity check failed after migration')
        conn.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        conn.execute('PRAGMA journal_mode=DELETE')
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
    for suffix in SQLITE_SIDECARS:
        sidecar = Path(str(path) + suffix)
        if sidecar.exists():
            sidecar.unlink()
    os.chmod(path, 0o600)
    _fsync_file(path)


def _publish_clone(source: Path, target: Path, migrate: bool,
                   target_marker_backup: Path | None = None) -> None:
    _mkdir_private(target.parent)
    fd, raw_temp = tempfile.mkstemp(prefix='.messages.', suffix='.db', dir=target.parent)
    os.close(fd)
    temp = Path(raw_temp)
    temp.unlink()
    try:
        _sqlite_backup(source, temp, exclusive=False)
        if migrate:
            _migrate_clone(temp)
        _integrity(temp)
        if target_marker_backup is not None:
            _write_target_marker(target_marker_backup, _file_sha256(temp))
        os.replace(temp, target)
        os.chmod(target, 0o600)
        _fsync_dir(target.parent)
    finally:
        if temp.exists():
            temp.unlink()
        for suffix in SQLITE_SIDECARS:
            sidecar = Path(str(temp) + suffix)
            if sidecar.exists():
                sidecar.unlink()


def _spool_entries(legacy_root: Path,
                   canonical_root: Path,
                   resume: bool = False) -> list[tuple[str, Path]]:
    source = legacy_root / 'spool'
    target = canonical_root / 'spool'
    if not source.is_dir():
        return []
    entries: list[tuple[str, Path]] = []
    for lane in ('new', 'tmp', 'processing', 'bad'):
        source_lane = source / lane
        if not source_lane.is_dir():
            continue
        for item in sorted(source_lane.iterdir()):
            info = item.lstat()
            if not stat.S_ISREG(info.st_mode):
                raise MigrationError('spool contains a non-regular entry')
            destination = target / lane / item.name
            if destination.exists():
                if (resume and destination.is_file()
                        and item.stat().st_size == destination.stat().st_size
                        and _file_sha256(item) == _file_sha256(destination)):
                    continue
                raise MigrationError('canonical spool entry already exists')
            entries.append((lane, item))
    return entries


def _stage_spool(entries: list[tuple[str, Path]],
                 canonical_root: Path) -> Path | None:
    if not entries:
        return None

    _mkdir_private(canonical_root)
    stage = Path(tempfile.mkdtemp(prefix='.spool-import.', dir=canonical_root))
    try:
        for lane, item in entries:
            stage_lane = stage / lane
            _mkdir_private(stage_lane)
            shutil.copy2(item, stage_lane / item.name, follow_symlinks=False)
    except Exception:
        shutil.rmtree(stage, ignore_errors=True)
        raise
    return stage


def _publish_spool(stage: Path | None, canonical_root: Path) -> None:
    if stage is None:
        return
    target = canonical_root / 'spool'
    moved: list[tuple[Path, Path]] = []
    try:
        for lane in ('new', 'tmp', 'processing', 'bad'):
            stage_lane = stage / lane
            if not stage_lane.is_dir():
                continue
            target_lane = target / lane
            if target_lane.exists():
                if not target_lane.is_dir():
                    raise MigrationError('canonical spool lane is not a directory')
            else:
                _mkdir_private(target_lane)
            for item in sorted(stage_lane.iterdir()):
                destination = target_lane / item.name
                if destination.exists():
                    raise MigrationError('canonical spool entry appeared during migration')
                os.replace(item, destination)
                moved.append((item, destination))
    except Exception:
        for source, destination in reversed(moved):
            if destination.exists():
                os.replace(destination, source)
        raise


def migrate(legacy_raw: str, canonical_raw: str, backup_raw: str | None,
            resume: bool = False, offline: bool = False) -> int:
    if not offline:
        raise MigrationError(
            '--offline is required: stop DB writers and spool producers before import')
    legacy_root = _resolved(legacy_raw)
    canonical_root = _resolved(canonical_raw)
    _validate_roots(legacy_root, canonical_root)
    source_db = legacy_root / 'messages.db'
    target_db = canonical_root / 'messages.db'
    target_preexisting = target_db.exists()
    if target_preexisting and not resume:
        raise MigrationError('canonical database already exists')

    entries = _spool_entries(legacy_root, canonical_root, resume=resume)
    backup = None
    source_counts = None
    if source_db.exists():
        if not backup_raw:
            raise MigrationError('--db-backup is required when a legacy database exists')
        backup = _resolved(backup_raw)
        if resume:
            _validate_backup_location(backup, legacy_root, canonical_root)
            if not backup.is_file():
                raise MigrationError('--resume requires an existing database backup')
            _verify_backup_manifest(backup, source_db)
            _integrity(backup)
            _verify_source_unchanged(source_db, backup)
            source_counts = _counts(backup)
        else:
            _validate_backup_path(backup, legacy_root, canonical_root)
            _sqlite_backup(source_db, backup, exclusive=True)
            _write_backup_manifest(backup, source_db)
            source_counts = _counts(backup)
    elif backup_raw or resume:
        raise MigrationError(
            '--db-backup/--resume was provided but no legacy database exists')

    if target_preexisting:
        assert source_counts is not None and backup is not None
        if any(Path(str(target_db) + suffix).exists()
               for suffix in SQLITE_SIDECARS):
            raise MigrationError(
                'existing canonical database has SQLite journal state')
        _integrity(target_db)
        _require_canonical_columns(target_db)
        _verify_target_marker(backup, target_db)
        if _counts(target_db) != source_counts:
            raise MigrationError('existing canonical database does not match the backup')

    stage = _stage_spool(entries, canonical_root)
    copied = len(entries)

    migrated = 1 if target_preexisting else 0
    published_here = False
    try:
        if source_db.exists() and not target_preexisting:
            assert backup is not None and source_counts is not None
            _publish_clone(
                backup, target_db, migrate=True, target_marker_backup=backup)
            migrated = 1
            published_here = True
            if _counts(target_db) != source_counts:
                raise MigrationError('row counts changed during database migration')
            _require_canonical_columns(target_db)
        _publish_spool(stage, canonical_root)
    except Exception:
        if target_db.exists() and published_here:
            target_db.unlink()
            _fsync_dir(target_db.parent)
        raise
    finally:
        if stage is not None and stage.exists():
            shutil.rmtree(stage, ignore_errors=True)
    try:
        print('database_migrated=%d spool_copied=%d' % (migrated, copied))
    except BrokenPipeError:
        pass
    return 0


def verify(raw: str) -> int:
    path = _resolved(raw)
    _integrity(path)
    counts = _counts(path)
    _require_canonical_columns(path)
    print('integrity_check=ok rows=%d' % sum(counts.values()))
    return 0


def backup_only(source_raw: str, backup_raw: str) -> int:
    """Take a consistent online rollback snapshot without claiming writers are stopped."""
    source = _resolved(source_raw)
    backup = _resolved(backup_raw)
    if not source.is_file():
        raise MigrationError('database source does not exist')
    if backup == source or _contains(source.parent, backup):
        raise MigrationError('database backup must be outside the source state root')
    if (backup.exists() or _manifest_path(backup).exists()
            or _target_marker_path(backup).exists()):
        raise MigrationError('database backup already exists')
    _sqlite_backup(source, backup, exclusive=True)
    _write_backup_manifest(backup, source)
    counts = _counts(backup)
    print('backup=ok ' + ' '.join('%s=%d' % (table, counts[table]) for table in TABLES))
    return 0


def restore(backup_raw: str, target_raw: str, offline: bool = False) -> int:
    if not offline:
        raise MigrationError(
            '--offline is required: stop all target database users before restore')
    backup = _resolved(backup_raw)
    target = _resolved(target_raw)
    if backup == target:
        raise MigrationError('backup and restore target must differ')
    if not backup.is_file():
        raise MigrationError('database backup does not exist')
    if any(Path(str(target) + suffix).exists() for suffix in SQLITE_SIDECARS):
        raise MigrationError(
            'restore target has SQLite journal state; stop and checkpoint it first')
    _integrity(backup)
    _publish_clone(backup, target, migrate=False)
    print('restore=ok backup_retained=1')
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument('legacy_root', nargs='?')
    result.add_argument('canonical_root', nargs='?')
    result.add_argument('--db-backup')
    result.add_argument('--backup-source', metavar='DB')
    result.add_argument('--verify', metavar='DB')
    result.add_argument('--restore-backup', metavar='DB')
    result.add_argument('--restore-to', metavar='DB')
    result.add_argument(
        '--resume', action='store_true',
        help='reuse a completed --db-backup after a failed first import')
    result.add_argument(
        '--offline', action='store_true',
        help='attest that DB writers and spool producers are stopped')
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.verify:
            if any((args.legacy_root, args.canonical_root, args.db_backup,
                    args.backup_source, args.restore_backup, args.restore_to, args.resume,
                    args.offline)):
                raise MigrationError('--verify cannot be combined with migration or restore')
            return verify(args.verify)
        if args.backup_source:
            if not args.db_backup:
                raise MigrationError('--backup-source requires --db-backup')
            if any((args.legacy_root, args.canonical_root, args.restore_backup,
                    args.restore_to, args.resume, args.offline)):
                raise MigrationError('online backup cannot be combined with migration or restore')
            return backup_only(args.backup_source, args.db_backup)
        if args.restore_backup or args.restore_to:
            if not args.restore_backup or not args.restore_to:
                raise MigrationError('--restore-backup and --restore-to are required together')
            if any((args.legacy_root, args.canonical_root, args.db_backup,
                    args.backup_source,
                    args.resume)):
                raise MigrationError('restore cannot be combined with migration')
            return restore(args.restore_backup, args.restore_to, args.offline)
        if not args.legacy_root or not args.canonical_root:
            raise MigrationError('LEGACY_ROOT and CANONICAL_ROOT are required')
        return migrate(
            args.legacy_root, args.canonical_root, args.db_backup,
            args.resume, args.offline)
    except (MigrationError, OSError, sqlite3.Error, RuntimeError) as exc:
        # Deliberately do not print row identifiers, SQL, or paths from nested exceptions.
        if isinstance(exc, MigrationError):
            message = str(exc)
        else:
            message = 'database migration failed; backup, if completed, was retained'
        print('error: ' + message, file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
