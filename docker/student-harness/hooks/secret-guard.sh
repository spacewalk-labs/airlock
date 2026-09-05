#!/usr/bin/env bash
# PreToolUse(Write|Edit) — 파일에 API 키·토큰 같은 시크릿 '값'이 들어가려 하면 차단.
# 값 자체는 절대 출력하지 않는다(어떤 종류인지만 알린다). exit 2 = 차단 + 메시지를 에이전트에 전달.
set -euo pipefail
input="$(cat)"
python3 - "$input" <<'PY'
import sys, json, re
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
ti = data.get("tool_input", {}) or {}
text = ti.get("content") or ti.get("new_string") or ""
path = ti.get("file_path", "") or ""
# 예제·템플릿·문서 파일은 통과(패턴을 설명으로 담을 수 있음)
if re.search(r'\.example|\.sample|\.md$|README', path):
    sys.exit(0)
patterns = {
    "OpenAI 키":       r"sk-[A-Za-z0-9]{20,}",
    "GitHub 토큰":     r"gh[pousr]_[A-Za-z0-9]{20,}",
    "AWS 액세스키":    r"AKIA[0-9A-Z]{16}",
    "Slack 토큰":      r"xox[baprs]-[A-Za-z0-9-]{10,}",
    "개인키(PEM)":     r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    "Bitwarden 토큰":  r"\b0\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}",
}
hits = [name for name, pat in patterns.items() if re.search(pat, text)]
if hits:
    sys.stderr.write(
        "🔒 시크릿 가드: 이 파일에 " + ", ".join(hits) + " 로 보이는 값이 있습니다.\n"
        "키·토큰 '값'은 파일에 넣지 마세요 — 금고(bws)에 두고 `bws run` 으로 주입합니다(secret-manage 스킬).\n"
        "이 쓰기는 차단되었습니다. 값을 빼고 이름/참조만 남기세요.\n")
    sys.exit(2)
sys.exit(0)
PY
