#!/usr/bin/env python3
"""doc-contract-lint 회귀 테스트 (수강생판).

회사 정본(`share-docs/scripts/test_doc_contract_lint.py`)의 이식본이다. 케이스는 수강생
자산 배선(상대경로 `doc.css`·`doc.js`)으로 바꿔 적었고, 수강생판에만 있는 검사
(플레이스홀더 잔여·깨진 이미지·안 닫힌 태그·제목 없음)의 케이스를 더했다.

이 테스트가 답해야 하는 질문은 "돌아가나"가 아니라 **"초록이 무슨 뜻인가"** 다.
검사기가 조용히 아무것도 안 보고 있어도 결과는 초록이다. 그래서 정상 문서 하나를 두고
**결함을 하나씩 주입해 그 규칙이 실제로 켜지는지** 확인한다(오라클 검증).

    python3 test_doc_contract_lint.py     # exit 0 = 전부 통과
"""

import importlib.util
import os
import sys
import tempfile

try:  # pytest 는 **선택** 의존이다 — `python3 <file>` 직접 실행이 정본 경로이고,
    import pytest  # 그 경로는 pytest 가 없는 박스에서도 그대로 돌아야 한다.
except ModuleNotFoundError:
    pytest = None

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("dcl", os.path.join(HERE, "doc-contract-lint.py"))
dcl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dcl)

CSS_LINK = '<link rel="stylesheet" href="doc.css">'
JS_TAG = '<script type="module" src="doc.js"></script>'

CLEAN = """<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <title>정상 문서</title>
  <meta property="og:title" content="정상 문서">
  <meta property="og:description" content="한 줄 요약">
  """ + CSS_LINK + """
</head>
<body>
  <main class="doc">
    <h1>정상 문서</h1>
    <img src="a.png" alt="설명">
  </main>
  """ + JS_TAG + """
</body>
</html>
"""

# 결정폼 + 회신 바 — 정상형
FORM_OK = CLEAN.replace("<h1>정상 문서</h1>", """<h1>정상 문서</h1>
    <section class="dec" data-decision="a"><label class="opt">
      <input type="radio" name="a" value="1"> 하나</label></section>
    <div class="commit-bar" data-decisions><button data-act="copy">결정 복사</button></div>""")

COMMIT_BAR = '<div class="commit-bar" data-decisions><button data-act="copy">결정 복사</button></div>'


def codes(html):
    """문서를 임시 폴더에 쓰고 코드 집합을 낸다.

    🔴 로컬 이미지 실재 검사가 있으므로 `a.png` 를 같은 폴더에 함께 만든다. 안 만들면
    모든 케이스에 img-missing 이 얹혀 "무엇을 재는 테스트인지"가 흐려진다.
    """
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "a.png"), "wb").write(b"\x89PNG")
        p = os.path.join(d, "doc.html")
        open(p, "w", encoding="utf-8").write(html)
        return {c for _l, c, _n, _m in dcl.check(p)}


def check_case(name, html, must_on, must_off):
    """케이스 하나를 판정해 실패 메시지 목록을 낸다 (빈 목록 = 통과).

    main() 과 pytest 가 이 함수 하나를 공유한다 — 판정을 두 벌로 두면 갈라진다.
    """
    got = codes(html)
    fails = []
    for c in must_on:
        if c not in got:
            fails.append(f"[{name}] {c} 가 안 켜졌다 (실제: {sorted(got) or '없음'})")
    for c in must_off:
        if c in got:
            fails.append(f"[{name}] {c} 가 잘못 켜졌다 (실제: {sorted(got)})")
    return fails


ALL_OFF = {"no-css", "no-js", "no-og", "no-title", "external-asset", "absolute-asset",
           "dup-asset", "img-no-alt", "img-missing", "unclosed-tag", "placeholder-left",
           "unknown-token", "hardcoded-color", "form-no-reply", "parse-failed"}

