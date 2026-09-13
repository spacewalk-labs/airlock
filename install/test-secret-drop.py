#!/usr/bin/env python3
"""Offline contract checks for the platform secret drop: CLI, HTTP boundary, devterm adapter.

Three layers, all against the checkout and scratch processes — no installed unit, no live
store, no devterm process:

  1. bin/airlock-secret — the store contract (stdin-only values, modes, atomic replace,
     symlink refusal, serialized cap, TTL sweep, metadata-only stdout).
  2. bin/airlock-accounts-api — the platform HTTP boundary for /secret-put|list|del
     (docs/tasks/active/platform-secret-drop.md AC-PSD-1/2): real HTTP against a scratch
     server, refusals before any CLI spawn (a spy CLI counts spawns), output rebuilt from
     an allowlist, and a runtime-random sentinel value that must never appear in any
     response, service log, or CLI output.
  3. devterm is an adapter only (AC-PSD-3): no secret handler/env/asset in the package,
     and its rendered nginx proxies exactly the three routes to the platform port under
     the owner guard.
"""

import concurrent.futures
import http.client
import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CLI = os.path.join(ROOT, "bin", "airlock-secret")
TMP = tempfile.mkdtemp(prefix="airlock-secret-test-")
HOME = os.path.join(TMP, "home")
os.mkdir(HOME)
ENV = dict(os.environ, HOME=HOME, AIRLOCK_SECRET_TTL_SEC="4")
STORE = os.path.join(HOME, ".devterm-secrets")

API = os.path.join(ROOT, "bin", "airlock-accounts-api")
# The value stand-in for the HTTP layer. Random per run, compared in memory, never printed.
SENTINEL = "sd-" + os.urandom(24).hex()
RESPONSES = []          # every HTTP body this run received, for the non-exposure sweep
SERVER_LOGS = []


def free_port():
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


