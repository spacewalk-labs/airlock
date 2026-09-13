# devterm — browser web terminal

A terminal in the browser with a **custom xterm.js client** and a **programmable
gate**, in front of a [ttyd](https://github.com/tsl0922/ttyd) (MIT) PTY backend,
behind the Airlock owner gate. Sessions run in `tmux`, so closing the tab and
reopening the same URL resumes the same session.

## How it works

```
browser --https--> tailscale serve :https_port --(identity)--> nginx owner-gate
        --(owner only / else 403)--> devterm-gate 127.0.0.1:backend_port
                                     --> serves the custom client + API
                                     --> proxies /ws,/token --> ttyd --> tmux (auto-resume)
```

- **Auth**: the Airlock nginx gate (`$owner_ok`) — owner-only. The loopback
  `devterm-gate` re-checks the identity header (`AIRLOCK_IDENTITY_HEADER`) as
  defense-in-depth. See `../../SECURITY.md`.
- **Client**: a self-contained xterm.js 5.x front (vendored under `web/vendor/`, MIT):
  live session tab bar (`tmux ls`), tab rename/kill/color/reorder/new, `Ctrl+1-9`,
  a toolbar (copy modal / OSC52, font size, 10 server-persisted themes, file upload,
  image paste + annotate, pane zoom / equalize), seamless auto-reconnect, a mobile key
  bar with forced Ctrl+C / touch scroll / CJK-IME handling, clickable URLs, and a
  return-to-Airlock affordance (origin derived from `location`, not hardcoded).
- **ttyd** is provisioned automatically (sha256-pinned x86_64 and aarch64 releases) and is used
  only as the PTY backend; its built-in web UI is never served.

## Config (`[apps.devterm]`)

`https_port` (secure-context, clipboard) · `gate_port` (loopback nginx gate) ·
`backend_port` (loopback devterm-gate) · `ttyd_port` (loopback ttyd) ·
`font_size` · `lang`. D-DEVTERM-9900 retired plaintext `public_port` 9900.

Subscription accounts are a platform surface under `/airlock-accounts/`, not a
DevTerm feature. The legacy `accounts`, `xai`, `claude_switch`, and
`claude_status` keys may still be passed during rollout but do not enable UI, routes,
or process state here. DevTerm retains only:

- the platform-owned secret-drop adapter used by the terminal;
- four temporary fleet reads while the external collector finishes moving to the hub
  prefix (`fleet_read_domain`, with `fleet_store` as its optional local data source);
- unconditional `~/.local/bin/claude-switch` and `claude-status` compatibility shims
  that exec the platform binaries.

### Optional terminal features

- **fileview file-open**: click a file path in the terminal to open it in fileview.
  Turns on automatically when `[apps.fileview]` is enabled. fileview serves the
  account's home only, so a path outside it is refused with "Outside <home>" rather
  than opened — the terminal can name files the viewer cannot address.
- **Orca worktree sidebar** (`orca_shim`): an experimental layout showing Orca's
  worktrees with per-worktree agent launchers. Needs the Orca CLI shim; falls back to
  the top-tab layout otherwise.
- **Remote sessions** (`remote_hosts = "hostA,hostB"`): also surface tmux sessions
  from the listed ssh hosts as tabs. Empty = local only (fully inert).
