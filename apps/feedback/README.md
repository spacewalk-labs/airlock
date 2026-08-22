# feedback

A suggestion box at the bottom of the hub launcher, **collapsed by default**: the
launcher shows a small `Feedback` trigger, and the box opens on click. The user
types free text and submits; a loopback backend attaches the **gate-verified
owner** (from the hub identity header, never a client field) and delivers it to
whichever **optional** targets are configured:

1. **intake** — forwards `{owner, text}` to an endpoint you host, which records
   the suggestion (e.g. opens a GitHub issue) and returns its URL.
2. **mail** — sends the suggestion to an address you configure, via a
   transactional mail API. No tracker to check; it lands in an inbox.

- **`/feedback/api/submit`** — the hub page POSTs `{text}` here (same-origin). The
  backend adds `owner` server-side and delivers it. The page never calls an
  external target directly.
- Both targets configured = a submission must reach **both** to be reported as
  sent. A partial delivery is an error, never a silent success.
- The box only appears when the backend reports it's **configured**
  (`GET /feedback/api/health` -> `enabled: true`; `intake`/`mail` say which
  targets are live). Unconfigured -> no box.

Everything is same-origin under the hub's identity gate; no per-app auth.

## Configuration

```toml
[apps.feedback]
backend_port = 19924
# target 1 — intake (protocol below)
intake_url = "https://your-intake.example"   # you host this
token_env  = "AIRLOCK_FEEDBACK_TOKEN"         # name of the env var holding the token
# target 2 — mail
mail_to      = "you@example.com"
mail_from    = "Airlock <feedback@your-verified-domain.example>"
mail_key_env = "RESEND_API_KEY"               # name of the env var holding the API key
mail_api     = "https://api.resend.com/emails"    # default; swap for another provider
```

Secrets are **not** stored in the config. Put them in the env vars named by
`token_env` / `mail_key_env`, delivered via an EnvironmentFile the installer
already wires:

```
# ~/.config/airlock-feedback.env   (chmod 600)
AIRLOCK_FEEDBACK_TOKEN=…your intake token…
RESEND_API_KEY=…your mail API key…
```

Configure neither target and the box degrades cleanly (it stays hidden; `submit`
reports "not configured"). Configure one and only that one runs.

### Mail notes

- **Not SMTP.** An Airlock box has no MTA, and mail sent straight from it has no
  SPF/DKIM to stand on — so this speaks a transactional mail API over HTTPS.
- `mail_from` must be a sender the provider accepts. Providers let you send from
  a shared sandbox sender before you have verified a domain; verify your own
  domain for anything long-lived.
- The default `mail_api` speaks the Resend API shape
  (`{from,to,reply_to,subject,text}` + bearer token). For a provider with a
  different body, change `mail_api` and `_send_mail()` in the backend.
- `reply_to` is set to the submitter when the gate identity looks like an
  address, so replying reaches the person who wrote the suggestion.

## Intake protocol (what your target must implement)

JSON over HTTPS. The token is sent in the `X-Airlock-Feedback-Token` header.

| Method + path    | Request body      | Response             |
|------------------|-------------------|----------------------|
| `POST /submit`   | `{owner, text}`   | `{ok, issue_url}`    |

- `owner` is the identity of the submitter (from the hub identity header); your
  endpoint decides how it records the suggestion.
- `issue_url` (optional) is shown to the user as a link to the created item.

A minimal target is a small web service that authenticates the token, creates a
tracking item from `text` (attributed to `owner`), and returns its URL.
