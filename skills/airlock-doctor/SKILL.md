---
name: airlock-doctor
description: Diagnose a running Airlock — check the Tailscale ingress, the identity gate (owner allowed / others 403), nginx, and each enabled app's backend. Use when the hub or an app is unreachable, returns 403 for the owner, or an app card is broken.
---

# airlock-doctor

Diagnose an Airlock install on the current box. Work top-down along the request
path: `tailscale serve → nginx gate → app backend`. Report cause, impact, and the
next concrete action — never a bare "it's broken".

## 1. Ingress (Tailscale)

```bash
tailscale status            # BackendState must be Running
sudo tailscale serve status # hub 443 + http port, and each separate-port app
```
If serve mappings are missing, re-run **airlock-deploy** (the installer creates
them). If `BackendState` isn't `Running`, `tailscale up` first.

## 2. The identity gate (most common culprit)

The gate is the trust boundary. Test it directly on the loopback gate/hub port
(get ports from `python3 bin/airlock-config env <app>` and `... env hub`):

```bash
HDR=Tailscale-User-Login ; OWNER=<owner-login> ; HUB=<hub nginx_port>
# owner should pass; a stranger and a missing header must both be denied.
curl -s -o /dev/null -w '%{http_code}\n' -H "$HDR: $OWNER"            http://127.0.0.1:$HUB/
curl -s -o /dev/null -w '%{http_code}\n' -H "$HDR: nobody@example.com" http://127.0.0.1:$HUB/
curl -s -o /dev/null -w '%{http_code}\n'                              http://127.0.0.1:$HUB/
```
- **Owner gets 403:** the owner login in `airlock.toml` doesn't match the identity
  Tailscale injects. Check `curl -s http://127.0.0.1:$HUB/whoami` (over the tailnet
  it echoes the verified login) and reconcile `[auth] owner`.
- **Stranger / no-header gets 200:** a GATE HOLE — stop and fix before anything
  else. Confirm `sudo nginx -T` shows the server-level `if ($hub_ok = 0) { return
  403; }` for the hub, and `if ($owner_ok = 0) { return 403; }` for separate-port
  gates. Never run a backend exposed without its gate.

## 3. nginx

```bash
sudo nginx -t                                   # config valid?
ls /etc/airlock/nginx/hub-locations.d/ /etc/airlock/nginx/servers.d/   # fragments present?
sudo systemctl reload nginx
```
A fragment references runtime vars (`$hub_ok`, `$owner_ok`, `$connection_upgrade`)
defined in the rendered site — if `nginx -t` complains about an unknown variable,
the main site didn't render; re-run the installer.

## 4. App backends (loopback)

```bash
systemctl --user status 'airlock-*'    # markserv/filebrowser/publish/dev-monitor/orca/paseo/devterm/code-server
journalctl --user -u airlock-<app> -n 50 --no-pager
```
Then hit the backend directly on its loopback port (from `airlock-config env
<app>`) to isolate backend-vs-gate. Each app's `apps/<app>/smoke.sh` runs the full
owner/deny/no-header check — run it to confirm end to end.

## 5. paseo resource backstop

When paseo slows down, sessions die, or tools report unrelated resource errors,
read both kernel event files for its cgroup. The generated unit's comment above
`MemoryMax` in `apps/paseo/render.sh` documents the cgroup layout. For a live unit,
systemd's `ControlGroup` is the source of truth; resolve it instead of hardcoding
a user ID, and fail visibly if the unit or either event file is absent:

```bash
PASEO_CGROUP="$(systemctl --user show -p ControlGroup --value airlock-paseo.service)"
if [ -z "$PASEO_CGROUP" ]; then
  echo "paseo ControlGroup is empty; check systemctl --user status airlock-paseo.service" >&2
else
  PASEO_CGROUP_DIR="/sys/fs/cgroup${PASEO_CGROUP}"
  for PASEO_EVENT in memory.events pids.events; do
    if [ ! -r "$PASEO_CGROUP_DIR/$PASEO_EVENT" ]; then
      echo "missing paseo cgroup event file: $PASEO_CGROUP_DIR/$PASEO_EVENT" >&2
    else
      cat "$PASEO_CGROUP_DIR/$PASEO_EVENT"
    fi
  done
fi
```

- `memory.events` `high` rising is the expected `MemoryHigh` throttle signal.
- `memory.events` `max` rising means the box is too small for paseo's workload;
  reduce concurrency or give the box more memory. If the unit deliberately uses
  `MemoryMax=infinity`, there is no memory backstop to interpret as a limit.
- `pids.events` `max` means a pids limit was reached: `fork()` fails and the symptom
  can surface as an unrelated tool or session error. Since 2026-08-07 the unit's
  `TasksMax` defaults to `infinity`, so this counter stays at 0 on the unit and the
  limit that can actually bite is the enclosing slice's — read that one too:
  `cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/pids.{max,events}`.
  A finite unit-level backstop is available with `AIRLOCK_PASEO_TASKS_MAX`.

## App-specific gotchas

- **orca/paseo** bind `0.0.0.0` / spawn children — orca is confined by an nft
  loopback ruleset (`nft list table inet airlock_orca` must show `iif != "lo" …
  drop`); paseo needs node ≥ 20 and the three gate headers (`X-Forwarded-Proto
  https`, `Host <fqdn>:<port>`, trusted proxy) or its WebSocket dies.
- **markwand/filebrowser** — a re-run must stop `airlock-filebrowser` before
  `filebrowser config set` (SQLite lock), else it times out.
- **notepad** needs `[apps.publish]` (it uses the publish upload backend).
- **A denied identity seeing the wrong-owner page with 403 is correct**, not a bug.

Report what you checked, what passed, what failed, and the single next action.
