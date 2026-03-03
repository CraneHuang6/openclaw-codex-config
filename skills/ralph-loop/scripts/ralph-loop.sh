#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER="$SCRIPT_DIR/parse_tasks.py"
STATE_ROOT="/Users/crane/.codex/workspace/outputs/ralph-loop"

usage() {
  cat <<'USAGE'
Usage:
  bash ralph-loop.sh --plan <abs-path> --mode <parallel|hybrid|serial> --max-lanes <N> --dry-run
  bash ralph-loop.sh --plan <abs-path> --resume

Core options:
  --plan <path>           Markdown plan with checkbox tasks
  --mode <value>          parallel (default) | hybrid | serial
  --max-lanes <n>         Max lanes for dispatch (default: 3)
  --dry-run               Simulate full schedule without writing state
  --resume                Resume from existing run_state.json

State update options (non-dry-run):
  --complete <task-id>    Mark task completed (repeatable)
  --fail <task-id>        Mark task failed and release lane (repeatable)

Gate flags (required for non-dry-run):
  --plan-approved
  --reviewer-pass
  --tester-pass

Optional:
  --no-strict             Allow unknown dependency IDs
  -h, --help              Show help
USAGE
}

PLAN=""
MODE="parallel"
MAX_LANES=3
DRY_RUN=0
RESUME=0
STRICT=1
PLAN_APPROVED=0
REVIEWER_PASS=0
TESTER_PASS=0
COMPLETE_IDS=()
FAIL_IDS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)
      PLAN="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      shift 2
      ;;
    --max-lanes)
      MAX_LANES="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --resume)
      RESUME=1
      shift
      ;;
    --complete)
      COMPLETE_IDS+=("$2")
      shift 2
      ;;
    --fail)
      FAIL_IDS+=("$2")
      shift 2
      ;;
    --plan-approved)
      PLAN_APPROVED=1
      shift
      ;;
    --reviewer-pass)
      REVIEWER_PASS=1
      shift
      ;;
    --tester-pass)
      TESTER_PASS=1
      shift
      ;;
    --no-strict)
      STRICT=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$PLAN" ]]; then
  echo "Missing required option: --plan" >&2
  usage
  exit 1
fi

case "$MODE" in
  parallel|hybrid|serial) ;;
  *)
    echo "Invalid --mode: $MODE (expected parallel|hybrid|serial)" >&2
    exit 1
    ;;
esac

if ! [[ "$MAX_LANES" =~ ^[0-9]+$ ]] || [[ "$MAX_LANES" -lt 1 ]]; then
  echo "--max-lanes must be a positive integer" >&2
  exit 1
fi

if [[ ! -f "$PARSER" ]]; then
  echo "Missing parser script: $PARSER" >&2
  exit 1
fi

