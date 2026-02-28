#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
JOB_ID="${OPENCLAW_CRON_PRECHECK_JOB_ID:-fb1707cc-ed1b-431e-9dc7-5348a60a27a5}"
RUN_LOG_FILE="${OPENCLAW_CRON_PRECHECK_RUN_LOG_FILE:-$OPENCLAW_HOME/cron/runs/${JOB_ID}.jsonl}"
SESSIONS_DIR="${OPENCLAW_CRON_PRECHECK_SESSIONS_DIR:-$OPENCLAW_HOME/agents/main/sessions}"
DIST_DIR="${OPENCLAW_CRON_PRECHECK_DIST_DIR:-/opt/homebrew/lib/node_modules/openclaw/dist}"
SUMMARY_FAIL_REGEX="${OPENCLAW_CRON_PRECHECK_FAIL_SUMMARY_REGEX:-第一批资料|等待8秒后继续搜索|记录第一批资料}"
SESSION_ID_FILTER="${OPENCLAW_CRON_PRECHECK_SESSION_ID:-}"
ALL_JOBS=0

patch_marker_files=0
patch_marker_total=0
patch_marker_complete=0
patch_check_reason="unknown"

eval_result="fail"
eval_reason="unknown"
eval_exit_code=1
eval_latest_status=""
eval_latest_summary=""
eval_latest_session_id=""
eval_latest_ts="0"
eval_summary_head=""
eval_last_assistant_stop="unknown"
eval_last_assistant_tool_calls="0"
eval_session_file=""
eval_session_file_exists=1

usage() {
  cat <<'USAGE'
Usage: cron-partial-report-precheck.sh [--job-id <id>] [--run-log <path>] [--sessions-dir <path>] [--session-id <id>] [--all-jobs]

Detects whether cron runs were incorrectly marked as ok while only returning interim output.
Checks:
1) Latest finished run status/summary
2) Last assistant stopReason/tool calls in linked session
3) Runtime patch marker coverage in gateway-cli-*.js (must be full coverage)
USAGE
}

