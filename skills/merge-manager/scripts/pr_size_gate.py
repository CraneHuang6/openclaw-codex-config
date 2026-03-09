#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import sys

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR / "lib"))

from github_gate_support import json_dump, load_simple_yaml, shortstat


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("--base-ref", default="origin/main")
    parser.add_argument("--head-ref", default="HEAD")
    parser.add_argument("--rules", required=True)
    args = parser.parse_args()

    rules = load_simple_yaml(args.rules)
    max_files = int(rules.get("pr_size", {}).get("max_files_changed", 20))
    max_lines = int(rules.get("pr_size", {}).get("max_lines_changed", 800))
    files_changed, added, deleted = shortstat(args.repo, args.base_ref, args.head_ref)
    total = added + deleted
    too_large = files_changed > max_files or total > max_lines
    print(json_dump({
        "files_changed": files_changed,
        "lines_changed": total,
        "added_lines": added,
        "deleted_lines": deleted,
        "too_large": too_large,
        "max_files_changed": max_files,
        "max_lines_changed": max_lines,
    }))
    return 2 if too_large else 0


if __name__ == "__main__":
    raise SystemExit(main())
