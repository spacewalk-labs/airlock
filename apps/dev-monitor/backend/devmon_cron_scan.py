#!/usr/bin/env python3
"""dev-monitor 수집기 — 이 박스의 스케줄드 잡을 전수 수집한다(조회만, mutation 없음).

수집 소스 5종. 하나도 조용히 빠뜨리지 않는다 — 못 읽으면 그 사실을 sources[] 에 남긴다.
  1. systemd user timer   (scope=user)    조작 가능 — 소유자 권한으로 start/stop
  2. systemd system timer (scope=system)  읽기 전용 — sudo 없음
  3. 개인 crontab         (scope=crontab) `crontab -l`
  4. 시스템 cron 파일     (scope=cron.d)  /etc/crontab · /etc/cron.d/* · /etc/cron.{hourly,daily,weekly,monthly}/
  5. CRON journal         (scope=cron-journal) sudo -n 경유, 현재 부팅 이후 실행 신호

판정축은 실행 신호(`execution`), 시의성(`timeliness`), 결과(`lastResult`)로 분리한다.
cron journal 은 실행 신호만 주고 종료코드는 주지 않으므로 결과를 성공으로 추정하지 않는다.

시각은 전부 epoch(float). 로컬 TZ(박스 표준 = Asia/Seoul)로 파싱한다 — 원격 수집이 아니라
같은 박스이므로 TZ 불일치가 원리적으로 없다(원격판 cron_health.py 의 TZ 맵이 불필요한 이유).
"""
from __future__ import annotations

import copy
import hashlib
import json
import math
import os
import pwd
import re
import shlex
import shutil
import stat
import subprocess
import threading
import time
from collections import Counter
from datetime import date, datetime, timedelta

# 다음 실행이 이만큼 지나도 안 돌았으면 late (원격판과 같은 유예)
LATE_GRACE_SEC = 300

# journal 수집 경로는 환경변수로 주입할 수 있다. 기본값은 실행 파일의 절대경로다.
SUDO = os.environ.get("CRON_CONSOLE_SUDO", "/usr/bin/sudo")
JOURNALCTL = os.environ.get("CRON_CONSOLE_JOURNALCTL", "/usr/bin/journalctl")
SERVICE_START_TIME = time.time()

SNAPSHOT_CACHE_TTL_SEC = 30
_snapshot_lock = threading.Lock()
_snapshot_cache: tuple[dict, float] | None = None

TIMER_RE = re.compile(r"[A-Za-z0-9_.@\\:-]+\.timer")
UNIT_SAFE_RE = re.compile(r"^[A-Za-z0-9_.@\\:-]+\.(timer|service)\Z")

# systemd human timestamp: "Tue 2026-07-28 05:00:30 KST"
_TS_RE = re.compile(
    r"^[A-Za-z]{3}\s+([0-9]{4}-[0-9]{2}-[0-9]{2}\s+[0-9]{2}:[0-9]{2}:[0-9]{2})")
# monotonic duration: "6d 18h 46min 27.896260s"
_DUR_RE = re.compile(r"([0-9]+(?:\.[0-9]+)?)\s*(us|ms|s|min|m|h|d|w)\b")
_DUR_UNIT = {"us": 1e-6, "ms": 1e-3, "s": 1, "min": 60, "m": 60, "h": 3600, "d": 86400, "w": 604800}
# ExecStart={ path=/bin/sh ; argv[]=/bin/sh -c "..." ; ignore_errors=no ... }
_ARGV_RE = re.compile(r"argv\[\]=(.*?)\s+;\s")

TIMER_PROPS = (
    "Id,Description,UnitFileState,ActiveState,LastTriggerUSec,"
    "NextElapseUSecRealtime,NextElapseUSecMonotonic,TimersCalendar,TimersMonotonic,Unit,"
    "FragmentPath"
)
SERVICE_PROPS = (
    "Id,Description,Result,ExecMainStatus,ExecMainStartTimestamp,"
    "ExecMainExitTimestamp,ActiveState,ExecStart,ConditionResult,FragmentPath"
)
CRON_SERVICE_PROPS = "UnitFileState,ActiveEnterTimestamp"

# cron.d/run-parts 파일명 규칙: 영숫자·'-'·'_' 만. 점이 들어간 이름(.dpkg-dist·.bak)과
# '~' 로 끝나는 백업은 cron 이 무시하므로 우리도 무시한다 — 안 도는 파일을 잡으로 세지 않게.
_RUN_PARTS_NAME_RE = re.compile(r"^[A-Za-z0-9_-]+\Z")

CRON_D_DIR = "/etc/cron.d"
CRONTAB_FILE = "/etc/crontab"
CRONTAB_SPOOL_DIR = "/var/spool/cron/crontabs"
RUN_PARTS_DIRS = ("/etc/cron.hourly", "/etc/cron.daily", "/etc/cron.weekly", "/etc/cron.monthly")

# /etc/crontab·cron.d 정의의 first-seen 은 프로세스 생애 동안만 기억한다. 디스크에는
# 쓰지 않는다. 파일 mtime 은 새로 나타난 정의의 약한 하한일 때만 사용한다.
_CRON_DEFINITION_SEEN: set[tuple[str, str, str, str]] = set()

DESCRIPTION_SCHEMA_VERSION = 1
DESCRIPTION_FILE_KIND = "job-descriptions.json"
# (path, mtime_ns, entries, error). A missing file is cached with mtime_ns=None;
# when it later appears, the mtime changes and the catalog is loaded again.
_DESCRIPTION_CACHE: tuple[str, int | None, dict[str, dict], str | None] | None = None

# 출처 후보에서 감점할 인터프리터·래퍼. python은 버전 접미사를 별도 정규식으로 처리한다.
_ORIGIN_WRAPPER_NAMES = frozenset({
    "sh", "bash", "env", "perl", "ruby", "node", "command", "test", "nice",
    "ionice", "timeout", "flock", "install", "find",
})
_ORIGIN_PYTHON_RE = re.compile(r"^python(?:[0-9]+(?:\.[0-9]+)*)?\Z")
_ORIGIN_REDIRECT_RE = re.compile(r"^(?:[0-9]+)?(?:>>?|<<|<>|>&|<&|>\|)(?:/|~/)")
_ORIGIN_REDIRECT_TOKENS = frozenset({">", ">>", "<", "<<", "<>", ">&", "<&", ">|"})
_ORIGIN_SHELL_WORDS = frozenset({
    "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if",
    "in", "then", "time", "until", "while",
})


# ---------------------------------------------------------------------------
# 프로세스 실행 (shell 없음 — argv 리스트만)
# ---------------------------------------------------------------------------


