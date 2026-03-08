#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MERGE_MANAGER_SHARED_CLASSIFY="$SCRIPT_DIR/../../merge-manager/scripts/lib/classify.sh"

if [[ -f "$MERGE_MANAGER_SHARED_CLASSIFY" ]]; then
  # Shared read-only classification core from merge-manager.
  # MVP boundary: only reuse read-only risk classification; keep merge/cleanup execution unchanged.
  source "$MERGE_MANAGER_SHARED_CLASSIFY"
fi

usage() {
  cat <<'USAGE'
Usage:
  review_merge_main_cleanup.sh --report <abs-path> [--base main] [--cleanup plan-only|archive|local-only] [--mode auto] [--json]
                               [--branches-file <abs-path>] [--branch-pattern <glob>] [--max-branches <N>]
                               [--approval-file <abs-path>] [--require-approval]
                               [--pre-test '<cmd>'] [--post-test '<cmd>'] [--require-tests]
                               [--archive-prefix <ref-prefix>] [--confirm-cleanup <token>]

Options:
  --base <branch>          Base branch to merge into (default: main)
  --cleanup <mode>         Cleanup mode: plan-only|archive|local-only (default: local-only)
  --mode <mode>            Execution mode, only auto is supported
  --report <path>          Markdown report path (required)
  --json                   Print JSON summary to stdout and write report-adjacent .json file
  --branches-file <path>   Explicit branch list file (one branch per line)
  --branch-pattern <glob>  Branch glob filter when branches-file is absent
  --max-branches <N>       Fail if selected target branches exceed N
  --approval-file <path>   JSON approvals file
  --require-approval       Require branch in approval file to be merge-eligible
  --pre-test <cmd>         Command run once before merge loop
  --post-test <cmd>        Command run after each successful merge
  --require-tests          Require both pre-test and post-test to be provided
  --archive-prefix <ref>   Archive ref prefix for cleanup=archive
  --confirm-cleanup <tok>  Cleanup confirmation token, compared with run token
  -h, --help               Show help
USAGE
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

warn() {
  echo "[WARN] $*" >&2
  printf '%s\n' "$*" >> "$WARNINGS_FILE"
}

record_cmd() {
  printf '%s\n' "$*" >> "$COMMAND_LOG"
}

BASE="main"
CLEANUP="local-only"
MODE="auto"
REPORT_PATH=""
PRINT_JSON=0

BRANCHES_FILE=""
BRANCH_PATTERN=""
MAX_BRANCHES=""

APPROVAL_FILE=""
REQUIRE_APPROVAL=0

PRE_TEST_CMD=""
POST_TEST_CMD=""
REQUIRE_TESTS=0

ARCHIVE_PREFIX="refs/archive/review-merge-main-cleanup"
CONFIRM_CLEANUP=""

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
    --branches-file)
      [[ $# -ge 2 ]] || die "missing value for --branches-file"
      BRANCHES_FILE="$2"
      shift 2
      ;;
    --branch-pattern)
      [[ $# -ge 2 ]] || die "missing value for --branch-pattern"
      BRANCH_PATTERN="$2"
      shift 2
      ;;
    --max-branches)
      [[ $# -ge 2 ]] || die "missing value for --max-branches"
      MAX_BRANCHES="$2"
      shift 2
      ;;
    --approval-file)
      [[ $# -ge 2 ]] || die "missing value for --approval-file"
      APPROVAL_FILE="$2"
      shift 2
      ;;
    --require-approval)
      REQUIRE_APPROVAL=1
      shift
      ;;
    --pre-test)
      [[ $# -ge 2 ]] || die "missing value for --pre-test"
      PRE_TEST_CMD="$2"
      shift 2
      ;;
    --post-test)
      [[ $# -ge 2 ]] || die "missing value for --post-test"
      POST_TEST_CMD="$2"
      shift 2
      ;;
    --require-tests)
      REQUIRE_TESTS=1
      shift
      ;;
    --archive-prefix)
      [[ $# -ge 2 ]] || die "missing value for --archive-prefix"
      ARCHIVE_PREFIX="$2"
      shift 2
      ;;
    --confirm-cleanup)
      [[ $# -ge 2 ]] || die "missing value for --confirm-cleanup"
      CONFIRM_CLEANUP="$2"
      shift 2
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
[[ "$MODE" == "auto" ]] || die "--mode only supports auto"
case "$CLEANUP" in
  plan-only|archive|local-only) ;;
  *) die "--cleanup only supports plan-only|archive|local-only" ;;
esac

if [[ -n "$MAX_BRANCHES" ]] && ! [[ "$MAX_BRANCHES" =~ ^[0-9]+$ ]]; then
  die "--max-branches must be a non-negative integer"
fi

if [[ "$REQUIRE_TESTS" -eq 1 ]] && ([[ -z "$PRE_TEST_CMD" ]] || [[ -z "$POST_TEST_CMD" ]]); then
  die "--require-tests requires both --pre-test and --post-test"
fi

if [[ "$REQUIRE_APPROVAL" -eq 1 ]] && [[ -z "$APPROVAL_FILE" ]]; then
  die "--require-approval requires --approval-file"
fi

command -v git >/dev/null 2>&1 || die "git not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

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
CLEANUP_CANDIDATES_FILE="$TMP_DIR/cleanup_candidates.txt"
PRESERVED_FILE="$TMP_DIR/preserved.txt"
UNCERTAIN_INDEX="$TMP_DIR/uncertain.tsv"
UNCERTAIN_MD="$TMP_DIR/uncertain.md"
TARGET_BRANCHES_FILE="$TMP_DIR/target_branches.txt"
ORDERED_TARGET_FILE="$TMP_DIR/ordered_target.tsv"
APPROVED_BRANCHES_FILE="$TMP_DIR/approved_branches.txt"
APPROVAL_META_FILE="$TMP_DIR/approval_meta.txt"
BLOCKED_BY_GATE_FILE="$TMP_DIR/blocked_by_gate.tsv"
ARCHIVE_REFS_FILE="$TMP_DIR/archive_refs.txt"
WARNINGS_FILE="$TMP_DIR/warnings.txt"
TEST_LOG_FILE="$TMP_DIR/test_log.txt"

: > "$COMMAND_LOG"
: > "$MERGED_FILE"
: > "$CLEANED_FILE"
: > "$CLEAN_FAIL_FILE"
: > "$CLEANUP_CANDIDATES_FILE"
: > "$PRESERVED_FILE"
: > "$UNCERTAIN_INDEX"
: > "$UNCERTAIN_MD"
: > "$TARGET_BRANCHES_FILE"
: > "$ORDERED_TARGET_FILE"
: > "$APPROVED_BRANCHES_FILE"
: > "$APPROVAL_META_FILE"
: > "$BLOCKED_BY_GATE_FILE"
: > "$ARCHIVE_REFS_FILE"
: > "$WARNINGS_FILE"
: > "$TEST_LOG_FILE"

EXEC_DIR="$REPO_ROOT"
ISOLATION_NOTE="no"
CREATED_WORKTREE=""
BASE_WORKTREE_PATH=""

GATE_STOP_REASON=""
GATE_STOP_KIND=""
GATE_EXIT_CODE=0
PRE_TEST_PASSED="not-run"
CLEANUP_CONFIRM_STATUS="not-applicable"
APPROVAL_LOADED="no"
APPROVAL_PARSE_ERROR=""
APPROVAL_REVIEWER=""
APPROVAL_APPROVED_AT=""
TARGET_SCOPE=""
RUN_TOKEN=""

set_gate_stop() {
  local kind="$1"
  local reason="$2"
  local code="${3:-3}"
  if [[ -z "$GATE_STOP_REASON" ]]; then
    GATE_STOP_KIND="$kind"
    GATE_STOP_REASON="$reason"
    GATE_EXIT_CODE="$code"
  fi
}

append_blocked_gate() {
  local gate="$1"
  local branch="$2"
  local reason="$3"
  printf '%s\t%s\t%s\n' "$gate" "$branch" "$reason" >> "$BLOCKED_BY_GATE_FILE"
}

cleanup_tmp() {
  if [[ -n "$CREATED_WORKTREE" && -d "$CREATED_WORKTREE" ]]; then
    git -C "$REPO_ROOT" worktree remove -f "$CREATED_WORKTREE" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup_tmp EXIT

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

add_uncertain_bundle() {
  local branch="$1"
  local risk="$2"
  local reason="$3"
  local suggestion="$4"
  local changed_count="$5"
  local commit_count="$6"
  local binary_count="$7"

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$branch" "$risk" "$reason" "$suggestion" "$changed_count" "$commit_count" >> "$UNCERTAIN_INDEX"

  {
    echo "### $branch"
    echo "- 风险等级: $risk"
    echo "- 风险原因: $reason"
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
}

load_target_branches() {
  local count=0
  if [[ -n "$BRANCHES_FILE" ]]; then
    [[ -f "$BRANCHES_FILE" ]] || die "--branches-file not found: $BRANCHES_FILE"
    TARGET_SCOPE="branches-file:$BRANCHES_FILE"
    while IFS= read -r raw; do
      branch="$(printf '%s' "$raw" | sed 's/^\s*//;s/\s*$//')"
      [[ -z "$branch" ]] && continue
      [[ "$branch" =~ ^# ]] && continue
      [[ "$branch" == "$BASE" ]] && continue
      if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
        printf '%s\n' "$branch" >> "$TARGET_BRANCHES_FILE"
      else
        warn "branch from --branches-file not found locally: $branch"
      fi
    done < "$BRANCHES_FILE"
  elif [[ -n "$BRANCH_PATTERN" ]]; then
    TARGET_SCOPE="branch-pattern:$BRANCH_PATTERN"
    while IFS= read -r branch; do
      [[ -z "$branch" ]] && continue
      [[ "$branch" == "$BASE" ]] && continue
      if [[ "$branch" == $BRANCH_PATTERN ]]; then
        printf '%s\n' "$branch" >> "$TARGET_BRANCHES_FILE"
      fi
    done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' refs/heads)
  else
    TARGET_SCOPE="all-local-branches"
    while IFS= read -r branch; do
      [[ -z "$branch" ]] && continue
      [[ "$branch" == "$BASE" ]] && continue
      printf '%s\n' "$branch" >> "$TARGET_BRANCHES_FILE"
    done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' refs/heads)
  fi

  if [[ -s "$TARGET_BRANCHES_FILE" ]]; then
    sort -u "$TARGET_BRANCHES_FILE" -o "$TARGET_BRANCHES_FILE"
  fi

  count="$(wc -l < "$TARGET_BRANCHES_FILE" | tr -d ' ')"
  if [[ -n "$MAX_BRANCHES" ]] && [[ "$count" -gt "$MAX_BRANCHES" ]]; then
    die "target branch count $count exceeds --max-branches $MAX_BRANCHES"
  fi

  while IFS= read -r branch; do
    [[ -n "$branch" ]] || continue
    ahead_count="$(git -C "$EXEC_DIR" rev-list --count "$BASE..$branch" 2>/dev/null || echo 0)"
    printf '%s\t%s\n' "$ahead_count" "$branch" >> "$ORDERED_TARGET_FILE"
  done < "$TARGET_BRANCHES_FILE"

  if [[ -s "$ORDERED_TARGET_FILE" ]]; then
    sort -n "$ORDERED_TARGET_FILE" -o "$ORDERED_TARGET_FILE"
  fi
}

load_approvals() {
  if [[ -z "$APPROVAL_FILE" ]]; then
    return 0
  fi

  if [[ ! -f "$APPROVAL_FILE" ]]; then
    APPROVAL_PARSE_ERROR="approval file not found: $APPROVAL_FILE"
    if [[ "$REQUIRE_APPROVAL" -eq 1 ]]; then
      set_gate_stop "approval_gate" "$APPROVAL_PARSE_ERROR" 4
    else
      warn "$APPROVAL_PARSE_ERROR"
    fi
    return 0
  fi

  if python3 - "$APPROVAL_FILE" "$APPROVED_BRANCHES_FILE" "$APPROVAL_META_FILE" <<'PY'
import json
import sys

src, out_branches, out_meta = sys.argv[1:4]
with open(src, 'r', encoding='utf-8') as f:
    data = json.load(f)

if not isinstance(data, dict):
    raise SystemExit('approval file must be a JSON object')

branches = data.get('approved_branches', [])
if not isinstance(branches, list):
    raise SystemExit('approved_branches must be an array')

reviewer = data.get('reviewer', '')
approved_at = data.get('approved_at', '')

with open(out_branches, 'w', encoding='utf-8') as f:
    for item in branches:
        if isinstance(item, str) and item.strip():
            f.write(item.strip() + '\n')

with open(out_meta, 'w', encoding='utf-8') as f:
    f.write(f"{reviewer}\t{approved_at}\n")
PY
  then
    APPROVAL_LOADED="yes"
    if [[ -s "$APPROVED_BRANCHES_FILE" ]]; then
      sort -u "$APPROVED_BRANCHES_FILE" -o "$APPROVED_BRANCHES_FILE"
    fi
    if [[ -s "$APPROVAL_META_FILE" ]]; then
      IFS=$'\t' read -r APPROVAL_REVIEWER APPROVAL_APPROVED_AT < "$APPROVAL_META_FILE" || true
    fi
  else
    APPROVAL_PARSE_ERROR="failed to parse approval file: $APPROVAL_FILE"
    if [[ "$REQUIRE_APPROVAL" -eq 1 ]]; then
      set_gate_stop "approval_gate" "$APPROVAL_PARSE_ERROR" 4
    else
      warn "$APPROVAL_PARSE_ERROR"
    fi
  fi
}

is_branch_approved() {
  local branch="$1"
  [[ -s "$APPROVED_BRANCHES_FILE" ]] || return 1
  grep -Fxq "$branch" "$APPROVED_BRANCHES_FILE"
}

classify_branch() {
  local branch="$1"
  local reasons_file="$2"
  local binary_count_file="$3"
  local changed_count_file="$4"
  if declare -F merge_manager_shared_classify_branch >/dev/null 2>&1; then
    merge_manager_shared_classify_branch "$EXEC_DIR" "$BASE" "$branch" "$reasons_file" "$binary_count_file" "$changed_count_file"
    return 0
  fi

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

run_one_test() {
  local test_kind="$1"
  local test_cmd="$2"
  local out_file="$3"

  [[ -n "$test_cmd" ]] || return 0
  record_cmd "(cd $EXEC_DIR && $test_cmd)"
  if bash -lc "cd \"$EXEC_DIR\" && $test_cmd" >"$out_file" 2>&1; then
    return 0
  fi
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

load_target_branches

RUN_TOKEN="$(
  {
    printf '%s\n' "$REPO_ROOT" "$BASE" "$TARGET_SCOPE"
    cat "$TARGET_BRANCHES_FILE"
  } | shasum | awk '{print substr($1,1,16)}'
)"

load_approvals

if [[ "$REQUIRE_TESTS" -eq 1 ]] && ([[ -z "$PRE_TEST_CMD" ]] || [[ -z "$POST_TEST_CMD" ]]); then
  set_gate_stop "test_gate" "require-tests enabled but pre/post tests not fully configured" 5
fi

if [[ -z "$GATE_STOP_REASON" ]] && [[ -n "$PRE_TEST_CMD" ]]; then
  PRE_TEST_OUTPUT="$TMP_DIR/pre_test.out"
  if run_one_test "pre" "$PRE_TEST_CMD" "$PRE_TEST_OUTPUT"; then
    PRE_TEST_PASSED="yes"
    {
      echo "[pre-test] PASS"
      cat "$PRE_TEST_OUTPUT"
      echo
    } >> "$TEST_LOG_FILE"
  else
    PRE_TEST_PASSED="no"
    {
      echo "[pre-test] FAIL"
      cat "$PRE_TEST_OUTPUT"
      echo
    } >> "$TEST_LOG_FILE"
    append_blocked_gate "test_gate" "*pre*" "pre-test failed"
    set_gate_stop "test_gate" "pre-test failed" 5
  fi
fi

if [[ -z "$GATE_STOP_REASON" ]]; then
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

    if [[ "$REQUIRE_APPROVAL" -eq 1 ]] && ! is_branch_approved "$branch"; then
      reason="审批门禁未通过：分支未出现在 approved_branches"
      suggestion="请先通过 Pre-Merge 审核并更新 approval-file，再执行自动合并。"
      add_uncertain_bundle "$branch" "high" "$reason" "$suggestion" "$changed_count" "$commit_count" "$binary_count"
      append_blocked_gate "approval_gate" "$branch" "$reason"
      continue
    fi

    if [[ "$reason_count" -gt 0 ]]; then
      reasons_joined="$(awk 'NF{printf("%s%s", sep, $0); sep="; "}' "$reasons_file")"
      suggestion="建议人工审计后再决定 merge/cherry-pick；当前流程自动保留该分支。"
      add_uncertain_bundle "$branch" "high" "$reasons_joined" "$suggestion" "$changed_count" "$commit_count" "$binary_count"
      append_blocked_gate "risk_gate" "$branch" "$reasons_joined"
      continue
    fi

    record_cmd "git -C $EXEC_DIR merge --no-ff --no-edit $branch"
    if merge_output="$(git -C "$EXEC_DIR" merge --no-ff --no-edit "$branch" 2>&1)"; then
      if [[ -n "$POST_TEST_CMD" ]]; then
        safe_branch="${branch//\//__}"
        safe_branch="${safe_branch//:/__}"
        POST_TEST_OUTPUT="$TMP_DIR/post_test.${safe_branch}.out"
        if run_one_test "post" "$POST_TEST_CMD" "$POST_TEST_OUTPUT"; then
          {
            echo "[post-test:$branch] PASS"
            cat "$POST_TEST_OUTPUT"
            echo
          } >> "$TEST_LOG_FILE"
          printf '%s\n' "$branch" >> "$MERGED_FILE"
          printf '[OK] merge %s: %s\n' "$branch" "$(printf '%s' "$merge_output" | tail -n 1)" >> "$COMMAND_LOG"
        else
          record_cmd "git -C $EXEC_DIR reset --hard ORIG_HEAD"
          git -C "$EXEC_DIR" reset --hard ORIG_HEAD >/dev/null 2>&1 || true
          {
            echo "[post-test:$branch] FAIL"
            cat "$POST_TEST_OUTPUT"
            echo
          } >> "$TEST_LOG_FILE"
          reason="post-test failed，已回滚本次 merge"
          suggestion="修复测试失败后重试；该分支已转入不确定审计。"
          add_uncertain_bundle "$branch" "high" "$reason" "$suggestion" "$changed_count" "$commit_count" "$binary_count"
          append_blocked_gate "test_gate" "$branch" "$reason"
          printf '[FAIL] merge %s: post-test failed and reset ORIG_HEAD\n' "$branch" >> "$COMMAND_LOG"
        fi
      else
        printf '%s\n' "$branch" >> "$MERGED_FILE"
        printf '[OK] merge %s: %s\n' "$branch" "$(printf '%s' "$merge_output" | tail -n 1)" >> "$COMMAND_LOG"
      fi
    else
      git -C "$EXEC_DIR" merge --abort >/dev/null 2>&1 || true
      reason="实际 merge 失败，已自动 abort。"
      suggestion="建议人工处理冲突或拆分提交后再合并。"
      add_uncertain_bundle "$branch" "high" "$reason" "$suggestion" "$changed_count" "$commit_count" "$binary_count"
      append_blocked_gate "risk_gate" "$branch" "$reason"

      {
        echo "#### merge 失败输出"
        echo '```text'
        echo "$merge_output"
        echo '```'
        echo
      } >> "$UNCERTAIN_MD"

      printf '[FAIL] merge %s: aborted\n' "$branch" >> "$COMMAND_LOG"
    fi

  done < "$ORDERED_TARGET_FILE"
fi

# Cleanup candidates are always computed for reporting.
while IFS= read -r branch; do
  [[ -n "$branch" ]] || continue
  [[ "$branch" == "$BASE" ]] && continue

  if git -C "$REPO_ROOT" merge-base --is-ancestor "$branch" "$BASE"; then
    printf '%s\n' "$branch" >> "$CLEANUP_CANDIDATES_FILE"
  fi
done < <(git -C "$REPO_ROOT" for-each-ref --format='%(refname:short)' refs/heads)

if [[ "$CLEANUP" == "plan-only" ]]; then
  CLEANUP_CONFIRM_STATUS="plan-only"
else
  if [[ -n "$CONFIRM_CLEANUP" ]]; then
    if [[ "$CONFIRM_CLEANUP" != "$RUN_TOKEN" ]]; then
      CLEANUP_CONFIRM_STATUS="mismatch"
      append_blocked_gate "cleanup_gate" "*cleanup*" "confirm-cleanup token mismatch"
      set_gate_stop "cleanup_gate" "confirm-cleanup token mismatch (expected $RUN_TOKEN)" 6
    else
      CLEANUP_CONFIRM_STATUS="matched"
    fi
  else
    CLEANUP_CONFIRM_STATUS="legacy-bypass"
    warn "cleanup confirmation token not provided; using compatibility behavior"
  fi
fi

if [[ -z "$GATE_STOP_REASON" ]] && [[ "$CLEANUP" != "plan-only" ]]; then
  while IFS= read -r branch; do
    [[ -n "$branch" ]] || continue
    [[ "$branch" == "$BASE" ]] && continue

    if [[ "$CLEANUP" == "archive" ]]; then
      archive_ref="${ARCHIVE_PREFIX%/}/$RUN_TOKEN/$branch"
      record_cmd "git -C $REPO_ROOT update-ref $archive_ref refs/heads/$branch"
      if git -C "$REPO_ROOT" update-ref "$archive_ref" "refs/heads/$branch" >/dev/null 2>&1; then
        printf '%s\t%s\n' "$branch" "$archive_ref" >> "$ARCHIVE_REFS_FILE"
      else
        cleanup_reason="failed to archive ref before delete"
        printf '%s\t%s\n' "$branch" "$cleanup_reason" >> "$CLEAN_FAIL_FILE"
        printf '[FAIL] cleanup %s: %s\n' "$branch" "$cleanup_reason" >> "$COMMAND_LOG"
        continue
      fi
    fi

    record_cmd "git -C $EXEC_DIR branch -d $branch"
    if cleanup_output="$(git -C "$EXEC_DIR" branch -d "$branch" 2>&1)"; then
      printf '%s\n' "$branch" >> "$CLEANED_FILE"
      printf '[OK] cleanup %s: %s\n' "$branch" "$(printf '%s' "$cleanup_output" | tail -n 1)" >> "$COMMAND_LOG"
    else
      cleanup_reason="$(printf '%s' "$cleanup_output" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//')"
      printf '%s\t%s\n' "$branch" "$cleanup_reason" >> "$CLEAN_FAIL_FILE"
      printf '[FAIL] cleanup %s\n' "$branch" >> "$COMMAND_LOG"
    fi
  done < "$CLEANUP_CANDIDATES_FILE"
fi

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
  echo "- 清理模式: $CLEANUP"
  echo "- 隔离执行: $ISOLATION_NOTE"
  echo "- 运行令牌: $RUN_TOKEN"
  echo "- 目标范围: $TARGET_SCOPE"
  echo "- 基线起始提交: $BASE_START_SHA"
  echo "- 基线结束提交: $BASE_END_SHA"
  echo
  echo "## 门禁状态"
  echo "- approval_gate: require=$REQUIRE_APPROVAL loaded=$APPROVAL_LOADED file=${APPROVAL_FILE:-none} reviewer=${APPROVAL_REVIEWER:-unknown} approved_at=${APPROVAL_APPROVED_AT:-unknown}"
  if [[ -n "$APPROVAL_PARSE_ERROR" ]]; then
    echo "- approval_gate_error: $APPROVAL_PARSE_ERROR"
  fi
  echo "- test_gate: require=$REQUIRE_TESTS pre_test=${PRE_TEST_CMD:-none} post_test=${POST_TEST_CMD:-none} pre_test_passed=$PRE_TEST_PASSED"
  echo "- cleanup_gate: mode=$CLEANUP confirm_status=$CLEANUP_CONFIRM_STATUS"
  if [[ -n "$GATE_STOP_REASON" ]]; then
    echo "- gate_stop: [$GATE_STOP_KIND] $GATE_STOP_REASON"
  fi
  echo
  echo "## 目标分支"
  if [[ -s "$TARGET_BRANCHES_FILE" ]]; then
    sed 's/^/- /' "$TARGET_BRANCHES_FILE"
  else
    echo "- 无"
  fi
  echo
  echo "## 已合并分支"
  if [[ -s "$MERGED_FILE" ]]; then
    sed 's/^/- /' "$MERGED_FILE"
  else
    echo "- 无"
  fi
  echo
  echo "## 清理候选分支"
  if [[ -s "$CLEANUP_CANDIDATES_FILE" ]]; then
    sed 's/^/- /' "$CLEANUP_CANDIDATES_FILE"
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
  if [[ -s "$ARCHIVE_REFS_FILE" ]]; then
    echo "## Archive Refs"
    while IFS=$'\t' read -r b r; do
      echo "- $b -> $r"
    done < "$ARCHIVE_REFS_FILE"
    echo
  fi
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
  echo "## blocked_by_gate"
  if [[ -s "$BLOCKED_BY_GATE_FILE" ]]; then
    while IFS=$'\t' read -r gate b reason; do
      echo "- [$gate] $b: $reason"
    done < "$BLOCKED_BY_GATE_FILE"
  else
    echo "- 无"
  fi
  echo
  echo "## 保留未合并分支"
  if [[ -s "$PRESERVED_FILE" ]]; then
    sed 's/^/- /' "$PRESERVED_FILE"
  else
    echo "- 无"
  fi
  echo
  echo "## 测试日志"
  if [[ -s "$TEST_LOG_FILE" ]]; then
    echo '```text'
    cat "$TEST_LOG_FILE"
    echo '```'
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
  if [[ -s "$WARNINGS_FILE" ]]; then
    echo "## Warnings"
    sed 's/^/- /' "$WARNINGS_FILE"
    echo
  fi
  echo "## 漂移检查"
  echo "- 开始 HEAD: $START_HEAD_SIG"
  echo "- 结束 HEAD: $END_HEAD_SIG"
  echo "- 工作区状态签名变化: $DRIFT_DETECTED"
} > "$REPORT_PATH"

python3 - "$TMP_DIR" "$REPO_ROOT" "$BASE" "$MODE" "$CLEANUP" "$REPORT_PATH" "$JSON_PATH" "$ISOLATION_NOTE" "$BASE_START_SHA" "$BASE_END_SHA" "$DRIFT_DETECTED" "$PRINT_JSON" "$TARGET_SCOPE" "$RUN_TOKEN" "$REQUIRE_APPROVAL" "$APPROVAL_FILE" "$APPROVAL_LOADED" "$APPROVAL_PARSE_ERROR" "$APPROVAL_REVIEWER" "$APPROVAL_APPROVED_AT" "$REQUIRE_TESTS" "$PRE_TEST_CMD" "$POST_TEST_CMD" "$PRE_TEST_PASSED" "$CLEANUP_CONFIRM_STATUS" "$GATE_STOP_KIND" "$GATE_STOP_REASON" "$GATE_EXIT_CODE" <<'PY'
import json
import os
import sys
from datetime import datetime

(
    tmp_dir,
    repo_root,
    base,
    mode,
    cleanup,
    report_path,
    json_path,
    isolation_note,
    base_start_sha,
    base_end_sha,
    drift,
    print_json,
    target_scope,
    run_token,
    require_approval,
    approval_file,
    approval_loaded,
    approval_parse_error,
    approval_reviewer,
    approval_approved_at,
    require_tests,
    pre_test_cmd,
    post_test_cmd,
    pre_test_passed,
    cleanup_confirm_status,
    gate_stop_kind,
    gate_stop_reason,
    gate_exit_code,
) = sys.argv[1:29]


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


def read_tsv(path, cols):
    out = []
    if not os.path.exists(path):
        return out
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            raw = raw.rstrip("\n")
            if not raw:
                continue
            parts = raw.split("\t")
            if len(parts) < cols:
                parts += [""] * (cols - len(parts))
            out.append(parts[:cols])
    return out

uncertain = []
for branch, risk, reasons, suggestion, changed_count, commit_count in read_tsv(os.path.join(tmp_dir, "uncertain.tsv"), 6):
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
for branch, reason in read_tsv(os.path.join(tmp_dir, "cleanup_fail.txt"), 2):
    cleanup_failures.append({"branch": branch, "reason": reason})

blocked_by_gate = []
for gate, branch, reason in read_tsv(os.path.join(tmp_dir, "blocked_by_gate.tsv"), 3):
    blocked_by_gate.append({"gate": gate, "branch": branch, "reason": reason})

archive_refs = []
for branch, ref in read_tsv(os.path.join(tmp_dir, "archive_refs.txt"), 2):
    archive_refs.append({"branch": branch, "ref": ref})

result = {
    "generated_at": datetime.now().isoformat(),
    "repository": repo_root,
    "base": base,
    "mode": mode,
    "cleanup_mode": cleanup,
    "isolation": isolation_note,
    "run_token": run_token,
    "target_scope": target_scope,
    "target_branches": read_list(os.path.join(tmp_dir, "target_branches.txt")),
    "base_start_sha": base_start_sha,
    "base_end_sha": base_end_sha,
    "drift_detected": drift,
    "approval_gate": {
        "required": require_approval == "1",
        "approval_file": approval_file,
        "loaded": approval_loaded,
        "parse_error": approval_parse_error,
        "reviewer": approval_reviewer,
        "approved_at": approval_approved_at,
    },
    "test_gate": {
        "required": require_tests == "1",
        "pre_test": pre_test_cmd,
        "post_test": post_test_cmd,
        "pre_test_passed": pre_test_passed,
    },
    "cleanup_confirmation": cleanup_confirm_status,
    "merged_branches": read_list(os.path.join(tmp_dir, "merged.txt")),
    "cleanup_candidates": read_list(os.path.join(tmp_dir, "cleanup_candidates.txt")),
    "cleaned_branches": read_list(os.path.join(tmp_dir, "cleaned.txt")),
    "archive_refs": archive_refs,
    "cleanup_failures": cleanup_failures,
    "uncertain_branches": uncertain,
    "blocked_by_gate": blocked_by_gate,
    "preserved_unmerged_branches": read_list(os.path.join(tmp_dir, "preserved.txt")),
    "warnings": read_list(os.path.join(tmp_dir, "warnings.txt")),
    "gate_stop": {
        "kind": gate_stop_kind,
        "reason": gate_stop_reason,
        "exit_code": int(gate_exit_code or 0),
    },
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

if [[ -n "$GATE_STOP_REASON" ]]; then
  echo "[WARN] gate stopped execution: [$GATE_STOP_KIND] $GATE_STOP_REASON" >&2
  echo "[OK] report: $REPORT_PATH"
  echo "[OK] json: $JSON_PATH"
  exit "$GATE_EXIT_CODE"
fi

echo "[OK] report: $REPORT_PATH"
echo "[OK] json: $JSON_PATH"
