#!/usr/bin/env python3
"""airlock-publish — static-share manager + optional pluggable external publish.

Runs on loopback (127.0.0.1:<backend_port>); the hub nginx proxies /publish/api/
here. It manages a local static-share directory (default ~/public_html): list,
unpublish (unlink symlinks, keeping the original), delete direct files (2-step
confirm), batch, repair broken symlinks, and accept clipboard/file uploads into
~/uploads (the notepad drop). It never parses airlock.toml itself — the installer
passes everything via the environment.

Optional external publish is a PLUGGABLE target with TWO backends, chosen by
[apps.publish.public_target] mode:

  mode = "remote" (default) — POST the snapshot to YOUR ingest service
      (AIRLOCK_PUBLISH_INGEST_URL + base_url + token). You host the receiver.
  mode = "local"            — write the snapshot into a public directory that
      THIS box's nginx serves (AIRLOCK_PUBLISH_PUBLIC_DIR + base_url). No second
      service, no token; expiry is enforced by this process (list/ingest sweep +
      the --cleanup timer).

Unconfigured => local-share manager only (the external endpoints report disabled
and the UI hides them).

Ingest protocol (what a REMOTE target must implement) — JSON over HTTPS, the
token in the `X-Airlock-Publish-Token` header:
  POST <ingest>/ingest      {slug, owner, src, title, ttl_hours, html_b64} -> {ok, result:{expiry, ttl_hours}}
  GET  <ingest>/list?owner= -> {ok, items:[{slug, owner, src, title, expiry, expired, mode}]}
  POST <ingest>/revoke      {slug, owner} -> {ok}
  POST <ingest>/set-expiry  {slug, owner, ttl_hours} -> {ok}
Remote mode accepts only one open document; bundle files and password-gated
publishing are local-target features and are rejected before ingest.
The public URL shown to the user is `<base_url>/<slug>/`.

Design notes for the local target live in docs/design/publish-local-target.md.
"""
import base64
import fcntl
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime
from html import unescape as html_unescape
from html.parser import HTMLParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.expanduser(os.environ.get('AIRLOCK_PUBLISH_SHARE_DIR', '~/public_html'))
PORT = int(os.environ.get('AIRLOCK_PUBLISH_BACKEND_PORT', '18803'))
UPLOADS = os.path.expanduser(os.environ.get('AIRLOCK_PUBLISH_UPLOADS_DIR', '~/uploads'))
HOME = os.path.expanduser('~')
IDENTITY_HEADER = os.environ.get('AIRLOCK_IDENTITY_HEADER', 'Tailscale-User-Login')

# ---- pluggable external publish target (all optional) ----
INGEST_URL = os.environ.get('AIRLOCK_PUBLISH_INGEST_URL', '').rstrip('/')
BASE_URL = os.environ.get('AIRLOCK_PUBLISH_BASE_URL', '').rstrip('/')
# The token lives in an env var whose NAME is configured (secret stays out of the
# config file); default AIRLOCK_PUBLISH_TOKEN. The installer wires an EnvironmentFile.
_TOKEN_ENV = os.environ.get('AIRLOCK_PUBLISH_TOKEN_ENV', 'AIRLOCK_PUBLISH_TOKEN')
TOKEN = os.environ.get(_TOKEN_ENV, '')
# "local" is opt-in and EXPLICIT. Inferring it from which keys are present would
# silently turn a half-configured remote install (base_url left behind, token
# gone) into a live public publisher, so the mode is never guessed.
PUBLIC_MODE = (os.environ.get('AIRLOCK_PUBLISH_PUBLIC_MODE', '') or 'remote').strip().lower()
PUBLIC_DIR = os.path.expanduser(os.environ.get('AIRLOCK_PUBLISH_PUBLIC_DIR', ''))
STATE_DIR = os.path.expanduser(os.environ.get('AIRLOCK_PUBLISH_STATE_DIR', '~/.local/state/airlock'))
STATE_FILE = os.path.join(STATE_DIR, 'publish-public.json')
LOCK_FILE = os.path.join(STATE_DIR, 'publish-public.lock')
LOCAL_MAX_BYTES = 25 * 1024 * 1024      # local disk guard; the remote path stays unlimited
RECONCILE_GRACE = 24 * 3600             # untracked slug dirs get swept after this
TTL_MIN_H, TTL_MAX_H, TTL_DEFAULT_H = 1, 24 * 365, 336
_RE_SLUG = re.compile(r'^[a-z0-9][a-z0-9-]{2,63}\Z')
# Transaction siblings are private recovery records, never publishable slugs.
_RE_TRANSACTION = re.compile(
    r'^(?P<slug>[a-z0-9][a-z0-9-]{2,63})\.(?P<kind>old|stage|failed)-[0-9a-f]+\Z')

# A plan is a short-lived, single-use capability for an explicit bundle build.
MAX_BUNDLE_DOCS = 50
MAX_BUNDLE_TOTAL_BYTES = 60 * 1024 * 1024
BUNDLE_PLAN_TTL_S = 10 * 60
MAX_BUNDLE_PLANS = 256
_BUNDLE_PLANS = {}
_BUNDLE_PLANS_LOCK = threading.Lock()

# crypt was removed from Python 3.13. Use htpasswd's bcrypt implementation,
# rather than embedding password hashing code in this service.
GATED_DIR = os.path.expanduser(os.environ.get('AIRLOCK_PUBLISH_GATED_DIR', '/opt/airlock/share-gated'))
HTPASSWD_DIR = os.path.expanduser(os.environ.get(
    'AIRLOCK_PUBLISH_HTPASSWD_DIR', '/opt/airlock/publish-gated-auth'))
HTPASSWD_BIN = os.environ.get('AIRLOCK_PUBLISH_HTPASSWD_BIN', 'htpasswd')
GATED_ENABLED = False
GATED_DISABLED_REASON = ''


def _overlaps(a, b):
    """True if two directories are the same or one contains the other."""
    ra, rb = os.path.realpath(a), os.path.realpath(b)
    return ra == rb or ra.startswith(rb + os.sep) or rb.startswith(ra + os.sep)


def _public_check():
    """(enabled, reason). A non-empty reason is logged once at startup so a
    half-configured target fails loudly instead of silently doing nothing."""
    if PUBLIC_MODE == 'local':
        if not BASE_URL:
            return False, 'local mode: base_url missing'
        if not PUBLIC_DIR:
            return False, 'local mode: public_dir missing'
        # The whole point of a separate dir: share_dir is the TAILNET-INTERNAL
        # share (symlinks the owner added for private viewing). Serving it
        # publicly would publish all of them.
        if _overlaps(PUBLIC_DIR, ROOT):
            return False, (f'local mode: public_dir ({PUBLIC_DIR}) overlaps share_dir ({ROOT}) — '
                           'refusing (that would publish the internal share)')
        try:
            os.makedirs(PUBLIC_DIR, exist_ok=True)
        except OSError as e:
            return False, f'local mode: cannot create public_dir: {e}'
        if not os.access(PUBLIC_DIR, os.W_OK):
            return False, f'local mode: public_dir not writable: {PUBLIC_DIR}'
        return True, ''
    missing = [n for n, v in (('ingest_url', INGEST_URL), ('base_url', BASE_URL), (_TOKEN_ENV, TOKEN)) if not v]
    if not missing:
        return True, ''
    # Nothing at all configured = the ordinary local-only install, not a mistake.
    partial = any((INGEST_URL, BASE_URL, TOKEN))
    return False, (f'remote mode: missing {", ".join(missing)}' if partial else '')


PUBLIC_ENABLED, PUBLIC_DISABLED_REASON = _public_check()


def _gated_storage_check():
    """Return a reason if the optional local gate cannot safely write/read."""
    if PUBLIC_MODE != 'local':
        return 'gated publishing is available only in local mode'
    if _overlaps(GATED_DIR, ROOT) or _overlaps(GATED_DIR, PUBLIC_DIR):
        return 'gated_dir overlaps an internal or public directory'
    if any(_overlaps(HTPASSWD_DIR, root) for root in (ROOT, PUBLIC_DIR, GATED_DIR)):
        return 'htpasswd_dir overlaps a served or internal directory'
    for path, label, mode in ((GATED_DIR, 'gated_dir', 0o755),
                              (HTPASSWD_DIR, 'htpasswd_dir', 0o755)):
        try:
            os.makedirs(path, mode=mode, exist_ok=True)
            os.chmod(path, mode)
        except OSError as exc:
            return f'cannot create {label}: {exc}'
        if not os.access(path, os.W_OK):
            return f'{label} not writable: {path}'
    return ''


if PUBLIC_MODE == 'local':
    if not shutil.which(HTPASSWD_BIN):
        GATED_DISABLED_REASON = f'htpasswd unavailable: {HTPASSWD_BIN}'
    else:
        GATED_DISABLED_REASON = _gated_storage_check()
        GATED_ENABLED = not GATED_DISABLED_REASON