CASES = [
    # (이름, HTML, 켜져야 하는 코드, 꺼져 있어야 하는 코드)
    ("정상 문서는 조용하다", CLEAN, set(), ALL_OFF),

    ("JS 미로드", CLEAN.replace(JS_TAG, ""), {"no-js"}, set()),

    ("CSS 도 인라인 style 도 없음", CLEAN.replace(CSS_LINK, ""), {"no-css"}, set()),

    ("og 없음", CLEAN.replace('<meta property="og:title" content="정상 문서">', ""),
     {"no-og"}, set()),

    ("title 없음", CLEAN.replace("<title>정상 문서</title>", ""), {"no-title"}, set()),

    # --- 자산 배선: 수강생판은 정본과 규칙이 뒤집혀 있다 ---
    ("외부 URL 자산은 자기완결을 깬다",
     CLEAN.replace('href="doc.css"', 'href="https://cdn.example.com/doc.css"'),
     {"external-asset"}, set()),

    ("루트 절대경로는 수강생 박스에 없다",
     CLEAN.replace('href="doc.css"', 'href="/_assets/doc.css"'),
     {"absolute-asset"}, set()),

    ("상대경로 자산은 정상이다", CLEAN, set(), {"external-asset", "absolute-asset"}),

    ("CSS 중복 로드", CLEAN.replace(CSS_LINK, CSS_LINK + "\n  " + CSS_LINK),
     {"dup-asset"}, set()),

    ("JS 중복 로드", CLEAN.replace(JS_TAG, JS_TAG + "\n" + JS_TAG), {"dup-asset"}, set()),

    ("alt 없는 img", CLEAN.replace('<img src="a.png" alt="설명">', '<img src="a.png">'),
     {"img-no-alt"}, set()),

    ("없는 로컬 이미지", CLEAN.replace('src="a.png"', 'src="없는그림.png"'),
     {"img-missing"}, set()),

    ("채우지 않은 플레이스홀더",
     CLEAN.replace("<h1>정상 문서</h1>", "<h1>{문서 제목}</h1>"),
     {"placeholder-left"}, set()),

    ("닫히지 않은 태그",
     CLEAN.replace("<h1>정상 문서</h1>", "<div><h1>정상 문서</h1>"),
     {"unclosed-tag"}, set()),

    # --- 토큰 실재 ---
    ("정본에 있는 토큰은 조용하다",
     CLEAN.replace("</head>", "<style>.x{color:var(--doc-bg)}</style>\n</head>"),
     set(), {"unknown-token"}),

    ("정본에 없는 --doc-* 토큰",
     CLEAN.replace("</head>", "<style>.x{color:var(--doc-nope-zzz)}</style>\n</head>"),
     {"unknown-token"}, set()),

    ("문서가 스스로 정의한 로컬 토큰은 대상이 아니다",
     CLEAN.replace("</head>", "<style>.x{--doc-mine:var(--doc-bg);color:var(--doc-mine)}</style>\n</head>"),
     set(), {"unknown-token"}),

    ("접두사가 다른 문서 고유 변수는 대상이 아니다",
     CLEAN.replace("</head>", "<style>.x{color:var(--rc-bar)}</style>\n</head>"),
     set(), {"unknown-token"}),

    # --- 결정폼 ---
    ("결정폼 + 회신 바 = 정상", FORM_OK, set(), {"form-no-reply"}),

    ("결정폼인데 회신 없음", FORM_OK.replace(COMMIT_BAR, ""), {"form-no-reply"}, set()),

    ("회신이 버튼 문구로만 있어도 인정",
     FORM_OK.replace(COMMIT_BAR, '<button onclick="x()">Markdown 으로 복사</button>'),
     set(), {"form-no-reply"}),

    ("구 계약 결정폼도 본다",
     FORM_OK.replace('class="dec" data-decision="a"', 'class="decision-form" data-key="a"')
            .replace(COMMIT_BAR, ""),
     {"form-no-reply"}, set()),

    ("`.decision-form` 을 서술 블록으로만 쓴 문서는 회신을 요구하지 않는다",
     CLEAN.replace("<h1>정상 문서</h1>", """<h1>정상 문서</h1>
    <div class="dec"><h3>A1</h3>
      <div class="decision-form"><h4>누가 무엇을</h4><p>제가 전부 합니다.</p></div>
    </div>"""),
     set(), {"form-no-reply"}),

    ("결정폼 밖의 라디오(퀴즈)는 결정폼으로 세지 않는다",
     CLEAN.replace("<h1>정상 문서</h1>", """<h1>정상 문서</h1>
    <div class="dec"><p>설명만</p></div>
    <div class="doc-quiz"><label><input type="radio" name="q1" value="a"> 보기</label></div>"""),
     set(), {"form-no-reply"}),

    # --- 오탐 방지 — <pre> 안은 예시이지 문서의 구성요소가 아니다 ---
    ("<pre> 안의 예시 마크업은 자산 로드가 아니다",
     CLEAN.replace("<h1>정상 문서</h1>", """<h1>정상 문서</h1>
<pre><code>&lt;link rel="stylesheet" href="doc.css"&gt;</code></pre>"""),
     set(), {"dup-asset", "placeholder-left"}),

    ("<pre> 안에 이스케이프 안 된 예시가 있어도 문서 요소로 세지 않는다",
     CLEAN.replace("<h1>정상 문서</h1>", "<h1>정상 문서</h1>\n<pre>" + CSS_LINK + "</pre>"),
     set(), {"dup-asset"}),

    ("<pre> 안의 img 는 alt 를 안 세운다",
     CLEAN.replace('<img src="a.png" alt="설명">', '<pre><code>&lt;img src="a.png"&gt;</code></pre>'),
     set(), {"img-no-alt", "img-missing"}),

    ("코드 블록 안의 중괄호는 플레이스홀더가 아니다",
     CLEAN.replace("<h1>정상 문서</h1>", "<h1>정상 문서</h1>\n<pre><code>.x{color:red}</code></pre>"),
     set(), {"placeholder-left"}),

    # --- 의도적 예외 ---
    ("standalone 은 계약 검사에서 빠진다",
     CLEAN.replace(CSS_LINK, '<meta name="doc-standalone" content="외부 제출본 — 공유 자산 미사용">'),
     {"standalone"}, {"no-css", "no-og", "no-js"}),

    ("이유 없는 예외는 통과시키지 않는다",
     CLEAN.replace(CSS_LINK, '<meta name="doc-standalone" content="">'),
     {"standalone-no-reason"}, {"standalone"}),
]


