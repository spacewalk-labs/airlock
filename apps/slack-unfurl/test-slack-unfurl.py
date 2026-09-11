#!/usr/bin/env python3
"""Offline, self-contained tests for the Slack unfurl worker."""

from __future__ import annotations

import base64
import importlib.util
import io
import json
import os
import pathlib
import queue
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import tomllib
import unittest
from unittest import mock


APP_DIR = pathlib.Path(__file__).resolve().parent
BACKEND = APP_DIR / "backend"
sys.dont_write_bytecode = True
sys.path.insert(0, str(BACKEND))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


socket_mode = load("socket_mode", BACKEND / "socket_mode.py")
unfurl = load("slack_unfurl", BACKEND / "slack_unfurl.py")

DOMAIN = "example.test"


class URLTests(unittest.TestCase):
    def test_hub_publish_path(self):
        parsed = unfurl.parse_publish_url(
            "https://writer.example.test/publish/files/quarterly-report.html", DOMAIN
        )
        self.assertEqual((parsed.box, parsed.fqdn, parsed.name), (
            "writer", "writer.example.test", "quarterly-report.html"
        ))

    def test_dedicated_port_root_path(self):
        parsed = unfurl.parse_publish_url(
            "https://writer.example.test:8000/quarterly-report.html", DOMAIN
        )
        self.assertEqual(parsed.name, "quarterly-report.html")

    def test_unconfigured_ports_are_not_documents(self):
        self.assertIsNone(unfurl.parse_publish_url(
            "https://writer.example.test:22/publish/files/report.html", DOMAIN
        ))
        self.assertIsNone(unfurl.parse_publish_url(
            "https://writer.example.test:1/report.html", DOMAIN
        ))
        parsed = unfurl.parse_publish_url(
            "https://writer.example.test:8443/report.html", DOMAIN, "8443"
        )
        self.assertEqual(parsed.name, "report.html")

    def test_normalized_runtime_port_set_is_reusable(self):
        ports = unfurl.parse_dedicated_ports("8000,19920")
        hub = unfurl.parse_publish_url(
            "https://writer.example.test/publish/files/report.html", DOMAIN, ports
        )
        dedicated = unfurl.parse_publish_url(
            "https://writer.example.test:8000/report.html", DOMAIN, ports
        )
        self.assertEqual((hub.name, dedicated.name), ("report.html", "report.html"))
        with self.assertRaises(ValueError):
            unfurl.parse_dedicated_ports("8000, 19920")

    def test_hub_root_fallback_is_not_a_document(self):
        self.assertIsNone(unfurl.parse_publish_url(
            "https://writer.example.test/quarterly-report.html", DOMAIN
        ))
        self.assertIsNone(unfurl.parse_publish_url(
            "https://writer.example.test:443/quarterly-report.html", DOMAIN
        ))

    def test_wrong_domain_and_traversal_are_rejected(self):
        self.assertIsNone(unfurl.parse_publish_url(
            "https://writer.public.example/publish/files/report.html", DOMAIN
        ))
        for path in ("../secret.html", "%2e%2e%2fsecret.html", "folder%2fsecret.html"):
            self.assertIsNone(unfurl.parse_publish_url(
                "https://writer.example.test/publish/files/" + path, DOMAIN
            ))

    def test_config_identifiers_reject_trailing_newlines(self):
        with self.assertRaises(ValueError):
            unfurl.normalize_domain_suffix("example.test\n")
        with self.assertRaises(ValueError):
            unfurl.validate_env_name("SLACK_TOKEN\n", "bot_token_env")


