#!/usr/bin/env bash
set -euo pipefail

DEFAULT_OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
skills_root="${OPENCLAW_DAILY_UPDATE_SKILLS_ROOT:-$DEFAULT_OPENCLAW_HOME/workspace/skills}"
strict_mode="${OPENCLAW_DAILY_UPDATE_SKILLS_SYNC_STRICT:-0}"
local_github_owners="${OPENCLAW_DAILY_UPDATE_LOCAL_GITHUB_OWNERS:-CraneHuang6}"

show_help() {
  cat <<'HELP'
Usage: update-installed-skills.sh [options]

Options:
  --skills-root <path>           Override skills root path.
  --local-github-owners <csv>    GitHub owners treated as local/self-developed.
  --strict                       Exit non-zero when any git sync fails.
  -h, --help                     Show this help message.
HELP
}

trim_spaces() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

extract_github_owner() {
  local url="$1" owner=""
  owner="$(printf '%s' "$url" | sed -E -n 's#^https?://(www\.)?github\.com/([^/]+)/[^/]+(\.git)?$#\2#p')"
  if [[ -z "$owner" ]]; then
    owner="$(printf '%s' "$url" | sed -E -n 's#^ssh://git@github\.com/([^/]+)/[^/]+(\.git)?$#\1#p')"
  fi
  if [[ -z "$owner" ]]; then
    owner="$(printf '%s' "$url" | sed -E -n 's#^git@github\.com:([^/]+)/[^/]+(\.git)?$#\1#p')"
  fi
  if [[ -z "$owner" ]]; then
    owner="$(printf '%s' "$url" | sed -E -n 's#^git://github\.com/([^/]+)/[^/]+(\.git)?$#\1#p')"
  fi
  printf '%s' "$owner"
}

is_local_github_owner() {
  local owner="$1" raw one
  owner="$(to_lower "$(trim_spaces "$owner")")"
  IFS=',' read -r -a raw <<< "$local_github_owners"
  for one in "${raw[@]}"; do
    one="$(to_lower "$(trim_spaces "$one")")"
    if [[ -n "$one" && "$one" == "$owner" ]]; then
      return 0
    fi
  done
  return 1
}

is_local_origin_url() {
  local url="$1"
  [[ "$url" == /* || "$url" == ./* || "$url" == ../* || "$url" == file://* ]]
}

is_network_origin_url() {
  local url="$1"
  [[ "$url" == http://* || "$url" == https://* || "$url" == ssh://* || "$url" == git://* || "$url" == git@* ]]
}

while (($#)); do
  case "$1" in
    --skills-root)
      if (($# < 2)); then
        echo "missing value for --skills-root" >&2
        exit 2
      fi
      skills_root="$2"
      shift 2
      ;;
    --local-github-owners)
      if (($# < 2)); then
        echo "missing value for --local-github-owners" >&2
        exit 2
      fi
      local_github_owners="$2"
      shift 2
      ;;
    --strict)
      strict_mode=1
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$strict_mode" != "0" && "$strict_mode" != "1" ]]; then
  echo "OPENCLAW_DAILY_UPDATE_SKILLS_SYNC_STRICT must be 0 or 1" >&2
  exit 2
fi

if [[ ! -d "$skills_root" ]]; then
  printf 'status=skip\n'
  printf 'skills_root=%s\n' "$skills_root"
  printf 'total_dirs=0\n'
  printf 'git_repos=0\n'
  printf 'updated=0\n'
  printf 'unchanged=0\n'
  printf 'skipped=0\n'
  printf 'failed=0\n'
  printf 'details_begin\n'
  printf 'skills root missing; skipped\n'
  exit 0
fi

total_dirs=0
git_repos=0
external_targets=0
updated=0
unchanged=0
skipped=0
failed=0
details=()

shopt -s nullglob
for dir in "$skills_root"/*; do
  [[ -d "$dir" ]] || continue
  total_dirs=$((total_dirs + 1))
  name="$(basename "$dir")"

  if [[ ! -e "$dir/.git" ]]; then
    skipped=$((skipped + 1))
    details+=("${name}: skip (not a git repo)")
    continue
  fi

  git_repos=$((git_repos + 1))

  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    failed=$((failed + 1))
    details+=("${name}: fail (invalid git repo)")
    continue
  fi

  # Use raw configured URL to avoid `insteadOf` rewrite side effects.
  origin_url="$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)"
  if [[ -z "$origin_url" ]]; then
    skipped=$((skipped + 1))
    details+=("${name}: skip (no origin remote)")
    continue
  fi

  if is_local_origin_url "$origin_url"; then
    skipped=$((skipped + 1))
    details+=("${name}: skip (local git origin)")
    continue
  fi

  github_owner="$(extract_github_owner "$origin_url")"
  source_label=""
  if [[ -n "$github_owner" ]]; then
    if is_local_github_owner "$github_owner"; then
      skipped=$((skipped + 1))
      details+=("${name}: skip (local github owner: ${github_owner})")
      continue
    fi
    source_label="github:${github_owner}"
  elif [[ -f "$dir/.clawhub/origin.json" ]]; then
    source_label="clawhub"
  elif is_network_origin_url "$origin_url"; then
    source_label="external-git"
  else
    skipped=$((skipped + 1))
    details+=("${name}: skip (unsupported origin: ${origin_url})")
    continue
  fi

  if ! git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    skipped=$((skipped + 1))
    details+=("${name}: skip (no upstream tracking branch)")
    continue
  fi

  external_targets=$((external_targets + 1))
  before_head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo unknown)"

  set +e
  pull_out="$(git -C "$dir" pull --ff-only 2>&1)"
  pull_code=$?
  set -e

  if (( pull_code != 0 )); then
    failed=$((failed + 1))
    first_line="$(printf '%s\n' "$pull_out" | head -n1)"
    details+=("${name}: fail (${first_line})")
    continue
  fi

  after_head="$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [[ "$before_head" != "$after_head" ]]; then
    updated=$((updated + 1))
    details+=("${name}: updated (${source_label})")
  else
    unchanged=$((unchanged + 1))
    details+=("${name}: unchanged (${source_label})")
  fi
done

status="pass"
if (( failed > 0 )); then
  status="warn"
fi
if (( total_dirs == 0 )); then
  status="skip"
  details+=("skills root exists but no skill directories found")
fi

printf 'status=%s\n' "$status"
printf 'skills_root=%s\n' "$skills_root"
printf 'total_dirs=%d\n' "$total_dirs"
printf 'git_repos=%d\n' "$git_repos"
printf 'external_targets=%d\n' "$external_targets"
printf 'updated=%d\n' "$updated"
printf 'unchanged=%d\n' "$unchanged"
printf 'skipped=%d\n' "$skipped"
printf 'failed=%d\n' "$failed"
printf 'details_begin\n'
if ((${#details[@]} == 0)); then
  printf 'no details\n'
else
  for line in "${details[@]}"; do
    printf '%s\n' "$line"
  done
fi

if (( strict_mode == 1 && failed > 0 )); then
  exit 1
fi
