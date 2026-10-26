"""Build a fake fleet folder covering each health state, for testing the server."""
from __future__ import annotations

import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

NOW = datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def status(login, machine, firm, init, dsb, equity, age_sec=30, state="running",
           peak=None, connected=True, algo=True, init_src="input", positions=0, floating=0.0):
    return {
        "schema": 1, "ea_version": "1.0", "state": state,
        "heartbeat_utc": iso(NOW - timedelta(seconds=age_sec)),
        "machine": machine, "firm": firm, "interval_sec": 60,
        "terminal": {"connected": connected, "algo_trading_enabled": algo,
                     "account_allows_experts": True, "ping_ms": 42.0, "build": 4755,
                     "data_path": "C:\\Users\\Administrator\\AppData\\Roaming\\MetaQuotes\\Terminal\\ABC"},
        "account": {"login": login, "server": "Demo-Server", "company": "Demo", "currency": "USD",
                    "leverage": 100, "balance": dsb, "equity": equity, "margin": 0, "margin_free": equity},
        "day": {"server_date": NOW.strftime("%Y-%m-%d"), "start_balance": dsb, "start_equity": dsb,
                "captured_utc": iso(NOW.replace(hour=22, minute=0, second=5) - timedelta(days=1))},
        "initial_balance": init, "initial_balance_source": init_src,
        "peak_equity": peak or max(init, equity),
        "positions": {"count": positions, "floating_pl": floating, "items": []},
    }


def main(root: Path) -> None:
    for sub in ("status", "deals", "events"):
        (root / sub).mkdir(parents=True, exist_ok=True)

    accounts = [
        status(1001, "VPS8", "FTMO", 100_000, 101_000, 100_500),                       # OK
        status(1002, "VPS8", "FTMO", 100_000, 100_000, 96_800, positions=2, floating=-1200),  # WARN (3.2% daily)
        status(1003, "PC1", "FTMO", 100_000, 99_000, 94_000),                          # BREACH firm daily 5.05%
        status(1004, "PC1", "BlueGuardian", 50_000, 50_000, 49_900, age_sec=1800),     # stale, limits unfilled
        status(1005, "PC3", "LiteFinance", 10_000, 9_200, 9_150, init_src="first_seen",
               state="stopped_terminal_closed", age_sec=7200),                         # 8.5% overall loss: inside 1 point of the 9% buffer -> WARN
        status(1006, "PC3", "Unknown Firm", 25_000, 25_000, 25_100, algo=False),       # algo off, unknown firm
        status(1007, "VPS8", "LiteFinance", 10_000, 8_400, 8_000, peak=10_400),          # demo EA test, deep drawdown
        status(1008, "VPS8", "Neotech", 5_010, 5_010, 4_780),                             # live cent recovery acct, -4.6% today
    ]
    accounts[-1]["account"]["currency"] = "USC"
    for a in accounts:
        (root / "status" / f"{a['account']['login']}.json").write_text(json.dumps(a, indent=1))
    (root / "status" / "1001 (asb's conflicted copy).json").write_text("{}")

    # Only these three are prop accounts; everything else is a test account.
    root_dir = Path(__file__).resolve().parent.parent
    rules_file = root_dir / "firm_rules.json"
    if not rules_file.exists():
        rules_file = root_dir / "firm_rules.example.json"
    rules = json.loads(rules_file.read_text())
    rules["accounts"] = {
        "1002": {"type": "challenge", "firm": "FTMO", "phase": "1", "initial_balance": 100000, "label": "FTMO 100k P1"},
        "1003": {"type": "funded", "firm": "FTMO", "initial_balance": 100000},
        "1004": {"type": "funded", "firm": "BlueGuardian", "initial_balance": 50000},
        "1008": {"type": "live", "initial_balance": 5010, "deposit": 170000, "label": "Cent recovery"},
    }
    (root / "firm_rules.json").write_text(json.dumps(rules, indent=2))
    (root / "status" / "broken.json").write_text('{"schema": 1, "acc')

    deals = []
    t = NOW - timedelta(hours=30)
    for i, (sym, pl) in enumerate([("XAUUSD", 120), ("XAUUSD", -80), ("EURUSD", 45),
                                    ("XAUUSD", 210), ("XAUUSD", -150)]):
        t += timedelta(hours=5)
        deals.append({"ticket": 500 + 2 * i, "position_id": 900 + i, "time_utc": iso(t - timedelta(minutes=30)),
                      "symbol": sym, "type": "buy", "entry": "in", "volume": 0.5, "price": 2400.0,
                      "profit": 0, "commission": -3.5, "swap": 0, "magic": 777, "comment": "STS \"Gold\""})
        deals.append({"ticket": 501 + 2 * i, "position_id": 900 + i, "time_utc": iso(t),
                      "symbol": sym, "type": "sell", "entry": "out", "volume": 0.5, "price": 2401.0,
                      "profit": pl, "commission": -3.5, "swap": -1.0, "magic": 777, "comment": "tp"})
    (root / "deals" / "1002.json").write_text(json.dumps(
        {"schema": 1, "login": 1002, "generated_utc": iso(NOW), "server_offset_sec": 10800, "deals": deals}))

    events = [
        {"ts": iso(NOW - timedelta(hours=2)), "machine": "VPS8", "level": "error", "source": "watchdog",
         "message": "terminal for 1002 not responding, restarted", "account_id": 1002},
        {"ts": iso(NOW - timedelta(hours=1)), "machine": "VPS8", "level": "info", "source": "watchdog",
         "message": "daily health check passed"},
        {"ts": iso(NOW - timedelta(hours=40)), "machine": "VPS8", "level": "warn", "source": "watchdog",
         "message": "old event outside 24h window"},
    ]
    with (root / "events" / "VPS8.jsonl").open("w") as fh:
        for e in events:
            fh.write(json.dumps(e) + "\n")
        fh.write('{"ts": "half-writ')  # simulate a line mid-sync
    with (root / "events" / "ASB-PC1.jsonl").open("w") as fh:
        fh.write(json.dumps({"ts": iso(NOW - timedelta(minutes=10)), "machine": "ASB-PC1",
                             "level": "warn", "source": "btc-node",
                             "message": "bitcoind peers dropped to 3"}) + "\n")


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "sample_fleet"))
