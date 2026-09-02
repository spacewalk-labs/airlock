#!/usr/bin/env python3
"""적재 워커 — 상시 유닛 하나가 큐 전체를 굴린다.

(파일 이름은 옛 oneshot 러너 시절 그대로다. `infra/dev-hub/` 는 이관 중이라 파일 추가가
금지돼 있어 새 이름으로 옮기지 못한다 — 하는 일은 러너가 아니라 워커다.)

구조는 한 문장이다. **하나 집어서, 끝날 때까지 돌리고, 그 다음 것을 집는다.**
"동시 1건"이 락으로 지키는 불변식이 아니라 직선 코드라, 위반할 방법이 없다.

이전 구조는 요청마다 systemd 템플릿 유닛을 띄우고 `kick_ingest_queue()` 를 HTTP 핸들러
셋과 러너의 `finally` 가 각자 불렀다. "다음 것을 시작한다"는 결정이 프로세스 경계를
넘나들었고 그것을 상태 디렉토리 전체 flock 으로 봉합했다. 적대검증 3라운드에서 나온
결함 15건이 전부 그 봉합선에서 나왔다 — 시그널이 락 대기 중에 떨어지면 큐가 영구히
막혔고, flock 이 open file description 단위라 같은 프로세스가 재획득하면 자기 락에
막혔다. 큐에 주인을 주면 둘 다 존재하지 않는 문제가 된다.

여기서 지키는 규칙은 둘이다.

- **시그널 핸들러는 플래그만 세운다.** 상태를 쓰지 않는다 — 그래서 어느 지점에 떨어져도
  재진입도 데드락도 없다. 처리는 루프가 자기 시점에 한다.
- **`state` 를 쓰는 것은 이 프로세스뿐이다.** 웹앱은 행을 넣고, 취소를 요청하고,
  종결된 행을 지운다.
"""

import fcntl
import hashlib
import importlib.util
import os
import signal
import json
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone

BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
BACKEND_PATH = os.path.join(BACKEND_DIR, "airlock-learning.py")
BACKEND_SPEC = importlib.util.spec_from_file_location("learning_manager_ingest_backend", BACKEND_PATH)
BACKEND = importlib.util.module_from_spec(BACKEND_SPEC)
BACKEND_SPEC.loader.exec_module(BACKEND)

# 저장 헬퍼. 스킬이 문서를 남기는 유일한 통로이고, **학습자료 판정을 소유한다** — 저장할
# 때와 검증할 때가 같은 함수를 쓰지 않으면 둘은 조용히 갈라진다.
PROVIDERS_PATH = os.path.join(BACKEND_DIR, "providers.py")
_PROVIDERS_SPEC = importlib.util.spec_from_file_location("learning_providers", PROVIDERS_PATH)
PROVIDERS = importlib.util.module_from_spec(_PROVIDERS_SPEC)
_PROVIDERS_SPEC.loader.exec_module(PROVIDERS)

# 라이브러리가 git 저장소일 때만 도는 커밋·push. 판정과 분리돼 있고 기본값은 off —
# 이유는 git_sync.py 의 첫 문단에 있다.
GIT_SYNC_PATH = os.path.join(BACKEND_DIR, "git_sync.py")
_GIT_SYNC_SPEC = importlib.util.spec_from_file_location("learning_git_sync", GIT_SYNC_PATH)
GITSYNC = importlib.util.module_from_spec(_GIT_SYNC_SPEC)
_GIT_SYNC_SPEC.loader.exec_module(GITSYNC)

SAVE_PATH = os.path.join(BACKEND_DIR, "save_document.py")
SAVE_SPEC = importlib.util.spec_from_file_location("learning_save_document", SAVE_PATH)
SAVE = importlib.util.module_from_spec(SAVE_SPEC)
SAVE_SPEC.loader.exec_module(SAVE)

# 큐는 백엔드 안의 이름공간이다(`IngestQueue`). 모듈을 따로 두지 않은 이유는
# `infra/dev-hub/` 가 airlock 이관 중이라 파일 **추가**가 금지돼 있기 때문이다.
QUEUE = BACKEND.IngestQueue

# 🔴 한 적재의 예산. 실측 2026-07-31: 9.7분 · 21.5분 · 23분 · 30분 초과 — 30분 천장은 실제
#    적재를 잘랐다. 이제 이 값이 **유일한 시간 예산**이다. 워커 유닛은 `Type=simple` 이라
#    `TimeoutStartSec` 이 없고, 그래서 "유닛과 러너 중 누가 먼저 죽나"를 맞추던 grace 상수와
#    `--print-unit-timeout` 왕복이 통째로 사라졌다.
DEFAULT_TIMEOUT_SECONDS = 60 * 60

# 큐를 들여다보는 주기. 13분짜리 작업에 2초 폴링은 공짜다 — 대신 알림 프로토콜·시그널
# 전달·`kick` 삼중 호출이 전부 없어진다.
POLL_SECONDS = 2.0

# 판정할 때 이해 못 한 줄을 세려고 읽는 로그 길이. 꼬리만 본다.
INGEST_UNKNOWN_SCAN_BYTES = 256 << 10

# 취소·종료 시 자식에게 주는 유예. 넘으면 프로세스 그룹째 SIGKILL 한다.
TERM_GRACE_SECONDS = 20.0

# 적재 산출물의 최소 크기는 저장 헬퍼가 정한다 — 저장을 거절하는 기준과 완료를 거절하는
# 기준이 다르면 "저장은 됐는데 완료가 아닌" 문서가 조용히 생긴다.
DOCUMENT_MIN_BYTES = SAVE.DOCUMENT_MIN_BYTES