def list_items():
    """One level of the share dir (no recursion)."""
    items = []
    if not os.path.isdir(ROOT):
        return items
    for name in sorted(os.listdir(ROOT)):
        if name.startswith('.'):
            continue
        full = os.path.join(ROOT, name)
        try:
            lstat = os.lstat(full)
        except OSError:
            continue
        is_link = os.path.islink(full)
        is_dir = os.path.isdir(full)
        is_broken = is_link and not os.path.exists(full)   # dangling symlink (target gone)
        target = None
        if is_link:
            try:
                raw = os.readlink(full)
                target = raw.replace(HOME, '~') if raw.startswith(HOME) else raw
            except OSError:
                target = '(broken link)'
        if name.endswith(('.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp')):
            ftype = 'image'
        elif name.endswith('.html'):
            ftype = 'html'
        elif is_dir:
            ftype = 'dir'
        else:
            ftype = 'file'
        target_dir = ''
        if target:
            target_dir = os.path.dirname(target) or '/'
        elif not is_link:
            target_dir = '(direct file)'
        items.append({
            'name': name,
            'type': ftype,
            'target': target,
            'target_dir': target_dir,
            'isLink': is_link,
            'isDir': is_dir,
            'isBroken': is_broken,
            'size': format_size(lstat.st_size, is_dir),
            'mtime': datetime.fromtimestamp(lstat.st_mtime).strftime('%Y-%m-%d %H:%M'),
            'mtime_epoch': int(lstat.st_mtime),
        })
    return items


def format_size(size, is_dir):
    if is_dir:
        return 'dir'
    if size < 1024:
        return f'{size} B'
    if size < 1024 * 1024:
        return f'{size // 1024} KB'
    return f'{size / (1024*1024):.1f} MB'


def safe_resolve(name):
    """name -> absolute path inside ROOT. Blocks path traversal. Lexical (does
    not follow the symlink itself)."""
    if not name or '/' in name or name.startswith('.'):
        return None
    real_root = os.path.realpath(ROOT)
    lexical = os.path.normpath(os.path.join(ROOT, name))
    if not lexical.startswith(real_root + os.sep) and lexical != real_root:
        return None
    return lexical


def unpublish(name):
    """Unlink a symlink (original preserved). Refuses direct files."""
    path = safe_resolve(name)
    if not path or not os.path.lexists(path):
        return False, f'not found: {name}'
    if not os.path.islink(path):
        return False, 'not a symlink — use unpublish-direct with confirm_name'
    try:
        os.unlink(path)
        return True, f'unlinked: {name}'
    except OSError as e:
        return False, str(e)


def unpublish_direct(name, confirm_name):
    """Delete a direct (non-symlink) file — only when the name is retyped."""
    if name != confirm_name:
        return False, 'confirm_name mismatch'
    path = safe_resolve(name)
    if not path or not os.path.lexists(path):
        return False, f'not found: {name}'
    if os.path.islink(path):
        return False, 'is symlink — use plain unpublish'
    if os.path.isdir(path):
        return False, 'is directory — refusing rm -rf'
    try:
        os.unlink(path)
        return True, f'deleted (direct): {name}'
    except OSError as e:
        return False, str(e)


def unpublish_batch(names, include_direct=False):
    """symlink -> unlink; direct file -> delete only if include_direct; real
    directory -> refused (no rm -rf). Returns a per-item result list."""
    results = []
    seen = set()
    for name in names:
        if name in seen:
            continue
        seen.add(name)
        path = safe_resolve(name)
        if not path or not os.path.lexists(path):
            results.append({'name': name, 'ok': False, 'kind': 'missing', 'message': f'not found: {name}'})
            continue
        if os.path.islink(path):
            ok, msg = unpublish(name)
            results.append({'name': name, 'ok': ok, 'kind': 'symlink', 'message': msg})
        elif os.path.isdir(path):
            results.append({'name': name, 'ok': False, 'kind': 'dir', 'message': 'directory — refused'})
        elif include_direct:
            ok, msg = unpublish_direct(name, name)
            results.append({'name': name, 'ok': ok, 'kind': 'direct', 'message': msg})
        else:
            results.append({'name': name, 'ok': False, 'kind': 'direct-skipped', 'message': 'direct file skipped (include_direct=false)'})
    return results


# ---- broken-symlink repair / cleanup ----
def _wt_to_main_candidates(target):
    """If a broken target points inside a git worktree, propose the main-repo path."""
    candidates = []
    m = re.match(r'^(.*?)-wt/[^/]+/(.+)\Z', target)      # ~/x/repo-wt/<slug>/rest -> ~/x/repo/rest
    if m:
        candidates.append(f'{m.group(1)}/{m.group(2)}')
    m = re.match(r'^(.+?)/wt/[^/]+/(.+)\Z', target)       # ~/x/repo/wt/<slug>/rest -> ~/x/repo/rest
    if m:
        candidates.append(f'{m.group(1)}/{m.group(2)}')
    seen = set()
    return [c for c in candidates if c not in seen and not seen.add(c)]


def analyze_broken(name):
    path = safe_resolve(name)
    if not path or not os.path.islink(path):
        return None
    try:
        target = os.readlink(path)
    except OSError:
        return {'name': name, 'action': 'unlink', 'reason': 'broken readlink', 'old_target': None, 'new_target': None}
    if os.path.exists(target):
        return None
    expanded = target if target.startswith('/') else os.path.realpath(os.path.join(os.path.dirname(path), target))
    new_target = next((c for c in _wt_to_main_candidates(expanded) if os.path.exists(c)), None)
    return {
        'name': name,
        'action': 'repair' if new_target else 'unlink',
        'reason': 'worktree->main repair' if new_target else 'target not found in any repair candidate',
        'old_target': target,
        'new_target': new_target,
    }


def repair_or_cleanup_all():
    if not os.path.isdir(ROOT):
        return []
    results = []
    for name in sorted(os.listdir(ROOT)):
        if name.startswith('.'):
            continue
        full = os.path.join(ROOT, name)
        if not os.path.islink(full) or os.path.exists(full):
            continue
        info = analyze_broken(name)
        if not info:
            continue
        try:
            os.unlink(full)
            if info['action'] == 'repair' and info['new_target']:
                os.symlink(info['new_target'], full)
            results.append({**info, 'ok': True})
        except OSError as e:
            results.append({**info, 'ok': False, 'error': str(e)})
    return results


# ==== external publish: self-contained snapshot + ingest push (pluggable) ====

_RE_CSS = re.compile(r'<link\b[^>]*\brel=["\']?stylesheet["\']?[^>]*>', re.I)
_RE_HREF = re.compile(r'\bhref=["\']([^"\']+)["\']', re.I)
_RE_JS = re.compile(r'<script\b([^>]*)\bsrc=["\']([^"\']+)["\']([^>]*)>\s*</script>', re.I)
_RE_IMG = re.compile(r'(<img\b[^>]*\bsrc=)["\']([^"\']+)["\']', re.I)
_RE_TITLE = re.compile(r'<title>([^<]*)</title>', re.I)
_RE_SCHEME = re.compile(r'^[a-z]+:', re.I)


def _read_share_file(ref, base_dir):
    """Resolve a local asset ref to a real file UNDER ROOT and read its bytes.
    Root-relative (/x) is relative to the share dir; otherwise to the page's dir.
    Returns (bytes, None) or (None, reason). Refuses anything outside ROOT."""
    ref = ref.split('#', 1)[0].split('?', 1)[0]
    if not ref or _RE_SCHEME.match(ref) or ref.startswith('//'):
        return None, 'external'
    cand = os.path.join(ROOT, ref.lstrip('/')) if ref.startswith('/') else os.path.join(base_dir, ref)
    real = os.path.realpath(cand)
    if not (real == os.path.realpath(ROOT) or real.startswith(os.path.realpath(ROOT) + os.sep)):
        return None, 'outside share dir'
    try:
        with open(real, 'rb') as fh:
            return fh.read(), None
    except OSError as e:
        return None, str(e)


def _guess_ctype(path):
    ext = os.path.splitext(path)[1].lower()
    return {'.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
            '.gif': 'image/gif', '.svg': 'image/svg+xml', '.webp': 'image/webp'}.get(ext, 'image/png')


