# 수강생 스타터 하네스 — 내 에이전트 기본 세팅

내 홈서버(Airlock)의 AI 에이전트가 **어디서 일하든 지킬 기본 규칙**과 **공통 스킬**을
한 벌로 모은 스타터입니다. **Claude Code**와 **Codex** 둘 다 같은 규칙을 보게 됩니다.

## 들어 있는 것

**지침·설정**

| 파일 | 하는 일 |
|---|---|
| `CLAUDE.md` | 내 전역 기본 규칙 — 소통(존댓말)·일하는 원칙·서브에이전트·검증·시크릿·세션 마감 |
| `AGENTS.md` | **Codex용** 지침. `CLAUDE.md` 심링크 = **같은 내용 한 벌**(둘이 안 엇갈리게) |

> 🔴 **스킬 폴더도 도구별로 갈립니다.** Claude 는 `~/.claude/skills`, **Codex 는 `~/.agents/skills`** 를
> 봅니다. 설치는 `~/.claude/skills` 에 깔고 `~/.agents/skills` 를 거기로 **심링크**합니다 —
> 이 배선이 없으면 Codex 에서는 **규칙만 읽히고 스킬이 하나도 안 보입니다**(오류도 안 납니다).

| `settings.json` | 기본 권한 — **가급적 다 허용**(막지 않음), 단 홈·시스템을 통째로 지우는 **파국적 삭제만 차단** + 훅 연결 |

**스킬 29종** (`skills/<이름>/SKILL.md`)

| 스킬 | 하는 일 |
|---|---|
| `task-discussion` | **시키기 전에 회의** — 빈 칸·모순을 먼저 짚고, 사용자만 답할 수 있는 것만 물어봄 |
| `task-doc` | **태스크 문서 먼저** — 바로 코딩 말고 문서→리뷰→재작성→실행 |
| `worklog` | **작업 로그** — 한 일·결정을 시간순으로 파일에 누적(스테이트리스 보완) |
| `session-resume` | **세션 열기** — 남은 인계 메모를 펼쳐 보이고 고르게, 남은 워크트리도 줍기 |
| `session-handoff` | **끊고 이어가기** — 컨텍스트가 찼을 때 다음이 이어받을 포인터를 남김 |
| `session-close` | **세션 닫기** — 정리 + worklog 인계 + 검증 상태 + **워크트리 회수** (📎 `scripts/retire-worktree.sh`) |
| `worktree` | **격리 폴더** — 일마다 워크트리 하나. 본진은 기본 브랜치로 안 건드림 (📎 `scripts/create-worktree.sh`) |
| `ship` | **배송** — 커밋 → push → PR → 머지 → 본진 pull → 워크트리 회수까지 한 번에 |
| `self-verify` | **독립 검증 게이트** — "다 됐다" 선언 전, 다른 에이전트가 반박해 보게 |
| `code-review` | **코드 리뷰** — 변경점을 일반 시선·적대 시선 두 축으로. 자기 리뷰 금지 |
| `pikes-filter` | **단순성 진단** — 추측성 최적화·과한 알고리즘·자료구조 불균형 찾기 |
| `subagent` | **서브에이전트** — 독립 작업을 나눠 시키고 결론만 회수(라우팅) |
| `codex` | **Codex 위임** — 2차 구현·리뷰를 Codex CLI에(AGENTS.md 공유) |
| `gemini` | **Gemini 위임** — 긴 문서를 한 번에 훑거나 다른 모델의 2차 의견(무료 API 키, 각자 발급) |
| `create-skill` | **스킬 만들기** — 같은 설명을 두 번 하고 있다면 스킬 후보. 만들기 전 판정부터 |
| `web-research` | **웹 조사** — 검색으로 여러 소스를 출처와 함께 종합 |
| `browser-session` | **로그인해야 보이는 사이트** — 쿠키를 붙여넣지 않고, 사람이 로그인한 브라우저를 이어받음 |
| `secret-manage` | **시크릿 관리** — 키를 bws 금고에 넣고 `bws run` 으로만 꺼내 쓰기 |
| `share-docs` | **문서 공유** — 내부 링크(테일넷) 먼저, 지시할 때만 내 도메인으로 공개. 묶음·기간·암호 게이트. **옛 이름 `doc-publish`** (📎 `templates/` · `assets/doc.css`·`doc.js` · `references/` · 린트 2종) |
| `orbstack-provision` | **머신 프로비저닝** — OrbStack 작업/배포 머신을 상의해 만들고 아카이브 |
| `web-deploy` | **웹서비스 배포** — self-hosted 러너로 push=배포, 도메인/게이트웨이 연결 |
| `repo-bootstrap` | **새 레포 만들기** — 위치·기본 브랜치·`.gitignore`·`WORKLOG.md`·첫 커밋·GitHub private |
| `web-project-bootstrap` | **웹 프로젝트 시작** — 표준 스타터 템플릿(Next.js·TS·Tailwind·pnpm) |
| `crawling-scraping` | **크롤링·스크래핑** — 가장 싼 방법부터, robots·약관 지키기 |
| `hwpx-doc` | **HWPX 공문 채우기** — 한글 양식 서식 보존하며 본문 자동 작성 |
| `excel-io` | **엑셀 읽고 쓰기** — xlsx·xlsm 을 openpyxl 로. 서식·수식 보존하며 내용만 채우기 (📎 `scripts/xlsx.py`) |
| `cad-read` | **캐드 도면 읽기** — DWG·DXF 에서 레이어·텍스트·치수·면적 뽑기. 읽기 전용 (📎 `scripts/cadread.py`) |
| `claude-md-gardener` | **지침 정원사** — CLAUDE.md/AGENTS.md의 낡은·모순 규칙을 주기적으로 손질 |
| `harness-gardener` | **하네스 정원사** — 스킬·설정 손질 + Claude↔Codex 동기화 + 훅이 실제로 도는지 점검 |

