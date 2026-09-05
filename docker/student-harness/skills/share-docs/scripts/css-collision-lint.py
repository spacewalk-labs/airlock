#!/usr/bin/env python3
"""share-docs 문서가 공유 클래스명을 다른 용도로 재사용했는지 판정한다 (수강생판).

회사 정본(`share-docs/scripts/css-collision-lint.py`)의 이식본이다. 바뀐 것은 자산 배선뿐 —
자산 이름이 `doc.css` 이고, 수강생은 **발행 직전 CSS 를 문서 안에 인라인**하므로
`<link>` 가 사라진 뒤에도 검사가 돌아야 한다. 그래서 "이 문서가 공유 자산을 쓰는가"를
파일명이 아니라 **`--doc-*` 토큰이 문서 안에 있는가**로도 판정한다.
CSS 클래스명(.step·.swatch·.doc-toast 등)은 정본과 같은 마크업 계약이라 그대로 둔다.

doc.css 는 클래스 143개를 정의하지만 skill 문서는 그 일부만 계약으로 싣는다.
그래서 작성자는 표에 없는 `step`·`swatch`·`toc` 같은 일반 낱말을 "비어 있는 이름"으로
읽고 자기 용도로 쓴다. 이름이 겹치면 공유 규칙이 그대로 먹혀 레이아웃이 조용히 깨진다 —
`.step` 은 1.7em 원형 배지라서 블록 콘텐츠를 담으면 배지 크기로 짓눌린다.

이름이 겹쳤다는 사실만으로는 판정할 수 없다. 실측(2026-08-02, 소비 문서 1,107개)상
페이지 `<style>` 은 항상 `<link>` 뒤에 오므로 **bare 재정의는 페이지가 이긴다** — 약 70개
문서가 공유 이름을 bare 로 덮어 쓰지만 전부 무해하다. 실제로 깨진 것은 페이지가 그 클래스를
자손 셀렉터로만 손대 **display 를 못 덮은** 부분 재정의였다.

    ERROR  배지형 공유 클래스가 블록 태그에 붙었는데 페이지가 display 를 bare 로 안 덮음
    WARN   공유 클래스의 레이아웃 속성을 자손 셀렉터로만 손댐 (부분 재정의)

검사하지 않는 것 둘. `display:none` 인 공유 클래스(`.doc-q-explain` 등)는 JS 가 여는 것이
계약이라 재정의 없는 사용이 정상이다. `position:fixed` 인 부유 컴포넌트(`.doc-toast` 등)는
원래 `<div>` 로 쓰는 것이라 태그 종류가 오·정상을 가르지 못한다. 둘 다 실측상 파손 0건이고
검사하면 정상 사용만 걸린다.

exit 0 = 이상 없음 / 1 = ERROR 있음 / 2 = lint 자체 실패
"""

import os
import re
import sys
from html.parser import HTMLParser

# 재사용 시 파괴적으로 작용하는 속성만 본다. 색·타이포는 겹쳐도 레이아웃을 안 깬다.
RISK_PROPS = {
    "display", "position", "float", "width", "height",
    "min-width", "min-height", "max-width", "max-height",
    "border-radius", "flex", "grid-template-columns", "overflow",
}

# 블록 콘텐츠를 담는 태그. 여기에 배지형 클래스가 붙으면 용도가 다르다는 신호다.
BLOCK_TAGS = {
    "div", "section", "article", "aside", "main", "li", "td", "th",
    "p", "h1", "h2", "h3", "h4", "h5", "h6", "ol", "ul", "table",
    "blockquote", "pre", "figure", "form", "fieldset", "nav", "header", "footer",
}

VOID_TAGS = {
    "area", "base", "br", "col", "embed", "hr", "img", "input",
    "link", "meta", "source", "track", "wbr",
}

SMALL_LEN = re.compile(r"^([0-9.]+)(em|rem|px|ch)\Z")


