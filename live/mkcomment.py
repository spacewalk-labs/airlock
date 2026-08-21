#!/usr/bin/env python3
"""live/mkcomment.py — turn a live-verification result into what gets published.

Two jobs, and the second one is the reason this is not a `jq` one-liner.

1. REDACT. The local record names the tailnet FQDN the container claimed and the
   ssh destination of the LXD host. Neither may leave this machine: airlock-work
   is mirrored to a public repository, `.github/workflows/ci.yml` refuses internal
   names, and a comment is not covered by that scan. So the FQDN is removed from
   every string, not just from the field that holds it — it appears inside smoke
   lines too, which is exactly the kind of second copy a field-level redaction
   misses.

2. STATE THE DENOMINATOR. bin/airlock-smoke does not count hub in its own summary
   (:42-62), so "9/10" and "10/10" are both correct depending on who is counting.
   The comment lists the items it is talking about rather than printing a fraction
   and hoping.

The exit code is reported as 0 / 1 / 3 and never as a boolean. 3 means every app
gate passed but this box could not check its own serve frontend; a reader who sees
only "passed" has been told something that is not true.
"""
import json
import os
import re
import sys

from verdict import MIN_ACCEPTANCE_PASSED


def redact(value, fqdn, host):
    """Remove the tailnet name and the ssh destination from anything stringy."""
    if isinstance(value, str):
        out = value
        if fqdn:
            out = out.replace(fqdn, "<container>")
            # The bare hostname turns up without the domain in nginx server names
            # and in unit Environment= lines. Plain replace, not a word-boundary
            # regex: install/test-regex-anchors.py refuses a pattern it cannot read
            # as a literal, and it is right to — it exists because twelve `^...$`
            # validators were accepting one character their character class forbids,
            # and it cannot check anchoring on a pattern built at runtime. The name
            # is `airlock-live-<timestamp>-<sha>` and is unique per run, so a
            # substring collision is not a thing that happens here.
            short = fqdn.split(".")[0]
            if short:
                out = out.replace(short, "<container>")
            # And the domain alone identifies the tailnet.
            domain = fqdn.split(".", 1)[1] if "." in fqdn else ""
            if domain:
                out = out.replace(domain, "<tailnet>")
        if host:
            out = out.replace(host, "<lxd-host>")
        return out
    if isinstance(value, list):
        return [redact(v, fqdn, host) for v in value]
    if isinstance(value, dict):
        return {k: redact(v, fqdn, host) for k, v in value.items()}
    return value


