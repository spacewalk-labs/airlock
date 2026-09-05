# airlock-project-starter — 템플릿 레포 자체를 고칠 때

> 🔴 **이 파일은 템플릿 레포 유지보수자용이다. 새 프로젝트가 받는 지침이 아니다.**
> 새 프로젝트의 지침은 [`AGENTS.md.template`](AGENTS.md.template) 이고, `setup.sh` §2 가 이 파일을
> 그것으로 **덮어쓴다.** 여기서 규칙을 고쳐도 생성될 프로젝트는 그대로다 — 그건 `.template` 에서 고친다.

이 레포가 무엇이고 왜 이렇게 생겼나(스택·훅 설계·보안 근거)는 [README.md](README.md) 가 정본이다.
여기 복제하지 않는다.

## 이 레포의 파일은 독자가 둘이다

"Use this template" 은 **모든 파일을 그대로 복사한다.** 갈리는 지점은 그다음 — `setup.sh` 가
무엇을 치환·삭제하느냐다.

| `setup.sh` 가 하는 일 | 대상 |
|---|---|
| `.template` → 실제 파일로 치환 (§2, **4종**) | `AGENTS.md`(이 파일) · `CLAUDE.md` · `README.md` · `.gitignore` |
| 삭제 | `LICENSE`(§2.5) · `setup.sh` 자신(§7) · `templates/`(§5.5, 테스트 스택 설치 시) |
| **아무것도 안 한다 → 그대로 상속된다** | `.claude/**` · `.github/**` · `.editorconfig` · `.env.example` |

`.claude/` 는 **두 곳에서 동시에 산다** — 지금 이 세션의 설정이면서, 앞으로 만들 모든 프로젝트에
실릴 payload 다. 여기서 훅·deny·rules 를 고치면 **이후 생성되는 모든 프로젝트가 바뀐다.**

- `.claude/rules/*.md` 의 frontmatter `paths:` 는 **자동 로드된다.** 2026-08-20 재실측
  (CC 2.1.235, 격리 저장소에 고유 마커를 심어 도구별 3-way 대조) — `paths:` 매칭 파일을
  `Read`·`Edit` 하면 전문이 주입되고, 비매칭 파일에서는 안 뜬다. 정본 = airlock-wiki
  `40_Playbooks/_System/agent-rules/instruction-placement.md` §0.
  🔴 **단 `Bash` 에는 안 걸린다** — `cat`·`sed` 로 읽고 고치면 영영 안 뜬다.
  🔴 **`globs:` 는 스코프가 무시되고 상시 로드된다** — 쓰지 마라. 항상 `paths:` 다.
  → 그래서 `AGENTS.md.template` 은 rules 를 링크로도 가리킨다(Codex 처럼 이 메커니즘이
  없는 하네스와 `cat` 편집 경로를 위한 이중 안전망).
- `.claude/settings.json` 의 deny 는 `git commit`·`git push` 를 막는다. 의도된 게이트다
  (커밋·푸시는 사람이 트리거한다). 우회하지 말고 사람에게 넘긴다.

## 🔴 상속 함정 — 루트에 파일을 더하기 전에 읽는다

루트에 새 파일을 두면 이후 만들어지는 프로젝트가 전부 그것을 상속한다(위 표의 3번째 행).
그래서 새 루트 파일은 셋 중 하나여야 한다.

1. 새 프로젝트에도 있어야 하는 것(`.editorconfig`·`.env.example`) → 그냥 둔다
2. 프로젝트마다 달라지는 것 → `*.template` 로 두고 `setup.sh` §2 치환 루프에 이름을 넣는다
3. 템플릿 레포 전용인 것 → `setup.sh` 가 **덮어쓰거나 지우게** 만든다

