#!/usr/bin/env bash
# PreToolUse(Bash) — 시크릿이 커밋에 들어가기 "전에" 막는다.
#
# 왜 PreToolUse 인가: 구버전은 PostToolUse 라 `git add` 가 이미 실행된 뒤에 검사했다.
# 여기서는 git add/commit 명령이 실행되기 전에 판정해 차단한다.
#
# 2층 검사:
#   ① 파일명 규칙 — .env* · *.pem/key/p12/pfx · id_rsa/id_ed25519 · credentials.json
#   ② 내용 스캔 — gitleaks (regex+entropy). 하드코딩된 토큰은 파일명으로 절대 안 잡힌다.
#      AI 도구가 co-author 인 커밋의 시크릿 유출률은 GitHub 평균의 약 2배라, 내용 스캔이 필수 계층이다.
#
# 침묵 금지: gitleaks 가 없으면 통과가 아니라 ask 로 올려 사람이 알게 한다.

set -uo pipefail

emit() { # $1=decision $2=reason
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg d "$1" --arg r "$2" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":%s}}\n' \
      "$1" "$(printf '%s' "$2" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '"시크릿 검사 차단"')"
  fi
  exit 0
}

INPUT=$(cat)

if command -v jq >/dev/null 2>&1; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
else
  echo "⚠️ hook secret-scan.sh: jq 없음 → 명령 파싱 불가" >&2
  emit ask "시크릿 검사 훅 전제(jq) 누락 — 검사 없이 실행할지 확인 필요"
fi

# git add / git commit 이 아니면 관여하지 않는다(결정 안 함).
case "$COMMAND" in
  *"git add"*|*"git commit"*) ;;
  *) exit 0 ;;
esac

# ── ① 파일명 규칙 ──
# 후보 = 이미 staged + 수정된 tracked + 새 파일(ignored 제외)
#      + **명령줄에 직접 적힌 경로**.
# 마지막 항목이 없으면 `git add -f .env.local` 이 빠져나간다 — gitignored 라
# ls-files --others 에 안 잡히는데 -f 는 무시를 무력화하기 때문이다.
CMD_PATHS=$(printf '%s\n' "$COMMAND" | tr ' ' '\n' | grep -vE '^(git|add|commit|-.*|--.*)$' || true)
CANDIDATES=$( { git diff --cached --name-only 2>/dev/null; git diff --name-only 2>/dev/null; \
                git ls-files --others --exclude-standard 2>/dev/null; \
                printf '%s\n' "$CMD_PATHS"; } | sort -u )

BLOCKED=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ "$f" = ".env.example" ] && continue
  case "$f" in
    .env|.env.*)                        BLOCKED="$BLOCKED
  - $f (.env 파일)" ;;
    *.pem|*.key|*.p12|*.pfx)            BLOCKED="$BLOCKED
  - $f (키/인증서)" ;;
    *id_rsa*|*id_ed25519*)              BLOCKED="$BLOCKED
  - $f (SSH 개인키)" ;;
    credentials.json|*service*account*.json) BLOCKED="$BLOCKED
  - $f (자격증명 JSON)" ;;
  esac
done <<< "$CANDIDATES"

if [ -n "$BLOCKED" ]; then
  emit deny "시크릿 파일이 커밋 경로에 있습니다:$BLOCKED

.gitignore 에 추가하거나 \`git reset HEAD <파일>\` 로 제외한 뒤 다시 시도하세요.
키 목록만 공유하려면 .env.example 을 쓰세요."
fi

# ── ② 내용 스캔 (gitleaks) ──
if ! command -v gitleaks >/dev/null 2>&1; then
  echo "⚠️ hook secret-scan.sh: gitleaks 없음 → 내용 스캔 불가(파일명 검사만 수행됨)" >&2
  emit ask "gitleaks 미설치로 하드코딩 시크릿을 검사하지 못했습니다. 설치 권장:
  brew install gitleaks  /  또는 https://github.com/gitleaks/gitleaks/releases
검사 없이 커밋을 진행할까요?"
fi

# gitleaks v8.19+ 는 `git --staged`, 구버전은 `protect --staged` — 둘 다 지원한다.
if gitleaks git --help >/dev/null 2>&1; then
  SCAN=(gitleaks git --staged --no-banner --redact)
else
  SCAN=(gitleaks protect --staged --no-banner --redact)
fi

if ! LEAKS=$("${SCAN[@]}" 2>&1); then
  emit deny "gitleaks 가 하드코딩된 시크릿을 발견했습니다(값은 마스킹됨):
$(printf '%s' "$LEAKS" | head -25)

해당 값을 코드에서 제거하고 .env.local 로 옮긴 뒤 다시 커밋하세요.
오탐이면 .gitleaksignore 에 근거를 남기고 등록하세요."
fi

exit 0
