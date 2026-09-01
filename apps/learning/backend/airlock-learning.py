#!/usr/bin/env python3
"""learning-manager — learning 레포 발행 상태를 소유하는 개인앱 백엔드.

수집은 learning 레포의 ``learn.py manifest --json`` 하나에 맡기고, 이 앱은
manifest의 repo-relative path를 실제 파일·심링크 상태에 다시 결합한다.
게이팅은 nginx가 맡으므로 이 프로세스는 loopback에서만 듣는다.
"""

import argparse
import copy
import importlib.util
import errno
import fcntl
import hashlib
import json
import os
import posixpath
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit


DEFAULT_LIBRARY = "~/learning"
# publish 의 공유 디렉터리. 설치기가 publish 의 설정에서 읽어 유닛에 실어 준다 —
# 이 기본값은 그것 없이 직접 띄울 때만 쓰이고, publish 백엔드의 폴백과 일부러 같다.
DEFAULT_SHARE_DIR = "~/public_html"
DEFAULT_STATE_DIR = "~/.local/state/airlock-learning"
DEFAULT_PORT = 18832
# 카테고리는 **라이브러리의 폴더**다. 이름 목록을 코드에 두지 않는다 — 폴더를 만들면
# 카테고리가 생기고, 폴더가 하나도 없으면 카테고리가 없는 평평한 라이브러리다.
# 여기 있던 4개 고정 목록(engineering/business/science/other)이 이 앱을 한 사람의
# 레포에 묶어 두던 두 곳 중 하나였다.
CATEGORY_SKIP_PREFIXES = (".", "_")
CATEGORY_SKIP_NAMES = frozenset({"scripts", "templates", "tests", "docs", "node_modules"})
BODY_MAX_BYTES = 1 << 20
MANIFEST_STDOUT_MAX_BYTES = 4 << 20
MANIFEST_STDERR_MAX_BYTES = 16 << 10
MANIFEST_TIMEOUT_SECONDS = 5
GIT_TIMEOUT_SECONDS = 3
# 취소 요청이 유닛 중지를 기다려 주는 예산 = **HTTP 핸들러가 매달릴 시간**이지, 중지가
# 실패했다고 판정하는 기한이 아니다. 넘으면 실패가 아니라 "접수됐고 아직 멈추는 중"이고
# 확정은 스윕이 한다.
#
# 유닛의 `TimeoutStopSec`(매니저 기본값 90초 — 우리 유닛 파일은 이 값을 쓰지 않는다)과는
# **독립**으로 둔다. 코드를 따라가 보면 어느 쪽이 크든 상태가 수렴한다: 짧으면 스윕이
# 확정하고, 길면 systemctl 이 stop 완료까지 블록한 뒤 rc=0 으로 돌아와 인라인 확정한다.
# 그러니 두 값을 결박하지 않는다 — 없는 불변식을 코드가 주장하게 만들 뿐이다.
#
# ⚠️ 단, "뒤집혀도 반드시 수렴한다" 는 **코드를 읽은 추론**이지 테스트가 지키는 불변식이
#    아니다(대소를 뒤집은 구성으로 돌려 본 적이 없다). 이 값을 크게 바꿀 일이 생기면
#    그때 실제로 확인할 것.
# Type=oneshot은 ExecStart가 도는 동안 activating이다. active만 보면 살아 있는
# 러너를 죽었다고 오판한다. 🔴 실측(2026-08-04, 레퍼런스 박스): 1800초를 돈 실제 적재 유닛
# `20db6e2e`의 ActiveEnterTimestamp가 비어 있다 — oneshot은 active를 한 번도 거치지 않는다.
VIDEO_ID_RE = re.compile(r"\A[A-Za-z0-9_-]{1,128}\Z")
# 취소 계열. 서버와 러너가 각자 "이미 취소로 기울었나"를 묻는 곳이 넷이라 이름을 준다.
YOUTUBE_HOSTS = {
    "youtube.com",
    "www.youtube.com",
    "m.youtube.com",
    "music.youtube.com",
    "youtu.be",
    "www.youtu.be",
}
# 적재 완료 표시. 패키지 안의 `apps/learning/skill/SKILL.md` §5 가 짝이다 — 앞 절이 전부 끝났을
# 때만 이 줄을 출력한다. `exit 0` 은 "claude 가 정상 종료했다" 는 뜻일 뿐 "적재가 됐다" 는
# 뜻이 아니다(2026-07-30 실측: 스킬이 되묻고 exit 0 으로 끝나 앱이 done 으로 기록했다).
# 🔴 줄 시작 + 알려진 주제 + .md 까지 요구한다 — 스킬 본문이 로그에 에코돼도 오탐하지 않게.
# `git log --format=%cI` 줄. 파일 이름이 시각처럼 보이는 경우와 갈리지 않게 전체 일치로 본다.
STAMP_RE = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:?[0-9]{2})")
# 화면에 실어 보내는 로그 꼬리 길이. 폰에서 보는 상세 카드용이다.
INGEST_LOG_VIEW_BYTES = 200 << 10

INGEST_DONE_MARKER = "LEARNING-INGEST-DONE"
# 🔴 예전에는 주제 4개를 정규식에 박아 그 폴더만 인정했다. 이제 **폴더 한 단계까지**를
# 문법으로 받고(평평한 라이브러리면 폴더 없이 파일명만), 그 폴더가 실제로 있는
# 카테고리인지는 문법이 아니라 `classify_target` 과 러너의 파일 검증이 판정한다.
INGEST_DONE_RE = re.compile(  # noqa: regex-anchor  # MULTILINE 로그를 줄 단위로 읽는다 — 여기의 ^$ 는 값 검증이 아니라 줄 경계이고, 패턴은 마커 상수에서 조립된다
    r"^" + INGEST_DONE_MARKER + r"[ \t]+((?:[^/\s]+/)?[^/\s]+\.md)[ \t]*$",
    re.MULTILINE,
)
# 표시는 로그 끝에 온다. 전체를 읽지 않고 꼬리만 본다.
INGEST_DONE_TAIL_BYTES = 64 << 10
# 제목 표시 — fetch 직후 스킬이 한 줄 흘리면 러너가 status 에 옮긴다. 적재 중 카드가
# `A5k--Wsg7WE 적재 중` 대신 무슨 영상인지 보여주기 위한 것이고, **판정에는 쓰지 않는다**
# (완료 판정의 유일한 근거는 위 DONE 마커다). 없으면 video_id 로 곱게 내려앉는다.
INGEST_META_MARKER = "LEARNING-INGEST-META"
# 🔴 닫는 `}` 를 요구하지 않는다 — 잘린 JSON 은 아예 매치되지 않아 **깨진 줄이 조용히**
# 사라진다. 줄 나머지를 받아 파싱을 시도하고, 실패는 로그로 드러낸다.
INGEST_META_RE = re.compile(  # noqa: regex-anchor  # 위와 같다: 줄 경계이지 값 검증이 아니다
    r"^" + INGEST_META_MARKER + r"[ \t]+(\S.*?)[ \t]*$", re.MULTILINE)
# 표시용 값만 받는다 — 러너가 상태에 병합하므로 아무 키나 받으면 status 계약이 오염된다.
INGEST_META_FIELDS = ("title", "channel", "duration")

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRONTEND_PATH = os.path.join(BASE_DIR, "frontend", "learning.html")
def env_first(*names, default):
    """앞 이름부터 찾아 처음 설정된 값을 쓴다.

    🔴 정본은 `AIRLOCK_LEARNING_*` 다 — 패키지 계약(D2)이 앱은 **자기 접두사를 가진
    런타임 변수만** 선언하게 하고, 그래서 `PUBLIC_HTML` 이나 `STATE_DIR` 처럼 남의
    것일 수도 있는 이름을 이 앱이 선언할 수 없다. 뒤의 이름들은 패키지가 되기 전
    배포본이 쓰던 것이라 읽기만 한다 — 새 설치는 만들지 않는다.
    """
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return default


PORT = int(env_first("AIRLOCK_LEARNING_PORT", "LEARNING_MANAGER_PORT",
                     default=str(DEFAULT_PORT)))

SNAPSHOT_LOCK = threading.Lock()
LAST_SUCCESS = None


