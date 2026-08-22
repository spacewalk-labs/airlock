#!/usr/bin/env python3
"""저장 헬퍼 — 적재의 성공을 git 이 아니라 **파일 자체**로 증명한다.

적재 스킬은 여기를 통해서만 라이브러리에 문서를 남긴다. 부르는 쪽에서 본 계약은 한 줄이다.

    exit 0 + 영수증 + 지금 그 자리에 있는 파일 = 저장됨

예전 계약은 `git cat-file -e HEAD:<경로>` 였다. 그 한 줄이 라이브러리를 git 레포로 못
박았고 — 스킬이 워크트리를 만들고, 커밋하고, PR 을 열고, 머지한 **뒤에야** 적재가
성공으로 판정됐다. 전사·요약이 20분 걸려 끝난 다음 그 절차가 막히면 결과물은 이미
있는데 판정은 실패였다. 여기서는 그 사이에 아무 단계도 없다: 바이트를 검사하고,
원자적으로 갈아끼우고, 갈아끼운 파일을 **다시 읽어** 영수증을 쓴다.

세 가지를 이 파일 하나가 소유한다. 갈라지면 조용히 어긋나는 것들이라 한군데 둔다.

  · **문서 경로 문법** — 완료 마커(`INGEST_DONE_RE`)가 받는 모양과 같아야 한다.
    헬퍼가 더 깊은 경로를 받아 주면 스킬은 저장에 성공하고 러너는 그 자리를 확인하지
    못한다.
  · **학습자료 판정** — 크기·프론트매터·video_id. 저장 시점과 검증 시점이 같은 함수를
    쓴다. 예전에는 검증 쪽에만 있어서, 스킬이 빈 파일을 쓰는 것 자체는 아무도 안 막았다.
  · **문서 단위 락** — 저장과 (카드 4단계의) 프론트매터 수정이 같은 락을 잡는다.

CLI:

    python3 save_document.py --path <라이브러리 상대경로>.md [--video-id ID]
                             [--library ROOT] [--from FILE] [--receipt PATH]

내용은 `--from` 이 없으면 표준입력에서 읽는다. 성공하면 영수증 JSON 한 줄을 표준출력에
찍고 exit 0, 실패하면 사람 문장을 표준오류에 찍고 exit 2 — **그리고 대상 파일은 손대지
않는다.** 검사는 전부 이름 바꾸기 전에 끝난다.

경계는 `os.replace` 다. 그 뒤의 실패는 저장을 되돌리지 못하므로 보통 exit 2 가 되지
않는다 — 영수증을 못 쓰거나 디렉터리를 fsync 하지 못하면 표준오류에 `[경고]` 를 찍고
exit 0 으로 끝난다. 그때 표준출력의 JSON 은 `{"receipt": false}` 이고, 러너는 그 상태에
이미 이름을 갖고 있다(`completed-without-receipt`).

**예외는 하나, `write-verify-failed` 다.** 갈아끼운 자리를 다시 읽었는데 내용이 다르면
같은 문서를 다른 무언가가 동시에 쓰고 있다는 뜻이고, 그때는 무엇이 남았는지 아무도
모른다. 그 하나만 이름 바꾸기 뒤에도 exit 2 이며, 메시지가 **파일은 이미 갈아끼워졌다**고
함께 말한다. 조용한 성공보다 시끄러운 실패가 맞는 유일한 자리다.
"""

import argparse
import contextlib
import errno
import fcntl
import hashlib
import json
import os
import re
import stat
import sys
import tempfile
import time
from datetime import datetime, timezone

# 프론트매터(제목·url·video_id·duration…)만으로도 이미 넘는 크기다. 목적은 빈 파일·
# 플레이스홀더를 걸러내는 것이고 내용 품질 판정이 아니다.
DOCUMENT_MIN_BYTES = 400

# 🔴 완료 마커가 받는 모양과 **같아야 한다** (`INGEST_DONE_RE`, airlock-learning.py).
#    라이브러리 루트 바로 아래이거나, 카테고리 폴더 한 단계 아래.
DOCUMENT_PATH_RE = re.compile(r"\A(?:[^/\s]+/)?[^/\s]+\.md\Z")

