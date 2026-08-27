# Running Airlock on macOS (design draft)

> Status: **design draft + unverified scaffolding.** Airlock v1 installs on a
> Linux box (Ubuntu 24.04). This document is the plan for running that same
> stack on a **macOS host** — the intended use is a **personal home server** on
> an Apple Silicon Mac using **OrbStack**. The scripts under `docker/` are
> reviewed for shell correctness and structure but have **not** been run on a
> real Mac yet; treat first boot as a shakedown. What is verified vs. assumed is
> called out inline.

## 1. Why macOS can't run the stock installer directly

Airlock's installers assume a Linux host. The coupling surface (mapped from
`install/` and every `apps/*/install.sh`):

| Concern | Airlock uses | macOS reality |
|---|---|---|
| Service manager | `systemd --user` units for nearly every app; a `publish` **timer**; an orca **system** unit | macOS has `launchd`, not systemd |
| Ingress | `sudo tailscale serve --https=…` (hub, devterm, code-server, orca, paseo) | works on macOS Tailscale, but the whole stack behind it is Linux |
| Reverse proxy | system `nginx` + `/etc/nginx/conf.d/airlock.conf`, `systemctl reload nginx` | different paths/manager |
| Firewall | `nft` (nftables) — **orca only** (loopback lock, binds `0.0.0.0`) | macOS has `pf`, not nft |
| Packages | `apt-get` (orca Electron deps) | macOS has Homebrew |
| Binaries | **x86_64-only**: orca AppImage (code-server, ttyd, filebrowser pin arm64 assets) | Apple Silicon is arm64 |
| Paths | `/opt/airlock/*`, `/etc/airlock/*`, `/etc/nginx`, `/etc/systemd/system` | SIP-restricted on macOS |

Conclusion: this is not a few-line port. The stack is Linux-native end to end.
**We do not port it to macOS. We run the Linux stack inside a Linux
environment that macOS hosts** — and keep a single codebase.

## 2. Decision: OrbStack Linux *machine*, not a hand-rolled container

Two ways to run the Linux stack on macOS:

- **A — OrbStack Linux machine** (recommended). `orb` machines are full
  systemd Ubuntu userlands (VM-backed, but ergonomically like a container).
  systemd is native, so `systemctl --user`, the publish timer, and orca's
  system unit **all work unchanged**. The machine is native by default; an
  `amd64` machine under Rosetta transparently runs the x86_64-only binaries (§4).
  You run the **stock `install/airlock-install.sh`** — no fork of the installer.
- **B — systemd-in-Docker image** (`docker/Dockerfile`, provided as an
  experimental alternative). Reproducible and portable to any systemd-capable
  runtime, but systemd-as-PID1 in Docker needs careful cgroup/privilege setup
  and is fragile to test blind. Kept in the repo for people who want a committed
  image artifact; **not the recommended path for a personal box.**

> **Install ergonomics are a separate, open task.** This document settles *where* the
> stack runs; it does not make setting it up easy. The terminal steps in
> [`../../docker/README-macos.md`](../../docker/README-macos.md) are the remaining wall for a
> non-terminal user, and the plan to put a macOS app in front of them — without porting
> anything — is written down, but the plan lives with the project's internal task board
> rather than here.

We lead with **A** because it removes the entire systemd-in-container failure
mode while reusing the real installer — the smallest change that fully solves
the problem (Pike: boring, one codebase). OrbStack is free for personal use;
`Colima`/`Lima` are the FOSS fallbacks if a machine equivalent is needed.

## 3. Architecture (both paths)

```
macOS host (Apple Silicon)
└── OrbStack
    └── Linux env "airlock"  (Ubuntu 24.04, host-native arch by default, systemd)
        ├── tailscaled            → this env joins the tailnet as its OWN node
        │     └── tailscale serve → https://airlock.<tailnet>.ts.net  (:443)
        ├── nginx                 → identity gate + reverse proxy (loopback)
        └── app backends (all bind 127.0.0.1): devterm, fileview, publish,
              notepad, dev-monitor, code-server, paseo  [orca: opt-in, heavy]
```

Key properties preserved from the Linux design:

- **Identity gate stays load-bearing.** `tailscale serve` runs *inside* the
  env, so it still strips client headers and injects `Tailscale-User-Login` —
  the nginx server-level `if ($hub_ok = 0) { return 403; }` is unchanged. The
  env appears as one new Tailscale node; you reach it at its own tailnet FQDN.
- **Backends stay loopback-only.** nginx already emits `listen 127.0.0.1:PORT`
  for every backend; the env's network namespace is the isolation boundary, so
  orca's `nft` loopback lock becomes defense-in-depth (see §5).
- **GPU: none.** OrbStack runs a Linux guest under Apple's
  Virtualization.framework, which does **not** expose Metal to the guest, and
  Apple Silicon has no CUDA. Airlock needs no GPU — its AI agents (orca, paseo)
  call **remote** model APIs, not local inference. If you ever need local GPU
  compute, do it in a native macOS (Metal) process or a separate Linux+NVIDIA
  box, not here.

## 4. Architecture / Rosetta note (x86_64-only apps)

**orca** is the only x86_64-only app left: no arm64 AppImage upstream, and
`apps/orca/install.sh` refuses any other arch outright. The tools that were also
x86_64-only when this was written now pin arm64 assets — code-server
(`apps/code-server/install.sh`), filebrowser and ttyd (`apps/fileview/install.sh`,
`apps/devterm/install.sh`). On Apple Silicon:

- **Native arm64 — the default, and the verified path.** The setup script takes
  the Mac's own architecture. Faster, no emulation, and it runs everything
  **except orca**.
- **amd64 under Rosetta (`AIRLOCK_ARCH=amd64`):** opt in only if you want orca,
  and read the hardware note below first — emulation brings a real nginx failure
  with it.

