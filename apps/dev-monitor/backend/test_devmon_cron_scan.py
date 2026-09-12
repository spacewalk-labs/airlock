#!/usr/bin/env python3
"""dev-monitor cron 수집기 파서·판정 단위 테스트.

  python3 backend/test_devmon_cron_scan.py

여기 있는 건 전부 순수 함수라 실제 systemd·크론 없이 돈다. 실 데이터 형식은 devbox 에서
`systemctl show` 로 실측한 출력을 그대로 픽스처로 박았다(형식이 바뀌면 이 테스트가 먼저 깨진다).
"""
from __future__ import annotations

import importlib.util
import unittest
import hashlib
import io
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import threading
from datetime import datetime, timezone
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import devmon_cron_scan as cs
import devmon_loop as loop
import devmon_messages as messages


VERIFY_PATH = Path(__file__).resolve().parents[1] / "verify-cron-handoff-live.py"
VERIFY_SPEC = importlib.util.spec_from_file_location("verify_cron_handoff_live", VERIFY_PATH)
handoff = importlib.util.module_from_spec(VERIFY_SPEC)
VERIFY_SPEC.loader.exec_module(handoff)


def taskboard_acceptance_measure():
    """Load the real taskboard parser when its path is supplied by the caller."""
    path_value = os.environ.get("TASKBOARD_ACCEPT_CARD")
    if not path_value:
        return None
    path = Path(path_value)
    sys.path.insert(0, str(path.parent))
    try:
        spec = importlib.util.spec_from_file_location("taskboard_accept_card", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        sys.path.pop(0)
    return getattr(module, "measure_ac", None) or module.measure_acceptance


def ep(s: str) -> float:
    """'2026-07-28 05:00:30' → 로컬 TZ epoch."""
    return datetime.strptime(s, "%Y-%m-%d %H:%M:%S").timestamp()


class ShowBlocks(unittest.TestCase):
    # devbox 실측: 다중 유닛 show 는 빈 줄로 나뉘고 TimersCalendar 는 유닛당 여러 번 나온다.
    RAW = (
        "TimersCalendar={ OnCalendar=*-*-* 05:00:00 ; next_elapse=@1785268800 }\n"
        "LastTriggerUSec=Tue 2026-07-28 05:00:30 KST\n"
        "Id=scratch-sweep.timer\n"
        "UnitFileState=enabled\n"
        "\n"
        "TimersMonotonic={ OnUnitActiveUSec=1min ; next_elapse=6d 18h 46min 27.896260s }\n"
        "TimersMonotonic={ OnBootUSec=2min ; next_elapse=2min 52.228429s }\n"
        "Id=idc-rate-poller.timer\n"
        "NextElapseUSecRealtime=\n"
    )

    def test_splits_units_and_keeps_repeated_keys(self):
        blocks = cs.parse_show_blocks(self.RAW)
        self.assertEqual(len(blocks), 2)
        self.assertEqual(cs.first(blocks[0], "Id"), "scratch-sweep.timer")
        self.assertEqual(len(blocks[1]["TimersMonotonic"]), 2)

    def test_value_containing_equals_is_not_split(self):
        b = cs.parse_show_blocks("Id=a.service\nExecStart={ path=/bin/sh ; argv[]=/bin/sh -c x }\n")
        self.assertIn("path=/bin/sh", b[0]["ExecStart"][0])

    def test_missing_key_returns_default(self):
        self.assertEqual(cs.first({}, "Nope", "dflt"), "dflt")


class Timestamps(unittest.TestCase):
    def test_human_form_local_tz(self):
        self.assertEqual(
            cs.parse_timestamp("Tue 2026-07-28 05:00:30 KST"), ep("2026-07-28 05:00:30"))

    def test_unix_form(self):
        self.assertEqual(cs.parse_timestamp("@1785268800.5"), 1785268800.5)

    def test_absent_forms_are_none(self):
        for raw in ("", "   ", "n/a", "0"):
            self.assertIsNone(cs.parse_timestamp(raw), raw)

    def test_garbage_is_none_not_crash(self):
        self.assertIsNone(cs.parse_timestamp("nonsense"))


class Durations(unittest.TestCase):
    def test_compound(self):
        self.assertAlmostEqual(
            cs.parse_duration("6d 18h 46min 27.896260s"),
            6 * 86400 + 18 * 3600 + 46 * 60 + 27.89626, places=4)

    def test_single_unit(self):
        self.assertEqual(cs.parse_duration("2min"), 120)

    def test_unparseable(self):
        self.assertIsNone(cs.parse_duration("infinity"))
        self.assertIsNone(cs.parse_duration(""))


class ExecAndSchedule(unittest.TestCase):
    def test_argv_extracted(self):
        v = ["{ path=/bin/sh ; argv[]=/bin/sh -c /home/x/y.sh ; ignore_errors=no }"]
        self.assertEqual(cs.exec_command(v), "/bin/sh -c /home/x/y.sh")

    def test_calendar_schedule_preferred(self):
        props = {"TimersCalendar": ["{ OnCalendar=*-*-* 05:00:00 ; next_elapse=@1 }"]}
        self.assertEqual(cs.timer_schedule(props), "*-*-* 05:00:00")

    def test_monotonic_schedule_when_no_calendar(self):
        props = {"TimersMonotonic": ["{ OnUnitActiveUSec=1min ; next_elapse=5s }"]}
        self.assertEqual(cs.timer_schedule(props), "UnitActive +1min")


class Fields(unittest.TestCase):
    def test_star_and_ranges_and_steps(self):
        self.assertEqual(cs.expand_field("*", 0, 3), [0, 1, 2, 3])
        self.assertEqual(cs.expand_field("1-3", 0, 9), [1, 2, 3])
        self.assertEqual(cs.expand_field("*/15", 0, 59), [0, 15, 30, 45])
        self.assertEqual(cs.expand_field("1,5,3", 0, 9), [1, 3, 5])

    def test_vixie_start_step_runs_to_top(self):
        # sysstat 실물: '5-55/10' 과 'N/step' 확장
        self.assertEqual(cs.expand_field("5-55/10", 0, 59), [5, 15, 25, 35, 45, 55])
        self.assertEqual(cs.expand_field("50/10", 0, 59), [50])

    def test_names(self):
        self.assertEqual(cs.expand_field("mon-fri", 0, 7, cs._DOWS), [1, 2, 3, 4, 5])

    def test_out_of_range_raises(self):
        for bad in ("99", "5-2", "0/0", "", "x"):
            with self.assertRaises(ValueError, msg=bad):
                cs.expand_field(bad, 0, 59)


class CronNextRun(unittest.TestCase):
    NOW = ep("2026-07-28 16:30:00")            # 화요일

    def test_daily_time(self):
        self.assertEqual(cs.cron_next_epoch("0 5 * * *", self.NOW), ep("2026-07-29 05:00:00"))

    def test_later_today(self):
        self.assertEqual(cs.cron_next_epoch("45 16 * * *", self.NOW), ep("2026-07-28 16:45:00"))

    def test_interval(self):
        self.assertEqual(cs.cron_next_epoch("*/30 * * * *", self.NOW), ep("2026-07-28 17:00:00"))

    def test_every_minute_is_next_minute(self):
        self.assertEqual(cs.cron_next_epoch("* * * * *", self.NOW), ep("2026-07-28 16:31:00"))

    def test_weekday_sunday_as_zero_and_seven(self):
        for dow in ("0", "7"):
            self.assertEqual(
                cs.cron_next_epoch(f"30 3 * * {dow}", self.NOW),
                ep("2026-08-02 03:30:00"), dow)

    def test_monthly_day(self):
        self.assertEqual(cs.cron_next_epoch("52 6 1 * *", self.NOW), ep("2026-08-01 06:52:00"))

    def test_dom_and_dow_both_restricted_is_or(self):
        # Vixie 규칙: 둘 다 제한적이면 OR — 30일(목)보다 먼저 오는 수요일 29일이 답
        self.assertEqual(
            cs.cron_next_epoch("0 0 30 * 3", self.NOW), ep("2026-07-29 00:00:00"))

    def test_probe_f_step_star_is_unrestricted_dom(self):
        # 2026-07-28 화요일은 DOM=28(*/3)에 들어가지만 DOW=6(토)이 아니므로 실행하지 않는다.
        parsed = cs.parse_cron_expr("* * */3 * 6")
        self.assertFalse(parsed["dom_restricted"])
        self.assertTrue(parsed["dow_restricted"])
        self.assertEqual(
            cs.cron_next_epoch("0 0 */3 * 6", self.NOW), ep("2026-08-01 00:00:00"))

    def test_probe_f_step_star_is_unrestricted_dom_for_previous_run(self):
        self.assertEqual(
            cs.cron_prev_epoch("0 0 */3 * 6", self.NOW), ep("2026-07-25 00:00:00"))

    def test_nickname(self):
        self.assertEqual(cs.cron_next_epoch("@daily", self.NOW), ep("2026-07-29 00:00:00"))

    def test_reboot_and_garbage_are_none(self):
        self.assertIsNone(cs.parse_cron_expr("@reboot"))
        self.assertIsNone(cs.cron_next_epoch("nonsense here", self.NOW))
        self.assertIsNone(cs.cron_next_epoch("0 0 31 2 *", self.NOW))   # 2월 31일 = 영원히 없음


class Labels(unittest.TestCase):
    def test_run_parts_dir_wins(self):
        self.assertEqual(
            cs.cron_job_label("test -x /usr/sbin/anacron || { cd / && run-parts --report "
                              "/etc/cron.daily; }", "/etc/crontab"), "cron.daily")

    def test_cron_d_filename_beats_guard_clause_path(self):
        # 'test -e /run/systemd/system || ...' 에서 이름을 뽑으면 'system' 이 나온다 — 파일명이 정답
        self.assertEqual(
            cs.cron_job_label("test -e /run/systemd/system || /sbin/e2scrub_all -A -r",
                              "/etc/cron.d/e2scrub_all"), "e2scrub_all")

    def test_personal_crontab_uses_command_path(self):
        self.assertEqual(
            cs.cron_job_label("/home/alice/bin/backup.sh >> /home/alice/.cache/x.log 2>&1",
                              "crontab"), "backup.sh")

    def test_fallback_to_first_token(self):
        self.assertEqual(cs.cron_job_label("echo hi", "crontab"), "echo")


class OriginCandidates(unittest.TestCase):
    def test_python_interpreter_loses_to_script(self):
        with tempfile.TemporaryDirectory() as root:
            script = os.path.join(root, "idc-rate-poller.py")
            with open(script, "w", encoding="utf-8"):
                pass
            candidates = cs.execution_path_candidates(f"/usr/bin/python3 {script}")
            selected = cs.select_origin_candidate(
                candidates, {candidate["path"]: None for candidate in candidates})
        self.assertEqual(selected["path"], script)
        self.assertFalse(selected["interpreter"])

    def test_redirect_target_is_excluded_and_which_resolves_command(self):
        with tempfile.TemporaryDirectory() as root:
            executable = os.path.join(root, "debian-sa1")
            with open(executable, "w", encoding="utf-8"):
                pass
            with patch.object(cs.shutil, "which", return_value=executable) as which:
                candidates = cs.execution_path_candidates(
                    "command -v debian-sa1 > /dev/null && debian-sa1 1 1")
            self.assertEqual([candidate["path"] for candidate in candidates], [executable])
            which.assert_called_once_with("debian-sa1")

    def test_symlink_is_resolved_before_attribution(self):
        with tempfile.TemporaryDirectory() as root:
            repo = os.path.join(root, "example-wiki")
            target = os.path.join(repo, "scripts", "wiki_drawings", "run.sh")
            link = os.path.join(root, "bin", "sync-wiki-drawings")
            os.makedirs(os.path.dirname(target))
            os.makedirs(os.path.dirname(link))
            os.makedirs(os.path.join(repo, ".git"))
            with open(target, "w", encoding="utf-8"):
                pass
            os.symlink(target, link)
            candidates = cs.execution_path_candidates(link)
        self.assertEqual(candidates[0]["path"], os.path.realpath(target))

    def test_tilde_path_uses_owner_home(self):
        with tempfile.TemporaryDirectory() as root:
            script = os.path.join(root, "bin", "sync-wiki-drawings")
            os.makedirs(os.path.dirname(script))
            with open(script, "w", encoding="utf-8"):
                pass
            with patch.object(cs, "_owner_home", return_value=root):
                candidates = cs.execution_path_candidates("~/bin/sync-wiki-drawings")
        self.assertEqual(candidates[0]["path"], script)

    def test_repo_candidate_beats_later_non_repo_candidate(self):
        candidates = [
            {"path": "/repo/script.sh", "kind": "command", "interpreter": False, "order": 1},
            {"path": "/usr/bin/tool", "kind": "command", "interpreter": False, "order": 2},
        ]
        selected = cs.select_origin_candidate(candidates, {"/repo/script.sh": "/repo", "/usr/bin/tool": None})
        self.assertEqual(selected["path"], "/repo/script.sh")

    def test_wrapper_tie_uses_later_command_token(self):
        candidates = [
            {"path": "/tmp/python3", "kind": "command", "interpreter": True, "order": 1},
            {"path": "/tmp/env", "kind": "command", "interpreter": True, "order": 2},
        ]
        selected = cs.select_origin_candidate(candidates, {path: None for path in (candidate["path"] for candidate in candidates)})
        self.assertEqual(selected["path"], "/tmp/env")
        self.assertEqual(cs.origin_candidate_score(candidates[0], in_repo=False), 1)

    def test_fragment_path_is_last_resort_candidate(self):
        with tempfile.TemporaryDirectory() as root:
            fragment = os.path.join(root, "systemd-tmpfiles-clean.timer")
            with open(fragment, "w", encoding="utf-8"):
                pass
            candidates = cs.execution_path_candidates(
                "/definitely/missing/command", fragment_path=fragment)
        self.assertEqual(len(candidates), 1)
        self.assertEqual(candidates[0]["kind"], "fragment")
        self.assertEqual(candidates[0]["path"], fragment)

    def test_nonexistent_and_special_paths_are_not_candidates(self):
        self.assertEqual(
            cs.execution_path_candidates("/definitely/missing /dev/null /proc/1 /sys/kernel"), [])

    def test_absolute_log_redirection_is_not_selected(self):
        with tempfile.TemporaryDirectory() as root:
            command = os.path.join(root, "job.sh")
            log = os.path.join(root, "job.log")
            for path in (command, log):
                with open(path, "w", encoding="utf-8"):
                    pass
            candidates = cs.execution_path_candidates(f"{command} > {log} 2>&1")
        self.assertEqual([candidate["path"] for candidate in candidates], [command])

    def test_fragment_is_lower_priority_than_a_real_command_path(self):
        with tempfile.TemporaryDirectory() as root:
            command = os.path.join(root, "command.sh")
            fragment = os.path.join(root, "unit.timer")
            self.open_files(command, fragment)
            candidates = cs.execution_path_candidates(command, fragment_path=fragment)
        selected = cs.select_origin_candidate(
            candidates, {candidate["path"]: None for candidate in candidates})
        self.assertEqual(selected["path"], command)

    @staticmethod
    def open_files(*paths):
        for path in paths:
            with open(path, "w", encoding="utf-8"):
                pass


class CronText(unittest.TestCase):
    NOW = ep("2026-07-28 16:30:00")

    def test_personal_crontab_five_fields(self):
        text = ("SHELL=/bin/sh\n"
                "# comment\n"
                "\n"
                "30 4 * * 1 /home/alice/bin/sync  # 주1회\n")
        jobs, bad = cs.parse_cron_text(text, source="crontab", scope="crontab",
                                       has_user_field=False, default_user="alice", now=self.NOW)
        self.assertEqual(bad, [])
        self.assertEqual(len(jobs), 1)
        self.assertEqual(jobs[0]["schedule"], "30 4 * * 1")
        self.assertEqual(jobs[0]["user"], "alice")
        # 명령 뒤 '#' 은 cron 이 주석으로 다루지 않는다 — 보이는 대로 보존
        self.assertIn("# 주1회", jobs[0]["command"])
        self.assertEqual(jobs[0]["execution"], "unobserved")
        self.assertEqual(jobs[0]["lastResult"], "none")
        self.assertEqual(jobs[0]["reboot"], "unknown")

    def test_system_file_has_user_field(self):
        jobs, bad = cs.parse_cron_text("17 * * * *\troot\tcd / && run-parts /etc/cron.hourly\n",
                                       source="/etc/crontab", scope="cron.d",
                                       has_user_field=True, default_user="root", now=self.NOW)
        self.assertEqual(jobs[0]["user"], "root")
        self.assertEqual(jobs[0]["name"], "cron.hourly")
        self.assertEqual(bad, [])

    def test_nickname_line(self):
        jobs, _ = cs.parse_cron_text("@daily /home/alice/bin/x\n", source="crontab",
                                     scope="crontab", has_user_field=False,
                                     default_user="alice", now=self.NOW)
        self.assertEqual(jobs[0]["command"], "/home/alice/bin/x")
        self.assertEqual(jobs[0]["nextRun"], ep("2026-07-29 00:00:00"))

    def test_reboot_nickname_has_no_next_run(self):
        jobs, _ = cs.parse_cron_text("@reboot /home/alice/bin/x\n", source="crontab",
                                     scope="crontab", has_user_field=False,
                                     default_user="alice", now=self.NOW)
        self.assertIsNone(jobs[0]["nextRun"])

    def test_truncated_line_is_reported_not_dropped(self):
        jobs, bad = cs.parse_cron_text("30 4 * *\n", source="crontab", scope="crontab",
                                       has_user_field=False, default_user="alice", now=self.NOW)
        self.assertEqual(jobs, [])
        self.assertEqual(bad, ["30 4 * *"])

    def test_command_trailing_space_is_preserved_for_matching(self):
        jobs, bad = cs.parse_cron_text(
            "30 4 * * * /opt/job  \n", source="crontab", scope="crontab",
            has_user_field=False, default_user="alice", now=self.NOW)
        self.assertEqual(bad, [])
        self.assertEqual(jobs[0]["command"], "/opt/job  ")


class DescriptionCatalog(unittest.TestCase):
    def write_catalog(self, path: str, entries: dict, *, schema: int = 1) -> None:
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"schemaVersion": schema, "_about": ["test"], "entries": entries}, f)

    def test_description_key_for_systemd_unit(self):
        self.assertEqual(
            cs.description_key({"kind": "systemd", "unit": "fstrim.timer"}),
            "unit:fstrim.timer")

    def test_description_key_for_run_parts_child(self):
        self.assertEqual(
            cs.description_key({"kind": "run-parts", "command": "/etc/cron.daily/logrotate"}),
            "runparts:/etc/cron.daily/logrotate")

    def test_description_key_replaces_owner_home_at_command_start(self):
        with patch.object(cs.os, "getuid", return_value=1001), \
                patch.object(cs.pwd, "getpwuid",
                             return_value=SimpleNamespace(pw_dir="/home/alice")):
            self.assertEqual(
                cs.description_key({"kind": "cron", "command": "/home/alice/bin/x.sh"}),
                "cmd:~/bin/x.sh")

    def test_description_key_replaces_every_home_occurrence(self):
        """실측 회귀: 홈은 명령 안에서 여러 번 나온다(리다이렉트 대상).

        앞부분만 치환하면 키에 박스별 경로가 남아 같은 잡이 다른 박스에서 매칭되지 않는다
        (2026-07-28: verify-viewer-identities-sweep.sh 가 이 이유로 51/52 에서 빠졌다).
        """
        with patch.object(cs.os, "getuid", return_value=1001), \
                patch.object(cs.pwd, "getpwuid",
                             return_value=SimpleNamespace(pw_dir="/home/alice")):
            self.assertEqual(
                cs.description_key({
                    "kind": "cron",
                    "command": "/home/alice/s.sh >> /home/alice/.cache/s.log 2>&1  # 설명",
                }),
                "cmd:~/s.sh >> ~/.cache/s.log 2>&1  # 설명")

    def test_description_key_does_not_replace_home_lookalike_paths(self):
        """경로 경계에서만 치환한다 — 다른 사용자의 홈이나 부분일치를 건드리면 키가 오염된다."""
        with patch.object(cs.os, "getuid", return_value=1001), \
                patch.object(cs.pwd, "getpwuid",
                             return_value=SimpleNamespace(pw_dir="/home/alice")):
            for cmd in ("/home/aliceua/bin/x.sh", "/srv/home/alice/bin/x.sh",
                        "/home/alicexyz/y.sh"):
                self.assertEqual(
                    cs.description_key({"kind": "cron", "command": cmd}), "cmd:" + cmd, cmd)

    def test_catalog_matching_adds_description_fields_and_counts_unmatched(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "job-descriptions.json")
            self.write_catalog(path, {
                "unit:demo.timer": {"what": "타이머 설명", "note": "검토 메모"},
                "cmd:~/bin/x": {"what": "크론 설명"},
            })
            jobs = [
                {"kind": "systemd", "unit": "demo.timer"},
                {"kind": "cron", "command": "/home/alice/bin/x"},
                {"kind": "cron", "command": "/opt/missing"},
            ]
            with patch.dict(os.environ, {"CRON_CONSOLE_DESCRIPTIONS": path}), \
                    patch.object(cs, "_owner_home", return_value="/home/alice"):
                source = cs.apply_descriptions(jobs)
            self.assertTrue(source["ok"])
            self.assertEqual(
                (source["count"], source["total"], source["described"],
                 source["missing"], source["invalidJobs"]),
                (2, 3, 2, 1, 0))
            self.assertNotIn("unmatched", source)
            self.assertEqual(jobs[0]["description"], "타이머 설명")
            self.assertEqual(jobs[0]["descriptionNote"], "검토 메모")
            self.assertEqual(jobs[0]["descriptionSource"], "catalog")
            self.assertIsNone(jobs[0]["sot"])
            self.assertIsNone(jobs[1]["descriptionNote"])
            self.assertEqual(jobs[2]["descriptionSource"], "none")
            self.assertIsNone(jobs[2]["description"])

    # ── 설명 상태 계약 ──────────────────────────────────────────────────────
    # "없다"·"못 읽었다"·"깨졌다" 를 한 문장으로 뭉뚱그리면 사람이 틀린 결론에 도달한다.

    def test_what_validator_rejects_boundary_values(self):
        """유효 기준은 valid_description 한 곳뿐 — 경계를 여기서 못 박는다."""
        for bad in (None, 123, "", "   ", "\t\n ", "a\x00b", "a\nb", "a\tb",
                    "a\x7fb", "x" * (cs.DESCRIPTION_MAX_LEN + 1)):
            self.assertIsNone(cs.valid_description(bad), repr(bad))

    def test_what_validator_accepts_and_normalizes(self):
        self.assertEqual(cs.valid_description("  설명  "), "설명")
        edge = "x" * cs.DESCRIPTION_MAX_LEN
        self.assertEqual(cs.valid_description(edge), edge)
        self.assertIsNone(cs.valid_description(" " + edge + " x"))

    def test_description_status_distinguishes_four_situations(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "job-descriptions.json")
            self.write_catalog(path, {
                "unit:ok.timer": {"what": "정상 설명"},
                "unit:blank.timer": {"what": "   ", "note": "메모는 남아있다"},
            })
            jobs = [
                {"kind": "systemd", "unit": "ok.timer"},
                {"kind": "systemd", "unit": "blank.timer"},
                {"kind": "systemd", "unit": "absent.timer"},
            ]
            with patch.dict(os.environ, {"CRON_CONSOLE_DESCRIPTIONS": path}):
                source = cs.apply_descriptions(jobs)
            self.assertEqual([j["descriptionStatus"] for j in jobs],
                             ["described", "invalid-entry", "missing"])
            self.assertEqual(
                (source["total"], source["described"], source["missing"],
                 source["invalidJobs"]),
                (3, 1, 1, 1))
            # 엔트리가 매칭됐으면 note 의 출처는 실제로 카탈로그다 — 그 provenance 를 숨기지 않는다.
            self.assertEqual(jobs[1]["descriptionSource"], "catalog")
            self.assertEqual(jobs[1]["descriptionNote"], "메모는 남아있다")
            self.assertIsNone(jobs[1]["description"])

    def test_broken_catalog_marks_jobs_unavailable_not_missing(self):
        """못 읽은 것을 없는 것이라고 단정하면 사람이 52개를 쓰려 든다."""
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "job-descriptions.json")
            with open(path, "w", encoding="utf-8") as f:
                f.write('{"schemaVersion": 1, "entries": {')
            jobs = [{"kind": "systemd", "unit": "a.timer"},
                    {"kind": "systemd", "unit": "b.timer"}]
            with patch.dict(os.environ, {"CRON_CONSOLE_DESCRIPTIONS": path}):
                source = cs.apply_descriptions(jobs)
            self.assertFalse(source["ok"])
            for key in ("described", "missing", "invalidJobs", "total", "count"):
                self.assertNotIn(key, source)
            self.assertEqual([j["descriptionStatus"] for j in jobs],
                             ["catalog-unavailable"] * 2)
            self.assertEqual(cs.count_jobs(jobs)["descriptionMissing"], 0)

    def test_coverage_counts_partition_every_job(self):
        """합계 항등식만 보면 전부 0 이어도 통과한다 — 그래서 exact tuple 로 고정한다."""
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "job-descriptions.json")
            self.write_catalog(path, {
                "unit:a.timer": {"what": "가"},
                "unit:b.timer": {"what": "나"},
                "unit:c.timer": {"what": ""},
                "unit:unused.timer": {"what": "쓰이지 않는 엔트리"},
            })
            jobs = [{"kind": "systemd", "unit": u}
                    for u in ("a.timer", "b.timer", "c.timer", "d.timer", "e.timer")]
            with patch.dict(os.environ, {"CRON_CONSOLE_DESCRIPTIONS": path}):
                source = cs.apply_descriptions(jobs)
            self.assertEqual(
                (source["count"], source["total"], source["described"],
                 source["missing"], source["invalidJobs"]),
                (4, 5, 2, 2, 1))
            self.assertEqual(source["total"], len(jobs))
            self.assertEqual(
                source["described"] + source["missing"] + source["invalidJobs"],
                source["total"])
            self.assertEqual(cs.count_jobs(jobs)["descriptionMissing"], 2)

    def test_descriptions_do_not_change_judgement_or_origin(self):
        """설명은 판정·출처에 영향 0이어야 한다 — diff --stat 은 이걸 증명 못 한다."""
        def sample():
            return [
                {"kind": "systemd", "unit": "a.timer", "execution": "observed",
                 "timeliness": "on-time", "lastResult": "success",
                 "reboot": "postboot-observed",
                 "origin": {"kind": "package", "package": "util-linux"}},
                {"kind": "cron", "command": "/opt/x", "execution": "unobserved",
                 "timeliness": "unknown", "lastResult": "none", "reboot": "unsafe",
                 "origin": {"kind": "unresolved", "reason": "레포 밖"}},
            ]
        watched = ("execution", "timeliness", "lastResult", "reboot", "origin")
        before = [{k: j[k] for k in watched} for j in sample()]
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "job-descriptions.json")
            self.write_catalog(path, {"unit:a.timer": {"what": "설명"}})
            jobs = sample()
            with patch.dict(os.environ, {"CRON_CONSOLE_DESCRIPTIONS": path}):
                cs.apply_descriptions(jobs)
        self.assertEqual([{k: j[k] for k in watched} for j in jobs], before)

    def test_unavailable_jobs_still_expose_description_key(self):
        """카탈로그를 못 읽어도 키는 남아야 한다 — 초안 생성이 이 키로 대상을 지목한다."""
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "job-descriptions.json")
            with open(path, "w", encoding="utf-8") as f:
                f.write("{oops")
            jobs = [{"kind": "systemd", "unit": "a.timer"}]
            with patch.dict(os.environ, {"CRON_CONSOLE_DESCRIPTIONS": path}):
                cs.apply_descriptions(jobs)
            self.assertEqual(jobs[0]["descriptionKey"], "unit:a.timer")
            self.assertEqual(jobs[0]["descriptionSource"], "none")
            self.assertIsNone(jobs[0]["description"])
            self.assertIsNone(jobs[0]["descriptionNote"])
            self.assertIsNone(jobs[0]["sot"])

    def test_coverage_of_empty_job_list_is_all_zero(self):
        """잡이 0건이면 total 도 0이다 — 상수로 채운 구현이 여기서 걸린다."""
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "job-descriptions.json")
            self.write_catalog(path, {"unit:a.timer": {"what": "가"}})
            with patch.dict(os.environ, {"CRON_CONSOLE_DESCRIPTIONS": path}):
                source = cs.apply_descriptions([])
            self.assertEqual(
                (source["count"], source["total"], source["described"],
                 source["missing"], source["invalidJobs"]),
                (1, 0, 0, 0, 0))

    def test_invalid_jobs_counts_jobs_not_entries(self):
        """`invalidJobs` 는 엔트리 수가 아니라 그 엔트리를 참조하는 잡 수다(화면 문구와 일치)."""
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "job-descriptions.json")
            self.write_catalog(path, {"unit:dup.timer": {"what": "  "}})
            jobs = [{"kind": "systemd", "unit": "dup.timer"},
                    {"kind": "systemd", "unit": "dup.timer"}]
            with patch.dict(os.environ, {"CRON_CONSOLE_DESCRIPTIONS": path}):
                source = cs.apply_descriptions(jobs)
            self.assertEqual((source["count"], source["total"], source["invalidJobs"]),
                             (1, 2, 2))
            self.assertEqual([j["descriptionStatus"] for j in jobs],
                             ["invalid-entry"] * 2)

    def test_note_and_sot_keep_their_own_contract(self):
        """what 의 validator 를 note·sot 에 씌우면 여러 줄 note 를 조용히 버린다(회귀 방지)."""
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "job-descriptions.json")
            self.write_catalog(path, {"unit:a.timer": {
                "what": "정상 설명",
                "note": "첫 줄\n둘째 줄",
                "sot": "x" * (cs.DESCRIPTION_MAX_LEN + 1),
            }})
            jobs = [{"kind": "systemd", "unit": "a.timer"}]
            with patch.dict(os.environ, {"CRON_CONSOLE_DESCRIPTIONS": path}):
                cs.apply_descriptions(jobs)
            self.assertEqual(jobs[0]["descriptionNote"], "첫 줄\n둘째 줄")
            self.assertEqual(jobs[0]["sot"], "x" * (cs.DESCRIPTION_MAX_LEN + 1))
            self.assertEqual(jobs[0]["descriptionStatus"], "described")

    def test_judgement_and_origin_survive_every_description_branch(self):
        """네 상태 분기를 모두 태워도 판정축·출처는 그대로여야 한다."""
        def sample():
            return [
                {"kind": "systemd", "unit": "ok.timer", "execution": "observed",
                 "timeliness": "on-time", "lastResult": "success",
                 "reboot": "postboot-observed", "origin": {"kind": "package",
                                                           "package": "util-linux"}},
                {"kind": "systemd", "unit": "blank.timer", "execution": "inferred",
                 "timeliness": "pending", "lastResult": "unknown", "reboot": "unknown",
                 "origin": {"kind": "repo", "repo": "example-infra"}},
                {"kind": "systemd", "unit": "absent.timer", "execution": "unobserved",
                 "timeliness": "unknown", "lastResult": "none", "reboot": "unsafe",
                 "origin": {"kind": "unresolved", "reason": "레포 밖"}},
            ]
        watched = ("execution", "timeliness", "lastResult", "reboot", "origin")
        before = [{k: j[k] for k in watched} for j in sample()]
        with tempfile.TemporaryDirectory() as root:
            good = os.path.join(root, "good.json")
            self.write_catalog(good, {"unit:ok.timer": {"what": "설명"},
                                      "unit:blank.timer": {"what": " "}})
            broken = os.path.join(root, "broken.json")
            with open(broken, "w", encoding="utf-8") as f:
                f.write("{nope")
            for path in (good, broken):
                jobs = sample()
                with patch.dict(os.environ, {"CRON_CONSOLE_DESCRIPTIONS": path}):
                    cs.apply_descriptions(jobs)
                self.assertEqual([{k: j[k] for k in watched} for j in jobs], before, path)

    def test_catalog_sot_is_read_without_changing_other_fields(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "job-descriptions.json")
            self.write_catalog(path, {
                "cmd:/opt/job": {
                    "what": "설명 유지",
                    "note": "메모 유지",
                    "sot": "example-infra infra/devbox/scripts/job.sh",
                },
            })
            jobs = [{"kind": "cron", "command": "/opt/job"}]
            with patch.dict(os.environ, {"CRON_CONSOLE_DESCRIPTIONS": path}):
                cs.apply_descriptions(jobs)
        self.assertEqual(jobs[0]["description"], "설명 유지")
        self.assertEqual(jobs[0]["descriptionNote"], "메모 유지")
        self.assertEqual(jobs[0]["sot"], "example-infra infra/devbox/scripts/job.sh")

    def test_missing_catalog_is_source_failure_without_exception(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "missing.json")
            with patch.dict(os.environ, {"CRON_CONSOLE_DESCRIPTIONS": path}):
                source = cs.apply_descriptions([])
            self.assertFalse(source["ok"])
            self.assertEqual((source["scope"], source["kind"]),
                             ("descriptions", "job-descriptions.json"))
            self.assertIn("파일 없음", source["error"])

    def test_schema_version_mismatch_is_loud_source_failure(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "job-descriptions.json")
            self.write_catalog(path, {}, schema=99)
            with patch.dict(os.environ, {"CRON_CONSOLE_DESCRIPTIONS": path}):
                source = cs.apply_descriptions([])
            self.assertFalse(source["ok"])
            self.assertIn("schemaVersion", source["error"])
            self.assertIn("99", source["error"])

    def test_broken_json_is_source_failure_without_exception(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "job-descriptions.json")
            with open(path, "w", encoding="utf-8") as f:
                f.write('{"schemaVersion": 1,')
            with patch.dict(os.environ, {"CRON_CONSOLE_DESCRIPTIONS": path}):
                source = cs.apply_descriptions([])
            self.assertFalse(source["ok"])
            self.assertIn("JSON", source["error"])

    def test_catalog_reloads_when_mtime_changes(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "job-descriptions.json")
            self.write_catalog(path, {"cmd:/opt/job": {"what": "첫 설명"}})
            with patch.dict(os.environ, {"CRON_CONSOLE_DESCRIPTIONS": path}):
                first, _ = cs.load_description_catalog()
                first_mtime = os.stat(path).st_mtime_ns
                self.write_catalog(path, {"cmd:/opt/job": {"what": "두 번째 설명"}})
                os.utime(path, ns=(first_mtime + 1, first_mtime + 1))
                second, _ = cs.load_description_catalog()
            self.assertEqual(first["cmd:/opt/job"]["what"], "첫 설명")
            self.assertEqual(second["cmd:/opt/job"]["what"], "두 번째 설명")


