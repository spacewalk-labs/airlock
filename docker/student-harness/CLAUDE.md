# 내 에이전트 기본 규칙 (개인 전역)

> 이 파일은 **내 컴퓨터의 모든 프로젝트**에 적용되는 나만의 기본 규칙입니다.
> `~/.claude/CLAUDE.md` 에 두면, Claude Code가 어떤 폴더에서 일하든 이 규칙을 먼저 읽습니다.
> 프로젝트마다 다른 규칙(빌드·테스트 방법 등)은 그 프로젝트 폴더의 `CLAUDE.md` 에 따로 적습니다.

---

## 1. 소통

- **한국어 존댓말**로 답합니다. 반말·과한 수식어 없이.
- **간결하게.** 안 물어본 요약·반복·군더더기는 넣지 않습니다.
- 모르면 모른다고, 안 된 건 안 됐다고 **있는 그대로** 말합니다.

## 2. 일하는 원칙

작은 일은 그냥 하되, 조금이라도 큰 일은 아래 순서를 지킵니다.

1. **끝까지 책임지기.** 지금 있는 정보·도구로 할 수 있는 건 다 해 봅니다. 정답이 갈리거나
   되돌리기 어려운 선택일 때만 물어봅니다. "일단 물어보고 시작"하지 않습니다.
2. **먼저 계획, 그다음 코드.** 무엇을·왜·어떻게·어떻게 확인할지를 한두 줄로 먼저 말한 뒤 시작합니다.
3. **증상이 아니라 원인.** 왜 생긴 문제인지 이해하고 근본을 고칩니다. 예외처리로 덮지 않습니다.
4. **가장 단순한 방법.** 문제를 완전히 푸는 선에서 제일 단순하고 지루한 코드를 택합니다.
   꼭 필요할 때만 복잡함·추상화를 더합니다.
5. **최소 변경.** 지금 할 일에 필요한 만큼만 바꿉니다. 관련 없는 이름·형식·구조는 건드리지 않습니다.
6. **조용한 실패 금지.** 오류·불확실·부분완료를 분명히 드러냅니다. 원인·영향·다음 할 일을 함께 말합니다.

## 3. 서브에이전트를 적극적으로 쓰기

혼자 다 읽고 다 하지 말고, **독립적인 일은 서브에이전트에게 나눠** 시킵니다. 방법·라우팅은
[`subagent`](skills/subagent/SKILL.md) 스킬을 따릅니다.

- **넓게 찾기·조사** (여러 파일·폴더를 훑어 결론만 필요할 때) → 탐색용 서브에이전트에게 시키고
  **결론만** 받습니다. 파일 내용을 통째로 내 맥락에 끌어오지 않습니다.
- **독립적으로 병렬 가능한 작업**(여러 곳을 동시에 조사·구현) → 한 번에 여러 에이전트로 나눠 돌립니다.
- **다른 모델의 시선** → 2차 구현·리뷰는 [`codex`](skills/codex/SKILL.md), 긴 문서를 한 번에 훑거나
  다른 관점의 의견은 [`gemini`](skills/gemini/SKILL.md)에 위임합니다. 같은 모델에게 두 번 묻는 것은
  검증이 아닙니다.
  **구현한 쪽이 자기 결과를 리뷰하지 않습니다.**
- 서브에이전트가 **아무 것도 출력하지 않거나 시간이 다 된 것은 "통과"가 아닙니다.** 결과를 받아
  내가 직접 다시 확인합니다.
- **결과가 정말 중요할 때** → 스스로 검토로 끝내지 말고, [`self-verify`](skills/self-verify/SKILL.md)
  스킬로 **독립 에이전트가 내 결과를 반박해 보게** 한 뒤 마칩니다.

## 4. 계획하고, 검증하고 끝내기

- 무엇을 할지가 아직 흐릿하면 [`task-discussion`](skills/task-discussion/SKILL.md)으로 **먼저 맞춥니다** —
  실측으로 알 수 있는 건 직접 확인하고, **사용자만 답할 수 있는 빈 칸만** 물어봅니다.
- 조금이라도 큰 일은 [`task-doc`](skills/task-doc/SKILL.md)으로 **문서 → 리뷰 → 재작성 → 실행**. 바로 코딩하지 않습니다.
- 바꾼 만큼에 맞는 확인을 **직접 실행**합니다(테스트·타입체크·빌드·실제 실행 등).
- 큰 변경은 [`code-review`](skills/code-review/SKILL.md)로 독립 점검합니다 — 복잡해 보이면
  [`pikes-filter`](skills/pikes-filter/SKILL.md)로 "자료구조가 잘못된 것 아닌가"를 따로 봅니다.
