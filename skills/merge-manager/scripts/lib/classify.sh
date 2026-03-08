#!/usr/bin/env bash
# Risk classification helpers for merge-manager.
# Exposes a compatibility function reused by review-merge-main-cleanup.

merge_manager_shared_classify_branch() {
  local exec_dir="$1"
  local base="$2"
  local branch="$3"
  local reasons_file="$4"
  local binary_count_file="$5"
  local changed_count_file="$6"
  : > "$reasons_file"

  local changed_files
  changed_files="$(git -C "$exec_dir" diff --name-only "$base...$branch" || true)"
  local changed_count
  changed_count="$(printf '%s\n' "$changed_files" | sed '/^$/d' | wc -l | tr -d ' ')"
  printf '%s\n' "$changed_count" > "$changed_count_file"

  if printf '%s\n' "$changed_files" | grep -Eq '^(browser/openclaw/user-data/|memory/.*\.sqlite$|media/inbound/|workspace(/|$)|exec-approvals\.json$|delivery-queue/|run/|tmp/)'; then
    echo "运行态/缓存/数据库/媒体落地文件改动" >> "$reasons_file"
  fi

  if printf '%s\n' "$changed_files" | grep -Eq '(^|/)\.?.*\.lock($|\.)'; then
    echo "包含可疑锁文件改动" >> "$reasons_file"
  fi

  local binary_count
  binary_count="$(git -C "$exec_dir" diff --numstat "$base...$branch" | awk 'BEGIN{c=0} $1=="-" && $2=="-" {c++} END{print c+0}')"
  printf '%s\n' "$binary_count" > "$binary_count_file"
  if [[ "$binary_count" -gt 20 ]]; then
    echo "二进制改动数量过大(${binary_count})" >> "$reasons_file"
  fi

  local mb
  mb="$(git -C "$exec_dir" merge-base "$base" "$branch")"
  if git -C "$exec_dir" merge-tree "$mb" "$base" "$branch" | grep -q '^<<<<<<< '; then
    echo "合并冲突预测失败" >> "$reasons_file"
  fi
}

mm_classification_json() {
  local repo_root="$1"
  local base="$2"
  local branch="$3"
  local policy_file="$4"
  local reasons_file binary_count_file changed_count_file
  reasons_file="$(mktemp)"
  binary_count_file="$(mktemp)"
  changed_count_file="$(mktemp)"
  merge_manager_shared_classify_branch "$repo_root" "$base" "$branch" "$reasons_file" "$binary_count_file" "$changed_count_file"

  local changed_files age_days stale_days docs_only tests_only only_docs_tests has_high_risk_path risk_level category reason_count
  changed_files="$(git -C "$repo_root" diff --name-only "$base...$branch" || true)"
  age_days="$(python3 - "$repo_root" "$branch" <<'PY'
import subprocess, sys
from datetime import datetime, timezone
repo, branch = sys.argv[1:3]
iso = subprocess.check_output(['git', '-C', repo, 'log', '-1', '--format=%cI', branch], text=True).strip()
now = datetime.now(timezone.utc)
ts = datetime.fromisoformat(iso.replace('Z', '+00:00'))
print(max(0, (now - ts).days))
PY
)"
  stale_days="$(mm_policy_nested_scalar "$policy_file" classification_rules stale_branch_days 14)"
  docs_only=yes
  tests_only=yes
  has_high_risk_path=no
  category=business_logic
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    if [[ ! "$path" =~ ^(docs/|README|.*\.md$) ]]; then
      docs_only=no
    fi
    if [[ ! "$path" =~ ^(tests?/|test/|.*(_test|\.test)\.) ]]; then
      tests_only=no
    fi
    if [[ "$path" == .github/workflows/* || "$path" == migrations/* || "$path" == infra/* || "$path" == deploy/* || "$path" == auth/* || "$path" == billing/* ]]; then
      has_high_risk_path=yes
    fi
    if [[ "$path" != */* ]]; then
      case "$path" in
        *.json|*.toml|*.yaml|*.yml|*.rules|*.sh)
          has_high_risk_path=yes
          ;;
      esac
    fi
    if [[ "$path" =~ (^|/)(shared|core|foundation|lib)/ ]]; then
      category=foundation
    elif [[ "$category" != foundation && "$path" =~ (^|/)(schema|types|contracts|interface|api)/ ]]; then
      category=interface_support
    fi
  done <<< "$changed_files"
  only_docs_tests=no
  if [[ "$docs_only" == yes || "$tests_only" == yes ]]; then
    only_docs_tests=yes
    category=docs_tests
  fi

  reason_count="$(sed '/^$/d' "$reasons_file" | wc -l | tr -d ' ')"
  if [[ "$has_high_risk_path" == yes || "$reason_count" -gt 0 ]]; then
    risk_level=high
  elif [[ "$only_docs_tests" == yes || "$(cat "$changed_count_file")" -le 5 ]]; then
    risk_level=safe
  else
    risk_level=medium
  fi

  python3 - "$branch" "$risk_level" "$category" "$age_days" "$stale_days" "$docs_only" "$tests_only" "$has_high_risk_path" "$reasons_file" <<'PY'
import json, sys, pathlib
branch, risk_level, category, age_days, stale_days, docs_only, tests_only, has_high_risk_path, reasons_file = sys.argv[1:10]
reasons = [line.strip() for line in pathlib.Path(reasons_file).read_text(encoding='utf-8').splitlines() if line.strip()]
print(json.dumps({
  'branch': branch,
  'risk_level': risk_level,
  'category': category,
  'age_days': int(age_days),
  'stale_days': int(stale_days),
  'stale': int(age_days) > int(stale_days),
  'docs_only': docs_only == 'yes',
  'tests_only': tests_only == 'yes',
  'has_high_risk_path': has_high_risk_path == 'yes',
  'reasons': reasons,
}, ensure_ascii=False, indent=2))
PY

  rm -f "$reasons_file" "$binary_count_file" "$changed_count_file"
}