# 프론트매터 블록을 줄 단위로 훑는다.
VIDEO_ID_RE = re.compile(  # noqa: regex-anchor  # 프론트매터 블록을 줄 단위로 읽는다 — 여기의 ^$ 는 값 검증이 아니라 줄 경계다
    rb'^video_id:[ \t]*"?([A-Za-z0-9_-]{1,128})"?[ \t\r]*$', re.MULTILINE)

RECEIPT_SCHEMA = 1
# 적재의 단계. 지금 이 헬퍼가 증명할 수 있는 것은 첫 단계뿐이다 — 렌더와 발행은 뒤에
# 오고, 각자 자기 시점에 자기 영수증을 쓴다(카드 3단계가 이 값을 화면에 올린다).
PHASE_DOCUMENT_SAVED = "document_saved"

DEFAULT_STATE_DIR = "~/.local/state/airlock-learning"
LOCK_TIMEOUT_SECONDS = 30.0
# 상태 패치(별표·보관)는 전역 상태 락을 쥔 채로 들어온다. 여기서 오래 기다리면 그동안
# 앱의 다른 요청이 전부 멈추므로 짧게 잡고, 못 잡으면 사용자에게 다시 누르라고 말한다.
PATCH_LOCK_TIMEOUT_SECONDS = 5.0


class DocumentChanged(Exception):
    """교체 직전에 대상 파일이 우리가 읽은 것과 달랐다."""


class SaveError(Exception):
    """사람이 읽을 실패 사유. reason 은 러너의 상태 코드로 그대로 올라간다."""

    def __init__(self, reason, message):
        super().__init__(message)
        self.reason = reason
        self.message = message


# --- 문서 판정: 저장하는 쪽과 검증하는 쪽이 같은 코드를 쓴다 ---

# 프론트매터가 닫혀야 하는 줄 수. 🔴 이 상한은 **읽는 쪽과 고치는 쪽이 같아야 한다.**
# 다르면 한쪽은 "프론트매터가 없다" 고 하고 다른 쪽은 한참 아래의 본문 `---` 를 닫는
# 울타리로 읽는다 — 그 상태로 키를 쓰면 본문 줄을 덮어쓴다(적대검증 2026-08-22).
FRONTMATTER_MAX_LINES = 60

BOM = b"\xef\xbb\xbf"


def fence_line(line):
    """그 줄이 `---` 울타리인가.

    🔴 `bytes.strip()` 은 **ASCII 공백만** 걷는다. 편집기가 남긴 NBSP(U+00A0) 하나가
    줄 끝에 붙으면 바이트 비교는 울타리를 못 알아보고, 그러면 한참 아래 본문의 `---` 를
    닫는 울타리로 읽어 **본문 줄이 프론트매터로 취급된다.** 실제로 그 상태에서 본문의
    `starred: not a key` 가 `starred: true` 로 덮어써졌다. 디코드해서 유니코드 공백까지
    걷는 것이 읽는 쪽(`read_front_matter`)의 규칙이고, 여기도 같아야 한다.
    """
    return line.decode("utf-8", "replace").strip() == "---"


def frontmatter_bounds(blob):
    """(줄 목록, 여는 울타리 index, 닫는 울타리 index). 프론트매터가 없으면 None.

    `frontmatter_block` 과 같은 규칙을 쓰되 **자리**를 돌려준다 — 읽기만 하는 쪽은 블록
    문자열이면 되지만, 고치는 쪽은 나머지 줄을 한 글자도 안 건드리려면 자리를 알아야 한다.

    이 함수가 이 기능의 **유일한** 프론트매터 파서다. 한때 둘이었고(백엔드는 디코드된
    문자열을 utf-8-sig 로, 헬퍼는 원시 바이트를), 적대검증이 낸 HIGH 세 건이 전부 그 둘이
    어긋나는 자리였다 — BOM 문서에서 버튼은 켜지고 요청은 409, NBSP 울타리에서 본문 덮어쓰기,
    60줄 넘는 프론트매터에서 읽기 전용 오판.
    """
    lines = blob.split(b"\n")
    if lines and lines[0].startswith(BOM):
        lines = [lines[0][len(BOM):]] + lines[1:]
    start = 0
    while start < len(lines) and not lines[start].strip():
        start += 1
    if start >= len(lines) or not fence_line(lines[start]):
        return None
    limit = min(len(lines), start + 1 + FRONTMATTER_MAX_LINES)
    for index in range(start + 1, limit):
        if fence_line(lines[index]):
            return lines, start, index
    return None