def bundle_single_file(name):
    """Inline a published HTML page's local css/js/img into ONE self-contained
    file (read from disk — gate-safe, no HTTP self-fetch). External refs stay.
    Returns (title, html_bytes)."""
    path = safe_resolve(name)
    if not path or not os.path.isfile(path):
        raise FileNotFoundError(name)
    base_dir = os.path.dirname(path)
    with open(path, 'r', encoding='utf-8', errors='replace') as fh:
        html = fh.read()

    def _css(m):
        hm = _RE_HREF.search(m.group(0))
        if not hm:
            return m.group(0)
        data, _err = _read_share_file(hm.group(1), base_dir)
        if data is None:
            return m.group(0)
        css = data.decode('utf-8', 'replace').replace('</style', '<\\/style')
        return '<style>\n' + css + '\n</style>'

    def _js(m):
        pre, ref, post = m.group(1), m.group(2), m.group(3)
        data, _err = _read_share_file(ref, base_dir)
        if data is None:
            return m.group(0)
        typ = ' type="module"' if 'module' in (pre + post) else ''
        js = data.decode('utf-8', 'replace').replace('</script', '<\\/script')
        return '<script' + typ + '>\n' + js + '\n</script>'

    def _img(m):
        pre, ref = m.group(1), m.group(2)
        data, _err = _read_share_file(ref, base_dir)
        if data is None:
            return m.group(0)
        b = os.path.join(base_dir, ref) if not ref.startswith('/') else os.path.join(ROOT, ref.lstrip('/'))
        return pre + '"data:' + _guess_ctype(b) + ';base64,' + base64.b64encode(data).decode('ascii') + '"'

    html = _RE_CSS.sub(_css, html)
    html = _RE_JS.sub(_js, html)
    html = _RE_IMG.sub(_img, html)
    tm = _RE_TITLE.search(html)
    return (tm.group(1).strip() if tm else name), html.encode('utf-8')


class BundleValidationError(RuntimeError):
    pass


def _first_href_span(start_tag):
    """Locate the browser-first href value without reserializing its tag."""
    size, i = len(start_tag), 1
    while i < size and start_tag[i].isspace():
        i += 1
    while i < size and not start_tag[i].isspace() and start_tag[i] not in '/>':
        i += 1
    while i < size:
        while i < size and start_tag[i].isspace():
            i += 1
        if i >= size or start_tag[i] == '>' or (start_tag[i] == '/' and i + 1 < size and start_tag[i + 1] == '>'):
            return None
        name_start = i
        while i < size and not start_tag[i].isspace() and start_tag[i] not in '=/>':
            i += 1
        if name_start == i:
            i += 1
            continue
        attr_name = start_tag[name_start:i].lower()
        while i < size and start_tag[i].isspace():
            i += 1
        if i >= size or start_tag[i] != '=':
            continue
        i += 1
        while i < size and start_tag[i].isspace():
            i += 1
        if i >= size:
            return None
        quote = start_tag[i] if start_tag[i] in ('"', "'") else ''
        value_start = i + 1 if quote else i
        value_end = start_tag.find(quote, value_start) if quote else value_start
        if quote and value_end < 0:
            return None
        if not quote:
            while value_end < size and not start_tag[value_end].isspace() and start_tag[value_end] != '>':
                if start_tag[value_end:value_end + 2] == '/>':
                    break
                value_end += 1
        i = value_end + 1 if quote else value_end
        if attr_name == 'href':
            return value_start, value_end, start_tag[value_start:value_end], quote
    return None


class _AnchorParser(HTMLParser):
    """Collect browser-active, first-href anchor positions without reformatting HTML."""

    def __init__(self, source):
        super().__init__(convert_charrefs=False)
        self.source = source
        self.line_starts = [0] + [match.end() for match in re.finditer(r'\n', source)]
        self.anchors = []
        self.inert = []

    def _anchor(self):
        span = _first_href_span(self.get_starttag_text())
        if span is None:
            return None
        line, column = self.getpos()
        start = self.line_starts[line - 1] + column
        value_start, value_end, ref, quote = span
        return {'start': start + value_start, 'end': start + value_end,
                'ref': ref, 'quote': quote}

    def _collect_anchor(self, tag):
        if self.inert or tag != 'a':
            return
        anchor = self._anchor()
        if anchor is not None:
            self.anchors.append(anchor)

    def handle_starttag(self, tag, _attrs):
        tag = tag.lower()
        if tag in ('script', 'style', 'template', 'noscript'):
            self.inert.append(tag)
            return
        self._collect_anchor(tag)

    def handle_startendtag(self, tag, _attrs):
        tag = tag.lower()
        if tag in ('script', 'style', 'template', 'noscript'):
            # HTML browsers ignore the slash on non-void elements, so inert content stays inert.
            self.inert.append(tag)
            return
        # Non-inert self-closing tags keep the existing anchor collection behavior.
        self._collect_anchor(tag)

    def handle_endtag(self, tag):
        tag = tag.lower()
        if self.inert and self.inert[-1] == tag:
            self.inert.pop()


def _bundle_target(ref, current):
    """Return (safe target, unsupported target) for a document anchor."""
    ref = html_unescape(ref or '')
    if not ref or ref.startswith('#') or _RE_SCHEME.match(ref) or ref.startswith('//'):
        return None, None
    path = urllib.parse.unquote(urllib.parse.urlsplit(
        urllib.parse.urljoin('/' + current, ref)).path).lstrip('/')
    if not path.lower().endswith(('.html', '.htm')):
        return None, None
    if safe_resolve(path):
        return path, None
    return None, path


def _bundle_anchors(html, current):
    parser = _AnchorParser(html)
    parser.feed(html)
    parser.close()
    targets, unsupported = [], []
    for anchor in parser.anchors:
        target, unsupported_target = _bundle_target(anchor['ref'], current)
        if target:
            targets.append(target)
        elif unsupported_target:
            unsupported.append(unsupported_target)
    return targets, list(dict.fromkeys(unsupported))


def _rewrite_bundle_anchors(html, current, link_map):
    """Rewrite selected internal document links and report selected-out links."""
    parser = _AnchorParser(html)
    parser.feed(html)
    parser.close()
    warnings, unsupported, replacements = [], [], []
    for anchor in parser.anchors:
        target, unsupported_target = _bundle_target(anchor['ref'], current)
        if unsupported_target:
            unsupported.append(unsupported_target)
            continue
        if not target:
            continue
        if target not in link_map:
            warnings.append(target)
            continue
        parsed = urllib.parse.urlsplit(html_unescape(anchor['ref']))
        suffix = (('?' + parsed.query) if parsed.query else '') + (('#' + parsed.fragment) if parsed.fragment else '')
        replacements.append((anchor['start'], anchor['end'], link_map[target] + suffix))

    for start, end, replacement in reversed(replacements):
        html = html[:start] + replacement + html[end:]
    return html, list(dict.fromkeys(warnings)), list(dict.fromkeys(unsupported))


def _register_bundle_plan(owner, entry, candidates):
    now = time.time()
    with _BUNDLE_PLANS_LOCK:
        for plan_id, record in list(_BUNDLE_PLANS.items()):
            if record['expires_at'] <= now:
                del _BUNDLE_PLANS[plan_id]
        while len(_BUNDLE_PLANS) >= MAX_BUNDLE_PLANS:
            oldest = min(_BUNDLE_PLANS, key=lambda key: _BUNDLE_PLANS[key]['expires_at'])
            del _BUNDLE_PLANS[oldest]
        plan_id = secrets.token_urlsafe(24)
        expires_at = int(now + BUNDLE_PLAN_TTL_S)
        _BUNDLE_PLANS[plan_id] = {'owner': owner, 'entry': entry,
                                  'candidates': candidates, 'expires_at': expires_at}
    return plan_id, expires_at


def _consume_bundle_plan(plan_id, owner, entry, docs):
    if not isinstance(plan_id, str) or not plan_id:
        return False, 'bundle plan missing'
    names = list(dict.fromkeys(docs))
    now = time.time()
    with _BUNDLE_PLANS_LOCK:
        record = _BUNDLE_PLANS.get(plan_id)
        if not record:
            return False, 'bundle plan missing or already used'
        if record['expires_at'] <= now:
            del _BUNDLE_PLANS[plan_id]
            return False, 'bundle plan expired'
        if record['owner'] != owner:
            return False, 'bundle plan owner mismatch'
        if record['entry'] != entry:
            return False, 'bundle plan entry mismatch'
        if entry not in names:
            return False, 'bundle plan must include its entry document'
        unknown = [name for name in names if name not in record['candidates']]
        if unknown:
            return False, 'bundle plan contains unapproved documents: ' + ', '.join(unknown)
        # Delete while holding the lock. A failed build still consumes approval.
        del _BUNDLE_PLANS[plan_id]
        return True, record


