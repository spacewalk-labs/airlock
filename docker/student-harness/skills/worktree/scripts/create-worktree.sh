#!/usr/bin/env bash
# create-worktree.sh <슬러그> [--base <기준브랜치>]
#
# 새 일 하나를 위한 격리 작업 폴더(git worktree)를 규약대로 만듭니다.
#   본진   = ~/workspace/<레포이름>   (항상 기본 브랜치로 둡니다)
#   새 폴더 = ~/workspace/<슬러그>     (브랜치 이름도 <슬러그>)
#   기준   = origin/<기본브랜치>       (뜨기 전에 항상 fetch)
# 원칙: 일 하나 = 워크트리 하나 = PR 하나.
#
# 안전: 이미 있는 폴더·이미 있는 브랜치는 절대 덮어쓰지 않습니다(남의 작업일 수 있습니다).
#       전제가 하나라도 어긋나면 아무것도 만들지 않고 멈춥니다.
#
# 종료 코드: 0 만들었음 / 2 사용법·전제 위반(아무것도 안 만듦) / 1 실행 오류
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
사용법: create-worktree.sh <슬러그> [--base <기준브랜치>]

  <슬러그>          소문자·숫자·하이픈. 폴더 이름이자 브랜치 이름이 됩니다 (예: login-fix).
  --base <브랜치>   기준 브랜치. 생략하면 origin 의 기본 브랜치를 자동으로 찾습니다.

  본진 레포 안에서 실행하세요. 새 폴더는 본진과 나란히 생깁니다.
  예) cd ~/workspace/myapp && create-worktree.sh login-fix
      → ~/workspace/login-fix (브랜치 login-fix, origin/<기본브랜치> 기준)
EOF
}

die()  { echo "오류: $*" >&2; exit 1; }
stop() { echo "중단: $*" >&2; exit 2; }
dup()  { echo "오류: $1 하나만 지정합니다 ($2, $3)." >&2; usage; exit 2; }

# ── 인자 ─────────────────────────────────────────────────────────────────────
slug=""
base_branch=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --base)
      [ $# -ge 2 ] || { echo "오류: --base 뒤에 브랜치 이름이 필요합니다." >&2; usage; exit 2; }
      [ -z "$base_branch" ] || dup "--base 옵션은" "$base_branch" "$2"
      base_branch="$2"; shift 2 ;;
    --) shift
        [ $# -eq 1 ] || { usage; exit 2; }
        [ -z "$slug" ] || dup "슬러그는" "$slug" "$1"
        slug="$1"; shift ;;
    -*) echo "오류: 모르는 옵션입니다: $1" >&2; usage; exit 2 ;;
    *)  [ -z "$slug" ] || dup "슬러그는" "$slug" "$1"
        slug="$1"; shift ;;
  esac
done

[ -n "$slug" ] || { usage; exit 2; }
printf '%s' "$slug" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' \
  || stop "슬러그는 소문자·숫자·하이픈만 씁니다(하이픈으로 시작·끝 X): '$slug'"

# ── 본진 찾기 ────────────────────────────────────────────────────────────────
top=$(git rev-parse --show-toplevel 2>/dev/null) \
  || stop "여기는 git 레포가 아닙니다. 본진(~/workspace/<레포>)에서 실행하세요."
