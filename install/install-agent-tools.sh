#!/usr/bin/env bash
# Install and execute-check the agent CLIs and harness prerequisite tools.
# Runs inside the Ubuntu host or OrbStack guest as root; login remains a human step.
set -euo pipefail

user="${1:?usage: install-agent-tools.sh USER}"
[ "$(id -u)" = 0 ] || { echo "agent tools: root is required" >&2; exit 1; }
id -u "$user" >/dev/null 2>&1 || { echo "agent tools: unknown user: $user" >&2; exit 1; }
home="$(getent passwd "$user" | cut -d: -f6)"
[ -n "$home" ] && [ -d "$home" ] && [ ! -L "$home" ] \
  || { echo "agent tools: unsafe home for $user: $home" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
# Install one at a time: one unavailable package must not make the other prerequisites
# disappear from the box without saying which name failed.
for package in git jq gitleaks unzip; do
  apt-get install -y -qq "$package" >/dev/null \
    || { echo "agent tools: apt package failed: $package" >&2; exit 1; }
done

command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1 \
  || { echo "agent tools: node and npm must be installed first" >&2; exit 1; }
node_major="$(node -p 'process.versions.node.split(".")[0]')"
case "$node_major" in *[!0-9]*|'') echo "agent tools: unreadable node version" >&2; exit 1 ;; esac
[ "$node_major" -ge 20 ] \
  || { echo "agent tools: node $node_major is too old; need 20 or newer" >&2; exit 1; }

npm install -g @anthropic-ai/claude-code @openai/codex pnpm >/dev/null

tool_path="/usr/local/bin:$home/.local/bin:$home/.opencode/bin:/usr/bin:/bin"
if ! runuser -u "$user" -- env HOME="$home" PATH="$tool_path" \
    sh -c 'opencode --version >/dev/null 2>&1'; then
  runuser -u "$user" -- env HOME="$home" PATH="$tool_path" \
    sh -c 'curl -fsSL https://opencode.ai/install | sh'
fi
install -d -o "$user" -g "$user" -m 0755 "$home/.local/bin"
if [ -x "$home/.opencode/bin/opencode" ]; then
  ln -sfn "$home/.opencode/bin/opencode" "$home/.local/bin/opencode"
  chown -h "$user:$user" "$home/.local/bin/opencode"
fi

runuser -u "$user" -- env HOME="$home" PATH="$tool_path" bash -c '
set -e
[ "$(node -p '\''process.versions.node.split(".")[0]'\'')" -ge 20 ]
claude --version >/dev/null
codex --version >/dev/null
opencode --version >/dev/null
pnpm --version >/dev/null
jq --version >/dev/null
gitleaks version >/dev/null
git --version >/dev/null
unzip -v >/dev/null
'

printf 'agent tools installed and executable for %s\n' "$user"
