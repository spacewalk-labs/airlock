#!/usr/bin/env bash
# SessionStart — 최근 작업 로그를 불러와 이어받게 한다(출력이 세션 맥락에 실림).
set -uo pipefail
f="WORKLOG.md"
if [ -f "$f" ]; then
  echo "### 최근 작업 로그 ($f) — 이어서 진행 참고"
  tail -n 40 "$f"
fi
exit 0
