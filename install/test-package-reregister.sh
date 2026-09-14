#!/usr/bin/env bash
# Focused acceptance fixture for disable/remove -> same-id package registration.
# It uses only scratch configs/checkouts and a local HTTP server; it never installs to
# the host or changes services, units, Node, databases, or the operator's Airlock files.
set -euo pipefail

# This suite reaches the real platform installer through the R4 transaction fixture.
# Pin the RAM-derived Paseo unit values so render-parity is independent of its host.
export AIRLOCK_PASEO_MEM_CAP_BYTES=34359738368

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/airlock-reregister.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

run_capture() {
  local output="$1"
  shift
  local rc=0
  "$@" >"$output" || rc=$?
  # Nested suites used to print their own partial ACs. Keep their diagnostics visible,
  # but let this entrypoint emit exactly one recomputed line for each card criterion.
  grep -v '^AC-' "$output" >&2 || true
  return "$rc"
}

observed_value() {
  local output="$1" criterion="$2" name="$3"
  python3 - "$output" "$criterion" "$name" <<'PY'
from pathlib import Path
import sys

path, criterion, name = sys.argv[1:]
rows = [line for line in Path(path).read_text().splitlines()
        if line.startswith(criterion + " | ")]
if len(rows) != 1 or " | observed: " not in rows[0]:
    print("UNMEASURED")
    raise SystemExit
body = rows[0].split(" | observed: ", 1)[1].split(" | verdict: ", 1)[0]
values = {}
for item in body.split(","):
    if "=" in item:
        key, value = item.split("=", 1)
        values[key] = value
print(values.get(name, "UNMEASURED"))
PY
}

judge_ones() {
  local value unknown=0
  for value in "$@"; do
    case "$value" in
      1) ;;
      UNMEASURED) unknown=1 ;;
      *) printf 'FAIL\n'; return ;;
    esac
  done
  if [ "$unknown" = 1 ]; then
    printf 'UNMEASURED\n'
  else
    printf 'PASS\n'
  fi
}

backend_rc=0
run_capture "$TMP/backend.out" python3 apps/dev-monitor/test-backend.py \
  PackageReregistrationTest \
  UpdateExecRouteTest.test_app_store_get_and_mutations_share_the_owner_gate_and_install_scope \
  UpdateExecRouteTest.test_personal_stale_lock_registration_keeps_register_route_and_reapproves \
  UpdateExecRouteTest.test_company_stale_lock_registration_uses_the_approved_reapproval_path \
  UpdateExecRouteTest.test_personal_registration_refuses_changed_or_denied_preview \
  UpdateExecRouteTest.test_personal_reapproval_uses_the_closed_install_action_and_break_glass \
  UpdateExecEndToEndTest.test_personal_install_rechecks_the_approved_digest_before_running \
  UpdateExecEndToEndTest.test_failed_install_has_no_unrelated_update_rollback \
  UpdateExecEndToEndTest.test_reapproval_passes_only_the_scoped_break_glass_flag_to_installer \
  || backend_rc=$?

transaction_rc=0
run_capture "$TMP/transaction.out" bash install/test-installer-transaction.sh \
  --case personal-path-r4-transaction || transaction_rc=$?

hub_rc=0
run_capture "$TMP/hub.out" bash install/test-hub-filter.sh || hub_rc=$?

manifest_rc=0
run_capture "$TMP/manifest.out" bash install/public-manifest.sh --check || manifest_rc=$?

# R4/R5 were measured on a disposable guest and the guest was then destroyed.  The
# committed verifier replays the sealed raw observation bundle; do not silently turn a
# missing, tampered, stale, or failing record back into a source-only pass.
sealed_evidence_verifier="docs/evidence/verify-ast-personal-path-r5-ebeff7b.py"
sealed_evidence_rc=0
run_capture "$TMP/sealed-evidence.out" python3 "$sealed_evidence_verifier" \
  || sealed_evidence_rc=$?
tamper_controls_rc=0
TMPDIR="$TMP" PYTHONDONTWRITEBYTECODE=1 \
  run_capture "$TMP/tamper-controls.out" \
  python3 docs/evidence/test-verify-ast-personal-path-r5-ebeff7b.py \
  || tamper_controls_rc=$?

revision="$(git rev-parse --short=12 HEAD)"
merged_source=0
reverse_ancestry_rejected=0
if git merge-base --is-ancestor 6c4595cd35720a8a1bca86c4e125c82f5d0c59fd HEAD; then
  merged_source=1
