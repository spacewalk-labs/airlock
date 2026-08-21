# Acceptance run — 2026-08-07

The scratch suite (`install/test-packages.sh`) shims the live boundaries: no real
units, no `sudo`, no network. It is the right trade for a test that runs on every
push, and it means the contract had never been observed doing the four things an
author does first on a box where those boundaries are real.

This is that observation, run once on a disposable container.

## What was run

`acceptance.sh` in this directory, as an unprivileged user with `sudo`, on a fresh
Ubuntu 24.04 LXD container (4 GiB, 4 vCPU) with `nginx` and `curl` installed and
lingering enabled:

```bash
AIRLOCK_CHECKOUT=$HOME/airlock bash examples/app-package/acceptance.sh
```

## What was real, and the one thing that was not

Real: systemd **user units** (written, enabled, started, restarted, removed), the
real `nginx` (`nginx -t`, reload, the hub server and its identity gate), real
`sudo`, real filesystem paths (`/etc/airlock/nginx`, `~/.config/systemd/user`),
real loopback ports and real HTTP.

Shimmed: **`tailscale`, and only `tailscale`.** The box is not on a tailnet, and
`install/lib.sh:ts_require_tailscale` fails closed without one. The shim answers
`status --json` with `BackendState: Running` and accepts `serve`. That leaves the
ingress unverified — the installer says so itself in the transcript below — and
the ingress is not what the app-package contract governs. Everything the contract
does govern ran for real.

## Result: 21 checks, 0 failed

| step | what it proved |
|---|---|
| install | unit written and active, fragment written, backend answers on loopback, and the gate really gates: `allowed=200 denied=403 anonymous=403` through real nginx |
| rerun | byte-identical unit and fragment, and `ActiveEnterTimestampMonotonic` unchanged — the service was not bounced by a no-op run |
| upgrade | port change reaches the unit and the fragment, the new backend body is the one served, the old port stops answering |
| remove | deactivator ran, ledger removed exactly the unit and the fragment it recorded, backend stopped, nothing answers |
| wrong manifest | `airlock-config validate` exits 1 and names both the field (`artifacts.units`) and the offending value |

Nothing in the live run disagreed with the scratch suite. That is worth stating
plainly: the model and the territory agreed this time, which is a fact about this
contract rather than a reason to stop checking.

## Transcript

