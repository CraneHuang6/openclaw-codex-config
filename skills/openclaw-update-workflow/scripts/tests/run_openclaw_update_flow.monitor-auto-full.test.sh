#!/usr/bin/env bash
set -euo pipefail

RUNNER="/Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh"

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

stub_daily="$tmp_dir/daily.sh"
cat >"$stub_daily" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
shift || true

calls_file="${STUB_CALLS_FILE:?}"
report_file="${STUB_REPORT_FILE:?}"
full_count_file="${STUB_FULL_COUNT_FILE:?}"
full_args_file="${STUB_FULL_ARGS_FILE:?}"

printf '%s|%s\n' "$mode" "$*" >> "$calls_file"

case "${mode}" in
  --skip-update)
    behavior="${STUB_MONITOR_BEHAVIOR:-ok_new}"
    case "$behavior" in
      ok_new)
        cat >"$report_file" <<'REPORT'
# OpenClaw Daily Auto Update - test

- before_version: v1.0.0
- latest_version: v1.1.0
REPORT
        ;;
      ok_same)
        cat >"$report_file" <<'REPORT'
# OpenClaw Daily Auto Update - test

- before_version: v1.1.0
- latest_version: v1.1.0
REPORT
        ;;
      ok_unknown)
        cat >"$report_file" <<'REPORT'
# OpenClaw Daily Auto Update - test

- before_version: v1.1.0
- latest_version: unknown
REPORT
        ;;
      fail)
        echo "monitor failed" >&2
        exit 23
        ;;
      *)
        echo "unknown monitor behavior: $behavior" >&2
        exit 97
        ;;
    esac
    echo "REPORT_FILE=$report_file"
    echo "STATUS=ok"
    ;;
  --with-update)
    count="$(cat "$full_count_file" 2>/dev/null || echo 0)"
    count="$((count + 1))"
    printf '%s\n' "$count" > "$full_count_file"
    printf '%s\n' "$*" >> "$full_args_file"
    exit_code="${STUB_FULL_EXIT_CODE:-0}"
    if [[ "$exit_code" =~ ^[0-9]+$ ]] && (( exit_code >= 0 && exit_code <= 255 )); then
      exit "$exit_code"
    fi
    exit 0
    ;;
  *)
    echo "unexpected mode: $mode" >&2
    exit 98
    ;;
esac
STUB
chmod +x "$stub_daily"

run_monitor() {
  local behavior="$1"
  local auto_full="$2"
  local full_exit="$3"

  local calls_file="$tmp_dir/calls.txt"
  local report_file="$tmp_dir/report.md"
  local full_count_file="$tmp_dir/full.count"
  local full_args_file="$tmp_dir/full.args"

  : > "$calls_file"
  : > "$full_count_file"
  : > "$full_args_file"

  set +e
  if [[ "$auto_full" == "__UNSET__" ]]; then
    run_out="$({
      STUB_MONITOR_BEHAVIOR="$behavior" \
      STUB_CALLS_FILE="$calls_file" \
      STUB_REPORT_FILE="$report_file" \
      STUB_FULL_COUNT_FILE="$full_count_file" \
      STUB_FULL_ARGS_FILE="$full_args_file" \
      STUB_FULL_EXIT_CODE="$full_exit" \
      OPENCLAW_SKILL_PROXY_PRECHECK_ENABLED=0 \
      OPENCLAW_SKILL_DAILY_SCRIPT="$stub_daily" \
      env -u OPENCLAW_SKILL_MONITOR_AUTO_FULL_ON_NEW_VERSION \
      bash "$RUNNER" monitor -- --feishu-target test-target
    } 2>&1)"
  else
    run_out="$({
      STUB_MONITOR_BEHAVIOR="$behavior" \
      STUB_CALLS_FILE="$calls_file" \
      STUB_REPORT_FILE="$report_file" \
      STUB_FULL_COUNT_FILE="$full_count_file" \
      STUB_FULL_ARGS_FILE="$full_args_file" \
      STUB_FULL_EXIT_CODE="$full_exit" \
      OPENCLAW_SKILL_PROXY_PRECHECK_ENABLED=0 \
      OPENCLAW_SKILL_DAILY_SCRIPT="$stub_daily" \
      OPENCLAW_SKILL_MONITOR_AUTO_FULL_ON_NEW_VERSION="$auto_full" \
      bash "$RUNNER" monitor -- --feishu-target test-target
    } 2>&1)"
  fi
  run_code=$?
  set -e

  run_calls="$(cat "$calls_file")"
  run_full_count="$(cat "$full_count_file" 2>/dev/null || true)"
  if [[ -z "${run_full_count}" ]]; then
    run_full_count=0
  fi
  run_full_args="$(cat "$full_args_file" 2>/dev/null || true)"
}

