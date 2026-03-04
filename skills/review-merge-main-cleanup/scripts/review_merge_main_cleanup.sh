#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  review_merge_main_cleanup.sh --report <abs-path> [--base main] [--cleanup local-only] [--mode auto] [--json]

Options:
  --base <branch>      Base branch to merge into (default: main)
  --cleanup <mode>     Cleanup mode, only local-only is supported
  --mode <mode>        Execution mode, only auto is supported
  --report <path>      Markdown report path (required)
  --json               Print JSON summary to stdout and write report-adjacent .json file
  -h, --help           Show help
USAGE
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

BASE="main"
CLEANUP="local-only"
MODE="auto"
REPORT_PATH=""
PRINT_JSON=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)
      [[ $# -ge 2 ]] || die "missing value for --base"
      BASE="$2"
      shift 2
      ;;
    --cleanup)
      [[ $# -ge 2 ]] || die "missing value for --cleanup"
      CLEANUP="$2"
      shift 2
      ;;
    --mode)
      [[ $# -ge 2 ]] || die "missing value for --mode"
      MODE="$2"
      shift 2
      ;;
    --report)
      [[ $# -ge 2 ]] || die "missing value for --report"
      REPORT_PATH="$2"
      shift 2
      ;;
    --json)
      PRINT_JSON=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$REPORT_PATH" ]] || die "--report is required"
[[ "$CLEANUP" == "local-only" ]] || die "--cleanup only supports local-only"
[[ "$MODE" == "auto" ]] || die "--mode only supports auto"

command -v git >/dev/null 2>&1 || die "git not found"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "current directory is not inside a git repository"
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
[[ -d "$REPO_ROOT" ]] || die "failed to resolve repository root"

git -C "$REPO_ROOT" rev-parse --verify "$BASE" >/dev/null 2>&1 || die "base branch not found: $BASE"

if [[ "$REPORT_PATH" != /* ]]; then
  REPORT_PATH="$(pwd)/$REPORT_PATH"
fi
REPORT_DIR="$(dirname "$REPORT_PATH")"
REPORT_FILE="$(basename "$REPORT_PATH")"
REPORT_PATH="$REPORT_DIR/$REPORT_FILE"

if [[ "$REPORT_PATH" == *.md ]]; then
  JSON_PATH="${REPORT_PATH%.md}.json"
else
  JSON_PATH="$REPORT_PATH.json"
fi

mkdir -p "$REPORT_DIR"

TMP_DIR="$(mktemp -d)"
COMMAND_LOG="$TMP_DIR/command.log"
MERGED_FILE="$TMP_DIR/merged.txt"
CLEANED_FILE="$TMP_DIR/cleaned.txt"
CLEAN_FAIL_FILE="$TMP_DIR/cleanup_fail.txt"
PRESERVED_FILE="$TMP_DIR/preserved.txt"
UNCERTAIN_INDEX="$TMP_DIR/uncertain.tsv"
UNCERTAIN_MD="$TMP_DIR/uncertain.md"

: > "$COMMAND_LOG"
: > "$MERGED_FILE"
: > "$CLEANED_FILE"
: > "$CLEAN_FAIL_FILE"
: > "$PRESERVED_FILE"
: > "$UNCERTAIN_INDEX"
: > "$UNCERTAIN_MD"

EXEC_DIR="$REPO_ROOT"
ISOLATION_NOTE="no"
CREATED_WORKTREE=""
BASE_WORKTREE_PATH=""

cleanup_tmp() {
  if [[ -n "$CREATED_WORKTREE" && -d "$CREATED_WORKTREE" ]]; then
    git -C "$REPO_ROOT" worktree remove -f "$CREATED_WORKTREE" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup_tmp EXIT

record_cmd() {
  printf '%s\n' "$*" >> "$COMMAND_LOG"
}

resolve_base_worktree() {
  local wt_path=""
  local wt_branch=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        wt_path="${line#worktree }"
        wt_branch=""
        ;;
      "branch refs/heads/"*)
        wt_branch="${line#branch refs/heads/}"
        if [[ "$wt_branch" == "$BASE" ]]; then
          printf '%s\n' "$wt_path"
          return 0
        fi
        ;;
    esac
  done < <(git -C "$REPO_ROOT" worktree list --porcelain)
  return 1
}

CURRENT_BRANCH="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || echo DETACHED)"
START_STATUS_SIG="$(git -C "$REPO_ROOT" status --porcelain=v1)"
START_HEAD_SIG="$(git -C "$REPO_ROOT" rev-parse HEAD)"
BASE_START_SHA="$(git -C "$REPO_ROOT" rev-parse "$BASE")"

if BASE_WORKTREE_PATH="$(resolve_base_worktree 2>/dev/null)"; then
  if [[ -n "$(git -C "$BASE_WORKTREE_PATH" status --porcelain=v1)" ]]; then
    die "base branch worktree is dirty: $BASE_WORKTREE_PATH"
  fi
  EXEC_DIR="$BASE_WORKTREE_PATH"
  ISOLATION_NOTE="yes (reuse existing base worktree: $BASE_WORKTREE_PATH)"
else
  if [[ -n "$START_STATUS_SIG" || "$CURRENT_BRANCH" != "$BASE" ]]; then
    CREATED_WORKTREE="$(mktemp -d "${TMPDIR:-/tmp}/review-merge-main-cleanup-worktree.XXXXXX")"
    record_cmd "git -C $REPO_ROOT worktree add $CREATED_WORKTREE $BASE"
    git -C "$REPO_ROOT" worktree add "$CREATED_WORKTREE" "$BASE" >/dev/null
    EXEC_DIR="$CREATED_WORKTREE"
    ISOLATION_NOTE="yes (created integration worktree: $CREATED_WORKTREE)"
  fi
fi

record_cmd "git -C $REPO_ROOT for-each-ref --format=%(refname:short) refs/heads"
BRANCH_ORDER_FILE="$TMP_DIR/branch_order.tsv"
: > "$BRANCH_ORDER_FILE"

while IFS= read -r branch; do
  [[ -n "$branch" ]] || continue
  [[ "$branch" == "$BASE" ]] && continue
  ahead_count="$(git -C "$EXEC_DIR" rev-list --count "$BASE..$branch" 2>/dev/null || echo 0)"
  printf '%s\t%s\n' "$ahead_count" "$branch" >> "$BRANCH_ORDER_FILE"
done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' refs/heads)

sort -n "$BRANCH_ORDER_FILE" -o "$BRANCH_ORDER_FILE"

classify_branch() {
  local branch="$1"
  local reasons_file="$2"
  local binary_count_file="$3"
  local changed_count_file="$4"
  : > "$reasons_file"

  local changed_files
  changed_files="$(git -C "$EXEC_DIR" diff --name-only "$BASE...$branch" || true)"

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
  binary_count="$(git -C "$EXEC_DIR" diff --numstat "$BASE...$branch" | awk 'BEGIN{c=0} $1=="-" && $2=="-" {c++} END{print c+0}')"
  printf '%s\n' "$binary_count" > "$binary_count_file"
  if [[ "$binary_count" -gt 20 ]]; then
    echo "二进制改动数量过大(${binary_count})" >> "$reasons_file"
  fi

  local mb
  mb="$(git -C "$EXEC_DIR" merge-base "$BASE" "$branch")"
  if git -C "$EXEC_DIR" merge-tree "$mb" "$BASE" "$branch" | grep -q '^<<<<<<< '; then
    echo "合并冲突预测失败" >> "$reasons_file"
  fi
}

while IFS=$'\t' read -r _ahead branch; do
  [[ -n "$branch" ]] || continue

  if git -C "$EXEC_DIR" merge-base --is-ancestor "$branch" "$BASE"; then
    continue
  fi

  reasons_file="$TMP_DIR/reasons.$$.txt"
  binary_count_file="$TMP_DIR/binary.$$.txt"
  changed_count_file="$TMP_DIR/changed.$$.txt"

  classify_branch "$branch" "$reasons_file" "$binary_count_file" "$changed_count_file"

  reason_count="$(sed '/^$/d' "$reasons_file" | wc -l | tr -d ' ')"
  binary_count="$(cat "$binary_count_file")"
  changed_count="$(cat "$changed_count_file")"
  commit_count="$(git -C "$EXEC_DIR" rev-list --count "$BASE..$branch")"

  if [[ "$reason_count" -gt 0 ]]; then
    reasons_joined="$(awk 'NF{printf("%s%s", sep, $0); sep="; "}' "$reasons_file")"
    suggestion="建议人工审计后再决定 merge/cherry-pick；当前流程自动保留该分支。"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$branch" "high" "$reasons_joined" "$suggestion" "$changed_count" "$commit_count" >> "$UNCERTAIN_INDEX"

    {
      echo "### $branch"
      echo "- 风险等级: high"
      echo "- 风险原因: $reasons_joined"
      echo "- 建议: $suggestion"
      echo "- 提交数量: $commit_count"
      echo "- 文件变更数量: $changed_count"
      echo "- 二进制变更数量: $binary_count"
      echo
      echo "#### 提交列表"
      git -C "$EXEC_DIR" log --oneline "$BASE..$branch" | sed 's/^/- /'
      echo
      echo "#### 文件改动摘要 (name-status)"
      git -C "$EXEC_DIR" diff --name-status "$BASE...$branch" | sed 's/^/- /'
      echo
    } >> "$UNCERTAIN_MD"

    continue
  fi

  record_cmd "git -C $EXEC_DIR merge --no-ff --no-edit $branch"
  if merge_output="$(git -C "$EXEC_DIR" merge --no-ff --no-edit "$branch" 2>&1)"; then
    printf '%s\n' "$branch" >> "$MERGED_FILE"
    printf '[OK] merge %s: %s\n' "$branch" "$(printf '%s' "$merge_output" | tail -n 1)" >> "$COMMAND_LOG"
  else
    git -C "$EXEC_DIR" merge --abort >/dev/null 2>&1 || true
    reasons_joined="实际 merge 失败，已自动 abort。"
    suggestion="建议人工处理冲突或拆分提交后再合并。"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$branch" "high" "$reasons_joined" "$suggestion" "$changed_count" "$commit_count" >> "$UNCERTAIN_INDEX"

    {
      echo "### $branch"
      echo "- 风险等级: high"
      echo "- 风险原因: $reasons_joined"
      echo "- 建议: $suggestion"
      echo "- 提交数量: $commit_count"
      echo "- 文件变更数量: $changed_count"
      echo
      echo "#### merge 失败输出"
      echo '```text'
      echo "$merge_output"
      echo '```'
      echo
      echo "#### 提交列表"
      git -C "$EXEC_DIR" log --oneline "$BASE..$branch" | sed 's/^/- /'
      echo
      echo "#### 文件改动摘要 (name-status)"
      git -C "$EXEC_DIR" diff --name-status "$BASE...$branch" | sed 's/^/- /'
      echo
    } >> "$UNCERTAIN_MD"

    printf '[FAIL] merge %s: aborted\n' "$branch" >> "$COMMAND_LOG"
  fi

done < "$BRANCH_ORDER_FILE"

# Cleanup merged local branches only.
while IFS= read -r branch; do
  [[ -n "$branch" ]] || continue
  [[ "$branch" == "$BASE" ]] && continue

  if git -C "$REPO_ROOT" merge-base --is-ancestor "$branch" "$BASE"; then
    record_cmd "git -C $EXEC_DIR branch -d $branch"
    if cleanup_output="$(git -C "$EXEC_DIR" branch -d "$branch" 2>&1)"; then
      printf '%s\n' "$branch" >> "$CLEANED_FILE"
      printf '[OK] cleanup %s: %s\n' "$branch" "$(printf '%s' "$cleanup_output" | tail -n 1)" >> "$COMMAND_LOG"
    else
      cleanup_reason="$(printf '%s' "$cleanup_output" | tr '\n' ' ' | sed 's/[[:space:]]\\+/ /g' | sed 's/^ //; s/ $//')"
      printf '%s\t%s\n' "$branch" "$cleanup_reason" >> "$CLEAN_FAIL_FILE"
      printf '[FAIL] cleanup %s\n' "$branch" >> "$COMMAND_LOG"
    fi
  fi
done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' refs/heads)

# Preserved (final unmerged) branches.
while IFS= read -r branch; do
  [[ -n "$branch" ]] || continue
  [[ "$branch" == "$BASE" ]] && continue
  if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$branch" "$BASE"; then
    printf '%s\n' "$branch" >> "$PRESERVED_FILE"
  fi
done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' refs/heads)

END_STATUS_SIG="$(git -C "$REPO_ROOT" status --porcelain=v1)"
END_HEAD_SIG="$(git -C "$REPO_ROOT" rev-parse HEAD)"
BASE_END_SHA="$(git -C "$REPO_ROOT" rev-parse "$BASE")"
DRIFT_DETECTED="no"
if [[ "$START_STATUS_SIG" != "$END_STATUS_SIG" ]]; then
  DRIFT_DETECTED="yes"
fi

NOW_TS="$(date '+%Y-%m-%d %H:%M:%S %Z')"

{
  echo "# 分支收敛报告"
  echo
  echo "- 时间: $NOW_TS"
  echo "- 仓库: $REPO_ROOT"
  echo "- 基线分支: $BASE"
  echo "- 执行模式: $MODE"
  echo "- 清理范围: $CLEANUP"
  echo "- 隔离执行: $ISOLATION_NOTE"
  echo "- 基线起始提交: $BASE_START_SHA"
  echo "- 基线结束提交: $BASE_END_SHA"
  echo
  echo "## 已合并分支"
  if [[ -s "$MERGED_FILE" ]]; then
    sed 's/^/- /' "$MERGED_FILE"
  else
    echo "- 无"
  fi
  echo
  echo "## 已清理本地分支"
  if [[ -s "$CLEANED_FILE" ]]; then
    sed 's/^/- /' "$CLEANED_FILE"
  else
    echo "- 无"
  fi
  echo
  if [[ -s "$CLEAN_FAIL_FILE" ]]; then
    echo "### 清理失败"
    while IFS=$'\t' read -r b reason; do
      echo "- $b"
      echo '```text'
      echo "$reason"
      echo '```'
    done < "$CLEAN_FAIL_FILE"
    echo
  fi
  echo "## 不确定分支完整审计"
  if [[ -s "$UNCERTAIN_MD" ]]; then
    cat "$UNCERTAIN_MD"
  else
    echo "- 无"
    echo
  fi
  echo "## 保留未合并分支"
  if [[ -s "$PRESERVED_FILE" ]]; then
    sed 's/^/- /' "$PRESERVED_FILE"
  else
    echo "- 无"
  fi
  echo
  echo "## 执行命令与关键结果"
  if [[ -s "$COMMAND_LOG" ]]; then
    sed 's/^/- /' "$COMMAND_LOG"
  else
    echo "- 无"
  fi
  echo
  echo "## 漂移检查"
  echo "- 开始 HEAD: $START_HEAD_SIG"
  echo "- 结束 HEAD: $END_HEAD_SIG"
  echo "- 工作区状态签名变化: $DRIFT_DETECTED"
} > "$REPORT_PATH"

python3 - "$TMP_DIR" "$REPO_ROOT" "$BASE" "$MODE" "$CLEANUP" "$REPORT_PATH" "$JSON_PATH" "$ISOLATION_NOTE" "$BASE_START_SHA" "$BASE_END_SHA" "$DRIFT_DETECTED" "$PRINT_JSON" <<'PY'
import json
import os
import sys
from datetime import datetime

tmp_dir, repo_root, base, mode, cleanup, report_path, json_path, isolation_note, base_start_sha, base_end_sha, drift, print_json = sys.argv[1:13]


def read_list(path):
    if not os.path.exists(path):
        return []
    out = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(line)
    return out


uncertain = []
uncertain_tsv = os.path.join(tmp_dir, "uncertain.tsv")
if os.path.exists(uncertain_tsv):
    with open(uncertain_tsv, "r", encoding="utf-8") as f:
        for raw in f:
            raw = raw.rstrip("\n")
            if not raw:
                continue
            parts = raw.split("\t")
            if len(parts) < 6:
                continue
            branch, risk, reasons, suggestion, changed_count, commit_count = parts[:6]
            uncertain.append(
                {
                    "branch": branch,
                    "risk": risk,
                    "reasons": [x.strip() for x in reasons.split(";") if x.strip()],
                    "suggestion": suggestion,
                    "changed_file_count": int(changed_count or 0),
                    "commit_count": int(commit_count or 0),
                }
            )

cleanup_failures = []
cleanup_fail_tsv = os.path.join(tmp_dir, "cleanup_fail.txt")
if os.path.exists(cleanup_fail_tsv):
    with open(cleanup_fail_tsv, "r", encoding="utf-8") as f:
        for raw in f:
            raw = raw.rstrip("\n")
            if not raw:
                continue
            if "\t" in raw:
                branch, reason = raw.split("\t", 1)
            else:
                branch, reason = raw, ""
            cleanup_failures.append({"branch": branch, "reason": reason})

result = {
    "generated_at": datetime.now().isoformat(),
    "repository": repo_root,
    "base": base,
    "mode": mode,
    "cleanup": cleanup,
    "isolation": isolation_note,
    "base_start_sha": base_start_sha,
    "base_end_sha": base_end_sha,
    "drift_detected": drift,
    "merged_branches": read_list(os.path.join(tmp_dir, "merged.txt")),
    "cleaned_branches": read_list(os.path.join(tmp_dir, "cleaned.txt")),
    "cleanup_failures": cleanup_failures,
    "uncertain_branches": uncertain,
    "preserved_unmerged_branches": read_list(os.path.join(tmp_dir, "preserved.txt")),
    "report_markdown": report_path,
}

with open(json_path, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)

if print_json == "1":
    print(json.dumps(result, ensure_ascii=False, indent=2))
PY

if [[ "$DRIFT_DETECTED" == "yes" ]]; then
  echo "[WARN] unexpected workspace status drift detected. Please review: $REPORT_PATH" >&2
  exit 2
fi

echo "[OK] report: $REPORT_PATH"
echo "[OK] json: $JSON_PATH"