def small_box(value):
    """1.7em 짜리 배지처럼 '작은 고정 크기'인지. 본문을 담을 수 없는 크기가 기준이다."""
    m = SMALL_LEN.match(value.strip().lower())
    if not m:
        return False
    n, unit = float(m.group(1)), m.group(2)
    return n <= (32 if unit == "px" else 2.5)


def strip_comments(css):
    return re.sub(r"/\*.*?\*/", "", css, flags=re.S)


def iter_rules(css):
    """(셀렉터목록, 선언블록) 을 낸다. @media 등 at-rule 은 껍데기만 벗기고 안을 그대로 훑는다."""
    css = strip_comments(css)
    depth, buf, sel = 0, [], []
    i = 0
    while i < len(css):
        c = css[i]
        if c == "{":
            depth += 1
            if depth == 1:
                sel = "".join(buf).strip()
                buf = []
            else:
                buf.append(c)
        elif c == "}":
            depth -= 1
            if depth == 0:
                body = "".join(buf)
                if sel.startswith("@"):
                    # at-rule 안의 룰을 재귀로 훑는다 (@media 안에도 bare 셀렉터가 산다)
                    yield from iter_rules(body)
                else:
                    yield sel, body
                buf, sel = [], []
            else:
                buf.append(c)
        else:
            buf.append(c)
        i += 1


def declared_risk(body):
    """선언블록에서 위험 속성만 뽑는다. {속성: 값}"""
    out = {}
    for decl in body.split(";"):
        if ":" not in decl:
            continue
        prop, _, val = decl.partition(":")
        prop = prop.strip().lower()
        if prop in RISK_PROPS:
            out[prop] = val.strip().lower().replace("!important", "").strip()
    return out


BARE_CLASS = re.compile(r"^\.([A-Za-z_][\w-]*)((?:[.:\[][^\s>+~]*)*)\Z")
ANY_CLASS = re.compile(r"\.([A-Za-z_][\w-]*)")


def parse_css(css):
    """(bare, touched) — bare[c]=덮은 위험속성 / touched[c]=자손 등으로 손댄 위험속성"""
    bare, touched = {}, {}
    for sel_list, body in iter_rules(css):
        if not body.strip():
            continue
        risk = declared_risk(body)
        for sel in sel_list.split(","):
            sel = sel.strip()
            if not sel:
                continue
            m = BARE_CLASS.match(sel)
            if m and risk:
                bare.setdefault(m.group(1), {}).update(risk)
            # touched 는 선언 종류를 안 가린다 — 색만 손댄 것도 "이 클래스를 자기 것으로
            # 여겼다"는 신호이고, 실측 파손(석수동)이 바로 색·굵기만 덮은 경우였다.
            for name in ANY_CLASS.findall(sel):
                touched.setdefault(name, {}).update(risk)
    return bare, touched


def classify(bare):
    """본문을 담을 수 없는 '배지형' 공유 클래스를 가려낸다 — 작은 고정 크기 + 인라인/플렉스."""
    badge = set()
    for name, props in bare.items():
        disp = props.get("display", "")
        if disp == "none":
            continue  # JS 가 여는 공유 컴포넌트 — 재정의 없는 사용이 계약이다
        fixed_dim = any(
            small_box(props[p]) for p in ("width", "height") if p in props
        )
        if fixed_dim and ("inline" in disp or disp in ("flex", "grid", "block")):
            badge.add(name)
    return badge