scenario_triggers_full_when_new_version_detected() {
  run_monitor "ok_new" "1" "0"
  [[ "$run_code" -eq 0 ]] || fail "expected exit 0, got $run_code"
  [[ "$run_full_count" -eq 1 ]] || fail "expected full to run once, got $run_full_count"
  grep -Fq '[monitor-auto-full] trigger full:' <<<"$run_out" || fail "missing trigger log"
  grep -Fq -- '--feishu-target test-target' <<<"$run_full_args" || fail "extra args were not forwarded to full"
}

scenario_default_skips_full_when_env_unset() {
  run_monitor "ok_new" "__UNSET__" "0"
  [[ "$run_code" -eq 0 ]] || fail "expected exit 0 when env unset, got $run_code"
  [[ "$run_full_count" -eq 0 ]] || fail "expected no full run when env unset, got $run_full_count"
  grep -Fq '[monitor-auto-full] skip auto full: disabled by OPENCLAW_SKILL_MONITOR_AUTO_FULL_ON_NEW_VERSION=0' <<<"$run_out" || fail "missing default-disabled log"
}

scenario_skips_full_when_latest_not_newer() {
  run_monitor "ok_same" "1" "0"
  [[ "$run_code" -eq 0 ]] || fail "expected exit 0 when same version, got $run_code"
  [[ "$run_full_count" -eq 0 ]] || fail "expected no full run when same version, got $run_full_count"
  grep -Fq '[monitor-auto-full] skip auto full: latest_version' <<<"$run_out" || fail "missing same-version skip log"
}

scenario_skips_full_when_latest_unknown() {
  run_monitor "ok_unknown" "1" "0"
  [[ "$run_code" -eq 0 ]] || fail "expected exit 0 when latest unknown, got $run_code"
  [[ "$run_full_count" -eq 0 ]] || fail "expected no full run when latest unknown, got $run_full_count"
  grep -Fq '[monitor-auto-full] skip auto full: latest_version is not stable' <<<"$run_out" || fail "missing unknown-version skip log"
}

scenario_skips_full_when_toggle_disabled() {
  run_monitor "ok_new" "0" "0"
  [[ "$run_code" -eq 0 ]] || fail "expected exit 0 when toggle disabled, got $run_code"
  [[ "$run_full_count" -eq 0 ]] || fail "expected no full run when toggle disabled, got $run_full_count"
  grep -Fq '[monitor-auto-full] skip auto full: disabled by OPENCLAW_SKILL_MONITOR_AUTO_FULL_ON_NEW_VERSION=0' <<<"$run_out" || fail "missing toggle-disabled log"
}

scenario_monitor_failure_short_circuits() {
  run_monitor "fail" "1" "0"
  [[ "$run_code" -eq 23 ]] || fail "expected monitor failure code 23, got $run_code"
  [[ "$run_full_count" -eq 0 ]] || fail "expected no full run when monitor failed, got $run_full_count"
  grep -Fq '[monitor-auto-full] skip auto full: monitor failed (exit=23)' <<<"$run_out" || fail "missing monitor-failed skip log"
}

scenario_full_failure_propagates_exit_code() {
  run_monitor "ok_new" "1" "42"
  [[ "$run_code" -eq 42 ]] || fail "expected full failure code 42, got $run_code"
  [[ "$run_full_count" -eq 1 ]] || fail "expected full run once on full failure, got $run_full_count"
}

scenario_triggers_full_when_new_version_detected
scenario_default_skips_full_when_env_unset
scenario_skips_full_when_latest_not_newer
scenario_skips_full_when_latest_unknown
scenario_skips_full_when_toggle_disabled
scenario_monitor_failure_short_circuits
scenario_full_failure_propagates_exit_code

echo "[PASS] run_openclaw_update_flow monitor auto full tests"
