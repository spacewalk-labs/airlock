#!/usr/bin/env bash
# Canonical contract-index and digest-only evidence producer tests. No live mutation.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
ok()  { echo "ok   trust-evidence: $1"; pass=$((pass+1)); }
bad() { echo "FAIL trust-evidence: $1"; fail=$((fail+1)); }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

if python3 - "$ROOT" <<'PY'
import importlib.machinery
import importlib.util
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

def load(path, name):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def schema(name):
    path = root / "schemas/trust" / name
    raw = path.read_bytes()
    value = json.loads(raw)
    expected = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    assert raw == expected, f"{name} is not canonical JSON"
    return value

config = load(root / "bin/airlock-config", "airlock_config_schema_test")
ledger = load(root / "bin/airlock-ledger", "airlock_ledger_schema_test")
evidence = load(root / "bin/airlock-trust-evidence", "airlock_trust_evidence_regex_test")
config_schema = schema("config-v2.json")
capability_schema = schema("capability-v1.json")
ledger_schema = schema("ledger-v5.json")

assert evidence.SUMMARY_RE.fullmatch("passed=281 failed=0")
assert evidence.SUMMARY_RE.fullmatch("passed=٢٨١ failed=0") is None
assert evidence.FULL_SHA_RE.fullmatch("a" * 40)
assert evidence.FULL_SHA_RE.fullmatch("a" * 40 + "\n") is None

allowed_skip = evidence.ALLOWED_SUITE_SKIPS["builtin-capability-migration"][0]
assert f'skip "{allowed_skip.removeprefix("SKIP ")}"' in (
    root / "install/test-builtin-migration.sh"
).read_text()
assert evidence.suite_summary(
    "builtin-capability-migration", 181, 0, f"{allowed_skip}\n---\npassed=180 failed=0\n"
) == (180, 1)
for returncode, output in (
    (0, "---\npassed=180 failed=0\n"),
    (0, "SKIP E: unrelated environmental check\n---\npassed=180 failed=0\n"),
    (0, f"{allowed_skip}\n---\npassed=181 failed=0\n"),
    (0, f"{allowed_skip}\n{allowed_skip}\n---\npassed=179 failed=0\n"),
    (0, f"{allowed_skip}\nSKIP E: unrelated environmental check\n---\npassed=179 failed=0\n"),
    (1, "---\npassed=181 failed=0\n"),
    (0, "---\npassed=181 failed=1\n"),
):
    try:
        evidence.suite_summary("builtin-capability-migration", 181, returncode, output)
    except evidence.EvidenceError:
        pass
    else:
        raise AssertionError(f"invalid suite summary was accepted: {output!r}")

assert config_schema["scope"] == "public-contract-index"
assert capability_schema["scope"] == "public-contract-index"
assert ledger_schema["scope"] == "public-contract-index"

assert config_schema["version"] == config.CONFIG_ABI_VERSION
assert config_schema["artifact_classes"] == list(config.ARTIFACT_CLASSES)
assert config_schema["manifest"]["closed_keys"] == list(config._MANIFEST_KEYS)
assert config_schema["manifest"]["config_keys"] == list(config._CONFIG_SCHEMA_KEYS)
assert config_schema["manifest"]["package_id_pattern"] == config.PACKAGE_ID_RE.pattern
assert config_schema["airlock_config"]["common_app_keys"] == sorted(config.COMMON_APP_KEYS)
assert config_schema["airlock_config"]["closed_sections"] == {
    key: sorted(value) for key, value in sorted(config.CLOSED_SECTIONS.items())
}

assert capability_schema["version"] == config.CAPABILITY_SCHEMA_VERSION
assert capability_schema["bundle_certifications"] == list(config.BUNDLE_CERTIFICATIONS)
assert capability_schema["bundle_entitlements"] == {
    key: list(value) for key, value in sorted(config.BUNDLE_ENTITLEMENTS.items())
}
assert capability_schema["grantable_capabilities"] == sorted(config.GRANTABLE_CAPABILITIES)
assert capability_schema["elevated_capabilities"] == sorted(config.ELEVATED_CAPABILITIES)
assert capability_schema["surface_classifications"] == dict(sorted(config.SURFACE_CLASSIFICATIONS.items()))

