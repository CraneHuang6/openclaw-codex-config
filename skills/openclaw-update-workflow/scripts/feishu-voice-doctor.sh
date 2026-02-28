#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
OPENCLAW_VOICE_CONFIG_KEY="skills.entries.xiaoke-voice-mode.env.OPENCLAW_TTS_VOICE_ID"
OPENCLAW_API_MODE_CONFIG_KEY="skills.entries.xiaoke-voice-mode.env.OPENCLAW_TTS_API_MODE"
OPENCLAW_ALLOW_LEGACY_FALLBACK_CONFIG_KEY="skills.entries.xiaoke-voice-mode.env.OPENCLAW_TTS_ALLOW_LEGACY_FALLBACK"
OPENCLAW_LEGACY_API_URL_CONFIG_KEY="skills.entries.xiaoke-voice-mode.env.OPENCLAW_TTS_LEGACY_API_URL"
OPENCLAW_GATEWAY_TIMEOUT_CONFIG_KEY="skills.entries.xiaoke-voice-mode.env.OPENCLAW_TTS_GATEWAY_MAX_TIME"
OPENCLAW_GATEWAY_DYNAMIC_TIMEOUT_CONFIG_KEY="skills.entries.xiaoke-voice-mode.env.OPENCLAW_TTS_GATEWAY_DYNAMIC_TIMEOUT"
OPENCLAW_MAX_CHARS_CONFIG_KEY="skills.entries.xiaoke-voice-mode.env.OPENCLAW_TTS_MAX_CHARS"
OPENCLAW_SELF_HEAL_CONFIG_KEY="skills.entries.xiaoke-voice-mode.env.OPENCLAW_TTS_SELF_HEAL_ON_TIMEOUT"
OPENCLAW_RETRY_ON_FAILURE_CONFIG_KEY="skills.entries.xiaoke-voice-mode.env.OPENCLAW_TTS_GATEWAY_RETRY_ON_FAILURE"
OPENCLAW_RETRY_MAX_CHARS_CONFIG_KEY="skills.entries.xiaoke-voice-mode.env.OPENCLAW_TTS_GATEWAY_RETRY_MAX_CHARS"
DEFAULT_LEGACY_API_URL="${OPENCLAW_TTS_DEFAULT_LEGACY_API_URL:-http://127.0.0.1:9880/tts}"

DEFAULT_TTS_PROJECT_ROOT="$HOME/Mac Projects/GPT-SoVITS"
TTS_PROJECT_ROOT="${OPENCLAW_TTS_PROJECT_ROOT:-$DEFAULT_TTS_PROJECT_ROOT}"
TTS_VOICES_FILE="${OPENCLAW_TTS_VOICES_FILE:-$TTS_PROJECT_ROOT/tools/opclaw_tts_service/voices.local.yaml}"
XIAOKE_TTS_SCRIPT="${OPENCLAW_XIAOKE_TTS_SCRIPT:-$OPENCLAW_HOME/workspace/skills/xiaoke-voice-mode/scripts/generate_tts_media.sh}"

TTS_LAUNCHD_LABEL="${OPENCLAW_TTS_LAUNCHD_LABEL:-com.openclaw.gptsovits.tts}"
TTS_AUDIT_LOG="${OPENCLAW_TTS_VOICE_AUDIT_LOG:-/tmp/opclaw_tts_voice_selection.log}"

apply_fix=0
restart_services=1
tail_lines=20

