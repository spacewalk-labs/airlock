# Airlock wiki (starter)

This directory is a **starter knowledge base** for your Airlock box. It is plain
Markdown you own — nothing here is required for Airlock to run. It exists so the
tools and any coding agents working on this box have a single place to read
durable, box-specific facts that aren't obvious from the code or git history.

Point `[paths] wiki` in `airlock.toml` at a wiki clone (or leave it empty to run
wiki-less). When set, the skill harness and the file viewer can surface it.

## Suggested layout

```
wiki/
  README.md          ← this file (index)
  setup/             ← how THIS box is set up (owner, apps enabled, quirks)
  decisions/         ← why things are the way they are (one file per decision)
  runbooks/          ← step-by-step for recurring ops (deploy, restore, rotate)
```

## What belongs here

- Durable, box- or team-specific facts: who the owner is, which apps you enabled
  and why, ports you changed, external services you wired (e.g. a publish target).
- Decisions with their rationale — the "why", so future-you (or an agent) doesn't
  re-litigate them.
- Runbooks for things you'll do again.

## What does NOT belong here

- **Secrets** — tokens, passwords, keys. Those go in an EnvironmentFile or a
  secret manager, never in the wiki (it's readable by anyone the hub gate admits).
- Things the repo already records: code structure, the install flow (`README.md`
  + each `apps/<name>/README.md`), the trust model (`SECURITY.md`).

Keep entries short and one-fact-per-file so they're easy to find and update.

## Back up and restore the Airlock installation contract

Run these commands as the OS user that owns the Airlock installation. The
administrative SSH account is only the access gate; restoring as `root` when the
box normally belongs to another user would create the wrong user units and state
paths.

Create a private archive from a fully checked installation whose tracked
checkout is clean:

```bash
python3 bin/airlock-backup create /private/path/box.airlock-backup
```

The destination is an output path, not a storage policy. Encryption, retention,
off-box copying, and storage cost are deliberately separate decisions. The tool
creates a new mode `0600` file and never overwrites an existing archive.

The archive has one fixed scope:

- exact `airlock.toml` bytes and their original absolute path;
- the operator checkout's Git revision, its content-addressed tree, and the
  complete `airlock-status --json` v1 report, accepted only when the process
  and document both say `rc=0`/`ok`;
- the absolute installed-state directory path;
- installed-state `app-ledger.json` and, when present,
  `plaintext-retirement.json`;
- repository-root `airlock.lock`, when present.

The path-to-member contract is exact; no directory is recursively copied:

| Source on the box | Archive member | Restore meaning |
|---|---|---|
| the path selected by `AIRLOCK_CONFIG`, otherwise `<checkout>/airlock.toml` | `config.toml` | exact bytes, restored to the new operator-selected config path |
| `$AIRLOCK_STATE_DIR/app-ledger.json`, otherwise `~/.local/state/airlock/app-ledger.json` | `records/app-ledger.json` | source install record and app-set authority; never installed as the new box's live ledger |
| the same state directory's `plaintext-retirement.json`, if present | `records/plaintext-retirement.json` | exact committed retirement record |
| `<checkout>/airlock.lock`, if present | `records/airlock.lock` | exact external-package digest grants |
| one successful `bin/airlock-status --json` run | `status.json` | source evidence; process rc and document must both be `0`/`ok` |
| generated metadata | `manifest.json` | source config/state paths, Git revision/tree, app set, hashes, and exclusions |

`$AIRLOCK_STATE_DIR/app-ledger.lock` is synchronization machinery, not an
installation record, and is not archived. `~/.config/airlock/**` is not copied:
that tree holds secret EnvironmentFiles on a real installation. The config may
declare their environment-variable names, but restoring their values is a
separate secret-provisioning prerequisite.

It does **not** include app-created data, a home directory, secret
EnvironmentFiles, tokens, credentials, or external/local package source trees.
Other untracked or ignored checkout files are likewise never included and make
backup/verification fail: ignored web assets and Python modules can still alter
what runs or installs. The only checkout exceptions are the selected config and
repository package lock, whose exact bytes are verified separately. Installed
state must live outside the checkout.
The config contract stores secret environment-variable names rather than secret
values. Backup also scans the frozen config and its comments for common
secret-bearing fields, credential-bearing URLs/query parameters, and embedded
key material; it reports key paths or line numbers only and refuses to create an
archive when one is found. This is a policy guard, not a general secret
classifier: if a secret was hidden under an innocent name, stop and remove it
before backup rather than treating the scanner as proof.

The archive's hashes detect corruption but do not authenticate who produced it:
an attacker able to replace both payload and manifest can recompute them. Restore
only archives received through a trusted path. Signing, encryption, key custody,
retention, and the storage trust boundary belong to the separate backup-storage
decision.

On a fresh checkout whose tracked tree matches the tree recorded in the archive,
restore with:

```bash
python3 bin/airlock-backup restore /private/path/box.airlock-backup
```

The default destinations are `<checkout>/airlock.toml` and
`$AIRLOCK_STATE_DIR` (otherwise `~/.local/state/airlock`); archive metadata never
chooses a write destination. Use `--config` or `--state-dir` to choose explicit
fresh destinations. A config that names a relative external package must keep
its original parent directory, because that directory is part of package
resolution. Restore refuses a dirty or different
tracked tree, a non-empty state directory, existing platform/app artifacts,
existing Airlock config or package lock, and existing Tailscale serve mappings;
it is not an overwrite or merge command.

`install/test-box-backup.py` is a deterministic contract fixture: it exercises
archive shape, fresh-target refusals, installer failure/resume, negative status
verdicts, byte/app-set comparisons, and path collisions with stubbed config,
installer, status, and Tailscale commands. It is not evidence of a real new-box
installation. That last axis requires the disposable LXD live harness and must
be reported as unverified when its host, owner, and short-lived Tailscale key
inputs are unavailable.

The source ledger stays in the archive as the installation record and comparison
authority. It is not copied into the live state directory: ledger records contain
absolute artifact paths, install nonces, and teardown authority from the old box.
The installer creates a fresh ledger on the new box, then restore requires the
new committed app set and plaintext-retirement record to match the archive.
If the installer or final verdict fails, a receipt binds the partial attempt to
that archive and target. After examining the failure, retry only that attempt:

```bash
python3 bin/airlock-backup restore --resume /private/path/box.airlock-backup
```

The receipt is the restore's first durable write, so a crash while creating the
config or package lock can recreate a missing sink through `--resume` without
overwriting a changed one. Its durable phase advances from `prepared` to
`installing`; a prepared retry still requires an empty state directory, so an
old source ledger cannot be mistaken for installer-created partial state. It is
removed only after the complete verdict is green. Cooperative Airlock writers
are excluded with one inherited ledger-lock descriptor held continuously from
the final fresh-state check through install and the green verdict; an actor
already able to write arbitrary files as the same OS user is
not a separate security boundary and can also replace the tool or checkout
itself.

`restore` runs this verification before it reports success. It can also be
repeated independently, and this is the acceptance command for a restored box:

```bash
python3 bin/airlock-backup verify /private/path/box.airlock-backup
```

Success means exact config and package-lock bytes, the recorded Git tree, a
clean tracked checkout with no unexplained untracked/ignored content, the same committed app set and retirement record, and a fresh
`airlock-status --json` result with exit code `0`. Exit code `3` (unchecked) is
always failure, even when no individual probe reported red. `bin/airlock-smoke`
is useful additional evidence but is not the restore verdict because an empty
app inventory can make that command return zero.
