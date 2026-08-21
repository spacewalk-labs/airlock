#!/usr/bin/env python3
"""airlock-feedback — a suggestion-box relay to PLUGGABLE delivery targets.

Runs on loopback (127.0.0.1:<backend_port>); the hub nginx proxies /feedback/api/
here. The hub's suggestion box POSTs {text}; this backend attaches the owner
SERVER-SIDE from the gate-verified identity header (never a client field) and
delivers it. It never parses airlock.toml itself — the installer passes everything
via the environment.

Two INDEPENDENT, optional targets. Configure either, both, or neither:

  1. intake  — forwards {owner, text} to an external endpoint that creates a
     tracking item (e.g. a GitHub issue) and returns its URL.
  2. mail    — sends the suggestion to a configured address over a transactional
     mail API, so a suggestion lands in an inbox with no tracker to check.

Neither configured = the box degrades cleanly (it stays hidden; submit reports
"not configured"). Both configured = a submission must reach BOTH to count as
sent; a partial delivery is reported as a failure, never as success.

Secrets (intake token, mail API key) live in env vars whose NAMES are configured,
delivered via an EnvironmentFile — so no secret and no recipient address needs to
sit in airlock.toml's committed example.

Intake protocol (what a target must implement) — JSON over HTTPS, the token in
the `X-Airlock-Feedback-Token` header:
  POST <intake>/submit   {owner, text}  ->  {ok, issue_url}
`owner` is the gate-verified login of the submitter; the target decides how it
records the suggestion (this backend just relays and returns `issue_url`).
"""
import json
import os
import sys
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get('AIRLOCK_FEEDBACK_BACKEND_PORT', '18805'))
IDENTITY_HEADER = os.environ.get('AIRLOCK_IDENTITY_HEADER', 'Tailscale-User-Login')

# ---- target 1: pluggable external intake (all optional) ----
INTAKE_URL = os.environ.get('AIRLOCK_FEEDBACK_INTAKE_URL', '').rstrip('/')
# The token lives in an env var whose NAME is configured (secret stays out of the
# config file); default AIRLOCK_FEEDBACK_TOKEN. The installer wires an EnvironmentFile.
_TOKEN_ENV = os.environ.get('AIRLOCK_FEEDBACK_TOKEN_ENV', '').strip() or 'AIRLOCK_FEEDBACK_TOKEN'
TOKEN = os.environ.get(_TOKEN_ENV, '')
INTAKE_ENABLED = bool(INTAKE_URL and TOKEN)

# ---- target 2: mail (all optional) ----
# A transactional mail API, not SMTP: this box has no MTA and its outbound mail
# would have no SPF/DKIM to stand on. Default endpoint speaks the Resend API
# ({from,to,reply_to,subject,text} + bearer token); swap MAIL_API + the body in
# _send_mail() for another provider.
MAIL_TO = os.environ.get('AIRLOCK_FEEDBACK_MAIL_TO', '').strip()
MAIL_FROM = os.environ.get('AIRLOCK_FEEDBACK_MAIL_FROM', '').strip()
# `or` not a get() default: the installer always writes these vars, so an
# unconfigured one arrives as an empty string rather than absent.
MAIL_API = os.environ.get('AIRLOCK_FEEDBACK_MAIL_API', '').strip() or 'https://api.resend.com/emails'
_MAIL_KEY_ENV = os.environ.get('AIRLOCK_FEEDBACK_MAIL_KEY_ENV', '').strip() or 'RESEND_API_KEY'
MAIL_KEY = os.environ.get(_MAIL_KEY_ENV, '')
MAIL_ENABLED = bool(MAIL_TO and MAIL_FROM and MAIL_KEY)

FEEDBACK_ENABLED = INTAKE_ENABLED or MAIL_ENABLED

TEXT_MAX = 8000   # generous cap; a target may clamp further
SUBJECT_MAX = 70  # keep the subject one readable line in a mail client list


def _one_line(s):
    """Collapse newlines — a subject built from user text must not inject headers."""
    return ' '.join(str(s).split())


def _relay_intake(text, owner):
    """Forward {owner, text} to the external intake, returning (ok, result|error)."""
    body = json.dumps({'owner': owner or 'unknown', 'text': text}).encode('utf-8')
    req = urllib.request.Request(
        INTAKE_URL + '/submit', data=body, method='POST',
        headers={'Content-Type': 'application/json',
                 # Explicit UA: some edge WAFs (e.g. Cloudflare Bot Fight Mode)
                 # 403 the default `Python-urllib` User-Agent.
                 'User-Agent': 'airlock-feedback/1',
                 'X-Airlock-Feedback-Token': TOKEN})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            res = json.loads(r.read().decode('utf-8'))
    except Exception as e:
        return False, f'unreachable: {e}'
    if not res.get('ok'):
        return False, res.get('error', 'intake error')
    return True, {'issue_url': res.get('issue_url')}