if [[ "$PLAN" = /* ]]; then
  PLAN_ABS="$PLAN"
else
  PLAN_ABS="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"
fi

if [[ ! -f "$PLAN_ABS" ]]; then
  echo "Plan file does not exist: $PLAN_ABS" >&2
  exit 1
fi

COMPLETE_CSV=""
if [[ ${#COMPLETE_IDS[@]} -gt 0 ]]; then
  COMPLETE_CSV="$(IFS=,; echo "${COMPLETE_IDS[*]}")"
fi
FAIL_CSV=""
if [[ ${#FAIL_IDS[@]} -gt 0 ]]; then
  FAIL_CSV="$(IFS=,; echo "${FAIL_IDS[*]}")"
fi

export PARSER PLAN_ABS MODE MAX_LANES DRY_RUN RESUME STRICT PLAN_APPROVED REVIEWER_PASS TESTER_PASS COMPLETE_CSV FAIL_CSV STATE_ROOT

python3 - <<'PY'
from __future__ import annotations

import datetime as dt
import fcntl
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def eprint(msg: str) -> None:
    print(msg, file=sys.stderr)


def parse_csv(value: str) -> list[str]:
    if not value:
        return []
    return [part.strip() for part in value.split(",") if part.strip()]


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def lane_capacity(mode: str, max_lanes: int) -> int:
    if mode == "serial":
        return 1
    if mode == "hybrid":
        return min(max_lanes, 2)
    return max_lanes


def parse_tasks(plan_abs: str, parser_path: str, strict: bool) -> list[dict]:
    cmd = [sys.executable, parser_path, "--plan", plan_abs]
    if strict:
        cmd.append("--strict")
    proc = subprocess.run(cmd, text=True, capture_output=True)
    if proc.returncode != 0:
        message = proc.stderr.strip() or proc.stdout.strip() or "parse_tasks failed"
        raise RuntimeError(message)
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid parser JSON output: {exc}") from exc


def build_initial_state(tasks: list[dict], plan_abs: str, mode: str, max_lanes: int) -> dict:
    now = utc_now()
    materialized = []
    for task in tasks:
        materialized.append(
            {
                "id": task["id"],
                "title": task["title"],
                "line": task["line"],
                "depends": task.get("depends", []),
                "status": "completed" if task.get("checked") else "pending",
                "lane": None,
                "retries": 0,
                "source": task.get("source", ""),
            }
        )

    return {
        "schema_version": 1,
        "plan_path": plan_abs,
        "mode": mode,
        "max_lanes": max_lanes,
        "created_at": now,
        "updated_at": now,
        "status": "active",
        "tasks": materialized,
    }


def reconcile_tasks_with_plan(state: dict, tasks: list[dict]) -> list[str]:
    old_map = {task["id"]: task for task in state.get("tasks", [])}
    merged = []
    changes: list[str] = []

    for task in tasks:
        old = old_map.get(task["id"])
        if old is None:
            merged.append(
                {
                    "id": task["id"],
                    "title": task["title"],
                    "line": task["line"],
                    "depends": task.get("depends", []),
                    "status": "completed" if task.get("checked") else "pending",
                    "lane": None,
                    "retries": 0,
                    "source": task.get("source", ""),
                }
            )
            changes.append(f"add {task['id']}")
            continue

        status = old.get("status", "pending")
        if status not in {"pending", "claimed", "completed", "failed"}:
            status = "pending"
        if task.get("checked"):
            status = "completed"

        merged.append(
            {
                "id": task["id"],
                "title": task["title"],
                "line": task["line"],
                "depends": task.get("depends", []),
                "status": status,
                "lane": old.get("lane") if status == "claimed" else None,
                "retries": int(old.get("retries", 0)),
                "source": task.get("source", ""),
            }
        )

    removed = [task_id for task_id in old_map if task_id not in {task["id"] for task in tasks}]
    for task_id in removed:
        changes.append(f"drop {task_id}")

    state["tasks"] = merged
    return changes


def atomic_write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as tmp:
        json.dump(payload, tmp, ensure_ascii=False, indent=2)
        tmp.write("\n")
        tmp_path = Path(tmp.name)
    os.replace(tmp_path, path)


def append_progress(progress_file: Path, entries: list[str]) -> None:
    progress_file.parent.mkdir(parents=True, exist_ok=True)
    with progress_file.open("a", encoding="utf-8") as handle:
        for entry in entries:
            handle.write(f"[{utc_now()}] {entry}\n")


def dependency_ready(task: dict, task_map: dict[str, dict]) -> tuple[bool, list[str]]:
    missing = []
    for dep in task.get("depends", []):
        dep_task = task_map.get(dep)
        if not dep_task or dep_task["status"] != "completed":
            missing.append(dep)
    return len(missing) == 0, missing


def summarize(state: dict) -> dict:
    counts = {"pending": 0, "claimed": 0, "completed": 0, "failed": 0}
    for task in state["tasks"]:
        status = task["status"]
        if status in counts:
            counts[status] += 1
    return counts


def schedule(state: dict) -> tuple[list[dict], list[dict]]:
    mode = state["mode"]
    cap = lane_capacity(mode, int(state["max_lanes"]))
    lanes = [f"lane-{i}" for i in range(1, cap + 1)]

    task_map = {task["id"]: task for task in state["tasks"]}
    claimed = [task for task in state["tasks"] if task["status"] == "claimed"]
    claimed_lanes = {task["lane"] for task in claimed if task.get("lane")}
    available_lanes = [lane for lane in lanes if lane not in claimed_lanes]

    ready = []
    blocked = []
    for task in sorted(state["tasks"], key=lambda item: (item["line"], item["id"])):
        if task["status"] not in {"pending", "failed"}:
            continue
        is_ready, missing = dependency_ready(task, task_map)
        if is_ready:
            ready.append(task)
        else:
            blocked.append({"id": task["id"], "missing": missing})

    claimed_now = []
    for task in ready:
        if not available_lanes:
            break
        lane = available_lanes.pop(0)
        task["status"] = "claimed"
        task["lane"] = lane
        claimed_now.append({"id": task["id"], "lane": lane, "title": task["title"]})

    return claimed_now, blocked


def all_completed(state: dict) -> bool:
    return all(task["status"] == "completed" for task in state["tasks"])


def dry_run(plan_abs: str, parser_path: str, mode: str, max_lanes: int, strict: bool) -> int:
    try:
        tasks = parse_tasks(plan_abs, parser_path, strict)
    except RuntimeError as exc:
        eprint(str(exc))
        return 1
    cap = lane_capacity(mode, max_lanes)
    lanes = [f"lane-{i}" for i in range(1, cap + 1)]

    state = build_initial_state(tasks, plan_abs, mode, max_lanes)
    rounds: list[list[tuple[str, str]]] = []

    while not all_completed(state):
        task_map = {task["id"]: task for task in state["tasks"]}
        ready = []
        for task in sorted(state["tasks"], key=lambda item: (item["line"], item["id"])):
            if task["status"] != "pending":
                continue
            ok, _ = dependency_ready(task, task_map)
            if ok:
                ready.append(task)

        if not ready:
            print("DRY_RUN=1")
            print(f"MODE={mode}")
            print("RESULT=blocked")
            for task in state["tasks"]:
                if task["status"] != "pending":
                    continue
                _, missing = dependency_ready(task, task_map)
                print(f"BLOCKED {task['id']} missing={','.join(missing)}")
            return 5

        assignments: list[tuple[str, str]] = []
        for idx, task in enumerate(ready[: len(lanes)]):
            lane = lanes[idx]
            assignments.append((lane, task["id"]))
            task["status"] = "completed"
        rounds.append(assignments)

    print("DRY_RUN=1")
    print(f"MODE={mode}")
    print(f"CAPACITY={cap}")
    for index, assignments in enumerate(rounds, start=1):
        rendered = " ".join([f"{lane}:{task_id}" for lane, task_id in assignments])
        print(f"ROUND {index}: {rendered}")
    print(f"ROUNDS={len(rounds)}")
    print("RESULT=complete")
    return 0


def main() -> int:
    parser_path = os.environ["PARSER"]
    plan_abs = os.environ["PLAN_ABS"]
    mode = os.environ["MODE"]
    max_lanes = int(os.environ["MAX_LANES"])
    dry = os.environ["DRY_RUN"] == "1"
    resume = os.environ["RESUME"] == "1"
    strict = os.environ["STRICT"] == "1"

    complete_ids = parse_csv(os.environ.get("COMPLETE_CSV", ""))
    fail_ids = parse_csv(os.environ.get("FAIL_CSV", ""))

    if dry:
        return dry_run(plan_abs, parser_path, mode, max_lanes, strict)

    missing_gates = []
    if os.environ.get("PLAN_APPROVED") != "1":
        missing_gates.append("plan-approved")
    if os.environ.get("REVIEWER_PASS") != "1":
        missing_gates.append("reviewer-pass")
    if os.environ.get("TESTER_PASS") != "1":
        missing_gates.append("tester-pass")
    if missing_gates:
        eprint("Gate check failed. Missing flags: " + ", ".join(missing_gates))
        return 20

    run_id = hashlib.sha1(plan_abs.encode("utf-8")).hexdigest()[:12]
    run_dir = Path(os.environ["STATE_ROOT"]) / run_id
    state_file = run_dir / "run_state.json"
    progress_file = run_dir / "progress.log"
    lock_file = run_dir / "claims.lock"

    run_dir.mkdir(parents=True, exist_ok=True)

    try:
        tasks = parse_tasks(plan_abs, parser_path, strict)
    except RuntimeError as exc:
        eprint(str(exc))
        return 1

    with lock_file.open("a+", encoding="utf-8") as lock_handle:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)

        log_entries: list[str] = []
        if resume:
            if not state_file.exists():
                eprint(f"--resume requested but state not found: {state_file}")
                return 3
            state = json.loads(state_file.read_text(encoding="utf-8"))
            log_entries.append("resume state")
            for change in reconcile_tasks_with_plan(state, tasks):
                log_entries.append(f"reconcile {change}")
        else:
            state = build_initial_state(tasks, plan_abs, mode, max_lanes)
            log_entries.append("initialize state")

        # Keep runtime knobs current on every run.
        state["mode"] = mode
        state["max_lanes"] = max_lanes

        task_map = {task["id"]: task for task in state["tasks"]}
        for task_id in complete_ids:
            task = task_map.get(task_id)
            if task is None:
                eprint(f"Unknown task id for --complete: {task_id}")
                return 4
            task["status"] = "completed"
            task["lane"] = None
            log_entries.append(f"complete {task_id}")

        for task_id in fail_ids:
            task = task_map.get(task_id)
            if task is None:
                eprint(f"Unknown task id for --fail: {task_id}")
                return 4
            if task["status"] == "completed":
                eprint(f"Cannot mark completed task as failed: {task_id}")
                return 4
            task["status"] = "failed"
            task["lane"] = None
            task["retries"] = int(task.get("retries", 0)) + 1
            log_entries.append(f"fail {task_id}")

        claimed_now, blocked = schedule(state)
        for item in claimed_now:
            log_entries.append(f"claim {item['id']} {item['lane']}")

        if all_completed(state):
            state["status"] = "completed"
            log_entries.append("run completed")
        elif not claimed_now and not any(task["status"] == "claimed" for task in state["tasks"]):
            state["status"] = "blocked"
            log_entries.append("run blocked by dependencies")
        else:
            state["status"] = "active"

        state["updated_at"] = utc_now()
        atomic_write_json(state_file, state)
        append_progress(progress_file, log_entries)

    counts = summarize(state)
    print(f"RUN_ID={run_id}")
    print(f"RUN_DIR={run_dir}")
    print(f"STATE_FILE={state_file}")
    print(f"PROGRESS_FILE={progress_file}")
    print(f"MODE={mode}")
    print(f"COUNTS pending={counts['pending']} claimed={counts['claimed']} completed={counts['completed']} failed={counts['failed']}")

    for item in claimed_now:
        print(f"DISPATCH task={item['id']} lane={item['lane']} title={item['title']}")

    if state["status"] == "blocked":
        print("RESULT=blocked")
        task_map = {task["id"]: task for task in state["tasks"]}
        for entry in blocked:
            task = task_map.get(entry["id"])
            if task and task["status"] in {"pending", "failed"}:
                print(f"BLOCKED task={entry['id']} missing={','.join(entry['missing'])}")
    elif state["status"] == "completed":
        print("RESULT=complete")
    else:
        print("RESULT=active")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
