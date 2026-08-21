#!/usr/bin/env python3
"""devmon_tokens — how long the provider credentials on this box have left.

Nothing on a dev box reads a credential's expiry until something fails. Claude Code
refreshes its OAuth token reactively, after an HTTP 401/403; paseo's plan panel caches
for five minutes and never re-asks; and no timer anywhere looks at `expiresAt`. So the
first sign that a token died is a job that did not run.

This module is the read side of the fix: given the credential files, say how much time
each provider has left. It is deliberately a pure function of (files, clock) so the
timer, the backend route and the tests all get the same verdict from the same code.

WHAT IT READS, AND WHAT IT REFUSES TO CARRY
    Only presence and timestamps. The token strings are never returned, never logged and
    never put in a card — the fields are read out of the parsed JSON by name and the
    parsed object is dropped. test-backend.py asserts this against a fixture whose token
    values are a sentinel string.

THE FOUR VERDICTS
    ok             time remains, past the warning threshold
    expiring-soon  inside the warning threshold — the point of the whole exercise
    expired        the deadline is behind us
    unknown        no file, or a file we cannot read the deadline out of

    `unknown` is NOT `ok`. A missing credentials file is the most likely shape of "this
    box was never set up / somebody cleared the state", and a checker that scores it
    green is worse than no checker. Every caller must render it as its own state.

WHICH FIELD IS THE DEADLINE
    Claude (`.credentials.json` -> `claudeAiOauth`): the access token in `expiresAt`
    turns over on its own every few hours, so on its own it is noise. What needs a human
    is `refreshTokenExpiresAt` — when that passes, no refresh can save the session. So
    the refresh deadline drives the verdict when it is present and the access deadline
    when it is not, and both are reported either way.

    Codex (`auth.json` -> `last_refresh`): there is no expiry field. What the file
    proves is when the token last came back alive — a panel can read green off a token
    that is already dead, and `last_refresh` is the only field that says otherwise. So
    the codex verdict is an AGE verdict: a refresh that stopped happening is the signal.
    It never reports `expired`, because staleness cannot prove death; the honest ceiling
    is `expiring-soon`. `auth_mode = "apikey"` has no refresh clock at all and is
    reported as such rather than being scored against one.
"""
import json
import os
from datetime import datetime, timezone

OK = 'ok'
EXPIRING = 'expiring-soon'
EXPIRED = 'expired'
UNKNOWN = 'unknown'

# Defaults, overridable by the caller (the installer declares them as config keys).
DEFAULT_WARN_HOURS = 24
DEFAULT_STALE_HOURS = 24

# A credentials file is a few KB. Anything larger is not one, and this runs in the
# backend's request path — so the read is bounded rather than trusting the name.
MAX_CREDENTIAL_BYTES = 256 * 1024


def now_utc():
    return datetime.now(timezone.utc)


def iso(dt):
    return dt.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def claude_credentials_path(env=None, home=None):
    """CLAUDE_HOME is what the CLI itself honours; ~/.claude is its default."""
    env = os.environ if env is None else env
    base = env.get('CLAUDE_HOME') or os.path.join(
        home if home is not None else os.path.expanduser('~'), '.claude')
    return os.path.join(base, '.credentials.json')


def codex_auth_path(env=None, home=None):
    env = os.environ if env is None else env
    base = env.get('CODEX_HOME') or os.path.join(
        home if home is not None else os.path.expanduser('~'), '.codex')
    return os.path.join(base, 'auth.json')


def _verdict(provider, status, detail, **extra):
    """One verdict. `fields_present` names fields we FOUND; it never carries their values."""
    out = {'provider': provider, 'status': status, 'detail': detail,
           'path': None, 'expires_at': None, 'seconds_remaining': None,
           'fields_present': []}
    out.update(extra)
    return out