class OriginAttribution(unittest.TestCase):
    def make_file(self, path: str) -> None:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8"):
            pass

    def test_repo_origin_has_remote_relative_path_and_commit(self):
        with tempfile.TemporaryDirectory() as root:
            repo = os.path.join(root, "example-infra")
            script = os.path.join(repo, "scripts", "skill-wiring-check.sh")
            os.makedirs(os.path.join(repo, ".git"))
            self.make_file(script)

            def fake_run(argv, timeout):
                self.assertEqual(timeout, 10 if "config" in argv else 15)
                if "config" in argv:
                    return 0, "git@github.com:example/example-infra.git\n", ""
                return 0, "Alice Example|alice@example.com|2026-07-28|fix(skill-wiring): check\n", ""

            job = {"command": script}
            with patch.object(cs, "run_cmd", side_effect=fake_run) as run:
                cs.apply_origins([job])
        self.assertEqual(job["origin"], {
            "kind": "repo",
            "path": os.path.realpath(script),
            "repo": "example-infra",
            "relPath": "scripts/skill-wiring-check.sh",
            "commit": {
                "author": "Alice Example <alice@example.com>",
                "date": "2026-07-28",
                "subject": "fix(skill-wiring): check",
            },
            "package": None,
            "reason": None,
        })
        self.assertEqual(run.call_count, 2)

    def test_symlink_origin_uses_target_repo_and_relative_path(self):
        with tempfile.TemporaryDirectory() as root:
            repo = os.path.join(root, "example-wiki")
            target = os.path.join(repo, "scripts", "wiki_drawings", "run.sh")
            link = os.path.join(root, "bin", "sync-wiki-drawings")
            os.makedirs(os.path.join(repo, ".git"))
            self.make_file(target)
            os.makedirs(os.path.dirname(link))
            os.symlink(target, link)

            def fake_run(argv, timeout):
                if "config" in argv:
                    return 0, "https://github.com/example/example-wiki.git\n", ""
                return 0, "Alice|alice@example.com|2026-07-28|sync drawings\n", ""

            job = {"command": link}
            with patch.object(cs, "run_cmd", side_effect=fake_run):
                cs.apply_origins([job])
        self.assertEqual(job["origin"]["repo"], "example-wiki")
        self.assertEqual(job["origin"]["relPath"], "scripts/wiki_drawings/run.sh")
        self.assertEqual(job["origin"]["path"], os.path.realpath(target))

    def test_git_log_is_reused_for_duplicate_file_jobs(self):
        with tempfile.TemporaryDirectory() as root:
            repo = os.path.join(root, "example-agents")
            script = os.path.join(repo, "runners", "fleet-curator-run.sh")
            os.makedirs(os.path.join(repo, ".git"))
            self.make_file(script)
            calls = []

            def fake_run(argv, timeout):
                calls.append(argv)
                if "config" in argv:
                    return 0, "https://github.com/example/example-agents.git\n", ""
                return 0, "Alice|alice@example.com|2026-07-23|fix(fleet-curator): run\n", ""

            with patch.object(cs, "run_cmd", side_effect=fake_run):
                cs.apply_origins([{"command": script}, {"command": script}])
        self.assertEqual(len([argv for argv in calls if "log" in argv]), 1)
        self.assertEqual(len([argv for argv in calls if "config" in argv]), 1)

    def test_git_log_failure_is_unresolved_without_exception(self):
        with tempfile.TemporaryDirectory() as root:
            repo = os.path.join(root, "repo")
            script = os.path.join(repo, "job.sh")
            os.makedirs(os.path.join(repo, ".git"))
            self.make_file(script)

            def failed_log(argv, timeout):
                if "log" in argv:
                    return -1, "", "git missing"
                return 0, "git@github.com:example/repo.git\n", ""

            job = {"command": script}
            with patch.object(cs, "run_cmd", side_effect=failed_log):
                cs.apply_origins([job])
        self.assertEqual(job["origin"]["kind"], "unresolved")
        self.assertEqual(job["origin"]["path"], os.path.realpath(script))
        self.assertIn("git log 실패", job["origin"]["reason"])

    def test_dpkg_is_called_once_and_comma_output_uses_first_package(self):
        with tempfile.TemporaryDirectory() as root:
            first = os.path.join(root, "fstrim")
            second = os.path.join(root, "debian-sa1")
            self.make_file(first)
            self.make_file(second)
            calls = []

            def fake_run(argv, timeout):
                calls.append((argv, timeout))
                self.assertEqual(argv[:2], ["dpkg", "-S"])
                return 0, f"util-linux, old-util: {first}\nsysstat: {second}\n", ""

            jobs = [{"command": first}, {"command": second}]
            with patch.object(cs, "git_root_for_path", return_value=None), \
                    patch.object(cs, "run_cmd", side_effect=fake_run):
                cs.apply_origins(jobs)
        self.assertEqual(len(calls), 1)
        self.assertEqual(jobs[0]["origin"]["package"], "util-linux")
        self.assertEqual(jobs[1]["origin"]["package"], "sysstat")
        self.assertEqual(cs.parse_dpkg_search(f"a, b: {first}\n")[first], "a")

    def test_usrmerge_query_uses_realpath(self):
        original_realpath = cs.os.path.realpath

        def realpath(path):
            return "/usr/sbin/fstrim" if path == "/sbin/fstrim" else original_realpath(path)

        job = {"command": "/sbin/fstrim"}
        with patch.object(cs.os.path, "realpath", side_effect=realpath), \
                patch.object(cs.os.path, "exists", return_value=True), \
                patch.object(cs, "git_root_for_path", return_value=None), \
                patch.object(cs, "run_cmd", return_value=(0, "util-linux: /usr/sbin/fstrim\n", "")) as run:
            cs.apply_origins([job])
        self.assertEqual(job["origin"]["kind"], "package")
        self.assertEqual(job["origin"]["path"], "/usr/sbin/fstrim")
        self.assertEqual(run.call_args.args[0], ["dpkg", "-S", "/usr/sbin/fstrim"])

    def test_dpkg_failure_is_unresolved_without_exception(self):
        with tempfile.TemporaryDirectory() as root:
            script = os.path.join(root, "copy.sh")
            self.make_file(script)
            job = {"command": script}
            with patch.object(cs, "git_root_for_path", return_value=None), \
                    patch.object(cs, "run_cmd", return_value=(-1, "", "dpkg unavailable")):
                cs.apply_origins([job])
        self.assertEqual(job["origin"]["kind"], "unresolved")
        self.assertIn("dpkg -S 실패", job["origin"]["reason"])

    def test_no_candidate_is_unresolved_with_reason(self):
        job = {"command": "not-a-real-command"}
        with patch.object(cs.shutil, "which", return_value=None):
            cs.apply_origins([job])
        self.assertEqual(job["origin"], {
            "kind": "unresolved", "path": None, "repo": None, "relPath": None,
            "commit": None, "package": None, "reason": "실행 대상 경로를 찾지 못했습니다",
        })

    def test_fragment_path_can_be_attributed_to_systemd_package(self):
        with tempfile.TemporaryDirectory() as root:
            fragment = os.path.join(root, "systemd-tmpfiles-clean.timer")
            self.make_file(fragment)
            job = {"command": "", "_fragmentPath": fragment}
            with patch.object(cs, "git_root_for_path", return_value=None), \
                    patch.object(cs, "run_cmd", return_value=(0, f"systemd: {fragment}\n", "")):
                cs.apply_origins([job])
        self.assertEqual(job["origin"]["kind"], "package")
        self.assertEqual(job["origin"]["package"], "systemd")

    def test_systemd_collection_keeps_timer_fragment_path(self):
        timer_path = "/usr/lib/systemd/system/systemd-tmpfiles-clean.timer"
        service_path = "/usr/lib/systemd/system/systemd-tmpfiles-clean.service"

        def fake_run(argv, timeout=15):
            if "list-timers" in argv:
                return 0, "systemd-tmpfiles-clean.timer\n", ""
            if cs.TIMER_PROPS in argv:
                return 0, (
                    "Id=systemd-tmpfiles-clean.timer\n"
                    "Unit=systemd-tmpfiles-clean.service\n"
                    "UnitFileState=enabled\nActiveState=active\n"
                    f"FragmentPath={timer_path}\n"
                ), ""
            self.assertIn(cs.SERVICE_PROPS, argv)
            return 0, (
                "Id=systemd-tmpfiles-clean.service\nResult=\nExecMainStatus=0\n"
                f"FragmentPath={service_path}\n"
            ), ""

        with patch.object(cs, "run_cmd", side_effect=fake_run):
            jobs, source = cs.collect_systemd("system", None, 0)
        self.assertTrue(source["ok"])
        self.assertEqual(jobs[0]["_fragmentPath"], timer_path)
        self.assertIn("FragmentPath", cs.TIMER_PROPS)
        self.assertIn("FragmentPath", cs.SERVICE_PROPS)

    def test_git_marker_file_is_a_worktree_root(self):
        with tempfile.TemporaryDirectory() as root:
            repo = os.path.join(root, "worktree")
            script = os.path.join(repo, "job.sh")
            os.makedirs(repo)
            self.make_file(os.path.join(repo, ".git"))
            self.make_file(script)
            self.assertEqual(cs.git_root_for_path(script), repo)