if pytest is not None:
    @pytest.mark.parametrize("case", CASES, ids=[c[0] for c in CASES])
    def test_contract_case(case):
        """CASES 를 pytest 케이스로 편다 — 안 펴면 pytest 가 케이스를 못 보고 초록을 낸다."""
        fails = check_case(*case)
        assert not fails, fails


def test_worktree_exclusion():
    """`.git` 이 파일이면 그 아래는 통째로 안 센다 — 조상까지 거슬러 본다."""
    with tempfile.TemporaryDirectory() as d:
        wt = os.path.join(d, "wt")
        docs = os.path.join(wt, "docs", "deep")
        os.makedirs(docs)
        open(os.path.join(wt, ".git"), "w").write("gitdir: /elsewhere\n")
        open(os.path.join(docs, "a.html"), "w").write(CLEAN)

        real = os.path.join(d, "real")
        os.makedirs(os.path.join(real, ".git"))
        os.makedirs(os.path.join(real, "docs"))
        open(os.path.join(real, "docs", "b.html"), "w").write(CLEAN)

        fails = []
        files, _ = dcl.collect([d])
        if any(os.sep + "wt" + os.sep in f for f in files):
            fails.append("루트에서 훑을 때 worktree 를 셌다")
        # 🔴 핵심 — worktree **안쪽 경로를 직접** 줘도 빠져야 한다
        files, skipped = dcl.collect([docs])
        if files:
            fails.append("worktree 내부 경로를 직접 주니 셌다 (조상 판정 실패)")
        files, _ = dcl.collect([os.path.join(real, "docs")])
        if len(files) != 1:
            fails.append(f"정상 클론을 잘못 뺐다: {files}")
        # pytest 로 수집될 때도 오라클이 있어야 한다 — return 만 하면 항상 통과한다.
        assert not fails, fails


def main():
    fails = []
    for case in CASES:
        fails += check_case(*case)
    try:
        test_worktree_exclusion()
    except AssertionError as e:
        fails += list(e.args[0])

    n = len(CASES) + 1
    if fails:
        print(f"실패 {len(fails)}건 / 케이스 {n}개")
        for f in fails:
            print("  ✗", f)
        return 1
    print(f"통과 — 케이스 {n}개, 실패 0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