class MetadataAndCardTests(unittest.TestCase):
    def test_title_metadata_and_card_shape(self):
        meta = unfurl.parse_title_meta(
            {"name": "report.html", "title": "Q3 <review>", "mtime": 1788825600},
            "report.html",
        )
        target = unfurl.parse_publish_url(
            "https://writer.example.test/publish/files/report.html", DOMAIN
        )
        card = unfurl.build_unfurl(target, meta)
        self.assertEqual([block["type"] for block in card["blocks"]], ["section", "context"])
        self.assertIn("Q3 &lt;review&gt;", card["blocks"][0]["text"]["text"])
        context = card["blocks"][1]["elements"][0]["text"]
        self.assertIn("발행 박스", context)
        self.assertIn("writer", context)
        self.assertRegex(context, r"발행일:\* \d{4}-\d{2}-\d{2}")

    def test_mismatched_name_and_invalid_title_fail_closed(self):
        with self.assertRaises(unfurl.MetadataError):
            unfurl.parse_title_meta({"name": "other.html", "title": "x", "mtime": 1}, "report.html")
        with self.assertRaises(unfurl.MetadataError):
            unfurl.parse_title_meta({"name": "report.html", "title": "", "mtime": 1}, "report.html")

    def test_title_lookup_targets_hub_meta_endpoint(self):
        seen = {}

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self, _limit):
                return json.dumps({
                    "name": "space name.html", "title": "A title", "mtime": "2026-09-08T12:30:00Z"
                }).encode()

            def geturl(self):
                return seen["url"]

        def opener(request, timeout):
            seen["url"] = request.full_url
            seen["timeout"] = timeout
            return Response()

        target = unfurl.PublishedLink(
            "https://writer.example.test:8443/space%20name.html",
            "writer.example.test",
            "writer",
            "space name.html",
        )
        meta = unfurl.fetch_title_meta(target, opener=opener)
        self.assertEqual(
            seen["url"],
            "https://writer.example.test/publish/api/meta?name=space+name.html",
        )
        self.assertEqual(meta.published_date, "2026-09-08")

    def test_title_lookup_rejects_redirected_response(self):
        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def geturl(self):
                return "http://outside.example/private"

            def read(self, _limit):
                return json.dumps({
                    "name": "report.html", "title": "Wrong source", "mtime": 1,
                }).encode()

        target = unfurl.parse_publish_url(
            "https://writer.example.test/publish/files/report.html", DOMAIN
        )
        with self.assertRaisesRegex(unfurl.MetadataError, "redirected"):
            unfurl.fetch_title_meta(target, opener=lambda _request, timeout: Response())

    def test_lookup_failure_omits_only_failed_card_and_batches_once(self):
        sent = []
        logs = []

        def fetch(target):
            if target.name == "missing.html":
                raise unfurl.MetadataError("HTTP 404")
            return unfurl.TitleMeta(target.name, "Good title", "2026-09-08")

        event = {
            "channel": "C123",
            "message_ts": "123.456",
            "links": [
                {"url": "https://writer.example.test/publish/files/good.html"},
                {"url": "https://writer.example.test/publish/files/missing.html"},
                {"url": "https://writer.example.test/hub.html"},
            ],
        }
        cache = unfurl.DedupeCache()
        count = unfurl.process_link_shared(
            event,
            DOMAIN,
            unfurl.DEFAULT_DEDICATED_PORTS,
            fetch,
            lambda *args: sent.append(args),
            cache,
            log=logs.append,
        )
        self.assertEqual(count, 1)
        self.assertEqual(len(sent), 1)
        self.assertEqual(list(sent[0][2]), [event["links"][0]["url"]])
        self.assertEqual(len(logs), 1)
        self.assertIn("missing.html", logs[0])
        self.assertEqual(
            unfurl.process_link_shared(
                event,
                DOMAIN,
                unfurl.DEFAULT_DEDICATED_PORTS,
                fetch,
                lambda *args: sent.append(args),
                cache,
            ),
            0,
        )
        self.assertEqual(len(sent), 1, "same channel/message must not unfurl twice")

    def test_all_lookup_failures_make_no_chat_call(self):
        sent = []
        event = {
            "channel": "C123",
            "message_ts": "789.012",
            "links": [{"url": "https://writer.example.test/publish/files/missing.html"}],
        }
        count = unfurl.process_link_shared(
            event,
            DOMAIN,
            unfurl.DEFAULT_DEDICATED_PORTS,
            lambda _target: (_ for _ in ()).throw(unfurl.MetadataError("HTTP 403")),
            lambda *args: sent.append(args),
            unfurl.DedupeCache(),
            log=lambda _message: None,
        )
        self.assertEqual(count, 0)
        self.assertEqual(sent, [])

    def test_acknowledged_event_is_drained_after_sigterm(self):
        stop = threading.Event()
        fetched = []
        sent = []
        event = {
            "channel": "C123",
            "message_ts": "stop.1",
            "links": [
                {"url": "https://writer.example.test/publish/files/one.html"},
                {"url": "https://writer.example.test/publish/files/two.html"},
            ],
        }

        def fetch(target):
            fetched.append(target.name)
            stop.set()
            return unfurl.TitleMeta(target.name, target.name, "2026-09-08")

        count = unfurl.process_link_shared(
            event,
            DOMAIN,
            unfurl.DEFAULT_DEDICATED_PORTS,
            fetch,
            lambda *args: sent.append(args),
            unfurl.DedupeCache(),
            stop_event=stop,
        )
        self.assertEqual((count, fetched, len(sent)), (2, ["one.html", "two.html"], 1))

    def test_queue_worker_drains_owned_event_after_global_stop(self):
        work = queue.Queue(maxsize=unfurl.WORK_QUEUE_MAX)
        sent = []
        event = {
            "channel": "C123", "message_ts": "drain.1",
            "links": [{"url": "https://writer.example.test/publish/files/one.html"}],
        }
        with mock.patch.object(
            unfurl, "fetch_title_meta",
            side_effect=lambda target: unfurl.TitleMeta(target.name, "Title", "2026-09-08"),
        ), mock.patch.object(
            unfurl, "_send_unfurls_with_retry", side_effect=lambda *args: sent.append(args)
        ):
            unfurl.STOP_EVENT.set()
            worker = threading.Thread(
                target=unfurl._process_event_queue,
                args=(work, DOMAIN, unfurl.DEFAULT_DEDICATED_PORTS, "token", unfurl.DedupeCache()),
            )
            worker.start()
            ready = threading.Event()
            ready.set()
            work.put(unfurl.QueuedEvent(event, ready, acknowledged=True))
            work.put(unfurl.QUEUE_STOP)
            worker.join(timeout=2)
            unfurl.STOP_EVENT.clear()
        self.assertFalse(worker.is_alive())
        self.assertEqual(len(sent), 1)

    def test_overlong_card_skips_only_that_link(self):
        sent = []
        logs = []
        long_url = "https://writer.example.test/publish/files/long.html?" + "한" * 1200
        good_url = "https://writer.example.test/publish/files/good.html"
        event = {
            "channel": "C123", "message_ts": "long.1",
            "links": [{"url": long_url}, {"url": good_url}],
        }
        count = unfurl.process_link_shared(
            event, DOMAIN, unfurl.DEFAULT_DEDICATED_PORTS,
            lambda target: unfurl.TitleMeta(target.name, "Title", "2026-09-08"),
            lambda *args: sent.append(args), unfurl.DedupeCache(), log=logs.append,
        )
        self.assertEqual((count, list(sent[0][2])), (1, [good_url]))
        self.assertEqual(len(logs), 1)

    def test_chat_unfurl_retries_transient_failures(self):
        calls = []
        waits = []

        def sender(*args):
            calls.append(args)
            if len(calls) < 3:
                raise socket_mode.SlackAPIError(
                    "temporary", transient=True, retry_after=40 if len(calls) == 1 else None
                )
            return {"ok": True}

        result = unfurl._send_unfurls_with_retry(
            "token", "C1", "1", {"url": {}}, sender=sender, sleeper=waits.append
        )
        self.assertEqual(result, {"ok": True})
        self.assertEqual((len(calls), waits), (3, [40, 2.0]))

    def test_chat_unfurl_does_not_retry_permanent_failure(self):
        calls = []

        def sender(*args):
            calls.append(args)
            raise socket_mode.SlackAPIError("invalid_auth")

        with self.assertRaises(socket_mode.SlackAPIError):
            unfurl._send_unfurls_with_retry(
                "token", "C1", "1", {"url": {}}, sender=sender,
                sleeper=lambda _delay: self.fail("permanent error was retried"),
            )
        self.assertEqual(len(calls), 1)


