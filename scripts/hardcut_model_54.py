#!/usr/bin/env python3
"""Hard-cut Codex/Claude defaults to gpt-5.4 with monitor kept on mini.

This script supports:
1) runtime hard-cut apply (clear reuse entrypoints + archive old 5.3 threads)
2) first-request model checks for Codex/Claude
3) 4-entry coverage verification + 30-min drift observation
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import sqlite3
import subprocess
import sys
from typing import Any


def parse_args() -> argparse.Namespace:
    home = pathlib.Path.home()
    codex_home = home / ".codex"
    parser = argparse.ArgumentParser(description="5.4 hard-cut helper for Codex + Claude")
    parser.add_argument("action", choices=["apply", "verify"], help="Run hard-cut apply or verification")

    parser.add_argument("--codex-global-state", default=str(codex_home / ".codex-global-state.json"))
    parser.add_argument("--codex-sqlite", default=str(codex_home / "state_5.sqlite"))
    parser.add_argument("--claude-state", default=str(home / ".claude.json"))
    parser.add_argument("--claude-projects-dir", default=str(home / ".claude/projects"))
    parser.add_argument("--baseline-file", default=str(codex_home / "tmp/model_54_hardcut_baseline.json"))

    parser.add_argument("--target-model", default="gpt-5.4")
    parser.add_argument("--fallback-model", default="gpt-5.3-codex")
    parser.add_argument("--monitor-model", default="gpt-5.1-codex-mini")

    parser.add_argument("--codex-main-cwd", default=str(codex_home))
    parser.add_argument("--codex-worktrees-root", default=str(codex_home / "worktrees"))
    parser.add_argument("--claude-main-cwd", default=str(home))
    parser.add_argument("--claude-project-cwd", default=str(home / ".openclaw"))

    parser.add_argument("--window-minutes", type=int, default=30)
    parser.add_argument("--kill-runtime", action="store_true", help="Kill known stale runtime processes")
    parser.add_argument("--auto-close-on-mismatch", action="store_true", help="Auto-close mismatched sessions")
    parser.add_argument("--since-ts", type=int, default=0, help="Override baseline timestamp for verify")

    return parser.parse_args()


def epoch_now() -> int:
    return int(dt.datetime.now(dt.timezone.utc).timestamp())


def iso_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def load_json(path: pathlib.Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def dump_json(path: pathlib.Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def backup_file(path: pathlib.Path, backup_root: pathlib.Path, ts: str) -> pathlib.Path:
    backup_root.mkdir(parents=True, exist_ok=True)
    out = backup_root / f"{path.name}.{ts}.bak"
    out.write_bytes(path.read_bytes())
    return out


def sql_fetch_all(conn: sqlite3.Connection, sql: str, params: tuple[Any, ...] = ()) -> list[sqlite3.Row]:
    conn.row_factory = sqlite3.Row
    cur = conn.execute(sql, params)
    return list(cur.fetchall())


def get_latest_model_rows(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    sql = """
WITH req AS (
  SELECT
    thread_id,
    ts,
    CASE
      WHEN instr(message, '"model":"') > 0 THEN
        substr(
          message,
          instr(message, '"model":"') + length('"model":"'),
          instr(substr(message, instr(message, '"model":"') + length('"model":"')), '"') - 1
        )
      ELSE NULL
    END AS model
  FROM logs
  WHERE target = 'codex_client::transport'
    AND message LIKE '%/v1/responses:%'
    AND thread_id IS NOT NULL
    AND thread_id <> ''
), latest AS (
  SELECT thread_id, max(ts) AS max_ts
  FROM req
  GROUP BY thread_id
)
SELECT r.thread_id, r.model, r.ts, t.archived, t.title, t.cwd, t.created_at, t.updated_at
FROM req r
JOIN latest l ON l.thread_id = r.thread_id AND l.max_ts = r.ts
JOIN threads t ON t.id = r.thread_id
ORDER BY r.ts DESC
"""
    return sql_fetch_all(conn, sql)


def get_first_model_rows(conn: sqlite3.Connection) -> list[sqlite3.Row]:
    sql = """
