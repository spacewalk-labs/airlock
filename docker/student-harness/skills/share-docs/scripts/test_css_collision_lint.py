#!/usr/bin/env python3
"""css-collision-lint.py 회귀 테스트 (수강생판).

회사 정본(`share-docs/scripts/test_css_collision_lint.py`)의 이식본이다. 바뀐 것은
자산 배선뿐 — <link> 를 상대경로 `doc.css` 로 적고, 수강생이 **발행 직전 인라인한 뒤**
에도 검사가 도는지 보는 케이스를 하나 더했다. 클래스명은 정본과 같은 계약이라 그대로다.

각 케이스는 실측된 문서에서 따왔다 — 통과해야 할 것과 걸려야 할 것 모두 실물이 근거다.
마지막 케이스는 오라클 검증이다: 규칙을 무력화했을 때 테스트가 실제로 빨개지는지 본다.
그게 없으면 "초록"이 규칙이 동작한다는 증거가 못 된다.

    python3 test_css_collision_lint.py     # exit 0 = 전부 통과
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
spec = importlib.util.spec_from_file_location("lint", os.path.join(HERE, "css-collision-lint.py"))
lint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lint)

# doc.css 의 실제 선언 모양을 줄인 것 (css:1575 .step, .swatch, .doc-toast, .doc-q-explain)
SHARED_CSS = """
.step { display: inline-flex; align-items: center; width: 1.7em; height: 1.7em; border-radius: 50%; }
.swatch { display: inline-block; width: .85em; height: .85em; border-radius: 2px; }
.doc-toast { position: fixed; bottom: 5.2rem; left: 50%; border-radius: 8px; }
.doc-q-explain { display: none; }
.note { border-radius: 10px; padding: 1em; }
.chip { display: inline-flex; border-radius: 999px; }
"""

HEAD = '<link rel="stylesheet" href="doc.css">'
# 발행 직전 인라인한 모습 — <link> 가 사라져도 `--doc-*` 토큰으로 공유 문서임을 안다
INLINED = '<style>:root{--doc-bg:#fff}</style>'


def run(html):
    """문서 하나를 검사해 (ERROR 수, WARN 수) 를 낸다."""
    shared, _ = lint.parse_css(SHARED_CSS)
    badge = lint.classify(shared)
    with tempfile.NamedTemporaryFile("w", suffix=".html", encoding="utf-8", delete=False) as f:
        f.write(html)
        path = f.name
    try:
        found = lint.check(path, shared, badge)
    finally:
        os.unlink(path)
    return (
        sum(1 for lv, *_ in found if lv == "ERROR"),
        sum(1 for lv, *_ in found if lv == "WARN"),
    )


CASES = [
    # (이름, html, 기대ERROR, 기대WARN)
    (
        "석수동 패턴 — 배지형을 블록 div 에 쓰고 자손 셀렉터로만 손댐",
        HEAD + "<style>.timeline .step{font-weight:600;color:#333}</style>"
        '<div class="timeline"><div class="step">Step5 extract</div></div>',
        1, 1,
    ),
    (
        "infra-console 패턴 — 배지형을 블록 div 에 쓰되 bare 로 display 재정의",
        HEAD + "<style>.step{display:grid;grid-template-columns:110px 1fr}</style>"
        '<div class="step"><strong>Journey 1</strong><p>본문</p></div>',
        0, 0,
    ),
    (
        "learn 패턴 — 배지형을 의도대로 span 배지로 사용",
        HEAD + '<ol><li><span class="step">1</span> 첫 단계</li></ol>',
        0, 0,
    ),
    (
        "doc-toast 회귀 — 부유 컴포넌트는 원래 div 다 (오탐 낸 적 있음)",
        HEAD + '<div class="doc-toast" id="toast"></div>',
        0, 0,
    ),
    (
        "doc-q-explain 회귀 — 숨김형은 JS 가 여는 게 계약 (오탐 42건 낸 적 있음)",
        HEAD + '<li class="doc-q-explain">해설 본문</li>',
        0, 0,
    ),
    (
        "무해한 bare 재정의 — 페이지가 이기므로 통과 (실측 약 70개 문서)",
        HEAD + "<style>.note{border-radius:4px}</style>" + '<div class="note">메모</div>',
        0, 0,
    ),
    (
        "부분 재정의 냄새 — 자손 셀렉터로만 손댔으나 배지형은 아님",
        HEAD + "<style>.doc .chip{color:#555}</style>" + '<div class="doc"><span class="chip">태그</span></div>',
        0, 1,
    ),
    (
        "공유 스타일시트를 안 쓰는 문서는 검사 대상이 아니다",
        "<style>.step{color:red}</style>" + '<div class="step">아무거나</div>',
        0, 0,
    ),
    (
        "인라인 발행본도 검사한다 — <link> 가 사라져도 계약은 남는다",
        INLINED + "<style>.timeline .step{font-weight:600;color:#333}</style>"
        '<div class="timeline"><div class="step">Step5 extract</div></div>',
        1, 1,
    ),
    (
        "SVG 안의 class 는 CSS 박스 모델이 다르므로 세지 않는다",
        HEAD + "<style>.brf .step{fill:#333}</style>"
        '<svg class="brf"><g class="step"><rect/></g></svg>',
        0, 0,
    ),
    (
        "swatch 도 배지형 — .step 전용 규칙이 아니다",
        HEAD + "<style>.legend .swatch{color:#000}</style>"
        '<div class="legend"><p class="swatch">파랑 = 정상</p></div>',
        1, 1,
    ),
]


def check_case(name, html, want_e, want_w):
    """케이스 하나를 판정해 (통과여부, 실패메시지) 를 낸다.

    main() 과 pytest 가 이 함수 하나를 공유한다 — 판정을 두 벌로 두면 갈라진다.
    """
    got_e, got_w = run(html)
    if (got_e, got_w) == (want_e, want_w):
        return True, None
    return False, f"  {name}: ERROR {got_e}(기대 {want_e}) · WARN {got_w}(기대 {want_w})"


def check_oracle():
    """판정 규칙을 무력화하면 1번 케이스가 반드시 통과로 바뀌어야 한다.

    안 바뀌면 위 PASS 들이 규칙이 아니라 다른 이유로 초록이라는 뜻이다.
    """
    real_classify = lint.classify
    lint.classify = lambda bare: set()
    try:
        stubbed_e, _ = run(CASES[0][1])
    finally:
        lint.classify = real_classify
    if stubbed_e == 0:
        return True, None
    return False, "  오라클: 배지형 판정을 없애도 ERROR 가 남았다 — 테스트가 규칙을 검증하지 않는다"


if pytest is not None:
    @pytest.mark.parametrize("case", CASES, ids=[c[0] for c in CASES])
    def test_collision_case(case):
        """CASES 를 pytest 케이스로 편다 — 안 펴면 pytest 가 10건을 못 보고 초록을 낸다."""
        ok, msg = check_case(*case)
        assert ok, msg


def test_oracle():
    ok, msg = check_oracle()
    assert ok, msg


def main():
    fails = []
    for name, html, want_e, want_w in CASES:
        ok, msg = check_case(name, html, want_e, want_w)
        print(f"{'PASS' if ok else 'FAIL'}  {name}")
        if msg:
            fails.append(msg)

    oracle_ok, oracle_msg = check_oracle()
    print(f"{'PASS' if oracle_ok else 'FAIL'}  오라클 — 규칙 제거 시 석수동 케이스가 통과로 바뀐다")
    if oracle_msg:
        fails.append(oracle_msg)

    print(f"\n검사 {len(CASES) + 1}개 · 실패 {len(fails)}")
    for f in fails:
        print(f)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
