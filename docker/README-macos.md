# Airlock on macOS (personal home server)

Airlock's stack is Linux-native (systemd, nginx, `tailscale serve`, some
x86_64-only binaries). You don't port it to macOS — you run the Linux stack in
a Linux environment that your Mac hosts, with **one codebase**. On Apple
Silicon the practical host is **[OrbStack](https://orbstack.dev)**.

Full rationale and the OS-coupling map: [`../docs/design/macos-container.md`](../docs/design/macos-container.md).

> **Status:** a **full real install now passes end-to-end on an arm64 machine**
> (Apple Silicon Mac mini, M2, 8 GB — 2026-07-26): downloads + `tailscale up`/`serve`
> + the gate, with **all app smokes green** (owner=200, non-owner=403) for
> hub/devterm/markwand/publish/notepad/dev-monitor/paseo. **arm64 is the default** —
> the setup script now takes the Mac's own architecture, and prints which one it picked.
> Two arch caveats found in that run:
> - **amd64/Rosetta is not recommended.** It installs, but the installer's
>   `systemctl reload nginx` (after rendering the site) *deactivates* nginx under
>   Rosetta — systemd can't track the process (`Inappropriate ioctl`) — so the hub
>   drops and smokes fail. (A separate ordering bug — the nginx `Type=simple`
>   drop-in was applied *after* `apt install nginx`, so nginx's postinstall start
>   timed out and aborted the whole apt run — is now **fixed** in the setup script
>   by pre-seeding the drop-in *before* install.)
> - **`orca` is x86_64-only** (no arm64 build upstream) — leave it out of an arm64
>   machine's `airlock.toml`; add it only on an amd64 machine (accepting the caveat
>   above). **`code-server` now installs on arm64** — its installer was taught the
>   arm64 asset + sha256 (code-server ships `linux-arm64` builds), so it is part of
>   the arm64-verified set.
>
> Details: [`../docs/design/macos-container.md`](../docs/design/macos-container.md) §8.

---

## Path A — OrbStack machine (recommended)

An OrbStack *machine* is a full systemd Ubuntu userland, so Airlock's
`systemctl --user` units, the publish timer, and orca's system unit all work,
and you run the **stock installer** unchanged. The machine is native by default
(arm64 on Apple Silicon); the one x86_64-only app, `orca`, needs an `amd64`
machine under Rosetta — see Architecture in Notes.

