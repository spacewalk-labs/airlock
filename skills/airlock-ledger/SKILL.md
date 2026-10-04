---
name: airlock-ledger
description: Recover or remove one Airlock app through the installed-state engine when apply reports restored or residue. Use before editing installation records or deleting app artifacts.
---

# airlock-ledger

Use the same checkout, user and configuration as the installed box. The engine
owns the installation record and projections; do not edit the record by hand.

```bash
ROOT="$(git -C /path/to/airlock rev-parse --show-toplevel)"
CONFIG="/path/to/airlock.toml"
AIRLOCK_CONFIG="$CONFIG" "$ROOT/bin/airlock-ledger" list
AIRLOCK_CONFIG="$CONFIG" "$ROOT/bin/airlock-ledger" plan
```

`list` shows each app's source, commit and artifact count. `plan` prints
`fresh`, `reinstall` or `upgrade-diff` with the app id. Company updates compare
that app's directory at its recorded commit against the mirror's current main.
A read does not convert the old v7 record on disk; the first successful write
creates the new record and archives v7.

Apply only the app being repaired:

```bash
AIRLOCK_CONFIG="$CONFIG" "$ROOT/bin/airlock-ledger" apply <app-id>
```

For a new Personal app, supply its directory with `--source /absolute/app/dir`.
For an explicit Company move, use `--source company`; its git URL comes from
`[site] company_repo`. A `[packages.<id>] path` line is not apply source authority.

Apply runs the install hook, stages that app's icon and ingress, refreshes the
nginx site and Hub manifest, then records its source, commit and artifacts. A
failed Company update replays its recorded starting commit once. Local and core
source failures report residue without replaying the same mutable checkout. `restored <id> <commit>` means
that replay succeeded; `residue <id>: ...` names what could not finish. Both
return nonzero. Fix the reported cause and repeat the same apply. Core apps use
the checkout in place; platform updates run `airlock-update`, and failed runs can be retried after fixing the reported cause.

Remove an app's recorded artifacts while preserving unrecorded user data:

```bash
AIRLOCK_DRY_RUN=1 AIRLOCK_CONFIG="$CONFIG" "$ROOT/bin/airlock-ledger" remove <app-id>
AIRLOCK_CONFIG="$CONFIG" "$ROOT/bin/airlock-ledger" remove <app-id>
```

Removal does not execute a deactivator. It reports residue and returns nonzero
if a recorded artifact or projection cannot be removed. Recheck `list` and run
the app's smoke check after apply when service readiness is the question.

For a box update or full installation, follow `skills/airlock-deploy/SKILL.md`
and `live/README.md`. Lifecycle verification uses disposable fixture roots:
`bash install/test-update.sh`. Never aim a test configuration at a shared box.
