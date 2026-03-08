#!/usr/bin/env bash
# Validation helpers for merge-manager dry-run.
# Runs branch replay in a temporary detached worktree when commands are available.

mm_detect_validation_commands() {
  local repo_root="$1"
  local policy_file="$2"
  local preferred=()
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    preferred+=("$cmd")
  done < <(mm_policy_nested_list "$policy_file" validation_commands preferred)

  local found=()
  for cmd in "${preferred[@]-}"; do
    case "$cmd" in
      npm*)
        [[ -f "$repo_root/package.json" ]] && found+=("$cmd")
        ;;
      pytest*)
        [[ -f "$repo_root/pyproject.toml" || -d "$repo_root/tests" ]] && found+=("$cmd")
        ;;
      cargo*)
        [[ -f "$repo_root/Cargo.toml" ]] && found+=("$cmd")
        ;;
      go\ test*)
        [[ -f "$repo_root/go.mod" ]] && found+=("$cmd")
        ;;
      make\ *)
        [[ -f "$repo_root/Makefile" ]] && found+=("$cmd")
        ;;
    esac
  done

  if [[ "${#found[@]}" -eq 0 ]]; then
    if [[ -f "$repo_root/package.json" ]]; then
      if python3 - "$repo_root/package.json" <<'PY' >/dev/null 2>&1
import json, sys
scripts = json.load(open(sys.argv[1], encoding='utf-8')).get('scripts', {})
required = {'lint', 'typecheck', 'test'}
missing = required - set(scripts)
raise SystemExit(0 if not missing else 1)
PY
      then
        found+=("npm run lint" "npm run typecheck" "npm test")
      fi
    fi
  fi

  if [[ "${#found[@]}" -gt 0 ]]; then
    printf '%s\n' "${found[@]}"
  fi
}

mm_validate_branch_json() {
  local repo_root="$1"
  local base="$2"
  local branch="$3"
  local policy_file="$4"
  local commands=()
  while IFS= read -r cmd; do
    [[ -n "$cmd" ]] || continue
    commands+=("$cmd")
  done < <(mm_detect_validation_commands "$repo_root" "$policy_file")

  local mb conflict=no
  mb="$(git -C "$repo_root" merge-base "$base" "$branch")"
  if git -C "$repo_root" merge-tree "$mb" "$base" "$branch" | grep -q '^<<<<<<< '; then
    conflict=yes
  fi

  if [[ "$conflict" == yes ]]; then
    python3 - "$branch" <<'PY'
import json, sys
print(json.dumps({
  'branch': sys.argv[1],
  'status': 'blocked',
  'validation_summary': 'merge-tree predicts conflicts against latest base',
  'commands': [],
  'details': ['merge-tree conflict predicted'],
}, ensure_ascii=False, indent=2))
PY
    return 0
  fi

  if [[ "${#commands[@]}" -eq 0 ]]; then
    python3 - "$branch" <<'PY'
import json, sys
print(json.dumps({
  'branch': sys.argv[1],
  'status': 'blocked',
  'validation_summary': 'no validation commands detected',
  'commands': [],
  'details': ['validation command detection returned empty; manual review required'],
}, ensure_ascii=False, indent=2))
PY
    return 0
  fi

  local temp_worktree base_sha merge_out result_status detail_file
  temp_worktree="$(mktemp -d "${TMPDIR:-/tmp}/merge-manager-validate.XXXXXX")"
  detail_file="$(mktemp)"
  base_sha="$(git -C "$repo_root" rev-parse "$base")"
  git -C "$repo_root" worktree add --detach "$temp_worktree" "$base_sha" >/dev/null 2>&1 || {
    python3 - "$branch" <<'PY'
import json, sys
print(json.dumps({
  'branch': sys.argv[1],
  'status': 'blocked',
  'validation_summary': 'failed to create temporary validation worktree',
  'commands': [],
  'details': ['git worktree add --detach failed'],
}, ensure_ascii=False, indent=2))
PY
    rm -f "$detail_file"
    rm -rf "$temp_worktree"
    return 0
  }

  result_status=pass
  if ! git -C "$temp_worktree" merge --no-commit --no-ff "$branch" >"$detail_file" 2>&1; then
    result_status=blocked
    printf 'merge replay failed\n' >> "$detail_file"
  else
    for cmd in "${commands[@]}"; do
      if ! bash -lc "cd '$temp_worktree' && $cmd" >>"$detail_file" 2>&1; then
        result_status=blocked
        printf 'command failed: %s\n' "$cmd" >> "$detail_file"
        break
      fi
    done
  fi

  git -C "$temp_worktree" merge --abort >/dev/null 2>&1 || true
  git -C "$repo_root" worktree remove --force "$temp_worktree" >/dev/null 2>&1 || rm -rf "$temp_worktree"

  python3 - "$branch" "$result_status" "$detail_file" "${commands[@]}" <<'PY'
import json, sys, pathlib
branch = sys.argv[1]
status = sys.argv[2]
detail_file = sys.argv[3]
commands = sys.argv[4:]
details = pathlib.Path(detail_file).read_text(encoding='utf-8', errors='replace').splitlines()
summary = 'all detected validation commands passed in detached dry-run worktree' if status == 'pass' else 'validation failed or replay could not complete cleanly'
print(json.dumps({
  'branch': branch,
  'status': status,
  'validation_summary': summary,
  'commands': commands,
  'details': details[-20:],
}, ensure_ascii=False, indent=2))
PY
  rm -f "$detail_file"
}
