#!/usr/bin/env bash
# Mode 644, not 755: the orchestrator runs this with `bash <path>` (install/airlock-install.sh, bin/airlock-smoke), so the executable bit
# does nothing — and the cutline policy refuses a NEW 755 file. Older apps
# carry 755 because they predate that rule, not because they need it.
# learning deactivate — no app-specific stop step. The ledger's generic "units"
# class stops/disables/deletes airlock-learning.service and
# airlock-learning-ingest.service; "fragments" removes the nginx fragment and
# "files" removes ~/.local/share/airlock-learning/.
#
# Deliberately NOT declared, therefore never touched: the library folder (the
# user's documents) and ~/.local/state/airlock-learning/ (ingest history and
# logs). Deactivating an app must not be a way to lose what you wrote.
# The one thing the generic classes cannot express: the ingest skill is a SYMLINK we
# planted in the user's own skill directories, and `files` only removes paths under our
# share dir. Removing the link here — and only when it is still ours — keeps a dangling
# `learning-ingest` out of every agent CLI's skill list after the app is gone.
set -euo pipefail

APP_DIR_LOCAL="$HOME/.local/share/airlock-learning"
# 🔴 자리는 install.sh 와 **같은 곳**에서 온다. 여기에 손으로 적으면 제공자를 하나 더
# 붙였을 때 설치는 세 군데에 걸고 해제는 두 군데만 지운다 — 남은 하나는 공유 디렉터리가
# 사라진 뒤 끊어진 링크로 그 CLI 의 스킬 목록에 계속 뜬다.
SKILL_ROOTS="$(python3 "$APP_DIR_LOCAL/backend/providers.py" --skill-roots 2>/dev/null || true)"
[ -n "$SKILL_ROOTS" ] || SKILL_ROOTS="$HOME/.claude/skills
$HOME/.agents/skills"
while IFS= read -r root; do
  [ -n "$root" ] || continue
  target="$root/learning-ingest"
  # 🔴 우리 링크만. 사용자의 진짜 스킬이나 다른 곳을 가리키는 링크는 남긴다 — 앱을 끄는
  # 것은 그 앱이 만들지 않은 파일을 지울 권한이 아니다. 비교는 문자열이 아니라 realpath 로
  # 한다(후행 슬래시나 상대경로 철자 하나로 "남의 것" 이 되면 끊어진 링크가 남는다).
  if [ -L "$target" ] \
     && [ "$(readlink -f "$target" 2>/dev/null)" = "$(readlink -f "$APP_DIR_LOCAL/skill" 2>/dev/null)" ] \
     && [ -n "$(readlink -f "$APP_DIR_LOCAL/skill" 2>/dev/null)" ]; then
    rm -f "$target"
    echo "[airlock] removed ingest skill link: $target"
  fi
done <<EOF
$SKILL_ROOTS
EOF
exit 0
