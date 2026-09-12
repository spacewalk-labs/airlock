#!/usr/bin/env bash
# Offline integrity and provenance checks for the Paseo package set shipped by Airlock.
set -euo pipefail
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BUNDLE="$ROOT/apps/paseo/vendor/guarded-0.2.5"
INSTALLED_SUMS="$BUNDLE/INSTALLED_SHA256SUMS"
EXPECTED_SOURCE=06697f6f6a2495e8040efdb81d4562f0f839e882

cd "$BUNDLE"
sha256sum -c SHA256SUMS

mapfile -t archives < <(find . -maxdepth 1 -type f -name '*.tgz' -printf '%f\n' | sort)
mapfile -t listed < <(awk '{print $2}' SHA256SUMS | sort)
[ "${#archives[@]}" -eq 6 ]
[ "${archives[*]}" = "${listed[*]}" ]

for archive in "${archives[@]}"; do
  package="$(tar -xOf "$archive" package/package.json | node -e '
    let data = "";
    process.stdin.on("data", chunk => data += chunk);
    process.stdin.on("end", () => {
      const value = JSON.parse(data);
      if (value.version !== "0.2.5" || !value.name.startsWith("@getpaseo/")) process.exit(1);
      process.stdout.write(value.name);
    });
  ')"
  expected_archive="getpaseo-${package#@getpaseo/}-0.2.5.tgz"
  [ "$archive" = "$expected_archive" ]
done

while read -r expected installed_path; do
  package="${installed_path#@getpaseo/}"
  package="${package%%/*}"
  archive="$BUNDLE/getpaseo-$package-0.2.5.tgz"
  archive_path="package/${installed_path#@getpaseo/"$package"/}"
  actual="$(tar -xOf "$archive" "$archive_path" | sha256sum | cut -d' ' -f1)"
  [ "$actual" = "$expected" ]
done < "$INSTALLED_SUMS"

server_archive="$BUNDLE/getpaseo-server-0.2.5.tgz"
server_info="$(tar -xOf "$server_archive" package/dist/server/server/websocket-server.js)"
grep -qF 'agentMessageSendGuard: true' <<<"$server_info"
grep -qF 'scheduleStateRestore: true' <<<"$server_info"
grep -qF 'agentRequestReceipts: false' <<<"$server_info"

mcp_shared="$(tar -xOf "$server_archive" package/dist/server/server/agent/mcp-shared.js)"
paseo_tools="$(tar -xOf "$server_archive" package/dist/server/server/agent/tools/paseo-tools.js)"
session_info="$(tar -xOf "$server_archive" package/dist/server/server/session.js)"
grep -qF 'archivedAt: record.archivedAt' <<<"$mcp_shared"
grep -qF 'status: "closed"' <<<"$mcp_shared"
grep -qF '.filter((agent) => includeArchived || !agent.archivedAt)' <<<"$paseo_tools"
grep -qF 'action: "agent.archive"' <<<"$session_info"
grep -qF 'actor: "unattributed"' <<<"$session_info"
grep -qF 'phase: "failed"' <<<"$session_info"

grep -qF "$EXPECTED_SOURCE" "$BUNDLE/README.md"
verify_line="$(grep -nF 'sha256sum -c SHA256SUMS >/dev/null' "$ROOT/apps/paseo/install.sh" | cut -d: -f1)"
handover_line="$(grep -nF 'airlock_handover_user_resource pidfile' "$ROOT/apps/paseo/install.sh" | cut -d: -f1)"
[ "$verify_line" -lt "$handover_line" ]
printf 'paseo-bundle: 6 packages verified, source=%s\n' "$EXPECTED_SOURCE"
