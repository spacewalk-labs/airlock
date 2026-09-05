---
name: codex
description: 2차 구현·코드 리뷰·막혔을 때 OpenAI Codex CLI에 위임한다. 설치·인증·호출법(codex exec)·결과 회수. AGENTS.md를 공유해 같은 규칙으로 일하게 한다.
---

# Codex에 위임하기 (codex)

Claude가 막히거나, **다른 구현/리뷰**가 필요할 때 OpenAI Codex CLI에 맡깁니다.
**무엇을 누구에게 시킬지**는 [`subagent`](../subagent/SKILL.md)가 정본이고, 이 문서는 **부르는 법**만 다룹니다.

## 언제

- 한 방식으로 막혔을 때 **다른 구현·진단**이 필요.
- 내 변경을 **다른 모델로 교차 리뷰**.

## 설치

```bash
command -v codex >/dev/null || npm i -g @openai/codex   # 또는 brew install codex
codex --version
```

> 설치·명령은 공식 문서가 정본입니다: <https://github.com/openai/codex>

## 인증 — 둘 중 **하나만**

- **ChatGPT 계정 로그인**(첫 실행 안내) — 구독으로 씁니다. `codex login status`로 확인.
- 또는 **API 키**(`OPENAI_API_KEY` 환경변수) — 평문 금지. [`secret-manage`](../secret-manage/SKILL.md) 절차대로 금고에 넣고 `bws run -- codex …`.
- 🔴 **둘을 섞지 마세요.** 구독 로그인이 멀쩡해도 환경변수에 API 키가 남아 있으면 codex가 그쪽을 쓰고
  **쓴 만큼 종량 과금**됩니다. 구독으로 쓸 거면 `env -u OPENAI_API_KEY codex …` 로 키를 지우고 부릅니다.

## 규칙 공유 (AGENTS.md)

Codex는 **작업 디렉토리의 `AGENTS.md`** 를 자동으로 읽습니다 — 전역 `~/.codex/AGENTS.md` 뿐 아니라
**지금 일하는 레포 루트의 `AGENTS.md`** 도 함께. `CLAUDE.md`와 같은 내용을 `AGENTS.md`로 두면 Codex가
**같은 규칙**으로 일합니다. 둘의 동기화는 [`harness-gardener`](../harness-gardener/SKILL.md)가 챙깁니다.

## 부르기 (실제 호출법)

프롬프트는 **파일에 적어 stdin으로** 넘깁니다. 서브커맨드는 `codex exec` 입니다.

```bash
TAG=fix-login; mkdir -p /tmp/codex-logs
cat > /tmp/codex-$TAG.md <<'EOF'
# 로그인 실패 원인을 찾아 고쳐 주세요
## 목표       — 무엇을 왜
## 대상       — 파일 절대경로
## 하지 말 것  — 건드리면 안 되는 것
## 완료 기준   — 테스트 통과 등 확인 가능한 것
EOF

nohup env -u OPENAI_API_KEY codex exec \
  -c sandbox_mode="workspace-write" \
  -o /tmp/codex-logs/$TAG.last.md \
  - < /tmp/codex-$TAG.md > /tmp/codex-logs/$TAG.log 2>&1
```

- 🔴 **stdin을 반드시 명시하세요** — `- < 파일`(권장), 프롬프트를 인자로 줬으면 `< /dev/null`.
  **안 하면 codex가 추가 입력을 기다리며 그대로 멈춰 있습니다(hang).** 가장 흔한 함정입니다.
- 🔴 **오래 걸리는 일은 `nohup`으로 감싸세요** — 안 감싸면 셸이 끊길 때 **아무 출력 없이 조용히 죽습니다**.
  `setsid`는 쓰지 마세요 — codex가 즉시 죽습니다(실측). `-o` 파일은 화면 출력이 끊겨도 최종 답변을 건지는 보루입니다.
- **한 호출 = 한 질문**(큰 프롬프트 하나보다 좁은 호출 여러 개). **시크릿 값 금지**(이름·참조만).

## 결과 회수 — 메인이 직접 재검증

```bash
tail -3 /tmp/codex-logs/$TAG.log        # 진행 보기
cat /tmp/codex-logs/$TAG.last.md        # 최종 답변
git status --porcelain && git diff --stat
<테스트 명령>                            # 프롬프트에 넣었어도 내가 다시 돌린다
```

- 🔴 **무출력·타임아웃은 통과가 아닙니다.** 몇 분째 아무 변화가 없으면
  `pkill -f "codex.*$TAG"` 로 **그 작업만** 끊고 다시 시도하거나 직접 합니다.
- codex 말만 믿지 않습니다 — **바뀐 파일과 테스트를 내가 확인**하고, 중요하면 [`self-verify`](../self-verify/SKILL.md) 게이트까지.

## 리뷰는 2축으로

같은 변경을 **일반 시선**(정확성·가독성)과 **적대 시선**("이 변경을 깨뜨려 봐라" — 회귀·경계·에러 경로)
으로 **각각 따로** 돌리고, 종합은 내가 합니다. 둘 다 지적한 것부터 고칩니다.

- 🔴 **자기 리뷰 금지** — 구현한 쪽이 자기 결과를 리뷰하지 않습니다.
- 리뷰·조사는 `-c sandbox_mode="read-only"` 로 (파일을 못 고치게).

## 하지 말 것

- 🔴 **브랜치·커밋·push·PR을 codex에게 맡기지 마세요.** `workspace-write` 샌드박스는 `.git` 쓰기를
  차단해서 `push`·`fetch`가 `Read-only file system`으로 죽습니다. **파일 변경만 시키고**, git 작업은
  메인 세션이 [`ship`](../ship/SKILL.md)으로 합니다.
- stdin 미명시(→ hang) · 무출력을 성공으로 취급 · 한 프롬프트에 여러 질문.
