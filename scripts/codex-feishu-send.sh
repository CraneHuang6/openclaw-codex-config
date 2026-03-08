#!/usr/bin/env bash
set -euo pipefail

export CODEX_NOTIFY_CHANNEL="${CODEX_NOTIFY_CHANNEL:-discord}"
export CODEX_NOTIFY_TARGET="${CODEX_NOTIFY_TARGET:-1480021215044440145}"
export CODEX_NOTIFY_LOG_FILE="${CODEX_NOTIFY_LOG_FILE:-$HOME/.codex/log/codex-notify.log}"
exec "${HOME}/.codex/scripts/codex-notify-send.sh" "$@"
