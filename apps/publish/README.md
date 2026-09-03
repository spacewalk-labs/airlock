# publish

A static-share manager for your Airlock, plus an **optional, pluggable** way to
publish a page to a public URL.

- **`/publish/`** — manage the share directory (default `/opt/airlock/share`):
  list entries, unpublish (unlink symlinks, keeping the original), delete direct
  files (with a retype-to-confirm step), batch operations, and repair broken
  symlinks.
- **`/publish/files/`** — the share directory served by nginx (behind the hub
  identity gate). Symlink or drop files here to make them reachable in your hub.
- **`/publish/api/upload-*`** — the drop used by [notepad](../notepad): pasted
  images and attached files land in `~/uploads` for a terminal/agent to read by
  path. Everything in `~/uploads` is deleted after 24h (a timer sweeps it).

Everything above is **local** and needs no configuration beyond `[apps.publish]`.

## Optional: external publishing (two modes)

If you configure `[apps.publish.public_target]`, an HTML page in the share
directory can be snapshotted into a single self-contained file (local CSS/JS/
images inlined; external URLs left as-is) and given a public URL with a TTL.
Leave the table out and the manager runs share-only (the external-publish
buttons stay hidden).

`mode` is explicit and never inferred: a half-configured target stays **off** and
says why in the journal, instead of quietly becoming a live public publisher.

### mode = "local" — this box serves the links itself

No second service, no token. Snapshots land in `public_dir`, which **your**
nginx serves at `base_url`. The TTL picker in the UI (24h / 7d / 14d / 30d) is
enforced here: the hourly cleanup timer deletes expired pages from disk, so an
expired link really 404s (within the hour).

```toml
[apps.publish.public_target]
mode       = "local"
base_url   = "https://doc.example.com"       # public URLs are <base_url>/<slug>/
public_dir = "/opt/airlock/share-public"     # default; nginx serves THIS
```

```nginx
server {
    listen 127.0.0.1:80;
    server_name doc.example.com;
    root /opt/airlock/share-public;      # NOT share_dir
    location / { try_files $uri $uri/ $uri/index.html =404; }
}
```

> ⚠️ **`public_dir` must not be `share_dir`** (nor contain it, nor sit inside
> it). `share_dir` is the tailnet-internal share — full of symlinks you added
> for private viewing — and nginx follows symlinks. The installer and the
> backend both refuse an overlapping `public_dir`.

Snapshot metadata (owner, source name, expiry) lives in
`~/.local/state/airlock/publish-public.json`, deliberately **outside** the
served directory. Local snapshots are capped at 25 MB; the remote path is not.

### Password-gated snapshots (local mode only)

In local mode, a public publish can use `mode: "open"` (default) or
`mode: "gated"`. A gated publish requires a non-empty password. It is written under
`gated_dir` and is served as `<base_url>/g/<slug>/`; an open snapshot remains
at `<base_url>/<slug>/`. The two directories are separate so switching an
existing slug between modes first removes the old copy. Re-publishing a gated
slug rotates its password; revoking or expiring it removes its credential.

The installer writes `public-includes.d/publish-gated.conf` in the nginx config
directory. Include it once inside the public server block alongside the open root
configuration:

```toml
[apps.publish.public_target]
gated_dir     = "/opt/airlock/share-gated"  # separate from share_dir and public_dir
htpasswd_dir  = "/opt/airlock/publish-gated-auth" # separate from every served directory
# htpasswd_bin = "htpasswd"                 # Apache utility with bcrypt support
```

```nginx
root /opt/airlock/share-public;
location / { try_files $uri $uri/ $uri/index.html =404; }
include /etc/airlock/nginx/public-includes.d/publish-gated.conf;
```

