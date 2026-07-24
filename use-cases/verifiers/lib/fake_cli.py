#!/usr/bin/env python3
"""A real, arbitrary CLI agent — the thing a `kind = "generic"` row wires.

This is not a mock of cowork. It is an ordinary executable on disk that cowork
spawns for real, over posix_spawn, with the argv and environment the descriptor
in config asked for. That is precisely the behaviour under test: a CLI cowork
has no Swift for is dispatched from configuration alone.

It reports back what it was actually handed, so a journey can assert on the real
wire rather than on an internal type:

    {"argv": [...], "env": {...}, "isolation": {"path": ..., "exists": ...,
                                                "mode": "0o700", "seeded": [...]},
     "stdin": "..."}

Knobs, read from its own environment (so a descriptor's `env` block drives them):
  FAKE_CLI_SLEEP  seconds to sleep BEFORE printing — used to run past a deadline
  FAKE_CLI_EXIT   exit code to end with (default 0)
  FAKE_CLI_SAY    extra verbatim line printed after the JSON
  FAKE_CLI_ISOVAR name of the isolation variable to inspect (default XDG_CONFIG_HOME)
"""

from __future__ import annotations

import json
import os
import stat
import sys
import time


def main() -> int:
    sleep = float(os.environ.get("FAKE_CLI_SLEEP", "0") or 0)
    if sleep:
        time.sleep(sleep)

    iso_var = os.environ.get("FAKE_CLI_ISOVAR", "XDG_CONFIG_HOME")
    iso_path = os.environ.get(iso_var)
    isolation = {"var": iso_var, "path": iso_path, "exists": False,
                 "mode": None, "seeded": []}
    if iso_path and os.path.isdir(iso_path):
        isolation["exists"] = True
        isolation["mode"] = oct(stat.S_IMODE(os.stat(iso_path).st_mode))
        isolation["seeded"] = sorted(os.listdir(iso_path))

    stdin = ""
    if not sys.stdin.isatty():
        try:
            stdin = sys.stdin.read()
        except Exception:
            stdin = ""

    print(json.dumps({
        "argv": sys.argv[1:],
        "env": dict(os.environ),
        "isolation": isolation,
        "stdin": stdin,
        "cwd": os.getcwd(),
    }))
    say = os.environ.get("FAKE_CLI_SAY")
    if say:
        print(say)
    sys.stdout.flush()
    return int(os.environ.get("FAKE_CLI_EXIT", "0") or 0)


if __name__ == "__main__":
    sys.exit(main())
