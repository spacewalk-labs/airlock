#!/usr/bin/env python3
"""Unit tests for _agy_accounts fleet store merging in airlock-accounts-api."""
import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
API_PATH = ROOT / "bin" / "airlock-accounts-api"

loader = importlib.machinery.SourceFileLoader("airlock_accounts_api_test", str(API_PATH))
spec = importlib.util.spec_from_loader("airlock_accounts_api_test", loader)
api = importlib.util.module_from_spec(spec)
loader.exec_module(api)


def test_agy_accounts_merge():
    with tempfile.TemporaryDirectory() as td:
        tdp = Path(td)
        local_store = tdp / "agy-usage-accounts.json"
        fleet_store = tdp / ".fleet-agy-usage.json"

        api.AGY_USAGE_BY_ACCOUNT = str(local_store)
        api.AGY_FLEET_STORE = str(fleet_store)

        # Mock _cli to return two accounts: active and saved
        api._cli = lambda args, **kw: (
            True,
            json.dumps({
                "accounts": [
                    {"email": "active@example.com", "active": True},
                    {"email": "saved@example.com", "active": False},
                ]
            }),
            "",
        )

        # 1. Local only
        local_data = {
            "active@example.com": {"groups": [{"name": "G_local_act"}], "observedAt": 1000},
            "saved@example.com": {"groups": [{"name": "G_local_saved"}], "observedAt": 500},
        }
        local_store.write_text(json.dumps(local_data), encoding="utf-8")
        if fleet_store.exists():
            fleet_store.unlink()

        res1 = {r["email"]: r for r in api._agy_accounts()}
        assert res1["active@example.com"]["groups"] == [{"name": "G_local_act"}]
        assert res1["saved@example.com"]["groups"] == [{"name": "G_local_saved"}]
        print("ok: 1. local only succeeds")

        # 2. Fleet has newer observation for saved account
        fleet_data = {
            "saved@example.com": {"groups": [{"name": "G_fleet_newer"}], "observedAt": 2000},
            "active@example.com": {"groups": [{"name": "G_fleet_older"}], "observedAt": 900},
        }
        fleet_store.write_text(json.dumps(fleet_data), encoding="utf-8")

        res2 = {r["email"]: r for r in api._agy_accounts()}
        # saved@example.com should get the newer fleet data
        assert res2["saved@example.com"]["groups"] == [{"name": "G_fleet_newer"}]
        # active@example.com should retain the newer local data
        assert res2["active@example.com"]["groups"] == [{"name": "G_local_act"}]
        print("ok: 2. fleet newer wins for saved, local newer wins for active")

        # 3. Fleet has invalid JSON - graceful fallback
        fleet_store.write_text("invalid json", encoding="utf-8")
        res3 = {r["email"]: r for r in api._agy_accounts()}
        assert res3["saved@example.com"]["groups"] == [{"name": "G_local_saved"}]
        print("ok: 3. invalid fleet store falls back gracefully")


if __name__ == "__main__":
    test_agy_accounts_merge()
    print("all agy accounts merge tests passed")
