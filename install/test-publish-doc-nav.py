#!/usr/bin/env python3
"""install/test-publish-doc-nav.py — the way out of a published document.

Airlock serves documents same-origin with the hub (`/publish/files/...`). That is the
point of the hub, and it has one consequence nobody designed: on a home-screen web app
there is no browser chrome, so a reader who opens a document is inside the standalone
window with no back gesture and no Done button. Measured on iPad 2026-09-02 — stuck.
The legacy box escaped it by accident (documents on another port, so iOS lent them its
own chrome), which is why this only appeared after the migration.

🔴 The platform already owned the answer. `hub/assets/airlock-return.js` exists for
exactly this — "no browser chrome, so no way back to the Airlock entrance" — and the
upstream bundles that cannot be edited get it injected before `</body>` by their gate.
A published document is the same case: a page nobody can edit, thousands of them and
byte-frozen, that still needs a way back. The first version of this fix shipped a
SECOND widget of its own before that was noticed (#333, reverted here).

So what this suite pins is mostly that: the documents get the shared widget, in the
same mode this app's own page already uses, and no second implementation comes back.
"""

import os
import re
import sys

PASS = 0
FAIL = 0

WIDGET = "/airlock-return.js"
TAG = '<script src="/airlock-return.js" data-mode="corner" defer></script>'


def ok(name):
    global PASS
    print(f"ok   publish-doc-nav: {name}")
    PASS += 1


def bad(name, detail=""):
    global FAIL
    print(f"FAIL publish-doc-nav: {name}" + (f" — {detail}" if detail else ""))
    FAIL += 1


def check(name, condition, detail=""):
    ok(name) if condition else bad(name, detail)


def block(source, header):
    """`<header> {` 부터 그 블록의 닫는 중괄호까지. 정규식을 조립하지 않는다 —
    이 레포의 lint 는 패턴이 리터럴이어야 검사할 수 있다고 요구하고, 그 요구가
    맞다. 중괄호 세기는 조립한 패턴보다 짧고 무엇을 자르는지도 더 분명하다."""
    start = source.find(header + " {")
    if start < 0:
        return None
    cursor = source.index("{", start)
    depth = 0
    for index in range(cursor, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[cursor + 1:index]
    return None


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    render = open(os.path.join(root, "apps/publish/render.sh"), encoding="utf-8").read()
    gate = open(os.path.join(root, "install/render-nginx.sh"), encoding="utf-8").read()
    installer = open(os.path.join(root, "apps/publish/install.sh"), encoding="utf-8").read()
    page = open(os.path.join(root, "apps/publish/frontend/publish.html"),
                encoding="utf-8").read()

    # --- 1. the hub's document surface ------------------------------------
    files = block(render, "location /publish/files/")
    check("허브의 문서 location 을 소스에서 찾는다", files is not None)
    if files:
        check("서빙되는 문서에 공용 위젯을 주입한다", TAG in files, files[:200])
        check("한 번만 주입한다 — 문서 안의 </body> 가 여럿일 수 있다",
              "sub_filter_once on" in files)
        check("이 앱 자기 화면과 같은 corner 모드를 쓴다 — 한 박스에 두 모양이면 그게 버그다",
              'data-mode="corner"' in files
              and 'data-mode="corner"' in page)

    # --- 2. nothing that is not a document --------------------------------
    api = block(render, "location /publish/api/")
    check("API 응답에는 주입하지 않는다", api is not None and "sub_filter" not in api)
    assets = block(render, "location /_assets/")
    check("공유 자산(CSS·JS)에는 주입하지 않는다",
          assets is not None and "sub_filter" not in assets)

    # --- 3. the separate document port ------------------------------------
    # 이 포트는 share 디렉터리만 서빙한다. 주입만 하고 위젯 경로를 안 열면 문서마다
    # 404 를 한 번씩 부르고 버튼은 끝내 안 나온다 — 조용한 절반의 고침이 된다.
    dedicated = re.search(
        r"# ==== Publish dedicated document-view gate ====(.*?)"
        r"# ==== End publish dedicated document-view gate ====", gate, re.S)
    check("전용 문서 포트 블록을 소스에서 찾는다", dedicated is not None)
    if dedicated:
        body = dedicated.group(1)
        check("전용 포트의 문서에도 주입한다", body.count(TAG) == 2, str(body.count(TAG)))
        check("전용 포트가 위젯 자체를 서빙한다 — 안 그러면 주입은 404 를 가리킨다",
              "location = /airlock-return.js" in body)

    # --- 4. the duplicate must not come back ------------------------------
    dup = os.path.join(root, "apps/publish/frontend/doc-nav.js")
    check("두 번째 위젯이 되살아나지 않았다", not os.path.exists(dup), dup)
    check("설치기가 두 번째 위젯을 깔지 않는다", "doc-nav.js" not in installer)
    # 양성 대조군 — 대조기가 살아 있나. 이 이름은 소스에 실재한다.
    check("대조기 양성 대조군 — 실재하는 이름은 잡힌다", "airlock-return.js" in render)

    print(f"publish-doc-nav: passed={PASS} failed={FAIL}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
