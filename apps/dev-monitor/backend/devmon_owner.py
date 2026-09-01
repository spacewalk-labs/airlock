#!/usr/bin/env python3
"""devmon_owner — the owner gate for owner-scoped dev-monitor APIs.

Three layers, and only the middle one is a boundary: nginx blocks first, THIS module is the
authorization boundary, and the frontend merely displays. Every request re-checks two
things — that it came through nginx (the proxy secret, which only nginx injects) and who
the ingress says is asking (the owner header).

Fail-closed on configuration: a PARTIALLY configured gate raises rather than running with a
hole. Nothing configured at all is a different case — its optional consumer is simply not
deployed and the monitor keeps serving observability.

Mutating requests are authenticated BEFORE the body is read, and are additionally checked
for same-origin, JSON content type and size.
"""
import hmac
import os

# The message feature needs all of these, or none of them.
_REQUIRED = ('DEV_MONITOR_OWNER', 'DEV_MONITOR_PROXY_SECRET',
             'DEV_MONITOR_SPOOL', 'DEV_MONITOR_DB')
_GATE_REQUIRED = ('DEV_MONITOR_OWNER', 'DEV_MONITOR_PROXY_SECRET')

MAX_BODY = 64 * 1024                    # cap for an owner POST body


class ConfigError(RuntimeError):
    pass


def load_config():
    """-> a config dict (feature on) or None (feature off). Partially set raises."""
    present = {k: os.environ.get(k, '').strip() for k in _REQUIRED}
    have = [k for k, v in present.items() if v]
    if not have:
        return None                     # not deployed; carry on as an observability monitor
    if len(have) != len(_REQUIRED):
        missing = [k for k in _REQUIRED if not present[k]]
        raise ConfigError('message feature is partially configured (fail-closed) — missing: %s'
                          % ', '.join(missing))
    return {
        'owner': present['DEV_MONITOR_OWNER'],
        'secret': present['DEV_MONITOR_PROXY_SECRET'],
        'spool': present['DEV_MONITOR_SPOOL'],
        'db': present['DEV_MONITOR_DB'],
    }


def load_gate_config():
    """-> the owner/proxy gate, or None when its consumer is not installed.

    Updates are owner-scoped even when the optional message spool is off.  Keep its
    two-value ingress gate separate from the message feature's all-or-nothing spool
    configuration: accepting one without the other would make a direct loopback
    request look like an owner request.
    """
    present = {k: os.environ.get(k, '').strip() for k in _GATE_REQUIRED}
    have = [k for k, v in present.items() if v]
    if not have:
        return None
    if len(have) != len(_GATE_REQUIRED):
        missing = [k for k in _GATE_REQUIRED if not present[k]]
        raise ConfigError('owner gate is partially configured (fail-closed) — missing: %s'
                          % ', '.join(missing))
    return {'owner': present['DEV_MONITOR_OWNER'], 'secret': present['DEV_MONITOR_PROXY_SECRET']}


def require_owner(handler, config):
    """Constant-time compare of BOTH the proxy secret and the owner. Writes 403 and returns
    False on failure. The secret is the one that has to be constant-time; the owner is
    compared the same way because there is no reason to have two comparison styles here."""
    # Compared as BYTES: hmac.compare_digest refuses a str with non-ASCII characters, and
    # http.server hands us headers decoded as latin-1. One accented character in a header —
    # or in the configured owner — otherwise raised before either comparison finished.
    def _b(value):
        return value.encode('utf-8', 'surrogateescape')

    secret = handler.headers.get('X-Devmon-Proxy-Secret', '')
    owner = handler.headers.get('X-Devmon-Owner', '')
    ok_secret = hmac.compare_digest(_b(secret), _b(config['secret']))
    ok_owner = hmac.compare_digest(_b(owner), _b(config['owner']))
    if not (ok_secret and ok_owner):
        # No data and no hint in the body — a 403 must not say which check failed.
        handler._json(403, {'ok': False})
        return False
    return True


def _host_only(hostport):
    """host[:port] -> host. Handles the IPv6 form '[::1]:port' too."""
    if hostport.startswith('['):
        return hostport.split(']', 1)[0] + ']'
    return hostport.rsplit(':', 1)[0] if ':' in hostport else hostport


def check_mutating(handler):
    """Same-origin + JSON + size checks for a mutating POST. Call BEFORE reading the body.

    True = passed. False = a 4xx has already been written.
    """
    # Same-origin by HOSTNAME, ignoring the port — this is what stops an external site from
    # POSTing here with the browser's credentials.
    #   Why the port is ignored: nginx forwards Host as $host (no port) while the browser's
    #   Origin includes a non-default port, so an exact comparison rejected perfectly good
    #   requests as 'bad origin'. A port difference is not a boundary here, and an external
    #   origin is still refused on the hostname. The owner header and the proxy secret are
    #   injected by nginx alone, so neither can be supplied by the caller either way.
    origin = handler.headers.get('Origin', '')
    host = handler.headers.get('Host', '')
    if origin:
        stripped = origin.split('://', 1)[-1]
        if _host_only(stripped) != _host_only(host):
            handler._json(403, {'ok': False, 'error': 'bad origin'})
            return False
    else:
        # A mutating request with no Origin is refused: a browser same-origin POST sends one,
        # so its absence means the caller is not the UI.
        handler._json(403, {'ok': False, 'error': 'missing origin'})
        return False
    ctype = handler.headers.get('Content-Type', '')
    if not ctype.startswith('application/json'):
        handler._json(415, {'ok': False, 'error': 'json required'})
        return False
    try:
        clen = int(handler.headers.get('Content-Length', '0'))
    except ValueError:
        clen = -1
    if clen < 0 or clen > MAX_BODY:
        handler._json(413, {'ok': False, 'error': 'body too large'})
        return False
    return True
