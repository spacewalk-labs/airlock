#!/bin/bash
set -euo pipefail

# 프로젝트 초기 설정 스크립트
# GitHub "Use this template"으로 복제한 후 실행
# 사용법: ./setup.sh

echo ""
echo "=========================================="
echo "  프로젝트 초기 설정"
echo "=========================================="
echo ""

# ─── 1. 프로젝트 정보 입력 ───

read -rp "프로젝트 이름 (예: my-awesome-app): " PROJECT_NAME
if [[ -z "$PROJECT_NAME" ]]; then
  echo "❌ 프로젝트 이름은 필수입니다."
  exit 1
fi

read -rp "프로젝트 설명: " PROJECT_DESCRIPTION
PROJECT_DESCRIPTION="${PROJECT_DESCRIPTION:-$PROJECT_NAME 프로젝트}"

echo ""
echo "─── 설정 확인 ───"
echo "  프로젝트 이름: $PROJECT_NAME"
echo "  설명: $PROJECT_DESCRIPTION"
echo ""
read -rp "이 설정으로 진행하시겠습니까? (Y/n): " CONFIRM
if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
  echo "설정이 취소되었습니다."
  exit 0
fi

echo ""
echo "🔧 설정을 적용합니다..."
echo ""

# ─── 1.5 템플릿 레포 remote 확인 ───

ORIGIN_URL=$(git remote get-url origin 2>/dev/null || echo "")
if [[ "$ORIGIN_URL" == *"airlock-project-starter"* ]]; then
  echo "⚠️  origin이 템플릿 레포(airlock-project-starter)를 가리키고 있습니다."
  echo "   clone이 아닌 'Use this template'으로 새 레포를 만들어야 합니다."
  echo ""
  read -rp "remote origin을 제거하시겠습니까? (Y/n): " REMOVE_REMOTE
  if [[ ! "$REMOVE_REMOTE" =~ ^[Nn]$ ]]; then
    git remote remove origin
    echo "  ✅ origin 제거 완료. 새 remote를 설정하세요:"
    echo "     git remote add origin https://github.com/<your-github-owner>/$PROJECT_NAME.git"
  else
    echo "  ⚠️  주의: 이 상태로 push하면 템플릿 레포가 수정됩니다."
  fi
  echo ""
fi

# ─── 1.7 전제 도구 점검 (조용히 넘기지 않는다) ───

echo "  🔍 전제 도구 점검"
MISSING=()
command -v pnpm     >/dev/null 2>&1 || MISSING+=("pnpm (npm install -g pnpm)")
command -v jq       >/dev/null 2>&1 || MISSING+=("jq — Claude Code 훅 전제 (apt install jq / brew install jq)")
command -v gitleaks >/dev/null 2>&1 || MISSING+=("gitleaks — 시크릿 커밋 차단 훅 전제 (brew install gitleaks)")
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "  ⚠️  다음 도구가 없습니다 — 없으면 해당 게이트가 동작하지 않습니다:"
  for m in "${MISSING[@]}"; do echo "       • $m"; done
  echo "     (훅은 전제 부재를 조용히 통과시키지 않고 사람에게 확인을 요청합니다.)"
else
  echo "     ✅ pnpm · jq · gitleaks 모두 확인"
fi

# ─── 2. .template → 실제 파일 (sed 치환) ───
#
# AGENTS.md 가 정본이고 CLAUDE.md 는 `@AGENTS.md` 한 줄이다.
# Codex·Cursor·Copilot 도 AGENTS.md 를 네이티브로 읽으므로 한 파일이 전 툴에 닿는다.

for template in AGENTS.md.template CLAUDE.md.template README.md.template .gitignore.template; do
  if [ -f "$template" ]; then
    TARGET="${template%.template}"
    echo "  📄 $template → $TARGET"
    sed -e "s|{{PROJECT_NAME}}|$PROJECT_NAME|g" \
        -e "s|{{PROJECT_DESCRIPTION}}|$PROJECT_DESCRIPTION|g" \
        "$template" > "$TARGET"
    rm "$template"
  fi