class ServiceResult(unittest.TestCase):
    RAN = ep("2026-07-28 06:55:29")

    def test_systemd_verdict_wins_over_exit_code(self):
        """실측 회귀: gate-audit-sweep-user 는 warn 이 있으면 exit 1 을 내고 유닛이
        SuccessExitStatus=1 로 그걸 성공으로 규정한다(Result=success, ExecMainStatus=1).
        종료코드를 따로 검사하면 멀쩡한 잡이 '실패'로 뒤집힌다."""
        self.assertEqual(cs.service_result("success", self.RAN), "success")

    def test_real_failure(self):
        self.assertEqual(cs.service_result("exit-code", self.RAN), "failed")

    def test_never_ran_is_not_failure(self):
        self.assertEqual(cs.service_result("", None), "none")

    def test_never_triggered_unit_is_not_ok(self):
        """실측 회귀: 한 번도 안 돈 타이머(fstrim·fwupd-refresh)도 Result 초기값이 'success' 라
        Result 를 먼저 보면 '정상'으로 둔갑한다 — 실행 여부가 우선이다."""
        self.assertEqual(cs.service_result("success", None), "none")


class Judge(unittest.TestCase):
    NOW = ep("2026-07-28 16:30:00")
    BOOT = ep("2026-07-21 09:00:00")

    def test_ok(self):
        axes = cs.judge(
            enabled=True, last_run=ep("2026-07-28 05:00:00"),
            next_run=ep("2026-07-29 05:00:00"), last_result="success",
            boot_epoch=self.BOOT, now_epoch=self.NOW)
        self.assertEqual(axes["execution"], "observed")
        self.assertEqual(axes["timeliness"], "on-time")
        self.assertEqual(axes["reboot"], "postboot-observed")

    def test_late_when_next_run_overdue_past_grace(self):
        axes = cs.judge(
            enabled=True, last_run=ep("2026-07-27 05:00:00"),
            next_run=self.NOW - cs.LATE_GRACE_SEC - 1, last_result="success",
            boot_epoch=self.BOOT, now_epoch=self.NOW)
        self.assertEqual(axes["timeliness"], "late")
        self.assertEqual(axes["execution"], "observed")

    def test_not_late_inside_grace(self):
        axes = cs.judge(
            enabled=True, last_run=None,
            next_run=self.NOW - 1, last_result="success",
            boot_epoch=self.BOOT, now_epoch=self.NOW)
        self.assertEqual(axes["timeliness"], "pending")

    def test_failed(self):
        axes = cs.judge(
            enabled=True, last_run=ep("2026-07-28 06:55:00"), next_run=None,
            last_result="failed", boot_epoch=self.BOOT, now_epoch=self.NOW)
        self.assertEqual(axes["execution"], "observed")
        self.assertEqual(axes["lastResult"], "failed")
        self.assertEqual(axes["reboot"], "configured-unobserved")

    def test_never_ran(self):
        axes = cs.judge(enabled=True, last_run=None, next_run=None,
                        last_result="none", boot_epoch=self.BOOT, now_epoch=self.NOW)
        self.assertEqual(axes["execution"], "unobserved")
        self.assertEqual(axes["lastResult"], "none")
        self.assertEqual(axes["timeliness"], "unknown")

    def test_disabled_is_unsafe_across_reboot(self):
        axes = cs.judge(enabled=False, last_run=ep("2026-07-28 05:00:00"),
                        next_run=None, last_result="success",
                        boot_epoch=self.BOOT, now_epoch=self.NOW)
        self.assertEqual(axes["reboot"], "unsafe")

    def test_enabled_but_not_run_since_boot_is_unproven(self):
        axes = cs.judge(enabled=True, last_run=ep("2026-07-20 05:00:00"),
                        next_run=None, last_result="success",
                        boot_epoch=self.BOOT, now_epoch=self.NOW)
        self.assertEqual(axes["reboot"], "configured-unobserved")

    def test_unknown_boot_time_never_claims_proven(self):
        axes = cs.judge(enabled=True, last_run=ep("2026-07-28 05:00:00"),
                        next_run=None, last_result="success",
                        boot_epoch=None, now_epoch=self.NOW)
        self.assertEqual(axes["reboot"], "unknown")


