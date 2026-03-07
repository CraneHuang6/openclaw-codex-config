#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATIC_SCRIPT="$SCRIPT_DIR/sync_model_upgrade.py"
RUNTIME_SCRIPT="$SCRIPT_DIR/hardcut_runtime_model.py"

PRIMARY_MODEL="gpt-5.4"
CLAUDE_MODEL=""
FALLBACK_MODEL="gpt-5.3-codex"
MONITOR_MODEL="gpt-5.1-codex-mini"
PROVIDER="qmcode"
WINDOW_MINUTES=30
RUN_TESTS=1
KILL_RUNTIME=1
SEED_BASELINES=1
AUTO_CLOSE_ON_MISMATCH=0
SINCE_TS=""
CLAUDE_PROJECT_CWD="${HOME}/.openclaw"
CODEX_MAIN_CWD="${HOME}/.codex"
CODEX_WORKTREES_ROOT="${HOME}/.codex/worktrees"
CODEX_WORKTREE_CWD=""
CLAUDE_MAIN_CWD="${HOME}"

usage() {
  cat <<'EOF'
Usage: run_full_model_sync.sh [options]

Runs static sync, runtime hard-cut, seeds 4 probe sessions, then verifies.

Options:
  --primary-model MODEL
  --claude-model MODEL
  --fallback-model MODEL
  --monitor-model MODEL
  --provider PROVIDER
  --window-minutes N
  --claude-project-cwd DIR
  --claude-main-cwd DIR
  --codex-main-cwd DIR
  --codex-worktrees-root DIR
  --codex-worktree-cwd DIR
  --since-ts TS
  --skip-tests
  --skip-kill-runtime
  --skip-seed-baselines
  --auto-close-on-mismatch
  -h, --help
EOF
}

print_cmd() {
  printf '+ '
  printf '%q ' "$@"
  printf '\n'
}

run_cmd() {
  print_cmd "$@"
  "$@"
}

pick_first_worktree() {
  local root="$1"
  find "$root" -mindepth 1 -maxdepth 1 -type d | LC_ALL=C sort | head -n 1
}

seed_codex_probe() {
  local cwd="$1"
  run_cmd codex exec -C "$cwd" --skip-git-repo-check "只输出OK。不要执行任何工具。"
}

seed_claude_probe() {
  local cwd="$1"
  local session_id
  session_id="$(uuidgen | tr 'A-Z' 'a-z')"
  (
    cd "$cwd"
    run_cmd claude -p --session-id "$session_id" "只输出OK。不要调用工具。"
  )
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --primary-model)
      PRIMARY_MODEL="$2"
      shift 2
      ;;
    --claude-model)
      CLAUDE_MODEL="$2"
      shift 2
      ;;
    --fallback-model)
      FALLBACK_MODEL="$2"
      shift 2
      ;;
    --monitor-model)
      MONITOR_MODEL="$2"
      shift 2
      ;;
    --provider)
      PROVIDER="$2"
      shift 2
      ;;
    --window-minutes)
      WINDOW_MINUTES="$2"
      shift 2
      ;;
    --claude-project-cwd)
      CLAUDE_PROJECT_CWD="$2"
      shift 2
      ;;
    --claude-main-cwd)
      CLAUDE_MAIN_CWD="$2"
      shift 2
      ;;
    --codex-main-cwd)
      CODEX_MAIN_CWD="$2"
      shift 2
      ;;
    --codex-worktrees-root)
      CODEX_WORKTREES_ROOT="$2"
      shift 2
      ;;
    --codex-worktree-cwd)
      CODEX_WORKTREE_CWD="$2"
      shift 2
      ;;
    --since-ts)
      SINCE_TS="$2"
      shift 2
      ;;
    --skip-tests)
      RUN_TESTS=0
      shift
      ;;
    --skip-kill-runtime)
      KILL_RUNTIME=0
      shift
      ;;
    --skip-seed-baselines)
      SEED_BASELINES=0
      shift
      ;;
    --auto-close-on-mismatch)
      AUTO_CLOSE_ON_MISMATCH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$CLAUDE_MODEL" ]]; then
  CLAUDE_MODEL="$PRIMARY_MODEL"
fi

if [[ ! -x "$STATIC_SCRIPT" ]]; then
  echo "[ERROR] Missing static sync script: $STATIC_SCRIPT" >&2
  exit 2
fi
if [[ ! -x "$RUNTIME_SCRIPT" ]]; then
  echo "[ERROR] Missing runtime hard-cut script: $RUNTIME_SCRIPT" >&2
  exit 2
fi

static_cmd=(
  python3 "$STATIC_SCRIPT"
  --mode all
  --primary-model "$PRIMARY_MODEL"
  --fallback-model "$FALLBACK_MODEL"
  --provider "$PROVIDER"
  --claude-model "$CLAUDE_MODEL"
)
if [[ "$RUN_TESTS" -eq 1 ]]; then
  static_cmd+=(--run-tests)
fi
run_cmd "${static_cmd[@]}"

runtime_apply_cmd=(
  python3 "$RUNTIME_SCRIPT" apply
  --target-model "$PRIMARY_MODEL"
  --claude-target-model "$CLAUDE_MODEL"
  --fallback-model "$FALLBACK_MODEL"
  --monitor-model "$MONITOR_MODEL"
  --codex-main-cwd "$CODEX_MAIN_CWD"
  --codex-worktrees-root "$CODEX_WORKTREES_ROOT"
  --claude-main-cwd "$CLAUDE_MAIN_CWD"
  --claude-project-cwd "$CLAUDE_PROJECT_CWD"
)
if [[ "$KILL_RUNTIME" -eq 1 ]]; then
  runtime_apply_cmd+=(--kill-runtime)
fi
run_cmd "${runtime_apply_cmd[@]}"

if [[ "$SEED_BASELINES" -eq 1 ]]; then
  if [[ -z "$CODEX_WORKTREE_CWD" ]]; then
    CODEX_WORKTREE_CWD="$(pick_first_worktree "$CODEX_WORKTREES_ROOT")"
  fi
  if [[ -z "$CODEX_WORKTREE_CWD" ]]; then
    echo "[ERROR] No Codex worktree found under $CODEX_WORKTREES_ROOT" >&2
    exit 2
  fi

  seed_codex_probe "$CODEX_MAIN_CWD"
  seed_codex_probe "$CODEX_WORKTREE_CWD"
  seed_claude_probe "$CLAUDE_MAIN_CWD"
  seed_claude_probe "$CLAUDE_PROJECT_CWD"
fi

runtime_verify_cmd=(
  python3 "$RUNTIME_SCRIPT" verify
  --target-model "$PRIMARY_MODEL"
  --claude-target-model "$CLAUDE_MODEL"
  --fallback-model "$FALLBACK_MODEL"
  --window-minutes "$WINDOW_MINUTES"
  --codex-main-cwd "$CODEX_MAIN_CWD"
  --codex-worktrees-root "$CODEX_WORKTREES_ROOT"
  --claude-main-cwd "$CLAUDE_MAIN_CWD"
  --claude-project-cwd "$CLAUDE_PROJECT_CWD"
)
if [[ "$AUTO_CLOSE_ON_MISMATCH" -eq 1 ]]; then
  runtime_verify_cmd+=(--auto-close-on-mismatch)
fi
if [[ -n "$SINCE_TS" ]]; then
  runtime_verify_cmd+=(--since-ts "$SINCE_TS")
fi
run_cmd "${runtime_verify_cmd[@]}"
