#!/usr/bin/env bash
# Emit classification JSON for a single branch.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/policy.sh"
source "$SCRIPT_DIR/lib/classify.sh"

usage() {
  cat <<'USAGE'
Usage: classify_branch.sh --repo <path> --base <branch> --branch <branch> [--policy <path>]
USAGE
}

REPO=""
BASE="main"
BRANCH=""
POLICY=""
TEMP_POLICY=""
cleanup() {
  if [[ -n "$TEMP_POLICY" ]]; then
    rm -f "$TEMP_POLICY"
  fi
}
trap cleanup EXIT
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --policy) POLICY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) mm_die "unknown argument: $1" ;;
  esac
done
[[ -n "$REPO" && -n "$BRANCH" ]] || mm_die "--repo and --branch are required"
REPO="$(mm_repo_root "$REPO")"
if [[ -z "$POLICY" ]]; then
  TEMP_POLICY="$(mktemp "${TMPDIR:-/tmp}/merge-manager-policy.XXXXXX")"
  python3 "$SCRIPT_DIR/generate_legacy_policy.py" --config-dir "$SCRIPT_DIR/../config" --output "$TEMP_POLICY"
  POLICY="$TEMP_POLICY"
fi
mm_classification_json "$REPO" "$BASE" "$BRANCH" "$POLICY"
