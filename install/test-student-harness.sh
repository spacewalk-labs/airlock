#!/usr/bin/env bash
# test-student-harness.sh — the GUI installer's pinned, user-home harness contract.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
INSTALL="$HERE/install-student-harness.py"
HARNESS="$ROOT/docker/student-harness"
STARTER="$ROOT/docker/project-starter"
SCAN="$HERE/check-internal-leaks.sh"
pass=0 fail=0
ok() { printf 'ok   student-harness: %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL student-harness: %s\n' "$1"; fail=$((fail+1)); }

scratch="$(mktemp -d)" || exit 2
trap 'rm -rf "$scratch"' EXIT

paths="$(find "$HARNESS" -type d -name __pycache__ -prune -o \
  \( -type f -o -type l \) -printf . | wc -c)"
skills="$(find "$HARNESS/skills" -mindepth 1 -maxdepth 1 -type d \
  -exec test -f '{}/SKILL.md' ';' -printf . | wc -c)"
hooks="$(find "$HARNESS/hooks" -type f -printf . | wc -c)"
read -r deny ask < <(python3 - "$HARNESS/settings.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
print(len(d["permissions"]["deny"]), len(d["permissions"]["ask"]))
PY
)
if [ "$paths/$skills/$hooks/$deny/$ask" = 64/29/3/4/14 ]; then
  ok "projection is exactly 64 files, 29 skills, 3 hooks, deny4 and ask14"
else
  bad "projection counts drifted: $paths/$skills/$hooks/$deny/$ask"
fi

if bash "$SCAN" --subset "$HARNESS" >/dev/null \
  && bash "$SCAN" --subset "$STARTER" >/dev/null \
  && python3 "$INSTALL" --check >/dev/null; then
  ok "the exact harness and starter projections pass the release leak rules"
else
  bad "a projected input contains an internal identifier"
fi

if python3 - "$INSTALL" "$ROOT/docker/student-harness-provenance.json" "$scratch" <<'PY'
import json, pathlib, subprocess, sys

