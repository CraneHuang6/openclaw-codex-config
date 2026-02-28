#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TARGET_FILE="/opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/accounts.ts"

OLD_IMPORT='import { DEFAULT_ACCOUNT_ID, normalizeAccountId } from "openclaw/plugin-sdk/account-id";'
NEW_IMPORT='import { DEFAULT_ACCOUNT_ID, normalizeAccountId } from "openclaw/plugin-sdk";'

show_help() {
  cat <<'EOF'
Usage: repatch-openclaw-feishu-account-id-import.sh [--dry-run|--apply] [--target-file <path>]

Options:
  --dry-run              Preview result without writing files.
  --apply                Apply patch and create <target>.bak when first patched.
  --target-file <path>   Override target file (default: /opt/homebrew/lib/node_modules/openclaw/extensions/feishu/src/accounts.ts).
  -h, --help             Show this help message.
EOF
}

apply=true
target_file="$DEFAULT_TARGET_FILE"

while (($#)); do
  case "$1" in
    --dry-run)
      apply=false
      shift
      ;;
    --apply)
      apply=true
      shift
      ;;
    --target-file)
      if (($# < 2)); then
        echo "missing value for --target-file" >&2
        exit 2
      fi
      target_file="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      show_help >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$target_file" ]]; then
  echo "{\"ok\":false,\"status\":\"missing_target\",\"apply\":$apply,\"targetFile\":\"$target_file\"}" >&2
  exit 1
fi

if grep -Fq -- "$NEW_IMPORT" "$target_file"; then
  echo "{\"ok\":true,\"status\":\"already_patched\",\"apply\":$apply,\"targetFile\":\"$target_file\"}"
  exit 0
fi

if ! grep -Fq -- "$OLD_IMPORT" "$target_file"; then
  echo "{\"ok\":false,\"status\":\"pattern_not_found\",\"apply\":$apply,\"targetFile\":\"$target_file\"}" >&2
  exit 1
fi

if [[ "$apply" == "false" ]]; then
  echo "{\"ok\":true,\"status\":\"would_patch\",\"apply\":false,\"targetFile\":\"$target_file\"}"
  exit 0
fi

tmp_file="$(mktemp)"
cleanup() {
  rm -f "$tmp_file"
}
trap cleanup EXIT

OLD_IMPORT="$OLD_IMPORT" NEW_IMPORT="$NEW_IMPORT" perl -0pe 's/\Q$ENV{OLD_IMPORT}\E/$ENV{NEW_IMPORT}/g' "$target_file" >"$tmp_file"

if cmp -s "$target_file" "$tmp_file"; then
  echo "{\"ok\":false,\"status\":\"replace_failed\",\"apply\":true,\"targetFile\":\"$target_file\"}" >&2
  exit 1
fi

backup_file="${target_file}.bak"
backup_created=false
if [[ ! -f "$backup_file" ]]; then
  cp "$target_file" "$backup_file"
  backup_created=true
fi

mv "$tmp_file" "$target_file"

if ! grep -Fq -- "$NEW_IMPORT" "$target_file"; then
  echo "{\"ok\":false,\"status\":\"verify_failed\",\"apply\":true,\"targetFile\":\"$target_file\"}" >&2
  exit 1
fi

echo "{\"ok\":true,\"status\":\"patched\",\"apply\":true,\"targetFile\":\"$target_file\",\"backupCreated\":$backup_created}"
