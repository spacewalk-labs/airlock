# code-server — browser IDE (multi-instance)

VS Code in the browser ([coder/code-server](https://github.com/coder/code-server),
MIT), behind the Airlock owner gate. Runs up to `slots` concurrent IDE instances
with a tab bar.

```
browser --https--> tailscale serve :https_port --(identity)--> nginx owner-gate
        --(owner only / else 403)--> tab-bar shell + slot manager
                                     --> code-server 127.0.0.1:<backend + N - 1>
```

- **Auth**: Airlock nginx gate (`$owner_ok`), owner-only. code-server itself runs
  `--auth none` — safe only because the gate is the sole path and each slot binds
  loopback. See `../../SECURITY.md`.
- **Binary**: sha256-pinned release (no piped installer).

## How it works

- **Slot manager** (`manager/manager.py`, stdlib asyncio, systemd `--user`
  `airlock-code-server-manager`): a loopback API that spawns/stops/reorders slots,
  each a templated unit `airlock-code-server@N` bound to `backend_port + N - 1`.
  It re-checks the gate-verified identity on every request (defense-in-depth).
- **Tab-bar shell** (`web/shell.html`, served static by the gate at `/`):
  spawn / kill / rename / color / reorder, with an iframe readiness-retry so a
  cold spawn (brief 502) does not surface as a broken panel. The shell embeds the
  shared `/airlock-return.js` (corner mode); no brand asset is vendored here.
- **Slot launcher** (`bin/airlock-code-server-slot`): computes `port = base + N`
  and execs code-server, keeping the port math out of the systemd unit.
- **nginx gate** (`gate/nginx-lib.sh` → `emit_slot_gate`): owner guard + shell at
  `/` + one `/s/N/` reverse proxy per slot (WS-safe, no `X-Forwarded-*`) + `/api/`
  to the manager. The slot count, ports, and identity header all derive from
  config — nothing is hardcoded.

## Config (`[apps.code-server]`)

- `https_port` — public HTTPS port (`tailscale serve`).
- `gate_port` — loopback nginx owner gate.
- `backend_port` — slot 1's loopback IDE port; slot N is `backend_port + N - 1`.
- `manager_port` — loopback slot manager API.
- `slots` — max concurrent instances (default 4). Drives the shell's `MAX_SLOTS`,
  the systemd `ExecCondition` allow-list, and the `/s/N/` gate blocks.

## State

- User-data-dir per slot: `~/.local/share/airlock-code-server/slots/N`.
- Shared extensions-dir: `~/.local/share/airlock-code-server/extensions`.
- Tab prefs (names/colors/order): `~/.config/airlock-code-server/tabs.json`.
