"""
Fallback for machines where the folder junction doesn't work.

Copies MT5's Common\\Files\\sts_fleet\\{status,deals} into the Dropbox fleet folder
whenever a file there is newer. Run it at logon with Task Scheduler:

    pythonw relay.py

Env: STS_FLEET_DIR (Dropbox fleet folder), MT5_COMMON_FILES (optional override of
%APPDATA%\\MetaQuotes\\Terminal\\Common\\Files).
"""
from __future__ import annotations

import os
import shutil
import time
from pathlib import Path

INTERVAL = 20
SRC = Path(os.environ.get(
    "MT5_COMMON_FILES",
    str(Path(os.environ.get("APPDATA", "")) / "MetaQuotes" / "Terminal" / "Common" / "Files"),
)) / "sts_fleet"
DST = Path(os.environ.get("STS_FLEET_DIR",
                          str(Path.home() / "Dropbox" / "ClaudeHub" / "fleet"))).expanduser()


def sync_once() -> int:
    copied = 0
    for sub in ("status", "deals"):
        src_dir, dst_dir = SRC / sub, DST / sub
        if not src_dir.is_dir():
            continue
        dst_dir.mkdir(parents=True, exist_ok=True)
        for f in src_dir.glob("*.json"):
            target = dst_dir / f.name
            try:
                if not target.exists() or f.stat().st_mtime > target.stat().st_mtime:
                    tmp = target.with_suffix(".json.tmp")
                    shutil.copy2(f, tmp)
                    os.replace(tmp, target)
                    copied += 1
            except OSError:
                pass  # file mid-write by MT5; next pass picks it up
    return copied


if __name__ == "__main__":
    while True:
        sync_once()
        time.sleep(INTERVAL)
