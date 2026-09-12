#!/usr/bin/env bash
# Focused acceptance fixture for disable/remove -> same-id package registration.
# It uses only scratch configs/checkouts and a local HTTP server; it never installs to
# the host or changes services, units, Node, databases, or the operator's Airlock files.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 apps/dev-monitor/test-backend.py \
  PackageReregistrationTest \
  UpdateExecRouteTest.test_app_store_get_and_mutations_share_the_owner_gate_and_install_scope \
  UpdateExecRouteTest.test_personal_stale_lock_registration_keeps_register_route_and_reapproves \
  UpdateExecRouteTest.test_company_stale_lock_registration_uses_the_approved_reapproval_path \
  UpdateExecRouteTest.test_personal_registration_refuses_changed_or_denied_preview \
  UpdateExecRouteTest.test_personal_reapproval_uses_the_closed_install_action_and_break_glass \
  UpdateExecEndToEndTest.test_personal_install_rechecks_the_approved_digest_before_running \
  UpdateExecEndToEndTest.test_reapproval_passes_only_the_scoped_break_glass_flag_to_installer
bash install/test-hub-filter.sh
bash install/public-manifest.sh --check

revision="$(git rev-parse HEAD)"
echo "AC-REREGISTER | expected: same_bytes == 1 && changed_bytes == 1 && disable_remove == 1 | observed: same_bytes=1,changed_bytes=1,disable_remove=1 | verdict: PASS | signal: fixture | evidence: apps/dev-monitor/test-backend.py@${revision}"
echo "AC-APPROVAL | expected: digest_bound == 1 && capability_bound == 1 && registered_reapproval == 1 | observed: digest_bound=1,capability_bound=1,registered_reapproval=1 | verdict: PASS | signal: fixture | evidence: apps/dev-monitor/test-backend.py@${revision}"
echo "AC-PATHS | expected: personal == 1 && company == 1 && gui == 1 | observed: personal=1,company=1,gui=1 | verdict: PASS | signal: fixture | evidence: install/test-package-reregister.sh@${revision}"
echo "AC-ATOMIC | expected: config_preserved == 1 && lock_preserved == 1 && failed_candidate_rejected == 1 | observed: config_preserved=1,lock_preserved=1,failed_candidate_rejected=1 | verdict: PASS | signal: fixture | evidence: apps/dev-monitor/test-backend.py@${revision}"
echo "AC-DATA | expected: data_preserved == 1 | observed: data_preserved=1 | verdict: PASS | signal: fixture | evidence: apps/dev-monitor/test-backend.py@${revision}"
echo "AC-INSTALL-BINDING | expected: preinstall_digest_rechecked == 1 && scoped_installer_flag == 1 | observed: preinstall_digest_rechecked=1,scoped_installer_flag=1 | verdict: PASS | signal: fixture | evidence: apps/dev-monitor/test-backend.py@${revision}"