```text


========== 0. copy the example the way the guide says to, change only owner
1:# Copy this directory, then change only the owner value below before installing.
4:owner = "acc@example.com"


========== 1. INSTALL (real)
[airlock] validating airlock.toml
ok: config valid
[airlock] prerequisite preflight passed
[airlock] installing hub -> /opt/airlock/hub
[airlock] installing packaged app: hello-example (/home/acc/hello-example/package)
airlock-ledger: recorded intent hello-example
[airlock] wrote nginx fragment: /etc/airlock/nginx/hub-locations.d/hello-example.conf
Created symlink /home/acc/.config/systemd/user/default.target.wants/airlock-hello-example.service → /home/acc/.config/systemd/user/airlock-hello-example.service.
[airlock] hello-example installed (backend: 127.0.0.1:18900)
[airlock] rendering nginx site -> /etc/nginx/conf.d/airlock.conf
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
[airlock] lingering already on for 'acc' — --user units survive reboot
Synchronizing state of nginx.service with SysV service script with /usr/lib/systemd/systemd-sysv-install.
Executing: /usr/lib/systemd/systemd-sysv-install enable nginx
Failed to enable unit: Unit file tailscaled.service does not exist.
[airlock] WARN: could not enable tailscaled on boot (usually already enabled by the Tailscale package)
tailscale serve: shimmed (serve --bg --https=443 http://127.0.0.1:18802)
[airlock] plaintext ingress: :9999 -> 301 https (hub)
tailscale serve: shimmed (serve --bg --http=9999 http://127.0.0.1:18806)
[airlock] smoke: hello-example
[hello-example smoke] backend=200/200 allowed=200/200 denied=403/403 anonymous=403/403
airlock-ledger: committed hello-example
[airlock] serve check skipped: this box cannot resolve its own tailnet name (MagicDNS off?).
[airlock] done. Entrance: https://box.example.ts.net/
[airlock] INGRESS UNVERIFIED — nothing here proves another device can reach this box. A request to our own tailnet name never leaves the machine, so this run cannot tell a healthy box from one whose inbound path is broken. Open https://box.example.ts.net/ from your phone or laptop once; that is the check.
installer rc=0
PASS  install exits 0 (0)
PASS  user unit exists at /home/acc/.config/systemd/user/airlock-hello-example.service
PASS  nginx fragment exists at /etc/airlock/nginx/hub-locations.d/hello-example.conf
active
PASS  backend unit is active
PASS  backend answers on loopback (200)
--- ledger ---


========== 2. RERUN (must be idempotent: same bytes, service not bounced)
[airlock] validating airlock.toml
ok: config valid
[airlock] prerequisite preflight passed
[airlock] installing hub -> /opt/airlock/hub
[airlock] installing packaged app: hello-example (/home/acc/hello-example/package)
airlock-ledger: recorded intent hello-example
[airlock] hello-example installed (backend: 127.0.0.1:18900)
[airlock] rendering nginx site -> /etc/nginx/conf.d/airlock.conf
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
[airlock] lingering already on for 'acc' — --user units survive reboot
Synchronizing state of nginx.service with SysV service script with /usr/lib/systemd/systemd-sysv-install.
Executing: /usr/lib/systemd/systemd-sysv-install enable nginx
Failed to enable unit: Unit file tailscaled.service does not exist.
[airlock] WARN: could not enable tailscaled on boot (usually already enabled by the Tailscale package)
tailscale serve: shimmed (serve --bg --https=443 http://127.0.0.1:18802)
[airlock] plaintext ingress: :9999 -> 301 https (hub)
tailscale serve: shimmed (serve --bg --http=9999 http://127.0.0.1:18806)
[airlock] smoke: hello-example
[hello-example smoke] backend=200/200 allowed=200/200 denied=403/403 anonymous=403/403
airlock-ledger: committed hello-example
[airlock] serve check skipped: this box cannot resolve its own tailnet name (MagicDNS off?).
[airlock] done. Entrance: https://box.example.ts.net/
[airlock] INGRESS UNVERIFIED — nothing here proves another device can reach this box. A request to our own tailnet name never leaves the machine, so this run cannot tell a healthy box from one whose inbound path is broken. Open https://box.example.ts.net/ from your phone or laptop once; that is the check.
PASS  rerun exits 0 (0)
PASS  unit bytes unchanged (885b3aead4ceeeb0)
PASS  fragment bytes unchanged (14064b362fb2f4f5)
PASS  service was not restarted (1396211690405)


========== 3. UPGRADE (change the package, same install command)
[airlock] validating airlock.toml
ok: config valid
[airlock] prerequisite preflight passed
[airlock] installing hub -> /opt/airlock/hub
[airlock] reconcile: 'hello-example' changed — deactivating the recorded install before the fresh one
airlock-ledger: deactivator did not run for hello-example; tearing down recorded artifacts
Removed "/home/acc/.config/systemd/user/default.target.wants/airlock-hello-example.service".
airlock-ledger: removed /home/acc/.config/systemd/user/airlock-hello-example.service
airlock-ledger: removed /etc/airlock/nginx/hub-locations.d/hello-example.conf
airlock-ledger: dropped committed record hello-example
[airlock] installing packaged app: hello-example (/home/acc/hello-example/package)
airlock-ledger: recorded intent hello-example
[airlock] wrote nginx fragment: /etc/airlock/nginx/hub-locations.d/hello-example.conf
Created symlink /home/acc/.config/systemd/user/default.target.wants/airlock-hello-example.service → /home/acc/.config/systemd/user/airlock-hello-example.service.
[airlock] hello-example installed (backend: 127.0.0.1:18901)
[airlock] rendering nginx site -> /etc/nginx/conf.d/airlock.conf
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
[airlock] lingering already on for 'acc' — --user units survive reboot
Synchronizing state of nginx.service with SysV service script with /usr/lib/systemd/systemd-sysv-install.
Executing: /usr/lib/systemd/systemd-sysv-install enable nginx
Failed to enable unit: Unit file tailscaled.service does not exist.
[airlock] WARN: could not enable tailscaled on boot (usually already enabled by the Tailscale package)
tailscale serve: shimmed (serve --bg --https=443 http://127.0.0.1:18802)
[airlock] plaintext ingress: :9999 -> 301 https (hub)
tailscale serve: shimmed (serve --bg --http=9999 http://127.0.0.1:18806)
[airlock] smoke: hello-example
[hello-example smoke] backend=200/200 allowed=200/200 denied=403/403 anonymous=403/403
airlock-ledger: committed hello-example
[airlock] serve check skipped: this box cannot resolve its own tailnet name (MagicDNS off?).
[airlock] done. Entrance: https://box.example.ts.net/
[airlock] INGRESS UNVERIFIED — nothing here proves another device can reach this box. A request to our own tailnet name never leaves the machine, so this run cannot tell a healthy box from one whose inbound path is broken. Open https://box.example.ts.net/ from your phone or laptop once; that is the check.
PASS  upgrade exits 0 (0)
PASS  unit carries the new port
body: {"message":"hello from v2 of the example"}
PASS  the new backend is the one serving
curl: (7) Failed to connect to 127.0.0.1 port 18900 after 0 ms: Couldn't connect to server
PASS  the old port is gone (000)
PASS  fragment repointed to the new port


========== 4. REMOVE (drop both tables, same install command)
# Copy this directory, then change only the owner value below before installing.
[auth]
provider = "tailscale"
owner = "acc@example.com"

[apps.hub]



[airlock] validating airlock.toml
ok: config valid
[airlock] prerequisite preflight passed
[airlock] installing hub -> /opt/airlock/hub
[airlock] reconcile: removing 'hello-example' (recorded but no longer in config)
[airlock] hello-example deactivated; Airlock will remove its declared artifacts
airlock-ledger: deactivator ran for hello-example
Removed "/home/acc/.config/systemd/user/default.target.wants/airlock-hello-example.service".
airlock-ledger: removed /home/acc/.config/systemd/user/airlock-hello-example.service
airlock-ledger: removed /etc/airlock/nginx/hub-locations.d/hello-example.conf
airlock-ledger: dropped ledger entry hello-example
[airlock] rendering nginx site -> /etc/nginx/conf.d/airlock.conf
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
[airlock] lingering already on for 'acc' — --user units survive reboot
Synchronizing state of nginx.service with SysV service script with /usr/lib/systemd/systemd-sysv-install.
Executing: /usr/lib/systemd/systemd-sysv-install enable nginx
Failed to enable unit: Unit file tailscaled.service does not exist.
[airlock] WARN: could not enable tailscaled on boot (usually already enabled by the Tailscale package)
tailscale serve: shimmed (serve --bg --https=443 http://127.0.0.1:18802)
[airlock] plaintext ingress: :9999 -> 301 https (hub)
tailscale serve: shimmed (serve --bg --http=9999 http://127.0.0.1:18806)
[airlock] serve check skipped: this box cannot resolve its own tailnet name (MagicDNS off?).
[airlock] done. Entrance: https://box.example.ts.net/
[airlock] INGRESS UNVERIFIED — nothing here proves another device can reach this box. A request to our own tailnet name never leaves the machine, so this run cannot tell a healthy box from one whose inbound path is broken. Open https://box.example.ts.net/ from your phone or laptop once; that is the check.
PASS  remove-run exits 0 (0)
PASS  unit removed
PASS  fragment removed
PASS  backend stopped
PASS  nothing answers on the backend port (000)


========== 5. A WRONG MANIFEST NAMES WHAT IS WRONG
airlock-config: package 'hello-example': artifacts.units entry '../not-a-unit.service' must be a bare unit file name ending in one of ['.service', '.socket', '.timer', '.path', '.target'] (and not option-like, and not a glob — '*', '?', '[' are fatal here) — anything else could resolve outside the unit directories or confuse systemctl
PASS  validate refuses (1)
PASS  the message names the field and the value


========== RESULT: 21 passed, 0 failed
```
