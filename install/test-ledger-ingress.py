#!/usr/bin/env python3
"""Run ingress ownership/compensation through real CLI, config and projection."""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = Path(os.environ.get("AIRLOCK_INGRESS_TEST_SCRATCH", str(Path.home() / "scratch/airlock-test-ledger-ingress")))
ARTIFACTS.mkdir(parents=True, exist_ok=True)

TOOL_STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
base = pathlib.Path(os.environ["INGRESS_FIXTURE"])
args = sys.argv[1:]
name = pathlib.Path(sys.argv[0]).name
with (base / "calls.jsonl").open("a") as handle:
    handle.write(json.dumps([name, *args]) + "\n")
fault_path = base / "faults.json"
faults = json.loads(fault_path.read_text())
if name == "systemctl":
    if args == ["reload", "nginx"] and faults.get("reload", 0):
        faults["reload"] -= 1
        fault_path.write_text(json.dumps(faults))
        raise SystemExit(42)
    if "show" in args:
        print("LoadState=loaded\nActiveState=inactive\nMainPID=0\nControlPID=0")
    raise SystemExit(0)
state_path = base / "serve.json"
state = json.loads(state_path.read_text())
if args == ["serve", "status", "--json"]:
    print(json.dumps({"TCP": {token.split(":")[1]: {"HTTPS" if token.startswith("https:") else "HTTP": True} for token in state}}))
    raise SystemExit(0)
if args == ["status", "--json"]:
    print('{"BackendState":"Running","Self":{"DNSName":"fixture.example.ts.net."}}')
    raise SystemExit(0)
assert args[0] == "serve", args
flag = next(arg for arg in args if arg.startswith(("--http=", "--https=")))
mode, port = flag[2:].split("=")
token = mode + ":" + port
if args[-1] == "off":
    counts = faults.setdefault("off_counts", {})
    counts[token] = counts.get(token, 0) + 1
    fail = token in faults.get("off", []) or counts[token] == faults.get("off_nth", {}).get(token)
    fault_path.write_text(json.dumps(faults))
    if fail:
        raise SystemExit(42)
    state.pop(token, None)
else:
    remaining = faults.get("on", {}).get(token, 0)
    if remaining:
        faults["on"][token] = remaining - 1
        fault_path.write_text(json.dumps(faults))
        raise SystemExit(42)
    state[token] = args[-1]
