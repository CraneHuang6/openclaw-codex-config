#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
DAILY_SCRIPT="${OPENCLAW_SKILL_DAILY_SCRIPT:-$OPENCLAW_HOME/scripts/daily-auto-update-local.sh}"
UNIFIED_PATCH_SCRIPT="${OPENCLAW_SKILL_UNIFIED_PATCH_SCRIPT:-$OPENCLAW_HOME/scripts/update-openclaw-with-feishu-repatch.sh}"
LAUNCHD_SCRIPT="${OPENCLAW_SKILL_LAUNCHD_SCRIPT:-$SCRIPT_DIR/install-daily-auto-update-launchd.sh}"
VOICE_DOCTOR_SCRIPT="${OPENCLAW_SKILL_VOICE_DOCTOR_SCRIPT:-$SCRIPT_DIR/feishu-voice-doctor.sh}"
FEISHU_NO_REPLY_PRECHECK_SCRIPT="${OPENCLAW_SKILL_FEISHU_NO_REPLY_PRECHECK_SCRIPT:-$SCRIPT_DIR/feishu-no-reply-precheck.sh}"
FEISHU_SINGLE_CARD_STREAMING_SCRIPT="${OPENCLAW_SKILL_FEISHU_SINGLE_CARD_STREAMING_SCRIPT:-$SCRIPT_DIR/feishu-single-card-streaming.sh}"
FEISHU_SINGLE_CARD_ACCEPTANCE_SCRIPT="${OPENCLAW_SKILL_FEISHU_SINGLE_CARD_ACCEPTANCE_SCRIPT:-$SCRIPT_DIR/feishu-single-card-acceptance.sh}"
SELFIE_GEMINI_KEY_PRECHECK_SCRIPT="${OPENCLAW_SKILL_SELFIE_GEMINI_KEY_PRECHECK_SCRIPT:-$SCRIPT_DIR/selfie-gemini-key-precheck.sh}"
CRON_PARTIAL_REPORT_PRECHECK_SCRIPT="${OPENCLAW_SKILL_CRON_PARTIAL_REPORT_PRECHECK_SCRIPT:-$SCRIPT_DIR/cron-partial-report-precheck.sh}"
REPORT_SUMMARY_SCRIPT="${OPENCLAW_SKILL_REPORT_SUMMARY_SCRIPT:-$SCRIPT_DIR/extract-openclaw-update-report-summary.py}"
FAST_PREFLIGHT_ENABLED="${OPENCLAW_SKILL_FAST_PREFLIGHT_ENABLED:-1}"
FAST_PREFLIGHT_STRICT="${OPENCLAW_SKILL_FAST_PREFLIGHT_STRICT:-1}"
AUTO_COMMIT_SCRIPT="${OPENCLAW_SKILL_AUTO_COMMIT_SCRIPT:-$SCRIPT_DIR/auto_commit_guarded.sh}"
AUTO_COMMIT_ENABLED="${OPENCLAW_SKILL_AUTO_COMMIT_ENABLED:-1}"
GATE_D2_VERDICT="${OPENCLAW_SKILL_GATE_D2_VERDICT:-UNKNOWN}"

# Stabilize automation runtime env: Codex/launchd may not inherit interactive shell proxy/path settings.
OPENCLAW_SKILL_PROXY_ENV_ENABLED="${OPENCLAW_SKILL_PROXY_ENV_ENABLED:-1}"
if [[ "$OPENCLAW_SKILL_PROXY_ENV_ENABLED" == "1" ]]; then
  export PATH="${OPENCLAW_SKILL_PATH:-/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"

  proxy_host="${OPENCLAW_SKILL_HTTP_PROXY_HOST:-192.168.1.2}"
  http_proxy_port="${OPENCLAW_SKILL_HTTP_PROXY_PORT:-7897}"
  socks_proxy_port="${OPENCLAW_SKILL_SOCKS_PROXY_PORT:-7897}"

  default_http_proxy="http://${proxy_host}:${http_proxy_port}"
  default_all_proxy="socks5://${proxy_host}:${socks_proxy_port}"

  : "${HTTP_PROXY:=${OPENCLAW_SKILL_HTTP_PROXY:-$default_http_proxy}}"
  : "${HTTPS_PROXY:=${OPENCLAW_SKILL_HTTPS_PROXY:-$HTTP_PROXY}}"
  : "${ALL_PROXY:=${OPENCLAW_SKILL_ALL_PROXY:-$default_all_proxy}}"
  : "${NO_PROXY:=${OPENCLAW_SKILL_NO_PROXY:-localhost,127.0.0.1,::1,.local}}"

  : "${http_proxy:=$HTTP_PROXY}"
  : "${https_proxy:=$HTTPS_PROXY}"
  : "${all_proxy:=$ALL_PROXY}"
  : "${no_proxy:=$NO_PROXY}"

  export HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
  export http_proxy https_proxy all_proxy no_proxy
