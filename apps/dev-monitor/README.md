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
urgent cards are sent to the configured Slack bot (or legacy webhook) after a grace
window. The owner can read, archive
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

The current message has eight base fields, with no schema version:

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
    "prompt": "Check the current backup state and recover it if needed.",
    "params": [
      {"key": "mode", "label": "Mode", "choices": ["diagnose", "recover"], "default": "diagnose"},
      {"key": "scope", "label": "Scope", "default": ""}
    ]
  }
}
```

`detail` is optional source text, preserved verbatim in the ledger and shown in a
collapsed “원천 메시지” section in the console. The card carries the latest receipt's
detail; older originals remain in the ledger. Only the refined `title`/`body`
go to Slack: `detail` never does. It does not participate in coalescing or unread
decisions. Existing producers may omit it. `emit_message.py --detail` sets it.

`resolves` is an optional target `group` string (the same syntax and reserved-prefix
rule as `group`). Only this explicit field resolves an incident; titles such as
“recovered” have no special meaning. `emit_message.py --resolves backup` sets it.

Every new urgent card, including heartbeat and a normal-to-urgent promotion, waits
**300 seconds** before its first Slack attempt. Set the single backend environment
variable `AIRLOCK_DEV_MONITOR_SLACK_GRACE_SECONDS` to another number of seconds (`0` sends
immediately), for example in a service environment override. Repeat receipts do not
extend that deadline; collection, ledger storage and console visibility stay immediate.

A resolution received during that initial window cancels delivery. After a bot post,
the card's nullable `slack_ts` identifies the original message for `chat.update`;
no new Slack message is posted. The closed card has a `✅` title and one-line
resolution reason and is available in the existing **Archived** view. A subsequent
incident creates a new active card. When several open cards share the target group,
each eligible card is closed without changing the group/run/link coalescing key.

If no open target exists, or a target has no `slack_ts` outside the initial grace
window (for example a webhook delivery, a normal card, or an unsuccessful post),
the resolution follows ordinary card creation/coalescing with its own declared
level and unchanged group/run/link key. It remains in the ledger in every case. A failed update uses the existing six-attempt retry path and
appears in delivery health even though the closed card is archived. Switching back
to webhook while an update is pending does not turn that update into a new post.
Both bot methods check Slack's JSON `ok` and require a valid response `ts`.

`peek` is an optional boolean (default `false`): `true` also shows the card in Porthole's
Peek bubble (normal: 15s; urgent: up to 90s with a progress line), on top of the badge and
inbox every card already gets. Whether it appears is decided by `peek` alone and how it
appears by `level` alone. Like urgency it only rises on coalescing, it is returned by
feed/preview, and closing a Peek does not mark the card read. The bubble truncates by
width, not character count: budget about 20 Korean (31 Latin) characters of title and 45
(74) of body for the narrowest phone. `emit_message.py --peek` sets it.

`source: "slack"` marks a card that arrived over Slack, and two rules key on it. Such a
card is never queued for the outbound Slack notifier — that notifier exists to reach the
owner away from the console, and the card already reached them there; without the rule an
urgent mention echoes back into the channel it came from. And on coalescing into a Slack
card the owner has already read, the level follows the incoming message instead of rising:
reading means "seen up to here", so dismissed urgency is not inherited. Every other source
keeps the ordinary climb, where severity that fell on its own would hide a fault.
See `docs/design/slack-porthole.md` (private).

`id`, `group`, `source`, `level` and a nonempty `title` are required. `body` is text
and defaults to empty; `link` and `run` are optional. IDs/groups/sources use 1–128
ASCII letters, digits, dots, underscores, colons or hyphens. The `dev-monitor:` ID/group
prefix remains reserved. Links must be absolute
HTTP(S) URLs. A run contains nonempty `cwd` and `prompt` strings and may declare up
to eight `params`. Each parameter has a unique 1–128 character ID-like `key`, a
nonempty `label`, optional 1–32 unique nonempty string `choices`, and an optional
string `default` (which must be one of its choices when choices exist). Labels,
choices, and defaults are limited to 200 characters. Files
larger than 16 KiB, filename/ID mismatches and invalid payloads are quarantined.

The transitional aliases `event_id`, `group_key` and `urgency` remain accepted;
conflicting old/new names are rejected. A legacy optional `created_at` must be an
aware timestamp and no more than five minutes in the future. Coalescing uses the
collector's receipt time, so a delayed spool backlog still coalesces. New producers
should use the eight-field format. The emitter's old kind/outcome/why/followup and
skill/exec CLI options have been removed.

For as long as it remains open, a card with the same group, run and link is updated:
its count grows, title/body and last receipt time advance, and it becomes unread.
Different runs or links get separate cards. Daily heartbeat IDs never coalesce across
UTC days. Urgency can
rise from normal to urgent, which queues the card; another receipt for an already
urgent card does not queue another notification. Repeating an ID never adds a
receipt or delivery. Heartbeat IDs stay separate from ordinary same-group cards.

Example from the repository root, using an already installed writable spool:

```sh
python3 apps/dev-monitor/examples/emit_message.py \
  --spool "$DEV_MONITOR_SPOOL" --source backup --group-key backup \
  --level urgent --title 'Backup has not completed' \
  --body 'Inspect the current backup state.' \
  --cwd /path/to/project --prompt 'Inspect and recover the backup if needed.' \
  --peek
