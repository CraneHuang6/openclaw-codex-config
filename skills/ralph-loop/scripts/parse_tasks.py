#!/usr/bin/env python3
"""Parse markdown checkbox tasks with optional dependency tags."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

CHECKBOX_RE = re.compile(r"^\s*[-*]\s*\[(?P<state>[ xX])\]\s*(?P<body>.+?)\s*$")
DEPENDS_RE = re.compile(r"\[depends:\s*(?P<value>[^\]]+)\]", re.IGNORECASE)
BOLD_ID_RE = re.compile(r"\*\*(?P<id>[A-Za-z][A-Za-z0-9_-]*)\*\*")
TOKEN_ID_RE = re.compile(r"\b(?P<id>[A-Za-z]{1,8}-\d{1,6})\b")
LEADING_ID_RE = re.compile(r"^\*\*[A-Za-z][A-Za-z0-9_-]*\*\*[:：\-\s]*")
LEADING_TOKEN_ID_RE = re.compile(r"^(?P<id>[A-Za-z]{1,8}-\d{1,6})[:：\-\s]+")

NONE_TOKENS = {"none", "na", "n/a", "nil", "-"}


@dataclass
class Task:
    id: str
    title: str
    line: int
    depends: list[str]
    checked: bool
    source: str


def normalize_dep_token(token: str) -> str:
    return token.strip().strip("*`[](){}<>")


def parse_depends(body: str) -> tuple[list[str], str]:
    match = DEPENDS_RE.search(body)
    if not match:
        return [], body

    value = match.group("value")
    deps: list[str] = []
    for part in re.split(r"[,\s]+", value):
        cleaned = normalize_dep_token(part)
        if not cleaned:
            continue
        if cleaned.lower() in NONE_TOKENS:
            continue
        deps.append(cleaned)

    body_without_dep = (body[: match.start()] + body[match.end() :]).strip()
    return deps, body_without_dep


def guess_task_id(body: str, index: int, used: set[str]) -> str:
    for pattern in (BOLD_ID_RE, TOKEN_ID_RE):
        match = pattern.search(body)
        if match:
            candidate = match.group("id")
            if candidate not in used:
                return candidate

    generated = f"T{index:03d}"
    while generated in used:
        index += 1
        generated = f"T{index:03d}"
    return generated


def extract_title(body_without_dep: str) -> str:
    title = LEADING_ID_RE.sub("", body_without_dep).strip()
    title = LEADING_TOKEN_ID_RE.sub("", title).strip()
    title = re.sub(r"\s+", " ", title)
    return title or body_without_dep


def parse_tasks(plan_path: Path) -> list[Task]:
    used_ids: set[str] = set()
    tasks: list[Task] = []

    for line_no, raw_line in enumerate(plan_path.read_text(encoding="utf-8").splitlines(), start=1):
        match = CHECKBOX_RE.match(raw_line)
        if not match:
            continue

        body = match.group("body").strip()
        depends, body_without_dep = parse_depends(body)
        task_id = guess_task_id(body_without_dep, len(tasks) + 1, used_ids)
        used_ids.add(task_id)

        task = Task(
            id=task_id,
            title=extract_title(body_without_dep),
            line=line_no,
            depends=depends,
            checked=match.group("state").lower() == "x",
            source=body,
        )
        tasks.append(task)

    return tasks


def remap_dependencies(tasks: list[Task], strict: bool) -> tuple[list[dict], list[tuple[str, str]]]:
    known = {task.id.upper(): task.id for task in tasks}
    unknown: list[tuple[str, str]] = []

    payload: list[dict] = []
    for task in tasks:
        deps: list[str] = []
        for dep in task.depends:
            normalized = known.get(dep.upper())
            if normalized is None:
                unknown.append((task.id, dep))
                if strict:
                    continue
                normalized = dep
            if normalized not in deps:
                deps.append(normalized)

        payload.append(
            {
                "id": task.id,
                "title": task.title,
                "line": task.line,
                "depends": deps,
                "checked": task.checked,
                "source": task.source,
            }
        )

    return payload, unknown


def main() -> int:
    parser = argparse.ArgumentParser(description="Parse markdown tasks for ralph-loop")
    parser.add_argument("--plan", required=True, help="Absolute path to markdown plan")
    parser.add_argument("--strict", action="store_true", help="Fail if dependency id is unknown")
    parser.add_argument("--pretty", action="store_true", help="Pretty JSON output")
    args = parser.parse_args()

    plan_path = Path(args.plan)
    if not plan_path.exists():
        print(f"Plan file does not exist: {plan_path}", file=sys.stderr)
        return 1

    tasks = parse_tasks(plan_path)
    if not tasks:
        print(f"No markdown checkbox tasks found in: {plan_path}", file=sys.stderr)
        return 1

    payload, unknown = remap_dependencies(tasks, strict=args.strict)
    if args.strict and unknown:
        unknown_text = ", ".join([f"{owner}->{dep}" for owner, dep in unknown])
        print(f"Unknown dependencies in strict mode: {unknown_text}", file=sys.stderr)
        return 2

    json.dump(payload, sys.stdout, ensure_ascii=False, indent=2 if args.pretty else None)
    if args.pretty:
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
