#!/usr/bin/env python3
"""git_sync.py — commit and push the library's documents, when it is a repository.

🔴 This is deliberately NOT part of the ingest verdict. The app used to judge an
ingest with `git cat-file -e HEAD:<path>`, which nailed the library to a repo and
made the skill create a worktree, commit, open a PR and merge before a document
that already existed on disk could be called done — and the failure arrived tens
of minutes late. That coupling was removed on purpose. So this module runs
*after* the verdict, owns no part of it, and never raises: a library that cannot
be pushed is a library with a warning, not a failed ingest.

Off by default. A library that happens to sit in a git repository is not consent
to write to someone's remote — the operator turns it on with `git_sync = "auto"`
in `[apps.learning]`.

What it commits is narrow on purpose: `*.md` and `*.html` under the library's
CATEGORY directories, which is exactly the set this app produces. It never runs
`git add -A`. The library's own tooling (an INDEX, scripts, docs) belongs to
whoever wrote it, and a study app sweeping a user's whole tree into a commit is
the kind of surprise that gets an app uninstalled.
"""

import json
import os
import subprocess
import time

# The worker polls its queue every second or two. Pushing on that beat would be
# one network round trip per second for a library nobody touched, so a periodic
# sync waits this long between attempts. An ingest that just finished does not
# wait — it calls with force=True, because that is the moment a user is watching
# for their document to appear in the repository.
INTERVAL_SECONDS = 60.0
GIT_TIMEOUT_SECONDS = 120.0
STATUS_NAME = "git-sync.json"

MODE_OFF = "off"
MODE_AUTO = "auto"


def mode(env=None):
    """`off` (default) or `auto`. An unknown value reads as off, not as auto —
    a typo must not start pushing to a remote."""
    env = os.environ if env is None else env
    value = (env.get("AIRLOCK_LEARNING_REPO_SYNC") or MODE_OFF).strip().lower()
    return MODE_AUTO if value == MODE_AUTO else MODE_OFF


def status_path(state_dir):
    return os.path.join(state_dir, STATUS_NAME)


def read_status(state_dir):
    try:
        with open(status_path(state_dir), "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _write_status(state_dir, payload):
    tmp = status_path(state_dir) + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, sort_keys=True)
        os.replace(tmp, status_path(state_dir))
    except OSError:
        # Losing the status file must not take the worker down with it. The next
        # tick writes it again; the worst case is that the UI is one cycle stale.
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _git(repo, *args):
    """Returns (rc, stdout, stderr). Never raises — a missing git is a warning."""
    try:
        done = subprocess.run(
            ["git", "-C", repo, *args], capture_output=True, text=True,
            timeout=GIT_TIMEOUT_SECONDS, check=False)
    except FileNotFoundError:
        return 127, "", "git 이 설치되어 있지 않습니다"
    except subprocess.TimeoutExpired:
        return 124, "", f"git {args[0] if args else ''} 이 {GIT_TIMEOUT_SECONDS:g}초 안에 끝나지 않았습니다"
    except OSError as exc:
        return 1, "", str(exc)
    return done.returncode, done.stdout, done.stderr


def _pathspecs(repo, categories):
    """One glob pair per category directory. `:(glob)` so `**` means "any depth"
    regardless of the caller's shell, and so a directory named like a git magic
    word cannot change the meaning of the argument."""
    specs = []
    for name in categories:
        if not name or name.startswith("-") or "/" in name:
            continue
        if not os.path.isdir(os.path.join(repo, name)):
            continue
        specs.append(f":(glob){name}/**/*.md")
        specs.append(f":(glob){name}/**/*.html")
    return specs


def _is_library_root(repo):
    rc, out, _err = _git(repo, "rev-parse", "--show-toplevel")
    if rc != 0:
        return False, "git 저장소가 아닙니다"
    top = out.strip()
    if not top:
        return False, "git 저장소가 아닙니다"
    if os.path.realpath(top) != os.path.realpath(repo):
        # A library nested inside a bigger repository is a different question:
        # committing there means writing into a tree this app does not own.
        return False, (f"라이브러리가 저장소 루트가 아닙니다 (루트: {top}) — "
                       "이 앱은 남의 저장소에 커밋하지 않습니다")
    return True, None


