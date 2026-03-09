#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures"

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
REPO="$TMP_DIR/repo"
mkdir -p "$REPO"

git -C "$REPO" init -q

git -C "$REPO" config user.name 'Codex Test'
git -C "$REPO" config user.email 'codex@example.com'
mkdir -p "$REPO/src" "$REPO/scripts"
cat > "$REPO/package.json" <<'JSON'
{"scripts":{"lint":"echo lint","typecheck":"echo typecheck","test":"echo test"}}
JSON
cat > "$REPO/scripts/check-agent-contracts.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$REPO/scripts/check-agent-contracts.sh"
echo 'base' > "$REPO/src/app.txt"
git -C "$REPO" add .
git -C "$REPO" commit -q -m 'base'
git -C "$REPO" branch -M main
git -C "$REPO" remote add origin "$REPO"
git -C "$REPO" fetch -q origin main:refs/remotes/origin/main

git -C "$REPO" checkout -q -b task/test-gates
mkdir -p "$REPO/infra"
echo 'changed' >> "$REPO/src/app.txt"
echo 'ops' > "$REPO/infra/config.tf"
git -C "$REPO" add .
git -C "$REPO" commit -q -m 'feature change'

echo "[TEST] changed files gate"
CHANGED_JSON="$(python3 "$ROOT/changed_files_gate.py" --repo "$REPO" --base-ref origin/main --head-ref HEAD)"
assert_contains "$CHANGED_JSON" '"files_changed": 2'
assert_contains "$CHANGED_JSON" '"infra/config.tf"'

echo "[TEST] risk gate detects protected paths"
set +e
RISK_OUT="$(python3 "$ROOT/risk_gate.py" --repo "$REPO" --base-ref origin/main --head-ref HEAD --protected-paths "$ROOT/../config/protected_paths.yaml" 2>&1)"
RISK_CODE=$?
set -e
[[ "$RISK_CODE" -eq 2 ]] || fail "risk gate should exit 2, got $RISK_CODE"
assert_contains "$RISK_OUT" '"risk_level": "high"'
assert_contains "$RISK_OUT" '"infra/config.tf"'

echo "[TEST] policy alignment keeps protected paths in legacy dry-run policy"
python3 - <<'PY2' "$ROOT/../config/protected_paths.yaml" "$ROOT/../assets/merge-policy.yaml"
from pathlib import Path
import sys
repo_paths = [line.strip()[2:].strip().strip('\"') for line in Path(sys.argv[1]).read_text(encoding='utf-8').splitlines() if line.strip().startswith('- ')]
legacy_paths = [line.strip()[2:].strip().strip('\"') for line in Path(sys.argv[2]).read_text(encoding='utf-8').splitlines() if line.strip().startswith('- ')]
missing = [item for item in repo_paths if item not in legacy_paths]
if missing:
    raise SystemExit(f'missing protected paths in merge-policy: {missing}')
PY2

echo "[TEST] PR size gate detects oversized change"
python3 - <<'PY' "$REPO"
from pathlib import Path
import sys
repo = Path(sys.argv[1])
with repo.joinpath('src/large.txt').open('w', encoding='utf-8') as fh:
    for idx in range(900):
        fh.write(f"line-{idx}\n")
PY
git -C "$REPO" add src/large.txt
git -C "$REPO" commit -q -m 'large change'
set +e
SIZE_OUT="$(python3 "$ROOT/pr_size_gate.py" --repo "$REPO" --base-ref origin/main --head-ref HEAD --rules "$ROOT/../config/merge_rules.yaml" 2>&1)"
SIZE_CODE=$?
set -e
[[ "$SIZE_CODE" -eq 2 ]] || fail "size gate should exit 2, got $SIZE_CODE"
assert_contains "$SIZE_OUT" '"too_large": true'

echo "[TEST] PR body gate enforces sections"
set +e
BODY_OUT="$(python3 "$ROOT/pr_body_gate.py" --rules "$ROOT/../config/merge_rules.yaml" --body-file "$FIXTURES/pr-body-missing.md" 2>&1)"
BODY_CODE=$?
set -e
[[ "$BODY_CODE" -eq 2 ]] || fail "body gate should exit 2, got $BODY_CODE"
assert_contains "$BODY_OUT" 'missing rollback plan'

echo "[TEST] evaluate merge readiness decisions"
READY_OUT="$(python3 "$ROOT/evaluate_merge_readiness.py" --rules "$ROOT/../config/merge_rules.yaml" --state-json "$FIXTURES/ready-state.json")"
assert_contains "$READY_OUT" '"decision": "ENABLE_AUTO_MERGE"'
MANUAL_OUT="$(python3 "$ROOT/evaluate_merge_readiness.py" --rules "$ROOT/../config/merge_rules.yaml" --state-json "$FIXTURES/manual-review-state.json")"
assert_contains "$MANUAL_OUT" '"decision": "REQUIRE_MANUAL_REVIEW"'
BLOCK_OUT="$(python3 "$ROOT/evaluate_merge_readiness.py" --rules "$ROOT/../config/merge_rules.yaml" --state-json "$FIXTURES/blocked-state.json")"
assert_contains "$BLOCK_OUT" '"decision": "BLOCK_AND_COMMENT"'
CONFLICT_OUT="$(python3 "$ROOT/evaluate_merge_readiness.py" --rules "$ROOT/../config/merge_rules.yaml" --state-json "$FIXTURES/conflict-state.json")"
assert_contains "$CONFLICT_OUT" '"decision": "ROUTE_TO_CONFLICT_REPAIR"'

set +e
FAIL_CLOSED_OUT="$(python3 "$ROOT/evaluate_merge_readiness.py" --rules "$ROOT/../config/merge_rules.yaml" --state-json "$FIXTURES/missing-fields-state.json" 2>&1)"
FAIL_CLOSED_CODE=$?
set -e
[[ "$FAIL_CLOSED_CODE" -eq 2 ]] || fail "missing fields should fail closed"
assert_contains "$FAIL_CLOSED_OUT" 'missing required state keys'

echo "[TEST] apply decision dry-run emits expected gh operations"
APPLY_OUT="$(bash "$ROOT/enqueue_automerge.sh" --decision-json "$FIXTURES/ready-decision.json" --pr 42 --repo owner/repo --dry-run)"
assert_contains "$APPLY_OUT" 'gh pr merge 42 --repo owner/repo --auto --squash'
BLOCK_APPLY_OUT="$(bash "$ROOT/enqueue_automerge.sh" --decision-json "$FIXTURES/blocked-decision.json" --pr 42 --repo owner/repo --dry-run)"
assert_contains "$BLOCK_APPLY_OUT" "gh pr edit 42 --repo owner/repo --add-label 'manual-review-required'"
assert_contains "$BLOCK_APPLY_OUT" 'gh pr comment 42 --repo owner/repo --body-file'

echo "[PASS] merge-manager github gates"
