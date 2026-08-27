# fileview — a directory viewer that owns its own rendering

> What was built, and why it is shaped this way. This replaces the planning
> document the work was done against, which is gone because the work landed
> (2026-08-23).

## What it is

One static document (`apps/fileview/static/viewer.html` + `app.js`) with a file tree
on the left and a viewer on the right, backed by **one** local service: filebrowser,
headless, reachable only through its `/api/`. The viewer renders markdown, code,
JSON, CSV, Jupyter notebooks, images, audio, video and PDF itself, edits any file in
a `<textarea>`, and creates, renames, moves, deletes, uploads and searches through
the same API.

## The five decisions worth keeping

### 1. The scope is the unix account, and there is no setting for it

filebrowser runs `--root /`. There is no `code_root`, no `browse_root`, no start
path, and no bookmarks — the only key the app has is its port.

This is the correction of a specific mistake. `[paths].code_root` was never a
designed setting: **markserv took a directory argument and filebrowser takes
`--root`**, so the installer had to write a value somewhere, and it became a config
key. Once it existed people read it as a boundary, which it never enforced —
SECURITY.md had to keep explaining that. Making the argument a constant removed the
key's reason to exist, and it went to `RETIRED_KEYS` in `bin/airlock-config` (beside
`paths.mount_exclude`, which had the same shape: a key that named a protection
nobody implemented).

What bounds the app now is the unix account its user service runs as — and that is
the whole boundary, on purpose. **fileview is the viewer of the account it runs as.**
The unit names no `User=`; it runs as whoever installed it, so the kernel draws the
line and the app has no way to express it, argue with it, or offer it as a choice.
Measured on the box it was built on: `~/.ssh/id_ed25519` and
`~/.claude/.credentials.json` are readable **and writable**, `/etc/passwd` is
readable, `/etc/shadow` and `/var/log/syslog` are not. Adding a collaborator while
fileview is enabled hands them that account.

Running it as a dedicated system account was considered and rejected: almost
everything the owner actually wants to look at is `0600`/`0700`, so the app would
stop being a viewer of their work and become a viewer of what they had remembered to
share with it.

Both halves of that are pinned by `install/test-fileview-root.sh` (in CI), which
fails if a variable is threaded back into `--root` or if the unit grows a `User=`.

### 2. Nothing is hidden — and that is enforced in two places

`.env` lists, opens, edits and saves exactly like any other file. No ignore list, no
dotfile rule, no dimming, no confirmation, no badge.

An ignore list was designed and then cut. The argument for it was noise; the argument
against it is that the tree is lazy, so a collapsed `node_modules` costs exactly one
row, and a rule that deletes rows contradicts the promise about `.env` on the same
screen. Where directory noise genuinely costs something is **recursive** work, so the
only place a skip list may appear is the scope of a search — visible, and reversible
in one click.

Two layers can break the promise, so both are pinned:

| Layer | Pinned by | How |
|---|---|---|
| server | `apps/fileview/smoke.sh` | creates a `.env` in a temp dir and asserts the API lists it — which also pins filebrowser's real `hideDotfiles` setting, which the installer sets to false explicitly rather than trusting the default |
| client | `install/test-fileview-tree.mjs` (CI) | runs the actual tree renderer against a fixture of everything anyone is tempted to hide and asserts rows-out equals items-in, **and** that a dotfile row carries identical decoration — class names, attributes, inline styles and the text of every part — to an ordinary one, **and** that the row has no part beyond the disclosure triangle and the name |

A grep for the absence of a filter was considered and rejected: it passes for the
wrong reasons and fails on a rename.

### 3. It reads Airlock's design values, and its icons are drawn

fileview inherited the Markwand Dev Server's design tokens along with its markdown
renderer: a teal accent on a cream page, its own 11/12/14/16px type scale, five
callout colours, and a set of emoji standing in for icons. None of that was wrong.
It just was not Airlock's, and two apps in one hub with two palettes is not a style
disagreement — it is the point at which the design system stops being one.

