#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_OPENCLAW_BIN="${OPENCLAW_BIN:-/opt/homebrew/bin/openclaw}"
DEFAULT_REPLY_VOICE_REPATCH_SCRIPT="${OPENCLAW_REPLY_VOICE_REPATCH_SCRIPT:-$SCRIPT_DIR/repatch-openclaw-feishu-reply-voice.sh}"
DEFAULT_DEDUP_REPATCH_SCRIPT="${OPENCLAW_DEDUP_REPATCH_SCRIPT:-$SCRIPT_DIR/repatch-openclaw-feishu-dedup-hardening.sh}"

mode="dry-run"
signature=""
openclaw_bin="$DEFAULT_OPENCLAW_BIN"
reply_voice_repatch_script="$DEFAULT_REPLY_VOICE_REPATCH_SCRIPT"
dedup_repatch_script="$DEFAULT_DEDUP_REPATCH_SCRIPT"
gateway_health_wait_attempts="${OPENCLAW_GATEWAY_HEALTH_WAIT_ATTEMPTS:-6}"
gateway_health_wait_sleep_sec="${OPENCLAW_GATEWAY_HEALTH_WAIT_SLEEP_SEC:-1}"

show_help() {
  cat <<'EOF'
Usage: openclaw-update-known-bug-fix.sh --signature <id> [options]

Known signatures:
  dns_network
  gateway_1006
  missing_reply_voice_script
  missing_dedup_persistent_export
  didaapi_target_missing

Options:
  --signature <id>               Bug signature id to handle. (required)
  --dry-run                      Classify only; do not execute fix actions. (default)
  --apply                        Execute known fix action when supported.
  --openclaw-bin <path>          Override openclaw binary path.
  --reply-voice-repatch <path>   Override reply-voice repatch script path.
  --dedup-repatch <path>         Override feishu dedup repatch script path.
  -h, --help                     Show this help message.
EOF
}

while (($#)); do
  case "$1" in
    --signature|--class)
      if (($# < 2)); then
        echo "missing value for --signature" >&2
        exit 2
      fi
      signature="$2"
      shift 2
      ;;
    --dry-run)
      mode="dry-run"
      shift
      ;;
    --apply)
      mode="apply"
      shift
      ;;
    --openclaw-bin)
      if (($# < 2)); then
        echo "missing value for --openclaw-bin" >&2
        exit 2
      fi
      openclaw_bin="$2"
      shift 2
      ;;
    --reply-voice-repatch)
      if (($# < 2)); then
        echo "missing value for --reply-voice-repatch" >&2
        exit 2
      fi
      reply_voice_repatch_script="$2"
      shift 2
      ;;
    --dedup-repatch)
      if (($# < 2)); then
        echo "missing value for --dedup-repatch" >&2
        exit 2
      fi
      dedup_repatch_script="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$signature" ]]; then
  echo "--signature is required" >&2
  exit 2
fi

extract_json_block() {
  local key="$1"
  local payload="$2"
  printf '%s\n' "$payload" | sed -n "/\"$key\"[[:space:]]*:[[:space:]]*{/,/^[[:space:]]*}/p"
}

gateway_status_json() {
  "$openclaw_bin" gateway status --json 2>/dev/null || true
}

gateway_status_is_healthy() {
  local payload="$1"
  local runtime_block rpc_block
  runtime_block="$(extract_json_block "runtime" "$payload")"
  rpc_block="$(extract_json_block "rpc" "$payload")"
  [[ "$runtime_block" == *'"status": "running"'* ]] && [[ "$rpc_block" == *'"ok": true'* ]]
}

wait_gateway_healthy() {
  local attempts="${1:-$gateway_health_wait_attempts}"
  local payload
  local i
  for ((i = 1; i <= attempts; i++)); do
    payload="$(gateway_status_json)"
    if gateway_status_is_healthy "$payload"; then
      return 0
    fi
    if (( i < attempts )) && [[ "$gateway_health_wait_sleep_sec" != "0" ]]; then
      sleep "$gateway_health_wait_sleep_sec"
    fi
  done
  return 1
}

case "$signature" in
  dns_network)
    echo "signature=dns_network"
    echo "action=skip-network-recovery"
    echo "result=skip"
    exit 10
    ;;
  didaapi_target_missing)
    echo "signature=didaapi_target_missing"
    echo "action=skip-expected-target-missing"
    echo "result=skip"
    exit 0
    ;;
  gateway_1006)
    echo "signature=gateway_1006"
    if [[ "$mode" == "dry-run" ]]; then
      echo "action=openclaw gateway restart -> install/start fallback -> probe (dry-run)"
      echo "result=pass"
      exit 0
    fi
    "$openclaw_bin" gateway restart
    if ! wait_gateway_healthy "$gateway_health_wait_attempts"; then
      "$openclaw_bin" gateway install --force
      "$openclaw_bin" gateway start >/dev/null 2>&1 || true
    fi
    "$openclaw_bin" gateway probe >/dev/null 2>&1 || true
    echo "action=openclaw gateway restart -> install/start fallback -> probe"
    if wait_gateway_healthy "$gateway_health_wait_attempts"; then
      echo "result=pass"
      exit 0
    fi
    echo "result=fail"
    echo "reason=gateway_not_healthy_after_known_fix"
    exit 1
    ;;
  missing_reply_voice_script)
    echo "signature=missing_reply_voice_script"
    if [[ ! -x "$reply_voice_repatch_script" ]]; then
      echo "action=reply-voice-repatch-missing"
      echo "result=fail"
      exit 1
    fi
    if [[ "$mode" == "dry-run" ]]; then
      echo "action=$reply_voice_repatch_script --apply (dry-run)"
      echo "result=pass"
      exit 0
    fi
    "$reply_voice_repatch_script" --apply
    echo "action=$reply_voice_repatch_script --apply"
    echo "result=pass"
    exit 0
    ;;
  missing_dedup_persistent_export)
    echo "signature=missing_dedup_persistent_export"
    if [[ ! -x "$dedup_repatch_script" ]]; then
      echo "action=dedup-repatch-missing"
      echo "result=fail"
      exit 1
    fi
    if [[ "$mode" == "dry-run" ]]; then
      echo "action=$dedup_repatch_script --apply (dry-run)"
      echo "result=pass"
      exit 0
    fi
    "$dedup_repatch_script" --apply
    echo "action=$dedup_repatch_script --apply"
    echo "result=pass"
    exit 0
    ;;
  *)
    echo "signature=$signature"
    echo "action=unsupported"
    echo "result=unsupported"
    exit 2
    ;;
esac