class EnvelopeTests(unittest.TestCase):
    def test_hello_and_disconnect_do_not_reset_reconnect_backoff(self):
        self.assertFalse(unfurl._resets_reconnect_backoff({"type": "hello"}))
        self.assertFalse(unfurl._resets_reconnect_backoff({"type": "disconnect"}))
        self.assertTrue(unfurl._resets_reconnect_backoff({"type": "events_api"}))

    def test_envelope_is_owned_and_acked_before_link_work_runs(self):
        order = []

        class Connection:
            def send_json(self, value):
                order.append(("ack", value))

        class RecordingQueue(queue.Queue):
            def put_nowait(self, value):
                order.append(("queue", value))
                super().put_nowait(value)

        event = {"type": "link_shared", "channel": "C1", "message_ts": "1", "links": []}
        work = RecordingQueue()
        keep_open = unfurl.acknowledge_and_enqueue(
            {"envelope_id": "E1", "type": "events_api", "payload": {"event": event}},
            Connection(),
            work,
        )
        self.assertTrue(keep_open)
        self.assertEqual(order[0][0], "queue")
        self.assertIsInstance(order[0][1], unfurl.QueuedEvent)
        self.assertEqual(order[0][1].event, event)
        self.assertEqual(order[1], ("ack", {"envelope_id": "E1"}))

    def test_queue_consumer_cannot_run_before_ack_completes(self):
        dequeued = threading.Event()
        ack_started = threading.Event()
        release_ack = threading.Event()
        processed = []

        class ObservedQueue(queue.Queue):
            def get(self, *args, **kwargs):
                item = super().get(*args, **kwargs)
                if item is not unfurl.QUEUE_STOP:
                    dequeued.set()
                return item

        class BlockingConnection:
            def send_json(self, _value):
                ack_started.set()
                self.assert_released = release_ack.wait(2)

        event = {"type": "link_shared", "channel": "C1", "message_ts": "1", "links": []}
        work = ObservedQueue(maxsize=unfurl.WORK_QUEUE_MAX)
        with mock.patch.object(
            unfurl, "process_link_shared", side_effect=lambda *args: processed.append(args)
        ):
            worker = threading.Thread(
                target=unfurl._process_event_queue,
                args=(work, DOMAIN, unfurl.DEFAULT_DEDICATED_PORTS, "token", unfurl.DedupeCache()),
            )
            worker.start()
            producer = threading.Thread(
                target=unfurl.acknowledge_and_enqueue,
                args=(
                    {"envelope_id": "E-race", "type": "events_api", "payload": {"event": event}},
                    BlockingConnection(), work,
                ),
            )
            producer.start()
            self.assertTrue(ack_started.wait(2))
            self.assertTrue(dequeued.wait(2))
            self.assertEqual(processed, [])
            release_ack.set()
            producer.join(2)
            work.join()
            work.put(unfurl.QUEUE_STOP)
            worker.join(2)
        self.assertFalse(producer.is_alive())
        self.assertFalse(worker.is_alive())
        self.assertEqual(len(processed), 1)

    def test_failed_ack_discards_reserved_event(self):
        processed = []

        class FailedConnection:
            def send_json(self, _value):
                raise OSError("connection closed")

        event = {"type": "link_shared", "channel": "C1", "message_ts": "1", "links": []}
        work = queue.Queue(maxsize=unfurl.WORK_QUEUE_MAX)
        with mock.patch.object(
            unfurl, "process_link_shared", side_effect=lambda *args: processed.append(args)
        ):
            worker = threading.Thread(
                target=unfurl._process_event_queue,
                args=(work, DOMAIN, unfurl.DEFAULT_DEDICATED_PORTS, "token", unfurl.DedupeCache()),
            )
            worker.start()
            with self.assertRaises(OSError):
                unfurl.acknowledge_and_enqueue(
                    {"envelope_id": "E-fail", "type": "events_api", "payload": {"event": event}},
                    FailedConnection(), work,
                )
            work.join()
            work.put(unfurl.QUEUE_STOP)
            worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(processed, [])

    def test_connections_open_retry_after_is_not_shortened_or_jittered(self):
        exc = socket_mode.SlackAPIError("ratelimited", transient=True, retry_after=40)
        self.assertEqual(
            unfurl._connection_retry_delay(
                exc, 1.0, jitter=lambda *_args: self.fail("Retry-After was jittered")
            ),
            40,
        )

    def test_invalid_retry_after_falls_back_to_bounded_backoff(self):
        for retry_after in (None, float("inf"), -1):
            exc = socket_mode.SlackAPIError(
                "ratelimited", transient=True, retry_after=retry_after
            )
            self.assertEqual(
                unfurl._connection_retry_delay(exc, 5.0, jitter=lambda _a, _b: 1.0),
                5.0,
            )

    def test_full_queue_is_not_acked_and_forces_reconnect(self):
        sent = []
        logs = []

        class Connection:
            def send_json(self, value):
                sent.append(value)

        work = queue.Queue(maxsize=1)
        work.put({"occupied": True})
        event = {"type": "link_shared", "channel": "C1", "message_ts": "1", "links": []}
        keep_open = unfurl.acknowledge_and_enqueue(
            {"envelope_id": "E-full", "type": "events_api", "payload": {"event": event}},
            Connection(), work, log=logs.append,
        )
        self.assertFalse(keep_open)
        self.assertEqual(sent, [])
        self.assertIn("not acknowledged", logs[0])

    def test_disconnect_is_acked_and_not_requeued(self):
        sent = []

        class Connection:
            def send_json(self, value):
                sent.append(value)

        work = queue.Queue()
        self.assertFalse(unfurl.acknowledge_and_enqueue(
            {"envelope_id": "E2", "type": "disconnect"}, Connection(), work
        ))
        self.assertEqual(sent, [{"envelope_id": "E2"}])
        self.assertTrue(work.empty())


