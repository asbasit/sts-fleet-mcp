"""
Mark which MT5 accounts are prop accounts. Everything untagged is a test account.

    python tag_account.py 1520011234 challenge FTMO 100000
    python tag_account.py 1520011234 funded FTMO 100000 --label "FTMO 100k funded"
    python tag_account.py 1520011234 challenge FTMO 100000 --phase 2
    python tag_account.py 500123 live --start 5000 --deposit 100000   (real-money account, buffer only)
    python tag_account.py 1520011234 test          (back to a plain test account)
    python tag_account.py --list

Edits the shared firm_rules.json in the fleet folder (STS_FLEET_DIR), which
every machine and the MCP server read. The server picks changes up on its next call.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
FLEET_DIR = Path(os.environ.get("STS_FLEET_DIR",
                                str(Path.home() / "Dropbox" / "ClaudeHub" / "fleet"))).expanduser()


def rules_path() -> Path:
    p = FLEET_DIR / "firm_rules.json"
    if not p.exists():
        FLEET_DIR.mkdir(parents=True, exist_ok=True)
        src = HERE.parent / "firm_rules.json"
        if not src.exists():
            src = HERE.parent / "firm_rules.example.json"
        shutil.copy(src, p)
    return p


def known_logins() -> dict[str, dict]:
    out = {}
    for f in (FLEET_DIR / "status").glob("*.json"):
        if "conflicted copy" in f.name.lower():
            continue
        try:
            d = json.loads(f.read_text(encoding="utf-8-sig"))
            a = d.get("account") or {}
            if a.get("login"):
                out[str(a["login"])] = {"machine": d.get("machine"), "server": a.get("server")}
        except Exception:
            pass
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description="Tag MT5 accounts as challenge / funded / test")
    ap.add_argument("login", nargs="?")
    ap.add_argument("type", nargs="?", choices=["challenge", "funded", "live", "test"])
    ap.add_argument("firm", nargs="?")
    ap.add_argument("initial_balance", nargs="?", type=float)
    ap.add_argument("--phase")
    ap.add_argument("--label")
    ap.add_argument("--start", type=float, help="balance to measure drawdown from (same as 4th value)")
    ap.add_argument("--deposit", type=float, help="original deposit, for recovery tracking (account currency)")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()

    p = rules_path()
    rules = json.loads(p.read_text(encoding="utf-8-sig"))
    accounts = rules.setdefault("accounts", {})
    seen = known_logins()

    if a.list or not a.login:
        tagged = {k: v for k, v in accounts.items() if not k.startswith("_")}
        print(f"Rules file: {p}\n")
        print("Prop accounts:")
        for k, v in sorted(tagged.items()):
            where = seen.get(k, {}).get("machine") or "no heartbeat yet"
            print(f"  {k:>12}  {v.get('type', '?'):9} {v.get('firm', '?'):13} "
                  f"{v.get('initial_balance', '?'):>10}  {v.get('label') or ''}  [{where}]")
        if not tagged:
            print("  (none yet)")
        print("\nTest accounts reporting heartbeats:")
        rest = sorted(k for k in seen if k not in tagged)
        for k in rest:
            print(f"  {k:>12}  {seen[k]['server'] or '':28} [{seen[k]['machine']}]")
        if not rest:
            print("  (none)")
        return

    if a.type is None:
        sys.exit("Say what the account is: challenge, funded or test")

    if a.type == "test":
        if accounts.pop(a.login, None) is None:
            print(f"{a.login} was already a test account")
        else:
            print(f"{a.login} is now a test account")
    else:
        if a.start and not a.initial_balance:
            a.initial_balance = a.start
        if a.type == "live":
            # live accounts have no firm; a number in the firm slot is the start balance
            if a.firm and a.initial_balance is None:
                try:
                    a.initial_balance = float(a.firm)
                except ValueError:
                    pass
            a.firm = None
        elif not a.firm:
            sys.exit("A prop account needs a firm, e.g. FTMO")
        firms = rules.get("firms", {})
        if a.firm and a.firm not in firms:
            match = next((f for f in firms if f.lower() == a.firm.lower()), None)
            if match:
                a.firm = match
            else:
                print(f"Note: '{a.firm}' isn't in firm_rules.json firms yet "
                      f"({', '.join(firms)}). It'll be checked against the STS buffer only.")
        entry = dict(accounts.get(a.login) or {})
        entry["type"] = a.type
        if a.firm:
            entry["firm"] = a.firm
        else:
            entry.pop("firm", None)
        if a.deposit:
            entry["deposit"] = int(a.deposit) if a.deposit.is_integer() else a.deposit
        if a.initial_balance:
            entry["initial_balance"] = int(a.initial_balance) if a.initial_balance.is_integer() else a.initial_balance
        if a.phase:
            entry["phase"] = a.phase
        if a.label:
            entry["label"] = a.label
        accounts[a.login] = entry
        bal = entry.get("initial_balance", "no starting balance (add it as the 4th value)")
        print(f"{a.login} is now a {a.type} account: {a.firm or 'no firm (STS buffer only)'}, start {bal}"
              + (f", deposit {entry['deposit']}" if entry.get("deposit") else ""))
        if a.login not in seen:
            print("  (no heartbeat from this login yet; check the number, or attach the EA)")

    tmp = p.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(rules, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, p)


if __name__ == "__main__":
    main()