WITH req AS (
  SELECT
    thread_id,
    ts,
    CASE
      WHEN instr(message, '"model":"') > 0 THEN
        substr(
          message,
          instr(message, '"model":"') + length('"model":"'),
          instr(substr(message, instr(message, '"model":"') + length('"model":"')), '"') - 1
        )
      ELSE NULL
    END AS model
  FROM logs
  WHERE target = 'codex_client::transport'
    AND message LIKE '%/v1/responses:%'
    AND thread_id IS NOT NULL
    AND thread_id <> ''
), first_req AS (
  SELECT thread_id, min(ts) AS first_ts
  FROM req
  GROUP BY thread_id
)
SELECT r.thread_id, r.model, r.ts AS first_ts, t.cwd, t.archived, t.title, t.created_at, t.updated_at
FROM req r
JOIN first_req f ON f.thread_id = r.thread_id AND f.first_ts = r.ts
JOIN threads t ON t.id = r.thread_id
ORDER BY t.created_at DESC
"""
    return sql_fetch_all(conn, sql)


def get_recent_threads(conn: sqlite3.Connection, since_ts: int) -> list[sqlite3.Row]:
    sql = """
SELECT id AS thread_id, cwd, archived, title, created_at, updated_at, rollout_path
FROM threads
WHERE created_at >= ?
ORDER BY created_at DESC
"""
    return sql_fetch_all(conn, sql, (since_ts,))


def get_latest_updated_thread_id(conn: sqlite3.Connection) -> str | None:
    rows = sql_fetch_all(
        conn,
        "SELECT id FROM threads WHERE archived = 0 ORDER BY updated_at DESC LIMIT 1",
    )
    return str(rows[0]["id"]) if rows else None


def archive_threads(conn: sqlite3.Connection, thread_ids: list[str]) -> int:
    if not thread_ids:
        return 0
    placeholders = ",".join("?" for _ in thread_ids)
    ts = epoch_now()
    conn.execute(
        f"UPDATE threads SET archived = 1, archived_at = ? WHERE id IN ({placeholders}) AND archived = 0",
        (ts, *thread_ids),
    )
    conn.commit()
    return conn.total_changes


def clear_codex_reuse_entrypoints(global_state_path: pathlib.Path, archived_ids: set[str]) -> dict[str, Any]:
    data = load_json(global_state_path)
    old_pinned = list(data.get("pinned-thread-ids", []))
    data["pinned-thread-ids"] = []

    # Remove stale metadata for archived/pinned thread ids so picker does not bias to old sessions.
    stale_ids = set(old_pinned) | archived_ids
    for key in ("thread-titles", "thread-workspace-root-hints"):
        if isinstance(data.get(key), dict):
            data[key] = {k: v for k, v in data[key].items() if k not in stale_ids}

    dump_json(global_state_path, data)
    return {
        "old_pinned": old_pinned,
        "cleared_pinned_count": len(old_pinned),
        "cleared_metadata_ids": len(stale_ids),
    }


def clear_claude_last_session_ids(claude_state_path: pathlib.Path) -> dict[str, Any]:
    data = load_json(claude_state_path)
    projects = data.get("projects", {})
    reset: list[dict[str, str]] = []
    if isinstance(projects, dict):
        for project_path, config in projects.items():
            if isinstance(config, dict) and config.get("lastSessionId"):
                reset.append({"project": project_path, "old_lastSessionId": str(config.get("lastSessionId"))})
                config["lastSessionId"] = None
    dump_json(claude_state_path, data)
    return {"projects_reset": reset, "reset_count": len(reset)}


def run_cmd(cmd: list[str]) -> tuple[int, str]:
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    combined = (proc.stdout or "") + (proc.stderr or "")
    return proc.returncode, combined.strip()


def kill_stale_runtime_processes() -> list[dict[str, Any]]:
    patterns = [
        "codex --no-alt-screen -m gpt-5.3-codex",
        "codex --no-alt-screen --disable shell_snapshot -c developer_instructions=\"# CODE REVIEWER AGENT",
        "claude --dangerously-skip-permissions --append-system-prompt # DEVELOPER AGENT",
        "tmux new-session -d -s claude_long",
    ]
    report: list[dict[str, Any]] = []
    for pattern in patterns:
        # pgrep returns 1 when no match; that is acceptable.
        pgrep_code, pgrep_out = run_cmd(["pgrep", "-f", pattern])
        matched_pids = [line.strip() for line in pgrep_out.splitlines() if line.strip().isdigit()] if pgrep_code == 0 else []
        pkill_code, _ = run_cmd(["pkill", "-f", pattern])
        report.append(
            {
                "pattern": pattern,
                "matched_pids": matched_pids,
                "killed_count": len(matched_pids),
                "pkill_code": pkill_code,
            }
        )
    return report


def parse_iso_to_epoch(value: str | None) -> int | None:
    if not value:
        return None
    try:
        return int(dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def parse_rollout_turn_context_model(rollout_path: str | None) -> str | None:
    if not rollout_path:
        return None
    path = pathlib.Path(rollout_path)
    if not path.exists():
        return None
    try:
        with path.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get("type") != "turn_context":
                    continue
                payload = obj.get("payload")
                if isinstance(payload, dict) and isinstance(payload.get("model"), str):
                    return payload.get("model")
    except OSError:
        return None
    return None


def iter_claude_sessions(projects_dir: pathlib.Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for file in sorted(projects_dir.rglob("*.jsonl")):
        if "/subagents/" in str(file) or "/tool-results/" in str(file):
            continue
        session_id = file.stem
        first_cwd: str | None = None
        first_assistant_model: str | None = None
        first_ts: int | None = None

        try:
            with file.open("r", encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                    except json.JSONDecodeError:
                        continue

                    if first_cwd is None and isinstance(obj.get("cwd"), str):
                        first_cwd = obj.get("cwd")

                    if first_ts is None:
                        ts_candidate = parse_iso_to_epoch(obj.get("timestamp"))
                        if ts_candidate is not None:
                            first_ts = ts_candidate

                    message = obj.get("message") if isinstance(obj.get("message"), dict) else None
                    if first_assistant_model is None and obj.get("type") == "assistant" and message:
                        model = message.get("model")
                        if isinstance(model, str):
                            first_assistant_model = model

                    if first_cwd and first_assistant_model and first_ts is not None:
                        break
        except OSError:
            continue

        if first_cwd and first_assistant_model and first_ts is not None:
            rows.append(
                {
                    "session_id": session_id,
                    "file": str(file),
                    "cwd": first_cwd,
                    "first_model": first_assistant_model,
                    "first_ts": first_ts,
                }
            )
    return rows


def categorize_codex(cwd: str, codex_main_cwd: str, codex_worktrees_root: str) -> str | None:
    if cwd == codex_main_cwd:
        return "codex_main"
    if cwd.startswith(codex_worktrees_root.rstrip("/") + "/"):
        return "codex_worktree"
    return None


def categorize_claude(cwd: str, claude_main_cwd: str, claude_project_cwd: str) -> str | None:
    if cwd == claude_main_cwd:
        return "claude_main"
    if cwd.startswith(claude_project_cwd.rstrip("/") + "/") or cwd == claude_project_cwd:
        return "claude_project"
    return None


def verify(args: argparse.Namespace) -> dict[str, Any]:
    baseline_path = pathlib.Path(args.baseline_file)
    baseline = load_json(baseline_path) if baseline_path.exists() else {}
    since_ts = args.since_ts or int(baseline.get("hardcut_ts", 0))
    if since_ts <= 0:
        since_ts = epoch_now() - 3600

    codex_db = pathlib.Path(args.codex_sqlite)
    conn = sqlite3.connect(codex_db)
    codex_first = get_first_model_rows(conn)
    codex_latest = get_latest_model_rows(conn)
    codex_recent_threads = get_recent_threads(conn, since_ts)

    codex_first_by_thread = {str(row["thread_id"]): row for row in codex_first}

    codex_candidates: dict[str, dict[str, Any]] = {}
    for row in codex_recent_threads:
        category = categorize_codex(str(row["cwd"]), args.codex_main_cwd, args.codex_worktrees_root)
        if not category:
            continue

        thread_id = str(row["thread_id"])
        log_row = codex_first_by_thread.get(thread_id)
        model_source = "state_5.sqlite:first_post"
        first_model: str | None = None
        first_ts: int | None = None
        if log_row is not None and log_row["model"] is not None:
            first_model = str(log_row["model"])
            first_ts = int(log_row["first_ts"])
        else:
            first_model = parse_rollout_turn_context_model(str(row["rollout_path"]))
            model_source = "session_rollout:turn_context"

        if not first_model:
            continue

        item = {
            "thread_id": thread_id,
            "first_model": first_model,
            "first_ts": first_ts,
            "created_at": int(row["created_at"]),
            "cwd": str(row["cwd"]),
            "title": str(row["title"]),
            "archived": int(row["archived"]),
            "model_source": model_source,
        }
        prev = codex_candidates.get(category)
        if prev is None or item["created_at"] > prev["created_at"]:
            codex_candidates[category] = item

    required_codex = ["codex_main", "codex_worktree"]
    codex_missing = [x for x in required_codex if x not in codex_candidates]
    codex_mismatch = [
        {"category": k, **v}
        for k, v in codex_candidates.items()
        if v["first_model"] != args.target_model
    ]

    # 30-minute observation on sessions created after hard-cut baseline:
    # first model fallback => default drift; first model target then fallback => explicit fallback.
    window_start = epoch_now() - args.window_minutes * 60
    first_model_by_thread = {
        str(row["thread_id"]): str(row["model"])
        for row in codex_first
        if row["model"] is not None
    }
    latest_by_thread = {
        str(row["thread_id"]): row
        for row in codex_latest
        if int(row["ts"]) >= window_start and int(row["created_at"]) >= since_ts
    }
    fallback_default_threads: list[dict[str, Any]] = []
    fallback_explicit_threads: list[dict[str, Any]] = []
    for tid, row in latest_by_thread.items():
        latest_model = str(row["model"])
        if latest_model != args.fallback_model:
            continue
        item = {
            "thread_id": tid,
            "latest_model": latest_model,
            "first_model": first_model_by_thread.get(tid),
            "title": str(row["title"]),
            "cwd": str(row["cwd"]),
            "ts": int(row["ts"]),
        }
        if item["first_model"] == args.target_model:
            fallback_explicit_threads.append(item)
        else:
            fallback_default_threads.append(item)

    conn.close()

    claude_rows = iter_claude_sessions(pathlib.Path(args.claude_projects_dir))
    claude_candidates: dict[str, dict[str, Any]] = {}
    for item in claude_rows:
        if int(item["first_ts"]) < since_ts:
            continue
        category = categorize_claude(item["cwd"], args.claude_main_cwd, args.claude_project_cwd)
        if not category:
            continue
        prev = claude_candidates.get(category)
        if prev is None or int(item["first_ts"]) > int(prev["first_ts"]):
            claude_candidates[category] = item

    required_claude = ["claude_main", "claude_project"]
    claude_missing = [x for x in required_claude if x not in claude_candidates]
    claude_mismatch = [
        {"category": k, **v}
        for k, v in claude_candidates.items()
        if v["first_model"] != args.target_model
    ]

    close_actions: list[dict[str, Any]] = []
    if args.auto_close_on_mismatch and claude_mismatch:
        claude_state_path = pathlib.Path(args.claude_state)
        state = load_json(claude_state_path)
        projects = state.get("projects", {})
        for mismatch in claude_mismatch:
            sid = mismatch["session_id"]
            for project_path, config in (projects.items() if isinstance(projects, dict) else []):
                if isinstance(config, dict) and str(config.get("lastSessionId")) == sid:
                    config["lastSessionId"] = None
                    close_actions.append(
                        {
                            "provider": "claude",
                            "project": project_path,
                            "closed_session_id": sid,
                            "reason": "first model mismatch",
                        }
                    )
        dump_json(claude_state_path, state)

    if args.auto_close_on_mismatch and codex_mismatch:
        conn2 = sqlite3.connect(args.codex_sqlite)
        closed = archive_threads(conn2, [x["thread_id"] for x in codex_mismatch])
        conn2.close()
        close_actions.append(
            {
                "provider": "codex",
                "closed_threads": [x["thread_id"] for x in codex_mismatch],
                "closed_count": closed,
                "reason": "first model mismatch",
            }
        )

    result = {
        "since_ts": since_ts,
        "since_iso": dt.datetime.fromtimestamp(since_ts, tz=dt.timezone.utc).isoformat(),
        "target_model": args.target_model,
        "codex": {
            "required_categories": required_codex,
            "candidates": codex_candidates,
            "missing": codex_missing,
            "mismatch": codex_mismatch,
            "window_minutes": args.window_minutes,
            "window_fallback_default_threads": fallback_default_threads,
            "window_fallback_explicit_threads": fallback_explicit_threads,
        },
        "claude": {
            "required_categories": required_claude,
            "candidates": claude_candidates,
            "missing": claude_missing,
            "mismatch": claude_mismatch,
        },
        "auto_close_actions": close_actions,
    }

    return result


def apply(args: argparse.Namespace) -> dict[str, Any]:
    codex_global_state = pathlib.Path(args.codex_global_state)
    codex_sqlite = pathlib.Path(args.codex_sqlite)
    claude_state = pathlib.Path(args.claude_state)
    baseline_file = pathlib.Path(args.baseline_file)

    ts = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup_root = baseline_file.parent / "hardcut_backups"

    backups = {
        "codex_global_state": str(backup_file(codex_global_state, backup_root, ts)),
        "claude_state": str(backup_file(claude_state, backup_root, ts)),
    }

    conn = sqlite3.connect(codex_sqlite)
    latest_rows = get_latest_model_rows(conn)
    latest_updated_thread_id = get_latest_updated_thread_id(conn)

    state_before = load_json(codex_global_state)
    pinned_before = list(state_before.get("pinned-thread-ids", []))

    keep_thread_ids: set[str] = set()
    if pinned_before:
        keep_thread_ids.add(str(pinned_before[0]))
    if latest_updated_thread_id:
        keep_thread_ids.add(str(latest_updated_thread_id))

    to_archive = [
        str(r["thread_id"])
        for r in latest_rows
        if str(r["model"]) == args.fallback_model
        and int(r["archived"]) == 0
        and str(r["thread_id"]) not in keep_thread_ids
    ]
    archived_count = archive_threads(conn, to_archive)
    conn.close()

    codex_clear = clear_codex_reuse_entrypoints(codex_global_state, set(to_archive))
    claude_clear = clear_claude_last_session_ids(claude_state)

    killed_report: list[dict[str, Any]] = []
    if args.kill_runtime:
        killed_report = kill_stale_runtime_processes()

    baseline = {
        "hardcut_ts": epoch_now(),
        "hardcut_iso": iso_now(),
        "target_model": args.target_model,
        "fallback_model": args.fallback_model,
        "monitor_model": args.monitor_model,
        "backups": backups,
        "kept_thread_ids": sorted(keep_thread_ids),
        "archived_thread_ids": to_archive,
        "archived_count": archived_count,
        "codex_clear": codex_clear,
        "claude_clear": claude_clear,
        "killed_runtime": killed_report,
    }
    dump_json(baseline_file, baseline)
    return baseline


def main() -> int:
    args = parse_args()

    if args.action == "apply":
        report = apply(args)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0

    verify_report = verify(args)
    print(json.dumps(verify_report, ensure_ascii=False, indent=2))

    has_failure = False
    if verify_report["codex"]["missing"] or verify_report["codex"]["mismatch"]:
        has_failure = True
    if verify_report["claude"]["missing"] or verify_report["claude"]["mismatch"]:
        has_failure = True
    if verify_report["codex"]["window_fallback_default_threads"]:
        has_failure = True

    return 2 if has_failure else 0


if __name__ == "__main__":
    sys.exit(main())
