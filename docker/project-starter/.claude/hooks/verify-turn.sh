#!/usr/bin/env bash
# Stop — 턴을 끝내기 전 검증 게이트. "다 됐습니다" 를 말하기 전에 실제로 돌려본다.
#
# 이 훅이 존재하는 이유: AGENTS.md 의 "Done 의 정의" 는 요청이고, 지켜지는 보장은 훅뿐이다.
# 소스가 바뀐 턴에서만 동작한다(대화·조사만 한 턴은 통과).
#
# exit 2 = 턴 종료를 막고 stderr 를 에이전트에 전달 → 스스로 고치고 다시 끝내려 한다.
# 무한루프 방지: stop_hook_active 가 true 면(이미 이 훅 때문에 계속되는 중) 통과시킨다.

set -uo pipefail

INPUT=$(cat)

if command -v jq >/dev/null 2>&1; then
  ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')
  [ "$ACTIVE" = "true" ] && exit 0
else
  echo "⚠️ hook verify-turn.sh: jq 없음 → 루프 가드 불가로 검증 생략" >&2
  exit 1
fi

[ -f package.json ] || exit 0
[ -d node_modules ] || { echo "⚠️ hook verify-turn.sh: node_modules 없음 → 검증 생략" >&2; exit 1; }

# 이 턴에 소스가 바뀌었나 (tracked 변경 + 새 파일)
CHANGED=$( { git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null; \
             git ls-files --others --exclude-standard 2>/dev/null; } \
           | grep -E '\.(ts|tsx|js|jsx|mjs|cjs|css)$' | head -1 )
[ -z "$CHANGED" ] && exit 0

FAIL=""
run() { # $1=라벨 $2..=명령
  local label="$1"; shift
  local out
  if ! out=$("$@" 2>&1); then
    FAIL="$FAIL

── $label 실패 ──
$(printf '%s' "$out" | tail -25)"
  fi
}

run "typecheck (tsc --noEmit)" pnpm -s typecheck
run "lint (eslint)"            pnpm -s lint
run "test (vitest)"            pnpm -s test -- --run

if [ -n "$FAIL" ]; then
  {
    echo "❌ 검증 게이트: 소스를 바꿨는데 검사가 통과하지 않았습니다. 턴을 끝낼 수 없습니다."
    echo "   (E2E 는 여기서 안 돌립니다 — 필요하면 pnpm test:e2e 를 직접 실행하세요.)"
    printf '%s\n' "$FAIL"
  } >&2
  exit 2
fi

exit 0
