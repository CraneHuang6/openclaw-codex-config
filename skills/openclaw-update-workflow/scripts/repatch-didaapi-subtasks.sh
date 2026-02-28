#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_WORKSPACE_ROOT="${OPENCLAW_HOME:-$HOME/.openclaw}/workspace"
PATCHER="$SCRIPT_DIR/patch-didaapi-subtasks.py"

show_help() {
  cat <<'EOF'
Usage: repatch-didaapi-subtasks.sh [--dry-run|--apply] [--workspace-root <path>]

Options:
  --dry-run                  Preview patch result without writing files.
  --apply                    Apply patch to DidaAPI backend + CLI files.
  --workspace-root <path>    Override workspace root (default: /Users/crane/.openclaw/workspace).
  -h, --help                 Show this help message.
EOF
}

for arg in "$@"; do
  if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
    show_help
    exit 0
  fi
done

has_mode=false
has_workspace_root=false
for arg in "$@"; do
  if [[ "$arg" == "--dry-run" || "$arg" == "--apply" ]]; then
    has_mode=true
  elif [[ "$arg" == "--workspace-root" ]]; then
    has_workspace_root=true
  fi
done

args=("$@")
if [[ "$has_mode" == "false" ]]; then
  args=(--apply "${args[@]}")
fi
if [[ "$has_workspace_root" == "false" ]]; then
  args+=(--workspace-root "$DEFAULT_WORKSPACE_ROOT")
fi

exec python3 "$PATCHER" "${args[@]}"
