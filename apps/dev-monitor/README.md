# dev-monitor

Per-box observability — CPU, memory, services, scheduled jobs, network, storage, top
processes and recent unit logs — served as a same-origin subpath under the hub at `/monitor/`. Observability needs no agent or
`psutil`: the backend reads `/proc` and shells out to `systemctl`/`journalctl`, so it runs
in a minimal container. Observability is visible to the owner and collaborators.

The Services section reads typed systemd state including result, substate and restart
count. A failure, non-zero restart count, missing unit, or enabled inactive daemon raises
the System badge and opens that otherwise-collapsed section. Successful completed
`oneshot` jobs and intentionally disabled inactive services remain healthy controls. This
path is local and always on; it does not depend on the optional message console.

The user-service inventory includes concrete `airlock-*` units, enabled services,
timer-targeted services, and loaded failures. It deliberately omits healthy incidental
static/generated helpers. Observation is not restart authority: only concrete `airlock-*`
units rediscovered through the original Airlock-only sources and confirmed by canonical systemd
`Id` receive a restart action; aliases, timer-only names, and dev-monitor itself remain excluded.

Optionally it also carries an **owner-only message and action console** (`messages = true`,
default off). That half is described below; if you leave it off, everything below is inert.

## Scheduled jobs

The **Cron** tab is the absorbed cron-console: one screen for systemd user/system timers,
the owner's crontab, `/etc/crontab`, `/etc/cron.d`, run-parts directories, and the current
boot's cron journal evidence. Failed, late, unavailable and reboot-unsafe are separate
verdicts; a source that cannot be read stays in `sources[]` and on screen instead of
silently becoming “no jobs”. The collector is part of this backend—there is no sidecar
unit, second port, nginx fragment or separate app package.

The tab is **read-only, on every install**. It has no run, pause or resume control and no
route behind one: a screen that can start a box's jobs is a screen whose compromise starts
them, and the value of watching does not need that. Jobs are changed on the box itself,
over SSH, which is where the rare emergency belongs. This does not depend on the owner
console below — enabling messages must never quietly enable job control with it, so the
write surface is absent rather than gated.

## Messages: one spool, one loop, one webhook

A producer publishes a JSON file. The collector records the receipt and creates or
updates a daily card in one SQLite transaction. Normal cards stay in the console;
urgent cards are sent to the configured Slack webhook. The owner can read, archive
or run a card. Reading and delivery are independent: Slack delivery does not mark
something read, and reading does not cancel a queued delivery.

```text
Producer → spool/new → loop (2 seconds) → ledger + cards → Slack
                           ↑                 ↑
                    heartbeat timer    owner dashboard/API
```

The loop collects, sends one due card with a two-second HTTP timeout, and performs
maintenance every 15 minutes. It retries without sleeping through collection.
There are four permanent backend roles: the HTTP main thread, the message loop,
and the two existing observation samplers. HTTP requests may briefly add a thread.

### Message format

The current message has eight fields, with no schema version:

```json
{
  "id": "backup:2026-09-10",
  "group": "backup",
  "source": "backup",
  "level": "urgent",
  "title": "Backup has not completed",
  "body": "Check the latest backup before the next scheduled run.",
  "link": "https://example.test/jobs/backup",
  "run": {
    "cwd": "/path/to/project",
    "prompt": "Check the current backup state and recover it if needed."
  }
}
```

`id`, `group`, `source`, `level` and a nonempty `title` are required. `body` is text
and defaults to empty; `link` and `run` are optional. IDs/groups/sources use 1–128
ASCII letters, digits, dots, underscores, colons or hyphens. The `dev-monitor:` ID/group
prefix remains reserved. Links must be absolute
HTTP(S) URLs. A run contains exactly nonempty `cwd` and `prompt` strings. Files
larger than 16 KiB, filename/ID mismatches and invalid payloads are quarantined.

