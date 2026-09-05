#!/usr/bin/env bash
# retire-worktree.sh <워크트리경로>
#
# 일이 끝난 워크트리를 안전하게 회수합니다(폴더 + 로컬 브랜치 + 원격 브랜치).
# 아래를 모두 통과할 때만 지웁니다 — 하나라도 어긋나면 **아무것도 지우지 않고** 사유만 냅니다.
#   ① 커밋하지 않은 변경(추적 안 된 새 파일 포함)이 없다   ② 지금 그 폴더 안에 서 있지 않다
#   ③ 본진 클론이 아니고, 기본 브랜치를 잡고 있지도 않다   ④ 이 본진에 등록된 워크트리다
#   ⑤ 머지된 것이 확인된다 — 기본 브랜치의 조상이거나, 머지된 PR 의 최종 커밋과 일치
#
# 🔴 squash 머지는 커밋 해시를 새로 만들어 조상 관계가 끊깁니다(ship 스킬이 squash 를 씁니다).
#    그래서 조상 관계가 아니면 PR 상태(gh)로 한 번 더 봅니다. 둘 다 아니면 회수하지 않습니다.
# 🔴 --force 는 쓰지 않습니다. 확신이 없으면 지우는 대신 보고합니다.
# ⚠️ 회수 대상은 **인자로 지목한 폴더 하나**입니다. 스크립트는 누가 만들었는지 알지 못하므로,
#    내가 만든 워크트리만 지목하세요. 깃이 무시(.gitignore)하는 파일(.env·내려받은 데이터 등)은
#    폴더와 함께 사라집니다 — **묻지 않고 지우고, 지운 목록을 사후에 출력합니다.** 남길 것이
#    있으면 실행 **전에** `git -C <워크트리> status --ignored` 로 보고 먼저 옮기세요.
#
# 종료 코드: 0 회수 완료 / 2 회수하지 않음(사유 출력) / 1 오류 또는 부분 완료(뒷정리 남음)
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
사용법: retire-worktree.sh <워크트리경로>

  예) cd ~/workspace/myapp && retire-worktree.sh ../login-fix

  회수할 워크트리 폴더를 직접 지목합니다 — 내가 만든 것만 지목하세요.
  지울 폴더 안에 서 있으면 안 됩니다. 먼저 본진으로 나오세요.
EOF
}

die()  { echo "오류: $*" >&2; exit 1; }
stop() { echo "회수 안 함: $*"; exit 2; }

case "${1-}" in
  -h|--help) usage; exit 0 ;;
  -*) echo "오류: 모르는 옵션입니다: $1" >&2; usage; exit 2 ;;