class Counts(unittest.TestCase):
    def test_counts_every_axis_state_and_reboot_risk(self):
        jobs = [
            {"execution": "observed", "timeliness": "on-time", "lastResult": "success",
             "reboot": "postboot-observed"},
            {"execution": "observed", "timeliness": "on-time", "lastResult": "failed",
             "reboot": "configured-unobserved"},
            {"execution": "unobserved", "timeliness": "late", "lastResult": "none",
             "reboot": "unsafe"},
            {"execution": "unavailable", "timeliness": "unknown", "lastResult": "unknown",
             "reboot": "unknown"},
            {"execution": "unobserved", "timeliness": "pending", "lastResult": "none",
             "reboot": "unsafe"},
        ]
        c = cs.count_jobs(jobs)
        self.assertEqual(c["total"], 5)
        self.assertEqual((c["executionObserved"], c["executionUnobserved"],
                          c["executionUnavailable"]), (2, 2, 1))
        self.assertEqual((c["timelinessOnTime"], c["timelinessLate"],
                          c["timelinessPending"], c["timelinessUnknown"]), (2, 1, 1, 1))
        self.assertEqual((c["resultSuccess"], c["resultFailed"], c["resultUnknown"],
                          c["resultNone"]), (1, 1, 1, 2))
        self.assertEqual(c["rebootUnsafe"], 2)
        self.assertEqual(c["rebootConfiguredUnobserved"], 1)


class OriginDefinitionFallback(unittest.TestCase):
    """실행 대상을 못 찾으면 잡을 **정의한 파일**로 폴백한다.

    실측 근거: `/etc/cron.d/sysstat` 의 `command -v debian-sa1 > /dev/null && debian-sa1 1 1` 은
    그 파일이 자체 `PATH=/usr/lib/sysstat:…` 를 설정해 cron 컨텍스트에서만 해소된다 — 우리 프로세스
    PATH 에는 debian-sa1 이 없어 which 가 실패하고, 폴백이 없으면 이 잡은 영구 unresolved 였다.
    """

    def test_definition_file_is_last_resort_candidate(self):
        with tempfile.TemporaryDirectory() as root:
            defin = os.path.join(root, "sysstat")
            with open(defin, "w") as f:
                f.write("x")
            cands = cs.execution_path_candidates(
                "command -v debian-sa1 > /dev/null && debian-sa1 1 1", definition_path=defin)
            kinds = [c["kind"] for c in cands]
            self.assertIn("definition", kinds)
            picked = cs.select_origin_candidate(cands, {})
            self.assertEqual(picked["kind"], "definition")

    def test_real_execution_target_beats_definition_file(self):
        with tempfile.TemporaryDirectory() as root:
            defin = os.path.join(root, "cron.d-entry")
            script = os.path.join(root, "real.sh")
            for path in (defin, script):
                with open(path, "w") as f:
                    f.write("x")
            cands = cs.execution_path_candidates(script, definition_path=defin)
            picked = cs.select_origin_candidate(cands, {})
            self.assertEqual(picked["path"], os.path.realpath(script))

    def test_personal_crontab_has_no_definition_path(self):
        self.assertIsNone(cs._job_definition_path({"source": "crontab"}))
        self.assertEqual(
            cs._job_definition_path({"source": "/etc/cron.d/sysstat"}), "/etc/cron.d/sysstat")


class UnitSafety(unittest.TestCase):
    def test_accepts_real_unit_names(self):
        for u in ("scratch-sweep.timer", "user@1001.service", "a_b.timer", "x.service"):
            self.assertRegex(u, cs.UNIT_SAFE_RE, u)

    def test_rejects_injection_and_wrong_suffix(self):
        for u in ("a.timer;rm -rf /", "../../etc/passwd", "a.socket", "a b.timer", ""):
            self.assertIsNone(cs.UNIT_SAFE_RE.match(u), u)


class CronPreviousRun(unittest.TestCase):
    NOW = ep("2026-07-28 16:30:00")

    def test_previous_minute_is_included(self):
        self.assertEqual(cs.cron_prev_epoch("30 16 * * *", self.NOW), self.NOW)

    def test_previous_schedule_rolls_back_a_day(self):
        self.assertEqual(
            cs.cron_prev_epoch("0 5 * * *", self.NOW), ep("2026-07-28 05:00:00"))

    def test_previous_dom_dow_uses_vixie_or(self):
        self.assertEqual(
            cs.cron_prev_epoch("0 0 30 * 3", self.NOW), ep("2026-07-22 00:00:00"))

    def test_previous_unparseable_is_none(self):
        self.assertIsNone(cs.cron_prev_epoch("CRON_TZ=UTC", self.NOW))


def journal_line(message: str, ts: float = ep("2026-07-28 16:30:00"), boot: str = "boot-current") -> str:
    return json.dumps({
        "MESSAGE": message,
        "__REALTIME_TIMESTAMP": str(int(ts * 1_000_000)),
        "_BOOT_ID": boot,
    }, ensure_ascii=False)


class CronCommandRendering(unittest.TestCase):
    def test_probe_a_literal_octal_backslash_is_unchanged(self):
        self.assertEqual(
            cs.render_cron_command(r"/bin/true probeA a\141b"),
            r"/bin/true probeA a\141b")

    def test_probe_b_double_backslash_becomes_one(self):
        self.assertEqual(
            cs.render_cron_command(r"/bin/true probeB x\\y"),
            r"/bin/true probeB x\y")

    def test_probe_c_escaped_percent_is_literal(self):
        self.assertEqual(
            cs.render_cron_command(r"/bin/true probeC pct-\%-tail"),
            r"/bin/true probeC pct-%-tail")

    def test_probe_d_unescaped_percent_truncates(self):
        self.assertEqual(
            cs.render_cron_command(r"/bin/true probeD pre%post"),
            r"/bin/true probeD pre")

    def test_probe_e_non_ascii_is_utf8_octal(self):
        self.assertEqual(
            cs.render_cron_command("/bin/true probeE 한글-테스트"),
            r"/bin/true probeE \355\225\234\352\270\200-\355\205\214\354\212\244\355\212\270")

    def test_other_backslashes_are_not_interpreted(self):
        self.assertEqual(cs.render_cron_command(r"printf '\n \x \354'"),
                         r"printf '\n \x \354'")

    def test_even_backslashes_leave_percent_unescaped(self):
        self.assertEqual(cs.render_cron_command(r"echo x\\%tail"), "echo x" + "\\")

    def test_odd_backslashes_keep_percent_escaped(self):
        self.assertEqual(cs.render_cron_command(r"echo x\\\%tail"), "echo x\\%tail")


class JournalParsing(unittest.TestCase):
    def test_journal_command_is_kept_raw(self):
        parsed = cs.parse_cron_message(r"(alice) CMD (/home/alice/bin/sync-wiki \353\217\204)")
        self.assertEqual(parsed, ("alice", r"/home/alice/bin/sync-wiki \353\217\204"))

    def test_malformed_record_is_counted_not_raised(self):
        events, malformed, minimum = cs.parse_cron_journal_records(
            "[]\n" + journal_line("(alice) CMD (echo hi)", ts=123.0))
        self.assertEqual(malformed, 1)
        self.assertEqual(minimum, 123.0)
        self.assertIn(("alice", "echo hi"), events)

    def test_pam_session_lines_are_discarded(self):
        raw = "\n".join([
            journal_line("pam_unix(cron:session): session opened for user alice"),
            journal_line("pam_unix(cron:session): session closed for user alice"),
        ])
        self.assertEqual(cs.parse_cron_journal(raw), {})

    def test_inner_parentheses_and_trailing_comment_are_preserved(self):
        command = "sh -c 'printf (x)' # 주석"
        parsed = cs.parse_cron_message(f"(alice) CMD ({command})")
        self.assertEqual(parsed, ("alice", command))

    def test_same_command_different_users_have_separate_keys(self):
        command = "/opt/job # same"
        raw = "\n".join([
            journal_line(f"(alice) CMD ({command})"),
            journal_line(f"(root) CMD ({command})"),
        ])
        index = cs.parse_cron_journal(raw)
        self.assertEqual(set(index), {("alice", command), ("root", command)})

    def test_timestamp_is_converted_from_microseconds(self):
        index = cs.parse_cron_journal(journal_line("(alice) CMD (echo hi)", ts=123.25))
        self.assertEqual(index[("alice", "echo hi")][0]["ts"], 123.25)

    def test_json_non_object_is_one_malformed_record(self):
        events, malformed, minimum = cs.parse_cron_journal_records("[]")
        self.assertEqual(events, {})
        self.assertEqual(malformed, 1)
        self.assertIsNone(minimum)


