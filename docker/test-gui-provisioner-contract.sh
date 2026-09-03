#!/usr/bin/env bash
# Fast structural regression checks for the guest provisioner and its LXD-side E2E.
# shellcheck disable=SC2016 # The grep probes intentionally match literal shell source.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVISIONER="$HERE/gui-provisioner.sh"
E2E="$HERE/test-gui-provisioner-e2e.sh"
VERSION_TEST="$HERE/test-gui-version-relation.py"
PREREQUISITES="$HERE/../install/prerequisites.tsv"

pass=0 fail=0
ok() { printf 'ok   gui-provisioner: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL gui-provisioner: %s\n' "$1"; fail=$((fail + 1)); }

if bash -n "$PROVISIONER" "$E2E"; then
  ok "guest and E2E scripts parse as Bash"
else
  bad "Bash syntax check failed"
fi

version_result="$(python3 "$VERSION_TEST" 2>&1)"
if [ "$version_result" = "passed=7 failed=0" ]; then
  ok "version relation classifies forward, rollback and ambiguous candidates"
else
  bad "version relation behavior failed: $version_result"
fi

forbidden='lxc[[:space:]]+(launch|delete|config|profile|storage)'
if grep -En "$forbidden" "$E2E" "$PROVISIONER" >/dev/null; then
  bad "public scripts contain a forbidden LXD lifecycle operation"
elif grep -Fq ': "${AIRLOCK_E2E_TARGET:?' "$E2E" \
  && grep -Fq ': "${AIRLOCK_TS_AUTHKEY_FILE:?' "$E2E"; then
  ok "driver has no launch/delete/config/profile/storage and requires its target inputs"
else
  bad "driver no longer requires explicit target/auth inputs"
fi

if grep -Eq 'guest[[:space:]]+bash[[:space:]]+-c' "$E2E"; then
  bad "driver sends shell fragments through SSH, which loses argv quoting"
elif [ "$(grep -c '^guest tee /run/' "$E2E")" = 3 ]; then
  ok "payloads cross SSH stdin through guest tee without a remote-shell redirection"
else
  bad "guest payload-delivery seam drifted"
fi

auth_install_line="$(grep -n 'guest install -m 0600 /dev/null /run/airlock-gui-authkey' "$E2E" | cut -d: -f1)"
auth_flag_line="$(grep -n '^key_delivered=1$' "$E2E" | cut -d: -f1)"
auth_tee_line="$(grep -n '^guest tee /run/airlock-gui-authkey' "$E2E" | cut -d: -f1)"
if [ -n "$auth_install_line" ] && [ -n "$auth_flag_line" ] && [ -n "$auth_tee_line" ] \
  && [ "$auth_install_line" -lt "$auth_flag_line" ] && [ "$auth_flag_line" -lt "$auth_tee_line" ]; then
  ok "auth cleanup is armed before key bytes can reach the guest"
else
  bad "auth cleanup is not armed between protected target creation and byte delivery"
fi

if grep -Fq 'tailscale up --auth-key="file:$auth_file"' "$PROVISIONER" \
  && ! grep -Eq '(cat|<)[[:space:]]*"?\$auth_file' "$PROVISIONER" \
  && grep -Fq 'rm -f "$auth_file"' "$PROVISIONER"; then
  ok "auth input is passed by file reference and deleted without being read into a shell value"
else
  bad "auth input file-only/cleanup contract drifted"
fi

wrong_tailnet_line="$(grep -n 'emit wrong-tailnet expected "$expected_tailnet"' "$PROVISIONER" | cut -d: -f1)"
installer_start_line="$(grep -n 'emit installer-start source_sha' "$PROVISIONER" | cut -d: -f1)"
if grep -Fq 'AIRLOCK_GUI_EXPECTED_TAILNET="$expected_tailnet"' "$E2E" \
  && [ -n "$wrong_tailnet_line" ] && [ -n "$installer_start_line" ] \
  && [ "$wrong_tailnet_line" -lt "$installer_start_line" ] \
  && grep -Fq 'refusing before stock install' "$PROVISIONER"; then
  ok "client tailnet is checked after auth and before stock install"
else
  bad "wrong-tailnet fail-fast contract drifted"
fi

version_block_line="$(grep -n 'emit version-blocked relation "$version_relation"' "$PROVISIONER" | cut -d: -f1)"
release_switch_line="$(grep -n 'ln -sfn "$release" /opt/airlock-gui/current' "$PROVISIONER" | cut -d: -f1)"
if [ -n "$version_block_line" ] && [ -n "$release_switch_line" ] && [ -n "$installer_start_line" ] \
  && [ "$version_block_line" -lt "$release_switch_line" ] \
  && [ "$version_block_line" -lt "$installer_start_line" ] \
  && grep -Fq 'rollback|ambiguous)' "$PROVISIONER"; then
  ok "rollback/ambiguous bundles stop before release switch and stock install"
else
  bad "stale-bundle fail-fast contract drifted"
fi

if grep -Fq -- "-w '%{http_code}|%{ssl_verify_result}'" "$E2E" \
  && ! grep -Eq 'curl[^\n]*(--insecure|[[:space:]]-k([[:space:]]|$))' "$E2E" \
  && grep -Fq '[ "$code" = 200 ] && [ "$tls" = 0 ]' "$E2E"; then
  ok "outside probes require HTTP 200 and TLS verification without -k"
else
  bad "outside HTTPS verdict contract drifted"
fi

if [ "$(grep -c '^provision_invocations=1$' "$E2E")" = 1 ] \
  && [ "$(grep -c 'bash /run/gui-provisioner.sh' "$E2E")" = 1 ]; then
  ok "E2E has one provisioner invocation path and records count one"
else
  bad "provisioner invocation-count contract drifted"
fi

if grep -Fq 'getent passwd airlock' "$E2E" \
  && grep -Fq 'command_name in git node nodejs nginx tailscale tailscaled' "$E2E" \
  && grep -Fq 'asserted_before_delivery' "$E2E"; then
  ok "pristine assertions precede delivery and are recorded"
else
  bad "pristine witness contract drifted"
fi

if grep -Fq $'core\tgit\tpresent\t-\tsudo apt-get update && sudo apt-get install -y git\t' \
    "$PREREQUISITES" \
  && grep -Fq 'command -v git >/dev/null' "$E2E" \
  && grep -Fq "dpkg-query -W -f='\${db:Status-Status}' git" "$E2E" \
  && grep -Fq '"git_installed": True' "$E2E"; then
  ok "a pristine host receives git for updates and repository-aware tools"
else
  bad "git prerequisite/install witness drifted"
fi

if grep -Fq 'lxc restart "$instance"' "$E2E" \
  && grep -Fq '"$boot_after" = "$boot_before"' "$E2E" \
  && grep -Fq 'external_probe_after_restart' "$E2E"; then
  ok "exact-instance restart requires a new boot ID and second outside probe"
else
  bad "restart/recovery contract drifted"
fi

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
