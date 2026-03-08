#!/usr/bin/env bash
set -euo pipefail

payload="${1:-}"
if [[ -z "${payload}" ]]; then
  exit 0
fi

log_file="${CODEX_FEISHU_NOTIFY_LOG_FILE:-$HOME/.codex/log/feishu-notify.log}"
mkdir -p "$(dirname "${log_file}")"

delegate_status=0
output="$(${HOME}/.codex/hooks/codex-notify-on-turn.sh "$@" 2>&1)" || delegate_status=$?
if [[ ${delegate_status} -ne 0 ]]; then
  {
    printf '[%s] [ERROR] notify hook failed\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] [ERROR] delegate output: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(printf '%s' "$output" | tr '\n' ' ' | cut -c1-1600)"
  } >>"${log_file}" 2>/dev/null || true
  exit "${delegate_status}"
fi

exit 0
