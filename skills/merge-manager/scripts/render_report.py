#!/usr/bin/env python3
"""Render merge-manager Markdown + JSON dry-run reports."""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def category_rank(category: str) -> int:
    return {
        "foundation": 0,
        "interface_support": 1,
        "business_logic": 2,
        "docs_tests": 3,
    }.get(category, 2)


def format_filter_reason(item: dict) -> str:
    reasons = item.get("filter_reasons", [])
    labels = []
    if "checked_out_in_worktree" in reasons:
        worktrees = item.get("checked_out_worktrees", [])
        if worktrees:
            labels.append(f"checked out in worktree: {', '.join(worktrees)}")
        else:
            labels.append("checked out in worktree")
    if "already_merged" in reasons:
        labels.append("already merged into base")
    return "; ".join(labels) or "filtered by policy"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--classifications-dir", required=True)
    parser.add_argument("--validations-dir", required=True)
    parser.add_argument("--markdown", required=True)
    parser.add_argument("--json", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--branch-pattern", default="")
    parser.add_argument("--branches-file", default="")
    parser.add_argument("--legacy-command", required=True)
    args = parser.parse_args()

    inventory = load_json(Path(args.inventory))
    classes_dir = Path(args.classifications_dir)
    validations_dir = Path(args.validations_dir)

    records = []
    changed_sets = {}
    for item in inventory["branches"]:
        branch = item["branch"]
        changed_sets[branch] = set(item.get("changed_files", []))

    for item in inventory["branches"]:
        branch = item["branch"]
        safe_name = branch.replace("/", "_").replace(":", "_")
        classification = load_json(classes_dir / f"{safe_name}.json")
        validation = load_json(validations_dir / f"{safe_name}.json")
        overlap = []
        for other, other_files in changed_sets.items():
            if other == branch:
                continue
            shared = changed_sets[branch] & other_files
            if shared:
                overlap.append({"branch": other, "files": sorted(shared)[:5], "count": len(shared)})

        state = "ready"
        blocker = ""
        if classification["stale"]:
            state = "stale"
            blocker = f"branch age {classification['age_days']}d exceeds stale threshold {classification['stale_days']}d"
        elif classification["risk_level"] == "high" or classification["has_high_risk_path"]:
            state = "manual_review"
            blocker = "; ".join(classification["reasons"] or ["high-risk path touched"])
        elif overlap and classification["category"] != "docs_tests":
            state = "manual_review"
            blocker = f"overlaps with {', '.join(item['branch'] for item in overlap)}"
        elif validation["status"] != "pass":
            state = "blocked"
            blocker = validation["validation_summary"]

        if state == "ready":
            next_action = "eligible for future execute after explicit approval"
        elif state == "stale":
            next_action = "refresh branch on latest base and rerun dry-run"
        elif state == "manual_review":
            next_action = "perform manual review or cherry-pick selective commits"
        else:
            next_action = "fix validation blockers and rerun dry-run"

        records.append(
            {
                "branch": branch,
                "risk_level": classification["risk_level"],
                "state": state,
                "overlap_summary": [
                    {"branch": entry["branch"], "count": entry["count"], "files": entry["files"]}
                    for entry in overlap
                ],
                "validation_summary": validation["validation_summary"],
                "merge_result": "not executed (dry-run MVP)",
                "blocker": blocker,
                "next_action": next_action,
                "classification": classification,
                "validation": validation,
                "ahead": item["ahead"],
                "behind": item["behind"],
                "last_commit": item["last_commit"],
                "changed_files": item.get("changed_files", []),
            }
        )

    merge_order = [
        record["branch"]
        for record in sorted(records, key=lambda record: (category_rank(record["classification"]["category"]), record["behind"], record["branch"]))
    ]
    blockers = [{"branch": record["branch"], "state": record["state"], "reason": record["blocker"]} for record in records if record["state"] != "ready"]
    filtered_out = inventory.get("filtered_out", [])

    report = {
        "assumptions": {
            "base_branch": args.base,
            "merge_strategy": "squash",
            "branch_pattern": args.branch_pattern or None,
            "branches_file": args.branches_file or None,
            "mode": "dry-run",
            "legacy_execute_entrypoint": args.legacy_command,
        },
        "candidate_branches": [record["branch"] for record in records],
        "filtered_out": filtered_out,
        "merge_order": merge_order,
        "branches": records,
        "blockers": blockers,
        "exact_next_command": args.legacy_command,
    }

    md_lines = [
        "# Merge Manager Report",
        "",
        "## Assumptions",
        f"- base_branch: `{args.base}`",
        "- merge_strategy: `squash`",
        "- mode: `dry-run`",
        f"- legacy_execute_entrypoint: `{args.legacy_command}`",
        "",
        "## Candidate Branches",
    ]
    if report["candidate_branches"]:
        md_lines.extend([f"- `{branch}`" for branch in report["candidate_branches"]])
    else:
        md_lines.append("- none")

    md_lines.extend(["", "## Filtered Out"])
    if filtered_out:
        md_lines.extend([f"- `{item['branch']}`: {format_filter_reason(item)}" for item in filtered_out])
    else:
        md_lines.append("- none")

    md_lines.extend(["", "## Merge Order"])
    if merge_order:
        md_lines.extend([f"{index + 1}. `{branch}`" for index, branch in enumerate(merge_order)])
    else:
        md_lines.append("1. none")

    md_lines.extend([
        "",
        "## Summary Table",
        "",
        "| branch | risk_level | state | overlap_summary | validation_summary | merge_result | blocker | next_action |",
        "|---|---|---|---|---|---|---|---|",
    ])
    for row in records:
        overlap_summary = ", ".join(f"{entry['branch']}({entry['count']})" for entry in row["overlap_summary"]) or "none"
        blocker = row["blocker"] or "none"
        md_lines.append(
            f"| `{row['branch']}` | `{row['risk_level']}` | `{row['state']}` | {overlap_summary} | {row['validation_summary']} | {row['merge_result']} | {blocker} | {row['next_action']} |"
        )

    md_lines.extend(["", "## Blockers"])
    if blockers:
        md_lines.extend([f"- `{item['branch']}`: `{item['state']}` — {item['reason']}" for item in blockers])
    else:
        md_lines.append("- none")

    md_lines.extend(["", "## Exact Next Command", "```bash", args.legacy_command, "```", ""])

    Path(args.json).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    Path(args.markdown).write_text("\n".join(md_lines), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
