#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_TARGET="/opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/media.ts"
PATCHER="$SCRIPT_DIR/patch-openclaw-feishu-media-path.mjs"

show_help() {
  cat <<'EOF'
Usage: repatch-openclaw-feishu-media-path.sh [--dry-run|--apply] [--target <path>]

Options:
  --dry-run           Preview patch result without writing files.
  --apply             Apply patch to media.ts and create media.ts.bak if needed.
  --target <path>     Override target file (default: /opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/media.ts).
  -h, --help          Show this help message.

Patch effects:
  - Keeps MEDIA:./workspace/... resolution for Feishu local media uploads.
  - Adds guarded /tmp media bridge to state/workspace/tmp-media for voice/file compatibility.
  - Adds Feishu audio compatibility retries: upload duration fallback + opus msg_type fallback.
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
