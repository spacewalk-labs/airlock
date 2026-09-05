#!/usr/bin/env bash
# PostToolUse(Write|Edit) — ts/tsx 를 고친 직후 타입체크 결과를 에이전트에게 되돌려준다.
#
# 왜 PostToolUse 인가: PreToolUse 는 "편집 전" 상태를 검사하므로 여기에 차단을 걸면
# 타입 에러를 고치려는 편집까지 막히는 데드락이 된다. 편집은 통과시키고 결과를 알려준 뒤,
# 진짜 게이트는 턴 종료(Stop 훅, verify-turn.sh)에서 잠근다.
#
# exit 2 = 에러 내용을 stderr 로 에이전트에 전달(계속 고치게 만든다).
# 침묵 금지: 전제(jq·tsc) 부재는 통과시키되 stderr 로 반드시 알린다.

set -uo pipefail

if ! command -v jq >/dev/null 2>&1; then
  echo "⚠️ hook typecheck.sh: jq 없음 → 타입체크 피드백 비활성 (설치: apt install jq)" >&2
  exit 1   # non-blocking error: transcript 에 훅 오류로 남는다(조용히 성공 아님)
fi

INPUT=$(cat)
FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')

case "$FILE" in
  *.ts|*.tsx) ;;
  *) exit 0 ;;
esac

# 스캐폴딩 전이면 검사 대상 자체가 없다(정상).
[ -f package.json ] || exit 0

if [ ! -d node_modules ]; then
  echo "⚠️ hook typecheck.sh: node_modules 없음 → 타입체크 생략. \`pnpm install\` 후 유효." >&2
  exit 1
fi

if [ ! -x node_modules/.bin/tsc ]; then
  echo "⚠️ hook typecheck.sh: typescript 미설치 → 타입체크 생략 (pnpm add -D typescript)" >&2
  exit 1
fi

OUT=$(node_modules/.bin/tsc --noEmit --pretty false 2>&1) && exit 0

{
  echo "❌ TypeScript 타입 에러 — 턴을 끝내기 전에 고쳐야 합니다 (Stop 훅이 잠급니다):"
  printf '%s\n' "$OUT" | head -30
} >&2
exit 2
