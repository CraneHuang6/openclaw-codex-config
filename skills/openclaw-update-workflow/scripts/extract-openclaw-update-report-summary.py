#!/usr/bin/env python3
import argparse
import json
import re
import sys
from pathlib import Path


BULLET_RE = re.compile(r"^- ([A-Za-z0-9_]+):\s*(.*)$")


def parse_report(path: Path) -> dict:
    if not path.is_file():
        raise FileNotFoundError(f"report not found: {path}")
    data = {"report_path": str(path)}
    in_header = False
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip("\n")
        if line.startswith("# OpenClaw Daily Auto Update"):
            in_header = True
            continue
        if not in_header:
            continue
        if line.startswith("## "):
            break
        m = BULLET_RE.match(line)
        if not m:
            continue
        key, value = m.group(1), m.group(2)
        data[key] = value
    return data


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Extract summary fields from OpenClaw daily auto update report markdown."
    )
    parser.add_argument("--report", required=True, help="Path to report markdown file")
    parser.add_argument(
        "--format",
        default="kv",
        choices=("kv", "json"),
        help="Output format (default: kv)",
    )
    parser.add_argument(
        "--field",
        action="append",
        default=[],
        help="Optional field filter (repeatable). If omitted, print all parsed fields.",
    )
    args = parser.parse_args()

    try:
        parsed = parse_report(Path(args.report))
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if args.field:
        filtered = {"report_path": parsed.get("report_path", str(args.report))}
        for key in args.field:
            if key in parsed:
                filtered[key] = parsed[key]
        parsed = filtered

    if args.format == "json":
        print(json.dumps(parsed, ensure_ascii=False, sort_keys=True))
        return 0

    for key in sorted(parsed.keys()):
        print(f"{key}={parsed[key]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