usage() {
  cat <<'EOF'
Usage:
  feishu-voice-doctor.sh [--apply] [--no-restart] [--tail <n>]

Defaults:
  - Check-only mode (no file/service changes)
  - Target voice: wakaba_mutsumi
  - Enforce emotion_routing.enabled=false in opclaw_tts_service voices file

Options:
  --apply              Apply fixes:
                       1) openclaw config OPENCLAW_TTS_VOICE_ID=wakaba_mutsumi
                       2) openclaw config OPENCLAW_TTS_API_MODE=auto
                       3) openclaw config OPENCLAW_TTS_ALLOW_LEGACY_FALLBACK=1
                       4) openclaw config OPENCLAW_TTS_LEGACY_API_URL=http://127.0.0.1:9880/tts
                       5) openclaw config OPENCLAW_TTS_GATEWAY_MAX_TIME=45
                       6) openclaw config OPENCLAW_TTS_GATEWAY_DYNAMIC_TIMEOUT=1
                       7) openclaw config OPENCLAW_TTS_MAX_CHARS=120
                       8) openclaw config OPENCLAW_TTS_SELF_HEAL_ON_TIMEOUT=1
                       9) openclaw config OPENCLAW_TTS_GATEWAY_RETRY_ON_FAILURE=1
                      10) openclaw config OPENCLAW_TTS_GATEWAY_RETRY_MAX_CHARS=80
                      11) voices.local.yaml emotion_routing.enabled=false
                      12) restart TTS launchd service + openclaw gateway
  --no-restart         Skip service restart in --apply mode.
  --tail <n>           Tail lines for /tmp/opclaw_tts_voice_selection.log (default: 20).
  -h, --help           Show this help message.
EOF
}