class WebSocketFrameTests(unittest.TestCase):
    def test_masked_text_frame_round_trip_for_all_length_encodings(self):
        for payload in (b"hello", b"x" * 126, b"y" * 70000):
            frame = socket_mode.encode_frame(payload, mask_key=b"mask")
            fin, opcode, decoded = socket_mode.decode_frame(frame, expect_masked=True)
            self.assertTrue(fin)
            self.assertEqual(opcode, 0x1)
            self.assertEqual(decoded, payload)

    def test_server_frame_is_unmasked(self):
        frame = socket_mode.encode_frame("hello", masked=False)
        self.assertEqual(socket_mode.read_frame(io.BytesIO(frame), expect_masked=False)[2], b"hello")

    def test_invalid_control_frame_is_rejected(self):
        with self.assertRaises(ValueError):
            socket_mode.encode_frame(b"x" * 126, opcode=0x9)

    def test_nonminimal_payload_lengths_are_rejected(self):
        with self.assertRaises(socket_mode.WebSocketProtocolError):
            socket_mode.decode_frame(b"\x81\x7e\x00\x01x", expect_masked=False)
        with self.assertRaises(socket_mode.WebSocketProtocolError):
            socket_mode.decode_frame(
                b"\x81\x7f" + struct.pack("!Q", 65535) + b"x" * 65535,
                expect_masked=False,
            )

    def test_idle_socket_forces_reconnect(self):
        class TimedOutSocket:
            def recv(self, _size):
                raise socket.timeout()

        clock_values = iter((0.0, 61.0))
        stream = socket_mode._SocketStream(
            TimedOutSocket(), idle_timeout=60, clock=lambda: next(clock_values)
        )
        with self.assertRaisesRegex(socket_mode.WebSocketIdleTimeout, "idle deadline"):
            socket_mode.read_frame(stream, expect_masked=False)

    def test_handshake_rejects_unrequested_options_and_bad_http(self):
        # RFC 6455's public example nonce, derived so generic secret scanners do
        # not mistake a known test vector for a committed API key.
        key = base64.b64encode(b"the sample nonce").decode("ascii")
        base = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
        socket_mode._validate_handshake_response(base.encode(), key)
        for invalid in (
            base.replace("HTTP/1.1", "HTTP/1.0"),
            base + "\r\nSec-WebSocket-Extensions: permessage-deflate",
            base + "\r\nSec-WebSocket-Protocol: unexpected",
            base + "\r\nUpgrade: websocket",
        ):
            with self.assertRaises(socket_mode.WebSocketProtocolError):
                socket_mode._validate_handshake_response(invalid.encode(), key)

    def test_fragmented_text_and_ping_pong(self):
        incoming = b"".join((
            socket_mode.encode_frame(b"rea", opcode=0x1, masked=False, fin=False),
            socket_mode.encode_frame(b"you there", opcode=0x9, masked=False),
            socket_mode.encode_frame(b"dy", opcode=0x0, masked=False),
        ))

        class FakeSocket:
            def __init__(self):
                self.sent = bytearray()

            def sendall(self, value):
                self.sent.extend(value)

        fake = FakeSocket()
        connection = socket_mode.WebSocketConnection(fake, io.BytesIO(incoming))
        self.assertEqual(connection.recv_text(), "ready")
        fin, opcode, payload = socket_mode.decode_frame(bytes(fake.sent), expect_masked=True)
        self.assertTrue(fin)
        self.assertEqual((opcode, payload), (0xA, b"you there"))

    def test_invalid_close_code_and_reason_are_rejected(self):
        class FakeSocket:
            def sendall(self, _value):
                raise AssertionError("invalid close must not be echoed")

        for payload in (struct.pack("!H", 1005), struct.pack("!H", 1000) + b"\xff"):
            incoming = socket_mode.encode_frame(payload, opcode=0x8, masked=False)
            connection = socket_mode.WebSocketConnection(FakeSocket(), io.BytesIO(incoming))
            with self.assertRaises(socket_mode.WebSocketProtocolError):
                connection.recv_text()

    def test_protocol_error_context_closes_with_1002(self):
        incoming = socket_mode.encode_frame(b"masked by server", masked=True)

        class FakeSocket:
            def __init__(self):
                self.sent = bytearray()

            def sendall(self, value):
                self.sent.extend(value)

            def shutdown(self, _how):
                pass

            def close(self):
                pass

        fake = FakeSocket()
        connection = socket_mode.WebSocketConnection(fake, io.BytesIO(incoming))
        with self.assertRaises(socket_mode.WebSocketProtocolError):
            with connection:
                connection.recv_text()
        fin, opcode, payload = socket_mode.decode_frame(bytes(fake.sent), expect_masked=True)
        self.assertTrue(fin)
        self.assertEqual(opcode, 0x8)
        self.assertEqual(struct.unpack("!H", payload)[0], 1002)