def plan_bundle(entry, max_docs=MAX_BUNDLE_DOCS, owner=''):
    """Read-only BFS proposal of locally linked HTML documents."""
    # Bundle planning is a local filesystem operation; remote ingest has no such contract.
    if PUBLIC_MODE != 'local':
        return False, 'bundle planning is available only in local mode'
    try:
        max_docs = int(max_docs or MAX_BUNDLE_DOCS)
    except (TypeError, ValueError):
        return False, 'max_docs must be an integer'
    max_docs = max(1, min(max_docs, MAX_BUNDLE_DOCS))
    if not entry.lower().endswith(('.html', '.htm')):
        return False, 'only HTML pages can be bundled'
    if not safe_resolve(entry) or not os.path.isfile(safe_resolve(entry)):
        return False, f'not found: {entry}'

    found, missing, failed, unsupported = [entry], [], [], []
    seen, queue, truncated = {entry}, [entry], False
    while queue:
        current = queue.pop(0)
        try:
            with open(safe_resolve(current), encoding='utf-8', errors='replace') as fh:
                targets, current_unsupported = _bundle_anchors(fh.read(), current)
        except OSError as exc:
            failed.append(f'{current} ({exc})')
            continue
        unsupported.extend(current_unsupported)
        for target in targets:
            if target in seen:
                continue
            seen.add(target)
            target_path = safe_resolve(target)
            if not target_path or not os.path.isfile(target_path):
                missing.append(target)
                continue
            if len(found) >= max_docs:
                truncated = True
                continue
            found.append(target)
            queue.append(target)
    try:
        _title, _files, _warnings, integrity = build_bundle_files(entry, found, include_integrity=True)
    except Exception as exc:
        return False, f'bundle plan build failed: {exc}'
    candidates = {name: {'digest': integrity[name]['digest']} for name in found}
    plan_id, expires = _register_bundle_plan(owner, entry, candidates)
    return True, {'plan_id': plan_id, 'plan_expires': expires, 'entry': entry,
                  'docs': [{'name': name, 'title': integrity[name]['title'],
                            'digest': integrity[name]['digest'],
                            'member': 'index.html' if name == entry else name,
                            'entry': name == entry} for name in found],
                  'count': len(found), 'missing': list(dict.fromkeys(missing)),
                  'fetch_failed': failed, 'truncated': truncated, 'max_docs': max_docs,
                  'unsupported': list(dict.fromkeys(unsupported)), 'warnings': _warnings}


def build_bundle_files(entry, docs, include_integrity=False):
    """Build approved documents into a slug-local files map from disk."""
    names = list(dict.fromkeys([entry] + [doc for doc in docs if doc != entry]))
    if len(names) > MAX_BUNDLE_DOCS:
        raise BundleValidationError(f'bundle document limit exceeded: {len(names)} > {MAX_BUNDLE_DOCS}')
    for name in names:
        if not isinstance(name, str) or not name.lower().endswith(('.html', '.htm')):
            raise BundleValidationError(f'not an HTML document: {name}')
        if not safe_resolve(name) or not os.path.isfile(safe_resolve(name)):
            raise BundleValidationError(f'not found: {name}')
    link_map = {name: ('./' if name == entry else name) for name in names}
    files, warnings, integrity, total = {}, [], {}, 0
    entry_title = entry
    for name in names:
        # Hash the exact artifact that is about to be written; a second read only creates a race.
        title, html_bytes = bundle_single_file(name)
        digest = hashlib.sha256(html_bytes).hexdigest()
        html, dangling, unsupported = _rewrite_bundle_anchors(
            html_bytes.decode('utf-8', 'replace'), name, link_map)
        data = html.encode('utf-8')
        member = 'index.html' if name == entry else name
        if member in files:
            raise BundleValidationError(
                f'bundle member name collides with the entry page: {member}')
        files[member] = data
        total += len(data)
        integrity[name] = {'title': title, 'digest': digest}
        warnings.extend(f'{name}: link outside bundle: {target}' for target in dangling)
        warnings.extend(f'{name}: unsupported subdirectory link: {target}' for target in unsupported)
        if name == entry:
            entry_title = title
    limit = LOCAL_MAX_BYTES if PUBLIC_MODE == 'local' else MAX_BUNDLE_TOTAL_BYTES
    if total > limit:
        raise BundleValidationError(f'bundle total size exceeds limit: {total} > {limit}')
    if include_integrity:
        return entry_title, files, warnings, integrity
    return entry_title, files, warnings


def _slugify(title, name):
    def s(x):
        return re.sub(r'[^a-z0-9]+', '-', (x or '').lower()).strip('-')[:32].strip('-')
    fbase = s(re.sub(r'\.html?\Z', '', name.lower()))
    tbase = s(title)
    base = fbase if len(fbase) >= 4 else (tbase if len(tbase) >= 4 else (fbase or tbase or 'doc'))
    return f'{base}-{secrets.token_hex(3)}'


def _ingest(method, ep, body=None, timeout=20):
    data = json.dumps(body).encode('utf-8') if body is not None else None
    req = urllib.request.Request(
        INGEST_URL + ep, data=data, method=method,
        headers={'Content-Type': 'application/json', 'X-Airlock-Publish-Token': TOKEN})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode('utf-8'))


# ---- local target: snapshots on disk, served by this box's nginx ----------
# State (owner identities, source names) lives OUTSIDE the served directory —
# nginx serves dotfiles, so a metadata file under public_dir would be readable.
_state_lock = threading.Lock()


class _FileLock:
    """Cross-PROCESS lock. The --cleanup sweep is a separate oneshot process, so
    an in-process lock alone would lose updates between publish and sweep."""

    def __init__(self, path):
        self.path, self.fh = path, None

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
        self.fh = open(self.path, 'a+')
        try:
            fcntl.flock(self.fh, fcntl.LOCK_EX)
        except Exception:
            self.fh.close()
            self.fh = None
            raise
        return self

    def __exit__(self, *_exc):
        try:
            fcntl.flock(self.fh, fcntl.LOCK_UN)
        finally:
            self.fh.close()


def _ttl_hours(v):
    try:
        h = int(v)
    except (TypeError, ValueError):
        return TTL_DEFAULT_H
    return max(TTL_MIN_H, min(TTL_MAX_H, h))


def _target_dir(mode):
    return GATED_DIR if mode == 'gated' else PUBLIC_DIR


def _slug_dir(slug, mode='open'):
    """Target/<slug> — only if the slug is well-formed AND resolves to a
    direct child of PUBLIC_DIR (blocks traversal and symlinked slug dirs)."""
    root = _target_dir(mode)
    if not slug or not _RE_SLUG.match(slug) or not root:
        return None
    p = os.path.join(root, slug)
    if os.path.dirname(os.path.realpath(p)) != os.path.realpath(root):
        return None
    return p


def _remove_slug_dir(slug, mode='open'):
    """Delete <slug>/ — files directly inside plus the directory. Never
    recursive: we only ever write index.html, so anything else is a surprise
    and should be left for a human to look at."""
    p = _slug_dir(slug, mode)
    if not p or os.path.islink(p) or not os.path.isdir(p):
        return False
    try:
        names = os.listdir(p)
    except OSError as e:
        sys.stderr.write(f'[airlock-publish] cannot inspect {p}: {e}\n')
        return False
    # Preflight before deleting anything. An unexpected nested directory must
    # leave the entire snapshot intact, especially before a mode transition.
    if any(not (os.path.isfile(os.path.join(p, name)) or os.path.islink(os.path.join(p, name)))
           for name in names):
        sys.stderr.write(f'[airlock-publish] refusing non-flat slug dir: {p}\n')
        return False
    for name in names:
        f = os.path.join(p, name)
        try:
            if os.path.isfile(f) or os.path.islink(f):
                os.unlink(f)
        except OSError as e:
            sys.stderr.write(f'[airlock-publish] unlink {f}: {e}\n')
    try:
        os.rmdir(p)
        return True
    except OSError as e:
        sys.stderr.write(f'[airlock-publish] rmdir {p}: {e}\n')
        return False


def _state_load():
    """Never raises. Corrupt state is moved aside rather than deleted — but see
    _reconcile(): starting from empty would otherwise orphan live public files
    forever (nginx keeps serving them, revoke/sweep refuse to touch them)."""
    try:
        with open(STATE_FILE, 'r', encoding='utf-8') as fh:
            d = json.load(fh)
        if isinstance(d, dict) and isinstance(d.get('items'), dict):
            return d
        raise ValueError('unexpected shape')
    except FileNotFoundError:
        pass
    except Exception as e:
        bad = f'{STATE_FILE}.corrupt-{int(time.time())}'
        try:
            os.replace(STATE_FILE, bad)
            sys.stderr.write(f'[airlock-publish] state unreadable ({e}) — moved to {bad}\n')
        except OSError:
            sys.stderr.write(f'[airlock-publish] state unreadable ({e}) and could not be moved\n')
    return {'version': 1, 'items': {}}


