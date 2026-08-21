# Airlock — build plan

Clean, generalized rewrite of an internal dev-tools suite into a reusable
open-source project. Single monorepo, single release (all 9 apps + wiki/skills),
config-driven, MIT core (+ AGPL-3.0 for `apps/paseo/patches/`).

Full rationale + license analysis + multi-model review live in a separate internal
design doc (kept out of this public repo).

## Guiding decisions

- **Clean rebuild** (no history port). Config-driven: one `airlock.toml` holds all
  site facts; code reads only via `bin/airlock-config`.
- **Auth = Tailscale, fail-closed** (see SECURITY.md). Header-value-only auth is
  unsafe; the installer verifies Tailscale is the ingress or refuses to start.
  Arbitrary header names are NOT a valid provider in v1.
- **Licensing**: MIT core. `apps/paseo/patches/` = AGPL-3.0 (paseo is AGPL-3.0;
  patches are derivatives). orca is MIT (web patches publishable).
- **v1 deploy** = single box, Tailscale-only. Multi-box / other auth providers = later.

## Milestone 1 = hub + devterm (installable by editing airlock.toml only)

**LIVE-VERIFIED** (2026-07-22) on a fresh Ubuntu 24.04 LXD container `test-airlock`
(Tailscale-joined). Full path proven: `airlock.toml` → `airlock-install.sh` →
config valid, ttyd sha-pinned, systemd --user unit active, `nginx -t` ok + reload,
`tailscale serve` (hub 443/9999, devterm 8443/9900 — 9910 is devterm's LOOPBACK
gate, never a tailnet port). Gate security live: owner=200,
deny=403, no-header=403. Identity injection over tailnet: `/whoami`=owner login, `/`
and `:8443/` = 200. Live test found + fixed: (1) installer sudo for /etc paths,
(2) ts precondition = "Tailscale up" not "serve configured" (chicken-and-egg),
(3) app smoke must run after nginx reload + hub needs its own `tailscale serve`.

## Tasks (dependency order; critical path T1→T2→T3→T4→T5)

- [x] **T1 — Repo scaffold.** LICENSE, NOTICE, README, SECURITY, airlock.toml.example,
      .gitignore, PLAN, CI (shellcheck + py_compile + PII grep). DONE.
- [x] **T2 — Config layer.** `bin/airlock-config` (Python tomllib; only toml parser),
      `install/lib.sh` (airlock_load / require_cmd / ts_fqdn / ts_verify_serve /
      render_loopback_nft). 14/14 tests. Fail-closed: provider must be tailscale,
      identity header fixed. DONE.
- [x] **T3 — Gate layer (security core).** `gate/nginx-lib.sh` (ident_var,
      emit_connection_upgrade_map, emit_identity_map, emit_owner_gate),
      `gate/identity.py` (12/12), `gate/loopback-only.nft.tpl`. nginx-lib 15/15 incl
      live `nginx -t`. Fail-closed verify + forged/missing-header negative tests. DONE.
- [x] **T4 — Hub + nginx renderer + orchestrator.** render-nginx.sh (10/10, nginx -t),
      `hub/index.html` + `wrong-owner.html`, `airlock-config webjson` (frontend-safe),
      `install/airlock-install.sh` orchestrator (dry-run verified). DONE.
- [x] **T5 — devterm → Milestone 1.** `apps/devterm/` install (ttyd sha-pinned) +
      devterm-shell (tmux auto-resume) + owner-gate nginx fragment + tailscale serve
      + smoke. Offline integration 6/6 (hub+devterm nginx -t together). DONE.
      NOTE: uses ttyd built-in client; custom mobile xterm client = later enhancement.
      **Milestone 1 reached: hub + devterm installable from airlock.toml alone.**
- [x] **T6 — markwand.** `apps/markwand/` — markserv viewer (npm, v1.17.4) + filebrowser
      editor (sha-pinned v2.63.18) behind the hub, served as same-origin subpaths
      (`/markwand/`, `/markwand/edit/`) with MIT static assets (tokens/enhance/editor/
      edit-button) injected via sub_filter from the hub webroot (`/__mw/`).
      **LIVE-VERIFIED** on `test-airlock` over the tailnet: viewer renders code_root,
      editor loads, asset injection present, identity injected, gate closes for
      non-owners (wrong-owner page). Established the **same-origin subpath pattern**
      (`emit_subpath_location` + `hub-locations.d`). NOTE: v1 = markserv viewer +
      filebrowser editor; the rich split-pane multitype viewer = later enhancement.
      **Gate model refactor (applies to all subpath apps): the hub now gates at the
      SERVER level (single `if ($hub_ok = 0) { return 403; }` chokepoint) instead of
      per-location — a per-location `if` + `try_files`/proxy is fragile and each app
      would have to remember its own guard. `error_page 403 @denied` (no `=`) keeps an
      honest 403 status while serving the wrong-owner body. Live test also fixed a
      filebrowser re-run idempotency bug (stop the unit before `config set`, else the
      SQLite lock times out).**