**The palette is linked, not copied.** `apps/fileview/static/tokens.css` no longer
holds a single colour value. It holds role aliases — `--bg: var(--airlock-surface-1)`
— over `hub/assets/airlock-tokens.css`, which the viewer and every sandboxed srcdoc
link directly. The alias layer is what keeps app.js from hard-coding the design
system's physical token names, and it is why the file has no theme blocks at all:
`var(--airlock-canvas)` already resolves per theme.

> The alternative — generating a mirror of the palette into this app and gating it
> byte-for-byte, the way the macOS launcher's colours are generated from the same
> CSS — was argued for on the grounds that `apps/` publishes independently of
> `hub/`. It was not taken. A
> mirror renders in *stale* colours silently; a link renders *unstyled* loudly, and
> loud is the failure you fix. The independence argument also does not reach: this
> is a hub subpath app whose static files are installed **into the hub's own
> webroot**, so `/assets/` is not a foreign dependency, it is the same directory one
> level up. What the objection did land was the cache: `/__fv/` is immutable for a
> year, so the installer now stamps `?v=<content hash>` onto the shared sheet as
> well, and a viewer document — which is never cached — always names a matching pair.

**The type scale is Airlock's, used one step lower.** Chrome and the tree sit at the
SoT's smallest step (13px), code and the editor at 15px, prose at 17px. No size is
invented. A dense tool that mints its own scale is a second design system with a
density argument in front of it.

**There are no file-type icons.** Not emoji, and not a monochrome redraw of the same
idea. A per-extension glyph sorts filenames into categories, and this app's central
promise is that it sorts nothing — an icon that files `.env` under "config" breaks
the same rule as hiding it, while passing a test that only compares class names. So
the tree row is a disclosure triangle and a name, `install/test-fileview-tree.mjs`
now compares the row's full decoration rather than its shape, and it asserts the row
has no third part for anything to occupy later. The toolbar keeps icons, because its
buttons are verbs rather than categories: one inline SVG sprite, 16px grid, 1.5px
strokes, `currentColor`, each with the same thing spelled out in its `aria-label`.
The srcdoc documents cannot reference the parent's sprite — opaque origin — so they
name the view in words instead: `JSON`, `IPYNB`, `RAW`, or the file's own extension
for a table.

**What the gate holds.** `install/test-design-review.py` fails the build on a
colour value in the alias layer, a hard-coded colour anywhere in the app's own
source, a `var(--x)` nothing defines, an emoji, a missing stylesheet link, a
`theme-color` that has drifted from `--airlock-canvas`, or a syntax colour under
4.5:1 on the surface it is painted on. Each check runs a positive control. Four
defects were found by writing it rather than by looking: `--lh-relaxed` was used by
the editor and defined nowhere; the light comment grey measured 2.82:1, because it
had been chosen against Markwand's beige; `theme-color` painted the browser chrome
dark in the light theme; and removing the leftover markserv override rules turned
out to have removed the *only* thing colouring highlighted code in the markdown
pane, which now links the syntax sheet like the srcdoc documents always did.

The same gate covers the other seven app frontends, which have **not** been ported
— devterm alone carries 294 hard-coded colours. Failing the build on those today
would fail it for work nobody has scheduled, so they are held to a recorded ceiling
instead: an app may lose raw colours and emoji, never gain them, and the counts are
printed on every run. New UI in an unported app therefore has to be written against
the tokens, which is the only part of the port that has to happen before someone
schedules the rest.

**What two independent reviews found, and the one thing they were wrong about.**
The port was reviewed from two axes, and both returned BLOCK. One found a genuine
keyboard trap: the first version of the tree navigation put the tab stop on the
container, so Shift+Tab out of a row landed on the container, whose focus handler
sent it straight back — focus could enter the file list and never leave it
backwards. The stop lives on a row now. The other found that `LICENSE` and
`Makefile` had Edit, Copy and Download disabled while `.bashrc` had them enabled,
because "is this a file" was a regex for "has an extension, or starts with a dot"
rather than the `isDir` the listing already returns; extensionless files being
treated worse than dotfiles is the exact inequality this app exists not to have.
Between them they also found that the theme toggle never reached an open code or
JSON pane (it reached into `contentDocument`, which is `null` for a sandboxed
srcdoc, and the exception was swallowed), that three warning-coloured labels
measured 4.47:1, 4.22:1 and 4.22:1 in the light theme, and six ways to walk past
the gate — a new stylesheet it did not scan, `rgb()`, a named colour, a commented
token counted as a definition, an issue number counted as a colour, and an app in
neither half of the ratchet. All of it is fixed and each fix has a mutation test.

