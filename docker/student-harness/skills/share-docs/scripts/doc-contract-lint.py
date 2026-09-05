#!/usr/bin/env python3
"""share-docs 문서가 **발행 전 계약**을 지켰는지 판정한다 (수강생판).

회사 정본(`share-docs/scripts/doc-contract-lint.py`)의 완화 이식본이다.
자산 규칙 하나가 뒤집혀 있다 — 정본은 공유 자산을 `/_assets/…` **절대경로**로만 부르게 강제하지만,
수강생판은 자산을 문서 폴더에 나란히 두고 **상대경로**로 걸었다가 발행 직전 인라인한다.
그래서 그 규칙은 **빼는 게 아니라 뒤집었다** — 외부 URL(CDN)로 부르는 쪽이 ERROR 다.
자기완결 HTML 이 목표인데 CDN 을 부르면 오프라인·스냅샷에서 조용히 스타일이 죽는다.

grep 이 아니라 **파싱**한다. `<pre>` 안의 예시 마크업과 본문 산문은 링크가 아니다.

    ERROR  발행하면 문서가 깨지거나 목적을 잃는다
    WARN   덜 좋은 문서가 된다
    INFO   집계용

정본에서 뒤늦게 들어온 검사 셋도 여기 실려 있다 — 토큰 실재(unknown-token) ·
결정폼 회신 경로(form-no-reply) · worktree 사본 제외. 수강생판에만 있는 검사
(플레이스홀더 잔여·깨진 이미지·안 닫힌 태그·하드코딩 색)는 그대로 남겨 두었다.

일부러 공유 자산을 안 쓰는 문서(목업·외부 제출본)는 <head> 에
`<meta name="doc-standalone" content="{이유}">` 를 넣어 계약 검사에서 뺀다.
빈 이유는 조용한 무력화라 ERROR 다.

사용법:  python3 scripts/doc-contract-lint.py [옵션] <html|dir>...
exit 0 = ERROR 없음 / 1 = ERROR 있음 / 2 = lint 자체 실패
"""

import os
import re
import sys
from pathlib import Path
from html.parser import HTMLParser

CSS_NAME = "doc.css"
JS_NAME = "doc.js"

# 토큰 실재 검사용 정본 CSS. 수강생판은 스킬 폴더의 assets/doc.css 가 정본이다.
CANONICAL_CSS = Path(__file__).resolve().parent.parent / "assets" / CSS_NAME

# 마크업이 아니라 **본문 텍스트**인 곳. 여기 안의 태그는 예시이지 문서의 구성요소가 아니다.
VERBATIM = {"pre", "code", "textarea", "template", "script", "style", "xmp"}

# 닫는 것이 선택이라 스택에 남아도 결함이 아닌 태그
OPTIONAL_CLOSE = {"html", "body", "head", "p", "li", "dt", "dd", "tr", "td", "th",
                  "thead", "tbody", "tfoot", "option", "figcaption"}

VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "source", "track", "wbr"}

SCHEME = re.compile(r"^(?:[a-z]+:)?//", re.I)
# 플레이스홀더를 셀 때 CSS/JS/예시 블록은 지운다. 거기 중괄호는 코드이지 빈칸이 아니다.
VERBATIM_BLOCK = re.compile(
    r"<(style|script|pre|code|textarea|template|xmp)\b[^>]*>.*?</\1\s*>", re.I | re.S)
# 중괄호 플레이스홀더. 첫 글자를 한글로 좁히면 {N}·{YYYY-MM-DD}·{} 를 통째로 놓친다.
PLACEHOLDER = re.compile(r"\{[^{}\n]{0,80}\}")
# 하드코딩 색. 토큰(var(--doc-*)) 밖의 색은 다크모드에서 따라오지 않는다.
HARDCODED_COLOR = re.compile(r"#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(")
LOCAL_IMG_EXT = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg")

# 결정폼임을 알리는 표식 (신 계약 · 구 계약 둘 다)
FORM_MARK = re.compile(r"\bdec\b|\bdecision-form\b")
# 회신 수단으로 인정하는 버튼 문구
REPLY_TEXT = re.compile(r"복사|copy|markdown|\bMD\b", re.I)

