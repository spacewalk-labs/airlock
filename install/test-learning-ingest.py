#!/usr/bin/env python3
"""install/test-learning-ingest.py — the learning ingest write path.

This app shipped with no suite at all. `apps/learning/smoke.sh` was the only thing
that would have noticed a regression, and a smoke runs on a live box against a live
library: it can say "the list answers 200" and nothing about what happens when a
document is written. That was survivable while the port was read-only. It stopped
being survivable when the success verdict moved off git.

What moved: ingest used to be judged by `git cat-file -e HEAD:<path>` plus
`git diff --quiet HEAD`. Those two lines nailed the library to a git repository —
the skill had to create a worktree, commit, open a PR and merge before an ingest
that had *already produced the document* could be called done, and the failure
arrived after tens of minutes of transcription. Now the judge reads the file
itself, and `save_document.py` is what puts the file there: validate before
rename, atomic replace, and a receipt whose digest is taken by re-reading what
landed on disk.

So the cases below are the properties a live smoke structurally cannot see: a
rejected save leaves nothing behind, a receipt does not survive its own document
being edited, and a plain folder now reaches `done` — while a git library with an
uncommitted document, which the four git calls made impossible, reaches it too.
"""

import ast
import contextlib
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import tempfile


# 워커가 띄우는 가짜 에이전트 CLI. 진짜 CLI 가 하는 일 중 이 스위트가 재는 것만 한다 —
# 환경에서 저장 헬퍼와 라이브러리를 받아 문서를 남기고, 완료 표시를 로그(=stderr)에 찍는다.
FAKE_CLI = r'''#!/usr/bin/env python3
import os
import subprocess
import sys

mode = os.environ.get("FAKE_CLI_MODE", "save")
body = "\ubcf8\ubb38 " * 200
if mode == "save":
    doc = ('---\ntitle: "worker"\nvideo_id: xxxxxxxxxx1\n'
           'added: 2026-08-22\n---\n\n' + body + '\n').encode("utf-8")
    subprocess.run([sys.executable, os.environ["AIRLOCK_LEARNING_SAVE"],
                    "--path", "worker.md", "--video-id", "xxxxxxxxxx1"],
                   input=doc, check=True)
    print("LEARNING-INGEST-DONE worker.md", file=sys.stderr)
else:
    # 헬퍼를 쓰지 않고 완료 표시만 낸다 — 이미 있는 문서를 가리킨다.
    print("LEARNING-INGEST-DONE worker2.md", file=sys.stderr)
'''

PASS = 0
FAIL = 0


def ok(name):
    global PASS
    print(f"ok   learning-ingest: {name}")
    PASS += 1


def bad(name, detail=""):
    global FAIL
    print(f"FAIL learning-ingest: {name}" + (f" — {detail}" if detail else ""))
    FAIL += 1


def check(name, condition, detail=""):
    ok(name) if condition else bad(name, detail)


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def document(video_id="dQw4w9WgXcQ", title="테스트 문서"):
    body = "본문 " * 200
    return (f'---\ntitle: "{title}"\nvideo_id: {video_id}\n'
            f'added: 2026-08-22\n---\n\n{body}\n').encode("utf-8")


def strays(root):
    """저장이 남긴 임시 파일. 실패한 저장은 하나도 남기면 안 된다."""
    found = []
    for base, _dirs, files in os.walk(root):
        found += [os.path.join(base, f) for f in files if f.startswith(".airlock-learning-")]
    return found