fi
# Mutation control for the ancestry predicate: reversing the relationship must not
# accept this post-merge verification commit as an ancestor of the older merge commit.
if ! git merge-base --is-ancestor HEAD 6c4595cd35720a8a1bca86c4e125c82f5d0c59fd; then
  reverse_ancestry_rejected=1
fi

backend_ok=$((backend_rc == 0 ? 1 : 0))
registered_reapproval="$(observed_value "$TMP/backend.out" AC-AST-R2 registered_reapproval)"
personal_remove_reregister="$(observed_value "$TMP/backend.out" AC-AST-R2 personal_remove_reregister)"
company_remove_reregister="$(observed_value "$TMP/backend.out" AC-AST-R2 company_remove_reregister)"
company_noop_remove_rejected="$(observed_value "$TMP/backend.out" AC-AST-R2 company_noop_remove_rejected)"
company_noop_register_rejected="$(observed_value "$TMP/backend.out" AC-AST-R2 company_noop_register_rejected)"
r2_mutation_rejected=0
if [ "$(judge_ones "$merged_source" "$reverse_ancestry_rejected" "$backend_ok" \
    "$registered_reapproval" "$personal_remove_reregister" 0 \
    "$company_noop_remove_rejected" "$company_noop_register_rejected")" = FAIL ]; then
  r2_mutation_rejected=1
fi
r2_verdict="$(judge_ones "$merged_source" "$reverse_ancestry_rejected" "$backend_ok" \
  "$registered_reapproval" "$personal_remove_reregister" "$company_remove_reregister" \
  "$company_noop_remove_rejected" "$company_noop_register_rejected" \
  "$r2_mutation_rejected")"
printf 'AC-AST-R2 | expected: merged_source == 1 && reverse_ancestry_rejected == 1 && backend_ok == 1 && registered_reapproval == 1 && personal_remove_reregister == 1 && company_remove_reregister == 1 && company_noop_remove_rejected == 1 && company_noop_register_rejected == 1 && mutation_rejected == 1 | observed: merged_source=%s,reverse_ancestry_rejected=%s,backend_ok=%s,registered_reapproval=%s,personal_remove_reregister=%s,company_remove_reregister=%s,company_noop_remove_rejected=%s,company_noop_register_rejected=%s,mutation_rejected=%s | verdict: %s | signal: fixture | evidence: install/test-package-reregister.sh@%s\n' \
  "$merged_source" "$reverse_ancestry_rejected" "$backend_ok" \
  "$registered_reapproval" "$personal_remove_reregister" "$company_remove_reregister" \
  "$company_noop_remove_rejected" "$company_noop_register_rejected" \
  "$r2_mutation_rejected" "$r2_verdict" "$revision"

digest_rejected_no_mutation="$(observed_value "$TMP/backend.out" AC-AST-R3 digest_rejected_no_mutation)"
capability_rejected_no_mutation="$(observed_value "$TMP/backend.out" AC-AST-R3 capability_rejected_no_mutation)"
drift_no_execution="$(observed_value "$TMP/backend.out" AC-AST-R3 drift_no_execution)"
committed_config_preserved="$(observed_value "$TMP/backend.out" AC-AST-R3 committed_config_preserved)"
r3_mutation_rejected=0
if [ "$(judge_ones "$merged_source" "$reverse_ancestry_rejected" "$backend_ok" \
    "$digest_rejected_no_mutation" "$capability_rejected_no_mutation" \
    "$drift_no_execution" 0)" = FAIL ]; then
  r3_mutation_rejected=1
fi
r3_verdict="$(judge_ones "$merged_source" "$reverse_ancestry_rejected" "$backend_ok" \
  "$digest_rejected_no_mutation" "$capability_rejected_no_mutation" \
  "$drift_no_execution" "$committed_config_preserved" "$r3_mutation_rejected")"
printf 'AC-AST-R3 | expected: merged_source == 1 && reverse_ancestry_rejected == 1 && backend_ok == 1 && digest_rejected_no_mutation == 1 && capability_rejected_no_mutation == 1 && drift_no_execution == 1 && committed_config_preserved == 1 && mutation_rejected == 1 | observed: merged_source=%s,reverse_ancestry_rejected=%s,backend_ok=%s,digest_rejected_no_mutation=%s,capability_rejected_no_mutation=%s,drift_no_execution=%s,committed_config_preserved=%s,mutation_rejected=%s | verdict: %s | signal: fixture | evidence: install/test-package-reregister.sh@%s\n' \
  "$merged_source" "$reverse_ancestry_rejected" "$backend_ok" \
  "$digest_rejected_no_mutation" "$capability_rejected_no_mutation" \
  "$drift_no_execution" "$committed_config_preserved" "$r3_mutation_rejected" \
  "$r3_verdict" "$revision"