# 🔴 없는 토큰을 써도 CSS 는 조용히 폴백 상수를 쓴다. 라이트에서는 멀쩡해 보이는데
#    다크 모드에서 색이 라이트에 고정된다 — 다크로 열어보기 전엔 아무도 모른다.
#    판정은 네임스페이스 규칙 하나 — `--doc-*` 는 정본 doc.css 만이 정의한다.
#    문서가 자기 로컬 변수(`--rc-bar` 등)를 정의해 쓰는 것은 접두사가 달라 대상이 아니다.
TOKEN_DEF = re.compile(r"(--doc-[A-Za-z0-9_-]+)\s*:")
TOKEN_USE = re.compile(r"var\(\s*(--doc-[A-Za-z0-9_-]+)")


def canonical_tokens(css_path):
    """정본 CSS 가 정의하는 `--doc-*` 전부. 없으면 검사를 끈다(빈 집합이 아니라 None)."""
    try:
        text = open(css_path, encoding="utf-8", errors="replace").read()
    except OSError:
        return None
    names = set(TOKEN_DEF.findall(text))
    return names or None


def unknown_tokens(styles, canonical):
    """문서가 쓰는데 정본에도 문서 자신에도 정의가 없는 `--doc-*` → [(줄, 이름)]."""
    if not canonical:
        return []
    local = set()
    for _line, css in styles:
        local.update(TOKEN_DEF.findall(css))
    known = canonical | local
    seen, out = set(), []
    for line, css in styles:
        for name in TOKEN_USE.findall(css):
            if name not in known and name not in seen:
                seen.add(name)
                out.append((line, name))
    return out