def _state_save(state):
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    tmp = f'{STATE_FILE}.tmp-{secrets.token_hex(4)}'
    try:
        with open(tmp, 'w', encoding='utf-8') as fh:
            json.dump(state, fh, ensure_ascii=False, indent=1)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, STATE_FILE)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _transaction_artifacts(root):
    artifacts = {}
    if not root:
        return artifacts
    try:
        names = os.listdir(root)
    except OSError:
        return artifacts
    for name in names:
        match = _RE_TRANSACTION.fullmatch(name)
        if not match:
            continue
        path = os.path.join(root, name)
        if not os.path.lexists(path):
            continue
        artifacts.setdefault(match.group('slug'), []).append((match.group('kind'), path))
    return artifacts


def _remove_transaction_artifact(kind, path):
    try:
        if os.path.islink(path) or not os.path.isdir(path):
            os.unlink(path)
        else:
            shutil.rmtree(path)
        sys.stderr.write(f'[airlock-publish] removed transaction {kind} {path}\n')
        return True
    except OSError as exc:
        sys.stderr.write(f'[airlock-publish] cannot remove transaction {kind} {path}: {exc}\n')
        return False


def _reconcile(state, now):
    """Converge disk <-> state, both directions.
    - a slug dir with no entry is ADOPTED with a short grace expiry (owner None
      => listed to nobody, but swept) so orphaned public content dies in a day
      instead of living forever;
    - an entry whose dir is gone is dropped."""
    items = state['items']
    # An untracked gated directory is adopted for safe expiry, but it must not
    # retain an auth file after state loss: otherwise the old password lives on.
    known_gated_before = {slug for slug, item in items.items()
                          if item.get('mode', 'open') == 'gated'}
    for mode, root in (('open', PUBLIC_DIR), ('gated', GATED_DIR)):
        artifacts = _transaction_artifacts(root)
        for slug, entries in artifacts.items():
            live = os.path.join(root, slug)
            old_dirs = [path for kind, path in entries
                        if kind == 'old' and not os.path.islink(path) and os.path.isdir(path)]
            # A backup that gets renamed back into place is gone from its old name;
            # trying to delete it afterwards would log a failure for something that
            # actually succeeded, and a log that cries wolf stops being read.
            consumed = None
            if not os.path.lexists(live) and old_dirs:
                # The newest renamed backup is closest to the interrupted replacement.
                chosen = max(old_dirs, key=lambda path: (os.stat(path).st_ctime_ns, path))
                try:
                    os.replace(chosen, live)
                    consumed = chosen
                    sys.stderr.write(f'[airlock-publish] recovered {live} from transaction backup {chosen}\n')
                except OSError as exc:
                    sys.stderr.write(f'[airlock-publish] cannot recover {live} from {chosen}: {exc}\n')
            for kind, path in entries:
                if path == consumed:
                    continue
                if kind == 'old' and not os.path.lexists(live):
                    continue
                _remove_transaction_artifact(kind, path)
        try:
            on_disk = {n for n in os.listdir(root)
                       if _RE_SLUG.match(n) and os.path.isdir(os.path.join(root, n))}
        except OSError:
            on_disk = set()
        known = {slug for slug, it in items.items() if it.get('mode', 'open') == mode}
        for slug in on_disk - known:
            if slug not in items:
                items[slug] = {'owner': None, 'src': None, 'title': slug,
                               'expiry': now + RECONCILE_GRACE, 'created': now,
                               'bytes': 0, 'mode': mode}
                sys.stderr.write(f'[airlock-publish] adopted untracked {mode} dir {slug} (expires in 24h)\n')
        for slug in known - on_disk:
            if mode == 'gated':
                # A manually removed gated directory must not strand a valid
                # credential that can no longer be reached through state APIs.
                try:
                    _update_htpasswd(slug, None)
                except Exception as exc:
                    # A missing/unwritable optional gate must not block open reconciliation;
                    # retain this item so a later sweep can retry credential cleanup.
                    sys.stderr.write(f'[airlock-publish] cannot remove credential for {slug}: {exc}\n')
                    continue
            items.pop(slug, None)
    try:
        auth_files = os.listdir(HTPASSWD_DIR)
    except OSError:
        auth_files = []
    for name in auth_files:
        if not name.endswith('.htpasswd'):
            continue
        slug = name[:-len('.htpasswd')]
        item = items.get(slug)
        if (not _RE_SLUG.match(slug) or slug not in known_gated_before or not item
                or item.get('mode', 'open') != 'gated'):
            path = os.path.join(HTPASSWD_DIR, name)
            try:
                os.unlink(path)
            except OSError as exc:
                sys.stderr.write(f'[airlock-publish] unlink orphan credential {path}: {exc}\n')
    return state


def _sweep(state, now):
    gone = []
    for slug, item in list(state['items'].items()):
        if (item.get('expiry') or 0) > now:
            continue
        mode = item.get('mode', 'open')
        if not _remove_slug_dir(slug, mode):
            # Keep state for a later filesystem cleanup retry, but expiry must
            # still revoke access to a gated page even when its directory is
            # unexpectedly non-flat and cannot be safely removed.
            if mode == 'gated':
                try:
                    _update_htpasswd(slug, None)
                except Exception as exc:
                    sys.stderr.write(f'[airlock-publish] cannot remove credential for {slug}: {exc}\n')
            continue
        if mode == 'gated':
            try:
                _update_htpasswd(slug, None)
            except Exception as exc:
                # Keep state when credential cleanup fails so the next sweep retries it.
                sys.stderr.write(f'[airlock-publish] cannot remove credential for {slug}: {exc}\n')
                continue
        state['items'].pop(slug, None)
        gone.append(slug)
    return gone


def _mint_slug(state, base):
    stem = re.sub(r'-[0-9a-f]{6}\Z', '', base or '') or 'doc'
    for _ in range(50):
        cand = f'{stem}-{secrets.token_hex(3)}'
        if (cand not in state['items'] and not os.path.exists(os.path.join(PUBLIC_DIR, cand))
                and not os.path.exists(os.path.join(GATED_DIR, cand))):
            return cand
    return f'doc-{secrets.token_hex(6)}'


def _files_valid(files):
    if not isinstance(files, dict) or not files:
        return False
    return all(isinstance(name, str) and name and '/' not in name and '\\' not in name
               and name != '.' and not name.startswith('.') and isinstance(data, bytes)
               for name, data in files.items())


