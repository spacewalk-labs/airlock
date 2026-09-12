#!/usr/bin/env python3
"""The durable 'convert and start after commit' record for a deferred dev-monitor.

Inside an install transaction the legacy messages DB is not converted and no
canonical writer is started. A backend start alone rewrites the DB (init_db()
switches it to WAL), so a conversion made before commit can never be undone
losslessly once the candidate runs -- and every later failure in the same
transaction used to strand the box in `degraded`. Instead the installer leaves
this record and converts only after the transaction is committed.

  write      STATE TX DB WRITER PORT APP   record a deferral for an OPEN transaction
  compensate STATE TX                      a failed TX takes its own record back
  app        STATE                         print the app id of any record, owed or not
  due        STATE                         print the record if activation is owed now
  clear      STATE TX                      activation of TX finished

Exit 0 = done / owed, 1 = nothing owed, 2 = refused (unsafe or inconsistent state).
"""
import json
import os
import re
import sys
import tempfile
from pathlib import Path

RECORD = 'dev-monitor-activation.json'
PREVIOUS = 'dev-monitor-activation.prev.json'
FIELDS = {'version', 'transaction_id', 'database', 'writer_user', 'backend_port', 'app_id'}
TX_RE = re.compile(r'[0-9a-f]{32}')
OPEN_PHASES = {'prepared', 'installing'}
# This record exempts its app from the pre-commit smoke pass, so it is bound to the
# one app whose database it is about. Every package child is handed the transaction
# id, and an id alone must not let any of them ask for that exemption.
APP_ID = 'dev-monitor'


class Refused(Exception):
    pass


def _fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _expected_db() -> str:
    return str(Path.home() / '.local/state/airlock/dev-monitor/messages.db')


def _load(path: Path) -> dict:
    info = path.lstat()
    if not path.is_file() or path.is_symlink():
        raise Refused(f'{path} is not a regular non-symlink file')
    if info.st_uid != os.getuid() or (info.st_mode & 0o777) != 0o600:
        raise Refused(f'{path} has unsafe ownership or mode')
    try:
        record = json.loads(path.read_text(encoding='utf-8'))
    except ValueError as exc:
        raise Refused(f'{path} is not valid JSON') from exc
    return _check(record, str(path))


def _check(record: object, path: str) -> dict:
    if not isinstance(record, dict) or set(record) != FIELDS or record['version'] != 1:
        raise Refused(f'{path} has an invalid shape')
    if not isinstance(record['transaction_id'], str) or not TX_RE.fullmatch(record['transaction_id']):
        raise Refused(f'{path} has an invalid transaction id')
    if record['database'] != _expected_db():
        raise Refused(f'{path} names a different database')
    if not isinstance(record['writer_user'], str) \
            or not re.fullmatch(r'[a-z_][a-z0-9_-]{0,31}', record['writer_user']):
        raise Refused(f'{path} has an invalid writer')
    port = record['backend_port']
    if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
        raise Refused(f'{path} has an invalid backend port')
    if record['app_id'] != APP_ID:
        raise Refused(f'{path} does not name {APP_ID}')
    return record


def _transaction(state: Path) -> dict | None:
    path = state / 'install-transaction.json'
    if not os.path.lexists(path):
        return None
    if path.is_symlink():
        raise Refused('install transaction record is a symlink')
    tx = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(tx, dict) or not TX_RE.fullmatch(str(tx.get('id', ''))):
        raise Refused('install transaction record is unreadable')
    return tx


def _atomic_write(path: Path, payload: dict) -> None:
    fd, raw = tempfile.mkstemp(prefix='.dev-monitor-activation.', dir=path.parent)
    temp = Path(raw)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            json.dump(payload, handle, sort_keys=True)
            handle.write('\n')
            handle.flush()
            os.fchmod(handle.fileno(), 0o600)
            os.fsync(handle.fileno())
        os.replace(temp, path)
        _fsync_dir(path.parent)
    finally:
        if temp.exists():
            temp.unlink()


