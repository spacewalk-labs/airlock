#!/usr/bin/env python3
"""Fleet registry: one assignment sheet, key name (op:// address) -> holding box.

Contract (card REGISTRY): the sheet holds NOTHING but the mapping — no credential
values, no usage, no metadata. Exactly one writer box (named by the deployment, not
by this file). Served as a URL by the fleet file server; other boxes point at it,
never write it.

Scenarios:
  held-key            another box holding a key refuses assignment to a new box
  unauthorized-write  every write not from the allowed writer is refused,
                      registry unchanged

Usage: install/test-fleet-registry.py --scenario held-key,unauthorized-write
"""
import argparse
import copy
import importlib.machinery
import importlib.util
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = []


def check(name, cond, observed=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f" — {observed}"))
    if not cond:
        failures.append(name)


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


registry = load("fleet_registry", os.path.join(ROOT, "bin", "airlock-fleet-registry"))

FIXTURE = os.path.join(ROOT, "install", "fixtures", "fleet-registry.json")

# Role names only — the real writer box is deployment state named on the board.
WRITER = "writer-box"
PEER = "peer-box"

# A key this test's writer holds in the fixture; a key another box holds.
MINE = "op://example-vault/muse-spark-example-1/password"
HELD = "op://example-vault/muse-spark-example-2/password"
FREE = "op://example-vault/muse-spark-example-9/password"


def scenario_held_key():
    with open(FIXTURE, encoding="utf-8") as f:
        sheet = json.load(f)
    check("shape: fixture is a bare key->box map", registry.is_valid(sheet), sheet)
    check("shape: fixture holds the writer's key", sheet.get(MINE) == WRITER, sheet)
    check("shape: fixture holds another box's key", sheet.get(HELD) == PEER, sheet)

    before = copy.deepcopy(sheet)
    # Another box's key cannot be taken by this box: refused, sheet unchanged.
    ok, reason = registry.assign(sheet, HELD, WRITER, writer=WRITER,
                                 allowed_writer=WRITER)
    check("held-key: assigning another box's key is refused",
          ok is False and reason == "held-by-other-box", (ok, reason))
    check("held-key: refused assignment leaves the sheet unchanged", sheet == before, sheet)

    # Re-assigning my own key to my own box is an idempotent no-op, not a refusal.
    ok, reason = registry.assign(sheet, MINE, WRITER, writer=WRITER,
                                 allowed_writer=WRITER)
    check("held-key: re-assigning my own key succeeds",
          ok is True and sheet.get(MINE) == WRITER, (ok, reason))

    # A key nobody holds can be assigned by the writer.
    ok, reason = registry.assign(sheet, FREE, WRITER, writer=WRITER,
                                 allowed_writer=WRITER)
    check("held-key: assigning an unheld key succeeds",
          ok is True and sheet.get(FREE) == WRITER, (ok, reason))

    # The validator rejects anything but the mapping: values, nesting, bad names.
    # A real key value is always longer than a hostname can be (DNS label limit 63),
    # so the value slot cannot carry one; a hostname-shaped string is by shape alone
    # indistinguishable from a box, and that remainder is single-writer + review.
    check("shape: key-length credential values are rejected",
          registry.is_valid({MINE: "sk-ant-" + "x" * 100}) is False)
    check("shape: overlong box names are rejected",
          registry.is_valid({MINE: "b" * 64}) is False)
    check("shape: nested entries are rejected",
          registry.is_valid({MINE: {"box": WRITER}}) is False)
    check("shape: non-op:// keys are rejected",
          registry.is_valid({"muse-spark-1": WRITER}) is False)
    check("shape: bad box names are rejected",
          registry.is_valid({MINE: "not a box!"}) is False)
    check("shape: a list is not a sheet", registry.is_valid([]) is False)


def scenario_unauthorized_write():
    with open(FIXTURE, encoding="utf-8") as f:
        sheet = json.load(f)
    before = copy.deepcopy(sheet)
    for writer in (PEER, "third-box", "", "root", WRITER + " "):
        ok, reason = registry.assign(sheet, FREE, PEER, writer=writer,
                                     allowed_writer=WRITER)
        check(f"unauthorized-write: writer {writer!r} is refused",
              ok is False and reason == "unauthorized-writer", (ok, reason))
    check("unauthorized-write: refused writes leave the sheet unchanged",
          sheet == before, sheet)
    # Even a held-key release by a non-writer is refused, not honored.
    ok, reason = registry.assign(sheet, HELD, WRITER, writer=PEER,
                                 allowed_writer=WRITER)
    check("unauthorized-write: non-writer cannot move another box's key either",
          ok is False and reason == "unauthorized-writer", (ok, reason))
    # No allowed writer configured: fail closed, every write refused.
    ok, reason = registry.assign(sheet, FREE, WRITER, writer=WRITER,
                                 allowed_writer="")
    check("unauthorized-write: empty allowed-writer refuses everything",
          ok is False and reason == "unauthorized-writer", (ok, reason))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", default="held-key,unauthorized-write")
    args = parser.parse_args()
    selected = {s.strip() for s in args.scenario.split(",") if s.strip()}
    if "held-key" in selected:
        scenario_held_key()
    if "unauthorized-write" in selected:
        scenario_unauthorized_write()
    unknown = selected - {"held-key", "unauthorized-write"}
    if unknown:
        check(f"unknown scenarios refused: {sorted(unknown)}", False)
    if failures:
        print(f"{len(failures)} FAILURES")
        return 1
    print("all fleet-registry scenarios green")
    return 0


if __name__ == "__main__":
    sys.exit(main())