The transitional aliases `event_id`, `group_key` and `urgency` remain accepted;
conflicting old/new names are rejected. A legacy optional `created_at` must be an
aware timestamp and no more than five minutes in the future. Coalescing uses the
collector's receipt time, so a delayed spool backlog still coalesces. New producers
should use the eight-field format. The emitter's old kind/outcome/why/followup and
skill/exec CLI options have been removed.

Within 24 hours of the first receipt, an unarchived card with the same group, run
and link is updated: its count grows, title/body and last receipt time advance,
and it becomes unread. Different runs or links get separate cards. Urgency can
rise from normal to urgent, which queues the card; another receipt for an already
urgent card does not queue another notification. Repeating an ID never adds a
receipt or delivery. Heartbeat IDs stay separate from ordinary same-group cards.

Example from the repository root, using an already installed writable spool:

```sh
python3 apps/dev-monitor/examples/emit_message.py \
  --spool "$DEV_MONITOR_SPOOL" --source backup --group-key backup \
  --level urgent --title 'Backup has not completed' \
  --body 'Inspect the current backup state.' \
  --cwd /path/to/project --prompt 'Inspect and recover the backup if needed.'
```

The emitter writes to `tmp/` and hard-links a complete file into `new/`; it does
not create a missing spool. “Queued” means published, not accepted or delivered.

### Tap Run