둘 다 **새기 전에** 막아둔 것이다(#4 는 사고 수습이 아니라 예방이다): `LICENSE`(MIT)는 §2.5 에서
삭제한다 — 안 그러면 비공개 프로젝트가 MIT 를 달고 시작한다. `README.md` 는 `README.md.template`
이 덮어쓴다. 이 파일도 같은 방식(2번)으로 처리돼 있다.

⚠️ §2.5 의 삭제 가드는 `LICENSE` 안의 `MIT License` **와** `Copyright (c) 2026 Airlock Project` 두 문자열을
모두 확인한다. 연도나 주체를 고치면 **조용히 삭제가 멈추고** MIT 가 새 프로젝트로 그대로 실린다 —
`LICENSE` 를 손대면 그 가드도 같이 고친다.

⚠️ **`CLAUDE.md` 를 symlink 로 바꾸지 말 것.** 이 템플릿은 `@AGENTS.md` import 를 사용하며, symlink 는 `setup.sh` 를
깬다 — §2 의 `sed … > CLAUDE.md` 리다이렉트가 **심링크를 따라가** 바로 앞 줄에서 생성한 `AGENTS.md` 를
덮어쓴다(2026-08-20 실측). 그래서 여기서는 `@AGENTS.md` 한 줄짜리 일반 파일이다.

## 검증 — 이 레포에서 "완료"란

`pnpm typecheck·lint·test` 는 **여기서 돌지 않는다**(`package.json` 이 없다). `typecheck.sh` 와
`verify-turn.sh` 는 `[ -f package.json ] || exit 0` 으로 스스로 빠지고, CI 도 `package.json` 부재를
감지해 빌드 검증을 스킵한다. `secret-scan.sh` 는 그 가드가 없고 **여기서도 그대로 산다** — 이 레포의
`git add`·`git commit` 도 검사한다. 즉 `AGENTS.md.template` 의 "Done 의 정의" 는 **생성될 프로젝트의 정의이지 이 레포의 것이 아니다.**

이 레포의 검증은 이것이다.

```bash
bash -n setup.sh                                            # 셸 구문
for f in .claude/hooks/*.sh; do bash -n "$f" || exit 1; done  # 훅 3개 — 반드시 루프로
jq -e . .claude/settings.json > /dev/null                   # settings.json 파싱
```

🔴 **훅 검사를 `bash -n .claude/hooks/*.sh` 로 쓰지 말 것.** `bash -n` 은 **첫 파일만** 읽고 나머지는
위치인자로 흘려버린다 — 2026-08-20 실측에서 구문오류가 든 훅 2개가 **exit 0 으로 통과**했다. 위 루프를 쓴다.

🔴 **`setup.sh` 나 훅의 로직을 바꿨다면 구문 검사로 끝내지 않는다** — 스크래치 디렉터리에 레포를
복사해 거기서 실제로 돌려본다. `setup.sh` 는 `git remote remove` · `rm LICENSE` · `rm setup.sh` 를
포함하므로 **작업 클론에서 실행하면 이 레포가 망가진다.**

시크릿은 이 레포에 없다 — `.env.example` 은 전 항목이 주석 처리된 키 목록이다(`AUTH_URL` 만
로컬 기본값을 예시로 달고 있다). **패턴·엔트로피에 걸리는** 시크릿이 들어가면 CI 의 gitleaks 가
PR 을 막는다 — 다만 모든 값을 잡지는 않으므로(placeholder 형태는 통과) 게이트를 믿고 값을 적지 않는다.

<!-- CC-RULES:START -->
<!-- 관리 블록 (엔진: agent-rules/scripts/apply-block.mjs). 이 안의 수정은 재생성 시 덮어쓰인다 — 커스텀 규칙은 블록 밖에. -->

## Working Discipline
- **작업 전 생각.** 가정과 모호성을 먼저 드러내고, 불확실하면 묻는다. 경합하는 해석을 침묵으로 고르지 않는다.
- **단순성 우선.** 요청된 문제를 푸는 최소 변경만. 미요청 기능·추상화·설정화 금지.
- **Surgical changes.** 작업과 직접 연결된 부분만 건드린다. 주변 리팩터링·포맷 정리 금지. 기존 스타일을 따른다.
- **목표 주도.** 성공 기준(테스트·빌드·lint·명령·스크린샷)을 먼저 정의하고, 통과할 때까지 반복한다.

## Verification
- 항상 검증 수단을 확보한다 — 검증 루프가 가장 큰 품질 레버. 레포별 구체 검증 명령은 블록 밖 본문(프리앰블·체크리스트)이 정본.
- 정직하게 보고한다: 실패하면 출력과 함께 말하고, 미검증은 "unverified" 로 표시한다. 미완성을 완료처럼 제시하지 않는다.

## Git / 워크트리 워크플로우 (멀티 세션)
- **본진 main = 읽기 전용 SoT. 모든 작업은 워크트리(`wt/{slug}-{YYYYMMDD}/`). 본진 main commit+push 는 사용자 명시 트리거만.** 큰 코드 변경은 무조건 워크트리 → PR.
- `git stash`·force push·amend(푸시됨)·다른 세션 WIP 자의 정리 금지.
- 한 작업 = 한 이슈 = 한 브랜치. **편집 시작 전에** 브랜치/worktree 를 만든다 — 커밋 시점이 아니라(`claude -w <name>` 또는 `git worktree add ../<task> -b <branch>`). 서브에이전트에 코드 변경 위임 시 worktree 격리(`isolation: worktree`), 미push 작업 있으면 부모 HEAD 기준(`worktree.baseRef=head`) 분기.
- 작은 PR, 한 PR 한 관심사. 이슈 참조("Fixes #42"). 한 브랜치 = 한 핸드오프(`docs/handoff/<branch>.md`). 레포에 `docs/GIT-WORKFLOW.md` 가 있으면 그쪽이 상세 SoT.
- **머지 후 정리.** PR 머지되면 워크트리(`git worktree remove`)·로컬/원격 브랜치(`git branch -d` · `git push origin --delete`)를 정리해 누적을 막는다. repo Settings "Automatically delete head branches" ON 권장. 세션 시작 시 머지된 로컬 브랜치 prune(`git fetch --prune`).
<!-- CC-RULES:END -->