state_path.write_text(json.dumps(state))
'''


class IngressTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="case-", dir=ARTIFACTS)
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        for name in ("home", "state", "data", "web", "confd", "site", "units-user", "units-system", "shim"):
            (self.base / name).mkdir()
        self.env = {key: value for key, value in os.environ.items()
                    if (not key.startswith(("AIRLOCK_", "GIT_"))
                        or key.startswith("AIRLOCK_TEST_GUARD"))
                    and key not in {"PYTHONPATH", "PYTHONHOME"}}
        self.env.update({"HOME": str(self.base / "home"), "INGRESS_FIXTURE": str(self.base),
                         "PATH": str(self.base / "shim") + os.pathsep + os.environ["PATH"],
                         "AIRLOCK_FIXTURE_ROOT": str(self.base), "AIRLOCK_TS_FQDN": "fixture.example.ts.net",
                         "AIRLOCK_CONFIG": str(self.base / "airlock.toml"),
                         "AIRLOCK_STATE_DIR": str(self.base / "state"), "AIRLOCK_DATA_DIR": str(self.base / "data"),
                         "AIRLOCK_WEBROOT": str(self.base / "web"), "AIRLOCK_CONFD": str(self.base / "confd"),
                         "AIRLOCK_NGINX_SITE": str(self.base / "site/airlock.conf"),
                         "AIRLOCK_UNIT_DIR_USER": str(self.base / "units-user"),
                         "AIRLOCK_UNIT_DIR_SYSTEM": str(self.base / "units-system"),
                         "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"})
        for name in ("tailscale", "systemctl"):
            self.write(self.base / "shim" / name, TOOL_STUB, executable=True)
        self.write(self.base / "shim/sudo", '#!/bin/sh\nexec "$@"\n', executable=True)
        self.write(self.base / "shim/nginx", "#!/bin/sh\nexit 0\n", executable=True)
        self.put("faults.json", {})
        self.put("serve.json", {"http:9999": "operator"})
        self.configure()
        self.log = ARTIFACTS / (self._testMethodName + ".log")
        self.log.write_text("")
        self.addCleanup(self.save_evidence)

    def save_evidence(self):
        evidence = {"serve": self.read("serve.json"), "faults": self.read("faults.json"),
                    "calls": [json.loads(line) for line in (self.base / "calls.jsonl").read_text().splitlines()]
                    if (self.base / "calls.jsonl").exists() else []}
        self.log.with_suffix(".json").write_text(json.dumps(evidence, indent=2) + "\n")

    def write(self, path, value, *, executable=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)
        if executable:
            path.chmod(0o755)

    def put(self, relative, value):
        self.write(self.base / relative, json.dumps(value) + "\n")

    def read(self, relative):
        return json.loads((self.base / relative).read_bytes())

    def configure(self, *, http=19901, company=""):
        self.write(self.base / "airlock.toml", '[site]\nname = "Ingress fixture"\n'
                   + (f'company_repo = "{company}"\n' if company else "")
                   + '[auth]\nprovider = "tailscale"\nowner = "owner@fixture.invalid"\n'
                   + f'[apps.hub]\nhttp_port = {http}\nnginx_port = 19002\nredirect_port = 19003\n')

    def command(self, *args, ok=True, stdin=""):
        result = subprocess.run(args, env=self.env, input=stdin, text=True, capture_output=True, timeout=90)
        with self.log.open("a") as handle:
            handle.write(f"$ {args!r}\nrc={result.returncode}\n{result.stdout}{result.stderr}\n")
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def ledger(self, *args, ok=True):
        info = {"company_repo": self.company_url} if hasattr(self, "company_url") else {}
        return self.command(sys.executable, str(ROOT / "bin/airlock-ledger"), *args, ok=ok, stdin=json.dumps(info))

    def loaded(self):
        code = ('from importlib.machinery import SourceFileLoader\nimport json,sys\n'
                'sys.dont_write_bytecode=True\n'
                'm=SourceFileLoader("ingress_read",sys.argv[1]).load_module()\n'
                'print(json.dumps(m.load_installed()))\n')
        return json.loads(self.command(sys.executable, "-c", code, str(ROOT / "bin/airlock-ledger")).stdout)

    def local_app(self, app):
        directory = self.base / "sources" / app
        self.write(directory / "airlock-app.toml", f'contract = 1\nid = "{app}"\n')
        for hook in ("install.sh", "smoke.sh"):
            self.write(directory / hook, "#!/bin/sh\nexit 0\n")
        return directory

    def legacy(self, *, beta=False):
        entries = {"devterm": {"committed": {"path": str(ROOT / "apps/devterm"),
                   "artifacts": {"serve_ports": [8443]},
                   "serve_mappings": {"tls": {"listen": 8443, "mode": "https", "target": 19010}}}}}
        history = [{"package": "devterm", "listen": 45678, "target": 19011, "state": "committed"}]
        served = {"https:8443": "old", "http:45678": "old", "http:9999": "operator"}
        if beta:
            entries["beta"] = {"committed": {"path": str(self.local_app("beta")), "artifacts": {"serve_ports": [45678, 45679]}}}
            history += [{"package": "devterm", "listen": 45680, "target": 19012, "state": "intent"},
                        {"package": "beta", "listen": 45681, "target": 19013, "state": "committed"}]
            served.update({"http:45678": "beta", "http:45679": "beta", "http:45681": "beta", "http:45680": "uncommitted"})
        self.put("state/app-ledger.json", {"version": 7, "entries": entries, "events": []})
        self.put("state/plaintext-retirement.json", {"version": 1, "entries": sorted(history, key=lambda row: (row["package"], row["listen"]))})
        self.put("serve.json", served)

    def assert_operator(self):
        self.assertEqual(self.read("serve.json")["http:9999"], "operator")

    def test_legacy_https_and_aux_http_transfer_read_only_then_remove(self):
        self.legacy()
        before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in (self.base / "state").iterdir()}
        self.assertEqual(set(self.loaded()["devterm"]["artifacts"]), {"https:8443", "http:45678"})
        self.ledger("plan")
        after = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in (self.base / "state").iterdir()}
        self.assertEqual(before, after)
        self.ledger("remove", "devterm")
        self.assertNotIn("https:8443", self.read("serve.json"))
        self.assertNotIn("http:45678", self.read("serve.json"))
        self.assertNotIn("devterm", self.loaded())
        self.assert_operator()

    def test_legacy_intent_and_other_owner_do_not_merge_or_retire(self):
        self.legacy(beta=True)
        rows = self.loaded()
        self.assertEqual(set(rows["devterm"]["artifacts"]), {"https:8443", "http:45678"})
        self.assertEqual(set(rows["beta"]["artifacts"]), {"http:45678", "http:45679", "http:45681"})
        self.ledger("remove", "devterm")
        self.assertEqual(rows["beta"], self.loaded()["beta"])
        for token in ("http:45678", "http:45679", "http:45681", "http:45680"):
            self.assertIn(token, self.read("serve.json"))
        self.assert_operator()

    def test_project_retires_old_hub_default_and_keeps_operator(self):
        self.put("serve.json", {"http:19901": "old-hub", "http:9999": "operator"})
        self.configure(http=19902)
        self.ledger("project")
        self.assertNotIn("http:19901", self.read("serve.json"))
        self.assertIn("http:19902", self.read("serve.json"))
        self.assert_operator()

    def test_core_teardown_and_project_preserve_noncore_shared_http(self):
        self.legacy(beta=True)
        beta_bytes = json.dumps(self.loaded()["beta"], sort_keys=True).encode()
        beta_tokens = ("http:45678", "http:45679", "http:45681")
        beta_maps = {token: self.read("serve.json")[token] for token in beta_tokens}
        code = ('from importlib.machinery import SourceFileLoader\nimport sys\n'
                'sys.dont_write_bytecode=True\n'
                'm=SourceFileLoader("ingress_teardown",sys.argv[1]).load_module()\n'
                'raise SystemExit(m.teardown_installed(core_root=sys.argv[2]))\n')
        self.command(sys.executable, "-c", code, str(ROOT / "bin/airlock-ledger"), str(ROOT))
        for phase in ("after core teardown", "after core project"):
            with self.subTest(phase=phase):
                rows = self.loaded()
                self.assertNotIn("devterm", rows)
                self.assertEqual(beta_bytes, json.dumps(rows["beta"], sort_keys=True).encode())
                served = self.read("serve.json")
                self.assertEqual(beta_maps, {token: served.get(token) for token in beta_tokens})
                self.assertNotIn("https:8443", served)
                self.assert_operator()
            if phase == "after core teardown":
                self.ledger("project")

    def test_remove_off_failure_retains_ownership_and_retries(self):
        self.legacy()
        before = self.loaded()["devterm"]
        self.put("faults.json", {"off": ["http:45678"]})
        self.ledger("remove", "devterm", ok=False)
        self.assertEqual(before, self.loaded()["devterm"])
        self.assertIn("http:45678", self.read("serve.json"))
        self.assertTrue(any(row["listen"] == 45678 for row in self.read("state/plaintext-retirement.json")["entries"]))
        self.put("faults.json", {})
        self.ledger("remove", "devterm")
        self.assertNotIn("http:45678", self.read("serve.json"))
        self.assertNotIn("devterm", self.loaded())
        self.assert_operator()

    def company(self, *, ports=(45678,), files=("alpha.old",), icon="old.svg", fail_hook=False):
        directory = self.base / "company/apps/alpha"
        defaults = "\n".join(f"p{i}_port = {port}" for i, port in enumerate(ports))
        serve = ", ".join(f'"p{i}_port"' for i in range(len(ports)))
        declared = ", ".join(f'"~/{name}"' for name in files)
        self.write(directory / "airlock-app.toml", f'contract = 1\nid = "alpha"\n[config.defaults]\n{defaults}\n[artifacts]\nfiles = [{declared}]\nserve_ports = [{serve}]\n[tile]\nlabel = "Alpha"\ncat = "apps"\nicon = "{icon}"\n')
        body = "#!/bin/sh\nset -eu\n"
        body += "\n".join(f'printf "owned-{name}\\n" >"$HOME/{name}"' for name in files if name != "user.keep") + "\n"
        body += "exit 42\n" if fail_hook else "exit 0\n"
        self.write(directory / "install.sh", body)
        self.write(directory / "smoke.sh", "#!/bin/sh\nexit 0\n")
        self.write(directory / icon, f'<svg xmlns="http://www.w3.org/2000/svg"><title>{icon}</title></svg>\n')
        if not (self.base / "company/.git").exists():
            self.command("git", "-C", str(self.base / "company"), "init", "-q", "-b", "main")
        self.command("git", "-C", str(self.base / "company"), "add", "-A")
        self.command("git", "-C", str(self.base / "company"), "-c", "user.name=fixture", "-c", "user.email=fixture@invalid", "commit", "-q", "-m", "fixture version")
        self.company_url = "file://" + str(self.base / "company")
        self.configure(company=self.company_url)
        return self.command("git", "-C", str(self.base / "company"), "rev-parse", "HEAD").stdout.strip()

    def test_upgrade_cleanup_failure_keeps_new_row_with_old_token_for_retry(self):
        self.company()
        self.ledger("apply", "alpha", "--source", "company")
        newest = self.company(ports=(45679,), files=("alpha.new",))
        # Project retires the live stale port first. Fail the later explicit
        # old-resource cleanup, rather than conflating it with projection failure.
        self.put("faults.json", {"off_nth": {"http:45678": 2}})
        self.ledger("apply", "alpha", "--source", "company", ok=False)
        row = self.loaded()["alpha"]
        self.assertEqual(row["commit"], newest)
        self.assertIn("http:45678", row["artifacts"])
        self.assertIn("http:45679", row["artifacts"])
        self.assertFalse((self.base / "home/alpha.old").exists())
        self.assertTrue((self.base / "home/alpha.new").exists())
        self.put("faults.json", {})
        self.ledger("apply", "alpha", "--source", "company")
        self.assertNotIn("http:45678", self.loaded()["alpha"]["artifacts"])
        self.assertNotIn("http:45678", self.read("serve.json"))
        self.assert_operator()

    def compensated_upgrade(self, fault):
        self.company()
        self.ledger("apply", "alpha", "--source", "company")
        original = self.loaded()["alpha"]
        old_bytes = {path: Path(path).read_bytes() for path in original["artifacts"] if path.startswith("/") and Path(path).is_file()}
        self.write(self.base / "home/user.keep", "user data\n")
        self.company(ports=(45678, 45679, 45680), files=("alpha.old", "alpha.new", "user.keep"), icon="new.svg", fail_hook=fault == "hook")
        if fault == "project":
            self.put("faults.json", {"reload": 1})
        elif fault == "ingress":
            self.put("faults.json", {"on": {"http:45680": 1}})
        result = self.ledger("apply", "alpha", "--source", "company", ok=False)
        self.assertIn("restored alpha", result.stderr)
        self.assertEqual(original, self.loaded()["alpha"])
        for path, content in old_bytes.items():
            self.assertEqual(Path(path).read_bytes(), content)
        self.assertFalse((self.base / "home/alpha.new").exists())
        self.assertFalse((self.base / "web/assets/apps/alpha/new.svg").exists())
        self.assertEqual((self.base / "home/user.keep").read_text(), "user data\n")
        self.assertIn("http:45678", self.read("serve.json"))
        self.assertNotIn("http:45679", self.read("serve.json"))
        self.assertNotIn("http:45680", self.read("serve.json"))
        self.assert_operator()

    def test_upgrade_hook_failure_compensates_only_this_attempt(self):
        self.compensated_upgrade("hook")

    def test_upgrade_project_failure_compensates_only_this_attempt(self):
        self.compensated_upgrade("project")

    def test_upgrade_later_ingress_failure_compensates_earlier_new_mapping(self):
        self.compensated_upgrade("ingress")

    def test_remove_missing_config_id_uses_recorded_removal(self):
        self.legacy()
        self.ledger("remove", "devterm")
        self.assertNotIn("devterm", self.loaded())
        self.assertNotIn("https:8443", self.read("serve.json"))
        self.assertNotIn("http:45678", self.read("serve.json"))
        self.assert_operator()


if __name__ == "__main__":
    unittest.main(verbosity=2)
