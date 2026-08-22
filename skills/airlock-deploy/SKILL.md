---
name: airlock-deploy
description: Install or re-deploy Airlock on this box from airlock.toml — validate config, run the orchestrator, and verify the gate + each enabled app. Use when setting up a new Airlock, enabling/disabling an app, or applying config changes.
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
   help the user fill in `[auth] owner`, `[paths] code_root`, and the app tables
   they want. A table's mere presence under `[apps.*]` enables that app.
   `code_root` is required whenever `[apps.markwand]` is enabled, and is not a
   free choice: everything under it is served read+write to the owner
   **and every collaborator**. Ask before accepting a home directory, and read
   `SECURITY.md` ("Two tiers") with the user if they are adding collaborators.
3. **Python ≥ 3.11** (for `tomllib`). Per-app extra prereqs are listed in each
   `apps/<name>/README.md` (e.g. markwand needs node; paseo needs node ≥ 20).

## Deploy

```bash
# 1. Validate before touching anything (fail-closed: provider must be tailscale).
bash -c 'cd <repo> && python3 bin/airlock-config validate'

# 2. Dry-run to preview every system-mutating step (no changes made).
AIRLOCK_DRY_RUN=1 bash install/airlock-install.sh

# 3. Real deploy. Needs sudo for nginx + tailscale serve steps.
bash install/airlock-install.sh
```

The orchestrator is **idempotent** — re-run it after any `airlock.toml` edit. It
validates config → runs each enabled app's installer (which drops an nginx
fragment) → renders the site → `nginx -t` + reload → `tailscale serve` for the hub
and the separate-port apps → smokes every enabled app.

## Verify (state what passed / what didn't)

- The orchestrator runs each app's `apps/<name>/smoke.sh` after reload; a smoke
  checks the gate is real: **owner = 200/302, denied identity = 403, missing
  header = 403.** A `GATE HOLE` failure is security-critical — do not hand off.
- `sudo nginx -t` is clean.
- `systemctl --user status 'airlock-*'` — enabled app backends are active.
- `sudo tailscale serve status` — the hub (443 + http port) and each separate-port
  app (devterm/code-server/orca/paseo) are mapped to their loopback gate.
- Open: `https://<this-box>.<tailnet>/` — the hub launcher lists the enabled apps.

## Notes

- Separate-port apps (devterm, code-server, orca, paseo) get their own
  owner-only gate + `tailscale serve` port. Same-origin subpath apps (markwand,
  publish, notepad, dev-monitor) live under the hub and inherit its single
  server-level identity gate.
- Secrets (e.g. the optional publish external-target token) go in an
  EnvironmentFile, never in `airlock.toml`.
- If something is wrong after deploy, use the **airlock-doctor** skill.
