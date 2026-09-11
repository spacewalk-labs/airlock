#!/usr/bin/env python3
"""Small stdlib-only Slack Socket Mode and RFC6455 client.

Only the protocol surface this worker needs is implemented: TLS WebSocket
handshake, masked client frames, text messages, fragmentation, ping/pong, close,
and the two Slack Web API calls used by Socket Mode.
"""

from __future__ import annotations

import base64
import hashlib
import io
import json
import math
import os
import socket
import ssl
import struct
import time
import urllib.error
import urllib.parse
import urllib.request


SLACK_API_ROOT = "https://slack.com/api/"
WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_FRAME_BYTES = 1 << 20
READ_IDLE_SECONDS = 60


class SlackAPIError(RuntimeError):
    def __init__(self, message, *, transient=False, retry_after=None):
        super().__init__(message)
        self.transient = transient
        self.retry_after = retry_after


class WebSocketProtocolError(RuntimeError):
    pass


class WebSocketIdleTimeout(WebSocketProtocolError):
    pass


def _validate_close_payload(payload):
    if len(payload) == 1:
        raise WebSocketProtocolError("invalid WebSocket close payload")
    if not payload:
        return
    code = struct.unpack("!H", payload[:2])[0]
    known = {
        1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011,
        1012, 1013, 1014,
    }
    if code not in known and not 3000 <= code <= 4999:
        raise WebSocketProtocolError("invalid WebSocket close status code")
    try:
        payload[2:].decode("utf-8")
    except UnicodeDecodeError as exc:
        raise WebSocketProtocolError("invalid UTF-8 WebSocket close reason") from exc


def _json_response(response, limit=1 << 20):
    body = response.read(limit + 1)
    if len(body) > limit:
        raise SlackAPIError("Slack API response is too large")
    try:
        value = json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SlackAPIError("Slack API returned invalid JSON") from exc
    if not isinstance(value, dict) or value.get("ok") is not True:
        error = value.get("error", "unknown_error") if isinstance(value, dict) else "invalid_response"
        transient = error in {"ratelimited", "internal_error", "request_timeout", "service_unavailable"}
        raise SlackAPIError(f"Slack API call failed: {error}", transient=transient)
    return value


def slack_api(method, token, payload=None, *, opener=urllib.request.urlopen, timeout=10):
    if method not in {"apps.connections.open", "chat.unfurl"}:
        raise ValueError("unsupported Slack API method")
    data = b"" if payload is None else json.dumps(
        payload, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")
    request = urllib.request.Request(
        SLACK_API_ROOT + method,
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json; charset=utf-8",
            "Accept": "application/json",
            "User-Agent": "airlock-slack-unfurl/1",
        },
        method="POST",
    )
    try:
        with opener(request, timeout=timeout) as response:
            return _json_response(response)
    except urllib.error.HTTPError as exc:
        retry_after = exc.headers.get("Retry-After") if exc.headers else None
        try:
            retry_after = float(retry_after) if retry_after is not None else None
        except ValueError:
            retry_after = None
        if retry_after is not None and (not math.isfinite(retry_after) or retry_after < 0):
            retry_after = None
        raise SlackAPIError(
            f"Slack API HTTP {exc.code}",
            transient=exc.code == 429 or 500 <= exc.code < 600,
            retry_after=retry_after,
        ) from exc
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise SlackAPIError(f"Slack API request failed: {exc}", transient=True) from exc


def open_socket_url(app_token, **kwargs):
    value = slack_api("apps.connections.open", app_token, **kwargs)
    url = value.get("url")
    parsed = urllib.parse.urlsplit(url) if isinstance(url, str) else None
    if parsed is None or parsed.scheme != "wss" or not parsed.hostname:
        raise SlackAPIError("apps.connections.open returned no valid wss URL")
    return url


def chat_unfurl(bot_token, channel, timestamp, unfurls, **kwargs):
    return slack_api(
        "chat.unfurl",
        bot_token,
        {"channel": channel, "ts": timestamp, "unfurls": unfurls},
        **kwargs,
    )


def encode_frame(payload, opcode=0x1, *, masked=True, mask_key=None, fin=True):
    """Encode one RFC6455 frame. Client callers leave ``masked`` enabled."""
    if isinstance(payload, str):
        payload = payload.encode("utf-8")
    payload = bytes(payload)
    if opcode not in {0x0, 0x1, 0x2, 0x8, 0x9, 0xA}:
        raise ValueError("unsupported WebSocket opcode")
    if opcode >= 0x8 and (not fin or len(payload) > 125):
        raise ValueError("invalid WebSocket control frame")
    if len(payload) > MAX_FRAME_BYTES:
        raise ValueError("WebSocket frame is too large")

    first = (0x80 if fin else 0) | opcode
    mask_bit = 0x80 if masked else 0
    length = len(payload)
    if length < 126:
        header = bytes((first, mask_bit | length))
    elif length < (1 << 16):
        header = bytes((first, mask_bit | 126)) + struct.pack("!H", length)
    else:
        header = bytes((first, mask_bit | 127)) + struct.pack("!Q", length)

    if not masked:
        return header + payload
    key = os.urandom(4) if mask_key is None else bytes(mask_key)
    if len(key) != 4:
        raise ValueError("WebSocket mask key must be four bytes")
    masked_payload = bytes(byte ^ key[index % 4] for index, byte in enumerate(payload))
    return header + key + masked_payload