def _parse_porcelain_z(out):
    """`git status --porcelain -z` 의 경로만 뽑는다.

    🔴 rename/copy 항목은 **두 필드**다 — 새 경로 뒤에 옛 경로가 따로 온다. 그걸 모르면
    옛 경로가 XY 접두 없는 항목으로 섞여 들어와 3글자가 잘린 쓰레기 경로가 된다.
    """
    fields = out.split("\0")
    paths = []
    index = 0
    while index < len(fields):
        entry = fields[index]
        index += 1
        if len(entry) < 4:
            continue
        xy, path = entry[:2], entry[3:]
        if xy[0] in ("R", "C") and index < len(fields):
            index += 1        # 옛 경로 필드를 건너뛴다
        if path:
            paths.append(path)
    return paths


def _changed(repo, specs):
    rc, out, err = _git(repo, "status", "--porcelain", "-z", "--", *specs)
    if rc != 0:
        return None, f"git status 가 실패했습니다: {err.strip() or rc}"
    return _parse_porcelain_z(out), None


def _upstream(repo):
    rc, out, _err = _git(repo, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    return out.strip() if rc == 0 and out.strip() else None


def _ahead_behind(repo):
    """Return commits unique to HEAD and its upstream, in that order."""
    rc, out, err = _git(repo, "rev-list", "--left-right", "--count", "HEAD...@{u}")
    if rc != 0:
        return None, None, f"git 이력 비교가 실패했습니다: {err.strip() or rc}"
    try:
        ahead, behind = (int(value) for value in out.split())
    except (TypeError, ValueError):
        return None, None, "git 이력 비교 결과를 이해할 수 없습니다"
    return ahead, behind, None


def sync(repo, state_dir, categories, log=None):
    """Commit (and push, when there is an upstream) the library's documents.

    Returns the status dict it recorded, or None when the mode is off. Callers
    treat the result as information only — nothing here changes an ingest verdict.
    """
    if mode() == MODE_OFF:
        return None

    previous = read_status(state_dir)
    previous_diverged = isinstance(previous, dict) and previous.get("diverged") is True

    def say(line):
        if log is not None:
            log(line)

    def record(ok, error, committed=0, pushed=False, diverged=False):
        payload = {"at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "ok": ok,
                   "error": error, "committed": committed, "pushed": pushed,
                   "diverged": diverged}
        _write_status(state_dir, payload)
        return payload

    ok, why = _is_library_root(repo)
    if not ok:
        return record(False, why)

    specs = _pathspecs(repo, categories)
    if not specs:
        # No category directories yet means there is nothing to commit, but we
        # still inspect the remote so an earlier sync failure cannot disappear.
        changed = []
    else:
        changed, err = _changed(repo, specs)
        if err:
            return record(False, err)

    upstream = _upstream(repo)
    pulled = False
    fetch_error = None
    if upstream is None and previous_diverged:
        return record(False,
                      "직전 갈라짐을 재확인할 upstream 이 없습니다 — push 를 멈춥니다",
                      diverged=True)
    if upstream is not None:
        rc, _out, fetch_err = _git(repo, "fetch")
        if rc != 0:
            error = (f"push 전 fetch 가 실패했습니다 ({upstream}): "
                     f"{fetch_err.strip() or rc}")
            if previous_diverged:
                # Not observed is not resolved. A transient network failure must
                # neither clear the warning nor stack commits on a branch already
                # known to need a person.
                return record(False, error, diverged=True)
            # Keep the app's files in a local commit even while the remote is
            # unavailable. The failed fetch remains loud and a later tick can
            # retry without requiring another document change.
            fetch_error = error
        else:
            ahead, behind, compare_error = _ahead_behind(repo)
            if compare_error:
                return record(False, compare_error)
            if ahead and behind:
                return record(
                    False,
                    (f"로컬과 {upstream} 이 갈라졌습니다 (로컬 {ahead}개, 원격 {behind}개) — "
                     "자동 rebase 하지 않으며 push 를 멈춥니다"),
                    diverged=True)
            if behind:
                rc, _out, pull_err = _git(repo, "pull", "--ff-only")
                if rc != 0:
                    return record(False, f"{upstream} fast-forward 가 실패했습니다: "
                                        f"{pull_err.strip() or rc}")
                pulled = True
                # The fast-forward may have changed category paths. Stage the
                # current working tree, not the list observed before the pull.
                specs = _pathspecs(repo, categories)
                if specs:
                    changed, err = _changed(repo, specs)
                    if err:
                        return record(False, err)
                else:
                    changed = []

    count = 0
    if changed:
        # 🔴 여기서 pathspec 을 다시 쓰지 않고 **방금 관측한 경로**를 그대로 스테이징한다.
        #    glob 을 다시 던지면 짝 HTML 이 없는 문서에서 `pathspec did not match any files`
        #    로 add 전체가 죽어 아무것도 커밋되지 않는다(실측 — 이 스위트가 잡았다).
        #    관측한 목록을 쓰면 그 창이 없고, 커밋한 것과 셌던 것이 같아진다.
        rc, _out, add_err = _git(repo, "add", "--", *changed)
        if rc != 0:
            return record(False, f"git add 가 실패했습니다: {add_err.strip() or rc}")

        count = len(changed)
        message = (f"learning: 문서 {count}건 변경\n\n"
                   "airlock learning 앱이 라이브러리에 쓴 것을 그대로 커밋했습니다.\n"
                   "커밋 대상은 카테고리 폴더의 .md/.html 뿐입니다.")
        rc, _out, commit_err = _git(repo, "commit", "-m", message)
        if rc != 0:
            # `nothing to commit` is possible when another writer committed between
            # our status and our add. That is not a failure — the tree is clean now.
            blob = (commit_err + _out).lower()
            if "nothing to commit" in blob or "nothing added" in blob:
                count = 0
            else:
                return record(False, f"git commit 이 실패했습니다: "
                                    f"{commit_err.strip() or rc}")
        else:
            say(f"[git] 문서 {count}건을 커밋했습니다")

    if upstream is None:
        if not count:
            return record(True, None)
        return record(True, "커밋했지만 push 하지 않았습니다 — 현재 브랜치에 upstream 이 "
                            "없습니다", committed=count)
    if fetch_error:
        return record(False, fetch_error, committed=count)

    ahead, behind, compare_error = _ahead_behind(repo)
    if compare_error:
        return record(False, compare_error, committed=count)
    if ahead and behind:
        return record(False,
                      (f"로컬과 {upstream} 이 갈라졌습니다 (로컬 {ahead}개, 원격 {behind}개) — "
                       "자동 rebase 하지 않으며 push 를 멈춥니다"),
                      committed=count, diverged=True)
    if not ahead and not pulled:
        return record(True, None, committed=count)

    rc, _out, push_err = _git(repo, "push")
    if rc != 0:
        # 🔴 A failed push is loud, and it stays loud: the commit is local, the
        # remote does not have it, and the next sync will try again. Silence here
        # is how a library drifts for a week and nobody knows.
        return record(False, f"커밋했지만 push 가 실패했습니다 ({upstream}): "
                             f"{push_err.strip() or rc}", committed=count)
    say(f"[git] {upstream} 로 push 했습니다")
    return record(True, None, committed=count, pushed=True)


class Ticker:
    """Calls sync() on its own beat, independent of the worker's poll interval."""

    def __init__(self, interval=INTERVAL_SECONDS):
        self.interval = interval
        self._last = None

    def tick(self, repo, state_dir, categories, log=None, force=False):
        if mode() == MODE_OFF:
            return None
        now = time.monotonic()
        if not force and self._last is not None and now - self._last < self.interval:
            return None
        self._last = now
        return sync(repo, state_dir, categories, log=log)
