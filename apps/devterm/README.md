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

### Optional features (default off, degrade cleanly when their deps are absent)

- **Claude Code login + account pool, and Codex login** (`accounts = true`): log in to
  a Claude Code account from the browser, keep several accounts in a pool, switch
  between them, and manage the box's Codex login — all from the account popup.

  The platform provides `bin/airlock-accounts` (login + pool + switch) and
  `bin/airlock-accounts-status` (identity/health probe). devterm keeps installing
  `~/.local/bin/claude-switch` and `claude-status` as compatibility shims, so both
  commands remain usable from the terminal. Set `claude_switch` / `claude_status` only
  to point the gate at your own build; otherwise it uses the platform tools. The Codex
  half needs the `codex` CLI. When the feature is off or a configured tool is missing,
  the UI is hidden and the endpoints return a clean "disabled".

  Login is headless — no callback port, no browser on the box: the popup issues a PKCE
  login link (`claude-switch login-url`, verifier stays server-side), you approve in any
  browser, and paste the returned code back (`login-code`). The gate sends that one-time
  value to the platform CLI over protected stdin, never process argv or an environment
  variable. Credentials live in
  `~/.claude-accounts/<id>.json` (mode 600); the active one is copied into
  `~/.claude/.credentials.json`, which is what Claude Code reads. Accounts are named
  after the id you log in as — `email (personal|team)` — so a re-login always revives
  the same slot. No secret value is ever returned to the browser or logged.
- **Fleet usage store** (`fleet_store` / `fleet_store_url`): annotates the account
  popup with utilization from a shared store. No host is hardcoded; unset = no usage
  numbers (the list still works).
- **OpenCode xAI login** (`xai = true`): shows the credential OpenCode keeps in
  `~/.local/share/opencode/auth.json`, and provides its supported SuperGrok device
  login and provider-scoped logout commands. Only credential state and access-token
  expiry reach the browser; access and refresh tokens never do. A past access-token
  expiry means OpenCode will refresh it on use, not that the sign-in is dead. This is
  labelled **OpenCode xAI** because Orca uses a separate `~/.grok/auth.json` login.
- **fileview file-open**: click a file path in the terminal to open it in fileview.
  Turns on automatically when `[apps.fileview]` is enabled.
- **Orca worktree sidebar** (`orca_shim`): an experimental layout showing Orca's
  worktrees with per-worktree agent launchers. Needs the Orca CLI shim; falls back to
  the top-tab layout otherwise.
- **Remote sessions** (`remote_hosts = "hostA,hostB"`): also surface tmux sessions
  from the listed ssh hosts as tabs. Empty = local only (fully inert).
