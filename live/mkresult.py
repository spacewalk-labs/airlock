#!/usr/bin/env python3
"""live/mkresult.py — assemble the durable result record.

Its own file rather than a heredoc inside live/verify.sh, for the reason this
whole campaign exists: the inner document carries install and smoke output, which
is arbitrary text, and a shell heredoc that interpolates arbitrary text is how
three words disappeared from a rendered systemd unit on 2026-08-07. Everything
here arrives through argv and the environment, which cannot be re-scanned.

Called twice per run — once as soon as the container has finished, and again after
cleanup — because a run that dies during teardown must still have recorded what it
found.
"""
import datetime
import json
import os
import sys


def main() -> None:
    result_path, inner_path = sys.argv[1], sys.argv[2]
    raw = ""
    try:
        with open(inner_path) as fh:
            raw = fh.read()
        inner = json.loads(raw or "{}")
    except FileNotFoundError:
        inner = {"error": "the inner script produced no document at all"}
    except json.JSONDecodeError:
        # The inner script died before it could emit its document. Say so, and
        # keep what it did manage to write. "unparseable" is a finding; a blank
        # would read as "nothing went wrong".
        inner = {"error": "the inner document was not valid JSON",
                 "raw_tail": raw[-4000:]}

    cleanup = os.environ["CLEANUP_OK"]
    record = {
        "schema": 1,
        "run_id": os.environ["RUN_ID"],
        "commit": os.environ["SHA"],
        "started_utc": os.environ["STARTED"],
        "ended_utc": datetime.datetime.now(datetime.timezone.utc)
                             .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "host": os.environ["HOST"],
        "container": os.environ["NAME"],
        "image": os.environ["IMAGE"],
        "image_fingerprint": os.environ["IMAGE_FP"],
        "limits": {"memory": os.environ["MEM"],
                   "cpu": os.environ["CPU"],
                   "disk": os.environ["DISK"]},
        "dev_monitor_messages_requested": os.environ["DEVMON_MESSAGES"] == "true",
        "stage": os.environ["STAGE"],
        "inner_rc": int(os.environ["INNER_RC"]),
        # None, not False: "we never got as far as cleaning up" and "cleanup was
        # attempted and failed" are different facts, and the second one means a
        # container is still running somewhere.
        "cleanup_ok": None if cleanup == "null" else (cleanup == "true"),
        "inner": inner,
    }
    with open(result_path, "w") as fh:
        json.dump(record, fh, indent=2)
        fh.write("\n")


if __name__ == "__main__":
    main()
