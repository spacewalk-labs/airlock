#!/usr/bin/env python3
"""Compatibility entry point for the account-surface ownership test.

The former differential oracle imported DevTerm's account helpers and compared them
with the platform copy. Phase 4 deliberately removes those helpers, so parity now means
that the retired DevTerm routes are absent/404 while the platform dispatches the same
route set. Keep this filename while CI and downstream callers migrate to the phase-4
contract's canonical entry point.
"""

from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


raise SystemExit(subprocess.run(
    [sys.executable, str(ROOT / "apps/devterm/test-accounts.py")],
    cwd=ROOT,
    check=False,
).returncode)
