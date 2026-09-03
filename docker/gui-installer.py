#!/usr/bin/env python3
"""Ubuntu GTK4/libadwaita front end for the pinned Airlock provisioner bundle."""

from __future__ import annotations

import socket
import subprocess
import sys
import threading
from pathlib import Path

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gui_installer_core import (  # noqa: E402
    ContractError,
    failure_copy,
    load_inputs,
    make_request,
    parse_event,
    picker_apps,
    reconcile_exit,
    write_all,
)


CONFIG = "/etc/airlock-gui-installer.json"
MAX_DETAILS = 200_000


class InstallerWindow(Adw.ApplicationWindow):
    def __init__(self, app: Adw.Application) -> None:
        super().__init__(application=app, title="Airlock 설치")
        self.set_default_size(720, 720)
        self.inputs = None
        self.switches: dict[str, Gtk.Switch] = {}
        self.process: subprocess.Popen[bytes] | None = None
        self.details_text = ""
        self.finished_url = ""
        self.terminal_event = ""
        self._io_lock = threading.Lock()
        self._stdout_done = False
        self._stderr_done = False
        self._returncode: int | None = None
        self._settle_scheduled = False
        self.connect("close-request", self._close_requested)

        toolbar = Adw.ToolbarView()
        toolbar.add_top_bar(Adw.HeaderBar())
        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE)
        toolbar.set_content(self.stack)
        self.set_content(toolbar)

        try:
            self.inputs = load_inputs(CONFIG)
            self._build_picker()
        except (OSError, ContractError) as exc:
            self._build_startup_failure(str(exc))

    def _page(self) -> tuple[Gtk.Box, Gtk.Box]:
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        scroll = Gtk.ScrolledWindow(vexpand=True, hscrollbar_policy=Gtk.PolicyType.NEVER)
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        body.set_margin_top(28)
        body.set_margin_bottom(28)
        body.set_margin_start(36)
        body.set_margin_end(36)
        scroll.set_child(body)
        outer.append(scroll)
        return outer, body

    def _title(self, body: Gtk.Box, title: str, subtitle: str) -> None:
        label = Gtk.Label(label=title, xalign=0)
        label.add_css_class("title-1")
        label.set_wrap(True)
        body.append(label)
        sub = Gtk.Label(label=subtitle, xalign=0)
        sub.add_css_class("dim-label")
        sub.set_wrap(True)
        body.append(sub)

    def _build_startup_failure(self, detail: str) -> None:
        outer, body = self._page()
        self._title(body, "설치 파일을 확인하지 못했습니다", "Airlock 설치 파일이 빠졌거나 서로 맞지 않습니다.")
        remedy = Gtk.Label(label="설치 USB를 다시 만든 뒤 이 아이콘을 다시 열어 주세요.", xalign=0)
        remedy.set_wrap(True)
        body.append(remedy)
        expander = Gtk.Expander(label="자세히")
        raw = Gtk.TextView(editable=False, monospace=True, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        raw.get_buffer().set_text(detail)
        expander.set_child(raw)
        body.append(expander)
        self.stack.add_named(outer, "startup-failure")
        self.stack.set_visible_child_name("startup-failure")

    def _build_picker(self) -> None:
        assert self.inputs is not None
        outer, body = self._page()
        self._title(
            body,
            "이 기기에 Airlock을 설치합니다",
            "필수 앱은 항상 설치됩니다. 더 필요한 앱만 골라 주세요.",
        )

        name_row = Adw.EntryRow(title="기기 이름")
        default_name = socket.gethostname().split(".", 1)[0].lower()
        safe_name = "".join(ch if ch.isalnum() or ch == "-" else "-" for ch in default_name).strip("-")
        name_row.set_text(safe_name[:63] or "airlock")
        body.append(name_row)
        self.name_row = name_row

        group = Adw.PreferencesGroup(title="설치할 앱")
        picker = picker_apps(self.inputs)
        hub_app = picker[0]
        hub = Adw.ActionRow(title=hub_app.label, subtitle=hub_app.subtitle)
        hub_switch = Gtk.Switch(active=True, sensitive=False, valign=Gtk.Align.CENTER)
        hub.add_suffix(hub_switch)
        group.add(hub)

        for app in picker[1:]:
            row = Adw.ActionRow(title=app.label, subtitle=app.subtitle)
            switch = Gtk.Switch(
                active=app.checked,
                sensitive=not app.locked,
                valign=Gtk.Align.CENTER,
            )
            row.add_suffix(switch)
            row.set_activatable_widget(switch)
            group.add(row)
            self.switches[app.app_id] = switch
        body.append(group)

        source = Gtk.Label(
            label=f"설치 묶음 {self.inputs.source_sha[:12]}", xalign=0
        )
        source.add_css_class("dim-label")
        body.append(source)

        self.validation = Gtk.Label(xalign=0)
        self.validation.add_css_class("error")
        self.validation.set_wrap(True)
        body.append(self.validation)
        start = Gtk.Button(label="설치 시작", halign=Gtk.Align.END)
        start.add_css_class("suggested-action")
        start.add_css_class("pill")
        start.connect("clicked", self._start)
        body.append(start)
        self.stack.add_named(outer, "picker")
        self.stack.set_visible_child_name("picker")

    def _build_progress(self) -> None:
        outer, body = self._page()
        self._title(body, "Airlock을 설치하고 있습니다", "이 창을 닫지 마세요. 설치에는 몇 분 걸릴 수 있습니다.")
        self.progress = Gtk.ProgressBar(show_text=True)
        self.progress.set_text("준비 중")
        body.append(self.progress)
        self.status = Gtk.Label(label="설치 파일을 확인하고 있습니다…", xalign=0)
        self.status.set_wrap(True)
        body.append(self.status)

        self.failure_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.failure_title = Gtk.Label(xalign=0)
        self.failure_title.add_css_class("title-3")
        self.failure_title.set_wrap(True)
        self.failure_remedy = Gtk.Label(xalign=0)
        self.failure_remedy.set_wrap(True)
        self.failure_box.append(self.failure_title)
        self.failure_box.append(self.failure_remedy)
        self.failure_box.set_visible(False)
        body.append(self.failure_box)

        self.details = Gtk.Expander(label="자세히")
        detail_scroll = Gtk.ScrolledWindow(min_content_height=180)
        self.detail_view = Gtk.TextView(editable=False, monospace=True, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        detail_scroll.set_child(self.detail_view)
        self.details.set_child(detail_scroll)
        body.append(self.details)

        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10, halign=Gtk.Align.END)
        self.retry = Gtk.Button(label="다시 시도")
        self.retry.connect("clicked", self._start)
        self.retry.set_visible(False)
        actions.append(self.retry)
        self.open_button = Gtk.Button(label="Airlock 열기")
        self.open_button.add_css_class("suggested-action")
        self.open_button.connect("clicked", self._open_url)
        self.open_button.set_visible(False)
        actions.append(self.open_button)
        self.copy_button = Gtk.Button(label="주소 복사")
        self.copy_button.connect("clicked", self._copy_url)
        self.copy_button.set_visible(False)
        actions.append(self.copy_button)
        body.append(actions)
        self.stack.add_named(outer, "progress")

    def _start(self, _button: Gtk.Button) -> None:
        assert self.inputs is not None
        if self.process and self.process.poll() is None:
            return
        selected = [app for app, switch in self.switches.items() if switch.get_active()]
        try:
            request = make_request(self.name_row.get_text(), selected, self.inputs)
        except ContractError as exc:
            self.validation.set_text(str(exc))
            self.stack.set_visible_child_name("picker")
            return
        self.validation.set_text("")
        if self.stack.get_child_by_name("progress") is None:
            self._build_progress()
        self.stack.set_visible_child_name("progress")
        self.details_text = ""
        self.detail_view.get_buffer().set_text("")
        self.failure_box.set_visible(False)
        self.retry.set_visible(False)
        self.open_button.set_visible(False)
        self.copy_button.set_visible(False)
        self.finished_url = ""
        self.terminal_event = ""
        with self._io_lock:
            self._stdout_done = False
            self._stderr_done = False
            self._returncode = None
            self._settle_scheduled = False
        self.progress.set_fraction(0.03)
        self.progress.set_text("권한 확인 중")
        self.status.set_text("관리자 권한을 확인하고 있습니다…")

        try:
            self.process = subprocess.Popen(
                ["pkexec", str(self.inputs.helper)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        except OSError as exc:
            self._show_failure("launcher-failed", "설치 작업을 시작하지 못했습니다.", str(exc))
            return
        assert self.process.stdin and self.process.stdout and self.process.stderr
        threading.Thread(target=write_all, args=(self.process.stdin, request), daemon=True).start()
        threading.Thread(target=self._read_stdout, args=(self.process.stdout,), daemon=True).start()
        threading.Thread(target=self._read_stderr, args=(self.process.stderr,), daemon=True).start()
        threading.Thread(target=self._wait_process, daemon=True).start()

    def _read_stdout(self, stream) -> None:
        for raw in iter(stream.readline, b""):
            line = raw.decode("utf-8", "replace").rstrip("\n")
            event = parse_event(line)
            if event is None:
                GLib.idle_add(self._append_detail, "[stdout] " + line + "\n")
            else:
                GLib.idle_add(self._handle_event, event)
        self._mark_complete("stdout")

    def _read_stderr(self, stream) -> None:
        for raw in iter(stream.readline, b""):
            line = raw.decode("utf-8", "replace")
            GLib.idle_add(self._append_detail, line)
        self._mark_complete("stderr")

    def _append_detail(self, text: str) -> bool:
        self.details_text = (self.details_text + text)[-MAX_DETAILS:]
        self.detail_view.get_buffer().set_text(self.details_text)
        return False

    def _handle_event(self, event: dict) -> bool:
        name = event["event"]
        labels = {
            "start": (0.08, "설치 대상 확인 중"),
            "target-verified": (0.14, "Ubuntu 확인 완료"),
            "version-relation": (0.22, "설치 묶음 버전 확인 완료"),
            "bundle-verified": (0.30, "설치 파일 확인 완료"),
            "account-ready": (0.42, "Airlock 사용자 준비 완료"),
            "prerequisites-ready": (0.56, "기본 프로그램 준비 완료"),
            "tailnet-ready": (0.68, "Tailscale 연결 완료"),
            "installer-start": (0.74, "선택한 앱 설치 중"),
        }
        if name in labels:
            fraction, text = labels[name]
            self.progress.set_fraction(fraction)
            self.progress.set_text(text)
            self.status.set_text(text + "…")
        elif name == "needs-auth":
            self.terminal_event = "needs-auth"
            url = str(event.get("value") or event.get("login_url") or "")
            self.finished_url = url
            self._show_failure(
                "tailscale-login",
                "Tailscale 로그인이 필요합니다.",
                "로그인 페이지에서 승인한 뒤 다시 시도해 주세요.",
                retry=True,
                action_url=url,
                action_label="로그인 열기",
            )
        elif name == "failed":
            self.terminal_event = "failed"
            code, message, remedy = failure_copy(event)
            if event.get("log"):
                remedy += "\n설치 기록: " + str(event["log"])
            self._show_failure(code, message, remedy, retry=bool(event.get("retry", True)))
        elif name == "finished":
            self.terminal_event = "finished"
            self.finished_url = str(event.get("value") or event.get("url") or "")
            self.progress.set_fraction(0.98)
            self.progress.set_text("마무리 확인 중")
            self.status.set_text("설치 결과를 확인하고 있습니다…")
        return False

    def _wait_process(self) -> None:
        assert self.process is not None
        rc = self.process.wait()
        with self._io_lock:
            self._returncode = rc
        self._mark_complete("process")

    def _mark_complete(self, source: str) -> None:
        with self._io_lock:
            if source == "stdout":
                self._stdout_done = True
            elif source == "stderr":
                self._stderr_done = True
            if (
                self._stdout_done
                and self._stderr_done
                and self._returncode is not None
                and not self._settle_scheduled
            ):
                self._settle_scheduled = True
                GLib.idle_add(self._process_finished, self._returncode)

    def _process_finished(self, rc: int) -> bool:
        outcome, code, message = reconcile_exit(rc, self.terminal_event, self.finished_url)
        if outcome == "success":
            self.progress.set_fraction(1.0)
            self.progress.set_text("설치 완료")
            self.status.set_text("Airlock을 사용할 준비가 됐습니다.")
            self.open_button.set_label("Airlock 열기")
            self.open_button.set_visible(True)
            self.copy_button.set_visible(True)
        elif outcome == "failure" and not self.failure_box.get_visible():
            remedy = "암호 입력 창을 취소했다면 다시 시도해 주세요." if code == "privilege-cancelled" else "자세히에서 기록을 확인한 뒤 다시 시도해 주세요."
            self._show_failure(
                code,
                message,
                remedy,
            )
        return False

    def _close_requested(self, _window) -> bool:
        if self.process and self.process.poll() is None:
            self.status.set_text("설치가 진행 중입니다. 끝난 뒤 창을 닫아 주세요.")
            return True
        return False

    def _show_failure(
        self,
        code: str,
        message: str,
        remedy: str,
        retry: bool = True,
        action_url: str = "",
        action_label: str = "",
    ) -> None:
        self.progress.set_text("설치 중단")
        self.status.set_text(message)
        self.failure_title.set_text(message)
        self.failure_remedy.set_text(remedy + f"\n오류 코드: {code}")
        self.failure_box.set_visible(True)
        self.details.set_expanded(True)
        self.retry.set_visible(retry)
        if action_url.startswith("https://"):
            self.open_button.set_label(action_label or "페이지 열기")
            self.open_button.set_visible(True)

    def _open_url(self, _button: Gtk.Button) -> None:
        if self.finished_url.startswith("https://"):
            Gio.AppInfo.launch_default_for_uri(self.finished_url, None)

    def _copy_url(self, _button: Gtk.Button) -> None:
        if self.finished_url:
            self.get_clipboard().set(self.finished_url)


class InstallerApp(Adw.Application):
    def __init__(self) -> None:
        super().__init__(application_id="org.airlock.Installer")

    def do_activate(self) -> None:
        window = self.get_active_window() or InstallerWindow(self)
        window.present()


def main() -> int:
    app = InstallerApp()
    return app.run(sys.argv)


if __name__ == "__main__":
    raise SystemExit(main())
