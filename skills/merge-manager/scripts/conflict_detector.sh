#!/usr/bin/env bash
set -euo pipefail

REPO="."
BASE_REF="origin/main"
HEAD_REF="HEAD"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --base-ref) BASE_REF="$2"; shift 2 ;;
    --head-ref) HEAD_REF="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: conflict_detector.sh [--repo <path>] [--base-ref <ref>] [--head-ref <ref>]"
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

merge_base="$(git -C "$REPO" merge-base "$HEAD_REF" "$BASE_REF")"
if ! git -C "$REPO" merge-tree "$merge_base" "$HEAD_REF" "$BASE_REF" >/tmp/merge-manager-conflict.out 2>/dev/null; then
  echo '{"status":"error","summary":"Unable to evaluate merge conflict state"}'
  exit 2
fi

if grep -q '<<<<<<<' /tmp/merge-manager-conflict.out; then
  echo '{"status":"conflict","summary":"conflict detected"}'
  exit 3
fi

echo '{"status":"clean","summary":"no conflict detected"}'
