#!/usr/bin/env bash
# The platform's "which agent CLI does this box run" layer: the [agent].provider key,
# the selection rule, and the CLI that hands the answer to a tool that cannot import it.
#
# Why this exists. The same question used to be answered twice — once inside the learning
# app, once by the literal string 'claude' in dev-monitor's action runner — and the two
# could not disagree loudly because neither knew the other existed. A box with only codex
# logged in had one working app and one that died with rc=127. Consolidating the rule only
# helps if the consolidation itself is pinned, so this suite asserts the three things that
# would let it come apart again:
#
#   1. the vendored copy is the same bytes as the platform original
#   2. the config layer refuses a provider the selector does not know (and refuses `model`,
#      which is the boundary owner decision 5 draws)
#   3. `auto` prefers a credential trace over mere installation, and says which it used
#
# Offline: no network, no live services, no agent CLI needs to be installed — the CLIs and
# the login-state probe are fabricated in a scratch dir.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 1

pass=0 fail=0
ok()  { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want $3, got $2)"; fi; }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export AIRLOCK_STATE_DIR="$scratch/state"      # never touch a developer's real ledger
# This suite runs NO installer — it only greps one for a line. But test-render-parity.sh's
# RAM-pin gate is a text scan over non-comment lines, and this file names an install.sh in
# one, so it counts as a matching suite. Pinning a variable that does nothing here is the
# honest move: rewriting the grep to dodge a text scan is the evasion that gate exists to
# catch, and a gate with a hole in it is worth less than a redundant export.
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368
CFG="$ROOT/bin/airlock-config"
AGENT="$ROOT/bin/airlock-agent"

# ---- 1. the vendored copy ---------------------------------------------------
# learning's backend cannot import from the platform tree (a package does not have to live
# inside it), so it carries a copy. A copy that drifts is worse than no copy: the app would
# keep selecting by an older rule while the platform reported the newer one.
VENDORED="$ROOT/apps/learning/backend/agent_provider.py"
if cmp -s "$ROOT/bin/agent_provider.py" "$VENDORED"; then
  ok "vendored agent_provider.py is byte-identical to bin/agent_provider.py"
else
  bad "vendored agent_provider.py has drifted from bin/agent_provider.py — copy it again"
fi
# ...and learning's installer actually ships it. Without this line the app imports nothing
# and the whole backend fails to start, which is a much louder failure than a stale copy but
# an easy one to introduce by adding a provider file and forgetting the install rule.
if grep -q 'backend/agent_provider.py' "$ROOT/apps/learning/install.sh"; then
  ok "learning's installer ships agent_provider.py next to providers.py"
else
  bad "learning's installer does not install agent_provider.py"
fi

# ---- 2. the config key ------------------------------------------------------
mk() { printf '%s\n' "$2" >"$scratch/$1"; }
base='[airlock]
config_version = 2
[site]
name = "T"
[auth]
provider = "tailscale"
owner = "owner@fixture.dev"
[apps.hub]'

mk plain.toml "$base"
is "no [agent] table validates" \
   "$(AIRLOCK_CONFIG="$scratch/plain.toml" python3 "$CFG" validate 2>&1)" "ok: config valid"
# The default is the compatibility statement, not a preference: the action runner ran claude
# before this key existed, so a box that never sets it has to keep running claude.
is "unset [agent].provider resolves to claude" \
   "$(AIRLOCK_CONFIG="$scratch/plain.toml" python3 "$CFG" get agent.provider 2>/dev/null)" "claude"
is "the resolved value is exported to every installer" \
   "$(AIRLOCK_CONFIG="$scratch/plain.toml" python3 "$CFG" env hub 2>/dev/null | grep '^AIRLOCK_AGENT_PROVIDER=')" \
   "AIRLOCK_AGENT_PROVIDER=claude"

for value in auto claude codex; do
  mk "v-$value.toml" "$base
[agent]
provider = \"$value\""
  if AIRLOCK_CONFIG="$scratch/v-$value.toml" python3 "$CFG" validate >/dev/null 2>&1; then
    ok "[agent].provider = $value validates"
  else
    bad "[agent].provider = $value validates"
  fi
  is "  ...and reads back as $value" \
     "$(AIRLOCK_CONFIG="$scratch/v-$value.toml" python3 "$CFG" get agent.provider 2>/dev/null)" "$value"
