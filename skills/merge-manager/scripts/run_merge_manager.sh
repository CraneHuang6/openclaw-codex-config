#!/usr/bin/env bash
# Orchestrate merge-manager dry-run inventory/classify/validate/report flow.
# MVP boundary: only --mode dry-run is implemented; execute remains intentionally disabled.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/policy.sh"

usage() {
  cat <<'USAGE'
Usage: run_merge_manager.sh --mode dry-run --base <branch> --report <abs-path>
                            [--branch-pattern <glob>] [--branches-file <path>] [--policy <path>] [--json]
USAGE
}

MODE="dry-run"
BASE="main"
REPORT_PATH=""
BRANCH_PATTERN=""
BRANCHES_FILE=""
POLICY=""
PRINT_JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --report) REPORT_PATH="$2"; shift 2 ;;
    --branch-pattern) BRANCH_PATTERN="$2"; shift 2 ;;
    --branches-file) BRANCHES_FILE="$2"; shift 2 ;;
    --policy) POLICY="$2"; shift 2 ;;
    --json) PRINT_JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) mm_die "unknown argument: $1" ;;
  esac
done
[[ -n "$REPORT_PATH" ]] || mm_die "--report is required"
REPORT_PATH="$(mm_abs_path "$REPORT_PATH")"
JSON_PATH="${REPORT_PATH%.md}.json"
mkdir -p "$(dirname "$REPORT_PATH")"

if [[ "$MODE" == "execute" ]]; then
  echo 'merge-manager: execute mode not enabled in MVP' >&2
  exit 2
fi
[[ "$MODE" == "dry-run" ]] || mm_die "--mode only supports dry-run or execute"

mm_require_cmd git
mm_require_cmd python3
SKILL_OWNER_ROOT="$(mm_skill_owner_root "$SCRIPT_DIR")"
REPO_ROOT="$(mm_target_repo_root "$PWD")"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
INVENTORY_JSON="$TEMP_DIR/inventory.json"
CLASS_DIR="$TEMP_DIR/classifications"
VALID_DIR="$TEMP_DIR/validations"
mkdir -p "$CLASS_DIR" "$VALID_DIR"

if [[ -z "$POLICY" ]]; then
  POLICY="$TEMP_DIR/derived-legacy-policy.yaml"
  python3 "$SCRIPT_DIR/generate_legacy_policy.py" --config-dir "$SCRIPT_DIR/../config" --output "$POLICY"
fi

bash "$SCRIPT_DIR/inventory_branches.sh" --repo "$REPO_ROOT" --base "$BASE" --policy "$POLICY" ${BRANCH_PATTERN:+--branch-pattern "$BRANCH_PATTERN"} ${BRANCHES_FILE:+--branches-file "$BRANCHES_FILE"} > "$INVENTORY_JSON"

python3 - "$INVENTORY_JSON" <<'PY' > "$TEMP_DIR/branches.txt"
import json, sys
for item in json.load(open(sys.argv[1], encoding='utf-8'))['branches']:
    print(item['branch'])
PY

while IFS= read -r branch; do
  [[ -n "$branch" ]] || continue
  safe_name="$(mm_sanitize_name "$branch")"
  bash "$SCRIPT_DIR/classify_branch.sh" --repo "$REPO_ROOT" --base "$BASE" --branch "$branch" --policy "$POLICY" > "$CLASS_DIR/$safe_name.json"
  bash "$SCRIPT_DIR/validate_branch.sh" --repo "$REPO_ROOT" --base "$BASE" --branch "$branch" --policy "$POLICY" > "$VALID_DIR/$safe_name.json"
done < "$TEMP_DIR/branches.txt"

LEGACY_CMD="cd '$REPO_ROOT' && bash $SKILL_OWNER_ROOT/skills/review-merge-main-cleanup/scripts/review_merge_main_cleanup.sh --base $BASE ${BRANCH_PATTERN:+--branch-pattern '$BRANCH_PATTERN'} ${BRANCHES_FILE:+--branches-file '$BRANCHES_FILE'} --cleanup plan-only --report /abs/path/report.md --json"
python3 "$SCRIPT_DIR/render_report.py" \
  --inventory "$INVENTORY_JSON" \
  --classifications-dir "$CLASS_DIR" \
  --validations-dir "$VALID_DIR" \
  --markdown "$REPORT_PATH" \
  --json "$JSON_PATH" \
  --base "$BASE" \
  --branch-pattern "$BRANCH_PATTERN" \
  --branches-file "$BRANCHES_FILE" \
  --legacy-command "$LEGACY_CMD"

if [[ "$PRINT_JSON" -eq 1 ]]; then
  cat "$JSON_PATH"
fi