while (($#)); do
  case "$1" in
    --apply)
      apply_fix=1
      shift
      ;;
    --no-restart)
      restart_services=0
      shift
      ;;
    --tail)
      if (($# < 2)); then
        echo "missing value for --tail" >&2
        exit 2
      fi
      tail_lines="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

get_openclaw_voice_id() {
  if ! command -v openclaw >/dev/null 2>&1; then
    printf '<openclaw-not-found>'
    return 0
  fi
  local v
  v="$(openclaw config get "$OPENCLAW_VOICE_CONFIG_KEY" 2>/dev/null || true)"
  v="$(trim "$v")"
  if [[ -z "$v" ]]; then
    printf '<missing>'
  else
    printf '%s' "$v"
  fi
}

get_openclaw_api_mode() {
  if ! command -v openclaw >/dev/null 2>&1; then
    printf '<openclaw-not-found>'
    return 0
  fi
  local v
  v="$(openclaw config get "$OPENCLAW_API_MODE_CONFIG_KEY" 2>/dev/null || true)"
  v="$(trim "$v")"
  if [[ -z "$v" ]]; then
    printf '<missing>'
  else
    printf '%s' "$v"
  fi
}

get_openclaw_allow_legacy_fallback() {
  if ! command -v openclaw >/dev/null 2>&1; then
    printf '<openclaw-not-found>'
    return 0
  fi
  local v
  v="$(openclaw config get "$OPENCLAW_ALLOW_LEGACY_FALLBACK_CONFIG_KEY" 2>/dev/null || true)"
  v="$(trim "$v")"
  if [[ -z "$v" ]]; then
    printf '<missing>'
  else
    printf '%s' "$v"
  fi
}

get_openclaw_legacy_api_url() {
  if ! command -v openclaw >/dev/null 2>&1; then
    printf '<openclaw-not-found>'
    return 0
  fi
  local v
  v="$(openclaw config get "$OPENCLAW_LEGACY_API_URL_CONFIG_KEY" 2>/dev/null || true)"
  v="$(trim "$v")"
  if [[ -z "$v" ]]; then
    printf '<missing>'
  else
    printf '%s' "$v"
  fi
}

yaml_emotion_value() {
  local key="$1"
  if [[ ! -f "$TTS_VOICES_FILE" ]]; then
    printf '<voices-file-missing>'
    return 0
  fi
  local out
  out="$(awk -v key="$key" '
    /^emotion_routing:[[:space:]]*$/ { in_section=1; next }
    in_section && /^[^[:space:]]/ { in_section=0 }
    in_section {
      pattern = "^[[:space:]]*" key ":[[:space:]]*"
      if ($0 ~ pattern) {
        value = $0
        sub(pattern, "", value)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        gsub(/^"|"$/, "", value)
        print value
        exit
      }
    }
  ' "$TTS_VOICES_FILE")"
  out="$(trim "$out")"
  if [[ -z "$out" ]]; then
    printf '<missing>'
  else
    printf '%s' "$out"
  fi
}

set_emotion_routing_disabled() {
  if [[ ! -f "$TTS_VOICES_FILE" ]]; then
    echo "voices file not found: $TTS_VOICES_FILE" >&2
    return 1
  fi
  local tmp backup
  tmp="$(mktemp "${TTS_VOICES_FILE}.tmp.XXXXXX")"
  awk '
    BEGIN { in_section=0; updated=0 }
    /^emotion_routing:[[:space:]]*$/ {
      in_section=1
      print
      next
    }
    in_section && /^[^[:space:]]/ {
      in_section=0
    }
    in_section && /^[[:space:]]*enabled:[[:space:]]*/ {
      sub(/enabled:[[:space:]]*.*/, "enabled: false")
      updated=1
    }
    {
      print
    }
    END {
      if (updated == 0) {
        exit 4
      }
    }
  ' "$TTS_VOICES_FILE" > "$tmp" || {
    rm -f "$tmp"
    return 1
  }

  if cmp -s "$TTS_VOICES_FILE" "$tmp"; then
    rm -f "$tmp"
    echo "emotion_routing.enabled already false"
    return 0
  fi

  backup="${TTS_VOICES_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$TTS_VOICES_FILE" "$backup"
  mv "$tmp" "$TTS_VOICES_FILE"
  echo "emotion_routing.enabled forced to false (backup: $backup)"
}

get_openclaw_gateway_timeout() {
  if ! command -v openclaw >/dev/null 2>&1; then
    printf '<openclaw-not-found>'
    return 0
  fi
  local v
  v="$(openclaw config get "$OPENCLAW_GATEWAY_TIMEOUT_CONFIG_KEY" 2>/dev/null || true)"
  v="$(trim "$v")"
  if [[ -z "$v" ]]; then
    printf '<missing>'
  else
    printf '%s' "$v"
  fi
}

get_openclaw_gateway_dynamic_timeout() {
  if ! command -v openclaw >/dev/null 2>&1; then
    printf '<openclaw-not-found>'
    return 0
  fi
  local v
  v="$(openclaw config get "$OPENCLAW_GATEWAY_DYNAMIC_TIMEOUT_CONFIG_KEY" 2>/dev/null || true)"
  v="$(trim "$v")"
  if [[ -z "$v" ]]; then
    printf '<missing>'
  else
    printf '%s' "$v"
  fi
}

get_openclaw_tts_max_chars() {
  if ! command -v openclaw >/dev/null 2>&1; then
    printf '<openclaw-not-found>'
    return 0
  fi
  local v
  v="$(openclaw config get "$OPENCLAW_MAX_CHARS_CONFIG_KEY" 2>/dev/null || true)"
  v="$(trim "$v")"
  if [[ -z "$v" ]]; then
    printf '<missing>'
  else
    printf '%s' "$v"
  fi
}

get_openclaw_tts_self_heal_on_timeout() {
  if ! command -v openclaw >/dev/null 2>&1; then
    printf '<openclaw-not-found>'
    return 0
  fi
  local v
  v="$(openclaw config get "$OPENCLAW_SELF_HEAL_CONFIG_KEY" 2>/dev/null || true)"
  v="$(trim "$v")"
  if [[ -z "$v" ]]; then
    printf '<missing>'
  else
    printf '%s' "$v"
  fi
}

get_openclaw_tts_retry_on_failure() {
  if ! command -v openclaw >/dev/null 2>&1; then
    printf '<openclaw-not-found>'
    return 0
  fi
  local v
  v="$(openclaw config get "$OPENCLAW_RETRY_ON_FAILURE_CONFIG_KEY" 2>/dev/null || true)"
  v="$(trim "$v")"
  if [[ -z "$v" ]]; then
    printf '<missing>'
  else
    printf '%s' "$v"
  fi
}

get_openclaw_tts_retry_max_chars() {
  if ! command -v openclaw >/dev/null 2>&1; then
    printf '<openclaw-not-found>'
    return 0
  fi
  local v
  v="$(openclaw config get "$OPENCLAW_RETRY_MAX_CHARS_CONFIG_KEY" 2>/dev/null || true)"
  v="$(trim "$v")"
  if [[ -z "$v" ]]; then
    printf '<missing>'
  else
    printf '%s' "$v"
  fi
}

get_media_output_mode() {
  if [[ ! -f "$XIAOKE_TTS_SCRIPT" ]]; then
    printf '<script-missing>'
    return 0
  fi
  if grep -Fq 'echo "MEDIA:$FINAL_PATH"' "$XIAOKE_TTS_SCRIPT"; then
    printf 'absolute'
    return 0
  fi
  if grep -E -q 'MEDIA:\./workspace|REL_PATH' "$XIAOKE_TTS_SCRIPT"; then
    printf 'relative'
    return 0
  fi
  printf '<unknown>'
}

restart_tts_service() {
  local uid
  uid="$(id -u)"
  if launchctl list | grep -Fq "$TTS_LAUNCHD_LABEL"; then
    launchctl kickstart -k "gui/$uid/$TTS_LAUNCHD_LABEL"
    echo "restarted launchd service: $TTS_LAUNCHD_LABEL"
  else
    echo "launchd service not loaded: $TTS_LAUNCHD_LABEL"
  fi
}

restart_gateway_service() {
  if command -v openclaw >/dev/null 2>&1; then
    openclaw gateway restart >/dev/null
    echo "restarted openclaw gateway"
  else
    echo "openclaw not found, skip gateway restart"
  fi
}

print_check_summary() {
  local cfg_voice cfg_api_mode cfg_allow_legacy_fallback cfg_legacy_api_url cfg_gateway_timeout cfg_gateway_dynamic_timeout cfg_max_chars cfg_self_heal cfg_retry_on_failure cfg_retry_max_chars emotion_enabled emotion_high emotion_low media_mode fallback_profile_status
  cfg_voice="$(get_openclaw_voice_id)"
  cfg_api_mode="$(get_openclaw_api_mode)"
  cfg_allow_legacy_fallback="$(get_openclaw_allow_legacy_fallback)"
  cfg_legacy_api_url="$(get_openclaw_legacy_api_url)"
  cfg_gateway_timeout="$(get_openclaw_gateway_timeout)"
  cfg_gateway_dynamic_timeout="$(get_openclaw_gateway_dynamic_timeout)"
  cfg_max_chars="$(get_openclaw_tts_max_chars)"
  cfg_self_heal="$(get_openclaw_tts_self_heal_on_timeout)"
  cfg_retry_on_failure="$(get_openclaw_tts_retry_on_failure)"
  cfg_retry_max_chars="$(get_openclaw_tts_retry_max_chars)"
  emotion_enabled="$(yaml_emotion_value "enabled")"
  emotion_high="$(yaml_emotion_value "high_voice_id")"
  emotion_low="$(yaml_emotion_value "low_voice_id")"
  media_mode="$(get_media_output_mode)"
  fallback_profile_status="fail"
  if [[ "$cfg_api_mode" == "auto" && "$cfg_allow_legacy_fallback" == "1" && "$cfg_legacy_api_url" == "$DEFAULT_LEGACY_API_URL" ]]; then
    fallback_profile_status="pass"
  fi

  echo "CHECK_openclaw_voice_id=$cfg_voice"
  echo "CHECK_openclaw_tts_api_mode=$cfg_api_mode"
  echo "CHECK_openclaw_tts_allow_legacy_fallback=$cfg_allow_legacy_fallback"
  echo "CHECK_openclaw_tts_legacy_api_url=$cfg_legacy_api_url"
  echo "CHECK_openclaw_tts_fallback_profile=$fallback_profile_status"
  echo "CHECK_openclaw_tts_gateway_max_time=$cfg_gateway_timeout"
  echo "CHECK_openclaw_tts_gateway_dynamic_timeout=$cfg_gateway_dynamic_timeout"
  echo "CHECK_openclaw_tts_max_chars=$cfg_max_chars"
  echo "CHECK_openclaw_tts_self_heal_on_timeout=$cfg_self_heal"
  echo "CHECK_openclaw_tts_gateway_retry_on_failure=$cfg_retry_on_failure"
  echo "CHECK_openclaw_tts_gateway_retry_max_chars=$cfg_retry_max_chars"
  echo "CHECK_emotion_routing_enabled=$emotion_enabled"
  echo "CHECK_emotion_routing_high_voice_id=$emotion_high"
  echo "CHECK_emotion_routing_low_voice_id=$emotion_low"
  echo "CHECK_xiaoke_media_output_mode=$media_mode"
}

apply_fixes() {
  if ! command -v openclaw >/dev/null 2>&1; then
    echo "openclaw command not found; cannot apply OPENCLAW_TTS_VOICE_ID fix" >&2
    return 1
  fi

  openclaw config set "$OPENCLAW_VOICE_CONFIG_KEY" wakaba_mutsumi >/dev/null
  echo "set $OPENCLAW_VOICE_CONFIG_KEY=wakaba_mutsumi"

  openclaw config set "$OPENCLAW_API_MODE_CONFIG_KEY" auto >/dev/null
  echo "set $OPENCLAW_API_MODE_CONFIG_KEY=auto"

  openclaw config set "$OPENCLAW_ALLOW_LEGACY_FALLBACK_CONFIG_KEY" '"1"' >/dev/null
  echo "set $OPENCLAW_ALLOW_LEGACY_FALLBACK_CONFIG_KEY=1"

  openclaw config set "$OPENCLAW_LEGACY_API_URL_CONFIG_KEY" "\"$DEFAULT_LEGACY_API_URL\"" >/dev/null
  echo "set $OPENCLAW_LEGACY_API_URL_CONFIG_KEY=$DEFAULT_LEGACY_API_URL"

  openclaw config set "$OPENCLAW_GATEWAY_TIMEOUT_CONFIG_KEY" '"45"' >/dev/null
  echo "set $OPENCLAW_GATEWAY_TIMEOUT_CONFIG_KEY=45"

  openclaw config set "$OPENCLAW_GATEWAY_DYNAMIC_TIMEOUT_CONFIG_KEY" '"1"' >/dev/null
  echo "set $OPENCLAW_GATEWAY_DYNAMIC_TIMEOUT_CONFIG_KEY=1"

  openclaw config set "$OPENCLAW_MAX_CHARS_CONFIG_KEY" '"120"' >/dev/null
  echo "set $OPENCLAW_MAX_CHARS_CONFIG_KEY=120"

  openclaw config set "$OPENCLAW_SELF_HEAL_CONFIG_KEY" '"1"' >/dev/null
  echo "set $OPENCLAW_SELF_HEAL_CONFIG_KEY=1"

  openclaw config set "$OPENCLAW_RETRY_ON_FAILURE_CONFIG_KEY" '"1"' >/dev/null
  echo "set $OPENCLAW_RETRY_ON_FAILURE_CONFIG_KEY=1"

  openclaw config set "$OPENCLAW_RETRY_MAX_CHARS_CONFIG_KEY" '"80"' >/dev/null
  echo "set $OPENCLAW_RETRY_MAX_CHARS_CONFIG_KEY=80"

  set_emotion_routing_disabled

  if [[ "$restart_services" == "1" ]]; then
    restart_tts_service
    restart_gateway_service
  else
    echo "skip service restart (--no-restart)"
  fi
}

echo "MODE=$([[ "$apply_fix" == "1" ]] && echo apply || echo check)"
echo "TARGET_voices_file=$TTS_VOICES_FILE"
echo "TARGET_xiaoke_tts_script=$XIAOKE_TTS_SCRIPT"
print_check_summary

if [[ "$apply_fix" == "1" ]]; then
  apply_fixes
  print_check_summary
fi

if [[ -f "$TTS_AUDIT_LOG" ]]; then
  echo "TAIL_voice_selection_audit=$TTS_AUDIT_LOG"
  tail -n "$tail_lines" "$TTS_AUDIT_LOG"
else
  echo "TAIL_voice_selection_audit=<missing:$TTS_AUDIT_LOG>"
fi
