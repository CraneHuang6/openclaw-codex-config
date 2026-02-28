#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: safe-clean-workspace.sh [options]

Safely clean a git workspace by:
  1) backing up critical local files/directories
  2) creating a verified stash that includes untracked files
  3) requiring a second confirmation before cleanup

Defaults are tuned for /Users/crane/.openclaw/workspace.

Options:
  --repo PATH          Target git repo (default: /Users/crane/.openclaw/workspace)
  --backup-root PATH   Backup root dir (default: /Users/crane/.openclaw/backup/manual-rollbacks)
  --mode MODE          Cleanup mode: untracked | full (default: untracked)
                       untracked = git clean -fd
                       full      = git reset --hard + git clean -fd
  --also-ignored       Use git clean -fdx instead of -fd (more destructive)
  --no-stash           Skip git stash step (not recommended)
  --no-backup          Skip backup step (not recommended)
  --yes-step1          Skip first confirmation (backup/stash phase)
  --yes-step2          Skip second confirmation (cleanup phase)
  --help               Show this help

Notes:
  - This script is interactive by default.
  - It never runs git clean/reset until after stash output is shown and step 2 is confirmed.
  - For runtime-written state files (e.g. cron status), stop writer processes before rollback checks.
EOF
}

log() { printf '[safe-clean] %s\n' "$*"; }
warn() { printf '[safe-clean][warn] %s\n' "$*" >&2; }
die() { printf '[safe-clean][error] %s\n' "$*" >&2; exit 1; }

confirm_token() {
  local prompt="$1" expected="$2"
  local input
  printf '%s\n' "$prompt"
  printf "Type '%s' to continue: " "$expected"
  IFS= read -r input
  [[ "$input" == "$expected" ]] || die "confirmation failed"
}

timestamp() {
  date +"%Y%m%d-%H%M%S"
}

repo="/Users/crane/.openclaw/workspace"
backup_root="/Users/crane/.openclaw/backup/manual-rollbacks"
mode="untracked"
also_ignored=0
do_stash=1
do_backup=1
yes_step1=0
yes_step2=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires a path"
      repo="$2"; shift 2 ;;
    --backup-root)
      [[ $# -ge 2 ]] || die "--backup-root requires a path"
      backup_root="$2"; shift 2 ;;
    --mode)
      [[ $# -ge 2 ]] || die "--mode requires a value"
      mode="$2"; shift 2 ;;
    --also-ignored)
      also_ignored=1; shift ;;
    --no-stash)
      do_stash=0; shift ;;
    --no-backup)
      do_backup=0; shift ;;
    --yes-step1)
      yes_step1=1; shift ;;
    --yes-step2)
      yes_step2=1; shift ;;
    --help|-h)
      usage; exit 0 ;;
    *)
      die "unknown option: $1" ;;
  esac
done

[[ "$mode" == "untracked" || "$mode" == "full" ]] || die "invalid --mode: $mode"
[[ -d "$repo" ]] || die "repo not found: $repo"

git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo: $repo"
repo_top="$(git -C "$repo" rev-parse --show-toplevel)"
branch="$(git -C "$repo" branch --show-current || true)"

clean_args=(-fd)
(( also_ignored )) && clean_args=(-fdx)

log "target repo: $repo_top"
log "branch: ${branch:-<detached>}"
log "mode: $mode"
log "clean args: git clean ${clean_args[*]}"
log "status (before):"
git -C "$repo" status --short || true

if (( ! yes_step1 )); then
  confirm_token \
    "Step 1/2 (backup + stash). This may create backups and a stash entry in the target repo." \
    "STEP1"
fi

backup_dir=""
if (( do_backup )); then
  ts="$(timestamp)"
  backup_dir="$backup_root/${ts}-safe-clean-workspace"
  mkdir -p "$backup_dir"
  manifest="$backup_dir/manifest.txt"
  : > "$manifest"

  critical_paths=(
    "memory"
    "MEMORY.md"
    "SOUL.md"
    "HEARTBEAT.md"
  )

  log "creating backup snapshot: $backup_dir"
  for rel in "${critical_paths[@]}"; do
    src="$repo_top/$rel"
    if [[ -e "$src" ]]; then
      mkdir -p "$backup_dir/$(dirname "$rel")"
      if [[ -d "$src" ]]; then
        rsync -a "$src/" "$backup_dir/$rel/"
      else
        cp -p "$src" "$backup_dir/$rel"
      fi
      printf '%s\n' "$rel" >> "$manifest"
      log "backed up: $rel"
    else
      warn "skip missing critical path: $rel"
    fi
  done
else
  warn "backup skipped (--no-backup)"
fi

stash_created=0
stash_ref=""
if (( do_stash )); then
  stash_before="$(git -C "$repo" stash list | head -1 || true)"
  stash_msg="safe-clean-workspace $(timestamp)"
  stash_out="$(git -C "$repo" stash push -u -m "$stash_msg" 2>&1 || true)"
  printf '%s\n' "$stash_out"

  stash_after="$(git -C "$repo" stash list | head -1 || true)"
  if [[ -n "$stash_after" && "$stash_after" != "$stash_before" ]]; then
    stash_created=1
    stash_ref="${stash_after%%:*}"
  elif printf '%s' "$stash_out" | grep -qi "No local changes to save"; then
    stash_created=0
  else
    warn "could not confidently detect a new stash entry; inspect stash list manually"
  fi

  log "stash list (top 3):"
  git -C "$repo" stash list | head -3 || true

  if (( stash_created )); then
    log "stash verification: $stash_ref"
    git -C "$repo" stash show --name-status --include-untracked "$stash_ref" || true
  else
    warn "no new stash detected; cleanup may still be safe only if status is already clean"
  fi
else
  warn "stash skipped (--no-stash)"
fi

log "status (after backup/stash, before cleanup):"
git -C "$repo" status --short || true

if (( ! yes_step2 )); then
  action_desc="git clean ${clean_args[*]}"
  [[ "$mode" == "full" ]] && action_desc="git reset --hard && $action_desc"
  confirm_token \
    "Step 2/2 (destructive cleanup). About to run: $action_desc" \
    "CLEAN"
fi

if [[ "$mode" == "full" ]]; then
  log "running: git reset --hard"
  git -C "$repo" reset --hard
fi

log "running: git clean ${clean_args[*]}"
git -C "$repo" clean "${clean_args[@]}"

log "status (after cleanup):"
git -C "$repo" status --short || true

if [[ -n "$backup_dir" ]]; then
  log "backup saved at: $backup_dir"
fi
if [[ -n "$stash_ref" ]]; then
  log "stash saved at: $stash_ref"
fi
log "done"