installer, source, scratch = map(pathlib.Path, sys.argv[1:])
base = json.loads(source.read_text(encoding="utf-8"))
mutations = (
    ("harness", "source_revision", "0" * 40),
    ("harness", "source_archive_sha256", "f" * 64),
    ("harness", "source_archive_bytes", 1),
    ("starter", "source_revision", "0" * 40),
)
for index, (section, key, value) in enumerate(mutations):
    candidate = json.loads(json.dumps(base))
    candidate[section][key] = value
    path = scratch / f"mutated-provenance-{index}.json"
    path.write_text(json.dumps(candidate), encoding="utf-8")
    result = subprocess.run(
        [sys.executable, str(installer), "--check", "--provenance", str(path)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    if result.returncode == 0:
        raise SystemExit(f"accepted mutated provenance field: {section}.{key}")
PY
then
  ok "course archive and starter revision pins each have a negative control"
else
  bad "a source/archive provenance pin can change without failing validation"
fi

if ! grep -q '\$home/code' "$ROOT/docker/gui-provisioner.sh" \
  && grep -q 'workspace_repo="\$workspace/airlock"' "$ROOT/docker/gui-provisioner.sh" \
  && grep -q 'NSHomeDirectory() + "/workspace/airlock"' \
       "$ROOT/mac/Sources/AirlockLauncher/LauncherModel.swift"; then
  ok "Ubuntu and macOS use the approved Airlock workspace and no legacy code directory"
else
  bad "a platform path still creates the legacy layout or misses the approved workspace"
fi

tools="$HERE/install-agent-tools.sh"
tool_contract=1
bash -n "$tools" || tool_contract=0
for token in git jq gitleaks unzip '@anthropic-ai/claude-code' '@openai/codex' pnpm opencode; do
  grep -Fq "$token" "$tools" || tool_contract=0
done
for caller in "$ROOT/docker/gui-provisioner.sh" "$ROOT/docker/orbstack-machine-setup.sh"; do
  grep -Fq 'install-agent-tools.sh' "$caller" || tool_contract=0
  grep -Fq 'install-student-harness.py' "$caller" || tool_contract=0
done
if [ "$tool_contract" = 1 ]; then
  ok "both platform paths statically wire install and execute-checks for every harness prerequisite"
else
  bad "an agent CLI, prerequisite tool or platform integration call is absent"
fi

exact_home="$scratch/exact-home"
mkdir -p "$exact_home"
if python3 "$INSTALL" --home "$exact_home" --fqdn exact-box.example.ts.net \
    >/dev/null 2>&1 \
  && cmp -s "$HARNESS/settings.json" "$exact_home/.claude/settings.json" \
  && python3 - "$HARNESS" "$STARTER" "$exact_home" \
       "$ROOT/docker/student-harness-provenance.json" <<'PY'
import json, os, pathlib, sys

harness, starter, home, provenance_path = map(pathlib.Path, sys.argv[1:])
provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
def file_bytes(root):
    return {
        path.relative_to(root): path.read_bytes()
        for path in root.rglob("*")
        if path.is_file() and "__pycache__" not in path.parts
    }

assert file_bytes(harness / "skills") == file_bytes(home / ".claude/skills")
assert file_bytes(harness / "hooks") == file_bytes(home / ".claude/hooks")
for relative in provenance["harness"]["executable_paths"]:
    assert os.access(home / ".claude" / relative, os.X_OK)
for relative in provenance["starter"]["executable_paths"]:
    assert os.access(home / "workspace/templates" / relative, os.X_OK)
installed = (home / ".claude/CLAUDE.md").read_text(encoding="utf-8")
source = (harness / "CLAUDE.md").read_text(encoding="utf-8")
prefix = (
    "# 외부 접속 개발서버\n\n"
    "이 박스는 외부 접속 개발서버입니다. 문서·개발서버·링크는 "
    "`exact-box.example.ts.net` 주소로 전달합니다.\n\n"
)
assert installed == prefix + source
for source_path in starter.rglob("*"):
    if not source_path.is_file():
        continue
    relative = source_path.relative_to(starter)
    assert source_path.read_bytes() == (home / "workspace/templates" / relative).read_bytes()
PY
then
  ok "clean-home install is byte-equal for settings, full skills/hooks, instructions and starter files"
else
  bad "clean-home install omitted or changed shipped harness/starter bytes"
fi
cp -a "$HARNESS" "$scratch/leaky"
printf '%s\n' "s""wk-planted" > "$scratch/leaky/planted.txt"
if ! bash "$SCAN" --subset "$scratch/leaky" >/dev/null 2>&1; then
  ok "leak measurement has a positive control"
else
  bad "leak measurement missed its planted identifier"
fi

if [ ! -f "$INSTALL" ]; then
  bad "installer is absent"
  printf '\npassed=%d failed=%d\n' "$pass" "$fail"
  exit 1
fi

make_tailscale() {
  local bin="$1" fqdn="$2"
  mkdir -p "$bin"
  cat > "$bin/tailscale" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = status ] && [ "\${2:-}" = --json ]; then
  printf '%s\n' '{"BackendState":"Running","Self":{"DNSName":"$fqdn."}}'
  exit 0
fi
exit 1
EOF
  chmod +x "$bin/tailscale"
}

home="$scratch/home"
mkdir -p "$home/.claude/skills/personal" "$home/.claude/hooks" \
  "$home/.codex" "$home/.agents/skills" "$home/workspace/templates"
printf 'old claude\n' > "$home/.claude/CLAUDE.md"
printf 'old settings\n' > "$home/.claude/settings.json"
printf 'old agents\n' > "$home/.codex/AGENTS.md"
printf 'personal\n' > "$home/.claude/skills/personal/SKILL.md"
printf 'personal hook\n' > "$home/.claude/hooks/personal.sh"
printf 'old codex skill\n' > "$home/.agents/skills/old.txt"
printf 'old starter\n' > "$home/workspace/templates/old.txt"
make_tailscale "$scratch/bin" "new-airlock.example.ts.net"

if PATH="$scratch/bin:$PATH" python3 "$INSTALL" --home "$home" \
    >"$scratch/install.out" 2>"$scratch/install.err"; then
  ok "installs into a populated home"
else
  bad "install failed: $(tail -1 "$scratch/install.err")"
fi

if head -4 "$home/.claude/CLAUDE.md" | grep -q 'new-airlock.example.ts.net' \
  && [ "$(grep -c '^# 외부 접속 개발서버$' "$home/.claude/CLAUDE.md")" = 1 ]; then
  ok "canonical instructions begin with the target box FQDN once"
else
  bad "target FQDN preamble is absent, misplaced or duplicated"
fi
if [ -L "$home/.codex/AGENTS.md" ] \
  && [ "$(readlink "$home/.codex/AGENTS.md")" = ../.claude/CLAUDE.md ] \
  && [ -L "$home/.agents/skills" ] \
  && [ "$(readlink "$home/.agents/skills")" = ../.claude/skills ]; then
  ok "AGENTS and Codex skills use the approved relative symlink directions"
else
  bad "one of the approved symlink directions is wrong"
fi
installed_skills="$(find "$home/.claude/skills" -mindepth 1 -maxdepth 1 -type d \
  -exec test -f '{}/SKILL.md' ';' -printf . | wc -c)"
installed_hooks="$(find "$home/.claude/hooks" -type f -printf . | wc -c)"
if [ "$installed_skills" = 30 ] && [ "$installed_hooks" = 4 ] \
  && [ -f "$home/.claude/skills/personal/SKILL.md" ] \
  && [ -f "$home/.claude/hooks/personal.sh" ]; then
  ok "29 shipped entries install without deleting personal skills or hooks"
else
  bad "shipped or personal harness content is missing: skills=$installed_skills hooks=$installed_hooks"
fi
if [ -d "$home/workspace/templates/.git" ] \
  && git -C "$home/workspace/templates" rev-parse --verify HEAD >/dev/null 2>&1 \
  && [ -x "$home/workspace/templates/setup.sh" ] \
  && [ -x "$home/.claude/hooks/secret-guard.sh" ] \
  && [ ! -e "$home/code" ]; then
  ok "starter is a runnable pinned local clone and no legacy code directory appears"
else
  bad "starter clone or no-code layout contract failed"
fi
backup="$(find "$home/.local/state/airlock/harness-backups" -mindepth 1 -maxdepth 1 -type d | head -1)"
if [ -n "$backup" ] \
  && grep -q 'old claude' "$backup/.claude/CLAUDE.md" \
  && grep -q 'old starter' "$backup/workspace/templates/old.txt"; then
  ok "pre-existing live destinations were backed up before replacement"
else
  bad "backup does not contain the original files"
fi

if python3 - "$INSTALL" "$HARNESS" "$STARTER" "$ROOT/docker/student-harness-provenance.json" \
    "$scratch/rollback-home" <<'PY'
import importlib.util, os, pathlib, sys

installer, harness, starter, provenance, home = map(pathlib.Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("student_harness_installer", installer)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home.mkdir()
(home / ".claude").mkdir()
(home / ".claude/CLAUDE.md").write_text("original claude\n", encoding="utf-8")
(home / ".claude/settings.json").write_text("original settings\n", encoding="utf-8")
metadata = module.load_and_validate_inputs(harness, starter, provenance)
stage = module.prepare_stage(home, harness, starter, metadata, "rollback.example.ts.net")
backup, existed = module.make_backup(home)
real_replace = module.os.replace
failed_destination = home / ".claude/settings.json"

def fail_second_publish(source, destination):
    if pathlib.Path(destination) == failed_destination:
        raise OSError("planted publish failure")
    return real_replace(source, destination)

module.os.replace = fail_second_publish
try:
    try:
        module.publish(home, stage, backup, existed)
    except module.InstallError:
        pass
    else:
        raise SystemExit("planted publish failure was accepted")
finally:
    module.os.replace = real_replace

assert (home / ".claude/CLAUDE.md").read_text() == "original claude\n"
assert (home / ".claude/settings.json").read_text() == "original settings\n"
PY
then
  ok "a publish failure restores the destination whose replacement failed"
else
  bad "publish rollback lost a destination at the failing replacement"
fi

fallback="$scratch/fallback-home"
mkdir -p "$fallback"
if python3 "$INSTALL" --home "$fallback" --fqdn unavailable >/dev/null 2>&1 \
  && head -4 "$fallback/.claude/CLAUDE.md" \
       | grep -q '<이 박스의 tailnet 호스트>.ts.net'; then
  ok "missing Tailscale identity produces the literal generic placeholder"
else
  bad "missing Tailscale identity did not produce the safe fallback"
fi

blocked="$scratch/blocked-home"
mkdir -p "$blocked/.claude" "$blocked/.local/state/airlock"
printf 'must survive\n' > "$blocked/.claude/CLAUDE.md"
before="$(sha256sum "$blocked/.claude/CLAUDE.md" | awk '{print $1}')"
printf 'not a directory\n' > "$blocked/.local/state/airlock/harness-backups"
if ! python3 "$INSTALL" --home "$blocked" >/dev/null 2>&1 \
  && [ "$(sha256sum "$blocked/.claude/CLAUDE.md" | awk '{print $1}')" = "$before" ]; then
  ok "backup failure stops before changing a live destination"
else
  bad "a live destination changed after backup failed"
fi

escape="$scratch/escape-home"; outside="$scratch/outside"
mkdir -p "$escape" "$outside"
ln -s "$outside" "$escape/.claude"
if ! python3 "$INSTALL" --home "$escape" >/dev/null 2>&1 \
  && [ -z "$(find "$outside" -mindepth 1 -print -quit)" ]; then
  ok "a symlinked destination parent is refused without an external write"
else
  bad "a symlinked destination parent escaped the selected home"
fi

printf '\npassed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
