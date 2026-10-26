"""
sts-fleet: read-only MCP server for STS fleet health.

Reads the status / deals / events files that STS_Heartbeat.mq5 and the
watchdogs write into a Dropbox-synced folder, and answers questions like
"which account is closest to breaching?" No tool here can trade, close,
restart or change anything.

Run:   python server.py            (stdio, for Claude Code / Claude Desktop)
Env:   STS_FLEET_DIR  path to the fleet folder (default ~/Dropbox/ClaudeHub/fleet)
"""
from __future__ import annotations

import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

try:  # mcp 2.x
    from mcp.server.mcpserver import MCPServer as _Server
except ImportError:  # mcp 1.x
    from mcp.server.fastmcp import FastMCP as _Server
try:
    from mcp.types import ToolAnnotations
    READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True,
                                openWorldHint=False)
except ImportError:
    READ_ONLY = None

VERSION = "0.1.0"
HERE = Path(__file__).resolve().parent
FLEET_DIR = Path(
    os.environ.get("STS_FLEET_DIR", str(Path.home() / "Dropbox" / "ClaudeHub" / "fleet"))
).expanduser()

LEVEL_ORDER = {"OK": 0, "WARN": 1, "BUFFER_HIT": 2, "BREACH": 3}
EVENT_LEVELS = {"info": 0, "warn": 1, "error": 2}

mcp = _Server(
    "sts-fleet",
    instructions=(
        "Read-only health view of the STS MT5 fleet. Most accounts are test accounts running EAs; "
        "accounts tagged challenge or funded are prop accounts with firm limits, and accounts tagged live "
        "are real-money accounts checked against the STS buffer only. Cent accounts (USC) also show *_usd figures. "
        "Start with fleet_status; use breach_risk for prop accounts and compare_test_accounts for EA tests. "
        "Loss figures are percentages of the limit's basis; headroom is percentage points left. "
        "Treat STALE accounts' numbers as out of date. This server cannot trade or change anything."
    ),
)


# --------------------------------------------------------------------------- #
# Loading
# --------------------------------------------------------------------------- #
def _now() -> datetime:
    return datetime.now(timezone.utc)