def write(state: Path, tx_id: str, database: str, writer: str, port: str, app_id: str) -> int:
    # The environment only names a transaction; the ledger's own record and
    # checkpoint prove it is this run's open one. A caller cannot mint authority.
    tx = _transaction(state)
    checkpoint = state / 'install-checkpoints' / tx_id
    if (tx is None or tx['id'] != tx_id or tx.get('phase') not in OPEN_PHASES
            or checkpoint.is_symlink() or not checkpoint.is_dir()):
        raise Refused('deferred activation requires this run\'s open install transaction')
    if app_id not in (tx.get('planned') or []):
        raise Refused(f'{app_id} is not part of transaction {tx_id}')
    if not port.isdigit():
        raise Refused('invalid backend port')
    payload = {'version': 1, 'transaction_id': tx_id, 'database': database,
               'writer_user': writer, 'backend_port': int(port), 'app_id': app_id}
    # Validate before publishing: a record written first and checked second leaves a
    # poisoned file that this run's own rollback would then refuse to take back.
    _check(payload, 'the requested activation record')
    record = state / RECORD
    if os.path.lexists(record):
        current = _load(record)
        previous = checkpoint / PREVIOUS
        # An earlier committed transaction may still owe its activation. Keep it
        # beside this transaction's checkpoint so a rollback can hand it back.
        if current['transaction_id'] != tx_id and not os.path.lexists(previous):
            _atomic_write(previous, current)
    _atomic_write(record, payload)
    return 0


def compensate(state: Path, tx_id: str) -> int:
    record = state / RECORD
    if not os.path.lexists(record):
        return 0
    # The durable phase decides, never the caller's idea of where the run got to: a
    # signal between `transaction-finish committed` and the installer's own bookkeeping
    # would otherwise take back a record of a committed install nobody can restore.
    tx = _transaction(state)
    if tx is not None and tx['id'] == tx_id and tx.get('phase') == 'committed':
        return 0
    current = _load(record)
    if current['transaction_id'] != tx_id:
        return 0
    previous = state / 'install-checkpoints' / tx_id / PREVIOUS
    if os.path.lexists(previous):
        _load(previous)
        os.replace(previous, record)
        _fsync_dir(previous.parent)
    else:
        record.unlink()
    _fsync_dir(state)
    return 0


def app(state: Path) -> int:
    """The app named by any record, including one this run has not committed yet.

    The pre-commit smoke pass uses this: whatever transaction deferred it, the app is
    stopped until activation, and its smoke runs there instead.
    """
    record = state / RECORD
    if not os.path.lexists(record):
        return 1
    print(_load(record)['app_id'])
    return 0


def due(state: Path) -> int:
    record = state / RECORD
    if not os.path.lexists(record):
        return 1
    current = _load(record)
    tx = _transaction(state)
    # Rollback removes a transaction's own record before restoring anything, so
    # a record naming another transaction belongs to one that committed earlier.
    if tx is not None and tx['id'] == current['transaction_id'] and tx.get('phase') != 'committed':
        return 1
    print('\t'.join((current['transaction_id'], current['database'], current['writer_user'],
                     str(current['backend_port']), current['app_id'])))
    return 0


def clear(state: Path, tx_id: str) -> int:
    record = state / RECORD
    if not os.path.lexists(record):
        return 0
    if _load(record)['transaction_id'] != tx_id:
        raise Refused('activation record changed underneath this run')
    record.unlink()
    _fsync_dir(state)
    return 0


def main(argv: list[str]) -> int:
    commands = {'write': (write, 7), 'compensate': (compensate, 3),
                'app': (app, 2), 'due': (due, 2), 'clear': (clear, 3)}
    if len(argv) < 2 or argv[0] not in commands or len(argv) != commands[argv[0]][1]:
        print(__doc__, file=sys.stderr)
        return 2
    func = commands[argv[0]][0]
    state = Path(argv[1])
    if argv[0] in ('app', 'due') and not os.path.lexists(state):
        return 1
    if (state.is_symlink() or not state.is_dir()
            or state.stat().st_uid != os.getuid()):
        print('error: state directory is unsafe', file=sys.stderr)
        return 2
    if len(argv) > 2 and not TX_RE.fullmatch(argv[2]):
        print('error: invalid transaction id', file=sys.stderr)
        return 2
    try:
        return func(state, *argv[2:])
    except (Refused, OSError, ValueError) as exc:
        print(f'error: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