```

The emitter writes to `tmp/` and hard-links a complete file into `new/`; it does
not create a missing spool. “Queued” means published, not accepted or delivered.

### HTTP ingest from remote producers

With messages enabled, remote producers can send the same JSON to
`POST https://<tailnet-host>:19926/api/ingest`, with the token in
`X-Devmon-Ingest-Token`. Configure `ingest_port` to change the HTTPS port.
This dedicated tailscale serve listener admits tagged nodes without a user-login
header; the app token authenticates publication. It exposes only this POST route,
clears owner/proxy headers, and returns 404 for all other paths and methods,
including GET and HEAD. The hub and its identity gate remain separate;
`/monitor/api/ingest` is not a supported route. Publishing a message does not
authorize reading cards or running their actions.

Declare `DEVMON_INGEST_TOKEN` in the mode-0600 app-specific
`~/.config/airlock/dev-monitor-secrets.env`. The installer checks the assignment
name only, without loading its value, and writes
`DEVMON_INGEST_TOKEN_NAME=DEVMON_INGEST_TOKEN` to the generated message environment.
If the name is absent, installation continues with a warning. The HTTPS port stays
mapped, but the backend returns 404 and accepts no messages. App removal retires
the mapping through the existing artifact ledger.
The backend resolves the named value from its systemd-loaded environment and
compares tokens with `hmac.compare_digest`. An unset/empty token or disabled message
console returns 404; a missing or mismatched header returns 401.

The existing message validator and 16 KiB request limit apply. Invalid JSON,
invalid messages and oversized bodies return 400. A complete file is fsynced in
`tmp/` and atomically hard-linked into `new/<id>.json` without overwriting:
success is `202 {"status":"queued"}`; an existing filename is
`202 {"status":"duplicate"}`. After the collector moves that file, a retry may
return `queued` again; the existing receipt ledger still deduplicates its ID.
A spool write failure returns 503. A 202 acknowledges publication only; card
creation and urgent delivery remain the existing loop's responsibility.

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

An installation may provide a card-free run template through
`/monitor/?run=<template>&week=<Friday>&action=<prompt|save|delete>[&url=<HTTPS URL>]`.
The page asks the same
owner API for a server-built preview, then opens the existing Run sheet. Its Run
button sends only `template`, `week`, the restricted action, optional `url` and the owner note to
`POST /api/owner/run/template`; `cwd` and the fixed prompt are never accepted from
the browser; a query-string `note` is rejected. The server requires an ISO Friday,
one of `prompt|save|delete` and an HTTPS URL, may prefill a server-owned note for the
action, appends at most
8,000 note characters, and uses the same owner, same-host mutation, cwd-root and
tmux launch checks as a card. The latest accepted launch for each template/week/action is
recorded next to the message database under `template-runs/` with its launch time,
input and window. When the message console is off, the page shows that the execution
console is unavailable. A public install with no private template definition rejects
the template name rather than accepting browser-owned execution data.

The existing owner and proxy-secret checks apply on every request. Writes also
check origin, content type and body size. Ordinary `/api/run` is not an execution
route. Publishing a spool message does not authorize execution.

### Storage, delivery and retention

| Table | Columns |
|---|---|
| `ledger` | `id` PK, `group`, `source`, `received_at`, `payload` |
| `cards` | `card_id`, `group`, `level`, `title`, `body`, `link`, `run`, `count`, `first_at`, `last_at`, `read_at`, `archived_at`, `ran_at`, `sent_at`, `send_attempts`, `send_next_at`, `detail`, `slack_ts` |

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
or separate sender thread. A crash during an update retries the same Slack timestamp.
Startup adds nullable `detail` and `slack_ts` columns to existing canonical databases;
existing receipts, cards and delivery schedules are preserved.

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
leaves it unconfigured. Retired webhook, roster, compatibility-path and old
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

### Coalescing existing open cards

Before changing an installed database, rehearse against a consistent private copy. The
backup command uses SQLite's online backup API, so it includes committed WAL state; do
not use plain `cp` on a live database.

```sh
DEV_MON_COPY_DIR=$(mktemp -d)
python3 apps/dev-monitor/migrate-legacy-state.py \
  --backup-source ~/.local/state/airlock/dev-monitor/messages.db \
  --db-backup "$DEV_MON_COPY_DIR/messages.db"
python3 apps/dev-monitor/test-migrate-legacy-state.py \
  --live-copy "$DEV_MON_COPY_DIR/messages.db"
```

The rehearsal derives the expected open identities from `(group, decoded run, link)`,
keeps heartbeat cards separate, verifies row and occurrence totals plus SQLite integrity,
runs the forward command twice, and restores the private copy byte-for-byte.

The live command is an offline maintenance operation: stop every database writer,
checkpoint and close SQLite, and verify the writers are stopped before running
`--coalesce-open-cards <state>/messages.db --offline`. It retains
`messages.db.pre-coalesce-open-cards` and adjacent manifest/target receipts. Duplicate
rows are archived with `count=0`, never deleted; the selected survivor keeps its delivery
columns. To roll back before any later write, run
`--compensate-coalesce-open-cards <state>/messages.db --offline`. Compensation refuses a
database whose bytes no longer match the recorded forward result. Keep the backup and
receipts after either path.

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
coalesce by provider while the card remains open. Its OnFailure unit
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