class IngestQueue:
    """적재 큐 — SQLite 한 테이블. **클래스는 이름공간일 뿐이다**(인스턴스를 만들지 않는다).

    모듈을 따로 두지 않은 이유는 하나다 — `infra/dev-hub/` 는 airlock 이관 중이라 파일
    **추가**가 금지돼 있고(`docs/airlock/sot-cutline.yaml`: statuses `M`·`D` 만), 그 규칙을
    내 편의로 흔들지 않는다. 대신 이름을 한 곳에 모아 `QUEUE.연산()` 으로만 부른다.

    설계 규칙 셋. 이 셋이 지켜지는 동안은 락도 스윕도 필요하지 않다.

    1. **실행 1회 = 행 1개.** 종결된 행은 다시 쓰지 않는다. 재시도는 `retry_of` 를 가진
       새 행이다. 그래서 "옛 흔적을 지우는" 코드가 존재하지 않는다.
    2. **`state` 를 쓰는 것은 워커 하나뿐이다.** 웹앱은 행을 넣고(`queued`), 취소를
       요청하고(`cancel=1`), 종결된 행을 지운다. 그 셋뿐이다.
    3. **`cancel` 은 상태가 아니라 요청이다.** 화면의 "취소 중"은 `state='running' AND
       cancel=1` 의 파생 뷰다. 저장하지 않으므로 "취소 중인데 이미 끝난" 조합이 생기지 않는다.

    이전 구조는 상태의 진실이 셋(status 문자열 · launching 불리언 · systemd ActiveState)
    으로 갈려 있었고, 적대검증 3라운드에서 나온 결함 15건이 전부 그 틈에서 나왔다.
    """

    # 시험이 여기를 patch 해 "핸들러가 DB 를 만지지 않는가" 를 잰다.
    sqlite3 = sqlite3

    WORKER_LOCK_NAME = "worker.lock"

    STATES = ("queued", "running", "done", "failed", "cancelled")
    TERMINAL_STATES = {"done", "failed", "cancelled"}
    ACTIVE_STATES = {"queued", "running"}

    SCHEMA = """
    CREATE TABLE IF NOT EXISTS attempts (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      url          TEXT    NOT NULL,
      video_id     TEXT    NOT NULL,
      state        TEXT    NOT NULL CHECK (state IN ('queued','running','done','failed','cancelled')),
      cancel       INTEGER NOT NULL DEFAULT 0,
      retry_of     INTEGER REFERENCES attempts(id) ON DELETE SET NULL,
      created_at   TEXT    NOT NULL,
      started_at   TEXT,
      finished_at  TEXT,
      exit_code    INTEGER,
      reason       TEXT,
      error        TEXT,
      document     TEXT,
      title        TEXT,
      channel      TEXT,
      duration     TEXT,
      failure_summary       TEXT,
      failure_summary_error TEXT
    );

    -- 🔴 "동시 1건" 의 1차 보장은 워커가 하나라는 사실이고, 이 인덱스는 그 사실이 깨졌을 때
    --    조용히 두 건이 도는 대신 **쓰기가 실패하게** 만드는 2차 방어선이다.
    CREATE UNIQUE INDEX IF NOT EXISTS one_running
      ON attempts(state) WHERE state = 'running';

    -- 🔴 같은 영상은 큐에 하나만 살아 있다. 웹앱의 사전 확인(`active_video_ids`)은 SELECT 와
    --    INSERT 사이에 창이 있어, 같은 URL 로 동시에 들어온 세 요청이 **전부 통과했다**(실측).
    --    그 창을 닫는 것은 인덱스뿐이다 — `one_running` 과 같은 자리의 방어선이다.
    CREATE UNIQUE INDEX IF NOT EXISTS one_live_per_video
      ON attempts(video_id) WHERE state IN ('queued','running');

    CREATE INDEX IF NOT EXISTS queued_order ON attempts(id) WHERE state = 'queued';
    """

    COLUMNS = (
        "id", "url", "video_id", "state", "cancel", "retry_of",
        "created_at", "started_at", "finished_at", "exit_code",
        "reason", "error", "document", "title", "channel", "duration",
        "failure_summary", "failure_summary_error",
    )


    class DuplicateVideo(Exception):
        """같은 영상이 이미 큐에 살아 있다. 웹앱이 409 로 옮긴다."""

        def __init__(self, video_id):
            super().__init__(video_id)
            self.video_id = video_id


    @staticmethod
    def db_path(state_dir):
        return os.path.join(state_dir, "ingest.db")


    @staticmethod
    def log_path(state_dir, attempt_id):
        return os.path.join(state_dir, "ingest", f"{int(attempt_id)}.log")


    @staticmethod
    def receipt_path(state_dir, attempt_id):
        """저장 헬퍼가 이 시도의 영수증을 쓰는 자리. 러너가 자식에게 경로로 넘긴다.

        로그 옆에 두는 이유는 하나다 — 시도가 끝나면 둘 다 그 시도의 증거이고,
        `state` 를 쓰는 것은 워커뿐이라는 규칙이 그대로 적용된다.
        """
        return os.path.join(state_dir, "ingest", f"{int(attempt_id)}.receipt.json")


    @staticmethod
    def worker_lock_path(state_dir):
        return os.path.join(state_dir, IngestQueue.WORKER_LOCK_NAME)


    @staticmethod
    def _enable_wal(conn):
        """🔴 `journal_mode` 전환에는 **busy handler 가 걸리지 않는다.** 다른 연결이 같은 순간에
        같은 전환을 하면 재시도 없이 곧바로 SQLITE_BUSY 가 되어 `connect()` 자체가 터진다
        (실측: 비어 있는 state 에 동시 요청 3건 → 40회 중 13회 `database is locked`, HTTP 500).

        모드는 DB 파일에 남으므로 **누가 한 번만 성공하면 된다** — 그래서 여기서만 짧게 되돌아본다.
        끝내 못 바꿔도 연결은 정상 동작한다(동시성만 낮아진다).
        """
        for _ in range(50):
            try:
                mode = conn.execute("PRAGMA journal_mode=WAL").fetchone()
            except IngestQueue.sqlite3.OperationalError:
                mode = None
            if mode is not None and str(mode[0]).lower() == "wal":
                return True
            time.sleep(0.02)
        return False


    @staticmethod
    def connect(state_dir):
        """스키마까지 보장해 돌려준다. 호출자는 close 만 책임진다."""
        os.makedirs(os.path.join(state_dir, "ingest"), exist_ok=True)
        conn = IngestQueue.sqlite3.connect(IngestQueue.db_path(state_dir), timeout=10, isolation_level=None)
        conn.row_factory = IngestQueue.sqlite3.Row
        conn.execute("PRAGMA busy_timeout=10000")
        IngestQueue._enable_wal(conn)
        conn.execute("PRAGMA foreign_keys=ON")
        conn.executescript(IngestQueue.SCHEMA)
        return conn


    @staticmethod
    def row_to_dict(row):
        if row is None:
            return None
        record = {key: row[key] for key in IngestQueue.COLUMNS}
        # 화면이 쓰는 파생 값. 저장하지 않는 이유는 모듈 주석 §3.
        record["cancelling"] = bool(record["cancel"]) and record["state"] == "running"
        return record


    @staticmethod
    def enqueue(conn, url, video_id, now, retry_of=None):
        try:
            cursor = conn.execute(
                "INSERT INTO attempts (url, video_id, state, created_at, retry_of)"
                " VALUES (?, ?, 'queued', ?, ?)",
                (url, video_id, now, retry_of),
            )
        except IngestQueue.sqlite3.IntegrityError as exc:
            # `one_live_per_video` 가 막았다 = 그 사이에 같은 영상이 들어왔다.
            raise IngestQueue.DuplicateVideo(video_id) from exc
        return int(cursor.lastrowid)


    @staticmethod
    def get(conn, attempt_id):
        return IngestQueue.row_to_dict(
            conn.execute("SELECT * FROM attempts WHERE id = ?", (attempt_id,)).fetchone()
        )


    @staticmethod
    def recent(conn, limit=200):
        rows = conn.execute(
            "SELECT * FROM attempts ORDER BY id DESC LIMIT ?", (limit,)
        ).fetchall()
        return [IngestQueue.row_to_dict(row) for row in rows]


    @staticmethod
    def active_video_ids(conn):
        rows = conn.execute(
            "SELECT DISTINCT video_id FROM attempts WHERE state IN ('queued','running')"
        ).fetchall()
        return {row["video_id"] for row in rows}


    @staticmethod
    def request_cancel(conn, attempt_id):
        """취소를 **요청**한다. 실제 종결은 워커가 한다.

        🔴 `queued` 행을 여기서 곧바로 `cancelled` 로 쓰지 않는다 — 그러면 웹앱도 `state` 를
        쓰는 주체가 되어 모듈 주석 §2 가 깨진다. 아직 안 뜬 행을 워커가 집어 즉시 종결하는
        비용은 폴링 한 바퀴(2초)뿐이다.
        """
        cursor = conn.execute(
            "UPDATE attempts SET cancel = 1 WHERE id = ? AND state IN ('queued','running')",
            (attempt_id,),
        )
        return cursor.rowcount > 0


    @staticmethod
    def delete(conn, attempt_id):
        cursor = conn.execute(
            "DELETE FROM attempts WHERE id = ? AND state IN ('done','failed','cancelled')",
            (attempt_id,),
        )
        return cursor.rowcount > 0


    # ---- 아래 셋은 워커 전용이다. 웹앱 경로에서 부르지 않는다. ----

    @staticmethod
    def recover_interrupted(conn, now):
        """워커가 뜰 때 한 번. 이 시점에 `running` 인 행은 **정의상 죽은 행**이다.

        워커가 싱글턴이므로, 워커가 방금 떴다는 것은 그 행을 돌리던 프로세스가 없다는
        뜻이다. 이전 구조의 스윕(유닛 ActiveState 조회 + `launching` 판정 + "기동 미확정"
        보류)이 통째로 이 한 문장으로 대체된다.
        """
        cursor = conn.execute(
            "UPDATE attempts SET state = 'failed', finished_at = ?, reason = 'interrupted',"
            " error = '실행 중 워커가 중단되어 결과를 알 수 없습니다' WHERE state = 'running'",
            (now,),
        )
        return cursor.rowcount


    @staticmethod
    def claim_next(conn, now):
        """가장 오래된 `queued` 한 건을 `running` 으로 옮기고 그 행을 돌려준다.

        취소가 요청된 행은 뜨우지 않고 곧바로 `cancelled` 로 종결한다(그래서 돌려주지 않는다).
        """
        conn.execute("BEGIN IMMEDIATE")
        try:
            # 이미 도는 건이 있으면 아무것도 집지 않는다. 워커가 하나면 이 조건은 늘 거짓이지만,
            # 참이 되는 상황(손으로 워커를 하나 더 띄운 경우)에서 `one_running` 인덱스가
            # IntegrityError 로 터지는 대신 조용히 양보하게 만든다.
            if conn.execute(
                "SELECT 1 FROM attempts WHERE state = 'running' LIMIT 1"
            ).fetchone() is not None:
                conn.execute("COMMIT")
                return None
            row = conn.execute(
                "SELECT * FROM attempts WHERE state = 'queued' ORDER BY id LIMIT 1"
            ).fetchone()
            if row is None:
                conn.execute("COMMIT")
                return None
            if row["cancel"]:
                conn.execute(
                    "UPDATE attempts SET state = 'cancelled', finished_at = ?,"
                    " reason = 'cancelled-before-start' WHERE id = ?",
                    (now, row["id"]),
                )
                conn.execute("COMMIT")
                return None
            conn.execute(
                "UPDATE attempts SET state = 'running', started_at = ? WHERE id = ?",
                (now, row["id"]),
            )
            claimed = conn.execute(
                "SELECT * FROM attempts WHERE id = ?", (row["id"],)
            ).fetchone()
            conn.execute("COMMIT")
            return IngestQueue.row_to_dict(claimed)
        except Exception:
            conn.execute("ROLLBACK")
            raise


    @staticmethod
    def cancel_requested(conn, attempt_id):
        row = conn.execute(
            "SELECT cancel FROM attempts WHERE id = ?", (attempt_id,)
        ).fetchone()
        return bool(row and row["cancel"])


    @staticmethod
    def finish(conn, attempt_id, state, now, **fields):
        """행을 종결한다. 종결 뒤에는 아무도 이 행을 쓰지 않는다.

        🔴 요약(`failure_summary`)은 **여기 인자로 들어와야 한다.** 종결 후에 따로 붙이면
        "어느 실행의 요약인가"를 지키는 가드가 다시 필요해진다 — 이전 구조가 타임스탬프
        스탬프 비교를 달아야 했던 이유가 그것이다.
        """
        if state not in IngestQueue.TERMINAL_STATES:
            raise ValueError(f"종결 상태가 아닙니다: {state}")
        allowed = ("exit_code", "reason", "error", "document", "title", "channel",
                   "duration", "failure_summary", "failure_summary_error")
        unknown = set(fields) - set(allowed)
        if unknown:
            raise ValueError(f"모르는 필드입니다: {sorted(unknown)}")
        assignments = ", ".join(f"{name} = ?" for name in fields)
        sql = "UPDATE attempts SET state = ?, finished_at = ?"
        if assignments:
            sql += ", " + assignments
        sql += " WHERE id = ?"
        conn.execute(sql, (state, now, *fields.values(), attempt_id))


    @staticmethod
    def set_meta(conn, attempt_id, **fields):
        """진행 중에 드러난 표시용 메타(제목·채널·길이)만 갱신한다."""
        allowed = ("title", "channel", "duration")
        unknown = set(fields) - set(allowed)
        if unknown:
            raise ValueError(f"메타 필드가 아닙니다: {sorted(unknown)}")
        if not fields:
            return
        assignments = ", ".join(f"{name} = ?" for name in fields)
        conn.execute(
            f"UPDATE attempts SET {assignments} WHERE id = ? AND state = 'running'",
            (*fields.values(), attempt_id),
        )


# 부르는 쪽은 이 이름만 쓴다.
QUEUE = IngestQueue

# 저장 헬퍼. 러너와 같은 모듈을 읽는다 — 영수증의 모양을 아는 곳이 하나여야 한다.
PROVIDERS_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "providers.py")
_PROVIDERS_SPEC = importlib.util.spec_from_file_location("learning_providers", PROVIDERS_PATH)
PROVIDERS = importlib.util.module_from_spec(_PROVIDERS_SPEC)
_PROVIDERS_SPEC.loader.exec_module(PROVIDERS)

SAVE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "save_document.py")
_SAVE_SPEC = importlib.util.spec_from_file_location("learning_save_document", SAVE_PATH)
SAVE = importlib.util.module_from_spec(_SAVE_SPEC)
_SAVE_SPEC.loader.exec_module(SAVE)


def normalized_document(repo, relative):
    """영수증의 경로를 **목록이 쓰는 철자**로 맞춘다. 쓸 수 없는 경로면 None.

    🔴 여기서는 realpath 로 풀지 **않는다.** 적재 판정(`_verify_document`)은 두 경로가
    같은 파일인지를 묻기 때문에 realpath 로 맞대는 것이 맞지만, 이 함수가 답할 질문은
    다르다 — "목록의 어느 행에 배지를 붙이나". 목록을 만드는 스캐너는 `os.listdir` 로
    걷고 `isdir` 는 심볼릭 링크를 따라가므로, `ml -> topics/ml` 인 라이브러리에서 그
    문서는 목록에 **`ml/live.md` 로** 실린다(`topics/ml/live.md` 는 두 단계라 아예 안
    실린다). realpath 로 풀면 어느 행에도 안 붙고, 화면에서는 조용히 아무 일도 일어나지
    않은 것처럼 보인다.

    문법 검사를 저장 헬퍼에 위임하는 것은 같은 이유다 — 저장이 받는 경로와 목록이 쓰는
    경로가 같은 문법이어야 이 짝이 성립한다.
    """
    try:
        _target, candidate = SAVE.resolve_in_library(repo, relative)
    except SAVE.SaveError:
        return None
    return candidate


def attempt_document(state_dir, repo, record):
    """진행 중인 적재가 **지금까지 저장한** 문서. 없으면 None.

    🔴 근거는 로그 마커가 아니라 영수증이다. 마커는 스킬이 "다 했다" 고 말하는 자리라
    적재가 끝날 때만 나오고, 그때는 이미 목록에 문서가 있다. 영수증은 저장하는 순간
    기계가 쓰므로, 20분짜리 적재의 4분째에 "이 문서는 이미 여기 있다" 를 말할 수 있는
    유일한 신호다 — 그것이 이 화면 전체가 기대고 있는 것이다.
    """
    receipt = SAVE.read_receipt(QUEUE.receipt_path(state_dir, record["id"]))
    if not isinstance(receipt, dict) or receipt.get("schema") != SAVE.RECEIPT_SCHEMA:
        return None
    # 🔴 `path` 가 문자열이 아니면 여기서 멈춘다. 손으로 고친 영수증 하나가
    #    `/api/ingest` 를 통째로 죽였다 — 그 분기는 LearningManagerError 만 잡아서
    #    AttributeError 가 핸들러를 뚫고 나가 응답 없이 연결이 끊겼다(적대검증 실측).
    if not isinstance(receipt.get("path"), str):
        return None
    return normalized_document(repo, receipt.get("path")), receipt.get("phase")


def _now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def configured_paths():
    """환경 override를 매번 읽어 테스트와 unit 환경을 같은 코드로 태운다."""
    def absolute(value):
        return os.path.abspath(os.path.expanduser(value))

    return {
        "repo": absolute(env_first(
            "AIRLOCK_LEARNING_LIBRARY", "LEARNING_LIBRARY", "LEARNING_REPO",
            default=DEFAULT_LIBRARY)),
        # 걷어낸 것과 남긴 것의 경계: `AIRLOCK_LEARNING_PUBLIC_HTML`(접두사 있음)은
        # 뒀다가 지웠다 — 설치가 유닛을 매번 새로 쓰므로 읽을 이유가 없고, 선언되지
        # 않은 `AIRLOCK_LEARNING_*` 참조는 strict 설정 스캔이 오타와 구분할 수 없어
        # 거부한다. 무접두 `PUBLIC_HTML` 은 남긴다 — 패키지가 되기 전 배포본이 쓰던
        # 이름이고 스캔의 대상이 아니며, 유닛 아래에서는 SHARE_DIR 가 항상 이긴다.
        "public": absolute(env_first(
            "AIRLOCK_LEARNING_SHARE_DIR", "PUBLIC_HTML", default=DEFAULT_SHARE_DIR)),
        "state": absolute(env_first(
            "AIRLOCK_LEARNING_STATE_DIR", "STATE_DIR", default=DEFAULT_STATE_DIR)),
    }


class LearningManagerError(Exception):
    def __init__(self, message, code=500, *, command=None, exit_code=None, stderr="", state_unknown=False):
        super().__init__(message)
        self.message = message
        self.code = code
        self.command = command
        self.exit_code = exit_code
        self.stderr = stderr
        self.state_unknown = state_unknown

    def payload(self):
        body = {"error": self.message}
        if self.command is not None:
            body["command"] = self.command
        if self.exit_code is not None or self.command is not None:
            body["exit_code"] = self.exit_code
        if self.command is not None:
            body["stderr"] = self.stderr
        return body


class CollectionError(LearningManagerError):
    pass


class RequestError(LearningManagerError):
    pass


def manifest_command():
    return ["python3", "scripts/learn.py", "manifest", "--json"]


def is_git_library(root):
    """라이브러리가 마침 git 레포인가.

    git 은 **있으면 정렬이 좋아지는 옵션**이지 요구사항이 아니다. 없는 폴더에서
    git 을 불러 놓고 그 실패를 사용자에게 경고로 보여 주면, git 을 쓴 적도 없는
    사람에게 "fatal: not a git repository" 를 읽히게 된다.
    """
    return os.path.isdir(os.path.join(root, ".git")) or os.path.isfile(os.path.join(root, ".git"))


def is_category_dir(root, name):
    """카테고리 = 라이브러리 루트 바로 아래의 보통 디렉터리."""
    if not name or name.startswith(CATEGORY_SKIP_PREFIXES) or name in CATEGORY_SKIP_NAMES:
        return False
    if os.sep in name or "/" in name:
        return False
    return os.path.isdir(os.path.join(root, name))


