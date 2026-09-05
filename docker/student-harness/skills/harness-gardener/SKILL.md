---
name: harness-gardener
description: 내 하네스 전체(스킬 모음·settings·훅·지침 파일)를 주기적으로 손질한다. 안 쓰는 스킬을 정리하고, 깨진 참조·낡은 경로를 고치고, 훅이 실제로 발화하는지 실행해 확인하고, Claude(~/.claude)와 Codex(~/.codex)가 같은 세팅을 보는지 맞춘다.
---

# 하네스 정원사 (harness-gardener)

하나의 스킬(`claude-md-gardener`)이 지침 파일 한 장을 돌본다면, 이 스킬은 **하네스 전체**를 돌봅니다:
`skills/` 모음, `settings.json`, **훅**, 그리고 **Claude와 Codex가 같은 걸 보고 있는지**.

> **원칙: "절대 하지 마"는 문서에 적지 말고 `settings.json` 의 `deny` 로 막습니다.** 지침 텍스트는
> 읽고 지켜 주기를 바라는 것이고, `deny`/`ask` 는 **실행 자체를 막는 것**입니다. 넣었으면 **막히는지 실제로 확인**합니다.

## 무엇을 하네스라 부르나

- **지침 파일** — `~/.claude/CLAUDE.md` (Claude) / `~/.codex/AGENTS.md` (Codex)
- **스킬 모음** — `~/.claude/skills/*/SKILL.md`
- **설정** — `~/.claude/settings.json` (권한 `allow`/`ask`/`deny` + 훅 등록)
- **훅** — `~/.claude/hooks/*.sh` (설정에 등록돼 **실제로 도는** 스크립트)

## 언제

- 스킬이 늘어나 뭐가 있는지 헷갈릴 때
- Claude에선 되는데 Codex에선 규칙이 안 먹힐 때(동기화 깨짐)
- 몇 주에 한 번 정기 점검

## 순서

1. **스킬 목록을 훑습니다.** 각 스킬에 대해:
   - 최근에 **실제로 쓴 적 있나?** 오래 안 쓰고 앞으로도 안 쓸 것 → 사용자에게 정리 제안.
   - `SKILL.md` frontmatter(`name`·`description`)가 **멀쩡한가?**
   - 안내한 **명령·경로·도구가 아직 유효한가?**(바뀐 건 실제로 확인) 깨진 참조는 고칩니다.
   - **스킬 목록과 실제 폴더가 맞나?** 스킬끼리 건 링크(`../<이름>/SKILL.md`)와 `CLAUDE.md` 가 열거한 목록이 실제 `skills/` 폴더와 어긋난 곳을 찾습니다.
2. **스킬끼리 겹치지 않나** 봅니다. 거의 같은 일을 하는 둘 → 하나로 합치자고 제안.
3. **settings.json 점검** — 권한이 지금 방식에 맞나. JSON 유효성 확인. (기본은 "가급적 허용".)
   막고 싶은 게 있으면 지침 텍스트가 아니라 `deny`/`ask` 에 넣고, 아래 절대로 **실제로 막히는지** 봅니다.
4. **훅이 실제로 발화하는지 확인합니다** — 아래 별도 절. **파일이 있는 것과 도는 것은 다릅니다.**
5. **Claude ↔ Codex 동기화** — 이게 핵심입니다:
   - `~/.claude/CLAUDE.md` 와 `~/.codex/AGENTS.md` 내용이 같은가(심링크면 자동, 복사본이면 맞춤).
   - Codex도 같은 스킬·규칙을 참조하도록 필요한 파일이 양쪽에 있는가.
   - 어긋나면 **한쪽을 정본으로 정해** 맞추고, 무엇을 맞췄는지 보고합니다.
6. **외부 에이전트 CLI 설치 점검** — 위임하는 도구가 실제로 깔려 있나. 넷을 다 봅니다:

   | CLI | 확인 | 없으면 |
   |---|---|---|
   | Claude Code | `command -v claude` | `npm i -g @anthropic-ai/claude-code` |
   | Codex | `command -v codex` | `npm i -g @openai/codex` |
   | opencode | `command -v opencode` | `curl -fsSL https://opencode.ai/install \| bash` (npm 아님) |
   | Gemini | `command -v gemini` | `npm i -g @google/gemini-cli` |

   🔴 **깔린 것과 로그인된 것은 다릅니다.** 셋 다 인증이 따로이고, 안 하면 Paseo 의 provider 목록에
   `Not installed` 가 아니라 **`Error`** 로 뜹니다 — 그 차이가 곧 진단입니다.
   설치·인증 세부는 [`codex`](../codex/SKILL.md)·[`gemini`](../gemini/SKILL.md) 스킬이 정본이고,
   API 키는 `bws` 금고로만 넣습니다.
