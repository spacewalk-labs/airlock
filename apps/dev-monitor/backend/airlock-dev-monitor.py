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

# The owner ingress gate is smaller than the optional message/action console: update
# detection needs it even on a box that intentionally has no message spool.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
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
    import devmon_email
    import action_runner
    _MESSAGES_AVAILABLE = devmon_owner is not None
except ImportError:
    MSG = None
    devmon_spool = None
    devmon_slack = None
    devmon_email = None
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
# Origins that count as "this box, another port" for the unread badge. The installer
# measures the tailnet FQDN and passes it; without it we still know our own hostname,
# so the badge keeps working from a short-name origin and nothing else is admitted.
CORS_HOSTS = frozenset(
    h.strip().lower()
    for h in ([socket.gethostname(), socket.gethostname().split('.')[0]]
              + os.environ.get('AIRLOCK_DEV_MONITOR_CORS_HOSTS', '').split(','))
    if h.strip()
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
# The two lanes with a liveness probe and a watchdog. Email is deliberately not one of them:
# a probe proves a lane by sending through it, and a mail probe on a timer is a scheduled
# message to a person's inbox saying nothing. Its health comes from the ledger alone.
MESSAGE_LANES = ('slack-urgent', 'slack-routine')
# Every lane the settings screen shows, which is the routing table's set rather than the
# probe's. A lane missing from this list is a lane whose silence nobody sees.
HEALTH_LANES = MESSAGE_LANES + ('email',)
# Per-lane wording, because the remedy differs: a Slack lane needs a webhook and the email
# lane needs an SMTP transport. A screen that says "no webhook configured" under 이메일 sends
# the operator looking for the wrong thing.
_LANE_UNCONFIGURED = {
    'slack-urgent': 'off: no webhook configured',
    'slack-routine': 'off: no webhook configured',
    'email': 'off: no transport configured',
}
_MESSAGE_LANE_WORKER_STATES = dict(_LANE_UNCONFIGURED)
_TMUX_LOCK = threading.Lock()
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
        """The request Origin if it is *this box on another port*, else None.

        Why this exists: the Airlock return widget is injected into tools that run on
        their own ports, and it reads the owner message preview from here to draw the
        unread badge. Without an echoed ACAO that fetch fails silently and the badge
        simply never appears — which reads as "no unread messages".

        The comparison is against a WHOLE hostname, never a label. An earlier version
        compared only the first label, which let `<boxname>.attacker.example` pass: the
        identity here is injected by the ingress, so any origin we echo can read owner
        data with the owner's own authority — ambient authority, even though the request
        carries no cookie. CORS_HOSTS is the exact set the installer measured (short name
        and tailnet FQDN); nothing else is same-box.
        """
        origin = self.headers.get('Origin') or ''
        if not origin:
            return None
        try:
            h = (urllib.parse.urlsplit(origin).hostname or '').lower()
        except ValueError:
            return None
        return origin if h and h in CORS_HOSTS else None

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
                             'message_lanes': _message_lanes_health(),
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

    def _owner_ready(self):
        """Return 404 when messages are disabled; otherwise require the owner gate."""
        if OWNER_CONFIG is None:
            self._json(404, {'ok': False, 'error': 'messages feature not enabled'})
            return False
        return devmon_owner.require_owner(self, OWNER_CONFIG)

    def _updates_owner_ready(self):
        """Updates keep their owner gate when messages are deliberately off."""
        if UPDATES_OWNER_CONFIG is None:
            self._json(404, {'ok': False, 'error': 'update detection owner gate not enabled'})
            return False
        return devmon_owner.require_owner(self, UPDATES_OWNER_CONFIG)

    def _handle_owner_get(self, path, qs):
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
        if not self._owner_ready():
            return
        if path == '/api/owner/messages/preview':
            # The one route a separate-port tool reads cross-origin: the return widget's
            # unread badge. Everything else stays same-origin only.
            self._json(200, MSG.preview(), cors=True)
            return
        if path == '/api/owner/messages':
            scope = qs.get('scope', ['active'])[0]
            if scope not in ('active', 'archived', 'all'):
                scope = 'active'
            self._json(200, MSG.feed(scope))
            return
        if path == '/api/owner/runs':
            card_id = qs.get('card_id', [None])[0]
            self._json(200, MSG.list_runs(card_id))
            return
        if path.startswith('/api/owner/runs/'):
            parts = path.split('/')
            if len(parts) == 5 and parts[4]:
                run = MSG.get_run(self._seg(parts[4]))
                self._json(200 if run else 404, run or {'ok': False, 'error': 'not_found'})
                return
        self._json(404, {'ok': False, 'error': f'unknown owner path: {path}'})

    # Every one of these answers 404 when the card refuses the transition, which is the same
    # answer an unknown card already gives. The task actions refuse on a card that does not
    # declare action, so "complete" is not reachable on a record even by hand-made request.
    _CARD_ACTIONS = {
        'read': lambda cid: MSG.mark_read(cid),
        'pin': lambda cid: MSG.set_pin(cid, True),
        'unpin': lambda cid: MSG.set_pin(cid, False),
        'archive': lambda cid: MSG.archive(cid),
        'dismiss': lambda cid: MSG.dismiss(cid),
        'undismiss': lambda cid: MSG.undismiss(cid),
        'start': lambda cid: MSG.start_task(cid),
        'complete': lambda cid: MSG.complete_task(cid),
        'reopen': lambda cid: MSG.reopen_task(cid),
        'snooze': lambda cid: MSG.snooze_task(cid),
        'unsnooze': lambda cid: MSG.unsnooze_task(cid),
        'not_task': lambda cid: MSG.not_task(cid),
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
        if not self._owner_ready():
            return
        body = self._read_body()
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
            if action == 'plan':
                self._owner_plan(card_id)
                return
            if action == 'execute':
                self._owner_execute(card_id, body)
                return
            fn = self._CARD_ACTIONS.get(action)
            if fn is not None:
                ok = fn(card_id)
                self._json(200 if ok else 404, {
                    'ok': ok,
                    'card_id': card_id,
                    'action': action,
                    # unread_count stays for the widget that has not been changed yet.
                    'unread_count': MSG.unread_count(),
                    'needs_action_count': MSG.needs_action_count(),
                })
                return
        if len(parts) == 6 and parts[:4] == ['', 'api', 'owner', 'runs']:
            if parts[5] == 'keep':
                self._owner_keep(self._seg(parts[4]))
                return
            if parts[5] == 'stop':
                self._owner_stop(self._seg(parts[4]))
                return
            if parts[5] == 'view':
                self._owner_view(self._seg(parts[4]))
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
        with _UPDATE_RUN_LOCK:
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
            plan = UPDATE_EXEC.build_plan(cfg['root'], cfg['dir'], run_id, action, app_id)
            outcome, _target = _launch_run(run_id, plan, cfg, run_id)
        if outcome != 'ok':
            self._fail_update_record(cfg, run_id, outcome)
            self._json(503 if outcome == 'ambiguous' else 500,
                       {'ok': False, 'error': 'launch_failed', 'outcome': outcome})
            return
        self._json(200, {'ok': True, 'run_id': run_id, 'action': action, 'id': app_id})

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

    def _owner_plan(self, card_id):
        res = MSG.issue_approval(card_id, EXEC_CONFIG)
        if res['ok']:
            self._json(200, res)
            return
        code = res['error']
        status = 404 if code == 'card_not_found' else 409 if code == 'run_active' else 422
        self._json(status, res)

    def _owner_execute(self, card_id, body):
        nonce = body.get('nonce') if isinstance(body, dict) else None
        res = MSG.redeem_approval(card_id, nonce, EXEC_CONFIG)
        if not res['ok']:
            code = res['error']
            status = 409 if code in ('plan_stale', 'nonce_used', 'expired', 'run_active', 'no_nonce') \
                else 404 if code in ('no_approval', 'card_not_found') else 400
            self._json(status, {'ok': False, 'error': code})
            return
        run_id = res['run_id']
        outcome, target = _launch_run(run_id, res['plan'])
        if outcome == 'nowindow':
            MSG.run_fail(run_id, 'launch failed before window')
            self._json(500, {'ok': False, 'error': 'launch_failed'})
            return
        if outcome == 'ambiguous':
            # The window may exist, so retain the card lock to prevent a duplicate run.
            sys.stderr.write(f'[exec] tmux launch ambiguous run={run_id}; retaining card lock\n')
            self._json(503, {'ok': False, 'error': 'launch_uncertain', 'run_id': run_id})
            return
        if not MSG.run_mark_running(run_id, target):
            if _tmux('kill-window', '-t', _win_id(target)) is None:
                sys.stderr.write(f'[exec] orphan window kill failed run={run_id} target={target}\n')
                self._json(500, {'ok': False, 'error': 'orphan_kill_failed', 'target': target})
            else:
                self._json(409, {'ok': False, 'error': 'run_superseded'})
            return
        self._json(200, {'ok': True, 'run_id': run_id, 'session': EXEC_CONFIG['session']})

    _VIEW_ERR_STATUS = {
        'not_found': 404,
        'not_active': 409,
        'launching': 409,
        'stale_target_format': 409,
        'stale_generation': 409,
        'tmux_unavailable': 502,
    }

    def _owner_view(self, run_id):
        """Create a view session only after generation-aware target validation."""
        session = EXEC_CONFIG['session']
        ok, res = MSG.run_view_request(MSG.get_run(run_id), _exec_alive_keys(session), session)
        if not ok:
            self._json(self._VIEW_ERR_STATUS.get(res, 409), {'ok': False, 'error': res})
            return
        if not _ensure_view_session(res['view'], session, res['window_id']):
            self._json(502, {'ok': False, 'error': 'view_create_failed'})
            return
        # Recheck after session creation so a restarted tmux server cannot redirect a view.
        ok2, res2 = MSG.run_view_request(MSG.get_run(run_id), _exec_alive_keys(session), session)
        if not ok2 or res2['target'] != res['target']:
            if _tmux('kill-session', '-t', res['view']) is None:
                sys.stderr.write(f"[view] stale view kill failed view={res['view']}\n")
            self._json(409, {'ok': False, 'error': 'stale_generation'})
            return
        self._json(200, {
            'ok': True,
            'arg': res['view'],
            'window_id': res['window_id'],
            'run_id': run_id,
        })

    def _owner_stop(self, run_id):
        run = MSG.get_run(run_id)
        if not run or run['status'] not in ('starting', 'running'):
            self._json(404, {'ok': False, 'error': 'not_active'})
            return
        target = run.get('tmux_target')
        if not target:
            # Do not release the lock while a launch may still create a window.
            self._json(409, {'ok': False, 'error': 'launching', 'retry_after': 1})
            return
        if ':' not in target:
            self._json(409, {'ok': False, 'error': 'stale_target_format', 'target': target})
            return
        keys = _exec_alive_keys(EXEC_CONFIG['session'])
        if keys is None:
            self._json(502, {'ok': False, 'error': 'tmux_unavailable'})
            return
        if target in keys and _tmux('kill-window', '-t', _win_id(target)) is None:
            self._json(502, {'ok': False, 'error': 'kill_failed'})
            return
        changed, _ = MSG.run_stop(run_id)
        self._json(200 if changed else 409, {'ok': bool(changed), 'run_id': run_id})

    def _owner_keep(self, run_id):
        """Persist an owner's Keep choice under the same lock as tmux lifecycle changes."""
        with _TMUX_LOCK:
            ok, error = MSG.run_keep(run_id)
        if ok:
            self._json(200, {'ok': True, 'run_id': run_id, 'keep': True})
            return
        status = 404 if error == 'not_found' else 409
        self._json(status, {'ok': False, 'run_id': run_id, 'error': error})

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


def _exec_alive_keys(session):
    """Return current ``server_pid:window_id`` keys, or None if tmux is indeterminate."""
    out = _tmux('list-windows', '-t', session, '-F', '#{pid}:#{window_id}', capture=True)
    if out is None:
        return set() if _tmux_has_session(session) == 1 else None
    return {line.strip() for line in out.splitlines() if line.strip()}


def _ensure_view_session(view, session, window_id, tmux=None):
    """Ensure that a view session contains only the requested run window."""
    command = tmux or _tmux
    if _tmux_has_session(view) == 0:
        return True
    if command('new-session', '-d', '-s', view) is None:
        return False
    dummy = command('list-windows', '-t', view, '-F', '#{window_id}', capture=True)
    if command('link-window', '-s', f'{session}:{window_id}', '-t', view + ':') is None:
        command('kill-session', '-t', view)
        return False
    if dummy and command('kill-window', '-t', f'{view}:{dummy}') is None:
        sys.stderr.write(f'[view] dummy window kill failed view={view} dummy={dummy}\n')
    return True


def _reap_view_sessions():
    """Remove view sessions whose corresponding run is no longer active."""
    out = _tmux('list-sessions', '-F', '#{session_name}', capture=True)
    if out is None:
        return
    keep = MSG.active_view_sessions()
    for name in out.splitlines():
        name = name.strip()
        if not name.startswith(MSG.VIEW_SESSION_PREFIX) or name in keep:
            continue
        if _tmux('kill-session', '-t', name) is None:
            sys.stderr.write(f'[view] orphan view kill failed session={name}\n')


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
    window_name = window_name or MSG.run_window_name(run_id)
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


def _sentinel_watcher(stop_event, sentinel_dir):
    """Apply runner completion sentinels and remove each file after processing."""
    while not stop_event.is_set():
        try:
            for name in os.listdir(sentinel_dir):
                if not name.endswith('.done'):
                    continue
                path = os.path.join(sentinel_dir, name)
                try:
                    with open(path) as f:
                        data = json.load(f)
                    MSG.run_finish(data['run_id'], int(data.get('exit_code', 1)))
                except Exception as exc:
                    sys.stderr.write(f'[sentinel] bad {name}: {exc}\n')
                finally:
                    try:
                        os.remove(path)
                    except OSError:
                        pass
        except OSError:
            pass
        stop_event.wait(2)


def _runs_in_flight():
    """Every run currently in 'starting' or 'running' — all of them, not a page.

    devmon_messages.list_runs() exists for the UI and caps at 50 by design. The reaper
    needs completeness, not recency, so it asks the store directly. Bounded anyway: a run
    only stays in these two states while it is alive.
    """
    conn = MSG._conn()
    rows = conn.execute(
        "SELECT * FROM runs WHERE status IN ('starting','running')").fetchall()
    return [dict(r) for r in rows]


def _reap_stuck_starting(session):
    """Fail runs that were approved but never produced a window, so the card unlocks.

    devmon_messages.reap_runs deliberately leaves a run with no recorded tmux_target
    alone: ending it on a guess would orphan a live process. That is right, but it left
    no way out at all — a launch that failed after the run row was written kept its card
    showing "running" with a Stop button that answers 409, forever.

    The escape has to be proof, not a timeout. _launch_run names every window
    deterministically, so the ABSENCE of a window with that name is proof that nothing
    was started for this run. (A name collision could only make us keep the run, never
    end a live one.) The grace period exists solely so we do not race a launch that is
    still inside _TMUX_LOCK.
    """
    names = _tmux('list-windows', '-t', session, '-F', '#{window_name}', capture=True)
    if names is None:
        # Session absent = definitely no windows. tmux unreachable = we know nothing.
        if _tmux_has_session(session) != 1:
            return
        live = set()
    else:
        live = {n.strip() for n in names.splitlines() if n.strip()}
    cutoff = time.time() - STARTING_GRACE_S
    # Not list_runs(): it pages at 50, and a stuck run is by definition an OLD one. With
    # 50 newer runs on the box the escape hatch simply stopped existing.
    for run in _runs_in_flight():
        if run.get('status') != 'starting' or run.get('tmux_target'):
            continue
        created = run.get('created_at') or ''
        try:
            age_ok = datetime.strptime(created[:19], '%Y-%m-%dT%H:%M:%S').replace(
                tzinfo=timezone.utc).timestamp() < cutoff
        except ValueError:
            continue
        if not age_ok or MSG.run_window_name(run['run_id']) in live:
            continue
        MSG.run_fail(run['run_id'], 'launch never produced a window')
        sys.stderr.write(f"[reaper] released stuck run={run['run_id']} (no window was ever created)\n")


def _is_claude_run(run):
    """Return whether a run used the interactive Claude path rather than direct exec."""
    try:
        plan = json.loads(run.get('plan_json') or '{}')
    except (TypeError, ValueError):
        # A malformed historical plan must not become an immortal process/window.
        return True
    return not (isinstance(plan.get('exec'), list) and plan['exec'])


def _reap_completed_runs(alive_ids, now=None):
    """Reclaim expired Claude runs as one process/window/sentinel lifecycle.

    ``now`` is an intentionally narrow test seam so the 24-hour boundary can be asserted
    without sleeping; it is not a supported retention override or configuration knob.
    """
    if not EXEC_CONFIG or action_runner is None or alive_ids is None:
        return
    clock_now = MSG.now_utc() if now is None else now
    alive = set(alive_ids)
    for run in MSG.reclaimable_runs():
        if not _is_claude_run(run):
            continue
        try:
            ended = MSG.parse_rfc3339(run['ended_at'])
        except (TypeError, ValueError) as exc:
            sys.stderr.write(f"[reaper] cannot age run={run.get('run_id')}: {exc}\n")
            continue
        age = (clock_now - ended).total_seconds()
        if age < RUN_RETENTION_S:
            continue

        run_id = run['run_id']
        target = run.get('tmux_target')
        if target and ':' not in target:
            # A legacy @N target cannot be matched to the current tmux server generation safely.
            sys.stderr.write(f"[reaper] cannot reclaim run={run_id}: unsupported tmux target {target}\n")
            continue

        # Keep and automatic reclaim share this lock. The re-read closes the race where an
        # owner presses Keep after the candidate query but before kill-window.
        with _TMUX_LOCK:
            latest = MSG.get_run(run_id)
            if (latest is None or latest['status'] not in MSG.RUN_TERMINAL
                    or latest.get('keep') or latest.get('reclaimed_at') is not None):
                continue
            target = latest.get('tmux_target')
            if target and ':' not in target:
                sys.stderr.write(f"[reaper] cannot reclaim run={run_id}: unsupported tmux target {target}\n")
                continue

            if target and target in alive:
                if _tmux('kill-window', '-t', _win_id(target)) is None:
                    sys.stderr.write(f"[reaper] expired run={run_id} window kill failed target={target}\n")
                    continue
                window_action = 'killed'
            elif target:
                window_action = 'already absent'
            else:
                window_action = 'no target'

            failures = action_runner.cleanup_run_sentinels(
                EXEC_CONFIG['sentinel_dir'], run_id)
            if failures:
                detail = '; '.join('%s: %s' % (path, exc) for path, exc in failures)
                sys.stderr.write(f"[reaper] expired run={run_id} sentinel cleanup failed: {detail}\n")
                continue
            if not MSG.run_mark_reclaimed(run_id, reason='turn ended more than 24h ago'):
                # Keep may have won a direct caller race; leave the reason visible rather than
                # claiming that all three resources were reclaimed.
                sys.stderr.write(f"[reaper] expired run={run_id} reclaim state changed before recording\n")
                continue
            sys.stderr.write(
                f"[reaper] reclaimed expired run={run_id} reason=turn ended more than 24h ago; "
                f"process=tmux-pane window={window_action} target={target or '-'} sentinels=removed\n")


def _reap_plan_files():
    """Delete the plan file of every run that is no longer active.

    The plan is the approved cwd plus the prompt, skill or argv — the same content
    devmon_messages.sweep() takes care to drop from `approvals` after a day so it is not
    retained. Leaving a plaintext copy in plans/ forever would make that pointless.
    """
    cfg = EXEC_CONFIG
    if not cfg:
        return
    # Must be the COMPLETE set of live runs. Derived from a paged list it would omit an
    # active run and delete the plan file the runner is about to open — the approved action
    # would then fail having never run.
    active = {r['run_id'] for r in _runs_in_flight()}
    for name in os.listdir(cfg['plan_dir']):
        if not name.endswith('.json') or name[:-5] in active:
            continue
        try:
            os.remove(os.path.join(cfg['plan_dir'], name))
        except OSError as exc:
            sys.stderr.write(f'[reaper] plan cleanup failed {name}: {exc}\n')


def _reaper_loop(stop_event, session):
    """Mark missing run windows only when tmux returns a definite live-key set."""
    while not stop_event.is_set():
        try:
            keys = _exec_alive_keys(session)
            if keys is None:
                stop_event.wait(15)
                continue
            MSG.reap_runs(keys)
            _reap_view_sessions()
            _reap_stuck_starting(session)
            _reap_completed_runs(keys)
            _reap_plan_files()
        except Exception as exc:
            sys.stderr.write(f'[reaper] {exc}\n')
        stop_event.wait(15)


def _sweep_loop(stop_event):
    """Run message retention and archival maintenance without stopping the monitor."""
    while not stop_event.is_set():
        try:
            MSG.sweep()
            for lane in MESSAGE_LANES:
                MSG.maybe_enqueue_lane_probe(lane)
        except Exception as exc:
            sys.stderr.write(f'[airlock-dev-monitor] sweep error: {exc}\n')
        stop_event.wait(900)


def _lane_watchdog_once(webhooks, active_incidents=None, at=None, recovery_candidates=None):
    """Record lane incidents and best-effort crossover notices with stable recovery."""
    if active_incidents is None:
        active_incidents = MSG.active_lane_watchdog_channels()
    if recovery_candidates is None:
        recovery_candidates = {}
    observed_at = at or MSG.now_utc()
    reasons = {}
    evaluation_failed = set()
    for lane in MESSAGE_LANES:
        try:
            reasons[lane] = MSG.lane_watchdog_reason(
                lane, 'on' if webhooks.get(lane) else 'off: no webhook configured', observed_at)
        except Exception as exc:  # isolate corrupt state to its lane
            evaluation_failed.add(lane)
            recovery_candidates.pop(lane, None)
            sys.stderr.write(
                f'[airlock-dev-monitor] lane watchdog {lane} evaluation error: '
                f'{exc.__class__.__name__}: {exc}\n')
    for lane, reason in reasons.items():
        if reason is None:
            if lane in active_incidents:
                # Recovery is evidence from consecutive completed evaluations, not
                # elapsed wall time.  A busy loop or process pause therefore cannot
                # create a 15-second cliff or count unobserved time as health.
                healthy_passes = recovery_candidates.get(lane, 0) + 1
                recovery_candidates[lane] = healthy_passes
                if healthy_passes < MSG.LANE_WATCHDOG_RECOVERY_HEALTHY_PASSES:
                    continue
                try:
                    MSG.resolve_lane_watchdog(lane, observed_at)
                    active_incidents.discard(lane)
                    recovery_candidates.pop(lane, None)
                except Exception as exc:
                    sys.stderr.write(
                        f'[airlock-dev-monitor] lane watchdog {lane} recovery error: {exc}\n')
            else:
                recovery_candidates.pop(lane, None)
            continue
        recovery_candidates.pop(lane, None)
        try:
            card_id, created = MSG.record_lane_watchdog(lane, reason, observed_at)
            active_incidents.add(lane)
            other_lane = next(candidate for candidate in MESSAGE_LANES if candidate != lane)
            if webhooks.get(other_lane):
                queued = MSG.enqueue_lane_watchdog_notice(card_id, other_lane, observed_at)
                if queued and (other_lane in evaluation_failed
                               or reasons.get(other_lane) is not None):
                    sys.stderr.write(
                        f'[airlock-dev-monitor] lane watchdog {lane}={reason["state"]}; '
                        f'opposite Slack lane {other_lane} is unhealthy, '
                        'queued best-effort notice\n')
            elif created:
                sys.stderr.write(
                    f'[airlock-dev-monitor] lane watchdog {lane}={reason["state"]}; '
                    'no configured opposite Slack lane for notice\n')
        except Exception as exc:
            sys.stderr.write(
                f'[airlock-dev-monitor] lane watchdog {lane} persistence error: '
                f'{exc.__class__.__name__}: {exc}\n')
            continue
    return active_incidents


def _lane_watchdog_loop(stop_event, webhooks):
    """Evaluate every lane independently of the webhook worker threads."""
    active_incidents = None
    recovery_candidates = {}
    while not stop_event.is_set():
        try:
            if active_incidents is None:
                active_incidents = MSG.active_lane_watchdog_channels()
            _lane_watchdog_once(
                webhooks, active_incidents, recovery_candidates=recovery_candidates)
        except Exception as exc:
            sys.stderr.write(f'[airlock-dev-monitor] lane watchdog error: {exc}\n')
        stop_event.wait(5)


def _build_exec_config():
    """Build execution paths after a complete owner configuration has been loaded."""
    state_dir = os.path.dirname(OWNER_CONFIG['db'])
    plan_dir = os.path.join(state_dir, 'plans')
    sentinel_dir = os.path.join(state_dir, 'sentinels')
    for directory in (plan_dir, sentinel_dir):
        os.makedirs(directory, exist_ok=True)
        try:
            os.chmod(directory, 0o700)
        except OSError:
            pass
    return {
        # `or HOME`, not a default= — a systemd EnvironmentFile writes an empty value for
        # an unset key, and canonical_plan reads a falsy root as 'no bound at all'.
        'cwd_root': os.environ.get('DEV_MONITOR_CWD_ROOT') or HOME,
        'session': os.environ.get('DEV_MONITOR_EXEC_SESSION', 'devmon-exec'),
        # Carried to the runner through the PLAN, never the environment: a tmux window
        # inherits the tmux SERVER's env, not ours. Resolution happens there (action_runner).
        'agent': {'provider': os.environ.get('AIRLOCK_AGENT_PROVIDER', ''),
                  'select_bin': os.environ.get('AIRLOCK_AGENT_BIN', '')},
        'runner': os.path.join(os.path.dirname(os.path.abspath(__file__)), 'action_runner.py'),
        'plan_dir': plan_dir,
        'sentinel_dir': sentinel_dir,
    }


def _messages_state():
    return _MESSAGES_STATE


def _message_lanes_health():
    """Return the stable per-lane health ABI, even while messages are unavailable."""
    # 🔴 이 dict 는 `MSG.delivery_lane_health()` 가 내는 것과 **같은 키 집합**이어야 한다. 그게
    #    docstring 이 말하는 "stable ABI" 의 전부다. 2026-08-18 실측 — 여기에만
    #    `last_success_age_seconds` 가 빠져 있어서, messages 가 꺼진 설치에서는 lane 하나가 10키,
    #    켜진 설치에서는 11키였다. 소비자는 켜고 끄는 것만으로 KeyError 를 만난다
    #    (실제로 devmon_messages.py:721 이 그 키를 읽는다). 아래 시험이 두 경로의 키 집합을 맞댄다.
    idle = {
        'delivery_state': 'idle',
        'last_success_at': None,
        'last_success_age_seconds': None,
        'pending_count': 0,
        'oldest_pending_age_seconds': None,
        'last_error': None,
        'last_error_at': None,
        'consecutive_failures': 0,
        'terminal_failures_since_success': 0,
        'ledger_error_count': 0,
    }
    health = {}
    for lane in HEALTH_LANES:
        delivery = dict(idle)
        if _MESSAGES_STATE == 'on' and OWNER_CONFIG is not None:
            try:
                delivery = MSG.delivery_lane_health(lane)
            except Exception as exc:
                delivery['delivery_state'] = 'unknown'
                delivery['last_error'] = 'health evaluation failed (%s)' % exc.__class__.__name__
                sys.stderr.write(
                    f'[airlock-dev-monitor] lane health {lane} evaluation error: '
                    f'{exc.__class__.__name__}: {exc}\n')
        health[lane] = {
            'worker_state': _MESSAGE_LANE_WORKER_STATES[lane],
            **delivery,
        }
    return health


def _start_messages():
    """Start the optional message/action console while preserving observability on failure."""
    global OWNER_CONFIG, EXEC_CONFIG, _MESSAGES_STATE
    _MESSAGE_LANE_WORKER_STATES.update(_LANE_UNCONFIGURED)
    # Fail closed, next to the worker states, and this is the only place that does it. Two
    # jobs in one line: every early return below — not requested, unavailable, ConfigError,
    # no owner gate, schema failure — leaves the two views of "which lanes work" agreeing,
    # and on the success path nothing between here and the declaration further down can route
    # a card against the module default. A second copy lower down was removed after a
    # mutation showed no input could tell it apart from this one.
    if MSG is not None:
        MSG.set_enabled_channels(())
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
    # Validate the spool synchronously. run_watcher() repeats this check defensively, but
    # a first check only inside the daemon thread could die there while health still claimed
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
    # P4: the box's own identity for owner resolution. Not part of `_REQUIRED` (devmon_owner.py)
    # — an empty DEV_MONITOR_ROSTER is "no roster on this box", a supported state, not a
    # reason to disable the message feature that DEV_MONITOR_OWNER already gated above.
    MSG.set_box_owner(OWNER_CONFIG['owner'])
    MSG.set_roster_path(os.environ.get('DEV_MONITOR_ROSTER', '').strip())
    legacy_webhook = os.environ.get('AIRLOCK_DEVMON_SLACK_WEBHOOK', '').strip()
    webhooks = {
        'slack-urgent': (
            os.environ.get('AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT', '').strip()
            or legacy_webhook),
        'slack-routine': os.environ.get(
            'AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_ROUTINE', '').strip(),
    }
    # None means this box cannot send mail. The routing table still says page -> email;
    # what changes is whether rows are written for a lane that has no worker to drain them.
    email_config = devmon_email.config_from_env()
    console_url = os.environ.get('AIRLOCK_DEVMON_CONSOLE_URL', '').strip()
    stop = None
    # From here on, anything that fails is a generic failure of the OPTIONAL half: an
    # unwritable execution directory or a thread that cannot start. None of it is a
    # reason to take observability down, and systemd would restart-loop us if it escaped.
    try:
        EXEC_CONFIG = _build_exec_config()
        stop = threading.Event()
        # --- delivery workers, before anything can enqueue for them ---
        for lane, webhook in webhooks.items():
            if not webhook:
                continue
            threading.Thread(
                target=devmon_slack.run_worker, args=(lane, webhook, stop, console_url),
                daemon=True, name=lane.replace('-', '_') + '_worker').start()
            # Thread.start() returned: only now may health claim this lane is on.
            _MESSAGE_LANE_WORKER_STATES[lane] = 'on'
        if email_config is not None:
            threading.Thread(
                target=devmon_email.run_worker, args=(email_config, stop, console_url),
                daemon=True, name='email_worker').start()
            _MESSAGE_LANE_WORKER_STATES['email'] = 'on'
        # ingest may only enqueue for lanes that have a running worker. Derived from the
        # states just set rather than from the config a second time: two readings of "is
        # this lane on" is how a queue starts filling for a thread that never started.
        MSG.set_enabled_channels(
            lane for lane in HEALTH_LANES if _MESSAGE_LANE_WORKER_STATES[lane] == 'on')
        # --- only now the threads that can ingest ---
        # The order is load-bearing, not tidiness. The spool watcher's first pass happens
        # immediately and a restart normally finds files already waiting, so starting it
        # before the line above would let a card be routed against the module default —
        # rows written to a lane whose worker was never started, which is the 2026-07-30
        # silence this whole phase exists to make impossible. The sentinel watcher and the
        # reaper both ingest too, through _emit_run_result.
        threading.Thread(
            target=devmon_spool.run_watcher, args=(OWNER_CONFIG['spool'], stop),
            daemon=True, name='spool_watcher').start()
        threading.Thread(
            target=_sweep_loop, args=(stop,), daemon=True, name='msg_sweep').start()
        threading.Thread(
            target=_lane_watchdog_loop, args=(stop, webhooks), daemon=True,
            name='msg_lane_watchdog').start()
        threading.Thread(
            target=_sentinel_watcher, args=(stop, EXEC_CONFIG['sentinel_dir']),
            daemon=True, name='exec_sentinel').start()
        threading.Thread(
            target=_reaper_loop, args=(stop, EXEC_CONFIG['session']),
            daemon=True, name='exec_reaper').start()
    except Exception as exc:  # noqa: BLE001 — an optional feature must not kill the monitor
        if stop is not None:
            stop.set()
        OWNER_CONFIG = None
        EXEC_CONFIG = None
        _MESSAGES_STATE = 'off'
        _MESSAGE_LANE_WORKER_STATES.update(_LANE_UNCONFIGURED)
        MSG.set_enabled_channels(())
        sys.stderr.write(f'[airlock-dev-monitor] messages failed to start ({exc.__class__.__name__}: '
                         f'{exc}) — observability only\n')
        return
    _MESSAGES_STATE = 'on'
    print(f"[airlock-dev-monitor] messages feature: on owner={OWNER_CONFIG['owner']} "
          f"spool={OWNER_CONFIG['spool']} db={OWNER_CONFIG['db']} "
          f"exec_session={EXEC_CONFIG['session']} "
          f"slack_urgent={_MESSAGE_LANE_WORKER_STATES['slack-urgent']} "
          f"slack_routine={_MESSAGE_LANE_WORKER_STATES['slack-routine']} "
          f"email={_MESSAGE_LANE_WORKER_STATES['email']} "
          f"roster={'configured' if MSG.roster_path() else 'unconfigured'}", flush=True)


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
          f'message_lanes={json.dumps(_message_lanes_health(), sort_keys=True)}', flush=True)
    with ThreadingHTTPServer(('127.0.0.1', PORT), Handler) as server:
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == '__main__':
    main()