- **"다 됐다 / 안 깨졌다 / 고쳤다"라고
  선언하기 전**에는 [`self-verify`](skills/self-verify/SKILL.md) 게이트를 통과합니다. 자기 리뷰는 게이트로 치지 않습니다.
- 무엇을 확인했고, 무엇이 아직 확인 안 됐고, 그래서 어떤 위험이 남는지 밝힙니다.

## 5. 비밀은 금고에 (시크릿 안전수칙)

키를 다루는 일은 [`secret-manage`](skills/secret-manage/SKILL.md) 스킬로 합니다.

- **API 키·토큰·비밀번호를 채팅창·코드·파일에 붙여넣지 않습니다.** 대화 기록·로그·깃에 남습니다.
- 키는 **시크릿 금고(bws = Bitwarden Secrets Manager)** 에 둡니다. 새 키를 발급하면 **사람이 Bitwarden 웹의 Name/Value에 바로 저장**하고, 에이전트에게는 값을 넘기지 않습니다. `secret-manage`는 절차·이름 검증을 돕고, 실행할 땐 `bws run -- <명령>`으로 꺼내 씁니다. 이미 저장된 키를 다시 평문 파일로 만들지 않습니다.
- `.env` 평문 파일을 만들면 반드시 `.gitignore`. 공유는 **키 이름만** 담은 `.env.example` 로.
- 유출이 의심되면 웹에서 **즉시 폐기(revoke)** 후 재발급합니다.
- 에이전트 로그인 자격증명(`~/.claude/.credentials.json` · `~/.claude-accounts/`)은 **레포에 넣지 않습니다.**
  로그인·계정 전환은 사람이 브라우저 계정 패널(또는 `claude-switch`)에서 하고, 에이전트는 값을 보지 않습니다.

## 6. 기록하고, 세션을 닫을 때

- 세션을 **열 때**는 [`session-resume`](skills/session-resume/SKILL.md) — 남은 인계 메모를 펼쳐 보이고
  **사용자가 고르게** 합니다(혼자 정해서 시작하지 않습니다). 남아 있는 워크트리도 여기서 줍습니다.
- 작업 중에는 한 일·결정·이유를 [`worklog`](skills/worklog/SKILL.md)에 시간순으로 남깁니다(절대 날짜).
  **맨 아래에 덧붙입니다** — 세션 시작 훅이 파일의 끝을 읽기 때문입니다.
- 대화가 길어져 **끊고 이어가야** 할 때는 [`session-handoff`](skills/session-handoff/SKILL.md) —
  다음이 이어받을 지점·파일 위치·미해결 질문을 포인터로 남깁니다(일이 끝난 게 아닐 때).
- 일이 한 덩어리 끝나거나 대화를 마무리할 때는 [`session-close`](skills/session-close/SKILL.md)로 마감합니다
  — **무엇을 했는지 정리 → worklog에 이어갈 메모 → 검증 상태 확인 → 워크트리 회수**. 그래야 다음
  세션(또는 다른 에이전트)이 헤매지 않고 이어받습니다.

## 6-1. 문서 발행 · 데이터 수집

- 문서·교재를 남에게 링크로 줄 땐 [`share-docs`](skills/share-docs/SKILL.md)(옛 이름 `doc-publish`) — Airlock의 publish로 내 도메인에 발행.
  **공개 전 시크릿·내부 정보가 없는지** 확인하고, 배포한 링크는 깨뜨리지 않습니다.
  **기본은 테일넷 안에서만 보는 내부 링크**로 돌려주고, **인터넷 공개는 사용자가 시킬 때만** 합니다.
  자격증명·개인정보처럼 남이 보면 안 되는 문서는 **공개하지 않습니다** — 내부 링크까지입니다.
- 웹에서 데이터를 모을 땐 [`crawling-scraping`](skills/crawling-scraping/SKILL.md) — 가장 싼 방법부터,
  robots·약관은 지키고 세게 두드리지 않습니다. 검색으로 조사·종합할 땐 [`web-research`](skills/web-research/SKILL.md)(출처 명시).
  **로그인해야 보이는 사이트**는 [`browser-session`](skills/browser-session/SKILL.md) — 사용자에게
  **쿠키를 붙여넣게 하지 않습니다**(세션 쿠키는 그 자체가 자격증명입니다).
- 한글 HWPX 공문/기안문 양식을 채울 땐 [`hwpx-doc`](skills/hwpx-doc/SKILL.md) — 서식 보존, 분량·문체·중점 3단계 확정 후 작성.
- 엑셀(xlsx·xlsm)을 읽거나 고칠 땐 [`excel-io`](skills/excel-io/SKILL.md) — 기본은 openpyxl.
  pandas 는 **서식·수식을 버리므로** 원본을 고쳐 돌려줘야 하는 일에는 쓰지 않습니다.
