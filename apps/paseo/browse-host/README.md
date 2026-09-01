# paseo browse-host — server-side browser panels (config-gated)

This is a **loopback WebSocket sidecar** that gives the paseo daemon a
server-side browser automation host: a Playwright-backed headless Chromium the
agents drive through paseo's native `browser_*` tools, plus a live browser panel
the owner can watch/drive from the web UI.

> **Status: wired, off by default.** Set `browse = true` under `[apps.paseo]` in
> `airlock.toml` and the paseo installer (`../install.sh`) adds the owner-gated
> `/browse-view/` stream route and runs this `install.sh` **warn-only** (a
> chromium download or a web-ui SHA-drift never breaks the hub or the daemon).
> Left `false` (the default), none of the below runs — no Playwright, no chromium,
> no web-ui patch, and the `/browse-view/` route is omitted.

## What turning it on does (and its dependencies)

1. **Playwright + Chromium.** `install.sh` runs `npm install` (adds `playwright` +
   `ws`) and `playwright install chromium`. This is a heavy dependency the v1
   daemon deliberately avoids. `playwright install` fetches the browser but not the
   shared libraries it links against, so the installer then *launches* chromium; if
   that fails it runs `playwright install-deps chromium` under `sudo -n` and probes
   again. The launch is the check because the download succeeding tells you nothing
   — a box can hold a complete chromium that dies on every start with
   `libatk-1.0.so.0: cannot open shared object file`.
2. **A SHA-pinned web-ui bundle patch.** `bin/patch-web-ui.js` applies three
   minimal, verified-unique edits to paseo's minified web-ui bundle (un-gate the
   "New browser" button on web + mark the pane container) and injects the
   companion `web/browse-view-client.js`. It is **fail-loud**: on a `@getpaseo/cli`
   version bump the bundle SHA changes, the patcher refuses, and a human must
   re-derive the anchors. This lockstep with an upstream minified bundle is why it
   is a follow-up, not v1.
3. **Reconcile ports/origin with `airlock.toml`.** The unit defaults
   (`PASEO_WS_URL` backend `19952`, stream port `19953`, allowed Origin on the
   `https_port`) must match your resolved `[apps.paseo]` config, and the nginx
   owner gate must proxy `/browse-view/` to the loopback stream port.

## Re-deriving the anchors

`bin/patch-web-ui.js` refuses to run when the bundle's SHA-256 does not match its
`PINNED_SHA`, which is what a `@getpaseo/cli` bump looks like. That refusal is the
whole design — the alternative is a half-patched bundle — so re-deriving is a
deliberate step, not an obstacle to route around.

```sh
npm_config_prefix=/tmp/paseo-probe npm i -g @getpaseo/cli@<new-version>
W=/tmp/paseo-probe/lib/node_modules/@getpaseo/cli/node_modules/@getpaseo/server/dist/server/web-ui
grep -o 'index-[0-9a-f]*\.js' "$W/index.html"          # the bundle index.html serves
sha256sum "$W/_expo/static/js/web/index-*.js"          # the new PINNED_SHA
```

Then, against that **pristine** bundle, update `PINNED_SHA`, `PINNED_VERSION` and
each `PATCHES` entry until every `find` occurs **exactly once** and every `repl`
**zero** times. `KNOWN_BUNDLE_SHAPES` is re-derived the same way — apply each listed
subset of edits to the pristine bundle and take `sha256` of the whole file — and the
same values go into `anchor-manifest.json`, which the drift test compares as data. Two things make this less alarming than it looks:

- The two `new-browser-gate-*` anchors are mostly minifier-local names, which are
  renamed between versions even when the code is untouched (0.1.110 → 0.2.5 renamed
  four locals and changed nothing else). Search for
  `getIsElectron)())return` and read the surrounding callback.
- `browserpane-marker`'s `find` has survived unchanged, and that is the one to be
  careful with, not the reassuring one: its **replacement** reads locals
  (`w`, `f.workspaceId`, `f.serverId`). Confirm in the new bundle that the enclosing
  function is still `BrowserPane=function(f){…{browserId:w}=f…}` and that its caller
  still passes `workspaceId` and `serverId` — otherwise the marker lands with
  `undefined` fields, the patcher exits 0, and the companion mounts against nothing.

Verify against the pristine bundle, not against a box: a bundle carrying
`PATCHED_MARKER` skips the SHA check entirely, so a patched bundle answers "fine" to
questions it has not been asked.

## Licensing

- **The sidecar is Apache-2.0.** `host.js`, `security.js`, `executor.js`,
  `stream-server.js`, `commands.js`, `bin/paseo-browse-host.js`, `web/*.js`, the
  tests, `install.sh`, and `smoke.sh` are an **independent** loopback-WS sidecar —
  they do **not** import paseo. Each carries `SPDX-License-Identifier: Apache-2.0`.
- **`bin/patch-web-ui.js` is AGPL-3.0-only.** It encodes derivative edits to
  paseo's own web-ui bundle, so it carries `SPDX-License-Identifier:
  AGPL-3.0-only` (same basis as `../patches/`). See `../patches/README.md`.

## Layout

| Path | Role | License |
|---|---|---|
| `bin/paseo-browse-host.js` | entry point | Apache-2.0 |
| `bin/patch-web-ui.js` | paseo web-ui bundle patcher (live panel) | **AGPL-3.0-only** |
| `src/host.js` | WS client: registers the browser host, answers execute requests | Apache-2.0 |
| `src/executor.js` | Playwright command executor (tabs, refs, redaction) | Apache-2.0 |
| `src/stream-server.js` | live-view CDP screencast + input transport | Apache-2.0 |
| `src/security.js` | proportionate URL policy (SSRF guard) | Apache-2.0 |
| `src/commands.js` | supported-command manifest | Apache-2.0 |
| `web/browse-view-client.js` | web-ui companion (canvas + toolbar + roster dock) | Apache-2.0 |
| `test/*` | unit + integration + e2e | Apache-2.0 |
| `install.sh` / `smoke.sh` | manual install + ship-gate smoke | Apache-2.0 |

## Tests

`npm test` runs the unit/integration suite (needs a resolvable `playwright`; some
integration tests need network). Two use environment overrides so they carry no
box-specific paths:

- `PASEO_PLAYWRIGHT_PATH` — optional extra path to resolve a `playwright` install.
- `PASEO_BROKER_PATH` — path to the installed `@getpaseo/server` broker.js;
  `test/broker.integration.mjs` **skips** cleanly when it is unset.

`smoke.sh` (the deploy gate) runs `test/smoke.cjs`, asserts the unit is active +
registered with the live daemon, and checks the loopback stream port.