def _read_exact(stream, size, stop_event=None):
    chunks = bytearray()
    while len(chunks) < size:
        try:
            chunk = stream.read(size - len(chunks))
        except socket.timeout:
            # A timeout in the middle of a frame must not discard the bytes
            # already consumed. It is only a periodic SIGTERM observation point.
            if stop_event is not None and stop_event.is_set():
                raise InterruptedError("WebSocket receive stopped")
            continue
        if not chunk:
            raise EOFError("WebSocket connection closed mid-frame")
        chunks.extend(chunk)
    return bytes(chunks)


def read_frame(stream, *, expect_masked=None, stop_event=None):
    """Read a frame from a file-like object and return ``(fin, opcode, body)``."""
    first, second = _read_exact(stream, 2, stop_event)
    if first & 0x70:
        raise WebSocketProtocolError("reserved WebSocket bits are set")
    fin = bool(first & 0x80)
    opcode = first & 0x0F
    if opcode not in {0x0, 0x1, 0x2, 0x8, 0x9, 0xA}:
        raise WebSocketProtocolError("unsupported WebSocket opcode")
    masked = bool(second & 0x80)
    if expect_masked is not None and masked != expect_masked:
        raise WebSocketProtocolError("unexpected WebSocket masking direction")
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", _read_exact(stream, 2, stop_event))[0]
        if length < 126:
            raise WebSocketProtocolError("non-minimal WebSocket payload length")
    elif length == 127:
        raw_length = _read_exact(stream, 8, stop_event)
        if raw_length[0] & 0x80:
            raise WebSocketProtocolError("invalid WebSocket 64-bit length")
        length = struct.unpack("!Q", raw_length)[0]
        if length < (1 << 16):
            raise WebSocketProtocolError("non-minimal WebSocket payload length")
    if length > MAX_FRAME_BYTES:
        raise WebSocketProtocolError("WebSocket frame is too large")
    if opcode >= 0x8 and (not fin or length > 125):
        raise WebSocketProtocolError("invalid WebSocket control frame")
    key = _read_exact(stream, 4, stop_event) if masked else None
    payload = _read_exact(stream, length, stop_event)
    if key is not None:
        payload = bytes(byte ^ key[index % 4] for index, byte in enumerate(payload))
    return fin, opcode, payload


def decode_frame(frame, *, expect_masked=None):
    stream = io.BytesIO(frame)
    value = read_frame(stream, expect_masked=expect_masked)
    if stream.read(1):
        raise WebSocketProtocolError("trailing bytes after WebSocket frame")
    return value


class WebSocketConnection:
    def __init__(self, sock, stream, stop_event=None):
        self.sock = sock
        self.stream = stream
        self.stop_event = stop_event
        self._close_sent = False

    def send_frame(self, payload, opcode=0x1, *, fin=True):
        self.sock.sendall(encode_frame(payload, opcode, fin=fin))

    def send_json(self, value):
        self.send_frame(json.dumps(value, ensure_ascii=False, separators=(",", ":")))

    def recv_text(self):
        fragments = bytearray()
        fragmented = False
        while True:
            fin, opcode, payload = read_frame(
                self.stream, expect_masked=False, stop_event=self.stop_event
            )
            if opcode == 0x8:
                _validate_close_payload(payload)
                if not self._close_sent:
                    self.send_frame(payload, 0x8)
                    self._close_sent = True
                return None
            if opcode == 0x9:
                self.send_frame(payload, 0xA)
                continue
            if opcode == 0xA:
                continue
            if opcode == 0x2:
                raise WebSocketProtocolError("binary WebSocket messages are unsupported")
            if opcode == 0x1:
                if fragmented:
                    raise WebSocketProtocolError("new text message before continuation finished")
                fragments.extend(payload)
                fragmented = not fin
            elif opcode == 0x0:
                if not fragmented:
                    raise WebSocketProtocolError("unexpected WebSocket continuation")
                fragments.extend(payload)
                fragmented = not fin
            if len(fragments) > MAX_FRAME_BYTES:
                raise WebSocketProtocolError("WebSocket message is too large")
            if not fragmented:
                try:
                    return fragments.decode("utf-8")
                except UnicodeDecodeError as exc:
                    raise WebSocketProtocolError("invalid UTF-8 WebSocket text") from exc

    def close(self, code=1000):
        if not self._close_sent:
            try:
                self.send_frame(struct.pack("!H", code), 0x8)
            except OSError:
                pass
            self._close_sent = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.stream.close()
        finally:
            self.sock.close()

    def __enter__(self):
        return self

    def __exit__(self, _type, value, _traceback):
        # A peer protocol violation gets RFC 6455's protocol-error status.
        # Local idle expiry is not evidence that the peer sent invalid bytes.
        protocol_error = isinstance(value, WebSocketProtocolError) and not isinstance(
            value, WebSocketIdleTimeout
        )
        self.close(1002 if protocol_error else 1000)