def has_markdown(directory):
    try:
        return any(name.endswith(".md") for name in os.listdir(directory))
    except OSError:
        return False


def library_categories(root):
    try:
        entries = sorted(os.listdir(root))
    except OSError:
        return []
    return [name for name in entries if is_category_dir(root, name)]


FRONTMATTER_KEYS = ("title", "added", "video_id", "source", "channel", "duration",
                    "upload_date", "url",
                    # 별표와 보관은 **문서 안에** 산다(오너 결정 2, 2026-08-21). 라이브러리
                    # 폴더를 통째로 위키로 옮겨도 상태가 따라가야 하기 때문이다 — 상태가
                    # 앱의 state 디렉터리에만 있으면 그 순간 전부 사라진다.
                    "starred", "archived")
# 프론트매터를 다 파싱하지 않는다. 목록에 필요한 스칼라 키만 첫 블록에서 긁는다 —
# 라이브러리는 남의 파일이고, 이 앱이 YAML 을 재해석해서 얻을 것이 없다.
FRONTMATTER_LINE_RE = re.compile(r"\A([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*?)\s*\Z")
# 라이브러리 루트에 있어도 학습자료가 아닌 이름들. 특정 레포의 관습이 아니라
# 어디서나 같은 뜻인 파일만 넣는다 — 여기에 주제 이름을 추가하지 말 것.
ROOT_NON_DOCUMENTS = frozenset({
    "readme.md", "index.md", "changelog.md", "contributing.md", "license.md",
    "claude.md", "agents.md", "codex.md",
})
# 프론트매터의 줄 상한은 저장 헬퍼가 소유한다 — 읽는 쪽과 고치는 쪽이 같아야 한다.
FRONTMATTER_MAX_LINES = SAVE.FRONTMATTER_MAX_LINES
# 프론트매터와 첫 헤딩을 찾기 위해 읽는 바이트. 문서 전체를 읽지 않는다.
FRONTMATTER_READ_BYTES = 64 << 10
HEADING_RE = re.compile(r"\A#\s+(.+?)\s*\Z")
FILENAME_DATE_RE = re.compile(r"\A([0-9]{4}-[0-9]{2}-[0-9]{2})")


def unquote_scalar(raw):
    """YAML 스칼라 한 줄에서 값만 꺼낸다.

    🔴 `strip('"')` 로는 안 된다. 실측(2026-08-21, 자료 168건): 제목 9건이
    `title: "\"이걸 알게 되어…\" | 선행 없이…"` 처럼 **이스케이프된 따옴표를 품은
    쌍따옴표 스칼라**여서, 순진하게 벗기면 백슬래시가 남고 안쪽 따옴표가 하나 잘린다.
    전체 YAML 파서를 들이지 않고 실제로 나타나는 두 인용 방식만 정확히 푼다.
    """
    value = raw.strip()
    if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
        try:
            return json.loads(value)
        except ValueError:
            return value[1:-1]
    if len(value) >= 2 and value[0] == "'" and value[-1] == "'":
        return value[1:-1].replace("''", "'")
    return value


def truthy_scalar(value):
    """YAML 이 참으로 읽는 스칼라. 그 밖의 값(빈 문자열·None·"no")은 거짓이다."""
    return str(value).strip().lower() in ("true", "yes", "on", "1")


def read_front_matter(path):
    """(fields, first_heading, has_block).

    🔴 블록의 경계는 **저장 헬퍼가 정한다**(`SAVE.frontmatter_bounds`). 한때 여기에 두
    번째 파서가 있었고 — 디코드된 문자열을 utf-8-sig 로 읽고, 60줄 상한을 자기 방식으로
    세고, `str.strip()` 으로 울타리를 봤다 — 헬퍼는 원시 바이트를 봤다. 그 어긋남에서
    적대검증이 HIGH 세 건을 냈다: BOM 문서는 별표 버튼이 켜지는데 요청은 409 였고,
    울타리 끝의 NBSP 하나가 본문 줄을 프론트매터로 만들어 **덮어쓰게** 했고, 60줄 넘는
    프론트매터는 한쪽만 읽기 전용으로 봤다.

    `has_block` 을 따로 내는 이유: **프론트매터가 없는 것**과 **있는데 우리가 아는 키가
    하나도 없는 것**은 다르다. 둘 다 fields 가 빈 dict 라서 `bool(fields)` 로는 못 가른다.
    별표를 적을 수 있는 문서인가가 여기서 갈린다(카드 4단계).
    """
    try:
        with open(path, "rb") as handle:
            blob = handle.read(FRONTMATTER_READ_BYTES)
    except OSError:
        return {}, "", False

    fields = {}
    has_block = False
    block = SAVE.frontmatter_block(blob)
    if block is not None:
        has_block = True
        for raw in block.decode("utf-8", "replace").split("\n"):
            match = FRONTMATTER_LINE_RE.match(raw.rstrip("\r"))
            if match and match.group(1) in FRONTMATTER_KEYS:
                fields[match.group(1)] = unquote_scalar(match.group(2))

    # 제목은 프론트매터 밖의 첫 헤딩이다. 블록이 있으면 그 뒤부터, 없으면 처음부터 본다.
    text = blob
    if has_block:
        bounds = SAVE.frontmatter_bounds(blob)
        if bounds:
            text = b"\n".join(bounds[0][bounds[2] + 1:])
    text = text.decode("utf-8", "replace")
    heading = ""
    for index, raw in enumerate(text.split("\n")):
        if index >= FRONTMATTER_MAX_LINES:
            break
        match = HEADING_RE.match(raw.rstrip("\r"))
        if match:
            heading = match.group(1)
            break
    return fields, heading, has_block


def builtin_manifest(root):
    """레포도 스크립트도 없는 **그냥 폴더**를 목록으로 만든다.

    legacy producer(`scripts/learn.py manifest --json`)와 **같은 봉투**를 낸다 —
    그래야 normalize_manifest 가 어느 쪽에서 왔는지 몰라도 된다. 이 앱이 남의
    박스에서 화면을 그리기 위해 필요한 것은 결국 이 함수 하나였다.
    """
    items = []
    warnings = []

    def add(relative, full):
        fields, heading, has_block = read_front_matter(full)
        name = os.path.basename(relative)
        stem = name[:-3]
        added = fields.get("added") or ""
        if not added:
            match = FILENAME_DATE_RE.match(stem)
            if match:
                added = match.group(1)
        if not added:
            try:
                added = datetime.fromtimestamp(
                    os.stat(full).st_mtime, timezone.utc).date().isoformat()
            except OSError:
                added = ""
        html = relative[:-3] + ".html"
        items.append({
            "path": relative,
            "added": added,
            "title": fields.get("title") or heading or stem,
            "mutable": True,
            "html_path": html if os.path.isfile(os.path.join(root, html)) else None,
            "video_id": fields.get("video_id"),
            "source": fields.get("source"),
            "channel": fields.get("channel"),
            "duration": fields.get("duration"),
            # legacy producer 도 내는 필드. 프론트가 발행 링크 폴백으로 읽는다.
            "url": fields.get("url"),
            "topic": os.path.dirname(relative) or None,
            # 별표·보관은 이제 **문서가 정본**이다(카드 4단계). 한때 이 두 줄을 일부러
            # 빼 두었는데, 그때는 스냅샷이 값을 덮어써서 "파일에 적으면 먹는다" 가 거짓
            # 신호였기 때문이다. 지금은 참이다.
            "starred": truthy_scalar(fields.get("starred")),
            "archived": truthy_scalar(fields.get("archived")),
            # 상태를 적을 수 있는 문서인가. 프론트매터가 없으면 이 앱은 만들어 주지
            # 않는다 — 남의 문서를 수리하지 않는 것이 규칙이고, 그러면 별표 버튼도
            # 눌리지 않아야 한다. 눌리는데 409 가 나는 것은 UI 가 거짓말한 것이다.
            "state_writable": has_block,
        })

    try:
        for name in sorted(os.listdir(root)):
            full = os.path.join(root, name)
            if name.endswith(".md") and os.path.isfile(full):
                # `.md` 자체이거나 `.` 로 시작하는 파일은 문서가 아니다.
                if name.startswith(".") or name.lower() in ROOT_NON_DOCUMENTS:
                    continue
                add(name, full)
            elif (os.path.isdir(full) and not is_category_dir(root, name)
                  and name in CATEGORY_SKIP_NAMES and has_markdown(full)):
                # 🔴 조용히 숨기지 않는다. 이 이름들은 레포 인프라라서 거르는 건데,
                #    맨 폴더에서는 사용자가 진짜 카테고리로 쓸 수 있는 이름이기도 하다.
                #    문서가 실제로 들어 있을 때만 말한다 — 빈 scripts/ 는 소음이다.
                warnings.append(
                    f"{name}/ 안의 자료는 목록에서 빠졌습니다 — 이 이름은 라이브러리"
                    " 인프라 폴더로 취급됩니다. 카테고리로 쓰려면 폴더 이름을 바꾸십시오.")
            elif is_category_dir(root, name):
                try:
                    children = sorted(os.listdir(full))
                except OSError as exc:
                    warnings.append(f"{name}/ 를 읽지 못했습니다: {exc}")
                    continue
                for child in children:
                    child_full = os.path.join(full, child)
                    if (child.endswith(".md") and not child.startswith(".")
                            and os.path.isfile(child_full)):
                        add(f"{name}/{child}", child_full)
    except OSError as exc:
        raise CollectionError(f"라이브러리를 읽지 못했습니다: {root}: {exc}", 500) from exc

    return {"schema_version": 1, "repo_head": {}, "items": items, "warnings": warnings}


def provider_preference():
    return env_first("AIRLOCK_LEARNING_AGENT", default="auto").strip().lower()


def ingest_provider():
    """(provider, 실행파일, 사유). 없으면 (None, None, 사람이 읽을 사유)."""
    return PROVIDERS.select(provider_preference(), os.environ)


def ingest_supported(repo):
    """적재를 지금 이 라이브러리에서 끝낼 수 있나 — **git 은 더 이상 조건이 아니다.**

    한때는 `is_git_library()` 였다. 러너의 성공 판정이 `git rev-parse HEAD` 를 요구해서,
    git 이 아닌 폴더에서는 적재가 반드시 실패했기 때문이다 — 그것도 claude 를 수십 분
    돌린 뒤에. 판정이 파일 자체(`save_document.py` 의 영수증 + 지금 그 자리의 내용)로
    바뀌었으므로 그 게이트는 사라진다.

    남은 조건은 **쓸 수 있는 폴더인가** 하나다. 읽기 전용 폴더에서 적재를 받으면 실패는
    여전히 수십 분 뒤에 온다.
    """
    return os.path.isdir(repo) and os.access(repo, os.W_OK | os.X_OK)


def listing_provider():
    value = env_first("AIRLOCK_LEARNING_LISTING", "LEARNING_LISTING_PROVIDER",
                      default="auto").strip().lower()
    return value if value in ("auto", "builtin", "legacy") else "auto"


def has_legacy_producer(root):
    return os.path.isfile(os.path.join(root, "scripts", "learn.py"))


def decode_output(data, limit):
    if not data:
        return ""
    text = data[:limit].decode("utf-8", errors="replace")
    if len(data) > limit:
        text += "\n[출력이 너무 길어 일부만 표시했습니다]"
    return text


def safe_relative(value, label="path", error_type=RequestError):
    """repo-relative POSIX 경로만 허용한다."""
    if not isinstance(value, str) or not value:
        raise error_type(f"{label}이(가) 없습니다", 400)
    if "\x00" in value or "\\" in value:
        raise error_type(f"{label} 형식이 아닙니다", 400)
    if value.startswith("/") or os.path.isabs(value):
        raise error_type(f"{label}은 절대경로일 수 없습니다", 400)
    parts = value.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise error_type(f"{label}에 경로 조작이 있습니다", 400)
    if posixpath.normpath(value) != value:
        raise error_type(f"{label}이 정규화된 상대경로가 아닙니다", 400)
    return value


def is_under(path, root):
    try:
        return os.path.commonpath([os.path.realpath(path), os.path.realpath(root)]) == os.path.realpath(root)
    except ValueError:
        return False


def repo_path(repo, relative, *, error_type=CollectionError):
    relative = safe_relative(relative, "manifest path", error_type)
    candidate = os.path.abspath(os.path.join(repo, *relative.split("/")))
    if not is_under(candidate, repo):
        raise error_type(f"manifest path가 learning 레포 밖입니다: {relative}", 500)
    resolved = os.path.realpath(candidate)
    if not is_under(resolved, repo):
        raise error_type(f"manifest path 심링크가 learning 레포 밖입니다: {relative}", 500)
    return candidate


def slug_for(item):
    path = item["path"]
    video_id = item.get("video_id")
    if not video_id:
        raise CollectionError(f"video_id가 없어 canonical 이름을 만들 수 없습니다: {path}", 500)
    filename = posixpath.basename(path)
    stem = filename[:-3] if filename.endswith(".md") else filename
    suffix = "--" + str(video_id)
    if stem.endswith(suffix):
        stem = stem[:-len(suffix)]
    date_prefix = ""
    if len(stem) >= 12 and stem[4] == "-" and stem[7] == "-" and stem[10:12] == "--":
        date_prefix = stem[:12]
    if date_prefix:
        stem = stem[12:]
    if not stem or "/" in stem or "\\" in stem or "\x00" in stem:
        raise CollectionError(f"canonical slug을 만들 수 없습니다: {path}", 500)
    return stem


def canonical_name(item):
    return f"learning-{slug_for(item)}-{item['video_id']}.html"


