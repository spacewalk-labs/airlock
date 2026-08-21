#!/usr/bin/env python3
"""Airlock code-server slot manager.

A tiny asyncio HTTP API (stdlib only) that spawns/stops/reorders up to a
configured number of code-server instances ("slots"), each a templated systemd
--user unit (airlock-code-server@N.service) bound to its own loopback port. The
tab-bar shell talks to this over the nginx gate's /api/ route.

It is loopback-only and re-checks the gate-verified identity on every request
(defense-in-depth): the nginx gate already 403s non-owners, and this refuses any
request whose identity header is not in the allow list.

Config (all from the environment, set by the systemd unit):
  AIRLOCK_CODE_SERVER_MANAGER_HOST  listen host (must be 127.0.0.1; default so)
  AIRLOCK_CODE_SERVER_MANAGER_PORT  listen port                    (default 18810)
  AIRLOCK_CODE_SERVER_SLOTS         max concurrent slots           (default 4)
  AIRLOCK_CODE_SERVER_BACKEND_PORT  slot 1's port; slot N = base+N-1 (default 18811)
  AIRLOCK_CODE_SERVER_ALLOW         comma-separated allowed logins (fail-closed)
  AIRLOCK_IDENTITY_HEADER           identity header to read (no hardcoded default)
"""

import asyncio
import json
import os
import sys
import time

