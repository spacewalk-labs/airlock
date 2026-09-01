---
name: airlock-ledger
description: Recover a packaged-app registration, upgrade, or removal when Airlock's installed-state ledger reports an intent, a refused removal, or a failed reconcile. Use before editing any ledger file or deleting registered app artifacts.
---

# airlock-ledger

Repair a packaged app by replaying Airlock's lifecycle. The ledger is the record
of what an installation was allowed to create; do **not** edit it or remove its
files, units, nginx fragments, containers, or Tailscale mappings by hand.

This procedure assumes the normal Airlock host prerequisites (Tailscale, nginx,
and the selected app's prerequisites) are present. If the preview stops at a
missing prerequisite, resolve it through `skills/airlock-deploy/SKILL.md` first,
then restart at section 1.

## 1. Freeze the symptom and identify the app

Run on the box and as the user that normally runs Airlock. First set the checkout
and the same config file used by the install. If the install output already names
an app id, use that exact id below.

```bash
ROOT="$(git -C /path/to/airlock rev-parse --show-toplevel)"
CONFIG="/path/to/airlock.toml"

AIRLOCK_CONFIG="$CONFIG" python3 "$ROOT/bin/airlock-config" validate
AIRLOCK_CONFIG="$CONFIG" python3 "$ROOT/bin/airlock-config" package-info \
  | "$ROOT/bin/airlock-ledger" list
AIRLOCK_CONFIG="$CONFIG" python3 "$ROOT/bin/airlock-config" package-info \
  | "$ROOT/bin/airlock-ledger" plan
```

`list` shows the recorded state; `plan` says what the ordinary installer will
do. Save this output with the app id and timestamp. A corrupt ledger, invalid
configuration, or a ledger-lock error is a stop condition: do not create an
empty ledger or run a second installer alongside the first one.

If the error says another Airlock run holds the lock, let that run finish, then
run this section again. The lock is released when its process exits; deleting a
lock file does not safely release a live process.

## 2. Preview the lifecycle before changing the box

```bash
AIRLOCK_DRY_RUN=1 AIRLOCK_CONFIG="$CONFIG" bash "$ROOT/install/airlock-install.sh"
```

The preview validates first and prints the reconcile work. It does not execute
an explicit third-party package installer, so it is a plan check, not proof that
the app will start.

On a shared box, read the entire preview before section 3. If it includes an
app you did not intend to recover, **stop**: do not use that configuration as a
registration/removal test and do not edit the live configuration to make it
smaller. Obtain an owner-approved, disposable app configuration whose preview
names only the test app, then restart at section 1 with that configuration.
The ordinary installer reconciles every app in its configuration, not only an
app name seen in `list`.

Do not mistake a shared box for a fresh restore target either. On the measured
shared-box inventory, Airlock's **fresh-box restore preflight** refused 51
existing-artifact findings. That is the guard working: preserve those existing
apps and use the disposable container harness in section 5 for a lifecycle
proof. It is not a reason to remove artifacts or to make the shared box fit a
test configuration.

Use `plan` plus the config as the decision table:

| `plan` output | Meaning | Next action |
|---|---|---|
| `fresh`, `reinstall`, or `upgrade-diff` | The app remains desired. | Continue with the ordinary install in section 3. |
| `upgrade-deactivate` | The package changed and has a recorded deactivator. | Continue with the ordinary install; it deactivates before reinstalling. |
| `remove` or `teardown-intent` | The app is no longer configured or a prior install stopped before commit. | Confirm that removal is intended, then continue with the ordinary install. |
| `refuse` | A removed package did not record a deactivator. | Use the explicit teardown in section 4; never delete the record by hand. |

## 3. Recover a desired app or ordinary removal

For an app that should be installed, repaired, upgraded, or normally removed,
run the orchestrator once. It serializes the ledger lifecycle as
`plan → intent → installer → gate/smoke → commit` and retains an intent if a
later step fails so the next run can recover it.

```bash
AIRLOCK_CONFIG="$CONFIG" bash "$ROOT/install/airlock-install.sh"
```

Then repeat the three commands from section 1. For a desired app, it should be
`state=committed`; for a successfully removed app, it should no longer appear in
`list` or `plan`. Also run the app's smoke check or `skills/airlock-doctor` when
the ledger is clean but the app remains unavailable.

If the installer reports a failed deactivation, do not install over it. Keep the
record, fix the reported host prerequisite or package problem, and re-run the
same command. The ledger intentionally retains a failed record so that its
artifacts cannot become orphaned.

## 4. Remove an explicitly teardown-only app

Only use this path after both `[apps.<id>]` and `[packages.<id>]` have been
removed from `airlock.toml`, and only when `plan` says `refuse` or the installer
names this command. It is destructive: preview it first.

```bash
AIRLOCK_DRY_RUN=1 AIRLOCK_CONFIG="$CONFIG" bash "$ROOT/bin/airlock-teardown" <app-id>
AIRLOCK_CONFIG="$CONFIG" bash "$ROOT/bin/airlock-teardown" <app-id>
```

This is platform-performed teardown: it removes the recorded artifacts but does
not run the package's missing deactivator. Re-run section 1 afterwards and
confirm that the entry is gone. `--adopt` is different: use it only when
Airlock's own `adopt-scan` output printed the exact command for an old built-in;
it is not a general repair switch.

## 5. Prove the full lifecycle without touching a shared box

For an end-to-end registration/removal proof, use Airlock's approved container
harness. Its `in-container.sh` payload has its own configuration for `hub` and
the disposable `hello-example` package, and exercises install, rerun, upgrade,
and removal. **Do not run that payload directly on the host.** The host-side
wrapper creates and destroys the container around it. Follow `live/README.md`'s
`Running it` section to provide the approved `AIRLOCK_LIVE_*` environment, then
run from the Airlock checkout:

```bash
ROOT="$(git -C /path/to/airlock rev-parse --show-toplevel)"
docker info >/dev/null
AIRLOCK_LIVE_PUBLISH=none bash "$ROOT/live/verify.sh"
```

Never point the example configuration at a live host, or bypass `verify.sh`:
its ordinary installer reconciles the entire configuration and can remove apps
not named there. If the approved live environment is unavailable, do not invent
its connection, owner, key, storage-pool, or tracking values. Record the
wrapper's final successful lifecycle output and the checkout revision. The
wrapper publishes to GitHub by default; only an operator who intends that
publication should omit `AIRLOCK_LIVE_PUBLISH=none` and provide its approved
tracking-issue number.

If the wrapper stops while creating its named container, preserve its run id and
local result record, then confirm only that exact container name is absent or
cleaned up. Do not reproduce the launch with a hand-written `lxc launch` on a
shared host: the wrapper's ownership nonce and cleanup are what limit the run to
its own container. Escalate the wrapper's reported failure to the host owner,
including its stage and run id.

## Stop and escalate

- A package-lock digest mismatch, a malformed/corrupt ledger, or an unfamiliar
  capability/refusal is fail-closed by design. Preserve the full diagnostic and
  escalate with the app id, `list`, `plan`, and the Airlock revision. Do not run
  `audit-lock-override` by hand.
- Do not run `airlock-ledger intent`, `commit`, `remove`, or `teardown` directly
  during normal recovery. The installer/teardown wrapper supplies the writer
  lock, config snapshot, active-port protection, and ordering they require.
- Do not run an explicit teardown for an app that is still enabled in config.
  Restore or change the config first, then repeat the decision table.