transaction_ok=$((transaction_rc == 0 ? 1 : 0))
actual_installer_transaction="$(observed_value "$TMP/transaction.out" AC-AST-R4-TRANSACTION positive)"
noop_installer_rejected="$(observed_value "$TMP/transaction.out" AC-AST-R4-TRANSACTION noop_installer_rejected)"
recovery_corruption_rejected="$(observed_value "$TMP/transaction.out" AC-AST-R4-TRANSACTION recovery_rejected)"
receipt_tamper_rejected="$(observed_value "$TMP/transaction.out" AC-AST-R4-TRANSACTION receipt_tamper_rejected)"
sealed_evidence_ok=$((sealed_evidence_rc == 0 ? 1 : 0))
attested_rollback_reentry="$(observed_value "$TMP/sealed-evidence.out" AC-AST-R5 attested_rollback_reentry)"
r4_verdict="$(judge_ones "$merged_source" "$transaction_ok" "$actual_installer_transaction" \
  "$noop_installer_rejected" "$recovery_corruption_rejected" \
  "$receipt_tamper_rejected" "$sealed_evidence_ok" "$attested_rollback_reentry")"
printf 'AC-AST-R4 | expected: merged_source == 1 && transaction_ok == 1 && actual_installer_transaction == 1 && noop_installer_rejected == 1 && recovery_corruption_rejected == 1 && receipt_tamper_rejected == 1 && sealed_evidence_ok == 1 && attested_rollback_reentry == 1 | observed: merged_source=%s,transaction_ok=%s,actual_installer_transaction=%s,noop_installer_rejected=%s,recovery_corruption_rejected=%s,receipt_tamper_rejected=%s,sealed_evidence_ok=%s,attested_rollback_reentry=%s | verdict: %s | signal: replay | evidence: %s@%s\n' \
  "$merged_source" "$transaction_ok" "$actual_installer_transaction" \
  "$noop_installer_rejected" "$recovery_corruption_rejected" \
  "$receipt_tamper_rejected" "$sealed_evidence_ok" "$attested_rollback_reentry" \
  "$r4_verdict" "$sealed_evidence_verifier" "$revision"

public_paths_classified=1
for path in bin/airlock-config hub/index.html \
    apps/dev-monitor/backend/devmon_apps.py \
    apps/dev-monitor/backend/airlock-dev-monitor.py \
    apps/dev-monitor/backend/action_runner.py \
    apps/dev-monitor/backend/devmon_update_exec.py \
    install/airlock-install.sh install/test-package-reregister.sh; do
  [ "$(bash install/public-manifest.sh --classify "$path" | cut -f1)" = public ] \
    || public_paths_classified=0
done
private_control_classified=0
if [ "$(bash install/public-manifest.sh --classify AGENTS.md | cut -f1)" = private ]; then
  private_control_classified=1
fi
unclassified_path_rejected=0
if ! bash install/public-manifest.sh --classify __ast_unclassified_mutation__ \
    >"$TMP/unclassified.out" 2>&1; then
  unclassified_path_rejected=1