class PackageContractTests(unittest.TestCase):
    def _install_env(self, temp, root):
        env = os.environ.copy()
        env.update({
            "HOME": str(temp / "home"),
            "AIRLOCK_ROOT": str(root),
            "AIRLOCK_APP_DIR": str(APP_DIR),
            "AIRLOCK_APP_ID": "slack-unfurl",
            "AIRLOCK_SLACK_UNFURL_DOMAIN_SUFFIX": DOMAIN,
            "AIRLOCK_SLACK_UNFURL_DEDICATED_PORTS": "8000,19920",
            "AIRLOCK_SLACK_UNFURL_BOT_TOKEN_ENV": "SLACK_UNFURL_BOT_TOKEN",
            "AIRLOCK_SLACK_UNFURL_APP_TOKEN_ENV": "SLACK_UNFURL_APP_TOKEN",
            "PYTHONDONTWRITEBYTECODE": "1",
        })
        return env

    def test_manifest_pins_confirmed_token_environment_names(self):
        manifest = tomllib.loads((APP_DIR / "airlock-app.toml").read_text())
        self.assertEqual(manifest["config"]["defaults"]["bot_token_env"], "SLACK_UNFURL_BOT_TOKEN")
        self.assertEqual(manifest["config"]["defaults"]["app_token_env"], "SLACK_UNFURL_APP_TOKEN")
        self.assertEqual(manifest["config"]["defaults"]["dedicated_ports"], "8000,19920")
        self.assertEqual(manifest["config"]["defaults"]["domain_suffix"], "example.test")
        self.assertNotIn(
            "AIRLOCK_SLACK_UNFURL_DEDICATED_PORTS", manifest["config"]["runtime_env"]
        )

    def test_unit_reads_secret_file_and_restarts(self):
        rendered = subprocess.run(
            [
                "bash", "-c",
                (
                    'source "$1"; render_slack_unfurl_unit '
                    'example.test 8000,19920 BOT_TOKEN APP_TOKEN /tmp/backend'
                ),
                "bash", str(APP_DIR / "render.sh"),
            ],
            check=True,
            text=True,
            capture_output=True,
        )
        self.assertEqual(rendered.stderr, "")
        self.assertIn("EnvironmentFile=-%h/.config/airlock-slack-unfurl.env", rendered.stdout)
        self.assertIn("Environment=AIRLOCK_SLACK_UNFURL_DOMAIN=example.test", rendered.stdout)
        self.assertIn("Environment=AIRLOCK_SLACK_UNFURL_ALLOWED_PORTS=8000,19920", rendered.stdout)
        self.assertIn("Environment=AIRLOCK_SLACK_UNFURL_BOT_TOKEN_NAME=BOT_TOKEN", rendered.stdout)
        self.assertIn("Environment=AIRLOCK_SLACK_UNFURL_APP_TOKEN_NAME=APP_TOKEN", rendered.stdout)
        self.assertIn("Type=simple", rendered.stdout)
        self.assertIn("Restart=on-failure", rendered.stdout)
        self.assertIn("TimeoutStopSec=15min", rendered.stdout)
        self.assertNotIn("proxy_pass", rendered.stdout)

    def test_render_library_has_no_top_level_output(self):
        result = subprocess.run(
            ["bash", str(APP_DIR / "render.sh")], check=True, text=True, capture_output=True
        )
        self.assertEqual((result.stdout, result.stderr), ("", ""))

    def test_smoke_asserts_worker_active(self):
        smoke = (APP_DIR / "smoke.sh").read_text()
        self.assertIn("systemctl --user is-active --quiet airlock-slack-unfurl.service", smoke)

    def test_install_tightens_secret_file_and_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            root = temp / "root"
            (root / "install").mkdir(parents=True)
            (root / "install" / "lib.sh").write_text(
                "require_cmd() { :; }\n"
                "airlock_load() { :; }\n"
                "airlock_run() { :; }\n"
                "log() { :; }\n"
                "die() { echo \"$*\" >&2; return 1; }\n"
            )
            env = self._install_env(temp, root)
            secret_dir = temp / "home" / ".config"
            secret_dir.mkdir(parents=True)
            secret_file = secret_dir / "airlock-slack-unfurl.env"
            secret_file.write_text("TOKEN_NAMES_ONLY_IN_FIXTURE=1\n")
            secret_file.chmod(0o644)
            subprocess.run(
                ["bash", str(APP_DIR / "install.sh")], check=True,
                text=True, capture_output=True, env=env,
            )
            self.assertEqual(secret_file.stat().st_mode & 0o777, 0o600)

        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            root = temp / "root"
            (root / "install").mkdir(parents=True)
            (root / "install" / "lib.sh").write_text(
                "require_cmd() { :; }\n"
                "airlock_load() { :; }\n"
                "airlock_run() { :; }\n"
                "log() { :; }\n"
                "die() { echo \"$*\" >&2; return 1; }\n"
            )
            env = self._install_env(temp, root)
            secret_dir = temp / "home" / ".config"
            secret_dir.mkdir(parents=True)
            target = temp / "unrelated.env"
            target.write_text("UNCHANGED=1\n")
            target.chmod(0o644)
            (secret_dir / "airlock-slack-unfurl.env").symlink_to(target)
            result = subprocess.run(
                ["bash", str(APP_DIR / "install.sh")], check=False,
                text=True, capture_output=True, env=env,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must not be a symlink", result.stderr)
            self.assertEqual(target.stat().st_mode & 0o777, 0o644)

    def test_smoke_enforces_secret_file_boundary(self):
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            root = temp / "root"
            (root / "install").mkdir(parents=True)
            (root / "install" / "lib.sh").write_text(
                "airlock_load() { :; }\n"
            )
            fake_bin = temp / "bin"
            fake_bin.mkdir()
            systemctl = fake_bin / "systemctl"
            systemctl.write_text("#!/usr/bin/env bash\nexit 0\n")
            systemctl.chmod(0o755)
            secret_dir = temp / "home" / ".config"
            secret_dir.mkdir(parents=True)
            secret_file = secret_dir / "airlock-slack-unfurl.env"
            secret_file.write_text("TOKEN_NAMES_ONLY_IN_FIXTURE=1\n")
            secret_file.chmod(0o600)
            env = os.environ.copy()
            env.update({
                "HOME": str(temp / "home"),
                "PATH": str(fake_bin) + os.pathsep + env["PATH"],
                "AIRLOCK_ROOT": str(root),
                "AIRLOCK_APP_ID": "slack-unfurl",
            })
            good = subprocess.run(
                ["bash", str(APP_DIR / "smoke.sh")], check=False,
                text=True, capture_output=True, env=env,
            )
            self.assertEqual(good.returncode, 0, good.stderr)
            secret_file.chmod(0o644)
            bad = subprocess.run(
                ["bash", str(APP_DIR / "smoke.sh")], check=False,
                text=True, capture_output=True, env=env,
            )
            self.assertNotEqual(bad.returncode, 0)
            self.assertIn("mode 0600", bad.stdout)
            secret_file.unlink()
            target = temp / "unrelated.env"
            target.write_text("UNCHANGED=1\n")
            target.chmod(0o600)
            secret_file.symlink_to(target)
            bad_symlink = subprocess.run(
                ["bash", str(APP_DIR / "smoke.sh")], check=False,
                text=True, capture_output=True, env=env,
            )
            self.assertNotEqual(bad_symlink.returncode, 0)
            self.assertIn("owner-owned regular file", bad_symlink.stdout)

    def test_installer_dry_render_preserves_runtime_abi_and_artifacts(self):
        manifest = tomllib.loads((APP_DIR / "airlock-app.toml").read_text())
        self.assertEqual(manifest["artifacts"], {
            "units": ["airlock-slack-unfurl.service"],
            "files": ["~/.local/share/airlock-slack-unfurl/"],
        })
        with tempfile.TemporaryDirectory() as raw_temp:
            temp = pathlib.Path(raw_temp)
            root = temp / "root"
            (root / "install").mkdir(parents=True)
            (root / "install" / "lib.sh").write_text(
                "require_cmd() { :; }\n"
                "airlock_load() { :; }\n"
                "airlock_run() { :; }\n"
                "log() { :; }\n"
            )
            render_dir = temp / "render"
            env = self._install_env(temp, root)
            env.update({
                "AIRLOCK_DRY_RUN": "1",
                "AIRLOCK_RENDER_DIR": str(render_dir),
            })
            subprocess.run(
                ["bash", str(APP_DIR / "install.sh")],
                check=True,
                text=True,
                capture_output=True,
                env=env,
            )
            unit = (render_dir / "units" / "airlock-slack-unfurl.service").read_text()
            expected_backend = temp / "home" / ".local/share/airlock-slack-unfurl/backend"
            self.assertIn(f"ExecStart=/usr/bin/python3 {expected_backend}/slack_unfurl.py", unit)
            self.assertIn("Environment=AIRLOCK_SLACK_UNFURL_ALLOWED_PORTS=8000,19920", unit)
            self.assertIn(
                "Environment=AIRLOCK_SLACK_UNFURL_BOT_TOKEN_NAME=SLACK_UNFURL_BOT_TOKEN", unit
            )
            self.assertIn(
                "Environment=AIRLOCK_SLACK_UNFURL_APP_TOKEN_NAME=SLACK_UNFURL_APP_TOKEN", unit
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