while (($#)); do
  case "$1" in
    --job-id)
      if (($# < 2)); then
        echo "missing value for --job-id" >&2
        exit 2
      fi
      JOB_ID="$2"
      RUN_LOG_FILE="$OPENCLAW_HOME/cron/runs/${JOB_ID}.jsonl"
      shift 2
      ;;
    --run-log)
      if (($# < 2)); then
        echo "missing value for --run-log" >&2
        exit 2
      fi
      RUN_LOG_FILE="$2"
      shift 2
      ;;
    --sessions-dir)
      if (($# < 2)); then
        echo "missing value for --sessions-dir" >&2
        exit 2
      fi
      SESSIONS_DIR="$2"
      shift 2
      ;;
    --session-id)
      if (($# < 2)); then
        echo "missing value for --session-id" >&2
        exit 2
      fi
      SESSION_ID_FILTER="$2"
      shift 2
      ;;
    --all-jobs)
      ALL_JOBS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi

check_patch_marker_coverage() {
  patch_marker_files=0
  patch_marker_total=0
  patch_marker_complete=0
  patch_check_reason="unknown"

  if [[ ! -d "$DIST_DIR" ]]; then
    patch_check_reason="runtime dist dir not found"
    return 1
  fi

  shopt -s nullglob
  local gateway_files=("$DIST_DIR"/gateway-cli-*.js)
  shopt -u nullglob

  patch_marker_total="${#gateway_files[@]}"
  if (( patch_marker_total < 1 )); then
    patch_check_reason="runtime gateway files not found"
    return 1
  fi

  local file
  for file in "${gateway_files[@]}"; do
    if rg -q 'Embedded run ended with pending tool calls' "$file"; then
      patch_marker_files=$((patch_marker_files + 1))
    fi
  done

  if (( patch_marker_files == patch_marker_total )); then
    patch_marker_complete=1
    patch_check_reason="runtime patch marker coverage complete"
    return 0
  fi

  patch_check_reason="runtime patch marker coverage incomplete"
  return 1
}

resolve_session_signals() {
  local session_id="$1"

  eval_last_assistant_stop="unknown"
  eval_last_assistant_tool_calls="0"
  eval_session_file=""
  eval_session_file_exists=1

  if [[ -z "$session_id" ]]; then
    return
  fi

  eval_session_file="$SESSIONS_DIR/${session_id}.jsonl"
  if [[ ! -f "$eval_session_file" ]]; then
    eval_session_file_exists=0
    return
  fi

  eval_last_assistant_stop="$(jq -r 'select(.type=="message" and .message.role=="assistant") | .message.stopReason // empty' "$eval_session_file" | tail -n 1)"
  eval_last_assistant_tool_calls="$(jq -r 'select(.type=="message" and .message.role=="assistant") | ((.message.content // []) | map(select(.type=="toolCall")) | length)' "$eval_session_file" | tail -n 1)"

  if [[ -z "$eval_last_assistant_stop" ]]; then
    eval_last_assistant_stop="unknown"
  fi
  if [[ -z "$eval_last_assistant_tool_calls" ]]; then
    eval_last_assistant_tool_calls="0"
  fi
}

evaluate_latest_run_json() {
  local latest_json="$1"

  eval_latest_status="$(jq -r '.status // ""' <<<"$latest_json")"
  eval_latest_summary="$(jq -r '.summary // ""' <<<"$latest_json")"
  eval_latest_session_id="$(jq -r '.sessionId // ""' <<<"$latest_json")"
  eval_latest_ts="$(jq -r '.ts // 0' <<<"$latest_json")"
  eval_summary_head="$(printf '%s' "$eval_latest_summary" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-120)"

  resolve_session_signals "$eval_latest_session_id"

  if [[ "$eval_latest_status" != "ok" ]]; then
    eval_result="pass"
    eval_reason="latest run already non-ok"
    eval_exit_code=0
  elif [[ -n "$eval_latest_session_id" && "$eval_session_file_exists" -eq 0 ]]; then
    eval_result="warn"
    eval_reason="ok status but session file missing"
    eval_exit_code=1
  elif printf '%s' "$eval_latest_summary" | rg -q "$SUMMARY_FAIL_REGEX"; then
    eval_result="fail"
    eval_reason="ok status with interim summary marker"
    eval_exit_code=1
  elif [[ "$eval_last_assistant_stop" == "toolUse" || "$eval_last_assistant_stop" == "tool_calls" || "$eval_last_assistant_stop" == "error" ]]; then
    eval_result="fail"
    eval_reason="ok status but assistant stopReason indicates incomplete/error end"
    eval_exit_code=1
  elif [[ "$eval_last_assistant_tool_calls" =~ ^[0-9]+$ ]] && (( eval_last_assistant_tool_calls > 0 )); then
    eval_result="warn"
    eval_reason="assistant last message still contains tool calls; verify run completion"
    eval_exit_code=0
  else
    eval_result="pass"
    eval_reason="no partial-success signal detected"
    eval_exit_code=0
  fi
}

print_single_mode_result() {
  echo "RESULT=$eval_result"
  echo "REASON=$eval_reason"
  echo "JOB_ID=$JOB_ID"
  echo "SESSION_ID_FILTER=$SESSION_ID_FILTER"
  echo "RUN_LOG_FILE=$RUN_LOG_FILE"
  echo "LATEST_TS=$eval_latest_ts"
  echo "LATEST_STATUS=$eval_latest_status"
  echo "LATEST_SESSION_ID=$eval_latest_session_id"
  echo "LATEST_SUMMARY_HEAD=$eval_summary_head"
  echo "LAST_ASSISTANT_STOP_REASON=$eval_last_assistant_stop"
  echo "LAST_ASSISTANT_TOOL_CALLS=$eval_last_assistant_tool_calls"
  echo "PATCH_MARKER_FILES=$patch_marker_files"
  echo "PATCH_MARKER_TOTAL=$patch_marker_total"
  echo "PATCH_MARKER_COMPLETE=$patch_marker_complete"
  if [[ -n "$eval_session_file" ]]; then
    echo "SESSION_FILE=$eval_session_file"
  fi
}

run_single_job_mode() {
  if [[ ! -f "$RUN_LOG_FILE" ]]; then
    echo "RESULT=fail"
    echo "REASON=run log not found"
    echo "JOB_ID=$JOB_ID"
    echo "RUN_LOG_FILE=$RUN_LOG_FILE"
    echo "PATCH_MARKER_FILES=$patch_marker_files"
    echo "PATCH_MARKER_TOTAL=$patch_marker_total"
    echo "PATCH_MARKER_COMPLETE=$patch_marker_complete"
    return 1
  fi

  local latest_json
  if [[ -n "$SESSION_ID_FILTER" ]]; then
    latest_json="$(
      jq -c --arg job "$JOB_ID" --arg sid "$SESSION_ID_FILTER" \
        'select(.jobId==$job and .action=="finished" and .sessionId==$sid)' \
        "$RUN_LOG_FILE" | tail -n 1
    )"
  else
    latest_json="$(jq -c --arg job "$JOB_ID" 'select(.jobId==$job and .action=="finished")' "$RUN_LOG_FILE" | tail -n 1)"
  fi

  if [[ -z "$latest_json" ]]; then
    local reason="no finished entries for job"
    if [[ -n "$SESSION_ID_FILTER" ]]; then
      reason="no finished entries for job/session"
    fi
    echo "RESULT=fail"
    echo "REASON=$reason"
    echo "JOB_ID=$JOB_ID"
    echo "SESSION_ID_FILTER=$SESSION_ID_FILTER"
    echo "RUN_LOG_FILE=$RUN_LOG_FILE"
    echo "PATCH_MARKER_FILES=$patch_marker_files"
    echo "PATCH_MARKER_TOTAL=$patch_marker_total"
    echo "PATCH_MARKER_COMPLETE=$patch_marker_complete"
    return 1
  fi

  evaluate_latest_run_json "$latest_json"
  if ! check_patch_marker_coverage; then
    eval_result="fail"
    eval_reason="$patch_check_reason"
    eval_exit_code=1
  fi

  print_single_mode_result
  return "$eval_exit_code"
}

run_all_jobs_mode() {
  if [[ -n "$SESSION_ID_FILTER" ]]; then
    echo "RESULT=fail"
    echo "REASON=--session-id is not supported with --all-jobs"
    echo "PATCH_MARKER_FILES=$patch_marker_files"
    echo "PATCH_MARKER_TOTAL=$patch_marker_total"
    echo "PATCH_MARKER_COMPLETE=$patch_marker_complete"
    return 2
  fi

  local runs_dir="$OPENCLAW_HOME/cron/runs"
  if [[ ! -d "$runs_dir" ]]; then
    echo "RESULT=fail"
    echo "REASON=run log directory not found"
    echo "RUNS_DIR=$runs_dir"
    echo "PATCH_MARKER_FILES=$patch_marker_files"
    echo "PATCH_MARKER_TOTAL=$patch_marker_total"
    echo "PATCH_MARKER_COMPLETE=$patch_marker_complete"
    return 1
  fi

  if ! check_patch_marker_coverage; then
    echo "RESULT=fail"
    echo "REASON=$patch_check_reason"
    echo "RUNS_DIR=$runs_dir"
    echo "PATCH_MARKER_FILES=$patch_marker_files"
    echo "PATCH_MARKER_TOTAL=$patch_marker_total"
    echo "PATCH_MARKER_COMPLETE=$patch_marker_complete"
    return 1
  fi

  shopt -s nullglob
  local run_files=("$runs_dir"/*.jsonl)
  shopt -u nullglob
  if (( ${#run_files[@]} < 1 )); then
    echo "RESULT=fail"
    echo "REASON=no run log files found"
    echo "RUNS_DIR=$runs_dir"
    echo "PATCH_MARKER_FILES=$patch_marker_files"
    echo "PATCH_MARKER_TOTAL=$patch_marker_total"
    echo "PATCH_MARKER_COMPLETE=$patch_marker_complete"
    return 1
  fi

  local total_jobs=0
  local pass_jobs=0
  local warn_jobs=0
  local fail_jobs=0
  local blocking_jobs=0
  local job_lines=()
  local run_file

  for run_file in "${run_files[@]}"; do
    local latest_json
    latest_json="$(jq -c 'select(.action=="finished")' "$run_file" | tail -n 1)"
    if [[ -z "$latest_json" ]]; then
      continue
    fi

    evaluate_latest_run_json "$latest_json"
    local run_job_id
    run_job_id="$(jq -r '.jobId // ""' <<<"$latest_json")"
    if [[ -z "$run_job_id" ]]; then
      run_job_id="$(basename "$run_file" .jsonl)"
    fi

    total_jobs=$((total_jobs + 1))
    if [[ "$eval_result" == "pass" ]]; then
      pass_jobs=$((pass_jobs + 1))
    elif [[ "$eval_result" == "warn" ]]; then
      warn_jobs=$((warn_jobs + 1))
    else
      fail_jobs=$((fail_jobs + 1))
    fi
    if (( eval_exit_code != 0 )); then
      blocking_jobs=$((blocking_jobs + 1))
    fi

    job_lines+=("JOB_CHECK=${run_job_id}|${eval_result}|${eval_latest_status}|${eval_last_assistant_stop}|${eval_reason}")
  done

  if (( total_jobs < 1 )); then
    echo "RESULT=fail"
    echo "REASON=no finished entries across run logs"
    echo "RUNS_DIR=$runs_dir"
    echo "PATCH_MARKER_FILES=$patch_marker_files"
    echo "PATCH_MARKER_TOTAL=$patch_marker_total"
    echo "PATCH_MARKER_COMPLETE=$patch_marker_complete"
    return 1
  fi

  local result="pass"
  local reason="all jobs passed partial-success checks"
  local exit_code=0
  if (( fail_jobs > 0 )); then
    result="fail"
    reason="${fail_jobs} job(s) failed checks"
    exit_code=1
  elif (( blocking_jobs > 0 )); then
    result="warn"
    reason="${blocking_jobs} job(s) produced blocking warnings"
    exit_code=1
  elif (( warn_jobs > 0 )); then
    result="warn"
    reason="${warn_jobs} job(s) produced non-blocking warnings"
    exit_code=0
  fi

  echo "RESULT=$result"
  echo "REASON=$reason"
  echo "RUNS_DIR=$runs_dir"
  echo "TOTAL_JOBS=$total_jobs"
  echo "PASS_JOBS=$pass_jobs"
  echo "WARN_JOBS=$warn_jobs"
  echo "FAIL_JOBS=$fail_jobs"
  echo "BLOCKING_JOBS=$blocking_jobs"
  echo "PATCH_MARKER_FILES=$patch_marker_files"
  echo "PATCH_MARKER_TOTAL=$patch_marker_total"
  echo "PATCH_MARKER_COMPLETE=$patch_marker_complete"
  local line
  for line in "${job_lines[@]}"; do
    echo "$line"
  done

  return "$exit_code"
}

if (( ALL_JOBS == 1 )); then
  run_all_jobs_mode
  exit $?
fi

run_single_job_mode
exit $?
