---
name: airlock-secret
description: Diagnose and recover Airlock's short-lived secret drop when a secret is missing, expired, rejected, or appears locked. Use without exposing a secret value in shell history, logs, or chat.
---

# airlock-secret

The secret drop stores a value only on the current box at
`~/.devterm-secrets/<name>.txt`. It returns metadata and a path, never the
value. Entries expire after 30 minutes by default; expiration is expected, not
a failure.

## 1. Identify whether it expired, was deleted, or cannot be written

Run as the same box user that runs DevTerm. This output contains only names,
paths, sizes, and remaining lifetime.

```bash
ROOT="$(git -C /path/to/airlock rev-parse --show-toplevel)"
"$ROOT/bin/airlock-secret" list
systemctl --user status airlock-secret-sweep.timer --no-pager
systemctl --user list-timers airlock-secret-sweep.timer --all
```

- A name absent from `list` has expired, was deleted, or was never stored.
  Put it again; it cannot be recovered from the secret drop.
- A listed name has `remain_sec`: use its returned path before that reaches
  zero. Calling `list`, `put`, or `del` also removes expired entries.
- The timer should be enabled and scheduled. If it is absent or failed, re-run
  the ordinary Airlock installer; do not hand-create a timer unit.

## 2. Put a replacement safely

Use the DevTerm secret form: it keeps the value out of terminal history and
returns the path to pass to the consuming tool. Do **not** paste or type a real
secret at a terminal prompt—the command's standard input is normally echoed and
can remain in terminal scrollback.

```bash
# For an automated caller only: stdin must already be a protected, non-TTY input
# channel. The value must never be an argument, environment variable, log, chat,
# or shell-history entry. stdout is safe metadata only.
"$ROOT/bin/airlock-secret" put -- GH_TOKEN
```

The name is 1–48 characters of letters, digits, `.`, `_`, or `-`, and cannot
start with `.`. The response gives the only handoff to use, for example
`~/.devterm-secrets/GH_TOKEN.txt`; do not print that file's content for
troubleshooting.

To deliberately revoke a value before its TTL, delete by name:

```bash
"$ROOT/bin/airlock-secret" del -- GH_TOKEN
"$ROOT/bin/airlock-secret" list
```

## 3. When it appears locked or reports `secret storage failed`

Each operation takes an exclusive advisory lock and releases it automatically
when the process exits. First stop making concurrent requests and check whether
another `airlock-secret` call is still alive:

```bash
ps -fu "$(id -u)" | rg '[a]irlock-secret'
```

Wait for a live invocation to complete, then retry `list`. Do **not** delete
`.airlock-secret.lock`, change permissions recursively, or replace
`~/.devterm-secrets`: those actions can race a live write or weaken the
secret-store boundary.

If `list` still reports storage failure after no process is holding it, stop
there. The store deliberately refuses symlinked or non-regular entries rather
than following them. Record the command, public JSON error code, user, and
whether the sweep timer is active; escalate to the box owner without attaching
the value or the contents of any secret file.

## 4. Verify the repair

```bash
"$ROOT/bin/airlock-secret" list
```

Confirm the replacement name appears with a positive `remain_sec`, then retry
the consuming action using the returned path. If it succeeds once and fails
later, compare the elapsed time with the TTL before diagnosing an application
fault.
