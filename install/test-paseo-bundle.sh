#!/usr/bin/env bash
# Offline integrity and provenance checks for the Paseo package set shipped by Airlock.
set -euo pipefail
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUNDLE="$ROOT/apps/paseo/vendor/guarded-0.8.0"
INSTALLED_SUMS="$BUNDLE/INSTALLED_SHA256SUMS"
EXPECTED_SOURCE=b8e24677e12b226c7c38c1c3a40649daa9f1152f

cd "$BUNDLE"
sha256sum -c SHA256SUMS

mapfile -t archives < <(find . -maxdepth 1 -type f -name '*.tgz' -printf '%f\n' | sort)
mapfile -t listed < <(awk '{print $2}' SHA256SUMS | sort)
[ "${#archives[@]}" -eq 7 ]
[ "${archives[*]}" = "${listed[*]}" ]

for archive in "${archives[@]}"; do
  package="$(tar -xOf "$archive" package/package.json | node -e '
    let data = "";
    process.stdin.on("data", chunk => data += chunk);
    process.stdin.on("end", () => {
      const value = JSON.parse(data);
      if (value.version !== "0.8.0" || !value.name.startsWith("@getpaseo/")) process.exit(1);
      process.stdout.write(value.name);
    });
  ')"
  expected_archive="getpaseo-${package#@getpaseo/}-0.8.0.tgz"
  [ "$archive" = "$expected_archive" ]
done

while read -r expected installed_path; do
  package="${installed_path#@getpaseo/}"
  package="${package%%/*}"
  archive="$BUNDLE/getpaseo-$package-0.8.0.tgz"
  archive_path="package/${installed_path#@getpaseo/"$package"/}"
  actual="$(tar -xOf "$archive" "$archive_path" | sha256sum | cut -d' ' -f1)"
  [ "$actual" = "$expected" ]
done < "$INSTALLED_SUMS"

server_archive="$BUNDLE/getpaseo-server-0.8.0.tgz"
server_info="$(tar -xOf "$server_archive" package/dist/server/server/websocket-server.js)"
grep -qF 'agentMessageSendGuard: true' <<<"$server_info"
grep -qF 'scheduleStateRestore: true' <<<"$server_info"
# Upstream's own request-dedup journal (agent/requests/index.ts) now covers what
# the 0.2.5-era fork's agentRequestReceipts flag intentionally left incomplete
# (keyed agent creation); we reuse it as-is and no longer force this false.
grep -qF 'agentRequestReceipts: true' <<<"$server_info"

agent_manager="$(tar -xOf "$server_archive" package/dist/server/server/agent/agent-manager.js)"
session_info="$(tar -xOf "$server_archive" package/dist/server/server/session.js)"
schedule_store="$(tar -xOf "$server_archive" package/dist/server/server/schedule/store.js)"
grep -qF 'class AgentMessageSendGuardRejectedError extends Error' <<<"$agent_manager"
grep -qF 'isAgentMessageSendGuardRejectedError' <<<"$agent_manager"
grep -qF 'msg.guard && msg.agentId !== msg.guard.expectedAgentId' <<<"$session_info"
grep -qF 'async transitionState(input, transition)' <<<"$schedule_store"
grep -qF 'async restoreState(input, restore)' <<<"$schedule_store"

# Four local Airlock patches with no runtime behaviour test (pure syntactic
# edits — depth4, image persistence, model prune, opencode picker defaults —
# muse-spark-1.3-contributor first at xhigh, then grok-4.6 at high, then
# grok-build) are also baked into this bundle, same as the 0.2.5 predecessor
# baked in every patch it shipped: a stock re-download of the same version
# cannot silently drop any of them.
claude_agent="$(tar -xOf "$server_archive" package/dist/server/server/agent/providers/claude/agent.js)"
model_manifest="$(tar -xOf "$server_archive" package/dist/server/server/agent/providers/claude/model-manifest.js)"
opencode_agent="$(tar -xOf "$server_archive" package/dist/server/server/agent/providers/opencode-agent.js)"
grep -qF 'maxDepth: searchesWorkspace ? undefined : 4' <<<"$session_info"
grep -qF '[paseo-attachments-persist]' <<<"$claude_agent"
grep -qF '[airlock-model-prune]' <<<"$model_manifest"
grep -qF '[airlock-opencode-grok-defaults]' <<<"$opencode_agent"
grep -qF 'const preferred = ["opencode-go/muse-spark-1.3-contributor", "xai/grok-4.6", "xai/grok-build-0.1"];' <<<"$opencode_agent"
grep -qF 'rawVariants.includes("xhigh")' <<<"$opencode_agent"
# provider-subagent-stream-filter DOES have a runtime behaviour test
# (provider-subagent-stream-filter.test.mjs, run at install time whenever the
# sentinel is present) — baked in because that test passes cleanly against the
# 0.8.0-derived candidate.
grep -qF '[paseo-provider-subagent-stream-filter]' <<<"$session_info"

# schedule-busy-pending-delivery also has its own runtime behaviour test
# (schedule-busy-pending-delivery.test.mjs). The stub agentManager it drives was
# stale for 0.8.0's agent-execution API (executeSchedule's agent-target path now
# goes through startAgentRun()/steerOrReplaceActiveTurn()/streamAgent()/
# replaceAgentRun()/waitForAgentEvent(), not the simpler 0.2.5-era runAgent()) --
# fixed, verified against the real 0.8.0 dist, so baked in too. The schema half
# (schedule-pending-delivery-schema.mjs, protocol's StoredScheduleSchema) was
# already baked; both halves now ship together.
schedule_service="$(tar -xOf "$server_archive" package/dist/server/server/schedule/service.js)"
grep -qF '[paseo-schedule-pending]' <<<"$schedule_service"

# orphan-process-guard (claude) and orphan-process-group (claude-agent,
# claude-query, codex-transport) also have their own runtime behaviour tests
# (orphan-process-guard.test.mjs, orphan-process-group.test.mjs) that pass
# cleanly against the 0.8.0-derived candidates, so they are baked in too, same
# reasoning as provider-subagent-stream-filter above. codex has no
# orphan-process-guard counterpart any more: 0.8.0 independently fixed that
# leak upstream (see orphan-process-guard.mjs's header).
claude_query="$(tar -xOf "$server_archive" package/dist/server/server/agent/providers/claude/query.js)"
codex_transport="$(tar -xOf "$server_archive" package/dist/server/server/agent/providers/codex/app-server-transport.js)"
grep -qF '[paseo-orphan-guard]' <<<"$claude_agent"
grep -qF '[paseo-process-group]' <<<"$claude_agent"
grep -qF '[paseo-process-group]' <<<"$claude_query"
grep -qF '[paseo-process-group]' <<<"$codex_transport"

grep -qF "$EXPECTED_SOURCE" "$BUNDLE/README.md"
verify_line="$(grep -nF 'sha256sum -c SHA256SUMS >/dev/null' "$ROOT/apps/paseo/install.sh" | cut -d: -f1)"
handover_line="$(grep -nF 'airlock_handover_user_resource pidfile' "$ROOT/apps/paseo/install.sh" | cut -d: -f1)"
[ "$verify_line" -lt "$handover_line" ]
printf 'paseo-bundle: 7 packages verified, source=%s\n' "$EXPECTED_SOURCE"