fi

run_proxy_precheck() {
  local enabled="${OPENCLAW_SKILL_PROXY_PRECHECK_ENABLED:-1}"
  local url="${OPENCLAW_SKILL_PROXY_PRECHECK_URL:-https://registry.npmjs.org}"
  local timeout="${OPENCLAW_SKILL_PROXY_PRECHECK_TIMEOUT:-5}"
  local attempts="${OPENCLAW_SKILL_PROXY_PRECHECK_ATTEMPTS:-2}"
  local retry_delay="${OPENCLAW_SKILL_PROXY_PRECHECK_RETRY_DELAY:-1}"
  local proxy_url="${HTTP_PROXY:-${http_proxy:-}}"
  local i=0

  if [[ "$enabled" != "1" ]]; then
    return 0
  fi
  if [[ -z "$proxy_url" ]]; then
    return 0
  fi

  if [[ ! "$attempts" =~ ^[0-9]+$ ]] || (( attempts < 1 )); then
    attempts=2
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "[precheck] classify=env reason=curl unavailable" >&2
    return 41
  fi
  if [[ ! "$retry_delay" =~ ^[0-9]+$ ]]; then
    retry_delay=1
  fi

  for ((i = 1; i <= attempts; i++)); do
    if curl --proxy "$proxy_url" -I --max-time "$timeout" "$url" >/dev/null 2>&1; then
      return 0
    fi
    if (( i < attempts )) && (( retry_delay > 0 )); then
      sleep "$retry_delay"
    fi
  done

  echo "[precheck] proxy unreachable: $proxy_url" >&2
  return 12
}

usage() {
  cat <<'EOF'
Usage:
  run_openclaw_update_flow.sh <mode> [-- extra args]

Modes:
  monitor          Run monitor first; auto full only when enabled and latest_version is newer.
  stable           Run daily maintenance without remote update.
  full             Run real update + local patch chain.
  patch            Reapply unified local patches only.
  launchd-refresh  Refresh launchd daily auto-update job.
  doctor           Run openclaw status/probe/security quick checks.
  voice-doctor     Check/fix Feishu voice default (wakaba + emotion routing).
  feishu-no-reply  Quick precheck for "Feishu message received but no reply".
  feishu-single-card  Enforce single-card streaming config for Feishu (apply/verify/rollback).
  feishu-single-card-accept  Validate one marker window: Started + Closed + replies=1.
  selfie-key-precheck  Validate xiaoke-selfie key precedence with forced invalid env key.
  cron-partial-precheck  Detect cron "status=ok but interim/partial output" regressions.
EOF
}

require_file() {
  local f="$1"
  if [[ ! -f "$f" ]]; then
    echo "Missing required file: $f" >&2
    exit 2
  fi
}

is_enabled_flag() {
  local v="$1"
  [[ "$v" == "1" || "$v" == "true" || "$v" == "yes" || "$v" == "on" ]]
}