def main() -> None:
    record = json.load(open(sys.argv[1]))
    verdict = os.environ.get("VERDICT", "?")
    inner = record.get("inner") or {}
    fqdn = inner.get("fqdn") or ""
    host = record.get("host") or ""

    units = redact(inner.get("units_late") or [], fqdn, host)
    smoke_lines = redact(inner.get("smoke_lines") or [], fqdn, host)
    external_packages = redact(inner.get("external_packages") or [], fqdn, host)
    external_gate = redact(inner.get("external_gate_line_found", False), fqdn, host)
    acceptance = inner.get("acceptance")
    if not isinstance(acceptance, dict):
        acceptance = {}
    acceptance_rc = redact(acceptance.get("rc", "n/a"), fqdn, host)
    acceptance_passed = redact(acceptance.get("passed", "n/a"), fqdn, host)
    acceptance_failed = redact(acceptance.get("failed", "n/a"), fqdn, host)
    acceptance_log_tail = redact(acceptance.get("log_tail") or [], fqdn, host)
    if not isinstance(acceptance_log_tail, list):
        acceptance_log_tail = [acceptance_log_tail]
    longest_backtick_run = max(
        (
            len(run)
            for line in acceptance_log_tail
            for run in re.findall(r"`+", str(line))
        ),
        default=0,
    )
    acceptance_fence = "`" * max(3, longest_backtick_run + 1)
    external_package_text = (
        ", ".join(f"`{package_id}`" for package_id in external_packages)
        if isinstance(external_packages, list) and external_packages
        else "none"
    )
    acceptance_ok = (
        isinstance(acceptance, dict)
        and isinstance(acceptance.get("rc"), int)
        and not isinstance(acceptance.get("rc"), bool)
        and isinstance(acceptance.get("passed"), int)
        and not isinstance(acceptance.get("passed"), bool)
        and isinstance(acceptance.get("failed"), int)
        and not isinstance(acceptance.get("failed"), bool)
        and acceptance.get("rc") == 0
        and acceptance.get("failed") == 0
        and acceptance.get("passed") >= MIN_ACCEPTANCE_PASSED
    )
    def is_down(u):
        # A oneshot that has run and exited is `inactive/dead` and is healthy;
        # airlock-publish-cleanup.service is timer-driven and would otherwise be
        # reported as a failure on every run.
        if u.get("active") == "active":
            return False
        if (u.get("type") == "oneshot" and u.get("sub") == "dead"
                and (u.get("exec_status") or "0") == "0"):
            return False
        return True

    down = [u for u in units if is_down(u)]
    churn = [u for u in units if (u.get("restarts") or "0") not in ("0", "")]

    smoke_rc = inner.get("smoke_rc")
    smoke_meaning = {
        0: "every gate passed and ingress was checked from the box itself",
        1: "something failed",
        3: "every gate passed, but this box could not check its own serve frontend "
           "(ingress UNVERIFIED — see bin/airlock-smoke:9-19)",
    }.get(smoke_rc, "unknown")

    print(f"## live verification — `{record['run_id']}`")
    print()
    print(f"| | |")
    print(f"|---|---|")
    print(f"| commit | `{record['commit']}` |")
    print(f"| verdict | **{verdict}** |")
    print(f"| started / ended (UTC) | {record['started_utc']} → {record['ended_utc']} |")
    print(f"| image | `{record['image']}` @ `{record['image_fingerprint'] or 'unrecorded'}` |")
    print(f"| limits | {record['limits']['memory']} / {record['limits']['cpu']} cpu / {record['limits']['disk']} |")
    # Publishing happens after the record is written and before cleanup, so the
    # stage a reader sees is the one the run had when it decided to speak.
    print(f"| stage reached when posted | `{record['stage']}` |")
    print(f"| install exit | `{inner.get('install_rc', 'n/a')}` |")
    print(f"| smoke exit | `{smoke_rc}` — {smoke_meaning} |")
    print(f"| external packages | {external_package_text}; smoke gate found: `{external_gate}` |")
    print(f"| acceptance | rc `{acceptance_rc}`; "
          f"{acceptance_passed} passed / {acceptance_failed} failed |")
    print(f"| soak between unit readings | {inner.get('soak_seconds', 'n/a')}s |")
    cleanup = record.get("cleanup_ok")
    # None is "not attempted YET", not "failed". The comment is rendered before
    # cleanup on purpose — a run that dies during teardown must still publish what
    # it found — so at this point the container is normally still up and about to
    # be deleted. Saying "not reached" here read as a failure in the first real
    # published result, which is the opposite of the truth.
    print(f"| container deleted | {'yes' if cleanup else ('NO — still running' if cleanup is False else 'not yet — this is posted before teardown, on purpose')} |")
    print()

    print(f"### units ({len(units)} found)")
    print()
    if not units:
        print("None. An install that produces no units has not installed anything.")
    else:
        print("| unit | type | active | sub | restarts | exec status |")
        print("|---|---|---|---|---|---|")
        for u in units:
            print(f"| `{u.get('id')}` | {u.get('type')} | {u.get('active')} | {u.get('sub')} | "
                  f"{u.get('restarts')} | {u.get('exec_status')} |")
    print()
    if down:
        print(f"**{len(down)} unit(s) were not active at the second reading.**")
        print()
    if churn:
        print(f"**{len(churn)} unit(s) had restarted at least once** — the reading is taken "
              f"after a soak precisely because \"responds once, then crash-loops\" is what "
              f"paseo did on 2026-08-07.")
        print()

    print("### smoke, per app")
    print()
    if not smoke_lines:
        print("No per-app smoke lines. That is itself a finding — the smoke prints one per app.")
    else:
        print("```")
        for line in smoke_lines:
            print(line)
        print("```")
        print()
        print(f"{len(smoke_lines)} app line(s). Note that `bin/airlock-smoke` excludes hub "
              f"from its own summary count, so this list is the denominator, not a fraction "
              f"someone has to infer.")
    print()
    if not acceptance_ok:
        print("### acceptance stage failure details")
        print()
        print("The acceptance stage removes the nine on purpose, so a teardown failure there is not a failure of the nine apps' own gates.")
        print()
        print(acceptance_fence)
        for line in acceptance_log_tail:
            print(line)
        print(acceptance_fence)
        print()
    print("<sub>Posted by `live/verify.sh`. The tailnet name and the LXD host are redacted; "
          "the unredacted record stays on the box that ran it.</sub>")


if __name__ == "__main__":
    main()