def _read_json(path):
    """-> (obj, None) | (None, reason). A reason is a short phrase, never file content.

    Distinguishes 'missing' from every other failure: an absent file usually means the
    provider was never set up here, while an unreadable or malformed one is an anomaly
    somebody has to look at. Both are `unknown`; only the second is worth waking anyone.
    """
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return None, 'missing'
    except OSError as e:
        return None, 'unreadable (%s)' % e.__class__.__name__
    if st.st_size > MAX_CREDENTIAL_BYTES:
        return None, 'implausible size (%d bytes)' % st.st_size
    try:
        with open(path, 'rb') as f:
            raw = f.read(MAX_CREDENTIAL_BYTES + 1)
    except OSError as e:
        return None, 'unreadable (%s)' % e.__class__.__name__
    try:
        obj = json.loads(raw.decode('utf-8'))
    except (UnicodeDecodeError, ValueError):
        # The exception text would quote the offending bytes, which in this file are
        # the token. Only the shape of the failure comes back.
        return None, 'malformed JSON'
    if not isinstance(obj, dict):
        return None, 'not a JSON object'
    return obj, None


def _epoch_ms(value):
    """Epoch milliseconds -> aware datetime, or None. Rejects bool, which is an int."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    try:
        return datetime.fromtimestamp(value / 1000.0, timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None


def _parse_iso(value):
    if not isinstance(value, str) or not value.strip():
        return None
    txt = value.strip()
    if txt.endswith('Z'):
        txt = txt[:-1] + '+00:00'
    try:
        dt = datetime.fromisoformat(txt)
    except ValueError:
        return None
    if dt.tzinfo is None:
        # A naive stamp in a credentials file is written by a local clock; reading it as
        # UTC is the assumption that never reports MORE time than there is.
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def humanize(seconds):
    """'in 3d 4h' / '2h ago'. Only ever formats a duration — no identifiers pass through."""
    if seconds is None:
        return '—'
    past = seconds < 0
    s = int(abs(seconds))
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    m, _ = divmod(s, 60)
    if d:
        text = '%dd %dh' % (d, h)
    elif h:
        text = '%dh %dm' % (h, m)
    else:
        text = '%dm' % m
    return ('%s ago' % text) if past else ('in %s' % text)


def check_claude(path=None, now=None, warn_hours=DEFAULT_WARN_HOURS):
    now = now or now_utc()
    path = path or claude_credentials_path()
    obj, reason = _read_json(path)
    if obj is None:
        return _verdict('claude', UNKNOWN, 'credentials %s' % reason, path=path,
                        reason=reason)
    oauth = obj.get('claudeAiOauth')
    if not isinstance(oauth, dict):
        return _verdict('claude', UNKNOWN, 'no claudeAiOauth section', path=path,
                        reason='no claudeAiOauth section')
    access = _epoch_ms(oauth.get('expiresAt'))
    refresh = _epoch_ms(oauth.get('refreshTokenExpiresAt'))
    present = [name for name, value in (('expiresAt', access),
                                        ('refreshTokenExpiresAt', refresh))
               if value is not None]
    # The refresh deadline is the one a person has to act on; see the module docstring.
    deadline, which = (refresh, 'refreshTokenExpiresAt') if refresh else (access, 'expiresAt')
    if deadline is None:
        return _verdict('claude', UNKNOWN, 'no usable expiry field', path=path,
                        fields_present=present, reason='no usable expiry field')
    remaining = int((deadline - now).total_seconds())
    if remaining <= 0:
        status, detail = EXPIRED, '%s passed %s' % (which, humanize(remaining))
    elif remaining <= warn_hours * 3600:
        status, detail = EXPIRING, '%s expires %s' % (which, humanize(remaining))
    else:
        status, detail = OK, '%s expires %s' % (which, humanize(remaining))
    return _verdict('claude', status, detail, path=path, expires_at=iso(deadline),
                    seconds_remaining=remaining, fields_present=present,
                    deadline_field=which,
                    access_expires_at=iso(access) if access else None,
                    refresh_expires_at=iso(refresh) if refresh else None)


def check_codex(path=None, now=None, stale_hours=DEFAULT_STALE_HOURS):
    now = now or now_utc()
    path = path or codex_auth_path()
    obj, reason = _read_json(path)
    if obj is None:
        return _verdict('codex', UNKNOWN, 'auth %s' % reason, path=path, reason=reason)
    mode = obj.get('auth_mode')
    mode = mode if isinstance(mode, str) and mode.strip() else None
    # TOP LEVEL, and this is not a detail: an earlier revision of this file read
    # `tokens.last_refresh`, which is where the field looks like it should be — `tokens`
    # is right there holding the three token strings. It is not there. Every real box
    # would have reported codex as `unknown` forever, and because an unreadable-but-
    # present file publishes a card, the timer would have posted one every single run.
    # The tests passed because the fixture had invented the nested shape. The nested
    # form is still accepted in case a codex release moves it.
    tokens = obj.get('tokens') if isinstance(obj.get('tokens'), dict) else {}
    field, last = 'last_refresh', _parse_iso(obj.get('last_refresh'))
    if last is None:
        field, last = 'tokens.last_refresh', _parse_iso(tokens.get('last_refresh'))
    present = ([f for f in ('auth_mode',) if mode] + ([field] if last else []))
    if mode == 'apikey':
        # An API key does not refresh, so there is no clock to be stale against. Saying
        # 'ok' here is a statement about the SHAPE of the credential, not its validity.
        return _verdict('codex', OK, 'api-key mode — no refresh clock to age',
                        path=path, fields_present=present, auth_mode=mode)
    if last is None:
        return _verdict('codex', UNKNOWN, 'no last_refresh timestamp', path=path,
                        fields_present=present, auth_mode=mode,
                        reason='no last_refresh timestamp')
    age = int((now - last).total_seconds())
    # Negative age = a clock disagreement, not freshness. Treated as unknown rather than
    # as the freshest possible token, which is the reading that hides a problem.
    if age < 0:
        return _verdict('codex', UNKNOWN, 'last_refresh is in the future',
                        path=path, fields_present=present, auth_mode=mode,
                        last_refresh=iso(last), reason='last_refresh in the future')
    if age >= stale_hours * 3600:
        status = EXPIRING
        detail = 'last refreshed %s — the session may already be dead' % humanize(-age)
    else:
        status = OK
        detail = 'last refreshed %s' % humanize(-age)
    return _verdict('codex', status, detail, path=path, fields_present=present,
                    auth_mode=mode, last_refresh=iso(last), last_refresh_field=field,
                    age_seconds=age,
                    seconds_remaining=max(0, stale_hours * 3600 - age))


def check_all(now=None, warn_hours=DEFAULT_WARN_HOURS, stale_hours=DEFAULT_STALE_HOURS,
              claude_path=None, codex_path=None):
    """Every provider, one snapshot. -> {'checked_at', 'warn_hours', 'stale_hours',
    'worst', 'providers': [...]}"""
    now = now or now_utc()
    providers = [check_claude(claude_path, now, warn_hours),
                 check_codex(codex_path, now, stale_hours)]
    return {'checked_at': iso(now), 'warn_hours': warn_hours,
            'stale_hours': stale_hours, 'worst': worst_status(providers),
            'providers': providers}


def snapshot_path(env=None, home=None):
    """Where the timer leaves its last verdict, and where the backend looks for it.

    The two halves are separate processes with no channel between them, so the file IS
    the channel — and its mtime is what makes a checker that stopped running visible as
    staleness rather than as silence.
    """
    env = os.environ if env is None else env
    explicit = env.get('DEV_MONITOR_TOKEN_SNAPSHOT')
    if explicit:
        return explicit
    home = home if home is not None else os.path.expanduser('~')
    return os.path.join(home, '.local', 'state', 'airlock', 'dev-monitor',
                        'token-freshness.json')


def write_snapshot(path, snapshot):
    """Write atomically (tmp + rename) at 0600, so a reader never sees half a file."""
    directory = os.path.dirname(path) or '.'
    os.makedirs(directory, mode=0o700, exist_ok=True)
    tmp = path + '.tmp'
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(snapshot, f, ensure_ascii=False, indent=2)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.replace(tmp, path)


def read_snapshot(path):
    """-> the timer's last snapshot with `age_seconds` added, or None.

    None means "the timer has never written here", which the UI must show as its own
    state. Reporting it as fresh-and-fine is the failure this module exists to prevent.
    """
    obj, _reason = _read_json(path)
    if obj is None or not isinstance(obj.get('checked_at'), str):
        return None
    checked = _parse_iso(obj['checked_at'])
    obj['age_seconds'] = int((now_utc() - checked).total_seconds()) if checked else None
    return obj


# Ordered worst-first. `unknown` outranks `ok` deliberately: see the module docstring.
_SEVERITY = (EXPIRED, EXPIRING, UNKNOWN, OK)


def worst_status(providers):
    for status in _SEVERITY:
        if any(p['status'] == status for p in providers):
            return status
    return OK