common=$(git -C "$top" rev-parse --git-common-dir)
case "$common" in /*) ;; *) common="$top/$common" ;; esac
[ "$(basename "$common")" = ".git" ] || stop "일반 클론이 아닙니다($common). 이 스크립트는 bare 레포를 다루지 않습니다."
main=$(cd "$common/.." && pwd -P)
repo_name=$(basename "$main")

wt="$(dirname "$main")/$slug"
[ "$slug" != "$repo_name" ] || stop "슬러그가 레포 이름과 같습니다($repo_name). 본진 폴더와 겹치므로 다른 이름을 쓰세요."
# -L 까지 보는 이유: 깨진 심링크는 -e 로 안 잡히는데 git 은 '이미 있다'며 실패합니다.
if [ -e "$wt" ] || [ -L "$wt" ]; then
  stop "이미 있습니다: $wt — 남의 작업일 수 있으니 덮어쓰지 않습니다. 다른 슬러그를 쓰세요."
fi

# ── 기준 브랜치 ──────────────────────────────────────────────────────────────
git -C "$main" remote get-url origin >/dev/null 2>&1 \
  || stop "origin 원격이 없습니다. 먼저 원격을 연결하세요(repo-bootstrap 스킬)."

if [ -z "$base_branch" ]; then
  base_branch=$(git -C "$main" ls-remote --symref origin HEAD 2>/dev/null \
                | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }') || base_branch=""
fi
if [ -z "$base_branch" ]; then
  base_branch=$(git -C "$main" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
                | sed 's#^origin/##') || base_branch=""
fi
[ -n "$base_branch" ] || stop "origin 의 기본 브랜치를 찾지 못했습니다. --base <브랜치> 로 직접 지정하세요."
base_branch="${base_branch#origin/}"

# ── 이미 있는 브랜치는 건드리지 않습니다 ─────────────────────────────────────
if git -C "$main" show-ref --verify --quiet "refs/heads/$slug"; then
  stop "로컬 브랜치 '$slug' 가 이미 있습니다. 진행 중인 다른 일일 수 있으니 다른 슬러그를 쓰세요.
       (폴더만 지운 잔재라면 본진에서 'git worktree prune' 으로 목록을 정리한 뒤 판단하세요.)"
fi
# ls-remote 의 패턴은 꼬리 일치라 'x' 가 'feat/x' 에도 걸립니다 — 정확히 같은 ref 만 봅니다.
remote_hit=$(git -C "$main" ls-remote --heads origin "$slug" 2>/dev/null \
             | awk -v r="refs/heads/$slug" '$2 == r { print $1; exit }') || remote_hit=""
[ -z "$remote_hit" ] || stop "원격 브랜치 'origin/$slug' 가 이미 있습니다. 다른 슬러그를 쓰세요."

# ── 낡은 기준 위에 뜨지 않기 ─────────────────────────────────────────────────
git -C "$main" fetch --quiet origin \
  || stop "git fetch 실패 — 네트워크를 확인하세요. 낡은 기준 위에 뜨면 남의 수정을 되돌리는 PR 이 되므로 여기서 멈춥니다."

base_ref="origin/$base_branch"
base_oid=$(git -C "$main" rev-parse --verify --quiet "refs/remotes/$base_ref") \
  || stop "기준 브랜치 '$base_ref' 를 찾지 못했습니다. --base 로 올바른 이름을 지정하세요."

# ── 만들기 ───────────────────────────────────────────────────────────────────
# --no-track 을 붙이는 이유: 안 붙이면 새 브랜치의 upstream 이 origin/<기본브랜치> 로 잡혀,
# 나중에 'git push' 가 "이름이 다르다"며 **'git push origin HEAD:<기본브랜치>'** 를 첫 번째로
# 제안합니다 — git 이 기본 브랜치 직접 push 를 권하는 셈입니다(ship 스킬은 언제나 PR 을 거칩니다).
# --no-track 이면 upstream 이 비어 'git push --set-upstream origin <슬러그>' 를 제안합니다.
if ! git -C "$main" worktree add --no-track "$wt" -b "$slug" "$base_ref" >/dev/null; then
  # 폴더는 못 만들었는데 브랜치만 남으면 그 슬러그가 영영 막힙니다 — 갓 만든 것만 되돌립니다.
  made=$(git -C "$main" rev-parse --verify --quiet "refs/heads/$slug") || made=""
  if [ -n "$made" ] && [ "$made" = "$base_oid" ]; then
    git -C "$main" branch -D "$slug" >/dev/null 2>&1 || true
  fi
  die "워크트리 생성에 실패했습니다."
fi

# 깃에 없는(.gitignore 된) 루트 설정 파일은 따라오지 않습니다 — 안내만 하고 자동 복사는 안 합니다.
hint_lines=""
for f in "$main"/.env "$main"/.env.*; do
  [ -f "$f" ] || continue
  git -C "$main" check-ignore -q -- "$f" || continue
  hint_lines="${hint_lines}      cp \"$f\" \"$wt/\"
"
done

echo "만들었습니다: $wt"
echo "  브랜치 $slug · 기준 $base_ref · 본진 $main"
echo "  cd \"$wt\"   ← 여기서 작업하세요. 본진은 기본 브랜치 그대로 둡니다."
if [ -n "$hint_lines" ]; then
  echo "  깃에 없는 파일은 따라오지 않습니다. 필요하면 손으로 복사하고 worklog 에 적어 두세요:"
  printf '%s' "$hint_lines"
fi
echo "  끝나면 ship 스킬로 커밋 → PR → 머지 → 회수."
