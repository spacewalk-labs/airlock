# paseo — coding-agent orchestration behind the Airlock owner gate

One browser tab (or your phone) drives this box's **[Paseo](https://github.com/getpaseo/paseo)**
daemon — a coding-agent orchestrator that runs `claude` / `codex` / `gemini`
sessions (chat + diff + PR) as child processes. Authentication is your
**Tailscale identity** (no password); the box **owner only** may enter.

Unlike orca/code-server, paseo is **pure Node** — no Electron, Xvfb, AppImage or
firewall rules. The daemon binds `127.0.0.1`, so **loopback binding is the
isolation**: the only route in is `tailscale serve` → the nginx owner gate.

```
browser ──https/WireGuard──▶ tailscale serve :19950
                              │  identity header injected by tailscale serve
                              ▼
                   127.0.0.1:19951  nginx owner gate  ── not the owner? 403
                              │  proxy_set_header X-Forwarded-Proto https   (1)
                              │  proxy_set_header Host <fqdn>:19950         (3)
                              ▼
                   127.0.0.1:19952  paseo daemon (loopback bind)
                              │  PASEO_TRUSTED_PROXIES=127.0.0.1            (2)
                              ▼
                    spawns claude / codex / gemini as child processes
```

Ports come from `airlock.toml` (`[apps.paseo]`: `https_port` / `gate_port` /
`backend_port`); the values above are the defaults.

## The three load-bearing gate headers

The daemon serves its web UI (with a WebSocket) same-origin. Behind Airlock's TLS
gate, three things must line up or the WebSocket silently fails:

1. **`X-Forwarded-Proto https` (literal, on the gate).** The gate is a plain-http
   listener, so `$scheme` is `http`. Left alone, the daemon would tell the web UI
   to open `ws://`, which fails behind TLS. Forcing the literal `https` fixes it.
2. **`PASEO_TRUSTED_PROXIES=127.0.0.1` (daemon unit env).** Makes the daemon trust
   header (1) from the loopback proxy and upgrade the web UI to `wss://`.
3. **`Host <fqdn>:<https_port>` WITH the port (on the gate).** Nginx's `$host`
   strips the port, which trips a welcome-screen bug. The daemon's
   `PASEO_HOSTNAMES` allowlist (a DNS-rebinding guard) is set to accept that same
   `<fqdn>:<https_port>` host.

Because the shared `emit_owner_gate` does not add (1) or (3), the paseo gate
fragment is **written directly** by `install.sh` — but it replicates
`emit_owner_gate`'s structure exactly (loopback `server`, `if ($owner_ok = 0)
{ return 403; }`, then a WS-safe `proxy_pass`).

## Runtime prerequisites (handled by `install.sh`)

- **node >= 20.** The daemon and its `node-pty` fail on node 18; the installer
  hard-checks and aborts with a clear message on older boxes.
- **Pinned `@getpaseo/cli@0.2.5`** installed into a fixed, user-writable npm
  prefix (`~/.npm-global`). The version is pinned deliberately — paseo is pre-1.0
  and a floating install would drift the web-ui bundle and the depth4 anchor.
  Override with `version` under `[apps.paseo]` in `airlock.toml`; note that this
  reinstalls a different package against a tree whose anchors still target the pin,
  so it is not a rollback. To go back, revert the commit that moved the pin and
  re-run the installer.
- **A systemd `--user` unit** with an explicit `PATH` (npm global bin + provider
  CLI dirs + node + system). The daemon spawns provider CLIs against this PATH; a
  mismatch ("provider not found") is the #1 pilot gotcha.
- **The depth4 search patch** (below), applied idempotently.
- **`sudo`** is needed for `tailscale serve` (HTTPS ingress), and — only when
  `browse = true` — for installing chromium's OS libraries. The chromium one runs
  as `sudo -n`: without passwordless `sudo` the browse-host install fails loudly
  with the command to run by hand, rather than waiting on a prompt.
  `AIRLOCK_DRY_RUN=1` prints every mutation instead of running it (the nginx
  fragment is still written — it is config).

## The depth4 patch (and why it is AGPL)

paseo's add-project name search full-scans `$HOME`; on a large home directory it
times out. The patch caps it to `maxDepth: 4` (workspace `@files` search is
untouched). It edits **paseo's own bundle**, so it is a **derivative of paseo and
is licensed AGPL-3.0** — see `patches/README.md`. `install.sh` applies it via an
idempotent `sed`; a paseo version bump that moved the anchor **warns loudly**
rather than silently skipping. `patches/depth4-search.patch` is the
reference / re-derivation copy of that edit.

## Licensing map

| Component | License | Why |
|---|---|---|
| paseo daemon (`@getpaseo/cli`) | **AGPL-3.0** (upstream) | fetched via npm at install; not redistributed by Airlock |
| `patches/` (our edits to paseo) | **AGPL-3.0** | derivative of paseo |
| `install.sh`, `smoke.sh`, this README | Apache-2.0 (Airlock core) | our glue; runs paseo as a separate process (mere aggregation) |
| `browse-host/` sidecar | **Apache-2.0** | independent loopback-WS sidecar; does not import paseo |
| `browse-host/bin/patch-web-ui.js` | **AGPL-3.0** | encodes derivative edits to paseo's web-ui bundle |

See the repo `NOTICE` and `patches/README.md`. Airlock talks to paseo over a
separate process boundary, so the Airlock core stays Apache-2.0 (mere aggregation); only
the modifications **to paseo itself** are AGPL. *This is not legal advice.*

## browse-host live panels (config-gated)

`browse-host/` is a loopback-WS sidecar (Playwright-backed) that gives agents
native `browser_*` tools (Level 1) and streams live browser panels into the web
UI (Level 2). It is **off by default** and turned on with `browse = true` under
`[apps.paseo]`. When on, this installer adds the owner-gated `/browse-view/`
stream route to the gate and runs `browse-host/install.sh` **warn-only** (a
chromium download or a web-ui SHA-drift never breaks the hub or the daemon).
Default off keeps the install lean — chromium is a ~150MB download and the
Level-2 web-ui patch is SHA-pinned to `@getpaseo/cli`. See `browse-host/README.md`.

## Files

| File | Role |
|---|---|
| `install.sh` | provision + pin `@getpaseo/cli` · depth4 patch · systemd `--user` unit · nginx owner-gate fragment (direct, +3 headers) · `tailscale serve` · browse-host wiring when `browse = true` |
| `smoke.sh` | gate health: backend reachable, owner 200/302, deny 403, no-header 403 |
| `patches/` | the AGPL depth4 patch + its licensing note |
| `browse-host/` | Apache-2.0 sidecar for agent browser tools + live panels (wired in when `browse = true`) |