run_fast_preflight() {
  local strict="$1"
  local task_dir
  task_dir="$(mktemp -d -t openclaw-preflight.XXXXXX)"

  local proxy_file="$task_dir/proxy"
  local deps_file="$task_dir/deps"
  local scripts_file="$task_dir/scripts"

  (
    if run_proxy_precheck; then
      echo "PASS proxy precheck" > "$proxy_file"
      exit 0
    else
      code=$?
      echo "FAIL proxy precheck exit=$code" > "$proxy_file"
      exit "$code"
    fi
  ) &
  local proxy_pid=$!

  (
    local missing=()
    command -v bash >/dev/null 2>&1 || missing+=("bash")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    if ((${#missing[@]} == 0)); then
      echo "PASS dependencies available" > "$deps_file"
      exit 0
    fi
    echo "FAIL dependencies missing: ${missing[*]}" > "$deps_file"
    exit 41
  ) &
  local deps_pid=$!

  (
    local required=(
      "$DAILY_SCRIPT"
      "$UNIFIED_PATCH_SCRIPT"
      "$REPORT_SUMMARY_SCRIPT"
    )
    local missing=()
    local f
    for f in "${required[@]}"; do
      if [[ ! -f "$f" ]]; then
        missing+=("$f")
      fi
    done
    if ((${#missing[@]} == 0)); then
      echo "PASS required scripts present" > "$scripts_file"
      exit 0
    fi
    echo "FAIL required scripts missing: ${missing[*]}" > "$scripts_file"
    exit 42
  ) &
  local scripts_pid=$!

  local proxy_code=0
  local deps_code=0
  local scripts_code=0

  wait "$proxy_pid" || proxy_code=$?
  wait "$deps_pid" || deps_code=$?
  wait "$scripts_pid" || scripts_code=$?

  local proxy_msg deps_msg scripts_msg
  proxy_msg="$(cat "$proxy_file" 2>/dev/null || echo "FAIL proxy precheck unknown")"
  deps_msg="$(cat "$deps_file" 2>/dev/null || echo "FAIL dependencies unknown")"
  scripts_msg="$(cat "$scripts_file" 2>/dev/null || echo "FAIL scripts unknown")"

  rm -rf "$task_dir" >/dev/null 2>&1 || true

  echo "[fast-preflight] $proxy_msg"
  echo "[fast-preflight] $deps_msg"
  echo "[fast-preflight] $scripts_msg"

  if (( proxy_code != 0 )); then
    echo "[fast-preflight] classify=infra reason=proxy precheck failed" >&2
    return "$proxy_code"
  fi
  if (( deps_code != 0 )); then
    echo "[fast-preflight] classify=env reason=dependencies unavailable" >&2
    return "$deps_code"
  fi
  if (( scripts_code != 0 )); then
    echo "[fast-preflight] classify=env reason=required scripts missing" >&2
    return "$scripts_code"
  fi

  echo "[fast-preflight] PASS"
  return 0
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

mode="$1"
shift || true

extra=()
if [[ $# -gt 0 ]]; then
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  extra=("$@")
fi

run_with_extra() {
  local base=("$@")
  if ((${#extra[@]} > 0)); then
    "${base[@]}" "${extra[@]}"
    return $?
  fi
  "${base[@]}"
  return $?
}

run_with_extra_capture() {
  local __out_var="$1"
  shift

  local tmp_out
  local cmd=("$@")
  local code=0
  local errexit_was_set=0
  if [[ "$-" == *e* ]]; then
    errexit_was_set=1
  fi
  tmp_out="$(mktemp -t openclaw-monitor.XXXXXX)"

  set +e
  if ((${#extra[@]} > 0)); then
    "${cmd[@]}" "${extra[@]}" 2>&1 | tee "$tmp_out"
    code=${PIPESTATUS[0]}
  else
    "${cmd[@]}" 2>&1 | tee "$tmp_out"
    code=${PIPESTATUS[0]}
  fi
  if (( errexit_was_set == 1 )); then
    set -e
  else
    set +e
  fi

  printf -v "$__out_var" '%s' "$(cat "$tmp_out")"
  rm -f "$tmp_out" >/dev/null 2>&1 || true
  return "$code"
}

extract_report_file_from_output() {
  local output="$1"
  local line
  local report=""
  while IFS= read -r line; do
    case "$line" in
      REPORT_FILE=*)
        report="${line#REPORT_FILE=}"
        ;;
    esac
  done <<< "$output"
  report="${report//$'\r'/}"
  printf '%s' "$report"
}

is_stable_version_tag() {
  local tag="$1"
  [[ "$tag" =~ ^v?[0-9]+([.][0-9]+)*$ ]]
}

version_gt() {
  local latest="$1"
  local current="$2"
  python3 - "$latest" "$current" <<'PY'
import re
import sys

latest = sys.argv[1].strip()
current = sys.argv[2].strip()

def parse(version: str):
    if version.startswith("v"):
        version = version[1:]
    nums = [int(x) for x in re.findall(r"\d+", version)]
    return tuple(nums)

if parse(latest) > parse(current):
    raise SystemExit(0)
raise SystemExit(1)
PY
}

load_report_versions() {
  local report_file="$1"
  local parsed line key value
  local before=""
  local latest=""

  if [[ ! -f "$REPORT_SUMMARY_SCRIPT" ]]; then
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  if ! parsed="$(python3 "$REPORT_SUMMARY_SCRIPT" --report "$report_file" --format kv --field before_version --field latest_version 2>/dev/null)"; then
    return 1
  fi

  while IFS= read -r line; do
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      before_version)
        before="$value"
        ;;
      latest_version)
        latest="$value"
        ;;
    esac
  done <<< "$parsed"

  if [[ -z "$before" || -z "$latest" ]]; then
    return 1
  fi

  MONITOR_BEFORE_VERSION="$before"
  MONITOR_LATEST_VERSION="$latest"
  return 0
}

run_monitor_then_optional_full() {
  local monitor_auto_full
  local monitor_output=""
  local monitor_code=0
  local report_file=""
  local before_version=""
  local latest_version=""

  monitor_auto_full="${OPENCLAW_SKILL_MONITOR_AUTO_FULL_ON_NEW_VERSION:-0}"

  if is_enabled_flag "$FAST_PREFLIGHT_ENABLED"; then
    run_fast_preflight "$FAST_PREFLIGHT_STRICT" || return $?
  else
    require_file "$DAILY_SCRIPT"
    run_proxy_precheck || return $?
  fi
  export OPENCLAW_DAILY_UPDATE_CHECK_LATEST_ON_SKIP=1

  set +e
  run_with_extra_capture monitor_output bash "$DAILY_SCRIPT" --skip-update
  monitor_code=$?
  set -e

  if (( monitor_code != 0 )); then
    echo "[monitor-auto-full] skip auto full: monitor failed (exit=${monitor_code})" >&2
    return "$monitor_code"
  fi

  if [[ "$monitor_auto_full" == "0" ]]; then
    echo "[monitor-auto-full] skip auto full: disabled by OPENCLAW_SKILL_MONITOR_AUTO_FULL_ON_NEW_VERSION=0"
    return 0
  fi

  report_file="$(extract_report_file_from_output "$monitor_output")"
  if [[ -z "$report_file" ]]; then
    echo "[monitor-auto-full] skip auto full: REPORT_FILE not found in monitor output"
    return 0
  fi
  if [[ ! -f "$report_file" ]]; then
    echo "[monitor-auto-full] skip auto full: report file missing: $report_file"
    return 0
  fi

  if ! load_report_versions "$report_file"; then
    echo "[monitor-auto-full] skip auto full: failed to parse before/latest version from report"
    return 0
  fi
  before_version="$MONITOR_BEFORE_VERSION"
  latest_version="$MONITOR_LATEST_VERSION"

  if ! is_stable_version_tag "$before_version"; then
    echo "[monitor-auto-full] skip auto full: before_version is not stable: $before_version"
    return 0
  fi
  if ! is_stable_version_tag "$latest_version"; then
    echo "[monitor-auto-full] skip auto full: latest_version is not stable: $latest_version"
    return 0
  fi

  if version_gt "$latest_version" "$before_version"; then
    echo "[monitor-auto-full] trigger full: latest_version ($latest_version) > before_version ($before_version)"
    run_proxy_precheck || return $?
    run_with_extra bash "$DAILY_SCRIPT" --with-update
    return $?
  fi

  echo "[monitor-auto-full] skip auto full: latest_version ($latest_version) is not newer than before_version ($before_version)"
  return 0
}

is_auto_commit_mode() {
  local m="$1"
  [[ "$m" == "monitor" || "$m" == "stable" || "$m" == "full" || "$m" == "patch" ]]
}

run_auto_commit_if_needed() {
  local completed_mode="$1"
  local gate_verdict_upper=""

  if [[ -z "$completed_mode" ]]; then
    return 0
  fi
  if ! is_auto_commit_mode "$completed_mode"; then
    return 0
  fi

  if ! is_enabled_flag "$AUTO_COMMIT_ENABLED"; then
    echo "AUTO_COMMIT_RESULT=skipped"
    echo "AUTO_COMMIT_REASON=disabled"
    echo "AUTO_COMMIT_HASH="
    echo "AUTO_COMMIT_FILES="
    return 0
  fi

  gate_verdict_upper="$(printf '%s' "$GATE_D2_VERDICT" | tr '[:lower:]' '[:upper:]')"
  if [[ "$gate_verdict_upper" != "PASS" ]]; then
    echo "AUTO_COMMIT_RESULT=skipped"
    echo "AUTO_COMMIT_REASON=gate_d2_not_pass"
    echo "AUTO_COMMIT_HASH="
    echo "AUTO_COMMIT_FILES="
    return 0
  fi

  if [[ ! -x "$AUTO_COMMIT_SCRIPT" ]]; then
    echo "AUTO_COMMIT_RESULT=skipped"
    echo "AUTO_COMMIT_REASON=auto_commit_script_missing"
    echo "AUTO_COMMIT_HASH="
    echo "AUTO_COMMIT_FILES="
    return 0
  fi

  local commit_output=""
  local commit_code=0
  set +e
  commit_output="$(
    OPENCLAW_SKILL_AUTO_COMMIT_MODE="$completed_mode" \
    "$AUTO_COMMIT_SCRIPT" 2>&1
  )"
  commit_code=$?
  set -e

  if [[ -n "$commit_output" ]]; then
    echo "$commit_output"
  fi

  if (( commit_code != 0 )); then
    echo "[auto-commit] warning: guard script failed (exit=${commit_code})" >&2
  fi
  return 0
}

run_status=0
completed_mode=""
case "$mode" in
  -h|--help|help)
    usage
    exit 0
    ;;
  stable)
    completed_mode="stable"
    if is_enabled_flag "$FAST_PREFLIGHT_ENABLED"; then
      run_fast_preflight "$FAST_PREFLIGHT_STRICT" || exit $?
    else
      require_file "$DAILY_SCRIPT"
      run_proxy_precheck || exit $?
    fi
    run_with_extra bash "$DAILY_SCRIPT" --skip-update || run_status=$?
    ;;
  monitor)
    completed_mode="monitor"
    run_monitor_then_optional_full || run_status=$?
    ;;
  full)
    completed_mode="full"
    if is_enabled_flag "$FAST_PREFLIGHT_ENABLED"; then
      run_fast_preflight "$FAST_PREFLIGHT_STRICT" || exit $?
    else
      require_file "$DAILY_SCRIPT"
      run_proxy_precheck || exit $?
    fi
    run_with_extra bash "$DAILY_SCRIPT" --with-update || run_status=$?
    ;;
  patch)
    completed_mode="patch"
    require_file "$UNIFIED_PATCH_SCRIPT"
    run_with_extra bash "$UNIFIED_PATCH_SCRIPT" --skip-update --no-restart || run_status=$?
    ;;
  launchd-refresh)
    require_file "$LAUNCHD_SCRIPT"
    run_with_extra bash "$LAUNCHD_SCRIPT" || run_status=$?
    ;;
  doctor)
    if ! command -v openclaw >/dev/null 2>&1; then
      echo "openclaw command not found in PATH" >&2
      exit 2
    fi
    openclaw status --deep
    openclaw gateway probe
    openclaw security audit --deep
    ;;
  voice-doctor)
    require_file "$VOICE_DOCTOR_SCRIPT"
    run_with_extra bash "$VOICE_DOCTOR_SCRIPT" || run_status=$?
    ;;
  feishu-no-reply)
    require_file "$FEISHU_NO_REPLY_PRECHECK_SCRIPT"
    run_with_extra bash "$FEISHU_NO_REPLY_PRECHECK_SCRIPT" || run_status=$?
    ;;
  feishu-single-card)
    require_file "$FEISHU_SINGLE_CARD_STREAMING_SCRIPT"
    run_with_extra bash "$FEISHU_SINGLE_CARD_STREAMING_SCRIPT" || run_status=$?
    ;;
  feishu-single-card-accept)
    require_file "$FEISHU_SINGLE_CARD_ACCEPTANCE_SCRIPT"
    run_with_extra bash "$FEISHU_SINGLE_CARD_ACCEPTANCE_SCRIPT" || run_status=$?
    ;;
  selfie-key-precheck)
    require_file "$SELFIE_GEMINI_KEY_PRECHECK_SCRIPT"
    run_with_extra bash "$SELFIE_GEMINI_KEY_PRECHECK_SCRIPT" || run_status=$?
    ;;
  cron-partial-precheck)
    require_file "$CRON_PARTIAL_REPORT_PRECHECK_SCRIPT"
    run_with_extra bash "$CRON_PARTIAL_REPORT_PRECHECK_SCRIPT" || run_status=$?
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    usage
    exit 2
    ;;
esac

if (( run_status == 0 )); then
  run_auto_commit_if_needed "$completed_mode"
fi

exit "$run_status"
