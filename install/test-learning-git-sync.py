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


def clone_writer(remote, path):
    subprocess.run(["git", "clone", "-q", "--branch", "main", remote, path],
                   check=True, timeout=60)
    git(path, "config", "user.email", "writer@example.com")
    git(path, "config", "user.name", "writer")


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
        reject = os.path.join(remote, "hooks", "pre-receive")
        write(remote, "hooks/pre-receive", "#!/bin/sh\nexit 1\n")
        os.chmod(reject, 0o755)
        state = os.path.join(tmp, "broken-state")
        os.makedirs(state)
        write(repo, "engineering/lost.md", "---\ntitle: lost\n---\n\nlost\n")
        status = GIT.sync(repo, state, categories)
        check("push 실패는 ok=False 로 남는다", status and status["ok"] is False, str(status))
        check("push 실패해도 커밋은 살아 있다",
              head_message(repo).startswith("learning:"), head_message(repo))
        check("실패가 상태 파일에 남아 다음 화면에 뜬다",
              (GIT.read_status(state) or {}).get("ok") is False)
        status = GIT.sync(repo, state, categories)
        check("다음 no-op tick 도 직전 실패를 성공으로 덮지 않는다",
              status and status["ok"] is False and status["committed"] == 0
              and (GIT.read_status(state) or {}).get("ok") is False,
              str(status))

        # --- 6. remote-only commits are fast-forwarded before app commits ----
        repo = os.path.join(tmp, "behind")
        remote = make_repo(repo)
        writer = os.path.join(tmp, "behind-writer")
        clone_writer(remote, writer)
        write(writer, "engineering/remote.md", "---\ntitle: remote\n---\n\nremote\n")
        git(writer, "add", "engineering/remote.md")
        git(writer, "commit", "-q", "-m", "remote document")
        remote_commit = git(writer, "rev-parse", "HEAD").stdout.strip()
        git(writer, "push", "-q")
        state = os.path.join(tmp, "behind-state")
        os.makedirs(state)
        write(repo, "engineering/local.md", "---\ntitle: local\n---\n\nlocal\n")
        commands = []
        real_git = GIT._git

        def recording_git(repo_path, *args):
            commands.append(args)
            return real_git(repo_path, *args)

        GIT._git = recording_git
        try:
            status = GIT.sync(repo, state, categories)
        finally:
            GIT._git = real_git
        check("원격보다 뒤처졌으면 ff-only 뒤 앱 변경을 push 한다",
              status and status["ok"] and status["committed"] == 1
              and status["pushed"], str(status))
        fetch_at = commands.index(("fetch",)) if ("fetch",) in commands else -1
        pull_at = commands.index(("pull", "--ff-only")) \
            if ("pull", "--ff-only") in commands else -1
        push_at = commands.index(("push",)) if ("push",) in commands else -1
        check("fetch → pull --ff-only → push 순서를 지킨다",
              -1 < fetch_at < pull_at < push_at, str(commands))
        check("원격 커밋이 로컬 이력에 보존된다",
              git(repo, "merge-base", "--is-ancestor", remote_commit, "HEAD",
                  check_rc=False).returncode == 0)
        check("ff-only 뒤의 앱 커밋이 원격에 올라간다",
              git(repo, "rev-parse", "HEAD").stdout
              == git(remote, "rev-parse", "main").stdout)

        # A fast-forward may still be impossible when it would overwrite an
        # untracked app file. Stop with git's diagnostic; never discard the file.
        repo = os.path.join(tmp, "behind-conflict")
        remote = make_repo(repo)
        writer = os.path.join(tmp, "behind-conflict-writer")
        clone_writer(remote, writer)
        write(writer, "engineering/same.md", "---\ntitle: remote\n---\n\nremote\n")
        git(writer, "add", "engineering/same.md")
        git(writer, "commit", "-q", "-m", "remote same path")
        git(writer, "push", "-q")
        local_same = "---\ntitle: local\n---\n\nlocal\n"
        write(repo, "engineering/same.md", local_same)
        state = os.path.join(tmp, "behind-conflict-state")
        os.makedirs(state)
        before = git(repo, "rev-parse", "HEAD").stdout.strip()
        status = GIT.sync(repo, state, categories)
        check("ff-only 가 로컬 파일과 충돌하면 실패로 멈춘다",
              status and status["ok"] is False and "fast-forward" in status["error"],
              str(status))
        check("ff-only 충돌은 로컬 파일과 HEAD 를 보존한다",
              open(os.path.join(repo, "engineering/same.md"), encoding="utf-8").read()
              == local_same and git(repo, "rev-parse", "HEAD").stdout.strip() == before)

        # --- 7. divergence stops push and remains loud across no-op ticks ----
        repo = os.path.join(tmp, "diverged")
        remote = make_repo(repo)
        writer = os.path.join(tmp, "diverged-writer")
        clone_writer(remote, writer)
        write(writer, "engineering/remote.md", "---\ntitle: remote\n---\n\nremote\n")
        git(writer, "add", "engineering/remote.md")
        git(writer, "commit", "-q", "-m", "remote document")
        git(writer, "push", "-q")
        write(repo, "engineering/local.md", "---\ntitle: local\n---\n\nlocal\n")
        git(repo, "add", "engineering/local.md")
        git(repo, "commit", "-q", "-m", "local document")
        remote_head = git(remote, "rev-parse", "main").stdout.strip()
        state = os.path.join(tmp, "diverged-state")
        os.makedirs(state)
        commands = []
        real_git = GIT._git

        def recording_git(repo_path, *args):
            commands.append(args)
            return real_git(repo_path, *args)

        GIT._git = recording_git
        try:
            status = GIT.sync(repo, state, categories)
        finally:
            GIT._git = real_git
        check("갈라졌으면 push 하지 않고 diverged 로 남긴다",
              status and status["ok"] is False and status["diverged"] is True,
              str(status))
        check("갈라진 로컬 커밋을 원격에 밀지 않는다",
              not any(args and args[0] == "push" for args in commands)
              and git(remote, "rev-parse", "main").stdout.strip() == remote_head,
              str(commands))
        status = GIT.sync(repo, state, categories)
        check("다음 no-op tick 도 diverged 를 지우지 않는다",
              status and status["committed"] == 0 and status["diverged"] is True
              and (GIT.read_status(state) or {}).get("diverged") is True,
              str(status))

        write(repo, "engineering/pending.md", "---\ntitle: pending\n---\n\npending\n")
        head_before = git(repo, "rev-parse", "HEAD").stdout.strip()
        status = GIT.sync(repo, state, categories)
        check("갈라졌으면 대기 중인 앱 파일도 stage·commit 하지 않는다",
              status and status["diverged"] is True
              and git(repo, "rev-parse", "HEAD").stdout.strip() == head_before
              and "pending.md" in git(repo, "status", "--porcelain").stdout,
              str(status))

        offline = remote + ".offline"
        os.rename(remote, offline)
        write(repo, "engineering/pending2.md", "---\ntitle: pending2\n---\n\npending2\n")
        try:
            status = GIT.sync(repo, state, categories)
        finally:
            os.rename(offline, remote)
        check("갈라진 뒤 fetch 가 실패해도 diverged 와 HEAD 를 보존한다",
              status and status["ok"] is False and status["diverged"] is True
              and git(repo, "rev-parse", "HEAD").stdout.strip() == head_before,
              str(status))
        git(repo, "reset", "--hard", "origin/main")
        status = GIT.sync(repo, state, categories)
        check("사람이 갈라짐을 해결하면 다음 tick 이 경고를 해제한다",
              status and status["ok"] is True and status["diverged"] is False,
              str(status))

        # --- 8. a library that is not the repository root is refused ---------
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

        # --- 9. a plain folder is not an error, it just has nothing to sync --
        plain = os.path.join(tmp, "plain", "engineering")
        os.makedirs(plain)
        state = os.path.join(tmp, "plain-state")
        os.makedirs(state)
        status = GIT.sync(os.path.join(tmp, "plain"), state, categories)
        check("git 저장소가 아니면 실패로 기록하되 예외는 내지 않는다",
              status is not None and status["ok"] is False, str(status))

        # --- 10. the ticker has its own beat --------------------------------
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

        # --- 11. the worker calls it, and the server only reads it -----------
        runner = open(os.path.join(root, "apps/learning/backend/ingest_runner.py"),
                      encoding="utf-8").read()
        check("워커가 적재 직후 force 로 동기화한다", "git_tick(force=True)" in runner)
        check("워커가 유휴에도 동기화를 시도한다", "git_tick()" in runner)
        server = open(os.path.join(root, "apps/learning/backend/airlock-learning.py"),
                      encoding="utf-8").read()
        check("서버는 상태를 읽기만 한다 — 커밋하지 않는다",
              "GITSYNC.read_status" in server and "GITSYNC.sync" not in server)
        check("서버가 실패를 경고로 올린다", "git_sync_warnings" in server)

        # --- 12. only the worker unit carries the knob ----------------------
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

        # --- 13. every backend module the app ships is actually installed ---
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

        # --- 14. the installer refuses a value it does not understand -------
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
