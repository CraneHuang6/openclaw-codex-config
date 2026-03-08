#!/usr/bin/env bash
set -euo pipefail

payload="${1:-}"
if [[ -z "${payload}" ]]; then
  exit 0
fi

LOG_FILE="${CODEX_NOTIFY_LOG_FILE:-$HOME/.codex/log/codex-notify.log}"
mkdir -p "$(dirname "$LOG_FILE")"

export CODEX_NOTIFY_PAYLOAD="${payload}"
if ! output="$(${HOME}/.codex/scripts/codex-notify-event-daemon.mjs --mode notify 2>&1)"; then
  {
    printf '[%s] [ERROR] notify hook failed\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] [ERROR] daemon output: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(printf '%s' "$output" | tr '\n' ' ' | cut -c1-1600)"
  } >>"$LOG_FILE" 2>/dev/null || true
fi
