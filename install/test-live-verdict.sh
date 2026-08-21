#!/usr/bin/env bash
# install/test-live-verdict.sh — the live verdict must fail closed when any
# required coverage, acceptance, or numeric fact is malformed or missing.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VERDICT="$ROOT/live/verdict.py"
pass=0; fail=0
ok()  { echo "ok   live-verdict: $1"; pass=$((pass+1)); }
bad() { echo "FAIL live-verdict: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

make_record() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

path, case = sys.argv[1:3]
package_id = "other-example" if case == "external-id" else "hello-example"
record = {
    "run_id": "fixture-run",
    "commit": "0123456789abcdef0123456789abcdef01234567",
    "started_utc": "2026-08-17T00:00:00Z",
    "ended_utc": "2026-08-17T00:02:01Z",
    "host": "private-host",
    "container": "private-container",
    "image_fingerprint": "a" * 64,
    "cleanup_ok": True,
    "inner_rc": 0,
    "dev_monitor_messages_requested": False,
    "inner": {
        "dev_monitor_messages_requested": False,
        "fqdn": "private-container.private-tailnet.example",
        "commit": "0123456789abcdef0123456789abcdef01234567",
        "install_rc": 0,
        "smoke_rc": 0,
        "units_late": [{
            "id": "airlock-hello-example.service",
            "type": "simple",
            "active": "active",
            "sub": "running",
            "exec_status": "0",
        }],
        "smoke_lines": [
            f"[{package_id} smoke] backend=200 allowed=200 denied=403 anonymous=403"
        ],
        "external_packages": [package_id],
        # This is retained for human readers, not used by live/verdict.py.
        "external_gate_line_found": True,
        "acceptance": {
            "rc": 0,
            "passed": 25,
            "failed": 0,
            "log_tail": [],
        },
        "devmon_no_webhook": {"rc": 0, "observation": {"skipped": True}},
    },
}

if case.startswith("devmon-"):
    zero = {
        "watchdog_cards": 0,
        "watchdog_events": 0,
        "watchdog_notice_deliveries": 0,
    }
    record["dev_monitor_messages_requested"] = True
    record["inner"]["dev_monitor_messages_requested"] = True
    record["inner"]["devmon_no_webhook"] = {
        "rc": 0,
        "observation": {
            "messages_effective": "on",
            "observation_requested_seconds": 120,
            "observation_elapsed_milliseconds": 120123,
            "observation_seconds": 120,
            "worker_states": {
                "slack-urgent": "off: no webhook configured",
                "slack-routine": "off: no webhook configured",
            },
            "zero_snapshot": zero,
            "off_branch_control": {"delta": dict(zero)},
            "positive_control": {
                "reason_state": "stalled",
                "delta": {key: 1 for key in zero},
            },
            "unexpected_sensitive_field": "KNOWN_SECRET_SENTINEL",
        },
    }

if case == "smoke-3":
    record["inner"]["smoke_rc"] = 3
elif case == "gate-missing":
    # Keep the producer's boolean true: only the measured line disappears.
    record["inner"]["smoke_lines"] = []
elif case == "gate-boolean-false":
    # The measured line is present: the producer's convenience boolean is ignored.
    record["inner"]["external_gate_line_found"] = False
elif case == "external-packages-empty":
    record["inner"]["external_packages"] = []
elif case == "external-packages-absent":
    del record["inner"]["external_packages"]
elif case == "acceptance-absent":
    del record["inner"]["acceptance"]
elif case == "acceptance-rc-2":
    record["inner"]["acceptance"]["rc"] = 2
elif case == "acceptance-failed-2":
    record["inner"]["acceptance"]["failed"] = 2
elif case == "acceptance-passed-0":
    record["inner"]["acceptance"]["passed"] = 0
elif case == "acceptance-passed-below-floor":
    record["inner"]["acceptance"]["passed"] = 24
elif case == "install-bool":
    record["inner"]["install_rc"] = False
elif case == "smoke-string":
    record["inner"]["smoke_rc"] = "0"
elif case == "smoke-bool":
    record["inner"]["smoke_rc"] = False
elif case == "inner-bool":
    record["inner_rc"] = False
elif case == "acceptance-rc-bool":
    record["inner"]["acceptance"]["rc"] = False
elif case == "acceptance-passed-bool":
    record["inner"]["acceptance"]["passed"] = False
elif case == "acceptance-passed-string":
    record["inner"]["acceptance"]["passed"] = "25"
elif case == "acceptance-failed-bool":
    record["inner"]["acceptance"]["failed"] = False
elif case == "oneshot":
    record["inner"]["units_late"].append({
        "id": "airlock-publish-cleanup.service",
        "type": "oneshot",
        "active": "inactive",
        "sub": "dead",
        "exec_status": "0",
    })
elif case == "inner-error":
    # Keep the otherwise-green facts so this case tests the error marker alone.
    record["inner"]["error"] = "the inner document was not valid JSON"
elif case == "devmon-effective-off":
    record["inner"]["devmon_no_webhook"]["observation"]["messages_effective"] = "off"
elif case == "devmon-request-mismatch":
    record["inner"]["dev_monitor_messages_requested"] = False
elif case == "devmon-zero-nonzero":
    record["inner"]["devmon_no_webhook"]["observation"]["zero_snapshot"]["watchdog_cards"] = 1
elif case == "devmon-control-dead":
    record["inner"]["devmon_no_webhook"]["observation"]["positive_control"]["delta"]["watchdog_events"] = 0
elif case == "devmon-soak-short":
    record["inner"]["devmon_no_webhook"]["observation"]["observation_requested_seconds"] = 119
elif case == "devmon-elapsed-short":
    record["inner"]["devmon_no_webhook"]["observation"]["observation_elapsed_milliseconds"] = 119999
elif case == "devmon-off-branch-nonzero":
    record["inner"]["devmon_no_webhook"]["observation"]["off_branch_control"]["delta"]["watchdog_cards"] = 1
elif case == "devmon-zero-bool":
    record["inner"]["devmon_no_webhook"]["observation"]["zero_snapshot"]["watchdog_cards"] = False
elif case == "devmon-collector-failed":
    record["inner"]["devmon_no_webhook"]["rc"] = 1
elif case == "devmon-green":
    pass
elif case == "inner-commit-absent":
    del record["inner"]["commit"]
elif case == "inner-commit-mismatch":
    record["inner"]["commit"] = "b" * 40
else:
    # external-id changes one semantic fact; its smoke line follows that id.
    assert case in {"green", "external-id"}

with open(path, "w") as output:
    json.dump(record, output)
PY
}

