#!/usr/bin/env python3
"""Phase-4 contract for retiring account ownership from DevTerm.

This is deliberately both a runtime parity probe and a source-boundary ratchet:
the retired account routes must be 404 at devterm and dispatch as 200 at the
platform handler, while the temporary fleet reads, secret-drop adapter, and
terminal/session surface remain present.
"""

from __future__ import annotations

import argparse
import ast
import asyncio
import importlib.machinery
import importlib.util
import inspect
import os
import operator
import re
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DEVTERM_GATE = ROOT / "apps/devterm/backend/devterm-gate.py"
PLATFORM_API = ROOT / "bin/airlock-accounts-api"
RENDER = ROOT / "apps/devterm/render.sh"
INSTALL = ROOT / "apps/devterm/install.sh"
APP_JS = ROOT / "apps/devterm/web/app.js"
INDEX = ROOT / "apps/devterm/web/index.html"
CONTROL = ROOT / "apps/devterm/web/platform-account-control.js"
POPUP = ROOT / "apps/devterm/web/popup.css"
HUB = ROOT / "hub/index.html"
GOLDEN_RENDER = ROOT / "install/golden/render"

FLEET_ROUTES = {
    "/claude-status": "GET",
    "/claude-usage": "GET",
    "/claude-usage-store": "GET",
    "/codex-usage": "GET",
}
SECRET_ROUTES = {"/secret-put", "/secret-list", "/secret-del"}
TERMINAL_ROUTES = {
    "/sessions", "/upload-image", "/upload-file", "/kill-session", "/list-dir",
    "/rename-session", "/tab-prefs", "/recent-images", "/recent-image", "/resolve",
    "/layout", "/pane",
}
ORCA_ROUTES = {
    "/orca/status", "/orca/tree", "/orca/worktree-create", "/orca/worktree-rm",
    "/orca/worktree-set", "/orca/repo-add",
}
ALLOWED_DEVTERM_ROUTES = TERMINAL_ROUTES | set(FLEET_ROUTES) | ORCA_ROUTES | {"/ws", "/token"}
ALLOWED_MODULE_MUTABLES = {
    "ALLOW", "REMOTE_HOSTS", "_CTYPES", "_remote_cache", "_last_mirror", "_LAYOUTS",
}

PREDICATE_TERM = re.compile(r"\A([a-z][a-z0-9_]*)\s*(==|!=|>=|<=|>|<)\s*(-?[0-9]+)\Z")
OPERATORS = {
    "==": operator.eq,
    "!=": operator.ne,
    ">=": operator.ge,
    "<=": operator.le,
    ">": operator.gt,
    "<": operator.lt,
}


def _compared_literals(test: ast.AST, variable: str) -> set[str]:
    values: set[str] = set()
    for node in ast.walk(test):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) \
                and node.func.attr == "startswith" and node.args:
            receiver_names = {
                child.id if isinstance(child, ast.Name) else child.attr
                for child in ast.walk(node.func.value)
                if isinstance(child, (ast.Name, ast.Attribute))
            }
            value = node.args[0]
            if variable in receiver_names and isinstance(value, ast.Constant) \
                    and isinstance(value.value, (str, bytes)):
                decoded = value.value.decode() if isinstance(value.value, bytes) else value.value
                values.add(decoded)
            continue
        if not isinstance(node, ast.Compare) or len(node.ops) != 1 or len(node.comparators) != 1:
            continue
        left_names = {
            child.id if isinstance(child, ast.Name) else child.attr
            for child in ast.walk(node.left)
            if isinstance(child, (ast.Name, ast.Attribute))
        }
        if variable not in left_names:
            continue
        value = node.comparators[0]
        if isinstance(node.ops[0], ast.Eq) and isinstance(value, ast.Constant) \
                and isinstance(value.value, (str, bytes)):
            decoded = value.value.decode() if isinstance(value.value, bytes) else value.value
            values.add(decoded)
        elif isinstance(node.ops[0], ast.In) and isinstance(value, (ast.Tuple, ast.List, ast.Set)):
            for item in value.elts:
                if isinstance(item, ast.Constant) and isinstance(item.value, (str, bytes)):
                    values.add(item.value.decode() if isinstance(item.value, bytes) else item.value)
    return values


