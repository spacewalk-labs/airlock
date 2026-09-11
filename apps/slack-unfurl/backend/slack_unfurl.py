#!/usr/bin/env python3
"""Unfurl tailnet-published documents through Slack Socket Mode."""

from __future__ import annotations

from collections import OrderedDict
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import math
import os
import queue
import random
import re
import signal
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

import socket_mode


ENV_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\Z")
DNS_LABEL_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z")
META_RESPONSE_LIMIT = 64 << 10
META_TIMEOUT_SECONDS = 5
DEDUPE_TTL_SECONDS = 10 * 60
DEDUPE_MAX_ENTRIES = 4096
DEFAULT_DEDICATED_PORTS = "8000,19920"
MAX_LINKS_PER_EVENT = 20
MAX_SECTION_TEXT = 3000
WORK_QUEUE_MAX = 4
MAX_RETRY_DELAY_SECONDS = 10
STOP_EVENT = threading.Event()
QUEUE_STOP = object()


class MetadataError(RuntimeError):
    pass


@dataclass(frozen=True)
class PublishedLink:
    url: str
    fqdn: str
    box: str
    name: str


@dataclass(frozen=True)
class TitleMeta:
    name: str
    title: str
    published_date: str


@dataclass
class QueuedEvent:
    """Queue reservation that becomes runnable only after its Slack ACK lands."""

    event: dict
    ready: threading.Event
    acknowledged: bool = False


def normalize_domain_suffix(value):
    raw_value = str(value)
    value = raw_value.lower().rstrip(".")
    labels = value.split(".")
    if (
        raw_value != value
        or not value
        or len(labels) < 2
        or any(not DNS_LABEL_RE.fullmatch(label) for label in labels)
    ):
        raise ValueError(
            "domain_suffix must be a canonical lowercase DNS suffix, without whitespace, a trailing dot, scheme, or path"
        )
    return value


def validate_env_name(value, label):
    if not ENV_NAME_RE.fullmatch(value or ""):
        raise ValueError(f"{label} must be an environment-variable name")
    return value


def parse_dedicated_ports(value):
    if isinstance(value, frozenset):
        if all(isinstance(port, int) and not isinstance(port, bool) and 1 <= port <= 65535 and port != 443 for port in value):
            return value
        raise ValueError("dedicated_ports contains an invalid normalized port")
    raw_value = str(value)
    values = raw_value.split(",")
    ports = set()
    for raw in values:
        if not raw or not raw.isascii() or not raw.isdecimal():
            raise ValueError("dedicated_ports must be canonical comma-separated port numbers")
        port = int(raw)
        if not 1 <= port <= 65535 or port == 443:
            raise ValueError("dedicated_ports must contain ports from 1 to 65535, excluding 443")
        ports.add(port)
    if raw_value != ",".join(str(int(raw)) for raw in values) or len(ports) != len(values):
        raise ValueError(
            "dedicated_ports must not contain whitespace, leading zeroes, or duplicates"
        )
    return frozenset(ports)


def parse_publish_url(url, domain_suffix, dedicated_ports=DEFAULT_DEDICATED_PORTS):
    """Return a published-document target, or ``None`` for unrelated/hub URLs."""
    suffix = normalize_domain_suffix(domain_suffix)
    ports = parse_dedicated_ports(dedicated_ports)
    try:
        parsed = urllib.parse.urlsplit(url)
        port = parsed.port
    except (TypeError, ValueError):
        return None
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        return None
    host = parsed.hostname.lower().rstrip(".")
    ending = "." + suffix
    if not host.endswith(ending):
        return None
    box = host[: -len(ending)]
    if not DNS_LABEL_RE.fullmatch(box):
        return None

    try:
        path = urllib.parse.unquote(parsed.path, errors="strict")
    except (UnicodeDecodeError, ValueError):
        return None
    prefix = "/publish/files/"
    if path.startswith(prefix) and port in {None, 443}:
        name = path[len(prefix) :]
    elif port in ports and path.startswith("/"):
        # A root path is a document only on an explicit dedicated port. On the
        # normal 443 hub it returns the Airlock launcher and must not be unfurled.
        name = path[1:]
    else:
        return None
    if (
        not name
        or "/" in name
        or "\\" in name
        or name in {".", ".."}
        or any(ord(char) < 32 for char in name)
        or not name.lower().endswith(".html")
    ):
        return None
    return PublishedLink(url=url, fqdn=host, box=box, name=name)