run_case() {
  local name="$1" expected="$2"
  local path="$TMP/$name.json" out reason rc
  if ! make_record "$path" "$name"; then
    bad "$name fixture generation failed"
    return
  fi
  out="$(python3 "$VERDICT" "$path" 2>"$path.reason")"; rc=$?
  reason="$(cat "$path.reason")"
  if [ "$rc" = 0 ] && [ "$out" = "$expected" ] && [ -n "$reason" ]; then
    ok "$name => $expected"
  else
    bad "$name => expected $expected, got rc=$rc stdout='$out' stderr='$reason'"
  fi
}

run_case green 0
run_case external-id 0
run_case smoke-3 3
run_case gate-missing 1
run_case gate-boolean-false 0
run_case external-packages-empty 1
run_case external-packages-absent 1
run_case acceptance-absent 1
run_case acceptance-rc-2 1
run_case acceptance-failed-2 1
run_case acceptance-passed-0 1
run_case acceptance-passed-below-floor 1
run_case install-bool 1
run_case smoke-string 1
run_case smoke-bool 1
run_case inner-bool 1
run_case acceptance-rc-bool 1
run_case acceptance-passed-bool 1
run_case acceptance-passed-string 1
run_case acceptance-failed-bool 1
run_case oneshot 0
run_case inner-error 1
run_case devmon-green 0
run_case devmon-effective-off 1
run_case devmon-request-mismatch 1
run_case devmon-zero-nonzero 1
run_case devmon-control-dead 1
run_case devmon-soak-short 1
run_case devmon-elapsed-short 1
run_case devmon-off-branch-nonzero 1
run_case devmon-zero-bool 1
run_case devmon-collector-failed 1

public_raw="$TMP/public-raw.json"
public_out="$TMP/public.json"
make_record "$public_raw" devmon-green
if python3 "$ROOT/live/mkpublicresult.py" "$public_raw" "$public_out" \
   && python3 - "$public_out" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
gate = record["dev_monitor_no_webhook"]
assert record["schema"] == 2
assert record["reproduction_scope"].startswith("host-local:")
assert 'test "$(git rev-parse HEAD)" = 0123456789abcdef0123456789abcdef01234567' in record["reproduction"]
assert 'lxc image info ' + ('a' * 64) in record["reproduction"]
assert '~/.config/airlock-live/env' in record["reproduction"]
assert record["result"]["verdict_provenance"].startswith(
    "recomputed from the full local runner record")
assert gate["positive_control"]["reason_state"] == "stalled"
assert gate["off_branch_control"]["delta"]["watchdog_cards"] == 0
assert "same_database_positive_control" not in gate
assert "raw_result_sha256" not in record
blob = json.dumps(record)
for secret in ("private-host", "private-container", "private-tailnet",
               "KNOWN_SECRET_SENTINEL"):
    assert secret not in blob
PY
then
  ok "runner-native public evidence preserves collector keys and excludes private/raw fields"
else
  bad "runner-native public evidence was not an exact safe projection"
fi

if python3 - "$ROOT/live/check-devmon-no-webhook.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("live_collector", sys.argv[1])
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)
assert collector.observation_timing("120", "119999") == {
    "observation_requested_seconds": 120,
    "observation_elapsed_milliseconds": 119999,
    "observation_seconds": 119,
}
PY
then
  ok "collector timing reports the supplied monotonic measurement, not the requested argv"