def frontmatter_block(blob):
    r"""첫 `---` 와 두 번째 `---` 사이. 없으면 None.

    🔴 `split(..., 2)[-1]` 로 잡으면 **본문**을 뒤지게 되어 늘 "video_id 없음" 이 된다
    (실측 2026-07-31: 그 실수로 9개 테스트가 그 진단으로 빨갰다). 본문에 우연히
    `video_id:` 가 있어도 그건 근거가 아니다.

    🔴 `split(b"---", 2)` 로도 안 된다 — 그건 **줄이 아니라 바이트열**을 찾는다. 제목이
    `title: "Rust --- part 1"` 이면 프론트매터가 거기서 잘려 `video_id` 가 본문 쪽으로
    넘어가고, 그러면 저장 자체가 거절된다(적대검증 2026-08-22).

    🔴 그렇다고 울타리를 `== b"---"` 로 엄격히 보면 **옛 파서가 받던 문서를 떨어뜨린다.**
    줄 끝의 공백 하나, 앞의 빈 줄 하나로 "프론트매터 없음" 이 되고 — 같은 함수가 이제
    쓰기까지 막으므로 — 멀쩡한 1,448바이트 문서의 저장이 거절된다. LLM 이 쓴 문서에 줄 끝
    공백은 흔하다. 그래서 울타리 줄은 `strip()` 해서 본다(2차 적대검증 2026-08-22).
    CRLF 도 이 `strip()` 이 함께 흡수한다.

    옛 파서와 달라지는 것이 하나 남는다: `----` 는 더 이상 울타리가 아니다. `lstrip()`
    으로 앞만 보던 옛 검사는 그것을 통과시켰다. YAML 의 구분선은 `---` 이고, 이 좁힘은
    의도한 것이다.
    """
    bounds = frontmatter_bounds(blob)
    if bounds is None:
        return None
    lines, start, end = bounds
    return b"\n".join(lines[start + 1:end])


def frontmatter_video_id(blob):
    front = frontmatter_block(blob)
    if front is None:
        return None
    found = VIDEO_ID_RE.search(front)
    return found.group(1).decode("ascii", "replace") if found else None


def document_defect(blob, relative, video_id=None):
    """학습자료로 볼 수 없으면 (reason, 사람 문장). 통과하면 (None, None).

    reason 은 러너가 `marker-document-<reason>` 으로 올려 쓰던 것과 같은 어휘다.
    """
    front = frontmatter_block(blob)
    if len(blob) < DOCUMENT_MIN_BYTES or front is None:
        return "empty", (
            f"산출물이 학습자료 모양이 아닙니다: {relative} — "
            f"{len(blob)}바이트, 프론트매터 {'있음' if front is not None else '없음'}"
        )
    if not video_id:
        return None, None
    # 🔴 **그 요청의 영상인지** 본다. 여기까지의 검사는 "학습자료 하나가 있다" 만 증명한다 —
    #    영상 A 요청이 무관한 기존 문서 B 를 가리키면 A 가 done 으로 기록되고, 상태에는
    #    문서 B 경로가 정상으로 남아 A 누락이 드러나지 않는다(적대검증 2026-07-31).
    #    판정 근거는 프론트매터 `video_id` 다 — 파일명은 사람이 바꿀 수 있다.
    actual = frontmatter_video_id(blob)
    if actual is None:
        return "no-video-id", (
            f"산출물 프론트매터에 video_id 가 없습니다: {relative} — "
            f"요청 영상({video_id})의 문서인지 확인할 수 없습니다"
        )
    if actual != video_id:
        return "other-video", (
            f"산출물이 **다른 영상**의 문서입니다: {relative} — "
            f"문서 video_id={actual}, 요청={video_id}. 이 요청의 산출물이 없습니다"
        )
    return None, None