assert ledger_schema["version"] == ledger.LEDGER_VERSION
assert ledger_schema["supported_versions"] == [1, 2, 3, 4, ledger.LEDGER_VERSION]
assert ledger_schema["artifact_classes"] == list(ledger.ARTIFACT_CLASSES)
assert ledger_schema["capabilities"] == list(ledger.CAPABILITIES)
assert ledger_schema["lifecycle_keys"] == list(ledger.LIFECYCLE_KEYS)
assert ledger_schema["audit_event_fields"] == list(ledger.AUDIT_EVENT_FIELDS)
assert set(ledger_schema["intent_record_fields"]) == set(ledger.INTENT_RECORD_FIELDS_V5)
assert set(ledger_schema["committed_record_fields"]) == set(ledger.COMMITTED_RECORD_FIELDS_V5)
assert ledger_schema["store_fields"] == list(ledger.STORE_FIELDS_V5)
PY
then
  ok "canonical contract-index bytes match selected runtime constants and v5 record shapes"
else
  bad "contract-index/runtime parity"
fi

# Exercise candidate binding and suite orchestration in a tiny committed checkout.
REPO="$TMP/repo"
mkdir -p "$REPO/bin" "$REPO/install" "$REPO/live" "$REPO/schemas/trust"
cp "$ROOT/bin/airlock-trust-evidence" "$REPO/bin/"
cp "$ROOT/bin/airlock-config" "$ROOT/bin/airlock-ledger" "$REPO/bin/"
cp "$ROOT/live/verdict.py" "$REPO/live/"
cp "$ROOT"/schemas/trust/*.json "$REPO/schemas/trust/"
chmod +x "$REPO/bin/airlock-trust-evidence"

make_fake_suite() {
  local path="$1" count="$2"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo --\n'
    printf 'echo "passed=%s failed=0"\n' "$count"
  } > "$path"
  chmod +x "$path"
}
make_fake_suite "$REPO/install/test-operator-surface.sh" 71
make_fake_suite "$REPO/install/test-builtin-migration.sh" 181
make_fake_suite "$REPO/install/test-ledger-system-unit.sh" 7
make_fake_suite "$REPO/install/test-live-verdict.sh" 39

git -C "$REPO" init -q
git -C "$REPO" config user.name test
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" add .
git -C "$REPO" commit -qm fixture
SHA="$(git -C "$REPO" rev-parse HEAD)"

schemas_a="$(python3 "$REPO/bin/airlock-trust-evidence" schemas)"
schemas_b="$(python3 "$REPO/bin/airlock-trust-evidence" schemas)"
if [ "$schemas_a" = "$schemas_b" ] && python3 -c '
import json,sys
d=json.load(sys.stdin)
assert len(d["candidate_sha"]) == 40
assert sorted(d["schemas"]) == ["capability_schema", "config_schema", "ledger_schema"]
assert all(v["digest"].startswith("sha256:") for v in d["schemas"].values())
assert sorted(d["runtime_pins"]) == ["config_and_capability_runtime", "ledger_runtime"]
assert all(v["digest"].startswith("sha256:") for v in d["runtime_pins"].values())
' <<<"$schemas_a"; then
  ok "schema bundle deterministically pins three indexes and both runtime implementations"
else
  bad "schema bundle determinism"
fi

suite_a="$(python3 "$REPO/bin/airlock-trust-evidence" suite)"
suite_b="$(python3 "$REPO/bin/airlock-trust-evidence" suite)"
if [ "$suite_a" = "$suite_b" ] && SHA="$SHA" python3 -c '
import json,os,sys
d=json.load(sys.stdin)
assert d["candidate_sha"] == os.environ["SHA"]
assert d["result"] == "passed"
assert [row["passed"] for row in d["suites"]] == [71, 181, 7, 39]
assert [row["skipped"] for row in d["suites"]] == [0, 0, 0, 0]
' <<<"$suite_a"; then
  ok "offline suite result is deterministic and candidate-bound"
else
  bad "offline suite candidate binding"
fi

RESULT="$TMP/live.json"
SHA="$SHA" python3 - "$RESULT" <<'PY'
import json, os, sys
record = {
    "schema": 1,
    "run_id": "fixture-run",
    "commit": os.environ["SHA"],
    "stage": "ran",
    "cleanup_ok": True,
    "inner_rc": 0,
    # live/verdict.py fail-closes this outer/inner contract even when messages are off.
    "dev_monitor_messages_requested": False,
    "inner": {
        "dev_monitor_messages_requested": False,
        "commit": os.environ["SHA"],
        "install_rc": 0,
        "smoke_rc": 0,
        "units_late": [{"id": "airlock-example.service", "type": "simple",
                        "active": "active", "sub": "running", "exec_status": "0"}],
        "smoke_lines": ["[example smoke] backend=200 allowed=200 denied=403 anonymous=403"],
        "external_packages": ["example"],
        "acceptance": {"rc": 0, "passed": 25, "failed": 0},
    },
}
with open(sys.argv[1], "w") as fh:
    json.dump(record, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
PY
live_a="$(python3 "$REPO/bin/airlock-trust-evidence" live "$RESULT")"
live_b="$(python3 "$REPO/bin/airlock-trust-evidence" live "$RESULT")"
if [ "$live_a" = "$live_b" ] && SHA="$SHA" python3 -c '
import json,os,sys
d=json.load(sys.stdin)
assert d["candidate_sha"] == os.environ["SHA"]
assert d["verdict"] == 0 and d["acceptance"] == {"failed": 0, "passed": 25}
assert d["result_sha256"].startswith("sha256:")
' <<<"$live_a"; then
  ok "live projection is deterministic, redacted, and bound to raw result bytes"
else
  bad "live result projection"
fi

python3 - "$RESULT" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    record = json.load(fh)
record["commit"] = "0" * 40
with open(sys.argv[1], "w") as fh:
    json.dump(record, fh)
PY
if python3 "$REPO/bin/airlock-trust-evidence" live "$RESULT" >"$TMP/wrong.out" 2>"$TMP/wrong.err"; then
  bad "wrong-candidate live result was accepted"
elif grep -Fq "commit must equal current candidate" "$TMP/wrong.err"; then
  ok "wrong-candidate live result is fail-closed"
else
  bad "wrong-candidate diagnostic"
fi

printf '# dirty\n' >> "$REPO/install/test-live-verdict.sh"
if python3 "$REPO/bin/airlock-trust-evidence" suite >"$TMP/dirty.out" 2>"$TMP/dirty.err"; then
  bad "dirty candidate was accepted"
elif grep -Fq "working tree is dirty" "$TMP/dirty.err"; then
  ok "dirty candidate is fail-closed before suite execution"
else
  bad "dirty-candidate diagnostic"
fi

# Reproduce a status/read race: the first clean status mutates a tracked schema
# after returning its output. Evidence must fail instead of binding mutable bytes
# to the pre-mutation candidate SHA.
git -C "$REPO" checkout -- install/test-live-verdict.sh
GIT_WRAP="$TMP/git-wrap"
mkdir -p "$GIT_WRAP"
REAL_GIT="$(command -v git)"
{
  printf '#!/usr/bin/env bash\n'
  printf 'REAL_GIT=%q\n' "$REAL_GIT"
  cat <<'SH'
"$REAL_GIT" "$@"
rc=$?
if [ "$rc" = 0 ] && [ "${1-}" = "-C" ] && [ "${3-}" = "status" ] && [ ! -e "$2/.race-mutated" ]; then
  printf '\n' >> "$2/schemas/trust/capability-v1.json"
  : > "$2/.race-mutated"
fi
exit "$rc"
SH
} > "$GIT_WRAP/git"
chmod +x "$GIT_WRAP/git"
if PATH="$GIT_WRAP:$PATH" python3 "$REPO/bin/airlock-trust-evidence" schemas >"$TMP/race.out" 2>"$TMP/race.err"; then
  bad "status/read race was accepted"
elif grep -Fq "working tree is dirty" "$TMP/race.err"; then
  ok "status/read race is fail-closed after committed-object reads"
else
  bad "status/read race diagnostic"
fi

echo "---"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
