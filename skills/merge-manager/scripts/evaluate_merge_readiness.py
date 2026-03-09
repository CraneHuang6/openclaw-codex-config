#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR / "lib"))

from github_gate_support import json_dump, load_simple_yaml, read_json

REQUIRED_KEYS = {
    "required_checks_passed",
    "approval_count",
    "has_conflicts",
    "has_blocking_label",
    "blocking_labels",
    "protected_paths_touched",
    "pr_too_large",
    "validation_evidence_present",
    "rollback_plan_present",
    "goal_present",
    "scope_present",
    "automerge_label_present",
    "manual_review_label_present",
    "up_to_date_with_target",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rules", required=True)
    parser.add_argument("--state-json", required=True)
    args = parser.parse_args()

    rules = load_simple_yaml(args.rules)
    labels = load_simple_yaml(SCRIPT_DIR.parent / "config" / "label_rules.yaml")
    state = read_json(args.state_json)
    missing_keys = sorted(REQUIRED_KEYS - set(state.keys()))
    if missing_keys:
        print(json_dump({"decision": "BLOCK_AND_COMMENT", "error": f"missing required state keys: {', '.join(missing_keys)}"}))
        return 2

    failures: list[str] = []
    checks = rules.get("checks", {})
    policy = rules.get("policy", {})
    automerge = rules.get("automerge", {})
    label_map = labels.get("labels", {})
    risk_labels = labels.get("risk_labels", {})
    size_labels = labels.get("size_labels", {})

    if checks.get("require_all_required_checks_passed", True) and not state["required_checks_passed"]:
        failures.append("required checks not passed")
    if int(state["approval_count"]) < int(checks.get("require_review_approval_count", 1)):
        failures.append("not enough approvals")
    if checks.get("require_up_to_date_with_target", True) and not state["up_to_date_with_target"]:
        failures.append("branch is not up to date with target")
    if state["has_blocking_label"]:
        failures.append("blocking label present")
    if policy.get("require_validation_evidence_in_pr_body", True) and not state["validation_evidence_present"]:
        failures.append("missing validation evidence")
    if policy.get("require_rollback_plan_in_pr_body", True) and not state["rollback_plan_present"]:
        failures.append("missing rollback plan")
    if policy.get("require_goal_section_in_pr_body", True) and not state["goal_present"]:
        failures.append("missing goal section")
    if policy.get("require_scope_section_in_pr_body", True) and not state["scope_present"]:
        failures.append("missing scope section")
    required_label = automerge.get("require_label")
    if required_label and not state["automerge_label_present"]:
        failures.append("missing automerge label")

    labels_to_add: list[str] = []
    labels_to_remove: list[str] = []
    decision = "ENABLE_AUTO_MERGE"

    if state["has_conflicts"]:
        decision = "ROUTE_TO_CONFLICT_REPAIR"
        labels_to_add.extend([label_map.get("conflict_repair"), risk_labels.get("medium")])
        labels_to_remove.append(label_map.get("automerge_candidate"))
    elif state["protected_paths_touched"] or state["pr_too_large"] or state["manual_review_label_present"]:
        decision = "REQUIRE_MANUAL_REVIEW"
        labels_to_add.extend([label_map.get("manual_review"), risk_labels.get("high" if state["protected_paths_touched"] else "medium"), size_labels.get("large" if state["pr_too_large"] else "small")])
        labels_to_remove.append(label_map.get("automerge_candidate"))
        if state["protected_paths_touched"]:
            failures.append("protected paths touched")
        if state["pr_too_large"]:
            failures.append("PR exceeds size threshold")
    elif failures:
        decision = "BLOCK_AND_COMMENT"
        labels_to_add.extend([risk_labels.get("medium"), size_labels.get("small")])
    else:
        labels_to_add.extend([risk_labels.get("low"), size_labels.get("small")])
        labels_to_remove.extend([label_map.get("manual_review"), label_map.get("conflict_repair")])

    if decision == "ENABLE_AUTO_MERGE" and failures:
        decision = "BLOCK_AND_COMMENT"

    labels_to_add = [label for label in labels_to_add if label]
    labels_to_remove = [label for label in labels_to_remove if label]
    unique_add = []
    for label in labels_to_add:
        if label not in unique_add:
            unique_add.append(label)
    unique_remove = []
    for label in labels_to_remove:
        if label not in unique_remove and label not in unique_add:
            unique_remove.append(label)

    failure_comment = ""
    if decision != "ENABLE_AUTO_MERGE":
        bullet_list = "\n".join(f"- {item}" for item in failures) if failures else "- manual review required"
        failure_comment = f"## Merge manager verdict\nDecision: {decision}\n\nReasons:\n{bullet_list}\n\nNext steps:\n- address the reasons above\n- rerun validation and update PR evidence\n- re-request merge manager evaluation\n"

    result = {
        "decision": decision,
        "failures": failures,
        "failure_comment": failure_comment,
        "labels_to_add": unique_add,
        "labels_to_remove": unique_remove,
    }
    print(json_dump(result))
    return 2 if missing_keys else 0


if __name__ == "__main__":
    raise SystemExit(main())