def _assigned_literal_collection(tree: ast.Module, variable: str) -> set[str]:
    for node in tree.body:
        if not isinstance(node, ast.Assign):
            continue
        if not any(isinstance(target, ast.Name) and target.id == variable for target in node.targets):
            continue
        if not isinstance(node.value, (ast.Tuple, ast.List, ast.Set)):
            return set()
        values = set()
        for item in node.value.elts:
            if isinstance(item, ast.Constant) and isinstance(item.value, (str, bytes)):
                values.add(item.value.decode() if isinstance(item.value, bytes) else item.value)
        return values
    return set()


def registered_route_bindings(source: str, functions: set[str]) -> dict[str, set[str]]:
    """Enumerate every literal route registered by the named dispatch functions.

    A path-only branch is recorded as ``*`` because it accepts every method. Devterm's
    TTYD membership branch is expanded from the product's TTYD_PATHS assignment rather
    than copied into this test.
    """
    tree = ast.parse(source)
    bindings: dict[str, set[str]] = {}
    for function in ast.walk(tree):
        if not isinstance(function, (ast.FunctionDef, ast.AsyncFunctionDef)) \
                or function.name not in functions:
            continue
        default_method = "GET" if function.name == "do_GET" else (
            "POST" if function.name == "do_POST" else "*"
        )
        for branch in ast.walk(function):
            if not isinstance(branch, ast.If):
                continue
            paths = {value.partition("?")[0] for value in _compared_literals(branch.test, "path")
                     if value.startswith("/")}
            methods = _compared_literals(branch.test, "method") or {default_method}
            for path in paths:
                bindings.setdefault(path, set()).update(methods)
        if function.name == "handle":
            for path in _assigned_literal_collection(tree, "TTYD_PATHS"):
                bindings.setdefault(path, set()).add("*")
    return bindings


def route_literals(source: str, functions: set[str]) -> set[str]:
    return set(registered_route_bindings(source, functions))


class Writer:
    def __init__(self):
        self.data = bytearray()

    def write(self, value):
        self.data.extend(value)

    async def drain(self):
        return None

    def close(self):
        return None


async def devterm_request(module, method: str, path: str) -> int:
    reader = asyncio.StreamReader()
    reader.feed_data(
        f"{method} {path} HTTP/1.1\r\nHost: box.example.test\r\n"
        "X-Test-Login: owner@example.test\r\nContent-Length: 0\r\n\r\n".encode()
    )
    reader.feed_eof()
    writer = Writer()
    await module.handle(reader, writer)
    return int(bytes(writer.data).split(b" ", 2)[1])