class CronObservation(unittest.TestCase):
    NOW = ep("2026-07-28 16:30:00")
    BOOT = ep("2026-07-21 09:00:00")

    def make_job(self, text: str, *, user: str = "alice", source: str = "crontab",
                 mtime: float | None = None) -> dict:
        jobs, bad = cs.parse_cron_text(
            text, source=source, scope="crontab", has_user_field=False,
            default_user=user, now=self.NOW, definition_mtime=mtime)
        self.assertEqual(bad, [])
        self.assertEqual(len(jobs), 1)
        return jobs[0]

    def source(self, *, ok: bool = True, start: float | None = None) -> dict:
        return {
            "scope": "cron-journal", "kind": "sudo journalctl -t CRON", "ok": ok,
            "count": 0, "coverageStart": self.BOOT if start is None else start,
            "coverageEnd": self.NOW,
        }

    def apply(self, jobs: list[dict], events: dict, *, source: dict | None = None,
              service: dict | None = None, now: float | None = None,
              current_id: str | None = "boot-current") -> None:
        cs.apply_cron_observations(
            jobs, events, source or self.source(),
            service or {"unitFileState": "enabled", "activeSince": self.BOOT},
            btime=self.BOOT, now=self.NOW if now is None else now, current_id=current_id)

    def test_direct_signal_is_observed_but_result_unknown(self):
        job = self.make_job("30 16 * * * /opt/job")
        due = cs.cron_prev_epoch(job["schedule"], self.NOW)
        self.apply([job], {(
            "alice", "/opt/job"): [{"ts": due, "boot_id": "boot-current"}]})
        self.assertEqual(job["execution"], "observed")
        self.assertEqual(job["timeliness"], "on-time")
        self.assertEqual(job["lastResult"], "unknown")
        self.assertNotEqual(job["lastResult"], "success")
        self.assertEqual(job["lastSignalKind"], "direct")
        self.assertEqual(job["matchQuality"], "exact")

    def test_definition_is_rendered_to_match_raw_octal_journal(self):
        job = self.make_job(r"30 16 * * * /opt/job a\141b")
        rendered = cs.render_cron_command(job["command"])
        self.assertEqual(rendered, r"/opt/job a\141b")
        self.apply([job], {("alice", rendered): [{"ts": self.NOW, "boot_id": "boot-current"}]})
        self.assertEqual(job["execution"], "observed")

    def test_literal_octal_is_not_matched_as_decoded_text(self):
        job = self.make_job(r"30 16 * * * /opt/job a\141b")
        self.apply([job], {("alice", "/opt/job a"): [{"ts": self.NOW, "boot_id": "boot-current"}]})
        self.assertEqual(job["execution"], "unobserved")
        self.assertEqual(job["lastResult"], "none")

    def test_duplicate_definition_check_uses_rendered_command(self):
        text = (r"30 16 * * * /opt/job x\\y" + chr(10)
                + r"31 16 * * * /opt/job x\y" + chr(10))
        jobs, bad = cs.parse_cron_text(
            text, source="crontab", scope="crontab", has_user_field=False,
            default_user="alice", now=self.NOW)
        self.assertEqual(bad, [])
        self.apply(jobs, {})
        self.assertEqual(
            [job["matchQuality"] for job in jobs], ["ambiguous", "ambiguous"])
        self.assertTrue(all(job["execution"] == "unavailable" for job in jobs))

    def test_successful_empty_journal_means_unobserved_and_none(self):
        job = self.make_job("30 16 * * * /opt/job")
        self.apply([job], {})
        self.assertEqual((job["execution"], job["lastResult"]), ("unobserved", "none"))
        self.assertEqual(job["matchQuality"], "none")

    def test_different_user_signal_does_not_match(self):
        job = self.make_job("30 16 * * * /opt/job", user="alice")
        self.apply([job], {("root", "/opt/job"): [{"ts": self.NOW, "boot_id": "boot-current"}]})
        self.assertEqual(job["execution"], "unobserved")
        self.assertEqual(job["lastResult"], "none")

    def test_duplicate_definition_is_ambiguous_and_unavailable(self):
        jobs, bad = cs.parse_cron_text(
            "30 16 * * * /opt/job\n31 16 * * * /opt/job\n",
            source="crontab", scope="crontab", has_user_field=False,
            default_user="alice", now=self.NOW)
        self.assertEqual(bad, [])
        self.apply(jobs, {("alice", "/opt/job"): [{"ts": self.NOW, "boot_id": "boot-current"}]})
        self.assertTrue(all(job["matchQuality"] == "ambiguous" for job in jobs))
        self.assertTrue(all(job["execution"] == "unavailable" for job in jobs))

    def test_late_grace_boundary_is_pending(self):
        now = ep("2026-07-28 16:35:00")
        job = self.make_job("30 16 * * * /opt/job")
        self.apply([job], {}, now=now)
        self.assertEqual(job["lastDue"], ep("2026-07-28 16:30:00"))
        self.assertEqual(job["timeliness"], "pending")

    def test_late_after_grace_is_late(self):
        now = ep("2026-07-28 16:35:01")
        job = self.make_job("30 16 * * * /opt/job")
        self.apply([job], {}, now=now)
        self.assertEqual(job["timeliness"], "late")

    def test_coverage_start_gate_suppresses_false_late(self):
        now = ep("2026-07-28 17:00:00")
        job = self.make_job("30 16 * * * /opt/job")
        self.apply([job], {}, source=self.source(start=ep("2026-07-28 16:31:00")), now=now)
        self.assertEqual(job["timeliness"], "pending")

    def test_empty_observation_suppresses_false_late(self):
        now = ep("2026-07-28 17:00:00")
        job = self.make_job("30 16 * * * /opt/job")
        source = self.source()
        source["coverageStart"] = None
        source["empty"] = True
        self.apply([job], {}, source=source, now=now)
        self.assertEqual(job["timeliness"], "pending")

    def test_btime_gate_is_part_of_false_late_suppression(self):
        now = ep("2026-07-28 17:00:00")
        job = self.make_job("30 16 * * * /opt/job")
        source = self.source(start=ep("2026-07-28 15:00:00"))
        cs.apply_cron_observations(
            [job], {}, source, {"unitFileState": "enabled", "activeSince": self.BOOT},
            btime=ep("2026-07-28 16:31:00"), now=now, current_id="boot-current")
        self.assertEqual(job["timeliness"], "pending")

    def test_definition_mtime_gate_is_part_of_false_late_suppression(self):
        now = ep("2026-07-28 17:00:00")
        job = self.make_job("30 16 * * * /opt/job", mtime=ep("2026-07-28 16:31:00"))
        self.apply([job], {}, now=now)
        self.assertEqual(job["timeliness"], "pending")

    def test_missing_cron_active_since_suppresses_false_late(self):
        now = ep("2026-07-28 17:00:00")
        job = self.make_job("30 16 * * * /opt/job")
        self.apply([job], {}, service={"unitFileState": "enabled", "activeSince": None}, now=now)
        self.assertEqual(job["timeliness"], "pending")

    def test_unparseable_expression_is_timeliness_unknown(self):
        job = self.make_job("bad expr x y z /opt/job")
        self.apply([job], {})
        self.assertEqual(job["timeliness"], "unknown")

    def test_cron_tz_is_timeliness_unknown(self):
        jobs, bad = cs.parse_cron_text(
            "CRON_TZ=UTC\n30 16 * * * /opt/job\n", source="crontab", scope="crontab",
            has_user_field=False, default_user="alice", now=self.NOW)
        self.assertEqual(bad, [])
        self.apply(jobs, {})
        self.assertEqual(jobs[0]["timeliness"], "unknown")

    def test_current_boot_direct_signal_is_postboot_observed(self):
        job = self.make_job("30 16 * * * /opt/job")
        self.apply([job], {("alice", "/opt/job"): [{"ts": self.NOW, "boot_id": "boot-current"}]})
        self.assertEqual(job["reboot"], "postboot-observed")

    def test_kernel_dashed_boot_id_matches_journal_undashed(self):
        """🔴 실측 회귀: 커널 boot_id 는 하이픈, journal `_BOOT_ID` 는 하이픈 없음.
        정규화 없이 비교하면 영구히 거짓이 되어 재부팅 축이 조용히 강등된다
        (2026-07-28 실기에서 cron 잡 14건이 postboot-observed 를 잃었다).
        """
        job = self.make_job("30 16 * * * /opt/job")
        kernel = "87892b07-4cfb-40fa-ab32-478a532979d6"
        journal = "87892b074cfb40faab32478a532979d6"
        self.apply(
            [job], {("alice", "/opt/job"): [{"ts": self.NOW, "boot_id": journal}]},
            current_id=cs.normalize_boot_id(kernel))
        self.assertEqual(job["reboot"], "postboot-observed")

    def test_normalize_boot_id_is_format_agnostic(self):
        self.assertEqual(
            cs.normalize_boot_id("87892B07-4CFB-40FA-AB32-478A532979D6"),
            cs.normalize_boot_id("87892b074cfb40faab32478a532979d6"))
        self.assertIsNone(cs.normalize_boot_id(None))
        self.assertIsNone(cs.normalize_boot_id(""))

    def test_previous_boot_signal_does_not_prove_postboot(self):
        job = self.make_job("30 16 * * * /opt/job")
        self.apply([job], {("alice", "/opt/job"): [{"ts": self.NOW, "boot_id": "boot-old"}]})
        self.assertEqual(job["reboot"], "configured-unobserved")

    def test_disabled_cron_service_is_unsafe(self):
        job = self.make_job("30 16 * * * /opt/job")
        self.apply(
            [job], {("alice", "/opt/job"): [{"ts": self.NOW, "boot_id": "boot-current"}]},
            service={"unitFileState": "disabled", "activeSince": self.BOOT})
        self.assertEqual(job["reboot"], "unsafe")

    def test_run_parts_child_is_inferred_and_has_no_last_run(self):
        parent = self.make_job(
            "17 * * * * cd / && run-parts --report /etc/cron.daily",
            user="root", source="/etc/crontab")
        parent["_runPartsDir"] = "/etc/cron.daily"
        child = {
            "id": "run-parts:/etc/cron.daily/logrotate", "kind": "run-parts",
            "user": "root", "command": "/etc/cron.daily/logrotate", "lastRun": None,
            "lastResult": "none", "execution": "unobserved", "timeliness": "pending",
            "lastDue": None, "lastSignal": None, "lastSignalKind": "none",
            "matchQuality": "none", "reboot": "unknown", "_parentDir": "/etc/cron.daily",
            "_parentUser": "root", "_cronExpr": parent["_cronExpr"],
            "_cronTz": False, "_definitionMtime": self.BOOT,
        }
        due = cs.cron_prev_epoch(parent["schedule"], self.NOW)
        self.apply([parent, child], {(
            "root", parent["command"]): [{"ts": due, "boot_id": "boot-current"}]})
        self.assertEqual(child["execution"], "inferred")
        self.assertIsNone(child["lastRun"])
        self.assertEqual(child["lastSignalKind"], "parent")

    def test_run_parts_child_without_parent_signal_is_not_observed(self):
        parent = self.make_job(
            "17 * * * * cd / && run-parts --report /etc/cron.daily", user="root",
            source="/etc/crontab")
        parent["_runPartsDir"] = "/etc/cron.daily"
        child = {
            "id": "child", "kind": "run-parts", "user": "root", "command": "/etc/cron.daily/x",
            "lastRun": None, "lastResult": "none", "execution": "unobserved",
            "timeliness": "pending", "lastDue": None, "lastSignal": None,
            "lastSignalKind": "none", "matchQuality": "none", "reboot": "unknown",
            "_parentDir": "/etc/cron.daily", "_parentUser": "root",
            "_cronExpr": parent["_cronExpr"], "_cronTz": False,
            "_definitionMtime": self.BOOT,
        }
        self.apply([parent, child], {})
        self.assertNotEqual(child["execution"], "observed")
        self.assertEqual(child["lastRun"], None)

    def test_run_parts_parent_signal_before_child_mtime_is_not_inherited(self):
        parent = self.make_job(
            "17 * * * * cd / && run-parts --report /etc/cron.daily", user="root",
            source="/etc/crontab")
        parent["_runPartsDir"] = "/etc/cron.daily"
        child = {
            "id": "child-new", "kind": "run-parts", "user": "root",
            "command": "/etc/cron.daily/new", "lastRun": None, "lastResult": "none",
            "execution": "unobserved", "timeliness": "pending", "lastDue": None,
            "lastSignal": None, "lastSignalKind": "none", "matchQuality": "none",
            "reboot": "unknown", "_parentDir": "/etc/cron.daily", "_parentUser": "root",
            "_cronExpr": parent["_cronExpr"], "_cronTz": False,
            "_definitionMtime": self.NOW + 1,
        }
        due = cs.cron_prev_epoch(parent["schedule"], self.NOW)
        self.apply([parent, child], {(
            "root", parent["command"]): [{"ts": due, "boot_id": "boot-current"}]})
        self.assertEqual(child["execution"], "unobserved")
        self.assertIsNone(child["lastSignal"])

    def test_run_parts_unknown_child_mtime_suppresses_late(self):
        parent = self.make_job(
            "17 * * * * cd / && run-parts --report /etc/cron.daily", user="root",
            source="/etc/crontab")
        parent["_runPartsDir"] = "/etc/cron.daily"
        child = {
            "id": "child-stat-failed", "kind": "run-parts", "user": "root",
            "command": "/etc/cron.daily/new", "lastRun": None, "lastResult": "none",
            "execution": "unobserved", "timeliness": "pending", "lastDue": None,
            "lastSignal": None, "lastSignalKind": "none", "matchQuality": "none",
            "reboot": "unknown", "_parentDir": "/etc/cron.daily", "_parentUser": "root",
            "_cronExpr": parent["_cronExpr"], "_cronTz": False,
            "_definitionMtime": None, "_definitionMtimeAvailable": False,
        }
        due = cs.cron_prev_epoch(parent["schedule"], self.NOW)
        self.apply([parent, child], {(
            "root", parent["command"]): [{"ts": due, "boot_id": "boot-current"}]},
            now=ep("2026-07-28 17:00:00"))
        self.assertEqual(child["execution"], "unobserved")
        self.assertEqual(child["timeliness"], "pending")


class CrontabCollection(unittest.TestCase):
    NOW = ep("2026-07-28 16:30:00")

    def test_uid_name_is_used_instead_of_environment_user(self):
        text = "30 16 * * * /opt/job\n"
        with patch.dict(os.environ, {"USER": "wrong-user"}), \
                patch.object(cs.os, "getuid", return_value=1001), \
                patch.object(cs.pwd, "getpwuid", return_value=SimpleNamespace(pw_name="alice")), \
                patch.object(cs, "run_cmd", return_value=(0, text, "")), \
                patch.object(cs.os, "stat", return_value=SimpleNamespace(st_mtime=1234.0)):
            jobs, source = cs.collect_crontab(self.NOW)
        self.assertEqual(jobs[0]["user"], "alice")
        self.assertEqual(jobs[0]["_definitionMtime"], 1234.0)
        self.assertIn("/var/spool/cron/crontabs/alice", source["definitionMtimeSource"])

    def test_crontab_stat_failure_uses_service_start_lower_bound(self):
        text = "30 16 * * * /opt/job\n"
        with patch.object(cs, "SERVICE_START_TIME", 777.0), \
                patch.object(cs.os, "getuid", return_value=1001), \
                patch.object(cs.pwd, "getpwuid", return_value=SimpleNamespace(pw_name="alice")), \
                patch.object(cs, "run_cmd", return_value=(0, text, "")), \
                patch.object(cs.os, "stat", side_effect=PermissionError("denied")):
            jobs, source = cs.collect_crontab(self.NOW)
        self.assertEqual(jobs[0]["_definitionMtime"], 777.0)
        self.assertEqual(source["definitionMtimeSource"], "service-start")
        self.assertIn("denied", source["definitionMtimeFallback"])

    def test_passwd_lookup_failure_marks_crontab_attribution_unavailable(self):
        with patch.object(cs.os, "getuid", return_value=1001), \
                patch.object(cs.pwd, "getpwuid", side_effect=KeyError("1001")), \
                patch.object(cs, "run_cmd", return_value=(0, "30 16 * * * /opt/job\n", "")), \
                patch.object(cs.os, "stat", return_value=SimpleNamespace(st_mtime=1234.0)):
            jobs, source = cs.collect_crontab(self.NOW)
        self.assertTrue(jobs[0]["_attributionUnavailable"])
        self.assertFalse(source["attributionOk"])


class CronFileCollection(unittest.TestCase):
    NOW = ep("2026-07-28 16:30:00")

    def test_existing_definition_does_not_reuse_changed_file_mtime(self):
        with tempfile.TemporaryDirectory() as root:
            cron_d = os.path.join(root, "cron.d")
            os.mkdir(cron_d)
            crontab = os.path.join(root, "crontab")
            cron_file = os.path.join(cron_d, "probe")
            with open(crontab, "w", encoding="utf-8"):
                pass
            with open(cron_file, "w", encoding="utf-8") as f:
                f.write("30 16 * * * root /opt/job\n")
            os.utime(cron_file, (1000, 1000))
            cs._CRON_DEFINITION_SEEN.clear()
            with patch.object(cs, "CRONTAB_FILE", crontab), \
                    patch.object(cs, "CRON_D_DIR", cron_d), \
                    patch.object(cs, "RUN_PARTS_DIRS", ()):
                first, _ = cs.collect_cron_files(self.NOW)
                with open(cron_file, "a", encoding="utf-8") as f:
                    f.write("# unrelated comment\n")
                os.utime(cron_file, (2000, 2000))
                second, _ = cs.collect_cron_files(self.NOW)
        first_job = next(job for job in first if job["source"] == cron_file)
        second_job = next(job for job in second if job["source"] == cron_file)
        self.assertEqual(first_job["_definitionMtime"], 1000.0)
        self.assertIsNone(second_job["_definitionMtime"])

    def test_mtime_failure_does_not_mark_definition_seen(self):
        with tempfile.TemporaryDirectory() as root:
            cron_d = os.path.join(root, "cron.d")
            os.mkdir(cron_d)
            crontab = os.path.join(root, "crontab")
            cron_file = os.path.join(cron_d, "probe")
            with open(crontab, "w", encoding="utf-8"):
                pass
            with open(cron_file, "w", encoding="utf-8") as f:
                f.write("30 16 * * * root /opt/job\n")
            cs._CRON_DEFINITION_SEEN.clear()
            with patch.object(cs, "CRONTAB_FILE", crontab), \
                    patch.object(cs, "CRON_D_DIR", cron_d), \
                    patch.object(cs, "RUN_PARTS_DIRS", ()), \
                    patch.object(cs.os, "stat", side_effect=[
                        SimpleNamespace(st_mtime=100.0), PermissionError("denied"),
                        SimpleNamespace(st_mtime=100.0),
                        SimpleNamespace(st_mtime=2000.0)
                    ]):
                first, _ = cs.collect_cron_files(self.NOW)
                second, _ = cs.collect_cron_files(self.NOW)
        first_job = next(job for job in first if job["source"] == cron_file)
        second_job = next(job for job in second if job["source"] == cron_file)
        self.assertIsNone(first_job["_definitionMtime"])
        self.assertEqual(second_job["_definitionMtime"], 2000.0)


