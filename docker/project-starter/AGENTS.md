# `airlock-project-starter` generated-artifact contract

In the private authoring checkout, repository-wide instructions come from the top-level
`AGENTS.md`, which the public projection intentionally omits. This file only describes
the template boundary: GitHub “Use this template” copies it, then
`setup.sh` replaces it with `AGENTS.md.template`. The generated project receives the
template, not these maintainer notes.

Read [`README.md`](README.md) and the transformation loop in [`setup.sh`](setup.sh)
before changing this directory. A new top-level starter file must deliberately be one
of these:

- inherited unchanged by every generated project;
- represented as a `*.template` input and rendered by the transformation loop; or
- explicitly removed or replaced by `setup.sh`.

Do not let a starter-maintenance file fall through into generated repositories by
accident. In particular, keep `CLAUDE.md` as the regular one-line `@AGENTS.md` bridge;
the setup redirection follows symlinks and could overwrite the newly rendered
`AGENTS.md`. If the starter license text changes, update the guarded license-removal
match at the same time so a generated private project does not silently inherit the
template license.

Verify shell syntax for `setup.sh` and every `.claude/hooks/*.sh` file, and parse
`.claude/settings.json` with `jq`. When transformation or hook behavior changes, run
`setup.sh` only in a disposable copy and inspect the generated repository. The script
removes files and repository metadata by design; never exercise it in this source
checkout. Validate the generated artifact and its hooks, not only the template text.
