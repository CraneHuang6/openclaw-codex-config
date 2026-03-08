#!/usr/bin/env bash
# Inventory helpers for merge-manager dry-run.
# Shared read-only core only; no merge or cleanup side effects.

mm_inventory_candidates() {
  local repo_root="$1"
  local base="$2"
  local branches_file="$3"
  local branch_pattern="$4"
  shift 4
  local protected=("$@")
  local tmp
  tmp="$(mktemp)"
  if [[ -n "$branches_file" ]]; then
    sed '/^\s*$/d' "$branches_file" > "$tmp"
  else
    git -C "$repo_root" for-each-ref --format='%(refname:short)' refs/heads > "$tmp"
  fi

  while IFS= read -r branch; do
    [[ -n "$branch" ]] || continue
    [[ "$branch" == "$base" ]] && continue
    local skip=0
    for protected_branch in "${protected[@]}"; do
      [[ -n "$protected_branch" ]] || continue
      if [[ "$branch" == "$protected_branch" ]]; then
        skip=1
        break
      fi
    done
    [[ "$skip" -eq 1 ]] && continue
    if [[ -n "$branch_pattern" ]] && [[ ! "$branch" == $branch_pattern ]]; then
      continue
    fi
    printf '%s\n' "$branch"
  done < "$tmp"
  rm -f "$tmp"
}

mm_branch_changed_files() {
  local repo_root="$1"
  local base="$2"
  local branch="$3"
  git -C "$repo_root" diff --name-only "$base...$branch" || true
}

mm_branch_age_days() {
  local repo_root="$1"
  local branch="$2"
  python3 - "$repo_root" "$branch" <<'PY'
import subprocess, sys
repo, branch = sys.argv[1:3]
iso = subprocess.check_output([
    'git', '-C', repo, 'log', '-1', '--format=%cI', branch
], text=True).strip()
from datetime import datetime, timezone
now = datetime.now(timezone.utc)
ts = datetime.fromisoformat(iso.replace('Z', '+00:00'))
print(max(0, (now - ts).days))
PY
}
