#!/usr/bin/env bash
# Codex notify hook: auto-commit git changes after each completed agent turn.

set -euo pipefail

payload="${1:-}"
if [[ -z "${payload}" ]]; then
  exit 0
fi

log_file="${HOME}/.codex/hooks/auto-commit.log"
mkdir -p "$(dirname "${log_file}")"

log() {
  local msg="$1"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${msg}" >>"${log_file}" 2>/dev/null || true
}

event="$(printf '%s' "${payload}" | jq -r '.event // empty' 2>/dev/null || true)"
if [[ "${event}" != "agent-turn-complete" ]]; then
  exit 0
fi

cwd="$(printf '%s' "${payload}" | jq -r '.cwd // empty' 2>/dev/null || true)"
if [[ -z "${cwd}" || ! -d "${cwd}" ]]; then
  exit 0
fi

if ! git -C "${cwd}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

repo_root="$(git -C "${cwd}" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${repo_root}" ]]; then
  exit 0
fi

lock_dir="${repo_root}/.git/.codex-auto-commit.lock"
if ! mkdir "${lock_dir}" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "${lock_dir}" >/dev/null 2>&1 || true' EXIT

if git -C "${repo_root}" diff --quiet \
  && git -C "${repo_root}" diff --cached --quiet \
  && [[ -z "$(git -C "${repo_root}" ls-files --others --exclude-standard)" ]]; then
  exit 0
fi

declare -a files=()
declare -a safe_files=()

while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  path="${line:3}"
  if [[ "${path}" == *" -> "* ]]; then
    path="${path##* -> }"
  fi
  files+=("${path}")
done < <(git -C "${repo_root}" status --porcelain)

if [[ ${#files[@]} -eq 0 ]]; then
  exit 0
fi

for path in "${files[@]}"; do
  case "${path}" in
  *.bak-* | *.html.bak-* | .DS_Store | */.DS_Store | node_modules/* | */node_modules/*)
    continue
    ;;
  .env | .env.* | *.pem | *.key | id_rsa | id_ed25519)
    log "skip commit in ${repo_root}: sensitive file detected (${path})"
    exit 0
    ;;
  esac
  safe_files+=("${path}")
done

if [[ ${#safe_files[@]} -eq 0 ]]; then
  exit 0
fi

git -C "${repo_root}" add -- "${safe_files[@]}" >/dev/null 2>&1 || {
  log "git add failed in ${repo_root}"
  exit 0
}

if git -C "${repo_root}" diff --cached --quiet; then
  exit 0
fi

derive_topic() {
  local first_path="$1"
  local top=""
  local base=""

  if [[ "${first_path}" =~ ^posts/[0-9]{4}-[0-9]{2}-[0-9]{2}/([^/]+)/ ]]; then
    echo "文章 ${BASH_REMATCH[1]}"
    return
  fi
  if [[ "${first_path}" =~ ^\.agents/skills/([^/]+)/ ]]; then
    echo "技能 ${BASH_REMATCH[1]}"
    return
  fi
  if [[ "${first_path}" =~ ^\.codex/skills/([^/]+)/ ]]; then
    echo "技能 ${BASH_REMATCH[1]}"
    return
  fi
  if [[ "${first_path}" =~ ^\.codex/AGENTS\.md$ ]]; then
    echo "全局规则"
    return
  fi

  top="${first_path%%/*}"
  if [[ "${top}" == "${first_path}" ]]; then
    base="${first_path##*/}"
    echo "${base%.*}"
    return
  fi
  echo "${top}"
}

action="更新"
status_lines="$(git -C "${repo_root}" status --porcelain)"
if [[ -n "${status_lines}" ]]; then
  all_new="true"
  all_deleted="true"
  while IFS= read -r status_line; do
    [[ -z "${status_line}" ]] && continue
    status="${status_line:0:2}"
    if [[ "${status}" != "??" ]]; then
      all_new="false"
    fi
    if [[ "${status:0:1}" != "D" && "${status:1:1}" != "D" ]]; then
      all_deleted="false"
    fi
  done <<<"${status_lines}"

  if [[ "${all_new}" == "true" ]]; then
    action="添加"
  elif [[ "${all_deleted}" == "true" ]]; then
    action="删除"
  fi
fi

topic="$(derive_topic "${safe_files[0]}")"
message="${action} ${topic}（Codex 自动提交）"

if git -C "${repo_root}" commit -m "${message}" >/dev/null 2>&1; then
  sha="$(git -C "${repo_root}" rev-parse --short HEAD 2>/dev/null || true)"
  log "committed ${sha} in ${repo_root}: ${message}"
else
  log "git commit failed in ${repo_root}"
fi

exit 0
