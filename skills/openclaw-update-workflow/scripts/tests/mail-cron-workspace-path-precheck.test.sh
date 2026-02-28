#!/usr/bin/env bash
set -euo pipefail

SCRIPT="/Users/crane/.codex/skills/openclaw-update-workflow/scripts/mail-cron-workspace-path-precheck.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

run_capture() {
  local out
  set +e
  out="$(bash "$SCRIPT" "$@" 2>&1)"
  local code=$?
  set -e
  printf '%s\n' "$code" > "$TMP_DIR/last.code"
  printf '%s\n' "$out" > "$TMP_DIR/last.out"
}

assert_code() {
  local expected="$1"
  local actual
  actual="$(cat "$TMP_DIR/last.code")"
  [[ "$actual" == "$expected" ]] || fail "expected exit code=$expected, got $actual"
}

assert_out_contains() {
  local needle="$1"
  rg -q --fixed-strings "$needle" "$TMP_DIR/last.out" || fail "missing output: $needle"
}

write_jobs_file() {
  local jobs_file="$1"
  local job_id="$2"
  local message="$3"

  mkdir -p "$(dirname "$jobs_file")"
  jq -n --arg id "$job_id" --arg msg "$message" '
    {
      jobs: [
        {
          id: $id,
          payload: {
            kind: "agentTurn",
            message: $msg
          }
        }
      ]
    }
  ' > "$jobs_file"
}

scenario_missing_constraints_should_fail() {
  local td="$TMP_DIR/missing-constraints"
  local jobs_file="$td/jobs.json"

  write_jobs_file "$jobs_file" "job-fail" "请检查邮箱；临时脚本写到 /tmp/qq_mail_1.scpt。"

  run_capture --jobs-file "$jobs_file" --job-id "job-fail"

  assert_code 1
  assert_out_contains "RESULT=fail"
  assert_out_contains "REASON=constraint violations:"
  assert_out_contains "workspace_tmp_path"
  assert_out_contains "ban_tmp_statement"
  assert_out_contains "osascript_or_heredoc_no_scpt"
}

scenario_all_constraints_should_pass() {
  local td="$TMP_DIR/all-constraints"
  local jobs_file="$td/jobs.json"

  write_jobs_file "$jobs_file" "job-pass" "请检查邮箱并整理。所有临时文件仅写 /Users/crane/.openclaw/workspace/tmp/mail-check；严禁 /tmp /var/tmp /private/tmp；QQ AppleScript 优先 osascript -e/heredoc，不落盘 .scpt。"

  run_capture --jobs-file "$jobs_file" --job-id "job-pass"

  assert_code 0
  assert_out_contains "RESULT=pass"
  assert_out_contains "REASON=message workspace tmp constraints satisfied"
}

scenario_multiline_constraints_should_pass() {
  local td="$TMP_DIR/multiline-constraints"
  local jobs_file="$td/jobs.json"
  local message

  message=$'第一行说明。\n第二行：所有临时文件仅写 /Users/crane/.openclaw/workspace/tmp/mail-check。\n第三行：严禁 /tmp /var/tmp /private/tmp。\n第四行：QQ AppleScript 优先 osascript -e/heredoc，不落盘 .scpt。'
  write_jobs_file "$jobs_file" "job-multiline-pass" "$message"

  run_capture --jobs-file "$jobs_file" --job-id "job-multiline-pass"

  assert_code 0
  assert_out_contains "RESULT=pass"
}

scenario_missing_constraints_should_fail
scenario_all_constraints_should_pass
scenario_multiline_constraints_should_pass

echo "[PASS] mail-cron-workspace-path-precheck tests"