class Doc(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.css_links = []      # (line, href)
        self.js_srcs = []
        self.metas = {}
        self.title = None
        self.imgs = []           # (line, src, alt 있음?)
        self.hrefs = []          # (line, href) — 로컬 파일 링크만
        self.styles = []         # (line, css 본문)
        self.unclosed = []
        self.has_form = False
        self.has_commit_bar = False
        self.has_md_output = False
        self.reply_button = False
        self._form_at = []       # 결정폼 표식이 열린 지점의 스택 깊이
        self._btn = None         # 버튼/앵커 텍스트 수집 버퍼
        self._verbatim = 0
        self._verbatim_tag = None
        self._style_at = None
        self._style_buf = None
        self._in_title = False
        self._stack = []         # (tag, line)

    def handle_starttag(self, tag, attrs):
        d = dict(attrs)
        if self._verbatim:
            if tag == self._verbatim_tag and tag not in VOID:
                self._verbatim += 1
            return
        if tag in VERBATIM:
            self._verbatim = 1
            self._verbatim_tag = tag
            if tag == "style":
                self._style_at, self._style_buf = self.getpos()[0], []
            if tag not in ("script", "style"):
                return

        line = self.getpos()[0]
        if tag == "link" and "stylesheet" in (d.get("rel") or "").lower():
            self.css_links.append((line, d.get("href") or ""))
        elif tag == "script" and d.get("src"):
            self.js_srcs.append((line, d.get("src")))
        elif tag == "meta":
            key = d.get("property") or d.get("name")
            if key:
                self.metas[key.lower()] = d.get("content") or ""
        elif tag == "img":
            self.imgs.append((line, d.get("src") or "", "alt" in d))
        elif tag == "title":
            self._in_title = True
        elif tag == "a" and d.get("href"):
            self.hrefs.append((line, d["href"]))

        # 🔴 클래스 이름만으로 "폼"이라 부르지 않는다. `.decision-form` 을 **서술 블록**으로
        #    쓴 문서가 실제로 있다. 판정 기준은 **그 블록 안에 고를 입력이 있는가** 하나다.
        cls = (d.get("class") or "").split()
        if FORM_MARK.search(" ".join(cls)) or "data-decision" in d:
            self._form_at.append(len(self._stack))
        if (tag == "input" and (d.get("type") or "").lower() in ("radio", "checkbox")
                and self._form_at):
            self.has_form = True
        if "commit-bar" in cls:
            self.has_commit_bar = True
        if d.get("id") == "md-output" or "data-md" in d:
            self.has_md_output = True
        if tag in ("button", "a") and self._btn is None:
            self._btn = []

        if tag not in VOID and tag not in ("script", "style"):
            self._stack.append((tag, line))

    def handle_endtag(self, tag):
        if self._verbatim:
            if tag == self._verbatim_tag:
                self._verbatim -= 1
                if not self._verbatim:
                    if tag == "style" and self._style_buf is not None:
                        self.styles.append((self._style_at, "".join(self._style_buf)))
                        self._style_at = self._style_buf = None
                    self._verbatim_tag = None
            return
        if tag == "title":
            self._in_title = False
        if tag in ("button", "a") and self._btn is not None:
            if REPLY_TEXT.search("".join(self._btn)):
                self.reply_button = True
            self._btn = None
        for i in range(len(self._stack) - 1, -1, -1):
            if self._stack[i][0] == tag:
                # 이 태그 안쪽에서 열린 채 남은 것들은 닫히지 않은 것이다
                self.unclosed += [t for t in self._stack[i + 1:]
                                  if t[0] not in OPTIONAL_CLOSE]
                del self._stack[i:]
                break
        while self._form_at and self._form_at[-1] >= len(self._stack):
            self._form_at.pop()

    def handle_data(self, data):
        if self._style_buf is not None:
            self._style_buf.append(data)
        elif self._in_title:
            self.title = (self.title or "") + data
        elif self._btn is not None:
            self._btn.append(data)

    def close(self):
        super().close()
        self.unclosed += [t for t in self._stack if t[0] not in OPTIONAL_CLOSE]


def check(path):
    """[(등급, 코드, 줄, 메시지)] 를 낸다."""
    try:
        html = open(path, encoding="utf-8", errors="replace").read()
    except OSError as e:
        return [("ERROR", "unreadable", 0, f"읽기 실패: {e}")]

    d = Doc()
    try:
        d.feed(html)
        d.close()
    except Exception as e:
        return [("ERROR", "parse-failed", 0, f"HTML 파싱 실패: {e}")]

    if "doc-standalone" in d.metas:
        why = d.metas["doc-standalone"].strip()
        if not why:
            return [("ERROR", "standalone-no-reason", 0,
                     "doc-standalone 에 이유가 없습니다 — 예외에는 이유를 적습니다")]
        return [("INFO", "standalone", 0, f"계약 검사 제외: {why}")]

    out = []
    base = os.path.dirname(os.path.abspath(path))
    # 템플릿 골격은 채워지기 전이라 중괄호가 남아 있는 것이 정상이다.
    # `templates/snippets/` 처럼 하위 폴더에 두는 조각도 포함하므로 경로 전체를 본다.
    is_template = "templates" in Path(path).resolve().parts
    # 조각(snippet)은 문서가 아니다 — <html> 뿌리가 없으면 제목·og·자산은 판정 대상이 아니다.
    is_fragment = "<html" not in html.lower() and "<body" not in html.lower()

    # --- 1. 자산: 상대경로/인라인이 정본. 외부 URL 은 자기완결을 깬다 ---
    for line, href in d.css_links + d.js_srcs:
        if SCHEME.match(href):
            out.append(("ERROR", "external-asset", line,
                        f"외부 URL 자산 ({href}) — 발행본은 자기완결이어야 합니다. "
                        f"파일을 문서 폴더에 두고 상대경로로 거세요"))
        elif href.startswith("/"):
            out.append(("WARN", "absolute-asset", line,
                        f"루트 절대경로 자산 ({href}) — 문서 폴더 기준 상대경로를 권합니다"))
    if is_fragment:
        pass
    elif not d.css_links and "<style" not in html.lower():
        out.append(("WARN", "no-css", 0, "doc.css 도 인라인 <style> 도 없습니다 — 스타일이 죽습니다"))
    if not is_fragment and not d.js_srcs and "<script" not in html.lower():
        out.append(("WARN", "no-js", 0,
                    "doc.js 미로드 — 목차·테마 토글·복사 버튼·퀴즈·탭이 한꺼번에 죽습니다"))
    named = [h for _, h in d.css_links if CSS_NAME in h]
    if len(named) > 1:
        out.append(("ERROR", "dup-asset", d.css_links[1][0],
                    f"{CSS_NAME} 를 {len(named)}회 로드합니다 — 한 번만 부릅니다"))
    named_js = [s for _, s in d.js_srcs if JS_NAME in s]
    if len(named_js) > 1:
        out.append(("ERROR", "dup-asset", d.js_srcs[1][0],
                    f"{JS_NAME} 를 {len(named_js)}회 로드합니다 — 한 번만 부릅니다"))

    # --- 1-1. 토큰 실재 (페이지 <style> 안) ---
    for line, name in unknown_tokens(d.styles, canonical_tokens(CANONICAL_CSS)):
        out.append(("ERROR", "unknown-token", line,
                    f"정본에 없는 토큰을 씁니다 ({name}) — 폴백 상수가 박혀 "
                    f"다크 모드에서 색이 라이트에 고정됩니다. {CSS_NAME} 의 이름을 확인하세요"))

    # --- 2. 메타 (조각은 문서가 아니므로 건너뛴다) ---
    if is_fragment:
        pass
    elif not (d.title or "").strip():
        out.append(("ERROR", "no-title", 0, "<title> 이 없습니다 — 발행 링크(slug)와 미리보기가 여기서 나옵니다"))
    for key in (() if is_fragment else ("og:title", "og:description")):
        if key not in d.metas:
            out.append(("WARN", "no-og", 0, f"{key} 없음 — 링크를 채팅에 붙여도 미리보기가 안 뜹니다"))

    # --- 2-1. 결정을 묻는데 돌려줄 방법이 없음 ---
    if d.has_form and not (d.has_commit_bar or d.has_md_output or d.reply_button):
        out.append(("ERROR", "form-no-reply", 0,
                    "결정을 묻는데 회신 수단이 없습니다 — 고르고도 돌려줄 방법이 없습니다"))

    # --- 3. 중괄호 플레이스홀더 잔여 ---
    if not is_template and not is_fragment:
        # 코드 블록을 같은 줄 수의 공백으로 치환해 줄 번호를 보존한다
        scan = VERBATIM_BLOCK.sub(lambda m: "\n" * m.group(0).count("\n"), html)
        hits = [(i + 1, m.group(0)) for i, ln in enumerate(scan.splitlines())
                for m in [PLACEHOLDER.search(ln)] if m]
        if hits:
            out.append(("ERROR", "placeholder-left", hits[0][0],
                        f"채우지 않은 플레이스홀더 {len(hits)}줄 (예: {hits[0][1]}) — "
                        f"🔴 인라인 **전** 원본에서 0 이 될 때까지 채웁니다"))

    # --- 4. 하드코딩 색 (페이지 <style> 안) ---
    for line, css in d.styles:
        for i, ln in enumerate(css.splitlines()):
            m = HARDCODED_COLOR.search(ln)
            if m and "var(--doc-" not in ln:
                out.append(("WARN", "hardcoded-color", line + i,
                            f"토큰 밖 색 ({m.group(0)}) — --doc-* 토큰을 쓰면 다크모드가 따라옵니다"))
                break

    # --- 5. 깨진 로컬 이미지 참조 ---
    for line, src, has_alt in d.imgs:
        if not has_alt:
            out.append(("WARN", "img-no-alt", line, "alt 없는 <img>"))
        if not src or SCHEME.match(src) or src.startswith("data:") or "{" in src:
            continue
        if not os.path.isfile(os.path.join(base, src.split("#")[0].split("?")[0])):
            out.append(("ERROR", "img-missing", line, f"이미지 파일이 없습니다: {src}"))
    for line, href in d.hrefs:
        h = href.split("#")[0].split("?")[0]
        if not h or SCHEME.match(h) or h.startswith(("data:", "mailto:", "#", "/")) or "{" in h:
            continue
        if h.lower().endswith(LOCAL_IMG_EXT) and not os.path.isfile(os.path.join(base, h)):
            out.append(("ERROR", "img-missing", line, f"원본 이미지 링크가 끊겼습니다: {href}"))

    # --- 6. 기초 구조 ---
    for tag, line in d.unclosed[:3]:
        out.append(("ERROR", "unclosed-tag", line, f"닫히지 않은 <{tag}>"))

    return out


def in_worktree(path):
    """이 경로가 git worktree 안인가 — `.git` 이 **디렉터리가 아니라 파일**이면 worktree 다.

    조상까지 거슬러 봐야 한다. `<worktree>/docs` 를 직접 인자로 주면 walk 는 레포 루트의
    표식을 영영 못 본다.
    """
    cur = os.path.abspath(path)
    while True:
        g = os.path.join(cur, ".git")
        if os.path.isfile(g):
            return True
        if os.path.isdir(g):
            return False
        nxt = os.path.dirname(cur)
        if nxt == cur:
            return False
        cur = nxt


def collect(paths, worktrees=False):
    """HTML 파일 목록. 기본은 **worktree 클론을 통째로 건너뛴다** (통계 부풀림 방지).

    작업 중인 worktree 를 스스로 검사하려면 `--worktrees` 를 준다.
    """
    out, skipped = [], []
    for p in paths:
        if not worktrees and in_worktree(p):
            skipped.append(p)
            continue
        if os.path.isfile(p):
            out.append(p)
            continue
        for dp, dn, fn in os.walk(p):
            if not worktrees and os.path.isfile(os.path.join(dp, ".git")):
                skipped.append(dp)
                dn[:] = []
                continue
            dn[:] = [x for x in dn if x not in ("node_modules", ".next", ".git", "dist",
                                                "build", "__pycache__", ".venv")]
            out += [os.path.join(dp, f) for f in sorted(fn) if f.endswith(".html")]
    return out, skipped


USAGE = """사용법: doc-contract-lint.py [옵션] <html|dir>...

  --summary       파일별 지적 대신 코드별 집계만
  --only=CODE     그 코드만 (쉼표로 여러 개)
  --list=CODE     해당 코드가 걸린 파일 경로만 (보정 대상 목록 뽑기)
  --warn-fail     WARN 도 종료코드 1
  --worktrees     git worktree 안도 검사 (기본은 제외 — 통계가 사본만큼 부풀기 때문)
"""


def main(argv):
    opts = [a for a in argv if a.startswith("--")]
    args = [a for a in argv if not a.startswith("--")]
    if not args:
        print(USAGE, file=sys.stderr)
        return 2

    only, listing = set(), set()
    for o in opts:
        if o.startswith("--only="):
            only |= set(o[7:].split(","))
        elif o.startswith("--list="):
            listing |= set(o[7:].split(","))
        elif o not in ("--summary", "--warn-fail", "--worktrees"):
            print(f"모르는 옵션: {o}\n{USAGE}", file=sys.stderr)
            return 2
    summary = "--summary" in opts or bool(listing)
    warn_fail = "--warn-fail" in opts

    files, skipped = collect(args, worktrees="--worktrees" in opts)
    if not files:
        if skipped:
            print(f"worktree {len(skipped)}곳을 건너뛰어 검사할 것이 없습니다 — "
                  f"작업 중인 사본을 검사하려면 --worktrees", file=sys.stderr)
        else:
            print("검사할 HTML 이 없습니다", file=sys.stderr)
        return 2

    counts, n_err, n_warn = {}, 0, 0
    for path in files:
        for level, code, line, msg in check(path):
            if only and code not in only:
                continue
            counts[code] = counts.get(code, 0) + 1
            if code in listing:
                print(path)
            elif not summary and level != "INFO":
                print(f"{level:5s} {code:18s} {path}:{line}  {msg}")
            if level == "ERROR":
                n_err += 1
            elif level == "WARN":
                n_warn += 1

    if not listing:
        print(f"\n문서 {len(files)}개"
              + (f" (worktree {len(skipped)}곳 제외)" if skipped else "")
              + f" · ERROR {n_err} · WARN {n_warn}")
        for code in sorted(counts, key=lambda c: -counts[c]):
            print(f"  {counts[code]:5d}  {code}")

    if n_err:
        return 1
    return 1 if (warn_fail and n_warn) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
