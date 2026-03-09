#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR / "lib"))

from github_gate_support import derive_legacy_policy, dump_simple_yaml, json_dump, write_legacy_policy


parser = argparse.ArgumentParser()
parser.add_argument("--config-dir", default=str(SCRIPT_DIR.parent / "config"))
parser.add_argument("--output")
parser.add_argument("--format", choices=("yaml", "json"), default="yaml")
args = parser.parse_args()

payload = derive_legacy_policy(args.config_dir)
if args.output:
    if args.format == "json":
        Path(args.output).write_text(json_dump(payload) + "\n", encoding="utf-8")
    else:
        write_legacy_policy(args.config_dir, args.output)
else:
    if args.format == "json":
        print(json_dump(payload))
    else:
        print(dump_simple_yaml(payload))
