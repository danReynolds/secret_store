#!/usr/bin/env python3
"""Hold a Keybay advisory lock for the CLI contention integration test."""

from __future__ import annotations

import fcntl
import sys
import time
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} LOCK_PATH READY_PATH", file=sys.stderr)
        return 2
    lock_path = Path(sys.argv[1])
    ready_path = Path(sys.argv[2])
    with lock_path.open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        ready_path.touch()
        time.sleep(20)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