def resolve_in_library(library, relative):
    """(절대경로, 라이브러리 상대경로). 문법 위반이나 라이브러리 밖이면 SaveError."""
    candidate = (relative or "").strip()
    if candidate.startswith("./"):
        candidate = candidate[2:]
    if not DOCUMENT_PATH_RE.fullmatch(candidate):
        raise SaveError("path-shape", (
            f"문서 경로가 규칙에 맞지 않습니다: {relative!r} — "
            "`이름.md` 또는 `카테고리/이름.md` 여야 합니다"
            " (완료 표시가 읽는 모양과 같아야 합니다)"))
    root = os.path.realpath(library)
    target = os.path.realpath(os.path.join(root, candidate))
    if target != root and not target.startswith(root + os.sep):
        raise SaveError("outside-library",
                        f"문서가 라이브러리 밖을 가리킵니다: {relative}")
    # 🔴 돌려주는 상대경로는 **받은 그대로**이고, 그래서 위의 문법을 만족한다 — 영수증에
    #    실린 값을 스킬이 완료 표시에 그대로 되받아 쓸 수 있어야 하기 때문이다. 해석된
    #    경로를 실으면 `ai -> topics/deep/ai` 같은 두 단계 링크에서 두 문법이 갈라진다.
    #
    #    동일성 판정은 문자열이 아니라 **realpath** 로 한다(러너 `_verify_document`).
    #    한때 여기서 해석 전 경로를, 러너에서 해석 후 경로를 문자열로 맞대 봐서, `ai ->
    #    topics/ai` 로 정리해 둔 사용자의 저장이 성공한 뒤 "영수증이 다른 문서를 가리킵니다"
    #    로 실패했다 — 같은 문자열을 두 번 찍으면서(적대검증 2026-08-22). 고칠 자리는
    #    어느 철자를 싣느냐가 아니라 **철자로 맞대 본 것** 쪽이었다.
    return target, candidate


# --- 문서 단위 락 ---

def document_lock_path(state_dir, relative):
    """락은 **상태 디렉터리**에 둔다 — 라이브러리는 사용자 것이고 이 앱은 문서 말고는
    아무것도 거기에 쓰지 않는다."""
    digest = hashlib.sha256(relative.encode("utf-8")).hexdigest()[:32]
    return os.path.join(state_dir, "locks", digest + ".lock")


@contextlib.contextmanager
def document_lock(state_dir, relative, timeout=None):
    """같은 문서에 두 쓰기가 겹치지 않게 한다. 카드 4단계의 프론트매터 수정도 이 락을 쓴다.

    `timeout` 을 부르는 쪽이 정할 수 있다. 별표 한 번은 전역 상태 락을 쥔 채로 들어오므로
    여기서 30초를 기다리면 **그동안 앱의 모든 요청이 멈춘다** — 그 경로는 짧게 잡는다.
    """
    path = document_lock_path(state_dir, relative)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    handle = open(path, "a+")
    try:
        _flock_with_timeout(handle, relative, timeout)
        yield
    finally:
        with contextlib.suppress(OSError):
            handle.close()   # close 가 flock 을 푼다


def _flock_with_timeout(handle, relative, timeout=None):
    """상대는 같은 문서를 쓰는 다른 프로세스이고 그쪽은 짧다 — 기다렸다 잡는다."""
    limit = LOCK_TIMEOUT_SECONDS if timeout is None else timeout
    deadline = time.monotonic() + limit
    while True:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except OSError as exc:
            if exc.errno not in (errno.EACCES, errno.EAGAIN):
                raise
            if time.monotonic() >= deadline:
                raise SaveError("locked", (
                    f"같은 문서를 다른 작업이 쓰고 있습니다: {relative} — "
                    f"{limit:.0f}초 기다렸습니다"))
            time.sleep(0.1)


# --- 원자적 쓰기 ---