def sibling_name(item):
    """문서끼리 잇는 링크가 쓰는 이름 = **레포 파일명 그대로.**

    🔴 왜 이름이 둘인가 — 발행 이름(`canonical_name`)은 `learning-<슬러그>-<영상ID>.html` 로
    평평하다. 그런데 문서 안의 `## 관련 학습자료` 는 **레포 기준 형제 파일명**
    (`<날짜>--<슬러그>--<영상ID>.html`)을 가리킨다. 레포에서는 같은 폴더라 열리지만 발행
    경로에는 그 이름이 없어서 **전부 404 였다**(실측 2026-08-21: 문서간 링크 562개 중 562개,
    문서 173건 중 162건). 레포에서 열면 멀쩡하고 발행본에서 눌러본 사람이 없어 오래 안 잡혔다.

    canonical 을 이 이름으로 **바꾸지 않는다** — 이미 나간 발행 URL 이 전부 죽는다.
    대신 같은 파일을 가리키는 심링크를 하나 더 둔다. 회수는 `unpublish_path` 가 그 문서의
    살아있는 alias 를 전부 지우므로 자동으로 짝이 맞는다.
    """
    # 🔴 `path`(마크다운)가 아니라 **`html_path`** 다. 링크가 가리키는 것은 발행본이다.
    #    (첫 판이 `path` 를 써서 `.md` 이름으로 심링크를 걸 뻔했고, 게이트가 잡았다.)
    return os.path.basename(item["html_path"])


def ensure_sibling_alias(public_html, item, source):
    """레포 파일명 심링크를 보장한다. 만들었으면 이름을, 이미 맞으면 None 을 돌려준다.

    이미 발행된 문서에도 붙일 수 있도록 **멱등**하게 둔다 — 그래야 backfill 이 발행 API
    재호출만으로 끝난다.
    """
    name = sibling_name(item)
    if not name or os.path.basename(name) != name:
        raise RequestError(f"sibling 이름이 안전하지 않습니다: {name}", 409)
    if name == item.get("canonical_name"):
        return None                      # 두 규칙이 같아졌다면 더 만들 것이 없다
    target = os.path.join(public_html, name)
    if os.path.lexists(target):
        # 같은 문서를 가리키면 할 일이 없다. 다른 것을 가리키면 **조용히 넘기지 않는다.**
        if os.path.islink(target) and os.path.realpath(target) == source:
            return None
        raise RequestError(
            f"sibling 이름이 이미 다른 것을 가리킵니다: {name}", 409)
    try:
        os.symlink(source, target)
    except FileExistsError:
        return None                      # 동시에 생겼다 — 위 검사와 같은 결론이면 문제없다
    except OSError as exc:
        raise LearningManagerError(f"sibling 심링크를 만들지 못했습니다: {exc}", 500) from exc
    if not (os.path.islink(target) and os.path.realpath(target) == source):
        try:
            os.unlink(target)
        except OSError:
            pass
        raise LearningManagerError("sibling 심링크 검증에 실패했습니다", 500)
    return name


def run_manifest(repo):
    command = manifest_command()
    script = os.path.join(repo, "scripts", "learn.py")
    if not os.path.isfile(script):
        raise CollectionError(
            f"learn.py 파일이 없습니다: {script}", 500,
            command=command, exit_code=None,
        )
    if not is_under(script, repo):
        raise CollectionError(
            f"learn.py가 learning 레포 밖의 심링크입니다: {script}", 500,
            command=command, exit_code=None,
        )

    try:
        # stdout/stderr를 PIPE로 전부 메모리에 쌓지 않는다. stdout은 임시 파일에 흘려
        # 보관하고, 검증 시 허용량보다 한 바이트 더 읽어 상한을 판정한다.
        with tempfile.TemporaryFile() as stdout_file, tempfile.TemporaryFile() as stderr_file:
            proc = subprocess.Popen(
                command,
                cwd=repo,
                shell=False,
                stdin=subprocess.DEVNULL,
                stdout=stdout_file,
                stderr=stderr_file,
            )
            try:
                proc.communicate(timeout=MANIFEST_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired as exc:
                proc.kill()
                proc.communicate()
                stderr_file.seek(0)
                detail = decode_output(stderr_file.read(MANIFEST_STDERR_MAX_BYTES + 1), MANIFEST_STDERR_MAX_BYTES)
                raise CollectionError(
                    "manifest 명령이 제한 시간 안에 끝나지 않았습니다", 500,
                    command=command, exit_code=proc.returncode, stderr=detail,
                ) from exc
            stdout_file.seek(0)
            stdout = stdout_file.read(MANIFEST_STDOUT_MAX_BYTES + 1)
            stderr_file.seek(0)
            stderr = stderr_file.read(MANIFEST_STDERR_MAX_BYTES + 1)
    except OSError as exc:
        raise CollectionError(
            f"manifest 명령을 실행하지 못했습니다: {exc}", 500,
            command=command, exit_code=None,
        ) from exc

    if len(stdout) > MANIFEST_STDOUT_MAX_BYTES:
        raise CollectionError(
            f"manifest stdout가 허용 크기를 초과했습니다: {len(stdout)} bytes", 500,
            command=command, exit_code=proc.returncode,
            stderr=decode_output(stderr, MANIFEST_STDERR_MAX_BYTES),
        )

    stderr_text = decode_output(stderr, MANIFEST_STDERR_MAX_BYTES)
    if stderr:
        raise CollectionError(
            "manifest 명령이 stderr를 출력했습니다", 500,
            command=command, exit_code=proc.returncode, stderr=stderr_text,
        )
    if proc.returncode != 0:
        raise CollectionError(
            f"manifest 명령이 exit {proc.returncode}로 끝났습니다", 500,
            command=command, exit_code=proc.returncode,
        )

    try:
        raw = stdout.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise CollectionError(
            f"manifest stdout가 UTF-8이 아닙니다: {exc}", 500,
            command=command, exit_code=proc.returncode,
        ) from exc
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise CollectionError(
            f"manifest stdout JSON을 해석하지 못했습니다: {exc.msg}", 500,
            command=command, exit_code=proc.returncode,
        ) from exc
    return data


def validate_manifest_item_contract(index, raw_item):
    if not isinstance(raw_item, dict):
        raise CollectionError(
            f"manifest item[{index}] 타입이 {type(raw_item).__name__}입니다; object여야 합니다", 500,
        )

    required_fields = {
        "path": "문자열(str)",
        "added": "문자열(str)",
        "title": "문자열(str)",
        "mutable": "bool",
    }
    for field, expected in required_fields.items():
        if field not in raw_item:
            raise CollectionError(
                f"manifest item[{index}].{field} 필드가 없습니다; {expected}이어야 합니다", 500,
            )
        value = raw_item[field]
        valid = type(value) is bool if field == "mutable" else isinstance(value, str)
        if not valid:
            raise CollectionError(
                f"manifest item[{index}].{field} 타입이 {type(value).__name__}입니다; "
                f"{expected}이어야 합니다", 500,
            )

    if "html_path" not in raw_item:
        raise CollectionError(
            f"manifest item[{index}].html_path 필드가 없습니다; 문자열(str) 또는 None이어야 합니다", 500,
        )
    html_path = raw_item["html_path"]
    if html_path is not None and not isinstance(html_path, str):
        raise CollectionError(
            f"manifest item[{index}].html_path 타입이 {type(html_path).__name__}입니다; "
            "문자열(str) 또는 None이어야 합니다", 500,
        )


def normalize_manifest(data, repo):
    if not isinstance(data, dict):
        raise CollectionError("manifest 최상위 값이 JSON object가 아닙니다", 500)
    if type(data.get("schema_version")) is not int or data["schema_version"] != 1:
        raise CollectionError("manifest schema_version이 1이 아닙니다", 500)
    if not isinstance(data.get("repo_head"), dict):
        raise CollectionError("manifest repo_head가 없습니다", 500)
    if not isinstance(data.get("items"), list):
        raise CollectionError("manifest items가 배열이 아닙니다", 500)
    if not isinstance(data.get("warnings"), list):
        raise CollectionError("manifest warnings가 배열이 아닙니다", 500)

    raw_items = data["items"]
    for index, raw_item in enumerate(raw_items):
        validate_manifest_item_contract(index, raw_item)

    video_counts = {}
    for index, raw_item in enumerate(raw_items):
        video_id = raw_item.get("video_id")
        if video_id:
            try:
                video_counts[video_id] = video_counts.get(video_id, 0) + 1
            except TypeError as exc:
                raise CollectionError(
                    f"manifest item[{index}].video_id 타입이 {type(video_id).__name__}입니다; "
                    "hashable 값이어야 합니다", 500,
                ) from exc

    items = []
    by_path = {}
    for raw_item in raw_items:
        path = safe_relative(raw_item.get("path"), "manifest path", CollectionError)
        if path in by_path:
            raise CollectionError(f"manifest path가 중복됩니다: {path}", 500)
        html_path = raw_item.get("html_path")
        if html_path is not None:
            html_path = safe_relative(html_path, "manifest html_path", CollectionError)
            repo_path(repo, html_path, error_type=CollectionError)

        item = dict(raw_item)
        item["path"] = path
        item["html_path"] = html_path
        video_id = item.get("video_id")
        source = item.get("source")
        eligible = (
            bool(video_id)
            and video_counts.get(video_id, 0) == 1
            and html_path is not None
            and source == "youtube"
        )
        item["mutable"] = item["mutable"] and eligible
        if item["mutable"]:
            item["canonical_name"] = canonical_name(item)
        by_path[path] = item
        items.append(item)

    # `added` 는 **날짜**다. 하루에 여러 건을 적재하면 순서가 갈리지 않아 방금 넣은 자료가
    # 알파벳 순서에 묻힌다(실측: 같은 날 7건). 그래서 **적재된 커밋 시각**으로 순서를 만든다.
    warnings = list(data["warnings"])
    changed, change_warning = change_times(repo)
    if change_warning:
        warnings.append(change_warning)
    for item in items:
        item["changed_at"] = changed.get(item["path"], "")

    items.sort(key=lambda value: value["path"])
    items.sort(key=lambda value: value["added"], reverse=True)
    # 시각을 모르는 항목(미커밋·git 조회 실패)은 `added` 순서를 그대로 유지한다 — sort 가
    # 안정적이라 빈 문자열끼리는 위 순서가 살아 있다.
    items.sort(key=lambda value: value["changed_at"] or "", reverse=True)
    return {
        "schema_version": 1,
        "repo_head": data["repo_head"],
        "warnings": warnings,
        "items": items,
        "by_path": by_path,
    }


def change_times(repo):
    """항목별 **적재 커밋** 시각(ISO). (map, 경고) 를 돌려준다 — 실패를 조용히 삼키지 않는다.

    git 한 번으로 레포 전체를 훑는다(항목당 호출 X). 파일이 여러 커밋에 나오면 **처음
    만난 것**이 가장 최근이다 — `git log` 가 최신순이라서다.

    🔴 마지막 커밋이 아니라 **파일이 추가된 커밋**(`--diff-filter=A`)을 본다. 적재 1건은
    자기 문서만 만드는 게 아니라 **관련 옛 문서의 역링크도 함께 편집**한다 — 마지막 커밋을
    쓰면 그 옛 문서들이 신규 적재와 같은 시각을 얻어 목록 상단에 끼어들고(실측 2026-08-07
    #120: 역링크만 바뀐 2건이 동반 상승), 재부상(`resurfaced.json`) 으로 올려둔 문서도
    무관한 역링크 커밋에 덮여 다시 내려갔다.
    `--no-renames` 는 파일을 옮겨도 새 경로가 A 로 잡히게 한다 — 없으면 R 로 나와
    그 항목만 시각을 잃는다.
    """
    # 🔴 quotepath 를 끄지 않으면 한글 경로가 `"engineering/\355\201..."` 로 나와 매칭이 어긋난다 —
    #    하필 한글 제목 자료가 최신인 경우가 많아, 최신변경순이 그 항목만 맨 아래로 보낸다(실측).
    if not is_git_library(repo):
        # git 라이브러리가 아니다. 경고도 내지 않는다 — 이건 실패가 아니라 구성이다.
        return {}, None
    command = [
        "git", "-c", "core.quotepath=false", "-C", repo,
        "log", "--format=%cI", "--name-only", "--diff-filter=A", "--no-renames",
        # `--root` 없으면 최초 커밋의 diff 가 안 나와 거기 들어간 문서만 시각을 잃는다.
        "--root", "--", "*.md",
    ]
    try:
        result = subprocess.run(
            command,
            shell=False,
            capture_output=True,
            text=True,
            timeout=GIT_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {}, f"변경 시각을 읽지 못해 최신변경순 정렬이 날짜 기준으로 내려갔습니다: {exc}"
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        return {}, (
            "변경 시각 조회가 exit "
            f"{result.returncode}로 끝나 최신변경순 정렬이 날짜 기준으로 내려갔습니다"
            + (f": {detail[:200]}" if detail else "")
        )
    times = {}
    stamp = ""
    for line in result.stdout.splitlines():
        if not line:
            continue
        if STAMP_RE.fullmatch(line):
            stamp = line
        elif stamp and line not in times:
            times[line] = stamp
    return times, None


def collect_manifest():
    repo = configured_paths()["repo"]
    provider = listing_provider()
    # auto = 기존 라이브러리(스크립트가 있음)는 그대로 두고, 맨 폴더는 내장으로 연다.
    # 🔴 legacy 를 골랐는데 실패하면 **조용히 내장으로 넘어가지 않는다** — 목록의 의미가
    #    말없이 바뀌는 것이 빈 목록보다 나쁘다.
    if provider == "builtin" or (provider == "auto" and not has_legacy_producer(repo)):
        return normalize_manifest(builtin_manifest(repo), repo)
    data = run_manifest(repo)
    try:
        return normalize_manifest(data, repo)
    except CollectionError as exc:
        # stdout 이후의 계약 검증 실패도 실행한 고정 argv와 exit code를 함께 돌려준다.
        if exc.command is None:
            exc.command = manifest_command()
            exc.exit_code = 0
            exc.stderr = ""
        raise


def worktree_roots(repo):
    if not is_git_library(repo):
        # 워크트리 개념이 없는 폴더다. 라이브러리 자신이 유일한 뿌리다.
        return [(os.path.realpath(repo), "main")]
    command = ["git", "-C", repo, "worktree", "list", "--porcelain"]
    try:
        result = subprocess.run(
            command,
            shell=False,
            capture_output=True,
            text=True,
            timeout=GIT_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise LearningManagerError(
            f"git worktree 목록을 읽지 못했습니다: {exc}", 500,
        ) from exc
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise LearningManagerError(
            f"git worktree 목록이 exit {result.returncode}로 끝났습니다"
            + (f": {detail[:400]}" if detail else ""), 500,
        )
    roots = [(os.path.realpath(repo), "main")]
    for line in result.stdout.splitlines():
        if line.startswith("worktree "):
            root = os.path.realpath(line[9:].strip())
            origin = "main" if root == os.path.realpath(repo) else "worktree"
            if (root, origin) not in roots:
                roots.append((root, origin))
    return roots


def classify_target(resolved, roots):
    resolved = os.path.realpath(resolved)
    candidates = []
    for root, origin in roots:
        try:
            relative = os.path.relpath(resolved, root)
        except ValueError:
            continue
        if relative == "." or relative == ".." or relative.startswith(".." + os.sep):
            continue
        parts = relative.split(os.sep)
        # 자료는 카테고리 폴더 안(`<폴더>/x.md`) 또는 평평한 라이브러리의 루트(`x.md`)에 산다.
        # 두 단계보다 깊으면 이 앱의 자료가 아니다 — 폴더가 유일한 분류축이기 때문이다.
        #
        # 🔴 확장자로 거르지 않는다. 이 함수는 **발행 심링크의 대상**도 분류하는데 그건
        #    `.md` 가 아니라 `.html` 이다. `.md` 만 받으면 평평한 라이브러리의 루트 문서는
        #    발행 직후 재스캔에서 분류에 실패해 500 으로 롤백된다 — 폴더 안 문서는 되고
        #    루트 문서만 안 되는 비대칭이 생긴다(depth-2 분기는 원래 확장자를 안 본다).
        if len(parts) == 1:
            candidates.append((len(root), root, origin, parts[0]))
        elif len(parts) == 2 and is_category_dir(root, parts[0]):
            candidates.append((len(root), root, origin, "/".join(parts)))
    if not candidates:
        return None
    _, root, origin, relative = max(candidates, key=lambda value: value[0])
    return {"root": root, "origin": origin, "relative": relative}


def add_attention(scan, entry):
    key = (entry.get("reason"), entry.get("name"), entry.get("path"), entry.get("target"))
    if key not in scan["attention_keys"]:
        scan["attention_keys"].add(key)
        scan["needs_attention"].append(entry)


def scan_links(repo, public_html, manifest):
    roots = worktree_roots(repo)
    scan = {
        "roots": roots,
        "entries": {},
        "aliases": {},
        "conflicts": {},
        "needs_attention": [],
        "attention_keys": set(),
    }
    html_to_path = {
        item["html_path"]: item["path"]
        for item in manifest["items"]
        if item.get("html_path")
    }

    if not os.path.lexists(public_html):
        try:
            os.makedirs(public_html, mode=0o755, exist_ok=True)
        except OSError as exc:
            raise LearningManagerError(
                f"공유 디렉터리를 만들지 못했습니다: {public_html}: {exc}", 500,
            ) from exc
    if not os.path.isdir(public_html):
        raise LearningManagerError(f"공유 디렉터리가 디렉터리가 아닙니다: {public_html}", 500)

    try:
        entries = sorted(os.scandir(public_html), key=lambda entry: entry.name)
        for entry in entries:
            full = entry.path
            try:
                info = os.lstat(full)
            except FileNotFoundError:
                continue
            if not stat.S_ISLNK(info.st_mode):
                continue
            target = os.readlink(full)
            resolved = os.path.realpath(full)
            jurisdiction = classify_target(resolved, roots)
            associated_path = jurisdiction and html_to_path.get(jurisdiction["relative"])
            record = {
                "name": entry.name,
                "target": target,
                "resolved": resolved,
                "origin": jurisdiction["origin"] if jurisdiction else None,
                "relative": jurisdiction["relative"] if jurisdiction else None,
                "associated_path": associated_path,
                "live": os.path.isfile(resolved),
            }
            scan["entries"][entry.name] = record
            if associated_path:
                scan["aliases"].setdefault(associated_path, []).append(record)
                if not record["live"]:
                    add_attention(scan, {
                        "name": entry.name,
                        "path": associated_path,
                        "target": target,
                        "reason": "dangling",
                    })
                if record["origin"] == "worktree":
                    add_attention(scan, {
                        "name": entry.name,
                        "path": associated_path,
                        "target": target,
                        "reason": "worktree_target",
                    })
            elif jurisdiction:
                add_attention(scan, {
                    "name": entry.name,
                    "target": target,
                    "reason": "unmapped_learning_target",
                })
    except OSError as exc:
        raise LearningManagerError(f"공유 디렉터리의 심링크를 스캔하지 못했습니다: {exc}", 500) from exc

    # canonical 자리를 별도로 확인한다. prefix로 관할을 추측하지 않고 실제 entry를 본다.
    for item in manifest["items"]:
        name = item.get("canonical_name")
        if not name:
            continue
        full = os.path.join(public_html, name)
        if not os.path.lexists(full):
            continue
        record = scan["entries"].get(name)
        if record is None:
            reason = "canonical_direct_file"
            scan["conflicts"][item["path"]] = reason
            add_attention(scan, {"name": name, "path": item["path"], "reason": reason})
            continue
        if record.get("associated_path") != item["path"]:
            reason = "canonical_other_document"
            scan["conflicts"][item["path"]] = reason
            add_attention(scan, {
                "name": name,
                "path": item["path"],
                "target": record.get("target"),
                "reason": reason,
            })

    return scan


def read_state(state_dir):
    path = os.path.join(state_dir, "state.json")
    if not os.path.lexists(path):
        return {}
    try:
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode):
            raise LearningManagerError(f"상태 파일이 일반 파일이 아닙니다: {path}", 500)
        with open(path, "r", encoding="utf-8") as stream:
            data = json.load(stream)
    except LearningManagerError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise LearningManagerError(f"보관 상태 JSON을 읽지 못했습니다: {exc}", 500) from exc
    if not isinstance(data, dict):
        raise LearningManagerError("보관 상태 JSON의 최상위 값이 object가 아닙니다", 500)
    state = {}
    for key, value in data.items():
        safe_relative(key, "상태 path", LearningManagerError)
        if value is not True:
            raise LearningManagerError(f"보관 상태 값이 true가 아닙니다: {key}", 500)
        state[key] = True
    return state


def write_state(state_dir, state):
    try:
        write_json_atomic(
            os.path.join(state_dir, "state.json"),
            {key: True for key in sorted(state)},
        )
    except OSError as exc:
        raise LearningManagerError(f"보관 상태를 원자 저장하지 못했습니다: {exc}", 500) from exc


def read_starred(state_dir):
    path = os.path.join(state_dir, "starred.json")
    if not os.path.lexists(path):
        return {}
    try:
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode):
            raise LearningManagerError(f"별표 상태 파일이 일반 파일이 아닙니다: {path}", 500)
        with open(path, "r", encoding="utf-8") as stream:
            data = json.load(stream)
    except LearningManagerError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise LearningManagerError(f"별표 상태 JSON을 읽지 못했습니다: {exc}", 500) from exc
    if not isinstance(data, dict):
        raise LearningManagerError("별표 상태 JSON의 최상위 값이 object가 아닙니다", 500)
    starred = {}
    for key, value in data.items():
        try:
            safe_relative(key, "별표 상태 path", LearningManagerError)
        except LearningManagerError as exc:
            raise LearningManagerError(exc.message, 500) from exc
        if value is not True:
            raise LearningManagerError(f"별표 상태 값이 true가 아닙니다: {key}", 500)
        starred[key] = True
    return starred


def write_starred(state_dir, starred):
    try:
        write_json_atomic(
            os.path.join(state_dir, "starred.json"),
            {key: True for key in sorted(starred)},
        )
    except OSError as exc:
        raise LearningManagerError(f"별표 상태를 원자 저장하지 못했습니다: {exc}", 500) from exc


def read_resurfaced(state_dir):
    """재부상 상태 — {path: ISO 시각}. 이미 적재된 영상을 다시 넣으면 그 문서를 목록
    맨 위로 올리기 위해 마지막 재부상 시각을 남긴다."""
    path = os.path.join(state_dir, "resurfaced.json")
    if not os.path.lexists(path):
        return {}
    try:
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode):
            raise LearningManagerError(f"재부상 상태 파일이 일반 파일이 아닙니다: {path}", 500)
        with open(path, "r", encoding="utf-8") as stream:
            data = json.load(stream)
    except LearningManagerError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise LearningManagerError(f"재부상 상태 JSON을 읽지 못했습니다: {exc}", 500) from exc
    if not isinstance(data, dict):
        raise LearningManagerError("재부상 상태 JSON의 최상위 값이 object가 아닙니다", 500)
    resurfaced = {}
    for key, value in data.items():
        safe_relative(key, "재부상 상태 path", LearningManagerError)
        if not isinstance(value, str) or not STAMP_RE.fullmatch(value):
            raise LearningManagerError(f"재부상 시각이 ISO 형식이 아닙니다: {key}", 500)
        resurfaced[key] = value
    return resurfaced