> 📎 표시가 붙은 스킬에는 **설명서 말고 실물**도 함께 들어 있습니다 — 문서 템플릿·스타일, 워크트리를
> 만들고 회수하는 스크립트. 설치하면 `~/.claude/skills/<이름>/` 아래에 그대로 깔립니다.
> 빈 화면에서 시작하거나 위험한 git 명령을 손으로 치지 않아도 됩니다.

**훅 3종** (`hooks/`) — 부르지 않아도 특정 순간 자동으로 도는 안전장치

| 훅 | 하는 일 |
|---|---|
| `secret-guard.sh` | **시크릿 가드**(PreToolUse) — 파일에 키·토큰 값이 들어가려 하면 차단 |
| `session-close-reminder.sh` | **세션 마감 리마인더**(Stop/PreCompact) — worklog·정리 안 하고 끝나면 상기 |
| `session-start-restore.sh` | **세션 시작 복원**(SessionStart) — 최근 worklog를 불러와 이어받게 |

## 로그인은 하네스가 아니라 Airlock이 담당합니다

이 하네스에는 **로그인·계정 정보가 들어 있지 않습니다**(들어가면 안 됩니다). Claude Code 로그인은
Airlock의 **devterm 계정 기능**(1부에서 `accounts = true` 로 켠 것)이 맡습니다 — 브라우저에서
승인 코드를 붙여 넣으면 끝이고, 폰에서도 됩니다. 터미널에서는 `claude-switch`(로그인·전환) ·
`claude-status`(점검).

⏳ **한 달쯤 뒤 재로그인이 필요합니다.** 토큰은 자동 갱신되지만 만료 시각 자체는 밀리지 않습니다.
잘 돌던 에이전트가 갑자기 인증을 요구하면 고장이 아니라 정상이니 계정 패널에서 다시 로그인하세요.

## Claude와 Codex — 왜 파일이 둘인가

- **Claude Code** 는 `CLAUDE.md` 를 읽고, **Codex** 는 `AGENTS.md` 를 읽습니다. 이름이 다릅니다.
- 그래서 **같은 규칙을 두 파일로** 둡니다. **이 폴더 안에서는** `AGENTS.md` 가 `CLAUDE.md` 심링크라
  정본이 하나입니다.
- ⚠️ **설치하고 나면 다릅니다.** 설치는 `~/.claude/CLAUDE.md` 와 `~/.codex/AGENTS.md` 로 **각각 복사**하므로
  내 머신에는 **사본 두 벌**이 생깁니다. 한쪽만 고치면 조용히 갈라집니다 — 고칠 땐 양쪽 다,
  또는 `ln -sf ~/.claude/CLAUDE.md ~/.codex/AGENTS.md` 로 직접 묶어 두세요.
- 이 둘이 어긋나지 않게 챙기는 게 **하네스 정원사**입니다.

## 설치 — 절차는 강의 챕터가 정본입니다

여기에 절차를 다시 적지 않습니다. **한 곳에만 두어야 갈라지지 않습니다.**
(예전엔 이 README 에도 설치 블록이 있었는데, 챕터가 고쳐질 때 여기만 낡아
 node 고정·전제 도구·검증이 빠진 옛 절차가 zip 안에 같이 배포됐습니다.)

→ **[3부 · 내 에이전트 기본 세팅 §5 설치](/k-ai-airlock-harness.html)**

그 챕터가 다루는 것: node 20+ 고정 · 에이전트 CLI · 전제 도구(`jq`·`gitleaks`·`pnpm`·`unzip`) ·
백업 · 지침/설정/스킬/훅 배치 · 웹 표준 스타터 클론 · 본진 폴더 · **실행 기반 설치 검증**.

## 확인

- 새 세션을 열고 `/session-close`, `/self-verify`, `/secret-manage` 가 스킬 목록에 보이면 OK.
- `/ship`, `/worktree`, `/session-resume` 까지 보이면 **최신 하네스**입니다(안 보이면 옛 zip).
- `CLAUDE.md`(Claude) / `AGENTS.md`(Codex) 는 세션 시작 시 자동으로 읽힙니다.

## 내 것으로 고치기

이건 **출발점**입니다. 쓰다 보면 내 방식에 맞게 고치세요 — 규칙 한 줄을 바꾸거나,
자주 하는 일을 새 스킬로 추가하면(→ `self-verify` 처럼 `skills/<이름>/SKILL.md`),
그게 곧 나만의 하네스가 됩니다. 손질이 밀리면 **정원사 스킬**(`claude-md-gardener`,
`harness-gardener`)에게 "한 번 점검해줘"라고 시키면 됩니다.