That `include` line is yours, and this app never edits it. What the installer owns
is the file behind it, which it keeps present in every mode: switching back to
`mode = "remote"` **empties** the fragment rather than deleting it, so the gate stops
being served while your include still resolves. Deleting it instead would make nginx
refuse to load the entire configuration — and not at that moment: the running nginx
keeps serving from memory, so the box looks healthy until the next reload fails, and
the next restart leaves it with no nginx at all.

The one case that still needs your hand is removing this app altogether. That
reclaims the fragment, and your `include` is then pointing at nothing — delete the
`include` line in the same change.

The gate uses nginx `auth_basic`. Its username is the published slug and its
password is the value supplied for that gated publish. Each slug has a separate
credential file, so a password for one document cannot unlock another. Airlock uses the system
`htpasswd -B` implementation because Python 3.13 no longer supplies `crypt`.
If that tool is unavailable, gated publishing fails closed while open publishing
continues to work.

### mode = "remote" (default) — you host an open-only ingest service

Snapshots are POSTed to *your* endpoint, which returns the public URL.
Bundles and password gates are local-only because the remote ingest contract has
no corresponding shape, and this box's nginx is the component that enforces the gate.

```toml
[apps.publish.public_target]
ingest_url = "https://your-ingest.example"   # you host this (protocol below)
base_url   = "https://docs.example"          # public URLs are <base_url>/<slug>/
token_env  = "AIRLOCK_PUBLISH_TOKEN"         # env var holding the auth token
```

The token is **not** stored in the config. Put it in the env var named by
`token_env`, delivered via an EnvironmentFile the installer already wires:

```
# ~/.config/airlock-publish.env   (chmod 600)
AIRLOCK_PUBLISH_TOKEN=…your token…
```

### Ingest protocol (what your target must implement)

JSON over HTTPS. The token is sent in the `X-Airlock-Publish-Token` header by
default. Receivers disagree about that name, and a receiver that already has
publishers deployed against a different one cannot rename without breaking all of
them at once — so the publisher bends: set `token_header` in
`[apps.publish.public_target]` and this app sends that name instead.

```toml
[apps.publish.public_target]
token_header = "X-Docpub-Token"   # what THIS receiver authenticates with
```

A wrong header name looks like an authorization failure, not a configuration one:
the receiver answers 403 because it never saw a token. If publishing 403s while the
token is known good, compare this value against what the receiver expects first.

| Method + path        | Request body                                              | Response                                              |
|----------------------|----------------------------------------------------------|------------------------------------------------------|
| `POST /ingest`       | `{slug, owner, src, title, ttl_hours, html_b64}`         | `{ok, result:{expiry, ttl_hours}}`                   |
| `GET  /list?owner=`  | —                                                        | `{ok, items:[{slug, owner, src, title, expiry, expired, mode}]}` |
| `POST /revoke`       | `{slug, owner}`                                          | `{ok}`                                               |
| `POST /set-expiry`   | `{slug, owner, ttl_hours}`                               | `{ok}`                                               |

- `html_b64` is base64 of the self-contained snapshot.
- `owner` is the identity of the publisher (from the hub identity header); your
  endpoint should scope `list`/`revoke`/`set-expiry` to that owner.
- The public URL shown to the user is `base_url/slug/`; your target decides how
  it actually serves that slug.

A minimal target is just a small web service that stores each `html_b64` under
its `slug`, serves it until `expiry`, and returns 404 afterwards.

### Bundle approval API (local mode only)

Local mode's `POST /publish/api/publish-plan` accepts `{entry, max_docs}` and returns a
read-only BFS proposal of linked local HTML files. It returns `plan_id`,
`plan_expires`, candidates, missing files, failed reads, truncation status, and
the server-clamped `max_docs`. To publish an approved subset, send
`{name: entry, docs: [...], plan_id}` to `POST /publish/api/publish-public`.
Plans are owner-bound, expire after ten minutes, and are consumed atomically
before the build, including if that build then fails. The builder rechecks all
approved document digests and rewrites links between selected members; links to
unselected local documents are returned as warnings.
