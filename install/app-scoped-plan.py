#!/usr/bin/env python3
"""Pure planner for selecting app lifecycle safety groups.

This module deliberately does not parse configuration, inspect the ledger, or run an
app.  Its inputs are immutable products from the existing source flow:
``airlock-config package-info``, ``airlock-ledger plan`` and, when selected mode could
narrow a destructive plan, the ledger producer's complete committed/intent dependency
snapshot.  The caller must run the complete-candidate preflight first and supplies that
digest here so the selection plan can be bound to the globally validated candidate.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


SCHEMA = "airlock.app-scoped-plan/v1"
APP_ID = re.compile(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?")
DIGEST = re.compile(r"[0-9a-f]{64}")
DESIRED_ACTIONS = {
    "fresh",
    "reinstall",
    "upgrade-deactivate",
    "upgrade-diff",
}
REMOVAL_ACTIONS = {"remove", "teardown-intent"}
ALL_ACTIONS = DESIRED_ACTIONS | REMOVAL_ACTIONS
DESTRUCTIVE_ACTIONS = REMOVAL_ACTIONS | {"upgrade-deactivate"}


class PlanError(ValueError):
    pass


def canonical_bytes(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def digest(value: Any) -> str:
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def read_json(path: str) -> dict[str, Any]:
    try:
        raw = sys.stdin.buffer.read() if path == "-" else Path(path).read_bytes()
        value = json.loads(raw)
    except (OSError, json.JSONDecodeError) as exc:
        raise PlanError(f"cannot read package-info JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise PlanError("package-info must be a JSON object")
    return value


def valid_id(value: Any, where: str) -> str:
    if not isinstance(value, str) or APP_ID.fullmatch(value) is None:
        raise PlanError(f"{where} is not a valid app id: {value!r}")
    return value


def normalise_package_info(raw: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    packages = raw.get("packages")
    order = raw.get("order")
    if not isinstance(packages, dict):
        raise PlanError("package-info.packages must be an object")
    if not isinstance(order, list):
        raise PlanError("package-info.order must be a list")

    ordered_ids = [valid_id(app_id, "package-info.order entry") for app_id in order]
    if len(ordered_ids) != len(set(ordered_ids)):
        raise PlanError("package-info.order contains a duplicate app id")
    position = {app_id: index for index, app_id in enumerate(ordered_ids)}

    result: dict[str, Any] = {}
    for raw_id, raw_package in packages.items():
        app_id = valid_id(raw_id, "package-info package key")
        if app_id not in position:
            raise PlanError(f"package-info.order omits configured package {app_id}")
        if not isinstance(raw_package, dict):
            raise PlanError(f"package-info.packages.{app_id} must be an object")
        raw_deps = raw_package.get("deps", [])
        if not isinstance(raw_deps, list):
            raise PlanError(f"package-info.packages.{app_id}.deps must be a list")
        deps = [valid_id(dep, f"package-info.packages.{app_id}.deps entry")
                for dep in raw_deps]
        if len(deps) != len(set(deps)):
            raise PlanError(f"package-info.packages.{app_id}.deps contains a duplicate")
        if app_id in deps:
            raise PlanError(f"package-info.packages.{app_id} depends on itself")
        for dep in deps:
            if dep not in position:
                raise PlanError(f"package-info.packages.{app_id} depends on absent app {dep}")
            if dep != "hub" and dep not in packages:
                raise PlanError(
                    f"package-info.packages.{app_id} depends on non-package app {dep}"
                )
            if dep in packages and position[dep] >= position[app_id]:
                raise PlanError(
                    f"package-info.order is not dependency-topological: {dep} must precede {app_id}"
                )
        result[app_id] = {"deps": deps}
    return result, ordered_ids


def read_ledger_plan(path: str) -> tuple[dict[str, str], list[str]]:
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise PlanError(f"cannot read ledger plan: {exc}") from exc
    actions: dict[str, str] = {}
    order: list[str] = []
    for number, line in enumerate(lines, 1):
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != 2:
            raise PlanError(f"ledger plan line {number} must contain action<TAB>app-id")
        action, raw_id = fields
        app_id = valid_id(raw_id, f"ledger plan line {number} app id")
        if action not in ALL_ACTIONS:
            raise PlanError(f"ledger plan line {number} has unknown action {action!r}")
        if app_id in actions:
            raise PlanError(f"ledger plan contains duplicate app id {app_id}")
        actions[app_id] = action
        order.append(app_id)
    return actions, order


def read_ledger_dependencies(path: str | None, actions: dict[str, str]) -> dict[str, Any] | None:
    """Read the ledger producer's complete destructive dependency snapshot.

    The planner never opens the ledger.  Each destructive row is therefore named
    explicitly, including rows with no dependencies, so absence cannot be mistaken
    for evidence that an app has no committed dependents.
    """
    if path is None:
        return None
    try:
        raw = json.loads(Path(path).read_bytes())
    except (OSError, json.JSONDecodeError) as exc:
        raise PlanError(f"cannot read ledger dependency snapshot: {exc}") from exc
    if not isinstance(raw, dict) or set(raw) != {
            "schema", "rows", "candidate_serve_mappings"}:
        raise PlanError(
            "ledger dependency snapshot must contain exactly schema, rows and "
            "candidate_serve_mappings"
        )
    if raw["schema"] != "airlock.ledger-dependencies/v2":
        raise PlanError("unknown ledger dependency snapshot schema")
    if not isinstance(raw["rows"], list):
        raise PlanError("ledger dependency snapshot rows must be a list")

    rows: dict[str, dict[str, Any]] = {}
    for index, value in enumerate(raw["rows"]):
        where = f"ledger dependency snapshot row {index + 1}"
        if not isinstance(value, dict) or set(value) != {"app_id", "deps", "record_kind"}:
            raise PlanError(f"{where} must contain exactly app_id, deps and record_kind")
        app_id = valid_id(value["app_id"], f"{where} app_id")
        if app_id in rows:
            raise PlanError(f"ledger dependency snapshot contains duplicate app id {app_id}")
        if value["record_kind"] not in {"committed", "intent"}:
            raise PlanError(f"{where} has invalid record_kind {value['record_kind']!r}")
        if not isinstance(value["deps"], list):
            raise PlanError(f"{where} deps must be a list")
        deps = [valid_id(dep, f"{where} dependency") for dep in value["deps"]]
        if len(deps) != len(set(deps)):
            raise PlanError(f"{where} contains a duplicate dependency")
        if app_id in deps:
            raise PlanError(f"{where} depends on itself")
        rows[app_id] = {
            "app_id": app_id,
            "deps": sorted(deps),
            "record_kind": value["record_kind"],
        }

    destructive = {app_id for app_id, action in actions.items()
                   if action in DESTRUCTIVE_ACTIONS}
    if set(rows) != destructive:
        missing = sorted(destructive - set(rows))
        extra = sorted(set(rows) - destructive)
        detail = []
        if missing:
            detail.append("missing " + ", ".join(missing))
        if extra:
            detail.append("unexpected " + ", ".join(extra))
        raise PlanError("ledger dependency snapshot is not complete for destructive plan rows: "
                        + "; ".join(detail))

    raw_candidate_mappings = raw["candidate_serve_mappings"]
    if not isinstance(raw_candidate_mappings, list):
        raise PlanError("ledger candidate serve mappings must be a list")
    candidate_mappings: dict[str, bool] = {}
    for index, value in enumerate(raw_candidate_mappings):
        where = f"ledger candidate serve mapping row {index + 1}"
        if not isinstance(value, dict) or set(value) != {"app_id", "matches_committed"}:
            raise PlanError(f"{where} must contain exactly app_id and matches_committed")
        app_id = valid_id(value["app_id"], f"{where} app_id")
        if app_id in candidate_mappings:
            raise PlanError(f"ledger candidate serve mappings duplicate app id {app_id}")
        if not isinstance(value["matches_committed"], bool):
            raise PlanError(f"{where} matches_committed must be boolean")
        candidate_mappings[app_id] = value["matches_committed"]
    desired = {app_id for app_id, action in actions.items() if action in DESIRED_ACTIONS}
    if set(candidate_mappings) != desired:
        raise PlanError("ledger candidate serve mappings do not match desired plan rows")
    return {
        "schema": raw["schema"],
        "rows": [rows[app_id] for app_id in sorted(rows)],
        "candidate_serve_mappings": [
            {"app_id": app_id, "matches_committed": candidate_mappings[app_id]}
            for app_id in sorted(candidate_mappings)
        ],
    }


def validate_actions(packages: dict[str, Any], actions: dict[str, str]) -> None:
    for app_id in packages:
        action = actions.get(app_id)
        if action is None:
            raise PlanError(f"ledger plan omits configured package {app_id}")
        if action not in DESIRED_ACTIONS:
            raise PlanError(f"configured package {app_id} has removal action {action}")
    for app_id, action in actions.items():
        if app_id not in packages and action not in REMOVAL_ACTIONS:
            raise PlanError(f"ledger-only app {app_id} has desired action {action}")


def parse_handoffs(values: list[str], packages: dict[str, Any],
                   actions: dict[str, str]) -> list[tuple[str, str]]:
    result: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for value in values:
        if value.count(":") != 1:
            raise PlanError(f"handoff must be OLD:NEW, got {value!r}")
        old_raw, new_raw = value.split(":", 1)
        old = valid_id(old_raw, "handoff old owner")
        new = valid_id(new_raw, "handoff new owner")
        if old == new:
            raise PlanError("handoff cannot name the same old and new owner")
        if actions.get(old) not in REMOVAL_ACTIONS:
            raise PlanError(f"handoff old owner {old} has no removal action")
        if new not in packages:
            raise PlanError(f"handoff new owner {new} is not a configured package")
        pair = (old, new)
        if pair in seen:
            raise PlanError(f"duplicate handoff {value}")
        seen.add(pair)
        result.append(pair)
    return sorted(result)


def connected_components(nodes: set[str], edges: list[tuple[str, str]]) -> list[set[str]]:
    graph = {node: set() for node in nodes}
    for left, right in edges:
        graph[left].add(right)
        graph[right].add(left)
    components: list[set[str]] = []
    remaining = set(nodes)
    while remaining:
        first = min(remaining)
        component: set[str] = set()
        stack = [first]
        while stack:
            node = stack.pop()
            if node in component:
                continue
            component.add(node)
            stack.extend(sorted(graph[node] - component, reverse=True))
        remaining -= component
        components.append(component)
    return components


def selected_components(selected: list[str], packages: dict[str, Any],
                        handoffs: list[tuple[str, str]],
                        ledger_dependencies: dict[str, Any]) -> list[set[str]]:
    """Expand only toward prerequisites and destructive committed dependents.

    Package dependencies are directional: selecting an app needs its prerequisites,
    but must not reinstall sibling apps that happen to share one.  Resource handoffs
    stay atomic.  The ledger snapshot contributes the reverse edge only for its
    destructive rows, where changing a dependency must also settle a committed
    dependent that is already being removed or deactivated.
    """
    forward: dict[str, set[str]] = {}
    for app_id, package in packages.items():
        forward.setdefault(app_id, set()).update(
            dep for dep in package["deps"] if dep in packages
        )
    for old, new in handoffs:
        forward.setdefault(old, set()).add(new)
        forward.setdefault(new, set()).add(old)
    for row in ledger_dependencies["rows"]:
        dependent = row["app_id"]
        for dependency in row["deps"]:
            forward.setdefault(dependency, set()).add(dependent)

    closures: list[set[str]] = []
    for requested in selected:
        closure: set[str] = set()
        stack = [requested]
        while stack:
            app_id = stack.pop()
            if app_id in closure:
                continue
            closure.add(app_id)
            stack.extend(sorted(forward.get(app_id, ()), reverse=True))
        overlaps = [item for item in closures if item & closure]
        for item in overlaps:
            closure.update(item)
            closures.remove(item)
        closures.append(closure)
    return closures


def coalesce_interleaved_destructive_components(
        components: list[set[str]], actions: dict[str, str],
        ledger_position: dict[str, int]) -> list[set[str]]:
    """Keep group execution from interleaving the ledger's destructive order.

    If two otherwise independent components occupy overlapping intervals in that
    order, executing either group as a unit would invert at least one ledger row.
    Joining only those intervals preserves the producer order without inventing a
    second dependency or execution engine.
    """
    active: list[tuple[int, int, set[str]]] = []
    passive: list[set[str]] = []
    for component in components:
        positions = [ledger_position[app_id] for app_id in component
                     if actions[app_id] in DESTRUCTIVE_ACTIONS]
        if positions:
            active.append((min(positions), max(positions), set(component)))
        else:
            passive.append(set(component))
    active.sort(key=lambda item: (item[0], item[1], sorted(item[2])))

    merged: list[set[str]] = []
    current: set[str] | None = None
    current_max = -1
    for start, end, component in active:
        if current is None or start > current_max:
            if current is not None:
                merged.append(current)
            current = set(component)
            current_max = end
        else:
            current.update(component)
            current_max = max(current_max, end)
    if current is not None:
        merged.append(current)
    return merged + passive


def make_plan(package_info: dict[str, Any], ledger_actions: dict[str, str],
              ledger_order: list[str], *, mode: str, selected: list[str],
              handoff_values: list[str], candidate_digest: str,
              ledger_dependencies: dict[str, Any] | None) -> dict[str, Any]:
    packages, app_order = normalise_package_info(package_info)
    validate_actions(packages, ledger_actions)
    handoffs = parse_handoffs(handoff_values, packages, ledger_actions)
    if DIGEST.fullmatch(candidate_digest) is None:
        raise PlanError("candidate preflight digest must be 64 lowercase hex characters")

    selected_ids = [valid_id(app_id, "selected app") for app_id in selected]
    if len(selected_ids) != len(set(selected_ids)):
        raise PlanError("selected app list contains a duplicate")
    if mode == "selected":
        if not selected_ids:
            raise PlanError("selected mode requires at least one --select app")
    elif selected_ids:
        raise PlanError("full mode does not accept --select")
    for app_id in selected_ids:
        if app_id not in ledger_actions:
            raise PlanError(f"selected app {app_id} has no actionable ledger row")
    ledger_position = {app_id: index for index, app_id in enumerate(ledger_order)}
    selected_ids.sort(key=lambda app_id: ledger_position[app_id])

    destructive_ids = {app_id for app_id, action in ledger_actions.items()
                       if action in DESTRUCTIVE_ACTIONS}
    if mode == "selected" and destructive_ids and ledger_dependencies is None:
        raise PlanError(
            "selected mode refuses a destructive ledger plan without a complete "
            "ledger dependency snapshot"
        )

    nodes = set(ledger_actions)
    edges: list[tuple[str, str]] = []
    reasons: list[dict[str, str]] = []
    for app_id in sorted(packages):
        for dep in sorted(packages[app_id]["deps"]):
            if dep not in packages:
                continue  # hub/platform dependency has no app lifecycle action
            edge = (dep, app_id)
            edges.append(edge)
            reasons.append({"kind": "dependency", "from": dep, "to": app_id})
    for old, new in handoffs:
        edges.append((old, new))
        reasons.append({"kind": "handoff", "from": old, "to": new})
    if ledger_dependencies is not None:
        for row in ledger_dependencies["rows"]:
            dependent = row["app_id"]
            for dependency in row["deps"]:
                if dependency not in nodes:
                    continue
                edges.append((dependency, dependent))
                reasons.append({
                    "kind": "committed-dependency",
                    "from": dependency,
                    "to": dependent,
                })

    if mode == "selected":
        assert ledger_dependencies is not None
        components = selected_components(
            selected_ids, packages, handoffs, ledger_dependencies
        )
    else:
        components = connected_components(nodes, edges)
        components = coalesce_interleaved_destructive_components(
            components, ledger_actions, ledger_position
        )
    requested_ids = list(ledger_order) if mode == "full" else selected_ids
    requested = set(requested_ids)
    chosen = [component for component in components if component & requested]
    package_position = {app_id: index for index, app_id in enumerate(app_order)}
    groups: list[dict[str, Any]] = []
    selected_members: set[str] = set()
    for component in chosen:
        installs = sorted((app_id for app_id in component if app_id in packages),
                          key=lambda app_id: package_position[app_id])
        removals = sorted((app_id for app_id in component if app_id not in packages),
                          key=lambda app_id: ledger_position[app_id])
        destructive_order = sorted(
            (app_id for app_id in component
             if ledger_actions[app_id] in DESTRUCTIVE_ACTIONS),
            key=lambda app_id: ledger_position[app_id],
        )
        members = removals + installs
        selected_members.update(component)
        group_reasons = [reason for reason in reasons
                         if reason["from"] in component and reason["to"] in component]
        group_identity = {"members": sorted(component), "reasons": group_reasons}
        groups.append({
            "actions": [{"app_id": app_id, "action": ledger_actions[app_id]}
                        for app_id in sorted(component, key=lambda item: ledger_position[item])],
            "destructive_order": destructive_order,
            "group_id": "group-" + digest(group_identity)[:16],
            "install_order": installs,
            "members": members,
            "remove_order": removals,
            "requested_apps": [app_id for app_id in requested_ids if app_id in component],
            "safety_reasons": group_reasons,
        })
    groups.sort(key=lambda group: min(ledger_position[app_id]
                                      for app_id in group["members"]))
    if mode == "selected":
        assert ledger_dependencies is not None
        mapping_matches = {
            row["app_id"]: row["matches_committed"]
            for row in ledger_dependencies["candidate_serve_mappings"]
        }
        unsafe_unrelated = [
            (app_id, ledger_actions[app_id])
            for app_id in ledger_order
            if (app_id not in selected_members
                and not mapping_matches.get(app_id, False))
        ]
        if unsafe_unrelated:
            detail = ", ".join(
                f"{app_id} ({action}; serve mapping differs)"
                for app_id, action in unsafe_unrelated
            )
            raise PlanError(
                "selected mode cannot publish unselected candidate changes: " + detail
            )
    if mode == "full":
        expected_destructive = [
            app_id for app_id in ledger_order
            if ledger_actions[app_id] in DESTRUCTIVE_ACTIONS
        ]
        observed_destructive = [
            app_id for group in groups for app_id in group["destructive_order"]
        ]
        if observed_destructive != expected_destructive:
            raise PlanError("full mode could not preserve ledger destructive order")

    normalised_actions = [{"app_id": app_id, "action": ledger_actions[app_id]}
                          for app_id in ledger_order]
    execution_actions = [row for row in normalised_actions
                         if row["app_id"] in selected_members]
    body: dict[str, Any] = {
        "candidate_preflight_digest": candidate_digest,
        "execution": {
            "actions": execution_actions,
            "destructive_order": [
                row["app_id"] for row in execution_actions
                if row["action"] in DESTRUCTIVE_ACTIONS
            ],
            "install_order": [
                app_id for group in groups for app_id in group["install_order"]
            ],
            "remove_order": [
                row["app_id"] for row in execution_actions
                if row["action"] in REMOVAL_ACTIONS
            ],
        },
        "groups": groups,
        "inputs": {
            "ledger_plan_digest": digest(normalised_actions),
            "ledger_dependencies_digest": (
                digest(ledger_dependencies) if ledger_dependencies is not None else None
            ),
            "package_info_digest": digest(package_info),
            "selection_digest": digest({
                "handoffs": handoffs,
                "mode": mode,
                "requested": requested_ids,
            }),
        },
        "mode": mode,
        "requested_apps": requested_ids,
        "schema": SCHEMA,
        "unrelated_apps": [app_id for app_id in ledger_order if app_id not in selected_members],
        "validation_contract": {
            "candidate_scope": "complete",
            "global_validator": "airlock-config validate",
            "package_info_producer": "airlock-config package-info",
            "preflight_producer": "airlock-config install-preflight --package-info-stdin",
            "ledger_plan_producer": "airlock-ledger plan",
            "ledger_dependency_producer": "airlock-ledger plan --dependency-snapshot",
        },
    }
    body["plan_digest"] = digest(body)
    return body


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-info", default="-", metavar="PATH",
                        help="package-info JSON path, or - for stdin")
    parser.add_argument("--ledger-plan", required=True, metavar="PATH",
                        help="airlock-ledger plan output")
    parser.add_argument("--ledger-dependencies", metavar="PATH",
                        help="complete destructive dependency snapshot from the ledger producer")
    parser.add_argument("--candidate-preflight-digest", required=True, metavar="SHA256")
    parser.add_argument("--mode", required=True, choices=("full", "selected"))
    parser.add_argument("--select", action="append", default=[], metavar="APP_ID")
    parser.add_argument("--handoff", action="append", default=[], metavar="OLD:NEW")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(list(sys.argv[1:] if argv is None else argv))
    try:
        package_info = read_json(args.package_info)
        actions, action_order = read_ledger_plan(args.ledger_plan)
        ledger_dependencies = read_ledger_dependencies(args.ledger_dependencies, actions)
        plan = make_plan(
            package_info,
            actions,
            action_order,
            mode=args.mode,
            selected=args.select,
            handoff_values=args.handoff,
            candidate_digest=args.candidate_preflight_digest,
            ledger_dependencies=ledger_dependencies,
        )
    except PlanError as exc:
        print(f"app-scoped-plan: {exc}", file=sys.stderr)
        return 2
    sys.stdout.buffer.write(canonical_bytes(plan))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
