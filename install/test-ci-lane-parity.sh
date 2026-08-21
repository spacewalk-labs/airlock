#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash install/test-ci-lane-parity.sh [--baseline REV]

Compare the run-step multiset at the branch point with the working-tree ci.yml.
By default the baseline is: git merge-base origin/main HEAD
EOF
}

baseline_override=""
while (($#)); do
  case "$1" in
    --baseline)
      (($# >= 2)) || { echo "FAIL --baseline requires a revision" >&2; exit 2; }
      baseline_override=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "FAIL unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
workflow=.github/workflows/ci.yml

if [[ -n "$baseline_override" ]]; then
  baseline=$(git rev-parse --verify "${baseline_override}^{commit}")
else
  git rev-parse --verify 'origin/main^{commit}' >/dev/null
  baseline=$(git merge-base origin/main HEAD)
fi

git cat-file -e "$baseline:$workflow"
[[ -s "$workflow" ]] || { echo "FAIL current working-tree $workflow is missing or empty" >&2; exit 2; }

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
baseline_file=$tmpdir/baseline.yml
negative_file=$tmpdir/negative.yml
helper=$tmpdir/parity.py
negative_log=$tmpdir/negative.log

git show "$baseline:$workflow" >"$baseline_file"

cat >"$helper" <<'PY'
from __future__ import annotations

import collections
import hashlib
import pathlib
import re
import sys
from dataclasses import dataclass

EXPECTED_RUNS_ON = "${{ endsWith(github.repository, '/airlock-work') && fromJSON('[\"self-hosted\",\"Linux\",\"X64\",\"shared-ci\"]') || 'ubuntu-latest' }}"
EXPECTED_BASELINE_RUNS = 39
JOB_KEY = re.compile(r"^    ([A-Za-z0-9_-]+):(?:[ ]*(.*))?$")
JOB_START = re.compile(r"^  ([A-Za-z0-9_-]+):[ ]*$")
STEP_START = re.compile(r"^      - (.*)$")
STEP_FIELD = re.compile(r"^        ([A-Za-z0-9_-]+):(?:[ ]?(.*))?$")
ALLOWED_JOB_KEYS = {"runs-on", "steps"}
ALLOWED_RUN_STEP_KEYS = {
    "name", "run", "env", "shell", "working-directory", "if",
    "continue-on-error", "timeout-minutes",
}
CONTEXT_KEYS = {
    "env", "shell", "working-directory", "if", "continue-on-error",
    "timeout-minutes",
}


class ParseError(RuntimeError):
    pass


@dataclass(frozen=True)
class RunStep:
    name: str
    run: str
    context: tuple[str, ...]
    job: str
    start: int
    end: int

    @property
    def key(self) -> tuple[str, str, tuple[str, ...]]:
        return (self.name, self.run, self.context)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def field_blocks(item: list[str], job: str) -> dict[str, tuple[str, int, int]]:
    fields: dict[str, tuple[str, int, int]] = {}
    first = STEP_START.match(item[0])
    if not first:
        raise ParseError(f"{job}: malformed step start")
    first_text = first.group(1)
    if ":" not in first_text:
        raise ParseError(f"{job}: step start must be key: value: {first_text!r}")
    first_key, first_value = first_text.split(":", 1)
    fields[first_key] = (first_value.lstrip(), 0, 1)

    starts: list[tuple[str, str, int]] = []
    for i, line in enumerate(item[1:], 1):
        match = STEP_FIELD.match(line.rstrip("\n"))
        if match:
            starts.append((match.group(1), match.group(2) or "", i))
    for pos, (key, value, start) in enumerate(starts):
        end = starts[pos + 1][2] if pos + 1 < len(starts) else len(item)
        if key in fields:
            raise ParseError(f"{job}: duplicate step key {key!r}")
        fields[key] = (value, start, end)
    return fields


def parse_run(item: list[str], info: tuple[str, int, int], job: str, name: str) -> str:
    value, start, end = info
    if value.startswith(">"):
        raise ParseError(f"{job}/{name}: folded run scalars are unsupported")
    if value in {"|", "|-", "|+"}:
        body: list[str] = []
        for line in item[start + 1:end]:
            if line.strip() and len(line) - len(line.lstrip(" ")) <= 8:
                break
            if line.strip() and not line.startswith("          "):
                raise ParseError(f"{job}/{name}: run body must be indented by 10 spaces")
            body.append(line[10:] if line.startswith("          ") else line)
        return "".join(body)
    if value.startswith("|"):
        raise ParseError(f"{job}/{name}: unsupported literal scalar header {value!r}")
    return value


def parse_context(item: list[str], fields: dict[str, tuple[str, int, int]]) -> tuple[str, ...]:
    context: list[str] = []
    for key in sorted(CONTEXT_KEYS):
        if key not in fields:
            continue
        value, start, end = fields[key]
        context.append(f"{key}:{value}")
        for line in item[start + 1:end]:
            context.append(line[8:].rstrip("\n") if line.startswith("        ") else line.rstrip("\n"))
    return tuple(context)


def parse(path: pathlib.Path) -> tuple[bytes, list[RunStep]]:
    data = path.read_bytes()
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ParseError(f"{path}: not UTF-8: {exc}") from exc
    lines = text.splitlines(keepends=True)
    jobs_line = next((i for i, line in enumerate(lines) if line.rstrip("\n") == "jobs:"), None)
    if jobs_line is None:
        raise ParseError(f"{path}: missing top-level jobs:")

    job_starts: list[tuple[str, int]] = []
    for i in range(jobs_line + 1, len(lines)):
        match = JOB_START.match(lines[i].rstrip("\n"))
        if match:
            job_starts.append((match.group(1), i))
    if not job_starts:
        raise ParseError(f"{path}: no jobs found")

    run_steps: list[RunStep] = []
    seen_jobs: set[str] = set()
    for index, (job, start) in enumerate(job_starts):
        if job in seen_jobs:
            raise ParseError(f"{path}: duplicate job id {job!r}")
        seen_jobs.add(job)
        end = job_starts[index + 1][1] if index + 1 < len(job_starts) else len(lines)
        block = lines[start + 1:end]

        job_fields: dict[str, str] = {}
        for line in block:
            match = JOB_KEY.match(line.rstrip("\n"))
            if match:
                key, value = match.group(1), match.group(2) or ""
                if key not in ALLOWED_JOB_KEYS:
                    raise ParseError(f"{path}: {job}: unsupported job key {key!r}")
                if key in job_fields:
                    raise ParseError(f"{path}: {job}: duplicate job key {key!r}")
                job_fields[key] = value
        if set(job_fields) != ALLOWED_JOB_KEYS:
            raise ParseError(f"{path}: {job}: expected exactly runs-on and steps job keys, got {sorted(job_fields)}")
        if job_fields["runs-on"] != EXPECTED_RUNS_ON:
            raise ParseError(f"{path}: {job}: runs-on fallback changed: {job_fields['runs-on']!r}")

        steps_index = next(i for i, line in enumerate(block) if line.rstrip("\n") == "    steps:")
        step_lines = block[steps_index + 1:]
        item_starts = [i for i, line in enumerate(step_lines) if STEP_START.match(line.rstrip("\n"))]
        checkout_count = 0
        for item_index, item_start in enumerate(item_starts):
            item_end = item_starts[item_index + 1] if item_index + 1 < len(item_starts) else len(step_lines)
            item = step_lines[item_start:item_end]
            fields = field_blocks(item, job)
            if fields.get("uses", ("", 0, 0))[0] == "actions/checkout@v4":
                checkout_count += 1
            if "run" not in fields:
                continue
            unknown = set(fields) - ALLOWED_RUN_STEP_KEYS
            if unknown:
                raise ParseError(f"{path}: {job}: unsupported run-step keys {sorted(unknown)}")
            if "name" not in fields or not fields["name"][0]:
                raise ParseError(f"{path}: {job}: every run step needs a nonempty name")
            name = fields["name"][0]
            run = parse_run(item, fields["run"], job, name)
            if not run.strip():
                raise ParseError(f"{path}: {job}/{name}: empty run body")
            absolute_start = start + 1 + steps_index + 1 + item_start
            absolute_end = start + 1 + steps_index + 1 + item_end
            run_steps.append(RunStep(name, run, parse_context(item, fields), job, absolute_start, absolute_end))
        if checkout_count != 1:
            raise ParseError(f"{path}: {job}: expected exactly one actions/checkout@v4, got {checkout_count}")
    return data, run_steps


def describe(counter: collections.Counter, prefix: str) -> None:
    for (name, run, context), count in sorted(counter.items(), key=lambda item: item[0][0]):
        digest = sha256((run + repr(context)).encode("utf-8"))[:12]
        print(f"{prefix} count={count} name={name!r} digest={digest}")


def compare(baseline_path: pathlib.Path, candidate_path: pathlib.Path) -> int:
    baseline_data, baseline_steps = parse(baseline_path)
    candidate_data, candidate_steps = parse(candidate_path)
    baseline_counter = collections.Counter(step.key for step in baseline_steps)
    candidate_counter = collections.Counter(step.key for step in candidate_steps)

    print(f"baseline_sha256={sha256(baseline_data)} baseline_runs={len(baseline_steps)}")
    print(f"candidate_sha256={sha256(candidate_data)} candidate_runs={len(candidate_steps)}")
    if len(baseline_steps) != EXPECTED_BASELINE_RUNS:
        raise ParseError(f"baseline positive control: expected {EXPECTED_BASELINE_RUNS} run steps, got {len(baseline_steps)}")
    if len({step.name for step in baseline_steps}) != EXPECTED_BASELINE_RUNS:
        raise ParseError("baseline positive control: run-step names are not unique")
    if len(baseline_counter) != EXPECTED_BASELINE_RUNS:
        raise ParseError("baseline positive control: command/context records are not unique")

    missing = baseline_counter - candidate_counter
    extra = candidate_counter - baseline_counter
    print(f"missing_total={sum(missing.values())} extra_total={sum(extra.values())}")
    describe(missing, "MISSING")
    describe(extra, "EXTRA")
    return 0 if not missing and not extra else 1


def mutate(source: pathlib.Path, target: pathlib.Path) -> None:
    data, steps = parse(source)
    if not steps:
        raise ParseError("negative control: candidate has no run step to remove")
    lines = data.decode("utf-8").splitlines(keepends=True)
    victim = steps[0]
    target.write_text("".join(lines[:victim.start] + lines[victim.end:]), encoding="utf-8")
    print(f"negative_removed={victim.name!r}")


def main() -> int:
    if len(sys.argv) != 4 or sys.argv[1] not in {"compare", "mutate"}:
        print("internal usage: parity.py compare BASELINE CANDIDATE | mutate SOURCE TARGET", file=sys.stderr)
        return 2
    try:
        if sys.argv[1] == "compare":
            return compare(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
        mutate(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
        return 0
    except ParseError as exc:
        print(f"FAIL {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
PY

echo "baseline_revision=$baseline"
python3 "$helper" compare "$baseline_file" "$workflow"

python3 "$helper" mutate "$workflow" "$negative_file"
set +e
python3 "$helper" compare "$baseline_file" "$negative_file" >"$negative_log" 2>&1
negative_rc=$?
set -e
if [[ $negative_rc -ne 1 ]]; then
  cat "$negative_log" >&2
  echo "FAIL negative control expected comparator exit 1, got $negative_rc" >&2
  exit 1
fi
if ! grep -Fxq 'missing_total=1 extra_total=0' "$negative_log"; then
  cat "$negative_log" >&2
  echo "FAIL negative control did not report exactly one missing command" >&2
  exit 1
fi

echo "negative_control=PASS comparator_exit=$negative_rc missing=1 extra=0"
echo "PASS ci lane command multiset matches branch-point baseline"
