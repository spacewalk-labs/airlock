#!/usr/bin/env python3
"""YouTube 영상 → 요약 가능한 마크다운 전사본.

메타(제목·채널·길이·챕터·설명) + 자막을 한 파일로 뽑는다.
자막 우선순위: 사람 자막(manual) > 자동 자막(ASR). 포맷은 json3 고정 — 자동자막 VTT 는
rolling duplication(같은 문장 2~3회 반복) + 단어별 태그라 정제 전제가 필요한데, json3 는
세그먼트가 그대로 구조화돼 있어 파싱이 결정적이다(크기 이득은 없다 — 원본은 오히려 크다).

usage: yt-transcript.py <url> [-l ko] [-o out.md] [--window 30] [--meta-json m.json]
  -l/--lang    자막 언어. **생략 시 영상 원어**(메타의 `language`) → 없으면 en 폴백.
               en 하드코딩이 아니다 — 한국어 영상에서 en 을 받으면 기계번역 트랙이 와서
               ASR 오류 위에 번역 오류가 한 겹 더 얹힌다.
  --window     전사본을 몇 초 단위 문단으로 묶을지 (기본 30)
  --meta-json  메타·자막유무를 JSON 으로 함께 기록. 하위 도구는 이 파일을 읽어라
               (마크다운 되파싱 X, --dump-json 재호출 X). `subs: null` = 자막 없음.

⚠ 자막이 아예 없어도 이 스크립트는 **exit 0 으로 문서를 생성**한다("자막 없음" 안내가 본문에
박힌다). 자동화에서 자막 유무로 분기하려면 exit code 가 아니라 --meta-json 의 `subs` 를 보라.
"""
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"[yt-transcript] 실패: {' '.join(cmd)}\n{p.stderr.strip()[-2000:]}")
    return p.stdout


def hms(sec):
    sec = int(sec)
    return f"{sec // 3600:d}:{sec % 3600 // 60:02d}:{sec % 60:02d}"


def pick_lang(tracks, lang):
    """메타의 자막 트랙 dict 에서 요청 언어에 맞는 **정확한** 코드 하나를 고른다.

    유튜브 수동 자막 코드는 `en-eEY6OEpapPo` 처럼 변형이 붙기도 해서 `en` 완전일치만
    보면 있는 자막을 놓친다. 그렇다고 `--sub-langs "en.*"` 로 넘기면 번역 트랙을 전부
    받으려다 HTTP 429 를 맞는다 → 여기서 후보를 1개로 좁혀 정확 코드로 요청한다.
    """
    if not tracks:
        return None
    cands = [c for c in tracks if c == lang or c.startswith(lang + "-")]
    if not cands:
        return None
    # 원어(-orig) > 완전일치 > 나머지(사전순)
    return sorted(cands, key=lambda c: (not c.endswith("-orig"), c != lang, c))[0]


def fetch_subs(url, langs, meta, tmp):
    """langs 순서대로 manual → auto. (경로, 종류) 반환. 부재는 (None, None), 실패는 종료.

    langs 는 우선순위 목록이다 — 앞이 영상 원어, 뒤가 폴백(en). 앞 언어에 트랙이 아예 없을
    때만 다음으로 내려간다(있는데 못 받은 건 폴백이 아니라 loud 실패다).
    """
    for lang in langs:
        for key, flag, kind in (("subtitles", "--write-subs", "manual"),
                                ("automatic_captions", "--write-auto-subs", "auto")):
            code = pick_lang(meta.get(key) or {}, lang)
            if not code:
                continue
            p = subprocess.run(
                ["yt-dlp", "--skip-download", flag, "--sub-langs", code,
                 "--sub-format", "json3", "-o", str(tmp / "s.%(ext)s"), url],
                capture_output=True, text=True,
            )
            hit = sorted(tmp.glob("s.*.json3"))
            if hit:
                return hit[0], f"{kind}:{code}"
            # 메타가 있다고 한 트랙을 못 받았다 = 네트워크·429·차단. "자막 없음" 으로 뭉개지 않는다.
            sys.exit(f"[yt-transcript] 자막 트랙 {code}({kind}) 를 받지 못했습니다 "
                     f"(rc={p.returncode}). 429/차단 가능 — 잠시 후 재시도.\n"
                     f"{(p.stderr or p.stdout).strip()[-1500:]}")
    return None, None


def flatten(j3):
    """json3 → [(start_sec, text)] — 빈 이벤트·개행 전용 이벤트 제거."""
    out = []
    for ev in json.load(open(j3, encoding="utf-8")).get("events", []):
        txt = "".join(s.get("utf8", "") for s in ev.get("segs", [])).strip()
        if txt:
            out.append((ev.get("tStartMs", 0) / 1000, txt))
    return out


