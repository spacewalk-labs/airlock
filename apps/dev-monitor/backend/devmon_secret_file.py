"""EnvironmentFile assignment boundaries only; systemd alone interprets values.

The states follow systemd's env-file.c (v255). No value is decoded, returned,
printed, or placed in an argument. Malformed/non-assignment input fails closed.
"""
import os
from pathlib import Path
import re
import stat

from devmon_secret_names import validate_names
from devmon_secrets import SLACK_CONFIG

LEGACY_NAMES = frozenset(name for _, names in SLACK_CONFIG.values() for name in names)


def assignment_names(text):
    if '\0' in text:
        raise ValueError('invalid credential file syntax')
    state, key, names = 'start', '', []
    for char in text:
        if state == 'start':
            if char in ' \t\r\n':
                continue
            if char in '#;':
                state = 'comment'
            else:
                key, state = char, 'key'
        elif state == 'comment':
            # Since systemd v254, a backslash does not continue a comment line.
            if char in '\r\n':
                state = 'start'
        elif state == 'key':
            if char == '=':
                key = key.rstrip(' \t')
                if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', key):
                    raise ValueError('invalid credential file syntax')
                names.append(key)  # Check every assignment, including duplicates.
                state = 'before'
            elif char in '\r\n':
                raise ValueError('invalid credential file syntax')
            else:
                key += char
        elif state == 'before':
            if char in '\r\n':
                state = 'start'
            elif char == "'":
                state = 'single'
            elif char == '"':
                state = 'double'
            elif char == '\\':
                state = 'escape'
            elif char not in ' \t':
                state = 'value'
        elif state == 'value':
            if char in '\r\n':
                state = 'start'
            elif char == '\\':
                state = 'escape'
        elif state == 'escape':
            state = 'value'
        elif state == 'single':
            if char == "'":
                state = 'before'
        elif state == 'double':
            if char == '"':
                state = 'before'
            elif char == '\\':
                state = 'double_escape'
        elif state == 'double_escape':
            state = 'double'
    if state not in ('start', 'before', 'value', 'comment'):
        raise ValueError('unterminated credential file syntax')
    return tuple(names)


def inspect_file(path, selected=()):
    """Check metadata and all assignment names before any environment is loaded."""
    validate_names(*selected)
    path = Path(path)
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o600):
        raise ValueError('credential file must be a user-owned regular file with mode 0600')
    # Preserve CRLF and quoted newlines; universal-newline translation would
    # change the boundaries that the real loader sees.
    names = assignment_names(path.read_bytes().decode('utf-8'))
    if not set(names) <= (set(filter(None, selected)) | LEGACY_NAMES):
        raise ValueError('credential file contains an unselected or control assignment')
    return names
