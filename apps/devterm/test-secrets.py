#!/usr/bin/env python3
"""Offline contract checks for the platform secret drop and devterm's thin relay."""

import asyncio
import concurrent.futures
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
CLI = os.path.join(ROOT, "bin", "airlock-secret")
TMP = tempfile.mkdtemp(prefix="airlock-secret-test-")
HOME = os.path.join(TMP, "home")
os.mkdir(HOME)
ENV = dict(os.environ, HOME=HOME, AIRLOCK_SECRET_TTL_SEC="4")
STORE = os.path.join(HOME, ".devterm-secrets")

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

    # Load devterm only after its D5 path is present. The store remains a child-process
    # concern; devterm sees and returns only the platform's validated metadata.
    os.environ["AIRLOCK_OWNER"] = "owner@example.invalid"
    os.environ["DEVTERM_SECRET_BIN"] = CLI
    os.environ["HOME"] = HOME
    os.environ["AIRLOCK_SECRET_TTL_SEC"] = "4"
    spec = importlib.util.spec_from_file_location(
        "gate", os.path.join(ROOT, "apps/devterm/backend/devterm-gate.py"))
    gate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gate)

    relay_value = os.urandom(28).hex().encode("ascii")
    relay_put = asyncio.run(gate._secret_cli("put", name="relay", raw=relay_value))
    relay_list = asyncio.run(gate._secret_cli("list"))
    check("devterm relays through the D5 CLI and returns only validated metadata",
          relay_put.get("ok") is True and "value" not in relay_put
          and relay_list.get("ok") is True and all("value" not in item for item in relay_list["secrets"])
          and relay_value not in json.dumps(relay_put).encode() + json.dumps(relay_list).encode())
    check("relay strips an unexpected CLI value field instead of reflecting it",
          gate._secret_payload("put", {
              "ok": True, "name": "relay", "path": "x", "ttl_sec": 4,
              "remain_sec": 4, "value": "unexpected",
          }, expected_name="relay") == {
              "ok": True, "name": "relay", "path": "x", "ttl_sec": 4, "remain_sec": 4,
          })

    headers = lambda **kw: {key.encode(): val for key, val in kw.items()}
    check("devterm keeps its HTTP same-origin guard",
          gate._secret_origin_ok({})
          and gate._secret_origin_ok(headers(
              origin=b"https://box.example.invalid:8443", host=b"box.example.invalid:8443"))
          and not gate._secret_origin_ok(headers(
              origin=b"https://other.example.invalid", host=b"box.example.invalid:8443")))

    async def guard_controls():
        calls = []
        sent = []
        original_cli, original_send = gate._secret_cli, gate._send_json

        async def no_cli(*args, **kwargs):
            calls.append((args, kwargs))
            return {"ok": True}

        async def capture(_cw, status, body, **_kwargs):
            sent.append((status, body))

        gate._secret_cli, gate._send_json = no_cli, capture
        try:
            await gate._serve_secret_put(None, {b"content-type": b"text/plain"}, b"", None)
            await gate._serve_secret_put(None, {
                b"content-type": b"application/json", b"origin": b"https://other.invalid",
                b"host": b"box.invalid",
            }, b"", None)
            await gate._serve_secret_put(None, {
                b"content-type": b"application/json",
                b"content-length": str(gate.SECRET_BODY_MAX + 1).encode(),
            }, b"", None)
        finally:
            gate._secret_cli, gate._send_json = original_cli, original_send
        return calls, sent

    guard_calls, guard_sent = asyncio.run(guard_controls())
    check("Content-Type, origin and body-cap refusals happen before CLI spawn",
          guard_calls == [] and [status for status, _ in guard_sent] == [
              b"415 Unsupported Media Type", b"403 Forbidden", b"413 Payload Too Large"])

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