6a. **배포본과 대조 — 내 하네스가 낡지 않았나.** 위 1~6은 *지금 있는 것*이 성한지만 봅니다.
   **없는 것은 못 봅니다.** 새 스킬이 추가돼도 내 박스에는 그냥 안 생기고, 그 사실을 알려 주는
   장치가 없습니다.
   - 최신 하네스 안내(수강생 공지)를 열어 **스킬 목록과 내 `~/.claude/skills/` 를 이름으로 대조**합니다.
   - 🔴 **개수로 판정하지 마세요.** 설치기는 덮어쓸 뿐 지우지 않아서, 내가 만든 스킬이 하나라도 있으면
     개수는 항상 통과합니다. **이름 집합**을 비교해야 빠진 것이 보입니다.
   - 빠진 것이 있으면 하네스를 다시 받습니다. ⚠️ 그 전에 `~/.claude/skills.bak.tar` 가 이미 있는지
     보세요 — 있으면 그게 원본이니 덮지 말고, 지금 스킬을 **날짜 붙인 다른 이름**으로 따로 보관한 뒤
     진행합니다. 내가 고쳐 쓰던 스킬·지침이 있으면 덮기 전에 사용자에게 확인받습니다.
7. **바꾸기 전 사용자 확인.** 스킬 삭제·병합·경로 수정, 설치는 요약해 승인받고 진행합니다.

## 🔴 훅 점검 — "파일이 있다"가 아니라 "실제로 발화한다"

훅은 **조용히 죽습니다.** 실행 권한이 없거나, 경로가 끊긴 심링크거나, 등록만 되고 파일이 없어도
**에러 없이 그냥 안 돕니다.** JSON 유효성까지만 보고 통과시키면 그 상태를 정상으로 넘기게 됩니다.
**직접 실행해서** 확인하세요 — 훅은 표준입력으로 JSON 을 받으므로 흉내낼 수 있습니다.

이 하네스가 설치하는 훅은 셋입니다 — `secret-guard.sh`(Write/Edit 전 시크릿 차단) ·
`session-close-reminder.sh`(Stop/PreCompact 상기) · `session-start-restore.sh`(SessionStart 로그 복원).
`settings.json` 의 `hooks` 에 적힌 경로가 셋 다 **존재하고 실행권한이 있는지** 먼저 봅니다.

```bash
ls -lL ~/.claude/hooks/*.sh      # -L 이라야 끊긴 심링크가 드러납니다. x 권한도 함께 확인

# 차단 훅: 가짜 키를 물려 exit 2(차단) 가 나오는지 — 안 나오면 가드가 죽은 것
printf '%s' '{"tool_input":{"file_path":"/tmp/probe.py","content":"k=\"sk-AAAAAAAAAAAAAAAAAAAAAAAA\""}}' \
  | ~/.claude/hooks/secret-guard.sh; echo "exit=$?"    # 기대: 🔒 메시지 + exit=2

echo '{}' | ~/.claude/hooks/session-close-reminder.sh; echo "exit=$?"   # 기대: 📌 문구 + exit=0
echo '{}' | ~/.claude/hooks/session-start-restore.sh;  echo "exit=$?"   # 기대: exit=0
```

**막는 설정도 같은 방식으로.** `deny` 에 넣었으면 실제로 그 명령을 시켜 보고 **막히는지** 확인합니다 —
규칙이 적혀 있다는 사실은 아무것도 보장하지 않습니다.

## 하지 말 것

- 사용자가 **직접 만든 스킬**을 "안 쓰는 것 같다"고 함부로 지우지 않습니다 — 제안만.
- 확인 없이 권한을 **더 조이지** 않습니다(이 하네스 기본은 허용 지향).
- 훅을 **"파일 있음 = 정상"** 으로 넘기지 않습니다. 실행 결과를 못 봤으면 "미확인"이라고 적습니다.

## 출력

```
스킬: N개 (정상 … / 깨짐 … / 안 씀 … / 중복 … / 링크만 있고 폴더 없음 …)
settings.json: 유효 ✔ · deny 실측 (막힘 ✔ / 안 막힘 …)
훅: secret-guard 발화 ✔(exit 2) · close-reminder ✔ · start-restore ✔  (실행권한·경로 확인)
Claude↔Codex 동기화: OK / 맞춤(…)
제안: …
```
