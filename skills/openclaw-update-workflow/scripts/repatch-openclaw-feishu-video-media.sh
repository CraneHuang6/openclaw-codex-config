#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_TARGET_ROOT="/opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src"
PATCHER="$SCRIPT_DIR/patch-openclaw-feishu-video-media.mjs"

show_help() {
  cat <<'EOF'
Usage: repatch-openclaw-feishu-video-media.sh [--dry-run|--apply] [--target-root <dir>]

Options:
  --dry-run              Preview patch result without writing files.
  --apply                Apply patch to bot.ts and create bot.ts.bak if needed.
  --target-root <dir>    Override target root (default: /opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src).
  -h, --help             Show this help message.
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
