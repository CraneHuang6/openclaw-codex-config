#!/usr/bin/env bash
set -euo pipefail

payload="${1:-}"
if [[ -z "${payload}" ]]; then
  exit 0
fi

export CODEX_NOTIFY_PAYLOAD="${payload}"
"${HOME}/.codex/scripts/codex-feishu-event-daemon.mjs" --mode notify >/dev/null 2>&1 || true
