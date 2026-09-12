#!/usr/bin/env python3
"""영상 하나의 메타와 전사본을 가져온다 — 적재 스킬이 §1 에서 부르는 도구.

이 파일이 존재하는 이유는 경계 하나다. 이 앱이 나온 원래 환경에서는 전사본을 **별도 레포의
공용 스킬**에서 받고, 자막이 없으면 로컬 whisper venv(모델 수 GB + ffmpeg)로 넘어간다.
둘 다 이 패키지가 실어 나를 수 있는 것이 아니다 — 하나는 남의 레포이고 하나는 앱 하나가
지기엔 너무 무거운 의존이다.

그래서 여기서 하는 것은 **자막 취득 하나**다. 자막이 없는 영상은 v1 의 범위 밖이라고
말한다. whisper 를 끌고 들어와 설치를 무겁게 만드는 것보다, 안 되는 것을 안 된다고
말하는 편이 낫다.

🔴 자막 포맷은 **json3 를 청한다.** 자동자막 VTT 는 같은 문장이 2~3회 반복되는
rolling duplication 에 단어별 태그까지 붙어서, 정제를 전제하지 않으면 요약이 같은 말을
세 번 읽는다. json3 는 이벤트마다 시작 시각과 텍스트가 한 번씩만 있다. (이 판단의
출처는 회사 공용 스크립트의 같은 결정이다 — 코드가 아니라 이유를 가져왔다.)

🔴 json3 가 **안 올 수도 있다.** yt-dlp 는 그 포맷이 없으면 조용히 다른 것을 받아 온다.
그때 "자막이 없다" 고 말하면 자막이 **있는** 영상을 거부하는 것이 된다 — 그래서 무엇이
왔는지를 사유에 적는다. 받아 온 다른 포맷을 파싱하지는 않는다(파서가 하나 더 늘고, 그
파서가 정확히 우리가 피하려던 중복을 다뤄야 한다). 지금은 정직하게 말하는 데서 멈춘다.

사람 자막이 있으면 그것을 먼저 쓴다. 자동자막은 받아쓰기라 고유명사와 숫자가 틀린다.
어느 쪽을 썼는지 결과에 싣고, 문서에도 한 줄로 남는다.

    python3 transcript.py --url <url> --out <경로>

성공하면 JSON 한 줄을 표준출력에 찍고 exit 0. 실패하면 사람이 읽을 문장을 표준오류에
찍고 exit 2 — 그리고 `--out` 은 만들지 않는다.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

YT_DLP_TIMEOUT_SECONDS = 300
# 🔴 유튜브의 레이트리밋은 IP 단위이고, 여러 영상을 잇달아 적재하면 반드시 만난다.
#    한 번 맞고 포기하면 되는 영상이 "자막 없음" 으로 기록된다 — 몇십 초 기다리면 대개
#    통과한다(실측 2026-09-04~05: 429 8건 중 6건이 재시도·우회로 결국 성공).
YT_DLP_RETRY_DELAYS = (5, 15, 45)
# 🔴 기다려도 안 되면 **다른 문으로** 청한다. 유튜브의 스로틀은 클라이언트마다 따로 걸리고,
#    web 이 막힌 동안 android 는 통과한다 (실측 2026-09-04: 429 로 두 번 죽은 영상이
#    이 인자 하나로 자막을 냈다. ios·tv 는 같은 영상에서 포맷 오류를 냈다 — 그래서
#    후보를 늘리지 않고 실제로 통과한 하나만 쓴다).
YT_DLP_LAST_RESORT = ["--extractor-args", "youtube:player_client=android"]
# 영상 id 는 URL 이 무엇이든 이 모양이다. 저장 헬퍼의 프론트매터 검사와 같은 문자 집합.
VIDEO_ID_RE = re.compile(r"\A[A-Za-z0-9_-]{1,128}\Z")


ERROR_SENTINEL = "LEARNING-INGEST-ERROR"
ERROR_CODES = {
    "tool-missing",
    "rate-limited",
    "video-unavailable",
    "metadata-invalid",
    "no-subs",
    "subtitle-unreadable",
    "transcript-write-failed",
}


def die(message, error):
    if error not in ERROR_CODES:
        raise ValueError(f"unknown learning ingest error: {error}")
    print(message, file=sys.stderr)
    print(f'{ERROR_SENTINEL} {json.dumps({"error": error}, separators=(",", ":"))}',
          file=sys.stderr)
    raise SystemExit(2)


def yt_dlp():
    found = shutil.which("yt-dlp")
    if not found:
        die("yt-dlp 을 찾지 못했습니다 — 자막을 받으려면 필요합니다. "
            "`pip install --user yt-dlp` 또는 배포판 패키지로 설치하십시오",
            "tool-missing")
    return found


def run(argv, failure_code="video-unavailable", **kwargs):
    try:
        return subprocess.run(argv, shell=False, capture_output=True,
                              timeout=YT_DLP_TIMEOUT_SECONDS, **kwargs)
    except subprocess.TimeoutExpired:
        die(f"yt-dlp 이 {YT_DLP_TIMEOUT_SECONDS}초 안에 끝나지 않았습니다",
            failure_code)
    except OSError as exc:
        die(f"yt-dlp 을 실행하지 못했습니다: {exc}", "tool-missing")


def rate_limited(stderr):
    text = stderr.decode("utf-8", "replace")
    return "429" in text or "Too Many Requests" in text


def run_patiently(argv, sleep=None, failure_code="video-unavailable"):
    """429 면 잠깐 기다렸다 다시 청한다. 다른 실패는 그대로 돌려준다 — 재시도가 고칠 수
    있는 것은 레이트리밋뿐이고, 지역차단·삭제된 영상을 세 번 더 물어봐야 답은 같다."""
    sleep = time.sleep if sleep is None else sleep
    for delay in YT_DLP_RETRY_DELAYS:
        result = run(argv, failure_code=failure_code)
        if result.returncode == 0 or not rate_limited(result.stderr):
            return result
        sleep(delay)
    result = run(argv, failure_code=failure_code)
    if result.returncode == 0 or not rate_limited(result.stderr):
        return result
    if YT_DLP_LAST_RESORT[0] in argv:
        return result
    return run(argv + YT_DLP_LAST_RESORT, failure_code=failure_code)


def source_language(info):
    """이 영상이 실제로 말하는 언어. 없으면 None.

    🔴 `language` 필드를 믿지 않는다. 유튜브는 한국어 영상에 `en` 을 달아 두기도 하고
       (실측 2026-09-04: lpFevXDUAxg 가 그랬다), 그러면 원어 자막이 멀쩡히 있는데도
       영어 **기계번역**을 받아 요약이 번역본에서 만들어진다.

    자막 목록이 더 정직하다. 자동자막은 원어 하나만 `<언어>-orig` 로 오고 나머지 백여
    개는 그것을 번역한 것이라, `-orig` 가 붙은 키가 곧 원어의 이름이다. 사람 자막밖에
    없으면 그건 사람이 올린 것이니 그대로 믿는다.
    """
    auto = info.get("automatic_captions")
    if isinstance(auto, dict):
        for name in sorted(auto):
            if name.endswith("-orig"):
                return name[: -len("-orig")]
    manual = info.get("subtitles")
    if isinstance(manual, dict) and manual:
        declared = info.get("language")
        if declared in manual:
            return declared
        return sorted(manual)[0]
    return info.get("language")


def _track_names(tracks):
    if not isinstance(tracks, dict):
        return []
    return sorted(name for name in tracks if isinstance(name, str) and name)


def caption_choice(info):
    """(플래그, 종류, 정확한 자막 코드) 하나. 없으면 None.

    메타데이터에 실제로 있는 트랙 하나만 고른다. 우선순위는 사람 자막 원어 → 사람
    자막 그 밖 → 자동 자막 원어(`-orig`) → 자동 자막 그 밖이다. `--sub-langs` 에
    후보를 여러 개 넘기면 하나가 429 일 때 이미 받은 자막까지 실패하므로, 이 함수에서
    요청 언어를 하나로 확정한다.
    """
    language = source_language(info)
    manual = _track_names(info.get("subtitles"))
    automatic = _track_names(info.get("automatic_captions"))

    # 사람 자막은 원어의 정확한 언어 코드가 있을 때 먼저 쓴다. 원어를 모르면
    # 아래의 "그 밖" 순서로만 고른다.
    if language and language in manual:
        return "--write-subs", "manual", language
    if manual:
        return "--write-subs", "manual", manual[0]

    # 자동자막의 원어는 source_language()가 찾아낸 <언어>-orig 키다. 접미사가 없는
    # 자동자막은 그 뒤의 일반 후보로만 취급한다.
    original = f"{language}-orig" if language else None
    if original and original in automatic:
        return "--write-auto-subs", "auto", original
    if automatic:
        return "--write-auto-subs", "auto", automatic[0]
    return None


def metadata(binary, url):
    # 🔴 `--no-playlist` 가 없으면 `list=` 가 붙은 평범한 watch 주소에서 yt-dlp 가 영상마다
    #    JSON 을 한 줄씩 내고 `json.loads` 가 죽는다. 재생목록에서 복사한 주소는 흔하고,
    #    접수는 그것을 통과시킨다 — 앱이 받아 놓고 워커가 이해 못 할 문장으로 실패한다.
    result = run_patiently([binary, "--skip-download", "--dump-json", "--no-playlist",
                            "--no-warnings", url])
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        # 🔴 낡은 yt-dlp 는 여기서 403 을 낸다. 그 경우 원인은 URL 이 아니라 도구다.
        hint = ("\n(yt-dlp 이 낡으면 403 이 납니다 — 최신으로 올려 보십시오)"
                if "403" in detail else "")
        error = "rate-limited" if rate_limited(result.stderr) else "video-unavailable"
        die(f"영상 정보를 읽지 못했습니다: {detail[:400]}{hint}", error)
    try:
        data = json.loads(result.stdout.decode("utf-8", "replace"))
    except ValueError as exc:
        die(f"영상 정보를 해석하지 못했습니다: {exc}", "metadata-invalid")
    if not isinstance(data, dict):
        die("영상 정보가 JSON 객체가 아닙니다", "metadata-invalid")
    return data


def hms(seconds):
    seconds = int(max(0, seconds))
    return f"{seconds // 3600:02d}:{seconds // 60 % 60:02d}:{seconds % 60:02d}"


def subtitle_events(binary, url, workdir, info, failures=None, failure_code=None):
    """(이벤트 목록, 종류). 자막이 없으면 (None, None). 실패 사유는 `failures` 에 쌓인다.

    `info` 에서 이미 고른 트랙 하나만 요청한다. 트랙이 없으면 호출하지 않고 반환한다.
    자동자막은 받아쓰기라 고유명사와 숫자가 틀린다.
    """
    failures = [] if failures is None else failures
    choice = caption_choice(info)
    if choice is None:
        return None, None
    flag, kind, code = choice
    for name in os.listdir(workdir):
        os.unlink(os.path.join(workdir, name))   # 이전 산출물을 이번 것으로 읽지 않는다
    # 🔴 언어를 안 주면 yt-dlp 는 **영어를 고른다.** 선택한 코드 하나를 항상 명시한다.
    argv = [binary, "--skip-download", flag, "--sub-format", "json3",
            "--sub-langs", code, "--no-playlist", "--no-warnings",
            "-o", os.path.join(workdir, "s.%(ext)s"), url]
    result = run_patiently(argv, failure_code="subtitle-unreadable")
    label = f"{kind}/{code}"
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        if detail:
            failures.append(f"{label}: {detail.splitlines()[-1][:200]}")
        error = "rate-limited" if rate_limited(result.stderr) else "subtitle-unreadable"
        if failure_code is not None:
            failure_code.append(error)
        return None, None
    landed = sorted(os.listdir(workdir))
    hits = [name for name in landed if name.endswith(".json3")]
    if not hits:
        if landed:
            failures.append(f"{label}: json3 자막이 없습니다 (받은 것: {', '.join(landed)})")
        if failure_code is not None:
            failure_code.append("subtitle-unreadable")
        return None, None
    try:
        with open(os.path.join(workdir, hits[0]), "r", encoding="utf-8") as handle:
            payload = json.load(handle)
        events = payload.get("events") if isinstance(payload, dict) else None
    except (OSError, ValueError, TypeError):
        events = None
    if isinstance(events, list) and events:
        return events, kind
    if failure_code is not None:
        failure_code.append("subtitle-unreadable")
    return None, None


def lines_from(events):
    """[(시작 초, 문장)] — 빈 이벤트와 개행 전용 이벤트는 버린다."""
    out = []
    for event in events:
        if not isinstance(event, dict):
            continue
        segs = event.get("segs")
        if not isinstance(segs, list):
            continue
        text = "".join(seg.get("utf8", "") for seg in segs if isinstance(seg, dict))
        text = " ".join(text.split())
        if not text:
            continue
        start = event.get("tStartMs")
        out.append((int(start) / 1000.0 if isinstance(start, (int, float)) else 0.0, text))
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="transcript.py", description="영상의 메타와 전사본을 가져온다")
    parser.add_argument("--url", required=True)
    parser.add_argument("--out", required=True, help="전사본을 쓸 경로")
    args = parser.parse_args(argv)

    binary = yt_dlp()
    info = metadata(binary, args.url)
    video_id = str(info.get("id") or "")
    if not VIDEO_ID_RE.fullmatch(video_id):
        die(f"영상 id 를 읽지 못했습니다: {video_id!r}", "metadata-invalid")

    # 메타데이터가 알려 준 트랙이 없으면 자막 요청 자체를 하지 않는다. 음성 인식으로
    # 우회하지 않는 것은 스킬 계약이다.
    if caption_choice(info) is None:
        die("이 영상은 자막이 없어 적재할 수 없습니다", "no-subs")

    failures = []
    failure_code = []
    with tempfile.TemporaryDirectory(prefix="airlock-learning-subs-") as workdir:
        events, kind = subtitle_events(binary, args.url, workdir,
                                       info, failures, failure_code)
    if not events:
        detail = "자막을 받지 못했습니다"
        if failures:
            detail += " — " + " / ".join(failures)
        die(detail, failure_code[-1] if failure_code else "subtitle-unreadable")

    lines = lines_from(events)
    if not lines:
        die("자막 파일은 받았지만 읽을 문장이 하나도 없습니다", "subtitle-unreadable")

    body = "\n".join(f"**[{hms(start)}]** {text}" for start, text in lines)
    # 🔴 임시 파일에 쓰고 이름을 바꾼다. 대상에 바로 쓰면 실패했을 때 **반쯤 쓰인 전사본**이
    #    남고("실패하면 --out 은 만들지 않는다" 는 계약을 깨고), 다음 시도가 그것을 이번
    #    것으로 읽는다 — 문서 저장이 원자적인 것과 같은 이유다.
    out = os.path.abspath(args.out)
    directory = os.path.dirname(out) or "."
    try:
        os.makedirs(directory, exist_ok=True)
        handle_fd, tmp = tempfile.mkstemp(prefix=".airlock-transcript-", dir=directory)
        try:
            with os.fdopen(handle_fd, "w", encoding="utf-8") as handle:
                handle.write(body + "\n")
            os.replace(tmp, out)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    except (OSError, UnicodeError) as exc:
        die(f"전사본을 쓰지 못했습니다: {exc}", "transcript-write-failed")

    duration = info.get("duration")
    print(json.dumps({
        "video_id": video_id,
        "title": info.get("title") or "",
        "channel": info.get("uploader") or info.get("channel") or "",
        "duration": hms(duration) if isinstance(duration, (int, float)) else "",
        "upload_date": info.get("upload_date") or "",
        "url": info.get("webpage_url") or args.url,
        "subs": kind,
        "transcript_path": out,
        "transcript_lines": len(lines),
    }, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
