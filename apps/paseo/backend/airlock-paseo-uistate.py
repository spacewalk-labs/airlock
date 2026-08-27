#!/usr/bin/env python3
"""airlock paseo ui-state — the box-side home for web-UI state paseo keeps per device.

Paseo stores the sidebar's project/workspace ORDER in the browser (a zustand
`persist` store keyed `sidebar-project-workspace-order`, backed by localStorage),
so a drag on the Mac is invisible on the iPad. There is no server-side home for it
upstream: the daemon exposes no general key/value route, and the order never
crosses the wire at all.

This is that home. One loopback HTTP service, one JSON blob per allowed key:

    GET    /<key>   -> 200 the stored JSON text, or 404 when nothing is stored yet
    PUT    /<key>   -> 204 (body is the JSON text the web UI would have kept local)
    DELETE /<key>   -> 204 (idempotent)

It binds 127.0.0.1 and carries no authentication of its own, exactly like the other
airlock loopback backends: the paseo nginx owner gate in front of it answers 403 to
everyone who is not the box owner, and nothing else can reach the port. The key
allowlist is the second wall — an unknown key is 404, so a patched bundle can never
turn this into a general-purpose store for whatever the upstream UI persists next.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

# Only the keys airlock deliberately shares between the owner's devices. Paseo
# persists more than this (draft reviews, dismissed callouts, a daemon registry);
# none of it is asked for here, and a key that is not listed is 404 on every verb.
ALLOWED_KEYS = frozenset({"sidebar-project-workspace-order"})

# The sidebar order is a list of keys — kilobytes at the very most. The cap is what
# stops a broken or hostile client from filling the state directory; it is not a
# tuning knob.
MAX_BYTES = 256 * 1024


def state_dir() -> Path:
    configured = os.environ.get("AIRLOCK_PASEO_UISTATE_DIR", "").strip()
    if configured:
        return Path(configured)
    base = os.environ.get("XDG_STATE_HOME", "").strip() or str(Path.home() / ".local" / "state")
    return Path(base) / "airlock" / "paseo-ui-state"


def key_path(key: str) -> Path | None:
    """The file backing `key`, or None when the key is not one we store.

    The allowlist is checked BEFORE the name is joined onto a path, so traversal
    ("../../.ssh/id_ed25519") never reaches the filesystem: a name that is not
    literally in ALLOWED_KEYS is rejected, and every allowed name is a bare slug.
    """
    if key not in ALLOWED_KEYS:
        return None
    return state_dir() / f"{key}.json"


def log(message: str) -> None:
    print(f"[paseo-uistate] {message}", flush=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "airlock-paseo-uistate"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003 - stdlib hook
        # The default handler logs every request to stderr, which would put the
        # owner's polling in the journal forever. Failures are logged explicitly.
        pass

    def _key(self) -> str:
        return self.path.lstrip("/").split("?", 1)[0]

    def _send(self, status: int, body: bytes = b"", ctype: str = "application/json") -> None:
        self.send_response(status)
        if body:
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
        else:
            self.send_header("Content-Length", "0")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - stdlib hook
        path = key_path(self._key())
        if path is None:
            self._send(404)
            return
        try:
            body = path.read_bytes()
        except FileNotFoundError:
            self._send(404)
            return
        except OSError as exc:
            log(f"read failed: {exc}")
            self._send(500)
            return
        self._send(200, body)

    def do_PUT(self) -> None:  # noqa: N802 - stdlib hook
        path = key_path(self._key())
        if path is None:
            self._send(404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send(400)
            return
        if length < 0 or length > MAX_BYTES:
            self._send(413)
            return
        raw = self.rfile.read(length) if length else b""
        try:
            json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            # Store only what we can hand back as JSON. A truncated body that we
            # accepted would come back as a corrupt store the web UI cannot parse,
            # and the device would silently lose its order instead of failing here.
            self._send(400)
            return
        try:
            directory = path.parent
            directory.mkdir(parents=True, exist_ok=True)
            os.chmod(directory, 0o700)
            fd, tmp = tempfile.mkstemp(dir=str(directory), prefix=".tmp-")
            try:
                with os.fdopen(fd, "wb") as handle:
                    handle.write(raw)
                    handle.flush()
                    os.fsync(handle.fileno())
                os.chmod(tmp, 0o600)
                os.replace(tmp, path)
            except BaseException:
                os.unlink(tmp)
                raise
        except OSError as exc:
            log(f"write failed: {exc}")
            self._send(500)
            return
        self._send(204)

    def do_DELETE(self) -> None:  # noqa: N802 - stdlib hook
        path = key_path(self._key())
        if path is None:
            self._send(404)
            return
        try:
            path.unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            log(f"delete failed: {exc}")
            self._send(500)
            return
        self._send(204)


def main() -> int:
    raw_port = os.environ.get("AIRLOCK_PASEO_UISTATE_PORT", "").strip()
    try:
        port = int(raw_port)
    except ValueError:
        print("AIRLOCK_PASEO_UISTATE_PORT is required and must be a port number", file=sys.stderr)
        return 2
    if not 1 <= port <= 65535:
        print(f"AIRLOCK_PASEO_UISTATE_PORT out of range: {port}", file=sys.stderr)
        return 2
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    log(f"listening on 127.0.0.1:{port} (state {state_dir()})")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