The Run button sends `POST /api/owner/run {"card_id":"…"}` through the existing
owner gate. The backend resolves an existing working directory strictly below
`exec_cwd_root` (default: the user's home), selects the configured agent, and opens
a tmux window immediately. The prompt remains one argv element through tmux and
the runner, including trailing semicolons, quotes and newlines. For a coalesced
card the backend appends `last_at` and `count`; the agent checks current conditions
before acting. Provider-specific CLI spelling and the agent fallback remain.

`ran_at` records a successful window launch, not task completion. Failed launches
leave it unchanged. tmux and an available agent CLI are needed for Run; their
absence does not disable message collection or observation. No approval dialog,
message plan, message execution table or message completion state machine exists.
The shared runner's executable-plan/completion-file path remains solely for the
separate update/harness features.

The existing owner and proxy-secret checks apply on every request. Writes also
check origin, content type and body size. Ordinary `/api/run` is not an execution
route. Publishing a spool message does not authorize execution.

### Storage, delivery and retention

| Table | Columns |
|---|---|
| `ledger` | `id` PK, `group`, `source`, `received_at`, `payload` |
| `cards` | `card_id`, `group`, `level`, `title`, `body`, `link`, `run`, `count`, `first_at`, `last_at`, `read_at`, `archived_at`, `ran_at`, `sent_at`, `send_attempts`, `send_next_at` |

The ledger is append-only within its retention period. Owner actions mutate only
cards. Receipt files and ledger rows expire after 180 days; cards expire when
their last receipt is that old. If more than 20 cards are active, the maintenance
pass can archive excess cards that have been read and idle for 48 hours.

A non-null `send_next_at` denotes a pending notification. All failed HTTP attempts,
including 500, 429 and other 4xx responses, retry up to **six total attempts,
including the first POST**. Delay starts at 30 seconds plus jitter and doubles;
a valid 429 Retry-After can lengthen it. After the sixth failure the card shows
“Delivery failed”. No configured webhook means collection continues and new urgent
cards remain pending. `/api/health` reports webhook configuration, pending count,
last send time and failed count.

Delivery is at least once. The loop POSTs before committing `sent_at`. If it dies
after the remote response but before that commit, restarting sends again. The
ledger ID still prevents a second receipt/card. There is no delivery claim table
or separate sender thread.

### Spool and heartbeat

```text
spool/tmp/          producer staging
spool/new/          complete published files
spool/processing/   private retained receipts for rollback
spool/bad/          rejected files and adjacent .reason files
```

The installer creates a separate system writer identity. State/spool parents are
0710; `tmp/` and `new/` are setgid+sticky 3770; `processing/`, `bad/` and the DB are
collector-only. The collector snapshots accepted bytes into a private inode before
committing, so an open producer descriptor cannot change a retained receipt.
Permanent rejected input is quarantined once; SQLite busy/full errors preserve
replayable files. Successful receipts remain until the 180-day cleanup, which
removes files before ledger rows. The old collector can replay those files after
a database rollback.

The writer's nftables rule permits loopback and rejects external egress. A
boot-enabled system unit restores that rule; the collector requires it to be
active. See [SECURITY.md](../../SECURITY.md) for the publishing/execution boundary.

With messages enabled, `airlock-devmon-heartbeat.timer` runs at **UTC midnight**
(`OnCalendar=*-*-* 00:00:00 UTC`, `Persistent=true`). The producer and validator share
[devmon_heartbeat.py](backend/devmon_heartbeat.py): daily ID `heartbeat:YYYY-MM-DD`,
group/source `heartbeat`, level `urgent`, title `살아 있음 YYYY-MM-DD`, and the
canonical body. Ordinary messages cannot claim a reserved heartbeat ID or replace
its alive card through same-group coalescing.

A legacy heartbeat `created_at` may reflect a retry or manual start at any time
on that UTC day; its UTC date must match the ID. Same-day canonical republication
is a duplicate. A new UTC day creates a new heartbeat even when less than 24 hours
has elapsed. This is a shared content contract, not source authentication.
The external timer demonstrates the whole spool-to-Slack path by arrival.

## Configuration and app-specific secrets

```toml
[apps.dev-monitor]
backend_port = 19923
messages = true
slack_webhook_urgent_env = "DEVMON_SLACK_WEBHOOK" # a name, never the URL
# exec_cwd_root = ""                           # default: the user's home
# exec_session = "devmon-exec"
# spool_writer_user = "airlock-dev-monitor-writer"
# spool_writer_group = "airlock-dev-monitor-writers"
```

The installer creates the spool and generated `dev-monitor.env`, including the
owner/proxy gate. Turning messages off removes that generated environment file.
The only webhook configuration key is `slack_webhook_urgent_env`; an empty value
leaves it unconfigured. The retired routine, roster, compatibility-path and old
`slack_webhook_env` alias keys are rejected by configuration validation.

Put the selected credential in `~/.config/airlock/dev-monitor-secrets.env`, a
regular file owned by the installing user with exact mode 0600. The service loads
that app-specific file with systemd EnvironmentFile semantics. The installer never
copies secret values into generated configuration. It checks file ownership/mode,
then uses a name-only lexer before a temporary systemd checker interprets values.
Unselected assignments, app controls and execution-environment control names are
rejected; the reserved-name definition is [devmon_secret_names.py](backend/devmon_secret_names.py).
Even when messages are disabled, an existing secret file must pass these checks.

An unset/blank runtime selector permits the supported legacy direct variable
`AIRLOCK_DEV_MONITOR_SLACK_WEBHOOK_URGENT`. A nonblank selector is authoritative:
if its target is absent or whitespace-only, the webhook is unconfigured; it does
not fall back. The old direct alias is not supported. The same resolver is used
by the checker and backend. Dry-run validates names and metadata only and explicitly
does not prove systemd-loaded value semantics. A real install requires the user
systemd manager for that check.

After editing the secret file, rerun installer validation before restarting.
A direct service restart loads the file without rerunning the name/metadata check;
no additional launcher or ExecStartPre protection is claimed.

## Offline database conversion and rollback

An old schema is never converted during service startup. When `messages = true`, the
installer classifies the database before rendering or restarting the service. A legacy
database is converted inside that existing lifecycle: the backend and repository-owned
producer units are stopped and verified, cross-UID spool publishing is fenced, WAL is
checkpointed, and a private `messages.db.pre-endstate` backup is retained. Conversion is
performed on a temporary clone; row counts, canonical columns and SQLite integrity must
pass before the clone atomically replaces the old database. The normal spool hardener and
service restart then restore the configured runtime. A current database is a no-op, so a
retry does not create or overwrite another backup.

The backup has adjacent private manifest/target receipts used to distinguish a resumable
failed attempt from an unrelated file. An outer install also keeps one durable migration
receipt beside its existing package checkpoint; app success does not remove it, and final
transaction commit removes the checkpoint. On a later nginx/smoke failure or crash retry,
the outer installer re-fences producers and restores the DB only when the target marker
proves that the converted database has not received later writes. It records the failed
transaction and restores the old package only after DB compensation succeeds. The backup
is retained. A changed DB or failed restore is preserved as degraded state with the old
incompatible writers stopped and the receipt available for retry. Never use a live webhook
as a failure stub.

For an explicitly offline maintenance run, stop the service and producers and run
`python3 apps/dev-monitor/migrate-legacy-state.py --endstate <state>/messages.db --offline`.
Use `--schema-state <state>/messages.db` for a read-only `legacy`/`canonical`
classification and `--verify <state>/messages.db` for the canonical row/integrity check.

Every old card and receipt is preserved. Receiptless historical cards do not get
invented ledger rows. Pending/claimed deliveries become due cards and drain;
interrupted claimed rows at the old cap retain one possible attempt. Old failures
stay failed. Historical cards that were never queued stay unqueued, even if urgent.
Multiple open deliveries for a card become one due card on the single webhook.
Original attempts and all old events/errors/approvals/runs remain only in the backup.

To roll back, stop service/producers, checkpoint and close the current database,
then run `python3 apps/dev-monitor/migrate-legacy-state.py --restore-backup
<state>/messages.db.pre-endstate --restore-to <state>/messages.db --offline`
as one command. Revert the Phase 6 change, then start the old service and producers.
The old collector recovers retained `processing/` receipts and deduplicates against
the restored DB. Keep the backup. The tool's existing relocation, backup, restore
and resume safeguards remain available in `--help`.

## Credential freshness

`token_freshness = true` enables the Credentials panel and `/api/tokens`; its timer
is installed separately with `bash apps/dev-monitor/install-token-timer.sh`.
The defaults `token_freshness_warn_hours = 24` and
`token_freshness_stale_hours = 24` control warning thresholds. Use `--uninstall` to
remove the timer; `--no-messages` explicitly permits a snapshot-only installation.

The verdicts are ok, expiring-soon, expired and unknown. Missing or unreadable
metadata is unknown. Claude's refresh-token deadline is used when available;
Codex's last-refresh age indicates staleness and does not prove expiry. Credentials
are read for timestamp/presence metadata; token values are never logged or published.

The checker writes `token-freshness.json` and emits messages for unhealthy
providers: expired is urgent; other non-OK verdicts are normal. Those messages
coalesce by provider over 24 hours. Its OnFailure unit
leaves local evidence and emits an urgent message if the checker itself fails.
A failed optional message configuration never takes observation down; health
reports what actually started.

## Verification

Run from the repository root. Tests use disposable state and local recorders.

```sh
python3 apps/dev-monitor/backend/test_devmon.py
python3 apps/dev-monitor/test-backend.py
python3 apps/dev-monitor/test-run-contract.py
python3 apps/dev-monitor/test-loop-contract.py
python3 apps/dev-monitor/test-migrate-legacy-state.py
python3 apps/dev-monitor/test-heartbeat.py
node apps/dev-monitor/test-frontend-contract.mjs
python3 apps/dev-monitor/test-secret-resolution.py --systemd
bash install/test-monitor-spool-hardening.sh
```

For V14, supply an explicit private DB **copy** and the preceding backend checkout:
`python3 apps/dev-monitor/test-endstate-rehearsal.py --copy <copy.db> --old-backend
<preceding-checkout>/apps/dev-monitor/backend` (one command). It checks row contents,
local heartbeat delivery, exact backup restoration and replay by the old collector.
Synthetic pending/claimed cases are tested separately from the real-data rehearsal.
Local recorder/systemd checks do not establish a production reinstall or real Slack
arrival. Campaign status, scope exceptions and exact PR evidence are in
[the endstate task](../../docs/tasks/active/dev-monitor-endstate.md).
