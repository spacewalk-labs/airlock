#!/usr/bin/env bash
# Stop / PreCompact — worklog·session-close 없이 끝나려 하면 상기(비차단).
# 최근 10분 내 WORKLOG.md 변경이 있으면 이미 남긴 것으로 보고 조용히 통과.
set -uo pipefail
recent=""
for f in WORKLOG.md ./*/WORKLOG.md; do
  [ -f "$f" ] || continue
  if find "$f" -mmin -10 2>/dev/null | grep -q .; then recent=1; break; fi
done
if [ -z "$recent" ]; then
  echo "📌 마무리 전 점검: 오늘 한 일을 worklog에 남기고 session-close로 정리했나요? 아직이면 지금 하세요."
fi
exit 0