fi
evidence_integrity="$(observed_value "$TMP/sealed-evidence.out" AC-AST-R5 evidence_integrity)"
summary_verdict_ok="$(observed_value "$TMP/sealed-evidence.out" AC-AST-R5 summary_verdict_ok)"
private_revision_ancestor="$(observed_value "$TMP/sealed-evidence.out" AC-AST-R5 private_revision_ancestor)"
runtime_paths_unchanged="$(observed_value "$TMP/sealed-evidence.out" AC-AST-R5 runtime_paths_unchanged)"
projection_revision_bound="$(observed_value "$TMP/sealed-evidence.out" AC-AST-R5 projection_revision_bound)"
installed_revision_bound="$(observed_value "$TMP/sealed-evidence.out" AC-AST-R5 installed_revision_bound)"
raw_register_done="$(observed_value "$TMP/sealed-evidence.out" AC-AST-R5 raw_register_done)"
raw_remove_done="$(observed_value "$TMP/sealed-evidence.out" AC-AST-R5 raw_remove_done)"
raw_remove_route_retired="$(observed_value "$TMP/sealed-evidence.out" AC-AST-R5 raw_remove_route_retired)"
raw_reregister_done="$(observed_value "$TMP/sealed-evidence.out" AC-AST-R5 raw_reregister_done)"
raw_reregister_route_nonce="$(observed_value "$TMP/sealed-evidence.out" AC-AST-R5 raw_reregister_route_nonce)"
raw_403_recovery="$(observed_value "$TMP/sealed-evidence.out" AC-AST-R5 raw_403_recovery)"
owner_gui_reregister="$(observed_value "$TMP/sealed-evidence.out" AC-AST-R5 owner_gui_reregister)"
service_smoke="$(observed_value "$TMP/sealed-evidence.out" AC-AST-R5 service_smoke)"
tamper_controls_ok=$((tamper_controls_rc == 0 ? 1 : 0))
manifest_ok=$((manifest_rc == 0 ? 1 : 0))
hub_ok=$((hub_rc == 0 ? 1 : 0))
r5_verdict="$(judge_ones "$manifest_ok" "$hub_ok" "$public_paths_classified" \
  "$private_control_classified" "$unclassified_path_rejected" "$sealed_evidence_ok" \
  "$evidence_integrity" "$summary_verdict_ok" "$private_revision_ancestor" \
  "$runtime_paths_unchanged" "$projection_revision_bound" "$installed_revision_bound" \
  "$raw_register_done" "$raw_remove_done" "$raw_remove_route_retired" \
  "$raw_reregister_done" "$raw_reregister_route_nonce" "$raw_403_recovery" \
  "$owner_gui_reregister" "$service_smoke" "$tamper_controls_ok")"
printf 'AC-AST-R5 | expected: manifest_ok == 1 && hub_ok == 1 && public_paths_classified == 1 && private_control_classified == 1 && unclassified_path_rejected == 1 && sealed_evidence_ok == 1 && evidence_integrity == 1 && summary_verdict_ok == 1 && private_revision_ancestor == 1 && runtime_paths_unchanged == 1 && projection_revision_bound == 1 && installed_revision_bound == 1 && raw_register_done == 1 && raw_remove_done == 1 && raw_remove_route_retired == 1 && raw_reregister_done == 1 && raw_reregister_route_nonce == 1 && raw_403_recovery == 1 && owner_gui_reregister == 1 && service_smoke == 1 && tamper_controls_ok == 1 | observed: manifest_ok=%s,hub_ok=%s,public_paths_classified=%s,private_control_classified=%s,unclassified_path_rejected=%s,sealed_evidence_ok=%s,evidence_integrity=%s,summary_verdict_ok=%s,private_revision_ancestor=%s,runtime_paths_unchanged=%s,projection_revision_bound=%s,installed_revision_bound=%s,raw_register_done=%s,raw_remove_done=%s,raw_remove_route_retired=%s,raw_reregister_done=%s,raw_reregister_route_nonce=%s,raw_403_recovery=%s,owner_gui_reregister=%s,service_smoke=%s,tamper_controls_ok=%s | verdict: %s | signal: replay | evidence: %s@%s\n' \
  "$manifest_ok" "$hub_ok" "$public_paths_classified" "$private_control_classified" \
  "$unclassified_path_rejected" "$sealed_evidence_ok" "$evidence_integrity" \
  "$summary_verdict_ok" "$private_revision_ancestor" "$runtime_paths_unchanged" \
  "$projection_revision_bound" "$installed_revision_bound" "$raw_register_done" \
  "$raw_remove_done" "$raw_remove_route_retired" "$raw_reregister_done" \
  "$raw_reregister_route_nonce" "$raw_403_recovery" "$owner_gui_reregister" \
  "$service_smoke" "$tamper_controls_ok" "$r5_verdict" \
  "$sealed_evidence_verifier" "$revision"

if [ "$backend_rc" -ne 0 ] || [ "$transaction_rc" -ne 0 ] \
    || [ "$hub_rc" -ne 0 ] || [ "$manifest_rc" -ne 0 ] || [ "$sealed_evidence_rc" -ne 0 ] \
    || [ "$tamper_controls_rc" -ne 0 ] \
    || [ "$r2_verdict" != PASS ] || [ "$r3_verdict" != PASS ] \
    || [ "$r4_verdict" != PASS ] || [ "$r5_verdict" != PASS ]; then
  exit 1
fi