class _SocketStream:
    """Minimal buffered ``read`` facade that remains usable after a timeout.

    ``socket.makefile()`` cannot reliably resume after the underlying socket
    times out. The worker deliberately uses a short timeout to observe SIGTERM,
    so frame reads stay directly on ``recv`` and retain any bytes delivered with
    the HTTP upgrade response here.
    """

    def __init__(self, sock, initial=b"", *, idle_timeout=READ_IDLE_SECONDS, clock=time.monotonic):
        self.sock = sock
        self.buffer = bytearray(initial)
        self.idle_timeout = idle_timeout
        self.clock = clock
        self.last_data_at = clock()

    def read(self, size):
        if size <= 0:
            return b""
        if self.buffer:
            chunk = bytes(self.buffer[:size])
            del self.buffer[:size]
            return chunk
        try:
            chunk = self.sock.recv(size)
        except socket.timeout:
            if self.clock() - self.last_data_at >= self.idle_timeout:
                raise WebSocketIdleTimeout("WebSocket connection exceeded its idle deadline")
            raise
        if chunk:
            self.last_data_at = self.clock()
        return chunk

    def close(self):
        self.buffer.clear()


def _validate_handshake_response(header_block, key):
    lines = header_block.split(b"\r\n")
    status = lines[0]
    if len(status) > 8192 or not status:
        raise WebSocketProtocolError("invalid WebSocket handshake response")
    parts = status.decode("iso-8859-1").split(" ", 2)
    if len(parts) < 2 or parts[0] != "HTTP/1.1" or parts[1] != "101":
        raise WebSocketProtocolError("WebSocket handshake was not accepted")
    headers = {}
    for line in lines[1:]:
        if len(line) > 8192:
            raise WebSocketProtocolError("WebSocket handshake header is too large")
        name, separator, value = line.decode("iso-8859-1").partition(":")
        if not separator:
            raise WebSocketProtocolError("malformed WebSocket handshake header")
        name = name.strip().lower()
        if name in headers:
            raise WebSocketProtocolError("duplicate WebSocket handshake header")
        headers[name] = value.strip()
    expected = base64.b64encode(
        hashlib.sha1((key + WEBSOCKET_GUID).encode("ascii"), usedforsecurity=False).digest()
    ).decode("ascii")
    if headers.get("upgrade", "").lower() != "websocket":
        raise WebSocketProtocolError("missing WebSocket Upgrade response")
    connection_tokens = {part.strip().lower() for part in headers.get("connection", "").split(",")}
    if "upgrade" not in connection_tokens:
        raise WebSocketProtocolError("missing WebSocket Connection upgrade response")
    if headers.get("sec-websocket-accept") != expected:
        raise WebSocketProtocolError("invalid WebSocket accept key")
    if "sec-websocket-extensions" in headers or "sec-websocket-protocol" in headers:
        raise WebSocketProtocolError("server selected an unrequested WebSocket option")


def connect_websocket(url, *, timeout=10, stop_event=None):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "wss" or not parsed.hostname or parsed.username or parsed.password:
        raise WebSocketProtocolError("Socket Mode URL must be an authenticated wss URL")
    try:
        port = parsed.port or 443
    except ValueError as exc:
        raise WebSocketProtocolError("invalid WebSocket port") from exc
    target = parsed.path or "/"
    if parsed.query:
        target += "?" + parsed.query
    host_header = parsed.hostname if port == 443 else f"{parsed.hostname}:{port}"
    key = base64.b64encode(os.urandom(16)).decode("ascii")

    raw = socket.create_connection((parsed.hostname, port), timeout=timeout)
    try:
        tls = ssl.create_default_context().wrap_socket(raw, server_hostname=parsed.hostname)
    except Exception:
        raw.close()
        raise
    tls.settimeout(timeout)
    request = (
        f"GET {target} HTTP/1.1\r\n"
        f"Host: {host_header}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "User-Agent: airlock-slack-unfurl/1\r\n\r\n"
    ).encode("ascii")
    tls.sendall(request)
    try:
        response = bytearray()
        while b"\r\n\r\n" not in response:
            chunk = tls.recv(4096)
            if not chunk:
                raise WebSocketProtocolError("WebSocket closed during handshake")
            response.extend(chunk)
            if len(response) > 65536:
                raise WebSocketProtocolError("WebSocket handshake headers are too large")
        header_block, initial = bytes(response).split(b"\r\n\r\n", 1)
        _validate_handshake_response(header_block, key)
        tls.settimeout(1.0)
        stream = _SocketStream(tls, initial)
        return WebSocketConnection(tls, stream, stop_event=stop_event)
    except Exception:
        tls.close()
        raise