def _htpasswd_hash(slug, password):
    """Ask htpasswd for bcrypt via stdin, so the password is not in argv."""
    try:
        result = subprocess.run([HTPASSWD_BIN, '-niB', slug], input=password + '\n',
                                text=True, capture_output=True, check=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as exc:
        raise BundleValidationError(f'cannot hash gated password: {exc}') from exc
    line = result.stdout.strip()
    if not line.startswith(slug + ':'):
        raise BundleValidationError('htpasswd returned an invalid record')
    return line


def _htpasswd_path(slug):
    if not slug or not _RE_SLUG.match(slug):
        return None
    path = os.path.join(HTPASSWD_DIR, slug + '.htpasswd')
    return path if os.path.dirname(os.path.realpath(path)) == os.path.realpath(HTPASSWD_DIR) else None


def _update_htpasswd(slug, password=None):
    """Atomically write one credential file per slug, or remove it."""
    path = _htpasswd_path(slug)
    if not path:
        raise BundleValidationError(f'invalid slug: {slug}')
    if password is None:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        return
    os.makedirs(HTPASSWD_DIR, mode=0o755, exist_ok=True)
    os.chmod(HTPASSWD_DIR, 0o755)
    tmp = f'{path}.tmp-{secrets.token_hex(4)}'
    # This is intentionally world-readable: local users can already read the
    # 0755 gated webroot, while nginx workers must read this bcrypt hash per request.
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        fh.write(_htpasswd_hash(slug, password) + '\n')
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def _local_ingest(slug, owner, src, title, ttl_hours, files, mode='open', password=''):
    if not _files_valid(files):
        return {'ok': False, 'error': 'invalid bundle files'}
    total_bytes = sum(len(data) for data in files.values())
    if total_bytes > LOCAL_MAX_BYTES:
        return {'ok': False, 'error': f'snapshot too large (>{LOCAL_MAX_BYTES // (1024 * 1024)}MB)'}
    if mode not in ('open', 'gated'):
        return {'ok': False, 'error': 'mode must be open or gated'}
    if mode == 'gated' and not GATED_ENABLED:
        return {'ok': False, 'error': 'gated publish unavailable: ' + (GATED_DISABLED_REASON or 'htpasswd unavailable')}
    ttl = _ttl_hours(ttl_hours)
    now = int(time.time())

    def _flat_dir(path):
        if not path or os.path.islink(path) or not os.path.isdir(path):
            return False
        try:
            return all(os.path.isfile(os.path.join(path, name)) or
                       os.path.islink(os.path.join(path, name))
                       for name in os.listdir(path))
        except OSError:
            return False

    def _remove_flat_dir(path):
        if not path or not os.path.lexists(path):
            return True
        if not _flat_dir(path):
            return False
        try:
            for name in os.listdir(path):
                os.unlink(os.path.join(path, name))
            os.rmdir(path)
            return True
        except OSError:
            return False

    def _restore_auth(path, data, mode_bits):
        if data is None:
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass
            return
        os.makedirs(os.path.dirname(path), mode=0o755, exist_ok=True)
        tmp = f'{path}.rollback-{secrets.token_hex(4)}'
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode_bits)
        try:
            os.replace(tmp, path)
        except OSError:
            # Keep rollback usable when the injected failure targets os.replace itself.
            os.rename(tmp, path)

    def _restore_dir(source, target):
        try:
            os.replace(source, target)
        except OSError:
            # The fallback is still an atomic same-filesystem rename, but avoids a
            # one-shot os.replace failure masking the prior live snapshot.
            os.rename(source, target)

    with _state_lock, _FileLock(LOCK_FILE):
        state = _reconcile(_state_load(), now)
        _sweep(state, now)
        if PUBLIC_MODE == 'local':
            # Local slug reuse must share this lock with the subsequent write.
            reusable = sorted(s for s, item in state['items'].items()
                              if item.get('owner') == owner and item.get('src') == src)
            if reusable:
                slug = reusable[0]
        cur = state['items'].get(slug)
        # Never write over someone else's slug (or an unexpected dir) — mint one.
        if (cur and cur.get('owner') != owner) or (not cur and (
                os.path.exists(os.path.join(PUBLIC_DIR, slug)) or
                os.path.exists(os.path.join(GATED_DIR, slug)))):
            slug = _mint_slug(state, slug)
            cur = None
        d = _slug_dir(slug, mode)
        if not d:
            return {'ok': False, 'error': f'invalid slug: {slug}'}
        expiry = now + ttl * 3600
        old_mode = (cur or {}).get('mode', 'open')
        if mode == 'gated':
            storage_problem = _gated_storage_check()
            if storage_problem:
                return {'ok': False, 'error': 'gated publish unavailable: ' + storage_problem}

        old_dir = _slug_dir(slug, old_mode) if cur else None
        if cur and not _flat_dir(old_dir):
            # Preserve the existing fail-closed behavior for unexpected nested content.
            return {'ok': False, 'error': 'cannot remove prior mode snapshot; refusing mode transition'}
        if old_dir != d and os.path.lexists(d):
            return {'ok': False, 'error': 'target slug already exists in the requested mode'}

        auth_path = _htpasswd_path(slug)
        old_auth = None
        old_auth_mode = 0o644
        if auth_path:
            try:
                with open(auth_path, 'rb') as fh:
                    old_auth = fh.read()
                old_auth_mode = os.stat(auth_path).st_mode & 0o777
            except FileNotFoundError:
                pass
            except OSError as exc:
                return {'ok': False, 'error': f'cannot read prior credential: {exc}'}

        # Prefix artifacts with the slug so reconcile can identify their transaction.
        stage = f'{d}.stage-{secrets.token_hex(8)}'
        try:
            os.makedirs(_target_dir(mode), mode=0o755, exist_ok=True)
            os.mkdir(stage, 0o755)
            os.chmod(stage, 0o755)
            # Build every member beside the live directory so a partial bundle is never served.
            for member, data in files.items():
                tmp = os.path.join(stage, f'.tmp-{secrets.token_hex(4)}')
                with open(tmp, 'wb') as fh:
                    fh.write(data)
                    fh.flush()
                    os.fsync(fh.fileno())
                os.chmod(tmp, 0o644)
                os.replace(tmp, os.path.join(stage, member))
        except Exception as exc:
            _remove_flat_dir(stage)
            return {'ok': False, 'error': f'cannot stage snapshot: {exc}'}

        backup = None
        installed = False
        previous_item = dict(state['items'][slug]) if slug in state['items'] else None
        state_save_attempted = False

        def rollback():
            errors = []
            if installed and os.path.lexists(d):
                failed = None
                if not _remove_flat_dir(d):
                    failed = f'{d}.failed-{secrets.token_hex(4)}'
                    try:
                        os.replace(d, failed)
                    except OSError:
                        try:
                            os.rename(d, failed)
                        except OSError as exc:
                            errors.append(f'cannot hide failed snapshot {d}: {exc}')
                            failed = None
                    if failed and not _remove_flat_dir(failed):
                        errors.append(f'cannot remove failed snapshot {failed}')
            if backup and not os.path.lexists(old_dir):
                try:
                    _restore_dir(backup, old_dir)
                except OSError as exc:
                    errors.append(f'cannot restore prior snapshot {old_dir}: {exc}')
            if os.path.lexists(stage) and not _remove_flat_dir(stage):
                errors.append(f'cannot remove staging directory {stage}')
            if auth_path:
                try:
                    _restore_auth(auth_path, old_auth, old_auth_mode)
                except Exception as exc:
                    errors.append(f'cannot restore prior credential {auth_path}: {exc}')
            return errors

        def rollback_state():
            if previous_item is None:
                state['items'].pop(slug, None)
            else:
                state['items'][slug] = previous_item
            if not state_save_attempted:
                return []
            try:
                _state_save(state)
            except Exception as exc:
                return [f'cannot restore publish state: {exc}']
            return []

        try:
            state['items'][slug] = {'owner': owner, 'src': src, 'title': title, 'expiry': expiry,
                                    'created': (cur or {}).get('created', now), 'bytes': total_bytes,
                                    'mode': mode}
            state_save_attempted = True
            # Persist state before content so a crash cannot leave an untracked public snapshot.
            _state_save(state)
        except Exception as exc:
            rollback_errors = rollback() + rollback_state()
            error = f'cannot save publish state: {exc}'
            if rollback_errors:
                error += '; rollback incomplete: ' + '; '.join(rollback_errors)
            return {'ok': False, 'error': error}

        try:
            if mode == 'gated':
                # Between invalidation and the new hash, either snapshot may exist but neither is readable.
                _update_htpasswd(slug, None)
            # Rename the old directory out of the way only after the complete stage succeeded.
            if old_dir:
                backup = f'{old_dir}.old-{secrets.token_hex(4)}'
                os.replace(old_dir, backup)
            os.replace(stage, d)
            installed = True
            if mode == 'gated':
                _update_htpasswd(slug, password)
            elif old_mode == 'gated':
                _update_htpasswd(slug, None)
        except Exception as exc:
            rollback_errors = rollback() + rollback_state()
            error = f'cannot commit snapshot: {exc}'
            if rollback_errors:
                error += '; rollback incomplete: ' + '; '.join(rollback_errors)
            return {'ok': False, 'error': error}

        if backup and not _remove_flat_dir(backup):
            try:
                # This path is a transaction directory created by this call, not user content.
                shutil.rmtree(backup)
            except OSError as exc:
                sys.stderr.write(f'[airlock-publish] cannot remove prior snapshot backup {backup}: {exc}\n')
    return {'ok': True, 'result': {'slug': slug, 'expiry': expiry, 'ttl_hours': ttl}}


def _local_sweep_only():
    """Timer entry — expire public snapshots without a page visit."""
    # Gated storage is optional; its absence must not disable open TTL cleanup.
    if not (PUBLIC_MODE == 'local' and PUBLIC_DIR and os.path.isdir(PUBLIC_DIR)):
        return []
    now = int(time.time())
    with _state_lock, _FileLock(LOCK_FILE):
        state = _reconcile(_state_load(), now)
        gone = _sweep(state, now)
        _state_save(state)
    return gone


def _local_refresh(now):
    state = _reconcile(_state_load(), now)
    _sweep(state, now)
    _state_save(state)
    return state


def _local_list(owner):
    now = int(time.time())
    with _state_lock, _FileLock(LOCK_FILE):
        state = _local_refresh(now)
        items = [{'slug': s, 'owner': it['owner'], 'src': it['src'], 'title': it['title'],
                  'expiry': it['expiry'], 'expired': it['expiry'] <= now,
                  'mode': it.get('mode', 'open')}
                 for s, it in sorted(state['items'].items()) if it.get('owner') == owner]
    return {'ok': True, 'items': items}


def _local_mutate(slug, owner, fn):
    """Owner-scoped read-modify-write. A foreign or unknown slug is 'not found'
    — the same answer either way, so it cannot be used to probe."""
    now = int(time.time())
    with _state_lock, _FileLock(LOCK_FILE):
        state = _local_refresh(now)
        it = state['items'].get(slug)
        if not it or it.get('owner') != owner:
            return {'ok': False, 'error': 'not found'}
        res = fn(state, slug, it, now)
        _state_save(state)
    return res