else
  bad "collector timing echoed the requested soak instead of measured elapsed time"
fi
run_case inner-commit-absent 1
run_case inner-commit-mismatch 1

# A failed lxc launch may still have created the instance. Drive the real harness
# only through that boundary with a fake ssh endpoint: its own marker must cause
# exact-name cleanup, while a different marker is a negative control that must
# never be deleted.
MOCK_BIN="$TMP/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/ssh" <<'SH'
#!/usr/bin/env bash
command=${!#}
case "$command" in
  "command -v lxc >/dev/null") exit 0 ;;
  "lxc launch "*)
    name="$(printf '%s\n' "$command" | sed -n 's/^lxc launch [^ ]* \([^ ]*\) .*/\1/p')"
    marker="$(printf '%s\n' "$command" | sed -n 's/.*user\.airlock_live_owner_nonce=\([^ ]*\).*/\1/p')"
    [ "${MOCK_FOREIGN_MARKER:-0}" = 1 ] && marker=some-other-run
    printf '%s\n' "$name" > "$MOCK_STATE/name"
    printf '%s\n' "$marker" > "$MOCK_STATE/marker"
    [ "${MOCK_LAUNCH_SUCCESS:-0}" = 1 ] && exit 0
    exit 1
    ;;
  "lxc config get "*" user.airlock_live_owner_nonce")
    [ -f "$MOCK_STATE/marker" ] || exit 1
    cat "$MOCK_STATE/marker"
    ;;
  "lxc config get "*" volatile.base_image") printf 'fixture-image-fingerprint\n'; exit 0 ;;
  "lxc exec "*" systemctl is-system-running --wait") exit 0 ;;
  "cat > /tmp/"*)
    [ "${MOCK_SWAP_MARKER_ON_STAGE:-0}" = 1 ] && printf 'some-other-run\n' > "$MOCK_STATE/marker"
    exit 1
    ;;
  "lxc exec "*) exit 0 ;;
  "lxc delete --force "*)
    expected_name="$(cat "$MOCK_STATE/name")"
    [ "$command" = "lxc delete --force $expected_name" ] || exit 91
    rm -f "$MOCK_STATE/name" "$MOCK_STATE/marker"
    exit 0
    ;;
  *) printf 'unexpected mock ssh command: %s\n' "$command" >&2; exit 90 ;;
esac
SH
chmod +x "$MOCK_BIN/ssh"

run_launch_cleanup_case() {
  local name="$1" foreign="$2" launch_success="$3" swap_marker="$4"
  local state results key rc result
  state="$TMP/$name-state"
  results="$TMP/$name-results"
  mkdir -p "$state" "$results"
  key="$TMP/$name.key"
  printf 'fixture-key\n' > "$key"
  chmod 600 "$key"
  rc=0
  PATH="$MOCK_BIN:$PATH" MOCK_STATE="$state" MOCK_FOREIGN_MARKER="$foreign" \
    MOCK_LAUNCH_SUCCESS="$launch_success" MOCK_SWAP_MARKER_ON_STAGE="$swap_marker" \
    AIRLOCK_LIVE_SSH=fixture-host AIRLOCK_LIVE_OWNER=fixture-owner \
    AIRLOCK_LIVE_TSKEY_FILE="$key" AIRLOCK_LIVE_RESULT_DIR="$results" \
    AIRLOCK_LIVE_PUBLISH=none AIRLOCK_LIVE_ALLOW_DIRTY=1 \
    bash "$ROOT/live/verify.sh" >"$TMP/$name.out" 2>"$TMP/$name.err" || rc=$?
  result="$(find "$results" -maxdepth 1 -name '*.json' ! -name '*.inner.json' -print -quit)"
  if [ "$foreign" = 0 ] && [ "$rc" = 1 ] && [ ! -e "$state/name" ] \
      && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["stage"] == "creating" and r["cleanup_ok"] is True' "$result"; then
    ok "partial launch owned by this run is deleted"
  elif [ "$foreign" = 1 ] && [ "$launch_success" = 0 ] && [ "$rc" = 1 ] && [ -e "$state/name" ] \
      && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["stage"] == "creating" and r["cleanup_ok"] is None' "$result"; then
    ok "partial launch with a foreign marker is not deleted"
  elif [ "$launch_success" = 1 ] && [ "$swap_marker" = 1 ] && [ "$rc" = 1 ] && [ -e "$state/name" ] \
      && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["stage"] == "delivering" and r["cleanup_ok"] is False' "$result"; then
    ok "successful launch whose marker changed before cleanup is not deleted"
  else
    bad "$name launch cleanup boundary (rc=$rc result=$result state=$(ls -1 "$state" 2>/dev/null))"
  fi
}

run_launch_cleanup_case owned-launch 0 0 0
run_launch_cleanup_case foreign-launch 1 0 0
run_launch_cleanup_case swapped-after-launch 0 1 1

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