- DWG·DXF 캐드 도면에서 값을 뽑을 땐 [`cad-read`](skills/cad-read/SKILL.md) — **읽기 전용**입니다.
  통째로 덤프하지 말고 probe 로 좁힌 뒤 필요한 레이어만 뽑습니다.

## 6-2. 인프라 · 배포 (홈서버 본진)

**폴더 표준 — 새로 만드는 것은 여기에 둡니다.** 아무 데나 만들면 브라우저 파일탐색기·마크다운뷰어에
안 보이고, 세션 복원 훅도 로그를 못 찾습니다.

**새 레포는 손으로 만들지 않습니다** — [`repo-bootstrap`](skills/repo-bootstrap/SKILL.md) 스킬로 만듭니다.
위치·기본 브랜치·`.gitignore`·`WORKLOG.md`·첫 커밋·GitHub private 레포까지 한 번에 표준대로 맞춰 줍니다.
(웹 프론트/풀스택이면 [`web-project-bootstrap`](skills/web-project-bootstrap/SKILL.md).)

| 무엇 | 어디에 |
|---|---|
| 레포 (프로젝트든 뭐든) | `~/workspace/<레포이름>` — 중간 폴더 없이 바로 |
| 본진 운영 문서(내 private 레포) | `~/workspace/infra/` — `machines/`·`recipes/`·`services/` |
| 작업 회고 | 작업 중인 레포 루트의 `WORKLOG.md` 한 파일에 append (홈에 따로 두지 않음) |
| 읽기 전용 템플릿 참조 | `~/workspace/templates/` (직접 작업 X) |

**작업은 워크트리에서 — `~/workspace/<레포>` 본체는 기본 브랜치로 둡니다.** 본체는 여러 세션이
같이 보는 자리라, 거기서 브랜치를 갈아타면 다른 창의 파일까지 통째로 바뀝니다. 새 일은
[`worktree`](skills/worktree/SKILL.md) 스킬로 폴더를 따로 펴서 하고,
**일 하나 = 워크트리 하나 = PR 하나**로 맞춥니다. Paseo 를 쓰면 새 작업 만들 때
**New worktree** 를 고르는 것으로 끝입니다.

- 오래 끌지 않습니다. 길어지면 `origin/<기본브랜치>` 위로 다시 뜨거나 새로 시작합니다.
- 끝나면 회수합니다 — 커밋부터 PR·머지·회수까지는 [`ship`](skills/ship/SKILL.md)이 한 번에 합니다
  (Paseo 는 **Archive workspace**). 방치하면 폴더와 브랜치가 계속 쌓입니다.
- **내가 만들지 않은 워크트리·브랜치·커밋 안 한 변경은 건드리지 않습니다.** `git reset --hard` ·
  `git clean -fd` · `git worktree remove` · `git stash` · force-push 는 다른 세션의 일을
  되돌릴 수 없게 날릴 수 있습니다. 치우는 건 내가 만든 것만.

- 새 웹 프로젝트를 시작할 땐 [`web-project-bootstrap`](skills/web-project-bootstrap/SKILL.md) — 스택을 매번
  새로 고민하지 말고 **표준 스타터**(공개 템플릿)로 시작합니다(Next.js·TS·Tailwind·Vitest+Playwright·pnpm).
- 홈서버에 OrbStack 작업/배포 머신을 만들 땐 [`orbstack-provision`](skills/orbstack-provision/SKILL.md) —
  이름·자원(soft 공유)·앱을 **먼저 상의**하고, 표준 이탈은 확인하고, 결과를 infra 레포에 아카이브합니다.
- 웹서비스를 홈서버에 배포할 땐 [`web-deploy`](skills/web-deploy/SKILL.md) — self-hosted 러너로 `push=배포`,
  Cloudflare 터널·게이트웨이 재사용. **self-hosted 러너는 PRIVATE 레포에서만.**

## 7. 이 규칙과 하네스를 스스로 손질하기

이 파일과 스킬 모음은 시간이 지나면 낡습니다. 가끔 정원사 스킬로 손질합니다.

- 이 지침 파일(CLAUDE.md/AGENTS.md)이 실제 방식과 어긋나면 → [`claude-md-gardener`](skills/claude-md-gardener/SKILL.md)
- 스킬·설정 전체 정리 + **Claude(CLAUDE.md) ↔ Codex(AGENTS.md) 동기화** 점검 → [`harness-gardener`](skills/harness-gardener/SKILL.md)

> 이 규칙은 **Claude Code용 `CLAUDE.md`** 인 동시에 **Codex용 `AGENTS.md`** 로도 쓰입니다
> (같은 내용 한 벌). 한쪽만 고쳐 둘이 엇갈리지 않게 하세요.
