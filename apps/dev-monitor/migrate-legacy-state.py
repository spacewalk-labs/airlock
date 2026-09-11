#!/usr/bin/env python3
"""Import or convert legacy dev-monitor state with a retained rollback backup.

Relocation never mutates its source. In-place endstate conversion is also copy based:
after the caller attests that DB writers and spool producers are stopped, take a SQLite
backup, migrate a temporary clone, validate it, then atomically publish it. The backup is
retained as the rollback artifact.
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


def _endstate_path(raw: str | Path) -> Path:
    """Resolve the installed DB without accepting a redirected leaf."""
    path = Path(raw).expanduser()
    if path.is_symlink():
        raise MigrationError('database source must be a regular non-symlink file')
    resolved = path.resolve(strict=False)
    if not resolved.is_file():
        raise MigrationError('database source does not exist')
    return resolved


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
        expected = ('ledger','cards') if 'ledger' in present else TABLES
        missing = set(expected) - present
        if missing:
            raise MigrationError('database is missing required tables')
        return {
            table: int(conn.execute('SELECT COUNT(*) FROM %s' % table).fetchone()[0])
            for table in expected
        }
    finally:
        conn.close()


def _require_canonical_columns(path: Path) -> None:
    conn = _open_source(path)
    try:
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if tables != {'ledger','cards'}:
            raise MigrationError('canonical database requires exactly ledger and cards')
        indexes = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='index'")}
        if not {'cards_send','cards_group','ledger_received'} <= indexes:
            raise MigrationError('canonical indexes missing')
        columns = {r[1] for r in conn.execute('PRAGMA table_info(cards)')}
        if not {'ran_at','send_attempts','send_next_at','sent_at','run'} <= columns:
            raise MigrationError('canonical cards columns missing')
    finally:
        conn.close()


def _expected_counts(counts):
    return {'ledger':counts.get('ledger',counts.get('occurrences',0)), 'cards':counts['cards']}


def _load_messages():
    backend = Path(__file__).resolve().parent / 'backend'
    sys.path.insert(0, str(backend))
    try:
        return importlib.import_module('devmon_messages')
    finally:
        sys.path.pop(0)


def _migrate_clone(path: Path) -> None:
    _load_messages()  # Set up the same app-only module resolution as the runtime.
    sys.path.insert(0,str(Path(__file__).parent / 'backend'))
    try:
        from devmon_migrate import convert
    finally:
        sys.path.pop(0)
    fd, name = tempfile.mkstemp(prefix='.endstate.',suffix='.db',dir=path.parent)
    os.close(fd)
    target = Path(name)
    try:
        try:
            convert(path,target)
        except (ValueError,TypeError) as error:
            raise MigrationError('invalid legacy data; original and backup retained') from error
        _make_standalone(target)
        os.replace(target,path)
    finally:
        target.unlink(missing_ok=True)


def _publish_clone(source: Path, target: Path, migrate: bool,
                   target_marker_backup: Path | None = None,
                   expected_counts: dict[str, int] | None = None) -> None:
    _mkdir_private(target.parent)
    fd, raw_temp = tempfile.mkstemp(prefix='.messages.', suffix='.db', dir=target.parent)
    os.close(fd)
    temp = Path(raw_temp)
    temp.unlink()
    try:
        _sqlite_backup(source, temp, exclusive=False)
        if migrate:
            # _migrate_clone finishes by making and integrity-checking a standalone DB.
            _migrate_clone(temp)
        else:
            _integrity(temp)
        if expected_counts is not None:
            _require_canonical_columns(temp)
            if _counts(temp) != expected_counts:
                raise MigrationError(
                    'row counts changed during conversion; backup retained')
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
        if _counts(target_db) != _expected_counts(source_counts):
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
            if _counts(target_db) != _expected_counts(source_counts):
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


def schema_state(raw: str) -> int:
    """Classify an installed DB from metadata without running conversion gates."""
    path = _endstate_path(raw)
    conn = _open_source(path)
    try:
        tables = {
            row[0] for row in conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'")
        }
    finally:
        conn.close()
    if 'ledger' in tables:
        _require_canonical_columns(path)
        print('canonical')
    elif set(TABLES) <= tables:
        print('legacy')
    else:
        raise MigrationError('database is missing required tables')
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
    print('backup=ok ' + ' '.join('%s=%d' % item for item in sorted(counts.items())))
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


def compensate_endstate(raw: str, offline: bool = False) -> int:
    """Restore only an unchanged conversion result; never discard later writes."""
    if not offline:
        raise MigrationError(
            '--offline is required: stop all target database users before compensation')
    target = _endstate_path(raw)
    backup = target.with_name(target.name + '.pre-endstate')
    counts = _counts(target)
    if 'ledger' not in counts:
        _integrity(target)
        print('compensated=0 already_legacy=1')
        return 0
    if backup.is_symlink() or not backup.is_file():
        raise MigrationError('database backup is not a regular file')
    _integrity(backup)
    _verify_target_marker(backup, target)
    return restore(str(backup), str(target), offline=True)


def endstate(raw: str, offline: bool = False) -> int:
    if not offline:
        raise MigrationError('--offline is required: stop service and mask producer timers first')
    source = _endstate_path(raw)
    backup = source.with_name(source.name + '.pre-endstate')
    counts = _counts(source)
    if 'ledger' in counts:
        _integrity(source)
        _require_canonical_columns(source)
        print('converted=0 backup_retained=%d' % backup.is_file())
        return 0
    conn = sqlite3.connect(source)
    try:
        if conn.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchone()[0]:
            raise MigrationError('database checkpoint busy; stop all database users')
        conn.execute('PRAGMA journal_mode=DELETE')
    finally:
        conn.close()
    if backup.exists():
        if backup.is_symlink() or not backup.is_file():
            raise MigrationError('database backup is not a regular file')
        _verify_backup_manifest(backup, source)
        _integrity(backup)
        _verify_source_unchanged(source, backup)
        if _counts(backup) != counts:
            raise MigrationError('database backup does not match the legacy source')
    else:
        _sqlite_backup(source, backup, exclusive=True)
        _write_backup_manifest(backup, source)
    _publish_clone(
        backup, source, migrate=True, target_marker_backup=backup,
        expected_counts=_expected_counts(counts))
    print('converted=1 backup_retained=1')
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument('legacy_root', nargs='?')
    result.add_argument('canonical_root', nargs='?')
    result.add_argument('--db-backup')
    result.add_argument('--backup-source', metavar='DB')
    result.add_argument('--verify', metavar='DB')
    result.add_argument('--schema-state', metavar='DB')
    result.add_argument('--endstate', metavar='DB')
    result.add_argument('--compensate-endstate', metavar='DB')
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
        if args.endstate:
            if any((args.legacy_root, args.canonical_root, args.db_backup,
                    args.backup_source, args.verify, args.schema_state,
                    args.compensate_endstate, args.restore_backup,
                    args.restore_to, args.resume)):
                raise MigrationError('--endstate cannot be combined with other operations')
            return endstate(args.endstate, args.offline)
        if args.compensate_endstate:
            if any((args.legacy_root, args.canonical_root, args.db_backup,
                    args.backup_source, args.verify, args.schema_state,
                    args.restore_backup, args.restore_to, args.resume)):
                raise MigrationError(
                    '--compensate-endstate cannot be combined with other operations')
            return compensate_endstate(args.compensate_endstate, args.offline)
        if args.schema_state:
            if any((args.legacy_root, args.canonical_root, args.db_backup,
                    args.backup_source, args.verify, args.endstate,
                    args.compensate_endstate, args.restore_backup,
                    args.restore_to, args.resume, args.offline)):
                raise MigrationError('--schema-state cannot be combined with other operations')
            return schema_state(args.schema_state)
        if args.verify:
            if any((args.legacy_root, args.canonical_root, args.db_backup,
                    args.backup_source, args.schema_state,
                    args.compensate_endstate, args.restore_backup,
                    args.restore_to, args.resume, args.offline)):
                raise MigrationError('--verify cannot be combined with migration or restore')
            return verify(args.verify)
        if args.backup_source:
            if not args.db_backup:
                raise MigrationError('--backup-source requires --db-backup')
            if any((args.legacy_root, args.canonical_root, args.restore_backup,
                    args.restore_to, args.compensate_endstate, args.resume,
                    args.offline)):
                raise MigrationError('online backup cannot be combined with migration or restore')
            return backup_only(args.backup_source, args.db_backup)
        if args.restore_backup or args.restore_to:
            if not args.restore_backup or not args.restore_to:
                raise MigrationError('--restore-backup and --restore-to are required together')
            if any((args.legacy_root, args.canonical_root, args.db_backup,
                    args.backup_source, args.compensate_endstate,
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