def chapter_at(chapters, t):
    for c in chapters:
        if c["start_time"] <= t < c["end_time"]:
            return c["title"]
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("-l", "--lang", default="",
                    help="자막 언어 (정확히 1개, 와일드카드 금지). 생략 시 영상 원어 → en")
    ap.add_argument("-o", "--out", default="-")
    ap.add_argument("--window", type=int, default=30, help="문단 묶음 초 단위")
    ap.add_argument("--meta-json", metavar="PATH",
                    help="메타·자막유무를 JSON 으로 함께 기록 (하위 도구가 마크다운을 파싱하지 "
                         "않게 — subs=null 이면 자막 없음)")
    a = ap.parse_args()

    meta = json.loads(run(["yt-dlp", "--skip-download", "--dump-json", a.url]))
    chapters = meta.get("chapters") or []

    # 기본 언어는 en 이 아니라 **영상의 원어**다. 한국어 영상에서 en 을 받으면 유튜브의 기계번역
    # 트랙이 와서 ASR 오류 위에 번역 오류가 한 겹 더 얹힌다(실측: ko 영상에서 RAG→"Leg",
    # Karpathy→"Andre Capas", 월간회고→"Wolgo"). 원어 트랙에는 그 층이 없다.
    # 명시 > 원어(meta.language) > en. pick_lang() 이 `-orig` 를 최우선으로 고른다.
    # 원어를 명시했거나 원어 트랙이 아예 없는 경우를 대비해 en 을 폴백으로 뒤에 붙인다
    # (원어 자막이 없는 영상에서 "자막 없음" 으로 오보하지 않도록).
    langs = [a.lang] if a.lang else list(dict.fromkeys([meta.get("language") or "en", "en"]))

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        path, kind = fetch_subs(a.url, langs, meta, tmp)
        lines = flatten(path) if path else []

    if a.meta_json:
        # 하위 도구(예: learning 적재)가 제목·자막유무를 알려고 마크다운을 되파싱하거나
        # --dump-json 을 한 번 더 부르지 않게 한다 — 메타의 주인은 이 스크립트 하나다.
        Path(a.meta_json).write_text(json.dumps({
            "video_id": meta.get("id"),
            "title": meta.get("title"),
            "channel": meta.get("channel") or meta.get("uploader"),
            "duration": meta.get("duration") or 0,
            "duration_hms": hms(meta.get("duration") or 0),
            "upload_date": meta.get("upload_date"),
            "webpage_url": meta.get("webpage_url"),
            "chapters": len(chapters),
            "language": meta.get("language"),   # 영상 원어 (없을 수 있음)
            "lang_requested": langs,            # 실제로 시도한 우선순위
            "subs": kind,            # None = 자막 없음 (문장 grep 금지). `auto:ko-orig` 처럼 코드 포함
            "transcript_lines": len(lines),
        }, ensure_ascii=False, indent=2), encoding="utf-8")

    L = [f"# {meta['title']}", ""]
    L += [f"- 채널: {meta.get('channel')}",
          f"- 길이: {hms(meta.get('duration') or 0)}",
          f"- 업로드: {meta.get('upload_date')}",
          f"- URL: {meta.get('webpage_url')}",
          f"- 자막: {kind or '없음'} (요청 {'/'.join(langs)}, 원어 {meta.get('language') or '?'})", ""]
    if chapters:
        L += ["## 챕터", ""]
        L += [f"- `{hms(c['start_time'])}` {c['title']}" for c in chapters] + [""]
    if meta.get("description"):
        L += ["## 설명(원문)", "", "```", meta["description"].strip(), "```", ""]

    L += ["## 전사본", ""]
    if not lines:
        L += ["> 자막 없음. 오디오 ASR 폴백 필요:",
              "> `yt-dlp -f bestaudio -x --audio-format mp3 <url>` → whisper/gemini 로 전사.", ""]
    else:
        cur_ch, buf, buf_t = None, [], None
        def flush():
            if buf:
                L.append(f"**[{hms(buf_t)}]** " + " ".join(buf))
                L.append("")
        for t, txt in lines:
            ch = chapter_at(chapters, t)
            if ch != cur_ch:
                flush(); buf.clear(); buf_t = None
                cur_ch = ch
                if ch:
                    L += [f"### {hms(t)} — {ch}", ""]
            if buf_t is None:
                buf_t = t
            buf.append(txt)
            if t - buf_t >= a.window:
                flush(); buf.clear(); buf_t = None
        flush()

    text = "\n".join(L) + "\n"
    if a.out == "-":
        sys.stdout.write(text)
    else:
        Path(a.out).write_text(text, encoding="utf-8")
        print(f"[yt-transcript] {a.out} · {len(text)} chars · 자막={kind}", file=sys.stderr)


if __name__ == "__main__":
    main()
