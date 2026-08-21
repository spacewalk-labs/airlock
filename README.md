# Airlock

A self-hosted **dev hub**: one browser entrance (add-to-homescreen PWA) that
composes a suite of developer tools behind a single identity gate — a web
terminal, a browser IDE, markdown/file viewers, a publish manager, a system
monitor, and browser-based AI coding-agent environments.

Airlock is a **composer/installer**, not a re-distribution of upstream tools.
You fill in one config file and run one installer; Airlock wires up the tools
(fetching each from its own upstream) behind a shared entrance and identity gate.

> Status: **v1 — all nine apps install from `airlock.toml` and are end-to-end
> verified** on a fresh Tailscale-joined Ubuntu 24.04 box (owner reaches each app;
> non-owners get 403). See [`PLAN.md`](PLAN.md) for the build plan and the handful
> of enhancements deferred to a follow-up (noted in the table below).

## What's inside

| App | What it is | Upstream |
|---|---|---|
| **hub** | The entrance: launcher, PWA, return widget, icon system | (ours) |
| **devterm** | Browser web terminal (mobile-friendly) | ttyd (MIT) |
| **markwand** | Markdown / file viewer + editor | markserv + filebrowser |
| **publish** | Static-file publish manager (+ optional pluggable external target) | (ours) |
| **notepad** | Clipboard / image upload scratchpad | (ours) |
| **dev-monitor** | System / service / network / storage monitor (+ optional owner-only message & action console) | (ours) |
| **code-server** | Browser IDE | code-server (MIT) |
| **orca** | Agent Development Environment (parallel coding agents) | stablyai/orca (MIT) |
| **paseo** | Coding-agent orchestration daemon | @getpaseo/cli (AGPL-3.0) |

Shipped since v1: dev-monitor's message/action console (`messages = true`),
code-server multi-tab slots, orca's patched web-bundle client, and paseo's
`browse-host` live browser panels (config-gated with `browse = true`).
Two Claude Code skills ship for operating a box: **airlock-deploy** and
**airlock-doctor** (`skills/`); a starter knowledge base lives in `wiki/`.

## Requirements (v1)

- A Linux box (Ubuntu 24.04 target; Python ≥ 3.11 for the config layer).
- **Tailscale** on the box. v1 authenticates via Tailscale identity and **fails
  closed** if Tailscale is not the ingress — see [`SECURITY.md`](SECURITY.md).
  (Non-Tailscale auth providers are a later update.)

## Quickstart

```bash
git clone <your-fork>/airlock && cd airlock
cp airlock.toml.example airlock.toml
$EDITOR airlock.toml            # set owner, apps, ports, branding
bash bin/airlock-preflight      # optional: report every enabled-app prerequisite
bash install/airlock-install.sh # installs enabled apps, renders nginx, runs smoke
```

Then open `https://<your-box>/` (Tailscale HTTPS) and add to home screen.

## Write an external app package

[Copy the runnable external package example and read the short author guide.](examples/app-package/README.md)

`bash bin/airlock-smoke` re-runs every enabled app's gate check on demand. It exits
`0` when the gates passed **and** the serve frontend was checked, `3` when the gates
passed but this box could not check its own ingress (it cannot resolve its own tailnet
name — MagicDNS off, some container runtimes), and `1` on failure. `3` is not `0`
because a run that never checked the ingress is not a run that verified it; open the
URL from another device once, which is the only check that can settle it.

> **Before you set `code_root` or add a collaborator:** markwand serves everything
> under `[paths].code_root` — dotfiles included — read **and write**, to the owner
> *and* every collaborator, and the viewer reads through symlinks that leave it.
> There is no exclusion list. Point it at a project directory, not at `~`.
> See [`SECURITY.md`](SECURITY.md#two-tiers-and-what-a-collaborator-actually-gets).

### Reboot survival (automatic)

The installer arms auto-start on boot by default, so **Airlock comes back on its
own after a reboot** — no manual step:

- each app's `systemd --user` unit is `enable`d by its installer, and the
  orchestrator runs `loginctl enable-linger` for the installing user so those
  units start at boot even on a **headless box** (no interactive login);
- `nginx` and `tailscaled` are enabled on boot;
- the hub's `tailscale serve` exposure is stored in tailscaled state, so it is
  re-applied automatically when tailscaled starts after a reboot.

If `enable-linger` can't be set (rare), the installer prints a loud `WARN` with
the one-line fix instead of failing the install.

### Tailscale SSH (default on)

`tailscale up` is run with `--ssh`, so the box accepts **Tailscale SSH** —
keyless, identity-gated remote login with no public SSH port. Actual access
still requires an `ssh` rule in your **tailnet ACL policy**, e.g.:

```jsonc
// tailnet policy → "ssh"
"ssh": [
  { "action": "check", "src": ["autogroup:member"], "dst": ["autogroup:self"], "users": ["autogroup:nonroot", "root"] }
]
```

Verify from another tailnet device (no key, no port):

```bash
tailscale status | grep <hostname>     # node is visible
ssh <user>@<hostname>                   # or: ssh <user>@<tailscale-ip>
```

### macOS host (personal home server)

The stack is Linux-native, so on a Mac you run it inside a Linux environment
(OrbStack) rather than natively — one codebase, no port. See
[`docker/README-macos.md`](docker/README-macos.md) for the step-by-step and
[`docs/design/macos-container.md`](docs/design/macos-container.md) for the
design. Status: reviewed draft, not yet hardware-verified.

## License

**MIT** (© 2026 Sunghyeon Cho) for the Airlock core and all app integrations,
**except** `apps/paseo/patches/` which is **AGPL-3.0** (modifications to Paseo).
See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). Upstream tools keep their own
licenses.

## Security

These are owner-only tools (shell, IDE, agent runners) — treat the identity gate
as load-bearing. Read [`SECURITY.md`](SECURITY.md) before exposing Airlock.