def atomic_write(target, blob, mode=0o644, expect=None):
    """같은 디렉터리의 임시 파일에 쓰고 fsync 한 뒤 rename 한다. 경고 목록을 돌려준다.

    🔴 대상 파일은 **끝까지 쓰인 내용으로 한 번에** 바뀌거나 아예 안 바뀐다. 실패한
    저장이 반쯤 쓰인 문서를 남기면 그 다음 검증은 "크기·프론트매터 통과"로 읽는다.

    `os.replace` 가 돌아온 순간 저장은 끝난 것이다. 그 뒤의 디렉터리 fsync 는 **전원이
    나갔을 때 남아 있느냐**의 문제이지 저장이 됐느냐의 문제가 아니므로, 실패해도 예외로
    올리지 않고 경고로 돌려준다 — 올리면 이미 갈아끼운 파일을 두고 "저장하지 못했습니다"
    라고 말하게 된다(적대검증 2026-08-22).
    """
    directory = os.path.dirname(target) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".airlock-learning-", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(blob)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        # 🔴 확인은 **교체 직전**에 한다. 한때 이 확인이 계산 전에 있었고, 적대검증이
        #    창을 재 봤더니 지켜지는 구간이 80µs, 안 지켜지는 구간이 380µs 였다 — fsync
        #    두 번이 전부 뒤쪽에 있었기 때문이다. 여기로 옮기면 남는 창은 이 비교와
        #    `os.replace` 사이뿐이다. 파일 시스템에 compare-and-swap 이 없으므로 창을
        #    0 으로 만들 수는 없고, 이것이 만들 수 있는 가장 작은 창이다.
        if expect is not None:
            with open(target, "rb") as handle:
                if handle.read() != expect:
                    raise DocumentChanged(target)
        os.replace(tmp, target)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise
    try:
        dir_fd = os.open(directory, os.O_RDONLY)
    except OSError as exc:
        return [f"{target} 를 갈아끼웠지만 디렉터리를 fsync 하지 못했습니다: {exc}"]
    try:
        os.fsync(dir_fd)
    except OSError as exc:
        return [f"{target} 를 갈아끼웠지만 디렉터리를 fsync 하지 못했습니다: {exc}"]
    finally:
        os.close(dir_fd)
    return []


# --- 프론트매터의 상태 키를 제자리에서 고친다 ---

# 고쳐도 되는 키. 🔴 목록은 좁게 유지한다 — 이 앱이 남의 문서에서 손대도 되는 것은
# 이 앱이 만든 상태뿐이다. 제목·url·video_id 는 사용자와 적재가 쓴 것이고, 여기서
# 고칠 이유가 생기면 그건 이 함수가 아니라 설계가 잘못된 것이다.
PATCHABLE_KEYS = ("starred", "archived")

# 줄 맨 앞의 키. 들여쓴 줄은 중첩 값이므로 건드리지 않는다.
FRONTMATTER_KEY_RE = re.compile(rb"\A([A-Za-z_][A-Za-z0-9_]*)[ \t]*:")


def _line_ending(line):
    """그 줄이 CRLF 였으면 b"\r", 아니면 b""."""
    return b"\r" if line.endswith(b"\r") else b""


def apply_frontmatter_updates(blob, updates):
    """프론트매터의 키만 고친 새 바이트. 프론트매터가 없으면 None.

    바꾸는 것은 해당 키의 줄 하나뿐이고, 나머지는 **한 바이트도 건드리지 않는다** —
    라이브러리는 사용자 파일이고, 별표 하나 누른 대가로 문서가 재조판되면 안 된다.
    값이 None 인 키는 지운다. 없는 키를 참으로 만들면 닫는 울타리 바로 앞에 넣는다.
    """
    bounds = frontmatter_bounds(blob)
    if bounds is None:
        return None
    lines, start, end = bounds
    # `frontmatter_bounds` 는 판정을 위해 BOM 을 걷어낸 줄 목록을 준다. 되붙이지 않으면
    # 별표 한 번에 파일의 BOM 이 사라진다 — 그것도 "그 줄 말고는 안 바뀐다" 의 위반이다.
    prefix = BOM if blob.startswith(BOM) else b""
    ending = _line_ending(lines[end]) if end < len(lines) else b""
    out = list(lines)
    remaining = dict(updates)
    written = set()
    kept = []
    for index in range(start + 1, end):
        match = FRONTMATTER_KEY_RE.match(out[index])
        key = match.group(1).decode("ascii") if match else None
        if key is None or (key not in remaining and key not in written):
            kept.append(out[index])
            continue
        if key in written:
            # 🔴 같은 키가 두 번 있으면 **뒤엣것을 지운다.** 읽는 쪽은 마지막 값을 쓰므로,
            #    앞만 고치면 파일은 바뀌는데 화면은 그대로다 — "버튼이 고장 났다" 로
            #    읽히고, 해제도 같은 이유로 안 먹는다(적대검증 2026-08-22).
            continue
        value = remaining.pop(key)
        written.add(key)
        if value is None:
            continue     # 줄째로 지운다
        kept.append(f"{key}: {value}".encode("utf-8") + _line_ending(out[index]))
    for key, value in remaining.items():
        if value is None:
            continue     # 지우라는데 애초에 없다
        kept.append(f"{key}: {value}".encode("utf-8") + ending)
    return prefix + b"\n".join(out[:start + 1] + kept + out[end:])


