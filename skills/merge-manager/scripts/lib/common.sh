#!/usr/bin/env bash
# Common helpers for merge-manager shared read-only core.
# MVP boundary: helpers only support inventory/classify/validate/report orchestration.

mm_die() {
  echo "[merge-manager][ERROR] $*" >&2
  exit 1
}

mm_note() {
  echo "[merge-manager] $*" >&2
}

mm_require_cmd() {
  command -v "$1" >/dev/null 2>&1 || mm_die "missing command: $1"
}

mm_abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$(pwd)" "$1" ;;
  esac
}

mm_repo_root() {
  git -C "$1" rev-parse --show-toplevel 2>/dev/null || mm_die "not inside git repo: $1"
}

mm_target_repo_root() {
  local cwd="${1:-$PWD}"
  mm_repo_root "$cwd"
}

mm_sanitize_name() {
  printf '%s' "$1" | sed 's#[/: ]#_#g'
}

mm_skill_owner_root() {
  local script_dir="$1"
  local owner_root
  owner_root="$(cd "$script_dir/../../.." && pwd)"
  [[ -f "$owner_root/AGENTS.md" ]] || mm_die "failed to resolve owning repo root from skill path: $script_dir"
  printf '%s\n' "$owner_root"
}
