# airlock-project-standard-starter

Airlock의 **웹 풀스택 표준 스타터** — Next.js(App Router) 프로젝트를 에이전틱 개발 규율까지 갖춘 상태로 시작하는 템플릿입니다.

> 이 README 는 **템플릿 레포 자체**의 문서입니다. 여기서 새 레포를 만들면 `setup.sh` 가 프로젝트용 README 로 교체합니다.

## 쓰는 법

1. GitHub 에서 **"Use this template" → Create a new repository** (clone 아님)
2. 클론 후 `./setup.sh` — 이름·설명 입력 → 템플릿 치환 · `.env.local` · Next 스캐폴딩 · 테스트 스택 · 스크립트 주입까지 자동
3. `pnpm dev` 또는 `claude`

전제 도구: **pnpm** · **jq**(훅) · **gitleaks**(시크릿 차단 훅). `setup.sh` 가 부재를 알려줍니다.

## 표준 스택

| 영역 | 기술 |
|---|---|
| Frontend | Next.js (App Router, Turbopack 기본) · React · TypeScript |
| Styling | Tailwind CSS |
| Lint | ESLint (flat config, 직접 호출 — Next 16 은 `next lint` 를 제거) |
| Test | **Vitest**(unit) + **Playwright**(E2E) |
| Runtime | Node (LTS) · pnpm |
| CI/CD | GitHub Actions — gitleaks → typecheck → lint → test → build (+ E2E, 주간 TruffleHog) |
| Agent | `AGENTS.md` 정본 + `CLAUDE.md` = `@AGENTS.md` (Claude Code·Codex·Cursor·Copilot 공통) |

**버전 숫자는 일부러 고정하지 않습니다** — `create-next-app` 이 항상 최신을 스캐폴딩하고, 정확한 값은 생성된 `package.json` 이 정본입니다.

### 테스트가 두 도구인 이유 (취향 아님)

**Vitest 는 async Server Component 를 렌더할 수 없습니다** — React 의 async 컴포넌트 지원이 테스트 러너에서 stable 이 아니라서 생기는 역량 한계로, mock 으로 우회할 수 없습니다([Next 공식 가이드](https://nextjs.org/docs/app/guides/testing/vitest)도 이 경우 E2E 를 권장). 이 스택은 Server Components 우선이라 단위 테스트만 두면 주력 코드가 검증 사각지대에 남습니다.

| 대상 | 도구 |
|---|---|
| Server Actions · 스키마 · 순수 로직 · 동기 컴포넌트 | Vitest |
| async Server Components · 인증 · 라우팅 · 폼 | Playwright |

## 에이전틱 개발 규율

| 위치 | 역할 |
|---|---|
| `AGENTS.md.template` | 항상 켜진 짧은 프로젝트 지침. Next 마커 섹션(`BEGIN:nextjs-agent-rules`)은 **번들 docs 를 읽으라는 지시** |
| `.claude/settings.json` | deny 16개 + 훅 배선 + 플러그인 선언 |
| `.claude/hooks/` | **강제되는 것** — 아래 3개 |
| `.claude/rules/` | 경로별 상세 규칙 (소스·테스트) — **자동 로드 아님.** `AGENTS.md` 가 링크해서 읽힌다 |
| `.claude/skills/code-review/` | Rob Pike 단순성 진단 (맥락에 따라 자동 발동) |
| `.claude/commands/` | `/dev` `/build` `/lint` `/test` `/setup-env` |

**훅 3개 — 전부 실제로 차단합니다**

- `typecheck.sh` (**PostToolUse**) — ts/tsx 편집 직후 `tsc --noEmit`, 에러를 에이전트에 되돌려줌
  *PreToolUse 에 두면 "편집 전" 상태를 검사해 **에러를 고치려는 편집까지 막히는 데드락**이 됩니다.*
- `secret-scan.sh` (**PreToolUse**) — 스테이징·커밋 **실행 전에** 파일명 규칙 + **gitleaks 내용 스캔**으로 차단
- `verify-turn.sh` (**Stop**) — 소스를 바꾼 턴은 `typecheck`+`lint`+`test` 통과 없이 **끝낼 수 없음**

세 훅 모두 전제(`jq`·`tsc`·`gitleaks`) 부재 시 **조용히 통과하지 않습니다**.

> `AGENTS.md` 에 쓴 문장은 **요청**이고, 훅에 쓴 것만 **보장**입니다.

## 보안

- 커밋 게이트(gitleaks) + 주간 full-history sweep(TruffleHog — **아직 살아있는** 자격증명만 골라 회전 대상 산출)
- 새 레포를 만들면 Settings → Code security 에서 **secret scanning + push protection** 을 켜세요. AI 도구가 co-author 인 커밋의 시크릿 유출률은 GitHub 평균의 **약 2배**입니다.
- ⚠️ CI 에서 `gitleaks/gitleaks-action` 은 쓰지 않습니다 — **organization 계정에 유료 라이선스를 요구**해 CI 가 무조건 실패합니다. CLI 바이너리(MIT)를 직접 받아 씁니다.

## 라이선스

이 **템플릿**은 [MIT](LICENSE) 입니다 — 자유롭게 쓰고 고쳐도 됩니다.

> 🔴 **이 템플릿으로 만든 프로젝트는 MIT 가 아닙니다.** 파일을 복사하면 `LICENSE` 도 따라가므로 `setup.sh` 가 이를 제거하고, 새 프로젝트는 기본적으로 **비공개(proprietary)** 로 시작합니다. 공개할 프로젝트라면 라이선스를 **명시적으로 다시 선택**하세요.

---

관련: airlock-wiki `airlock-wiki-vault/40_Playbooks/new-project-bootstrap.md` (무엇을·왜) · 이 레포 (어떻게·최신 버전)