def patch_frontmatter(library, relative, updates, state_dir=None):
    """문서의 프론트매터 상태 키를 고친다. (sha256, 경고 목록).

    🔴 쓰기 직전에 파일을 **다시 읽어** 계산의 근거가 아직 그대로인지 본다. 문서 단위
    락은 이 앱의 쓰기끼리만 지켜 준다 — 같은 파일을 편집기로 열어 둔 사람은 락을 모르고,
    파일 시스템에는 compare-and-swap 이 없다. 그래서 이 재확인은 창을 **좁히는** 것이지
    닫는 것이 아니다. 좁히는 값은 있다: 별표 한 번에 사용자가 방금 쓴 문단이 사라지는
    것과, 그 요청이 409 로 거절되는 것의 차이다.
    """
    for key in updates:
        if key not in PATCHABLE_KEYS:
            raise SaveError("unpatchable-key", (
                f"이 앱이 고칠 수 있는 프론트매터 키가 아닙니다: {key} — "
                f"고칠 수 있는 것은 {', '.join(PATCHABLE_KEYS)} 뿐입니다"))
    target, relative = resolve_in_library(library, relative)
    state_dir = state_dir or os.path.abspath(os.path.expanduser(
        os.environ.get("AIRLOCK_LEARNING_STATE_DIR") or DEFAULT_STATE_DIR))

    warnings = []
    with document_lock(state_dir, relative, PATCH_LOCK_TIMEOUT_SECONDS):
        try:
            with open(target, "rb") as handle:
                before = handle.read()
            mode = stat.S_IMODE(os.stat(target).st_mode)
        except OSError as exc:
            raise SaveError("unreadable", f"문서를 읽지 못했습니다: {relative} — {exc}")
        after = apply_frontmatter_updates(before, updates)
        if after is None:
            # 고치지 않는다. 프론트매터가 없는 문서를 **고쳐 주는** 것은 수리이고,
            # 남의 문서를 수리하지 않는 것이 이 앱의 규칙이다.
            raise SaveError("no-frontmatter", (
                f"프론트매터가 없어 상태를 적을 수 없습니다: {relative} — "
                "이 문서는 목록에서 읽기 전용입니다"))
        if after == before:
            return hashlib.sha256(before).hexdigest(), warnings
        try:
            # 🔴 모드를 **그대로 둔다.** 기본 644 로 쓰면 0600 짜리 개인 메모가 별표
            #    한 번에 세상에 열린다(적대검증 2026-08-22).
            warnings += atomic_write(target, after, mode, expect=before)
        except DocumentChanged as exc:
            raise SaveError("document-changed", (
                f"쓰는 사이에 문서가 바뀌었습니다: {relative} — "
                "지금 화면에 보이는 내용이 파일과 다릅니다. 다시 시도하십시오")) from exc
    return hashlib.sha256(after).hexdigest(), warnings


# `occupant_video_id` 가 "자리가 비었다" 를 말하는 값. None 은 "문서는 있는데 video_id 가
# 없다" 라는 다른 뜻이므로 구분해야 한다.
FREE = object()


def occupant_video_id(target):
    """그 자리에 이미 있는 문서의 `video_id`. 자리가 비었으면 FREE.

    읽지 못하는 파일이 있으면 `None` — **비었다고 답하지 않는다.** 못 읽는 것을 없는 것으로
    치면 그 파일을 덮어쓰게 된다.
    """
    if not os.path.exists(target):
        return FREE
    try:
        with open(target, "rb") as handle:
            return frontmatter_video_id(handle.read())
    except OSError:
        return None


