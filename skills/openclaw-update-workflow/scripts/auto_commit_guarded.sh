#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${OPENCLAW_SKILL_AUTO_COMMIT_REPO:-/Users/crane/.codex}"
MODE="${OPENCLAW_SKILL_AUTO_COMMIT_MODE:-unknown}"

print_result() {
  local result="$1"
  local reason="$2"
  local hash="${3:-}"
  local files="${4:-}"
  echo "AUTO_COMMIT_RESULT=${result}"
  echo "AUTO_COMMIT_REASON=${reason}"
  echo "AUTO_COMMIT_HASH=${hash}"
  echo "AUTO_COMMIT_FILES=${files}"
}

is_allowlisted_path() {
  local path="$1"
  [[ "$path" == "AGENTS.md" || "$path" == "skills/openclaw-update-workflow" || "$path" == skills/openclaw-update-workflow/* ]]
}

is_sensitive_path() {
  local path="$1"
  local base
  base="$(basename "$path")"
  case "$base" in
    .env|.env.*|*.key|*.pem|*.p12|*.pfx|*.crt|*.cer)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

if [[ ! -d "$REPO_ROOT/.git" ]]; then
  print_result "failed" "repo_not_found"
  exit 2
fi

changed_paths="$(
  {
    git -C "$REPO_ROOT" diff --name-only
    git -C "$REPO_ROOT" diff --cached --name-only
    git -C "$REPO_ROOT" ls-files --others --exclude-standard
  } | sed '/^$/d' | sort -u
)"

if [[ -z "$changed_paths" ]]; then
  print_result "skipped" "no_changes"
  exit 0
fi

allowlist_files=()
outside_paths=()
while IFS= read -r rel; do
  [[ -z "$rel" ]] && continue
  if is_sensitive_path "$rel"; then
    print_result "skipped" "sensitive_file_detected" "" "$rel"
    exit 0
  fi
  if is_allowlisted_path "$rel"; then
    allowlist_files+=("$rel")
  else
    outside_paths+=("$rel")
  fi
done <<< "$changed_paths"

if ((${#outside_paths[@]} > 0)); then
  outside_csv="$(printf '%s\n' "${outside_paths[@]}" | paste -sd ',' -)"
  print_result "skipped" "dirty_outside_allowlist" "" "$outside_csv"
  exit 0
fi

if ((${#allowlist_files[@]} == 0)); then
  print_result "skipped" "no_changes"
  exit 0
fi

git -C "$REPO_ROOT" add -- "${allowlist_files[@]}"

if git -C "$REPO_ROOT" diff --cached --quiet --; then
  print_result "skipped" "no_changes"
  exit 0
fi

commit_message="chore(openclaw-update-workflow): auto commit after gate d2 pass (${MODE})"
if ! git -C "$REPO_ROOT" commit -m "$commit_message" >/dev/null 2>&1; then
  allowlist_csv="$(printf '%s\n' "${allowlist_files[@]}" | paste -sd ',' -)"
  print_result "failed" "git_commit_failed" "" "$allowlist_csv"
  exit 3
fi

commit_hash="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
allowlist_csv="$(printf '%s\n' "${allowlist_files[@]}" | paste -sd ',' -)"
print_result "committed" "ok" "$commit_hash" "$allowlist_csv"
