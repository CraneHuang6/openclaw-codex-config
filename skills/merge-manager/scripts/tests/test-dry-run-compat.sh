#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="/Users/crane/.codex/.worktrees/codex-merge-manager-github-automation-v1"
RUNNER="$REPO_ROOT/skills/merge-manager/scripts/run_merge_manager.sh"

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

assert_contains() {
  local text="$1"
  local needle="$2"
  [[ "$text" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
TARGET="$TMP_DIR/target"
REPORT="$TMP_DIR/report.md"
JSON="$TMP_DIR/report.json"

git -C "$TMP_DIR" init -q "$TARGET"
git -C "$TARGET" config user.name 'Codex Test'
git -C "$TARGET" config user.email 'codex@example.com'
mkdir -p "$TARGET/scripts"
cat > "$TARGET/scripts/check-agent-contracts.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TARGET/scripts/check-agent-contracts.sh"
cat > "$TARGET/package.json" <<'JSON'
{"scripts":{"lint":"echo lint","typecheck":"echo typecheck","test":"echo test"}}
JSON
echo 'base' > "$TARGET/app.txt"
git -C "$TARGET" add .
git -C "$TARGET" commit -q -m 'base'
git -C "$TARGET" branch -M main

git -C "$TARGET" checkout -q -b worker/demo
mkdir -p "$TARGET/docs"
echo 'doc change' > "$TARGET/docs/readme.md"
git -C "$TARGET" add docs/readme.md
git -C "$TARGET" commit -q -m 'docs'
git -C "$TARGET" checkout -q main

git -C "$TARGET" checkout -q -b worker/feature
mkdir -p "$TARGET/src"
echo 'feature' > "$TARGET/src/feature.txt"
git -C "$TARGET" add src/feature.txt
git -C "$TARGET" commit -q -m 'feature'
git -C "$TARGET" checkout -q main

cd "$TARGET"
OUT="$(bash "$RUNNER" --mode dry-run --base main --branch-pattern 'worker/*' --report "$REPORT" --json)"
assert_contains "$OUT" '"branch": "worker/feature"'
assert_contains "$OUT" '"branch": "worker/demo"'
[[ -f "$REPORT" ]] || fail "missing markdown report"
[[ -f "$JSON" ]] || fail "missing json report"
grep -Fq 'Exact Next Command' "$REPORT" || fail 'report missing next command'

echo "[PASS] merge-manager dry-run compatibility"
