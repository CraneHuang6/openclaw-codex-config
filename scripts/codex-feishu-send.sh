#!/usr/bin/env bash
set -euo pipefail

CHANNEL="${CODEX_FEISHU_CHANNEL:-feishu}"
TARGET="${CODEX_FEISHU_TARGET:-ou_9911a4b1244b09203d2ea79f5cef2bee}"
LOG_FILE="${CODEX_NOTIFY_LOG_FILE:-$HOME/.codex/log/feishu-notify.log}"
DRY_RUN="${CODEX_NOTIFY_DRY_RUN:-0}"

TITLE=""
BODY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)
      TITLE="${2:-}"
      shift 2
      ;;
    --body)
      BODY="${2:-}"
      shift 2
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$TITLE" || -z "$BODY" ]]; then
  echo "usage: codex-feishu-send.sh --title <title> --body <body>" >&2
  exit 2
fi

mkdir -p "$(dirname "$LOG_FILE")"

log() {
  local level="$1"
  local msg="$2"
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" >>"$LOG_FILE" 2>/dev/null || true
}

classify_error() {
  local out="$1"
  if [[ "$out" == *"createReplyVoiceTtsBridge"* || "$out" == *"Unknown channel: feishu"* ]]; then
    echo "FEISHU_PLUGIN_BROKEN"
    return
  fi
  if [[ "$out" == *"401"* || "$out" == *"403"* ]]; then
    echo "AUTH_OR_PERMISSION"
    return
  fi
  if [[ "$out" == *"timeout"* || "$out" == *"ETIMEDOUT"* ]]; then
    echo "NETWORK_TIMEOUT"
    return
  fi
  echo "SEND_FAILED"
}

MESSAGE="${TITLE}"$'\n'"${BODY}"

attempt=1
while [[ $attempt -le 3 ]]; do
  cmd=(openclaw message send --channel "$CHANNEL" --target "$TARGET" --message "$MESSAGE" --json)
  if [[ "$DRY_RUN" == "1" ]]; then
    cmd+=(--dry-run)
  fi

  if output="$("${cmd[@]}" 2>&1)"; then
    log "INFO" "send ok attempt=${attempt} target=${TARGET} title=${TITLE}"
    printf '%s\n' "$output"
    exit 0
  fi

  rc=$?
  cls="$(classify_error "$output")"
  compact_out="$(printf '%s' "$output" | tr '\n' '|' | cut -c1-1200)"
  log "ERROR" "send failed attempt=${attempt} rc=${rc} class=${cls} target=${TARGET} title=${TITLE} out=${compact_out}"

  if [[ $attempt -lt 3 ]]; then
    sleep $attempt
  fi
  attempt=$((attempt + 1))
done

exit 1
