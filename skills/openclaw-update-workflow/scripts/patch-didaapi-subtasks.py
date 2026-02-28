#!/usr/bin/env python3
"""Patch DidaAPI subtask support into backend and CLI files.

This patcher is idempotent:
- If markers already exist, no file changes are made.
- In --dry-run mode, it reports whether changes would be made.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


DEFAULT_WORKSPACE_ROOT = Path("/Users/crane/.openclaw/workspace")


MODELS_BASE_PATH = Path("services/DidaAPI/models/base.py")
ROUTERS_TASKS_PATH = Path("services/DidaAPI/routers/tasks.py")
CLI_MANAGER_PATH = Path("skills/didaapi-task-manager/scripts/didaapi_manager.py")


CREATE_SUBTASK_FIELD_LINE = '    subtasks: Optional[list[str]] = Field(None, description="子任务标题列表")\n'
ROUTERS_IMPORT_LINE = "from utils import app_logger, generate_object_id\n"
ROUTERS_SORT_ORDER_LINE = "SUBTASK_SORT_ORDER_STEP = 1 << 39\n"
ROUTERS_SORT_ORDER_MARKER = '"sortOrder": index * SUBTASK_SORT_ORDER_STEP'
CLI_SUBTASK_PAYLOAD_MARKER = 'payload["subtasks"] = clean_subtasks'
CLI_SUBTASK_ARG_LINE = (
    '    create_parser.add_argument("--subtask", dest="subtasks", action="append", '
    'default=[], help="Subtask title (repeatable)")\n'
)


class PatchError(RuntimeError):
    """Raised when a patch anchor cannot be found."""


@dataclass
class PatchResult:
    changed: bool
    content: str


def _replace_utils_import(text: str) -> PatchResult:
    if ROUTERS_IMPORT_LINE in text:
        return PatchResult(False, text)

    legacy_line = "from utils import app_logger\n"
    if legacy_line in text:
        return PatchResult(True, text.replace(legacy_line, ROUTERS_IMPORT_LINE, 1))

    raise PatchError("utils import anchor not found in routers/tasks.py")


def _ensure_subtasks_field(text: str) -> PatchResult:
    class_start = text.find("class CreateTaskRequest(BaseModel):")
    class_end = text.find("\n\nclass UpdateTaskRequest(BaseModel):", class_start)
    if class_start < 0 or class_end < 0:
        raise PatchError("CreateTaskRequest block anchor not found in models/base.py")

    block = text[class_start:class_end]
    if CREATE_SUBTASK_FIELD_LINE.strip() in block:
        return PatchResult(False, text)

    tags_line = '    tags: Optional[list[str]] = Field(None, description="标签列表")\n'
    insert_at = block.find(tags_line)
    if insert_at < 0:
        raise PatchError("tags field anchor not found in CreateTaskRequest block")
    insert_at += len(tags_line)

    block = block[:insert_at] + CREATE_SUBTASK_FIELD_LINE + block[insert_at:]
    return PatchResult(True, text[:class_start] + block + text[class_end:])


def _ensure_router_sort_order_constant(text: str) -> PatchResult:
    if ROUTERS_SORT_ORDER_LINE.strip() in text:
        return PatchResult(False, text)

    anchor = 'router = APIRouter(prefix="/tasks", tags=["任务管理"])\n'
    idx = text.find(anchor)
    if idx < 0:
        raise PatchError("router anchor not found in routers/tasks.py")
    idx += len(anchor)

    updated = text[:idx] + ROUTERS_SORT_ORDER_LINE + text[idx:]
    return PatchResult(True, updated)


def _ensure_router_subtask_mapping(text: str) -> PatchResult:
    if ROUTERS_SORT_ORDER_MARKER in text:
        return PatchResult(False, text)

    func_start = text.find("async def create_task(task_request: CreateTaskRequest):")
    if func_start < 0:
        raise PatchError("create_task function not found in routers/tasks.py")

    # Find function boundary by next route decorator.
    next_route = text.find("\n\n@router.post", func_start + 1)
    func_end = next_route if next_route >= 0 else len(text)
    func_body = text[func_start:func_end]

    start_line = "        task_data = task_request.model_dump(by_alias=True, exclude_none=True)\n"
    end_line = "        return await dida_service.create_task(task_data)\n"
    start_idx = func_body.find(start_line)
    end_idx = func_body.find(end_line)
    if start_idx < 0 or end_idx < 0:
        raise PatchError("create_task payload block anchor not found in routers/tasks.py")
    end_idx += len(end_line)

    replacement = (
        "        task_data = task_request.model_dump(by_alias=True, exclude_none=True)\n"
        "        subtasks = task_data.pop(\"subtasks\", None)\n"
        "        if subtasks is not None:\n"
        "            clean_subtasks = [\n"
        "                item.strip()\n"
        "                for item in subtasks\n"
        "                if isinstance(item, str) and item.strip()\n"
        "            ]\n"
        "            items = [\n"
        "                {\n"
        "                    \"id\": generate_object_id(),\n"
        "                    \"title\": title,\n"
        "                    \"status\": 0,\n"
        "                    \"sortOrder\": index * SUBTASK_SORT_ORDER_STEP,\n"
        "                }\n"
        "                for index, title in enumerate(clean_subtasks)\n"
        "            ]\n"
        "            if items:\n"
        "                task_data[\"items\"] = items\n"
        "        return await dida_service.create_task(task_data)\n"
    )

    func_body = func_body[:start_idx] + replacement + func_body[end_idx:]
    updated = text[:func_start] + func_body + text[func_end:]
    return PatchResult(True, updated)


def _ensure_cli_subtask_payload(text: str) -> PatchResult:
    if CLI_SUBTASK_PAYLOAD_MARKER in text:
        return PatchResult(False, text)

    anchor = (
        "    if args.tags:\n"
        "        payload[\"tags\"] = args.tags\n"
        "\n"
        "    response = client.post(\"/tasks/create\", payload=payload)\n"
    )
    if anchor not in text:
        raise PatchError("cmd_create anchor not found in didaapi_manager.py")

    replacement = (
        "    if args.tags:\n"
        "        payload[\"tags\"] = args.tags\n"
        "    subtasks = getattr(args, \"subtasks\", [])\n"
        "    if subtasks:\n"
        "        clean_subtasks = [item.strip() for item in subtasks if isinstance(item, str) and item.strip()]\n"
        "        if clean_subtasks:\n"
        "            payload[\"subtasks\"] = clean_subtasks\n"
        "\n"
        "    response = client.post(\"/tasks/create\", payload=payload)\n"
    )

    updated = text.replace(anchor, replacement, 1)
    return PatchResult(True, updated)


def _ensure_cli_subtask_arg(text: str) -> PatchResult:
    if CLI_SUBTASK_ARG_LINE.strip() in text:
        return PatchResult(False, text)

    anchor = (
        '    create_parser.add_argument("--tag", dest="tags", action="append", default=[], '
        'help="Tag (repeatable)")\n'
    )
    idx = text.find(anchor)
    if idx < 0:
        raise PatchError("create_parser --tag anchor not found in didaapi_manager.py")
    idx += len(anchor)

    updated = text[:idx] + CLI_SUBTASK_ARG_LINE + text[idx:]
    return PatchResult(True, updated)


def _apply_transforms(text: str, transforms: list[Callable[[str], PatchResult]]) -> PatchResult:
    changed = False
    current = text
    for transform in transforms:
        result = transform(current)
        changed = changed or result.changed
        current = result.content
    return PatchResult(changed, current)


def _ensure_markers(models_text: str, routers_text: str, cli_text: str) -> None:
    if CREATE_SUBTASK_FIELD_LINE.strip() not in models_text:
        raise PatchError("missing CreateTaskRequest.subtasks marker after patch")
    if ROUTERS_IMPORT_LINE.strip() not in routers_text:
        raise PatchError("missing routers/tasks.py generate_object_id import marker after patch")
    if ROUTERS_SORT_ORDER_LINE.strip() not in routers_text:
        raise PatchError("missing routers/tasks.py SUBTASK_SORT_ORDER_STEP marker after patch")
    if ROUTERS_SORT_ORDER_MARKER not in routers_text:
        raise PatchError("missing routers/tasks.py subtask sortOrder mapping marker after patch")
    if CLI_SUBTASK_PAYLOAD_MARKER not in cli_text:
        raise PatchError("missing didaapi_manager.py payload subtasks marker after patch")
    if CLI_SUBTASK_ARG_LINE.strip() not in cli_text:
        raise PatchError("missing didaapi_manager.py --subtask parser marker after patch")


def run(apply: bool, workspace_root: Path) -> dict:
    models_path = workspace_root / MODELS_BASE_PATH
    routers_path = workspace_root / ROUTERS_TASKS_PATH
    cli_path = workspace_root / CLI_MANAGER_PATH

    for target in (models_path, routers_path, cli_path):
        if not target.is_file():
            raise PatchError(f"target file missing: {target}")

    models_original = models_path.read_text(encoding="utf-8")
    routers_original = routers_path.read_text(encoding="utf-8")
    cli_original = cli_path.read_text(encoding="utf-8")

    models_result = _apply_transforms(models_original, [_ensure_subtasks_field])
    routers_result = _apply_transforms(
        routers_original,
        [_replace_utils_import, _ensure_router_sort_order_constant, _ensure_router_subtask_mapping],
    )
    cli_result = _apply_transforms(
        cli_original,
        [_ensure_cli_subtask_payload, _ensure_cli_subtask_arg],
    )

    _ensure_markers(models_result.content, routers_result.content, cli_result.content)

    if apply:
        if models_result.changed:
            models_path.write_text(models_result.content, encoding="utf-8")
        if routers_result.changed:
            routers_path.write_text(routers_result.content, encoding="utf-8")
        if cli_result.changed:
            cli_path.write_text(cli_result.content, encoding="utf-8")

    changed_any = models_result.changed or routers_result.changed or cli_result.changed
    status = "patched" if (apply and changed_any) else "already_patched"
    if not apply and changed_any:
        status = "would_patch"

    return {
        "ok": True,
        "apply": apply,
        "status": status,
        "workspace_root": str(workspace_root),
        "files": {
            str(MODELS_BASE_PATH): {"changed": models_result.changed},
            str(ROUTERS_TASKS_PATH): {"changed": routers_result.changed},
            str(CLI_MANAGER_PATH): {"changed": cli_result.changed},
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Ensure DidaAPI subtask patch is present in backend + CLI files"
    )
    parser.add_argument("--dry-run", action="store_true", help="Preview patch result without writing")
    parser.add_argument("--apply", action="store_true", help="Apply patch changes to files")
    parser.add_argument(
        "--workspace-root",
        default=str(DEFAULT_WORKSPACE_ROOT),
        help=f"Workspace root path (default: {DEFAULT_WORKSPACE_ROOT})",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    apply = args.apply or not args.dry_run
    workspace_root = Path(args.workspace_root).expanduser().resolve()

    try:
        result = run(apply=apply, workspace_root=workspace_root)
        print(json.dumps(result, ensure_ascii=True))
        return 0
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
