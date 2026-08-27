#!/usr/bin/env python3
"""적재를 돌릴 에이전트 CLI 어댑터 — 어느 CLI 인지를 러너가 모르게 한다.

러너는 한때 `claude` 하나에 못 박혀 있었다. argv 도, 스트림 형식도, 실행 파일 이름도,
매니페스트의 필수 조건 줄도 전부 그 이름이었다. 그래서 codex 만 로그인된 박스는 이 앱의
중심 기능을 쓸 수 없었고 — **설치 자체가 막혔다.** 필수 조건 술어에 "이거 아니면 저거" 가
없어서 `claude` 가 present 여야만 프리플라이트를 통과했기 때문이다.

어댑터가 답하는 것은 넷이다.

  · `probe`        — 이 박스에 그 CLI 가 있나, 그리고 로그인 흔적이 있나
  · `build_argv`   — 프롬프트 하나를 헤드리스로 돌리는 명령줄
  · `build_env`    — 자식에게 줄 환경 (종량 과금 변수를 걷어낸)
  · `skill_target` — 적재 스킬을 심어야 그 CLI 가 찾는 자리

🔴 **스트림 파싱은 판정이 아니라 진행 표시다.** 완료의 근거는 로그의 DONE 표시 하나이고,
그것은 어느 CLI 든 자기 표준출력에 그대로 흘린다. claude 의 `stream-json` 은 그 줄을 JSON
이벤트 안에 넣어 보내므로 꺼내야 하고, codex 는 평문이라 그대로 지나간다. 어느 쪽이든
**못 읽으면 진행 표시를 잃을 뿐 판정은 멀쩡하다** — 그 경계가 이 파일의 설계다.

로그인 판정에 대해 정직하게: 실행해 보지 않고 "로그인됐다" 를 확신할 방법은 없다. 여기서
보는 것은 플랫폼이 돌려준 **사용 가능한 로그인 boolean**이라는 힌트뿐이고, 힌트가 없어도
실행은 막지 않는다. 힌트는 여러 CLI 가 깔린 박스에서 **어느 것을 먼저 쓸지 고르는 데만**
쓴다. 이 앱은 제공자 자격 파일의 경로나 형식을 알지 못한다.
"""

import json
import os
import shutil
import subprocess

# 🔴 구독이 아니라 종량 과금으로 돌 뻔하게 만드는 환경 변수 전부. 자식은 환경을 통째로
#    상속하므로 여기서 막지 않으면 조용히 과금된다. 유닛의 `UnsetEnvironment` 와 별개인
#    fail-closed 방어선이다 — 빈 문자열도 존재이므로 구독 실행으로 치지 않는다.
UNSAFE_BILLING_ENV = (
    "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
    "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
    "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
    "AWS_PROFILE", "AWS_BEARER_TOKEN_BEDROCK",
    "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT",
    "ANTHROPIC_VERTEX_PROJECT_ID", "CLOUD_ML_REGION",
    "OPENAI_API_KEY", "OPENAI_BASE_URL",
)

SKILL_NAME = "learning-ingest"

# 도구 결과를 로그에 남길 때의 앞머리 길이. 전사본 하나가 로그를 통째로 채우지
# 않게 자른다.
TOOL_RESULT_HEAD_BYTES = 1200

# 이해하지 못한 이벤트 줄의 앞머리. 로그에는 남기되 완료 표시로는 읽히지 않게 한다.
UNKNOWN_EVENT_PREFIX = "[원문] "


