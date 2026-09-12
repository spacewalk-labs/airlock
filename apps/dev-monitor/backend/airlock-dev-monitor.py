#!/usr/bin/env python3
"""airlock-dev-monitor — per-box system/service/network/storage observability.

Runs on loopback (127.0.0.1:<backend_port>); the hub nginx proxies /monitor/api/
here. No psutil dependency: uses only the stdlib + /proc + subprocess so it runs
in a minimal container.

The optional message/action console is imported defensively. If its modules are
absent, or its configuration is not enabled, owner routes return 404 and the
process continues to serve observability.
"""
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# The owner ingress gate is smaller than the optional message/action console: update
# detection needs it even on a box that intentionally has no message spool.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from devmon_secret_names import validate_config
from devmon_secrets import slack_webhooks

# Reject selector/control collisions before parsing any overridden control values.
validate_config(os.environ)
try:
    import devmon_owner
except ImportError:
    devmon_owner = None

# Message/action console modules live beside this backend. Import defensively so
# a deployment without them still provides the observability endpoints.
try:
    import devmon_messages as MSG
    import devmon_spool
    import devmon_slack
    import devmon_loop
    import action_runner
    _MESSAGES_AVAILABLE = devmon_owner is not None
except ImportError:
    MSG = None
    devmon_spool = None
    devmon_slack = None
    devmon_loop = None
    action_runner = None
    _MESSAGES_AVAILABLE = False

# Credential freshness is imported on its own, not with the bundle above: it needs none
# of those modules and must keep working on an install that has no message console.
try:
    import devmon_tokens as TOKENS
    import devmon_accounts as TOKEN_ACCOUNTS
except ImportError:
    TOKENS = None
    TOKEN_ACCOUNTS = None

try:
    import devmon_updates as UPDATES
except ImportError:
    UPDATES = None

try:
    import devmon_home_order as HOME_ORDER
except ImportError:
    HOME_ORDER = None

try:
    import devmon_apps as APPS
except ImportError:
    APPS = None

try:
    import devmon_company_catalog as COMPANY_CATALOG
except ImportError:
    COMPANY_CATALOG = None

# Update EXECUTION is imported separately from update DETECTION so an older tree that
# has the collector but not the runner degrades to a read-only panel instead of 500s.
try:
    import devmon_update_exec as UPDATE_EXEC
except ImportError:
    UPDATE_EXEC = None

# Harness execution — the settings panel's 하네스 section. Imported on its own for the
# same reason as the two above: a tree that has update detection but not this module
# must show the harness rows it can read and simply offer no button, rather than 500.
try:
    import devmon_harness as HARNESS
except ImportError:
    HARNESS = None

# Cron health is core observability, independent of the optional message console.
try:
    import devmon_cron as CRON
except ImportError:
    CRON = None

PORT = int(os.environ.get('AIRLOCK_DEV_MONITOR_BACKEND_PORT', '19923'))
IDENTITY_HEADER = os.environ.get('AIRLOCK_IDENTITY_HEADER', 'Tailscale-User-Login')
# Whether the optional message/action console was requested in configuration.
MESSAGES_REQUESTED = os.environ.get(
    'AIRLOCK_DEV_MONITOR_MESSAGES', 'false').strip().lower() in ('1', 'true', 'yes', 'on')
TOKEN_FRESHNESS = os.environ.get(
    'AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS', 'false').strip().lower() in ('1', 'true', 'yes', 'on')


def _token_hours(name, default):
    """A bad threshold must not take the route down — it falls back and says so."""
    raw = os.environ.get(name, '').strip()
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if value >= 1 else default


TOKEN_WARN_HOURS = _token_hours('AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS_WARN_HOURS', 24)
TOKEN_STALE_HOURS = _token_hours('AIRLOCK_DEV_MONITOR_TOKEN_FRESHNESS_STALE_HOURS', 24)
HOME = os.path.expanduser('~')
# The exact origins allowed to read the unread badge. The installer names them
# scheme+host+PORT — one per badge-drawing tool listener — and an empty set is a
# working state: no cross-origin read, badge only on the hub itself.
#
# The port is the whole point. Comparing hostnames admitted EVERY port of this box,
# including the one that serves published documents — thousands of generated HTML
# pages, some carrying externally sourced content. One `fetch` in any of them read
# the owner's whole message preview, because the ingress injects the reader's
# identity and we echoed the origin back. No cookie is involved; that is what makes
# it ambient authority rather than CSRF.
CORS_ORIGINS = frozenset(
    o.strip().lower()
    for o in os.environ.get('AIRLOCK_DEV_MONITOR_CORS_ORIGINS', '').split(',')
    if o.strip()
)

# Message feature config, loaded by _start_messages. None keeps owner routes
# unavailable without touching the optional modules.
OWNER_CONFIG = None
UPDATES_OWNER_CONFIG = None
EXEC_CONFIG = None
# Update execution keeps its own paths. It cannot borrow EXEC_CONFIG's: those live
# under the message console's database directory, which the installer creates only when
# `messages = true`, and this path has to work on a box that never enabled it.
UPDATE_EXEC_CONFIG = None
_UPDATE_RUN_LOCK = threading.Lock()
# The harness upgrade keeps its own record and its own lock. A Codex CLI upgrade and
# `bin/airlock-update` share no failure and no mutex, so neither may block or report
# over the other (devmon_harness, "Why it does NOT reuse the update run record").
HARNESS_EXEC_CONFIG = None
_HARNESS_RUN_LOCK = threading.Lock()
# The collector the update timer runs. The 하네스 section's '지금 점검' asks for one
# more run of exactly this unit; nothing else on these routes starts a unit.
UPDATE_DETECT_UNIT = 'airlock-update-detect.service'
_MESSAGES_STATE = 'off'
_SLACK_WORKER_ON = False
_TMUX_LOCK = threading.Lock()
MAX_OWNER_PARAM = 200
MAX_OWNER_NOTE = 8000
# How long a run may sit in 'starting' with no window of its own name before the
# reaper calls it a failed launch. Only has to outlast one _launch_run under the lock.
STARTING_GRACE_S = 120
# A completed Claude run is useful for one day after its turn ends. This is a product
# retention rule, not an environment/configuration knob.
RUN_RETENTION_S = 24 * 60 * 60

# History sampling — record cpu%/mem% every minute, summarize into 1h/1d/7d
# averages (ring buffer + a persistent CSV under XDG data home, never /tmp).
_STATE_DIR = os.path.join(HOME, '.local', 'share', 'airlock-dev-monitor')
HISTORY_CSV = os.path.join(_STATE_DIR, 'history.csv')
HISTORY_MAX_DAYS = 7   # 7 days x 1440 min/day = 10080 rows max