STOPPING = False


FAILURE_SUMMARY_MODEL = "sonnet"
# 🔴 요약은 워커 루프를 그동안 **멈춰 세운다** — 다음 적재가 이만큼 늦어진다. 실측
#    2026-08-17 실제 요약 소요는 7.9초였고, 이 상한은 모델이 막혔을 때의 천장이다.
FAILURE_SUMMARY_TIMEOUT_SECONDS = 120
# 이보다 짧은 로그는 요약할 원문이 없다(cli-missing 처럼 러너가 한 줄
# 쓰고 끝난 경우). 이때는 이미 `error` 한 줄이 스스로 설명한다.
FAILURE_SUMMARY_MIN_LOG_BYTES = 400
# 요약 모델에 넣을 로그 꼬리 길이. 실패 원인은 거의 항상 끝에 있다.
FAILURE_SUMMARY_TAIL_BYTES = 60000

# 🔴 도구 **출력**도 로그에 남긴다. 2026-08-21 이전에는 도구 *이름*만 남겨서, 적재가 왜
#    느린지·검사가 무엇을 거부했는지를 사후에 알 수 없었다(실측: 재검증 41건의 사유를
#    한 건도 못 읽었다). 다만 통째로 남기면 로그가 부푼다 — 전사본을 Read 한 결과 하나가
#    수만 바이트다. 그래서 결과마다 앞부분만 남긴다. 진단에 필요한 것은 대개 첫 줄들이다
#    (에러 메시지·검사 위반 목록은 앞에 온다).
FAILURE_SUMMARY_PROMPT = (
    "아래 <stdin> 은 유튜브 영상을 학습자료로 적재하는 자동화 작업이 실패했을 때 남은 "
    "실행 로그입니다. 로그를 읽고 '왜 실패했는지'를 한국어 2~3문장으로만 쓰세요. "
    "사람이 다음에 무엇을 하면 되는지 한 문장 포함하세요. "
    "제목·머리말·불릿·코드블록 없이 평서문만 출력하세요. "
    "로그에 근거가 없으면 추측하지 말고 '로그만으로는 원인을 특정할 수 없습니다'로 시작하세요."
)


def failure_summary_enabled():
    """`INGEST_FAILURE_SUMMARY=0` 으로 끈다. 시험은 모델을 부르면 안 되고, 운영에서도
    코덱스가 오래 막힐 때 사람이 끌 수 있어야 한다. 기본은 켜짐이다."""
    raw = BACKEND.env_first("AIRLOCK_LEARNING_FAILURE_SUMMARY", "INGEST_FAILURE_SUMMARY",
                            default="1").strip().lower()
    return raw not in {"0", "false", "no", "off", ""}


# 🔴 **허용목록**이다. 지울 것을 세는 방식(blacklist)은 졌다 — `CLAUDE_CODE_USE_BEDROCK`,
#    `CLAUDE_CODE_USE_VERTEX`, AWS·GCP 자격증명, `CODEX_API_KEY` 처럼 과금 경로로 새는
#    변수는 계속 늘어나고, 하나 빠뜨리면 조용히 과금된다. 요약에 필요한 것만 통과시킨다.
#    (실측: placeholder AWS 환경 + `CLAUDE_CODE_USE_BEDROCK=1` 이면 claude 가 bedrock 을 고른다.)
FAILURE_SUMMARY_ENV_KEEP = (
    "HOME", "PATH", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TZ",
    "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME",
)


def _subscription_env():
    """자식에게 넘길 환경. 구독 로그인(`~/.codex`·`~/.claude`)은 HOME 으로 찾으므로
    자격증명 변수는 하나도 필요 없다."""
    return {name: os.environ[name] for name in FAILURE_SUMMARY_ENV_KEEP if name in os.environ}


def _clip_tail(text, max_bytes=FAILURE_SUMMARY_TAIL_BYTES):
    """🔴 **바이트**로 자른다. 글자 수로 자르면 한글은 한 글자가 3바이트라 한계를 3배로
    넘긴다. 앞을 버리고 뒤를 남긴다 — 실패 원인은 로그 끝에 있다."""
    data = str(text).encode("utf-8", "replace")
    if len(data) <= max_bytes:
        return data.decode("utf-8", "replace")
    return data[-max_bytes:].decode("utf-8", "replace")


