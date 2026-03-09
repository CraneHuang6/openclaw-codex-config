#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR / "lib"))

from github_gate_support import changed_files, json_dump, load_simple_yaml, match_glob


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("--base-ref", default="origin/main")
    parser.add_argument("--head-ref", default="HEAD")
    parser.add_argument("--protected-paths", required=True)
    args = parser.parse_args()

    patterns = load_simple_yaml(args.protected_paths).get("protected_paths", [])
    files = changed_files(args.repo, args.base_ref, args.head_ref)
    risky = [path for path in files if any(match_glob(path, pattern) for pattern in patterns)]
    result = {
        "changed_files": files,
        "protected_paths_touched": risky,
        "risk_level": "high" if risky else "low",
    }
    print(json_dump(result))
    if risky:
        print("Protected paths touched. Manual review required.", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
