#!/usr/bin/env python3
"""Compatibility wrapper.

Delegates to skill-owned runtime hard-cut script:
/Users/crane/.codex/skills/openclaw-model-upgrade-sync/scripts/hardcut_runtime_model.py
"""

from __future__ import annotations

import os
import pathlib
import sys


def main() -> int:
    target = pathlib.Path.home() / ".codex" / "skills" / "openclaw-model-upgrade-sync" / "scripts" / "hardcut_runtime_model.py"
    if not target.exists():
        print(f"[ERROR] target script not found: {target}", file=sys.stderr)
        return 2
    os.execv(sys.executable, [sys.executable, str(target), *sys.argv[1:]])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
