"""
Append one event to the fleet event log for this machine.

CLI (from a watchdog, batch file or scheduled task):
    python fleet_event.py --level error --source watchdog --account 500777 "terminal restarted"

Python:
    from fleet_event import log_event
    log_event("terminal restarted", level="error", source="watchdog", account_id=500777)

Machine name comes from --machine, then STS_MACHINE, then COMPUTERNAME / HOSTNAME.
Fleet folder comes from STS_FLEET_DIR (default ~/Dropbox/ClaudeHub/fleet).
"""
from __future__ import annotations

import argparse
import json
import os
import socket
from datetime import datetime, timezone
from pathlib import Path


def _fleet_dir() -> Path:
    return Path(os.environ.get("STS_FLEET_DIR",
                               str(Path.home() / "Dropbox" / "ClaudeHub" / "fleet"))).expanduser()


def _machine() -> str:
    return (os.environ.get("STS_MACHINE") or os.environ.get("COMPUTERNAME")
            or os.environ.get("HOSTNAME") or socket.gethostname())


def log_event(message: str, level: str = "info", source: str = "script",
              account_id: int | None = None, machine: str | None = None) -> Path:
    level = level.lower()
    if level not in ("info", "warn", "error"):
        raise ValueError("level must be info, warn or error")
    machine = machine or _machine()
    ev = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "machine": machine,
        "level": level,
        "source": source,
        "message": message,
    }
    if account_id is not None:
        ev["account_id"] = int(account_id)
    folder = _fleet_dir() / "events"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"{machine}.jsonl"
    # If the last line was cut off (crash, sync), start on a fresh line so this event survives.
    lead = ""
    if path.exists() and path.stat().st_size:
        with path.open("rb") as fh:
            fh.seek(-1, os.SEEK_END)
            if fh.read(1) != b"\n":
                lead = "\n"
    with path.open("a", encoding="utf-8") as fh:
        fh.write(lead + json.dumps(ev) + "\n")
    return path


def main() -> None:
    ap = argparse.ArgumentParser(description="Log a fleet event")
    ap.add_argument("message")
    ap.add_argument("--level", default="info", choices=["info", "warn", "error"])
    ap.add_argument("--source", default="watchdog")
    ap.add_argument("--account", type=int)
    ap.add_argument("--machine")
    a = ap.parse_args()
    print(log_event(a.message, a.level, a.source, a.account, a.machine))


if __name__ == "__main__":
    main()
