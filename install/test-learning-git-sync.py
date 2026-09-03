#!/usr/bin/env python3
"""install/test-learning-git-sync.py — the library commit/push path.

The learning app deliberately removed git from its ingest verdict: a document
that exists on disk is done, and it stays done whether or not anyone commits it.
That was the right call and it left a hole — on a box whose library IS a git
repository, documents piled up uncommitted and nobody noticed until a whole
month of study material was sitting untracked (2026-09-02, 36 files).

`git_sync.py` closes the hole without reopening the coupling. So the properties
worth pinning here are mostly about what it REFUSES to do: it is off unless asked,
it will not commit into a repository it does not own, it will not sweep files the
app never wrote, and a failed push is loud rather than a lost document.
"""

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

PASS = 0
FAIL = 0


def ok(name):
    global PASS
    print(f"ok   learning-git-sync: {name}")
    PASS += 1


def bad(name, detail=""):
    global FAIL
    print(f"FAIL learning-git-sync: {name}" + (f" — {detail}" if detail else ""))
    FAIL += 1


def check(name, condition, detail=""):
    ok(name) if condition else bad(name, detail)


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def git(repo, *args, check_rc=True):
    done = subprocess.run(["git", "-C", repo, *args], capture_output=True,
                          text=True, timeout=60, check=False)
    if check_rc and done.returncode != 0:
        raise AssertionError(f"git {' '.join(args)}: {done.stderr.strip()}")
    return done


