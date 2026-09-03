#!/usr/bin/env bash
# Root-owned pkexec target. Trusted bundle coordinates come only from root-owned config;
# the unprivileged GUI supplies one bounded JSON request over stdin.
set -euo pipefail

CONFIG=/etc/airlock-gui-installer.json
say() { printf '[airlock-gui-entrypoint] %s\n' "$*" >&2; }
failure_emitted=0
fail() {
  failure_emitted=1
  CODE="$1" MESSAGE="$2" REMEDY="$3" LOG_REF="${4:-}" python3 - <<'PY'
import json, os
doc = {"event": "failed", "schema": "airlock.gui-progress/v1", "code": os.environ["CODE"],
       "message": os.environ["MESSAGE"], "remedy": os.environ["REMEDY"]}
if os.environ.get("LOG_REF"):
    doc["log"] = os.environ["LOG_REF"]
print(json.dumps(doc, ensure_ascii=False, sort_keys=True), flush=True)
PY
  say "$1: $2"
  exit 1
}
unexpected_failure() {
  local rc="$1"
  trap - ERR
  if [ "$failure_emitted" = 0 ]; then
    fail helper-failed "설치 준비 작업이 예기치 않게 멈췄습니다." "기기를 다시 시작한 뒤 다시 시도해 주세요."
  fi
  exit "$rc"
}
trap 'unexpected_failure $?' ERR

trusted_file() {
  python3 - "$1" <<'PY'
import os, pathlib, stat, sys
path = pathlib.Path(sys.argv[1])
if not path.is_absolute():
    raise SystemExit("trusted path is not absolute")
current = pathlib.Path("/")
for part in path.parts[1:]:
    current /= part
    info = current.lstat()
    if stat.S_ISLNK(info.st_mode):
        raise SystemExit(f"trusted path contains a symlink: {current}")
    if info.st_uid != 0 or info.st_mode & 0o022:
        raise SystemExit(f"trusted path has unsafe owner or mode: {current}")
if not stat.S_ISREG(path.stat().st_mode):
    raise SystemExit("trusted path is not a regular file")
PY
}

[ "$(id -u)" = 0 ] || fail privilege-required "관리자 권한을 받지 못했습니다." "암호 창을 취소했다면 다시 시도해 주세요."
[ "$#" = 0 ] || fail invalid-invocation "설치 프로그램 호출이 올바르지 않습니다." "바탕화면의 Airlock 설치 아이콘을 다시 열어 주세요."
if ! trusted_file "$CONFIG"; then
  fail installer-damaged "설치 설정을 찾을 수 없습니다." "설치 USB를 다시 만들어 주세요."
fi

request="$(mktemp /run/airlock-gui-request.XXXXXX)" \
  || fail temporary-file "설치 입력을 안전하게 보관하지 못했습니다." "기기를 다시 시작한 뒤 재시도해 주세요."
selection="$(mktemp /run/airlock-gui-selection.XXXXXX)" \
  || { rm -f "$request"; fail temporary-file "설치 입력을 안전하게 보관하지 못했습니다." "기기를 다시 시작한 뒤 재시도해 주세요."; }
cleanup() { rm -f "$request" "$selection"; }
trap cleanup EXIT
chmod 0600 "$request" "$selection"

# 64 KiB is ample for the catalog and prevents an unbounded stdin write as root.
dd bs=65537 count=1 of="$request" status=none
[ "$(wc -c < "$request")" -le 65536 ] \
  || fail invalid-selection "선택한 앱 목록이 너무 큽니다." "창을 닫고 다시 열어 주세요."

if ! parsed="$({ CONFIG="$CONFIG" REQUEST="$request" SELECTION="$selection" python3 - <<'PY'
import json, os, pathlib, re
cfg_path = pathlib.Path(os.environ["CONFIG"])
req_path = pathlib.Path(os.environ["REQUEST"])
cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
req = json.loads(req_path.read_text(encoding="utf-8"))
if cfg.get("schema") != "airlock.gui-installer-config/v1":
    raise SystemExit("bad installer config schema")
if set(req) != {"schema", "hostname", "selected_optional_apps"}:
    raise SystemExit("bad request keys")
if req.get("schema") != "airlock.gui-install-request/v1":
    raise SystemExit("bad selection schema")
hostname = req.get("hostname")
selected = req.get("selected_optional_apps")
if not isinstance(hostname, str) or re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", hostname) is None:
    raise SystemExit("bad hostname")
if not isinstance(selected, list) or any(not isinstance(x, str) for x in selected):
    raise SystemExit("bad selected app list")
if len(selected) != len(set(selected)):
    raise SystemExit("duplicate selected app")
for field in ("bundle", "bundle_sha256", "expected_tailnet", "provisioner"):
    if not isinstance(cfg.get(field), str) or not cfg[field]:
        raise SystemExit("missing installer config field: " + field)
pathlib.Path(os.environ["SELECTION"]).write_text(
    json.dumps({"schema": "airlock.gui-selection/v1", "selected_optional_apps": selected}, sort_keys=True) + "\n",
    encoding="utf-8",
)
print(cfg["bundle"])
print(cfg["bundle_sha256"])
print(cfg["expected_tailnet"])
print(cfg["provisioner"])
print(hostname)
PY
} 2>&1)"; then
  say "request/config validation failed: $parsed"
  fail invalid-selection "선택한 앱이나 기기 이름을 읽지 못했습니다." "입력을 확인하고 다시 시도해 주세요."
fi

bundle="$(printf '%s\n' "$parsed" | sed -n '1p')"
bundle_sha="$(printf '%s\n' "$parsed" | sed -n '2p')"
tailnet="$(printf '%s\n' "$parsed" | sed -n '3p')"
provisioner="$(printf '%s\n' "$parsed" | sed -n '4p')"
hostname="$(printf '%s\n' "$parsed" | sed -n '5p')"
for path in "$bundle" "$provisioner"; do
  if ! trusted_file "$path"; then
    fail installer-damaged "설치 파일 일부가 없거나 안전하지 않습니다." "설치 USB를 다시 만들어 주세요."
  fi
done
case "$bundle_sha" in *[!0-9a-f]*|'') fail installer-damaged "설치 파일 해시가 올바르지 않습니다." "설치 USB를 다시 만들어 주세요." ;; esac
[ "${#bundle_sha}" = 64 ] || fail installer-damaged "설치 파일 해시 길이가 올바르지 않습니다." "설치 USB를 다시 만들어 주세요."

export AIRLOCK_GUI_BUNDLE="$bundle"
export AIRLOCK_GUI_BUNDLE_SHA256="$bundle_sha"
export AIRLOCK_GUI_EXPECTED_TAILNET="$tailnet"
export AIRLOCK_GUI_HOSTNAME="$hostname"
export AIRLOCK_GUI_SELECTION_FILE="$selection"
exec bash "$provisioner"