def write_resurfaced(state_dir, resurfaced):
    try:
        write_json_atomic(
            os.path.join(state_dir, "resurfaced.json"),
            {key: resurfaced[key] for key in sorted(resurfaced)},
        )
    except OSError as exc:
        raise LearningManagerError(f"재부상 상태를 원자 저장하지 못했습니다: {exc}", 500) from exc


@contextmanager
def state_lock(state_dir):
    """보관 상태(starred·resurfaced·manifest 캐시)용 lock.

    🔴 **적재 큐는 더 이상 이 lock 을 쓰지 않는다.** 큐의 직렬화는 워커가 하나라는 사실이
    하고, 두 프로세스 사이의 쓰기 조율은 SQLite 가 한다. 예전에 적재가 이 lock 을 함께
    쓰면서 러너가 같은 파일을 새 fd 로 재획득해 자기 락에 막히는 데드락이 났다.
    """
    try:
        os.makedirs(state_dir, mode=0o700, exist_ok=True)
        lock_path = os.path.join(state_dir, ".lock")
        with open(lock_path, "a+", encoding="utf-8") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
    except LearningManagerError:
        raise
    except OSError as exc:
        raise LearningManagerError(f"보관 상태 lock을 열지 못했습니다: {exc}", 500) from exc


def write_json_atomic(path, payload):
    """JSON을 임시 파일에 fsync한 뒤 교체한다.

    보관 상태와 적재 spool 상태가 같은 원자 저장 경계를 사용한다. 디렉터리 fsync을
    지원하지 않는 파일시스템의 알려진 errno만 허용하고, 그 밖의 실패는 표면화한다.
    """
    directory = os.path.dirname(path)
    temporary = None
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=".json-", suffix=".tmp", dir=directory)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, ensure_ascii=False, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
        try:
            directory_fd = os.open(directory, os.O_RDONLY)
            try:
                try:
                    os.fsync(directory_fd)
                except OSError as exc:
                    if exc.errno not in (errno.EINVAL, errno.ENOTSUP):
                        raise
            finally:
                os.close(directory_fd)
        except OSError:
            raise
    except BaseException:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass
        raise


def validate_youtube_url(value):
    if not isinstance(value, str):
        raise RequestError("url이 없습니다", 400)
    url = value.strip()
    if not url or len(url) > 2048:
        raise RequestError("url이 비어 있거나 너무 깁니다", 400)
    if any(ord(char) < 0x20 or ord(char) == 0x7F for char in url):
        raise RequestError("url에 제어문자가 있습니다", 400)
    if any(char.isspace() for char in url):
        raise RequestError("url에 공백이 있습니다", 400)
    try:
        parsed = urlsplit(url)
        hostname = (parsed.hostname or "").lower().rstrip(".")
        has_port = parsed.port is not None
        has_credentials = parsed.username is not None or parsed.password is not None
    except ValueError as exc:
        raise RequestError("url 형식을 해석하지 못했습니다", 400) from exc
    if parsed.scheme.lower() not in ("http", "https") or not parsed.netloc:
        raise RequestError("유튜브 http(s) URL만 받을 수 있습니다", 400)
    if hostname not in YOUTUBE_HOSTS or has_port or has_credentials:
        raise RequestError("유튜브 URL만 받을 수 있습니다", 400)
    if not parsed.path.strip("/") and not parsed.query:
        raise RequestError("유튜브 영상 URL이 아닙니다", 400)
    return url


def video_id_from_url(url):
    """정상 YouTube ID는 그대로 쓰고, 비정상 쿼리도 안전한 식별자로 보존한다."""
    parsed = urlsplit(url)
    hostname = (parsed.hostname or "").lower().rstrip(".")
    candidate = ""
    if hostname in {"youtu.be", "www.youtu.be"}:
        candidate = parsed.path.strip("/").split("/", 1)[0]
    else:
        query = parse_qs(parsed.query, keep_blank_values=True)
        if query.get("v"):
            candidate = query["v"][0]
        if not candidate:
            parts = [part for part in parsed.path.split("/") if part]
            if len(parts) >= 2 and parts[0].lower() in {"shorts", "embed", "live"}:
                candidate = parts[1]
    candidate = unquote(candidate)
    if not candidate:
        raise RequestError("유튜브 영상 ID를 찾을 수 없습니다", 400)
    if VIDEO_ID_RE.fullmatch(candidate):
        return candidate
    # URL 검증은 통과했지만 셸 메타문자 등이 들어온 경우도 셸을 거치지 않고
    # 처리할 수 있도록 URL 자체의 비밀 없는 digest를 내부 중복 키로 쓴다.
    return "url-" + hashlib.sha256(url.encode("utf-8")).hexdigest()[:32]


def _ingested_manifest_item(video_id):
    """manifest 에서 같은 영상의 항목을 찾는다. (manifest, item|None) 을 돌려준다."""
    manifest = collect_manifest()
    for item in manifest["items"]:
        if str(item.get("video_id") or "") == video_id:
            return manifest, item
    return manifest, None


def anthropic_account_diagnostic():
    """Anthropic 설정의 존재 여부만 보고 실행 계정 위험을 진단한다."""
    configured = any(
        name in os.environ
        for name in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL")
    )
    if configured:
        return "종량 과금 위험 — 실행이 거부됩니다"
    return "구독 (API 키 미주입)"