> **Hardware note (2026-07-24):** the amd64/Rosetta machine surfaced a real
> friction — nginx's `Type=forking` systemd unit times out on start under
> emulation (§8). arm64-native avoids it entirely and is faster. So **prefer
> arm64 unless you specifically need orca**; choose amd64 only for the x86_64-only
> apps. The setup script therefore defaults to **the Mac's own architecture** —
> arm64 on Apple Silicon — and prints which one it picked. Set
> `AIRLOCK_ARCH=amd64` to opt into Rosetta for orca. (It used to default to amd64,
> which put the stock config on the discouraged path without saying so.)

## 5. Per-app notes for the containerized run

| App | In-container status | Notes |
|---|---|---|
| hub | ✅ | static + nginx; the entry point |
| paseo | ✅ (cleanest) | pure Node; binds loopback; needs agent CLIs (claude/codex/gemini) on PATH |
| fileview, publish, notepad, dev-monitor | ✅ | Go/Python backends, loopback |
| devterm | ✅ | needs PTY (`/dev/pts`) — present in OrbStack |
| code-server | ✅ (arm64 or amd64) | installer pins both assets |
| **dev-monitor caveat** | ⚠️ | reports the **env's** view (its /proc, services), **not the Mac host**. Expected — it monitors the Airlock box, which is now the env. |
| **orca** | ⚠️ opt-in / heavy | apt Electron deps + **Xvfb** + AppImage extract + **nft system unit** + binds `0.0.0.0`. Needs `NET_ADMIN` for nft; x86_64-only. **Recommend leaving orca disabled** in the home-server config unless you specifically want it. If enabled without nft privilege, the loopback lock can't apply — rely on the env boundary and keep the env off any bridged/exposed port. |

## 6. Persistence (volumes / mounts)

Persist so a rebuild doesn't lose identity or work:

- **Tailscale state** — `/var/lib/tailscale` (else you re-auth every boot).
- **Your code** — mount the Mac dir you actually edit into the env. In an
  OrbStack machine, Mac files are visible under `/mnt/mac/Users/<you>/…` and the
  tools reach them there; there is no path to configure (fileview serves the
  guest's whole filesystem — see `SECURITY.md`). Mount a project directory rather
  than your Mac home: whatever you mount is readable and writable by the owner
  and every collaborator, and nothing in the guest can see far enough to warn you.
- **`airlock.toml`** — the single source of site facts.
- **App state / home** — `$HOME` (code-server config, paseo `~/.paseo`,
  filebrowser db, publish share dir, orca pairing).

## 7. What's in the repo (`docker/`)

- `orbstack-machine-setup.sh` — **recommended path.** Idempotent helper that
  creates the OrbStack machine at the Mac's own architecture (override with
  `AIRLOCK_ARCH`), installs base packages, brings up Tailscale, and runs the
  stock installer.
- `Dockerfile`, `docker-compose.yml`, `.dockerignore` — **experimental**
  systemd-in-Docker alternative (path B).
- `airlock.env.example` — env template (`TS_AUTHKEY`, timezone, platform).
- `README-macos.md` — step-by-step user instructions.

## 8. Verification status & open risks

**Verified on hardware** (an Apple Silicon Mac mini — M2, macOS 15):
- OrbStack 2.2.1 installs from the direct `.dmg` (no Homebrew/CLT needed) and
  the engine runs in the logged-in GUI session.
- `orb create -a amd64 ubuntu:24.04` → the machine is **x86_64 (Rosetta)** with
  **systemd as PID 1**, working `apt`/`sudo`, and the Mac fs mounted at `/mnt/mac`.
- Base packages install: nginx, node 20, python 3.12, tailscale 1.98, nft, tmux.
- The **stock installer runs end-to-end in `AIRLOCK_DRY_RUN=1`** for all 8 apps
  (hub, devterm, fileview, publish, notepad, dev-monitor, code-server, paseo) —
  config validate, nginx render, per-app systemd `--user` units, `tailscale
  serve` mappings, and nginx fragments all produced correctly (`RC=0`).

**Finding — nginx systemd unit under emulation:** the packaged nginx unit is
`Type=forking`; under the amd64/Rosetta machine systemd fails to detect the fork
and start times out (~90s) although nginx itself starts fine. Fix: a
`Type=simple` + `daemon off` drop-in (now applied by `orbstack-machine-setup.sh`
§2b). This is the main reason **arm64-native is the better default** (§4) — it
avoids the emulation entirely; the drop-in is harmless there anyway.

**Full real install verified** (same box, same day, 7 apps — orca off):
- Upstream downloads under Rosetta succeeded (ttyd, filebrowser, markserv/paseo
  via npm).
- `tailscale up` created the resident node and `tailscale serve --https=443`
  exposed the hub; the entry point returned **200** to the owner over the tailnet
  and `/whoami` reported the owner login.
- The identity gate was confirmed at the loopback nginx: **owner=200,
  non-owner=403, no-header=403**.
- All 7 `systemctl --user` units came up `active` — with **user lingering
  enabled** (`loginctl enable-linger`), now done by the setup script §2c. This
  was the one gap found: a fresh machine has nginx installed-but-stopped, so the
  installer's `systemctl reload nginx` fails until nginx is started (the drop-in
  step §2b starts it) — and `--user` units need lingering to persist.

**Still NOT verified:** orca's Xvfb + nft path under emulation (highest risk —
hence opt-in), and code-server (arm64 or amd64 — both assets pinned) end-to-end.

**Recommended first run:** enable only hub + paseo + devterm + fileview +
publish + notepad + dev-monitor + code-server (orca off). Confirm the entry point
and one agent app end-to-end, then decide whether orca is worth its cost.
