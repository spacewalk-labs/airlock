# orca — browser Orca ADE behind the Airlock owner gate

One browser tab attaches to this box's [**Orca ADE**](https://github.com/stablyai/orca)
(a git-worktree parallel-agent IDE) — **no local install**. Authentication is your
**Tailscale identity** (no password); the box **owner only** may enter.

```
browser ──https/WireGuard──▶ tailscale serve :19940
                              │  identity header injected by tailscale serve
                              ▼
                   127.0.0.1:19941  nginx owner gate  ── not the owner? 403
                              │  (WS-safe proxy: no X-Forwarded-*, which would
                              ▼   break orca's Origin check)
                   0.0.0.0:19942  orca serve  ── nft loopback-only (gate reaches it,
                              │                    the tailnet cannot)
                    ┌─────────┴──────────┐
              web client            runtime
              (web-index.html)      (owns the worktrees, terminals, agents;
                                     keeps running even if the client disconnects)
```

Ports come from `airlock.toml` (`[apps.orca]`: `https_port` / `gate_port` /
`backend_port`); the values above are the defaults.

## Serves the patched web client

This installs the vendor `orca serve` (the runtime) but serves a **patched web client**
vendored at `apps/orca/web-bundle/dist/` — not the raw client `orca serve` ships. The
patch fixes an upstream bug where terminals die permanently after a page reload
(*"Local PTYs are unavailable in the web client"*) and adds an automatic reconnect
overlay when the runtime restarts. `install.sh` copies the dist to a world-readable
path, serves it at `/orca-web/`, and 302-redirects the vendor client URL (`/web-index.html`)
to it, so bookmarks and the launcher both land on the patched client. Provenance,
patch summary, and how to refresh the bundle: `web-bundle/README.md`.

**Zero-paste entry.** The launcher opens the gate root (`https://<box>:<https_port>/`).
For the owner, a document navigation there is 302-redirected to the patched client
carrying the runtime pairing (captured from `serve.log`), so opening Orca lands directly
in the workbench with no pairing paste. A WebSocket upgrade to `/` (the runtime RPC) is
proxied to the backend instead of redirected. If the pairing is not yet in `serve.log`
at install time (first cold start), `/orca-web/` still loads but asks to pair once;
re-running the installer wires zero-paste (the pairing URL is stable across restarts).

**Not deployed here (client code is inert without them):** the bundle also carries
local browser render (needs a slot-manager sidecar) and element-comment "grab" (needs a
page-injected bridge). Airlock does not install those services in v1, so the client
falls back to upstream behavior for them. Documented follow-up.

If the bundle is ever absent, `install.sh` falls back to serving the raw upstream client
(no `/orca-web/`, no zero-paste) and says so.

## Why the nft loopback rule

`orca serve` has **no `--host` flag**, so it binds `0.0.0.0`. An nft table
(`render_loopback_nft airlock_orca <backend_port>`, from `install/lib.sh`) drops any
non-loopback traffic to the backend port, so the **only** route in is
`tailscale serve` → the nginx owner gate. A small systemd oneshot re-applies the
rule on boot (nft is not persistent by default). See `SECURITY.md`.

## Runtime prerequisites (handled by `install.sh`)

- **Xvfb + GTK/nss/gbm libraries** — orca is Electron (Chromium); even headless
  `serve` needs an X display and the GTK runtime, or it crashes. `install.sh`
  installs them via `apt` (with a t64/non-t64 fallback for Ubuntu `noble`) and runs
  a **dedicated persistent Xvfb** unit for orca's display.
- **The AppImage** is downloaded from `stablyai/orca` and **sha256-verified**
  (mismatch aborts). It is `--appimage-extract`ed because the FUSE mount fails under
  `systemd --user`.
- **`sudo`** is needed for `apt` (runtime libs), `nft` (loopback rule + boot unit),
  and `tailscale serve` (HTTPS ingress). `AIRLOCK_DRY_RUN=1` prints every such step
  instead of running it (the nginx fragment is still written — it is config).
- **x86_64 only** — the pinned SHA is for the amd64 AppImage.

## Usage — add a project first

Opening a terminal on an empty screen fails with
`Local PTYs are unavailable in the web client`: with no project, the terminal falls
back to the `local` execution host (your laptop), which the browser has no PTY for.
Instead: **add a project** → host = **`Orca Server`** (this box) → pick a folder →
open the workspace → open terminals/agents **inside it** (they attach to the box's
runtime). The project list is browser-local state, so a fresh browser starts empty —
re-add the project; the runtime's worktrees are still there.

## Files

| File | Role |
|---|---|
| `install.sh` | provision + verify AppImage · Xvfb & `orca serve` systemd (`--user`) units · nft loopback rule · install vendored web client to serve path · nginx owner-gate fragment (patched client at `/orca-web/` + vendor redirect + zero-paste map) · `tailscale serve` |
| `smoke.sh` | gate health: backend reachable, owner 200/302, deny 403, no-header 403; patched client served + gated + widget-injected, vendor path redirected |
| `web-bundle/dist/` | the vendored **patched web client** (built dist) served at `/orca-web/` — see `web-bundle/README.md` |

The loopback firewall reuses the shared template `gate/loopback-only.nft.tpl` (via
`render_loopback_nft`); there is no per-app `.nft` file.
