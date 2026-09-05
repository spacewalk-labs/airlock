---
name: web-project-bootstrap
description: 새 웹 프로젝트/서비스 레포를 표준 스택으로 시작한다 — 하네스와 함께 설치된 고정 스타터(Next.js App Router·TypeScript·Tailwind·Vitest+Playwright·pnpm·GitHub Actions·AGENTS.md)를 복제하고 setup.sh로 초기화. 스택을 매번 새로 고민하지 말고 이걸로 시작. 순수 백엔드·데이터 파이프라인은 대상 아님.
---

# 새 웹 프로젝트 부트스트랩 (web-project-bootstrap)

새 **웹 프론트/풀스택** 레포를 시작할 때, 스택·설정·에이전트 규칙을 매번 새로 고민하지 않도록
**하나의 표준 스타터**로 시작합니다. 하네스 설치기가 검증한 고정 스냅샷을
`~/workspace/templates`에 놓으며, 이 스킬은 "무엇을·왜·어떻게 시작"만 안내합니다.

> 📦 **정본(SoT)**: `~/workspace/templates` — Airlock 설치본에 고정된 읽기 전용 스타터입니다.
> 정확한 버전·명령·플러그인 목록은 **그 폴더의 README·`setup.sh`가 정본**입니다. 이 문서에 버전 숫자를
> 박지 마세요(rot 원인). `create-next-app`·CI(`node lts/*`·`pnpm latest`)가 늘 최신을 따릅니다.
>
> 🔒 **권한**: 이 폴더는 설치본의 기준 사본입니다. 직접 작업하지 않고 아래처럼 내 프로젝트로 복제해 시작합니다.

## 전제 도구 (없으면 스타터가 막습니다)

스타터의 `setup.sh`와 훅 3개는 **`pnpm` · `jq` · `gitleaks`** 를 전제로 합니다. **없으면 조용히
통과시키지 않고 사람에게 확인을 요청**합니다 — 그게 설계입니다(전제 부재를 통과시키면 "검사했다"는
거짓이 되므로). 하네스 설치 때 함께 깔리지만, 막히면 여기부터 확인하세요:

**존재가 아니라 실행으로 확인하세요** — `pnpm` 은 node 버전이 낮으면 파일은 있는데 실행하면 죽습니다.
`command -v` 로만 보면 ✅ 로 보여서, 첫 `pnpm install` 에서야 터집니다.

```bash
node -v                                   # 20 이상이어야 합니다
for c in pnpm jq; do printf '%-10s %s\n' "$c" "$($c --version 2>&1 | head -1)"; done
printf '%-10s %s\n' gitleaks "$(gitleaks version 2>&1 | head -1)"
# node 가 낮으면 — nvm 사용 시: nvm install --lts && nvm use --lts  (그 다음 npm i -g pnpm 재실행)
# 도구가 없으면 — 우분투: sudo apt-get install -y jq gitleaks && npm i -g pnpm
#                맥:     brew install jq gitleaks && npm i -g pnpm
```

| 도구 | 없으면 무슨 일이 | 어디에 쓰이나 |
|---|---|---|
| `jq` | 훅 3개 전부 제 기능을 못 함(타입체크 피드백·명령 파싱·루프 가드) | Claude Code 훅 입출력 파싱 |
| `gitleaks` | 시크릿이 커밋으로 새는 걸 **막지 못함** | 커밋 전 내용 스캔(파일명만으론 하드코딩 토큰을 못 잡음) |
| `pnpm` | 설치·실행 명령이 전부 실패 | 표준 패키지 매니저 |
| `node` 20+ | **pnpm 이 깔려 있어도 실행되지 않음** — 존재 확인만 하면 못 잡는 함정 | 모든 JS 도구의 런타임 |

## 언제 쓰나
- 새 **웹 프론트/풀스택** 레포 시작(Next.js App Router 기준).
- Claude Code 최적화 설정(규칙·훅·커맨드)을 처음부터 갖고 시작하고 싶을 때.
- ❌ 순수 백엔드(Kotlin/Python)·데이터 파이프라인은 대상 아님 — 해당 도메인 레포 참조.

## 표준 스택 (한눈에 — 값은 스타터가 정본)
| 영역 | 기술 |
|---|---|
| Frontend | **Next.js**(App Router, Turbopack) · React · TypeScript |
| Styling | Tailwind CSS |
| Lint | ESLint (flat config, `eslint.config.mjs`) |
| Test | **Vitest**(unit) + **Playwright**(E2E) — 둘 다 필요 |
| Runtime | Node(LTS) · **pnpm** |
| CI/CD | GitHub Actions — gitleaks → typecheck → lint → test → build (+E2E) |
| Agent | **`AGENTS.md` 정본** + `CLAUDE.md` = `@AGENTS.md` (Claude·Codex·Cursor 공통) |

> **테스트가 두 도구인 이유(취향 아님)**: Vitest는 async Server Component를 렌더 못 합니다 →
> async 서버컴포넌트·인증·라우팅·폼은 **Playwright(E2E)**, Server Actions·스키마·순수 로직·동기 컴포넌트는 **Vitest**.

## 3단계 시작 — 스타터를 '내 것'으로 만들기

하네스가 깔아 둔 `~/workspace/templates`를 복사하고 `.git`을 끊어 **내 private 레포**로
새로 시작합니다. 기준 사본에 push하지 않기 위함입니다.
레포는 **`~/workspace/<레포이름>`** 에 바로 둡니다 — 중간 폴더 없이(→ 1부 §3.2):
```bash
cp -r ~/workspace/templates ~/workspace/<새-프로젝트> && cd ~/workspace/<새-프로젝트>
rm -rf .git && git init && ./setup.sh
gh repo create <새-프로젝트> --private --source=. --remote=origin --push
```

3. **개발 시작** — `pnpm install && pnpm dev` (또는 `claude`로 Claude Code 세션).

## setup.sh가 자동으로 해주는 것
- `CLAUDE.md`·`README.md`·`.gitignore` 생성(이름/설명 치환) · `.env.local`(`.env.example` 기반, git 제외)
- Next.js 스캐폴딩(선택): TypeScript + Tailwind + App Router + ESLint flat config, Turbopack 기본
- `.editorconfig` · PR 템플릿 · CI 파이프라인 · 템플릿 remote 오사용 감지

## 마무리 (스타터가 대신 못 하는 계층)
- **GitHub 보안**: 새 레포 Settings → Code security 에서 **secret scanning + push protection** 켜기.
- **에이전트 규칙**: 스타터에 `AGENTS.md` 가 이미 들어 있습니다 — 추가 작업 없음.
- 완성한 웹서비스를 **내 홈서버에 올려 도메인으로 공개**하려면 → **[web-deploy]** 스킬로 이어집니다.