LISTEN_HOST = os.environ.get("AIRLOCK_CODE_SERVER_MANAGER_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("AIRLOCK_CODE_SERVER_MANAGER_PORT", "18810"))
if LISTEN_HOST != "127.0.0.1":
    sys.exit("[FATAL] AIRLOCK_CODE_SERVER_MANAGER_HOST must be 127.0.0.1")

MAX_SLOTS = int(os.environ.get("AIRLOCK_CODE_SERVER_SLOTS", "4"))
if MAX_SLOTS < 1:
    sys.exit("[FATAL] AIRLOCK_CODE_SERVER_SLOTS must be >= 1")

# Slot 1 lives on BACKEND_PORT; slot N lives on BACKEND_PORT + N - 1. This must
# match the systemd unit template and the nginx /s/N/ routing.
BACKEND_PORT = int(os.environ.get("AIRLOCK_CODE_SERVER_BACKEND_PORT", "18811"))

ALLOW = [x.strip() for x in os.environ.get("AIRLOCK_CODE_SERVER_ALLOW", "").split(",") if x.strip()]

# The identity header is operator-configured (never a hardcoded provider header).
# Fail closed if it is missing — an empty header name would let every request
# read the wrong (or no) identity.
IDENT_HEADER = os.environ.get("AIRLOCK_IDENTITY_HEADER", "").strip()
if not IDENT_HEADER:
    sys.exit("[FATAL] AIRLOCK_IDENTITY_HEADER not set (run via the airlock env)")
IDENT_HEADER_LC = IDENT_HEADER.lower()

UNIT_TEMPLATE = "airlock-code-server@%d.service"
TABS_PATH = os.path.expanduser("~/.config/airlock-code-server/tabs.json")
VALID_SLOTS = {str(n) for n in range(1, MAX_SLOTS + 1)}

_lock = asyncio.Lock()
ops: dict[int, str] = {}


def slot_port(n: int) -> int:
    return BACKEND_PORT + n - 1


def slot_unit(n: int) -> str:
    return UNIT_TEMPLATE % n


def _resp(status, body, ctype=b"application/json; charset=utf-8", cache=b"no-store, must-revalidate"):
    return (
        b"HTTP/1.1 " + status + b"\r\nContent-Type: " + ctype
        + b"\r\nContent-Length: " + str(len(body)).encode()
        + b"\r\nCache-Control: " + cache + b"\r\nConnection: close\r\n\r\n" + body
    )


async def _send_json(cw, status, payload):
    cw.write(_resp(status, json.dumps(payload).encode(), b"application/json; charset=utf-8"))
    await cw.drain()


async def _read_head(reader):
    buf = b""
    while b"\r\n\r\n" not in buf:
        if len(buf) > 64 * 1024:
            return None, b""
        chunk = await reader.read(4096)
        if not chunk:
            return None, b""
        buf += chunk
    head, _, leftover = buf.partition(b"\r\n\r\n")
    return head + b"\r\n\r\n", leftover


def _parse_headers(head):
    headers = {}
    for line in head.split(b"\r\n")[1:]:
        if line and b":" in line:
            k, _, v = line.partition(b":")
            headers[k.strip().lower()] = v.strip()
    return headers


def _request_path(head):
    try:
        target = head.split(b"\r\n", 1)[0].split(b" ")[1]
    except IndexError:
        return b"/"
    return target.split(b"?", 1)[0]


async def _read_body(reader, headers, leftover, limit=64 * 1024):
    clen = headers.get(b"content-length")
    if clen is None:
        return b""
    try:
        clen = int(clen)
    except ValueError:
        return None
    if clen < 0 or clen > limit:
        return None
    buf = bytearray(leftover)
    while len(buf) < clen:
        chunk = await reader.read(min(65536, clen - len(buf)))
        if not chunk:
            break
        buf += chunk
    if len(buf) < clen:
        return None
    return bytes(buf[:clen])


async def _read_json_body(reader, headers, leftover, limit=64 * 1024):
    body = await _read_body(reader, headers, leftover, limit=limit)
    if body is None or len(body) > limit:
        return None
    if not body:
        return {}
    try:
        obj = json.loads(body.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None
    return obj if isinstance(obj, dict) else None


async def _systemctl(*args):
    proc = await asyncio.create_subprocess_exec(
        "systemctl",
        "--user",
        *args,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    out, _ = await proc.communicate()
    return proc.returncode, out.decode("utf-8", "replace")


def _tabs_default():
    return {"slots": {}, "order": [], "hidden": [], "rev": 0}


def _normalize_tabs(d):
    if not isinstance(d, dict):
        return _tabs_default()
    out = _tabs_default()
    slots = d.get("slots")
    if isinstance(slots, dict):
        out["slots"] = {str(k): v for k, v in slots.items() if isinstance(v, dict) and str(k) in VALID_SLOTS}
    order = d.get("order")
    if isinstance(order, list):
        out["order"] = [str(x) for x in order if str(x) in VALID_SLOTS]
    hidden = d.get("hidden")
    if isinstance(hidden, list):
        out["hidden"] = [str(x) for x in hidden if str(x) in VALID_SLOTS]
    rev = d.get("rev")
    if isinstance(rev, int) and rev >= 0:
        out["rev"] = rev
    return out


def _load_tabs():
    if not os.path.exists(TABS_PATH):
        return _tabs_default()
    try:
        with open(TABS_PATH, "r", encoding="utf-8") as f:
            return _normalize_tabs(json.load(f))
    except Exception as e:
        try:
            st = os.stat(TABS_PATH)
            suffix = str(int(st.st_mtime))
            os.replace(TABS_PATH, TABS_PATH + ".corrupt." + suffix)
        except Exception:
            pass
        print(f"[warn] tabs.json invalid, reset to default: {e}", file=sys.stderr)
        return _tabs_default()


def _save_tabs(d):
    path_dir = os.path.dirname(TABS_PATH)
    os.makedirs(path_dir, exist_ok=True)
    tmp = TABS_PATH + ".tmp." + str(os.getpid()) + "." + str(int(time.time()))
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(d, f, ensure_ascii=False, separators=(",", ":"))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, TABS_PATH)


async def _slot_status(n):
    rc, out = await _systemctl(
        "show",
        slot_unit(n),
        "-p",
        "LoadState",
        "-p",
        "ActiveState",
        "-p",
        "SubState",
        "-p",
        "Result",
    )
    data = {"loadState": "", "activeState": "", "subState": "", "result": ""}
    if rc == 0 or out:
        for line in out.splitlines():
            if "=" not in line:
                continue
            k, _, v = line.partition("=")
            if k == "LoadState":
                data["loadState"] = v
            elif k == "ActiveState":
                data["activeState"] = v
            elif k == "SubState":
                data["subState"] = v
            elif k == "Result":
                data["result"] = v
    active = data["activeState"]
    load = data["loadState"]
    if active == "active":
        state = "running"
    elif active == "activating":
        state = "activating"
    elif active == "failed":
        state = "failed"
    elif active in {"inactive", "deactivating"} or load == "not-found":
        state = "stopped"
    elif rc != 0 or not active:
        state = "unknown"        # systemctl/bus error — do NOT mistake for stopped (excluded from spawn)
    else:
        state = "stopped"
    return {
        "slot": n,
        "port": slot_port(n),
        "unit": slot_unit(n),
        "url": f"/s/{n}/",
        "state": state,
        "systemd": data,
    }


def _require_slot(d):
    try:
        slot = int(d.get("slot"))
    except Exception:
        return None
    if slot < 1 or slot > MAX_SLOTS:
        return None
    return slot


def _sanitize_name(name):
    if not isinstance(name, str):
        return None
    out = "".join(ch for ch in name if ord(ch) >= 32 and ord(ch) != 127)
    return out[:64]


def _validate_color(color):
    if not isinstance(color, str) or len(color) != 7 or not color.startswith("#"):
        return None
    hexpart = color[1:]
    if any(ch not in "0123456789abcdefABCDEF" for ch in hexpart):
        return None
    return "#" + hexpart.lower()


def _apply_prefs_patch(tabs, obj):
    op = obj.get("op")
    if op == "setName":
        slot = _require_slot(obj)
        if slot is None:
            return None, (400, {"ok": False, "error": "invalid slot"})
        name = _sanitize_name(obj.get("name"))
        if name is None:
            return None, (400, {"ok": False, "error": "invalid name"})
        tabs["slots"].setdefault(str(slot), {})["name"] = name
    elif op == "setColor":
        slot = _require_slot(obj)
        if slot is None:
            return None, (400, {"ok": False, "error": "invalid slot"})
        color = _validate_color(obj.get("color"))
        if color is None:
            return None, (400, {"ok": False, "error": "invalid color"})
        tabs["slots"].setdefault(str(slot), {})["color"] = color
    elif op == "setHidden":
        slot = _require_slot(obj)
        if slot is None:
            return None, (400, {"ok": False, "error": "invalid slot"})
        hidden = obj.get("hidden")
        if not isinstance(hidden, bool):
            return None, (400, {"ok": False, "error": "invalid hidden"})
        key = str(slot)
        hidden_list = [x for x in tabs["hidden"] if x != key]
        if hidden:
            hidden_list.append(key)
        tabs["hidden"] = hidden_list
    elif op == "reorder":
        order = obj.get("order")
        if not isinstance(order, list):
            return None, (400, {"ok": False, "error": "invalid order"})
        seen = set()
        out = []
        for item in order:
            if not isinstance(item, int) or item < 1 or item > MAX_SLOTS or item in seen:
                return None, (400, {"ok": False, "error": "invalid order"})
            seen.add(item)
            out.append(str(item))
        tabs["order"] = out
    else:
        return None, (400, {"ok": False, "error": "unknown op"})
    return tabs, None


async def _spawn_slot():
    async with _lock:
        ops_snapshot = dict(ops)
        chosen = None
        for n in range(1, MAX_SLOTS + 1):
            if n in ops_snapshot:
                continue
            status = await _slot_status(n)
            # failed slots are also candidates — reset-failed before start auto-recovers
            # them (keeps full capacity). unknown (bus error) is excluded.
            if status["state"] in ("stopped", "failed"):
                ops[n] = "spawning"
                chosen = n
                break
        if chosen is None:
            return None
    try:
        await _systemctl("reset-failed", slot_unit(chosen))   # clear failed (harmless otherwise)
        rc, out = await _systemctl("start", slot_unit(chosen))
        if rc != 0:
            print(f"[error] spawn slot {chosen} rc={rc}: {out.strip()}", file=sys.stderr)
            raise RuntimeError(f"systemctl start failed (slot {chosen})")
    finally:
        async with _lock:
            ops.pop(chosen, None)
    return chosen


async def _kill_slot(slot):
    async with _lock:
        if slot in ops:
            return False, "slot busy"
        ops[slot] = "stopping"
    try:
        rc, out = await _systemctl("stop", slot_unit(slot))
        await _systemctl("reset-failed", slot_unit(slot))   # tidy (rc ignored)
        if rc != 0:
            print(f"[error] kill slot {slot} rc={rc}: {out.strip()}", file=sys.stderr)
            raise RuntimeError(f"systemctl stop failed (slot {slot})")
    finally:
        async with _lock:
            ops.pop(slot, None)
    return True, ""


async def handle(cr, cw):
    try:
        head, leftover = await _read_head(cr)
        if head is None:
            return
        headers = _parse_headers(head)
        login = headers.get(IDENT_HEADER_LC.encode(), b"").decode("latin1").strip()
        if login not in ALLOW:
            await _send_json(cw, b"403 Forbidden", {"ok": False, "error": "forbidden"})
            return

        method = head.split(b" ", 1)[0]
        path = _request_path(head)

        if method == b"GET" and path == b"/api/list":
            async with _lock:
                ops_snapshot = dict(ops)
            tabs = _load_tabs()
            slots = []
            for n in range(1, MAX_SLOTS + 1):
                status = await _slot_status(n)
                # state = systemd truth; op (spawning|stopping|None) overlaid so the
                # frontend can show a pending spinner while an op is in flight.
                status["op"] = ops_snapshot.get(n)
                slots.append(status)
            await _send_json(cw, b"200 OK", {"ok": True, "maxSlots": MAX_SLOTS, "tabs": tabs, "slots": slots})
            return

        if method == b"POST" and path == b"/api/spawn":
            obj = await _read_json_body(cr, headers, leftover)
            if obj is None:
                clen = headers.get(b"content-length", b"0")
                if clen == b"0":
                    obj = {}
                else:
                    await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "invalid json"})
                    return
            if obj:
                await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "unexpected body"})
                return
            slot = await _spawn_slot()
            if slot is None:
                await _send_json(cw, b"409 Conflict", {"ok": False, "error": "max slots reached"})
                return
            await _send_json(
                cw,
                b"200 OK",
                {"ok": True, "slot": slot, "port": slot_port(slot), "url": f"/s/{slot}/", "state": "activating"},
            )
            return

        if method == b"POST" and path == b"/api/kill":
            obj = await _read_json_body(cr, headers, leftover)
            if obj is None:
                await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "invalid json"})
                return
            slot = _require_slot(obj)
            if slot is None:
                await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "invalid slot"})
                return
            ok, err = await _kill_slot(slot)
            if not ok:
                await _send_json(cw, b"409 Conflict", {"ok": False, "error": err})
                return
            await _send_json(cw, b"200 OK", {"ok": True, "slot": slot, "state": "stopped"})
            return

        if method == b"POST" and path == b"/api/prefs":
            obj = await _read_json_body(cr, headers, leftover)
            if obj is None:
                await _send_json(cw, b"400 Bad Request", {"ok": False, "error": "invalid json"})
                return
            async with _lock:
                tabs = _load_tabs()
                tabs, err = _apply_prefs_patch(tabs, obj)
                if err is not None:
                    code, payload = err
                    await _send_json(cw, f"{code} Bad Request".encode(), payload)
                    return
                tabs["rev"] = int(tabs.get("rev", 0)) + 1
                _save_tabs(tabs)
            await _send_json(cw, b"200 OK", {"ok": True, "tabs": tabs, "rev": tabs["rev"]})
            return

        await _send_json(cw, b"404 Not Found", {"ok": False, "error": "not found"})
    except Exception as e:
        print(f"[error] request handler: {e!r}", file=sys.stderr)
        try:
            await _send_json(cw, b"500 Internal Server Error", {"ok": False, "error": "internal error"})
        except Exception:
            pass


async def main():
    server = await asyncio.start_server(handle, LISTEN_HOST, LISTEN_PORT)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
