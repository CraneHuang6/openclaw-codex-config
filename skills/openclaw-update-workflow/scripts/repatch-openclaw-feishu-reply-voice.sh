#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_TARGET_ROOT="/opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src"
PATCHER="$SCRIPT_DIR/patch-openclaw-feishu-reply-voice.mjs"

show_help() {
  cat <<'EOF'
Usage: repatch-openclaw-feishu-reply-voice.sh [--dry-run|--apply] [--target-root <dir>]

Options:
  --dry-run              Preview patch result without writing files.
  --apply                Apply patch to bot.ts/reply-voice-*.ts and create .bak if needed.
  --target-root <dir>    Override target root (default: /opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src).
  -h, --help             Show this help message.

Patch effects:
  - Add "reply + 生成语音" local fast-path in bot.ts (chunk size 500; fail-fast on any chunk error).
  - Harden no-final fallback in bot.ts (30s->90s timeout override + reply失败后直发文本兜底).
  - Disable slow-reply mid-process notice text ("小可还在处理中..."), keep final voice/text fallback behavior.
  - Ensure reply-voice-command.ts and reply-voice-tts.ts exist with stable local bridge behavior.
EOF
}

for arg in "$@"; do
  if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
    show_help
    exit 0
  fi
done

has_mode=false
has_target_root=false
for arg in "$@"; do
  if [[ "$arg" == "--dry-run" || "$arg" == "--apply" ]]; then
    has_mode=true
  elif [[ "$arg" == "--target-root" ]]; then
    has_target_root=true
  fi
done

args=("$@")
if [[ "$has_mode" == "false" ]]; then
  args=(--apply "${args[@]}")
fi
if [[ "$has_target_root" == "false" ]]; then
  args+=(--target-root "$DEFAULT_TARGET_ROOT")
fi

exec node "$PATCHER" "${args[@]}"