def _open_queue():
    """요청마다 연결을 연다. SQLite 연결은 싸고, 오래 들고 있으면 그것이 곧 락 문제가 된다."""
    return QUEUE.connect(configured_paths()["state"])


def _view(record, include_log=False):
    """DB 행 → 화면이 읽는 모양. **여기가 유일한 번역 지점이다.**

    저장하는 것은 `state` 5개뿐이고, 화면의 `cancelling` 은 `running` + 취소요청의
    파생 표시다. 파생을 저장하지 않으므로 "취소 중인데 이미 끝난" 조합이 생기지 않는다.
    """
    if record is None:
        raise RequestError("적재 요청을 찾을 수 없습니다", 404)
    view = dict(record)
    view["status"] = "cancelling" if record["cancelling"] else record["state"]
    # 진행 중인 적재도 이미 문서를 남겼을 수 있다. 남겼으면 화면은 큐 카드 대신 그
    # 문서의 행에 배지를 붙인다 — 같은 것이 두 자리에 있으면 하나는 거짓말이다.
    # 🔴 `queued` 는 아직 시작도 안 했으므로 무엇도 저장했을 수 없다. `running` 만 본다 —
    #    "아직 안 한 일의 증거" 를 읽을 자리를 아예 만들지 않는다.
    if record["state"] == "running" and not view.get("document"):
        paths = configured_paths()
        found = attempt_document(paths["state"], paths["repo"], record)
        if found and found[0]:
            view["document"], view["phase"] = found
    if include_log:
        view["log"] = _read_log(record["id"])
    return view


def _read_log(attempt_id, limit=INGEST_LOG_VIEW_BYTES):
    path = QUEUE.log_path(configured_paths()["state"], attempt_id)
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError:
        return ""
    if len(data) > limit:
        data = data[-limit:]
    return data.decode("utf-8", "replace")


def _attempt_id(value):
    try:
        number = int(str(value).strip())
    except (TypeError, ValueError):
        raise RequestError("적재 id 형식이 아닙니다", 400)
    if number <= 0:
        raise RequestError("적재 id 형식이 아닙니다", 400)
    return number


def _assert_video_available(conn, video_id):
    """같은 영상이 큐에 살아 있으면 거부하고, 이미 적재됐으면 재부상 대상으로 돌려준다.

    근거는 **큐와 manifest** 둘뿐이다. manifest 중복은 409 가 아니다 — 이미 적재된 영상을
    다시 넣는 것은 "기존 문서를 목록 맨 위로 올려 달라"는 뜻으로 받는다.
    """
    if video_id in QUEUE.active_video_ids(conn):
        raise RequestError(f"video_id가 이미 큐에 있습니다: {video_id}", 409)
    return _ingested_manifest_item(video_id)


def create_ingest_plan(url):
    """계획은 **서버 상태가 아니다** — 검증하고 확인 다이얼로그가 보여줄 값만 돌려준다."""
    url = validate_youtube_url(url)
    video_id = video_id_from_url(url)
    paths = configured_paths()
    conn = _open_queue()
    try:
        _, item = _assert_video_available(conn, video_id)
    finally:
        conn.close()
    plan = {
        "url": url,
        "video_id": video_id,
        "cwd": paths["repo"],
        "execution": "/learning-ingest",
        "account": anthropic_account_diagnostic(),
    }
    if item is not None:
        plan.update({
            "duplicate": True,
            "existing_path": item["path"],
            "existing_title": item.get("title", ""),
        })
    return plan


def create_ingest_run(url):
    """URL 하나로 큐에 넣는다 — 승인은 클라이언트가 사람에게 받고, 서버는 요청만 받는다.

    행 하나를 INSERT 하는 것이 전부다. 워커가 자기 주기에 집어 간다. 예전처럼 여기서
    유닛을 띄우지 않으므로 "띄웠는데 떴는지 모르겠다"(`launching`)는 상태가 없다.
    """
    if not ingest_supported(configured_paths()["repo"]):
        raise RequestError(
            "이 라이브러리에는 적재본을 쓸 수 없습니다 — 폴더가 없거나 쓰기 권한이 "
            "없습니다. 폴더를 열어 보고 발행하는 것은 그대로 됩니다.", 400)
    # 🔴 CLI 가 없으면 **접수하지 않는다.** 받아 두면 워커가 집어 가서 즉시 실패하고,
    #    사용자는 큐에 빨간 카드가 하나 생긴 뒤에야 "CLI 가 없다" 를 읽는다. 매니페스트의
    #    필수 조건으로 막지 않는 이유는 그 술어에 "이거 아니면 저거" 가 없어서다 —
    #    claude 를 필수로 걸면 codex 만 있는 박스는 설치 자체가 막힌다.
    provider, _binary, reason = ingest_provider()
    if provider is None:
        raise RequestError(reason, 400)
    url = validate_youtube_url(url)
    video_id = video_id_from_url(url)
    paths = configured_paths()
    conn = _open_queue()
    try:
        manifest, item = _assert_video_available(conn, video_id)
        if item is not None:
            # 이미 적재된 영상 — 적재를 돌리지 않고 기존 문서를 목록 맨 위로 올린다.
            resurfaced = {
                key: value
                for key, value in read_resurfaced(paths["state"]).items()
                if key in manifest["by_path"]
            }
            resurfaced[item["path"]] = (
                datetime.now().astimezone().isoformat(timespec="seconds")
            )
            write_resurfaced(paths["state"], resurfaced)
            return {"duplicate": True, "path": item["path"], "video_id": video_id}
        try:
            attempt_id = QUEUE.enqueue(conn, url, video_id, _now_iso())
        except QUEUE.DuplicateVideo:
            # 사전 확인과 INSERT 사이에 같은 영상이 들어왔다 — 결과는 사전 확인과 같은 409 다.
            raise RequestError(f"video_id가 이미 큐에 있습니다: {video_id}", 409)
        return {"id": attempt_id, "status": "queued", "video_id": video_id}
    finally:
        conn.close()


def retry_ingest(request_id):
    """실패한 적재를 **새 행**으로 다시 넣는다. 옛 행은 손대지 않는다.

    🔴 같은 id 를 되살리지 않는 것이 이 설계의 핵심이다. 되살리면 옛 흔적을 지워야 하고
    (필드 목록을 손으로 관리), 로그를 옮겨야 하고(비원자적 회전), 옛 실행이 아직 정리 안
    됐는지 확인해야 한다(유닛 생존 가드). 새 행은 그 셋이 전부 필요 없다 — 처음부터
    비어 있고, 자기 로그를 갖고, 충돌할 상대가 없다.
    """
    attempt_id = _attempt_id(request_id)
    conn = _open_queue()
    try:
        record = QUEUE.get(conn, attempt_id)
        if record is None:
            raise RequestError("적재 요청을 찾을 수 없습니다", 404)
        if record["state"] not in QUEUE.TERMINAL_STATES:
            raise RequestError("아직 끝나지 않은 적재는 다시 시도할 수 없습니다", 409)
        if record["video_id"] in QUEUE.active_video_ids(conn):
            raise RequestError("같은 영상이 이미 큐에 있습니다", 409)
        try:
            new_id = QUEUE.enqueue(conn, record["url"], record["video_id"], _now_iso(),
                                   retry_of=attempt_id)
        except QUEUE.DuplicateVideo:
            raise RequestError("같은 영상이 이미 큐에 있습니다", 409)
        return {"id": new_id, "status": "queued", "retry_of": attempt_id}
    finally:
        conn.close()


def list_ingest():
    conn = _open_queue()
    try:
        return [_view(record) for record in QUEUE.recent(conn)]
    finally:
        conn.close()


def ingest_detail(request_id):
    conn = _open_queue()
    try:
        return _view(QUEUE.get(conn, _attempt_id(request_id)), include_log=True)
    finally:
        conn.close()


def cancel_ingest(request_id):
    """취소를 **요청**만 한다. 실제 종결은 워커가 자식을 죽인 뒤에 쓴다.

    예전에는 여기서 `systemctl stop` 을 부르고 10초를 기다리며 상태를 직접 썼다. 그래서
    "stop 은 보냈는데 유닛이 아직 사는" 창이 생겼고 `cancelling` 을 저장해야 했다.
    지금은 플래그 하나를 쓰고 즉시 응답한다.
    """
    attempt_id = _attempt_id(request_id)
    conn = _open_queue()
    try:
        record = QUEUE.get(conn, attempt_id)
        if record is None:
            raise RequestError("적재 요청을 찾을 수 없습니다", 404)
        if record["state"] in QUEUE.TERMINAL_STATES:
            raise RequestError("이미 끝난 적재입니다", 409)
        QUEUE.request_cancel(conn, attempt_id)
        return _view(QUEUE.get(conn, attempt_id))
    finally:
        conn.close()


def delete_ingest(request_id):
    attempt_id = _attempt_id(request_id)
    paths = configured_paths()
    conn = _open_queue()
    try:
        record = QUEUE.get(conn, attempt_id)
        if record is None:
            raise RequestError("적재 요청을 찾을 수 없습니다", 404)
        if record["state"] not in QUEUE.TERMINAL_STATES:
            raise RequestError("실행 중인 적재는 지울 수 없습니다 — 먼저 취소하세요", 409)
        QUEUE.delete(conn, attempt_id)
    finally:
        conn.close()
    for path in (QUEUE.log_path(paths["state"], attempt_id),
                 QUEUE.receipt_path(paths["state"], attempt_id)):
        try:
            os.unlink(path)
        except OSError:
            pass
    return {"deleted": attempt_id}


def item_view(item, scan):
    result = dict(item)
    aliases = scan["aliases"].get(item["path"], [])
    result["public_name"] = item.get("canonical_name")
    result["aliases"] = sorted(alias["name"] for alias in aliases)
    result["live_aliases"] = sorted(alias["name"] for alias in aliases if alias["live"])
    result["published"] = bool(result["live_aliases"])
    result.pop("canonical_name", None)
    return result


def document_flag(repo, manifest, path, key):
    """문서의 상태 키. 생산자가 실어 주면 그것을 쓰고, 아니면 파일에서 읽는다.

    builtin 스캐너는 어차피 모든 문서의 프론트매터를 읽으므로 그대로 싣는다. 라이브러리가
    자기 `scripts/learn.py` 를 가진 경우에는 그 생산자가 이 키를 모르므로 여기서 읽는다 —
    남의 생산자에게 우리 상태 키를 요구하지 않는 것이 `auto` 를 두는 이유다.
    """
    item = manifest["by_path"].get(path)
    if item is None:
        return False
    if key in item:
        return truthy_scalar(item.get(key))
    try:
        full = repo_path(repo, path, error_type=CollectionError)
    except LearningManagerError:
        return False
    fields, _heading, _has_block = read_front_matter(full)
    return truthy_scalar(fields.get(key))


def build_snapshot():
    paths = configured_paths()
    with state_lock(paths["state"]):
        manifest = collect_manifest()
        state = read_state(paths["state"])
        starred = read_starred(paths["state"])
        resurfaced = read_resurfaced(paths["state"])
        scan = scan_links(paths["repo"], paths["public"], manifest)

    # 재부상 시각이 적재 커밋 시각보다 새로우면 그 문서를 그 시각에 적재된 것처럼 취급한다.
    # 둘 다 이 박스에서 만든 같은 오프셋의 ISO 라 문자열 비교가 시간 비교와 일치한다.
    bumped = False
    for item in manifest["items"]:
        stamp = resurfaced.get(item["path"], "")
        if stamp and stamp >= (item.get("changed_at") or ""):
            item["changed_at"] = stamp
            bumped = True
    if bumped:
        # 🔴 재부상 스탬프는 초 단위로 절삭된다 — 같은 초의 커밋과 동률이 되면 시각만으로는
        #    자리를 못 올린다. 동률에서는 재부상한 쪽이 이긴다(두 번째 키).
        #    normalize_manifest 의 최종 정렬과 같은 첫 키라 나머지 순서는 안정적으로 유지된다.
        manifest["items"].sort(
            key=lambda value: (
                value["changed_at"] or "",
                1 if value["path"] in resurfaced else 0,
            ),
            reverse=True,
        )

    views = {item["path"]: item_view(item, scan) for item in manifest["items"]}
    # 🔴 정본은 문서다. 옛 `starred.json`·`state.json` 은 **합집합으로만** 읽는다 —
    #    이 앱은 남의 문서를 일괄로 고치지 않으므로 이관은 사용자가 그 문서를 건드릴 때
    #    한 건씩 일어난다(별표를 누르면 그때 문서에 적히고 JSON 에서 빠진다). 그 사이에
    #    빼기로 읽으면 이미 별표해 둔 170개가 화면에서 한꺼번에 사라진다.
    for path, view in views.items():
        view["starred"] = document_flag(paths["repo"], manifest, path, "starred") \
            or path in starred
    needs_attention = list(scan["needs_attention"])
    attention_keys = set()

    def add_state_attention(entry):
        key = (entry.get("reason"), entry.get("name"), entry.get("path"), entry.get("target"))
        if key not in attention_keys:
            attention_keys.add(key)
            needs_attention.append(entry)

    for entry in scan["needs_attention"]:
        attention_keys.add((entry.get("reason"), entry.get("name"), entry.get("path"), entry.get("target")))

    # 🔴 목록은 **폴더에 있는 모든 자료**다. 예전에는 "발행된 것" 이었고 발행되지
    #    않은 자료는 보관함의 `unpublished` 칸으로 갔다 — 한 사람이 자기 레포의
    #    발행 상태를 관리하던 시절의 모양이다. 그 결과 앱을 막 깐 사람이 첫 자료를
    #    만들면 목록이 아니라 보관함에서 그걸 찾아야 했다. 발행은 이제 자료의
    #    **상태**(`published`)이지 목록에 들어올 자격이 아니다.
    archived = []
    listed = []
    for item in manifest["items"]:
        path = item["path"]
        view = views[path]
        live = bool(view["live_aliases"])
        if document_flag(paths["repo"], manifest, path, "archived") or state.get(path):
            archived.append(view)
            if live:
                add_state_attention({
                    "path": path,
                    "reason": "archived_but_live",
                    "names": view["live_aliases"],
                })
        else:
            listed.append(view)

    for path in sorted(set(state) - set(views)):
        add_state_attention({"path": path, "reason": "orphan_archive_record"})

    return {
        "items": listed,
        "archive": {
            "archived": archived,
            "needs_attention": needs_attention,
        },
        "warnings": manifest["warnings"],
        "repo_head": manifest["repo_head"],
        "orphan_starred_paths": sorted(set(starred) - set(views)),
        "stale": False,
    }