done

mk typo.toml "$base
[agent]
provider = \"clade\""
if AIRLOCK_CONFIG="$scratch/typo.toml" python3 "$CFG" validate >/dev/null 2>&1; then
  bad "an unknown provider is rejected"
else
  ok "an unknown provider is rejected"
fi

# Owner decision 5 has a schema consequence, not just a comment: there is no model key, so
# writing one has to fail rather than sit in the file looking effective.
mk model.toml "$base
[agent]
model = \"opus\""
if AIRLOCK_CONFIG="$scratch/model.toml" python3 "$CFG" validate >/dev/null 2>&1; then
  bad "[agent].model is rejected (owner decision 5 — the CLI picks the model)"
else
  ok "[agent].model is rejected (owner decision 5 — the CLI picks the model)"
fi

# ---- 3. the selector -------------------------------------------------------
# Fabricate the two CLIs and the login-state probe. bin_discovery takes <CMD>_BIN as an
# operator override, which is exactly the hook a test needs; airlock-accounts-status is
# replaced wholesale, since the real one reads the developer's own login files.
bindir="$scratch/bin"; mkdir -p "$bindir"
for c in claude codex; do printf '#!/bin/sh\n' >"$bindir/$c"; chmod 755 "$bindir/$c"; done
fake_status() {   # $1,$2 = claude/codex usable-login booleans
  local p="$scratch/status-$1-$2"
  printf '#!/bin/sh\nprintf %%s %s\n' \
    "'{\"schema_version\":1,\"providers\":{\"claude\":$1,\"codex\":$2}}'" >"$p"
  chmod 755 "$p"; printf '%s' "$p"
}
sel() {   # sel <claude-login> <codex-login> [--prefer X] -> one JSON line
  local st; st="$(fake_status "$1" "$2")"; shift 2
  CLAUDE_BIN="$bindir/claude" CODEX_BIN="$bindir/codex" \
  AIRLOCK_ACCOUNTS_STATUS_BIN="$st" AIRLOCK_CONFIG="$scratch/plain.toml" \
  python3 "$AGENT" select --json "$@"
}
field() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get(sys.argv[1]))' "$1"; }

is "auto with only codex logged in picks codex" \
   "$(sel false true --prefer auto | field provider)" "codex"
is "auto with only claude logged in picks claude" \
   "$(sel true false --prefer auto | field provider)" "claude"
# The AUTO_TIEBREAK answer, pinned so it cannot drift silently: declaration order decides,
# and declaration order is claude first.
is "auto with BOTH logged in picks claude" \
   "$(sel true true --prefer auto | field provider)" "claude"
# A trace is a hint about where a login file sits. A wrong hint must not be able to refuse a
# CLI that would have worked, so "installed, no trace" still runs.
is "auto with neither logged in still runs something" \
   "$(sel false false --prefer auto | field provider)" "claude"
case "$(sel false false --prefer auto | field reason)" in
  *"로그인 흔적을 찾지 못했습니다"*) ok "  ...and says the trace was missing" ;;
  *) bad "  ...and says the trace was missing" ;;
esac

is "a pinned provider wins over the credential trace" \
   "$(sel true false --prefer codex | field provider)" "codex"
is "  ...and the binary is the resolved path, not the bare name" \
   "$(sel true false --prefer codex | field binary)" "$bindir/codex"
is "no --prefer falls back to the configured key" \
   "$(sel true true | field provider)" "claude"

# An unrecognised value is not silently read as auto: the note is the only way an operator
# learns their file says something the platform did not understand.
case "$(sel true true --prefer clade | field reason)" in
  *"모릅니다"*) ok "an unknown preference is reported, not silently defaulted" ;;
  *) bad "an unknown preference is reported, not silently defaulted" ;;
esac