esac
[ $# -eq 1 ] || { usage; exit 2; }

target="$1"
[ -d "$target" ] \
  || die "그런 폴더가 없습니다: $target
       (폴더를 이미 지웠다면 본진에서 'git worktree prune' 으로 목록을 정리하세요.)"
wt=$(cd "$target" && pwd -P)

git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "git 워크트리가 아닙니다: $wt"

# ── 본진 찾기 ────────────────────────────────────────────────────────────────
common=$(git -C "$wt" rev-parse --git-common-dir)
case "$common" in /*) ;; *) common="$wt/$common" ;; esac
[ "$(basename "$common")" = ".git" ] || die "일반 클론이 아닙니다($common). 이 스크립트는 bare 레포를 다루지 않습니다."
main=$(cd "$common/.." && pwd -P)

[ "$wt" != "$main" ] || stop "여기는 본진 클론입니다($main). 본진은 회수 대상이 아닙니다."

wt_list=$(git -C "$main" worktree list --porcelain)
printf '%s\n' "$wt_list" | grep -qxF "worktree $wt" \
  || stop "$wt 는 본진($main)의 워크트리 목록에 없습니다. 워크트리 자체가 아니라 그 하위 폴더를 지정했을 수 있습니다."

here=$(pwd -P)
case "$here" in
  "$wt"|"$wt"/*) stop "지금 이 폴더 안에 서 있습니다. 먼저 'cd \"$main\"' 한 뒤 다시 실행하세요." ;;
esac

# ── ① 커밋하지 않은 변경 ─────────────────────────────────────────────────────
# --untracked-files=normal 을 명시하는 이유: status.showUntrackedFiles=no 설정이 있으면
# 추적 안 된 파일이 목록에서 사라져, 이 가드와 git 자체 가드가 **동시에** 뚫립니다.
# (짧은 형태 '-u normal' 은 normal 을 경로로 읽어 버립니다 — 반드시 '=' 형태로 씁니다.)
dirty=$(git -C "$wt" status --porcelain --untracked-files=normal)
if [ -n "$dirty" ]; then
  echo "회수 안 함: 커밋하지 않은 변경이 있습니다 — 지우면 되돌릴 수 없습니다."
  printf '%s\n' "$dirty" | sed -n '1,20p'
  echo "  먼저 커밋하거나(ship 스킬) 정리한 뒤 다시 실행하세요."
  exit 2
fi

branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD)
[ "$branch" != "HEAD" ] || stop "detached HEAD 라 어느 브랜치인지 알 수 없습니다 — 사람이 확인하세요."
head_oid=$(git -C "$wt" rev-parse HEAD)
head_short=$(git -C "$wt" rev-parse --short HEAD)

# ── ⑤ 머지 판정 ──────────────────────────────────────────────────────────────
def=$(git -C "$wt" ls-remote --symref origin HEAD 2>/dev/null \
      | awk '/^ref:/ { sub("refs/heads/", "", $2); print $2; exit }') || def=""
if [ -z "$def" ]; then
  def=$(git -C "$wt" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##') || def=""
fi
[ -n "$def" ] || stop "기본 브랜치를 알 수 없습니다(원격 조회 실패). 머지 여부를 판정할 수 없어 그대로 둡니다."

# ③ 기본 브랜치를 잡은 워크트리는 회수 대상이 아닙니다(브랜치까지 지워집니다).
[ "$branch" != "$def" ] || stop "이 워크트리는 기본 브랜치($def)를 잡고 있습니다. 회수 대상이 아닙니다."

git -C "$wt" fetch --quiet origin "$def" \
  || stop "origin/$def 를 받아오지 못했습니다(네트워크?). 머지 여부를 판정할 수 없어 그대로 둡니다."

merged=no
how=""
if git -C "$wt" merge-base --is-ancestor HEAD FETCH_HEAD 2>/dev/null; then
  merged=yes; how="$def 의 조상"
fi
gh_state=none
if [ "$merged" = no ] && command -v gh >/dev/null 2>&1; then
  if pr_oid=$(cd "$wt" && gh pr list --head "$branch" --state merged \
                --json headRefOid --jq '.[0].headRefOid' 2>/dev/null); then
    gh_state=ok
    if [ -n "$pr_oid" ] && [ "$pr_oid" = "$head_oid" ]; then
      merged=yes; how="머지된 PR 의 최종 커밋과 일치(squash 머지)"
    fi
  else
    gh_state=failed   # 로그인 안 됨·원격이 GitHub 아님 등 — '머지 안 됨'과 구분한다
  fi
fi

if [ "$merged" = no ]; then
  echo "회수 안 함: 머지된 증거가 없습니다 (브랜치 $branch @ $head_short)."
  echo "  · 기본 브랜치($def)의 조상이 아닙니다."
  case "$gh_state" in
    ok)     echo "  · 머지된 PR 도 찾지 못했습니다." ;;
    failed) echo "  · gh 실행이 실패했습니다(로그인 안 됨·GitHub 원격 아님 등) — PR 상태를 확인하지 못했습니다." ;;
    none)   echo "  · gh 명령이 없어 PR 상태를 못 봤습니다 — squash 머지는 PR 로만 판정됩니다." ;;
  esac
  echo "  아직 안 보냈으면 ship 스킬로 PR 을 내고, 머지된 뒤 다시 실행하세요."
  exit 2
fi

# ── 회수 ─────────────────────────────────────────────────────────────────────
# 깃이 무시하는 파일은 status 에 안 나오지만 폴더와 함께 사라집니다 — 지우기 전에 목록을 받아 두고,
# 지운 **뒤에** 무엇이 없어졌는지 알립니다. 여기서 멈춰 물어보지는 않습니다(위 헤더 ⚠️ 참고).
# 실패를 삼키지 않습니다(|| ignored="" 금지) — 목록을 못 읽었는데 지우면 무엇이 없어졌는지
# 영영 말해 줄 수 없습니다. set -e·pipefail 이 지우기 전에 멈춥니다.
ignored=$(git -C "$wt" status --porcelain --ignored --untracked-files=normal | sed -n 's/^!! //p')

git -C "$main" worktree remove "$wt" || die "워크트리 제거에 실패했습니다: $wt"
echo "회수 완료: $wt"
echo "  브랜치 $branch · 근거: $how"
if [ -n "$ignored" ]; then
  n_ignored=$(printf '%s\n' "$ignored" | wc -l)
  echo "  알림: 깃이 무시하던 아래 항목이 폴더와 함께 방금 삭제됐습니다:"
  printf '%s\n' "$ignored" | sed -n '1,10p' | sed 's/^/      /'
  [ "$n_ignored" -le 10 ] || echo "      … 외 $((n_ignored - 10))개"
fi

leftover=0
cur=$(git -C "$main" rev-parse --verify --quiet "refs/heads/$branch") || cur=""
if [ -z "$cur" ]; then
  echo "  로컬 브랜치 $branch: 이미 없습니다."
elif [ "$cur" != "$head_oid" ]; then
  echo "  로컬 브랜치 $branch: 판정 이후 다른 커밋으로 움직였습니다 — 지우지 않고 남깁니다."
  leftover=1
else
  git -C "$main" branch -D "$branch" >/dev/null
  echo "  로컬 브랜치 $branch: 삭제(머지 확인 뒤 -D — squash 머지된 브랜치는 -d 가 거부합니다)."
fi

remote_oid=$(git -C "$main" ls-remote --heads origin "$branch" 2>/dev/null \
             | awk -v r="refs/heads/$branch" '$2 == r { print $1; exit }') || remote_oid=""
if [ -z "$remote_oid" ]; then
  echo "  원격 브랜치 origin/$branch: 이미 없습니다(머지 시 자동 삭제됐을 수 있습니다)."
elif [ "$remote_oid" != "$head_oid" ]; then
  echo "  원격 브랜치 origin/$branch: 판정 이후 움직였습니다 — 지우지 않습니다. 사람이 확인하세요."
  leftover=1
elif git -C "$main" push --quiet origin --delete "$branch"; then
  echo "  원격 브랜치 origin/$branch: 삭제."
else
  echo "  원격 브랜치 origin/$branch: 삭제 실패 — 남겨 둡니다."
  leftover=1
fi

n_stash=$(git -C "$main" stash list 2>/dev/null | grep -ci "on $branch:" || true)
[ "${n_stash:-0}" -eq 0 ] \
  || echo "  참고: 이 브랜치에서 만든 stash 가 $n_stash 개 본진에 남아 있습니다 ('git stash list' 로 확인)."

if [ "$leftover" -ne 0 ]; then
  echo "  🔴 뒷정리가 일부 남았습니다 — 위 항목을 사람이 확인하세요."
  exit 1
fi
exit 0
