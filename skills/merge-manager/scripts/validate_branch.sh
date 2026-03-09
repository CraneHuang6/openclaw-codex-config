#!/usr/bin/env bash
# Emit validation JSON for a single branch in dry-run mode.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/policy.sh"
source "$SCRIPT_DIR/lib/validation.sh"

usage() {
  cat <<'USAGE'
Usage: validate_branch.sh --repo <path> --base <branch> --branch <branch> [--policy <path>]
USAGE
}

emit_validation_json() {
  local branch="$1"
  local status="$2"
  local summary="$3"
  local details_file="$4"
  shift 4
  local commands=("$@")
  local python_args=("$branch" "$status" "$summary" "$details_file")
  if [[ "${#commands[@]}" -gt 0 ]]; then
    python_args+=("${commands[@]}")
  fi

  python3 - "${python_args[@]}" <<'PY'
import json, pathlib, sys
branch = sys.argv[1]
status = sys.argv[2]
summary = sys.argv[3]
details_file = pathlib.Path(sys.argv[4])
commands = sys.argv[5:]
details = []
if details_file.exists():
    details = details_file.read_text(encoding='utf-8', errors='replace').splitlines()[-20:]
print(json.dumps({
  'branch': branch,
  'status': status,
  'validation_summary': summary,
  'commands': commands,
  'details': details,
}, ensure_ascii=False, indent=2))
PY
}

validate_branch_json() {
  local repo_root="$1"
  local base="$2"
  local branch="$3"
  local policy_file="$4"
  local commands=()
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    commands+=("$cmd")
  done < <(mm_detect_validation_commands "$repo_root" "$policy_file")

  local mb
  mb="$(git -C "$repo_root" merge-base "$base" "$branch")"
  if git -C "$repo_root" merge-tree "$mb" "$base" "$branch" | grep -q '^<<<<<<< '; then
    local details_file
    details_file="$(mktemp)"
    printf 'merge-tree conflict predicted\n' > "$details_file"
    emit_validation_json "$branch" blocked 'merge-tree predicts conflicts against latest base' "$details_file"
    rm -f "$details_file"
    return 0
  fi

  if [[ "${#commands[@]}" -eq 0 ]]; then
    local details_file
    details_file="$(mktemp)"
    printf 'validation command detection returned empty; manual review required\n' > "$details_file"
    emit_validation_json "$branch" blocked 'no validation commands detected' "$details_file"
    rm -f "$details_file"
    return 0
  fi

  local temp_worktree detail_file base_sha result_status
  temp_worktree="$(mktemp -d "${TMPDIR:-/tmp}/merge-manager-validate.XXXXXX")"
  detail_file="$(mktemp)"
  base_sha="$(git -C "$repo_root" rev-parse "$base")"
  if ! git -C "$repo_root" worktree add --detach "$temp_worktree" "$base_sha" >/dev/null 2>&1; then
    printf 'git worktree add --detach failed\n' > "$detail_file"
    emit_validation_json "$branch" blocked 'failed to create temporary validation worktree' "$detail_file"
    rm -f "$detail_file"
    rm -rf "$temp_worktree"
    return 0
  fi

  result_status=pass
  if ! git -C "$temp_worktree" merge --no-commit --no-ff "$branch" >"$detail_file" 2>&1; then
    result_status=blocked
    printf 'merge replay failed\n' >> "$detail_file"
  else
    local cmd
    for cmd in "${commands[@]}"; do
      if ! CODEX_HOME="$temp_worktree" bash -lc "cd '$temp_worktree' && $cmd" >>"$detail_file" 2>&1; then
        result_status=blocked
        printf 'command failed: %s\n' "$cmd" >> "$detail_file"
        break
      fi
    done
  fi

  git -C "$temp_worktree" merge --abort >/dev/null 2>&1 || true
  git -C "$repo_root" worktree remove --force "$temp_worktree" >/dev/null 2>&1 || rm -rf "$temp_worktree"

  local summary='all detected validation commands passed in detached dry-run worktree'
  if [[ "$result_status" != pass ]]; then
    summary='validation failed or replay could not complete cleanly'
  fi
  if [[ "${#commands[@]}" -gt 0 ]]; then
    emit_validation_json "$branch" "$result_status" "$summary" "$detail_file" "${commands[@]}"
  else
    emit_validation_json "$branch" "$result_status" "$summary" "$detail_file"
  fi
  rm -f "$detail_file"
}

REPO=""
BASE="main"
BRANCH=""
POLICY=""
TEMP_POLICY=""
cleanup() {
  if [[ -n "$TEMP_POLICY" ]]; then
    rm -f "$TEMP_POLICY"
  fi
}
trap cleanup EXIT
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --policy) POLICY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) mm_die "unknown argument: $1" ;;
  esac
done
[[ -n "$REPO" && -n "$BRANCH" ]] || mm_die "--repo and --branch are required"
REPO="$(mm_repo_root "$REPO")"
if [[ -z "$POLICY" ]]; then
  TEMP_POLICY="$(mktemp "${TMPDIR:-/tmp}/merge-manager-policy.XXXXXX")"
  python3 "$SCRIPT_DIR/generate_legacy_policy.py" --config-dir "$SCRIPT_DIR/../config" --output "$TEMP_POLICY"
  POLICY="$TEMP_POLICY"
fi
validate_branch_json "$REPO" "$BASE" "$BRANCH" "$POLICY"
