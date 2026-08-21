# orca web-bundle — the patched Orca web client (vendored)

`dist/` is the **built** Orca web client that Airlock serves at `/orca-web/` behind
the owner gate, in place of the raw client that `orca serve` ships. `apps/orca/install.sh`
copies it to a world-readable serve path and 302-redirects the vendor client URL to it.

## Why vendor a build (not the source)

The client is a static, self-contained build (`web-index.html` + hashed `assets/`).
Serving it needs no toolchain, so only the **built dist** is vendored here — not the
upstream source and not the build tooling. The dist is a derivative of the upstream
Orca web client (MIT) plus local patches (also MIT); see repo-root `NOTICE`.

## What the patches change (all baked into `dist/`)

- **PTY-reload fix** — upstream bug: after a full page reload the terminal panes die
  with *"Local PTYs are unavailable in the web client"* forever. The fix maps the
  paired web client's "local" host to the active runtime so terminals survive reload.
- **Runtime-rebind** — a *"Reconnecting…"* overlay + automatic re-attach when the
  runtime restarts, instead of a dead terminal.
- **Local browser render** and **grab** (element-comment) — present in the bundle but
  **inert unless extra sidecars are installed** (a slot manager / a grab bridge, which
  Airlock does not deploy in v1). With those absent, the client falls back to the
  upstream behavior (streaming render; no grab). See "Not wired in v1" below.

## Integrity: VERSION + verify-web-bundle.sh

`VERSION` pins what this build *is*: the upstream AppImage version it pairs with, the entry
asset name, the file count and a sha256 over the whole tree. A build carries no version
string inside it, so without that file neither "is this stale?" nor "did this get corrupted
in transit?" can be answered.

`../bin/verify-web-bundle.sh` checks `dist/` against the pin, and `../install.sh` runs it
before serving. This matters because of *how* a broken bundle fails: a partial clone or a
truncated copy still serves 200s and then renders a blank page, so nothing looks wrong.
Verifying up front turns that into a failed install.

It does **not** rebuild — re-deriving the client needs the upstream source and toolchain,
which this repo deliberately does not vendor. When you do re-derive `dist/`, regenerate
every field in `VERSION` in the same commit; a stale pin is worse than no pin.

## Provenance / PII

The upstream client is MIT, © 2026 Lovecast Inc. (`github.com/stablyai/orca`). The
vendored dist was **PII-scrubbed**: our patches' Korean UI strings were translated to
English and an internal namespace/token + internal script names were removed. What
remains in the dist is upstream's own content only — its i18n locale bundles (incl.
the Korean `ko-*.js` locale and the native-script language names in the language
picker), a CJK text-measurement sample, and library data — none of which is
Airlock/operator PII.

## Refreshing the bundle

The dist here is a static snapshot. To refresh it (new upstream pin or new patch):

1. Produce a fresh built `dist/` from the (separately maintained) patched Orca web
   client — `web-index.html` + `assets/` only.
2. Replace `dist/` here with it.
3. **Re-run the PII scrub** — the built bundle bakes in our patches' UI strings, which
   were authored in a non-English language and reference internal names. Grep the fresh
   `dist/` for internal identifiers (your organization name, dev-host names, internal
   repo/script names) and translate any of our patch strings still in the original
   language to English. The set of terms + the exact old→new string map is recorded in
   this directory's git history (the commit that first vendored the bundle). Only our
   patch strings are scrubbed — upstream's own i18n locales are left intact.
   The durable fix is to English-ize those strings in the patches upstream and rebuild;
   scrubbing the built dist is the fallback when only the build is at hand.
4. Confirm `web-index.html` still ends with `</body>` (the return-widget `sub_filter`
   injection anchors on it) and still references its assets by their (new) hashed names.

## Not wired in v1

Local browser render (slot manager + external proxy pool) and grab (a page-injected
bridge) need extra services this repo does not install. The client degrades gracefully
without them. Wiring them is a documented follow-up, not part of v1.