done

# ─── 2.5 템플릿 라이선스 제거 ───
#
# "Use this template" 은 파일을 복사하므로 템플릿의 MIT LICENSE 도 따라온다.
# 그대로 두면 **비공개 프로젝트가 MIT 라이선스를 달고 시작**한다(오공개 위험).
# → 제거하고, 공개할 프로젝트면 사람이 명시적으로 다시 고르게 한다.

if [ -f LICENSE ] && grep -q 'MIT License' LICENSE && grep -q 'Copyright (c) 2026 Airlock Project' LICENSE; then
  rm -f LICENSE
  echo "  🗑️  템플릿의 MIT LICENSE 제거 — 이 프로젝트는 기본 비공개(proprietary)"
  echo "       공개할 프로젝트라면 라이선스를 직접 추가하세요."
fi

# ─── 3. .env.local 생성 ───

if [ -f ".env.example" ] && [ ! -f ".env.local" ]; then
  echo "  📄 .env.example → .env.local 복사"
  cp .env.example .env.local
fi

# ─── 4. 실행 권한 부여 ───

echo "  🔑 hooks 실행 권한 부여"
chmod +x .claude/hooks/*.sh 2>/dev/null || true

# ─── 5. Next.js 스캐폴딩 (선택) ───

SCAFFOLDED=false
echo ""
read -rp "Next.js 프로젝트를 생성하시겠습니까? (y/N): " SCAFFOLD

if [[ "$SCAFFOLD" =~ ^[Yy]$ ]]; then
  if ! command -v pnpm &>/dev/null; then
    echo "❌ pnpm이 없어 스캐폴딩을 건너뜁니다. 'npm install -g pnpm' 후 재시도하세요."
  else
    echo ""
    echo "📦 Next.js 프로젝트 생성 중..."

    # create-next-app은 기존 파일이 있으면 거부하므로 임시 이동.
    #
    # ⚠️ CLAUDE.md / AGENTS.md 는 그냥 복원하지 않는다 —
    #    create-next-app 이 AGENTS.md(번들 docs 를 읽으라는 지시) + CLAUDE.md(@AGENTS.md) 를
    #    직접 생성한다. 우리 것으로 덮어씌우면 그 지시가 사라져,
    #    에이전트가 설치된 버전이 아니라 낡은 학습데이터로 Next API 를 쓴다.
    #    → 아래에서 마커 밖에 우리 규칙만 append 하는 방식으로 병합한다.
    TMPDIR_BACKUP=$(mktemp -d)
    BACKUP_ITEMS=(.claude .editorconfig .env.example .env.local .github README.md .gitignore setup.sh templates)
    for item in "${BACKUP_ITEMS[@]}"; do
      [ -e "$item" ] && mv "$item" "$TMPDIR_BACKUP/"
    done

    [ -f AGENTS.md ] && mv AGENTS.md "$TMPDIR_BACKUP/AGENTS.md.ours"
    rm -f CLAUDE.md

    # Next 16: Turbopack이 dev/build 기본. --yes로 비대화형 보장.
    # AGENTS.md·CLAUDE.md 자동 생성이 기본값이다(끄려면 --no-agents-md).
    #
    # --skip-install 이 중요하다: pnpm 10+ 는 승인되지 않은 빌드 스크립트(sharp 등)를
    # ERR_PNPM_IGNORED_BUILDS 로 **중단**시킨다. 스캐폴딩이 곧바로 install 을 하면
    # 여기서 죽으므로, 생성만 하고 → allowBuilds 를 적어준 뒤 → 우리가 install 한다.
    set +e
    pnpm create next-app . --typescript --tailwind --eslint --app --src-dir \
      --import-alias "@/*" --use-pnpm --skip-install --yes
    NEXT_RESULT=$?
    set -e

    # 원본 복원 (Next.js가 만든 README.md, .gitignore 덮어쓰기)
    for item in "${BACKUP_ITEMS[@]}"; do
      [ -e "$TMPDIR_BACKUP/$item" ] && mv -f "$TMPDIR_BACKUP/$item" .
    done

    if [ "$NEXT_RESULT" -ne 0 ]; then
      echo "⚠️  Next.js 생성 실패. 수동으로 실행하세요:"
      echo "  pnpm create next-app . --typescript --tailwind --eslint --app --src-dir --use-pnpm"
      [ -f "$TMPDIR_BACKUP/AGENTS.md.ours" ] && mv "$TMPDIR_BACKUP/AGENTS.md.ours" AGENTS.md
      [ -f AGENTS.md ] && echo "@AGENTS.md" > CLAUDE.md
    else
      SCAFFOLDED=true

      # ── AGENTS.md 병합 ──
      # Next 가 만든 마커 섹션(BEGIN/END:nextjs-agent-rules)은 그대로 두고,
      # 우리 규칙은 마커 밖에 붙인다 → 향후 Next 업데이트가 우리 규칙을 덮지 않는다.
      if [ -f "$TMPDIR_BACKUP/AGENTS.md.ours" ]; then
        if [ -f AGENTS.md ] && grep -q 'BEGIN:nextjs-agent-rules' AGENTS.md; then
          echo "  🔀 AGENTS.md 병합 (Next 마커 섹션 유지 + 프로젝트 규칙 append)"
          awk '/END:nextjs-agent-rules/{found=1; next} found' "$TMPDIR_BACKUP/AGENTS.md.ours" >> AGENTS.md
        else
          echo "  📄 AGENTS.md — Next 생성분이 없어 우리 것을 사용"
          mv "$TMPDIR_BACKUP/AGENTS.md.ours" AGENTS.md
        fi
      fi
      # CLAUDE.md 는 @AGENTS.md 한 줄 (Next 도 같은 방식으로 만든다)
      if [ ! -f CLAUDE.md ] || ! grep -q '@AGENTS.md' CLAUDE.md; then
        echo "@AGENTS.md" > CLAUDE.md
      fi

      # ── 빌드 스크립트 승인 (pnpm 10+) ──
      # sharp = Next 이미지 최적화, unrs-resolver = eslint 리졸버. 둘 다 정상 의존성이라 허용한다.
      # 승인을 비워두면 install 자체가 ERR_PNPM_IGNORED_BUILDS 로 실패한다.
      echo "  🔧 pnpm 빌드 스크립트 승인 (sharp · unrs-resolver)"
      python3 - <<'PYEOF'
import re, pathlib
p = pathlib.Path('pnpm-workspace.yaml')
allow = "allowBuilds:\n  sharp: true\n  unrs-resolver: true\n"
if p.exists():
    s = p.read_text()
    # create-next-app 이 남긴 플레이스홀더/무시목록을 실제 승인으로 교체
    s = re.sub(r'(?ms)^allowBuilds:\n(?:[ \t]+.*\n)*', '', s)
    s = re.sub(r'(?ms)^ignoredBuiltDependencies:\n(?:[ \t]*-.*\n)*', '', s)
    p.write_text(allow + s.lstrip('\n'))
else:
    p.write_text(allow)
print("     ✅ pnpm-workspace.yaml allowBuilds 설정")
PYEOF

      echo "  📦 의존성 설치"
      pnpm install
    fi
    rm -rf "$TMPDIR_BACKUP"
  fi
fi

# ─── 5.5 테스트 스택 배선 (Vitest + Playwright) ───
#
# 왜 둘 다인가: Vitest 는 async Server Component 를 렌더할 수 없다(러너 역량 한계, 우회 불가).
# 우리 표준은 Server Components 우선이라, 단위(Vitest)만 두면 주력 코드가 검증 사각지대에 남는다.

if [ "$SCAFFOLDED" = true ] && [ -d templates ]; then
  echo ""
  read -rp "테스트 스택(Vitest + Playwright)을 설치하시겠습니까? (Y/n): " WANT_TEST
  if [[ ! "$WANT_TEST" =~ ^[Nn]$ ]]; then
    echo "🧪 테스트 스택 설치 중..."
    pnpm add -D vitest @vitejs/plugin-react jsdom \
      @testing-library/react @testing-library/dom @testing-library/jest-dom \
      @playwright/test

    cp templates/vitest.config.ts .
    cp templates/vitest.setup.ts .
    cp templates/playwright.config.ts .
    mkdir -p e2e src/__tests__
    cp templates/e2e-example/home.spec.ts e2e/home.spec.ts
    cp templates/test-example/example.test.ts src/__tests__/example.test.ts

    # package.json 스크립트 주입 (Next 16 은 `next lint` 가 없어 eslint 직접 호출)
    node - <<'NODE'
const fs = require('fs')
const p = JSON.parse(fs.readFileSync('package.json', 'utf8'))
const oldLint = p.scripts?.lint
p.scripts = {
  ...p.scripts,
  typecheck: 'tsc --noEmit',
  lint: !oldLint || oldLint.includes('next lint') ? 'eslint .' : oldLint,
  test: 'vitest',
  'test:e2e': 'playwright test',
}
fs.writeFileSync('package.json', JSON.stringify(p, null, 2) + '\n')
console.log('  ✅ package.json 스크립트: typecheck · lint · test · test:e2e')
NODE

    rm -rf templates
    echo "  💡 Playwright 브라우저 설치: pnpm exec playwright install --with-deps chromium"
  fi
fi

# ─── 6. Claude Code 추천 플러그인 안내 ───

echo ""
echo "🧩 Claude Code 추천 플러그인은 .claude/settings.json 에 선언되어 있습니다:"
echo "     • context7          — 라이브러리 최신 문서 참조 (공식, verified)"
echo "     • security-guidance — OWASP Top 10 실시간 보안 린터 (공식, verified)"
echo "     • bkit              — PDCA 개발 방법론 (커뮤니티 — verified 아님, autoUpdate 끔)"
echo "   → 'claude' 첫 실행 시 워크스페이스 trust 후 자동 설치됩니다."

# ─── 7. setup.sh 자체 삭제 여부 ───

echo ""
read -rp "setup.sh를 삭제하시겠습니까? (초기 설정 완료 후 불필요) (Y/n): " DELETE_SETUP

if [[ ! "$DELETE_SETUP" =~ ^[Nn]$ ]]; then
  rm -f setup.sh
  echo "  🗑️  setup.sh 삭제 완료"
fi

# ─── 8. 결과 요약 ───

echo ""
echo "=========================================="
echo "  ✅ 초기 설정 완료!"
echo "=========================================="
echo ""
echo "  프로젝트: $PROJECT_NAME"
echo ""
echo "📋 다음 단계:"
if [ "$SCAFFOLDED" != true ]; then
  echo "  • Next.js 프로젝트 생성:"
  echo "    pnpm create next-app . --typescript --tailwind --eslint --app --src-dir --use-pnpm"
fi
echo "  • .env.local 에 환경변수 값 채우기"
echo "  • GitHub 레포 Settings → secret scanning + push protection 활성화"
echo "  • Claude Code 로 개발 시작: claude"
echo ""
echo "  유용한 명령어:"
echo "    /dev         - 개발 서버 시작"
echo "    /build       - 프로덕션 빌드"
echo "    /lint        - ESLint + 타입체크"
echo "    /test        - Vitest (+ 'e2e' 인자 시 Playwright)"
echo "    /setup-env   - 환경변수 설정 가이드"
echo "    code-review  - Rob Pike 단순성 진단 (skill — 맥락에 따라 자동 발동)"
echo ""