def _published_date(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        try:
            return datetime.fromtimestamp(value, timezone.utc).date().isoformat()
        except (OverflowError, OSError, ValueError) as exc:
            raise MetadataError("metadata mtime is outside the supported range") from exc
    if isinstance(value, str):
        stripped = value.strip()
        try:
            return datetime.fromtimestamp(float(stripped), timezone.utc).date().isoformat()
        except (ValueError, OverflowError, OSError):
            pass
        try:
            parsed = datetime.fromisoformat(stripped.replace("Z", "+00:00"))
            return parsed.date().isoformat()
        except ValueError as exc:
            raise MetadataError("metadata mtime has an invalid format") from exc
    raise MetadataError("metadata mtime is missing")


def parse_title_meta(payload, expected_name):
    if isinstance(payload, (bytes, bytearray, str)):
        try:
            payload = json.loads(payload)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise MetadataError("metadata endpoint returned invalid JSON") from exc
    if not isinstance(payload, dict) or payload.get("name") != expected_name:
        raise MetadataError("metadata response does not match the requested document")
    title = payload.get("title")
    if not isinstance(title, str) or not title.strip():
        raise MetadataError("metadata response has no title")
    title = title.strip()
    if len(title) > 500:
        raise MetadataError("metadata title is too long")
    return TitleMeta(expected_name, title, _published_date(payload.get("mtime")))


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, _req, _fp, _code, _msg, _headers, _newurl):
        return None


_META_OPENER = urllib.request.build_opener(_NoRedirectHandler()).open


def fetch_title_meta(target, *, opener=None, timeout=META_TIMEOUT_SECONDS):
    query = urllib.parse.urlencode({"name": target.name})
    url = f"https://{target.fqdn}/publish/api/meta?{query}"
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": "airlock-slack-unfurl/1"},
        method="GET",
    )
    opener = opener or _META_OPENER
    try:
        with opener(request, timeout=timeout) as response:
            if response.geturl() != url:
                raise MetadataError("metadata endpoint redirected outside its exact URL")
            body = response.read(META_RESPONSE_LIMIT + 1)
    except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError, OSError) as exc:
        raise MetadataError(f"title lookup failed: {exc}") from exc
    if len(body) > META_RESPONSE_LIMIT:
        raise MetadataError("metadata response is too large")
    return parse_title_meta(body, target.name)


def slack_escape(value):
    return str(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def build_unfurl(target, meta):
    # A literal pipe terminates Slack's <url|label> URL field. Encode it before
    # applying Slack's required entity escaping; the unfurls map key remains the
    # exact URL from the event.
    link_url = urllib.parse.quote(
        target.url, safe=":/?#[]@!$&'()*+,;=%"
    )
    section_text = f"<{slack_escape(link_url)}|{slack_escape(meta.title)}>"
    if len(section_text) > MAX_SECTION_TEXT:
        raise MetadataError("unfurl section text is too long")
    return {
        "blocks": [
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": section_text,
                },
            },
            {
                "type": "context",
                "elements": [
                    {
                        "type": "mrkdwn",
                        "text": (
                            f"*발행 박스:* {slack_escape(target.box)}  "
                            f"*발행일:* {meta.published_date}"
                        ),
                    }
                ],
            },
        ]
    }


class DedupeCache:
    def __init__(self, ttl=DEDUPE_TTL_SECONDS, max_entries=DEDUPE_MAX_ENTRIES, clock=time.monotonic):
        self.ttl = ttl
        self.max_entries = max_entries
        self.clock = clock
        self.entries = OrderedDict()

    def _prune(self, now):
        while self.entries:
            key, expires = next(iter(self.entries.items()))
            if expires > now and len(self.entries) <= self.max_entries:
                break
            self.entries.pop(key, None)

    def seen(self, key):
        now = self.clock()
        self._prune(now)
        expires = self.entries.get(key)
        if expires is None or expires <= now:
            self.entries.pop(key, None)
            return False
        self.entries.move_to_end(key)
        return True

    def remember(self, key):
        now = self.clock()
        self.entries[key] = now + self.ttl
        self.entries.move_to_end(key)
        self._prune(now)