def remember_success(snapshot):
    global LAST_SUCCESS
    with SNAPSHOT_LOCK:
        LAST_SUCCESS = copy.deepcopy(snapshot)


def stale_failure(error):
    with SNAPSHOT_LOCK:
        previous = copy.deepcopy(LAST_SUCCESS)
    if previous is None:
        result = {"stale": False}
    else:
        result = previous
        result["stale"] = True
    result.update(error.payload())
    return result


def validate_item(manifest, path):
    path = safe_relative(path, "path", RequestError)
    item = manifest["by_path"].get(path)
    if item is None:
        raise RequestError(f"manifest에 없는 path입니다: {path}", 400)
    return item


def require_mutable(item):
    if not item.get("mutable"):
        raise RequestError(f"이 문서는 발행 상태 변경 대상이 아닙니다: {item['path']}", 409)


def write_document_flag(paths, relative, key, value, reader=None, writer=None):
    """문서에 상태를 적고, 옛 JSON 에 남아 있던 같은 문서의 항목을 걷어낸다.

    🔴 걷어내기를 이 함수가 **직접** 한다. 한때는 부르는 쪽 셋이 각자 했고, 주석만 여기서
    약속하고 있었다 — 다음에 부르는 사람이 잊으면 합집합 읽기 때문에 **해제가 조용히 안
    먹는다.** 약속과 코드는 같은 자리에 있어야 한다.

    🔴 순서가 중요하다. 문서에 못 적으면 아무것도 바꾸지 않는다 — 화면만 바뀌고 파일은
    그대로인 상태를 만들지 않는 것이, 상태를 문서로 옮긴 이유의 절반이다. 그리고 성공하면
    옛 JSON 에서 반드시 뺀다: 읽기는 합집합이라, JSON 에 남아 있으면 **해제가 먹지 않는다.**
    """
    try:
        SAVE.patch_frontmatter(paths["repo"], relative,
                               {key: "true" if value else None},
                               state_dir=paths["state"])
    except SAVE.SaveError as exc:
        if exc.reason == "no-frontmatter":
            # 🔴 **끄는 것은 언제나 된다.** 옛 JSON 에만 별표가 있는데 그 문서에 프론트매터가
            #    없으면, 여기서 409 를 내는 순간 그 별표는 영원히 못 끈다 — 합집합이 계속
            #    참으로 읽고 버튼은 비활성이라 앱 안에 길이 없다(적대검증 2026-08-22).
            #    문서에 적을 것이 없을 뿐이지 걷어낼 것은 있다.
            if not value:
                if reader is not None and writer is not None:
                    drop_legacy_flag(paths, relative, reader, writer)
                return
            raise RequestError(
                f"이 문서에는 상태를 적을 수 없습니다: {relative} — 프론트매터가 없습니다."
                " 이 앱은 남의 문서를 고쳐 주지 않으므로 목록에서 읽기 전용입니다", 409) from exc
        if exc.reason == "document-changed":
            raise RequestError(exc.message, 409) from exc
        raise RequestError(f"상태를 적지 못했습니다: {exc.message}", 409) from exc
    except OSError as exc:
        raise LearningManagerError(f"상태를 적지 못했습니다: {relative}: {exc}", 500) from exc
    if reader is not None and writer is not None:
        drop_legacy_flag(paths, relative, reader, writer)


def drop_legacy_flag(paths, relative, reader, writer):
    """옛 JSON 에 남아 있던 항목을 걷어낸다. 없으면 아무 일도 하지 않는다."""
    legacy = reader(paths["state"])
    if relative in legacy:
        del legacy[relative]
        writer(paths["state"], legacy)


def star_path(path, starred):
    if type(starred) is not bool:
        raise RequestError("starred는 bool이어야 합니다", 400)
    paths = configured_paths()
    with state_lock(paths["state"]):
        manifest = collect_manifest()
        item = validate_item(manifest, path)
        write_document_flag(paths, item["path"], "starred", starred,
                            read_starred, write_starred)
    return {"ok": True, "path": item["path"], "starred": starred}


def validate_publish_source(repo, item):
    html_path = item.get("html_path")
    if not html_path:
        raise RequestError("html_path가 없어 발행할 수 없습니다", 409)
    source = repo_path(repo, html_path, error_type=RequestError)
    try:
        info = os.lstat(source)
    except OSError as exc:
        raise RequestError(f"발행할 HTML을 읽지 못했습니다: {html_path}", 409) from exc
    if stat.S_ISLNK(info.st_mode):
        resolved = os.path.realpath(source)
        raise RequestError(f"발행 대상이 심링크입니다: {resolved}", 409)
    if not stat.S_ISREG(info.st_mode) or not is_under(source, repo):
        raise RequestError("발행 대상 HTML이 learning 레포의 일반 파일이 아닙니다", 409)
    return os.path.realpath(source)


def canonical_path(public_html, item):
    name = item.get("canonical_name")
    if not name or os.path.basename(name) != name or "/" in name or "\\" in name:
        raise RequestError(f"canonical 이름이 안전하지 않습니다: {name}", 409)
    return os.path.join(public_html, name)


def live_aliases(scan, path):
    return [alias for alias in scan["aliases"].get(path, []) if alias["live"]]


def unlink_alias(public_html, record, path, scan):
    full = os.path.join(public_html, record["name"])
    try:
        info = os.lstat(full)
        if not stat.S_ISLNK(info.st_mode):
            raise RequestError(f"alias가 더 이상 심링크가 아닙니다: {record['name']}", 409)
        target = os.readlink(full)
        resolved = os.path.realpath(full)
    except FileNotFoundError:
        return
    jurisdiction = classify_target(resolved, scan["roots"])
    associated = jurisdiction and next(
        (item_path for item_path, aliases in scan["aliases"].items()
         if any(alias["name"] == record["name"] for alias in aliases)),
        None,
    )
    if associated != path or target != record["target"]:
        raise RequestError(f"alias 대상이 확인 당시와 달라졌습니다: {record['name']}", 409)
    if not os.path.isfile(resolved):
        return
    try:
        os.unlink(full)
    except OSError as exc:
        raise LearningManagerError(f"alias를 회수하지 못했습니다: {record['name']}: {exc}", 500) from exc


def ensure_no_live_aliases(repo, public_html, manifest, path):
    scan = scan_links(repo, public_html, manifest)
    remaining = live_aliases(scan, path)
    if remaining:
        raise LearningManagerError(
            "회수 후에도 live alias가 남았습니다: "
            + ", ".join(alias["name"] for alias in remaining), 500,
        )
    return scan


def publish_path(path):
    paths = configured_paths()
    with state_lock(paths["state"]):
        manifest = collect_manifest()
        item = validate_item(manifest, path)
        require_mutable(item)
        state = read_state(paths["state"])
        if state.get(item["path"]):
            raise RequestError("보관 중인 문서는 먼저 복원해야 발행할 수 있습니다", 409)
        scan = scan_links(paths["repo"], paths["public"], manifest)
        if item["path"] in scan["conflicts"]:
            raise RequestError(
                f"canonical 이름 충돌로 발행할 수 없습니다: {scan['conflicts'][item['path']]}", 409,
            )
        # canonical worktree는 아래 canonical 자리 검사에서 별도로 거부한다.
        if any(
            alias.get("name") != item["canonical_name"]
            and alias.get("origin") == "worktree"
            for alias in scan["aliases"].get(item["path"], [])
        ):
            raise RequestError("기존 alias 대상이 worktree라 발행하지 않습니다", 409)
        source = validate_publish_source(paths["repo"], item)
        target = canonical_path(paths["public"], item)
        name = item["canonical_name"]
        existing = scan["entries"].get(name)
        if existing:
            if existing.get("associated_path") != item["path"]:
                raise RequestError("canonical 이름이 다른 문서를 가리킵니다", 409)
            if not existing.get("live"):
                raise RequestError("canonical 심링크가 dangling이라 덮어쓰지 않습니다", 409)
            if existing.get("origin") != "main":
                raise RequestError("canonical 대상이 worktree라 발행하지 않습니다", 409)
            if existing.get("resolved") != source:
                raise RequestError("canonical 대상 경로가 현재 manifest와 다릅니다", 409)
            # canonical 이 이미 있어도 sibling 은 없을 수 있다(2026-08-21 이전에 발행된 것들).
            sibling = ensure_sibling_alias(paths["public"], item, source)
            return {"ok": True, "path": item["path"], "name": name, "created": False,
                    "sibling": sibling}

        os.makedirs(paths["public"], mode=0o755, exist_ok=True)
        try:
            os.symlink(source, target)
        except FileExistsError as exc:
            raise RequestError("canonical 자리가 동시에 생겨 발행하지 않았습니다", 409) from exc
        except OSError as exc:
            raise LearningManagerError(f"canonical 심링크를 만들지 못했습니다: {exc}", 500) from exc

        try:
            after = scan_links(paths["repo"], paths["public"], manifest)
            record = after["entries"].get(name)
            if not record or record.get("associated_path") != item["path"] or not record.get("live"):
                raise LearningManagerError("발행 후 canonical 심링크 검증에 실패했습니다", 500)
        except Exception:
            try:
                if os.path.islink(target) and os.path.realpath(target) == source:
                    os.unlink(target)
            except OSError:
                pass
            raise
        sibling = ensure_sibling_alias(paths["public"], item, source)
        return {"ok": True, "path": item["path"], "name": name, "created": True,
                "sibling": sibling}


def unpublish_path(path):
    paths = configured_paths()
    with state_lock(paths["state"]):
        manifest = collect_manifest()
        item = validate_item(manifest, path)
        require_mutable(item)
        read_state(paths["state"])
        scan = scan_links(paths["repo"], paths["public"], manifest)
        if item["path"] in scan["conflicts"]:
            raise RequestError(
                f"canonical 충돌 때문에 회수하지 않습니다: {scan['conflicts'][item['path']]}", 409,
            )
        aliases = live_aliases(scan, item["path"])
        removed = []
        for alias in aliases:
            unlink_alias(paths["public"], alias, item["path"], scan)
            removed.append(alias["name"])
        ensure_no_live_aliases(paths["repo"], paths["public"], manifest, item["path"])
        return {"ok": True, "path": item["path"], "removed": sorted(removed)}


def archive_paths(paths_to_archive):
    paths = configured_paths()
    results = []
    had_failure = False
    internal_failure = False
    with state_lock(paths["state"]):
        manifest = collect_manifest()
        state = read_state(paths["state"])
        for path in paths_to_archive:
            try:
                item = validate_item(manifest, path)
                require_mutable(item)
                scan = scan_links(paths["repo"], paths["public"], manifest)
                if item["path"] in scan["conflicts"]:
                    raise RequestError(
                        f"canonical 충돌 때문에 보관하지 않습니다: {scan['conflicts'][item['path']]}" , 409,
                    )
                removed = []
                for alias in live_aliases(scan, item["path"]):
                    unlink_alias(paths["public"], alias, item["path"], scan)
                    removed.append(alias["name"])
                ensure_no_live_aliases(paths["repo"], paths["public"], manifest, item["path"])
                # 보관도 문서가 정본이다. 못 적으면 링크만 회수된 채로 남는데, 그쪽이
                # 안전한 방향이다 — 공개된 것을 내렸고 목록에는 그대로 있다.
                write_document_flag(paths, item["path"], "archived", True,
                                    read_state, write_state)
                state.pop(item["path"], None)
                results.append({"path": item["path"], "ok": True, "removed": sorted(removed)})
            except LearningManagerError as exc:
                had_failure = True
                if not isinstance(exc, RequestError):
                    internal_failure = True
                results.append({"path": path, "ok": False, "error": exc.message})
                if not isinstance(exc, RequestError) and "상태" in exc.message:
                    break
    if had_failure:
        return (500 if internal_failure else 409), {"ok": False, "results": results}
    return 200, {"ok": True, "results": results}


def restore_path(path):
    paths = configured_paths()
    with state_lock(paths["state"]):
        manifest = collect_manifest()
        item = validate_item(manifest, path)
        # 🔴 여기서 `require_mutable` 을 부르면 **보관함에서 나올 수 없는 문서**가 생긴다.
        #    `mutable` 은 렌더된 html 짝과 `source: youtube` 를 요구하는데, 남의 위키에서
        #    복사해 온 문서가 `archived: true` 를 갖고 있으면 그 문서는 목록에 없고 보관함에
        #    있으면서 복구 버튼은 409 를 낸다 — 영구히(적대검증 2026-08-22). 보관은 발행
        #    상태가 아니고, 들어간 것은 나올 수 있어야 한다.
        state = read_state(paths["state"])
        was_archived = (document_flag(paths["repo"], manifest, item["path"], "archived")
                        or item["path"] in state)
        if not was_archived:
            return {"ok": True, "path": item["path"], "restored": False}
        write_document_flag(paths, item["path"], "archived", False,
                            read_state, write_state)
        return {"ok": True, "path": item["path"], "restored": True}


def forget_path(path):
    paths = configured_paths()
    path = safe_relative(path, "path", RequestError)
    with state_lock(paths["state"]):
        manifest = collect_manifest()
        state = read_state(paths["state"])
        if path in manifest["by_path"]:
            raise RequestError("manifest에 남아 있는 path는 forget할 수 없습니다", 409)
        if path not in state:
            raise RequestError("보관 상태에 없는 orphan path입니다", 404)
        del state[path]
        write_state(paths["state"], state)
        return {"ok": True, "path": path, "forgotten": True}


def script_payload(data):
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    return payload.replace("</", "<\\/").replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")