def _local_revoke(slug, owner):
    def _do(state, s, _it, _now):
        if not _remove_slug_dir(s, _it.get('mode', 'open')):
            if _it.get('mode', 'open') == 'gated':
                _update_htpasswd(s, None)
            return {'ok': False, 'error': 'cannot remove snapshot directory'}
        if _it.get('mode', 'open') == 'gated':
            _update_htpasswd(s, None)
        state['items'].pop(s, None)
        return {'ok': True, 'slug': s}
    return _local_mutate(slug, owner, _do)


def _local_set_expiry(slug, owner, ttl_hours):
    def _do(_state, s, it, now):
        it['expiry'] = now + _ttl_hours(ttl_hours) * 3600
        return {'ok': True, 'slug': s, 'expiry': it['expiry']}
    return _local_mutate(slug, owner, _do)


def publish_public(name, ttl_hours, owner, mode='open', password='', docs=None, plan_id=''):
    if not PUBLIC_ENABLED:
        return False, 'external publish not configured ([apps.publish.public_target])'
    if PUBLIC_MODE == 'local' and not owner:
        return False, 'identity header missing — refusing to publish without an owner'
    if mode not in ('open', 'gated'):
        return False, 'mode must be open or gated'
    if PUBLIC_MODE != 'local' and docs is not None:
        # Remote ingest accepts one html_b64 snapshot, not the local bundle files map.
        return False, 'bundle publishing is available only in local mode'
    if PUBLIC_MODE != 'local' and mode == 'gated':
        # Never turn an explicit password request into an unauthenticated open URL.
        return False, 'gated publishing is available only in local mode'
    # Validate the credential before reading or writing any source/public data.
    if mode == 'gated' and (not isinstance(password, str) or not password):
        return False, 'gated publish requires a password'
    # A control character would be silently truncated: htpasswd reads one line from stdin,
    # so "abc\ndef" would store the credential "abc" while the person who typed it believes
    # the password is longer. Refuse instead of weakening it behind their back. htpasswd
    # also caps bcrypt input at 72 bytes and would quietly ignore the rest.
    if mode == 'gated':
        if any(ord(ch) < 0x20 or ord(ch) == 0x7f for ch in password):
            return False, 'password must not contain control characters or line breaks'
        if len(password.encode('utf-8')) > 72:
            return False, 'password must be at most 72 bytes (the bcrypt limit)'
    if docs is not None and (not isinstance(docs, list) or any(not isinstance(doc, str) or not doc for doc in docs)):
        return False, 'docs must be a list of document names'
    path = safe_resolve(name)
    if not path or not os.path.lexists(path):
        return False, f'not found: {name}'
    if not name.lower().endswith(('.html', '.htm')):
        return False, 'only HTML pages can be published externally'
    warnings = []
    if docs:
        plan_ok, plan = _consume_bundle_plan(plan_id, owner, name, docs)
        if not plan_ok:
            return False, plan
        try:
            title, files, warnings, current = build_bundle_files(name, docs, include_integrity=True)
        except Exception as e:
            return False, f'bundle failed: {e}'
        changed = [doc for doc in dict.fromkeys(docs)
                   if plan['candidates'][doc]['digest'] != current[doc]['digest']]
        if changed:
            return False, 'source changed after bundle plan: ' + ', '.join(changed)
        html_bytes = None
    else:
        try:
            title, html_bytes = bundle_single_file(name)
            files = {'index.html': html_bytes}
        except Exception as e:
            return False, f'bundle failed: {e}'
    slug = _slugify(title, name)
    if PUBLIC_MODE != 'local':
        # Remote ingest owns the remote slug contract; local reuse happens inside _local_ingest's lock.
        existing = public_list(owner)
        if existing.get('ok'):
            items = existing.get('items', [])
            reused = next((it['slug'] for it in items
                           if it.get('src') == name and not it.get('expired')), None)
            if not reused:
                reused = next((it['slug'] for it in items if it.get('src') == name), None)
            if reused:
                slug = reused
    if PUBLIC_MODE == 'local':
        try:
            res = _local_ingest(slug, owner, name, title, ttl_hours, files, mode, password)
        except Exception as e:
            return False, f'local ingest failed: {e}'
    else:
        try:
            payload = {
                'slug': slug, 'owner': owner or 'unknown', 'src': name, 'title': title,
                'ttl_hours': ttl_hours,
            }
            if docs:
                payload['files'] = {member: base64.b64encode(data).decode('ascii') for member, data in files.items()}
            else:
                payload['html_b64'] = base64.b64encode(html_bytes).decode('ascii')
            if mode == 'gated':
                payload.update({'mode': 'gated', 'gate': {'type': 'password', 'password': password}})
            res = _ingest('POST', '/ingest', payload)
        except Exception as e:
            return False, f'ingest failed: {e}'
    if not isinstance(res, dict):
        return False, 'ingest returned an invalid response'
    if not res.get('ok'):
        return False, res.get('error', 'ingest error')
    r = res.get('result', {})
    if not isinstance(r, dict) or 'expiry' not in r:
        return False, 'ingest returned an invalid result'
    slug = r.get('slug', slug)      # the local target may mint a fresh slug
    prefix = '/g' if mode == 'gated' and PUBLIC_MODE == 'local' else ''
    return True, {'url': f'{BASE_URL}{prefix}/{slug}/', 'slug': slug, 'expiry': r.get('expiry'),
                  'ttl_hours': r.get('ttl_hours'), 'mode': mode,
                  'bundle': sorted(files) if docs else None, 'warnings': warnings}


def _local_guard(owner):
    """Local mode has no second service to scope by token, so the hub identity
    IS the boundary. An empty owner means the request did not pass the gate."""
    if not PUBLIC_ENABLED:
        return {'ok': False, 'error': 'external publish not configured'}
    if PUBLIC_MODE == 'local' and not owner:
        return {'ok': False, 'error': 'identity header missing'}
    return None


def public_list(owner):
    bad = _local_guard(owner)
    if bad:
        return bad
    if PUBLIC_MODE == 'local':
        d = _local_list(owner)
    else:
        ep = '/list' + (('?owner=' + urllib.parse.quote(owner)) if owner else '')
        try:
            d = _ingest('GET', ep, timeout=12)
        except Exception as e:
            return {'ok': False, 'error': str(e)}
    if not isinstance(d, dict):
        return {'ok': False, 'error': 'ingest returned an invalid response'}
    items = d.get('items', [])
    if (not isinstance(items, list) or
            any(not isinstance(it, dict) or not isinstance(it.get('slug'), str) for it in items)):
        return {'ok': False, 'error': 'ingest returned an invalid item list'}
    for it in items:
        prefix = '/g' if PUBLIC_MODE == 'local' and it.get('mode', 'open') == 'gated' else ''
        it['url'] = f'{BASE_URL}{prefix}/{it["slug"]}/'
    return d


def public_revoke(slug, owner):
    bad = _local_guard(owner)
    if bad:
        return bad
    if PUBLIC_MODE == 'local':
        return _local_revoke(slug, owner)
    try:
        return _ingest('POST', '/revoke', {'slug': slug, 'owner': owner}, timeout=12)
    except Exception as e:
        return {'ok': False, 'error': str(e)}


def public_set_expiry(slug, owner, ttl_hours):
    bad = _local_guard(owner)
    if bad:
        return bad
    if PUBLIC_MODE == 'local':
        return _local_set_expiry(slug, owner, ttl_hours)
    try:
        return _ingest('POST', '/set-expiry', {'slug': slug, 'owner': owner, 'ttl_hours': ttl_hours}, timeout=12)
    except Exception as e:
        return {'ok': False, 'error': str(e)}


# ==== uploads — clipboard image / arbitrary file drop into ~/uploads ====
_RE_UPLOAD = re.compile(r'^image([0-9]{3,})-[0-9]{8}-[0-9]{6}\.jpg\Z')   # only auto-named files (protect manual ones)
UPLOAD_TTL_SEC = 24 * 3600
UPLOAD_MAX_BYTES = 12 * 1024 * 1024
FILE_MAX_BYTES = 50 * 1024 * 1024
_RE_FILE_SAFE = re.compile(r'[^0-9A-Za-z._ \-()]+')            # filename allowlist (blocks traversal/control chars)
_upload_lock = threading.Lock()


def cleanup_old_uploads():
    if not os.path.isdir(UPLOADS):
        return 0
    cutoff = time.time() - UPLOAD_TTL_SEC
    removed = 0
    for name in os.listdir(UPLOADS):
        full = os.path.join(UPLOADS, name)
        try:
            if os.path.isfile(full) and not os.path.islink(full) and os.path.getmtime(full) < cutoff:
                os.unlink(full)
                removed += 1
        except OSError:
            pass
    return removed


def _next_upload_seq():
    mx = 0
    if os.path.isdir(UPLOADS):
        for name in os.listdir(UPLOADS):
            m = _RE_UPLOAD.match(name)
            if m and os.path.isfile(os.path.join(UPLOADS, name)):
                mx = max(mx, int(m.group(1)))
    return mx + 1


