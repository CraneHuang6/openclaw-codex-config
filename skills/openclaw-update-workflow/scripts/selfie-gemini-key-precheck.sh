#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
SELFIE_SCRIPT="${OPENCLAW_SKILL_XIAOKE_SELFIE_SCRIPT:-$OPENCLAW_HOME/workspace/skills/xiaoke-selfie/scripts/xiaoke_selfie.py}"
SELFIE_CONTEXT="${OPENCLAW_SKILL_SELFIE_PRECHECK_CONTEXT:-在教室里的自拍}"

if [[ ! -f "$SELFIE_SCRIPT" ]]; then
  echo "xiaoke-selfie script missing: $SELFIE_SCRIPT" >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not found in PATH" >&2
  exit 2
fi

out_file="$(mktemp "${TMPDIR:-/tmp}/xiaoke-selfie-key-precheck.XXXXXX")"
cleanup() {
  rm -f "$out_file"
}
trap cleanup EXIT

set +e
GEMINI_API_KEY="invalid-key-for-precheck" \
  python3 "$SELFIE_SCRIPT" \
    --context "$SELFIE_CONTEXT" \
    --mode auto \
    --resolution 1K \
    >"$out_file" 2>&1
status=$?
set -e

cat "$out_file"

if [[ "$status" -ne 0 ]]; then
  echo "FAIL: xiaoke-selfie failed while invalid env key was injected." >&2
  echo "Expected behavior: fallback to openclaw.json key should still succeed." >&2
  exit 1
fi

if ! rg -q '^MEDIA:' "$out_file"; then
  echo "FAIL: no MEDIA token found in xiaoke-selfie output." >&2
  exit 1
fi

echo "PASS: xiaoke-selfie ignored invalid env key and generated image successfully."
