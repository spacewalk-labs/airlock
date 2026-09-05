#!/usr/bin/env python3
"""learning 앱의 자막 취득이 유튜브 레이트리밋에 무너지지 않는지 고정한다.

지키는 계약은 하나다 — **부수 언어 하나의 429 가 이미 손에 쥔 자막을 버리게 하지 않는다.**
yt-dlp 는 `--sub-langs` 로 청한 언어 중 하나라도 못 받으면 비영으로 끝난다. 그래서 한국어
영상에 `ko,ko-orig,en` 을 한 번에 청하면, ko 자막이 정상으로 와 있어도 en 의 429 하나로
전체가 "자막 없음" 이 된다 (실측 2026-09-02~05: 적재 잡 118건 중 18건이 이 경로로 죽었고
실패 사유는 전부 `for 'en'` 이었다).

yt-dlp 는 부르지 않는다 — 네트워크와 유튜브의 그날 기분에 CI 를 매달지 않기 위해, 실행되는
argv 를 가로채 무엇을 청했는지로 판정한다.
"""

import importlib.util
import json
import os
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(HERE, os.pardir, "apps", "learning", "skill", "transcript.py")

EVENTS = {"events": [{"tStartMs": 0, "segs": [{"utf8": "안녕하세요"}]}]}
RATE_LIMITED = (b"ERROR: Unable to download video subtitles: "
                b"HTTP Error 429: Too Many Requests")


def load():
    spec = importlib.util.spec_from_file_location("transcript", TARGET)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def result(returncode, stderr=b""):
    return types.SimpleNamespace(returncode=returncode, stderr=stderr, stdout=b"")


def harness(module, workdir, have, throttled=("en",)):
    """(청한 것 목록, 잔 시간 목록). `have` 에 있는 (종류, 언어) 만 자막을 낸다."""
    asked, naps = [], []
    module.time = types.SimpleNamespace(sleep=naps.append)

    def run(argv, **kwargs):
        kind = "manual" if "--write-subs" in argv else "auto"
        langs = argv[argv.index("--sub-langs") + 1]
        asked.append((kind, langs))
        if langs in throttled:
            return result(1, RATE_LIMITED)
        if (kind, langs) in have:
            path = os.path.join(workdir, "s.sub.json3")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(EVENTS, handle)
        return result(0)

    module.run = run
    return asked, naps


def check(name, condition, detail=""):
    if not condition:
        print(f"FAIL  {name}{(' — ' + str(detail)) if detail else ''}", file=sys.stderr)
        return False
    print(f"ok    {name}")
    return True


def main():
    module = load()
    passed = True

    passed &= check(
        "영상 언어를 먼저, en 은 대비책으로",
        module.language_rounds("ko") == (["ko", "ko-orig"], ["en"])
        and module.language_rounds("en") == (["en"],)
        and module.language_rounds(None) == (["en"],),
        module.language_rounds("ko"))

    # 급소. 이 검사가 잡는 결함이 실제로 18건을 죽였다.
    with tempfile.TemporaryDirectory() as workdir:
        asked, naps = harness(module, workdir, {("auto", "ko,ko-orig")})
        events, kind = module.subtitle_events("yt-dlp", "u", workdir, "ko", [])
        passed &= check("en 이 429 여도 한국어 자막으로 성공한다",
                        events and kind == "auto", (events, kind))
        passed &= check("자막을 얻었으면 en 을 더 청하지 않는다",
                        ("auto", "en") not in asked, asked)
        passed &= check("대비책 라운드에서는 429 를 기다리지 않는다", naps == [], naps)

    with tempfile.TemporaryDirectory() as workdir:
        asked, _ = harness(module, workdir, {("manual", "ko,ko-orig")})
        events, kind = module.subtitle_events("yt-dlp", "u", workdir, "ko", [])
        passed &= check("사람 자막이 있으면 요청 한 번으로 끝난다",
                        events and kind == "manual" and asked == [("manual", "ko,ko-orig")],
                        asked)

    with tempfile.TemporaryDirectory() as workdir:
        asked, _ = harness(module, workdir, set(), throttled=())
        module.subtitle_events("yt-dlp", "u", workdir, "en", [])
        passed &= check("영어 영상은 같은 언어를 두 번 청하지 않는다",
                        asked == [("manual", "en"), ("auto", "en")], asked)

    # 1순위 라운드의 429 는 기다려 준다 — 재시도가 실제로 고칠 수 있는 유일한 실패다.
    with tempfile.TemporaryDirectory() as workdir:
        _, naps = harness(module, workdir, set(), throttled=("ko,ko-orig",))
        module.subtitle_events("yt-dlp", "u", workdir, "ko", [])
        passed &= check("1순위 언어의 429 는 물러서서 다시 청한다",
                        naps == list(module.YT_DLP_RETRY_DELAYS) * 2, naps)

    with tempfile.TemporaryDirectory() as workdir:
        failures = []
        harness(module, workdir, set())
        module.subtitle_events("yt-dlp", "u", workdir, "ko", failures)
        passed &= check("실패 사유에 어느 언어였는지가 남는다",
                        any(item.startswith("manual/en") and "429" in item
                            for item in failures), failures)

    # 429 가 아닌 실패를 세 번 더 물어봐야 답은 같다. 시간만 잃는다.
    calls, naps = [], []
    module.time = types.SimpleNamespace(sleep=naps.append)
    module.run = lambda argv, **kwargs: (calls.append(argv),
                                         result(1, b"ERROR: Video unavailable"))[1]
    outcome = module.run_patiently(["yt-dlp"])
    passed &= check("429 가 아닌 실패는 재시도하지 않는다",
                    len(calls) == 1 and naps == [] and outcome.returncode == 1,
                    (len(calls), naps))

    print("PASS" if passed else "FAIL")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