- [x] **T7 — publish + notepad.** `apps/publish/` = static-share manager backend
      (`airlock-publish.py`, loopback) + clean OSS frontend, served as subpaths
      (`/publish/` UI, `/publish/api/` backend, `/publish/files/` = the share dir,
      default `/opt/airlock/share`). Also the shared **uploads** drop (`~/uploads`,
      24h TTL timer) that notepad uses. `apps/notepad/` = frontend-only scratchpad
      (paste image / attach file → `~/uploads`, token-expand on copy); requires
      `[apps.publish]` (fail-loud if absent). **External publish is a PLUGGABLE
      target** (`[apps.publish.public_target]` ingest_url/base_url/token_env; token
      via EnvironmentFile, never in config) — the original internal snapshot-publish
      pipeline (a private ingest service) is GONE; unconfigured = local-only. Ingest protocol
      documented in `apps/publish/README.md`. Snapshot bundling reads from disk
      (gate-safe, no HTTP self-fetch through the gate). **LIVE-VERIFIED** on
      `test-airlock` over the tailnet: UI/list/files 200, gate closes for
      non-owners, and an upload round-trip landed in `~/uploads` with correct
      content. Config layer: `airlock-config env` now skips nested tables (read via
      `get`); publish gained a `share_dir` default. Integration 9/9.
- [x] **T8 — dev-monitor (observability).** `apps/dev-monitor/` — the system-status
      collector (`airlock-dev-monitor.py`, loopback) + clean English dashboard at
      `/monitor/` (overview/services/network/storage/top/history/logs). Same-origin
      subpath (server-level gate). **LIVE-VERIFIED** on `test-airlock`: UI 200,
      `/monitor/api/overview` returns real host/cpu/memory/disk over the tailnet,
      gate closes for non-owners. The **message/action console** (spool + Slack +
      action-runner) is DEFERRED behind the default-off `messages` flag: the four
      `devmon_*` modules are optional imports, and the backend runs observability-
      only without them, warning clearly if `messages=true` is requested. Integration 10/10.
- [x] **T9 — code-server.** `apps/code-server/` single-instance (sha-pinned) + owner-gate
      fragment + tailscale serve + smoke. In integration test (orchestrator→render→nginx -t).
      NOTE: single instance; multi-tab slot manager = later enhancement. DONE (v1).
- [x] **T10 — orca (v1, upstream web client).** `apps/orca/` — headless Orca ADE
      (Electron) behind the owner gate. sha-pinned AppImage (1.4.139) + `--appimage-
      extract` + APPDIR, dedicated Xvfb `--user` unit, `orca serve` `--user` unit,
      fixed pairing-code + `--pairing-address` rewrite (URL printed to bookmark),
      scope/daemon reap. Owner gate = `emit_owner_gate` (separate port 8446). orca
      binds 0.0.0.0, so an nft loopback-only ruleset (shared template +
      `airlock-orca-firewall.service`) confines the backend. **LIVE-VERIFIED** on
      `test-airlock`: Electron daemon listens on 18821, gate deny=403/owner=200|302,
      nft `iif != lo … drop 18821` active, units active. **The patched web-bundle /
      orca-web client is a documented FOLLOW-UP** (needs the separate repo opened) —
      v1 serves the upstream web client. Integration 12/12.
- [x] **T11 — paseo (v1 daemon + AGPL patch).** `apps/paseo/` — pure-Node daemon
      (`@getpaseo/cli@0.1.110`, pinned) behind the owner gate (separate port 8447).
      Gate fragment written directly (not emit_owner_gate) to carry the 3 load-
      bearing headers (`X-Forwarded-Proto https`, `Host <fqdn>:port`, trusted-proxy
      env) or the web-UI WebSocket dies. node ≥ 20 hard check, explicit unit PATH
      (provider-spawn gotcha), idempotent **AGPL depth4 patch**. **LIVE-VERIFIED**
      on `test-airlock`: daemon on 6767, `/:8447` tailnet=200, deny=403, and the
      depth4 patch confirmed applied to the installed paseo. **Licensing:** patches/
      = AGPL-3.0 (+ full AGPL text vendored at `patches/LICENSE`); `browse-host/`
      shipped as labeled source (sidecar = MIT, `patch-web-ui.js` = AGPL) but NOT
      wired in v1 (Playwright + SHA-pinned web-ui patch = follow-up). Integration 14/14.
- [x] **T12 — starter wiki + skills.** `skills/airlock-deploy/SKILL.md` (deploy +
      verify) and `skills/airlock-doctor/SKILL.md` (top-down gate/nginx/backend
      diagnosis) + a `wiki/README.md` starter knowledge base (wiki-less OK).
- [x] **T13 — release gate.** README/NOTICE reconciled to what v1 actually ships
      (aspirational xterm/hljs/orca-web-patches entries removed; markwand assets +
      paseo AGPL split documented). `bin/airlock-smoke` (standalone all-app gate
      check). Full AGPL-3.0 text vendored at `apps/paseo/patches/LICENSE`. PII guard
      passes over the whole repo (CI pattern, 0 hits). **Fresh-box E2E DONE**: all 8
      apps installed + smoked green on `test-airlock` (owner=200/302, non-owner=403).
      Offline suites: config 14, identity (pass), nginx-lib 15, render 10,
      integration 14. Remaining = the USER's action: push to the new GitHub org;
      pre-publish courtesies noted in NOTICE (download hash/provenance inventory;
      optional interop note to getpaseo).

## Must-fix before public (from Codex review)

1. Header-only auth → Tailscale fail-closed (T3).
2. Gate not reachable by a header-forwarding proxy (T3).
3. paseo provenance: AGPL confirmed; patches AGPL-separated; pin tarball integrity.
4. Remove private orca-web material / internal-org refs; open patch series (T10).
5. Full PII scrub (identities, emails, tailnet, sibling-repo paths, org names).
6. Dependency/provenance inventory + NOTICE (AppImage, Chromium, vendored FE).
7. Confirm deploy model (single-box Tailscale); don't advertise "any server".
8. Scope = 9 apps; re-check publish/dev-monitor nginx-trust boundaries.
