#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class PendingContainer:
    parent: dict[str, Any]
    key: str


def _parse_scalar(raw: str) -> Any:
    value = raw.strip().strip('"').strip("'")
    lowered = value.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if lowered in {"null", "none", "~"}:
        return None
    if re.fullmatch(r"-?\d+", value):
        return int(value)
    return value


def _dump_scalar(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, int):
        return str(value)
    text = str(value)
    if re.fullmatch(r"[A-Za-z0-9._/-]+", text):
        return text
    escaped = text.replace('\\', '\\\\').replace('"', '\\"')
    return f'"{escaped}"'


def load_simple_yaml(path: str | Path) -> dict[str, Any]:
    root: dict[str, Any] = {}
    stack: list[tuple[int, Any]] = [(-1, root)]
    path = Path(path)
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        line = raw.strip()
        while len(stack) > 1 and indent <= stack[-1][0]:
            stack.pop()
        container = stack[-1][1]
        if isinstance(container, PendingContainer):
            replacement: Any = [] if line.startswith("- ") else {}
            container.parent[container.key] = replacement
            stack[-1] = (stack[-1][0], replacement)
            container = replacement
        if line.startswith("- "):
            if not isinstance(container, list):
                raise ValueError(f"invalid list item in {path}: {line}")
            container.append(_parse_scalar(line[2:]))
            continue
        if ":" not in line:
            raise ValueError(f"invalid yaml line in {path}: {line}")
        key, rest = line.split(":", 1)
        key = key.strip()
        rest = rest.strip()
        if isinstance(container, list):
            raise ValueError(f"unexpected mapping under list in {path}: {line}")
        if rest == "":
            pending = PendingContainer(container, key)
            container[key] = None
            stack.append((indent, pending))
        else:
            container[key] = _parse_scalar(rest)
    return root


def dump_simple_yaml(data: Any, indent: int = 0) -> str:
    lines: list[str] = []
    prefix = " " * indent
    if isinstance(data, dict):
        for key, value in data.items():
            if isinstance(value, (dict, list)):
                lines.append(f"{prefix}{key}:")
                lines.append(dump_simple_yaml(value, indent + 2))
            else:
                lines.append(f"{prefix}{key}: {_dump_scalar(value)}")
    elif isinstance(data, list):
        for item in data:
            if isinstance(item, (dict, list)):
                lines.append(f"{prefix}-")
                lines.append(dump_simple_yaml(item, indent + 2))
            else:
                lines.append(f"{prefix}- {_dump_scalar(item)}")
    else:
        lines.append(f"{prefix}{_dump_scalar(data)}")
    return "\n".join(line for line in lines if line != "")


def json_dump(data: Any) -> str:
    return json.dumps(data, ensure_ascii=False, indent=2)


def git_output(repo: str | Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def changed_files(repo: str | Path, base_ref: str, head_ref: str) -> list[str]:
    out = git_output(repo, "diff", "--name-only", f"{base_ref}...{head_ref}")
    return [line.strip() for line in out.splitlines() if line.strip()]


def shortstat(repo: str | Path, base_ref: str, head_ref: str) -> tuple[int, int, int]:
    out = git_output(repo, "diff", "--shortstat", f"{base_ref}...{head_ref}")
    files = added = deleted = 0
    parts = out.replace(",", "").split()
    for index, token in enumerate(parts):
        if token in {"file", "files"} and index > 0:
            files = int(parts[index - 1])
        elif token == "insertions(+)" and index > 0:
            added = int(parts[index - 1])
        elif token == "deletions(-)" and index > 0:
            deleted = int(parts[index - 1])
    return files, added, deleted


def match_glob(path: str, pattern: str) -> bool:
    regex = re.escape(pattern)
    regex = regex.replace(r"\*\*", ".*")
    regex = regex.replace(r"\*", "[^/]*")
    return re.fullmatch(regex, path) is not None


def read_json(path: str | Path) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write_json(path: str | Path, data: Any) -> None:
    Path(path).write_text(json_dump(data) + "\n", encoding="utf-8")


def parse_pr_sections(body: str) -> dict[str, str]:
    sections: dict[str, list[str]] = {}
    current: str | None = None
    for line in body.splitlines():
        if line.startswith("## "):
            current = line[3:].strip().lower()
            sections.setdefault(current, [])
            continue
        if current is not None:
            sections[current].append(line)
    return {key: "\n".join(value).strip() for key, value in sections.items()}


def derive_legacy_policy(config_dir: str | Path) -> dict[str, Any]:
    config_dir = Path(config_dir)
    merge_rules = load_simple_yaml(config_dir / "merge_rules.yaml")
    protected = load_simple_yaml(config_dir / "protected_paths.yaml")
    dry_run = merge_rules.get("dry_run", {})
    return {
        "base_branch": merge_rules.get("target_branch", "main"),
        "merge_strategy": merge_rules.get("merge_method", "squash"),
        "delete_merged_local_branches": dry_run.get("delete_merged_local_branches", True),
        "protected_branches": dry_run.get("protected_branches", [merge_rules.get("target_branch", "main"), "master", "develop"]),
        "high_risk_paths": protected.get("protected_paths", []),
        "validation_commands": dry_run.get(
            "validation_commands",
            {
                "detect_if_missing": True,
                "explicit": ["bash scripts/check-agent-contracts.sh"],
                "preferred": ["npm run lint", "npm run typecheck", "npm test"],
                "conservative_root_scripts": ["bash scripts/check-agent-contracts.sh"],
            },
        ),
        "classification_rules": dry_run.get(
            "classification_rules",
            {
                "docs_only_is_safe": True,
                "tests_only_is_safe": True,
                "root_config_is_high_risk": True,
                "large_cross_cutting_change_is_high_risk": True,
                "overlapping_core_files_requires_manual_review": True,
                "stale_branch_days": 14,
            },
        ),
    }


def write_legacy_policy(config_dir: str | Path, output_path: str | Path) -> Path:
    output_path = Path(output_path)
    output_path.write_text(dump_simple_yaml(derive_legacy_policy(config_dir)) + "\n", encoding="utf-8")
    return output_path
