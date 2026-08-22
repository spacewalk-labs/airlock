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
        receipt_path = os.path.join(state, "ingest", "1.receipt.json")
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
        env["AIRLOCK_LEARNING_RECEIPT"] = os.path.join(state, "ingest", "2.receipt.json")
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
        link_receipt = os.path.join(state, "ingest", "3.receipt.json")
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
        deep_receipt = os.path.join(state, "ingest", "5.receipt.json")
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
        broken = os.path.join(state, "ingest", "4.receipt.json")
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

        atomic_receipt = os.path.join(state, "ingest", "6.receipt.json")
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