def load_source_module(path: Path, name: str):
    loader = importlib.machinery.SourceFileLoader(name, os.fspath(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def mutate_once(source: str, old: str, new: str, label: str) -> str:
    if source.count(old) != 1:
        raise AssertionError(f"{label}: mutation target count was {source.count(old)}, expected 1")
    return source.replace(old, new, 1)


def write_temp_source(root: Path, relative: str, source: str) -> Path:
    path = root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source, encoding="utf-8")
    return path


def load_gate(source_path: Path, web_root: str, name: str):
    keys = {
        "AIRLOCK_IDENTITY_HEADER": "X-Test-Login",
        "AIRLOCK_OWNER": "owner@example.test",
        "DEVTERM_WEB": web_root,
        "DEVTERM_CLAUDE_STATUS": "/bin/true",
        "DEVTERM_FLEET_READ_DOMAIN": "example.test",
    }
    before = {key: os.environ.get(key) for key in keys}
    os.environ.update(keys)
    try:
        return load_source_module(source_path, name)
    finally:
        for key, value in before.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def platform_statuses(module, bindings: dict[str, set[str]]) -> dict[tuple[str, str], int]:
    """Exercise the real route dispatcher without provider/network side effects."""

    class ProbeHandler(module.Handler):
        def __init__(self, method: str, path: str):
            self.command = method
            self.path = path
            self.headers = {}
            self.statuses = []

        def _send(self, status, _payload, cors_origin=None):
            del cors_origin
            self.statuses.append(status)

        def _panel_route(self):
            return False

        def _platform_ingress_allowed(self):
            return True

        def _guarded(self):
            return True

        def _json_body(self):
            return {"name": "fixture", "code": "ABCD-1234"}

    replacements = {
        "_probe": lambda _args=(): (200, {}),
        "_accounts_payload": lambda: {},
        "_xai_status_payload": lambda: (200, {}),
        "_acct_alert_payload": lambda: {},
        "_codex_usage_cached": lambda wait=False: {},
        "_fetch_fleet_store": lambda: {},
        "_cli": lambda args, **_kwargs: (
            True,
            "https://auth.example.test/login" if args == ["login-url"] else "",
            "",
        ),
        "_codex_login_start": lambda: (200, {}),
        "_codex_login_cancel": lambda: (200, {}),
        "_xai_login_start": lambda: (200, {}),
        "_cancel_xai_login": lambda: True,
        "_xai_logout": lambda: (200, {}),
        "_claude_usage_state_save": lambda _payload: None,
        "_invalidate_codex_usage_cache": lambda: None,
        "_invalidate_acct_caches": lambda: None,
    }
    saved = {name: getattr(module, name) for name in replacements}
    for name, value in replacements.items():
        setattr(module, name, value)
    try:
        statuses = {}
        for route, methods in bindings.items():
            for method in methods:
                handler = ProbeHandler(method, route)
                (handler.do_GET if method == "GET" else handler.do_POST)()
                assert len(handler.statuses) == 1, (route, method, handler.statuses)
                statuses[(route, method)] = handler.statuses[0]
        return statuses
    finally:
        for name, value in saved.items():
            setattr(module, name, value)


def _method_for_probe(method: str) -> str:
    return "GET" if method == "*" else method


def exercise_registered_routes(module, bindings: dict[str, set[str]]) -> dict[tuple[str, str], int]:
    """Run every AST-enumerated DevTerm binding through the real dispatcher.

    Handler bodies are replaced with a uniform 200 response so this measures dispatch,
    not tmux, filesystem, or remote-host side effects. An inline response introduced by
    a source mutation is not replaced and therefore remains observable.
    """
    async def respond(*args, **_kwargs):
        writer = next((value for value in reversed(args) if isinstance(value, Writer)), None)
        if writer is None:
            raise AssertionError("route stub received no Writer")
        writer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        await writer.drain()

    replacements = {}
    for name, value in vars(module).items():
        if (name.startswith("_serve_") or name == "_proxy_ttyd") \
                and inspect.iscoroutinefunction(value):
            replacements[name] = value
            setattr(module, name, respond)
    try:
        statuses = {}
        for route, methods in sorted(bindings.items()):
            for method in sorted(methods):
                probe_method = _method_for_probe(method)
                statuses[(route, method)] = asyncio.run(
                    devterm_request(module, probe_method, route)
                )
        return statuses
    finally:
        for name, value in replacements.items():
            setattr(module, name, value)


def module_mutable_bindings(source: str) -> set[str]:
    """Enumerate every mutable collection bound at module scope."""
    tree = ast.parse(source)
    mutable_nodes = (ast.Dict, ast.List, ast.Set, ast.DictComp, ast.ListComp, ast.SetComp)
    names: set[str] = set()
    for node in tree.body:
        if not isinstance(node, (ast.Assign, ast.AnnAssign)) or not isinstance(node.value, mutable_nodes):
            continue
        targets = node.targets if isinstance(node, ast.Assign) else [node.target]
        names.update(target.id for target in targets if isinstance(target, ast.Name))
    return names


def source_observations(
    gate_source: str,
    platform_source: str,
    render_source: str,
    install_source: str,
    app_source: str,
    index_source: str,
    popup_source: str,
    control_exists: bool,
) -> dict[str, int]:
    devterm_routes = route_literals(gate_source, {"handle"})
    platform_routes = route_literals(platform_source, {"do_GET", "do_POST"}) - SECRET_ROUTES
    account_ui_markers = sum((
        control_exists,
        '<script src="accounts.js"></script>' in index_source,
        '<script src="platform-account-control.js"></script>' in index_source,
        "window.initAccounts" in app_source,
        "window.initPlatformAccountControl" in app_source,
        "openAcctMenu" in app_source,
        "FEAT.accounts" in app_source,
        "FEAT.xai" in app_source,
        ".tab-pop.acct" in popup_source,
        "location = /panel.html" in render_source,
        "location = /accounts.js" in render_source,
        '"$HERE/web/platform-account-control.js"' in install_source,
    )) + sum(marker in install_source for marker in (
        "AIRLOCK_DEVTERM_ACCOUNTS", "AIRLOCK_DEVTERM_XAI",
        "AIRLOCK_DEVTERM_CLAUDE_SWITCH", "AIRLOCK_DEVTERM_CLAUDE_STATUS",
    ))
    mutable_bindings = module_mutable_bindings(gate_source)
    secret_routes = sum(route in render_source for route in ("/secret-put", "/secret-list", "/secret-del"))
    secret_adapter = int(
        '<script src="secretdrop.js"></script>' in index_source
        and "window.initSecretDrop" in app_source
        and "location = /secretdrop.js" in render_source
        and "ACCOUNT_PANEL_DIR" in install_source
    )
    fleet_guards = int("def _fleet_read_ok" in gate_source) + int(
        "render_devterm_fleet_read" in render_source
        and "render_devterm_fleet_locations" in render_source
    )
    return {
        "platform_routes": len(platform_routes),
        "registered_routes": len(devterm_routes),
        # Any literal route outside the complete retained DevTerm surface is a boundary
        # breach. This deliberately fails closed for a newly invented account route;
        # there is no fixed retired-route list for it to evade.
        "account_domain_routes": len(devterm_routes - ALLOWED_DEVTERM_ROUTES),
        "fleet_routes": len(devterm_routes & set(FLEET_ROUTES)),
        "terminal_routes": len(devterm_routes & TERMINAL_ROUTES),
        "module_state_total": len(mutable_bindings),
        "unexpected_module_state": len(mutable_bindings - ALLOWED_MODULE_MUTABLES),
        "account_ui_markers": account_ui_markers,
        "secret_routes": secret_routes,
        "secret_adapter": secret_adapter,
        "fleet_guards": fleet_guards,
    }


def frontend_observations(
    hub_source: str,
    widget_sources: dict[str, str],
    app_source: str,
    index_source: str,
) -> dict[str, int]:
    devterm_markers = (
        "panel.html?p=accounts",
        "platform-account-control.js",
        'src="accounts.js"',
        "window.initPlatformAccountControl",
    )
    injections = []
    bad_bases = []
    legacy = 0
    for path, source in widget_sources.items():
        normalized = source.replace('\\"', '"')
        values = re.findall(r'data-(account-panel|panel)="([^"]+)"', normalized)
        for kind, value in values:
            injections.append((path, kind, value))
            legacy += int(kind == "panel")
            if value == "${PLATFORM_PANEL_URL}":
                valid = 'PLATFORM_PANEL_URL="$(airlock_secret_panel_url || true)"' in normalized
            else:
                valid = value == "/airlock-accounts/" or (
                    value.startswith("https://") and value.endswith("/airlock-accounts/")
                )
            if not valid:
                bad_bases.append((path, value))
    return {
        "pill_base": hub_source.count('return "/airlock-accounts/";'),
        "widget_injections": len(injections),
        "widget_injection_files": len({path for path, _kind, _value in injections}),
        "widget_bad_bases": len(bad_bases),
        "legacy_panel_injections": legacy,
        "devterm_account_paths": sum(
            source.count(marker)
            for source in (index_source, app_source)
            for marker in devterm_markers
        ),
    }


def widget_product_sources() -> dict[str, str]:
    paths = list(ROOT.glob("apps/*/install.sh")) + list(GOLDEN_RENDER.rglob("*.conf"))
    result = {}
    for path in paths:
        source = path.read_text(encoding="utf-8")
        if "data-account-panel=" in source or "data-panel=" in source:
            result[path.relative_to(ROOT).as_posix()] = source
    return result


def mutate_once(source: str, before: str, after: str, name: str) -> str:
    if source.count(before) != 1:
        raise AssertionError(f"{name}: expected exactly one mutation target, found {source.count(before)}")
    return source.replace(before, after, 1)


def write_temp_source(temp_root: Path, relative: str, source: str) -> Path:
    path = temp_root / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source, encoding="utf-8")
    return path