class DocParser(HTMLParser):
    """문서에서 <style> 전문과 (태그, 클래스, 줄번호) 사용 내역을 모은다."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.styles = []
        self.uses = []
        self._in_style = False
        self._svg_depth = 0
        self._stack = []

    def handle_starttag(self, tag, attrs):
        d = dict(attrs)
        if tag == "style":
            self._in_style = True
        if tag == "svg":
            self._svg_depth += 1
        if self._svg_depth == 0 and "class" in (d or {}):
            classes = (d.get("class") or "").split()
            if classes:
                self.uses.append((tag, classes, self.getpos()[0]))
        if tag not in VOID_TAGS:
            self._stack.append(tag)

    def handle_endtag(self, tag):
        if tag == "style":
            self._in_style = False
        if tag == "svg" and self._svg_depth:
            self._svg_depth -= 1
        for i in range(len(self._stack) - 1, -1, -1):
            if self._stack[i] == tag:
                del self._stack[i:]
                break

    def handle_data(self, data):
        if self._in_style:
            self.styles.append(data)


SHARED_TOKEN = re.compile(r"--doc-[A-Za-z0-9_-]+")


def uses_shared_css(html):
    """공유 자산을 쓰는 문서인가. 상대경로 <link> 든 인라인된 뒤든 둘 다 잡는다."""
    return "doc.css" in html or SHARED_TOKEN.search(html) is not None


def check(path, shared_bare, badge):
    findings = []
    try:
        html = open(path, encoding="utf-8", errors="replace").read()
    except OSError as e:
        return [("ERROR", 0, "?", f"읽기 실패: {e}")]

    if not uses_shared_css(html):
        return []

    p = DocParser()
    try:
        p.feed(html)
    except Exception as e:  # 깨진 마크업은 판정 불가 — 조용히 통과시키지 않는다
        return [("ERROR", 0, "?", f"HTML 파싱 실패: {e}")]

    page_bare, page_touched = parse_css("\n".join(p.styles))

    seen = set()
    for tag, classes, line in p.uses:
        for c in classes:
            if c not in shared_bare:
                continue
            covers_display = "display" in page_bare.get(c, {})
            if c in badge and tag in BLOCK_TAGS and not covers_display:
                findings.append((
                    "ERROR", line, c,
                    f"배지형 공유 클래스를 블록 태그 <{tag}> 에 사용 — "
                    f"페이지가 .{c} 의 display 를 bare 로 덮지 않아 공유 규칙"
                    f"({shared_bare[c].get('display', '?')}) 이 그대로 적용됩니다",
                ))

        for c in classes:
            if c in seen or c not in shared_bare:
                continue
            seen.add(c)
            if c in page_touched and c not in page_bare:
                left = sorted(set(shared_bare[c]) - set(page_touched[c]))
                if left:
                    findings.append((
                        "WARN", line, c,
                        f"공유 클래스 .{c} 를 자손 셀렉터로만 손댔습니다 — "
                        f"{', '.join(left)} 는 공유 규칙이 그대로 남습니다",
                    ))
    return findings


def collect(paths):
    out = []
    for p in paths:
        if os.path.isdir(p):
            for dp, dn, fn in os.walk(p):
                dn[:] = [d for d in dn if d not in ("node_modules", ".next", ".git",
                                                    "__pycache__", ".venv")]
                out += [os.path.join(dp, f) for f in sorted(fn) if f.endswith(".html")]
        else:
            out.append(p)
    return out


def default_css():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(os.path.dirname(here), "assets", "doc.css")


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    css_path = default_css()
    for a in argv:
        if a.startswith("--css="):
            css_path = a[6:]
    if not args:
        print("사용법: css-collision-lint.py [--css=<doc.css>] <html|dir>...", file=sys.stderr)
        return 2
    try:
        shared_bare, _ = parse_css(open(css_path, encoding="utf-8").read())
    except OSError as e:
        print(f"공유 CSS 를 읽지 못했습니다 ({css_path}): {e}", file=sys.stderr)
        return 2
    if not shared_bare:
        print(f"공유 CSS 에서 클래스를 못 찾았습니다: {css_path}", file=sys.stderr)
        return 2

    badge = classify(shared_bare)
    files = collect(args)
    n_err = n_warn = 0
    for path in files:
        for level, line, cls, msg in check(path, shared_bare, badge):
            print(f"{level}  {path}:{line}  .{cls}  {msg}")
            if level == "ERROR":
                n_err += 1
            else:
                n_warn += 1
    print(f"문서 {len(files)}개 · 공유 클래스 {len(shared_bare)}개"
          f"(배지형 {len(badge)}: {' '.join('.'+c for c in sorted(badge))})"
          f" · ERROR {n_err} · WARN {n_warn}")
    return 1 if n_err else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
