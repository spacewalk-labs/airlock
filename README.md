# Airlock

**A self-hosted workspace for a single dev server.**

Airlock turns one Tailscale-joined Linux box into a development environment you
can reach from any device. Every tool sits behind a single identity check, and
the whole thing is set up from one `airlock.toml` and one installer script, with
each tool fetched from its own upstream rather than redistributed here.

Working across several machines scatters your work. Keeping it on one box is
what lets it accumulate: repos, notes, research, running services, and session
history pile up in one place, so your next task starts with what the last one
left.

> Status: **v1 — all nine apps install from `airlock.toml` and are end-to-end
> verified** on a fresh Tailscale-joined Ubuntu 24.04 box (owner reaches each app;
> non-owners get 403). See [`PLAN.md`](PLAN.md) for the build plan and the handful
> of enhancements deferred to a follow-up (noted in the table below).

## What's inside

| App | What it is | Upstream |
|---|---|---|
| **hub** | The way in: launcher, PWA, return widget, icon system | (ours) |
| **devterm** | Browser web terminal (mobile-friendly) | ttyd (MIT) |
| **fileview** | Directory viewer + editor | filebrowser (API only) |
| **publish** | Static-file publish manager (+ optional pluggable external target) | (ours) |
| **notepad** | Clipboard / image upload scratchpad | (ours) |
| **dev-monitor** | System / service / network / storage monitor (+ optional owner-only message & action console) | (ours) |
| **code-server** | Browser IDE | code-server (MIT) |
| **orca** | Agent Development Environment (parallel coding agents) | stablyai/orca (MIT) |
| **paseo** | Coding-agent orchestration daemon | @getpaseo/cli (Apache-2.0) |

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

## Update

An installed box has no remote pointing here — the install cuts that link on
purpose — so `git pull` is not the update path. Preview, then update:

```bash
bash bin/airlock-update --dry-run   # what would change; changes nothing
bash bin/airlock-update             # write the release, commit it, re-run the installer
```

A checkout older than that script (2026-08-22) runs it once from here, with the same
flags after `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/spacewalk-labs/airlock/main/bin/airlock-update | bash -s -- --dry-run
```

Installed before 2026-08-21, or the preview says it cannot tell which release the box
came from: [`docs/update-old-install.md`](docs/update-old-install.md).

Public projection releases bind their source with the exact commit subject
`release from source @ <source-sha>`, where `<source-sha>` is the full 40-character
lowercase Git SHA. Release readers also accept the same shape with a restricted
legacy source label and its historical 7–40-character SHA so already-published
history remains readable; new release writers must use the neutral `source`
spelling and a full SHA.

## Write an external app package

[Copy the runnable external package example and read the short author guide.](examples/app-package/README.md)

`bash bin/airlock-smoke` re-runs every enabled app's gate check on demand. It exits
`0` when the gates passed **and** the serve frontend was checked, `3` when the gates
passed but this box could not check its own ingress (it cannot resolve its own tailnet
name — MagicDNS off, some container runtimes), and `1` on failure. `3` is not `0`
because a run that never checked the ingress is not a run that verified it; open the
URL from another device once, which is the only check that can settle it.

> **Before you add a collaborator:** fileview serves **the whole home directory of
> this box's user account** — dotfiles, `~/.ssh` and every agent credential included
> — read **and write**. Nothing above home is served (`--root %h`), and there is no
> root setting and no ignore list. See [SECURITY.md](SECURITY.md).

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

**AGPL-3.0** (© 2026 Sunghyeon Cho) for the Airlock core and all app
integrations. `apps/paseo/patches/` and the web-ui patcher are marked
`AGPL-3.0-only` separately because they are modifications to Paseo. See
[`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). Upstream tools keep their own
licenses.

Using Airlock — for yourself, or inside a company — costs nothing and requires
nothing. AGPL-3.0 keeps an express patent grant (§11) and stays an OSI-approved
open-source license, while §13 closes the one gap Apache-2.0 left open: someone
repackaging Airlock as a service must publish their modified source. It does not
grant trademark rights — see the trademark note in [`LICENSE`](LICENSE).

Changed from Apache-2.0 on 2026-09-08. Versions already published under
Apache-2.0 stay under it. The reasoning is in
[`docs/design/commercialisation-and-license.md`](docs/design/commercialisation-and-license.md).

## Security

These are owner-only tools (shell, IDE, agent runners) — treat the identity check
as load-bearing. Read [`SECURITY.md`](SECURITY.md) before exposing Airlock.