# 발행본은 공용 CSS·JS 를 오리진 절대경로(`/_assets/…`)로 참조한다. 그 절대경로는 **앱이 아니라
# 허브 루트**로 간다 — 앱은 nginx `location /learning/ { proxy_pass …:PORT/; }` 뒤에 접두어가
# 벗겨진 채 붙어 있어서, 브라우저의 공용 문서 자산(`/_assets/`) 요청은 앱을 스쳐 지나간다.
# 허브 루트의 markserv 는 그 경로에 대해 **200 + HTML 404 페이지**를 준다(실측 2026-07-31) —
# 콘텐츠 타입이 CSS 가 아니라 브라우저가 조용히 버리고, 뷰어 안 문서는 무장식으로 렌더된다.
# 그래서 내주는 시점에 `../_assets/` 로 바꾼다: 문서 주소가 항상 `<접두어>/doc/<이름>` 이라
# 한 단계 위 = `<접두어>/_assets/…` = 이 앱의 자산 라우트다(접두어가 무엇이든 성립).
DOC_ASSET_REF = re.compile(rb"""(?<=["'])/_assets/""")


def rewrite_asset_refs(body):
    return DOC_ASSET_REF.sub(b"../_assets/", body)


def snapshot_or_failure():
    try:
        snapshot = build_snapshot()
        remember_success(snapshot)
        return snapshot
    except LearningManagerError as exc:
        return stale_failure(exc)


def inventory_rows(manifest, state, scan):
    rows = []
    for name, record in sorted(scan["entries"].items()):
        path = record.get("associated_path") or "-"
        desired = "-"
        if record.get("associated_path") in manifest["by_path"]:
            desired = manifest["by_path"][record["associated_path"]].get("canonical_name", "-")
        if record.get("associated_path") and name == desired:
            action = "canonical"
        elif record.get("live") and record.get("associated_path"):
            action = "alias"
        elif record.get("associated_path"):
            action = "dangling; 보류"
        else:
            action = "판정 불가; 보류"
        rows.append((name, path, record.get("origin") or "outside", action, record.get("target", "")))
    for item in manifest["items"]:
        if not item.get("mutable") or state.get(item["path"]):
            continue
        if not scan["aliases"].get(item["path"]):
            rows.append(("-", item["path"], "-", "미발행; 생성 안 함", item.get("canonical_name", "")))
    return rows


def fix_links(paths, manifest, state):
    """A9 수정 모드. 확인된 live alias만 canonical으로 정리하고 dangling은 보류한다."""
    changed = []
    for item in manifest["items"]:
        path = item["path"]
        if not item.get("mutable") or state.get(path):
            continue
        current = scan_links(paths["repo"], paths["public"], manifest)
        aliases = current["aliases"].get(path, [])
        live = [alias for alias in aliases if alias["live"]]
        if not live or path in current["conflicts"]:
            continue
        source = validate_publish_source(paths["repo"], item)
        target = canonical_path(paths["public"], item)
        name = item["canonical_name"]
        canonical = current["entries"].get(name)
        if canonical:
            if (canonical.get("associated_path") != path
                    or not canonical.get("live")
                    or canonical.get("origin") != "main"):
                continue
        else:
            os.makedirs(paths["public"], mode=0o755, exist_ok=True)
            try:
                os.symlink(source, target)
            except FileExistsError:
                continue
            changed.append(f"create {name}")
        current = scan_links(paths["repo"], paths["public"], manifest)
        for alias in current["aliases"].get(path, []):
            if alias["name"] != name and alias["live"]:
                unlink_alias(paths["public"], alias, path, current)
                changed.append(f"unlink {alias['name']}")
    return changed


def inventory(fix=False):
    paths = configured_paths()
    with state_lock(paths["state"]):
        manifest = collect_manifest()
        state = read_state(paths["state"])
        scan = scan_links(paths["repo"], paths["public"], manifest)
        print("name\tpath\torigin\tstatus\ttarget")
        for row in inventory_rows(manifest, state, scan):
            print("\t".join(row))
        for attention in scan["needs_attention"]:
            print("ATTENTION\t" + json.dumps(attention, ensure_ascii=False, sort_keys=True))
        if fix:
            changed = fix_links(paths, manifest, state)
            for entry in changed:
                print("FIXED\t" + entry)
        else:
            print("DRY-RUN\t실제 링크 변경 없음; --fix-links를 명시해야 수정합니다")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "learning-manager"

    def log_message(self, format_string, *args):
        return

    def _send_json(self, code, body):
        payload = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def _send_bytes(self, code, payload, content_type):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def _page(self):
        try:
            with open(FRONTEND_PATH, "r", encoding="utf-8") as stream:
                page = stream.read()
        except OSError as exc:
            return self._send_json(500, {"error": f"프런트엔드 페이지를 읽지 못했습니다: {exc}"})
        data = snapshot_or_failure()
        inline = f"<script>window.__LEARNING_DATA__ = {script_payload(data)};</script>"
        marker = "<!-- LEARNING_MANAGER_DATA -->"
        if marker in page:
            page = page.replace(marker, inline, 1)
        elif "</head>" in page:
            page = page.replace("</head>", inline + "</head>", 1)
        else:
            return self._send_json(500, {"error": "프런트엔드에 data 삽입 위치가 없습니다"})
        return self._send_bytes(200, page.encode("utf-8"), "text/html; charset=utf-8")

    def _published_doc(self, name):
        """발행본 HTML 을 **앱과 같은 오리진**으로 내준다 — iframe 뷰어가 쓴다.

        문서를 발행 URL 로 직접 열면 앱 껍데기(뒤로가기)를 잃고, 앱이 테일넷 https 로
        열렸을 때는 http iframe 이 혼합 콘텐츠로 차단된다. 그래서 여기서 내준다.
        발행 디렉터리의 항목은 learning 레포를 가리키는 심링크라 realpath 는 밖으로
        나간다 — 경계는 **이름**으로 잡는다(디렉터리 이동 금지).
        """
        if not name or name != os.path.basename(name) or name in (".", ".."):
            return self._send_json(400, {"error": "문서 이름이 올바르지 않습니다"})
        if not name.endswith(".html"):
            return self._send_json(400, {"error": "발행본은 .html 입니다"})
        public = configured_paths()["public"]
        target = os.path.join(public, name)
        if os.path.dirname(os.path.abspath(target)) != public:
            return self._send_json(400, {"error": "발행 디렉터리 밖입니다"})
        try:
            with open(target, "rb") as stream:
                body = stream.read()
        except OSError as exc:
            # 발행이 회수됐거나 심링크가 끊긴 경우다. 빈 화면으로 삼키지 않는다.
            return self._send_json(404, {"error": f"발행본을 읽지 못했습니다: {exc}"})
        return self._send_bytes(200, rewrite_asset_refs(body), "text/html; charset=utf-8")

    def _library_doc(self, relative):
        """**아직 발행하지 않은** 자료의 렌더본을 라이브러리에서 바로 내준다.

        🔴 이게 없으면 "깔고 붙여넣고 읽는다" 가 마지막 걸음에서 깨진다. 목록이
        폴더 전체가 된 뒤로 미발행 자료도 목록에 있는데, 뷰어는 발행 디렉터리만
        봤다 — 눌러 보면 iframe 에 404 JSON 원문이 떴다(실측). 읽는 것과 공유하는
        것은 다른 일이고, 읽기가 공유를 기다릴 이유가 없다.

        경계는 발행 경로와 다르다. 저기는 이름 하나(디렉터리 이동 금지)로 잡지만
        여기는 라이브러리 안의 상대경로라 `repo_path` 로 뿌리 안에 있음을 강제한다.
        """
        paths = configured_paths()
        try:
            relative = safe_relative(relative, "문서 경로")
            if not relative.endswith(".html"):
                raise RequestError("렌더본은 .html 입니다", 400)
            target = repo_path(paths["repo"], relative, error_type=RequestError)
        except LearningManagerError as exc:
            return self._send_json(exc.code, exc.payload())
        try:
            with open(target, "rb") as stream:
                body = stream.read()
        except OSError as exc:
            return self._send_json(404, {"error": f"렌더본을 읽지 못했습니다: {exc}"})
        return self._send_bytes(200, rewrite_asset_refs(body), "text/html; charset=utf-8")

    ASSET_TYPES = {".css": "text/css; charset=utf-8", ".js": "text/javascript; charset=utf-8"}

    def _published_asset(self, name):
        """발행본이 쓰는 공용 문서 자산(`_assets/` 아래 css·js). 이름 경계는 /doc 과 같은 규칙이다."""
        if not name or name != os.path.basename(name) or name in (".", ".."):
            return self._send_json(400, {"error": "자산 이름이 올바르지 않습니다"})
        content_type = self.ASSET_TYPES.get(os.path.splitext(name)[1].lower())
        if content_type is None:
            return self._send_json(400, {"error": "자산은 .css · .js 만 내줍니다"})
        public = configured_paths()["public"]
        target = os.path.join(public, "_assets", name)
        if os.path.dirname(os.path.abspath(target)) != os.path.join(public, "_assets"):
            return self._send_json(400, {"error": "자산 디렉터리 밖입니다"})
        try:
            with open(target, "rb") as stream:
                body = stream.read()
        except OSError as exc:
            return self._send_json(404, {"error": f"자산을 읽지 못했습니다: {exc}"})
        return self._send_bytes(200, body, content_type)

    def _read_json(self):
        raw_length = self.headers.get("Content-Length")
        if raw_length is None:
            raise RequestError("Content-Length가 없습니다", 400)
        try:
            length = int(raw_length)
        except ValueError as exc:
            raise RequestError("Content-Length가 올바르지 않습니다", 400) from exc
        if length < 0:
            raise RequestError("Content-Length가 올바르지 않습니다", 400)
        if length > BODY_MAX_BYTES:
            raise RequestError("요청 본문이 너무 큽니다", 413)
        body = self.rfile.read(length)
        if len(body) != length:
            raise RequestError("요청 본문을 끝까지 읽지 못했습니다", 400)
        try:
            data = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise RequestError(f"JSON 본문이 올바르지 않습니다: {exc}", 400) from exc
        if not isinstance(data, dict):
            raise RequestError("JSON 본문은 object여야 합니다", 400)
        return data

    def _post_path(self, data):
        return safe_relative(data.get("path"), "path", RequestError)

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        if path in ("/", "/index.html"):
            return self._page()
        if path == "/api/health":
            return self._send_json(200, {"ok": True})
        if path.startswith("/doc/"):
            return self._published_doc(unquote(path[len("/doc/"):]))
        if path.startswith("/read/"):
            return self._library_doc(unquote(path[len("/read/"):]))
        if path.startswith("/_assets/"):
            # `/doc/…` 이 내주는 문서의 자산 참조가 여기로 온다(`rewrite_asset_refs` 참고). 앱 오리진에서
            # 이걸 안 내주면 뷰어 안 문서가 스타일을 잃는다(실측: 무장식 텍스트로 렌더).
            return self._published_asset(unquote(path[len("/_assets/"):]))
        if path == "/api/ingest":
            try:
                records = list_ingest()
                return self._send_json(200, {"requests": records})
            except LearningManagerError as exc:
                return self._send_json(exc.code, exc.payload())
        if path.startswith("/api/ingest/"):
            request_id = unquote(path[len("/api/ingest/"):])
            if "/" not in request_id:
                try:
                    return self._send_json(200, ingest_detail(request_id))
                except LearningManagerError as exc:
                    return self._send_json(exc.code, exc.payload())
        if path == "/api/items":
            try:
                snapshot = build_snapshot()
                remember_success(snapshot)
                return self._send_json(200, snapshot)
            except LearningManagerError as exc:
                return self._send_json(exc.code, stale_failure(exc))
        return self._send_json(404, {"error": "not found"})

    def do_POST(self):
        path = self.path.split("?", 1)[0].rstrip("/") or "/"
        try:
            body = self._read_json()
            if path == "/api/ingest/plan":
                result = create_ingest_plan(body.get("url"))
                return self._send_json(200, result)
            if path == "/api/ingest/run":
                result = create_ingest_run(body.get("url"))
                return self._send_json(202, result)
            if path.startswith("/api/ingest/"):
                suffix = path[len("/api/ingest/"):]
                if suffix.endswith("/cancel"):
                    request_id = unquote(suffix[:-len("/cancel")].rstrip("/"))
                    result = cancel_ingest(request_id)
                    return self._send_json(200, result)
                if suffix.endswith("/delete"):
                    request_id = unquote(suffix[:-len("/delete")].rstrip("/"))
                    result = delete_ingest(request_id)
                    return self._send_json(200, result)
                if suffix.endswith("/retry"):
                    request_id = unquote(suffix[:-len("/retry")].rstrip("/"))
                    result = retry_ingest(request_id)
                    return self._send_json(200, result)
            if path == "/api/publish":
                result = publish_path(self._post_path(body))
                return self._send_json(200, result)
            if path == "/api/unpublish":
                result = unpublish_path(self._post_path(body))
                return self._send_json(200, result)
            if path == "/api/star":
                result = star_path(self._post_path(body), body.get("starred"))
                return self._send_json(200, result)
            if path == "/api/archive":
                values = body.get("paths")
                if not isinstance(values, list) or not values:
                    raise RequestError("paths 배열이 없습니다", 400)
                if len(values) > 500:
                    raise RequestError("한 번에 처리할 path가 너무 많습니다", 413)
                safe_paths = [safe_relative(value, "path", RequestError) for value in values]
                code, result = archive_paths(safe_paths)
                return self._send_json(code, result)
            if path == "/api/restore":
                result = restore_path(self._post_path(body))
                return self._send_json(200, result)
            if path == "/api/forget":
                result = forget_path(self._post_path(body))
                return self._send_json(200, result)
            return self._send_json(404, {"error": "not found"})
        except LearningManagerError as exc:
            return self._send_json(exc.code, exc.payload())
        except Exception as exc:
            return self._send_json(500, {"error": f"처리하지 못했습니다: {exc}"})


class Server(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def main(argv=None):
    parser = argparse.ArgumentParser(description="learning-manager")
    parser.add_argument("--inventory", action="store_true")
    parser.add_argument("--fix-links", action="store_true")
    args = parser.parse_args(argv)
    if args.fix_links and not args.inventory:
        parser.error("--fix-links는 --inventory와 함께 써야 합니다")
    if args.inventory:
        try:
            inventory(fix=args.fix_links)
        except LearningManagerError as exc:
            print("error: " + exc.message, file=sys.stderr)
            return 1
        return 0

    server = Server(("127.0.0.1", PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 130
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