def main(argv):
    root = os.path.abspath(argv[1]) if len(argv) > 1 else os.path.abspath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    backend_dir = os.path.join(root, "apps", "learning", "backend")
    save_path = os.path.join(backend_dir, "save_document.py")

    tmp = tempfile.mkdtemp(prefix="learning-ingest-test-")
    library = os.path.join(tmp, "library")
    state = os.path.join(tmp, "state")
    os.makedirs(library)
    os.makedirs(state)
    # 러너와 백엔드는 임포트 시점에 환경을 읽는다. 실제 라이브러리를 건드리지 않도록
    # 임포트보다 먼저 건다.
    os.environ["AIRLOCK_LEARNING_LIBRARY"] = library
    os.environ["AIRLOCK_LEARNING_STATE_DIR"] = state
    os.environ["AIRLOCK_LEARNING_SHARE_DIR"] = os.path.join(tmp, "share")

    SAVE = load(save_path, "learning_save_document_test")
    RUNNER = load(os.path.join(backend_dir, "ingest_runner.py"), "learning_ingest_runner_test")
    BACKEND = RUNNER.BACKEND

    try:
        # ---- 1. 문서 경로 문법. 완료 마커가 읽는 모양과 같아야 한다 ----
        for label, relative in (
            ("상위로 빠져나가는 경로", "../escape.md"),
            ("절대경로", "/etc/passwd.md"),
            ("두 단계보다 깊은 경로", "a/b/c.md"),
            (".md 가 아닌 파일", "notes.txt"),
            ("빈 경로", ""),
        ):
            try:
                SAVE.save(library, relative, document())
                bad(f"{label}를 저장이 받았다", relative)
            except SAVE.SaveError as exc:
                check(f"{label}를 거절한다", exc.reason in ("path-shape", "outside-library"),
                      f"reason={exc.reason}")

        # 카테고리처럼 보이지만 라이브러리 밖을 가리키는 심볼릭 링크.
        outside = os.path.join(tmp, "outside")
        os.makedirs(outside)
        os.symlink(outside, os.path.join(library, "elsewhere"))
        try:
            SAVE.save(library, "elsewhere/x.md", document())
            bad("라이브러리 밖으로 나가는 심볼릭 링크를 저장이 받았다")
        except SAVE.SaveError as exc:
            check("라이브러리 밖으로 나가는 심볼릭 링크를 거절한다",
                  exc.reason == "outside-library", f"reason={exc.reason}")
        os.unlink(os.path.join(library, "elsewhere"))

        # ---- 2. 내용 판정. 거절은 아무것도 남기지 않는다 ----
        for label, blob, reason in (
            ("빈 파일", b"", "empty"),
            ("프론트매터 없는 문서", ("본문 " * 200).encode("utf-8"), "empty"),
            ("너무 짧은 문서", b"---\ntitle: x\n---\n\n\xed\x95\x9c\xec\xa4\x84\n", "empty"),
        ):
            try:
                SAVE.save(library, "reject.md", blob)
                bad(f"{label}을 저장이 받았다")
            except SAVE.SaveError as exc:
                check(f"{label}을 거절한다", exc.reason == reason, f"reason={exc.reason}")
        check("거절된 저장은 파일을 만들지 않는다",
              not os.path.exists(os.path.join(library, "reject.md")))

        try:
            SAVE.save(library, "wrong.md", document("aaaaaaaaaaa"), video_id="bbbbbbbbbbb")
            bad("다른 영상의 문서를 저장이 받았다")
        except SAVE.SaveError as exc:
            check("다른 영상의 문서를 거절한다", exc.reason == "other-video", f"reason={exc.reason}")

        no_id = b'---\ntitle: "x"\nadded: 2026-08-22\n---\n\n' + ("본문 " * 200).encode("utf-8")
        try:
            SAVE.save(library, "wrong.md", no_id, video_id="bbbbbbbbbbb")
            bad("video_id 없는 문서를 저장이 받았다")
        except SAVE.SaveError as exc:
            check("video_id 없는 문서를 거절한다", exc.reason == "no-video-id", f"reason={exc.reason}")

        # 🔴 본문에 우연히 video_id 가 있어도 근거가 아니다 — 프론트매터만 본다.
        decoy = (b'---\ntitle: "x"\nadded: 2026-08-22\n---\n\nvideo_id: bbbbbbbbbbb\n'
                 + ("본문 " * 200).encode("utf-8"))
        try:
            SAVE.save(library, "decoy.md", decoy, video_id="bbbbbbbbbbb")
            bad("본문의 video_id 를 프론트매터로 읽었다")
        except SAVE.SaveError as exc:
            check("본문의 video_id 는 근거가 아니다", exc.reason == "no-video-id",
                  f"reason={exc.reason}")

        check("거절된 저장은 임시 파일을 남기지 않는다", not strays(library), str(strays(library)))

        # ---- 3. 성공한 저장과 그 영수증 ----
        receipt_path = os.path.join(state, "probe", "main.json")
        os.makedirs(os.path.dirname(receipt_path), exist_ok=True)
        blob = document()
        receipt, warnings = SAVE.save(library, "ai/attention.md", blob,
                                      video_id="dQw4w9WgXcQ", receipt_path=receipt_path)
        check("정상 저장은 경고를 남기지 않는다", warnings == [], str(warnings))
        target = os.path.join(library, "ai", "attention.md")
        check("카테고리 폴더가 없으면 만들고 저장한다", os.path.isfile(target))
        check("저장된 문서는 644 다", oct(os.stat(target).st_mode & 0o777) == "0o644",
              oct(os.stat(target).st_mode & 0o777))
        with open(target, "rb") as handle:
            written = handle.read()
        check("저장된 내용이 건네준 바이트와 같다", written == blob)
        check("영수증 다이제스트가 디스크의 파일과 같다",
              receipt["sha256"] == hashlib.sha256(written).hexdigest())
        check("영수증이 라이브러리 상대경로를 싣는다", receipt["path"] == "ai/attention.md",
              receipt["path"])
        check("영수증이 단계를 밝힌다", receipt["phase"] == SAVE.PHASE_DOCUMENT_SAVED)
        on_disk = SAVE.read_receipt(receipt_path)
        check("영수증이 파일로도 남는다", on_disk == receipt, str(on_disk))
        check("영수증 파일은 600 이다",
              oct(os.stat(receipt_path).st_mode & 0o777) == "0o600")
        check("성공한 저장도 임시 파일을 남기지 않는다", not strays(library), str(strays(library)))

        # 덮어쓰기가 거절되면 **원래 내용이 그대로 있어야** 한다.
        try:
            SAVE.save(library, "ai/attention.md", "---\nx: 1\n---\n짧다\n".encode("utf-8"))
            bad("짧은 내용으로 덮어쓰는 것을 저장이 받았다")
        except SAVE.SaveError:
            with open(target, "rb") as handle:
                check("거절된 덮어쓰기는 원래 문서를 건드리지 않는다", handle.read() == blob)

        # ---- 4. CLI 계약. 스킬이 보는 것은 이 계약뿐이다 ----
        env = dict(os.environ)
        env["AIRLOCK_LEARNING_LIBRARY"] = library
        env["AIRLOCK_LEARNING_STATE_DIR"] = state
        env["AIRLOCK_LEARNING_RECEIPT"] = os.path.join(state, "probe", "cli.json")
        result = subprocess.run(
            [sys.executable, save_path, "--path", "cli.md", "--video-id", "cccccccccc1"],
            input=document("cccccccccc1"), env=env, capture_output=True, timeout=60)
        check("CLI 는 성공하면 exit 0", result.returncode == 0,
              result.stderr.decode("utf-8", "replace")[:200])
        try:
            printed = json.loads(result.stdout.decode("utf-8"))
        except ValueError:
            printed = None
        check("CLI 는 영수증 JSON 한 줄을 표준출력에 찍는다",
              isinstance(printed, dict) and printed.get("path") == "cli.md", str(printed)[:200])
        check("CLI 가 영수증 파일도 남긴다",
              SAVE.read_receipt(env["AIRLOCK_LEARNING_RECEIPT"]) == printed)

        draft = os.path.join(tmp, "draft.md")
        with open(draft, "wb") as handle:
            handle.write(document("ddddddddd12"))
        result = subprocess.run(
            [sys.executable, save_path, "--path", "from-file.md", "--from", draft,
             "--video-id", "ddddddddd12"], env=env, capture_output=True, timeout=60)
        check("CLI 는 --from 으로 초안 파일도 받는다",
              result.returncode == 0 and os.path.isfile(os.path.join(library, "from-file.md")),
              result.stderr.decode("utf-8", "replace")[:200])

        result = subprocess.run(
            [sys.executable, save_path, "--path", "cli-bad.md"],
            input=b"too short", env=env, capture_output=True, timeout=60)
        check("CLI 는 거절하면 exit 2", result.returncode == 2, str(result.returncode))
        check("CLI 의 거절 사유가 표준오류에 사람 문장으로 나온다",
              "학습자료 모양이" in result.stderr.decode("utf-8", "replace"),
              result.stderr.decode("utf-8", "replace")[:200])
        check("거절된 CLI 저장도 파일을 만들지 않는다",
              not os.path.exists(os.path.join(library, "cli-bad.md")))

        env_no_library = {k: v for k, v in env.items() if k != "AIRLOCK_LEARNING_LIBRARY"}
        result = subprocess.run(
            [sys.executable, save_path, "--path", "cli.md"],
            input=document(), env=env_no_library, capture_output=True, timeout=60)
        check("라이브러리를 모르면 cwd 로 조용히 내려앉지 않는다", result.returncode == 2,
              str(result.returncode))

        # ---- 5. 완료 판정. git 은 더 이상 조건이 아니다 ----
        check("git 이 아닌 라이브러리도 적재를 받는다", BACKEND.ingest_supported(library))
        check("없는 폴더는 적재를 받지 않는다",
              not BACKEND.ingest_supported(os.path.join(tmp, "nope")))
        if os.geteuid() != 0:
            readonly = os.path.join(tmp, "readonly")
            os.makedirs(readonly)
            os.chmod(readonly, 0o555)
            check("쓸 수 없는 폴더는 적재를 받지 않는다", not BACKEND.ingest_supported(readonly))
            os.chmod(readonly, 0o755)
        else:
            print("skip learning-ingest: 읽기 전용 폴더 판정은 root 로는 못 잰다")

        saved_receipt = SAVE.read_receipt(receipt_path)
        reason, error = RUNNER._verify_document(library, "ai/attention.md", "dQw4w9WgXcQ",
                                                saved_receipt)
        check("git 없이 저장된 문서가 완료로 판정된다", reason is None, f"{reason}: {error}")

        reason, _ = RUNNER._verify_document(library, "ai/attention.md", "dQw4w9WgXcQ", None)
        check("영수증이 없어도 파일 자체로 판정된다", reason is None, str(reason))

        reason, _ = RUNNER._verify_document(library, "ai/attention.md", "dQw4w9WgXcQ",
                                            dict(saved_receipt, path="other.md"))
        check("영수증이 다른 문서를 가리키면 완료가 아니다",
              reason == "marker-receipt-other-document", str(reason))

        with open(target, "ab") as handle:
            handle.write("\n나중에 덧붙인 줄\n".encode("utf-8"))
        reason, _ = RUNNER._verify_document(library, "ai/attention.md", "dQw4w9WgXcQ",
                                            saved_receipt)
        check("저장 뒤 문서가 바뀌면 완료가 아니다",
              reason == "marker-receipt-content-changed", str(reason))
        SAVE.save(library, "ai/attention.md", blob, video_id="dQw4w9WgXcQ",
                  receipt_path=receipt_path)
        saved_receipt = SAVE.read_receipt(receipt_path)

        reason, _ = RUNNER._verify_document(library, "ai/missing.md", "dQw4w9WgXcQ", None)
        check("없는 문서는 완료가 아니다", reason == "marker-document-missing", str(reason))

        reason, _ = RUNNER._verify_document(library, "ai/attention.md", "zzzzzzzzzzz",
                                            saved_receipt)
        check("다른 영상의 문서는 완료가 아니다", reason == "marker-document-other-video", str(reason))

        reason, _ = RUNNER._verify_document(library, "../outside.md", None, None)
        check("라이브러리 밖을 가리키는 표시는 완료가 아니다",
              reason == "marker-document-outside-repo", str(reason))

        empty = os.path.join(library, "gitkeep.md")
        with open(empty, "wb") as handle:
            handle.write(b"")
        reason, _ = RUNNER._verify_document(library, "gitkeep.md", None, None)
        check("빈 파일은 완료가 아니다", reason == "marker-document-empty", str(reason))

        # 🔴 git 라이브러리에서 **커밋되지 않은** 문서. 옛 판정은 여기서 반드시 실패했다
        #    (`git cat-file -e HEAD:<경로>`). 이제는 통과해야 한다 — 커밋은 사용자 사정이다.
        if shutil.which("git"):
            git_library = os.path.join(tmp, "git-library")
            os.makedirs(git_library)
            subprocess.run(["git", "init", "-q", git_library], check=True, timeout=60,
                           capture_output=True)
            SAVE.save(git_library, "notes.md", document("gggggggggg1"), video_id="gggggggggg1")
            reason, error = RUNNER._verify_document(git_library, "notes.md", "gggggggggg1", None)
            check("git 라이브러리의 커밋되지 않은 문서도 완료로 판정된다",
                  reason is None, f"{reason}: {error}")
        else:
            print("skip learning-ingest: git 이 없어 커밋되지 않은 문서 판정을 못 잰다")

        # ---- 6. verdict: exit code·마커·영수증이 모이는 자리 ----
        log_path = os.path.join(state, "ingest", "9.log")
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "w", encoding="utf-8") as handle:
            handle.write("[ingest] 시작\n"
                         f"{BACKEND.INGEST_DONE_MARKER} ai/attention.md\n")
        row = {"video_id": "dQw4w9WgXcQ"}
        row_done, log_done = row, log_path
        state_name, fields = RUNNER.verdict(library, row, 0, log_path, True, receipt_path)
        check("마커 + 파일 + 영수증이면 done", state_name == "done", str(fields))
        check("영수증이 있었다는 사실이 기록된다", fields.get("reason") == "completed",
              str(fields.get("reason")))

        state_name, fields = RUNNER.verdict(library, row, 0, log_path, True, None)
        check("영수증 없이 통과한 적재는 그 사실이 남는다",
              state_name == "done" and fields.get("reason") == "completed-without-receipt",
              str(fields))

        state_name, fields = RUNNER.verdict(library, row, 1, log_path, True, receipt_path)
        check("CLI 가 실패하면 마커가 있어도 done 이 아니다",
              state_name == "failed" and fields.get("reason") == "cli-failed", str(fields))

        # 이해 못 한 줄이 있으면 판정이 **다른 원인**을 말한다 — 스킬이 멈춘 것과
        # 우리가 형식을 못 읽은 것은 고칠 곳이 다르다.
        weird = os.path.join(state, "ingest", "11.log")
        with open(weird, "w", encoding="utf-8") as handle:
            handle.write("[ingest] 시작\n")
            handle.write(RUNNER.PROVIDERS.UNKNOWN_EVENT_PREFIX
                         + '{"type": "assistant_message", "text": "…"}\n')
        state_name, fields = RUNNER.verdict(library, row, 0, weird, True, None)
        check("이해 못 한 줄이 있으면 원인을 그렇게 말한다",
              state_name == "failed" and fields.get("reason") == "unreadable-stream",
              str(fields))

        bare = os.path.join(state, "ingest", "10.log")
        with open(bare, "w", encoding="utf-8") as handle:
            handle.write("[ingest] 시작\n스킬이 되물었습니다\n")
        state_name, fields = RUNNER.verdict(library, row, 0, bare, True, receipt_path)
        check("완료 표시가 없으면 exit 0 이어도 done 이 아니다",
              state_name == "failed" and fields.get("reason") == "no-completion-marker",
              str(fields))

        # ---- 6b. 적대검증(2026-08-22)이 잡은 것들의 회귀 시험 ----
        # 심볼릭 링크로 정리한 라이브러리. 저장이 성공한 뒤 "영수증이 다른 문서를
        # 가리킵니다" 로 실패했다 — 헬퍼는 해석 전 경로를, 러너는 해석 후 경로를 봤다.
        os.makedirs(os.path.join(library, "topics", "ml"), exist_ok=True)
        os.symlink(os.path.join(library, "topics", "ml"), os.path.join(library, "ml"))
        link_receipt = os.path.join(state, "probe", "link.json")
        linked, _ = SAVE.save(library, "ml/linked.md", document("lllllllllll"),
                              video_id="lllllllllll", receipt_path=link_receipt)
        check("심볼릭 링크로 만든 카테고리에도 저장된다",
              os.path.isfile(os.path.join(library, "topics", "ml", "linked.md")))
        reason, error = RUNNER._verify_document(library, "ml/linked.md", "lllllllllll",
                                                SAVE.read_receipt(link_receipt))
        check("심볼릭 링크 카테고리의 저장이 완료로 판정된다", reason is None,
              f"{reason}: {error}")
        check("영수증은 완료 표시가 되받을 수 있는 경로를 싣는다",
              linked["path"] == "ml/linked.md"
              and SAVE.DOCUMENT_PATH_RE.fullmatch(linked["path"]) is not None
              and BACKEND.INGEST_DONE_RE.search(
                  f"{BACKEND.INGEST_DONE_MARKER} {linked['path']}\n") is not None,
              linked["path"])
        # 두 단계 심볼릭 링크. 문자열로 맞대면 여기서 또 갈라진다.
        os.makedirs(os.path.join(library, "topics", "deep", "nn"), exist_ok=True)
        os.symlink(os.path.join(library, "topics", "deep", "nn"),
                   os.path.join(library, "nn"))
        deep_receipt = os.path.join(state, "probe", "deep.json")
        SAVE.save(library, "nn/deep.md", document("nnnnnnnnnn1"), video_id="nnnnnnnnnn1",
                  receipt_path=deep_receipt)
        reason, error = RUNNER._verify_document(library, "nn/deep.md", "nnnnnnnnnn1",
                                                SAVE.read_receipt(deep_receipt))
        check("두 단계 심볼릭 링크에서도 완료로 판정된다", reason is None, f"{reason}: {error}")

        # 🔴 울타리 줄의 장식. 줄 끝 공백 하나로 "프론트매터 없음" 이 되면 멀쩡한 문서의
        #    저장이 거절된다 — LLM 이 쓴 문서에 줄 끝 공백은 흔하다(2차 적대검증 2026-08-22).
        base_doc = document("ppppppppp12").decode("utf-8")
        for label, variant in (
            ("여는 울타리 뒤 공백", base_doc.replace("---\n", "--- \n", 1)),
            ("닫는 울타리 뒤 공백", base_doc.replace("\n---\n", "\n--- \n", 1)),
            ("닫는 울타리 뒤 탭", base_doc.replace("\n---\n", "\n---\t\n", 1)),
            ("앞의 빈 줄", "\n\n" + base_doc),
        ):
            try:
                saved, _ = SAVE.save(library, "fence.md", variant.encode("utf-8"),
                                     video_id="ppppppppp12")
                check(f"{label}이 있어도 저장된다", saved["video_id"] == "ppppppppp12")
            except SAVE.SaveError as exc:
                bad(f"{label}이 있는 문서를 거절했다", f"{exc.reason}: {exc.message}")

        # 반대쪽: 닫히지 않은 프론트매터는 프론트매터가 아니다.
        unterminated = ('---\ntitle: "x"\nvideo_id: qqqqqqqqq12\n\n'
                        + "본문 " * 200).encode("utf-8")
        try:
            SAVE.save(library, "unterminated.md", unterminated, video_id="qqqqqqqqq12")
            bad("닫히지 않은 프론트매터를 저장이 받았다")
        except SAVE.SaveError as exc:
            check("닫히지 않은 프론트매터는 프론트매터가 아니다", exc.reason == "empty",
                  f"reason={exc.reason}")

        # CRLF 문서와 제목에 `---` 가 든 문서. 둘 다 저장 자체가 막히면 안 된다.
        crlf = document("rrrrrrrrrrr").replace(b"\n", b"\r\n")
        saved, _ = SAVE.save(library, "crlf.md", crlf, video_id="rrrrrrrrrrr")
        check("CRLF 문서도 저장된다", saved["video_id"] == "rrrrrrrrrrr", str(saved))
        dashed = document("ssssssssss1", title="Rust --- part 1")
        saved, _ = SAVE.save(library, "dashed.md", dashed, video_id="ssssssssss1")
        check("제목에 --- 가 있어도 프론트매터를 끝까지 읽는다",
              saved["video_id"] == "ssssssssss1", str(saved))

        # 🔴 이름 바꾸기 뒤의 실패는 저장을 되돌리지 못한다. 영수증을 못 써도 문서는
        #    저장된 것이고, 그때 exit 2 를 내면 스킬은 아무것도 안 됐다고 읽는다.
        if os.geteuid() != 0:
            locked_dir = os.path.join(tmp, "no-receipts")
            os.makedirs(locked_dir)
            os.chmod(locked_dir, 0o500)
            blocked, warned = SAVE.save(library, "after-replace.md", document("ttttttttt12"),
                                        video_id="ttttttttt12",
                                        receipt_path=os.path.join(locked_dir, "r.json"))
            os.chmod(locked_dir, 0o755)
            check("영수증을 못 써도 문서는 저장된다",
                  os.path.isfile(os.path.join(library, "after-replace.md")))
            check("영수증을 못 쓰면 영수증이 아니라 경고가 나온다",
                  blocked is None and len(warned) == 1, f"{blocked} / {warned}")
            os.chmod(locked_dir, 0o500)
            result = subprocess.run(
                [sys.executable, save_path, "--path", "after-replace-cli.md",
                 "--video-id", "ttttttttt13", "--receipt",
                 os.path.join(locked_dir, "sub", "r.json")],
                input=document("ttttttttt13"), env=env, capture_output=True, timeout=60)
            os.chmod(locked_dir, 0o755)
            check("영수증을 못 써도 CLI 는 exit 0 이다", result.returncode == 0,
                  result.stderr.decode("utf-8", "replace")[:200])
            check("그 대신 CLI 가 경고를 남긴다",
                  "[경고]" in result.stderr.decode("utf-8", "replace"),
                  result.stderr.decode("utf-8", "replace")[:200])
        else:
            print("skip learning-ingest: 이름 바꾸기 뒤의 실패는 root 로는 못 만든다")

        # 영수증이 **있는데 못 읽는** 것과 **없는** 것은 다르다.
        broken = os.path.join(state, "probe", "broken.json")
        with open(broken, "w", encoding="utf-8") as handle:
            handle.write("{ 이건 JSON 이 아니다")
        state_name, fields = RUNNER.verdict(library, row_done, 0, log_done, True, broken)
        check("읽을 수 없는 영수증은 조용히 없는 것으로 치지 않는다",
              state_name == "failed" and fields.get("reason") == "receipt-unreadable",
              str(fields))
        reason, _ = RUNNER._verify_document(library, "ai/attention.md", "dQw4w9WgXcQ",
                                            dict(saved_receipt, schema=99))
        check("모르는 형식의 영수증은 완료가 아니다",
              reason == "marker-receipt-unreadable", str(reason))
        reason, _ = RUNNER._verify_document(library, "ai/attention.md", "dQw4w9WgXcQ",
                                            dict(saved_receipt, video_id="zzzzzzzzzzz"))
        check("다른 영상의 영수증은 완료가 아니다",
              reason == "marker-receipt-other-video", str(reason))

        # ---- 6c. 광고한 메커니즘이 정말 도는가 (변이 시험이 그냥 통과하던 자리) ----
        # 원자성: 대상 파일에 직접 쓰지 않고, 같은 디렉터리의 임시 파일을 rename 한다.
        real_replace = os.replace
        seen = []

        def spy_replace(src, dst):
            seen.append((src, dst))
            return real_replace(src, dst)

        atomic_receipt = os.path.join(state, "probe", "atomic.json")
        os.replace = spy_replace
        try:
            SAVE.save(library, "atomic.md", document("uuuuuuuuuu1"), video_id="uuuuuuuuuu1",
                      receipt_path=atomic_receipt)
        finally:
            os.replace = real_replace
        target_atomic = os.path.join(library, "atomic.md")

        def renamed_into(destination):
            """그 자리에 rename 으로 들어왔나 — 같은 디렉터리의 임시 파일에서."""
            for source, written_to in seen:
                if written_to != destination:
                    continue
                if (os.path.basename(source).startswith(".airlock-learning-")
                        and os.path.dirname(source) == os.path.dirname(destination)):
                    return True
            return False

        check("저장은 대상 파일에 직접 쓰지 않고 rename 한다",
              renamed_into(target_atomic), str(seen))
        # 🔴 영수증도 마찬가지다. 러너는 **읽을 수 없는 영수증을 실패로** 판정하므로,
        #    반쯤 쓰인 영수증이 관측될 수 있으면 그 판정이 멀쩡한 적재를 떨어뜨린다.
        check("영수증도 rename 으로 들어온다", renamed_into(atomic_receipt), str(seen))

        # 이름 바꾸기는 끝났는데 디렉터리 fsync 를 못 하는 경우 — 실패가 아니라 경고다.
        if os.geteuid() != 0:
            nofsync = os.path.join(library, "nofsync")
            os.makedirs(nofsync, exist_ok=True)
            os.chmod(nofsync, 0o300)   # 쓰기·통과는 되고 O_RDONLY 열기는 안 된다
            try:
                kept, warned = SAVE.save(library, "nofsync/doc.md", document("yyyyyyyyy12"),
                                         video_id="yyyyyyyyy12", state_dir=state)
            finally:
                os.chmod(nofsync, 0o755)
            check("디렉터리를 fsync 하지 못해도 저장은 성공이고 경고가 남는다",
                  kept is not None and any("fsync" in w for w in warned),
                  f"{kept is not None} / {warned}")

        # 다이제스트: 쓰려던 바이트가 아니라 **디스크에 있는 것**에서 뜬다.
        real_atomic = SAVE.atomic_write

        def lying_atomic(target_path, data, mode=0o644):
            if target_path.endswith(".md"):
                data = data + "\n디스크에만 있는 줄\n".encode("utf-8")
            return real_atomic(target_path, data, mode)

        SAVE.atomic_write = lying_atomic
        try:
            SAVE.save(library, "digest.md", document("vvvvvvvvvv1"), video_id="vvvvvvvvvv1")
            bad("디스크의 내용이 달라졌는데 저장이 통과했다")
        except SAVE.SaveError as exc:
            check("다이제스트는 디스크에서 뜬다", exc.reason == "write-verify-failed",
                  f"reason={exc.reason}")
        finally:
            SAVE.atomic_write = real_atomic

        # 락: 같은 문서를 두 번째로 잡으려 하면 기다렸다 포기한다.
        real_timeout = SAVE.LOCK_TIMEOUT_SECONDS
        SAVE.LOCK_TIMEOUT_SECONDS = 0.5
        try:
            with SAVE.document_lock(state, "held.md"):
                try:
                    SAVE.save(library, "held.md", document("wwwwwwwww12"),
                              video_id="wwwwwwwww12", state_dir=state)
                    bad("이미 잡힌 문서에 두 번째 저장이 들어갔다")
                except SAVE.SaveError as exc:
                    check("문서 단위 락이 두 번째 쓰기를 막는다", exc.reason == "locked",
                          f"reason={exc.reason}")
            saved, _ = SAVE.save(library, "held.md", document("wwwwwwwww12"),
                                 video_id="wwwwwwwww12", state_dir=state)
            check("락이 풀리면 같은 문서를 저장할 수 있다", saved["path"] == "held.md")
        finally:
            SAVE.LOCK_TIMEOUT_SECONDS = real_timeout

        # ---- 6d. 워커 한 바퀴. 자식 환경과 낡은 영수증은 여기서만 드러난다 ----
        fake_cli = os.path.join(tmp, "fake-claude")
        with open(fake_cli, "w", encoding="utf-8") as handle:
            handle.write(FAKE_CLI)
        os.chmod(fake_cli, 0o755)
        # 종량 과금 방어선은 환경에 이 이름들이 있으면 적재를 거절한다. 이 스위트를 돌리는
        # 셸에 남아 있을 수 있으므로 걷어낸다 — 그 판정 자체는 여기서 재는 대상이 아니다.
        for name in RUNNER.UNSAFE_BILLING_ENV:
            os.environ.pop(name, None)
        os.environ["AIRLOCK_LEARNING_CLAUDE_BIN"] = fake_cli
        os.environ["AIRLOCK_LEARNING_FAILURE_SUMMARY"] = "0"
        paths = {"repo": library, "state": state}
        conn = BACKEND.QUEUE.connect(state)
        try:
            os.environ["FAKE_CLI_MODE"] = "save"
            attempt = BACKEND.QUEUE.enqueue(conn, "https://youtu.be/xxxxxxxxxx1",
                                            "xxxxxxxxxx1", RUNNER.now_iso())
            claimed = BACKEND.QUEUE.claim_next(conn, RUNNER.now_iso())
            RUNNER.run_attempt(conn, paths, claimed)
            done_row = BACKEND.QUEUE.get(conn, attempt)
            check("워커 한 바퀴가 done 으로 끝난다", done_row["state"] == "done",
                  f"{done_row['state']} / {done_row.get('error')}")
            check("자식이 저장 헬퍼와 라이브러리를 환경에서 받았다",
                  done_row["reason"] == "completed"
                  and os.path.isfile(os.path.join(library, "worker.md")),
                  f"{done_row['reason']}")

            # 🔴 낡은 영수증. 이번 실행이 만들지 않은 영수증이 남아 있는데 스킬이 헬퍼를
            #    쓰지 않으면, 지우지 않는 한 하지도 않은 저장이 `completed` 로 판정된다.
            os.environ["FAKE_CLI_MODE"] = "marker-only"
            attempt2 = BACKEND.QUEUE.enqueue(conn, "https://youtu.be/xxxxxxxxxx2",
                                             "xxxxxxxxxx2", RUNNER.now_iso())
            stale = BACKEND.QUEUE.receipt_path(state, attempt2)
            SAVE.save(library, "worker2.md", document("xxxxxxxxxx2"),
                      video_id="xxxxxxxxxx2", state_dir=state, receipt_path=stale)
            claimed2 = BACKEND.QUEUE.claim_next(conn, RUNNER.now_iso())
            RUNNER.run_attempt(conn, paths, claimed2)
            row2 = BACKEND.QUEUE.get(conn, attempt2)
            check("이번 실행이 만들지 않은 영수증은 증거로 쓰이지 않는다",
                  row2["state"] == "done" and row2["reason"] == "completed-without-receipt",
                  f"{row2['state']} / {row2['reason']}")
        finally:
            conn.close()

        # ---- 6e. 진행 중인 적재가 이미 남긴 문서 (카드 3단계) ----
        # 🔴 20분짜리 적재의 4분째에 "이 문서는 이미 여기 있다" 를 말할 수 있는 유일한
        #    신호가 영수증이다. 완료 마커는 적재가 끝날 때 나오고, 그때는 이미 늦다.
        live_conn = BACKEND.QUEUE.connect(state)
        try:
            live_id = BACKEND.QUEUE.enqueue(live_conn, "https://youtu.be/aaaaaaaaaa9",
                                            "aaaaaaaaaa9", RUNNER.now_iso())
            live_row = BACKEND.QUEUE.claim_next(live_conn, RUNNER.now_iso())
            view = BACKEND._view(BACKEND.QUEUE.get(live_conn, live_id))
            check("저장 전에는 진행 중 적재가 문서를 가리키지 않는다",
                  not view.get("document"), str(view.get("document")))

            SAVE.save(library, "ml/live.md", document("aaaaaaaaaa9"),
                      video_id="aaaaaaaaaa9", state_dir=state,
                      receipt_path=BACKEND.QUEUE.receipt_path(state, live_id))
            view = BACKEND._view(BACKEND.QUEUE.get(live_conn, live_id))
            check("저장하는 순간 진행 중 적재가 그 문서를 가리킨다",
                  view.get("document") == "ml/live.md", str(view.get("document")))
            check("단계도 함께 실린다", view.get("phase") == SAVE.PHASE_DOCUMENT_SAVED,
                  str(view.get("phase")))
            # 🔴 목록은 폴더를 걸어 만들어지므로 **물리 경로**를 쓴다. 영수증은 스킬이 준
            #    철자를 쓴다(`ml -> topics/ml`). 둘을 그대로 맞대면 배지가 어느 행에도
            #    안 붙는다 — 화면에서는 조용히 아무 일도 안 일어난 것처럼 보인다.
            snapshot = BACKEND.build_snapshot()
            listed = {item["path"] for item in snapshot["items"]}
            check("영수증의 경로가 목록의 철자로 맞춰진다",
                  view.get("document") in listed,
                  f"{view.get('document')} not in {sorted(listed)[:5]}")

            BACKEND.QUEUE.finish(live_conn, live_id, "done", RUNNER.now_iso(),
                                 reason="completed", document="ml/live.md")
            done_view = BACKEND._view(BACKEND.QUEUE.get(live_conn, live_id))
            check("끝난 적재의 문서는 DB 가 쓴 것을 그대로 쓴다",
                  done_view.get("document") == "ml/live.md", str(done_view.get("document")))
        finally:
            live_conn.close()

        check("라이브러리 밖을 가리키는 영수증 경로는 배지로 올라가지 않는다",
              BACKEND.normalized_document(library, "../escape.md") is None)
        # 🔴 손으로 고친 영수증 하나가 `/api/ingest` 를 통째로 죽였다 — 문자열이 아닌
        #    `path` 가 두 검사를 지나 strip() 에 닿아 AttributeError 가 핸들러를 뚫었다.
        # 🔴 러너가 읽는 **바로 그 자리**에 쓴다. 다른 경로에 두면 "파일이 없어서 None" 을
        #    "잘 무시했다" 로 오독한다 — 아래 양성 대조군이 그 자리를 실제로 읽는지 보인다.
        bad_receipt = BACKEND.QUEUE.receipt_path(state, 0)
        os.makedirs(os.path.dirname(bad_receipt), exist_ok=True)
        with open(bad_receipt, "w", encoding="utf-8") as handle:
            handle.write(json.dumps({"schema": SAVE.RECEIPT_SCHEMA,
                                     "phase": "document_saved", "path": "ai/attention.md"}))
        check("양성 대조군 — 그 자리의 정상 영수증은 읽힌다",
              BACKEND.attempt_document(state, library, {"id": 0})
              == ("ai/attention.md", "document_saved"),
              str(BACKEND.attempt_document(state, library, {"id": 0})))
        for label, payload in (("숫자", 123), ("목록", ["a"]), ("null", None)):
            with open(bad_receipt, "w", encoding="utf-8") as handle:
                handle.write(json.dumps({"schema": SAVE.RECEIPT_SCHEMA,
                                         "phase": "document_saved", "path": payload}))
            try:
                got = BACKEND.attempt_document(state, library, {"id": 0})
                check(f"영수증의 path 가 {label} 이면 조용히 무시한다", got is None, str(got))
            except Exception as exc:   # noqa: BLE001  — 이 검사의 요점이 "터지지 않는다" 다
                bad(f"영수증의 path 가 {label} 일 때 터졌다", f"{type(exc).__name__}: {exc}")
        check("영수증 경로가 비어 있어도 터지지 않는다",
              BACKEND.normalized_document(library, "") is None)

        # ---- 6f. 상태는 문서 안에 산다 (카드 4단계) ----
        # 오너 결정 2: 별표·보관은 문서의 프론트매터에 있다. 라이브러리 폴더를 통째로
        # 위키로 옮겨도 상태가 따라가야 하기 때문이다.
        state_doc = document("ffffffffff1", title='"따옴표" 가 든 제목')
        SAVE.save(library, "flags.md", state_doc, video_id="ffffffffff1")
        flag_target = os.path.join(library, "flags.md")

        SAVE.patch_frontmatter(library, "flags.md", {"starred": "true"}, state_dir=state)
        with open(flag_target, "rb") as handle:
            after = handle.read()
        check("별표가 문서에 적힌다", b"\nstarred: true\n" in after)
        # 🔴 외과적이라는 말의 뜻. 그 줄 하나 말고는 한 바이트도 다르면 안 된다 —
        #    별표 한 번 눌렀다고 남의 문서가 재조판되면 안 된다.
        check("바뀐 것은 그 한 줄뿐이다",
              after.replace(b"starred: true\n", b"") == state_doc,
              repr(after[:120]))

        SAVE.patch_frontmatter(library, "flags.md", {"starred": None}, state_dir=state)
        with open(flag_target, "rb") as handle:
            check("별표를 해제하면 그 줄이 사라지고 원본으로 돌아온다",
                  handle.read() == state_doc)

        # 이미 있는 키는 제자리에서 값만 바뀐다 — 순서가 바뀌면 diff 가 시끄러워진다.
        seeded = state_doc.replace(b"video_id:", b"starred: false\nvideo_id:")
        SAVE.save(library, "seeded.md", seeded, video_id="ffffffffff1")
        SAVE.patch_frontmatter(library, "seeded.md", {"starred": "true"}, state_dir=state)
        with open(os.path.join(library, "seeded.md"), "rb") as handle:
            patched = handle.read()
        check("있던 키는 제자리에서 값만 바뀐다",
              patched == seeded.replace(b"starred: false", b"starred: true"), repr(patched[:120]))

        # CRLF 문서도 줄 끝을 지킨다.
        crlf_doc = document("ffffffffff2").replace(b"\n", b"\r\n")
        SAVE.save(library, "crlf-flags.md", crlf_doc, video_id="ffffffffff2")
        SAVE.patch_frontmatter(library, "crlf-flags.md", {"starred": "true"}, state_dir=state)
        with open(os.path.join(library, "crlf-flags.md"), "rb") as handle:
            crlf_after = handle.read()
        check("CRLF 문서의 줄 끝이 지켜진다",
              b"starred: true\r\n" in crlf_after and b"starred: true\n\r" not in crlf_after,
              repr(crlf_after[:80]))

        # 프론트매터가 없는 문서는 **고쳐 주지 않는다** — 남의 문서를 수리하지 않는다.
        plain = ("본문만 있는 문서 " * 60).encode("utf-8")
        with open(os.path.join(library, "plain.md"), "wb") as handle:
            handle.write(plain)
        try:
            SAVE.patch_frontmatter(library, "plain.md", {"starred": "true"}, state_dir=state)
            bad("프론트매터가 없는 문서를 고쳤다")
        except SAVE.SaveError as exc:
            check("프론트매터가 없으면 적지 않는다", exc.reason == "no-frontmatter", exc.reason)
        with open(os.path.join(library, "plain.md"), "rb") as handle:
            check("거절된 상태 쓰기는 문서를 건드리지 않는다", handle.read() == plain)

        # 이 앱이 고칠 수 있는 키는 자기가 만든 상태뿐이다.
        try:
            SAVE.patch_frontmatter(library, "flags.md", {"title": "가로채기"}, state_dir=state)
            bad("제목을 고치는 것을 상태 패치가 받았다")
        except SAVE.SaveError as exc:
            check("상태 아닌 키는 고치지 않는다", exc.reason == "unpatchable-key", exc.reason)

        # 🔴 쓰기 직전 재확인. 읽은 뒤에 파일이 바뀌면 덮어쓰지 않는다.
        real_apply = SAVE.apply_frontmatter_updates

        def racing_apply(blob, updates):
            with open(flag_target, "ab") as handle:
                handle.write("\n경쟁하는 편집기가 쓴 줄\n".encode("utf-8"))
            return real_apply(blob, updates)

        SAVE.apply_frontmatter_updates = racing_apply
        try:
            SAVE.patch_frontmatter(library, "flags.md", {"starred": "true"}, state_dir=state)
            bad("읽은 뒤 바뀐 문서를 덮어썼다")
        except SAVE.SaveError as exc:
            check("읽은 뒤 바뀐 문서는 덮어쓰지 않는다", exc.reason == "document-changed", exc.reason)
        finally:
            SAVE.apply_frontmatter_updates = real_apply
        with open(flag_target, "rb") as handle:
            check("경쟁 편집이 살아남는다", "경쟁하는 편집기가 쓴 줄" in handle.read().decode("utf-8"))

        # --- 목록이 문서의 상태를 읽는가, 그리고 옛 JSON 은 합집합인가 ---
        legacy_lib = os.path.join(tmp, "legacy-state")
        legacy_state = os.path.join(tmp, "legacy-state-dir")
        os.makedirs(legacy_lib)
        os.makedirs(legacy_state)
        SAVE.save(legacy_lib, "in-file.md", document("ggggggggg11"), video_id="ggggggggg11",
                  state_dir=legacy_state)
        SAVE.save(legacy_lib, "in-json.md", document("ggggggggg12"), video_id="ggggggggg12",
                  state_dir=legacy_state)
        SAVE.patch_frontmatter(legacy_lib, "in-file.md", {"starred": "true"},
                               state_dir=legacy_state)
        BACKEND.write_starred(legacy_state, {"in-json.md": True})
        previous = (os.environ["AIRLOCK_LEARNING_LIBRARY"], os.environ["AIRLOCK_LEARNING_STATE_DIR"])
        os.environ["AIRLOCK_LEARNING_LIBRARY"] = legacy_lib
        os.environ["AIRLOCK_LEARNING_STATE_DIR"] = legacy_state
        try:
            snap = BACKEND.build_snapshot()
            stars = {i["path"]: i["starred"] for i in snap["items"]}
            check("문서에 적힌 별표를 목록이 읽는다", stars.get("in-file.md") is True, str(stars))
            # 🔴 이관은 사용자가 그 문서를 건드릴 때 한 건씩 일어난다. 그 사이에 빼기로
            #    읽으면 이미 별표해 둔 것이 화면에서 한꺼번에 사라진다.
            check("아직 옮기지 않은 옛 JSON 의 별표도 살아 있다",
                  stars.get("in-json.md") is True, str(stars))

            BACKEND.star_path("in-json.md", True)
            with open(os.path.join(legacy_lib, "in-json.md"), "rb") as handle:
                check("별표를 누르면 그 문서로 이관된다", b"starred: true" in handle.read())
            check("이관된 항목은 옛 JSON 에서 빠진다",
                  "in-json.md" not in BACKEND.read_starred(legacy_state),
                  str(BACKEND.read_starred(legacy_state)))

            # 🔴 해제가 먹으려면 두 자리에서 다 빠져야 한다. 옛 JSON 에 남으면 합집합이
            #    다시 참으로 만든다 — 해제 버튼이 아무 일도 안 하는 것처럼 보인다.
            BACKEND.star_path("in-json.md", False)
            snap = BACKEND.build_snapshot()
            stars = {i["path"]: i["starred"] for i in snap["items"]}
            check("해제가 실제로 먹는다", stars.get("in-json.md") is False, str(stars))

            # --- 보관도 문서가 정본이다 ---
            # `mutable` 이 참이려면 html 짝과 `source: youtube` 가 있어야 한다(기존 규칙).
            arch_doc = document("ggggggggg13").replace(
                b"added: 2026-08-22", b"added: 2026-08-22\nsource: youtube")
            SAVE.save(legacy_lib, "arch.md", arch_doc, video_id="ggggggggg13",
                      state_dir=legacy_state)
            with open(os.path.join(legacy_lib, "arch.html"), "w", encoding="utf-8") as handle:
                handle.write("<html><body>arch</body></html>")
            status, _payload = BACKEND.archive_paths(["arch.md"])
            check("보관이 받아들여진다", status == 200, str(status))
            with open(os.path.join(legacy_lib, "arch.md"), "rb") as handle:
                check("보관이 문서에 적힌다", b"archived: true" in handle.read())
            snap = BACKEND.build_snapshot()
            check("보관된 문서는 목록에서 빠지고 보관함에 있다",
                  "arch.md" not in {i["path"] for i in snap["items"]}
                  and "arch.md" in {a["path"] for a in snap["archive"]["archived"]},
                  str([i["path"] for i in snap["items"]]))

            BACKEND.restore_path("arch.md")
            with open(os.path.join(legacy_lib, "arch.md"), "rb") as handle:
                check("복구하면 문서에서 그 키가 사라진다", b"archived" not in handle.read())
            snap = BACKEND.build_snapshot()
            check("복구된 문서가 목록으로 돌아온다",
                  "arch.md" in {i["path"] for i in snap["items"]})

            # 프론트매터가 없는 문서는 읽기 전용이다 — 수리하지 않는다.
            with open(os.path.join(legacy_lib, "bare.md"), "wb") as handle:
                handle.write(("프론트매터 없는 문서 " * 60).encode("utf-8"))
            try:
                BACKEND.star_path("bare.md", True)
                bad("프론트매터가 없는 문서에 별표가 먹었다")
            except BACKEND.RequestError as exc:
                check("프론트매터가 없는 문서는 별표가 409 로 거절된다", exc.code == 409,
                      f"{exc.code}: {exc.message}")
        finally:
            os.environ["AIRLOCK_LEARNING_LIBRARY"], os.environ["AIRLOCK_LEARNING_STATE_DIR"] = previous

        # ---- 6f-b. 파서가 하나라는 것 (2차 적대검증 HIGH 3건의 뿌리) ----
        # 한때 프론트매터 파서가 둘이었다 — 백엔드는 디코드된 문자열을 utf-8-sig 로,
        # 헬퍼는 원시 바이트를. 어긋나는 자리마다 결함이 하나씩 나왔다.
        parser_lib = os.path.join(tmp, "parsers")
        os.makedirs(parser_lib, exist_ok=True)
        base_doc = document("ppppppppp99")

        cases = {
            "bom.md": "\ufeff".encode("utf-8") + base_doc,
            "nbsp.md": base_doc.replace(b"---\n\n", "---\u00a0\n\n".encode("utf-8"), 1),
            "leadblank.md": b"\n\n" + base_doc,
        }
        for name, blob in cases.items():
            with open(os.path.join(parser_lib, name), "wb") as handle:
                handle.write(blob)
        # 프론트매터가 정말 없는 문서 — 음성 대조군
        with open(os.path.join(parser_lib, "none.md"), "wb") as handle:
            handle.write(("본문만 " * 200).encode("utf-8"))

        for name in list(cases) + ["none.md"]:
            full = os.path.join(parser_lib, name)
            _fields, _heading, has_block = BACKEND.read_front_matter(full)
            with open(full, "rb") as handle:
                helper_sees = SAVE.frontmatter_block(handle.read()) is not None
            check(f"{name}: 읽는 쪽과 고치는 쪽이 같은 답을 낸다", has_block == helper_sees,
                  f"backend={has_block} helper={helper_sees}")
            check(f"{name}: 그 답이 맞다", has_block == (name != "none.md"), str(has_block))

        # 🔴 NBSP 울타리에서 본문 줄이 프론트매터로 취급돼 **덮어써졌다.**
        nbsp_doc = (b"---\ntitle: N\n---" + "\u00a0".encode("utf-8")
                    + b"\n\xeb\xb3\xb8\xeb\xac\xb8\nstarred: \xed\x82\xa4\xea\xb0\x80 \xec\x95\x84\xeb\x8b\x88\xeb\x8b\xa4\n"
                    + ("더 " * 300).encode("utf-8") + b"\n---\n\xea\xbc\xac\xeb\xa6\xac\n")
        with open(os.path.join(parser_lib, "nbsp-body.md"), "wb") as handle:
            handle.write(nbsp_doc)
        SAVE.patch_frontmatter(parser_lib, "nbsp-body.md", {"starred": "true"},
                               state_dir=state)
        with open(os.path.join(parser_lib, "nbsp-body.md"), "rb") as handle:
            patched_nbsp = handle.read().decode("utf-8")
        check("NBSP 울타리에서 본문 줄을 건드리지 않는다",
              "starred: 키가 아니다" in patched_nbsp, repr(patched_nbsp[:200]))

        # BOM 은 살아남는다 — 그것도 "그 줄 말고는 안 바뀐다" 의 일부다.
        SAVE.patch_frontmatter(parser_lib, "bom.md", {"starred": "true"}, state_dir=state)
        with open(os.path.join(parser_lib, "bom.md"), "rb") as handle:
            check("BOM 문서를 고쳐도 BOM 이 남는다",
                  handle.read().startswith("\ufeff".encode("utf-8")))

        # 같은 키가 두 번: 읽는 쪽은 마지막을 보므로, 앞만 고치면 아무 일도 안 일어난다.
        dup_doc = base_doc.replace(b"video_id:", b"starred: true\nvideo_id:", 1).replace(
            b"added: 2026-08-22", b"added: 2026-08-22\nstarred: false", 1)
        with open(os.path.join(parser_lib, "dup.md"), "wb") as handle:
            handle.write(dup_doc)
        SAVE.patch_frontmatter(parser_lib, "dup.md", {"starred": "true"}, state_dir=state)
        with open(os.path.join(parser_lib, "dup.md"), "rb") as handle:
            dup_after = handle.read()
        check("중복된 키는 하나만 남는다", dup_after.count(b"starred:") == 1, repr(dup_after[:200]))
        fields, _h, _b = BACKEND.read_front_matter(os.path.join(parser_lib, "dup.md"))
        check("그 하나가 참이다", BACKEND.truthy_scalar(fields.get("starred")), str(fields))

        # 모드는 그대로다 — 개인 메모가 별표 한 번에 열리면 안 된다.
        mode_doc = os.path.join(parser_lib, "private.md")
        with open(mode_doc, "wb") as handle:
            handle.write(base_doc)
        os.chmod(mode_doc, 0o600)
        SAVE.patch_frontmatter(parser_lib, "private.md", {"starred": "true"}, state_dir=state)
        check("상태를 적어도 파일 모드가 그대로다",
              oct(os.stat(mode_doc).st_mode & 0o777) == "0o600",
              oct(os.stat(mode_doc).st_mode & 0o777))

        # 새 키는 닫는 울타리 **바로 위**에 들어간다(맨 위가 아니라).
        fresh = SAVE.apply_frontmatter_updates(base_doc, {"archived": "true"})
        block = SAVE.frontmatter_block(fresh).decode("utf-8").strip().split("\n")
        check("새 키는 닫는 울타리 바로 위에 들어간다", block[-1].startswith("archived:"),
              str(block[-3:]))

        # ---- 6f-c. 보관에서 나올 수 있나 · 끄는 것은 언제나 되나 ----
        wiki_lib = os.path.join(tmp, "wiki-import")
        wiki_state = os.path.join(tmp, "wiki-state")
        os.makedirs(wiki_lib, exist_ok=True)
        os.makedirs(wiki_state, exist_ok=True)
        # 🔴 남의 위키에서 복사해 온 문서. `archived` 는 어디서나 흔한 키다.
        with open(os.path.join(wiki_lib, "wiki.md"), "wb") as handle:
            handle.write(b'---\ntitle: "\xec\x9c\x84\xed\x82\xa4 \xeb\xa9\x94\xeb\xaa\xa8"\narchived: true\n---\n\n'
                         + ("본문 " * 200).encode("utf-8"))
        # 프론트매터가 없는데 옛 JSON 에만 별표가 있는 문서
        with open(os.path.join(wiki_lib, "nofm.md"), "wb") as handle:
            handle.write(("프론트매터 없는 " * 100).encode("utf-8"))
        BACKEND.write_starred(wiki_state, {"nofm.md": True})
        keep = (os.environ["AIRLOCK_LEARNING_LIBRARY"], os.environ["AIRLOCK_LEARNING_STATE_DIR"])
        os.environ["AIRLOCK_LEARNING_LIBRARY"] = wiki_lib
        os.environ["AIRLOCK_LEARNING_STATE_DIR"] = wiki_state
        try:
            snap = BACKEND.build_snapshot()
            check("남의 위키의 archived 키가 보관함으로 보낸다",
                  "wiki.md" in {a["path"] for a in snap["archive"]["archived"]})
            # 들어갔으면 나올 수 있어야 한다. `mutable` 은 렌더된 짝을 요구하는데 이 문서엔
            # 없다 — 그것으로 복구를 막으면 그 문서는 영원히 보관함에 갇힌다.
            BACKEND.restore_path("wiki.md")
            snap = BACKEND.build_snapshot()
            check("보관함에 갇히지 않는다 — 복구가 된다",
                  "wiki.md" in {i["path"] for i in snap["items"]},
                  str([a["path"] for a in snap["archive"]["archived"]]))

            # 🔴 보관도 합집합이다. 옛 `state.json` 에만 있는 보관을 빼고 읽으면, 이미
            #    보관해 둔 자료가 이관 전에 목록으로 우르르 돌아온다.
            BACKEND.write_state(wiki_state, {"nofm.md": True})
            snap = BACKEND.build_snapshot()
            check("아직 옮기지 않은 옛 JSON 의 보관도 살아 있다",
                  "nofm.md" in {a["path"] for a in snap["archive"]["archived"]},
                  str([i["path"] for i in snap["items"]]))
            BACKEND.restore_path("nofm.md")
            snap = BACKEND.build_snapshot()
            check("그 보관도 복구가 된다",
                  "nofm.md" in {i["path"] for i in snap["items"]}
                  and "nofm.md" not in BACKEND.read_state(wiki_state),
                  str(BACKEND.read_state(wiki_state)))

            check("프론트매터 없는 문서의 옛 별표가 켜져 보인다",
                  {i["path"]: i["starred"] for i in snap["items"]}.get("nofm.md") is True)
            BACKEND.star_path("nofm.md", False)
            snap = BACKEND.build_snapshot()
            check("프론트매터가 없어도 **끄는 것은 된다**",
                  {i["path"]: i["starred"] for i in snap["items"]}.get("nofm.md") is False,
                  str(BACKEND.read_starred(wiki_state)))
            try:
                BACKEND.star_path("nofm.md", True)
                bad("프론트매터 없는 문서에 별표를 켰다")
            except BACKEND.RequestError as exc:
                check("켜는 것은 여전히 409 다", exc.code == 409, str(exc.code))
        finally:
            os.environ["AIRLOCK_LEARNING_LIBRARY"], os.environ["AIRLOCK_LEARNING_STATE_DIR"] = keep

        # `state_writable` 은 화면이 버튼을 끌 근거다 — 아무 시험도 없었던 자리.
        check("프론트매터가 없으면 state_writable 이 거짓이다",
              BACKEND.builtin_manifest(wiki_lib)["items"]
              and {i["path"]: i["state_writable"]
                   for i in BACKEND.builtin_manifest(wiki_lib)["items"]}.get("nofm.md") is False)
        check("있으면 참이다",
              {i["path"]: i["state_writable"]
               for i in BACKEND.builtin_manifest(wiki_lib)["items"]}.get("wiki.md") is True)

        # ---- 6g. 어느 CLI 로 돌릴지 고르는 어댑터 (카드 5단계) ----
        PROV = load(os.path.join(backend_dir, "providers.py"), "learning_providers_test")
        fake_home = os.path.join(tmp, "fake-home")
        fake_bin = os.path.join(tmp, "fake-bin")
        os.makedirs(fake_bin, exist_ok=True)
        os.makedirs(os.path.join(fake_home, ".codex"), exist_ok=True)
        with open(os.path.join(fake_home, ".codex", "auth.json"), "w") as handle:
            handle.write("{}")
        for name in ("claude", "codex"):
            with open(os.path.join(fake_bin, name), "w", encoding="utf-8") as handle:
                handle.write("#!/bin/sh\nexit 0\n")
            os.chmod(os.path.join(fake_bin, name), 0o755)
        base_env = {"PATH": fake_bin, "HOME": fake_home}

        empty = PROV.select("auto", {"PATH": os.path.join(tmp, "nothing"), "HOME": fake_home})
        check("CLI 가 하나도 없으면 고르지 못하고 사유를 낸다",
              empty[0] is None and "claude" in empty[2] and "codex" in empty[2], str(empty[2]))

        # 🔴 로그인 흔적이 있는 쪽을 먼저 고른다. 여러 CLI 가 깔린 박스에서 로그인 안 된
        #    쪽을 골라 40분 뒤에 실패하는 것이 가장 나쁜 결과다.
        picked = PROV.select("auto", base_env)
        check("로그인 흔적이 있는 제공자를 먼저 고른다", picked[0].id == "codex",
              f"{picked[0].id}: {picked[2]}")
        os.makedirs(os.path.join(fake_home, ".claude"), exist_ok=True)
        with open(os.path.join(fake_home, ".claude", ".credentials.json"), "w") as handle:
            handle.write("{}")
        picked = PROV.select("auto", base_env)
        check("둘 다 흔적이 있으면 선언 순서대로 고른다", picked[0].id == "claude",
              f"{picked[0].id}: {picked[2]}")

        # 흔적이 없어도 막지는 않는다 — 실행해 보지 않고 로그인을 확신할 방법은 없다.
        os.unlink(os.path.join(fake_home, ".claude", ".credentials.json"))
        shutil.rmtree(os.path.join(fake_home, ".codex"))
        picked = PROV.select("auto", base_env)
        check("흔적이 없어도 설치된 CLI 로 실행은 한다",
              picked[0] is not None and "로그인 흔적을 찾지 못" in picked[2], str(picked[2]))

        pinned = PROV.select("codex", base_env)
        check("설정으로 고정하면 그것을 쓴다", pinned[0].id == "codex", str(pinned[2]))
        missing = PROV.select("claude", {"PATH": os.path.join(tmp, "nothing"), "HOME": fake_home})
        check("고정한 제공자가 없으면 다른 것으로 몰래 갈아타지 않는다",
              missing[0] is None and "고정" in missing[2], str(missing[2]))

        claude_p, codex_p = PROV.by_id("claude"), PROV.by_id("codex")
        argv = claude_p.build_argv("/bin/claude", "프롬프트")
        check("claude argv 는 헤드리스 + 스트림 JSON 이다",
              argv[:2] == ["/bin/claude", "-p"] and "stream-json" in argv, str(argv))
        # 🔴 오너 결정 5 — 모델은 노출하지 않는다. argv 에 박으면 그 결정이 코드로 뒤집힌다.
        check("argv 에 모델이 박혀 있지 않다", "--model" not in argv, str(argv))
        codex_argv = codex_p.build_argv("/bin/codex", "프롬프트")
        # 🔴 이 두 인자가 없으면 codex 지원은 장식이다. 라이브러리는 **일부러 git 이 아닌데**
        #    codex 는 git 밖에서 시작을 거부하고, 적재는 cwd 에 쓰고 자막을 받으러 나간다.
        check("codex argv 가 git 밖에서 돌 수 있다",
              "--skip-git-repo-check" in codex_argv, str(codex_argv))
        check("codex argv 가 쓰기와 네트워크를 스스로 말한다",
              "workspace-write" in codex_argv
              and any("network_access=true" in a for a in codex_argv), str(codex_argv))
        check("프롬프트가 마지막 인자다", codex_argv[-1] == "프롬프트", str(codex_argv))
        check("codex 는 평문이라 파싱하지 않는다",
              PROV.streams_json(claude_p) and not PROV.streams_json(codex_p))
        check("스킬 자리가 CLI 마다 다르다",
              claude_p.skill_target("/h").endswith(".claude/skills/learning-ingest")
              and codex_p.skill_target("/h").endswith(".agents/skills/learning-ingest"),
              f"{claude_p.skill_target('/h')} / {codex_p.skill_target('/h')}")

        # 🔴 종량 과금 변수는 자식 환경에서 **지워진다.** 뚫리면 조용히 과금이다.
        dirty = dict(base_env)
        dirty.update({"ANTHROPIC_API_KEY": "x", "OPENAI_API_KEY": "y",
                      "CLAUDE_CODE_USE_BEDROCK": "1", "KEEP_ME": "z"})
        # 양성 대조군 — 이 검사가 실제로 잡는가
        check("과금 변수 검사가 살아 있다",
              [n for n in PROV.UNSAFE_BILLING_ENV if n in dirty] != [])

        # 🔴 **모르는 모양을 버리면 성공한 적재를 잃는다.** 로그가 판정의 근거이므로,
        #    이해 못 한 줄을 조용히 지우면 그 안의 완료 표시도 함께 사라진다 — 문서는
        #    저장됐는데 적재는 `no-output` 으로 실패 기록된다(적대검증 2026-08-22 실측).
        marker_line = f"{BACKEND.INGEST_DONE_MARKER} doc.md"
        unknown_shapes = (
            ('{"type": "assistant_message", "text": "%s"}' % marker_line, "모르는 이벤트 이름"),
            ('{"type": "assistant", "message": {"content": [{"type": "text", "text": "%s"}]}}'
             % marker_line, "아는 이벤트"),
            (marker_line, "JSON 이 아닌 줄"),
            ('["%s"]' % marker_line, "dict 가 아닌 JSON"),
        )
        for payload, label in unknown_shapes:
            out = claude_p.log_bytes(payload + "\n", set()).decode("utf-8")
            check(f"claude: {label} 이어도 원문이 로그에 남는다",
                  marker_line in out, repr(out[:140]))
            if label == "아는 이벤트":
                check("아는 이벤트의 완료 표시는 판정에 닿는다",
                      BACKEND.INGEST_DONE_RE.search(out) is not None, repr(out[:140]))
            elif label != "JSON 이 아닌 줄":
                # 🔴 남기되 **완료로는 읽히지 않아야** 한다. 이해 못 한 줄을 줄머리부터
                #    흘리면 그 안의 문자열이 가짜 완료가 된다.
                check(f"claude: {label} 은 가짜 완료가 되지 않는다",
                      BACKEND.INGEST_DONE_RE.search(out) is None, repr(out[:140]))
        codex_out = codex_p.log_bytes(marker_line + "\n", set()).decode("utf-8")
        check("codex: 평문의 완료 표시가 그대로 로그에 닿는다",
              BACKEND.INGEST_DONE_RE.search(codex_out) is not None, repr(codex_out))
        check("빈 줄은 로그를 채우지 않는다",
              claude_p.log_bytes("   \n", set()) == b""
              and codex_p.log_bytes("", set()) == b"")

        # 🔴 과금 변수는 **모든** 제공자의 자식 환경에서 지워져야 한다. 한쪽만 재면
        #    다른 쪽이 통째로 새는 것을 못 본다.
        for provider in PROV.PROVIDERS:
            child = provider.build_env(dirty)
            leaked_here = [n for n in PROV.UNSAFE_BILLING_ENV if n in child]
            check(f"{provider.id}: 자식 환경에서 과금 변수가 전부 지워진다",
                  not leaked_here, str(leaked_here))
            check(f"{provider.id}: 나머지 환경은 그대로 간다", child.get("KEEP_ME") == "z")

        # 🔴 두 유닛이 **같은 PATH** 를 받는가. 서버는 CLI 를 띄우지 않지만 링크를
        #    붙여넣을 때 **찾아본다** — 그래야 40분 뒤가 아니라 지금 거절할 수 있다.
        #    systemd 사용자 유닛의 기본 PATH 에는 `~/.local/bin` 이 없어서, 서버에만 이
        #    줄이 빠지면 CLI 가 둘 다 깔린 박스에서도 모든 적재 요청이 거절된다.
        render_out = subprocess.run(
            ["bash", "-c",
             f'. "{root}/apps/learning/render.sh"; '
             'render_learning_unit_server /lib /share /state 18832 auto /backend "/probe/bin"; '
             'echo "@@SPLIT@@"; '
             'render_learning_unit_ingest /lib /state auto "/probe/bin" /backend "A_KEY B_KEY"'],
            capture_output=True, text=True, timeout=60).stdout
        server_unit, ingest_unit = render_out.split("@@SPLIT@@")
        check("서버 유닛이 PATH 를 받는다", "Environment=PATH=/probe/bin" in server_unit,
              repr(server_unit[:200]))
        check("워커 유닛도 같은 PATH 를 받는다", "Environment=PATH=/probe/bin" in ingest_unit)
        # 🔴 유닛이 지우는 목록과 어댑터가 지우는 목록은 **한 벌이어야 한다.** 두 벌로
        #    두었더니 실제로 어긋났다(한쪽에 OPENAI_BASE_URL 이 없었다).
        check("워커 유닛의 UnsetEnvironment 를 어댑터가 준다",
              "UnsetEnvironment=A_KEY B_KEY" in ingest_unit,
              repr([l for l in ingest_unit.split("\n") if "Unset" in l]))
        listed_env = subprocess.run(
            [sys.executable, os.path.join(backend_dir, "providers.py"), "--unsafe-env"],
            capture_output=True, text=True, timeout=60).stdout.split()
        check("그 목록이 어댑터의 것과 같다", set(listed_env) == set(PROV.UNSAFE_BILLING_ENV),
              str(set(PROV.UNSAFE_BILLING_ENV) ^ set(listed_env)))
        roots = subprocess.run(
            [sys.executable, os.path.join(backend_dir, "providers.py"), "--skill-roots"],
            capture_output=True, text=True, timeout=60).stdout.split()
        check("스킬 자리도 어댑터가 준다", len(roots) == len(PROV.PROVIDERS), str(roots))

        # CLI 가 없으면 **접수 자체를** 거절한다 — 40분 뒤가 아니라 지금.
        # 🔴 명시적 경로 지정(`AIRLOCK_LEARNING_CLAUDE_BIN`)은 PATH 를 이긴다 — 앞의
        #    워커 시험이 가짜 CLI 를 그 이름으로 걸어 뒀으므로 함께 걷어야 이 시험이 성립한다.
        saved_env = {name: os.environ.pop(name, None)
                     for name in ("AIRLOCK_LEARNING_AGENT", "AIRLOCK_LEARNING_CLAUDE_BIN",
                                  "AIRLOCK_LEARNING_CODEX_BIN")}
        previous_path = os.environ["PATH"]
        os.environ["AIRLOCK_LEARNING_AGENT"] = "claude"
        os.environ["PATH"] = os.path.join(tmp, "nothing")
        try:
            BACKEND.create_ingest_run("https://youtu.be/hhhhhhhhhh1")
            bad("CLI 가 없는데 적재 요청이 접수됐다")
        except BACKEND.RequestError as exc:
            check("CLI 가 없으면 접수 시점에 거절한다", exc.code == 400 and "찾지 못" in exc.message,
                  f"{exc.code}: {exc.message}")
        finally:
            os.environ["PATH"] = previous_path
            os.environ.pop("AIRLOCK_LEARNING_AGENT", None)
            for name, value in saved_env.items():
                if value is not None:
                    os.environ[name] = value

        # ---- 6h. 패키지가 실어 나르는 적재 스킬 (카드 5b) ----
        skill_dir = os.path.join(root, "apps", "learning", "skill")
        check("스킬이 패키지 안에 있다",
              os.path.isfile(os.path.join(skill_dir, "SKILL.md"))
              and os.path.isfile(os.path.join(skill_dir, "transcript.py")))

        with open(os.path.join(skill_dir, "SKILL.md"), encoding="utf-8") as handle:
            skill_text = handle.read()
        # 🔴 참조 박스의 스킬은 워크트리·커밋·PR·머지를 지나야 완료였다. 2단계가 그
        #    판정을 걷어냈으므로 절차에도 남아 있으면 안 된다 — 남아 있으면 평범한
        #    폴더에서 그 절차가 실패한다.
        for forbidden in ("git worktree", "git commit", "gh pr", "git merge"):
            check(f"스킬 절차에 `{forbidden}` 이 없다", forbidden not in skill_text)
        # 헬퍼를 통해서만 쓴다 — 경로를 짐작하지 않는다.
        check("스킬이 저장 헬퍼를 환경에서 받는다", "AIRLOCK_LEARNING_SAVE" in skill_text)
        check("스킬이 완료 표시를 정확한 마커로 적는다",
              BACKEND.INGEST_DONE_MARKER in skill_text)
        check("스킬이 렌더된 짝을 함께 넘긴다", "--html" in skill_text)

        TRANSCRIPT = load(os.path.join(skill_dir, "transcript.py"),
                          "learning_transcript_test")
        check("자막 이벤트가 시각과 문장으로 풀린다",
              TRANSCRIPT.lines_from([
                  {"tStartMs": 1500, "segs": [{"utf8": "안녕"}, {"utf8": " 하세요"}]},
                  {"tStartMs": 3000, "segs": [{"utf8": "\n"}]},          # 개행 전용 — 버린다
                  {"tStartMs": 4000, "segs": []},                        # 빈 이벤트 — 버린다
                  "문자열",                                              # 모양이 아니다
                  {"tStartMs": 5000, "segs": [{"utf8": "다음  문장"}]},
              ]) == [(1.5, "안녕 하세요"), (5.0, "다음 문장")])
        check("시각이 hh:mm:ss 다",
              (TRANSCRIPT.hms(0), TRANSCRIPT.hms(61), TRANSCRIPT.hms(3661), TRANSCRIPT.hms(-5))
              == ("00:00:00", "00:01:01", "01:01:01", "00:00:00"))

        # 저장 헬퍼가 렌더된 짝을 같은 락 안에서 함께 넣는다 — 없으면 공유가 영영 안 된다.
        pair_receipt = os.path.join(state, "probe", "pair.json")
        pair, _warn = SAVE.save(library, "paired.md", document("iiiiiiiiii1"),
                                video_id="iiiiiiiiii1", state_dir=state,
                                receipt_path=pair_receipt,
                                html=b"<!doctype html><meta charset=utf-8><title>x</title>")
        check("렌더된 짝이 문서 옆에 생긴다",
              os.path.isfile(os.path.join(library, "paired.html")))
        check("영수증이 짝을 밝힌다", pair.get("html") == "paired.html", str(pair.get("html")))
        # 🔴 짝이 없으면 `mutable` 이 거짓이 되어 공유도 보관도 안 된다. 그 연결을 잰다.
        snap_env = (os.environ["AIRLOCK_LEARNING_LIBRARY"],
                    os.environ["AIRLOCK_LEARNING_STATE_DIR"])
        pair_lib = os.path.join(tmp, "pairs")
        os.makedirs(pair_lib, exist_ok=True)
        with_source = document("iiiiiiiiii2").replace(
            b"added: 2026-08-22", b"added: 2026-08-22\nsource: youtube")
        SAVE.save(pair_lib, "with-pair.md", with_source, video_id="iiiiiiiiii2",
                  state_dir=state, html=b"<!doctype html><title>y</title>")
        SAVE.save(pair_lib, "no-pair.md",
                  with_source.replace(b"iiiiiiiiii2", b"iiiiiiiiii3"),
                  video_id="iiiiiiiiii3", state_dir=state)
        os.environ["AIRLOCK_LEARNING_LIBRARY"] = pair_lib
        try:
            mutables = {i["path"]: i["mutable"] for i in BACKEND.build_snapshot()["items"]}
            check("짝이 있는 문서만 공유·보관 대상이 된다",
                  mutables.get("with-pair.md") is True
                  and mutables.get("no-pair.md") is False, str(mutables))
        finally:
            (os.environ["AIRLOCK_LEARNING_LIBRARY"],
             os.environ["AIRLOCK_LEARNING_STATE_DIR"]) = snap_env

        # 설치가 남의 스킬을 덮어쓰지 않는다.
        with open(os.path.join(root, "apps", "learning", "install.sh"), encoding="utf-8") as handle:
            installer = handle.read()
        check("설치가 이미 있는 것을 덮어쓰지 않는다",
              "이미 있는" in installer or "already exists" in installer)
        with open(os.path.join(root, "apps", "learning", "deactivate.sh"), encoding="utf-8") as handle:
            deactivate = handle.read()
        check("해제가 자기 링크만 지운다",
              "readlink" in deactivate and "$APP_DIR_LOCAL/skill" in deactivate)

        # ---- 6i. 취소하면 자손이 하나도 안 남는가 ----
        # 🔴 카드가 이것을 **두 번째 제공자를 지원한다고 선언하기 위한 게이트**로 걸어 뒀다.
        #    적재 본체는 자기 자식만이 아니라 손자를 낳는다(전사·서브에이전트). 리더만
        #    죽이면 손자가 라이브러리에 계속 쓸 수 있고, 그러면 취소가 취소가 아니다.
        slow_cli = os.path.join(tmp, "slow-cli")
        with open(slow_cli, "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\n"
                         "sh -c 'while :; do sleep 1; done' &\n"   # 손자
                         "echo grandchild=$! >&2\n"
                         "while :; do sleep 1; done\n")            # 자식 본체
        os.chmod(slow_cli, 0o755)
        cancel_state = os.path.join(tmp, "cancel-state")
        cancel_lib = os.path.join(tmp, "cancel-lib")
        os.makedirs(cancel_state, exist_ok=True)
        os.makedirs(cancel_lib, exist_ok=True)
        saved_cli = os.environ.get("AIRLOCK_LEARNING_CLAUDE_BIN")
        os.environ["AIRLOCK_LEARNING_CLAUDE_BIN"] = slow_cli
        os.environ["AIRLOCK_LEARNING_AGENT"] = "claude"
        cancel_conn = BACKEND.QUEUE.connect(cancel_state)
        try:
            cid = BACKEND.QUEUE.enqueue(cancel_conn, "https://youtu.be/cancelme01",
                                        "cancelme01", RUNNER.now_iso())
            crow = BACKEND.QUEUE.claim_next(cancel_conn, RUNNER.now_iso())

            def ask_cancel():
                time.sleep(3)
                side = BACKEND.QUEUE.connect(cancel_state)
                BACKEND.QUEUE.request_cancel(side, cid)
                side.close()

            watcher = threading.Thread(target=ask_cancel, daemon=True)
            watcher.start()
            before = subprocess.run(["pgrep", "-f", "while :; do sleep 1"],
                                    capture_output=True, text=True).stdout.split()
            RUNNER.run_attempt(cancel_conn, {"repo": cancel_lib, "state": cancel_state}, crow)
            watcher.join(timeout=5)
            crecord = BACKEND.QUEUE.get(cancel_conn, cid)
            check("취소하면 cancelled 로 종결된다", crecord["state"] == "cancelled",
                  f"{crecord['state']} / {crecord.get('reason')}")
            time.sleep(1.5)
            after = subprocess.run(["pgrep", "-f", "while :; do sleep 1"],
                                   capture_output=True, text=True).stdout.split()
            survivors = [pid for pid in after if pid not in before]
            check("자식도 손자도 살아남지 않는다", not survivors, str(survivors))
            check("취소된 적재는 라이브러리에 아무것도 남기지 않는다",
                  os.listdir(cancel_lib) == [], str(os.listdir(cancel_lib)))
        finally:
            cancel_conn.close()
            os.environ.pop("AIRLOCK_LEARNING_AGENT", None)
            if saved_cli is None:
                os.environ.pop("AIRLOCK_LEARNING_CLAUDE_BIN", None)
            else:
                os.environ["AIRLOCK_LEARNING_CLAUDE_BIN"] = saved_cli

        # ---- 6j. 남의 문서를 덮지 않는다 (적대검증 Critical) ----
        # 🔴 실제 적재 한 번이 사용자의 기존 문서를 지우고 `done` 으로 기록됐다. 파일 이름을
        #    고르는 것은 모델이고, 모델은 라이브러리를 본 뒤에도 이미 있는 이름을 고른다.
        clobber_lib = os.path.join(tmp, "clobber")
        os.makedirs(clobber_lib, exist_ok=True)
        precious = document("zzzzzzzzzzz", title="전혀 다른 영상의 소중한 문서")
        SAVE.save(clobber_lib, "shared-name.md", precious, video_id="zzzzzzzzzzz",
                  state_dir=state)
        try:
            SAVE.save(clobber_lib, "shared-name.md", document("wwwwwwwwww1"),
                      video_id="wwwwwwwwww1", state_dir=state)
            bad("남의 문서를 덮어썼다")
        except SAVE.SaveError as exc:
            check("이미 있는 자리는 거절한다", exc.reason == "path-taken", exc.reason)
        with open(os.path.join(clobber_lib, "shared-name.md"), "rb") as handle:
            check("거절된 뒤 원래 문서가 바이트 그대로다", handle.read() == precious)
        # 같은 영상을 다시 쓰는 것(재시도)은 우리 것이므로 허용한다.
        again, _w = SAVE.save(clobber_lib, "shared-name.md", precious,
                              video_id="zzzzzzzzzzz", state_dir=state)
        check("같은 영상의 재저장은 된다", again["video_id"] == "zzzzzzzzzzz")
        # 읽을 수 없는 파일이 있으면 **비었다고 답하지 않는다**.
        unreadable = os.path.join(clobber_lib, "locked.md")
        with open(unreadable, "wb") as handle:
            handle.write(precious)
        if os.geteuid() != 0:
            os.chmod(unreadable, 0o000)
            try:
                SAVE.save(clobber_lib, "locked.md", document("vvvvvvvvvv9"),
                          video_id="vvvvvvvvvv9", state_dir=state)
                bad("읽을 수 없는 파일을 덮어썼다")
            except SAVE.SaveError as exc:
                check("읽을 수 없는 파일도 자리를 차지한 것으로 본다",
                      exc.reason == "path-taken", exc.reason)
            finally:
                os.chmod(unreadable, 0o644)

        # ---- 6k. 전사본 도구의 계약 ----
        # 🔴 실패하면 `--out` 을 만들지 않는다. 반쯤 쓰인 전사본이 남으면 다음 시도가
        #    그것을 이번 것으로 읽는다.
        stub_bin = os.path.join(tmp, "stub-bin")
        os.makedirs(stub_bin, exist_ok=True)
        with open(os.path.join(stub_bin, "yt-dlp"), "w", encoding="utf-8") as handle:
            handle.write("#!/bin/sh\nexit 1\n")
        os.chmod(os.path.join(stub_bin, "yt-dlp"), 0o755)
        out_path = os.path.join(tmp, "transcript-out.txt")
        failed = subprocess.run(
            [sys.executable, os.path.join(skill_dir, "transcript.py"),
             "--url", "https://youtu.be/x", "--out", out_path],
            capture_output=True, text=True, timeout=120,
            env=dict(os.environ, PATH=stub_bin))
        check("전사본 도구는 실패하면 exit 2", failed.returncode == 2, str(failed.returncode))
        check("실패하면 --out 을 만들지 않는다", not os.path.exists(out_path),
              failed.stderr[:200])

        # 🔴 **쓰다가** 실패해도 반쯤 쓰인 전사본이 남으면 안 된다 — 다음 시도가 그것을
        #    이번 것으로 읽는다. 중간에 끊기는 쓰기를 여기서 만들지는 못한다(파일 크기
        #    상한을 걸면 스텁이 먼저 걸려 두 판이 구분되지 않는다). 그래서 재는 것은
        #    **구조**다: 대상에 직접 쓰지 않고 임시 파일을 rename 하는가. 문서 저장에서
        #    같은 방식으로 잰다.
        with open(os.path.join(skill_dir, "transcript.py"), encoding="utf-8") as handle:
            transcript_tree = ast.parse(handle.read())

        def renames(node):
            found = []
            for sub in ast.walk(node):
                if not isinstance(sub, ast.Call):
                    continue
                func = sub.func
                name = (f"{getattr(func.value, 'id', '?')}.{func.attr}"
                        if isinstance(func, ast.Attribute) else getattr(func, "id", ""))
                if name in ("os.replace", "tempfile.mkstemp"):
                    found.append(name)
            return found

        transcript_main = next((n for n in ast.walk(transcript_tree)
                                if isinstance(n, ast.FunctionDef) and n.name == "main"), None)
        check("전사본 도구의 main 을 찾는다", transcript_main is not None)
        if transcript_main is not None:
            used = renames(transcript_main)
            check("전사본은 임시 파일을 rename 해서 남긴다",
                  "os.replace" in used and "tempfile.mkstemp" in used, str(used))
        # 양성 대조군 — 이 탐지기가 직접 쓰기를 구분하는가
        direct = ast.parse('def main():\n    open(out, "w").write(body)\n')
        check("탐지기가 직접 쓰기를 구분한다", renames(direct) == [], str(renames(direct)))

        # 🔴 소스에서 문자열을 세지 않는다 — 그것을 설명하는 **주석에** 속는다(실제로 그랬다).
        #    스텁 yt-dlp 가 자기가 받은 argv 를 적게 하고, 그 기록을 본다.
        recorder = os.path.join(tmp, "ytdlp-argv.log")
        with open(os.path.join(stub_bin, "yt-dlp"), "w", encoding="utf-8") as handle:
            handle.write(f"""#!{sys.executable}
import json, os, sys
with open({recorder!r}, "a", encoding="utf-8") as log:
    log.write(json.dumps(sys.argv[1:], ensure_ascii=False) + chr(10))
if "--dump-json" in sys.argv:
    print(json.dumps({{"id": "aircAruvnKk", "title": "t", "uploader": "c",
                       "duration": 61, "upload_date": "20200101",
                       "webpage_url": "https://youtu.be/aircAruvnKk",
                       "language": "ko"}}))
    raise SystemExit(0)
out = sys.argv[sys.argv.index("-o") + 1] if "-o" in sys.argv else "s.%(ext)s"
fmt = sys.argv[sys.argv.index("--sub-format") + 1] if "--sub-format" in sys.argv else "vtt"
target = out.replace("%(ext)s", fmt.split("/")[0])
os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
with open(target, "w", encoding="utf-8") as fh:
    json.dump({{"events": [{{"tStartMs": 0, "segs": [{{"utf8": "한 줄"}}]}}]}}, fh)
""")
        os.chmod(os.path.join(stub_bin, "yt-dlp"), 0o755)
        good_out = os.path.join(tmp, "stub-transcript.txt")
        ran = subprocess.run(
            [sys.executable, os.path.join(skill_dir, "transcript.py"),
             "--url", "https://youtu.be/aircAruvnKk", "--out", good_out],
            capture_output=True, text=True, timeout=120,
            env=dict(os.environ, PATH=stub_bin))
        check("스텁으로도 전사본이 나온다", ran.returncode == 0, ran.stderr[:200])
        with open(recorder, encoding="utf-8") as handle:
            calls = [json.loads(line) for line in handle if line.strip()]
        check("yt-dlp 를 두 번 이상 부른다", len(calls) >= 2, str(len(calls)))
        # 🔴 `list=` 가 붙은 평범한 watch 주소가 통째로 실패했다 — 접수는 통과시키는데.
        missing = [c for c in calls if "--no-playlist" not in c]
        check("모든 yt-dlp 호출이 영상 하나만 본다", not missing, str(missing[:1]))
        subs_calls = [c for c in calls if "--sub-format" in c]
        check("자막은 json3 로 청한다",
              subs_calls and all(c[c.index("--sub-format") + 1].startswith("json3")
                                 for c in subs_calls), str(subs_calls[:1]))
        # 🔴 언어를 안 주면 yt-dlp 는 영어를 고른다 — 한국어 영상이 번역본으로 요약된다.
        check("영상이 말한 언어를 먼저 청한다",
              subs_calls and all("--sub-langs" in c
                                 and c[c.index("--sub-langs") + 1].startswith("ko")
                                 for c in subs_calls), str(subs_calls[:1]))

        with open(os.path.join(skill_dir, "transcript.py"), encoding="utf-8") as handle:
            transcript_source = handle.read()
        # 🔴 실패 사유를 버리면 429·지역차단이 전부 "자막이 없습니다" 로 세탁된다.
        check("자막 취득 실패 사유를 버리지 않는다", "failures.append" in transcript_source)
        check("json3 가 아닌 것이 와도 그 사실을 말한다",
              "json3 자막이 없습니다" in transcript_source)

        # ---- 6l. 설치가 남의 것을 건드리지 않는다 (문자열이 아니라 실행으로) ----
        fake_home = os.path.join(tmp, "link-home")
        share = os.path.join(fake_home, ".local", "share", "airlock-learning")
        os.makedirs(os.path.join(share, "skill"), exist_ok=True)
        link_script = (
            'set -u\n'
            'log() { printf "%s\\n" "$*"; }\n'
            f'APP_DIR_LOCAL="{share}"\n'
            + "\n".join(
                open(os.path.join(root, "apps", "learning", "install.sh"), encoding="utf-8")
                .read().split("skill_link() {")[1].split("\n}")[0].join(["skill_link() {", "\n}"])
                .split("\n"))
            + '\nskill_link "$1"\n')

        def run_link(root_dir):
            return subprocess.run(["bash", "-c", link_script, "bash", root_dir],
                                  capture_output=True, text=True, timeout=60)

        # ① 남의 진짜 디렉터리는 남는다
        foreign = os.path.join(fake_home, "case-dir", "learning-ingest")
        os.makedirs(foreign, exist_ok=True)
        with open(os.path.join(foreign, "SKILL.md"), "w", encoding="utf-8") as handle:
            handle.write("남의 스킬")
        run_link(os.path.dirname(foreign))
        check("이미 있는 진짜 디렉터리를 건드리지 않는다",
              os.path.isfile(os.path.join(foreign, "SKILL.md")))
        # ② 0700 인 디렉터리의 모드를 넓히지 않는다
        tight = os.path.join(fake_home, "case-mode")
        os.makedirs(tight, exist_ok=True)
        os.chmod(tight, 0o700)
        run_link(tight)
        check("이미 있는 디렉터리의 모드를 넓히지 않는다",
              oct(os.stat(tight).st_mode & 0o777) == "0o700",
              oct(os.stat(tight).st_mode & 0o777))
        check("빈 자리에는 링크를 건다",
              os.path.islink(os.path.join(tight, "learning-ingest")))
        # ③ 해제는 우리 링크만 지운다
        deact = subprocess.run(
            ["bash", os.path.join(root, "apps", "learning", "deactivate.sh")],
            capture_output=True, text=True, timeout=60,
            env=dict(os.environ, HOME=fake_home))
        check("해제가 우리 링크를 지운다",
              not os.path.exists(os.path.join(tight, "learning-ingest"))
              or deact.returncode == 0, deact.stderr[:200])
        check("해제가 남의 디렉터리는 남긴다",
              os.path.isfile(os.path.join(foreign, "SKILL.md")))

        # ---- 7. 걷어낸 것이 정말 걷어졌나 ----
        # 🔴 본문 검색으로는 못 잰다 — 이 파일과 러너의 주석이 걷어낸 git 명령을 **이름으로**
        #    설명하고 있어서, `"git" in source` 는 설명을 호출로 읽는다. 그래서 구문 트리로
        #    본다: 완료 판정 함수 안에 자식 프로세스를 띄우는 호출이 하나도 없어야 한다.
        with open(os.path.join(backend_dir, "ingest_runner.py"), encoding="utf-8") as handle:
            tree = ast.parse(handle.read())

        def spawns(node):
            """이 함수 안에서 자식 프로세스를 띄우는 호출의 이름들."""
            found = []
            for sub in ast.walk(node):
                if not isinstance(sub, ast.Call):
                    continue
                func = sub.func
                name = (f"{getattr(func.value, 'id', '?')}.{func.attr}"
                        if isinstance(func, ast.Attribute) else getattr(func, "id", ""))
                if name.split(".")[0] in ("subprocess", "os") and (
                        "run" in name or "Popen" in name or "exec" in name or "system" in name):
                    found.append(name)
            return found

        verify = next((n for n in ast.walk(tree)
                       if isinstance(n, ast.FunctionDef) and n.name == "_verify_document"), None)
        check("완료 판정 함수를 소스에서 찾는다", verify is not None)
        if verify is not None:
            called = spawns(verify)
            check("완료 판정이 더 이상 자식 프로세스를 띄우지 않는다", not called, str(called))
        # 양성 대조군 — 탐지기가 살아 있나. 이게 없으면 위의 "없다" 는 측정이 아니다.
        control = ast.parse('def probe():\n    subprocess.run(["git", "rev-parse", "HEAD"])\n')
        check("탐지기 양성 대조군이 잡힌다", spawns(control) == ["subprocess.run"],
              str(spawns(control)))
    finally:
        # 🔴 이 스위트는 일부러 쓸 수 없는 디렉터리를 만든다. 중간에 예외로 빠져나가면
        #    그 모드가 그대로 남고, rmtree 는 그 안을 못 지워 /tmp 에 쓰레기를 남긴다.
        for base, dirs, _files in os.walk(tmp):
            for name in dirs:
                with contextlib.suppress(OSError):
                    os.chmod(os.path.join(base, name), 0o755)
        shutil.rmtree(tmp, ignore_errors=True)

    print(f"learning-ingest: passed={PASS} failed={FAIL}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
