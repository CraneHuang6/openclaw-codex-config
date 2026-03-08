#!/usr/bin/env bash
# Emit validation JSON for a single branch in dry-run mode.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/policy.sh"
source "$SCRIPT_DIR/lib/validation.sh"

usage() {
  cat <<'USAGE'
Usage: validate_branch.sh --repo <path> --base <branch> --branch <branch> [--policy <path>]
USAGE
}

REPO=""
BASE="main"
BRANCH=""
POLICY="$SCRIPT_DIR/../assets/merge-policy.yaml"
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
mm_validate_branch_json "$REPO" "$BASE" "$BRANCH" "$POLICY"