def run_cmd(argv: list[str], timeout: int = 15,
            cwd: str | None = None) -> tuple[int, str, str]:
    """(rc, stdout, stderr). 실행 자체가 불가하면 rc=-1 + stderr 에 이유."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                           shell=False, cwd=cwd)
    except FileNotFoundError as e:
        return -1, "", f"명령 없음: {e}"
    except subprocess.TimeoutExpired:
        return -1, "", f"시간 초과({timeout}s)"
    except OSError as e:
        return -1, "", str(e)
    return p.returncode, p.stdout, p.stderr


def systemctl(scope: str) -> list[str]:
    """scope 별 systemctl 접두 argv."""
    return ["systemctl", "--user"] if scope == "user" else ["systemctl"]


# ---------------------------------------------------------------------------
# 파서 (순수 함수 — 테스트 대상)
# ---------------------------------------------------------------------------


def parse_show_blocks(raw: str) -> list[dict[str, list[str]]]:
    """`systemctl show <여러 유닛>` 출력 → 유닛별 {key: [값...]}.

    블록 구분 = 빈 줄. TimersCalendar 처럼 같은 키가 여러 번 나오므로 값은 항상 리스트다.
    """
    blocks: list[dict[str, list[str]]] = []
    cur: dict[str, list[str]] = {}
    for line in raw.splitlines():
        if not line.strip():
            if cur:
                blocks.append(cur)
                cur = {}
            continue
        key, sep, val = line.partition("=")
        if not sep:
            continue
        cur.setdefault(key.strip(), []).append(val.strip())
    if cur:
        blocks.append(cur)
    return blocks


def first(props: dict[str, list[str]], key: str, default: str = "") -> str:
    vals = props.get(key)
    return vals[0] if vals else default


def parse_timestamp(raw: str) -> float | None:
    """systemd 타임스탬프 → epoch. 빈 값·미실행('n/a', '0')은 None."""
    raw = (raw or "").strip()
    if not raw or raw in ("n/a", "0"):
        return None
    if raw.startswith("@"):                       # --timestamp=unix 형식
        try:
            return float(raw[1:])
        except ValueError:
            return None
    m = _TS_RE.match(raw)
    if not m:
        return None
    try:
        dt = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")   # 로컬 TZ 로 해석
    except ValueError:
        return None
    return dt.timestamp()


def parse_duration(raw: str) -> float | None:
    """'6d 18h 46min 27.896260s' → 초. 인식 못 하면 None."""
    raw = (raw or "").strip()
    if not raw or raw in ("n/a", "infinity"):
        return None
    total = 0.0
    hit = False
    for num, unit in _DUR_RE.findall(raw):
        total += float(num) * _DUR_UNIT[unit]
        hit = True
    return total if hit else None


def exec_command(vals: list[str]) -> str:
    """ExecStart 속성값 → 사람이 읽는 명령줄."""
    for v in vals:
        m = _ARGV_RE.search(v)
        if m:
            return m.group(1).strip()
    return vals[0].strip() if vals else ""


def timer_schedule(props: dict[str, list[str]]) -> str:
    """타이머 스케줄을 사람이 읽는 한 줄로. OnCalendar 우선, 없으면 monotonic 조건."""
    parts: list[str] = []
    for v in props.get("TimersCalendar", []):
        m = re.search(r"OnCalendar=([^;}]+)", v)
        if m:
            parts.append(m.group(1).strip())
    if parts:
        return " · ".join(parts)
    for v in props.get("TimersMonotonic", []):
        m = re.search(r"(On\w+USec)=([^;}]+)", v)
        if m:
            parts.append(f"{m.group(1)[2:-4]} +{m.group(2).strip()}")   # OnBootUSec → 'Boot +2min'
    return " · ".join(parts)


# ---------------------------------------------------------------------------
# 크론 표현식 → 다음 실행 시각
# ---------------------------------------------------------------------------

_MONTHS = {n: i for i, n in enumerate(
    "jan feb mar apr may jun jul aug sep oct nov dec".split(), start=1)}
_DOWS = {n: i for i, n in enumerate("sun mon tue wed thu fri sat".split())}

# @nickname → 5필드 표현식 (@reboot 은 시각 개념이 없어 None)
CRON_NICKNAMES = {
    "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *", "@monthly": "0 0 1 * *",
    "@weekly": "0 0 * * 0", "@daily": "0 0 * * *", "@midnight": "0 0 * * *",
    "@hourly": "0 * * * *",
}


def _field_num(tok: str, names: dict[str, int] | None) -> int:
    tok = tok.strip().lower()
    if names and tok in names:
        return names[tok]
    return int(tok)          # ValueError 는 호출자로 전파 — 조용히 넘기지 않는다


def expand_field(spec: str, lo: int, hi: int, names: dict[str, int] | None = None) -> list[int]:
    """크론 필드 → 정렬된 정수 목록. 형식이 아니면 ValueError."""
    spec = spec.strip()
    if not spec:
        raise ValueError("빈 필드")
    out: set[int] = set()
    for part in spec.split(","):
        step = 1
        body = part
        if "/" in part:
            body, _, step_s = part.partition("/")
            step = int(step_s)
            if step <= 0:
                raise ValueError(f"step={step_s}")
        body = body.strip()
        if body == "*":
            start, end = lo, hi
        elif "-" in body:
            a, _, b = body.partition("-")
            start, end = _field_num(a, names), _field_num(b, names)
        else:
            start = _field_num(body, names)
            # Vixie 확장: 'N/step' 은 N 부터 상한까지. 'N' 단독은 그 값만.
            end = hi if step > 1 else start
        if start > end or start < lo or end > hi:
            raise ValueError(f"범위 밖: {part}")
        out.update(range(start, end + 1, step))
    if not out:
        raise ValueError(f"매치 없음: {spec}")
    return sorted(out)


def parse_cron_expr(expr: str) -> dict | None:
    """5필드 크론(또는 @nickname) → 매칭 집합. @reboot·해석 불가면 None."""
    expr = expr.strip()
    if expr.startswith("@"):
        expr = CRON_NICKNAMES.get(expr.split()[0].lower(), "")
        if not expr:
            return None
    toks = expr.split()
    if len(toks) < 5:
        return None
    try:
        mins = expand_field(toks[0], 0, 59)
        hours = expand_field(toks[1], 0, 23)
        doms = expand_field(toks[2], 1, 31)
        months = expand_field(toks[3], 1, 12, _MONTHS)
        dows = {d % 7 for d in expand_field(toks[4], 0, 7, _DOWS)}   # 7 = 일요일
    except ValueError:
        return None
    return {
        "min": mins, "hour": hours, "dom": doms, "month": months, "dow": sorted(dows),
        # Vixie 규칙: 필드가 '*' 또는 '*/n'으로 시작하면 STAR(무제한)다. dom·dow가
        # 둘 다 제한적이면 OR, 한쪽만 제한적이면 그쪽만 적용한다.
        "dom_restricted": not toks[2].strip().startswith("*"),
        "dow_restricted": not toks[4].strip().startswith("*"),
    }


_RUN_PARTS_RE = re.compile(r"run-parts\b[^;&|]*?(/etc/cron\.[a-z]+)")


def _owner_home() -> str | None:
    try:
        return pwd.getpwuid(os.getuid()).pw_dir
    except (KeyError, OSError):
        return None


def description_key(job: dict, *, home_dir: str | None = None) -> str:
    """잡 정의 그대로를 카탈로그 키로 바꾼다(렌더·판정과 무관한 순수 계산)."""
    kind = job.get("kind")
    if kind == "systemd":
        return "unit:" + str(job.get("unit") or "")
    if kind == "run-parts":
        return "runparts:" + str(job.get("command") or "")

    command = str(job.get("command") or "")
    owner_home = _owner_home() if home_dir is None else home_dir
    if owner_home:
        owner_home = owner_home.rstrip("/") or "/"
        if owner_home != "/":
            # 홈은 명령 안에서 여러 번 나온다 — 예: `… sweep.sh >> /home/alice/.cache/x.log`.
            # 앞부분만 치환하면 키에 박스별 경로가 남아 다른 박스에서 같은 잡이 매칭되지 않는다.
            # 경로 경계(앞이 문자열 시작이거나 경로문자가 아님)에서만 바꿔 우연한 부분일치를 피한다.
            command = re.sub(  # noqa: regex-anchor — escaped runtime home makes this dynamic.
                r"(?<![\w./~-])" + re.escape(owner_home) + r"(?=/|\s|\Z)", "~", command)
        elif command == owner_home:
            command = "~"
    return "cmd:" + command


def _description_path() -> str:
    override = os.environ.get("CRON_CONSOLE_DESCRIPTIONS")
    if override is not None:
        return override
    return os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", DESCRIPTION_FILE_KIND)


def _description_mtime(path: str) -> int | None:
    try:
        return os.stat(path).st_mtime_ns
    except OSError:
        return None


# 설명 본문의 유효 기준. "문자열이면 통과" 로 두면 공백·제어문자·1만자가 전부 설명 행세를 한다
# (적대 리뷰 프로브로 실측). 현재 실데이터는 15~84자 — 400자는 5배 여유이고, 넘으면 카탈로그를
# 고쳐야 할 데이터지 화면이 감당할 문장이 아니다. 설명은 한 문장이므로 개행·탭도 거부한다.
DESCRIPTION_MAX_LEN = 400
# note 는 설명보다 길 수 있다(실측 최대 174자). 다만 무한은 아니다 — 화면과 커밋에 그대로 들어간다.
NOTE_MAX_LEN = 1000
_DESCRIPTION_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")


def valid_description(value: object, *, max_len: int = DESCRIPTION_MAX_LEN) -> str | None:
    """유효한 설명이면 정규화된 문자열을, 아니면 None 을 준다. 판정 기준은 여기 한 곳뿐이다.

    `max_len` 만 달리해 note 에도 쓴다 — 카탈로그가 읽는 `note` 는 여러 줄 계약이라
    카탈로그 적용에는 쓰지 않고, **사람이 승인 화면에서 제출한 값**에만 적용한다.
    """
    if not isinstance(value, str):
        return None
    if _DESCRIPTION_CONTROL_RE.search(value):
        return None
    text = value.strip()
    if not text or len(text) > max_len:
        return None
    return text


def _read_description_catalog(path: str) -> tuple[dict[str, dict], str | None]:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return {}, f"파일 없음: {path}"
    except UnicodeDecodeError as e:
        return {}, f"인코딩 오류: {e.reason}"
    except json.JSONDecodeError as e:
        return {}, f"JSON 오류: {e.msg} (line {e.lineno}, column {e.colno})"
    except OSError as e:
        return {}, str(e)[:300] or type(e).__name__

    if not isinstance(data, dict):
        return {}, "최상위 JSON이 객체가 아닙니다"
    if data.get("schemaVersion") != DESCRIPTION_SCHEMA_VERSION:
        return {}, (
            f"schemaVersion 불일치: {data.get('schemaVersion')!r} "
            f"(expected {DESCRIPTION_SCHEMA_VERSION})"
        )
    entries = data.get("entries")
    if not isinstance(entries, dict):
        return {}, "entries가 객체가 아닙니다"
    if any(not isinstance(key, str) or not isinstance(value, dict)
           for key, value in entries.items()):
        return {}, "entries의 키·값 형식이 올바르지 않습니다"
    return entries, None


def load_description_catalog() -> tuple[dict[str, dict], dict]:
    """카탈로그를 생애 1회 읽고, 파일 mtime 변경 때만 다시 읽는다."""
    global _DESCRIPTION_CACHE
    path = _description_path()
    mtime = _description_mtime(path)
    if (_DESCRIPTION_CACHE is None
            or _DESCRIPTION_CACHE[0] != path
            or _DESCRIPTION_CACHE[1] != mtime):
        entries, error = _read_description_catalog(path)
        _DESCRIPTION_CACHE = (path, mtime, entries, error)

    _, _, entries, error = _DESCRIPTION_CACHE
    source = {
        "scope": "descriptions",
        "kind": DESCRIPTION_FILE_KIND,
        "ok": error is None,
    }
    if error is not None:
        source["error"] = error
    return entries, source


def invalidate_description_cache() -> None:
    """테스트·개발 중 강제 재읽기를 위한 내부 캐시 무효화."""
    global _DESCRIPTION_CACHE
    _DESCRIPTION_CACHE = None


def _evidence_content_hash(path: object) -> str:
    """실행 대상 파일의 머리 내용 해시. 레포 밖 스크립트는 커밋이 없어 내용이 바뀌어도
    경로·출처가 그대로다 — 그러면 "근거가 바뀌었는데 승인이 통과" 하는 구멍이 남는다."""
    if not isinstance(path, str) or not path:
        return "-"
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return "?"
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return "!"
        return hashlib.sha256(os.read(fd, 65536)).hexdigest()[:32]
    except OSError:
        return "?"
    finally:
        os.close(fd)


def evidence_fingerprint(job: dict) -> str:
    """이 잡의 **근거**가 바뀌었는지 판별하는 지문.

    키만으로는 부족하다 — 같은 `unit:foo.timer` 여도 ExecStart 나 스크립트 실체는 바뀐다.
    근거가 바뀌면 옛 초안·옛 거절은 더 이상 그 잡에 대한 판단이 아니므로 새 초안으로 인정한다.
    파일 내용까지 읽지는 않는다(비싸고, 실행 대상 경로·커밋이 바뀌면 origin 이 이미 달라진다).
    """
    origin = job.get("origin") or {}
    material = [
        str(job.get("descriptionKey") or description_key(job)),
        _evidence_content_hash(origin.get("path")),
        str(job.get("command") or ""),
        str(job.get("unit") or ""),
        str(job.get("source") or ""),
        str(origin.get("path") or ""),
        str(origin.get("repo") or ""),
        str(origin.get("package") or ""),
        str((origin.get("commit") or {}).get("date") or ""),
    ]
    return hashlib.sha256("\x00".join(material).encode("utf-8")).hexdigest()


def apply_descriptions(jobs: list[dict]) -> dict:
    """모든 잡에 카탈로그 필드를 붙이고 설명 source 상태를 반환한다.

    설명을 못 받은 사유는 셋이고 화면이 그걸 구분해야 한다 — 카탈로그를 못 읽은 것을
    "설명 없음"이라 말하면 사람이 "52개를 써야겠다"는 틀린 결론에 도달한다.
    `descriptionStatus` 가 그 진실을 말하고, `descriptionSource` 는 기존 의미를 유지한다
    (엔트리가 매칭되면 `note`·`sot` 는 실제로 카탈로그에서 온 것이므로).
    """
    entries, source = load_description_catalog()
    usable = bool(source["ok"])
    described = 0
    missing = 0
    invalid_jobs = 0
    for job in jobs:
        key = description_key(job)
        entry = entries.get(key)
        job["descriptionKey"] = key
        job["description"] = None
        job["descriptionNote"] = None
        job["descriptionSource"] = "none"
        job["sot"] = None
        if not usable:
            # 못 읽은 것을 없는 것이라고 단정하지 않는다.
            job["descriptionStatus"] = "catalog-unavailable"
            continue
        if isinstance(entry, dict):
            # validator 는 `what` 에만 적용한다. note·sot 는 계약이 다르다 —
            # note 는 여러 줄을 UI 가 `pre-wrap` 으로 보여주므로 개행을 거부하면 데이터를 버린다.
            job["description"] = valid_description(entry.get("what"))
            note = entry.get("note")
            job["descriptionNote"] = note if isinstance(note, str) else None
            sot = entry.get("sot")
            job["sot"] = sot if isinstance(sot, str) and sot else None
            job["descriptionSource"] = "catalog"
        if job["description"]:
            job["descriptionStatus"] = "described"
            described += 1
        elif isinstance(entry, dict):
            job["descriptionStatus"] = "invalid-entry"
            invalid_jobs += 1
        else:
            job["descriptionStatus"] = "missing"
            missing += 1
    if usable:
        # count = 로드된 엔트리 수 (다른 source 의 count 와 같은 뜻으로 맞춘다).
        source["count"] = len(entries)
        source["total"] = len(jobs)
        source["described"] = described
        source["missing"] = missing
        source["invalidJobs"] = invalid_jobs
    return source


def _origin_tokens(command: str) -> list[str]:
    """명령을 실행하지 않고 경로 후보를 뽑을 수 있게 셸 토큰만 분리한다."""
    try:
        lexer = shlex.shlex(str(command or ""), posix=True, punctuation_chars=";&|<>")
        lexer.whitespace_split = True
        lexer.commenters = ""
        return list(lexer)
    except ValueError:
        # 깨진 인용부호가 있어도 출처 수집 전체를 중단하지 않는다. 이 경우에도
        # 아래에서 which()에는 경로가 아닌 고정 토큰만 넘긴다.
        return str(command or "").split()


def _origin_wrapper(path: str) -> bool:
    name = os.path.basename(path.rstrip("/"))
    return name in _ORIGIN_WRAPPER_NAMES or bool(_ORIGIN_PYTHON_RE.fullmatch(name))


def _origin_path(raw: str) -> str | None:
    """경로를 realpath로 해소하고, 존재하며 안전한 경로만 반환한다."""
    if raw.startswith("~/"):
        owner_home = _owner_home()
        raw = os.path.join(owner_home, raw[2:]) if owner_home else os.path.expanduser(raw)
    if not raw.startswith("/"):
        return None
    raw_normalized = raw.rstrip("/") or "/"
    if raw_normalized == "/dev" or raw_normalized.startswith(("/dev/", "/proc/", "/sys/")):
        return None
    try:
        path = os.path.realpath(raw)
        normalized = path.rstrip("/") or "/"
        if (normalized == "/dev" or normalized.startswith(("/dev/", "/proc/", "/sys/"))
                or not os.path.exists(path)):
            return None
    except OSError:
        return None
    return path


def execution_path_candidates(command: str, *, fragment_path: str | None = None,
                              definition_path: str | None = None) -> list[dict]:
    """명령에서 실행 대상 후보를 뽑는다.

    반환값은 명령 순서(`order`), realpath(`path`), 래퍼 여부(`interpreter`)와
    후보 출처(`kind`)만 가진다. subprocess를 호출하지 않으므로 후보 선정과
    점수화 자체를 모킹 없이 검증할 수 있다.
    """
    tokens = _origin_tokens(command)
    candidates: list[dict] = []
    redirect_pending = False
    for index, token in enumerate(tokens):
        if token in _ORIGIN_REDIRECT_TOKENS:
            redirect_pending = True
            continue
        if redirect_pending:
            if token == "&":
                continue
            redirect_pending = False
            continue
        if _ORIGIN_REDIRECT_RE.match(token):
            continue
        raw = token if token.startswith(("/", "~/")) else None
        if raw is None:
            continue
        path = _origin_path(raw)
        if path is None:
            continue
        candidates.append({
            "path": path,
            "kind": "command",
            "interpreter": _origin_wrapper(path),
            "order": index,
        })

    # /dev/null만 남는 sysstat 형태처럼 usable 절대경로가 없을 때만 PATH를
    # 사용한다. 사용자 명령의 토큰을 argv로 넘기지 않고, which가 반환한 검증된
    # 파일 경로만 이후 dpkg/git 호출에 사용한다.
    if not candidates:
        for index, token in enumerate(tokens):
            if (not token or token in _ORIGIN_SHELL_WORDS or token in _ORIGIN_REDIRECT_TOKENS
                    or token.startswith("-") or "=" in token or "/" in token):
                continue
            if _origin_wrapper(token):
                continue
            try:
                found = shutil.which(token)
            except (OSError, TypeError):
                found = None
            if not found:
                continue
            path = _origin_path(found)
            if path is not None:
                candidates.append({
                    "path": path,
                    "kind": "which",
                    "interpreter": _origin_wrapper(path),
                    "order": index,
                })
            break

    fragment = _origin_path(str(fragment_path or ""))
    if fragment is not None:
        candidates.append({
            "path": fragment,
            "kind": "fragment",
            "interpreter": False,
            "order": -1,
        })

    # 최후 폴백: 이 잡을 **정의한 파일**(`/etc/cron.d/sysstat`·`/etc/crontab`).
    # 실행 대상을 못 찾는 경우가 실제로 있다 — 실측: `/etc/cron.d/sysstat` 의
    # `command -v debian-sa1 … && debian-sa1 1 1` 은 그 파일이 자체 `PATH=/usr/lib/sysstat:…`
    # 를 설정해 cron 컨텍스트에서만 해소된다(우리 프로세스 PATH 에는 없어 which 실패).
    # 이때 "이 크론 항목을 심은 패키지·레포" 는 정의 파일로 정확히 답할 수 있다.
    definition = _origin_path(str(definition_path or ""))
    if definition is not None:
        candidates.append({
            "path": definition,
            "kind": "definition",
            "interpreter": False,
            "order": -2,
        })
    return candidates


def origin_candidate_score(candidate: dict, *, in_repo: bool = False) -> int:
    """출처 후보 점수. repo > 실파일 > 래퍼 > FragmentPath > 정의파일 순이다.

    정의파일이 가장 낮다 — "무엇이 실행되나" 보다 약한 근거이고(그 파일이 심은 항목일 뿐),
    실행 대상을 찾은 경우에는 쓰지 않는다.
    """
    if candidate.get("kind") == "definition":
        return -1
    if candidate.get("kind") == "fragment":
        return 0
    if in_repo:
        return 3
    return 1 if candidate.get("interpreter") else 2


def select_origin_candidate(candidates: list[dict], git_roots: dict[str, str | None]) -> dict | None:
    """후보 중 최고 점수를 고른다. 동점이면 명령에서 뒤에 온 후보를 고른다."""
    if not candidates:
        return None
    return max(
        candidates,
        key=lambda candidate: (
            origin_candidate_score(candidate, in_repo=bool(git_roots.get(candidate["path"]))),
            int(candidate.get("order", -1)),
        ),
    )


def git_root_for_path(path: str) -> str | None:
    """파일·디렉토리 후보에서 위로 올라가 `.git`(파일 또는 디렉토리)을 찾는다."""
    try:
        current = path if os.path.isdir(path) else os.path.dirname(path)
    except OSError:
        return None
    while current:
        try:
            if os.path.exists(os.path.join(current, ".git")):
                return current
        except OSError:
            return None
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    return None


def _repo_name(root: str, remote: str) -> str:
    remote = remote.strip().rstrip("/")
    if remote:
        name = re.split(r"[/\\:]", remote)[-1]
        if name.endswith(".git"):
            name = name[:-4]
        if name:
            return name
    return os.path.basename(root.rstrip(os.sep)) or root


def _origin_reason(value: object, fallback: str) -> str:
    text = re.sub(r"\s+", " ", str(value or "")).strip()
    return text[:240] or fallback


def _git_remote(root: str, cache: dict[str, str]) -> str:
    if root in cache:
        return cache[root]
    try:
        rc, out, _err = run_cmd(
            ["git", "-C", root, "config", "--get", "remote.origin.url"], timeout=10)
    except Exception:
        rc, out = -1, ""
    remote = out.strip().splitlines()[0] if rc == 0 and out.strip() else ""
    name = _repo_name(root, remote)
    cache[root] = name
    return name


def _git_commit(root: str, rel_path: str, cache: dict[tuple[str, str], tuple[dict | None, str | None]]) -> tuple[dict | None, str | None]:
    key = (root, rel_path)
    if key in cache:
        return cache[key]
    try:
        rc, out, err = run_cmd(
            [
                "git", "-C", root, "log", "-1", "--format=%an|%ae|%ad|%s",
                "--date=short", "--", rel_path,
            ],
            timeout=15,
        )
    except Exception as e:
        rc, out, err = -1, "", str(e)
    if rc != 0:
        result = (None, f"git log 실패: {_origin_reason(err or out, f'rc={rc}')}")
        cache[key] = result
        return result
    line = out.splitlines()[0].rstrip("\r") if out.splitlines() else ""
    parts = line.split("|", 3)
    if len(parts) != 4:
        result = (None, "git log 결과를 해석할 수 없습니다")
        cache[key] = result
        return result
    name, email, commit_date, subject = parts
    author = f"{name} <{email}>" if email else name
    result = ({"author": author, "date": commit_date, "subject": subject}, None)
    cache[key] = result
    return result


def parse_dpkg_search(raw: str) -> dict[str, str]:
    """`dpkg -S` 출력에서 realpath별 첫 패키지를 뽑는다."""
    packages: dict[str, str] = {}
    for line in raw.splitlines():
        package_part, separator, path_part = line.partition(": ")
        if not separator or not path_part.strip():
            continue
        package = package_part.split(",", 1)[0].strip()
        if not package:
            continue
        raw_path = path_part.strip()
        if not raw_path.startswith("/"):
            continue
        try:
            path = os.path.realpath(raw_path)
            normalized = path.rstrip("/") or "/"
            if normalized == "/dev" or normalized.startswith(("/dev/", "/proc/", "/sys/")):
                continue
        except OSError:
            continue
        packages[path] = package
    return packages


def _dpkg_packages(paths: list[str]) -> tuple[dict[str, str], str | None]:
    if not paths:
        return {}, None
    try:
        rc, out, err = run_cmd(["dpkg", "-S", *paths], timeout=30)
    except Exception as e:
        return {}, f"dpkg -S 실패: {_origin_reason(e, type(e).__name__)}"
    packages = parse_dpkg_search(out)
    if rc != 0:
        detail = _origin_reason(err or out, f"rc={rc}")
        # dpkg-query는 등록이 없는 경로를 질의하면 rc=1을 낸다. 일부 경로만
        # 매칭된 경우에도 stdout의 유효한 결과는 보존하고 나머지는 패키지 없음이다.
        if rc == 1:
            return packages, None
        return packages, f"dpkg -S 실패: {detail}"
    return packages, None


def _unresolved_origin(path: str | None, reason: str) -> dict:
    return {
        "kind": "unresolved", "path": path, "repo": None, "relPath": None,
        "commit": None, "package": None, "reason": reason,
    }


def _repo_origin(path: str, root: str, repo: str, rel_path: str, commit: dict) -> dict:
    return {
        "kind": "repo", "path": path, "repo": repo, "relPath": rel_path,
        "commit": commit, "package": None, "reason": None,
    }


def _package_origin(path: str, package: str) -> dict:
    return {
        "kind": "package", "path": path, "repo": None, "relPath": None,
        "commit": None, "package": package, "reason": None,
    }


def _job_definition_path(job: dict) -> str | None:
    """이 잡을 정의한 파일의 절대경로. 개인 crontab 은 spool 이라 파일 경로가 없다(None)."""
    source = str(job.get("source") or "")
    return source if source.startswith("/") else None


def apply_origins(jobs: list[dict]) -> None:
    """모든 잡에 파일·레포·패키지 출처를 붙인다(스냅샷당 한 번)."""
    git_roots: dict[str, str | None] = {}
    selected: list[tuple[dict, dict | None, str | None]] = []
    package_paths: list[str] = []
    package_path_set: set[str] = set()

    for job in jobs:
        try:
            candidates = execution_path_candidates(
                str(job.get("command") or ""),
                fragment_path=job.get("_fragmentPath"),
                definition_path=_job_definition_path(job),
            )
            for candidate in candidates:
                path = candidate["path"]
                if path not in git_roots:
                    git_roots[path] = git_root_for_path(path)
            candidate = select_origin_candidate(candidates, git_roots)
            root = git_roots.get(candidate["path"]) if candidate else None
            selected.append((job, candidate, root))
            if candidate is not None and root is None and candidate["path"] not in package_path_set:
                package_path_set.add(candidate["path"])
                package_paths.append(candidate["path"])
        except (OSError, TypeError, ValueError) as e:
            selected.append((job, None, None))
            job["origin"] = _unresolved_origin(
                None, f"출처 후보 해석 실패: {_origin_reason(e, type(e).__name__)}")

    packages, package_error = _dpkg_packages(package_paths)
    remote_cache: dict[str, str] = {}
    commit_cache: dict[tuple[str, str], tuple[dict | None, str | None]] = {}
    for job, candidate, root in selected:
        if "origin" in job:
            continue
        if candidate is None:
            job["origin"] = _unresolved_origin(None, "실행 대상 경로를 찾지 못했습니다")
            continue
        path = candidate["path"]
        if root is not None:
            try:
                rel_path = os.path.relpath(path, root)
            except ValueError:
                job["origin"] = _unresolved_origin(path, "레포 상대 경로를 만들 수 없습니다")
                continue
            repo = _git_remote(root, remote_cache)
            commit, error = _git_commit(root, rel_path, commit_cache)
            if error is not None or commit is None:
                job["origin"] = _unresolved_origin(path, error or "git log 결과가 없습니다")
                continue
            job["origin"] = _repo_origin(
                path, root, repo, rel_path, commit)
            continue
        package = packages.get(path)
        if package is not None:
            job["origin"] = _package_origin(path, package)
        elif package_error is not None:
            job["origin"] = _unresolved_origin(path, package_error)
        else:
            job["origin"] = _unresolved_origin(path, "git 레포와 dpkg 패키지를 찾지 못했습니다")


def cron_job_label(command: str, source: str) -> str:
    """cron 명령 → 목록에 쓸 짧은 이름.

    첫 토큰을 쓰면 'cd'·'test'·'command' 같은 껍데기가 잡힌다(`cd / && run-parts ...`).
    ① run-parts 대상 디렉토리
    ② cron.d 파일명 — 패키지가 잡 이름으로 지은 것이라 명령 파싱보다 정확하다. 명령 앞의
       가드 절에 나오는 경로(`test -e /run/systemd/system`·`> /dev/null`)는 실행 대상이 아니라
       거기서 이름을 뽑으면 'system'·'null' 같은 헛이름이 나온다.
    ③ 명령 안 첫 절대경로의 파일명 — 개인 crontab(파일 하나에 여러 잡)은 이 경로가 곧 정체다.
    ④ 첫 토큰
    """
    m = _RUN_PARTS_RE.search(command)
    if m:
        return os.path.basename(m.group(1))
    if source.startswith("/") and source != CRONTAB_FILE:
        return os.path.basename(source)
    for tok in command.split():
        tok = tok.strip("'\"[](){};&|")
        if tok.startswith("/") and len(tok) > 1:
            return os.path.basename(tok.rstrip("/"))
    return command.split()[0] if command.split() else "?"


def _day_matches(d: date, m: dict) -> bool:
    if d.month not in m["month"]:
        return False
    dom_hit = d.day in m["dom"]
    dow_hit = (d.weekday() + 1) % 7 in m["dow"]      # date.weekday(): 월=0 → 크론: 일=0
    if m["dom_restricted"] and m["dow_restricted"]:
        return dom_hit or dow_hit
    if m["dom_restricted"]:
        return dom_hit
    if m["dow_restricted"]:
        return dow_hit
    return True


def cron_next_epoch(expr: str, now_epoch: float) -> float | None:
    """크론 표현식의 다음 실행 epoch. 해석 불가·1년 내 없음이면 None(= UI 에 '계산 불가')."""
    m = parse_cron_expr(expr)
    if not m:
        return None
    now = datetime.fromtimestamp(now_epoch).replace(second=0, microsecond=0)
    floor = now + timedelta(minutes=1)
    day = floor.date()
    for i in range(367):
        if _day_matches(day, m):
            for h in m["hour"]:
                for mi in m["min"]:
                    cand = datetime(day.year, day.month, day.day, h, mi)
                    if (i > 0) or cand >= floor:
                        return cand.timestamp()
        day += timedelta(days=1)
    return None


def cron_prev_epoch(expr: str, now_epoch: float) -> float | None:
    """크론 표현식의 직전 실행 epoch. 해석 불가·1년 내 없음이면 None."""
    m = parse_cron_expr(expr)
    if not m:
        return None
    now = datetime.fromtimestamp(now_epoch).replace(second=0, microsecond=0)
    day = now.date()
    for i in range(367):
        if _day_matches(day, m):
            for hour in reversed(m["hour"]):
                for minute in reversed(m["min"]):
                    candidate = datetime(day.year, day.month, day.day, hour, minute)
                    if i > 0 or candidate <= now:
                        return candidate.timestamp()
        day -= timedelta(days=1)
    return None


# ---------------------------------------------------------------------------
# 판정 (순수 함수)
# ---------------------------------------------------------------------------


def service_result(result: str, last_run: float | None) -> str:
    """서비스의 마지막 결과 → ``success`` | ``failed`` | ``unknown`` | ``none``.

    판정 권위는 systemd 의 `Result` 다. `ExecMainStatus`(종료코드)는 참고값일 뿐 —
    유닛이 `SuccessExitStatus=` 로 0 아닌 종료를 성공으로 선언할 수 있다. 실측:
    gate-audit-sweep-user 는 warn 이 있으면 exit 1 을 내고 유닛이 `SuccessExitStatus=1` 로
    그걸 성공으로 규정한다 — 종료코드만 보면 멀쩡히 도는 잡이 '실패'로 뒤집힌다.
    """
    # 실행 여부를 먼저 본다 — 한 번도 안 돈 유닛도 Result 초기값이 'success' 라(fstrim·fwupd-refresh
    # 등 실측) Result 를 먼저 검사하면 안 돈 잡이 성공으로 둔갑한다.
    if last_run is None:
        return "none"
    if result == "success":
        return "success"
    if not result or result in ("n/a", "none", "unknown"):
        return "unknown"
    return "failed"


def judge(
    *,
    enabled: bool,
    last_run: float | None,
    next_run: float | None,
    last_result: str,
    boot_epoch: float | None,
    now_epoch: float,
    unit_file_state: str | None = None,
) -> dict[str, str | float | None]:
    """systemd 타이머의 축별 판정.

    ``Result`` 는 호출자가 이미 ``service_result`` 로 정규화해 넣는다. 타이머 발화와
    서비스 결과를 섞지 않으며, 마지막 발화가 없는 유닛은 Result 초기값만으로 관측됐다고
    판정하지 않는다.
    """
    if last_run is None:
        last_result = "none"
    execution = "observed" if last_run is not None else "unobserved"
    if next_run is not None and now_epoch > next_run + LATE_GRACE_SEC:
        # 기존 systemd 판정의 회귀 지점: 마지막 발화가 있어도 다음 예정시각을
        # grace 이상 넘겼으면 시의성은 늦음이다.
        timeliness = "late"
        last_due = next_run
    elif last_run is not None:
        timeliness = "on-time"
        last_due = last_run
    elif next_run is None:
        timeliness = "unknown"
        last_due = None
    else:
        timeliness = "pending"
        last_due = None

    unsafe_states = {"disabled", "masked", "not-found"}
    if unit_file_state in unsafe_states or (unit_file_state is None and not enabled):
        reboot = "unsafe"
    elif last_result == "success" and last_run is not None and boot_epoch is not None \
            and last_run > boot_epoch:
        reboot = "postboot-observed"
    elif boot_epoch is None:
        reboot = "unknown"
    else:
        reboot = "configured-unobserved"

    return {
        "execution": execution,
        "timeliness": timeliness,
        "lastDue": last_due,
        "lastResult": last_result,
        "reboot": reboot,
    }


# ---------------------------------------------------------------------------
# 수집
# ---------------------------------------------------------------------------


def boot_epoch() -> float | None:
    """/proc/stat btime — TZ 무관 절대 epoch. 재부팅 생존 판정의 기준선."""
    try:
        with open("/proc/stat") as f:
            for line in f:
                if line.startswith("btime "):
                    return float(line.split()[1])
    except (OSError, ValueError, IndexError):
        return None
    return None


def normalize_boot_id(value: str | None) -> str | None:
    """boot id 를 비교 가능한 한 형태로. 🔴 커널과 journal 의 표기가 다르다 — 실측:
    `/proc/sys/kernel/random/boot_id` = `87892b07-4cfb-40fa-ab32-478a532979d6`(하이픈),
    journal `_BOOT_ID` = `87892b074cfb40faab32478a532979d6`(하이픈 없음). 그대로 비교하면
    영구히 거짓이 되어 재부팅 축이 조용히 `configured-unobserved` 로 떨어진다.
    """
    if not isinstance(value, str):
        return None
    return value.strip().replace("-", "").lower() or None


def current_boot_id() -> str | None:
    """현재 부팅의 journal `_BOOT_ID`와 비교할 커널 boot id (표기 정규화 후)."""
    try:
        with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as f:
            value = f.read().strip()
    except (OSError, UnicodeError):
        return None
    return normalize_boot_id(value)


_CRON_MESSAGE_RE = re.compile(r"^\(([^()]+)\) CMD \((.*)\)\Z")


def render_cron_command(command: str) -> str:
    """정의 command를 cron journal MESSAGE의 CMD 괄호 안 형태로 렌더한다.

    journal의 octal escape는 역으로 해석하지 않는다. ``\\141``이 원래 문자 ``a``인지
    리터럴 백슬래시와 숫자인지는 journal에 남은 정보만으로 구분할 수 없기 때문이다.
    대신 cron이 정의를 기록할 때 수행하는 손실 없는 방향을 그대로 적용한다.

    1. 백슬래시 짝수 개가 앞선 첫 ``%``에서 command를 자른다.
    2. ``\\%``와 ``\\\\``만 각각 ``%``와 ``\\``로 바꾸고 다른 백슬래시는 보존한다.
    3. UTF-8 바이트 중 printable ASCII 밖의 값은 세 자리 8진 escape로 쓴다.
    """
    prefix: list[str] = []
    i = 0
    while i < len(command):
        if command[i] == "%":
            slash_count = 0
            j = i - 1
            while j >= 0 and command[j] == "\\":
                slash_count += 1
                j -= 1
            if slash_count % 2 == 0:
                break
        prefix.append(command[i])
        i += 1

    unescaped: list[str] = []
    i = 0
    while i < len(prefix):
        if prefix[i] == "\\" and i + 1 < len(prefix):
            if prefix[i + 1] in ("%", "\\"):
                unescaped.append(prefix[i + 1])
                i += 2
                continue
        unescaped.append(prefix[i])
        i += 1

    encoded = "".join(unescaped).encode("utf-8")
    return "".join(
        chr(byte) if 0x20 <= byte <= 0x7E else f"\\{byte:03o}"
        for byte in encoded
    )


def parse_cron_message(message: str) -> tuple[str, str] | None:
    """``(user) CMD (command)``만 파싱하고 journal command 원문을 보존한다."""
    match = _CRON_MESSAGE_RE.fullmatch(message)
    if not match:
        return None
    return match.group(1), match.group(2)


def parse_cron_journal_records(
    raw: str,
) -> tuple[dict[tuple[str, str], list[dict[str, str | float | None]]], int, float | None]:
    """journal JSON lines를 ``(user, raw command) -> events`` 인덱스로 바꾼다.

    반환값은 ``(events, malformed, minimum_timestamp)``다. 한 레코드의 JSON·필드 오류는
    그 레코드만 malformed로 세고 계속 진행한다. 전체 journal 명령의 실패는 이 함수가
    아니라 ``collect_cron_journal``의 source ``ok=False`` 경계에서 표현한다.
    """
    events: dict[tuple[str, str], list[dict[str, str | float | None]]] = {}
    malformed = 0
    minimum_timestamp: float | None = None
    for _lineno, line in enumerate(raw.splitlines(), start=1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
            if not isinstance(record, dict):
                raise ValueError("JSON record is not an object")
            timestamp = record.get("__REALTIME_TIMESTAMP")
            ts = float(str(timestamp).strip()) / 1_000_000
            if ts < 0 or not math.isfinite(ts):
                raise ValueError("invalid timestamp")
            if minimum_timestamp is None or ts < minimum_timestamp:
                minimum_timestamp = ts

            message = record.get("MESSAGE")
            if not isinstance(message, str):
                raise ValueError("MESSAGE is not a string")
            parsed = parse_cron_message(message)
            if parsed is None:
                continue

            boot_id = record.get("_BOOT_ID")
            if boot_id is not None and not isinstance(boot_id, str):
                raise ValueError("invalid boot id")
            events.setdefault(parsed, []).append({"ts": ts, "boot_id": boot_id})
        except Exception:
            # 한 레코드의 JSON·필드·파서 예외가 이미 모은 이벤트를 폐기하지 않게 한다.
            malformed += 1
            continue

    for values in events.values():
        values.sort(key=lambda event: float(event["ts"]))
    return events, malformed, minimum_timestamp


def parse_cron_journal(raw: str) -> dict[tuple[str, str], list[dict[str, str | float | None]]]:
    """호환용 순수 파서 — malformed 통계가 필요하면 ``parse_cron_journal_records``를 쓴다."""
    return parse_cron_journal_records(raw)[0]


def _journal_source(*, btime: float | None, end: float, ok: bool = True) -> dict:
    source = {
        "scope": "cron-journal",
        "kind": "sudo journalctl -t CRON",
        "ok": ok,
        "count": 0,
        "malformed": 0,
        "coverageStart": None,
        "coverageEnd": end,
        "empty": True,
    }
    return source


def journal_argv(btime: float) -> list[str]:
    """cron journal 수집에 사용하는 고정 argv."""
    sudo = os.environ.get("CRON_CONSOLE_SUDO", SUDO)
    journalctl = os.environ.get("CRON_CONSOLE_JOURNALCTL", JOURNALCTL)
    return [
        sudo, "-n", "--", journalctl,
        "-t", "CRON", "-o", "json", "--no-pager", "--all",
        "--since", f"@{int(btime)}",
        "--output-fields=MESSAGE,_BOOT_ID,__REALTIME_TIMESTAMP",
    ]


def collect_cron_journal(
    btime: float | None, now: float | None = None,
) -> tuple[dict[tuple[str, str], list[dict[str, str | float | None]]], dict]:
    """현재 부팅 이후 CRON journal을 수집한다.

    명령 전체 실패는 소스에 남기고 빈 인덱스를 반환한다. 개별 JSON 레코드 오류는
    ``malformed``로 세고 유효한 이벤트와 실제 관측 시작점을 보존한다.
    """
    end = time.time() if now is None else now
    source = _journal_source(btime=btime, end=end)
    if btime is None:
        source.update(ok=False, error="btime을 읽지 못해 journal 범위를 만들 수 없습니다")
        return {}, source

    try:
        rc, out, err = run_cmd(journal_argv(btime), timeout=30)
    except Exception as e:  # 주입된 실행기 예외도 HTTP 부분결과 경계를 넘지 않게 한다.
        if now is None:
            source["coverageEnd"] = time.time()
        source.update(ok=False, error=str(e)[:300] or type(e).__name__)
        return {}, source
    if now is None:
        source["coverageEnd"] = time.time()
    if rc != 0:
        source.update(ok=False, error=(err or out).strip()[:300] or f"rc={rc}")
        return {}, source
    try:
        index, malformed, minimum_timestamp = parse_cron_journal_records(out)
    except Exception as e:
        if now is None:
            source["coverageEnd"] = time.time()
        source.update(ok=False, error=str(e)[:300] or "journal 파싱 실패")
        return {}, source
    if now is None:
        source["coverageEnd"] = time.time()
    source["count"] = sum(len(values) for values in index.values())
    source["malformed"] = malformed
    if minimum_timestamp is not None:
        source["coverageStart"] = max(btime, minimum_timestamp)
        source["empty"] = False
    return index, source


def collect_cron_service() -> tuple[dict, dict]:
    """cron.service의 재부팅 구성상태와 활성화 시각을 읽는다."""
    source = {
        "scope": "cron-service",
        "kind": "systemctl show cron.service",
        "ok": True,
        "count": 1,
    }
    rc, out, err = run_cmd(
        ["systemctl", "show", "cron.service", "-p", CRON_SERVICE_PROPS], timeout=15)
    if rc != 0:
        source.update(ok=False, error=(err or out).strip()[:300] or f"rc={rc}")
        return {"unitFileState": None, "activeSince": None}, source
    props = parse_show_blocks(out)
    if not props:
        source.update(ok=False, error="cron.service 속성이 비어 있습니다")
        return {"unitFileState": None, "activeSince": None}, source
    block = props[0]
    state = first(block, "UnitFileState") or None
    active_since = parse_timestamp(first(block, "ActiveEnterTimestamp"))
    if state is None:
        source.update(ok=False, error="cron.service UnitFileState가 없습니다")
    return {"unitFileState": state, "activeSince": active_since}, source


def collect_systemd(scope: str, boot: float | None, now: float) -> tuple[list[dict], dict]:
    """systemd 타이머 전수(scope='user'|'system'). (jobs, source) — 예외를 밖으로 내지 않는다."""
    sc = systemctl(scope)
    src: dict = {"scope": scope, "kind": "systemd timer", "ok": True, "count": 0}
    rc, out, err = run_cmd(sc + ["list-timers", "--all", "--no-pager"])
    if rc != 0:
        src.update(ok=False, error=(err or out).strip()[:300] or f"rc={rc}")
        return [], src

    units = sorted(set(TIMER_RE.findall(out)))
    if not units:
        return [], src

    rc, out, err = run_cmd(sc + ["show"] + units + ["-p", TIMER_PROPS], timeout=30)
    if rc != 0:
        src.update(ok=False, error=(err or "").strip()[:300] or f"show rc={rc}")
        return [], src
    timers = {first(b, "Id"): b for b in parse_show_blocks(out) if first(b, "Id")}

    # 타이머가 실제로 켜는 유닛 = Unit 속성(기본은 동명 .service). 그쪽에서 실행 결과를 읽는다.
    svc_names = sorted({first(t, "Unit") or u[:-6] + ".service" for u, t in timers.items()})
    services: dict[str, dict[str, list[str]]] = {}
    if svc_names:
        rc, out, err = run_cmd(sc + ["show"] + svc_names + ["-p", SERVICE_PROPS], timeout=30)
        if rc == 0:
            services = {first(b, "Id"): b for b in parse_show_blocks(out) if first(b, "Id")}
        else:
            src["serviceError"] = (err or "").strip()[:200] or f"show rc={rc}"

    jobs: list[dict] = []
    for unit in units:
        t = timers.get(unit, {})
        svc_name = first(t, "Unit") or unit[:-6] + ".service"
        s = services.get(svc_name, {})

        unit_file_state = first(t, "UnitFileState")
        # static 타이머는 enable 개념이 없다 — .wants 에 걸려 부팅 시 함께 오므로 활성이면 안전한 쪽.
        enabled = unit_file_state == "enabled" or (
            unit_file_state == "static" and first(t, "ActiveState") == "active"
        )

        last_run = parse_timestamp(first(t, "LastTriggerUSec"))
        next_run = parse_timestamp(first(t, "NextElapseUSecRealtime"))
        if next_run is None:
            # 간격 타이머(OnBootSec·OnUnitActiveSec)는 monotonic 으로만 답한다 → btime 기준 환산.
            mono = parse_duration(first(t, "NextElapseUSecMonotonic"))
            if mono is not None and boot is not None:
                next_run = boot + mono

        exit_status = first(s, "ExecMainStatus")
        last_result = service_result(first(s, "Result"), last_run)
        # 조건(ConditionPathExists 등) 미충족으로 건너뛴 실행도 systemd 는 성공으로 친다.
        # 결과 축은 systemd Result를 따르되, 건너뛴 사실은 별도 필드에 남긴다.
        condition_met = first(s, "ConditionResult") != "no"

        started = parse_timestamp(first(s, "ExecMainStartTimestamp"))
        exited = parse_timestamp(first(s, "ExecMainExitTimestamp"))
        duration = (exited - started) if (started is not None and exited is not None
                                         and exited >= started) else None

        axes = judge(
            enabled=enabled, last_run=last_run, next_run=next_run,
            last_result=last_result, boot_epoch=boot, now_epoch=now,
            unit_file_state=unit_file_state,
        )
        jobs.append({
            "id": f"{scope}:{unit}",
            "scope": scope,
            "kind": "systemd",
            "name": unit[:-6],
            "unit": unit,
            "service": svc_name,
            "description": first(t, "Description") or first(s, "Description"),
            "schedule": timer_schedule(t),
            "command": exec_command(s.get("ExecStart", [])),
            "_fragmentPath": first(t, "FragmentPath") or first(s, "FragmentPath") or None,
            "enabled": enabled,
            "unitFileState": unit_file_state,
            "activeState": first(t, "ActiveState"),
            "serviceActiveState": first(s, "ActiveState"),
            "lastRun": last_run,
            "nextRun": next_run,
            "lastResult": last_result,
            "exitStatus": int(exit_status) if exit_status.isdigit() else None,
            "conditionMet": condition_met,
            "durationSec": duration,
            "execution": axes["execution"],
            "timeliness": axes["timeliness"],
            "lastDue": axes["lastDue"],
            "lastSignal": last_run,
            "lastSignalKind": "direct" if last_run is not None else "none",
            "matchQuality": "exact" if last_run is not None else "none",
            "reboot": axes["reboot"],
            "controllable": scope == "user",       # system 은 sudo 없어 조회만
            "logs": scope == "user",               # logs API 는 user journal 만 제공
            "source": f"systemctl {'--user ' if scope == 'user' else ''}list-timers",
        })
    src["count"] = len(jobs)
    return jobs, src


def parse_cron_text(
    text: str, *, source: str, scope: str, has_user_field: bool,
    default_user: str, now: float, definition_mtime: float | None = None,
) -> tuple[list[dict], list[str]]:
    """crontab 형식 텍스트 → (jobs, 해석 실패 줄 목록).

    환경변수 줄(`NAME=value`)·주석·빈 줄은 건너뛴다. 명령 뒤의 `#` 은 cron 이 주석으로
    다루지 않으므로(셸에 그대로 전달) 자르지 않는다 — 보이는 대로가 실제다.
    """
    jobs: list[dict] = []
    bad: list[str] = []
    cron_tz = False
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        head = line.split()[0]
        assignment = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=", line)
        if assignment:
            if assignment.group(1) == "CRON_TZ":
                cron_tz = True
            # SHELL=/bin/sh 등. CRON_TZ는 해당 지점 이후 시각 해석을 보류한다.
            continue

        if head.startswith("@"):
            # 앞쪽 구분 공백은 무시하되 마지막 command의 trailing space는 journal 귀속을
            # 위해 보존한다.
            toks = raw_line.split(None, 2 if has_user_field else 1)
            expr = head
            rest = toks[2] if (has_user_field and len(toks) > 2) else (
                toks[1] if len(toks) > 1 else "")
            user = toks[1] if (has_user_field and len(toks) > 1) else default_user
        else:
            nfields = 6 if has_user_field else 5
            toks = raw_line.split(None, nfields)
            if len(toks) <= nfields:
                bad.append(line[:200])
                continue
            expr = " ".join(toks[:5])
            user = toks[5] if has_user_field else default_user
            rest = toks[nfields]

        next_run = None if expr.lower().startswith("@reboot") else cron_next_epoch(expr, now)
        jobs.append({
            "id": f"{scope}:{source}:{len(jobs)}",
            "scope": scope,
            "kind": "cron",
            "name": cron_job_label(rest, source),
            "unit": None,
            "service": None,
            "description": "",
            "schedule": expr,
            "command": rest,
            "user": user,
            "enabled": True,                 # crontab 에 있으면 cron 이 읽는다(주석이면 위에서 걸림)
            "unitFileState": "",
            "activeState": "",
            "lastRun": None,
            "nextRun": next_run,
            "lastResult": "none",
            "exitStatus": None,
            "durationSec": None,
            "execution": "unobserved",
            "timeliness": "unknown" if cron_tz else "pending",
            "lastDue": None if cron_tz else cron_prev_epoch(expr, now),
            "lastSignal": None,
            "lastSignalKind": "none",
            "matchQuality": "none",
            "reboot": "unknown",
            "controllable": False,
            "logs": False,
            "source": source,
            "_cronExpr": expr,
            "_cronTz": cron_tz,
            "_definitionMtime": definition_mtime,
        })
        run_parts = _RUN_PARTS_RE.search(rest)
        if run_parts:
            jobs[-1]["_runPartsDir"] = run_parts.group(1)
    return jobs, bad


def collect_crontab(now: float) -> tuple[list[dict], dict]:
    """소유자 개인 crontab. `crontab -l` 은 잡이 없으면 rc=1 — 실패와 구분한다."""
    uid = os.getuid()
    try:
        user = pwd.getpwuid(uid).pw_name
        user_fallback = None
    except (KeyError, OSError) as e:
        # 환경변수 USER를 쓰면 서비스 환경 오염 때 journal attribution key가 어긋난다.
        # passwd 조회도 실패하면 UID를 명시해 오귀속을 피한다.
        user = f"uid:{uid}"
        user_fallback = str(e)[:200] or type(e).__name__
    src: dict = {"scope": "crontab", "kind": f"crontab -l ({user})", "ok": True, "count": 0}
    if user_fallback:
        src["userFallback"] = user_fallback
        src["attributionOk"] = False
    rc, out, err = run_cmd(["crontab", "-l"])
    if rc != 0:
        msg = (err or "").strip()
        if "no crontab" in msg.lower():
            return [], src
        src.update(ok=False, error=msg[:300] or f"rc={rc}")
        return [], src
    spool_path = os.path.join(CRONTAB_SPOOL_DIR, user)
    try:
        definition_mtime = os.stat(spool_path).st_mtime
        src["definitionMtimeSource"] = spool_path
    except OSError as e:
        definition_mtime = SERVICE_START_TIME
        src["definitionMtimeSource"] = "service-start"
        src["definitionMtimeFallback"] = str(e)[:200] or type(e).__name__
    src["definitionMtime"] = definition_mtime
    jobs, bad = parse_cron_text(
        out, source="crontab", scope="crontab", has_user_field=False,
        default_user=user, now=now, definition_mtime=definition_mtime,
    )
    if user_fallback:
        for job in jobs:
            job["_attributionUnavailable"] = True
    src["count"] = len(jobs)
    if bad:
        src["unparsed"] = bad
    return jobs, src


def collect_cron_files(now: float) -> tuple[list[dict], list[dict]]:
    """/etc/crontab · /etc/cron.d/* · run-parts 디렉토리. 읽기 실패도 소스에 남긴다."""
    jobs: list[dict] = []
    sources: list[dict] = []

    files = [CRONTAB_FILE]
    try:
        files += sorted(
            os.path.join(CRON_D_DIR, n) for n in os.listdir(CRON_D_DIR)
            if _RUN_PARTS_NAME_RE.match(n)
        )
    except OSError as e:
        sources.append({"scope": "cron.d", "kind": CRON_D_DIR, "ok": False, "error": str(e)[:200]})

    for path in files:
        src: dict = {"scope": "cron.d", "kind": path, "ok": True, "count": 0}
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError as e:
            src.update(ok=False, error=str(e)[:200])
            sources.append(src)
            continue
        try:
            definition_mtime = os.stat(path).st_mtime
            src["fileMtime"] = definition_mtime
        except OSError as e:
            definition_mtime = None
            src["mtimeError"] = str(e)[:200] or type(e).__name__
        fjobs, bad = parse_cron_text(
            text, source=path, scope="cron.d", has_user_field=True,
            default_user="root", now=now,
        )
        new_definitions = 0
        for job in fjobs:
            identity = (
                str(job.get("source", path)), str(job.get("user", "")),
                str(job.get("schedule", "")), str(job.get("command", "")),
            )
            if identity not in _CRON_DEFINITION_SEEN and definition_mtime is not None:
                _CRON_DEFINITION_SEEN.add(identity)
                job["_definitionMtime"] = definition_mtime
                new_definitions += 1
            else:
                # 파일의 무관한 수정으로 기존 정의 전체를 pending으로 억제하지 않는다.
                # mtime 조회 실패 때는 seen에 넣지 않았으므로 다음 스냅샷에서 재시도한다.
                job["_definitionMtime"] = None
        jobs += fjobs
        src["count"] = len(fjobs)
        src["newDefinitions"] = new_definitions
        if bad:
            src["unparsed"] = bad
        sources.append(src)

    # run-parts 디렉토리: 스케줄은 위 /etc/crontab 항목이 갖고, 여기는 그 항목이 실행할 스크립트 목록.
    # 자식 스크립트엔 스케줄이 없으므로 그 디렉토리를 실제로 실행하는 항목의 다음 실행을 물려준다.
    parent_defs: dict[str, list[dict]] = {}
    for j in jobs:
        m = _RUN_PARTS_RE.search(j.get("command", ""))
        if m:
            parent_defs.setdefault(m.group(1), []).append(j)

    for d in RUN_PARTS_DIRS:
        src = {"scope": "run-parts", "kind": d, "ok": True, "count": 0}
        try:
            names = sorted(
                n for n in os.listdir(d)
                if _RUN_PARTS_NAME_RE.match(n) and os.access(os.path.join(d, n), os.X_OK)
            )
        except OSError as e:
            src.update(ok=False, error=str(e)[:200])
            sources.append(src)
            continue
        root_parents = [j for j in parent_defs.get(d, []) if j.get("user") == "root"]
        single_parent = root_parents[0] if len(root_parents) == 1 else None
        parent_cron_tz = (
            bool(single_parent.get("_cronTz")) if single_parent else
            any(bool(parent.get("_cronTz")) for parent in root_parents)
        )
        mtime_errors: list[str] = []
        for n in names:
            child_path = os.path.join(d, n)
            try:
                child_mtime = os.stat(child_path).st_mtime
            except OSError as e:
                child_mtime = None
                mtime_errors.append(f"{child_path}: {str(e)[:140] or type(e).__name__}")
            jobs.append({
                "id": f"run-parts:{d}/{n}",
                "scope": "run-parts",
                "kind": "run-parts",
                "name": n,
                "unit": None, "service": None,
                "description": f"{d} 안의 스크립트 — {CRONTAB_FILE} 의 run-parts 항목이 실행"
                               " (예정 시각은 그 항목 기준)",
                "schedule": os.path.basename(d).replace("cron.", "") + " (run-parts)",
                "command": os.path.join(d, n),
                "user": "root",
                "enabled": True,
                "unitFileState": "", "activeState": "",
                "lastRun": None, "nextRun": single_parent.get("nextRun") if single_parent else None,
                "lastResult": "none", "exitStatus": None, "durationSec": None,
                "execution": "unobserved", "timeliness": "pending",
                "lastDue": None, "lastSignal": None, "lastSignalKind": "none",
                "matchQuality": "none", "reboot": "unknown",
                "controllable": False, "logs": False,
                "source": d,
                "_cronExpr": single_parent.get("_cronExpr") if single_parent else None,
                "_cronTz": parent_cron_tz,
                # 부모 cron 정의의 mtime이 아니라 자식 스크립트 자체의 mtime이다.
                "_definitionMtime": child_mtime,
                "_definitionMtimeAvailable": child_mtime is not None,
                "_runPartsChild": True,
                "_parentUser": "root",
                "_parentDir": d,
            })
        src["count"] = len(names)
        if mtime_errors:
            src["mtimeErrors"] = mtime_errors
        sources.append(src)

    return jobs, sources


def _cron_reboot_state(
    *, service_state: str | None, journal_ok: bool,
    events: list[dict[str, str | float | None]], current_id: str | None,
    direct_signal: bool,
) -> str:
    """cron.service 구성과 직접 journal 신호로 재부팅 축을 판정한다."""
    if service_state in {"disabled", "masked", "not-found"}:
        return "unsafe"
    # 양쪽 다 여기서 정규화한다 — 호출자가 정규화했다고 가정하면 표기 하나만 어긋나도
    # 판정이 조용히 강등된다(normalize_boot_id 주석의 실측 사고).
    current = normalize_boot_id(current_id)
    if not journal_ok or not direct_signal or current is None:
        return "unknown" if not journal_ok or current is None else "configured-unobserved"
    if any(normalize_boot_id(event.get("boot_id")) == current for event in events):
        return "postboot-observed"
    if service_state in {
        "enabled", "enabled-runtime", "static", "indirect", "generated", "transient",
        "alias", "linked", "linked-runtime",
    }:
        return "configured-unobserved"
    return "unknown"


def _cron_due(
    job: dict, now: float,
) -> tuple[float | None, bool]:
    """(lastDue, schedule 해석 가능 여부)."""
    if job.get("_cronTz"):
        return None, False
    expr = job.get("_cronExpr")
    if not isinstance(expr, str) or not parse_cron_expr(expr):
        return None, False
    return cron_prev_epoch(expr, now), True


def _cron_timeliness(
    *, last_due: float | None, schedule_valid: bool, cron_tz: bool,
    signal_events: list[dict[str, str | float | None]], now: float,
    journal_ok: bool, coverage_start: float | None, btime: float | None,
    cron_active_since: float | None, definition_mtime: float | None,
    definition_mtime_known: bool = True,
) -> str:
    if not journal_ok or cron_tz or not schedule_valid:
        return "unknown"
    if not definition_mtime_known:
        # 자식 파일의 생성 시각을 모르면 부모 신호와 정의 시각을 비교할 수 없다.
        return "pending"
    # 성공한 빈 journal은 btime 이후 전체를 관측했다는 증거가 아니다.
    if coverage_start is None:
        return "pending"
    if last_due is None:
        return "pending"
    if any(float(event["ts"]) >= last_due for event in signal_events):
        return "on-time"
    # cron.service 상태를 읽지 못했거나 아직 활성화 시각이 없으면 late를 단정하지 않는다.
    if cron_active_since is None:
        return "pending"

    lower_bounds = [
        value for value in (coverage_start, btime, cron_active_since, definition_mtime)
        if value is not None
    ]
    if lower_bounds and last_due < max(lower_bounds):
        return "pending"
    return "late" if now > last_due + LATE_GRACE_SEC else "pending"


def apply_cron_observations(
    jobs: list[dict], journal_events: dict[tuple[str, str], list[dict]],
    journal_source: dict, cron_service: dict, *, btime: float | None,
    now: float, current_id: str | None,
) -> None:
    """수집한 CRON 신호를 정의에 귀속하고 cron 잡의 네 판정축을 채운다."""
    cron_jobs = [job for job in jobs if job.get("kind") == "cron"]
    child_jobs = [job for job in jobs if job.get("kind") == "run-parts"]
    rendered_commands = {
        job["id"]: render_cron_command(str(job.get("command", "")))
        for job in cron_jobs
    }
    definition_counts = Counter(
        (job.get("user"), rendered_commands[job["id"]]) for job in cron_jobs
    )
    journal_ok = bool(journal_source.get("ok"))
    coverage_start = journal_source.get("coverageStart")
    service_state = cron_service.get("unitFileState")
    cron_active_since = cron_service.get("activeSince")

    decisions: dict[str, dict] = {}
    for job in cron_jobs:
        key = (job.get("user"), rendered_commands[job["id"]])
        ambiguous = definition_counts[key] > 1
        events = [] if ambiguous or not journal_ok else list(journal_events.get(key, []))
        decisions[job["id"]] = {
            "events": events,
            "ambiguous": ambiguous,
            "matchQuality": "ambiguous" if ambiguous else ("exact" if events else "none"),
        }

    for job in cron_jobs + child_jobs:
        decision = decisions.get(job.get("id"), {})
        ambiguous = bool(decision.get("ambiguous"))
        attribution_unavailable = bool(job.get("_attributionUnavailable"))
        signal_events: list[dict] = list(decision.get("events", []))
        direct_signal = job.get("kind") == "cron"
        inferred = False
        match_quality = decision.get("matchQuality", "none")

        if job.get("kind") == "run-parts":
            parent_dir = job.get("_parentDir")
            parent_user = job.get("_parentUser", "root")
            parents = [
                parent for parent in cron_jobs
                if parent.get("_runPartsDir") == parent_dir
                and parent.get("user") == parent_user
            ]
            if len(parents) != 1 or decisions.get(parents[0].get("id"), {}).get("ambiguous"):
                ambiguous = bool(parents) or len(parents) > 1
                match_quality = "ambiguous" if ambiguous else "none"
                signal_events = []
            else:
                parent_decision = decisions[parents[0]["id"]]
                child_mtime = job.get("_definitionMtime")
                # 부모 wrapper 신호가 자식 파일보다 이르면 자식이 아직 존재하지 않았을
                # 가능성이 있으므로 상속하지 않는다. stat 실패도 안전하게 상속 금지다.
                signal_events = [
                    event for event in parent_decision["events"]
                    if child_mtime is not None and float(event["ts"]) >= child_mtime
                ]
                match_quality = "exact" if signal_events else "none"
                inferred = bool(signal_events) and journal_ok
                direct_signal = False

        last_signal = max(signal_events, key=lambda event: float(event["ts"])) if signal_events else None
        last_due, schedule_valid = _cron_due(job, now)
        job["lastDue"] = last_due
        job["matchQuality"] = match_quality
        job["lastSignal"] = last_signal.get("ts") if last_signal else None
        job["lastSignalKind"] = "parent" if inferred else ("direct" if signal_events and direct_signal else "none")
        job["lastRun"] = None if job.get("kind") == "run-parts" else (
            last_signal.get("ts") if last_signal else None
        )

        if not journal_ok or ambiguous or attribution_unavailable:
            job["execution"] = "unavailable"
            job["timeliness"] = "unknown"
            job["lastResult"] = "unknown"
        else:
            covered = bool(signal_events) and (
                last_due is None or any(float(event["ts"]) >= last_due for event in signal_events)
            )
            if inferred:
                job["execution"] = "inferred"
            elif covered:
                job["execution"] = "observed"
            else:
                job["execution"] = "unobserved"
            job["timeliness"] = _cron_timeliness(
                last_due=last_due,
                schedule_valid=schedule_valid,
                cron_tz=bool(job.get("_cronTz")),
                signal_events=signal_events,
                now=now,
                journal_ok=journal_ok,
                coverage_start=coverage_start,
                btime=btime,
                cron_active_since=cron_active_since,
                definition_mtime=job.get("_definitionMtime"),
                definition_mtime_known=job.get(
                    "_definitionMtimeAvailable",
                    not (job.get("kind") == "run-parts"
                         and job.get("_definitionMtime") is None),
                ),
            )
            job["lastResult"] = "unknown" if signal_events else "none"

        job["reboot"] = _cron_reboot_state(
            service_state=service_state,
            journal_ok=journal_ok and not ambiguous and not attribution_unavailable,
            events=signal_events,
            current_id=current_id,
            direct_signal=direct_signal and not inferred and not ambiguous,
        )


def attention_key(job: dict) -> tuple[int, float, str]:
    """결과·시의성·재부팅 위험을 함께 반영하는 화면 정렬 키."""
    if job.get("lastResult") == "failed":
        priority = 0
    elif job.get("timeliness") == "late":
        priority = 1
    elif job.get("reboot") == "unsafe":
        priority = 2
    elif job.get("execution") == "unavailable" or job.get("timeliness") == "unknown":
        priority = 3
    elif job.get("reboot") == "configured-unobserved":
        priority = 4
    elif job.get("execution") == "inferred":
        priority = 5
    elif job.get("timeliness") == "pending":
        priority = 7
    else:
        priority = 6
    due = job.get("lastDue")
    if due is None:
        due = job.get("nextRun")
    return priority, due if due is not None else float("inf"), str(job.get("name", ""))


def count_jobs(jobs: list[dict]) -> dict:
    """카운트는 서버가 한 번만 센다 — 프런트가 다시 세면 두 진실이 갈린다."""
    c = {
        "total": len(jobs),
        "executionObserved": 0, "executionInferred": 0,
        "executionUnobserved": 0, "executionUnavailable": 0,
        "timelinessOnTime": 0, "timelinessLate": 0,
        "timelinessPending": 0, "timelinessUnknown": 0,
        "resultSuccess": 0, "resultFailed": 0,
        "resultUnknown": 0, "resultNone": 0,
        "rebootUnsafe": 0, "rebootConfiguredUnobserved": 0,
        "rebootPostbootObserved": 0, "rebootUnknown": 0,
        # 카탈로그를 못 읽은 잡(`catalog-unavailable`)은 여기 세지 않는다 — 모르는 것과 없는 것은 다르다.
        "descriptionMissing": 0,
    }
    fields = {
        "execution": {
            "observed": "executionObserved", "inferred": "executionInferred",
            "unobserved": "executionUnobserved", "unavailable": "executionUnavailable",
        },
        "timeliness": {
            "on-time": "timelinessOnTime", "late": "timelinessLate",
            "pending": "timelinessPending", "unknown": "timelinessUnknown",
        },
        "lastResult": {
            "success": "resultSuccess", "failed": "resultFailed",
            "unknown": "resultUnknown", "none": "resultNone",
        },
        "reboot": {
            "unsafe": "rebootUnsafe", "configured-unobserved": "rebootConfiguredUnobserved",
            "postboot-observed": "rebootPostbootObserved", "unknown": "rebootUnknown",
        },
        "descriptionStatus": {"missing": "descriptionMissing"},
    }
    for job in jobs:
        for field, names in fields.items():
            key = names.get(job.get(field))
            if key:
                c[key] += 1
    return c


def _strip_internal_fields(job: dict) -> dict:
    return {key: value for key, value in job.items() if not key.startswith("_")}


def _snapshot_uncached() -> dict:
    """전 소스 수집 스냅샷. 어떤 소스가 실패해도 나머지는 낸다(부분 결과 + 실패 표면화)."""
    now = time.time()
    boot = boot_epoch()
    current_id = current_boot_id()
    jobs: list[dict] = []
    sources: list[dict] = []

    for scope in ("user", "system"):
        j, s = collect_systemd(scope, boot, now)
        jobs += j
        sources.append(s)

    j, s = collect_crontab(now)
    jobs += j
    sources.append(s)

    j, s = collect_cron_files(now)
    jobs += j
    sources += s

    # coverageEnd는 snapshot 시작시각이 아니라 journal 수집이 끝난 시각이어야 한다.
    journal_events, journal_source = collect_cron_journal(boot)
    sources.append(journal_source)
    cron_jobs_exist = any(job.get("kind") in {"cron", "run-parts"} for job in jobs)
    if cron_jobs_exist:
        try:
            cron_service, cron_service_source = collect_cron_service()
        except Exception as e:
            cron_service = {"unitFileState": None, "activeSince": None}
            cron_service_source = {
                "scope": "cron-service", "kind": "systemctl show cron.service", "ok": False,
                "count": 0, "error": str(e)[:300] or type(e).__name__,
            }
        sources.append(cron_service_source)
        apply_cron_observations(
            jobs, journal_events, journal_source, cron_service,
            btime=boot, now=now, current_id=current_id,
        )

    # The absorbed monitor UI needs health, not the former private console's repo-origin
    # and authored-description workflow. Avoid reading script contents and git metadata
    # that no response consumer uses; the public API applies a second explicit allowlist.
    jobs = [_strip_internal_fields(job) for job in jobs]
    jobs.sort(key=attention_key)
    notes: list[str] = []
    if os.path.exists("/usr/sbin/anacron"):
        notes.append(
            "anacron 설치됨 — /etc/cron.{daily,weekly,monthly} 는 /etc/crontab 시각이 아니라 "
            "anacron 스케줄로 실행될 수 있습니다."
        )
    notes.append(
        "cron 계열은 sudo -n journalctl로 현재 부팅 이후 실행 신호를 관측합니다. "
        "journal은 종료코드를 제공하지 않으므로 신호가 있어도 lastResult는 unknown입니다."
    )
    if not journal_source.get("ok"):
        notes.append(
            "cron journal 수집 실패 — 원인은 sources의 cron-journal 항목에 있으며, "
            "cron 잡의 execution은 unavailable로 표시됩니다."
        )
    elif journal_source.get("empty"):
        notes.append(
            "현재 부팅 이후 journal 레코드가 없어 관측 시작점을 정할 수 없습니다. "
            "cron 잡의 late 판정은 억제됩니다."
        )
    coverage_end = journal_source.get("coverageEnd", now)
    return {
        "schemaVersion": 3,
        "now": now,
        "bootTime": boot,
        "coverageStart": journal_source.get("coverageStart"),
        "coverageEnd": coverage_end,
        "hostname": os.uname().nodename,
        "jobs": jobs,
        "counts": count_jobs(jobs),
        "sources": sources,
        "notes": notes,
    }


def invalidate_snapshot_cache() -> None:
    """조작 성공 직후 다음 GET이 새 상태를 읽도록 성공 스냅샷을 버린다."""
    global _snapshot_cache
    with _snapshot_lock:
        _snapshot_cache = None


def snapshot() -> dict:
    """30초 메모리 캐시와 single-flight가 적용된 전 소스 스냅샷."""
    global _snapshot_cache
    with _snapshot_lock:
        # 대기 중인 요청은 lock을 얻은 뒤의 시각으로 age를 계산한다. 수집이 30초보다
        # 오래 걸려도 같은 single-flight 결과를 다시 수집하지 않는다.
        requested_at = time.monotonic()
        if _snapshot_cache is not None:
            cached_value, cached_at = _snapshot_cache
            age = requested_at - cached_at
            if age < SNAPSHOT_CACHE_TTL_SEC:
                result = copy.deepcopy(cached_value)
                result["cached"] = True
                result["cachedAgeSec"] = round(max(0.0, age), 3)
                return result

        # lock을 수집 전체 동안 유지해 동시 요청이 같은 sudo/journal 스캔을 중복하지
        # 않게 한다. 이 함수 안에서는 snapshot()을 재호출하지 않으므로 교착도 없다.
        fresh = _snapshot_uncached()
        cached_at = time.monotonic()
        _snapshot_cache = (fresh, cached_at)
        result = copy.deepcopy(fresh)
        result["cached"] = False
        result["cachedAgeSec"] = 0
        return result


if __name__ == "__main__":       # 수동 점검용 — 콘솔 없이 그대로 확인할 수 있게
    import json
    print(json.dumps(snapshot(), ensure_ascii=False, indent=2))