### 1. Install OrbStack
Download from https://orbstack.dev and launch it once. Keep the Mac awake and
on power (a home server shouldn't sleep): System Settings → Energy → prevent
sleep, or run `caffeinate -s` in a login item.

### 2. Get the repo + config on your Mac
```bash
git clone <your-fork>/airlock && cd airlock
cp airlock.toml.example airlock.toml
$EDITOR airlock.toml
```
In `airlock.toml`:
- set `[auth].owner` to your Tailscale login (e.g. `you@example.com`);
- set `[paths].code_root` to the code you want the tools to edit — inside the
  machine your Mac files appear under `/mnt/mac/Users/<you>/…`, so e.g.
  `code_root = "/mnt/mac/Users/<you>/code"`. Name a project directory, not a home
  directory: everything under it is served read+write to the owner and
  every collaborator ([SECURITY.md](../SECURITY.md#two-tiers-and-what-a-collaborator-actually-gets));
- for the **first run, leave `[apps.orca]` out** (it's the heaviest app — Xvfb,
  nft, x86_64). Add it later once the rest works.

### 3. (Optional) a Tailscale auth key for non-interactive setup
Generate a reusable key at https://login.tailscale.com/admin/settings/keys and:
```bash
export TS_AUTHKEY=tskey-auth-xxxxxxxx   # a SECRET — don't paste it elsewhere
```
Skip this to authenticate interactively (the script prints the login URL).

### 4. Run the setup helper (on the Mac)
```bash
bash docker/orbstack-machine-setup.sh
```
It creates the machine at **your Mac's own architecture** (arm64 on Apple Silicon
— the verified path), installs prerequisites, brings up Tailscale, and runs
`install/airlock-install.sh`. Re-run it any time after editing `airlock.toml`.
The first line it prints is the architecture it chose and where that came from.

### 5. Open it
Visit the URL the script prints — `https://airlock.<your-tailnet>.ts.net/` —
from any device on your tailnet, and **add to home screen** for the PWA.

**Manage it** like a small box:
```bash
orb -m airlock                       # shell into the machine
orb -m airlock systemctl --user status airlock-paseo    # check an app
orb -m airlock -u root tailscale status
```

### 6. Update it later
An installed checkout has no remote pointing here — step 2 has you drop `.git` and start
your own repository — so `git pull` has nothing to fetch and
`merge --allow-unrelated-histories` conflicts on every changed file. Use this instead:

```bash
bash bin/airlock-update              # --dry-run first to see what would change
```

**If your checkout predates this script** (it landed 2026-08-22), it is not in your tree
yet. Fetch and run it in one line — the release repository is public, so no login:

```bash
curl -fsSL https://raw.githubusercontent.com/spacewalk-labs/airlock/main/bin/airlock-update | bash
```

After that first run, `Update Airlock` sits at the top of the checkout and a double-click
runs it. That works with no Developer ID and no notarisation because the file arrives by
`git`, and Gatekeeper's quarantine flag is set by whatever *downloads* a file.

It writes the release tree over the checkout and commits the result to **your** repository,
so the file update is one `git reset --hard` from being undone. Two limits on that:

- It restores **this checkout**. It does not roll back what the installer did inside the
  Linux machine — `/opt/airlock`, the user units, the rendered nginx config, package
  versions. Undoing the files and re-running the installer is what returns the box.
- Anything the installer changed keeps running until you do.

What it will not touch: `airlock.toml` (in `.gitignore` on both sides, so no tree carries
it), and any file it does not recognise — those are listed and left. Files that your
checkout's older `.gitignore` happens to hide but the release does carry are committed
first, so the undo restores them rather than deleting them.

On a Mac it finds the machine Airlock is installed in rather than assuming the name.
`orbstack-machine-setup.sh` defaults to `airlock`, so if you named yours something else a
default-named run would build a **second** machine and install into it — a successful-looking
update that leaves your box untouched. Only running machines are probed (`orb run` starts a
stopped one). If two qualify, or if you pass a `--machine` name that has no Airlock in it,
it stops and says so rather than guessing.

---

## Path B — systemd-in-Docker (experimental)

A reproducible image/compose, for people who want a committed container artifact
instead of a machine. systemd-as-PID1 in Docker needs cgroup access and is
fragile to test blind — **Path A is recommended.**

```bash
cp docker/airlock.env.example docker/airlock.env   # fill in TS_AUTHKEY
cp airlock.toml.example airlock.toml               # owner, apps, code_root=/code
# point your real code dir in at /code:
export AIRLOCK_CODE_DIR="$HOME/code"
docker compose -f docker/docker-compose.yml up -d --build
docker logs -f airlock                             # watch first-boot install
```
If you didn't set `TS_AUTHKEY`, authenticate once then restart:
```bash
docker exec -it airlock tailscale up
docker restart airlock
```

---

## Notes

- **GPU:** none available to the Linux guest (Virtualization.framework doesn't
  expose Metal; Apple Silicon has no CUDA). Airlock needs no GPU — its AI agents
  call remote model APIs. Do local GPU work elsewhere.
- **Architecture:** the default is your Mac's own — arm64 on Apple Silicon (native,
  lighter, and the end-to-end-verified path — see Status). Override with
  `AIRLOCK_ARCH=amd64` only if you need `orca` (x86_64-only), accepting the
  `systemctl reload nginx` breakage noted in Status. Either way the script prints
  the architecture it used and whether you chose it or it was detected.
- **orca** is x86_64-only (no arm64 build) and heavy — leave it out of an arm64
  machine. **`code-server` runs on arm64** (installer takes the `linux-arm64`
  asset). The arm64 set that installs and smokes clean is: hub, devterm, markwand,
  publish, notepad, dev-monitor, paseo, code-server.
- **Secrets:** `docker/airlock.env` and `airlock.toml` are gitignored. Keep your
  `TS_AUTHKEY` out of logs and commits.
- **If OrbStack itself is down** (the machine is unreachable and `orb` reports no
  engine), two things surprise people:
  - `orbctl start` brings up **only the engine** — the machines stay down. Use
    `orbctl start --all`, or start yours by name.
  - Starting OrbStack from an **SSH session** leaves it unable to recreate its
    socket, so `orb` keeps failing. Start it in the Mac's GUI session instead:
    `launchctl asuser $(id -u) open -ga OrbStack` — the machines come back with it.