def make_repo(root, with_remote=True):
    """A library that looks like the real one: category folders, an INDEX, scripts."""
    os.makedirs(os.path.join(root, "engineering"), exist_ok=True)
    os.makedirs(os.path.join(root, "scripts"), exist_ok=True)
    git(root, "init", "-q", "-b", "main")
    git(root, "config", "user.email", "test@example.com")
    git(root, "config", "user.name", "test")
    write(root, "INDEX.md", "# index\n")
    write(root, "scripts/learn.py", "print('producer')\n")
    write(root, "engineering/seed.md", "---\ntitle: seed\n---\n\nseed\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "seed")
    if not with_remote:
        return None
    remote = root + ".git"
    subprocess.run(["git", "init", "-q", "--bare", remote], check=True, timeout=60)
    git(root, "remote", "add", "origin", remote)
    git(root, "push", "-q", "-u", "origin", "main")
    return remote


def write(root, relative, text):
    full = os.path.join(root, relative)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", encoding="utf-8") as handle:
        handle.write(text)


def head_message(repo, ref="HEAD"):
    return git(repo, "log", "-1", "--format=%s", ref).stdout.strip()


def committed_names(repo):
    return set(git(repo, "show", "--name-only", "--format=", "HEAD").stdout.split())


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    GIT = load(os.path.join(root, "apps/learning/backend/git_sync.py"),
               "learning_git_sync")
    tmp = tempfile.mkdtemp(prefix="learning-git-sync-")
    categories = ["engineering"]
    try:
        # --- 1. off is the default, and it is silent -------------------------
        repo = os.path.join(tmp, "off")
        make_repo(repo)
        state = os.path.join(tmp, "off-state")
        os.makedirs(state)
        write(repo, "engineering/a.md", "---\ntitle: a\n---\n\na\n")
        os.environ.pop("AIRLOCK_LEARNING_REPO_SYNC", None)
        check("환경변수가 없으면 꺼져 있다", GIT.mode() == GIT.MODE_OFF)
        check("꺼져 있으면 sync 가 아무것도 하지 않는다",
              GIT.sync(repo, state, categories) is None)
        check("꺼져 있으면 상태 파일도 남기지 않는다",
              not os.path.exists(GIT.status_path(state)))
        check("꺼져 있으면 커밋도 없다", head_message(repo) == "seed")
        os.environ["AIRLOCK_LEARNING_REPO_SYNC"] = "yes-please"
        check("모르는 값은 auto 가 아니라 off 로 읽는다", GIT.mode() == GIT.MODE_OFF)

        # --- 2. auto: commits documents, pushes, and touches nothing else ----
        os.environ["AIRLOCK_LEARNING_REPO_SYNC"] = "auto"
        remote = make_repo(os.path.join(tmp, "live"))
        repo = os.path.join(tmp, "live")
        state = os.path.join(tmp, "live-state")
        os.makedirs(state)
        write(repo, "engineering/new.md", "---\ntitle: new\n---\n\nnew\n")
        write(repo, "engineering/new.html", "<html>new</html>")
        # Things the app never wrote. A study app that commits these is a study
        # app that lands somebody's half-finished script in a pushed commit.
        write(repo, "INDEX.md", "# index\n\n- new\n")
        write(repo, "scripts/scratch.py", "raise SystemExit('WIP')\n")
        status = GIT.sync(repo, state, categories)
        check("커밋했다고 보고한다", status and status["ok"] and status["committed"] == 2,
              str(status))
        check("push 했다고 보고한다", status and status["pushed"], str(status))
        names = committed_names(repo)
        check("문서와 발행본만 커밋한다",
              names == {"engineering/new.md", "engineering/new.html"}, str(names))
        check("INDEX.md 는 손대지 않는다", "INDEX.md" not in names)
        check("scripts/ 의 남의 작업은 손대지 않는다",
              "scripts/scratch.py" not in names)
        check("원격에도 올라갔다", head_message(remote, "main").startswith("learning:"),
              head_message(remote, "main"))
        check("커밋 안 한 파일은 그대로 남아 있다",
              "scratch.py" in git(repo, "status", "--porcelain").stdout)

        # --- 3. nothing to do is success, not a warning ----------------------
        status = GIT.sync(repo, state, categories)
        check("바뀐 것이 없으면 조용히 성공한다",
              status and status["ok"] and status["committed"] == 0, str(status))

        # --- 4. no upstream: commit locally, say so --------------------------
        repo = os.path.join(tmp, "local")
        make_repo(repo, with_remote=False)
        state = os.path.join(tmp, "local-state")
        os.makedirs(state)
        write(repo, "engineering/solo.md", "---\ntitle: solo\n---\n\nsolo\n")
        status = GIT.sync(repo, state, categories)
        check("upstream 이 없어도 커밋은 한다",
              status and status["committed"] == 1 and not status["pushed"], str(status))
        check("push 하지 않았다는 것을 말한다",
              status and status["error"] and "upstream" in status["error"], str(status))

        # --- 5. a failed push is loud, and the commit survives ---------------
        repo = os.path.join(tmp, "broken")
        remote = make_repo(repo)
        shutil.rmtree(remote)
        state = os.path.join(tmp, "broken-state")
        os.makedirs(state)
        write(repo, "engineering/lost.md", "---\ntitle: lost\n---\n\nlost\n")
        status = GIT.sync(repo, state, categories)
        check("push 실패는 ok=False 로 남는다", status and status["ok"] is False, str(status))
        check("push 실패해도 커밋은 살아 있다",
              head_message(repo).startswith("learning:"), head_message(repo))
        check("실패가 상태 파일에 남아 다음 화면에 뜬다",
              (GIT.read_status(state) or {}).get("ok") is False)

        # --- 6. a library that is not the repository root is refused ---------
        outer = os.path.join(tmp, "outer")
        make_repo(outer, with_remote=False)
        nested = os.path.join(outer, "library")
        os.makedirs(os.path.join(nested, "engineering"))
        write(nested, "engineering/inner.md", "---\ntitle: inner\n---\n\ninner\n")
        state = os.path.join(tmp, "nested-state")
        os.makedirs(state)
        status = GIT.sync(nested, state, categories)
        check("라이브러리가 저장소 루트가 아니면 거부한다",
              status and status["ok"] is False and "루트" in (status["error"] or ""),
              str(status))
        check("거부했으면 바깥 저장소에 커밋하지 않았다",
              head_message(outer) == "seed", head_message(outer))

        # --- 7. a plain folder is not an error, it just has nothing to sync --
        plain = os.path.join(tmp, "plain", "engineering")
        os.makedirs(plain)
        state = os.path.join(tmp, "plain-state")
        os.makedirs(state)
        status = GIT.sync(os.path.join(tmp, "plain"), state, categories)
        check("git 저장소가 아니면 실패로 기록하되 예외는 내지 않는다",
              status is not None and status["ok"] is False, str(status))

        # --- 8. the ticker has its own beat ---------------------------------
        repo = os.path.join(tmp, "beat")
        make_repo(repo)
        state = os.path.join(tmp, "beat-state")
        os.makedirs(state)
        ticker = GIT.Ticker(interval=3600)
        write(repo, "engineering/one.md", "---\ntitle: one\n---\n\none\n")
        first = ticker.tick(repo, state, categories)
        check("첫 tick 은 돈다", first is not None and first["committed"] == 1, str(first))
        write(repo, "engineering/two.md", "---\ntitle: two\n---\n\ntwo\n")
        check("주기 안의 다음 tick 은 건너뛴다",
              ticker.tick(repo, state, categories) is None)
        forced = ticker.tick(repo, state, categories, force=True)
        check("force 는 주기를 무시한다",
              forced is not None and forced["committed"] == 1, str(forced))

        # --- 9. the worker calls it, and the server only reads it ------------
        runner = open(os.path.join(root, "apps/learning/backend/ingest_runner.py"),
                      encoding="utf-8").read()
        check("워커가 적재 직후 force 로 동기화한다", "git_tick(force=True)" in runner)
        check("워커가 유휴에도 동기화를 시도한다", "git_tick()" in runner)
        server = open(os.path.join(root, "apps/learning/backend/airlock-learning.py"),
                      encoding="utf-8").read()
        check("서버는 상태를 읽기만 한다 — 커밋하지 않는다",
              "GITSYNC.read_status" in server and "GITSYNC.sync" not in server)
        check("서버가 실패를 경고로 올린다", "git_sync_warnings" in server)

        # --- 10. only the worker unit carries the knob ----------------------
        render = subprocess.run(
            ["bash", "-c",
             f'. "{root}/apps/learning/render.sh"; '
             'render_learning_unit_server /lib /share /state 18832 auto /backend "/p" /s; '
             'echo "@@SPLIT@@"; '
             'render_learning_unit_ingest /lib /state auto "/p" /backend "A_KEY" /s auto'],
            capture_output=True, text=True, timeout=60).stdout
        server_unit, ingest_unit = render.split("@@SPLIT@@")
        check("워커 유닛이 knob 을 받는다",
              'Environment="AIRLOCK_LEARNING_REPO_SYNC=auto"' in ingest_unit)
        check("서버 유닛은 knob 을 받지 않는다",
              "AIRLOCK_LEARNING_REPO_SYNC" not in server_unit)
        omitted = subprocess.run(
            ["bash", "-c",
             f'. "{root}/apps/learning/render.sh"; '
             'render_learning_unit_ingest /lib /state auto "/p" /backend "A_KEY" /s'],
            capture_output=True, text=True, timeout=60).stdout
        check("인자를 안 주면 off 로 렌더된다",
              'Environment="AIRLOCK_LEARNING_REPO_SYNC=off"' in omitted)

        # --- 11. every backend module the app ships is actually installed ---
        # 🔴 The copy list is written by hand, and a file missing from it does not
        #    degrade the feature — the module that imports it fails at load, so the
        #    server AND the worker crash-loop. Measured 2026-09-02: git_sync.py was
        #    added, every suite stayed green, and the live box came back with
        #    `FileNotFoundError ... git_sync.py` on both units. Nothing else looks at
        #    this list, so nothing else can catch the next omission.
        installer = open(os.path.join(root, "apps/learning/install.sh"),
                         encoding="utf-8").read()
        backend_dir = os.path.join(root, "apps/learning/backend")
        shipped = sorted(n for n in os.listdir(backend_dir) if n.endswith(".py"))
        missing = [n for n in shipped if f'"$HERE/backend/{n}"' not in installer]
        check("설치기가 backend 의 모든 .py 를 깐다", not missing, str(missing))
        # 양성 대조군 — 대조기가 살아 있나. 없으면 위의 "없다" 는 측정이 아니다.
        check("대조기 양성 대조군이 잡힌다",
              "definitely-not-shipped.py" not in installer and bool(shipped))

        # --- 11. the installer refuses a value it does not understand -------
        manifest = open(os.path.join(root, "apps/learning/airlock-app.toml"),
                        encoding="utf-8").read()
        check("기본값이 off 로 선언돼 있다", 'git_sync = "off"' in manifest)
        check("런타임 변수가 선언돼 있다 — 선언 안 된 이름은 오타와 구분되지 않는다",
              '"AIRLOCK_LEARNING_REPO_SYNC"' in manifest)
        installer = open(os.path.join(root, "apps/learning/install.sh"),
                         encoding="utf-8").read()
        check("설치기가 모르는 값을 거절한다",
              "git_sync must be off or auto" in installer)
    finally:
        os.environ.pop("AIRLOCK_LEARNING_REPO_SYNC", None)
        shutil.rmtree(tmp, ignore_errors=True)

    print(f"learning-git-sync: passed={PASS} failed={FAIL}")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
