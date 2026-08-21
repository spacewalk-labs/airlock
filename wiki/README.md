# Airlock wiki (starter)

This directory is a **starter knowledge base** for your Airlock box. It is plain
Markdown you own — nothing here is required for Airlock to run. It exists so the
tools and any coding agents working on this box have a single place to read
durable, box-specific facts that aren't obvious from the code or git history.

Point `[paths] wiki` in `airlock.toml` at a wiki clone (or leave it empty to run
wiki-less). When set, the skill harness and the file viewer can surface it.

## Suggested layout

```
wiki/
  README.md          ← this file (index)
  setup/             ← how THIS box is set up (owner, apps enabled, quirks)
  decisions/         ← why things are the way they are (one file per decision)
  runbooks/          ← step-by-step for recurring ops (deploy, restore, rotate)
```

## What belongs here

- Durable, box- or team-specific facts: who the owner is, which apps you enabled
  and why, ports you changed, external services you wired (e.g. a publish target).
- Decisions with their rationale — the "why", so future-you (or an agent) doesn't
  re-litigate them.
- Runbooks for things you'll do again.

## What does NOT belong here

- **Secrets** — tokens, passwords, keys. Those go in an EnvironmentFile or a
  secret manager, never in the wiki (it's readable by anyone the hub gate admits).
- Things the repo already records: code structure, the install flow (`README.md`
  + each `apps/<name>/README.md`), the trust model (`SECURITY.md`).

Keep entries short and one-fact-per-file so they're easy to find and update.
