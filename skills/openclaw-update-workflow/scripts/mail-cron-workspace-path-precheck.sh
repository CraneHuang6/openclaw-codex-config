#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
JOB_ID="326b827c-02be-4707-bea2-fde41e4149ec"
JOBS_FILE="$OPENCLAW_HOME/cron/jobs.json"
JOBS_FILE_EXPLICIT=0

usage() {
  cat <<'USAGE'
Usage: mail-cron-workspace-path-precheck.sh [--openclaw-home <path>] [--jobs-file <path>] [--job-id <id>]

Checks whether the target cron job payload.message satisfies all workspace tmp constraints.
Default values:
  OPENCLAW_HOME: $HOME/.openclaw
  jobs file: $OPENCLAW_HOME/cron/jobs.json
  job id: 326b827c-02be-4707-bea2-fde41e4149ec
USAGE
}

print_result() {
  local result="$1"
  local reason="$2"

  echo "RESULT=$result"
  echo "REASON=$reason"
  echo "JOB_ID=$JOB_ID"
  echo "JOBS_FILE=$JOBS_FILE"
}

join_csv() {
  local first=1
  local item
  for item in "$@"; do
    if [[ "$first" -eq 1 ]]; then
      printf '%s' "$item"
      first=0
    else
      printf ',%s' "$item"
    fi
  done
}

while (($#)); do
  case "$1" in
    --openclaw-home)
      if (($# < 2)); then
        print_result "fail" "missing value for --openclaw-home"
        exit 2
      fi
      OPENCLAW_HOME="$2"
      if [[ "$JOBS_FILE_EXPLICIT" -eq 0 ]]; then
        JOBS_FILE="$OPENCLAW_HOME/cron/jobs.json"
      fi
      shift 2
      ;;
    --jobs-file)
      if (($# < 2)); then
        print_result "fail" "missing value for --jobs-file"
        exit 2
      fi
      JOBS_FILE="$2"
      JOBS_FILE_EXPLICIT=1
      shift 2
      ;;
    --job-id)
      if (($# < 2)); then
        print_result "fail" "missing value for --job-id"
        exit 2
      fi
      JOB_ID="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      print_result "fail" "unknown option: $1"
      exit 2
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  print_result "fail" "jq is required"
  exit 2
fi

if [[ ! -f "$JOBS_FILE" ]]; then
  print_result "fail" "jobs file not found"
  exit 1
fi

if [[ ! -r "$JOBS_FILE" ]]; then
  print_result "fail" "jobs file is not readable"
  exit 1
fi

job_count="$(jq -r --arg job "$JOB_ID" '[.jobs[]? | select(.id==$job)] | length' "$JOBS_FILE" 2>/dev/null || echo "")"
if [[ -z "$job_count" ]]; then
  print_result "fail" "jobs file is not valid JSON"
  exit 1
fi

if [[ "$job_count" == "0" ]]; then
  print_result "fail" "job id not found"
  exit 1
fi

message="$(jq -r --arg job "$JOB_ID" '[.jobs[]? | select(.id==$job) | .payload.message // empty][0] // empty' "$JOBS_FILE" 2>/dev/null || echo "")"
if [[ -z "$message" ]]; then
  print_result "fail" "payload.message missing or empty"
  exit 1
fi

has_workspace_tmp=0
has_tmp_ban_statement=0
has_osascript_or_heredoc_no_scpt=0

expected_tmp_dir="$OPENCLAW_HOME/workspace/tmp/mail-check"
if [[ "$message" == *"$expected_tmp_dir"* ]]; then
  has_workspace_tmp=1
fi

has_tmp_paths=1
for path in "/tmp" "/var/tmp" "/private/tmp"; do
  if [[ "$message" != *"$path"* ]]; then
    has_tmp_paths=0
    break
  fi
done

has_tmp_ban_keyword=0
if [[ "$message" == *"严禁"* || "$message" == *"禁止"* ]]; then
  has_tmp_ban_keyword=1
fi

if (( has_tmp_paths == 1 && has_tmp_ban_keyword == 1 )); then
  has_tmp_ban_statement=1
fi

if grep -Eiq 'osascript[[:space:]]+-e|heredoc' <<< "$message"; then
  if grep -Eiq '不落盘[[:space:]]*\.scpt|\.scpt.*(不落盘|禁止落盘|不写入|不落地)' <<< "$message"; then
    has_osascript_or_heredoc_no_scpt=1
  fi
fi

violations=()
if [[ "$has_workspace_tmp" -ne 1 ]]; then
  violations+=("workspace_tmp_path")
fi
if [[ "$has_tmp_ban_statement" -ne 1 ]]; then
  violations+=("ban_tmp_statement")
fi
if [[ "$has_osascript_or_heredoc_no_scpt" -ne 1 ]]; then
  violations+=("osascript_or_heredoc_no_scpt")
fi

if ((${#violations[@]} > 0)); then
  reason="constraint violations: $(join_csv "${violations[@]}")"
  print_result "fail" "$reason"
  exit 1
fi

print_result "pass" "message workspace tmp constraints satisfied"
exit 0