def devterm_runtime_observations(
    gate_source: str,
    temp_root: Path,
    module_name: str,
) -> tuple[dict[str, set[str]], dict[tuple[str, str], int]]:
    source_path = write_temp_source(
        temp_root, f"{module_name}/apps/devterm/backend/devterm-gate.py", gate_source
    )
    web_root = temp_root / module_name / "web"
    web_root.mkdir(parents=True, exist_ok=True)
    module = load_gate(source_path, os.fspath(web_root), module_name)
    bindings = registered_route_bindings(gate_source, {"handle"})
    return bindings, exercise_registered_routes(module, bindings)


def predicate_holds(expected: str, observed: dict[str, int]) -> bool:
    """Evaluate the board's numeric predicate grammar without eval or fixed verdicts."""
    for raw_term in expected.split("&&"):
        match = PREDICATE_TERM.fullmatch(raw_term.strip())
        if match is None:
            raise ValueError(f"invalid predicate term: {raw_term!r}")
        name, op, raw_value = match.groups()
        if name not in observed:
            raise ValueError(f"predicate field has no observation: {name}")
        if not OPERATORS[op](observed[name], int(raw_value)):
            return False
    return True


def format_observed(expected: str, observed: dict[str, int]) -> str:
    names = [PREDICATE_TERM.fullmatch(term.strip()).group(1) for term in expected.split("&&")]
    return ",".join(f"{name}={observed[name]}" for name in names)


