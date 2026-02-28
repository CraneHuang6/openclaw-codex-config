#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
DAILY_SCRIPT="${OPENCLAW_SKILL_DAILY_SCRIPT:-$SCRIPT_DIR/daily-auto-update-local.sh}"
UNIFIED_PATCH_SCRIPT="${OPENCLAW_SKILL_UNIFIED_PATCH_SCRIPT:-$SCRIPT_DIR/update-openclaw-with-feishu-repatch.sh}"
LAUNCHD_SCRIPT="${OPENCLAW_SKILL_LAUNCHD_SCRIPT:-$SCRIPT_DIR/install-daily-auto-update-launchd.sh}"
VOICE_DOCTOR_SCRIPT="${OPENCLAW_SKILL_VOICE_DOCTOR_SCRIPT:-$SCRIPT_DIR/feishu-voice-doctor.sh}"
FEISHU_NO_REPLY_PRECHECK_SCRIPT="${OPENCLAW_SKILL_FEISHU_NO_REPLY_PRECHECK_SCRIPT:-$SCRIPT_DIR/feishu-no-reply-precheck.sh}"
SELFIE_GEMINI_KEY_PRECHECK_SCRIPT="${OPENCLAW_SKILL_SELFIE_GEMINI_KEY_PRECHECK_SCRIPT:-$SCRIPT_DIR/selfie-gemini-key-precheck.sh}"
CRON_PARTIAL_REPORT_PRECHECK_SCRIPT="${OPENCLAW_SKILL_CRON_PARTIAL_REPORT_PRECHECK_SCRIPT:-$SCRIPT_DIR/cron-partial-report-precheck.sh}"

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
  monitor          Generate monitoring report (skip update + check latest version).
  stable           Run daily maintenance without remote update.
  full             Run real update + local patch chain.
  patch            Reapply unified local patches only.
  launchd-refresh  Refresh launchd daily auto-update job.
  doctor           Run openclaw status/probe/security quick checks.
  voice-doctor     Check/fix Feishu voice default (wakaba + emotion routing).
  feishu-no-reply  Quick precheck for "Feishu message received but no reply".
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

exec_with_extra() {
  local base=("$@")
  if ((${#extra[@]} > 0)); then
    exec "${base[@]}" "${extra[@]}"
  fi
  exec "${base[@]}"
}

case "$mode" in
  -h|--help|help)
    usage
    ;;
  stable)
    require_file "$DAILY_SCRIPT"
    run_proxy_precheck || exit $?
    exec_with_extra bash "$DAILY_SCRIPT" --skip-update
    ;;
  monitor)
    require_file "$DAILY_SCRIPT"
    run_proxy_precheck || exit $?
    export OPENCLAW_DAILY_UPDATE_CHECK_LATEST_ON_SKIP=1
    exec_with_extra bash "$DAILY_SCRIPT" --skip-update
    ;;
  full)
    require_file "$DAILY_SCRIPT"
    run_proxy_precheck || exit $?
    exec_with_extra bash "$DAILY_SCRIPT" --with-update
    ;;
  patch)
    require_file "$UNIFIED_PATCH_SCRIPT"
    exec_with_extra bash "$UNIFIED_PATCH_SCRIPT" --skip-update --no-restart
    ;;
  launchd-refresh)
    require_file "$LAUNCHD_SCRIPT"
    exec_with_extra bash "$LAUNCHD_SCRIPT"
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
    exec_with_extra bash "$VOICE_DOCTOR_SCRIPT"
    ;;
  feishu-no-reply)
    require_file "$FEISHU_NO_REPLY_PRECHECK_SCRIPT"
    exec_with_extra bash "$FEISHU_NO_REPLY_PRECHECK_SCRIPT"
    ;;
  selfie-key-precheck)
    require_file "$SELFIE_GEMINI_KEY_PRECHECK_SCRIPT"
    exec_with_extra bash "$SELFIE_GEMINI_KEY_PRECHECK_SCRIPT"
    ;;
  cron-partial-precheck)
    require_file "$CRON_PARTIAL_REPORT_PRECHECK_SCRIPT"
    exec_with_extra bash "$CRON_PARTIAL_REPORT_PRECHECK_SCRIPT"
    ;;
  *)
    echo "Unknown mode: $mode" >&2
    usage
    exit 2
    ;;
esac
