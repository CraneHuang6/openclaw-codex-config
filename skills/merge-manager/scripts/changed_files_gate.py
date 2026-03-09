#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR / "lib"))

from github_gate_support import changed_files, json_dump


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default=".")
    parser.add_argument("--base-ref", default="origin/main")
    parser.add_argument("--head-ref", default="HEAD")
    args = parser.parse_args()

    files = changed_files(args.repo, args.base_ref, args.head_ref)
    print(json_dump({"base_ref": args.base_ref, "head_ref": args.head_ref, "files_changed": len(files), "changed_files": files}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