def read_receipt(path):
    """영수증을 읽는다. 없거나 못 읽으면 None — 판정은 부르는 쪽이 한다."""
    try:
        with open(path, "rb") as handle:
            data = json.loads(handle.read().decode("utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def save(library, relative, blob, video_id=None, state_dir=None, receipt_path=None,
         html=None):
    """검사 → 락 → 원자적 쓰기 → **다시 읽어** 영수증. (영수증|None, 경고 목록)을 돌려준다.

    🔴 경계는 `os.replace` 다. **그 전에** 걸린 것은 전부 SaveError 이고 대상 파일은
    손대지 않은 채로 남는다. **그 뒤에** 걸린 것은 저장을 되돌리지 못하므로 실패가 아니라
    경고다 — 영수증을 못 쓰거나 다시 읽지 못하면 증거가 없어지는 것이지 저장이 없어지는
    것이 아니다. 그때 영수증은 None 이고, 러너는 이미 그 상태에 이름을 갖고 있다
    (`completed-without-receipt`). 예외는 `write-verify-failed` 하나뿐이다(모듈 주석).

    적대검증(2026-08-22)이 잡은 것이 정확히 이 자리였다. 영수증 디렉터리에 쓸 수 없으면
    문서는 디스크에 멀쩡히 있는데 CLI 가 exit 2 로 "저장하지 못했습니다" 를 찍었고, 스킬은
    아무것도 저장되지 않았다고 읽었다. 이 함수가 없애려던 실패가 바로 그것이다.
    """
    target, relative = resolve_in_library(library, relative)
    reason, message = document_defect(blob, relative, video_id)
    if reason is not None:
        raise SaveError(reason, message)

    state_dir = state_dir or os.path.abspath(os.path.expanduser(
        os.environ.get("AIRLOCK_LEARNING_STATE_DIR") or DEFAULT_STATE_DIR))
    warnings = []
    with document_lock(state_dir, relative):
        # 🔴 **남의 문서를 덮지 않는다.** 파일 이름을 고르는 것은 모델이고, 모델은 라이브러리를
        #    본 뒤에도 이미 있는 이름을 고를 수 있다 — 실측 2026-08-22: 실제 적재 한 번이
        #    사용자의 기존 문서를 지우고 `done` 으로 기록됐다. 경고도 로그도 없었다.
        #    같은 영상의 문서를 다시 쓰는 것(재시도)만 허용한다: 그건 우리가 쓴 것이다.
        existing = occupant_video_id(target)
        if existing is not FREE and (not video_id or existing != video_id):
            raise SaveError("path-taken", (
                f"그 자리에 이미 다른 문서가 있습니다: {relative}"
                + (f" (그 문서의 video_id={existing})" if existing else "")
                + " — 덮어쓰지 않습니다. 다른 이름을 고르십시오"))
        warnings += atomic_write(target, blob)
        # 🔴 렌더된 짝은 **같은 락 안에서** 함께 들어간다. 이 파일이 없으면 그 문서는
        #    영원히 공유할 수 없다 — publish 로 나가는 것은 `.md` 가 아니라 `.html` 이고,
        #    `mutable` 판정도 이 짝의 존재를 본다. 문서만 저장하고 짝을 잊으면, 목록에는
        #    보이는데 공유 버튼만 안 먹는 자료가 조용히 쌓인다.
        if html is not None:
            # 🔴 `.md` 는 이미 갈아끼워졌다. 여기서 예외를 올리면 "실패하면 대상 파일은
            #    손대지 않는다" 가 두 번째로 깨진다 — 문서는 저장됐는데 exit 2 다.
            #    짝이 없으면 그 문서는 공유·보관이 안 되므로 그것을 **경고로 말한다.**
            try:
                warnings += atomic_write(target[:-3] + ".html", html)
            except OSError as exc:
                warnings.append(
                    f"{relative} 는 저장했지만 렌더된 짝을 쓰지 못했습니다: {exc} — "
                    "이 문서는 짝이 생길 때까지 공유·보관할 수 없습니다")
                html = None
        # 🔴 의도가 아니라 **디스크에 있는 것**의 다이제스트를 싣는다. 영수증이 파일과
        #    따로 놀면 영수증은 자기보고가 되고, 그건 우리가 걷어낸 그것이다.
        try:
            with open(target, "rb") as handle:
                written = handle.read()
        except OSError as exc:
            return None, warnings + [
                f"{relative} 를 저장했지만 다시 읽지 못해 영수증을 만들지 못했습니다: {exc}"]

    if written != blob:
        # 갈아끼운 뒤 그 자리의 내용이 다르다 = 다른 무언가가 같은 파일을 쓰고 있다.
        # 저장은 일어났으므로 그 사실을 함께 말한다.
        raise SaveError("write-verify-failed", (
            f"저장 직후 다시 읽은 내용이 다릅니다: {relative} — "
            f"{len(blob)}바이트를 썼는데 {len(written)}바이트가 읽힙니다. "
            "파일은 이미 갈아끼워졌고, 다른 무언가가 같은 문서를 쓰고 있습니다"))

    receipt = {
        "schema": RECEIPT_SCHEMA,
        "phase": PHASE_DOCUMENT_SAVED,
        "library": os.path.realpath(library),
        "path": relative,
        "bytes": len(written),
        "sha256": hashlib.sha256(written).hexdigest(),
        "video_id": frontmatter_video_id(written),
        "html": relative[:-3] + ".html" if html is not None else None,
        "saved_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    if receipt_path:
        try:
            warnings += atomic_write(
                receipt_path,
                json.dumps(receipt, ensure_ascii=False, sort_keys=True).encode("utf-8") + b"\n",
                0o600)
        except OSError as exc:
            return None, warnings + [
                f"{relative} 를 저장했지만 영수증을 쓰지 못했습니다: {exc}"]
    return receipt, warnings


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="save_document.py",
        description="학습 문서를 라이브러리에 원자적으로 저장하고 영수증을 낸다")
    parser.add_argument("--path", required=True,
                        help="라이브러리 상대경로 (이름.md 또는 카테고리/이름.md)")
    parser.add_argument("--library", default=None,
                        help="라이브러리 루트 (기본: AIRLOCK_LEARNING_LIBRARY)")
    parser.add_argument("--video-id", default=None,
                        help="이 문서가 그 영상의 것인지 프론트매터로 확인한다")
    parser.add_argument("--from", dest="source", default=None,
                        help="내용을 읽을 파일 (기본: 표준입력)")
    parser.add_argument("--receipt", default=None,
                        help="영수증을 쓸 경로 (기본: AIRLOCK_LEARNING_RECEIPT)")
    parser.add_argument("--html", default=None,
                        help="렌더된 짝(.html)을 읽을 파일 — 없으면 그 문서는 공유할 수 없다")
    args = parser.parse_args(argv)

    library = args.library or os.environ.get("AIRLOCK_LEARNING_LIBRARY")
    if not library:
        # cwd 로 조용히 내려앉지 않는다 — 틀린 폴더에 문서를 쓰는 것보다 안 쓰는 게 낫다.
        print("라이브러리를 알 수 없습니다 — --library 를 주거나 "
              "AIRLOCK_LEARNING_LIBRARY 를 설정하세요", file=sys.stderr)
        return 2
    if not os.path.isdir(library):
        print(f"라이브러리 폴더가 없습니다: {library}", file=sys.stderr)
        return 2

    try:
        if args.source:
            with open(args.source, "rb") as handle:
                blob = handle.read()
        else:
            blob = sys.stdin.buffer.read()
    except OSError as exc:
        print(f"내용을 읽지 못했습니다: {exc}", file=sys.stderr)
        return 2

    rendered = None
    if args.html:
        try:
            with open(args.html, "rb") as handle:
                rendered = handle.read()
        except OSError as exc:
            print(f"렌더된 짝을 읽지 못했습니다: {exc}", file=sys.stderr)
            return 2

    receipt_path = args.receipt or os.environ.get("AIRLOCK_LEARNING_RECEIPT") or None
    try:
        receipt, warnings = save(library, args.path, blob, args.video_id,
                                 receipt_path=receipt_path, html=rendered)
    except SaveError as exc:
        print(f"[{exc.reason}] {exc.message}", file=sys.stderr)
        return 2
    except OSError as exc:
        # 이름 바꾸기 전의 실패만 여기 온다 — 그 뒤의 것은 save() 가 경고로 바꾼다.
        print(f"저장하지 못했습니다: {exc}", file=sys.stderr)
        return 2
    for warning in warnings:
        print(f"[경고] {warning}", file=sys.stderr)
    if receipt is None:
        # 문서는 저장됐다. 없어진 것은 영수증이고, 그건 exit 0 을 뒤집지 않는다.
        print(json.dumps({"phase": PHASE_DOCUMENT_SAVED, "receipt": False},
                         ensure_ascii=False, sort_keys=True))
        return 0
    print(json.dumps(receipt, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
