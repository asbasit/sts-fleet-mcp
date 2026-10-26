"""
End-to-end check: starts server.py over stdio as a real MCP client would,
lists tools and resources, and calls every tool against a sample fleet.

    python tests/make_sample_fleet.py sample_fleet
    STS_FLEET_DIR=sample_fleet python tests/smoke_test.py
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

SERVER = Path(__file__).resolve().parent.parent / "server.py"


async def main() -> None:
    params = StdioServerParameters(command=sys.executable, args=[str(SERVER)], env=dict(os.environ))
    async with stdio_client(params) as (r, w):
        async with ClientSession(r, w) as s:
            await s.initialize()
            tools = [t.name for t in (await s.list_tools()).tools]
            res = [str(x.uri) for x in (await s.list_resources()).resources]
            print("tools:", tools)
            print("resources:", res)

            async def call(name, **args):
                out = await s.call_tool(name, args)
                assert not getattr(out, "is_error", getattr(out, "isError", False)), out.content
                data = json.loads(out.content[0].text)
                print(f"\n=== {name} {args}\n{json.dumps(data, indent=1)[:2500]}")
                return data

            fs = await call("fleet_status", include_ok=True)
            br = await call("breach_risk", top_n=5)
            ah = await call("account_health", account_id=1003)
            at = await call("account_health", account_id=1007)
            lv = await call("account_health", account_id=1008)
            await call("account_health", account_id=9999)
            rt = await call("recent_trades", account_id=1002, hours=24)
            ct = await call("compare_test_accounts", sort_by="drawdown")
            ev = await call("watchdog_events", since_hours=24, min_level="warn")
            rules = await s.read_resource("fleet://rules")
            assert "internal_buffer" in rules.contents[0].text

            c = fs["counts"]
            assert (c["prop_accounts"], c["test_accounts"], c["BREACH"]) == (4, 4, 1), c
            assert {r["login"] for r in fs["prop_accounts"]} == {1002, 1003, 1004, 1008}
            assert lv["kind"] == "live" and lv["firm"] is None and lv["level"] == "BUFFER_HIT", lv["level"]
            assert not any(ch["limit"].startswith("firm") for ch in lv["checks"])
            assert lv["equity_usd"] == 47.8 and lv["to_breakeven_usd"] == 1652.2 and not lv["issues"], lv
            assert all("level" not in r for r in fs["test_accounts"])
            assert any("broken.json" in e for e in fs["read_errors"])
            assert {r["login"] for r in br["ranked"]} <= {1002, 1003, 1004, 1008}
            assert br["ranked"][0]["login"] == 1003 and br["ranked"][0]["firm_headroom_pct"] == -0.05
            assert ah["level"] == "BREACH" and ah["firm_headroom_pct"] < 0
            assert at["kind"] == "test" and at["level"] is None and at["dd_from_peak_pct"] > 20 and not at["checks"]
            assert ct["accounts"][0]["login"] == 1007
            assert rt["summary"]["closed_trades"] >= 1
            assert all(e["level"] in ("warn", "error") for e in ev["events"])
            print("\nALL CHECKS PASSED")


asyncio.run(main())