def save_uploaded_image(image_b64):
    """base64 JPEG -> ~/uploads/imageNNN-<ts>.jpg. Server-generated name (no traversal)."""
    if not image_b64 or not isinstance(image_b64, str):
        return False, 'no image'
    if image_b64.startswith('data:'):
        comma = image_b64.find(',')
        if comma != -1:
            image_b64 = image_b64[comma + 1:]
    try:
        raw = base64.b64decode(image_b64, validate=True)
    except Exception:
        return False, 'invalid base64'
    if not raw:
        return False, 'empty image'
    if len(raw) > UPLOAD_MAX_BYTES:
        return False, f'image too large (>{UPLOAD_MAX_BYTES // (1024 * 1024)}MB)'
    if raw[:3] != b'\xff\xd8\xff':
        return False, 'not a jpeg'
    with _upload_lock:
        cleanup_old_uploads()
        os.makedirs(UPLOADS, exist_ok=True)
        ts = datetime.now().strftime('%Y%m%d-%H%M%S')
        n = _next_upload_seq()
        for _ in range(100):
            fname = f'image{n:03d}-{ts}.jpg'
            fpath = os.path.join(UPLOADS, fname)
            try:
                fd = os.open(fpath, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            except FileExistsError:
                n += 1
                continue
            with os.fdopen(fd, 'wb') as f:
                f.write(raw)
            return True, {'name': fname, 'path': f'~/uploads/{fname}', 'n': n, 'bytes': len(raw)}
    return False, 'sequence exhausted'


def _safe_upload_name(name):
    base = os.path.basename(str(name or '').replace('\\', '/')).strip()
    base = _RE_FILE_SAFE.sub('_', base).lstrip('.').strip() or 'file'
    return base[:120]


def save_uploaded_file(filename, data_b64):
    """base64 arbitrary file -> ~/uploads/<name>. Kept (not auto-deleted by the
    imageNNN rule) but still swept by the 24h TTL cleanup."""
    if not data_b64 or not isinstance(data_b64, str):
        return False, 'no data'
    if data_b64.startswith('data:'):
        comma = data_b64.find(',')
        if comma != -1:
            data_b64 = data_b64[comma + 1:]
    try:
        raw = base64.b64decode(data_b64, validate=True)
    except Exception:
        return False, 'invalid base64'
    if not raw:
        return False, 'empty file'
    if len(raw) > FILE_MAX_BYTES:
        return False, f'file too large (>{FILE_MAX_BYTES // (1024 * 1024)}MB)'
    safe = _safe_upload_name(filename)
    with _upload_lock:
        cleanup_old_uploads()
        os.makedirs(UPLOADS, exist_ok=True)
        stem, ext = os.path.splitext(safe)
        for i in range(1000):
            cand = safe if i == 0 else f'{stem}-{i + 1}{ext}'
            fpath = os.path.join(UPLOADS, cand)
            try:
                fd = os.open(fpath, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            except FileExistsError:
                continue
            with os.fdopen(fd, 'wb') as f:
                f.write(raw)
            return True, {'name': cand, 'path': f'~/uploads/{cand}', 'bytes': len(raw)}
    return False, 'name collision exhausted'


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
        for prefix in ('/publish/', '/publish'):
            if path.startswith(prefix):
                path = path[len(prefix):]
                return path if path.startswith('/') else '/' + path
        return path

    def _owner(self):
        return self.headers.get(IDENTITY_HEADER, '')

    def do_GET(self):
        path = self._strip(urllib.parse.urlparse(self.path).path)
        if path in ('/api/list', '/list'):
            self._json(200, {'ok': True, 'items': list_items(), 'root': ROOT, 'public_enabled': PUBLIC_ENABLED,
                             'public_mode': PUBLIC_MODE, 'gated_enabled': GATED_ENABLED,
                             'gated_disabled_reason': GATED_DISABLED_REASON})
            return
        if path in ('/api/health', '/health', '/'):
            self._json(200, {'ok': True, 'service': 'airlock-publish', 'port': PORT, 'public_enabled': PUBLIC_ENABLED,
                             'public_mode': PUBLIC_MODE, 'gated_enabled': GATED_ENABLED,
                             'gated_disabled_reason': GATED_DISABLED_REASON})
            return
        if path in ('/api/public-list', '/public-list'):
            self._json(200, public_list(self._owner()))
            return
        if path in ('/api/uploads-cleanup', '/uploads-cleanup'):
            self._json(200, {'ok': True, 'removed': cleanup_old_uploads()})
            return
        self._json(404, {'ok': False, 'error': f'unknown path: {path}'})

    def do_POST(self):
        path = self._strip(urllib.parse.urlparse(self.path).path)
        body = self._read_body()
        if path in ('/api/unpublish', '/unpublish'):
            ok, msg = unpublish(body.get('name', ''))
            self._json(200 if ok else 400, {'ok': ok, 'name': body.get('name', ''), 'message': msg})
            return
        if path in ('/api/unpublish-direct', '/unpublish-direct'):
            ok, msg = unpublish_direct(body.get('name', ''), body.get('confirm_name', ''))
            self._json(200 if ok else 400, {'ok': ok, 'name': body.get('name', ''), 'message': msg})
            return
        if path in ('/api/unpublish-batch', '/unpublish-batch'):
            names = body.get('names', [])
            results = unpublish_batch(names if isinstance(names, list) else [], bool(body.get('include_direct', False)))
            self._json(200, {'ok': True, 'count': len(results), 'ok_count': sum(1 for r in results if r.get('ok')), 'results': results})
            return
        if path in ('/api/repair-broken', '/repair-broken'):
            results = repair_or_cleanup_all()
            self._json(200, {'ok': True, 'count': len(results), 'results': results})
            return
        if path in ('/api/publish-public', '/publish-public'):
            ok, res = publish_public(body.get('name', ''), body.get('ttl_hours'), self._owner(),
                                     body.get('mode', 'open'), body.get('password', ''),
                                     body.get('docs'), body.get('plan_id', ''))
            self._json(200 if ok else 400, {'ok': ok, 'result': res} if ok else {'ok': ok, 'error': res})
            return
        if path in ('/api/publish-plan', '/publish-plan'):
            if PUBLIC_MODE != 'local':
                self._json(400, {'ok': False, 'error': 'bundle planning is available only in local mode'})
                return
            owner = self._owner()
            if PUBLIC_MODE == 'local' and not owner:
                self._json(400, {'ok': False, 'error': 'identity header missing'})
                return
            ok, res = plan_bundle(body.get('entry', body.get('name', '')), body.get('max_docs'), owner)
            self._json(200 if ok else 400, {'ok': ok, 'result': res} if ok else {'ok': ok, 'error': res})
            return
        if path in ('/api/public-revoke', '/public-revoke'):
            self._json(200, public_revoke(body.get('slug', ''), self._owner()))
            return
        if path in ('/api/public-set-expiry', '/public-set-expiry'):
            self._json(200, public_set_expiry(body.get('slug', ''), self._owner(), body.get('ttl_hours')))
            return
        if path in ('/api/upload-image', '/upload-image'):
            ok, res = save_uploaded_image(body.get('image', ''))
            self._json(200 if ok else 400, {'ok': ok, **res} if ok else {'ok': ok, 'error': res})
            return
        if path in ('/api/upload-file', '/upload-file'):
            ok, res = save_uploaded_file(body.get('name', ''), body.get('data', ''))
            self._json(200 if ok else 400, {'ok': ok, **res} if ok else {'ok': ok, 'error': res})
            return
        self._json(404, {'ok': False, 'error': f'unknown path: {path}'})

    def log_message(self, fmt, *args):
        sys.stderr.write(f'[airlock-publish] {self.address_string()} - {fmt % args}\n')


def main():
    if '--cleanup' in sys.argv:                    # systemd timer entry — TTL sweep without a page visit
        expired = _local_sweep_only()
        print(f'[airlock-publish] cleanup removed {cleanup_old_uploads()} upload(s), '
              f'{len(expired)} expired public snapshot(s)', flush=True)
        return
    if PUBLIC_DISABLED_REASON:
        sys.stderr.write(f'[airlock-publish] external publish DISABLED — {PUBLIC_DISABLED_REASON}\n')
    where = PUBLIC_DIR if PUBLIC_MODE == 'local' else INGEST_URL
    print(f'[airlock-publish] root={ROOT} uploads={UPLOADS} listen=127.0.0.1:{PORT} '
          f'public={PUBLIC_ENABLED}({PUBLIC_MODE}{" " + where if PUBLIC_ENABLED and where else ""})', flush=True)
    with ThreadingHTTPServer(('127.0.0.1', PORT), Handler) as server:
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == '__main__':
    main()