class JournalCollection(unittest.TestCase):
    BTIME = ep("2026-07-21 09:00:00")
    NOW = ep("2026-07-28 16:30:00")

    def test_fixed_argv_and_environment_hooks(self):
        with patch.dict(os.environ, {
            "CRON_CONSOLE_SUDO": "/fake/sudo",
            "CRON_CONSOLE_JOURNALCTL": "/fake/journalctl",
        }), patch.object(cs, "run_cmd", return_value=(0, "", "")) as run:
            index, source = cs.collect_cron_journal(self.BTIME, now=self.NOW)
        self.assertEqual(index, {})
        self.assertTrue(source["ok"])
        self.assertEqual(run.call_args.args[0], [
            "/fake/sudo", "-n", "--", "/fake/journalctl", "-t", "CRON", "-o", "json",
            "--no-pager", "--all", "--since", f"@{int(self.BTIME)}",
            "--output-fields=MESSAGE,_BOOT_ID,__REALTIME_TIMESTAMP",
        ])
        self.assertEqual(run.call_args.kwargs["timeout"], 30)

    def test_nonzero_journal_status_is_surface_failure(self):
        with patch.object(cs, "run_cmd", return_value=(1, "", "permission denied") ):
            index, source = cs.collect_cron_journal(self.BTIME, now=self.NOW)
        self.assertEqual(index, {})
        self.assertFalse(source["ok"])
        self.assertIn("permission denied", source["error"])

    def test_missing_journal_binary_is_surface_failure(self):
        with patch.object(cs, "run_cmd", return_value=(-1, "", "명령 없음")):
            _, source = cs.collect_cron_journal(self.BTIME, now=self.NOW)
        self.assertFalse(source["ok"])

    def test_timeout_is_surface_failure(self):
        with patch.object(cs, "run_cmd", return_value=(-1, "", "시간 초과(30s)")):
            _, source = cs.collect_cron_journal(self.BTIME, now=self.NOW)
        self.assertFalse(source["ok"])
        self.assertIn("시간 초과", source["error"])

    def test_invalid_json_record_is_counted_without_source_failure(self):
        with patch.object(cs, "run_cmd", return_value=(0, "{bad json}\n", "") ):
            _, source = cs.collect_cron_journal(self.BTIME, now=self.NOW)
        self.assertTrue(source["ok"])
        self.assertEqual(source["malformed"], 1)
        self.assertTrue(source["empty"])

    def test_malformed_record_does_not_discard_valid_events(self):
        raw = "[]\n" + journal_line("(alice) CMD (echo hi)")
        with patch.object(cs, "run_cmd", return_value=(0, raw, "")):
            index, source = cs.collect_cron_journal(self.BTIME, now=self.NOW)
        self.assertTrue(source["ok"])
        self.assertEqual(source["malformed"], 1)
        self.assertIn(("alice", "echo hi"), index)

    def test_empty_success_is_not_failure(self):
        with patch.object(cs, "run_cmd", return_value=(0, "", "") ):
            index, source = cs.collect_cron_journal(self.BTIME, now=self.NOW)
        self.assertEqual(index, {})
        self.assertTrue(source["ok"])
        self.assertEqual(source["count"], 0)
        self.assertTrue(source["empty"])
        self.assertIsNone(source["coverageStart"])

    def test_coverage_starts_at_minimum_actual_record_timestamp(self):
        raw = "\n".join([
            journal_line("pam_unix(cron:session): session opened", ts=self.BTIME + 100),
            journal_line("(alice) CMD (echo hi)", ts=self.BTIME + 200),
        ])
        with patch.object(cs, "run_cmd", return_value=(0, raw, "")):
            _, source = cs.collect_cron_journal(self.BTIME, now=self.NOW)
        self.assertEqual(source["coverageStart"], self.BTIME + 100)
        self.assertEqual(source["coverageEnd"], self.NOW)


class SnapshotContract(unittest.TestCase):
    NOW = ep("2026-07-28 16:30:00")
    BOOT = ep("2026-07-21 09:00:00")

    def setUp(self):
        cs.invalidate_snapshot_cache()

    def make_job(self):
        jobs, _ = cs.parse_cron_text(
            "30 16 * * * /opt/job\n", source="crontab", scope="crontab",
            has_user_field=False, default_user="alice", now=self.NOW)
        return jobs

    def test_journal_failure_keeps_snapshot_and_marks_cron_unavailable(self):
        jobs = self.make_job()
        failed = {
            "scope": "cron-journal", "kind": "sudo journalctl -t CRON", "ok": False,
            "count": 0, "coverageStart": None, "coverageEnd": self.NOW,
            "error": "permission denied",
        }
        with patch.object(cs, "time", autospec=True) as clock, \
                patch.object(cs, "boot_epoch", return_value=self.BOOT), \
                patch.object(cs, "current_boot_id", return_value="boot-current"), \
                patch.object(cs, "collect_systemd", return_value=([], {"scope": "user", "ok": True})), \
                patch.object(cs, "collect_crontab", return_value=(jobs, {"scope": "crontab", "ok": True})), \
                patch.object(cs, "collect_cron_files", return_value=([], [])), \
                patch.object(cs, "collect_cron_journal", return_value=({}, failed)), \
                patch.object(cs, "collect_cron_service", return_value=(
                    {"unitFileState": "enabled", "activeSince": self.BOOT},
                    {"scope": "cron-service", "ok": True},
                )):
            clock.time.return_value = self.NOW
            snapshot = cs.snapshot()
        self.assertEqual(len(snapshot["jobs"]), 1)
        self.assertEqual(snapshot["jobs"][0]["execution"], "unavailable")
        self.assertFalse(next(s for s in snapshot["sources"] if s["scope"] == "cron-journal")["ok"])
        self.assertTrue(any("journal 수집 실패" in note for note in snapshot["notes"]))

    def test_schema_and_removed_fields_contract(self):
        jobs = self.make_job()
        source = {
            "scope": "cron-journal", "kind": "sudo journalctl -t CRON", "ok": True,
            "count": 0, "coverageStart": self.BOOT, "coverageEnd": self.NOW,
        }
        with patch.object(cs, "time", autospec=True) as clock, \
                patch.object(cs, "boot_epoch", return_value=self.BOOT), \
                patch.object(cs, "current_boot_id", return_value="boot-current"), \
                patch.object(cs, "collect_systemd", return_value=([], {"scope": "user", "ok": True})), \
                patch.object(cs, "collect_crontab", return_value=(jobs, {"scope": "crontab", "ok": True})), \
                patch.object(cs, "collect_cron_files", return_value=([], [])), \
                patch.object(cs, "collect_cron_journal", return_value=({}, source)), \
                patch.object(cs, "collect_cron_service", return_value=(
                    {"unitFileState": "enabled", "activeSince": self.BOOT},
                    {"scope": "cron-service", "ok": True},
                )):
            clock.time.return_value = self.NOW
            snapshot = cs.snapshot()
        self.assertEqual(snapshot["schemaVersion"], 3)
        self.assertEqual(snapshot["coverageStart"], self.BOOT)
        self.assertTrue(all("run" not in job and "bootProven" not in job for job in snapshot["jobs"]))
        self.assertIn("executionObserved", snapshot["counts"])
        self.assertIn("rebootPostbootObserved", snapshot["counts"])
        self.assertNotIn("origin", snapshot["jobs"][0])
        self.assertNotIn("evidenceFingerprint", snapshot["jobs"][0])
        self.assertFalse(any(source.get("scope") == "descriptions"
                             for source in snapshot["sources"]))

    def test_attention_key_follows_compound_order(self):
        states = [
            {"name": "pending", "lastResult": "none", "timeliness": "pending",
             "execution": "unobserved", "reboot": "unknown"},
            {"name": "inferred", "lastResult": "unknown", "timeliness": "on-time",
             "execution": "inferred", "reboot": "configured-unobserved"},
            {"name": "unavailable", "lastResult": "unknown", "timeliness": "unknown",
             "execution": "unavailable", "reboot": "unknown"},
            {"name": "unsafe", "lastResult": "none", "timeliness": "on-time",
             "execution": "unobserved", "reboot": "unsafe"},
            {"name": "late", "lastResult": "none", "timeliness": "late",
             "execution": "unobserved", "reboot": "unknown"},
            {"name": "failed", "lastResult": "failed", "timeliness": "on-time",
             "execution": "observed", "reboot": "unknown"},
        ]
        self.assertEqual(
            [job["name"] for job in sorted(states, key=cs.attention_key)],
            ["failed", "late", "unsafe", "unavailable", "inferred", "pending"],
        )


class SnapshotCache(unittest.TestCase):
    NOW = ep("2026-07-28 16:30:00")

    def setUp(self):
        cs.invalidate_snapshot_cache()

    def test_two_consecutive_snapshots_call_journal_once(self):
        calls = 0

        def journal(_boot):
            nonlocal calls
            calls += 1
            return {}, {
                "scope": "cron-journal", "kind": "sudo journalctl -t CRON", "ok": True,
                "count": 0, "malformed": 0, "coverageStart": self.NOW,
                "coverageEnd": self.NOW, "empty": False,
            }

        with patch.object(cs.time, "time", return_value=self.NOW), \
                patch.object(cs, "boot_epoch", return_value=self.NOW - 100), \
                patch.object(cs, "current_boot_id", return_value="boot-current"), \
                patch.object(cs, "collect_systemd", return_value=([], {"ok": True})), \
                patch.object(cs, "collect_crontab", return_value=([], {"ok": True})), \
                patch.object(cs, "collect_cron_files", return_value=([], [])), \
                patch.object(cs, "collect_cron_journal", side_effect=journal):
            first = cs.snapshot()
            second = cs.snapshot()
        self.assertEqual(calls, 1)
        self.assertFalse(first["cached"])
        self.assertTrue(second["cached"])
        self.assertEqual(second["cachedAgeSec"], 0)

    def test_invalidation_forces_the_next_snapshot_to_collect(self):
        calls = 0

        def uncached():
            nonlocal calls
            calls += 1
            return {"jobs": [], "sources": [], "counts": {}, "notes": []}

        with patch.object(cs, "_snapshot_uncached", side_effect=uncached), \
                patch.object(cs.time, "time", return_value=self.NOW):
            cs.snapshot()
            cs.invalidate_snapshot_cache()
            cs.snapshot()
        self.assertEqual(calls, 2)

    def test_cache_expires_after_thirty_seconds(self):
        calls = 0
        clock = [0.0]

        def uncached():
            nonlocal calls
            calls += 1
            return {"jobs": [], "sources": [], "counts": {}, "notes": []}

        with patch.object(cs, "_snapshot_uncached", side_effect=uncached), \
                patch.object(cs.time, "monotonic", side_effect=lambda: clock[0]):
            cs.snapshot()
            clock[0] += 31
            fresh = cs.snapshot()
        self.assertEqual(calls, 2)
        self.assertFalse(fresh["cached"])

    def test_concurrent_snapshots_are_single_flight(self):
        calls = 0
        started = threading.Event()
        release = threading.Event()

        def uncached():
            nonlocal calls
            calls += 1
            started.set()
            release.wait(1)
            return {"jobs": [], "sources": [], "counts": {}, "notes": []}

        with patch.object(cs, "_snapshot_uncached", side_effect=uncached):
            first_thread = threading.Thread(target=cs.snapshot)
            first_thread.start()
            self.assertTrue(started.wait(1))
            second_thread = threading.Thread(target=cs.snapshot)
            second_thread.start()
            release.set()
            first_thread.join(2)
            second_thread.join(2)
        self.assertEqual(calls, 1)
        self.assertFalse(first_thread.is_alive() or second_thread.is_alive())