One finding was **not** accepted: that highlighting `.env` as shell breaks the
promise. It does not. `langByExt` treats `env` exactly as it treats `sh` and `py`,
so the file gets the same service every other file gets — and removing it would
leave `.env` rendered *worse* than its neighbours, which is the promise inverted
rather than kept.

**Interaction is where "refined" is actually decided.** The tree is
`role="tree"` with a single tab stop and roving focus, arrow keys walk and open and
close it, `:focus-visible` rings are real, the splitter takes arrow keys and
publishes `aria-valuenow`, and every tappable control — toolbar buttons, tree rows,
the splitter — grows to at least 44px on the touch layout. Changing the icons without this would
have been a repaint of a mouse-only app.

### 4. It opens where you work, and the root is still above it

The tree is rooted at `/` and always will be — that is decision 1 and a CI gate
holds it. But a filesystem root is a correct place to *start* and a useless one:
`/bin`, `/boot`, `/dev`, and the directory you actually keep things in is four rows
down and closed. So the tree opens with the running account's home already
expanded and scrolled to, with `/` and every sibling exactly where they were.

The home path is a fact about the account, not a setting. There is no key, nothing
reads config, and the installer writes `$HOME` into the page the same way it writes
asset hashes — the shipped HTML carries an empty value, so a checkout never has
somebody's box baked into it, and a file served unstamped simply lands at the root.

That distinction is load-bearing, because this is precisely the shape
`[paths].code_root` had: a directory the installer had to write somewhere, which
became a key, which was then read as a boundary it never enforced.
`install/test-fileview-root.sh` therefore pins four things — the shipped value is
empty, the installer fills it from `$HOME` exactly once, no config path feeds it,
and it reaches the initial expansion and nothing else. Both halves have a mutation
test: a baked path and a config-sourced path are each detected.

**Making a file is part of the promise.** `.env` could be read, edited, renamed and
deleted like any other file, but the only way to *create* one was to right-click a
folder row — while "New folder" had a button. The button is there now, beside it,
and both write into the folder you are looking at rather than into whatever the
search scope happened to be. Measured: creating `.env` and `Makefile` through the
API both return 200, and the toolbar's own path creates and opens `.env` in the
directory holding the open file.

### 5. The viewer renders; the backend serves bytes

markserv is gone. Its last job was rendering `.md`, and marked + DOMPurify were
already vendored for notebook cells. Deleting it removed a unit, a port, the `node`
and `npm` prerequisites, an `--ignore-scripts` workaround for a dependency's
postinstall, a PATH derivation for a `#!/usr/bin/env node` script, three nginx
`sub_filter` injections, three injected scripts, and a second directory listing that
omitted dot entries and therefore needed a paragraph of SECURITY.md to explain.

Two rules hold the rendering path together:

- **Sanitize first, rewrite second.** marked passes raw HTML through by design, so
  DOMPurify is not defence in depth — it is the only defence. The rewrite pass that
  resolves relative image and link references walks only nodes that survived it, and
  runs while the fragment is still detached, so no `<img>` ever requests a
  pre-rewrite URL.
- **Markdown renders in the parent document; self-contained views stay sandboxed.**
  Code, JSON, CSV and notebooks keep `sandbox=""` srcdocs — they make no network
  requests, so they lose nothing. Markdown cannot: a sandboxed srcdoc has an opaque
  origin, so its subresource requests carry no cookie, and relative images would be
  impossible. Markdown was already an unsandboxed same-origin document under
  markserv, so no isolation was given up.

## Authentication: one token, two carriers

