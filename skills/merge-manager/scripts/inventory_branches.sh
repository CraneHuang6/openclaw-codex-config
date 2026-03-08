#!/usr/bin/env bash
# Emit branch inventory JSON for merge-manager dry-run.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/policy.sh"
source "$SCRIPT_DIR/lib/inventory.sh"

usage() {
  cat <<'USAGE'
Usage: inventory_branches.sh --repo <path> --base <branch> [--policy <path>] [--branch-pattern <glob>] [--branches-file <path>]
USAGE
}

REPO=""
BASE="main"
POLICY="$SCRIPT_DIR/../assets/merge-policy.yaml"
BRANCH_PATTERN=""
BRANCHES_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --policy) POLICY="$2"; shift 2 ;;
    --branch-pattern) BRANCH_PATTERN="$2"; shift 2 ;;
    --branches-file) BRANCHES_FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) mm_die "unknown argument: $1" ;;
  esac
done
[[ -n "$REPO" ]] || mm_die "--repo is required"
REPO="$(mm_repo_root "$REPO")"
PROTECTED=()
while IFS= read -r protected_branch; do
  [[ -n "$protected_branch" ]] || continue
  PROTECTED+=("$protected_branch")
done < <(mm_policy_list "$POLICY" protected_branches)

CANDIDATES=()
while IFS= read -r candidate_branch; do
  [[ -n "$candidate_branch" ]] || continue
  CANDIDATES+=("$candidate_branch")
done < <(mm_inventory_candidates "$REPO" "$BASE" "$BRANCHES_FILE" "$BRANCH_PATTERN" "${PROTECTED[@]-}")

CANDIDATES_FILE="$(mktemp)"
WORKTREE_FILE="$(mktemp)"
trap 'rm -f "$CANDIDATES_FILE" "$WORKTREE_FILE"' EXIT
for branch in "${CANDIDATES[@]-}"; do
  [[ -n "$branch" ]] || continue
  printf '%s\n' "$branch" >> "$CANDIDATES_FILE"
done
while IFS= read -r worktree_entry; do
  [[ -n "$worktree_entry" ]] || continue
  printf '%s\n' "$worktree_entry" >> "$WORKTREE_FILE"
done < <(mm_worktree_branch_locations "$REPO")

python3 - "$REPO" "$BASE" "$CANDIDATES_FILE" "$WORKTREE_FILE" <<'PY'
import json
import pathlib
import subprocess
import sys

repo = sys.argv[1]
base = sys.argv[2]
branches_file = pathlib.Path(sys.argv[3])
worktree_file = pathlib.Path(sys.argv[4])
branches = [line.strip() for line in branches_file.read_text(encoding='utf-8').splitlines() if line.strip()]
worktree_map = {}
for raw in worktree_file.read_text(encoding='utf-8').splitlines():
    if not raw.strip():
        continue
    branch, path = raw.split('\t', 1)
    worktree_map.setdefault(branch, []).append(path)

candidates = []
filtered_out = []
for branch in branches:
    ahead = subprocess.check_output(['git', '-C', repo, 'rev-list', '--count', f'{base}..{branch}'], text=True).strip()
    behind = subprocess.check_output(['git', '-C', repo, 'rev-list', '--count', f'{branch}..{base}'], text=True).strip()
    last_commit = subprocess.check_output(['git', '-C', repo, 'log', '-1', '--format=%cI', branch], text=True).strip()
    changed_files = subprocess.check_output(['git', '-C', repo, 'diff', '--name-only', f'{base}...{branch}'], text=True).splitlines()
    merged = subprocess.call(['git', '-C', repo, 'merge-base', '--is-ancestor', branch, base]) == 0
    checked_out_paths = worktree_map.get(branch, [])
    record = {
        'branch': branch,
        'ahead': int(ahead),
        'behind': int(behind),
        'last_commit': last_commit,
        'already_merged': merged,
        'checked_out_worktrees': checked_out_paths,
        'changed_files': changed_files,
    }

    reasons = []
    if checked_out_paths:
        reasons.append('checked_out_in_worktree')
    if merged:
        reasons.append('already_merged')

    if reasons:
        filtered_out.append({
            **record,
            'filter_reasons': reasons,
        })
    else:
        candidates.append(record)

print(json.dumps({
    'repo_root': repo,
    'base': base,
    'branches': candidates,
    'filtered_out': filtered_out,
}, ensure_ascii=False, indent=2))
PY