# Nothing installed is an ANSWER (exit 0 with a reason), not a crash: the caller decides
# what to do about it, and a non-zero exit here would read as "the selector is broken".
empty="$scratch/empty"; mkdir -p "$empty"
out="$(CLAUDE_BIN="$empty/claude" CODEX_BIN="$empty/codex" \
       AIRLOCK_ACCOUNTS_STATUS_BIN="$(fake_status false false)" \
       AIRLOCK_CONFIG="$scratch/plain.toml" python3 "$AGENT" select --json --prefer auto)"
is "nothing installed exits 0" "$?" "0"
is "  ...with provider null" "$(printf '%s' "$out" | field provider)" "None"
case "$(printf '%s' "$out" | field reason)" in
  ?*) ok "  ...and a reason a person can act on" ;;
  *) bad "  ...and a reason a person can act on" ;;
esac

# A probe that cannot answer must not veto an installed CLI — it only orders the candidates.
is "a broken login probe degrades to no-trace, never to no-CLI" \
   "$(CLAUDE_BIN="$bindir/claude" CODEX_BIN="$bindir/codex" \
      AIRLOCK_ACCOUNTS_STATUS_BIN=/nonexistent/status \
      AIRLOCK_CONFIG="$scratch/plain.toml" python3 "$AGENT" select --json --prefer auto \
      | field provider)" "claude"

# ---- 4. the value reaches a unit, and cannot forge a directive on the way ----
# Both values end up on `Environment=` lines, where a newline starts a new directive. validate
# is the first lock (an unknown provider never gets that far); this is the second, for an app
# installer run on its own. Positive AND negative control, because "the install failed" is only
# evidence if an install that should succeed does.
dm_install() {   # dm_install <config> <render-dir>
  AIRLOCK_TS_FQDN=box.example.ts.net AIRLOCK_CONFIG="$1" \
  AIRLOCK_ROOT="$ROOT" AIRLOCK_APP_DIR="$ROOT/apps/dev-monitor" AIRLOCK_APP_ID=dev-monitor \
  AIRLOCK_DRY_RUN=1 AIRLOCK_RENDER_DIR="$2" bash "$ROOT/apps/dev-monitor/install.sh" 2>&1
}
mk unit-ok.toml "$base
[agent]
provider = \"codex\"
[apps.dev-monitor]"
if dm_install "$scratch/unit-ok.toml" "$scratch/r-ok" \
     | grep -q 'dev-monitor installed'; then
  ok "dev-monitor installs with a configured provider"
else
  bad "dev-monitor installs with a configured provider"
fi
is "  ...and the unit carries the resolved provider" \
   "$(grep -c '^Environment=AIRLOCK_AGENT_PROVIDER=codex$' "$scratch/r-ok/units/airlock-dev-monitor.service")" "1"
is "  ...and the selector path" \
   "$(grep -c '^Environment=AIRLOCK_AGENT_BIN=.*airlock-agent$' "$scratch/r-ok/units/airlock-dev-monitor.service")" "1"

# `\n` is the TOML escape, not a shell one — a raw newline inside a basic string is illegal
# TOML and the parser would reject the FIXTURE, which is not the same as rejecting the value.
mk unit-inject.toml 'agent = { provider = "claude\nExecStart=/bin/evil" }
'"$base"'
[apps.dev-monitor]'
# Positive control on the fixture itself: the value really does carry a newline by the time
# anything reads it. Without this, a fixture the parser rejects would look like a caught attack.
is "the injection fixture really does decode to a newline" \
   "$(AIRLOCK_CONFIG="$scratch/unit-inject.toml" python3 "$CFG" get agent.provider 2>/dev/null | wc -l)" "2"
if AIRLOCK_CONFIG="$scratch/unit-inject.toml" python3 "$CFG" validate >/dev/null 2>&1; then
  bad "validate refuses a provider carrying a newline"
else
  ok "validate refuses a provider carrying a newline"
fi
case "$(dm_install "$scratch/unit-inject.toml" "$scratch/r-inject")" in
  *"must not contain newlines"*) ok "the installer refuses it too, without validate's help" ;;
  *) bad "the installer refuses it too, without validate's help" ;;
esac
if [ -f "$scratch/r-inject/units/airlock-dev-monitor.service" ]; then
  bad "  ...and writes no unit at all"
else
  ok "  ...and writes no unit at all"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