def process_link_shared(
    event,
    domain_suffix,
    dedicated_ports,
    fetcher,
    sender,
    dedupe,
    *,
    log=None,
    stop_event=None,
):
    log = log or (lambda message: print(message, file=sys.stderr, flush=True))
    channel = event.get("channel") if isinstance(event, dict) else None
    timestamp = event.get("message_ts") if isinstance(event, dict) else None
    links = event.get("links") if isinstance(event, dict) else None
    if not isinstance(channel, str) or not isinstance(timestamp, str) or not isinstance(links, list):
        log("link_shared ignored: missing channel, message_ts, or links")
        return 0
    key = (channel, timestamp)
    if dedupe.seen(key):
        return 0

    unfurls = {}
    for item in links[:MAX_LINKS_PER_EVENT]:
        url = item.get("url") if isinstance(item, dict) else None
        target = (
            parse_publish_url(url, domain_suffix, dedicated_ports)
            if isinstance(url, str)
            else None
        )
        if target is None or target.url in unfurls:
            continue
        try:
            meta = fetcher(target)
            unfurls[target.url] = build_unfurl(target, meta)
        except Exception as exc:  # one bad box/link must not suppress good siblings
            log(f"title lookup skipped for {target.fqdn}/{target.name}: {exc}")
            continue

    if unfurls:
        sender(channel, timestamp, unfurls)
    dedupe.remember(key)
    return len(unfurls)


def _handle_signal(_signum, _frame):
    STOP_EVENT.set()


def _required_runtime_config():
    domain = normalize_domain_suffix(os.environ.get("AIRLOCK_SLACK_UNFURL_DOMAIN", ""))
    dedicated_ports = parse_dedicated_ports(
        os.environ.get("AIRLOCK_SLACK_UNFURL_ALLOWED_PORTS", "")
    )
    bot_name = validate_env_name(
        os.environ.get("AIRLOCK_SLACK_UNFURL_BOT_TOKEN_NAME", ""), "bot_token_env"
    )
    app_name = validate_env_name(
        os.environ.get("AIRLOCK_SLACK_UNFURL_APP_TOKEN_NAME", ""), "app_token_env"
    )
    bot_token = os.environ.get(bot_name)
    app_token = os.environ.get(app_name)
    if not bot_token or not app_token:
        missing = bot_name if not bot_token else app_name
        raise ValueError(f"required token environment variable is absent: {missing}")
    return domain, dedicated_ports, bot_token, app_token


def _send_unfurls_with_retry(bot_token, channel, timestamp, unfurls, *, sender=None, sleeper=time.sleep):
    sender = sender or socket_mode.chat_unfurl
    delay = 1.0
    for attempt in range(3):
        try:
            return sender(bot_token, channel, timestamp, unfurls)
        except socket_mode.SlackAPIError as exc:
            if attempt == 2 or not exc.transient:
                raise
            # Retry-After is Slack's earliest permitted retry time, not a hint
            # that may be shortened to our ordinary exponential-backoff cap.
            retry_delay = (
                exc.retry_after
                if exc.retry_after is not None
                else min(MAX_RETRY_DELAY_SECONDS, delay)
            )
            sleeper(max(0, retry_delay))
            delay *= 2


def _process_event_queue(work_queue, domain, dedicated_ports, bot_token, dedupe):
    while True:
        item = work_queue.get()
        try:
            if item is QUEUE_STOP:
                return
            item.ready.wait()
            if not item.acknowledged:
                continue
            process_link_shared(
                item.event,
                domain,
                dedicated_ports,
                fetch_title_meta,
                lambda channel, timestamp, unfurls: _send_unfurls_with_retry(
                    bot_token, channel, timestamp, unfurls
                ),
                dedupe,
            )
        except Exception as exc:
            print(f"link_shared processing failed: {exc}", file=sys.stderr, flush=True)
        finally:
            work_queue.task_done()