class Surface:
    """A scratch bin/airlock-accounts-api on loopback. No panel, no account CLI."""

    def __init__(self, secret_bin, home):
        self.port = free_port()
        self.origin = "http://127.0.0.1:%d" % self.port
        log = os.path.join(TMP, "surface-%d.log" % self.port)
        SERVER_LOGS.append(log)
        env = dict(os.environ, HOME=home, AIRLOCK_SECRET_TTL_SEC="4",
                   AIRLOCK_HUB_ACCOUNTS_PORT=str(self.port),
                   AIRLOCK_STATE_DIR=os.path.join(TMP, "state-%d" % self.port),
                   AIRLOCK_ACCOUNTS_STATUS_BIN="", AIRLOCK_ACCOUNTS_BIN="",
                   AIRLOCK_ACCOUNTS_PANEL_DIR="", AIRLOCK_ACCOUNTS_PANEL_STYLE_DIR="")
        env.pop("AIRLOCK_SECRET_BIN", None)
        if secret_bin is not None:
            env["AIRLOCK_SECRET_BIN"] = secret_bin
        self.logf = open(log, "wb")
        self.proc = subprocess.Popen([sys.executable, API], env=env,
                                     stdout=self.logf, stderr=subprocess.STDOUT)
        for _ in range(100):
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=0.2).close()
                return
            except OSError:
                if self.proc.poll() is not None:
                    break
                time.sleep(0.05)
        raise RuntimeError("scratch account surface did not start")

    def request(self, method, path, body=None, ctype="application/json", origin="same"):
        headers = {}
        if ctype:
            headers["Content-Type"] = ctype
        if origin == "same":
            headers["Origin"] = self.origin
        elif origin:
            headers["Origin"] = origin
        data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=15)
        conn.request(method, path, body=data, headers=headers)
        resp = conn.getresponse()
        raw = resp.read()
        conn.close()
        RESPONSES.append(raw)
        try:
            return resp.status, json.loads(raw.decode("utf-8"))
        except ValueError:
            return resp.status, None

    def raw_oversize(self, path):
        """Declare a body over the cap and send none: the refusal must not wait for it."""
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as sock:
            sock.sendall(("POST %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Type: application/json\r\n"
                          "Content-Length: %d\r\n\r\n" % (path, self.port, 96 * 1024 + 1)).encode())
            data = b""
            while True:
                try:
                    chunk = sock.recv(4096)
                except socket.timeout:
                    break           # the server waited for the body: that IS the defect
                if not chunk:
                    break
                data += chunk
        RESPONSES.append(data)
        return int(data.split(b" ", 2)[1]) if data.startswith(b"HTTP/") else 0

    def stop(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
        self.logf.close()


SPY = r"""#!/usr/bin/env python3
import json, os, sys
with open(os.environ["SPY_LOG"], "a") as log:
    log.write(" ".join(sys.argv[1:3]) + "\n")
cmd = sys.argv[1]
if cmd == "put":
    got = sys.stdin.buffer.read().decode("utf-8", "replace")
    # A regressed CLI that reflects the value and adds fields: the relay must drop both.
    print(json.dumps({"ok": True, "name": sys.argv[3], "path": "~/.devterm-secrets/x.txt",
                      "ttl_sec": 4, "remain_sec": 4, "value": got, "extra": "LEAK-MARK"}))
elif cmd == "list":
    print(json.dumps({"ok": True, "ttl_sec": 4, "secrets": [
        {"name": "a", "path": "p", "bytes": 1, "remain_sec": 3, "value": "LEAK-MARK"}]}))
else:
    print(json.dumps({"ok": False, "error": "unlink /home/owner/.devterm-secrets/a.txt: EACCES"}))
    sys.exit(1)
"""

GATE = os.path.join(ROOT, "apps", "devterm", "backend", "devterm-gate.py")
DEVTERM_INSTALL = os.path.join(ROOT, "apps", "devterm", "install.sh")
# What would mean the relay came back: a handler, the CLI hand-in, or the CLI itself.
GATE_FORBIDDEN = ('b"/secret-put"', 'b"/secret-list"', 'b"/secret-del"', "DEVTERM_SECRET_BIN",
                  "_secret_cli", "airlock-secret", "_serve_secret_")


def devterm_secret_code(text):
    return [needle for needle in GATE_FORBIDDEN if needle in text]


def render_devterm(*args):
    script = ('. "$1/install/lib.sh"; . "$1/gate/nginx-lib.sh"; . "$1/apps/devterm/render.sh"; '
              'shift; render_devterm_nginx "$@"')
    env = dict(os.environ, AIRLOCK_IDENTITY_HEADER="Tailscale-User-Login",
               AIRLOCK_OWNER="owner@example.invalid")
    return subprocess.run(["bash", "-c", script, "render", ROOT, *args], env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)


def location_blocks(text, prefix):
    blocks = {}
    for part in text.split("    location = ")[1:]:
        head, _, rest = part.partition(" {")
        if head.startswith(prefix):
            blocks[head] = rest.split("\n    }", 1)[0]
    return blocks


fails = []
checks = 0


def check(name, condition):
    global checks
    checks += 1
    print(("PASS " if condition else "FAIL ") + name)
    if not condition:
        fails.append(name)


def run(*args, stdin=None, env=None):
    return subprocess.run(
        [sys.executable, CLI, *args], input=stdin, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=env or ENV, timeout=10,
    )


def payload(result):
    try:
        return json.loads(result.stdout.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None


try:
    # An idle/unused platform has no store yet. Read and sweep do not create one merely
    # because the timer ticked.
    listed = run("list")
    swept = run("sweep")
    check("absent store lists and sweeps without being created",
          listed.returncode == 0 and payload(listed) == {"ok": True, "secrets": [], "ttl_sec": 4}
          and swept.returncode == 0 and payload(swept) == {"ok": True, "removed": 0}
          and not os.path.exists(STORE))

    value = os.urandom(32).hex().encode("ascii")
    put = run("put", "--", "GH_TOKEN", stdin=b" \r\n" + value + b"\r\n ")
    put_json = payload(put)
    target = os.path.join(STORE, "GH_TOKEN.txt")
    check("put accepts a value on stdin and returns metadata only",
          put.returncode == 0 and put_json == {
              "ok": True, "name": "GH_TOKEN", "path": "~/.devterm-secrets/GH_TOKEN.txt",
              "ttl_sec": 4, "remain_sec": put_json.get("remain_sec") if put_json else None,
          } and type(put_json.get("remain_sec")) is int
          and value not in put.stdout + put.stderr)
    check("normalization and restrictive modes belong to the platform CLI",
          open(target, "rb").read() == value + b"\n"
          and stat.S_IMODE(os.stat(target).st_mode) == 0o600
          and stat.S_IMODE(os.stat(STORE).st_mode) == 0o700)
    check("atomic put leaves no temporary file",
          not any(name.endswith(".tmp") for name in os.listdir(STORE)))

    replacement = os.urandom(32).hex().encode("ascii")
    rewritten = run("put", "--", "GH_TOKEN", stdin=replacement)
    check("atomic replace preserves mode and replaces the inode contents",
          rewritten.returncode == 0 and open(target, "rb").read() == replacement + b"\n"
          and stat.S_IMODE(os.stat(target).st_mode) == 0o600
          and replacement not in rewritten.stdout + rewritten.stderr)

    listed = run("list")
    listed_json = payload(listed)
    check("list is sorted bounded metadata and never includes a value field",
          listed.returncode == 0 and listed_json.get("ok") is True
          and listed_json.get("ttl_sec") == 4
          and listed_json.get("secrets") == [{
              "name": "GH_TOKEN", "path": "~/.devterm-secrets/GH_TOKEN.txt",
              "bytes": len(replacement) + 1,
              "remain_sec": listed_json["secrets"][0]["remain_sec"],
          }]
          and set(listed_json["secrets"][0]) == {"name", "path", "bytes", "remain_sec"}
          and replacement not in listed.stdout + listed.stderr)

    missing_separator = run("put", "-leading", stdin=value)
    missing_created = os.path.exists(os.path.join(STORE, "-leading.txt"))
    leading = run("put", "--", "-leading", stdin=value)
    check("the mandatory separator refuses ambiguity and permits an option-like name",
          missing_separator.returncode == 2 and not missing_created
          and leading.returncode == 0 and os.path.isfile(os.path.join(STORE, "-leading.txt")))

    invalid = run("put", "--", "../escape", stdin=value)
    check("name validation rejects traversal without echoing stdin",
          invalid.returncode != 0 and payload(invalid).get("error") == "invalid name"
          and value not in invalid.stdout + invalid.stderr
          and not os.path.exists(os.path.join(HOME, "escape.txt")))

    # Refuse both a store-directory symlink and a final-name symlink. The target bytes are
    # generated and compared in memory; no credential-like fixture is printed.
    victim = os.path.join(TMP, "victim")
    victim_bytes = os.urandom(24)
    with open(victim, "wb") as stream:
        stream.write(victim_bytes)
    final_link = os.path.join(STORE, "linked.txt")
    os.symlink(victim, final_link)
    refused_final = run("put", "--", "linked", stdin=value)
    check("a final-name symlink is refused and its target is untouched",
          refused_final.returncode != 0 and open(victim, "rb").read() == victim_bytes
          and os.path.islink(final_link) and value not in refused_final.stdout + refused_final.stderr)
    os.unlink(final_link)

    linked_home = os.path.join(TMP, "linked-home")
    os.mkdir(linked_home)
    os.symlink(TMP, os.path.join(linked_home, ".devterm-secrets"))
    linked_env = dict(ENV, HOME=linked_home)
    refused_dir = run("put", "--", "safe", stdin=value, env=linked_env)
    check("a symlinked store directory is refused without walking into it",
          refused_dir.returncode != 0 and not os.path.exists(os.path.join(TMP, "safe.txt"))
          and value not in refused_dir.stdout + refused_dir.stderr)

    # Fill 63 live slots, then release 16 callers together. Exactly one may commit. This
    # is the control for the old listdir -> O_EXCL TOCTOU; a per-process check without the
    # shared flock admits more than one under this barrier.
    for filename in os.listdir(STORE):
        if filename.endswith(".txt") and not os.path.islink(os.path.join(STORE, filename)):
            os.unlink(os.path.join(STORE, filename))
    for index in range(63):
        path = os.path.join(STORE, "base%02d.txt" % index)
        with open(path, "wb") as stream:
            stream.write(b"x\n")
        os.chmod(path, 0o600)
    barrier = None

    def contender(index):
        barrier.wait()
        return run("put", "--", "race%02d" % index,
                   stdin=os.urandom(16).hex().encode("ascii")).returncode

    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        barrier = __import__("threading").Barrier(16)
        results = list(pool.map(contender, range(16)))
    live = [name for name in os.listdir(STORE) if name.endswith(".txt")
            and os.path.isfile(os.path.join(STORE, name))]
    check("the file-count cap is serialized across concurrent relays",
          results.count(0) == 1 and len(live) == 64)

    for filename in live:
        os.unlink(os.path.join(STORE, filename))
    expired_value = os.urandom(20).hex().encode("ascii")
    fresh_value = os.urandom(20).hex().encode("ascii")
    check("expiry control setup stores both candidates",
          run("put", "--", "expired", stdin=expired_value).returncode == 0
          and run("put", "--", "fresh", stdin=fresh_value).returncode == 0)
    expired_path = os.path.join(STORE, "expired.txt")
    fresh_path = os.path.join(STORE, "fresh.txt")
    old = time.time() - 5
    os.utime(expired_path, (old, old))
    sweep = run("sweep")
    check("sweep deletes an expired secret and spares a fresh one",
          sweep.returncode == 0 and not os.path.exists(expired_path)
          and os.path.isfile(fresh_path) and open(fresh_path, "rb").read() == fresh_value + b"\n")

    stray = os.path.join(STORE, ".orphan.tmp")
    foreign = os.path.join(STORE, "not a secret.txt")
    open(stray, "wb").close()
    open(foreign, "wb").close()
    os.utime(foreign, (0, 0))
    run("sweep")
    check("sweep removes orphan temps but leaves files outside its name contract",
          not os.path.exists(stray) and os.path.exists(foreign))

    deleted = run("del", "--", "fresh")
    deleted_again = run("del", "--", "fresh")
    check("delete is idempotent and metadata-only",
          deleted.returncode == 0 and deleted_again.returncode == 0
          and payload(deleted) == {"ok": True, "name": "fresh"}
          and not os.path.exists(fresh_path))

    # ---- platform HTTP boundary (bin/airlock-accounts-api) -------------------------
    for filename in os.listdir(STORE):
        path = os.path.join(STORE, filename)
        if filename.endswith(".txt") and os.path.isfile(path) and not os.path.islink(path):
            os.unlink(path)
    surface = Surface(CLI, HOME)
    try:
        status, body = surface.request("POST", "/secret-put", {"name": "HTTP_TOKEN", "value": SENTINEL})
        http_target = os.path.join(STORE, "HTTP_TOKEN.txt")
        check("platform put stores through the CLI and answers metadata only",
              status == 200 and isinstance(body, dict)
              and set(body) == {"ok", "name", "path", "ttl_sec", "remain_sec"}
              and body["path"] == "~/.devterm-secrets/HTTP_TOKEN.txt"
              and open(http_target, "rb").read() == SENTINEL.encode() + b"\n"
              and stat.S_IMODE(os.stat(http_target).st_mode) == 0o600)
        status, body = surface.request("GET", "/secret-list", ctype=None)
        check("platform list answers bounded metadata for the stored name",
              status == 200 and body.get("ok") is True
              and any(item == {"name": "HTTP_TOKEN", "path": "~/.devterm-secrets/HTTP_TOKEN.txt",
                               "bytes": len(SENTINEL) + 1, "remain_sec": item.get("remain_sec")}
                      for item in body.get("secrets", [])))
        status, body = surface.request("POST", "/secret-put", {"name": "../escape", "value": SENTINEL})
        check("an invalid name is 400 with the fixed error, value not echoed",
              status == 400 and body == {"ok": False, "error": "invalid name"})
        status, body = surface.request("POST", "/secret-put",
                                       {"name": "BIG", "value": SENTINEL + "x" * 70000})
        check("a value over the store cap is 413 from the CLI's verdict",
              status == 413 and body == {"ok": False, "error": "value too large"})
        status, body = surface.request("POST", "/secret-put", b'{"name": "SURR", "value": "\\ud800"}')
        check("an unencodable value is refused before the CLI", status == 400
              and body == {"ok": False, "error": "value not encodable"})
        status, body = surface.request("POST", "/secret-put", None)
        check("an empty body is refused as a missing name", status == 400
              and body == {"ok": False, "error": "invalid name"})
        status, body = surface.request("POST", "/secret-del", {"name": "HTTP_TOKEN"})
        again, _ = surface.request("POST", "/secret-del", {"name": "HTTP_TOKEN"})
        check("platform delete is idempotent and removes the file",
              status == 200 and body == {"ok": True, "name": "HTTP_TOKEN"} and again == 200
              and not os.path.exists(http_target))
        status, body = surface.request("GET", "/secret-list?x=1", ctype=None)
        check("a query string does not open a second route shape", status == 200 and body.get("ok") is True)
    finally:
        surface.stop()

    spy = os.path.join(TMP, "spy-secret")
    spy_log = os.path.join(TMP, "spy.log")
    with open(spy, "w") as stream:
        stream.write(SPY)
    os.chmod(spy, 0o700)
    open(spy_log, "w").close()
    os.environ["SPY_LOG"] = spy_log
    surface = Surface(spy, HOME)
    try:
        refusals = [
            surface.request("POST", "/secret-put", {"name": "A", "value": SENTINEL}, ctype="text/plain")[0],
            surface.request("POST", "/secret-put", {"name": "A", "value": SENTINEL},
                            origin="https://evil.example.invalid")[0],
            surface.request("GET", "/secret-list", ctype=None, origin="https://evil.example.invalid")[0],
            surface.request("POST", "/secret-del", {"name": "A"}, origin="https://evil.example.invalid")[0],
            surface.request("POST", "/secret-del", {"name": "A"}, ctype="text/plain")[0],
            surface.raw_oversize("/secret-put"),
        ]
        check("Content-Type, origin and body-cap refusals answer 415/403/413",
              refusals == [415, 403, 403, 403, 415, 413])
        check("no refusal spawned the CLI", open(spy_log).read() == "")
        status, body = surface.request("POST", "/secret-put", {"name": "SPY", "value": SENTINEL})
        check("an unexpected CLI value/extra field is dropped, not reflected",
              status == 200 and set(body) == {"ok", "name", "path", "ttl_sec", "remain_sec"}
              and "LEAK-MARK" not in json.dumps(body))
        status, body = surface.request("GET", "/secret-list", ctype=None)
        check("list items are rebuilt from the allowlist",
              status == 200 and body["secrets"] == [{"name": "a", "path": "p", "bytes": 1, "remain_sec": 3}])
        status, body = surface.request("POST", "/secret-del", {"name": "SPY"})
        check("an unlisted CLI error becomes the fixed failure, not the CLI's text",
              status == 500 and body == {"ok": False, "error": "secret operation failed"})
        check("the spy saw exactly the three accepted operations",
              open(spy_log).read().split("\n")[:-1] == ["put --", "list", "del --"])
    finally:
        surface.stop()

    surface = Surface(None, HOME)
    try:
        put_status, put_body = surface.request("POST", "/secret-put", {"name": "NOBIN", "value": SENTINEL})
        list_status, list_body = surface.request("GET", "/secret-list", ctype=None)
        check("with no AIRLOCK_SECRET_BIN every secret route fails closed",
              put_status == 500 and put_body == {"ok": False, "error": "secret operation failed"}
              and list_status == 500 and not os.path.exists(os.path.join(STORE, "NOBIN.txt")))
    finally:
        surface.stop()

    leaked = [raw for raw in RESPONSES if SENTINEL.encode() in raw]
    logged = [log for log in SERVER_LOGS if SENTINEL.encode() in open(log, "rb").read()]
    check("AC-PSD-2: the sentinel value is in no HTTP response (%d checked)" % len(RESPONSES),
          len(RESPONSES) > 10 and not leaked)
    check("AC-PSD-2: the sentinel value is in no service log (%d checked)" % len(SERVER_LOGS),
          len(SERVER_LOGS) == 3 and not logged)

    # ---- devterm is an adapter only ----------------------------------------------------
    gate_text = open(GATE).read()
    install_text = open(DEVTERM_INSTALL).read()
    check("devterm's gate carries no secret handler, CLI or env", devterm_secret_code(gate_text) == [])
    check("the scan would catch a returning handler (control)",
          devterm_secret_code(gate_text + '\nelif path == b"/secret-put":\n') == ['b"/secret-put"'])
    check("devterm's installer hands in no secret CLI and ships no secret asset",
          "DEVTERM_SECRET_BIN" not in install_text and "web/secretdrop.js" not in install_text
          and not os.path.exists(os.path.join(ROOT, "apps", "devterm", "web", "secretdrop.js")))
    rendered = render_devterm("19911", "19913", "/opt/airlock/hub/assets/accounts", "", "19904")
    text = rendered.stdout.decode()
    routes = location_blocks(text, "/secret-")
    check("devterm's nginx proxies exactly the three routes to the platform port under the owner guard",
          rendered.returncode == 0 and sorted(routes) == ["/secret-del", "/secret-list", "/secret-put"]
          and all("if ($owner_ok = 0) { return 403; }" in block
                  and "proxy_pass http://127.0.0.1:19904;" in block
                  and "proxy_set_header Host $http_host;" in block for block in routes.values()))
    asset = location_blocks(text, "/secretdrop.js").get("/secretdrop.js", "")
    check("devterm's nginx aliases the platform secretdrop.js under the owner guard",
          "if ($owner_ok = 0) { return 403; }" in asset
          and "alias /opt/airlock/hub/assets/accounts/secretdrop.js;" in asset)
    bare = render_devterm("19911", "19913", "/opt/airlock/hub/assets/accounts")
    bad = render_devterm("19911", "19913", "/opt/airlock/hub/assets/accounts", "", "19904;evil")
    check("no platform port renders no secret route; a malformed port is refused",
          bare.returncode == 0 and location_blocks(bare.stdout.decode(), "/secret-") == {}
          and bad.returncode != 0)

    # One control spans success and error paths. The random stdin bytes are never printed
    # by this test; the assertion proves the CLI did not print them either.
    echo_probe = os.urandom(48).hex().encode("ascii")
    echo_success = run("put", "--", "echo-check", stdin=echo_probe)
    echo_error = run("put", "--", "../bad", stdin=echo_probe)
    check("CLI refuses to echo a value on success or error",
          echo_probe not in echo_success.stdout + echo_success.stderr
          and echo_probe not in echo_error.stdout + echo_error.stderr)
finally:
    shutil.rmtree(TMP, ignore_errors=True)

print("\nsecret-drop: %d passed, %d failed" % (checks - len(fails), len(fails)))
sys.exit(1 if fails else 0)
