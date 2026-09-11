#!/usr/bin/env bash
# Boolean-only systemd loader check shared by installer/smoke. No secret output.
devmon_secret_nonempty() {
  local file="$1" name="$2"
  python3 "$(dirname "${BASH_SOURCE[0]}")/backend/devmon_secret_names.py" "$name" || return 2
  [ -f "$file" ] && [ -r "$file" ] || return 1
  python3 "$(dirname "${BASH_SOURCE[0]}")/check-secrets.py" --file "$file" "$name"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  devmon_secret_nonempty "$1" "$2"
fi