def _send_mail(text, owner):
    """Mail the suggestion to the configured address, returning (ok, None|error)."""
    who = _one_line(owner or 'unknown')
    subject = f'[Airlock] {who}: {_one_line(text)}'[:SUBJECT_MAX]
    payload = {'from': MAIL_FROM, 'to': [MAIL_TO], 'subject': subject,
               'text': f'From: {who}\n\n{text}\n'}
    # The identity header is a login, which on the supported gate is an email —
    # so a reply goes back to the submitter instead of dead-ending in the inbox.
    if '@' in who and ' ' not in who:
        payload['reply_to'] = who
    req = urllib.request.Request(
        MAIL_API, data=json.dumps(payload).encode('utf-8'), method='POST',
        headers={'Content-Type': 'application/json',
                 'User-Agent': 'airlock-feedback/1',
                 'Authorization': f'Bearer {MAIL_KEY}'})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            r.read()
    except Exception as e:
        # The key must never reach a log line, and provider error bodies echo
        # request fields — report the class of failure only.
        return False, f'send failed: {type(e).__name__}'
    return True, None


def submit_feedback(text, owner):
    """Deliver to every configured target. ok only if ALL of them succeeded."""
    if not FEEDBACK_ENABLED:
        return False, 'feedback not configured ([apps.feedback])'
    text = (text or '').strip()
    if not text:
        return False, 'empty message'
    if len(text) > TEXT_MAX:
        return False, f'message too long (>{TEXT_MAX} chars)'

    result, errors = {}, []
    if INTAKE_ENABLED:
        ok, res = _relay_intake(text, owner)
        if ok:
            result.update(res)
        else:
            errors.append(f'intake: {res}')
    if MAIL_ENABLED:
        ok, err = _send_mail(text, owner)
        if not ok:
            errors.append(f'mail: {err}')
    if errors:
        return False, '; '.join(errors)
    return True, result


class Handler(BaseHTTPRequestHandler):
    def _json(self, status, payload):
        body = json.dumps(payload).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        n = int(self.headers.get('Content-Length', '0'))
        if n <= 0:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode('utf-8'))
        except Exception:
            return {}

    def _strip(self, path):
        for prefix in ('/feedback/', '/feedback'):
            if path.startswith(prefix):
                path = path[len(prefix):]
                return path if path.startswith('/') else '/' + path
        return path

    def _owner(self):
        # The gate-verified identity, injected by the hub nginx (tailscale serve
        # strips any client-supplied copy). NEVER trust a client-sent owner field.
        return self.headers.get(IDENTITY_HEADER, '')

    def do_GET(self):
        path = self._strip(urllib.parse.urlparse(self.path).path)
        if path in ('/api/health', '/health', '/'):
            # `enabled` drives the hub's box; the per-target flags make a
            # half-configured install visible instead of silently one-legged.
            self._json(200, {'ok': True, 'service': 'airlock-feedback',
                             'port': PORT, 'enabled': FEEDBACK_ENABLED,
                             'intake': INTAKE_ENABLED, 'mail': MAIL_ENABLED})
            return
        self._json(404, {'ok': False, 'error': f'unknown path: {path}'})

    def do_POST(self):
        path = self._strip(urllib.parse.urlparse(self.path).path)
        body = self._read_body()
        if path in ('/api/submit', '/submit'):
            ok, res = submit_feedback(body.get('text', ''), self._owner())
            self._json(200 if ok else 400,
                       {'ok': ok, **res} if ok else {'ok': ok, 'error': res})
            return
        self._json(404, {'ok': False, 'error': f'unknown path: {path}'})

    def log_message(self, fmt, *args):
        sys.stderr.write(f'[airlock-feedback] {self.address_string()} - {fmt % args}\n')


def main():
    print(f'[airlock-feedback] listen=127.0.0.1:{PORT} enabled={FEEDBACK_ENABLED} '
          f'intake={INTAKE_ENABLED} mail={MAIL_ENABLED}', flush=True)
    # Loud about a target that was asked for but can't run — a half-configured
    # target would otherwise look like a deliberate omission.
    if INTAKE_URL and not TOKEN:
        print(f'[airlock-feedback] WARNING intake_url set but ${_TOKEN_ENV} is empty '
              '— intake disabled', flush=True)
    if (MAIL_TO or MAIL_FROM) and not MAIL_ENABLED:
        missing = [n for n, v in (('mail_to', MAIL_TO), ('mail_from', MAIL_FROM),
                                  (f'${_MAIL_KEY_ENV}', MAIL_KEY)) if not v]
        print(f'[airlock-feedback] WARNING mail configured but missing {", ".join(missing)} '
              '— mail disabled', flush=True)
    with ThreadingHTTPServer(('127.0.0.1', PORT), Handler) as server:
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == '__main__':
    main()