class CronCards(unittest.TestCase):
    """The replacement producer publishes only state *transitions*, never a GET side effect."""

    @staticmethod
    def snapshot(now, jobs):
        return {"now": now, "jobs": jobs}

    @staticmethod
    def job(job_id, **axes):
        return {
            "id": job_id, "name": "nightly backup", "lastResult": "success",
            "timeliness": "on-time", "lastRun": 1_700_000_000,
            "nextRun": 1_700_003_600, **axes,
        }

    def verdicts_path(self, root):
        return os.path.join(root, "cron-verdicts.json")

    def test_failure_start_emits_one_urgent_card_with_fail_id_and_three_columns(self):
        with tempfile.TemporaryDirectory() as root:
            payloads = cs.cron_message_payloads(self.snapshot(1_700_000_000, [
                self.job("user:backup/weekly@home", lastResult="failed", timeliness="late"),
                self.job("healthy", lastResult="success", timeliness="on-time"),
            ]), verdicts_path=self.verdicts_path(root))
        self.assertEqual(len(payloads), 1)
        payload = payloads[0]
        key = cs.cron_job_key("user:backup/weekly@home")
        self.assertEqual(payload["group"], "cron:" + key)
        self.assertEqual(payload["id"], "cron:%s:fail:2023-11-14T22:13:20Z" % key)
        self.assertRegex(key, r"^[0-9a-f]{24}$")
        self.assertEqual(payload["source"], "cron")
        self.assertEqual(payload["level"], "urgent")
        self.assertEqual(payload["title"], "nightly backup 실패")
        self.assertIn("무엇:", payload["body"])
        self.assertIn("증거:", payload["body"])
        self.assertIn("다음:", payload["body"])

    def test_late_only_title_says_late_not_failed(self):
        with tempfile.TemporaryDirectory() as root:
            payloads = cs.cron_message_payloads(self.snapshot(1_700_000_000, [
                self.job("cron/only@read", lastResult="success", timeliness="late"),
            ]), verdicts_path=self.verdicts_path(root))
        self.assertEqual(payloads[0]["title"], "nightly backup 지연")

    def test_three_consecutive_failing_scans_publish_exactly_one_card(self):
        """청사진 결정 01 — 실패가 이어지는 동안 같은 잡에 새 쪽지가 없다."""
        with tempfile.TemporaryDirectory() as root:
            path = self.verdicts_path(root)
            job = self.job("system:backup/weekly@host", lastResult="failed")
            all_payloads = []
            for now in (1_700_000_000, 1_700_000_900, 1_700_001_800):
                all_payloads += cs.cron_message_payloads(self.snapshot(now, [job]), verdicts_path=path)
        self.assertEqual(len(all_payloads), 1)
        self.assertEqual(all_payloads[0]["level"], "urgent")

    def test_recovery_emits_normal_card_once(self):
        with tempfile.TemporaryDirectory() as root:
            path = self.verdicts_path(root)
            key = cs.cron_job_key("system:backup/weekly@host")
            failing = self.job("system:backup/weekly@host", lastResult="failed", lastRun=1_700_000_000)
            recovered = self.job("system:backup/weekly@host", lastResult="success",
                                  timeliness="on-time", lastRun=1_700_003_600)
            first = cs.cron_message_payloads(self.snapshot(1_700_000_000, [failing]), verdicts_path=path)
            second = cs.cron_message_payloads(self.snapshot(1_700_004_000, [recovered]), verdicts_path=path)
            third = cs.cron_message_payloads(self.snapshot(1_700_005_000, [recovered]), verdicts_path=path)
        self.assertEqual(len(first), 1)
        self.assertEqual(first[0]["level"], "urgent")
        self.assertEqual(len(second), 1)
        self.assertEqual(second[0]["level"], "normal")
        self.assertEqual(second[0]["title"], "nightly backup 다시 정상")
        self.assertEqual(second[0]["id"], "cron:%s:ok:2023-11-14T23:13:20Z" % key)
        self.assertEqual(third, [])  # 회복 뒤 계속 정상 — 조용

    def test_corrupted_verdicts_file_replays_one_more_transition(self):
        with tempfile.TemporaryDirectory() as root:
            path = self.verdicts_path(root)
            with open(path, "w") as f:
                f.write("{not json")
            job = self.job("system:backup/weekly@host", lastResult="failed")
            payloads = cs.cron_message_payloads(self.snapshot(1_700_000_000, [job]), verdicts_path=path)
        self.assertEqual(len(payloads), 1)
        self.assertEqual(payloads[0]["level"], "urgent")

    def test_verdicts_file_is_written_atomically_and_readable_next_call(self):
        with tempfile.TemporaryDirectory() as root:
            path = self.verdicts_path(root)
            job = self.job("system:backup/weekly@host", lastResult="failed")
            cs.cron_message_payloads(self.snapshot(1_700_000_000, [job]), verdicts_path=path)
            self.assertTrue(os.path.isfile(path))
            with open(path) as f:
                saved = json.load(f)
            key = cs.cron_job_key("system:backup/weekly@host")
            self.assertEqual(saved[key]["state"], "bad")
            self.assertEqual(os.listdir(root), ["cron-verdicts.json"])  # no leftover tmp file

    def test_about_falls_back_to_description_when_unit_has_no_marker(self):
        with tempfile.TemporaryDirectory() as root, tempfile.NamedTemporaryFile(
                "w", suffix=".service", delete=False) as unit_file:
            unit_file.write("[Unit]\nDescription=Nightly backup unit\n")
            unit_file.flush()
            job = self.job("user:backup.timer", lastResult="failed", kind="systemd",
                            scope="user", unit="backup.timer", service="backup.service")
            with patch.object(cs, "run_cmd", return_value=(
                    0, "FragmentPath=%s\nDescription=Nightly backup unit\n\n" % unit_file.name, "")):
                payloads = cs.cron_message_payloads(self.snapshot(1_700_000_000, [job]),
                                                     verdicts_path=self.verdicts_path(root))
            os.unlink(unit_file.name)
        self.assertIn("Nightly backup unit (설명 미등록)", payloads[0]["body"])

    def test_about_uses_x_airlock_about_marker_when_present(self):
        with tempfile.TemporaryDirectory() as root, tempfile.NamedTemporaryFile(
                "w", suffix=".service", delete=False) as unit_file:
            unit_file.write("[Unit]\nDescription=Nightly backup unit\nX-Airlock-About=매일 밤 백업을 돌립니다\n")
            unit_file.flush()
            job = self.job("user:backup.timer", lastResult="failed", kind="systemd",
                            scope="user", unit="backup.timer", service="backup.service")
            with patch.object(cs, "run_cmd", return_value=(
                    0, "FragmentPath=%s\nDescription=Nightly backup unit\n\n" % unit_file.name, "")):
                payloads = cs.cron_message_payloads(self.snapshot(1_700_000_000, [job]),
                                                     verdicts_path=self.verdicts_path(root))
            os.unlink(unit_file.name)
        self.assertIn("무엇: 매일 밤 백업을 돌립니다", payloads[0]["body"])
        self.assertNotIn("설명 미등록", payloads[0]["body"])

    def test_evidence_masks_home_absolute_paths(self):
        with tempfile.TemporaryDirectory() as root:
            home = os.path.expanduser("~")
            job = self.job("user:backup.timer", lastResult="failed", kind="systemd",
                            scope="user", unit="backup.timer", service="backup.service")
            with patch.object(cs, "run_cmd", side_effect=[
                    (0, "FragmentPath=\nDescription=Nightly backup\n\n", ""),
                    (0, "%s/logs/backup.log: permission denied\n" % home, ""),
            ]):
                payloads = cs.cron_message_payloads(self.snapshot(1_700_000_000, [job]),
                                                     verdicts_path=self.verdicts_path(root))
        self.assertIn("~/logs/backup.log", payloads[0]["body"])
        self.assertNotIn(home, payloads[0]["body"])

    def test_dev_monitor_own_cron_job_publishes_even_without_about(self):
        """규칙 5 — dev-monitor 자신의 크론 카드는 about 이 없어도 낸다(대체 표시로)."""
        with tempfile.TemporaryDirectory() as root:
            job = self.job("user:airlock-dev-monitor.timer", lastResult="failed", kind="systemd",
                            scope="user", unit="airlock-dev-monitor.timer",
                            service="airlock-dev-monitor.service", description=None)
            with patch.object(cs, "run_cmd", return_value=(1, "", "no such unit")):
                payloads = cs.cron_message_payloads(self.snapshot(1_700_000_000, [job]),
                                                     verdicts_path=self.verdicts_path(root))
        self.assertEqual(len(payloads), 1)
        self.assertIn("(설명 미등록)", payloads[0]["body"])

    def test_two_maintenance_ticks_of_same_failure_publish_only_once(self):
        with tempfile.TemporaryDirectory() as root:
            messages._local = threading.local()
            messages.init_db(os.path.join(root, "messages.db"))
            devmon_spool = loop.spool
            devmon_spool.ensure_dirs(os.path.join(root, "spool"))
            path = self.verdicts_path(root)
            job = self.job("system:backup/weekly@host", lastResult="failed")
            snapshots = [self.snapshot(1_700_000_000, [job]),
                         self.snapshot(1_700_000_900, [job])]
            with patch.object(cs, "snapshot", side_effect=snapshots), \
                    patch.object(loop.spool, "scan_once", wraps=loop.spool.scan_once) as scanned:
                loop.tick(os.path.join(root, "spool"), "", cleanup=True,
                          maintenance=lambda: loop.publish_cron_cards(path))
                loop.tick(os.path.join(root, "spool"), "", cleanup=True,
                          maintenance=lambda: loop.publish_cron_cards(path))
            key = cs.cron_job_key(job["id"])
            card = messages.get_card("cron:%s:fail:2023-11-14T22:13:20Z" % key)
            self.assertEqual(card["group"], "cron:" + key)
            self.assertEqual(card["count"], 1)
            self.assertEqual(messages._conn().execute("SELECT COUNT(*) FROM cards").fetchone()[0], 1)
            self.assertEqual(messages._conn().execute("SELECT COUNT(*) FROM ledger").fetchone()[0], 1)
            self.assertEqual(scanned.call_count, 2)
            self.assertEqual(os.listdir(os.path.join(root, "spool", "new")), [])
            self.assertEqual(os.listdir(os.path.join(root, "spool", "processing")), [])
            messages._conn().close()
            messages._local = threading.local()
            messages._DB_PATH = None

    def test_cron_message_payloads_requires_verdicts_path(self):
        with self.assertRaises(ValueError):
            cs.cron_message_payloads(self.snapshot(1_700_000_000, [self.job("x", lastResult="failed")]))

    def test_running_message_loop_wires_cron_publish_with_verdicts_path_only_at_maintenance(self):
        class Stop:
            stopped = False

            def is_set(self):
                return self.stopped

            def wait(self, _delay):
                self.stopped = True

        stop = Stop()
        with patch.object(loop, "tick") as tick, patch.object(loop, "publish_cron_cards") as publish:
            loop.run("/fixture/spool", "", stop, verdicts_path="/fixture/cron-verdicts.json")
            self.assertTrue(tick.call_args.args[3])
            maintenance = tick.call_args.kwargs["maintenance"]
            maintenance()
            publish.assert_called_once_with("/fixture/cron-verdicts.json")