class Provider:
    """어댑터의 기본형. 하위 클래스는 이름과 자리만 바꾼다."""

    id = ""
    label = ""
    command = ""
    # 스킬을 심는 자리 (홈 기준 상대경로).
    skill_root = ""

    def probe(self, env=None):
        """(실행파일 경로|None, 자격 힌트 bool)."""
        env = env if env is not None else os.environ
        def usable(path):
            return bool(path) and os.path.isfile(path) and os.access(path, os.X_OK)

        override = env.get(self.binary_env)
        candidate = None
        if override:
            candidate = override if "/" in override else shutil.which(
                override, path=env.get("PATH", ""))
            if not usable(candidate):
                # 🔴 지정이 안 풀리면 **PATH 로 돌아간다.** 예전에는 여기서 이 제공자를
                #    통째로 없는 것으로 쳤다 — 깔려 있고 PATH 에도 있는 CLI 를, 낡은
                #    환경변수 하나 때문에 "찾지 못했습니다" 라고 말하게 된다.
                candidate = None
        if not usable(candidate):
            candidate = shutil.which(self.command, path=env.get("PATH", ""))
        if not usable(candidate):
            candidate = None
        return candidate, self.has_credentials(env)

    @property
    def binary_env(self):
        return f"AIRLOCK_LEARNING_{self.id.upper()}_BIN"

    def has_credentials(self, env=None):
        """플랫폼이 이 제공자에 사용 가능한 로그인이 있다고 답했나.

        호출 실패·초과 출력·잘못된 JSON은 모두 힌트 없음으로 축소한다. 힌트는 자동 선택
        순서만 바꾸므로, 이 경계의 실패 때문에 설치된 CLI 자체를 막아서는 안 된다. stderr와
        원문 stdout은 로그에 싣지 않는다 — 플랫폼 계약은 boolean 외 자격 정보를 주지 않는다.
        """
        env = env if env is not None else os.environ
        binary = (env.get("AIRLOCK_LEARNING_ACCOUNTS_STATUS_BIN") or "").strip()
        if not binary:
            return False
        try:
            proc = subprocess.run(
                [binary, "login-state", "--json"], env=env,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=10, check=False)
        except (OSError, subprocess.TimeoutExpired):
            return False
        if proc.returncode != 0 or len(proc.stdout) > 64 * 1024:
            return False
        try:
            payload = json.loads(proc.stdout.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return False
        providers = payload.get("providers") if isinstance(payload, dict) else None
        return (isinstance(payload, dict)
                and type(payload.get("schema_version")) is int
                and payload.get("schema_version") == 1
                and isinstance(providers, dict)
                and providers.get(self.id) is True)

    def build_argv(self, binary, prompt):
        raise NotImplementedError

    def build_env(self, base=None):
        """자식에게 줄 환경. 과금 변수를 **지운다**."""
        base = dict(base if base is not None else os.environ)
        for name in UNSAFE_BILLING_ENV:
            base.pop(name, None)
        return base

    def skill_target(self, home=None):
        home = home or os.path.expanduser("~")
        return os.path.join(home, self.skill_root, SKILL_NAME)

    def log_bytes(self, line, seen=None):
        """자식의 출력 한 줄 → 로그에 쓸 바이트. 아무것도 안 쓸 거면 b"".

        🔴 **여기서 b"" 를 돌려주는 것은 로그에서 그 줄을 지우는 것이고, 판정은 로그를
        읽는다.** 그러니 "모르는 모양" 은 절대 b"" 가 되면 안 된다 — 완료 표시가 그 안에
        들어 있으면 성공한 적재가 `no-output` 으로 뒤집힌다(적대검증 2026-08-22 실측).
        모르면 **원문 그대로** 남긴다.
        """
        raise NotImplementedError


class ClaudeProvider(Provider):
    id = "claude"
    label = "Claude Code"
    command = "claude"
    skill_root = ".claude/skills"

    def build_argv(self, binary, prompt):
        # `--model` 은 싣지 않는다. 오너 결정 5 — 모델은 화면에도 argv 에도 노출하지
        # 않고 CLI 의 기본값을 쓴다. 여기서 고정하면 그 결정이 코드로 뒤집힌다.
        return [binary, "-p", prompt, "--output-format", "stream-json", "--verbose"]

    def log_bytes(self, line, seen=None):
        """stream-json 한 줄 → 로그 바이트.

        🔴 **모르는 모양은 원문 그대로 남긴다.** 한때 이 자리가 `type` 을 아는 것만
        옮기고 나머지는 버렸다. claude 가 이벤트 이름 하나를 바꾸면 그 안에 실린 완료
        표시가 로그에 못 닿고, 문서는 멀쩡히 저장됐는데 적재는 `no-output` 으로 실패
        기록된다(적대검증 2026-08-22가 실제로 그렇게 뒤집었다). 로그가 지저분해지는
        것과 성공한 적재를 잃는 것 중에서는 전자가 낫다.
        """
        text = line.decode("utf-8", "replace") if isinstance(line, bytes) else line
        stripped = text.strip()
        if not stripped:
            return b""
        try:
            event = json.loads(stripped)
        except ValueError:
            return text.encode("utf-8", "replace")
        if not isinstance(event, dict):
            return (stripped + "\n").encode("utf-8")
        chunk = self._translate_event(event, seen)
        if chunk:
            return chunk
        # 아는 모양이 아니었다 = 우리가 이해 못 한 것이지 버려도 되는 것이 아니다.
        #
        # 🔴 `[원문]` 을 앞에 붙이는 것은 안전장치다. 완료 판정은 `^마커 <경로>$` 로 **줄
        #    전체**를 요구하는데, 이해 못 한 이벤트를 줄머리부터 흘리면 그 안에 실린 문자열이
        #    가짜 완료가 될 수 있다. 접두어가 있으면 마커는 줄머리에 올 수 없다.
        #    동시에 이 접두어가 "형식이 바뀌었다" 는 유일한 단서다 — 판정이 그것을 읽는다.
        return (UNKNOWN_EVENT_PREFIX + stripped + "\n").encode("utf-8")

    def _translate_event(self, event, seen=None):
        """stream-json 이벤트 한 개 → 로그에 쓸 바이트(없으면 b"").

        사람이 읽는 진행 줄로 옮긴다. assistant 텍스트는 **손대지 않고** 그대로 —
        완료 표시가 줄머리에 있어야 러너가 그걸 찾는다.
        """
        kind = event.get("type")
        if kind == "assistant":
            out = []
            for block in (event.get("message") or {}).get("content") or []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text":
                    text = block.get("text") or ""
                    if text.strip():
                        body = text.rstrip("\n")
                        out.append(body + "\n")
                        if seen is not None:
                            seen.add(body)
                elif block.get("type") == "tool_use":
                    name = str(block.get("name") or "도구")
                    data = block.get("input") if isinstance(block.get("input"), dict) else {}
                    hint = data.get("description") or data.get("command") or data.get("file_path") or ""
                    hint = " ".join(str(hint).split())[:120]
                    out.append(f"[진행] {name}: {hint}\n" if hint else f"[진행] {name}\n")
            return "".join(out).encode("utf-8")
        if kind == "user":
            # 도구가 **무엇을 돌려줬나**. 이름만 있고 결과가 없으면 로그로 진단을 못 한다.
            out = []
            for block in (event.get("message") or {}).get("content") or []:
                if not isinstance(block, dict) or block.get("type") != "tool_result":
                    continue
                body = block.get("content")
                if isinstance(body, list):
                    body = "".join(part.get("text", "") for part in body
                                   if isinstance(part, dict) and part.get("type") == "text")
                # 🔴 **한 줄로 접는 것이 안전장치다 — 보기 좋으라고 하는 게 아니다.**
                #    완료 판정(`INGEST_DONE_RE`)은 `^마커 <경로>$` 로 **줄 전체**를 요구한다.
                #    도구 출력을 줄바꿈 그대로 남기면, 에이전트가 마커를 grep 한 결과나 스킬
                #    문서를 Read 한 결과가 그 줄을 그대로 담아 **적재를 가짜로 완료 처리**할 수
                #    있다. 여기서 접고 `[결과]` 를 앞에 붙이므로 마커가 줄머리에 올 수 없다.
                #    줄바꿈을 보존하도록 고치려면 먼저 그 판정 경로를 다시 설계하라.
                text = " ".join(str(body or "").split())
                if not text:
                    continue
                raw = text.encode("utf-8", "replace")
                if len(raw) > TOOL_RESULT_HEAD_BYTES:
                    text = raw[:TOOL_RESULT_HEAD_BYTES].decode("utf-8", "ignore") + " …(잘림)"
                label = "결과·오류" if block.get("is_error") else "결과"
                out.append(f"[{label}] {text}\n")
            return "".join(out).encode("utf-8")
        if kind == "result":
            # 마지막 요약 텍스트. `-p` 가 원래 찍던 그 값이라 마커가 여기 올 수도 있다.
            # 실측(실제 claude): 같은 텍스트가 assistant 로 이미 왔다 — 두 번 찍으면 로그가 부풀고
            # 사용자는 요약이 반복된 것으로 읽는다. 이미 쓴 것과 같으면 건너뛴다.
            text = event.get("result")
            if isinstance(text, str) and text.strip():
                body = text.rstrip("\n")
                if seen is not None and body in seen:
                    return b""
                return (body + "\n").encode("utf-8")
        return b""



class CodexProvider(Provider):
    id = "codex"
    label = "Codex CLI"
    command = "codex"
    skill_root = ".agents/skills"

    def build_argv(self, binary, prompt):
        """🔴 두 인자가 없으면 이 앱에서는 **한 번도 돌지 않는다.**

        `--skip-git-repo-check`: codex 는 git 레포가 아닌 디렉터리에서 시작을 거부한다
        (`Not inside a trusted directory and --skip-git-repo-check was not specified.`).
        그런데 이 앱의 라이브러리는 **일부러 git 이 아니다** — 2단계가 그렇게 만들었다.
        이 플래그가 없으면 codex 지원은 장식이다(적대검증 2026-08-22 실측: exit 1).

        `--sandbox workspace-write` + 네트워크: 적재는 cwd(라이브러리)에 문서를 쓰고
        자막을 받으러 밖에 나간다. 기본값에 기대면 상대 박스의 설정에 따라 둘 중 하나가
        조용히 막힌다 — 우리가 필요한 것을 우리가 말한다.
        """
        return [binary, "exec",
                "--skip-git-repo-check",
                "--sandbox", "workspace-write",
                "-c", "sandbox_workspace_write.network_access=true",
                prompt]

    def log_bytes(self, line, seen=None):
        # codex exec 는 평문을 흘린다 — 원문이 곧 로그다.
        return line if isinstance(line, bytes) else line.encode("utf-8", "replace")

    @property
    def streams_json(self):
        return False


PROVIDERS = (ClaudeProvider(), CodexProvider())


def by_id(provider_id):
    for provider in PROVIDERS:
        if provider.id == provider_id:
            return provider
    return None


def streams_json(provider):
    """그 CLI 의 표준출력이 JSON 이벤트인가. 아니면 평문 그대로 로그로 간다."""
    return getattr(provider, "streams_json", True)


def skill_roots(home=None):
    """스킬을 심어야 할 디렉터리들. 설치 스크립트가 이 목록을 읽는다.

    🔴 설치가 `~/.claude/skills` 를 직접 적으면 자리를 아는 곳이 둘이 된다. 새 CLI 를
    붙일 때 어댑터만 고치고 설치를 잊으면, 그 CLI 는 스킬을 못 찾는데 아무 데서도
    실패하지 않는다 — 조용히 안 되는 종류다.
    """
    return [os.path.dirname(provider.skill_target(home)) for provider in PROVIDERS]


def select(preference="auto", env=None):
    """(provider, 실행파일, 사유). 못 고르면 (None, None, 사람이 읽을 사유).

    고르는 순서는 하나뿐이다 — **자격 흔적이 있는 것 먼저.** 여러 CLI 가 깔린 박스에서
    로그인 안 된 쪽을 골라 40분 뒤에 실패하는 것이 가장 나쁜 결과이기 때문이다.
    """
    env = env if env is not None else os.environ
    known = ("auto",) + tuple(p.id for p in PROVIDERS)
    requested = str(preference or "auto").strip().lower()
    note = ""
    if requested not in known:
        # 조용히 auto 로 바꾸지 않는다 — 오타 하나로 다른 CLI 가 돌고 있는데 로그는
        # 아무 말도 안 하는 것이 이 자리에서 가장 나쁜 결과다.
        note = f" (설정의 provider 값 {requested!r} 을 모릅니다 — auto 로 봤습니다)"
        requested = "auto"
    preference = requested

    if preference != "auto":
        provider = by_id(preference)
        binary, _hint = provider.probe(env)
        if binary:
            return provider, binary, f"{provider.label} (설정에서 고정){note}"
        return None, None, (
            f"{provider.label}({provider.command})를 찾지 못했습니다 — 설정이 이 제공자로 "
            f"고정되어 있습니다. 설치하거나 provider 를 auto 로 되돌리십시오{note}")

    found = []
    for provider in PROVIDERS:
        binary, hint = provider.probe(env)
        if binary:
            found.append((provider, binary, hint))
    for provider, binary, hint in found:
        if hint:
            return provider, binary, f"{provider.label} (로그인 흔적 있음){note}"
    if found:
        provider, binary, _hint = found[0]
        return provider, binary, (
            f"{provider.label} (설치되어 있지만 로그인 흔적을 찾지 못했습니다 — 그래도 실행합니다){note}")
    names = ", ".join(p.command for p in PROVIDERS)
    return None, None, (
        f"적재를 돌릴 에이전트 CLI 를 찾지 못했습니다 — {names} 중 하나가 로그인되어 "
        f"있어야 링크를 문서로 만들 수 있습니다. 폴더를 열어 보고 공유하는 것은 그대로 됩니다{note}")


if __name__ == "__main__":
    # 설치 스크립트용 최소 CLI. 셸에서 파이썬 모듈을 임포트할 수는 없으니, 이 두 줄이
    # 어댑터와 설치 사이의 유일한 통로다 — 자리와 목록을 두 벌로 적지 않기 위해서.
    import sys as _sys
    _mode = _sys.argv[1:2]
    if _mode == ["--skill-roots"]:
        for _root in skill_roots():
            print(_root)
        raise SystemExit(0)
    if _mode == ["--unsafe-env"]:
        print(" ".join(UNSAFE_BILLING_ENV))
        raise SystemExit(0)
    print("usage: providers.py --skill-roots | --unsafe-env", file=_sys.stderr)
    raise SystemExit(2)
