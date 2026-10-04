---
name: airlock-deploy
description: Install or re-deploy Airlock on this box from airlock.toml — validate config, run the orchestrator, and verify the gate + installed apps. Use when setting up a new Airlock, applying or removing one app, or applying config changes.
---

# airlock-deploy

Deploy Airlock (a self-hosted developer workspace behind a Tailscale identity check) on the
current box. Everything site-specific lives in `airlock.toml`; the installer reads
it only through `bin/airlock-config`.

## Preconditions (check first, fail loud)

1. **Tailscale is up and authenticated** — Airlock's whole trust model is that
   `tailscale serve` is the sole ingress (it injects the verified identity header
   and strips client-supplied ones). Run `tailscale status`; if `BackendState`
   isn't `Running`, stop and tell the user to run `tailscale up`. Do NOT try to
   run Airlock behind another proxy — that is insecure-by-default (see SECURITY.md).
2. **`airlock.toml` exists.** If only `airlock.toml.example` is present, copy it and
   help the user fill in `[auth] owner` and the app tables
   they want. `[apps.*]` supplies inputs; `bin/airlock-ledger list` reports installed apps.
   The platform installer applies only recorded core apps from this checkout.
   On a fresh box, explicitly apply each chosen app after installing the platform.
   fileview has no path setting: it serves **the home directory of this box's user
   account**, read and write, to the owner **and every collaborator** if its audience
   is opened. Nothing above home is served.
   A leftover `[paths] code_root` is a retired key — tell the user to delete the
   line. Read `SECURITY.md` ("Two tiers") with the user before adding anyone to
   `collaborators`.
3. **Python ≥ 3.11** (for `tomllib`). Per-app extra prereqs are listed in each
   `apps/<name>/README.md` (e.g. fileview needs node; paseo needs node ≥ 20).

## Deploy

```bash
# 1. Validate before touching anything (fail-closed: provider must be tailscale).
bash -c 'cd <repo> && python3 bin/airlock-config validate'

# 2. Dry-run to preview every system-mutating step (no changes made).
AIRLOCK_DRY_RUN=1 bash install/airlock-install.sh

# 3. Install the platform and update recorded core apps from this checkout.
bash install/airlock-install.sh

# 4. First install of a chosen shipped app (repeat for each selected app).
python3 bin/airlock-ledger apply <id> --source "$PWD/apps/<id>"
```

🔴 **Do not stop any `airlock-*` unit yourself before running the installer.** The
installer already stops and restarts what it manages, and it does that from a
transient scope it moves itself into first (`airlock_escape_selfkill_cgroup` in
`install/lib.sh`), precisely so a run hosted by one of those units survives the
restart it asked for. A stop you issue beforehand happens **outside** that guard:
it kills your own session, and the installer never starts, so the box is left with
the unit down and nothing to bring it back.

That is not hypothetical. On 2026-09-07 a rollout prepended
`systemctl --user stop airlock-paseo.service;` to this command and sent it to two
boxes at once over ssh. Both daemons went down within four seconds of each other
(08:47:06Z and 08:47:10Z), the ssh connections died with the session that opened
them, the installer never ran on either box, and every agent session on both was
lost. One box stayed down for three minutes; the other for 93.

The full installer applies the platform and the recorded core apps whose source
is this checkout's `apps/` directory, then projects the shared ingress. A fresh
box receives the platform only. Company and Personal apps use their own apply.

To install or update one app, run `bin/airlock-ledger apply <id>` from the
installed clone. Supply `--source <absolute-app-directory>` on any first local install.
For Company, set `[site] company_repo` to its Git URL and use `--source company`.
Later applies use the recorded source; changing the Company URL requires explicit
`--source company` to replace that source.
To remove it, run `bin/airlock-ledger remove <id>`; recorded artifacts are removed
and user data stays. Read `bin/airlock-ledger list` for installed repo/commit facts.
A failed Company apply reapplies its recorded commit once. A failed local apply
reports failure without retrying the current source as a restore. Diagnose the
output before retrying; keep the operation scoped to that app.

## Verify (state what passed / what didn't)

- Run `bash apps/<name>/smoke.sh` for the app being verified after apply. A smoke
  checks the gate is real: **owner = 200/302, denied identity = 403, missing
  header = 403.** A `GATE HOLE` failure is security-critical — do not hand off.
- `sudo nginx -t` is clean.
- `systemctl --user status 'airlock-*'` — installed app backends are active.
- `sudo tailscale serve status` — the hub (443 + http port) and each separate-port
  app (devterm/code-server/orca/paseo) are mapped to their loopback gate.
- Open: `https://<this-box>.<tailnet>/` — the hub launcher lists installed apps.

## Notes

- Separate-port apps (devterm, code-server, orca, paseo) get their own
  owner-only gate + `tailscale serve` port. Same-origin subpath apps (fileview,
  publish, notepad, dev-monitor) live under the hub and inherit its single
  server-level identity gate.
- Secrets (e.g. the optional publish external-target token) go in an
  EnvironmentFile, never in `airlock.toml`.
- If something is wrong after deploy, use the **airlock-doctor** skill.
