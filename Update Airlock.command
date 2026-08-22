#!/bin/bash
# "Update Airlock.command" — the double-clickable form of bin/airlock-update.
#
# A .command file is what macOS opens in Terminal on a double-click, and it is here
# rather than in a downloadable app for one reason: it arrives inside the checkout, by
# git. Gatekeeper's quarantine attribute is set by the thing that DOWNLOADS a file — a
# browser, a mail client — so a file that got here through `git fetch` carries none,
# and double-clicking it just runs. That is what lets an update work with no signing
# identity, no notarisation, and no installer.
#
# The one thing this file must not do is grow logic. It is the front door for people
# who do not open terminals; everything that can be wrong belongs in bin/airlock-update
# where it can be tested on Linux (install/test-update.sh).
cd "$(dirname "$0")" || exit 1

bash bin/airlock-update "$@"
status=$?

echo
if [ "$status" = 0 ]; then
  echo "끝났습니다. 이 창은 닫으셔도 됩니다."
else
  echo "업데이트가 끝나지 못했습니다 (코드 $status)."
  echo "위에 빨간 글씨로 이유가 적혀 있습니다. 그 줄을 그대로 복사해 알려 주세요."
fi
# Terminal is configured per-profile to close on exit or not, so neither behaviour can
# be assumed. Holding the window here means the message above is readable either way.
echo
read -r -p "확인하셨으면 Enter 를 누르세요. " _
exit "$status"
