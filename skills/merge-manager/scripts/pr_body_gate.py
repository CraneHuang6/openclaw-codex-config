#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path
import sys

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR / "lib"))

from github_gate_support import json_dump, load_simple_yaml, parse_pr_sections


def _meaningful(value: str) -> bool:
    stripped = value.strip()
    if not stripped:
        return False
    filtered = []
    for line in stripped.splitlines():
        line = line.strip()
        if not line or line.startswith("<!--") or line == "~~~bash" or line == "~~~":
            continue
        filtered.append(line)
    return bool(filtered)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rules", required=True)
    parser.add_argument("--body-file", required=True)
    args = parser.parse_args()

    body = Path(args.body_file).read_text(encoding="utf-8")
    rules = load_simple_yaml(args.rules)
    policy = rules.get("policy", {})
    sections = parse_pr_sections(body)

    checks = {
        "goal_present": _meaningful(sections.get("goal", "")),
        "scope_present": _meaningful(sections.get("scope", "")),
        "validation_evidence_present": _meaningful(sections.get("validation performed", "")) or _meaningful(sections.get("validation result", "")),
        "rollback_plan_present": _meaningful(sections.get("rollback plan", "")),
    }
    missing = []
    if policy.get("require_goal_section_in_pr_body", True) and not checks["goal_present"]:
        missing.append("missing goal section")
    if policy.get("require_scope_section_in_pr_body", True) and not checks["scope_present"]:
        missing.append("missing scope section")
    if policy.get("require_validation_evidence_in_pr_body", True) and not checks["validation_evidence_present"]:
        missing.append("missing validation evidence")
    if policy.get("require_rollback_plan_in_pr_body", True) and not checks["rollback_plan_present"]:
        missing.append("missing rollback plan")
    result = {**checks, "missing": missing}
    print(json_dump(result))
    return 2 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
