#!/usr/bin/env bash
set -euo pipefail

SCRIPT="/Users/crane/.codex/skills/openclaw-update-workflow/scripts/cron-partial-report-precheck.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

run_capture() {
  local out
  set +e
  out="$($SCRIPT "$@" 2>&1)"
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

make_dist_empty() {
  local dist_dir="$1"
  mkdir -p "$dist_dir"
}

make_dist_all_patched() {
  local dist_dir="$1"
  mkdir -p "$dist_dir"
  cat > "$dist_dir/gateway-cli-a.js" <<'JS'
const msg = "Embedded run ended with pending tool calls";
JS
  cat > "$dist_dir/gateway-cli-b.js" <<'JS'
const msg = "Embedded run ended with pending tool calls";
JS
}

make_dist_partial_patched() {
  local dist_dir="$1"
  mkdir -p "$dist_dir"
  cat > "$dist_dir/gateway-cli-a.js" <<'JS'
const msg = "Embedded run ended with pending tool calls";
JS
  cat > "$dist_dir/gateway-cli-b.js" <<'JS'
const msg = "no marker";
JS
}

write_session() {
  local sessions_dir="$1"
  local sid="$2"
  local stop_reason="$3"
  local include_tool_call="${4:-0}"

  mkdir -p "$sessions_dir"
  if [[ "$include_tool_call" == "1" ]]; then
    cat > "$sessions_dir/${sid}.jsonl" <<JSON
{"type":"message","message":{"role":"assistant","stopReason":"${stop_reason}","content":[{"type":"toolCall","id":"call_1","name":"search","arguments":"{}"}]}}
JSON
  else
    cat > "$sessions_dir/${sid}.jsonl" <<JSON
{"type":"message","message":{"role":"assistant","stopReason":"${stop_reason}","content":[{"type":"text","text":"done"}]}}
JSON
  fi
}

write_run_log_entry() {
  local run_log="$1"
  local job_id="$2"
  local ts="$3"
  local status="$4"
  local session_id="$5"
  local summary="$6"

  mkdir -p "$(dirname "$run_log")"
  cat > "$run_log" <<JSON
{"ts":${ts},"jobId":"${job_id}","action":"finished","status":"${status}","sessionId":"${session_id}","summary":"${summary}"}
JSON
}

scenario_single_job_pass() {
  local td="$TMP_DIR/single-pass"
  local run_log="$td/runs/job-pass.jsonl"
  local sessions="$td/sessions"
  local dist="$td/dist"

  make_dist_all_patched "$dist"
  write_run_log_entry "$run_log" "job-pass" "1772244303187" "ok" "sid-pass" "final summary"
  write_session "$sessions" "sid-pass" "stop" "0"

  OPENCLAW_CRON_PRECHECK_DIST_DIR="$dist" run_capture --job-id job-pass --run-log "$run_log" --sessions-dir "$sessions"

  assert_code 0
  assert_out_contains "RESULT=pass"
  assert_out_contains "REASON=no partial-success signal detected"
}

scenario_missing_session_warn_and_fail() {
  local td="$TMP_DIR/missing-session"
  local run_log="$td/runs/job-missing.jsonl"
  local sessions="$td/sessions"
  local dist="$td/dist"

  make_dist_all_patched "$dist"
  write_run_log_entry "$run_log" "job-missing" "1772244303187" "ok" "sid-missing" "done"
  mkdir -p "$sessions"

  OPENCLAW_CRON_PRECHECK_DIST_DIR="$dist" run_capture --job-id job-missing --run-log "$run_log" --sessions-dir "$sessions"

  assert_code 1
  assert_out_contains "RESULT=warn"
  assert_out_contains "REASON=ok status but session file missing"
}

scenario_patch_marker_partial_should_fail() {
  local td="$TMP_DIR/marker-partial"
  local run_log="$td/runs/job-marker.jsonl"
  local sessions="$td/sessions"
  local dist="$td/dist"

  make_dist_partial_patched "$dist"
  write_run_log_entry "$run_log" "job-marker" "1772244303187" "ok" "sid-marker" "done"
  write_session "$sessions" "sid-marker" "stop" "0"

  OPENCLAW_CRON_PRECHECK_DIST_DIR="$dist" run_capture --job-id job-marker --run-log "$run_log" --sessions-dir "$sessions"

  assert_code 1
  assert_out_contains "RESULT=fail"
  assert_out_contains "REASON=runtime patch marker coverage incomplete"
}

scenario_all_jobs_detects_bad_job() {
  local td="$TMP_DIR/all-jobs"
  local home="$td/home"
  local runs_dir="$home/cron/runs"
  local sessions="$home/agents/main/sessions"
  local dist="$td/dist"

  make_dist_all_patched "$dist"
  mkdir -p "$runs_dir"

  write_run_log_entry "$runs_dir/job-good.jsonl" "job-good" "1772244303000" "ok" "sid-good" "done"
  write_session "$sessions" "sid-good" "stop" "0"

  write_run_log_entry "$runs_dir/job-bad.jsonl" "job-bad" "1772244303999" "ok" "sid-bad" ""
  write_session "$sessions" "sid-bad" "toolUse" "1"

  OPENCLAW_HOME="$home" OPENCLAW_CRON_PRECHECK_DIST_DIR="$dist" run_capture --all-jobs

  assert_code 1
  assert_out_contains "RESULT=fail"
  assert_out_contains "TOTAL_JOBS=2"
  assert_out_contains "FAIL_JOBS=1"
  assert_out_contains "JOB_CHECK=job-bad|fail|ok|toolUse|ok status but assistant stopReason indicates incomplete/error end"
  assert_out_contains "JOB_CHECK=job-good|pass|ok|stop|no partial-success signal detected"
}

scenario_all_jobs_fail_when_dist_missing() {
  local td="$TMP_DIR/all-jobs-dist-missing"
  local home="$td/home"
  local runs_dir="$home/cron/runs"
  local sessions="$home/agents/main/sessions"
  local dist="$td/dist"

  make_dist_empty "$dist"
  mkdir -p "$runs_dir"

  write_run_log_entry "$runs_dir/job-good.jsonl" "job-good" "1772244303000" "ok" "sid-good" "done"
  write_session "$sessions" "sid-good" "stop" "0"

  OPENCLAW_HOME="$home" OPENCLAW_CRON_PRECHECK_DIST_DIR="$dist" run_capture --all-jobs

  assert_code 1
  assert_out_contains "RESULT=fail"
  assert_out_contains "REASON=runtime gateway files not found"
}

scenario_single_job_pass
scenario_missing_session_warn_and_fail
scenario_patch_marker_partial_should_fail
scenario_all_jobs_detects_bad_job
scenario_all_jobs_fail_when_dist_missing

echo "[PASS] cron-partial-report-precheck tests"
