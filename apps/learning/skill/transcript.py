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


def die(message):
    print(message, file=sys.stderr)
    raise SystemExit(2)


def yt_dlp():
    found = shutil.which("yt-dlp")
    if not found:
        die("yt-dlp 을 찾지 못했습니다 — 자막을 받으려면 필요합니다. "
            "`pip install --user yt-dlp` 또는 배포판 패키지로 설치하십시오")
    return found


def run(argv, **kwargs):
    try:
        return subprocess.run(argv, shell=False, capture_output=True,
                              timeout=YT_DLP_TIMEOUT_SECONDS, **kwargs)
    except subprocess.TimeoutExpired:
        die(f"yt-dlp 이 {YT_DLP_TIMEOUT_SECONDS}초 안에 끝나지 않았습니다")
    except OSError as exc:
        die(f"yt-dlp 을 실행하지 못했습니다: {exc}")


def rate_limited(stderr):
    text = stderr.decode("utf-8", "replace")
    return "429" in text or "Too Many Requests" in text


def run_patiently(argv, sleep=None):
    """429 면 잠깐 기다렸다 다시 청한다. 다른 실패는 그대로 돌려준다 — 재시도가 고칠 수
    있는 것은 레이트리밋뿐이고, 지역차단·삭제된 영상을 세 번 더 물어봐야 답은 같다."""
    sleep = time.sleep if sleep is None else sleep
    for delay in YT_DLP_RETRY_DELAYS:
        result = run(argv)
        if result.returncode == 0 or not rate_limited(result.stderr):
            return result
        sleep(delay)
    result = run(argv)
    if result.returncode == 0 or not rate_limited(result.stderr):
        return result
    if YT_DLP_LAST_RESORT[0] in argv:
        return result
    return run(argv + YT_DLP_LAST_RESORT)


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


def language_rounds(language):
    """자막 언어를 청하는 순서. 영상이 자기 언어를 말하면 **그것만** 먼저 청하고, `en` 은
    그 라운드가 빈손일 때의 대비책으로 미룬다.

    🔴 한 번에 `ko,ko-orig,en` 을 청하면 안 된다. yt-dlp 는 청한 언어 중 **하나라도**
       못 받으면 비영 종료라, ko 자막을 이미 손에 쥐고도 en 하나의 429 로 전체가 실패한다
       (실측 2026-09-02~05: 잡 118건 중 18건이 이 경로로 죽었고 실패 사유는 전부
       `for 'en'` 이었다). 요청 수도 영상마다 두 배가 되어 레이트리밋을 스스로 앞당긴다.
    """
    if language and language != "en":
        return ([language, f"{language}-orig"], ["en"])
    return (["en"],)


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
        die(f"영상 정보를 읽지 못했습니다: {detail[:400]}{hint}")
    try:
        data = json.loads(result.stdout.decode("utf-8", "replace"))
    except ValueError as exc:
        die(f"영상 정보를 해석하지 못했습니다: {exc}")
    return data


def hms(seconds):
    seconds = int(max(0, seconds))
    return f"{seconds // 3600:02d}:{seconds // 60 % 60:02d}:{seconds % 60:02d}"


def attempts(language):
    """(플래그, 종류, 언어목록, 끈질기게) 를 시도할 순서대로. 사람 자막 → 자동자막, 각
    안에서 영상 언어 → en.

    🔴 429 를 기다려 주는 것은 **1순위 라운드에만** 한다. 대비책인 en 라운드에서까지
       세 번 기다리면 영상 하나에 2분이 그냥 사라지는데, 정작 그 영상의 진짜 자막은
       다음 라운드에 있다. 대비책은 한 번 청해 보고 아니면 넘어가는 것이 맞다.
    """
    for flag, kind in (("--write-subs", "manual"), ("--write-auto-subs", "auto")):
        for index, langs in enumerate(language_rounds(language)):
            yield flag, kind, langs, index == 0


def subtitle_events(binary, url, workdir, language=None, failures=None):
    """(이벤트 목록, 종류). 자막이 없으면 (None, None). 실패 사유는 `failures` 에 쌓인다.

    사람 자막 → 자동자막 순서. 사람 자막이 있으면 그것을 먼저 쓴다 — 자동자막은 받아쓰기라
    고유명사와 숫자가 틀린다.
    """
    failures = [] if failures is None else failures
    for flag, kind, langs, patient in attempts(language):
        for name in os.listdir(workdir):
            os.unlink(os.path.join(workdir, name))   # 앞 시도의 산출물을 이번 것으로 읽지 않는다
        # 🔴 언어를 안 주면 yt-dlp 는 **영어를 고른다.** 한국어 영상의 자동자막에 ko 와
        #    en 이 다 있으면 en(기계번역)을 받아 오고, 요약이 번역본에서 만들어진다
        #    (적대검증 2026-08-22 실측). 그래서 언제나 명시해서 청한다.
        argv = [binary, "--skip-download", flag, "--sub-format", "json3",
                "--sub-langs", ",".join(langs),
                "--no-playlist", "--no-warnings",
                "-o", os.path.join(workdir, "s.%(ext)s"), url]
        result = run_patiently(argv) if patient else run(argv)
        label = f"{kind}/{','.join(langs)}"
        if result.returncode != 0:
            # 🔴 실패 사유를 버리지 않는다. 버리면 429·지역차단·인증요구가 전부 "자막이
            #    없습니다" 로 세탁된다 — 사용자는 되는 영상을 안 된다고 읽고, 그 오해를
            #    풀 방법이 없다.
            detail = result.stderr.decode("utf-8", "replace").strip()
            if detail:
                failures.append(f"{label}: {detail.splitlines()[-1][:200]}")
            continue
        landed = sorted(os.listdir(workdir))
        hits = [name for name in landed if name.endswith(".json3")]
        if not hits:
            if landed:
                # 자막은 왔는데 json3 가 아니다. "없다" 와 전혀 다른 사건이다.
                failures.append(f"{label}: json3 자막이 없습니다 (받은 것: {', '.join(landed)})")
            continue
        try:
            with open(os.path.join(workdir, hits[0]), "r", encoding="utf-8") as handle:
                payload = json.load(handle)
        except (OSError, ValueError):
            continue
        events = payload.get("events")
        if isinstance(events, list) and events:
            return events, kind
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
        die(f"영상 id 를 읽지 못했습니다: {video_id!r}")

    failures = []
    with tempfile.TemporaryDirectory(prefix="airlock-learning-subs-") as workdir:
        events, kind = subtitle_events(binary, args.url, workdir,
                                       source_language(info), failures)
    if not events:
        if failures:
            die("자막을 받지 못했습니다 — " + " / ".join(failures))
        die("이 영상에는 자막이 없습니다 — 자막 없는 영상의 적재는 아직 지원하지 않습니다. "
            "(기계 전사를 붙이면 되지만 모델 파일 수 GB 가 설치에 따라붙습니다.)")

    lines = lines_from(events)
    if not lines:
        die("자막 파일은 받았지만 읽을 문장이 하나도 없습니다")

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
    except OSError as exc:
        die(f"전사본을 쓰지 못했습니다: {exc}")

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