def acknowledge_and_enqueue(envelope, connection, work_queue, *, log=None):
    """Take ownership, then ACK immediately before any link/network work."""
    log = log or (lambda message: print(message, file=sys.stderr, flush=True))
    if not isinstance(envelope, dict):
        return True
    payload = envelope.get("payload")
    event = payload.get("event") if isinstance(payload, dict) else None
    queued = None
    if isinstance(event, dict) and event.get("type") == "link_shared":
        envelope_id = envelope.get("envelope_id")
        if not isinstance(envelope_id, str):
            log("link_shared not acknowledged: envelope_id is missing")
            return False
        queued = QueuedEvent(event, threading.Event())
        try:
            work_queue.put_nowait(queued)
        except queue.Full:
            # Do not ACK work we could not take ownership of. Closing the
            # connection prompts Slack to redeliver it on a fresh connection.
            log("link_shared not acknowledged: bounded work queue is full")
            return False
    envelope_id = envelope.get("envelope_id")
    if isinstance(envelope_id, str):
        try:
            connection.send_json({"envelope_id": envelope_id})
        except Exception:
            if queued is not None:
                queued.ready.set()
            raise
    if queued is not None:
        queued.acknowledged = True
        queued.ready.set()
    return envelope.get("type") != "disconnect"


def _resets_reconnect_backoff(envelope):
    return isinstance(envelope, dict) and envelope.get("type") not in {"hello", "disconnect"}


def _connection_retry_delay(exc, delay, *, jitter=random.uniform):
    if (
        isinstance(exc, socket_mode.SlackAPIError)
        and exc.retry_after is not None
        and math.isfinite(exc.retry_after)
        and exc.retry_after >= 0
    ):
        return max(0, exc.retry_after)
    return min(30.0, delay) * jitter(0.8, 1.2)


def run_worker(domain, dedicated_ports, bot_token, app_token):
    dedupe = DedupeCache()
    work_queue = queue.Queue(maxsize=WORK_QUEUE_MAX)
    processor = threading.Thread(
        target=_process_event_queue,
        args=(work_queue, domain, dedicated_ports, bot_token, dedupe),
        name="slack-unfurl-events",
        daemon=True,
    )
    processor.start()
    delay = 1.0
    try:
        while not STOP_EVENT.is_set():
            connection_error = None
            try:
                websocket_url = socket_mode.open_socket_url(app_token)
                with socket_mode.connect_websocket(websocket_url, stop_event=STOP_EVENT) as connection:
                    while not STOP_EVENT.is_set():
                        try:
                            raw = connection.recv_text()
                        except InterruptedError:
                            break
                        if raw is None:
                            break
                        try:
                            envelope = json.loads(raw)
                        except json.JSONDecodeError:
                            print("Socket Mode ignored an invalid JSON envelope", file=sys.stderr, flush=True)
                            continue
                        if _resets_reconnect_backoff(envelope):
                            delay = 1.0
                        if not acknowledge_and_enqueue(envelope, connection, work_queue):
                            break
            except Exception as exc:
                if STOP_EVENT.is_set():
                    break
                connection_error = exc
                print(f"Socket Mode connection failed; retrying: {exc}", file=sys.stderr, flush=True)
            if STOP_EVENT.is_set():
                break
            wait_for = _connection_retry_delay(connection_error, delay)
            STOP_EVENT.wait(wait_for)
            delay = min(30.0, delay * 2)
    finally:
        work_queue.put(QUEUE_STOP)
        # Slack will not resend acknowledged envelopes. Drain them on a normal
        # SIGTERM rather than silently losing cards during service restarts.
        processor.join()
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["--check-config"]:
        if len(argv) != 5:
            print(
                "usage: slack_unfurl.py --check-config DOMAIN DEDICATED_PORTS BOT_TOKEN_ENV APP_TOKEN_ENV",
                file=sys.stderr,
            )
            return 2
        try:
            normalize_domain_suffix(argv[1])
            parse_dedicated_ports(argv[2])
            validate_env_name(argv[3], "bot_token_env")
            validate_env_name(argv[4], "app_token_env")
        except ValueError as exc:
            print(exc, file=sys.stderr)
            return 2
        return 0
    if argv:
        print("usage: slack_unfurl.py", file=sys.stderr)
        return 2
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)
    try:
        domain, dedicated_ports, bot_token, app_token = _required_runtime_config()
    except ValueError as exc:
        print(f"slack-unfurl configuration error: {exc}", file=sys.stderr)
        return 2
    return run_worker(domain, dedicated_ports, bot_token, app_token)


if __name__ == "__main__":
    raise SystemExit(main())