# ---- helpers ----
def read_proc(path, default=''):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def run(cmd, timeout=3):
    try:
        return subprocess.check_output(cmd, timeout=timeout, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ''


# ---- overview ----
def host_info():
    name = socket.gethostname()
    os_pretty = ''
    for line in read_proc('/etc/os-release').splitlines():
        if line.startswith('PRETTY_NAME='):
            os_pretty = line.split('=', 1)[1].strip().strip('"')
    kernel = read_proc('/proc/sys/kernel/osrelease')
    uptime_s = float(read_proc('/proc/uptime', '0').split()[0] or 0)
    return {
        'hostname': name,
        'os': os_pretty,
        'kernel': kernel,
        'uptime_seconds': int(uptime_s),
        'uptime_human': humanize_seconds(uptime_s),
    }


def humanize_seconds(s):
    s = int(s)
    d, s = divmod(s, 86400)
    h, s = divmod(s, 3600)
    m, _ = divmod(s, 60)
    parts = []
    if d: parts.append(f'{d}d')
    if h: parts.append(f'{h}h')
    if m or not parts: parts.append(f'{m}m')
    return ' '.join(parts)


_prev_cpu = {'usage_usec': 0, 'ts': 0.0, 'fallback_total': 0, 'fallback_idle': 0}


def _read_cgroup_cpu_usage_usec():
    """cgroup v2 cpu.stat usage_usec — this container's own cumulative CPU time (microsec)."""
    txt = read_proc('/sys/fs/cgroup/cpu.stat')
    for line in txt.splitlines():
        if line.startswith('usage_usec '):
            try:
                return int(line.split()[1])
            except (ValueError, IndexError):
                return None
    return None


def cpu_info():
    """This container's cpu % = cgroup cpu.stat delta / (wall_clock_delta x cores).

    100% = every core fully used. Falls back to /proc/stat (host-wide) when the
    cgroup v2 cpu.stat is unavailable.
    """
    global _prev_cpu
    cores = os.cpu_count() or 1
    now_ts = time.time()
    usage_usec = _read_cgroup_cpu_usage_usec()
    pct = 0.0
    source = 'cgroup'
    if usage_usec is not None:
        if _prev_cpu['usage_usec'] > 0:
            wall_dt = now_ts - _prev_cpu['ts']
            usage_dt = usage_usec - _prev_cpu['usage_usec']
            if wall_dt > 0:
                # denominator = wall_clock(sec) x cores x 1e6 microsec/core/sec
                max_usec = wall_dt * cores * 1_000_000
                pct = round((usage_dt / max_usec) * 100, 1) if max_usec > 0 else 0
        _prev_cpu = {'usage_usec': usage_usec, 'ts': now_ts,
                     'fallback_total': _prev_cpu.get('fallback_total', 0),
                     'fallback_idle': _prev_cpu.get('fallback_idle', 0)}
    else:
        # fallback — host /proc/stat (host-wide when the container has no cpu quota)
        source = 'proc-stat-host'
        fields = read_proc('/proc/stat').splitlines()[0].split()[1:]
        user, nice, system, idle, iowait = (int(x) for x in fields[:5])
        total = sum(int(x) for x in fields)
        if _prev_cpu.get('fallback_total', 0) > 0:
            dt = total - _prev_cpu['fallback_total']
            di = (idle + iowait) - _prev_cpu['fallback_idle']
            if dt > 0:
                pct = round((1 - di / dt) * 100, 1)
        _prev_cpu['fallback_total'] = total
        _prev_cpu['fallback_idle'] = idle + iowait
        _prev_cpu['ts'] = now_ts
    loadavg = read_proc('/proc/loadavg').split()[:3]
    # cgroup quota (cpu.max) — the per-container CPU cap, if any.
    quota_str = read_proc('/sys/fs/cgroup/cpu.max').strip()
    quota_pct = None    # None = no quota (all cores available)
    if quota_str and not quota_str.startswith('max '):
        try:
            quota_us, period_us = quota_str.split()
            quota_us, period_us = int(quota_us), int(period_us)
            # quota = N% of one core. As a fraction of all cores: quota/period/cores x 100
            quota_pct = round(quota_us / period_us / cores * 100, 1) if period_us > 0 and cores > 0 else None
        except (ValueError, IndexError):
            pass
    return {
        'percent': pct,
        'loadavg': loadavg,
        'cores': cores,
        'source': source,           # 'cgroup' (this container) or 'proc-stat-host' (fallback)
        'quota_pct': quota_pct,     # None = unlimited / number = this container's cap (% of cores)
    }


def mem_info():
    info = {}
    for line in read_proc('/proc/meminfo').splitlines():
        if ':' in line:
            k, v = line.split(':', 1)
            info[k.strip()] = int(v.strip().split()[0])  # kB
    total = info.get('MemTotal', 0) * 1024
    avail = info.get('MemAvailable', info.get('MemFree', 0)) * 1024
    used = total - avail
    cache = info.get('Cached', 0) * 1024
    swap_total = info.get('SwapTotal', 0) * 1024
    swap_used = swap_total - info.get('SwapFree', 0) * 1024
    return {
        'used_bytes': used,
        'total_bytes': total,
        'cache_bytes': cache,
        'swap_used_bytes': swap_used,
        'swap_total_bytes': swap_total,
        'percent': round(used * 100 / total, 1) if total else 0,
    }


def disk_info(path='/'):
    try:
        st = os.statvfs(path)
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        used = total - free
        return {
            'path': path,
            'used_bytes': used,
            'total_bytes': total,
            'percent': round(used * 100 / total, 1) if total else 0,
        }
    except OSError:
        return {'path': path, 'used_bytes': 0, 'total_bytes': 0, 'percent': 0}


# ---- services ----
# System services are queried by fixed name (they need sudo to change, so they
# are shown read-only). User observation is broader than restart authority: private
# apps and timer jobs must remain visible, while writes stay restricted to Airlock.
SYSTEM_SERVICES = ['nginx', 'ssh', 'tailscaled']
SELF_SERVICE = 'airlock-dev-monitor'
SERVICE_SHOW_PROPERTIES = (
    'Id', 'Type', 'LoadState', 'ActiveState', 'SubState', 'Result', 'NRestarts',
    'ExecMainStatus', 'UnitFileState', 'ActiveEnterTimestamp',
)
SERVICE_COMMAND_TIMEOUT = 1


def _service_command(cmd, allowed_nonzero=()):
    """Bound a service-panel probe and retain stdout even with a non-zero status."""
    try:
        proc = subprocess.run(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, timeout=SERVICE_COMMAND_TIMEOUT, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return '', 'collection failed'
    if proc.returncode != 0:
        if proc.returncode in allowed_nonzero and proc.stdout.strip():
            return proc.stdout, None
        return proc.stdout, 'collection failed'
    return proc.stdout, None


def _observed_user_inventory():
    """Meaningful concrete user services plus collection health."""
    commands = [
        ['systemctl', '--user', 'list-unit-files', '--no-legend', '--type=service'],
        ['systemctl', '--user', 'list-units', '--all', '--no-legend', '--plain',
         '--type=service'],
        ['systemctl', '--user', 'list-timers', '--all', '--no-legend', '--plain'],
    ]
    units = []
    failed = False
    for index, command in enumerate(commands):
        output, error = _service_command(command)
        failed = failed or bool(error)
        for line in output.splitlines():
            parts = line.split()
            if not parts:
                continue
            if index == 2:
                # list-timers' final column is the activated service unit.
                name = parts[-1]
                include = name.endswith('.service')
            else:
                # Older systemctl can still prefix a failed unit with a bullet despite
                # --plain/--no-legend. Do not lose a failed template instance here.
                if parts[0] == '●' and len(parts) > 1:
                    parts = parts[1:]
                name = parts[0]
                state = parts[1] if index == 0 and len(parts) > 1 else ''
                active = parts[2] if index == 1 and len(parts) > 2 else ''
                include = (name.startswith('airlock-')
                           or state in ('enabled', 'enabled-runtime')
                           or active == 'failed')
            if include and name.endswith('.service') and '@.' not in name:
                units.append(name[:-len('.service')])
    return sorted(set(units)), ('inventory collection failed' if failed else None)


def _airlock_user_inventory():
    """Original Airlock-only discovery, kept separate from broad observation."""
    commands = [
        ['systemctl', '--user', 'list-unit-files', '--no-legend', '--type=service'],
        ['systemctl', '--user', 'list-units', '--all', '--no-legend', '--plain',
         '--type=service', 'airlock-*'],
    ]
    units = []
    failed = False
    for command in commands:
        output, error = _service_command(command)
        failed = failed or bool(error)
        for line in output.splitlines():
            parts = line.split()
            if not parts:
                continue
            name = parts[1] if parts[0] == '●' and len(parts) > 1 else parts[0]
            if (name.startswith('airlock-') and name.endswith('.service')
                    and '@.' not in name):
                units.append(name[:-len('.service')])
    return sorted(set(units)), ('inventory collection failed' if failed else None)


def _airlock_user_units():
    """Restart allowlist: complete original discovery plus canonical systemd Id."""
    candidates, error = _airlock_user_inventory()
    if error or not candidates:
        return []
    raw, error = _systemctl_show(candidates, 'user')
    if error:
        return []
    canonical = set()
    for block in _show_blocks(raw):
        props = dict(line.split('=', 1) for line in block.splitlines() if '=' in line)
        unit_id = props.get('Id', '')
        if unit_id.endswith('.service'):
            canonical.add(unit_id[:-len('.service')])
    # An alias resolves to a different Id and receives no write authority. This also
    # prevents an airlock-* alias from bypassing SELF_SERVICE exclusion.
    return [name for name in candidates if name in canonical]


def _systemctl_show(names, scope):
    if isinstance(names, str):
        names = [names]
    if not names:
        return '', None
    cmd = ['systemctl']
    if scope == 'user':
        cmd.append('--user')
    cmd.extend([
        'show', '--no-pager',
        '--property=' + ','.join(SERVICE_SHOW_PROPERTIES), '--', *names,
    ])
    # `systemctl show` returns rc=3 for useful inactive-unit output. Inventory commands
    # do not: partial stdout with non-zero must remain fail-visible.
    return _service_command(cmd, allowed_nonzero=(3,))


def _show_blocks(raw):
    blocks = []
    current = []
    for line in raw.splitlines():
        if not line.strip():
            if current:
                blocks.append('\n'.join(current))
                current = []
        else:
            current.append(line)
    if current:
        blocks.append('\n'.join(current))
    return blocks


def _as_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _service_from_show(name, scope, raw, collection_error=None):
    props = {}
    for line in raw.splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            props[key] = value

    service_type = props.get('Type', '')
    load_state = props.get('LoadState', '')
    active_state = props.get('ActiveState', '')
    sub_state = props.get('SubState', '')
    result = props.get('Result', '')
    n_restarts = _as_int(props.get('NRestarts'))
    exec_main_status = _as_int(props.get('ExecMainStatus'))
    unit_file_state = props.get('UnitFileState', '')

    attention = False
    reason = ''
    required = ('LoadState', 'ActiveState', 'SubState', 'Result', 'NRestarts')
    if collection_error or any(key not in props for key in required):
        attention, reason = True, 'health collection failed'
    elif load_state != 'loaded':
        attention, reason = True, 'LoadState=' + (load_state or 'unknown')
    elif active_state == 'failed' or sub_state == 'failed':
        reason = 'failed'
        if result:
            reason += ': Result=' + result
        if exec_main_status not in (None, 0):
            reason += ', ExecMainStatus=' + str(exec_main_status)
        attention = True
    elif result and result != 'success':
        attention, reason = True, 'Result=' + result
    elif sub_state == 'auto-restart':
        attention, reason = True, 'SubState=auto-restart'
    elif n_restarts is None:
        attention, reason = True, 'NRestarts unavailable'
    elif n_restarts > 0:
        attention, reason = True, 'NRestarts=' + str(n_restarts)
    elif (service_type != 'oneshot' and active_state == 'inactive'
          and unit_file_state in ('enabled', 'enabled-runtime')):
        attention, reason = True, 'enabled service is inactive/' + (sub_state or 'unknown')

    return {
        'name': name,
        'scope': scope,
        # Compatibility for clients deployed before typed systemd health.
        'state': active_state or 'unknown',
        'uptime': uptime_from_timestamp(props.get('ActiveEnterTimestamp', '')),
        'type': service_type,
        'load_state': load_state or 'unknown',
        'active_state': active_state or 'unknown',
        'sub_state': sub_state or 'unknown',
        'result': result or 'unknown',
        'n_restarts': n_restarts,
        'exec_main_status': exec_main_status,
        'unit_file_state': unit_file_state or 'unknown',
        'attention': attention,
        'attention_reason': reason,
        # A synchronous restart from inside this service kills both the request
        # handler and its systemctl child before either can report success.
        # Observation never grants mutation. svc_info adds the explicit Airlock-only
        # allowlist after classification; direct/failed/system rows remain read-only.
        'action_allowed': False,
    }


def _service_group_info(names, scope):
    """Resolve a scope in one bounded systemctl call, keyed by systemd's own Id."""
    raw, error = _systemctl_show(names, scope)
    if error:
        return [_service_from_show(name, scope, '', error) for name in names]
    by_name = {}
    for block in _show_blocks(raw):
        props = dict(line.split('=', 1) for line in block.splitlines() if '=' in line)
        unit_id = props.get('Id', '')
        if unit_id.endswith('.service'):
            by_name[unit_id[:-len('.service')]] = block
    return [
        _service_from_show(
            name, scope, by_name.get(name, ''),
            None if name in by_name else 'collection failed')
        for name in names
    ]


def svc_info():
    user_units, inventory_error = _observed_user_inventory()
    out = _service_group_info(user_units, 'user')
    restartable = set(_airlock_user_units())
    for item in out:
        item['action_allowed'] = (item['name'] in restartable
                                  and item['name'] != SELF_SERVICE)
    if inventory_error:
        item = _service_from_show(
            'airlock-user-inventory', 'user', '', inventory_error)
        item['action_allowed'] = False
        out.append(item)
    out.extend(_service_group_info(SYSTEM_SERVICES, 'system'))
    return out


def _services_payload(services=None):
    services = svc_info() if services is None else services
    return {
        'services': services,
        'attention_count': sum(1 for item in services if item.get('attention')),
    }


def restart_svc(name):
    """Restart exactly one installed airlock user unit, never a system service."""
    if (not isinstance(name, str) or name == SELF_SERVICE
            or name not in set(_airlock_user_units())):
        return False, 'service restart is not allowed'
    try:
        subprocess.check_call(
            ['systemctl', '--user', 'restart', '--', name], timeout=10,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True, f'restarted: {name}'
    except subprocess.TimeoutExpired:
        return False, 'restart timeout'
    except (OSError, subprocess.CalledProcessError):
        return False, 'restart failed'


def uptime_from_timestamp(ts):
    if not ts:
        return ''
    try:
        # systemd format, e.g. 'Mon 2026-05-21 09:25:53 UTC'
        for fmt in ('%a %Y-%m-%d %H:%M:%S %Z', '%a %Y-%m-%d %H:%M:%S'):
            try:
                dt = datetime.strptime(ts.rsplit(' ', 1)[0] + ' ' + ts.rsplit(' ', 1)[1], fmt)
                seconds = (datetime.now() - dt.replace(tzinfo=None)).total_seconds()
                return humanize_seconds(seconds)
            except ValueError:
                continue
    except Exception:
        pass
    return ''


# ---- network ----
def network_info():
    ts_json = run(['tailscale', 'status', '--json'])
    self_ip = ''
    self_dns = ''
    peers = []
    if ts_json:
        try:
            d = json.loads(ts_json)
            self_ip = (d.get('Self', {}).get('TailscaleIPs') or [''])[0]
            self_dns = d.get('Self', {}).get('DNSName', '').rstrip('.')
            for p in d.get('Peer', {}).values():
                peers.append({
                    'name': p.get('HostName', ''),
                    'ip': (p.get('TailscaleIPs') or [''])[0],
                    'online': p.get('Online', False),
                })
        except Exception:
            pass

    listen = []
    # /proc/net/tcp parse — minimal subset (IPv4 LISTEN sockets)
    try:
        with open('/proc/net/tcp') as f:
            for line in f.readlines()[1:30]:
                fields = line.split()
                if len(fields) < 4:
                    continue
                local = fields[1]
                state = fields[3]
                if state != '0A':   # LISTEN
                    continue
                ip_hex, port_hex = local.split(':')
                port = int(port_hex, 16)
                ip = '.'.join(str(int(ip_hex[i:i+2], 16)) for i in (6, 4, 2, 0))
                listen.append({'port': port, 'ip': ip})
    except OSError:
        pass
    # dedupe
    seen = set()
    listen_uniq = []
    for it in sorted(listen, key=lambda x: x['port']):
        key = (it['port'], it['ip'])
        if key in seen: continue
        seen.add(key)
        listen_uniq.append(it)

    return {
        'tailscale': {
            'ip': self_ip,
            'dns': self_dns,
            'peer_count': len(peers),
            'peers': peers[:10],
        },
        'listen_ports': listen_uniq,
    }


# ---- storage ----
def du_quick(path):
    if not os.path.isdir(path):
        return None
    out = run(['du', '-sh', '--apparent-size', path], timeout=15)
    if not out:
        return None
    return out.split()[0]


def storage_info():
    items = []
    root = disk_info('/')
    items.append({'path': '/', 'bytes': root['used_bytes'], 'total_bytes': root['total_bytes'], 'human': du_quick('/') or ''})
    # Common per-user directories, if present (no assumptions about which exist).
    for sub in ['code', 'workspace', 'public_html', 'uploads', '.cache']:
        full = os.path.join(HOME, sub)
        if os.path.isdir(full):
            items.append({'path': f'~/{sub}', 'human': du_quick(full) or '(scan timeout)'})
    return items


# ---- history sampling (1-minute thread) ----
def history_sample_once():
    """Append one cpu/mem sample to the CSV."""
    cpu_info()   # delta sampling — the second call is accurate; the first primes _prev_cpu
    time.sleep(0.5)
    c = cpu_info()
    m = mem_info()
    ts = int(time.time())
    line = f'{ts},{c["percent"]},{m["percent"]}\n'
    try:
        with open(HISTORY_CSV, 'a') as f:
            f.write(line)
    except OSError as e:
        sys.stderr.write(f'[history] write fail: {e}\n')


def history_sampler():
    """1-minute sampling thread, started at boot."""
    while True:
        try:
            history_sample_once()
        except Exception as e:
            sys.stderr.write(f'[history] sample err: {e}\n')
        time.sleep(60)


def history_load(seconds_ago):
    """(ts, cpu, mem) tuples within the last seconds_ago .. now."""
    cutoff = int(time.time()) - seconds_ago
    rows = []
    if not os.path.exists(HISTORY_CSV):
        return rows
    try:
        with open(HISTORY_CSV) as f:
            for line in f:
                try:
                    ts, c, m = line.strip().split(',')
                    ts = int(ts)
                    if ts >= cutoff:
                        rows.append((ts, float(c), float(m)))
                except (ValueError, IndexError):
                    continue
    except OSError:
        pass
    return rows


def history_summary():
    """1h / 1d / 7d averages + peak cpu%/mem%."""
    def stats(rows):
        if not rows:
            return {'samples': 0}
        cpus = [r[1] for r in rows]
        mems = [r[2] for r in rows]
        return {
            'samples': len(rows),
            'cpu_avg': round(sum(cpus) / len(cpus), 1),
            'cpu_max': round(max(cpus), 1),
            'mem_avg': round(sum(mems) / len(mems), 1),
            'mem_max': round(max(mems), 1),
        }
    one_h = history_load(3600)
    one_d = history_load(86400)
    seven_d = history_load(86400 * 7)
    return {
        '1h': stats(one_h),
        '1d': stats(one_d),
        '7d': stats(seven_d),
    }


def history_trim():
    """Drop the oldest rows when the CSV grows past the retention window."""
    if not os.path.exists(HISTORY_CSV):
        return
    max_lines = HISTORY_MAX_DAYS * 1440 + 100
    try:
        with open(HISTORY_CSV) as f:
            lines = f.readlines()
        if len(lines) > max_lines:
            with open(HISTORY_CSV, 'w') as f:
                f.writelines(lines[-max_lines:])
    except OSError:
        pass


# ---- top processes (5-second live sampling, grouped by comm) ----
_TOP_LOCK = threading.Lock()
_TOP_CACHE = {'ts': 0, 'cpu': [], 'mem': [], 'total_mem_kb': 1, 'cores': 1}
_CLOCK_TICKS = os.sysconf('SC_CLK_TCK') if hasattr(os, 'sysconf') else 100


def _scan_procs():
    """/proc/*/stat utime+stime + /proc/*/status VmRSS + comm."""
    import pwd
    procs = {}
    try:
        pids = [d for d in os.listdir('/proc') if d.isdigit()]
    except OSError:
        return procs
    for pid in pids:
        try:
            with open(f'/proc/{pid}/stat') as f:
                line = f.read()
            rb = line.rfind(')')
            if rb < 0:
                continue
            fields = line[rb + 2:].split()
            # after ')': state(0), ppid(1), pgrp(2), session(3), tty_nr(4), tpgid(5), flags(6),
            # minflt(7), cminflt(8), majflt(9), cmajflt(10), utime(11), stime(12), ...
            if len(fields) < 13:
                continue
            utime = int(fields[11])
            stime = int(fields[12])
        except (OSError, ValueError):
            continue
        comm = line[line.find('(') + 1:rb]
        rss = 0
        try:
            with open(f'/proc/{pid}/status') as f:
                for line2 in f:
                    if line2.startswith('VmRSS:'):
                        rss = int(line2.split()[1])
                        break
        except (OSError, ValueError):
            pass
        user = 'unknown'
        try:
            uid = os.stat(f'/proc/{pid}').st_uid
            user = pwd.getpwuid(uid).pw_name
        except (OSError, KeyError):
            try:
                user = str(uid)
            except Exception:
                pass
        procs[int(pid)] = {'comm': comm, 'ticks': utime + stime, 'rss_kb': rss, 'user': user}
    return procs


def _top_sampler():
    """5-second sampling. cpu = delta jiffies / 5s / cores. mem = sum RSS. Grouped by comm."""
    global _TOP_CACHE
    prev = _scan_procs()
    cores = os.cpu_count() or 1
    while True:
        time.sleep(5)
        try:
            cur = _scan_procs()
            mem_total_kb = 1
            try:
                with open('/proc/meminfo') as f:
                    for line in f:
                        if line.startswith('MemTotal:'):
                            mem_total_kb = int(line.split()[1])
                            break
            except OSError:
                pass
            groups = {}
            for pid, info in cur.items():
                prev_info = prev.get(pid)
                if not prev_info or prev_info['comm'] != info['comm']:
                    # new process — count mem now, cpu delta starts at 0
                    tick_delta = 0
                else:
                    tick_delta = info['ticks'] - prev_info['ticks']
                    if tick_delta < 0:
                        tick_delta = 0
                comm = info['comm']
                g = groups.setdefault(comm, {
                    'ticks_delta': 0, 'rss_kb_sum': 0, 'count': 0,
                    'user': info['user'], 'pid_sample': pid,
                })
                g['ticks_delta'] += tick_delta
                g['rss_kb_sum'] += info['rss_kb']
                g['count'] += 1
            sample_seconds = 5.0
            cpu_list = []
            mem_list = []
            for comm, g in groups.items():
                cpu_seconds = g['ticks_delta'] / _CLOCK_TICKS
                cpu_cores = round(cpu_seconds / sample_seconds, 3)
                cpu_pct = round(cpu_cores / cores * 100, 1) if cores > 0 else 0
                entry = {
                    'comm': comm, 'count': g['count'], 'user': g['user'],
                    'cpu_cores': cpu_cores, 'cpu_pct': cpu_pct,
                    'mem_bytes': g['rss_kb_sum'] * 1024,
                    'mem_pct': round(g['rss_kb_sum'] / mem_total_kb * 100, 1) if mem_total_kb else 0,
                    'pid_sample': g['pid_sample'],
                }
                if cpu_cores > 0.001:
                    cpu_list.append(entry)
                if g['rss_kb_sum'] > 0:
                    mem_list.append(entry)
            cpu_list.sort(key=lambda x: -x['cpu_cores'])
            mem_list.sort(key=lambda x: -x['mem_bytes'])
            with _TOP_LOCK:
                _TOP_CACHE = {
                    'ts': time.time(), 'cpu': cpu_list[:30], 'mem': mem_list[:30],
                    'total_mem_kb': mem_total_kb, 'cores': cores,
                }
            prev = cur
        except Exception as e:
            sys.stderr.write(f'[top_sampler] err: {e}\n')


def top_processes(n=10, sort_by='cpu'):
    """Return the 5-second sampling cache. Empty until the first window elapses."""
    with _TOP_LOCK:
        cache = dict(_TOP_CACHE)
    key = 'cpu' if sort_by == 'cpu' else 'mem'
    return cache.get(key, [])[:n]


# ---- recent logs (user units only — no sudo) ----
def recent_logs(unit='airlock-dev-monitor', n=10):
    out = run(['journalctl', '--user', '-u', unit, '-n', str(n), '--no-pager', '-o', 'short-iso'])
    lines = []
    for line in out.splitlines()[-n:]:
        lines.append(line.strip())
    return lines


# ---- credential freshness ----
def token_freshness_info():
    """Live verdicts, plus how old the TIMER's last verdict is.

    Two clocks on purpose. The live half answers "how long is left" the moment the page
    is opened; `last_check` answers "is anything actually watching". A card that showed
    only the live half would look identical whether the timer had run this morning or
    died in March, and a card that showed only the snapshot would go stale silently.
    """
    snapshot_path = TOKENS.snapshot_path()
    last = TOKENS.read_snapshot(snapshot_path)
    raw, source_error = TOKEN_ACCOUNTS.raw_deadlines()
    live = TOKENS.check_all(raw, warn_hours=TOKEN_WARN_HOURS,
                            stale_hours=TOKEN_STALE_HOURS)
    live['source_error'] = source_error
    live['last_check'] = {
        'path': snapshot_path,
        # None both times, and they mean different things: never = the timer has never
        # run here, which is not the same as a run whose age we know.
        'checked_at': last.get('checked_at') if last else None,
        'age_seconds': last.get('age_seconds') if last else None,
        'ever': last is not None,
    }
    return live


def _token_state():
    """What the health endpoint admits to: what was ASKED FOR is not what is RUNNING."""
    if not TOKEN_FRESHNESS:
        return 'off'
    return 'on' if TOKENS is not None else 'unavailable'


# ---- HTTP handler ----
class Handler(BaseHTTPRequestHandler):
    def _cors_origin(self):
        """The request Origin if it is a listener allowed to draw the badge, else None.

        Why this exists: the Airlock return widget is injected into tools that run on
        their own ports, and it reads the owner message preview from here to draw the
        unread badge. Without an echoed ACAO that fetch fails silently and the badge
        simply never appears — which reads as "no unread messages".

        The comparison is a WHOLE ORIGIN — scheme, host AND port — against the set the
        installer measured. Two earlier versions were each one step too loose. The first
        compared only the hostname's first label, which let `<boxname>.attacker.example`
        pass. The second compared the whole hostname, which was still every PORT of this
        box: the document port serves generated HTML by the thousand, so a script in any
        published page could read the owner's message preview with the owner's own
        authority. Neither needed a cookie — the ingress injects the identity, and an
        echoed ACAO hands the response to whatever asked.

        The badge is drawn by the shell-grade tools only. The document port is
        deliberately absent from the allowed set: it is the one surface here whose
        content is bulk-generated, so it is the one that must not be able to ask.
        """
        origin = (self.headers.get('Origin') or '').strip().lower()
        # Echo the NORMALISED value, not what arrived. Matching already folds case and
        # trims padding, so returning the raw header would put caller-chosen bytes into a
        # security response header for free. A browser always sends the normalised form,
        # so this is byte-identical for every real caller and only closes the gap for
        # hand-made requests — which are not bound by CORS anyway, but should still not
        # get to choose what we say back.
        return origin if origin in CORS_ORIGINS else None

    def _json(self, status, payload, cors=False):
        """cors=True only where a cross-origin read is a feature. It is off by default
        because most of what this serves is the owner's, and a route that does not need
        to be readable from another origin should not be."""
        body = json.dumps(payload, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-cache, no-store, must-revalidate')
        allowed = self._cors_origin() if cors else None
        if allowed:
            self.send_header('Access-Control-Allow-Origin', allowed)
        # Vary regardless: the body does not change with Origin, but the header set does
        # for the routes that opt in, and a shared cache must not reuse one origin's
        # response for another.
        self.send_header('Vary', 'Origin')
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

    def _strip_prefix(self, path):
        for prefix in ('/monitor/', '/monitor'):
            if path.startswith(prefix):
                rest = path[len(prefix):]
                if not rest.startswith('/'):
                    rest = '/' + rest
                return rest
        return path

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        path = self._strip_prefix(url.path)
        if path.startswith('/api/owner/'):
            self._handle_owner_get(path, urllib.parse.parse_qs(url.query))
            return
        if path in ('/api/overview', '/overview'):
            self._json(200, {
                'host': host_info(),
                'cpu': cpu_info(),
                'memory': mem_info(),
                'disk': disk_info('/'),
            })
            return
        if path in ('/api/services', '/services'):
            self._json(200, _services_payload())
            return
        if path in ('/api/network', '/network'):
            self._json(200, network_info())
            return
        if path in ('/api/storage', '/storage'):
            self._json(200, {'items': storage_info()})
            return
        if path in ('/api/tokens', '/tokens'):
            # 404 rather than an empty answer when the feature is off: an empty provider
            # list would render as "nothing wrong here", which is the one thing this
            # feature must never say by accident.
            if _token_state() != 'on':
                self._json(404, {'ok': False, 'error': 'token freshness not enabled',
                                 'state': _token_state()})
                return
            self._json(200, token_freshness_info())
            return
        if path in ('/api/cron/jobs', '/cron/jobs'):
            if CRON is None:
                self._json(503, {'ok': False, 'error': 'cron collector unavailable'})
                return
            try:
                self._json(200, CRON.snapshot())
            except Exception as exc:
                self._json(500, {'ok': False, 'error': f'cron collection failed: {exc}'})
            return
        if path in ('/api/history', '/history'):
            self._json(200, history_summary())
            return
        if path in ('/api/top', '/top'):
            qs = urllib.parse.parse_qs(url.query)
            sort_by = qs.get('sort', ['cpu'])[0]
            try:
                n = int(qs.get('n', ['10'])[0])
            except ValueError:
                n = 10
            self._json(200, {'sort_by': sort_by, 'processes': top_processes(n, sort_by)})
            return
        if path.startswith('/api/logs') or path.startswith('/logs'):
            qs = urllib.parse.parse_qs(url.query)
            unit = qs.get('unit', ['airlock-dev-monitor'])[0]
            try:
                n = int(qs.get('n', ['10'])[0])
            except ValueError:
                n = 10
            self._json(200, {'unit': unit, 'lines': recent_logs(unit, n)})
            return
        if path in ('/api/health', '/health', '/'):
            # 'messages' is what actually happened, not what was asked for: requested but
            # unconfigured reads as 'off' here too. Without this the only evidence of a
            # half-configured install is one journal line at boot, which nothing can query
            # afterwards — smoke.sh included.
            self._json(200, {'ok': True, 'service': 'airlock-dev-monitor', 'port': PORT,
                             'messages': _messages_state(),
                             'slack': ('configured' if any(_slack_webhooks().values())
                                       else 'not configured'),
                             **_message_delivery_health(),
                             'messages_requested': MESSAGES_REQUESTED,
                             'token_freshness': _token_state(),
                             'cron': 'on' if CRON is not None else 'unavailable'})
            return
        self._json(404, {'ok': False, 'error': f'unknown path: {path}'})

    def do_POST(self):
        url = urllib.parse.urlparse(self.path)
        path = self._strip_prefix(url.path)
        if path.startswith('/api/owner/'):
            self._handle_owner_post(path)
            return
        self._json(404, {'ok': False, 'error': f'unknown path: {path}'})

    # ---- message/action console owner routes ----
    @staticmethod
    def _seg(value):
        """Decode ONE already-split path segment.

        card_id and run_id both contain ':' (event ids carry a timestamp, run ids a
        window name), which encodeURIComponent turns into %3A. Without this every card
        the shipped producer creates is inert: read/pin/archive/dismiss 404 and /plan
        answers card_not_found, so the unread badge never clears.

        Decoding per segment rather than decoding the whole path first is deliberate —
        a %2F in the path must stay part of one id and must not be able to invent a
        new path segment.
        """
        return urllib.parse.unquote(value)

    def _owner_ready(self, cors=False):
        """Return 404 when messages are disabled; otherwise require the owner gate.

        cors is threaded through to both the 404 and the owner-gate 403 so that
        messages/preview — the one route a non-owner tailnet viewer legitimately
        polls cross-origin — can be read as a real rejection instead of an opaque
        CORS failure. Every other caller leaves it False.
        """
        if OWNER_CONFIG is None:
            self._json(404, {'ok': False, 'error': 'messages feature not enabled'}, cors=cors)
            return False
        return devmon_owner.require_owner(self, OWNER_CONFIG, cors=cors)

    def _updates_owner_ready(self):
        """Updates keep their owner gate when messages are deliberately off."""
        if UPDATES_OWNER_CONFIG is None:
            self._json(404, {'ok': False, 'error': 'update detection owner gate not enabled'})
            return False
        return devmon_owner.require_owner(self, UPDATES_OWNER_CONFIG)

    def _handle_owner_get(self, path, qs):
        if path == '/api/owner/apps':
            if APPS is None:
                self._json(404, {'ok': False, 'error': 'app store not enabled'})
                return
            if not self._updates_owner_ready():
                return
            cfg = UPDATE_EXEC_CONFIG
            if cfg is None:
                self._json(404, {'ok': False, 'error': 'app store execution not enabled'})
                return
            updates = UPDATES.read_snapshot() if UPDATES is not None else None
            try:
                projection = APPS.list_apps(cfg['root'], updates)
                try:
                    config = APPS.config_path(cfg['root'])
                except APPS.AppsError as exc:
                    # list_apps intentionally has a review-only projection for this
                    # exact failure.  A source-tree launch without AIRLOCK_CONFIG asks
                    # package-info for the config path next, which is lock-strict too;
                    # do not let the optional company lookup erase that projection.
                    if (projection.get('degraded') != 'lock-mismatch'
                            or exc.code != 'config_invalid'
                            or 'package lock digest mismatch' not in exc.detail):
                        raise
                    projection['company'] = []
                else:
                    projection['company'] = (
                        COMPANY_CATALOG.list_catalog(config)
                        if COMPANY_CATALOG is not None else [])
                self._json(200, projection)
            except APPS.AppsError as exc:
                sys.stderr.write(f'[apps] listing failed ({exc.code}): {exc.detail}\n')
                self._json(500, {'ok': False, 'error': exc.code})
            except COMPANY_CATALOG.CatalogError as exc:
                sys.stderr.write(f'[apps] company catalog failed ({exc.code}): {exc.detail}\n')
                self._json(500, {'ok': False, 'error': exc.code})
            return
        if path == '/api/owner/home/order':
            if HOME_ORDER is None:
                self._json(404, {'ok': False, 'error': 'home ordering not enabled'})
                return
            if not self._updates_owner_ready():
                return
            try:
                try:
                    cfg = UPDATE_EXEC_CONFIG
                    manifest = HOME_ORDER.manifest_order(
                        cfg['root'] if cfg is not None else None)
                except RuntimeError as exc:
                    # `airlock-config apps` resolves explicit package manifests and is
                    # therefore lock-strict.  The update snapshot still names the only
                    # reviewable tiles; use the same narrow degraded projection as the
                    # app sheet, never a partial inventory for another config error.
                    if (APPS is None or cfg is None
                            or 'package lock digest mismatch' not in str(exc)):
                        raise
                    updates = UPDATES.read_snapshot() if UPDATES is not None else None
                    try:
                        projection = APPS.list_apps(cfg['root'], updates)
                    except APPS.AppsError as projection_error:
                        raise RuntimeError(str(projection_error)) from projection_error
                    if projection.get('degraded') != 'lock-mismatch':
                        raise
                    manifest = [row['id'] for row in projection.get('installed', [])
                                if isinstance(row, dict) and isinstance(row.get('id'), str)]
                self._json(200, {'order': HOME_ORDER.read_order(manifest)})
            except (OSError, RuntimeError):
                self._json(500, {'ok': False, 'error': 'home order unavailable'})
            return
        if path == '/api/owner/updates':
            # The update collector is optional in an already-installed older tree.
            # Return 404, never an empty list: an empty answer would look current while
            # no daily observation is actually running.
            if UPDATES is None:
                self._json(404, {'ok': False, 'error': 'update detection not enabled'})
                return
            if not self._updates_owner_ready():
                return
            snapshot = UPDATES.read_snapshot()
            if snapshot is None:
                self._json(404, {'ok': False, 'error': 'update detection has no snapshot'})
                return
            self._json(200, snapshot)
            return
        if path == '/api/owner/updates/run':
            if not self._updates_owner_ready():
                return
            self._owner_update_run()
            return
        if path == '/api/owner/harness/run':
            if not self._updates_owner_ready():
                return
            self._owner_harness_run()
            return
        # The one route a separate-port tool reads cross-origin: the return widget's
        # unread badge. tailnet_view means the caller is often NOT the owner, so the
        # gate's rejection has to be readable too (cors=True on both), not just the
        # 200 — otherwise a non-owner viewer's badge poll fails as an opaque CORS
        # error instead of the "not owner, real zero" the widget already expects.
        # Everything else stays same-origin only.
        is_preview = path == '/api/owner/messages/preview'
        if not self._owner_ready(cors=is_preview):
            return
        if is_preview:
            self._json(200, MSG.preview(), cors=True)
            return
        if path == '/api/owner/messages':
            scope = qs.get('scope', ['active'])[0]
            if scope not in ('active', 'archived', 'all'):
                scope = 'active'
            self._json(200, MSG.feed(scope))
            return
        self._json(404, {'ok': False, 'error': f'unknown owner path: {path}'})

    _CARD_ACTIONS = {
        'read': lambda cid: MSG.mark_read(cid),
        'archive': lambda cid: MSG.archive(cid),
    }

    def _handle_owner_post(self, path):
        # Validate origin, content type, and size before reading an untrusted body.
        if not devmon_owner.check_mutating(self):
            return
        # Ahead of the message console's gate on purpose: update execution is owner-only
        # but not message-only, exactly as update detection has been since #291.
        if path == '/api/owner/updates/execute':
            if not self._updates_owner_ready():
                return
            self._owner_update_execute(self._read_body())
            return
        if path == '/api/owner/harness/execute':
            if not self._updates_owner_ready():
                return
            self._owner_harness_execute(self._read_body())
            return
        if path == '/api/owner/apps/package-preview':
            if APPS is None or UPDATE_EXEC_CONFIG is None:
                self._json(404, {'ok': False, 'error': 'app store not enabled'})
                return
            if not self._updates_owner_ready():
                return
            body = self._read_body()
            package_path = body.get('path') if isinstance(body, dict) else None
            if not isinstance(package_path, str) or not package_path.strip():
                self._json(400, {'ok': False, 'error': 'bad_package_path'})
                return
            try:
                self._json(200, APPS.package_preview(
                    UPDATE_EXEC_CONFIG['root'], package_path))
            except APPS.AppsError as exc:
                sys.stderr.write(f'[apps] package preview failed ({exc.code}): '
                                 f'{exc.detail}\n')
                status = 400 if exc.code in ('bad_package_path', 'config_invalid') else 500
                self._json(status, {'ok': False, 'error': exc.code})
            return
        parts = path.split('/')
        if len(parts) == 6 and parts[:4] == ['', 'api', 'owner', 'apps']:
            if not self._updates_owner_ready():
                return
            body = self._read_body()
            if parts[5] == 'install-company':
                self._owner_company_install(self._seg(parts[4]))
            else:
                self._owner_app_action(self._seg(parts[4]), parts[5], body)
            return
        if path == '/api/owner/home/order':
            if HOME_ORDER is None:
                self._json(404, {'ok': False, 'error': 'home ordering not enabled'})
                return
            if not self._updates_owner_ready():
                return
            body = self._read_body()
            if not isinstance(body, dict) or not isinstance(body.get('order'), list):
                self._json(400, {'ok': False, 'error': 'order must be an array'})
                return
            try:
                cfg = UPDATE_EXEC_CONFIG
                manifest = HOME_ORDER.manifest_order(
                    cfg['root'] if cfg is not None else None)
                order = HOME_ORDER.write_order(body['order'], manifest)
            except (OSError, RuntimeError):
                self._json(500, {'ok': False, 'error': 'home order unavailable'})
                return
            self._json(200, {'order': order})
            return
        if not self._owner_ready():
            return
        body = self._read_body()
        if path == '/api/owner/run/window':
            self._owner_run_window(body)
            return
        if path == '/api/owner/run':
            self._owner_run(body)
            return
        if path == '/api/owner/service/restart':
            name = body.get('name', '') if isinstance(body, dict) else ''
            ok, message = restart_svc(name)
            self._json(200 if ok else 400, {
                'ok': ok, 'name': name, 'message': message,
            })
            return
        parts = path.split('/')
        if len(parts) == 6 and parts[:4] == ['', 'api', 'owner', 'messages']:
            card_id, action = self._seg(parts[4]), parts[5]
            fn = self._CARD_ACTIONS.get(action)
            if fn is not None:
                ok = fn(card_id)
                self._json(200 if ok else 404, {
                    'ok': ok,
                    'card_id': card_id,
                    'action': action,
                    # unread_count stays for the widget that has not been changed yet.
                    'unread_count': MSG.unread_count(),
                })
                return
        self._json(404, {'ok': False, 'error': f'unknown owner path: {path}'})

    # ---- update execution (owner gate, no message console) ----
    def _owner_update_run(self):
        """Report the last update run plus whether ANY updater holds the mutex.

        `busy` is deliberately three-valued. `null` means the question could not be
        measured on this box, and answering `false` there would be the exact absence
        claim ("nothing is running") that the panel has no evidence for.
        """
        cfg = UPDATE_EXEC_CONFIG
        if cfg is None:
            self._json(404, {'ok': False, 'error': 'update execution not enabled'})
            return
        self._json(200, {
            'ok': True,
            'busy': UPDATE_EXEC.updater_busy(cfg['root']),
            'run': UPDATE_EXEC.observed(UPDATE_EXEC.read_record(cfg['dir'])),
        })

    @staticmethod
    def _pending_app_ids():
        """App ids the current snapshot says are pending a plain reinstall.

        🔴 `lock-mismatch` rows are excluded, and this is the server-side half of owner
        decision LOCK_UI_V1: an external package whose source digest moved needs its lock
        re-approved, that is a terminal procedure, and the panel offers review only. The
        button being absent is presentation; this is the boundary.
        """
        snapshot = UPDATES.read_snapshot() if UPDATES is not None else None
        apps = (snapshot or {}).get('apps')
        if not isinstance(apps, list):
            return set()
        return {a.get('id') for a in apps
                if isinstance(a, dict) and a.get('action') == 'upgrade'}

    def _owner_update_execute(self, body):
        """Validate a closed enum, then launch `bin/airlock-update` in a tmux window."""
        cfg = UPDATE_EXEC_CONFIG
        if cfg is None:
            self._json(404, {'ok': False, 'error': 'update execution not enabled'})
            return
        action = body.get('action') if isinstance(body, dict) else None
        app_id = body.get('id') if isinstance(body, dict) else None
        if action == 'platform':
            app_id = None
        elif action == 'app':
            if not isinstance(app_id, str) or not UPDATE_EXEC.APP_ID.match(app_id):
                self._json(400, {'ok': False, 'error': 'bad_app_id'})
                return
            if app_id not in self._pending_app_ids():
                # Either the snapshot never listed it, or it is a lock-mismatch row.
                self._json(409, {'ok': False, 'error': 'app_not_pending'})
                return
        else:
            self._json(400, {'ok': False, 'error': 'bad_action'})
            return
        self._owner_update_launch(action, app_id)

    def _owner_update_launch(self, action, app_id, response_action=None, lock_held=False,
                             approved_digest=None, package_path=None, reapprove=False):
        """Launch one already-authorized closed action through the shared scope."""
        cfg = UPDATE_EXEC_CONFIG
        if cfg is None:
            self._json(404, {'ok': False, 'error': 'update execution not enabled'})
            return
        if not lock_held:
            with _UPDATE_RUN_LOCK:
                return self._owner_update_launch(action, app_id, response_action, True)
        record = UPDATE_EXEC.observed(UPDATE_EXEC.read_record(cfg['dir']))
        if UPDATE_EXEC.active(record):
            self._json(409, {'ok': False, 'error': 'run_active',
                             'run_id': record.get('runId')})
            return
        # Only a measured `True` blocks. An unmeasurable lock must not take the
        # button away — the updater's own mutex refuses a second run regardless,
        # and that refusal is visible in the pane and in the run's exit code.
        if UPDATE_EXEC.updater_busy(cfg['root']) is True:
            self._json(409, {'ok': False, 'error': 'updater_busy'})
            return
        run_id = UPDATE_EXEC.new_run_id()
        try:
            UPDATE_EXEC.ensure_dirs(cfg['dir'])
            UPDATE_EXEC.sweep_plans(cfg['dir'])
            # Written BEFORE the window exists so a click is never invisible: if the
            # launch dies here, the panel shows a failed run instead of nothing.
            UPDATE_EXEC.write_record(
                cfg['dir'], UPDATE_EXEC.start_record(run_id, action, app_id))
        except OSError as exc:
            sys.stderr.write(f'[update-exec] run record write failed: {exc}\n')
            self._json(500, {'ok': False, 'error': 'state_unwritable'})
            return
        plan = UPDATE_EXEC.build_plan(
            cfg['root'], cfg['dir'], run_id, action, app_id,
            approved_digest=approved_digest, package_path=package_path,
            reapprove=reapprove)
        outcome, _target = _launch_run(run_id, plan, cfg, run_id)
        if outcome != 'ok':
            self._fail_update_record(cfg, run_id, outcome)
            self._json(503 if outcome == 'ambiguous' else 500,
                       {'ok': False, 'error': 'launch_failed', 'outcome': outcome})
            return
        payload = {'ok': True, 'run_id': run_id,
                   'action': response_action or action, 'id': app_id}
        if response_action is not None:
            payload['execution'] = action
        self._json(200, payload)

    def _owner_app_action(self, app_id, action, body=None):
        """Mutate one app intent, then run the full installer outside this service."""
        if APPS is None or UPDATE_EXEC_CONFIG is None:
            self._json(404, {'ok': False, 'error': 'app store not enabled'})
            return
        if action not in ('enable', 'disable', 'remove', 'register', 'reapprove'):
            self._json(404, {'ok': False, 'error': 'unknown app action'})
            return
        if not isinstance(app_id, str) or APPS.APP_ID.fullmatch(app_id) is None:
            self._json(400, {'ok': False, 'error': 'bad_app_id'})
            return
        with _UPDATE_RUN_LOCK:
            # Refuse before changing the operator's config. Otherwise a second click
            # during a live installer would answer 409 only after leaving unapplied
            # intent behind on disk.
            cfg = UPDATE_EXEC_CONFIG
            record = UPDATE_EXEC.observed(UPDATE_EXEC.read_record(cfg['dir']))
            if UPDATE_EXEC.active(record):
                self._json(409, {'ok': False, 'error': 'run_active',
                                 'run_id': record.get('runId')})
                return
            if UPDATE_EXEC.updater_busy(cfg['root']) is True:
                self._json(409, {'ok': False, 'error': 'updater_busy'})
                return
            self._owner_app_action_locked(app_id, action, body)

    def _owner_company_install(self, app_id):
        """Stage one catalog pin, then reuse the canonical config writer and installer."""
        if APPS is None or COMPANY_CATALOG is None or UPDATE_EXEC_CONFIG is None:
            self._json(404, {'ok': False, 'error': 'company catalog not enabled'})
            return
        if not isinstance(app_id, str) or APPS.APP_ID.fullmatch(app_id) is None:
            self._json(400, {'ok': False, 'error': 'bad_app_id'})
            return
        with _UPDATE_RUN_LOCK:
            cfg = UPDATE_EXEC_CONFIG
            record = UPDATE_EXEC.observed(UPDATE_EXEC.read_record(cfg['dir']))
            if UPDATE_EXEC.active(record):
                self._json(409, {'ok': False, 'error': 'run_active',
                                 'run_id': record.get('runId')})
                return
            if UPDATE_EXEC.updater_busy(cfg['root']) is True:
                self._json(409, {'ok': False, 'error': 'updater_busy'})
                return
            try:
                config = APPS.config_path(cfg['root'])
                rows = COMPANY_CATALOG.list_catalog(config)
                entry = next((row for row in rows if row['id'] == app_id), None)
                if entry is None:
                    self._json(404, {'ok': False, 'error': 'app_not_found'})
                    return
                if entry['installable'] is not True:
                    self._json(409, {
                        'ok': False, 'error': 'catalog_not_installable',
                        'reason': entry['reason'],
                    })
                    return
                package = COMPANY_CATALOG.stage_entry(cfg['root'], config, entry)
                preview = APPS.package_preview(cfg['root'], str(package))
                canonical_path = str(Path(preview.get('path', '')).resolve())
                if (preview.get('id') != app_id
                        or preview.get('digest') != entry['tree_digest']
                        or Path(canonical_path) != package.resolve()):
                    self._json(409, {'ok': False, 'error': 'package_preview_changed'})
                    return
                if preview.get('installable') is not True:
                    self._json(409, {
                        'ok': False, 'error': 'package_not_installable',
                        'rejected_capabilities': preview.get('rejected_capabilities') or [],
                        'conflict': preview.get('conflict'),
                    })
                    return
                if preview.get('registered'):
                    self._json(409, {'ok': False, 'error': 'package_already_registered'})
                    return
                reapprove = preview.get('requires_reapproval') is True
                registration = {
                    'path': canonical_path,
                    'grant': preview.get('grants') or [],
                }
                if reapprove:
                    APPS.register(config, app_id, registration,
                                  approved_digest=entry['tree_digest'])
                else:
                    APPS.register(config, app_id, registration)
            except APPS.AppsError as exc:
                sys.stderr.write(f'[apps] company register failed for {app_id!r} '
                                 f'({exc.code}): {exc.detail}\n')
                status = 400 if exc.code in ('bad_app_id', 'config_invalid') else 409 \
                    if exc.code in ('config_conflict', 'package_already_registered') else 500
                self._json(status, {'ok': False, 'error': exc.code})
                return
            except COMPANY_CATALOG.CatalogError as exc:
                sys.stderr.write(f'[apps] company stage failed for {app_id!r} '
                                 f'({exc.code}): {exc.detail}\n')
                status = 409 if exc.code in (
                    'digest_mismatch', 'catalog_not_installable') else 503 \
                    if exc.code in ('catalog_unavailable', 'stage_unavailable') else 500
                self._json(status, {'ok': False, 'error': exc.code})
                return
            self._owner_update_launch(
                'install', app_id, response_action='install-company', lock_held=True,
                approved_digest=entry['tree_digest'], package_path=canonical_path,
                reapprove=reapprove)

    def _owner_app_action_locked(self, app_id, action, body=None):
        cfg = UPDATE_EXEC_CONFIG
        updates = UPDATES.read_snapshot() if UPDATES is not None else None
        try:
            if action in ('register', 'reapprove'):
                package_path = body.get('path') if isinstance(body, dict) else None
                approved_digest = body.get('digest') if isinstance(body, dict) else None
                if (not isinstance(package_path, str) or not package_path.strip()
                        or not isinstance(approved_digest, str)
                        or re.fullmatch(r'[0-9a-f]{64}', approved_digest) is None):
                    self._json(400, {'ok': False, 'error': 'bad_package_approval'})
                    return
                preview = APPS.package_preview(cfg['root'], package_path)
                if preview.get('id') != app_id or preview.get('digest') != approved_digest:
                    self._json(409, {'ok': False, 'error': 'package_preview_changed'})
                    return
                if preview.get('installable') is not True:
                    self._json(409, {
                        'ok': False, 'error': 'package_not_installable',
                        'rejected_capabilities': preview.get('rejected_capabilities') or [],
                        'conflict': preview.get('conflict'),
                    })
                    return
                config = APPS.config_path(cfg['root'])
                canonical_path = str(Path(preview['path']).resolve())
                if action == 'register':
                    if preview.get('registered'):
                        self._json(409, {'ok': False, 'error': 'package_already_registered'})
                        return
                    reapprove = preview.get('requires_reapproval') is True
                    registration = {
                        'path': canonical_path,
                        'grant': preview.get('grants') or [],
                    }
                    if reapprove:
                        APPS.register(config, app_id, registration,
                                      approved_digest=approved_digest)
                    else:
                        APPS.register(config, app_id, registration)
                else:
                    if APPS.registered_package_path(config, app_id) != Path(canonical_path):
                        self._json(409, {'ok': False, 'error': 'package_path_changed'})
                        return
                    if preview.get('requires_reapproval') is not True:
                        self._json(409, {'ok': False, 'error': 'reapproval_not_required'})
                        return
                    reapprove = True
                self._owner_update_launch(
                    'install', app_id, response_action=action, lock_held=True,
                    approved_digest=approved_digest, package_path=canonical_path,
                    reapprove=reapprove)
                return

            projection = APPS.list_apps(cfg['root'], updates)
            installed = {row['id']: row for row in projection['installed']}
            public = {row['id']: row for row in projection['public']}
            if action == 'enable':
                if app_id not in installed and app_id not in public:
                    self._json(404, {'ok': False, 'error': 'app_not_found'})
                    return
                if app_id not in installed:
                    config = APPS.config_path(cfg['root'])
                    APPS.register(config, app_id)
            else:
                row = installed.get(app_id)
                if app_id == 'hub' or app_id in projection['apps'] and row is None:
                    self._json(409, {'ok': False, 'error': 'app_locked'})
                    return
                # Reconcile cannot remove a recorded package without its optional
                # deactivator.  Refuse before changing config; the UI also disables
                # the destructive control, but presentation is not the boundary.
                if row is not None and not row.get('canRemove'):
                    error = ('disable_unavailable' if action == 'disable'
                             else 'remove_unavailable')
                    self._json(409, {'ok': False, 'error': error})
                    return
                if row is not None:
                    config = APPS.config_path(cfg['root'])
                    APPS.mutate_enabled(config, app_id, False)
        except APPS.AppsError as exc:
            sys.stderr.write(f'[apps] {action} failed for {app_id!r} '
                             f'({exc.code}): {exc.detail}\n')
            if exc.code in ('bad_app_id', 'bad_package_path', 'bad_package_registration',
                            'bad_package_grants', 'bad_package_approval',
                            'config_invalid', 'config_unsupported'):
                status = 400
            elif exc.code in ('config_conflict', 'app_already_registered',
                              'package_already_registered', 'package_not_registered'):
                status = 409
            else:
                status = 500
            self._json(status, {'ok': False, 'error': exc.code})
            return
        # Current installer reconcile removes the committed artifacts, including
        # units, for every canRemove app.  `teardown` remains a closed runner action
        # for an explicit future caller; remove must not run it as well and double-act.
        self._owner_update_launch('install', app_id, response_action=action, lock_held=True)

    @staticmethod
    def _fail_update_record(cfg, run_id, outcome):
        """Close out a run that never got a window, so nothing waits on the grace timer."""
        record = UPDATE_EXEC.read_record(cfg['dir'])
        if not record or record.get('runId') != run_id:
            return                      # superseded already; not ours to rewrite
        record['status'] = 'failed'
        record['endedAt'] = UPDATE_EXEC.now_iso()
        record['note'] = ('실행 창을 만들지 못했습니다 (%s) — tmux 가 설치돼 있는지 '
                          '확인하십시오. 아무것도 실행되지 않았습니다.' % outcome
                          if outcome == 'nowindow' else
                          '실행 창 생성 결과를 확인하지 못했습니다 (%s) — 터미널에서 '
                          'tmux 세션을 확인하십시오.' % outcome)
        try:
            UPDATE_EXEC.write_record(cfg['dir'], record)
        except OSError as exc:
            sys.stderr.write(f'[update-exec] failure record write failed: {exc}\n')

    # ---- harness section (same owner gate, its own run record) ----
    def _owner_harness_run(self):
        """Report the last harness upgrade run.

        No `busy` field, and its absence is the point: unlike `bin/airlock-update` an
        npm global install takes no cross-process mutex, so there is no second updater
        to measure and nothing to claim about one.
        """
        if HARNESS is None or HARNESS_EXEC_CONFIG is None:
            self._json(404, {'ok': False, 'error': 'harness execution not enabled'})
            return
        cfg = HARNESS_EXEC_CONFIG
        self._json(200, {'ok': True,
                         'run': HARNESS.observed(HARNESS.read_record(cfg['dir']))})

    def _start_detection(self):
        """Ask the existing detection oneshot to measure again, now.

        `--no-block`, because a collection runs `airlock-update --dry-run`, an
        `npm view` and the hook check: a blocking start would hold this request open
        for a minute and the browser would call that a failure. The panel watches
        `checkedAt` in the snapshot instead, which is the fact it actually needs.

        One hardcoded unit name, not a caller-supplied one: this is the same collector
        the timer runs, and a route that could start an arbitrary unit would be a
        different feature with a different gate.
        """
        try:
            subprocess.check_call(
                ['systemctl', '--user', 'start', '--no-block', '--',
                 UPDATE_DETECT_UNIT], timeout=10,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            self._json(504, {'ok': False, 'error': 'recheck_timeout'})
            return
        except (OSError, subprocess.CalledProcessError):
            # Overwhelmingly "the timer was never installed on this box", which is a
            # real state (install/airlock-update-timer.sh is a separate step) and not
            # something the panel should retry into.
            self._json(409, {'ok': False, 'error': 'recheck_unavailable'})
            return
        self._json(200, {'ok': True, 'action': 'recheck', 'unit': UPDATE_DETECT_UNIT})

    def _owner_harness_execute(self, body):
        """Validate a closed enum, then either re-measure or launch the one upgrade."""
        action = body.get('action') if isinstance(body, dict) else None
        if action == 'recheck':
            if UPDATES is None:
                self._json(404, {'ok': False, 'error': 'update detection not enabled'})
                return
            self._start_detection()
            return
        if action not in (HARNESS.ACTIONS if HARNESS else ()):
            self._json(400, {'ok': False, 'error': 'bad_action'})
            return
        cfg = HARNESS_EXEC_CONFIG
        if cfg is None:
            self._json(404, {'ok': False, 'error': 'harness execution not enabled'})
            return
        with _HARNESS_RUN_LOCK:
            record = HARNESS.observed(HARNESS.read_record(cfg['dir']))
            if HARNESS.active(record):
                self._json(409, {'ok': False, 'error': 'run_active',
                                 'run_id': record.get('runId')})
                return
            run_id = UPDATE_EXEC.new_run_id()
            try:
                UPDATE_EXEC.ensure_dirs(cfg['dir'])
                UPDATE_EXEC.sweep_plans(cfg['dir'])
                # Written BEFORE the window exists so a click is never invisible.
                UPDATE_EXEC.write_record(cfg['dir'], HARNESS.start_record(run_id, action))
            except OSError as exc:
                sys.stderr.write(f'[harness-exec] run record write failed: {exc}\n')
                self._json(500, {'ok': False, 'error': 'state_unwritable'})
                return
            plan = HARNESS.build_plan(cfg['root'], cfg['dir'], run_id, action)
            outcome, _target = _launch_run(run_id, plan, cfg, run_id)
        if outcome != 'ok':
            self._fail_harness_record(cfg, run_id, outcome)
            self._json(503 if outcome == 'ambiguous' else 500,
                       {'ok': False, 'error': 'launch_failed', 'outcome': outcome})
            return
        self._json(200, {'ok': True, 'run_id': run_id, 'action': action})

    @staticmethod
    def _fail_harness_record(cfg, run_id, outcome):
        """Close out a run that never got a window, so nothing waits on the grace timer."""
        record = UPDATE_EXEC.read_record(cfg['dir'])
        if not record or record.get('runId') != run_id:
            return                      # superseded already; not ours to rewrite
        record['status'] = 'failed'
        record['endedAt'] = UPDATE_EXEC.now_iso()
        record['note'] = ('실행 창을 만들지 못했습니다 (%s) — tmux 가 설치돼 있는지 '
                          '확인하십시오. 아무것도 실행되지 않았습니다.' % outcome
                          if outcome == 'nowindow' else
                          '실행 창 생성 결과를 확인하지 못했습니다 (%s) — 터미널에서 '
                          'tmux 세션을 확인하십시오.' % outcome)
        try:
            UPDATE_EXEC.write_record(cfg['dir'], record)
        except OSError as exc:
            sys.stderr.write(f'[harness-exec] failure record write failed: {exc}\n')

    def _owner_run(self, body):
        card_id = body.get('card_id') if isinstance(body, dict) else None
        if not isinstance(card_id, str):
            self._json(400, {'ok': False, 'error': 'card_id required'})
            return
        card = MSG.get_card(card_id)
        if not card or not card['run']:
            self._json(404, {'ok': False, 'error': 'run not found'})
            return
        try:
            prompt, ran_input = _compose_message_input(
                card, body.get('params', {}), body.get('note', ''))
        except ValueError as error:
            self._json(400, {'ok': False, 'error': str(error)})
            return
        try:
            target = _launch_message(card, EXEC_CONFIG, prompt)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            sys.stderr.write('[message-run] launch failed: %s\n' % type(error).__name__)
            self._json(502, {'ok': False, 'error': 'launch_failed'})
            return
        window = _win_id(target)
        ran_at = MSG.mark_ran(card_id, ran_input, window)
        self._json(200, {'ok': True, 'card_id': card_id, 'target': target,
                         'window': window, 'session': EXEC_CONFIG['session'],
                         'ran_at': ran_at})

    def _owner_run_window(self, body):
        card_id = body.get('card_id') if isinstance(body, dict) else None
        if not isinstance(card_id, str):
            self._json(400, {'ok': False, 'error': 'card_id required'})
            return
        card = MSG.get_card(card_id)
        window = card.get('ran_window') if card else None
        if not isinstance(window, str) or not re.fullmatch(r'@[0-9]+\Z', window):
            self._json(404, {'ok': False, 'error': 'run window not found'})
            return
        with _TMUX_LOCK:
            active = _tmux('select-window', '-t', window) is not None
        self._json(200, {'ok': True, 'card_id': card_id,
                         'state': 'active' if active else 'ended',
                         'window': window,
                         'session': EXEC_CONFIG['session'] if EXEC_CONFIG else None})

    def log_message(self, fmt, *args):
        sys.stderr.write(f'[airlock-dev-monitor] {self.address_string()} - {fmt % args}\n')


# ---- action execution orchestration ----
def _tmux(*args, capture=False, timeout=8):
    """Run tmux, returning output on capture and None when the result is unknown."""
    try:
        if capture:
            return subprocess.check_output(
                ['tmux'] + list(args), text=True, timeout=timeout,
                stderr=subprocess.DEVNULL).strip()
        subprocess.check_call(
            ['tmux'] + list(args), timeout=timeout,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return ''
    except Exception:
        return None


def _win_id(target):
    """Extract the tmux window id from a generation-aware target."""
    return target.rsplit(':', 1)[-1] if target else target


def _tmux_has_session(name):
    """1 = definitely absent, 0 = present, None = tmux could not be asked at all.

    Kept separate from _tmux because the distinction between "no such session" (exit 1,
    a real answer) and "there is no tmux on this box" matters: the first means reap it,
    the second must not be read as reap-everything. Never raises — an action console on
    a box without tmux degrades to refusing to run things, not to 500s.
    """
    try:
        return subprocess.call(['tmux', 'has-session', '-t', name],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               timeout=8)
    except Exception:  # noqa: BLE001 — missing binary, timeout, permission: all "unknown"
        return None


def _launch_run(run_id, plan, cfg=None, window_name=None):
    """Persist a plan then launch its runner in a new tmux window.

    `cfg`/`window_name` are parameters rather than globals because two features launch
    runs now — approved action cards and the settings panel's update button — and they
    keep different state directories. Everything below (the tmux absence check, the
    exclusive plan write, the ambiguity contract) is identical for both, so it is one
    function with two callers rather than two copies to keep in step.
    """
    cfg = cfg or EXEC_CONFIG
    # Checked before anything is written: with no tmux there is no window and nothing
    # started, which is a DEFINITE answer, not an ambiguous one. Saying so lets the
    # caller release the card lock instead of holding it for a run that cannot exist.
    if shutil.which('tmux') is None:
        sys.stderr.write('[exec] tmux is not installed — approved actions cannot run '
                         '(install tmux, or set messages = false)\n')
        return ('nowindow', None)
    plan_out = dict(plan)
    plan_out['cwd_root'] = cfg['cwd_root']
    plan_out['agent'] = cfg['agent']            # server-controlled, like cwd_root — never from the card
    plan_file = os.path.join(cfg['plan_dir'], run_id + '.json')
    try:
        fd = os.open(plan_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as f:
            json.dump(plan_out, f, ensure_ascii=False)
    except OSError as exc:
        sys.stderr.write(f'[exec] plan write failed: {exc}\n')
        return ('nowindow', None)
    command = ' '.join(shlex.quote(item) for item in [
        'python3', cfg['runner'], run_id, plan_file, cfg['sentinel_dir'],
    ])
    window_name = window_name or ('exec-' + run_id.split('-')[-1])
    session, cwd = cfg['session'], plan['cwd']
    with _TMUX_LOCK:
        has_session = _tmux_has_session(session) == 0
        if has_session:
            target = _tmux(
                'new-window', '-t', session + ':', '-n', window_name, '-c', cwd,
                '-P', '-F', '#{pid}:#{window_id}', command, capture=True)
        else:
            target = _tmux(
                'new-session', '-d', '-s', session, '-n', window_name, '-c', cwd,
                '-P', '-F', '#{pid}:#{window_id}', command, capture=True)
    if not target:
        return ('ambiguous', None)
    _tmux('setw', '-t', _win_id(target), 'window-size', 'largest')
    return ('ok', target)


def _build_exec_config():
    return {
        'cwd_root': os.environ.get('DEV_MONITOR_CWD_ROOT') or HOME,
        'session': os.environ.get('DEV_MONITOR_EXEC_SESSION', 'devmon-exec'),
        'agent': {'provider': os.environ.get('AIRLOCK_AGENT_PROVIDER', ''),
                  'select_bin': os.environ.get('AIRLOCK_AGENT_BIN', '')},
        'runner': os.path.join(os.path.dirname(os.path.abspath(__file__)), 'action_runner.py'),
    }


def _compose_message_input(card, supplied, note):
    """Apply the stored declaration and compose the one immutable prompt argv."""
    if not isinstance(supplied, dict):
        raise ValueError('params must be an object')
    if not isinstance(note, str) or len(note) > MAX_OWNER_NOTE:
        raise ValueError('note must be a string of at most 8000 characters')
    declared = card['run'].get('params', [])
    by_key = {item['key']: item for item in declared}
    if set(supplied) - set(by_key):
        raise ValueError('undeclared param')
    values = {}
    for key, item in by_key.items():
        if key in supplied:
            value = supplied[key]
            if not isinstance(value, str):
                raise ValueError('param values must be strings')
        elif 'default' in item:
            value = item['default']
        elif 'choices' in item:
            raise ValueError('choice param requires a value')
        else:
            value = ''
        if len(value) > MAX_OWNER_PARAM:
            raise ValueError('param value is too long')
        if 'choices' in item and value not in item['choices']:
            raise ValueError('param value is not an allowed choice')
        values[key] = value
    canonical_params = json.dumps(
        values, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
    prompt = card['run']['prompt']
    if card['count'] > 1:
        prompt += '\n\nMessage context: last_at=%s count=%s' % (
            card['last_at'], card['count'])
    if declared:
        prompt += '\n\nParameters: ' + canonical_params
    if note:
        prompt += '\n\nOwner note:\n' + note
    ran_input = json.dumps({'note': note, 'params': values}, ensure_ascii=False,
                           sort_keys=True, separators=(',', ':'))
    return prompt, ran_input


def _launch_message(card, cfg, prompt=None):
    run = card['run']
    cwd = os.path.realpath(os.path.expanduser(run['cwd']))
    root = os.path.realpath(os.path.expanduser(cfg['cwd_root']))
    if not os.path.isdir(cwd) or not cwd.startswith(root + os.sep):
        raise ValueError('cwd outside allowed root or missing')
    if prompt is None:
        prompt, _unused = _compose_message_input(card, {}, '')
    agent = action_runner.resolve_agent(cfg.get('agent'))
    agent['binary'] = action_runner.resolve_exe(
        action_runner.build_argv({'prompt': prompt}, agent), action_runner.runtime_env())
    # Multiple shell-command arguments make tmux exec them directly. The prompt is
    # one argv element here and one argv element again when the runner calls the CLI.
    command = [sys.executable, cfg['runner'], '--message', root, prompt, json.dumps(agent)]
    session = cfg['session']
    def tmux_arg(value):
        # tmux parses a terminal semicolon even in argv form. One extra backslash
        # quotes it for that parser; tmux removes exactly that extra backslash.
        return value[:-1] + '\\;' if value.endswith(';') else value

    def message_tmux(*args, **kwargs):
        return _tmux(*(tmux_arg(value) for value in args), **kwargs)

    with _TMUX_LOCK:
        if _tmux_has_session(tmux_arg(session)) != 0:
            if message_tmux('new-session', '-d', '-s', session) is None:
                raise OSError('cannot create execution session')
        target = message_tmux('new-window', '-d', '-t', session + ':', '-n', 'message', '-c', cwd,
                              '-P', '-F', '#{pid}:#{window_id}', *command, capture=True)
    if not target:
        raise OSError('cannot create execution window')
    return target


def _messages_state():
    return _MESSAGES_STATE


def _message_delivery_health():
    if _MESSAGES_STATE != 'on' or OWNER_CONFIG is None:
        return {'pending_count': 0, 'last_sent_at': None, 'failed_count': 0}
    return MSG.delivery_health()


def _slack_webhooks():
    return slack_webhooks(os.environ)


def _start_messages():
    """Start the optional message/action console while preserving observability on failure."""
    global OWNER_CONFIG, EXEC_CONFIG, _MESSAGES_STATE, _SLACK_WORKER_ON
    _SLACK_WORKER_ON = False
    if not MESSAGES_REQUESTED:
        return
    if not _MESSAGES_AVAILABLE:
        print('[airlock-dev-monitor] message/action modules unavailable; observability only',
              flush=True)
        return
    try:
        OWNER_CONFIG = devmon_owner.load_config()
    except devmon_owner.ConfigError as exc:
        # A partial owner gate must never expose routes, but must not stop monitoring.
        sys.stderr.write(f'[airlock-dev-monitor] messages disabled: {exc}\n')
        return
    if OWNER_CONFIG is None:
        # Requested in airlock.toml but not configured at all. The installer writes the
        # env file whenever messages = true, so reaching here means it is missing or
        # unreadable — say so, or the console silently never appears.
        print('[airlock-dev-monitor] messages requested but no owner gate is configured '
              '(DEV_MONITOR_OWNER/PROXY_SECRET/SPOOL/DB all unset) — observability only',
              flush=True)
        return
    # Validate the spool before starting the loop; a daemon failure must not leave health
    # messages=on — especially if startup chmod drift broke the cross-UID boundary.
    try:
        devmon_spool.ensure_dirs(OWNER_CONFIG['spool'])
    except Exception as exc:  # noqa: BLE001 — preserve observability, name the failed axis
        OWNER_CONFIG = None
        EXEC_CONFIG = None
        _MESSAGES_STATE = 'off: spool'
        sys.stderr.write(
            f'[airlock-dev-monitor] messages spool failed '
            f'({exc.__class__.__name__}: {exc}) — observability only\n')
        return
    # Schema failures need their own named state: they otherwise look exactly like a
    # deliberately disabled optional console in health and the startup banner.
    try:
        MSG.init_db(OWNER_CONFIG['db'])
    except Exception as exc:  # noqa: BLE001 — preserve observability, but name the axis
        OWNER_CONFIG = None
        EXEC_CONFIG = None
        _MESSAGES_STATE = 'off: schema'
        sys.stderr.write(
            f'[airlock-dev-monitor] messages schema failed '
            f'({exc.__class__.__name__}: {exc}) — observability only\n')
        return
    webhook = _slack_webhooks()['slack-urgent']
    console_url = os.environ.get('AIRLOCK_DEVMON_CONSOLE_URL', '').strip()
    stop = None
    # From here on, anything that fails is a generic failure of the OPTIONAL half: an
    # unwritable execution directory or a thread that cannot start. None of it is a
    # reason to take observability down, and systemd would restart-loop us if it escaped.
    try:
        EXEC_CONFIG = _build_exec_config()
        stop = threading.Event()
        _SLACK_WORKER_ON = bool(webhook)
        # The cron card's prior-verdict file lives next to the message DB — same state
        # directory, same lifetime, no new axis to provision or clean up.
        verdicts_path = os.path.join(os.path.dirname(OWNER_CONFIG['db']), 'cron-verdicts.json')
        threading.Thread(target=devmon_loop.run,
                         args=(OWNER_CONFIG['spool'],webhook,stop,console_url,verdicts_path),
                         daemon=True,name='loop').start()
    except Exception as exc:  # noqa: BLE001 — an optional feature must not kill the monitor
        if stop is not None:
            stop.set()
        OWNER_CONFIG = None
        EXEC_CONFIG = None
        _MESSAGES_STATE = 'off'
        _SLACK_WORKER_ON = False
        sys.stderr.write(f'[airlock-dev-monitor] messages failed to start ({exc.__class__.__name__}: '
                         f'{exc}) — observability only\n')
        return
    _MESSAGES_STATE = 'on'
    print(f"[airlock-dev-monitor] messages feature: on slack={_SLACK_WORKER_ON}", flush=True)



def _start_updates_owner_gate():
    """Load the minimal ingress gate independently of the message spool feature."""
    global UPDATES_OWNER_CONFIG
    if UPDATES is None or devmon_owner is None:
        return
    try:
        UPDATES_OWNER_CONFIG = devmon_owner.load_gate_config()
    except devmon_owner.ConfigError as exc:
        sys.stderr.write(f'[airlock-dev-monitor] updates owner gate disabled: {exc}\n')


def _start_update_exec():
    """Resolve where update runs keep their state. Never fatal.

    Split from the gate above so the two failures stay distinguishable: a box can have
    a working owner gate and an unwritable state directory, and in that case the panel
    must still show what is available to update — it just cannot start one.
    """
    global UPDATE_EXEC_CONFIG
    if UPDATE_EXEC is None or UPDATES_OWNER_CONFIG is None:
        return
    try:
        root = UPDATE_EXEC.default_root()
        directory = UPDATE_EXEC.default_dir()
        UPDATE_EXEC.ensure_dirs(directory)
    except OSError as exc:
        sys.stderr.write('[airlock-dev-monitor] update execution disabled '
                         f'(state directory unusable: {exc})\n')
        return
    UPDATE_EXEC_CONFIG = {
        'root': root,
        'dir': directory,
        # The runner's own contract: it needs a plan file, a sentinel directory and a
        # place to be. It shares the action console's tmux session name so there is one
        # session to attach to, whether or not that console is enabled.
        'plan_dir': str(UPDATE_EXEC.plan_dir(directory)),
        'sentinel_dir': str(UPDATE_EXEC.sentinel_dir(directory)),
        'session': os.environ.get('DEV_MONITOR_EXEC_SESSION', 'devmon-exec'),
        'runner': os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               'action_runner.py'),
        # exec mode reaches neither: the plan carries an absolute argv and its own root.
        'cwd_root': str(root),
        'agent': {},
    }


def _start_harness_exec():
    """Resolve where harness runs keep their state. Never fatal, like update exec.

    Split from _start_update_exec for the reason the two records are split: a box can
    run platform updates from the panel and still have no way to upgrade the Codex CLI
    (or the other way around), and the panel has to be able to say which.
    """
    global HARNESS_EXEC_CONFIG
    if HARNESS is None or UPDATE_EXEC is None or UPDATES_OWNER_CONFIG is None:
        return
    try:
        root = UPDATE_EXEC.default_root()
        directory = HARNESS.default_dir()
        UPDATE_EXEC.ensure_dirs(directory)
    except OSError as exc:
        sys.stderr.write('[airlock-dev-monitor] harness execution disabled '
                         f'(state directory unusable: {exc})\n')
        return
    HARNESS_EXEC_CONFIG = {
        'root': root,
        'dir': directory,
        'plan_dir': str(UPDATE_EXEC.plan_dir(directory)),
        'sentinel_dir': str(UPDATE_EXEC.sentinel_dir(directory)),
        # The same tmux session as the other two runners: one session to attach to.
        'session': os.environ.get('DEV_MONITOR_EXEC_SESSION', 'devmon-exec'),
        'runner': os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               'action_runner.py'),
        'cwd_root': str(root),
        'agent': {},
    }


def main():
    os.makedirs(_STATE_DIR, exist_ok=True)
    # first sampling — the next call onward is accurate
    cpu_info()
    history_trim()
    threading.Thread(target=history_sampler, daemon=True, name='history_sampler').start()
    threading.Thread(target=_top_sampler, daemon=True, name='top_sampler').start()
    _start_updates_owner_gate()
    _start_update_exec()
    _start_harness_exec()
    _start_messages()
    print(f'[airlock-dev-monitor] listen=127.0.0.1:{PORT} messages={_messages_state()} '
          f'delivery={json.dumps(_message_delivery_health(), sort_keys=True)}', flush=True)
    with ThreadingHTTPServer(('127.0.0.1', PORT), Handler) as server:
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == '__main__':
    main()