After login the JWT is both kept in `localStorage` (sent as `X-Auth`) and set as an
`auth` cookie. filebrowser accepts the cookie **for GET only** — measured against the
pinned binary: `GET /api/raw` with cookie alone answers 200, `PUT` and `DELETE`
answer 401 and leave the file untouched.

That asymmetry is the whole design. Reads become plain URLs — `<img src>`,
`<video src>`, the browser's PDF viewer, the download link — with no JavaScript
plumbing, while every mutation still requires a header a cross-site request cannot
set.

## Performance: paint from cache, then revalidate

A fresh install felt slow for a structural reason: the first row of the tree was
behind **two serialised round trips** (login, then listing) plus a cold asset
download. What fixed it:

- directory listings and the set of expanded directories live in `localStorage`; the
  tree paints from them with zero round trips, then re-fetches and repaints only the
  directories whose listing actually changed (repainting unconditionally would fold
  the tree under the user every time);
- **file contents are never cached** — showing a stale file as current is the one
  failure a viewer must not have;
- `/proc`, `/sys` and `/run` are not stored, because they change faster than the
  cache can be right. That is cache policy, not a display filter: they appear in the
  tree like any other directory;
- the JWT moved from `sessionStorage` to `localStorage`, removing the login round
  trip from the first-paint path;
- the script moved out of the HTML to `/__fv/app.js`, and every asset URL carries
  `?v=<content hash>` stamped at install time behind a one-year `immutable` header.
  Nothing has a version to bump by hand: a changed file is a changed URL.

Rejected: a clock-driven warm-up (server-side listing is one `readdir`; the cost is
round trips and cold browser cache, so a timer would spend I/O and fix neither), and
idle prefetching of adjacent directories (the cache already makes visited
directories instant; prefetching buys one round trip on a guess).

Proven by turning the backend off and reloading: the tree still painted, `.env`
included, with the previously expanded directory still open — and the failure was
reported in a toast rather than swallowed.

## Search is scoped, and says so

filebrowser has no index. A search is `afero.Walk` with no timeout, and from `/` it
descends `/proc` and `/sys` — measured still running at 12 seconds with no stop
condition but client disconnect. So a search always names its scope on screen, is
abortable, and searching at `/` asks first and explains why. Right-clicking a folder
sets the scope to it; clicking the scope label widens it back.

## What was deliberately not built

- **Dragging a row onto another row to move it.** It needs hover-expand, drop
  highlighting and an undo story, and it is the operation you least want to
  fat-finger when the root is `/`. Moving is a menu item with a path field.
- **Zip download of a directory.** The archiver has no FIFO guard: a directory
  holding a socket or a pipe returned nothing for 8 seconds when measured.
- **A table of contents sidebar.** The tree is the navigation.
- **Syntax highlighting while editing.** The read view highlights; adding an editor
  bundle for the write view can wait until it is missed.

## The size cap is a stream, not a measurement

`fetchTextGuarded` reads the body through a reader and cancels at the cap instead of
buffering it and measuring afterwards. It was the other way round at first, filed as
an accepted residual risk — until the review pointed out what `--root /` does to it:
a path with no honest `Content-Length` (a device, a pipe) makes "check the size after
`r.text()`" a check that never runs. Measured, the pinned filebrowser serves those
files as zero bytes, so the hazard did not reproduce; the cap is enforced by
construction anyway, because relying on a server to be honest about length is the
part that would silently stop being true.

## Migration

The rename is what retracts the old app. On a box whose install-state ledger has
`markwand` committed, its package disappearing makes `airlock-ledger plan` mark it
`remove` and replay its recorded deactivator and artifacts. Boxes that predate the
ledger are covered by a one-shot sweep in `apps/fileview/install.sh` that removes
four literal names — a no-op wherever the ledger already did the work, which is
cheaper than taking a census of which boxes are which.

filebrowser's database moved to `~/.config/airlock-fileview/` and is now a declared
artifact. The old one carried this app's previous `baseURL` baked in, and it holds no
user data, so the "retained data, do not declare" exception it used to get was buying
nothing.
