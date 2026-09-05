---
name: repo-bootstrap
description: 새 레포를 표준 구조로 만든다 — ~/workspace/<이름> 폴더, git init -b main, README·.gitignore·WORKLOG.md, 첫 커밋, 내 GitHub에 private 레포 생성·push까지. 폴더를 손으로 만들고 git init 을 직접 치지 말고 이걸 쓴다. 웹 프론트/풀스택이면 web-project-bootstrap 으로 넘긴다.
---

# 새 레포 만들기 (repo-bootstrap)

새 프로젝트를 시작할 때 **매번 다른 모양으로 만들지 않도록** 하는 표준 절차입니다.
위치·기본 브랜치·기본 파일·첫 커밋·GitHub 연결까지 **한 번에** 끝냅니다.

> 왜 표준이 필요한가: 폴더가 제자리에 없으면 **파일탐색기·마크다운뷰어·세션 복원 훅이 못 찾습니다.**
> `WORKLOG.md` 가 없으면 다음 세션이 맥락을 못 이어받습니다. `.gitignore` 가 없으면 **첫 커밋에
> 키가 딸려 들어갑니다.** 매번 손으로 하면 매번 하나씩 빠집니다.

## 먼저 — 웹이면 여기가 아닙니다

**웹 프론트/풀스택**(Next.js 계열)이면 [`web-project-bootstrap`](../web-project-bootstrap/SKILL.md)
으로 넘기세요. 회사 표준 스타터 템플릿에 CI·테스트·훅까지 들어 있어 훨씬 많이 줍니다.

이 스킬은 **그 밖의 전부** — 파이썬·데이터 분석·스크립트 모음·문서 레포·실험용 등입니다.

## 0) 이름 정하기 (사람에게 확인)

**소문자·숫자·하이픈만.** 공백·한글·대문자는 쓰지 않습니다 — 그대로 GitHub 레포 이름과 주소가 됩니다.

이름이 안 정해졌으면 **추측하지 말고 물어보세요.** 나중에 바꿀 수 있지만 옛 주소가 지저분하게 남습니다.

## 1) 🔴 상위 폴더가 레포가 아닌지 먼저 확인

**이 검사를 건너뛰지 마세요.** `~/workspace` 가 레포가 되면 형제 레포가 통째로 빨려 들어갑니다.

```bash
git -C ~/workspace rev-parse --show-toplevel 2>&1 | head -1
# → "not a git repository" 여야 정상입니다.
#   경로가 나오면 여기서 멈추고 사람에게 알리세요. 절대 그대로 진행하지 마세요.
```

## 2) 폴더 + git

```bash
NAME=<레포이름>
mkdir -p ~/workspace/"$NAME" && cd ~/workspace/"$NAME"
git init -b main
```

- 위치는 **`~/workspace/<레포이름>`** — 중간 폴더 없이 바로(하네스 폴더 표준).
- `-b main` 은 기본 브랜치를 `main` 으로 못박는 옵션입니다. 안 쓰면 `master` 가 되어 GitHub 와 어긋납니다.

## 3) 기본 파일 3개

**`.gitignore` 를 먼저 만듭니다** — 첫 커밋에 키가 딸려 들어가는 것을 막기 위해서입니다.

```gitignore
# 시크릿 — 절대 커밋하지 않습니다
.env
.env.*
!.env.example
*.pem
*.key
내정보.txt

# 런타임·빌드 산출물
__pycache__/
*.pyc
.venv/
venv/
node_modules/
dist/
build/
.DS_Store
```

`README.md` — **무엇을 왜 만드는지 3줄**이면 충분합니다. 나중에 늘립니다.

```markdown
# <레포이름>

<한 줄 설명 — 이게 무엇인가>

## 목표
- <무엇을 할 수 있게 되면 성공인가>

## 실행
<아직 없으면 "준비 중">
```

`WORKLOG.md` — [`worklog`](../worklog/SKILL.md) 이 이어 붙이고, **세션 시작 훅이 이 파일을 읽어**
지난 맥락을 되살립니다. 빈 파일이라도 만들어 둡니다.

```markdown
# 작업 로그

## <YYYY-MM-DD> — 레포 시작
- 한 일: repo-bootstrap 으로 초기 구조 생성
- 왜: <이 프로젝트를 시작한 이유>
- 다음: <첫 번째로 할 일>
```

## 4) 첫 커밋

```bash
git add -A
git commit -m "chore: 레포 초기화 (repo-bootstrap)"
```

> 💡 **첫 커밋은 그냥 형식이 아닙니다.** 커밋이 하나도 없는 레포에서는 **워크트리를 만들 수 없습니다**
> — 가지를 칠 줄기가 없기 때문입니다. 여기까지 해 둬야 다음 작업부터 워크트리로 갈 수 있습니다.

## 5) GitHub 에 private 레포 만들고 push

```bash
gh auth status                      # 로그인 안 돼 있으면 gh auth login 부터
gh repo create "$NAME" --private --source=. --remote=origin --push
```

- **기본은 `--private`.** 공개가 필요하면 **사람에게 먼저 확인**하고 바꿉니다
  (한 번 공개되면 그 사이에 노출된 것은 되돌릴 수 없습니다).
- 같은 이름이 이미 있으면 **덮어쓰지 말고 멈추고 물어보세요** — 다른 이름 / 기존 것에 연결 /
  기존 것 정리 중 무엇을 원하는지 갈립니다.

## 6) 확인 — 이 두 줄이 맞아야 끝

```bash
git rev-parse --show-toplevel       # → /home/<계정>/workspace/<레포이름>
git remote -v                       # → origin 이 내 계정의 레포를 가리킴
```

첫 줄이 `/home/<계정>/workspace` (레포 이름 없이)로 나오면 **1)의 사고가 난 것**입니다.
그 상태로 커밋하지 말고 사람에게 알리세요.

## 다음 작업부터는 워크트리

여기까지가 **본체**입니다. 본체는 `main` 에 둔 채로 두고, 실제 작업은 워크트리에서 합니다
(`CLAUDE.md` §6-2). Paseo 를 쓰면 새 작업 만들 때 **New worktree** 를 고르는 것으로 끝입니다.

## 하지 않는 것

- **`~/workspace` 자체를 레포로 만들지 않습니다.**
- 실제 키·토큰·비밀번호를 파일에 넣지 않습니다 — 값은 [`secret-manage`](../secret-manage/SKILL.md),
  파일에는 이름만 담은 `.env.example`.
- 이미 있는 폴더를 조용히 덮어쓰지 않습니다. 있으면 멈추고 물어봅니다.
