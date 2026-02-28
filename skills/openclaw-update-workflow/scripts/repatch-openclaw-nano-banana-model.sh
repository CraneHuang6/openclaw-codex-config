#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TARGET="/opt/homebrew/lib/node_modules/openclaw/skills/nano-banana-pro/scripts/generate_image.py"
PATCHER="/Users/crane/.openclaw/scripts/patch-openclaw-nano-banana-model.mjs"

show_help() {
  cat <<'EOF'
Usage: repatch-openclaw-nano-banana-model.sh [--dry-run|--apply] [--target <path>]

Options:
  --dry-run         Preview patch result without writing files.
  --apply           Apply patch to generate_image.py and create .bak if needed.
  --target <path>   Override target file (default: /opt/homebrew/lib/node_modules/openclaw/skills/nano-banana-pro/scripts/generate_image.py).
  -h, --help        Show this help message.

Patch effects:
  - Set default image model to gemini-3.1-flash-image-preview.
  - Add automatic fallback to gemini-3-pro-image-preview on model failure.
  - Add --model/--fallback-model args and NANO_BANANA_MODEL env compatibility.
EOF
}

for arg in "$@"; do
  if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
    show_help
    exit 0
  fi
done

has_mode=false
has_target=false
for arg in "$@"; do
  if [[ "$arg" == "--dry-run" || "$arg" == "--apply" ]]; then
    has_mode=true
  elif [[ "$arg" == "--target" ]]; then
    has_target=true
  fi
done

args=("$@")
if [[ "$has_mode" == "false" ]]; then
  args=(--apply "${args[@]}")
fi
if [[ "$has_target" == "false" ]]; then
  args+=(--target "$DEFAULT_TARGET")
fi

exec node "$PATCHER" "${args[@]}"