def _parse_ts(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _iso(dt: datetime | None) -> str | None:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if dt else None


def _skip(p: Path) -> bool:
    # Dropbox leaves "(... conflicted copy ...)" files around; never trust them.
    return "conflicted copy" in p.name.lower() or p.name.startswith(".")


def _read_json(p: Path) -> Any:
    return json.loads(p.read_text(encoding="utf-8-sig"))


def load_rules() -> dict:
    for p in (FLEET_DIR / "firm_rules.json", HERE / "firm_rules.json", HERE / "firm_rules.example.json"):
        if p.exists():
            rules = _read_json(p)
            rules["_source"] = str(p)
            return rules
    return {
        "internal_buffer": {"daily_loss_pct": 4.0, "max_loss_pct": 9.0},
        "warn_margin_pct": 1.0,
        "stale_after_sec": 300,
        "firms": {},
        "accounts": {},
        "_source": "built-in defaults",
    }


def load_statuses() -> tuple[list[dict], list[str]]:
    folder = FLEET_DIR / "status"
    statuses, errors = [], []
    if not folder.is_dir():
        return [], [f"status folder not found: {folder}"]
    for p in sorted(folder.glob("*.json")):
        if _skip(p):
            continue
        try:
            data = _read_json(p)
            data["_file"] = p.name
            statuses.append(data)
        except Exception as exc:  # partial write mid-sync, bad JSON, locked file
            errors.append(f"{p.name}: {exc}")
    return statuses, errors


def load_events() -> list[dict]:
    folder = FLEET_DIR / "events"
    out: list[dict] = []
    if not folder.is_dir():
        return out
    for p in sorted(folder.glob("*.jsonl")):
        if _skip(p):
            continue
        try:
            lines = p.read_text(encoding="utf-8-sig").splitlines()
        except Exception:
            continue
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue  # half-written last line during sync
            ev.setdefault("machine", p.stem)
            out.append(ev)
    return out


# --------------------------------------------------------------------------- #
# Health maths
# --------------------------------------------------------------------------- #
# Accounts that get risk checks. challenge/funded: firm limits + STS buffer.
# live: real-money broker account, STS buffer only (no firm).
PROP_TYPES = ("challenge", "funded", "live")
CENT_CURRENCIES = ("USC", "EUC", "GBC")


def _account_tag(rules: dict, login: Any) -> dict:
    """The entry for this login under "accounts" in firm_rules.json, or {} (= test account)."""
    tag = (rules.get("accounts") or {}).get(str(login)) or {}
    return tag if isinstance(tag, dict) else {}


def _effective_limits(rules: dict, firm: str, tag: dict) -> dict:
    firm_rules = dict(rules.get("firms", {}).get(firm) or {})
    for k in ("daily_loss_pct", "max_loss_pct", "daily_basis", "max_basis"):
        if tag.get(k) is not None:
            firm_rules[k] = tag[k]
    firm_rules.setdefault("daily_basis", "day_start_balance")
    firm_rules.setdefault("max_basis", "static")
    firm_rules["_firm_known"] = firm in rules.get("firms", {})
    return firm_rules


def _pct(num: float, den: float | None) -> float | None:
    if not den:
        return None
    return round(num / den * 100.0, 2)


def compute_health(st: dict, rules: dict, now: datetime) -> dict:
    acct = st.get("account") or {}
    term = st.get("terminal") or {}
    day = st.get("day") or {}
    login = acct.get("login")
    tag = _account_tag(rules, login)
    kind = str(tag.get("type", "test")).lower()
    is_prop = kind in PROP_TYPES
    broker_hint = st.get("firm") or acct.get("company") or "UNKNOWN"
    firm = tag.get("firm") or (None if kind == "live" else broker_hint)
    stale_after = int(rules.get("stale_after_sec", 300))

    equity = float(acct.get("equity") or 0)
    dsb = day.get("start_balance")
    dse = day.get("start_equity")
    initial = float(tag["initial_balance"]) if tag.get("initial_balance") else st.get("initial_balance")
    peak = max(float(st.get("peak_equity") or 0), equity) or None

    # Measured for every account, prop or test. Signed: positive = gain.
    day_pl_pct = _pct(equity - (dsb or 0), dsb) if dsb else None
    growth_pct = _pct(equity - (initial or 0), initial) if initial else None
    dd_from_peak_pct = _pct((peak or 0) - equity, peak) if peak else None

    # Operational problems matter for every account.
    hb = _parse_ts(st.get("heartbeat_utc"))
    age = int((now - hb).total_seconds()) if hb else None
    state = st.get("state", "running")
    stale = age is None or age > stale_after
    issues = []
    if stale:
        issues.append(f"heartbeat stale ({age}s old)" if age is not None else "no valid heartbeat time")
    if state != "running":
        issues.append(f"heartbeat EA reported {state}")
    if term and not term.get("connected", True):
        issues.append("terminal disconnected from broker")
    if term and not term.get("algo_trading_enabled", True):
        issues.append("Algo Trading button is off")
    if term and not term.get("account_allows_experts", True):
        issues.append("account does not allow experts")

    # Cent accounts report in cents; give dollar figures alongside.
    cur = str(acct.get("currency") or "")
    cent = bool(tag.get("cent")) or cur.upper() in CENT_CURRENCIES
    div = 100.0 if cent else 1.0
    deposit = float(tag["deposit"]) if tag.get("deposit") else None

    pos = st.get("positions") or {}
    out = {
        "login": login,
        "kind": kind if is_prop else "test",
        "label": tag.get("label"),
        "firm": firm if is_prop else None,
        "broker": broker_hint,
        "machine": st.get("machine"),
        "trade_mode": acct.get("trade_mode"),
        "level": None,
        "stale": stale,
        "heartbeat_age_sec": age,
        "state": state,
        "equity": equity,
        "balance": acct.get("balance"),
        "currency": acct.get("currency"),
        "day_pl_pct": day_pl_pct,
        "growth_pct": growth_pct,
        "dd_from_peak_pct": dd_from_peak_pct,
        "open_positions": pos.get("count", 0),
        "floating_pl": pos.get("floating_pl"),
        "issues": issues,
        "_checks": [],
        **({"cent_account": True, "equity_usd": round(equity / div, 2),
            "balance_usd": round(float(acct.get("balance") or 0) / div, 2)} if cent else {}),
        **({"deposit": deposit, "deposit_usd": round(deposit / div, 2),
            "recovered_pct_of_deposit": _pct(equity, deposit),
            "to_breakeven_usd": round((deposit - equity) / div, 2)} if deposit else {}),
        "_limits": {},
    }
    if not is_prop:
        return out

    # ---- prop accounts only: firm limits + STS internal buffer -------------
    if kind == "live":
        limits = {"daily_basis": tag.get("daily_basis", "day_start_balance"),
                  "max_basis": tag.get("max_basis", "static"), "_firm_known": True}
    else:
        limits = _effective_limits(rules, firm, tag)
    buf = dict(rules.get("internal_buffer", {}))
    for k in ("buffer_daily_pct", "buffer_overall_pct"):
        if tag.get(k) is not None:
            buf["daily_loss_pct" if k == "buffer_daily_pct" else "max_loss_pct"] = tag[k]
    warn_margin = float(rules.get("warn_margin_pct", 1.0))

    basis = limits["daily_basis"]
    if basis == "day_start_equity":
        day_ref = dse
    elif basis == "day_start_max":
        day_ref = max(x for x in (dsb, dse) if x is not None) if (dsb or dse) else None
    else:
        day_ref = dsb
    daily_loss = _pct((day_ref or 0) - equity, day_ref)
    if limits["max_basis"] == "trailing":
        overall_loss = _pct((peak or 0) - equity, initial)
    else:
        overall_loss = _pct((initial or 0) - equity, initial)

    # Headroom = limit minus current loss, in percentage points. Negative means past it.
    checks = []
    for name, limit, loss in (
        ("firm_daily", limits.get("daily_loss_pct"), daily_loss),
        ("firm_overall", limits.get("max_loss_pct"), overall_loss),
        ("buffer_daily", buf.get("daily_loss_pct"), daily_loss),
        ("buffer_overall", buf.get("max_loss_pct"), overall_loss),
    ):
        if limit is None or loss is None:
            continue
        checks.append({"limit": name, "limit_pct": limit, "loss_pct": loss,
                       "headroom_pct": round(limit - loss, 2)})

    level = "OK"
    for c in checks:
        if c["headroom_pct"] <= 0:
            lvl = "BREACH" if c["limit"].startswith("firm") else "BUFFER_HIT"
        elif c["limit"].startswith("buffer") and c["headroom_pct"] <= warn_margin:
            lvl = "WARN"
        else:
            continue
        if LEVEL_ORDER[lvl] > LEVEL_ORDER[level]:
            level = lvl
    nearest = min(checks, key=lambda c: c["headroom_pct"]) if checks else None
    firm_checks = [c for c in checks if c["limit"].startswith("firm")]
    firm_nearest = min(firm_checks, key=lambda c: c["headroom_pct"]) if firm_checks else None

    if kind != "live":
        if not limits["_firm_known"]:
            issues.append(f"firm '{firm}' not in firm_rules.json, buffer only")
        elif limits.get("daily_loss_pct") is None or limits.get("max_loss_pct") is None:
            issues.append(f"firm limits for {firm} not filled in, buffer only")
        if not tag.get("firm"):
            issues.append(f"no firm in this account's tag, guessed '{firm}' from broker")
    cap = _parse_ts(day.get("captured_utc"))
    if cap and day_ref and cap.hour not in (21, 22, 23, 0, 1):
        issues.append("day start captured mid-day, daily loss is approximate")
    if not tag.get("initial_balance") and st.get("initial_balance_source") == "first_seen":
        issues.append("no initial_balance in this account's tag (using first balance seen)")

    out.update({
        "level": level,
        "phase": tag.get("phase"),
        "buffer_applied": {"daily_loss_pct": buf.get("daily_loss_pct"), "max_loss_pct": buf.get("max_loss_pct")},
        "daily_loss_pct": daily_loss,
        "overall_loss_pct": overall_loss,
        "nearest_limit": nearest,
        "firm_headroom_pct": firm_nearest["headroom_pct"] if firm_nearest else None,
        "firm_nearest_limit": firm_nearest["limit"] if firm_nearest else None,
        "_checks": checks,
        "_limits": {k: v for k, v in limits.items() if not k.startswith("_")},
    })
    return out


def _row(h: dict) -> dict:
    return {k: v for k, v in h.items() if not k.startswith("_")}


def _all_health() -> tuple[list[dict], list[str], dict]:
    rules = load_rules()
    statuses, errors = load_statuses()
    now = _now()
    return [compute_health(s, rules, now) for s in statuses], errors, rules


# --------------------------------------------------------------------------- #
# Tools
# --------------------------------------------------------------------------- #
@mcp.tool(annotations=READ_ONLY)
def fleet_status(include_ok: bool = True) -> dict:
    """Overview of every machine and MT5 account in the STS fleet.

    Accounts come in two groups. Risk-checked accounts (tagged challenge,
    funded or live in firm_rules.json; live = real money, STS buffer only) are risk-checked against firm limits and the STS buffer
    and get a level: OK / WARN / BUFFER_HIT / BREACH. Every other account is a
    test account: measured (day P&L, growth, drawdown from peak) and checked
    for operational problems (stale, disconnected, algo off), but never
    judged against prop rules. Set include_ok=False to list only what needs
    attention.
    """
    healths, errors, rules = _all_health()
    now = _now()

    machines: dict[str, dict] = {}
    for h in healths:
        m = machines.setdefault(h["machine"] or "UNSET", {"accounts": 0, "last_heartbeat_age_sec": None})
        m["accounts"] += 1
        age = h["heartbeat_age_sec"]
        if age is not None and (m["last_heartbeat_age_sec"] is None or age < m["last_heartbeat_age_sec"]):
            m["last_heartbeat_age_sec"] = age
    stale_after = int(rules.get("stale_after_sec", 300))
    for m in machines.values():
        age = m["last_heartbeat_age_sec"]
        m["stale"] = age is None or age > stale_after

    # Machines that only appear in the event logs (e.g. watchdog hosts with no MT5 heartbeat).
    cutoff = now - timedelta(hours=24)
    for ev in load_events():
        ts = _parse_ts(ev.get("ts"))
        name = ev.get("machine")
        if not name or not ts or ts < cutoff:
            continue
        m = machines.setdefault(name, {"accounts": 0, "last_heartbeat_age_sec": None, "stale": None})
        age = int((now - ts).total_seconds())
        if m.get("last_event_age_sec") is None or age < m["last_event_age_sec"]:
            m["last_event_age_sec"] = age

    prop = [h for h in healths if h["kind"] in PROP_TYPES]
    test = [h for h in healths if h["kind"] not in PROP_TYPES]
    counts = {lvl: sum(1 for h in prop if h["level"] == lvl) for lvl in LEVEL_ORDER}
    counts["prop_accounts"] = len(prop)
    counts["test_accounts"] = len(test)
    counts["STALE"] = sum(1 for h in healths if h["stale"])
    counts["test_with_issues"] = sum(1 for h in test if h["issues"])

    prop_rows = [_row(h) for h in prop]
    test_rows = [_row(h) for h in test]
    if not include_ok:
        prop_rows = [r for r in prop_rows if r["level"] != "OK" or r["issues"]]
        test_rows = [r for r in test_rows if r["issues"]]
    prop_rows.sort(key=lambda r: (-LEVEL_ORDER[r["level"]], not r["stale"], r["login"] or 0))
    test_rows.sort(key=lambda r: (not r["issues"], r["machine"] or "", r["login"] or 0))
    # Test accounts are monitored, not risk-checked: drop prop-only fields.
    test_rows = [{k: v for k, v in r.items() if k not in ("level", "firm", "kind")} for r in test_rows]

    return {
        "generated_utc": _iso(now),
        "fleet_dir": str(FLEET_DIR),
        "rules_source": rules.get("_source"),
        "counts": counts,
        "machines": machines,
        "prop_accounts": prop_rows,
        "test_accounts": test_rows,
        "read_errors": errors,
    }


@mcp.tool(annotations=READ_ONLY)
def account_health(account_id: int) -> dict:
    """Full detail for one MT5 account (by login number).

    For prop accounts: daily and overall loss against the firm's hard limits
    and the STS internal buffer (default 4% daily / 9% overall), with headroom
    to each. For test accounts: performance and operational state only.
    Both include terminal state, open positions and data-quality warnings.
    """
    rules = load_rules()
    statuses, errors = load_statuses()
    for st in statuses:
        if (st.get("account") or {}).get("login") == account_id:
            h = compute_health(st, rules, _now())
            return {
                **_row(h),
                "checks": h["_checks"],
                "limits_applied": h["_limits"],
                "internal_buffer": rules.get("internal_buffer") if h["kind"] in PROP_TYPES else None,
                "terminal": st.get("terminal"),
                "day": st.get("day"),
                "initial_balance": st.get("initial_balance"),
                "peak_equity": st.get("peak_equity"),
                "positions": (st.get("positions") or {}).get("items", []),
                "heartbeat_utc": st.get("heartbeat_utc"),
                "ea_version": st.get("ea_version"),
            }
    known = sorted((s.get("account") or {}).get("login") for s in statuses)
    return {"error": f"no status file for account {account_id}", "known_accounts": known,
            "read_errors": errors}


@mcp.tool(annotations=READ_ONLY)
def breach_risk(top_n: int = 10) -> dict:
    """Prop accounts (challenge / funded) ranked by how close they are to
    their nearest loss limit. Test accounts are never included.

    Headroom is in percentage points of the limit's basis (e.g. 1.2 means
    1.2% left before that limit). Negative headroom means the limit is
    already passed. `headroom_pct` is against the tightest limit (usually the
    STS internal buffer); `firm_headroom_pct` is against the prop firm's own
    hard limit, null when that firm's limits aren't filled in. Stale accounts are included and flagged, since their
    numbers may be out of date.
    """
    healths, errors, _ = _all_health()
    healths = [h for h in healths if h["kind"] in PROP_TYPES]
    ranked = [h for h in healths if h.get("nearest_limit") is not None]
    ranked.sort(key=lambda h: h["nearest_limit"]["headroom_pct"])
    no_data = [h["login"] for h in healths if h.get("nearest_limit") is None]
    return {
        "generated_utc": _iso(_now()),
        "ranked": [
            {
                "login": h["login"],
                "kind": h["kind"],
                "label": h["label"],
                "firm": h["firm"],
                "machine": h["machine"],
                "level": h["level"],
                "stale": h["stale"],
                "nearest_limit": h["nearest_limit"]["limit"],
                "headroom_pct": h["nearest_limit"]["headroom_pct"],
                "firm_headroom_pct": h["firm_headroom_pct"],
                "daily_loss_pct": h["daily_loss_pct"],
                "overall_loss_pct": h["overall_loss_pct"],
                "open_positions": h["open_positions"],
                "floating_pl": h["floating_pl"],
            }
            for h in ranked[: max(1, top_n)]
        ],
        "accounts_without_limit_data": no_data,
        "read_errors": errors,
    }


@mcp.tool(annotations=READ_ONLY)
def recent_trades(account_id: int, hours: int = 24) -> dict:
    """Closed trades for one account over the last `hours` hours, with a summary.

    Net P&L includes commission and swap. Win rate counts closing deals only.
    Data comes from the heartbeat EA's deals export (last 7 days by default).
    """
    p = FLEET_DIR / "deals" / f"{account_id}.json"
    if not p.exists():
        return {"error": f"no deals file for account {account_id}", "expected_path": str(p)}
    try:
        data = _read_json(p)
    except Exception as exc:
        return {"error": f"could not read {p.name}: {exc}"}

    since = _now() - timedelta(hours=hours)
    deals = [d for d in data.get("deals", []) if (_parse_ts(d.get("time_utc")) or since) >= since]
    closes = [d for d in deals if d.get("entry") in ("out", "inout", "out_by")]

    def net(d: dict) -> float:
        return float(d.get("profit", 0)) + float(d.get("commission", 0)) + float(d.get("swap", 0))

    nets = [net(d) for d in closes]
    wins = [n for n in nets if n > 0]
    by_symbol: dict[str, dict] = {}
    for d, n in zip(closes, nets):
        s = by_symbol.setdefault(d.get("symbol", "?"), {"trades": 0, "net_pl": 0.0})
        s["trades"] += 1
        s["net_pl"] = round(s["net_pl"] + n, 2)
    # Commission on opening deals is a real cost too.
    open_costs = sum(float(d.get("commission", 0)) for d in deals if d.get("entry") == "in")

    return {
        "account_id": account_id,
        "window_hours": hours,
        "export_generated_utc": data.get("generated_utc"),
        "summary": {
            "closed_trades": len(closes),
            "wins": len(wins),
            "losses": len([n for n in nets if n < 0]),
            "win_rate_pct": round(len(wins) / len(nets) * 100, 1) if nets else None,
            "net_pl_closes": round(sum(nets), 2),
            "opening_commission": round(open_costs, 2),
            "net_pl_total": round(sum(nets) + open_costs, 2),
            "best": round(max(nets), 2) if nets else None,
            "worst": round(min(nets), 2) if nets else None,
            "by_symbol": by_symbol,
        },
        "deals": deals[-100:],
    }


@mcp.tool(annotations=READ_ONLY)
def compare_test_accounts(sort_by: str = "growth", machine: str | None = None) -> dict:
    """Side-by-side performance of test accounts (everything not tagged as a
    prop account), for judging which EAs are doing well.

    sort_by: "growth" (equity vs starting balance), "today" (day P&L %),
    "drawdown" (current drawdown from peak equity, worst first).
    Growth uses the first balance the heartbeat saw unless an
    initial_balance is set for that account in firm_rules.json.
    """
    healths, errors, _ = _all_health()
    rows = [h for h in healths if h["kind"] not in PROP_TYPES]
    if machine:
        rows = [h for h in rows if str(h["machine"]).lower() == machine.lower()]
    key = {"growth": "growth_pct", "today": "day_pl_pct", "drawdown": "dd_from_peak_pct"}.get(sort_by, "growth_pct")
    rows.sort(key=lambda h: (h[key] is None, -(h[key] or 0)))
    return {
        "sorted_by": key,
        "accounts": [
            {k: h[k] for k in ("login", "label", "machine", "broker", "equity", "currency", "growth_pct",
                               "day_pl_pct", "dd_from_peak_pct", "open_positions", "floating_pl",
                               "stale", "issues")}
            for h in rows
        ],
        "read_errors": errors,
    }


@mcp.tool(annotations=READ_ONLY)
def watchdog_events(since_hours: int = 24, machine: str | None = None,
                    min_level: str = "info", limit: int = 100) -> dict:
    """Events logged by the VPS watchdogs and other fleet scripts, newest first.

    Filter by machine name (e.g. "VPS8") and minimum level ("info", "warn",
    "error"). Use this to see restarts, disconnects and failures that the
    account heartbeats alone wouldn't explain.
    """
    floor = EVENT_LEVELS.get(min_level.lower(), 0)
    since = _now() - timedelta(hours=since_hours)
    out = []
    for ev in load_events():
        ts = _parse_ts(ev.get("ts"))
        if not ts or ts < since:
            continue
        if machine and str(ev.get("machine", "")).lower() != machine.lower():
            continue
        if EVENT_LEVELS.get(str(ev.get("level", "info")).lower(), 0) < floor:
            continue
        out.append(ev)
    out.sort(key=lambda e: e.get("ts", ""), reverse=True)
    counts = {lvl: sum(1 for e in out if str(e.get("level", "info")).lower() == lvl) for lvl in EVENT_LEVELS}
    return {"since_hours": since_hours, "counts": counts, "events": out[: max(1, limit)]}


# --------------------------------------------------------------------------- #
# Resources
# --------------------------------------------------------------------------- #
@mcp.resource("fleet://rules")
def rules_resource() -> str:
    """Firm loss limits, the STS internal buffer, and per-account overrides in use."""
    return json.dumps(load_rules(), indent=2)


@mcp.resource("fleet://schema")
def schema_resource() -> str:
    """The data contract for status, deals and event files."""
    p = HERE / "mql5" / "SCHEMA.md"
    return p.read_text(encoding="utf-8") if p.exists() else "SCHEMA.md not found next to server.py"


if __name__ == "__main__":
    mcp.run()