def _summarize_with_claude(log_text):
    """적재 본체가 이미 쓰는 실행 파일이라 새로 붙는 의존성이 없다.

    🔴 요약기는 지금도 claude 전용이다. 도구를 전부 끄는 인자가 CLI 마다 다르고, 그
    인자를 잘못 주면 신뢰할 수 없는 전사를 도구가 켜진 에이전트에 먹이게 된다 — 실패
    요약 한 줄의 편의가 그 위험을 살 만하지 않다. claude 가 없으면 요약을 접고 원문
    로그를 남긴다(아래 호출부가 그 실패를 삼킨다).
    """
    claude = PROVIDERS.by_id("claude").probe()[0]
    if not claude:
        raise FileNotFoundError("실패 요약은 claude 로만 만듭니다 — 찾지 못했습니다")
    prompt = FAILURE_SUMMARY_PROMPT.replace("<stdin> 은", "아래 로그는") + (
        "\n\n--- 로그 ---\n" + _clip_tail(log_text)
    )
    result = subprocess.run(
        # 🔴 도구를 전부 끈다. 이 박스의 사용자 설정은 `defaultMode=bypassPermissions` 라,
        #    도구를 켠 채 신뢰할 수 없는 전사를 먹이면 프롬프트 주입 한 줄이 무승인 실행이
        #    된다. 요약은 글자만 만들면 되므로 도구가 하나도 필요 없다.
        # 🔴 `--tools ""` 만으로는 **부족하다** — 그건 내장 도구만 끄고 MCP 서버는 그대로
        #    남긴다. 실측 2026-08-17: `--tools ""` 만 걸고 로컬 서버의 난수를 요청했더니
        #    모델이 그 값을 정확히 가져왔고 서버 로그에 GET 이 찍혔다(= 유출 경로가 열려
        #    있었다). MCP 까지 비우면 같은 요청에서 요청이 아예 나가지 않는다.
        # 🔴 `--tools ""` 와 MCP 차단은 **도구만** 끈다. 훅·플러그인·CLAUDE.md·세션 저장은
        #    그대로 살아 있었다(적대검증 2026-08-18). 그래서 신뢰할 수 없는 로그가 로컬
        #    지침·훅 출력과 같은 컨텍스트에 들어가고, 프롬프트가 세션 파일로 디스크에
        #    영구 복제됐다(실측: 요약 프롬프트가 담긴 세션 파일 4개, 최대 53KB).
        #    `--safe-mode` 가 그 커스터마이즈 전부를, `--no-session-persistence` 가
        #    디스크 복제를 끈다.
        [claude, "-p", prompt, "--model", FAILURE_SUMMARY_MODEL, "--tools", "",
         "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
         "--safe-mode", "--no-session-persistence"],
        shell=False, capture_output=True, text=True,
        timeout=FAILURE_SUMMARY_TIMEOUT_SECONDS, env=_subscription_env(),
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        raise RuntimeError(f"claude exit {result.returncode}: {detail[-300:]}")
    return (result.stdout or "").strip()


def summarize_failure(log_text):
    """(요약, 실패사유). 둘 다 None 이 아닌 경우는 없다. **조용히 빈 값을 남기지 않는다** —
    요약을 못 만든 이유도 화면까지 흘려야 사람이 '왜 설명이 없나'를 묻지 않는다."""
    if len(str(log_text).encode("utf-8", "replace")) < FAILURE_SUMMARY_MIN_LOG_BYTES:
        return None, "로그가 짧아 요약할 내용이 없습니다"
    try:
        text = _summarize_with_claude(log_text)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        return None, f"요약을 만들지 못했습니다 — {exc}"
    if not text:
        return None, "요약을 만들지 못했습니다 — 빈 응답"
    return text, None


def timeout_seconds():
    raw = BACKEND.env_first("AIRLOCK_LEARNING_INGEST_TIMEOUT_SECONDS",
                            "INGEST_TIMEOUT_SECONDS", default=str(DEFAULT_TIMEOUT_SECONDS))
    try:
        value = float(raw)
    except ValueError:
        return float(DEFAULT_TIMEOUT_SECONDS)
    return value if value > 0 else float(DEFAULT_TIMEOUT_SECONDS)


def resolve_provider():
    """(provider, 실행파일). 못 고르면 FileNotFoundError 에 사람이 읽을 사유를 담는다.

    한때 이 자리는 `_resolve_claude()` 였고 `claude` 하나만 찾았다. 지금은 어댑터가
    고른다 — 어느 CLI 인지는 러너의 관심사가 아니다.
    """
    preference = BACKEND.env_first("AIRLOCK_LEARNING_AGENT", default="auto")
    provider, binary, reason = PROVIDERS.select(preference, os.environ)
    if provider is None:
        raise FileNotFoundError(reason)
    return provider, binary, reason


def _kill_process(process):
    """프로세스 **그룹**을 죽인다. 리더가 이미 죽었어도 그룹은 남을 수 있다.

    🔴 예전에는 `process.poll() is not None` 이면 곧바로 반환했다. 그런데 우리가 죽이려는
    것은 리더 하나가 아니라 **자손 전부**다 — 적재 본체는 git·gemini·서브에이전트를 낳는다.
    리더가 SIGTERM 에 죽고 자손이 그것을 무시하면, 그 판정 한 줄 때문에 그룹에 SIGKILL 이
    한 번도 가지 않았다(적대검증 2026-08-18 실측: 리더 `returncode=-15`, 자손 생존).
    그 자손은 DB 가 `cancelled` 로 종결된 뒤에도 같은 learning 레포를 계속 고칠 수 있고,
    그 사이 다음 적재가 시작된다 — "동시 1건" 이 조용히 깨지는 유일한 경로였다.
    """
    errors = []
    pid = getattr(process, "pid", None)
    if pid:
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError as exc:
            errors.append(str(exc))
    try:
        process.kill()
    except ProcessLookupError:
        pass
    except OSError as exc:
        errors.append(str(exc))
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        errors.append("프로세스가 종료되지 않았습니다")
    # 그룹이 정말 비었는지 확인한다. `killpg` 가 성공해도 SIGKILL 전달과 소멸 사이에는
    # 짧은 창이 있고, 여기서 못 비우면 다음 적재와 겹친다.
    if pid:
        for _ in range(20):
            try:
                os.killpg(pid, 0)
            except (ProcessLookupError, OSError):
                break
            time.sleep(0.1)
        else:
            errors.append(f"프로세스 그룹 {pid} 이 아직 살아 있습니다")
    return errors


def _extract_meta(text):
    """스킬이 흘린 표시용 메타(제목·채널·길이)를 뽑는다. 없거나 깨졌으면 None.

    🔴 **판정에 쓰지 않는다.** 완료 판정의 유일한 근거는 DONE 마커다(§8). 이건 적재 중 카드에
    무슨 영상인지 보여주기 위한 것이고, 없으면 video_id 로 내려앉을 뿐이다 — 그래서 깨진 줄
    하나로 적재를 실패시키지 않는다.
    """
    match = BACKEND.INGEST_META_RE.search(text)
    if not match:
        return None
    try:
        payload = json.loads(match.group(1))
    except ValueError:
        return False        # 마커는 있는데 JSON 이 깨졌다 — 조용히 넘기지 않고 로그에 남긴다.
    if not isinstance(payload, dict):
        return False
    fields = {key: str(payload[key]) for key in BACKEND.INGEST_META_FIELDS
              if isinstance(payload.get(key), (str, int, float)) and str(payload[key]).strip()}
    return fields or False


def _pump_stream(stream, log_file, on_meta=None, provider=None):
    """자식의 stdout 을 읽어 로그로 옮긴다. 별 스레드에서 돈다.

    JSON 이 아니거나 모르는 모양이면 **원문을 그대로** 남긴다 — 형식이 바뀌었을 때
    조용히 아무것도 안 쓰는 것이 최악이다(그러면 다시 '멈춘 것처럼' 보인다).

    🔴 이 함수가 하는 일은 **진행 표시**다. 완료 판정은 로그에 남은 DONE 표시가 하고,
    그 표시는 어느 경로로 들어와도(JSON 이벤트에서 꺼내든, 평문 그대로든) 같은 로그에
    닿는다. 그래서 이벤트 하나를 못 읽는 것은 화면이 심심해지는 일이지 성공한 적재가
    실패로 뒤집히는 일이 아니다.
    """
    if stream is None:
        return
    # 🔴 출력을 로그로 옮기는 법은 **어댑터가 안다.** 러너가 CLI 별 분기를 들고 있으면
    #    세 번째를 붙일 때 여기도 고쳐야 하고, 잊으면 그 CLI 의 출력이 조용히 사라진다.
    translate = provider.log_bytes if provider is not None else None
    seen = set()          # 이미 로그에 쓴 텍스트 — result 중복 방지
    try:
        for raw in stream:
            line = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else raw
            if not line.strip():
                continue
            chunk = (translate(line, seen) if translate is not None
                     else line.encode("utf-8", "replace"))
            if not chunk:
                continue
            log_file.write(chunk)
            if on_meta is not None:
                meta = _extract_meta(chunk.decode("utf-8", "replace"))
                if meta:
                    on_meta(meta)
                elif meta is False:
                    log_file.write("[진행] 제목 메타 줄을 읽지 못했습니다(표시만 영향).\n"
                                   .encode("utf-8"))
    except (OSError, ValueError):
        # 파이프가 끊기거나 로그를 못 쓰면 진행 표시만 잃는다 — 판정은 마커·exit code 가 한다.
        pass
    finally:
        try:
            stream.close()
        except OSError:
            pass


def _completion_document(log_path):
    """로그 꼬리에서 적재 완료 표시를 찾아 문서 경로를 돌려준다. 없으면 None.

    exit 0 을 완료의 증거로 쓰지 않기 위한 유일한 근거다 — 짝이 되는 계약은
    패키지 안의 `apps/learning/skill/SKILL.md` §5 다.
    """
    try:
        size = os.path.getsize(log_path)
        with open(log_path, "rb") as handle:
            if size > BACKEND.INGEST_DONE_TAIL_BYTES:
                handle.seek(size - BACKEND.INGEST_DONE_TAIL_BYTES)
            tail = handle.read()
    except OSError:
        # 로그를 못 읽으면 완료를 확인할 수 없다 = 완료가 아니다. 조용히 성공시키지 않는다.
        return None
    matches = BACKEND.INGEST_DONE_RE.findall(tail.decode("utf-8", "replace"))
    return matches[-1] if matches else None


def _verify_document(repo, document, video_id=None, receipt=None):
    """마커가 가리키는 산출물이 **지금 그 자리에 그 내용으로** 있는지 실측한다.

    마커는 스킬(LLM)의 자기보고라 그것만으로는 적재를 증명하지 못한다. 두 번의 적대검증이
    실제로 뒤집은 것들이라 검사도 그만큼 구체적이다(2026-07-30):
      · 파일이 없어도 done        → isfile
      · 빈 `.gitkeep` 도 done     → 크기·프론트매터
      · 무관한 기존 문서를 가리켜도 done → 프론트매터 `video_id`

    🔴 예전에는 이 함수가 git 을 네 번 불렀다 — `rev-parse HEAD`, `cat-file -e HEAD:<경로>`,
    `diff --quiet HEAD`, `show HEAD:<경로>`. 그 네 줄이 라이브러리를 git 레포로 못 박았고,
    스킬은 완료를 증명하려고 워크트리·커밋·PR·머지를 지나야 했다. 지금 판정하는 것은
    **커밋 이력이 아니라 파일 자체**라, 같은 질문("지금 이 내용이 여기 있나")에 git 없이
    답한다. git 이 있는 라이브러리에서도 답은 같다 — 커밋 여부는 이제 사용자 사정이다.

    `receipt` 가 있으면(= 스킬이 저장 헬퍼를 썼으면) 다이제스트까지 대조한다. 없으면
    파일만으로 판정하고, 그 사실을 부르는 쪽이 로그에 남긴다 — 조용히 봐주지 않는다.

    🔴 **영수증이 막는 것과 못 막는 것.** 영수증 파일은 자식(에이전트 CLI)이 쓸 수 있는
    자리에 있고 같은 UID 로 돈다. 그러니 **거짓말하는 스킬을 막지 못한다** — 스킬이 헬퍼를
    부르지 않고 자기 도구로 파일과 영수증을 둘 다 지어내면 통과한다(적대검증 2026-08-22).
    같은 UID 안에서 위조 불가능한 영수증은 만들 수 없으므로 그것을 목표로 삼지 않는다.
    영수증이 실제로 막는 것은 **저장 이후의 표류**다: 저장한 뒤 그 파일이 바뀌었는지,
    마커가 저장한 것과 다른 문서를 가리키는지, 다른 영상의 문서인지.

    돌려주는 값은 (reason, error) 이고 통과하면 (None, None).
    """
    repo_root = os.path.realpath(repo)
    target = os.path.realpath(os.path.join(repo_root, document))
    if target != repo_root and not target.startswith(repo_root + os.sep):
        return "marker-document-outside-repo", f"완료 표시가 레포 밖을 가리킵니다: {document}"
    if not os.path.isfile(target):
        return "marker-document-missing", (
            f"완료 표시는 있지만 산출물이 없습니다: {document} — 적재가 되지 않았습니다"
        )
    relative = os.path.relpath(target, repo_root)

    try:
        with open(target, "rb") as handle:
            blob = handle.read()
    except OSError as exc:
        return "marker-verify-failed", (
            f"산출물을 읽지 못했습니다: {document} — {exc}"
        )

    reason, error = SAVE.document_defect(blob, relative, video_id)
    if reason is not None:
        return f"marker-document-{reason}", error

    # 영수증은 저장 헬퍼가 **파일을 다시 읽어** 쓴 것이다. 다르면 저장 이후에 누군가
    # 그 파일을 갈아치웠다는 뜻이고, 그때 이 적재가 무엇을 만들었는지는 알 수 없다.
    if receipt:
        if receipt.get("schema") != SAVE.RECEIPT_SCHEMA:
            return "marker-receipt-unreadable", (
                f"저장 영수증의 형식을 모릅니다: schema={receipt.get('schema')!r} — "
                f"이 워커가 아는 것은 {SAVE.RECEIPT_SCHEMA} 입니다"
            )
        if video_id and receipt.get("video_id") != video_id:
            return "marker-receipt-other-video", (
                f"저장 영수증이 다른 영상의 문서입니다: 영수증 "
                f"video_id={receipt.get('video_id')}, 요청={video_id}"
            )
        # 🔴 **철자가 아니라 파일로** 맞댄다. 라이브러리 안에 심볼릭 링크가 하나만 있어도
        #    같은 파일이 두 이름을 갖고, 문자열 비교는 그것을 "다른 문서" 로 읽는다 —
        #    실제로 그렇게 읽어서 성공한 저장이 실패로 판정됐다(적대검증 2026-08-22).
        receipt_target = os.path.realpath(os.path.join(repo_root, receipt.get("path") or ""))
        if receipt_target != target:
            return "marker-receipt-other-document", (
                f"완료 표시({document})와 저장 영수증({receipt.get('path')})이 다른 문서를 "
                "가리킵니다 — 적재가 무엇을 남겼는지 확인할 수 없습니다"
            )
        digest = hashlib.sha256(blob).hexdigest()
        if receipt.get("sha256") != digest:
            return "marker-receipt-content-changed", (
                f"저장한 뒤 산출물이 바뀌었습니다: {document} — "
                f"영수증 {str(receipt.get('sha256'))[:12]}…, 지금 파일 {digest[:12]}…"
            )
    return None, None


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _handle_signal(signum, _frame):
    """🔴 **플래그만 세운다.** 여기서 상태를 쓰거나 락을 잡으면, 신호가 떨어지는 지점에 따라
    재진입·데드락이 생긴다 — 이전 구조가 정확히 그래서 깨졌다. 처리는 루프가 한다."""
    global STOPPING
    STOPPING = True


def acquire_singleton(state_dir):
    """워커가 둘 도는 것을 막는다. 기동 때 한 번 잡고 프로세스가 죽을 때까지 들고 있으므로
    **재획득이 없다** — flock 재진입 데드락이 원리적으로 불가능하다."""
    # 첫 기동에는 state 디렉터리 자체가 없다 — 여기서 만들지 않으면 워커가 뜨지 못한다.
    os.makedirs(state_dir, exist_ok=True)
    path = QUEUE.worker_lock_path(state_dir)
    handle = open(path, "a+")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        return None
    handle.truncate(0)
    handle.write(f"{os.getpid()}\n")
    handle.flush()
    return handle


def timeout_seconds():
    raw = BACKEND.env_first("AIRLOCK_LEARNING_INGEST_TIMEOUT_SECONDS",
                            "INGEST_TIMEOUT_SECONDS", default=str(DEFAULT_TIMEOUT_SECONDS))
    try:
        value = float(raw)
    except ValueError:
        return float(DEFAULT_TIMEOUT_SECONDS)
    return value if value > 0 else float(DEFAULT_TIMEOUT_SECONDS)


def append_log(path, message):
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    with os.fdopen(os.open(path, flags, 0o600), "ab", buffering=0) as handle:
        handle.write(message.encode("utf-8", "replace"))


def read_log(path, limit=None):
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError:
        return ""
    if limit is not None and len(data) > limit:
        data = data[-limit:]
    return data.decode("utf-8", "replace")


def build_prompt(row, state_dir):
    """🔴 이전 로그를 **argv 에 싣지 않고 경로로 넘긴다.** 스킬이 자기 Read 도구로 읽는다.

    이전 구조는 로그 본문을 프롬프트에 이어붙여 argv 한 요소로 넘겼고, 리눅스의
    `MAX_ARG_STRLEN`(128KiB)에 걸려 바이트 단위 클리핑 상수와 로그 회전 절차가 따라붙었다.
    경로 한 줄이면 그 전부가 필요 없다. 옛 시도의 로그는 그 자리에 그대로 남는다.
    """
    prompt = f"/learning-ingest {row['url']}"
    if row.get("retry_of"):
        previous = QUEUE.log_path(state_dir, row["retry_of"])
        if os.path.exists(previous):
            prompt += (
                f"\n\n이 영상은 이전 시도(#{row['retry_of']})가 실패했습니다."
                f" 실패한 실행의 로그가 {previous} 에 있습니다."
                " 먼저 그 로그를 읽어 무엇이 막혔는지 확인하고, 같은 지점에서 다시 막히지 않게 진행하세요."
            )
    return prompt


# 과금 변수 목록의 정본은 어댑터다 — 자식 환경을 만드는 쪽과 검사하는 쪽이 같은 목록을
# 봐야 한다. 갈라지면 "지웠다고 생각한 변수" 가 남는다.
UNSAFE_BILLING_ENV = PROVIDERS.UNSAFE_BILLING_ENV


def unsafe_anthropic_env():
    """구독이 아니라 종량 과금으로 돌 **뻔한** 이름들. 빈 문자열도 존재로 친다.

    한때 이 함수의 결과가 적재를 **거절**했다. 그때는 그것이 유일한 방어선이었기 때문이다.
    지금은 어댑터의 `build_env` 가 같은 목록을 자식 환경에서 **지운다** — 같은 목록을 보고
    하나는 막고 하나는 고치는 셈이라, 거절은 더 안전하지도 않으면서 멀쩡한 적재를 막는다.
    자기 일로 `OPENAI_API_KEY` 를 켜 둔 사람의 박스에서는 링크가 하나도 안 들어간다
    (실측 2026-08-22: 실제 적재 시험이 여기서 0초 만에 죽었다).

    그래서 지금 이 값은 **거절 사유가 아니라 로그에 남길 사실**이다. 조용히 지우면 "왜
    내 API 키가 안 먹지" 를 아무도 못 읽는다.
    """
    return {name for name in UNSAFE_BILLING_ENV if name in os.environ}


def verdict(repo, row, return_code, log_path, produced_output, receipt_path=None):
    """(상태, 필드). exit 0 을 완료의 근거로 쓰지 않는다.

    🔴 2026-07-30 실측: 링크가 학습자료가 아니어서 스킬이 **되묻고 exit 0 으로 끝났고**,
    앱은 그것을 done 으로 기록했다 — 적재는 하나도 안 됐는데 성공으로 보였다. 완료의
    유일한 근거는 `apps/learning/skill/SKILL.md` §5 의 완료 표시이고, 그것도 자기보고이므로
    산출물이 라이브러리에 실제로 있는지까지 본다.

    저장 헬퍼를 쓴 스킬은 영수증을 남긴다. 그러면 판정은 **자기보고 두 개(마커·exit) +
    기계가 쓴 것 하나(영수증) + 지금 그 자리의 파일**이 된다. 영수증이 없어도 판정은
    되지만 그때 무엇이 빠졌는지는 fields 에 적힌다 — 조용히 같은 것으로 치지 않는다.
    """
    if return_code != 0:
        return "failed", {
            "exit_code": return_code, "reason": "cli-failed",
            "error": f"에이전트 CLI 가 exit {return_code}로 끝났습니다",
        }
    if not produced_output:
        return "failed", {
            "exit_code": return_code, "reason": "no-output",
            "error": "에이전트 CLI 가 아무 출력 없이 끝났습니다",
        }
    document = _completion_document(log_path)
    if document is None:
        # 🔴 이해하지 못한 이벤트가 로그에 있으면 원인이 다르다 — 스킬이 멈춘 게 아니라
        #    **우리가 CLI 의 출력 형식을 못 읽은 것**이다. 그 둘을 같은 문장으로 보고하면
        #    사람은 스킬을 고치러 가고, 고칠 곳은 여기다.
        unknown = read_log(log_path, INGEST_UNKNOWN_SCAN_BYTES).count(
            PROVIDERS.UNKNOWN_EVENT_PREFIX)
        if unknown:
            return "failed", {
                "exit_code": return_code, "reason": "unreadable-stream",
                "error": f"에이전트 CLI 의 출력에서 이해하지 못한 줄이 {unknown}개 있었고 "
                         "적재 완료 표시를 찾지 못했습니다 — CLI 의 출력 형식이 바뀌었을 수 "
                         "있습니다. 로그의 `[원문]` 줄을 보십시오",
            }
        return "failed", {
            "exit_code": return_code, "reason": "no-completion-marker",
            "error": "에이전트 CLI 가 exit 0으로 끝났지만 적재 완료 표시가 없습니다 — "
                     "스킬이 되묻거나 중간에 멈춘 것입니다",
        }
    # 영수증이 **없는 것**과 **있는데 못 읽는 것**은 다르다. 앞은 헬퍼를 쓰지 않은 스킬이고,
    # 뒤는 헬퍼가 쓰다 만 것이거나 누군가 건드린 것이다 — 뒤를 앞으로 접어 넣으면 그것이
    # 바로 조용한 통과가 된다.
    receipt = None
    if receipt_path and os.path.exists(receipt_path):
        receipt = SAVE.read_receipt(receipt_path)
        if receipt is None:
            return "failed", {
                "exit_code": return_code, "reason": "receipt-unreadable",
                "error": "저장 영수증이 있는데 읽을 수 없습니다 — 적재가 무엇을 남겼는지 "
                         "확인할 수 없습니다",
            }
    reason, error = _verify_document(repo, document, row.get("video_id"), receipt)
    if reason is not None:
        return "failed", {"exit_code": return_code, "reason": reason, "error": error}
    return "done", {
        "exit_code": return_code,
        "reason": "completed" if receipt else "completed-without-receipt",
        "document": document,
    }


def attach_summary(state, fields, log_path):
    """실패 이유를 사람 문장으로 붙인다. **행을 종결하기 전에** 붙인다.

    🔴 종결 뒤에 따로 붙이면 "이 요약이 어느 실행의 것인가"를 지키는 가드가 필요해진다 —
    이전 구조가 `finished_at` 스탬프를 비교해야 했던 이유가 그것이다. 여기서는 워커가
    행을 쥐고 있는 동안 한 번에 쓰므로 그 질문 자체가 생기지 않는다.
    """
    if state != "failed" or not failure_summary_enabled():
        return fields
    summary, error = summarize_failure(read_log(log_path))
    if summary:
        fields["failure_summary"] = summary
    else:
        fields["failure_summary_error"] = error
    return fields


def run_attempt(conn, paths, row):
    state_dir = paths["state"]
    attempt_id = row["id"]
    log_path = QUEUE.log_path(state_dir, attempt_id)
    append_log(log_path, f"[ingest] #{attempt_id} 실행을 시작했습니다 — {row['url']}\n")

    try:
        provider, binary, reason = resolve_provider()
    except FileNotFoundError as exc:
        QUEUE.finish(conn, attempt_id, "failed", now_iso(),
                     reason="cli-missing", error=str(exc))
        return
    append_log(log_path, f"[ingest] {reason} — {binary}\n")

    argv = provider.build_argv(binary, build_prompt(row, state_dir))

    # 스킬이 저장 헬퍼를 찾고 이 시도의 영수증을 어디에 쓸지 아는 유일한 통로다. 스킬이
    # 설치 경로를 알아맞히게 하지 않는다 — 앱이 어디에 깔렸는지는 앱이 안다.
    receipt_path = QUEUE.receipt_path(state_dir, attempt_id)
    os.makedirs(os.path.dirname(receipt_path), exist_ok=True)
    # 영수증 이름은 시도 번호라 보통은 새 파일이다 — 재시도는 새 번호를 받고, 죽은
    # `running` 행은 재실행이 아니라 실패로 종결된다(`mark_dead_running`). 그래도 지우는
    # 이유는 하나다: 남아 있는 파일이 있다면 그것은 **이 실행이 만들지 않은 것**이고
    # (상태 DB 만 초기화됐거나 백업에서 되돌린 경우), 그걸 이번 증거로 읽으면 하지도 않은
    # 저장이 완료로 판정된다.
    try:
        os.unlink(receipt_path)
    except FileNotFoundError:
        pass
    except OSError as exc:
        QUEUE.finish(conn, attempt_id, "failed", now_iso(), reason="receipt-unwritable",
                     error=f"이전 시도의 저장 영수증을 지우지 못했습니다: {exc}")
        return
    child_env = provider.build_env(os.environ)
    stripped = unsafe_anthropic_env()
    if stripped:
        append_log(log_path, "[ingest] 종량 과금으로 붙을 수 있는 환경 변수를 자식에서 "
                             "지웠습니다: " + ", ".join(sorted(stripped))
                             + " — 적재는 로그인된 구독으로 돕니다\n")
    child_env["AIRLOCK_LEARNING_LIBRARY"] = paths["repo"]
    child_env["AIRLOCK_LEARNING_STATE_DIR"] = state_dir
    child_env["AIRLOCK_LEARNING_RECEIPT"] = receipt_path
    child_env["AIRLOCK_LEARNING_SAVE"] = SAVE_PATH

    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    log_file = os.fdopen(os.open(log_path, flags, 0o600), "ab", buffering=0)
    try:
        before = os.fstat(log_file.fileno()).st_size
        try:
            process = subprocess.Popen(
                argv, cwd=paths["repo"], shell=False, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=log_file, start_new_session=True,
                env=child_env,
            )
        except OSError as exc:
            QUEUE.finish(conn, attempt_id, "failed", now_iso(),
                         reason="cli-start-failed", error=f"에이전트 CLI 를 실행하지 못했습니다: {exc}")
            return

        # 🔴 펌프 스레드는 **로그만 쓴다.** SQLite 연결은 만든 스레드에서만 쓸 수 있고
        #    (`sqlite3.ProgrammingError`), 그보다 앞서 "누가 DB 를 쓰나"를 하나로 두는 것이
        #    이 재설계의 규칙이다. 스레드는 받은 메타를 상자에 담아만 두고, 아래 폴링 루프가
        #    자기 스레드에서 옮긴다. 실측 2026-08-18: 이 구분이 없을 때 스레드가 첫 메타에서
        #    죽었고, 그 바람에 **완료 표시가 로그에 실리지 못해 성공한 적재가 실패로 판정됐다.**
        pending_meta = {}
        meta_guard = threading.Lock()
        seen_meta = {}

        def remember_meta(meta):
            with meta_guard:
                pending_meta.update(meta)

        def flush_meta():
            with meta_guard:
                fresh = {k: v for k, v in pending_meta.items() if seen_meta.get(k) != v}
                pending_meta.clear()
            if fresh:
                seen_meta.update(fresh)
                QUEUE.set_meta(conn, attempt_id, **fresh)

        pump = threading.Thread(target=_pump_stream, args=(process.stdout, log_file),
                                kwargs={"on_meta": remember_meta, "provider": provider},
                                daemon=True)
        pump.start()

        budget = timeout_seconds()
        started = time.monotonic()
        stopped_by = None
        while process.poll() is None:
            flush_meta()
            if QUEUE.cancel_requested(conn, attempt_id):
                stopped_by = "cancelled"
                break
            if STOPPING:
                stopped_by = "worker-stopping"
                break
            if time.monotonic() - started > budget:
                stopped_by = "timeout"
                break
            time.sleep(POLL_SECONDS)

        if stopped_by is not None:
            _terminate(process, log_path)
            pump.join(timeout=10)
            if stopped_by == "cancelled":
                QUEUE.finish(conn, attempt_id, "cancelled", now_iso(), reason="cancelled")
                append_log(log_path, "[ingest] 취소했습니다\n")
                return
            error = ({"timeout": f"에이전트 CLI 가 {budget:g}초 안에 끝나지 않았습니다",
                      "worker-stopping": "워커가 종료되어 적재를 중단했습니다"}[stopped_by])
            fields = attach_summary("failed", {"reason": stopped_by, "error": error}, log_path)
            QUEUE.finish(conn, attempt_id, "failed", now_iso(), **fields)
            return

        pump.join(timeout=10)   # 남은 줄을 다 옮긴 뒤 판정한다(마커가 마지막 줄에 온다)
        flush_meta()
        produced = os.fstat(log_file.fileno()).st_size != before
        state, fields = verdict(paths["repo"], row, process.returncode, log_path, produced,
                                receipt_path)
        fields = attach_summary(state, fields, log_path)
        QUEUE.finish(conn, attempt_id, state, now_iso(), **fields)
        if state == "done":
            append_log(log_path, f"[ingest] 완료 — {fields.get('document')}\n")
            if fields.get("reason") == "completed-without-receipt":
                # 판정은 통과했지만 증거 하나가 없었다. 스킬이 저장 헬퍼를 쓰지 않고
                # 자기 도구로 파일을 쓴 것이다 — 되긴 되고, 원자성과 다이제스트 대조는
                # 못 받는다. 조용히 같은 것으로 치지 않는다.
                append_log(log_path,
                           "[ingest] 참고 — 저장 영수증이 없어 파일 자체만으로 판정했습니다"
                           f" (스킬이 {SAVE_PATH} 를 쓰면 원자적 저장과 다이제스트 대조가"
                           " 함께 붙습니다)\n")
    finally:
        log_file.close()


def _terminate(process, log_path):
    """SIGTERM 을 먼저 주고, 유예가 지나면 프로세스 그룹째 SIGKILL 한다."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (ProcessLookupError, OSError):
        pass
    deadline = time.monotonic() + TERM_GRACE_SECONDS
    while process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.5)
    errors = _kill_process(process)
    if errors:
        append_log(log_path, "[ingest] 프로세스 종료 경고: " + "; ".join(errors) + "\n")


def main(argv=None):
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    paths = BACKEND.configured_paths()
    state_dir = paths["state"]
    lock = acquire_singleton(state_dir)
    if lock is None:
        print("적재 워커가 이미 돌고 있습니다", file=sys.stderr)
        return 1

    conn = QUEUE.connect(state_dir)
    try:
        recovered = QUEUE.recover_interrupted(conn, now_iso())
        if recovered:
            print(f"중단된 적재 {recovered}건을 실패로 확정했습니다", file=sys.stderr)
        # 🔴 커밋은 큐 바깥에 산다. 적재 판정은 파일이 디스크에 있는지로 끝나고
        #    (그 결합을 떼는 것이 이 앱의 재설계였다), git 은 그 뒤에 따로 따라온다.
        #    워커에 두는 이유는 이 앱의 규칙 그대로다 — 라이브러리에 쓰는 주체는 하나여야
        #    하고, 별표 한 번에 push 한 번이 붙으면 화면이 네트워크를 기다리게 된다.
        ticker = GITSYNC.Ticker()

        def git_tick(force=False):
            ticker.tick(paths["repo"], state_dir,
                        BACKEND.library_categories(paths["repo"]),
                        log=lambda line: print(line, file=sys.stderr), force=force)

        while not STOPPING:
            row = QUEUE.claim_next(conn, now_iso())
            if row is None:
                git_tick()
                time.sleep(POLL_SECONDS)
                continue
            run_attempt(conn, paths, row)
            # 방금 문서가 생겼다. 다음 주기를 기다리지 않는다 — 사용자가 지금 보고 있다.
            git_tick(force=True)
    finally:
        conn.close()
        lock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
