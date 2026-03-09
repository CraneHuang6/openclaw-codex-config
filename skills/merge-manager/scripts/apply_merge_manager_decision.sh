#!/usr/bin/env bash
set -euo pipefail

DECISION_JSON=""
PR_NUMBER=""
REPO_SLUG=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --decision-json) DECISION_JSON="$2"; shift 2 ;;
    --pr) PR_NUMBER="$2"; shift 2 ;;
    --repo) REPO_SLUG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      echo "Usage: apply_merge_manager_decision.sh --decision-json <path> --pr <number> --repo <owner/repo> [--dry-run]"
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done
[[ -n "$DECISION_JSON" && -n "$PR_NUMBER" && -n "$REPO_SLUG" ]] || { echo 'missing required arguments' >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT
python3 - "$DECISION_JSON" "$TMP_DIR" <<'PY'
import json, pathlib, sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'))
outdir = pathlib.Path(sys.argv[2])
outdir.mkdir(parents=True, exist_ok=True)
(outdir / 'decision.txt').write_text(payload.get('decision', ''), encoding='utf-8')
(outdir / 'labels_to_add.txt').write_text('\n'.join(payload.get('labels_to_add', [])) + '\n', encoding='utf-8')
(outdir / 'labels_to_remove.txt').write_text('\n'.join(payload.get('labels_to_remove', [])) + '\n', encoding='utf-8')
(outdir / 'failure_comment.md').write_text(payload.get('failure_comment', ''), encoding='utf-8')
PY

decision="$(cat "$TMP_DIR/decision.txt")"
labels_to_add=()
while IFS= read -r line; do
  [[ -n "$line" ]] && labels_to_add+=("$line")
done < "$TMP_DIR/labels_to_add.txt"
labels_to_remove=()
while IFS= read -r line; do
  [[ -n "$line" ]] && labels_to_remove+=("$line")
done < "$TMP_DIR/labels_to_remove.txt"
comment_file="$TMP_DIR/failure_comment.md"

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '%s\n' "$*"
  else
    eval "$@"
  fi
}

for label in "${labels_to_add[@]-}"; do
  run_cmd "gh pr edit $PR_NUMBER --repo $REPO_SLUG --add-label '$label'"
done
for label in "${labels_to_remove[@]-}"; do
  run_cmd "gh pr edit $PR_NUMBER --repo $REPO_SLUG --remove-label '$label'"
done
if [[ -s "$comment_file" ]]; then
  run_cmd "gh pr comment $PR_NUMBER --repo $REPO_SLUG --body-file '$comment_file'"
fi
if [[ "$decision" == 'ENABLE_AUTO_MERGE' ]]; then
  run_cmd "gh pr merge $PR_NUMBER --repo $REPO_SLUG --auto --squash"
fi