def evaluate_ac(
    ac_id: str,
    expected: str,
    observed: dict[str, int],
    mutated: dict[str, int],
    mutation_name: str,
    signal: str,
    revision: str,
    emit: bool,
) -> bool:
    allowed_signals = {"live", "replay", "fixture", "projection", "mock"}
    if signal not in allowed_signals:
        raise ValueError(f"unsupported AC signal: {signal}")
    mutation_passed = predicate_holds(expected, mutated)
    observed = {**observed, "negative_control": int(not mutation_passed)}
    final_expected = f"{expected} && negative_control==1"
    passed = predicate_holds(final_expected, observed)
    if emit:
        verdict = "PASS" if passed else "FAIL"
        mutation_verdict = "PASS" if mutation_passed else "FAIL"
        print(
            f"AC-{ac_id} | expected: {final_expected} | observed: "
            f"{format_observed(final_expected, observed)} | verdict: {verdict} | signal: {signal} "
            f"| evidence: apps/devterm/test-accounts.py@{revision}"
        )
        print(
            f"MUTATION-{ac_id} | mutation: {mutation_name} | observed: "
            f"{format_observed(expected, mutated)} | verdict: {mutation_verdict} "
            f"| signal: {signal} | evidence: temporary source copy@{revision}"
        )
    return passed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--emit-ac", action="store_true")
    args = parser.parse_args()

    sources = {
        "gate_source": DEVTERM_GATE.read_text(encoding="utf-8"),
        "platform_source": PLATFORM_API.read_text(encoding="utf-8"),
        "render_source": RENDER.read_text(encoding="utf-8"),
        "install_source": INSTALL.read_text(encoding="utf-8"),
        "app_source": APP_JS.read_text(encoding="utf-8"),
        "index_source": INDEX.read_text(encoding="utf-8"),
        "popup_source": POPUP.read_text(encoding="utf-8"),
        "control_exists": CONTROL.exists(),
    }
    observed = source_observations(**sources)

    platform_source = sources["platform_source"]
    platform_bindings = registered_route_bindings(platform_source, {"do_GET", "do_POST"})
    platform_account_bindings = {
        route: methods for route, methods in platform_bindings.items() if route not in SECRET_ROUTES
    }
    platform = load_source_module(PLATFORM_API, "platform_account_retirement")
    platform_status = platform_statuses(platform, platform_account_bindings)

    route_mutant_source = mutate_once(
        sources["gate_source"],
        'elif path == b"/sessions":',
        'elif path == b"/account-admin":\n'
        '            cw.write(_resp(b"200 OK", b"account admin"))\n'
        '            await cw.drain()\n'
        '        elif path == b"/sessions":',
        "P4A /account-admin",
    )
    state_mutant_source = sources["gate_source"] + "\nACCOUNT_CACHE_V2 = {}\n"
    fleet_mutant_source = mutate_once(
        sources["gate_source"],
        'elif path == b"/codex-usage" and method == b"GET":\n'
        '            await _serve_codex_usage(cw)',
        'elif path == b"/codex-usage" and method == b"GET":\n'
        '            cw.write(_resp(b"404 Not Found", b"broken fleet route"))\n'
        '            await cw.drain()',
        "P4C /codex-usage 404",
    )

    widget_sources = widget_product_sources()
    widget_mutant_sources = dict(widget_sources)
    widget_mutant_path = "install/golden/render/orca/installer-path/nginx.conf"
    widget_mutant_sources[widget_mutant_path] = mutate_once(
        widget_sources[widget_mutant_path],
        'data-account-panel="https://box.example.ts.net/airlock-accounts/"',
        'data-account-panel="https://box.example.ts.net:19913/"',
        "P4D devterm widget base",
    )

    revision = subprocess.check_output(
        ["git", "rev-parse", "--short=12", "HEAD"], cwd=ROOT, text=True
    ).strip()
    with tempfile.TemporaryDirectory(prefix="devterm-account-retirement-") as temp_dir:
        temp_root = Path(temp_dir)
        gate_bindings, gate_status = devterm_runtime_observations(
            sources["gate_source"], temp_root, "devterm_gate_current"
        )
        route_mutant_bindings, route_mutant_status = devterm_runtime_observations(
            route_mutant_source, temp_root, "devterm_gate_account_admin_mutant"
        )
        _fleet_mutant_bindings, fleet_mutant_status = devterm_runtime_observations(
            fleet_mutant_source, temp_root, "devterm_gate_codex_404_mutant"
        )

        # The retired probe set is derived from the platform's actual registered account
        # surface. Only the four explicitly retained fleet reads are excluded.
        retired_bindings = {
            route: methods for route, methods in platform_account_bindings.items()
            if route not in FLEET_ROUTES
        }
        current_gate_path = write_temp_source(
            temp_root, "devterm_retired_probe/devterm-gate.py", sources["gate_source"]
        )
        retired_web = temp_root / "devterm_retired_probe/web"
        retired_web.mkdir(parents=True, exist_ok=True)
        retired_gate = load_gate(current_gate_path, os.fspath(retired_web), "devterm_retired_probe")
        retired_status = {}
        for route, methods in retired_bindings.items():
            for method in methods:
                retired_status[(route, method)] = asyncio.run(
                    devterm_request(retired_gate, method, route)
                )

        # Write and re-read the other two mutants as files too: every negative control
        # is the same observer over a product/fixture source copy, never a result-dict edit.
        state_path = write_temp_source(
            temp_root, "state_mutant/devterm-gate.py", state_mutant_source
        )
        state_mutant_sources = {**sources, "gate_source": state_path.read_text(encoding="utf-8")}
        widget_path = write_temp_source(
            temp_root, widget_mutant_path, widget_mutant_sources[widget_mutant_path]
        )
        widget_mutant_sources[widget_mutant_path] = widget_path.read_text(encoding="utf-8")

    unexpected_bindings = {
        (route, method) for route, methods in gate_bindings.items()
        if route not in ALLOWED_DEVTERM_ROUTES for method in methods
    }
    route_mutant_unexpected = {
        (route, method) for route, methods in route_mutant_bindings.items()
        if route not in ALLOWED_DEVTERM_ROUTES for method in methods
    }
    p4a_expected = (
        "retired_404==16 && platform_200==20 && platform_routes==20 && registered_routes==24 "
        "&& registered_runtime_200==25 && account_domain_routes==0 && account_domain_200==0"
    )
    p4a_observed = {
        "retired_404": sum(code == 404 for code in retired_status.values()),
        "platform_200": sum(code == 200 for code in platform_status.values()),
        "platform_routes": len(platform_account_bindings),
        "registered_routes": len(gate_bindings),
        "registered_runtime_200": sum(code == 200 for code in gate_status.values()),
        "account_domain_routes": len(unexpected_bindings),
        "account_domain_200": sum(gate_status[binding] == 200 for binding in unexpected_bindings),
    }
    p4a_mutated = {
        **p4a_observed,
        "registered_routes": len(route_mutant_bindings),
        "registered_runtime_200": sum(code == 200 for code in route_mutant_status.values()),
        "account_domain_routes": len(route_mutant_unexpected),
        "account_domain_200": sum(
            route_mutant_status[binding] == 200 for binding in route_mutant_unexpected
        ),
    }

    p4b_expected = (
        "module_state_total==6 && unexpected_module_state==0 && account_ui_markers==0 "
        "&& fleet_routes==4 && fleet_guards==2 && secret_routes==3 && secret_adapter==1 "
        "&& terminal_routes==12"
    )
    p4b_observed = {name: observed[name] for name in (
        "module_state_total", "unexpected_module_state", "account_ui_markers", "fleet_routes",
        "fleet_guards", "secret_routes", "secret_adapter", "terminal_routes",
    )}
    p4b_mutant_observed = source_observations(**state_mutant_sources)
    p4b_mutated = {name: p4b_mutant_observed[name] for name in p4b_observed}

    p4c_expected = "fleet_runtime_200==4 && fleet_routes==4 && fleet_guards==2"
    p4c_observed = {
        "fleet_runtime_200": sum(
            code == 200 for (route, _method), code in gate_status.items() if route in FLEET_ROUTES
        ),
        "fleet_routes": observed["fleet_routes"],
        "fleet_guards": observed["fleet_guards"],
    }
    p4c_mutated = {
        **p4c_observed,
        "fleet_runtime_200": sum(
            code == 200 for (route, _method), code in fleet_mutant_status.items()
            if route in FLEET_ROUTES
        ),
    }

    frontend = frontend_observations(
        HUB.read_text(encoding="utf-8"), widget_sources,
        sources["app_source"], sources["index_source"],
    )
    p4d_expected = (
        "pill_base==1 && widget_injections==12 && widget_injection_files==12 "
        "&& widget_bad_bases==0 && legacy_panel_injections==0 && devterm_account_paths==0"
    )
    p4d_mutated = frontend_observations(
        HUB.read_text(encoding="utf-8"), widget_mutant_sources,
        sources["app_source"], sources["index_source"],
    )

    results = (
        evaluate_ac("DTI-P4A", p4a_expected, p4a_observed, p4a_mutated,
                    "add product /account-admin 200 route", "fixture", revision, args.emit_ac),
        evaluate_ac("DTI-P4B", p4b_expected, p4b_observed, p4b_mutated,
                    "add module ACCOUNT_CACHE_V2 mutable state", "fixture", revision, args.emit_ac),
        evaluate_ac("DTI-P4C", p4c_expected, p4c_observed, p4c_mutated,
                    "make product /codex-usage return 404", "fixture", revision, args.emit_ac),
        evaluate_ac("DTI-P4D", p4d_expected, frontend, p4d_mutated,
                    "point data-account-panel at devterm :19913", "fixture", revision, args.emit_ac),
    )
    if not args.emit_ac:
        print(f"devterm account retirement: {'PASS' if all(results) else 'FAIL'}")
    return 0 if all(results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