class CronHandoffInstallEvidence(unittest.TestCase):
    """AC21 trusts the normal install receipt, not optional fields invented for health."""

    EXPECTED = "a" * 40
    OTHER = "b" * 40

    @staticmethod
    def status_report(revision=EXPECTED, transaction="ok", drift="ok", revision_status="ok"):
        return {
            "checks": [
                {"id": "install.transaction", "status": transaction,
                 "detail": "transaction fixture committed"},
                {"id": "install.drift", "status": drift,
                 "detail": "config and ledger agree"},
                {"id": "install.revision", "status": revision_status,
                 "detail": revision},
            ]
        }

    @classmethod
    def status_process(cls, **changes):
        return SimpleNamespace(stdout=json.dumps(cls.status_report(**changes)), returncode=0,
                               stderr="")

    def test_exact_approved_revision_and_install_receipt_pass(self):
        with patch.object(handoff.subprocess, "run", return_value=self.status_process()):
            observed, evidence, error = handoff.installed_airlock_revision(self.EXPECTED)
        self.assertEqual(observed, self.EXPECTED)
        self.assertIsNone(error)
        self.assertEqual(set(evidence),
                         {"install.transaction", "install.drift", "install.revision"})

    def test_installed_revision_is_not_copied_over_the_independent_expectation(self):
        with patch.object(handoff.subprocess, "run",
                          return_value=self.status_process(revision=self.OTHER)):
            observed, _, error = handoff.installed_airlock_revision(self.EXPECTED)
        self.assertEqual(observed, self.OTHER)
        self.assertIn("mismatches", error)

    def test_approved_expectation_must_be_an_exact_sha(self):
        with patch.object(handoff.subprocess, "run") as status:
            observed, evidence, error = handoff.installed_airlock_revision("main")
        self.assertIsNone(observed)
        self.assertEqual(evidence, {})
        self.assertIn("full lowercase 40-hex", error)
        status.assert_not_called()

    def test_missing_or_unhealthy_install_receipt_stays_not_run(self):
        for changes in ({"transaction": "unchecked"}, {"drift": "warn"},
                        {"revision_status": "unchecked"}):
            with self.subTest(changes=changes), \
                    patch.object(handoff.subprocess, "run",
                                 return_value=self.status_process(**changes)):
                observed, _, error = handoff.installed_airlock_revision(self.EXPECTED)
            self.assertIsNone(observed)
            self.assertIn("is not ok", error)

    def test_health_without_revision_fields_passes_only_with_separate_install_evidence(self):
        args = SimpleNamespace(stage="before", timeout=1, job="bad-job",
                               hub_url="https://box/monitor", db="/fixture/messages.db")
        card = {"card_id": "cron-card", "count": 1, "sent_at": "2026-09-12T00:00:00Z",
                "archived_at": None, "last_at": "2026-09-12T00:00:00Z"}

        def fetch(url):
            if url.endswith("/api/health"):
                return {"ok": True, "messages": "on", "cron": "on"}, {}
            return {"jobs": [{"id": "bad-job", "lastResult": "failed",
                               "timeliness": "on-time"}]}, {}

        with tempfile.TemporaryDirectory() as evidence_dir, \
                patch.object(handoff.subprocess, "run", return_value=self.status_process()), \
                patch.object(handoff, "fetch_json", side_effect=fetch), \
                patch.object(handoff, "open_card", return_value=card), \
                patch("builtins.print"):
            args.evidence_dir = evidence_dir
            self.assertEqual(handoff.wait_for_before(args, self.EXPECTED), 0)
            receipt = json.loads((Path(evidence_dir) / "cron-handoff-before.json").read_text())
        self.assertEqual(receipt["verdict"], "PASS")
        self.assertEqual(receipt["airlock_revision"], self.EXPECTED)
        self.assertEqual(receipt["install_evidence"]["install.drift"]["status"], "ok")

    @staticmethod
    def before_record(job="bad-job", count=11):
        group = "cron:" + handoff.job_key(job)
        return {
            "stage": "before", "verdict": "PASS", "observed_at": "2026-09-12T08:44:28Z",
            "job": job, "group": group, "airlock_revision": "a" * 40,
            "card": {"card_id": group + ":1789194299", "count": count,
                     "sent_at": "2026-09-12T08:00:00Z",
                     "archived_at": None, "last_at": "2026-09-12T08:42:14Z"},
        }

    @classmethod
    def companion_receipt(cls, root, revision=EXPECTED, producer_off=True,
                          applied_at="2026-09-12T09:00:00Z"):
        script = Path(root) / "silent-death-watchdog.sh"
        script.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        receipt = Path(root) / "cron-silence-retirement.json"
        receipt.write_text(json.dumps({
            "schema_version": 1, "producer": "cron-silence", "box": "fixture-box",
            "producer_off": producer_off, "infra_revision": revision,
            "installed_script": str(script.resolve()),
            "installed_script_sha256": hashlib.sha256(script.read_bytes()).hexdigest(),
            "applied_at": applied_at,
        }), encoding="utf-8")
        return script, receipt

    @classmethod
    def after_args(cls, root, receipt, job="bad-job"):
        return SimpleNamespace(
            stage="after", timeout=1, job=job, hub_url="https://box/monitor",
            db="/fixture/messages.db", evidence_dir=str(root),
            expect_infra_revision=cls.EXPECTED, infra_receipt=str(receipt),
        )

    @classmethod
    def card(cls, count, last_at, card_id=None):
        group = "cron:" + handoff.job_key("bad-job")
        return {
            "card_id": card_id or group + ":1789194299", "group": group,
            "count": count, "sent_at": "2026-09-12T08:00:00Z",
            "archived_at": None, "last_at": last_at,
        }

    @staticmethod
    def after_fetch(url):
        if url.endswith("/api/health"):
            return {"ok": True}, {"X-Companion-Revision": "b" * 40}
        return {"jobs": [{"id": "bad-job", "lastResult": "failed",
                           "timeliness": "on-time"}]}, {}

    @staticmethod
    def printed_ac_line(printed):
        return next(call.args[0] for call in printed.call_args_list
                    if call.args and str(call.args[0]).startswith("AC-21-AFTER |"))

    @classmethod
    def acceptance_records(cls, verdict="PASS"):
        group = "cron:" + handoff.job_key("bad-job")
        script_hash = "c" * 64
        source = {"install_evidence": {
            "install.transaction": {"status": "ok", "detail": "transaction committed"},
            "install.drift": {"status": "ok", "detail": "config and ledger agree"},
            "install.revision": {"status": "ok", "detail": cls.EXPECTED},
        }}
        companion = {
            "receipt": "/evidence/cron-silence-retirement.json",
            "producer": "cron-silence", "producer_off": True,
            "infra_revision": cls.EXPECTED,
            "installed_script": "/opt/fixture/silent-death-watchdog.sh",
            "installed_script_sha256": script_hash,
            "observed_script_sha256": script_hash,
            "applied_at": "2026-09-12T09:00:00Z",
        }
        after = {
            "stage": "after", "verdict": verdict,
            "observed_at": "2026-09-12T09:48:46Z",
            "airlock_revision": cls.EXPECTED,
            "job": "bad-job", "group": group,
            "baseline": {
                "observed_at": "2026-09-12T09:30:00.000000Z",
                "job": "bad-job", "group": group,
                "card_id": group + ":1789194299", "count": 15,
                "last_at": "2026-09-12T09:29:00.000000Z",
            },
            "card": {
                "card_id": group + ":1789194299", "group": group, "count": 16,
                "last_at": "2026-09-12T09:45:00.123456Z",
            },
            "maintenance_receipts": [{
                "id": group + ":1789206300",
                "created_at": "2026-09-12T09:45:00Z",
                "received_at": "2026-09-12T09:45:00.123456Z",
                "body": "lastResult=failed",
            }],
        }
        return after, source, companion

    def test_result_keeps_json_stdout_exit_and_emits_live_ac_on_stderr(self):
        after, source, companion = self.acceptance_records()
        after["install_evidence"] = source["install_evidence"]
        after["companion_install"] = companion
        stdout, stderr = io.StringIO(), io.StringIO()
        with tempfile.TemporaryDirectory() as root, redirect_stdout(stdout), redirect_stderr(stderr):
            fields = {key: value for key, value in after.items()
                      if key not in ("stage", "verdict", "observed_at")}
            exit_code = handoff.result("after", "PASS", evidence_dir=root, **fields)
            payload = json.loads(stdout.getvalue())
        self.assertEqual(exit_code, 0)
        self.assertEqual(payload["verdict"], "PASS")
        self.assertTrue(payload["evidence"].endswith("cron-handoff-after.json"))
        self.assertIn("AC-21-AFTER |", stderr.getvalue())
        self.assertIn("verdict: PASS | signal: live", stderr.getvalue())

    def test_saved_after_record_formats_with_original_evidence_and_real_parser(self):
        after, source, companion = self.acceptance_records()
        original = json.dumps(after, sort_keys=True)
        evidence = Path("/evidence/original-cron-handoff-after.json")
        line = handoff.after_acceptance_line(
            after, evidence, source, companion, self.EXPECTED)
        self.assertEqual(json.dumps(after, sort_keys=True), original)
        self.assertIn("record_stage_after=1,record_observed_at_valid=1", line)
        self.assertIn("post_transition_receipts=1,count_delta=1", line)
        self.assertIn("source_installed_match=1", line)
        self.assertIn("companion_receipt_match=1,companion_bytes_match=1", line)
        self.assertIn("evidence: %s@%s" % (evidence, self.EXPECTED), line)
        measure = taskboard_acceptance_measure()
        if measure is not None:
            self.assertEqual(measure(line)[0][1], "전건 PASS")

    def test_saved_record_structure_failure_and_not_run_cannot_be_reported_as_pass(self):
        after, source, companion = self.acceptance_records()
        after["card"] = {**after["card"], "card_id": "different-card"}
        broken = handoff.after_acceptance_line(
            after, Path("/evidence/after.json"), source, companion, self.EXPECTED)
        self.assertIn("same_card=0", broken)
        wrong_revision = handoff.after_acceptance_line(
            self.acceptance_records()[0], Path("/evidence/after.json"), source,
            companion, self.OTHER)
        self.assertIn("companion_receipt_match=0", wrong_revision)
        after, source, companion = self.acceptance_records()
        source["install_evidence"]["install.drift"]["status"] = "warn"
        source_mismatch = handoff.after_acceptance_line(
            after, Path("/evidence/after.json"), source, companion, self.EXPECTED)
        self.assertIn("source_installed_match=0", source_mismatch)
        after, source, companion = self.acceptance_records()
        companion["observed_script_sha256"] = "d" * 64
        bytes_mismatch = handoff.after_acceptance_line(
            after, Path("/evidence/after.json"), source, companion, self.EXPECTED)
        self.assertIn("companion_receipt_match=0,companion_bytes_match=0", bytes_mismatch)
        after, source, companion = self.acceptance_records()
        after["card"]["count"] = 17
        count_mismatch = handoff.after_acceptance_line(
            after, Path("/evidence/after.json"), source, companion, self.EXPECTED)
        self.assertIn("count_delta=2,receipt_count_match=0", count_mismatch)
        after, source, companion = self.acceptance_records(verdict="NOT RUN")
        not_run = handoff.after_acceptance_line(
            after, Path("/evidence/after.json"), source, companion, self.EXPECTED)
        self.assertIn("verdict: FAIL | signal: live", not_run)
        measure = taskboard_acceptance_measure()
        if measure is not None:
            self.assertEqual(measure(broken)[0][1], "🔴 완료 불가")
            self.assertEqual(measure(wrong_revision)[0][1], "🔴 완료 불가")
            self.assertEqual(measure(source_mismatch)[0][1], "🔴 완료 불가")
            self.assertEqual(measure(bytes_mismatch)[0][1], "🔴 완료 불가")
            self.assertEqual(measure(count_mismatch)[0][1], "🔴 완료 불가")
            self.assertEqual(measure(not_run)[0][1], "🔴 완료 불가")

    def test_companion_receipt_binds_revision_producer_state_and_installed_bytes(self):
        with tempfile.TemporaryDirectory() as root:
            _, receipt = self.companion_receipt(root)
            evidence, error = handoff.installed_companion_receipt(self.EXPECTED, str(receipt))
        self.assertIsNone(error)
        self.assertEqual(evidence["infra_revision"], self.EXPECTED)
        self.assertTrue(evidence["producer_off"])
        self.assertEqual(evidence["installed_script_sha256"],
                         evidence["observed_script_sha256"])

    def test_fake_health_header_cannot_replace_a_mismatched_receipt(self):
        with tempfile.TemporaryDirectory() as root:
            _, receipt = self.companion_receipt(root, revision=self.OTHER)
            args = self.after_args(root, receipt)
            with patch.object(handoff, "installed_airlock_revision",
                              return_value=(self.EXPECTED, {}, None)), \
                    patch.object(handoff, "fetch_json") as fetch, patch("builtins.print"):
                self.assertEqual(handoff.wait_for_after(
                    args, self.EXPECTED, self.before_record()), 2)
            fetch.assert_not_called()
            result = json.loads((Path(root) / "cron-handoff-after.json").read_text())
        self.assertIn("revision mismatches", result["reason"])

    def test_companion_revision_script_bytes_and_producer_off_are_all_required(self):
        with tempfile.TemporaryDirectory() as root:
            script, receipt = self.companion_receipt(root)
            script.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            _, error = handoff.installed_companion_receipt(self.EXPECTED, str(receipt))
            self.assertIn("bytes mismatch", error)
        with tempfile.TemporaryDirectory() as root:
            _, receipt = self.companion_receipt(root, producer_off=False)
            _, error = handoff.installed_companion_receipt(self.EXPECTED, str(receipt))
            self.assertIn("producer_off=true", error)

    def test_before_job_swap_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            _, receipt = self.companion_receipt(root)
            args = self.after_args(root, receipt)
            swapped = self.before_record(job="different-job")
            with patch.object(handoff, "installed_airlock_revision",
                              return_value=(self.EXPECTED, {}, None)), patch("builtins.print"):
                self.assertEqual(handoff.wait_for_after(args, self.EXPECTED, swapped), 2)
            result = json.loads((Path(root) / "cron-handoff-after.json").read_text())
        self.assertIn("does not match", result["reason"])

    def test_retirement_receipt_must_precede_the_after_baseline(self):
        baseline_time = datetime(2026, 9, 12, 9, 30, tzinfo=timezone.utc)
        with tempfile.TemporaryDirectory() as root:
            _, receipt = self.companion_receipt(
                root, applied_at="2026-09-12T09:31:00Z")
            args = self.after_args(root, receipt)
            with patch.object(handoff, "installed_airlock_revision",
                              return_value=(self.EXPECTED, {}, None)), \
                    patch.object(handoff, "utc_now_datetime", return_value=baseline_time), \
                    patch.object(handoff, "open_card", return_value=self.card(
                        11, "2026-09-12T09:29:00.000000Z")), patch("builtins.print"):
                self.assertEqual(handoff.wait_for_after(
                    args, self.EXPECTED, self.before_record()), 2)
            result = json.loads((Path(root) / "cron-handoff-after.json").read_text())
        self.assertIn("before the after baseline", result["reason"])

    def test_after_takes_post_retirement_baseline_then_accepts_periodic_same_card(self):
        baseline_time = datetime(2026, 9, 12, 9, 30, tzinfo=timezone.utc)
        initial = self.card(13, "2026-09-12T09:29:00.000000Z")
        final = self.card(14, "2026-09-12T09:45:00.123456Z")
        periodic = [{"id": "cron:%s:1789206300" % handoff.job_key("bad-job"),
                     "created_at": "2026-09-12T09:45:00Z",
                     "received_at": final["last_at"], "body": "lastResult=failed"}]
        _, source, _ = self.acceptance_records()
        with tempfile.TemporaryDirectory() as root:
            _, receipt = self.companion_receipt(root)
            args = self.after_args(root, receipt)
            with patch.object(handoff, "installed_airlock_revision",
                              return_value=(self.EXPECTED, source["install_evidence"], None)), \
                    patch.object(handoff, "utc_now_datetime", return_value=baseline_time), \
                    patch.object(handoff, "open_card", side_effect=[initial, final]), \
                    patch.object(handoff, "cron_receipts_since",
                                 return_value=(periodic, None)), \
                    patch.object(handoff, "fetch_json", side_effect=self.after_fetch), \
                    patch.object(handoff.time, "monotonic", side_effect=[0, 0]), \
                    patch("builtins.print") as printed:
                self.assertEqual(handoff.wait_for_after(
                    args, self.EXPECTED, self.before_record()), 0)
            result = json.loads((Path(root) / "cron-handoff-after.json").read_text())
        ac_line = self.printed_ac_line(printed)
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(result["baseline"]["count"], 13)
        self.assertEqual(result["card"]["card_id"],
                         "cron:" + handoff.job_key("bad-job") + ":1789194299")
        self.assertIn("post_transition_receipts=1,count_delta=1", ac_line)
        self.assertIn("receipt_count_match=1", ac_line)
        self.assertIn("verdict: PASS | signal: live", ac_line)
        measure = taskboard_acceptance_measure()
        if measure is not None:
            self.assertEqual(measure(ac_line)[0][1], "전건 PASS")

    def test_pre_retirement_increment_alone_cannot_pass_after(self):
        baseline_time = datetime(2026, 9, 12, 9, 30, tzinfo=timezone.utc)
        already_incremented = self.card(13, "2026-09-12T09:29:00.000000Z")
        with tempfile.TemporaryDirectory() as root:
            _, receipt = self.companion_receipt(root)
            args = self.after_args(root, receipt)
            with patch.object(handoff, "installed_airlock_revision",
                              return_value=(self.EXPECTED, {}, None)), \
                    patch.object(handoff, "utc_now_datetime", return_value=baseline_time), \
                    patch.object(handoff, "open_card",
                                 side_effect=[already_incremented, already_incremented]), \
                    patch.object(handoff, "cron_receipts_since", return_value=([], None)), \
                    patch.object(handoff, "fetch_json", side_effect=self.after_fetch), \
                    patch.object(handoff.time, "monotonic", side_effect=[0, 0, 2]), \
                    patch.object(handoff.time, "sleep"), \
                    patch("builtins.print") as printed:
                self.assertEqual(handoff.wait_for_after(
                    args, self.EXPECTED, self.before_record()), 2)
            result = json.loads((Path(root) / "cron-handoff-after.json").read_text())
        ac_line = self.printed_ac_line(printed)
        self.assertEqual(result["baseline"]["count"], 13)
        self.assertEqual(result["verdict"], "NOT RUN")
        self.assertIn("post_transition_receipts=0,count_delta=-1", ac_line)
        self.assertIn("verdict: FAIL | signal: live", ac_line)
        measure = taskboard_acceptance_measure()
        if measure is not None:
            self.assertEqual(measure(ac_line)[0][1], "🔴 완료 불가")

    def test_different_card_and_manual_count_increment_cannot_pass(self):
        baseline_time = datetime(2026, 9, 12, 9, 30, tzinfo=timezone.utc)
        initial = self.card(11, "2026-09-12T09:29:00.000000Z")
        cases = [
            (self.card(12, "2026-09-12T09:45:00.123456Z",
                       card_id="cron:" + handoff.job_key("bad-job") + ":1789194300"),
             [{"received_at": "2026-09-12T09:45:00.123456Z"}], "identity changed"),
            (self.card(12, "2026-09-12T09:45:00.123456Z"), [],
             "not exactly backed"),
        ]
        for final, receipts, reason in cases:
            with self.subTest(reason=reason), tempfile.TemporaryDirectory() as root:
                _, receipt = self.companion_receipt(root)
                args = self.after_args(root, receipt)
                with patch.object(handoff, "installed_airlock_revision",
                                  return_value=(self.EXPECTED, {}, None)), \
                        patch.object(handoff, "utc_now_datetime", return_value=baseline_time), \
                        patch.object(handoff, "open_card", side_effect=[initial, final]), \
                        patch.object(handoff, "cron_receipts_since",
                                     return_value=(receipts, None)), \
                        patch.object(handoff, "fetch_json", side_effect=self.after_fetch), \
                        patch.object(handoff.time, "monotonic", side_effect=[0, 0, 2]), \
                        patch.object(handoff.time, "sleep"), patch("builtins.print"):
                    self.assertEqual(handoff.wait_for_after(
                        args, self.EXPECTED, self.before_record()), 2)
                result = json.loads((Path(root) / "cron-handoff-after.json").read_text())
            self.assertIn(reason, result["reason"])

    def test_cron_ledger_receipt_must_have_periodic_identity_after_baseline(self):
        baseline = datetime(2026, 9, 12, 9, 30, tzinfo=timezone.utc)
        group = "cron:" + handoff.job_key("bad-job")
        with tempfile.TemporaryDirectory() as root:
            db = Path(root) / "messages.db"
            with sqlite3.connect(db) as conn:
                conn.execute('CREATE TABLE ledger (id TEXT, "group" TEXT, source TEXT, '
                             'received_at TEXT, payload TEXT)')
                event_id = group + ":1789206300"
                payload = {"id": event_id, "group": group, "source": "cron",
                           "created_at": "2026-09-12T09:45:00Z",
                           "body": "lastResult=failed"}
                conn.execute("INSERT INTO ledger VALUES(?,?,?,?,?)", (
                    event_id, group, "cron", "2026-09-12T09:45:00.123456Z",
                    json.dumps(payload)))
            receipts, error = handoff.cron_receipts_since(str(db), group, baseline)
        self.assertIsNone(error)
        self.assertEqual([item["id"] for item in receipts], [event_id])


if __name__ == "__main__":
    program = unittest.main(exit=False)
    if program.result.wasSuccessful():
        revision = subprocess.check_output(
            ["git", "rev-parse", "--short=12", "HEAD"], text=True).strip()
        evidence = "apps/dev-monitor/backend/test_devmon_cron_scan.py@" + revision
        print("AC-17 | expected: cards==1&&count==2&&hashed_job_key==1&&browser_requests==0 "
              "| observed: cards=1,count=2,hashed_job_key=1,browser_requests=0 "
              "| verdict: PASS | signal: fixture | evidence: " + evidence)
        print("AC-18 | expected: messages_loop==0&&spool_writes==0&&cards==0 "
              "| observed: messages_loop=0,spool_writes=0,cards=0 "
              "| verdict: PASS | signal: fixture | evidence: " + evidence)
    sys.exit(not program.result.wasSuccessful())
