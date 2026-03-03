#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/crane/.codex/skills/ralph-loop"
RUNNER="$ROOT/scripts/ralph-loop.sh"
PARSER="$ROOT/scripts/parse_tasks.py"
SAMPLE_PLAN="$ROOT/references/examples/sample-plan.md"
STATE_ROOT="/Users/crane/.codex/workspace/outputs/ralph-loop"

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

assert_contains() {
  local text="$1"
  local needle="$2"
  [[ "$text" == *"$needle"* ]] || fail "expected output to contain: $needle"
}

echo "[TEST] parse >=20 tasks + dependency extraction"
PARSED_JSON="$(python3 "$PARSER" --plan "$SAMPLE_PLAN")"
python3 - "$PARSED_JSON" <<'PY'
import json
import sys
items = json.loads(sys.argv[1])
assert len(items) >= 20, len(items)
assert any(i["id"] == "US-005" and set(i["depends"]) == {"US-002", "US-003"} for i in items)
assert any(i["id"].startswith("T") for i in items), "missing generated ID task"
PY

echo "[TEST] strict mode rejects unknown dependency"
BAD_PLAN="$(mktemp)"
cat > "$BAD_PLAN" <<'MD'
- [ ] **US-001** Task A [depends: none]
- [ ] **US-002** Task B [depends: UNKNOWN-404]
MD
set +e
python3 "$PARSER" --plan "$BAD_PLAN" --strict >/tmp/ralph-parse-out.txt 2>/tmp/ralph-parse-err.txt
code=$?
set -e
[[ "$code" -eq 2 ]] || fail "strict mode should fail with code 2, got $code"
rm -f "$BAD_PLAN"

echo "[TEST] dry-run should not write run_state"
RUN_ID="$(printf '%s' "$SAMPLE_PLAN" | shasum | awk '{print $1}' | cut -c1-12)"
RUN_DIR="$STATE_ROOT/$RUN_ID"
rm -rf "$RUN_DIR"
DRY_OUT="$(bash "$RUNNER" --plan "$SAMPLE_PLAN" --mode parallel --max-lanes 3 --dry-run)"
assert_contains "$DRY_OUT" "DRY_RUN=1"
assert_contains "$DRY_OUT" "RESULT=complete"
[[ ! -d "$RUN_DIR" ]] || fail "dry-run should not create run directory"

echo "[TEST] gate check should block non-dry-run"
set +e
bash "$RUNNER" --plan "$SAMPLE_PLAN" --mode parallel --max-lanes 3 >/tmp/ralph-gate-out.txt 2>/tmp/ralph-gate-err.txt
code=$?
set -e
[[ "$code" -eq 20 ]] || fail "expected gate failure code 20, got $code"

echo "[TEST] active scheduling + no duplicate claims on resume"
OUT1="$(bash "$RUNNER" --plan "$SAMPLE_PLAN" --mode parallel --max-lanes 3 --plan-approved --reviewer-pass --tester-pass)"
assert_contains "$OUT1" "RESULT=active"
assert_contains "$OUT1" "RUN_DIR="

STATE_FILE="$(awk -F= '/^STATE_FILE=/{print $2}' <<<"$OUT1")"
[[ -f "$STATE_FILE" ]] || fail "missing state file after first run"

CLAIMED1="$(python3 - "$STATE_FILE" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
print(len([t for t in state["tasks"] if t["status"]=="claimed"]))
PY
)"
[[ "$CLAIMED1" -ge 1 ]] || fail "expected claimed tasks on first run"

OUT2="$(bash "$RUNNER" --plan "$SAMPLE_PLAN" --mode parallel --max-lanes 3 --resume --plan-approved --reviewer-pass --tester-pass)"
assert_contains "$OUT2" "RESULT=active"
CLAIMED2="$(python3 - "$STATE_FILE" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
claimed=[t["id"] for t in state["tasks"] if t["status"]=="claimed"]
assert len(claimed)==len(set(claimed)), claimed
print(len(claimed))
PY
)"
[[ "$CLAIMED2" -eq "$CLAIMED1" ]] || fail "resume should not duplicate or over-claim when lanes are full"

echo "[TEST] complete claimed tasks then resume should dispatch new ready tasks"
CLAIMED_IDS="$(python3 - "$STATE_FILE" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
print(" ".join([t["id"] for t in state["tasks"] if t["status"]=="claimed"]))
PY
)"
[[ -n "$CLAIMED_IDS" ]] || fail "expected claimed ids"

COMPLETE_ARGS=()
for id in $CLAIMED_IDS; do
  COMPLETE_ARGS+=(--complete "$id")
done

OUT3="$(bash "$RUNNER" --plan "$SAMPLE_PLAN" --mode parallel --max-lanes 3 --resume --plan-approved --reviewer-pass --tester-pass "${COMPLETE_ARGS[@]}")"
assert_contains "$OUT3" "RESULT=active"
python3 - "$STATE_FILE" $CLAIMED_IDS <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
completed={t["id"] for t in state["tasks"] if t["status"]=="completed"}
for task_id in sys.argv[2:]:
    assert task_id in completed, task_id
PY

echo "[TEST] mode behavior serial=1 lane, hybrid<=2 lanes"
MODE_PLAN="$(mktemp)"
cat > "$MODE_PLAN" <<'MD'
- [ ] **A-1** Task one [depends: none]
- [ ] **A-2** Task two [depends: none]
- [ ] **A-3** Task three [depends: none]
MD

OUT_SERIAL="$(bash "$RUNNER" --plan "$MODE_PLAN" --mode serial --max-lanes 5 --plan-approved --reviewer-pass --tester-pass)"
SERIAL_STATE="$(awk -F= '/^STATE_FILE=/{print $2}' <<<"$OUT_SERIAL")"
SERIAL_CLAIMED="$(python3 - "$SERIAL_STATE" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
print(len([t for t in state["tasks"] if t["status"]=="claimed"]))
PY
)"
[[ "$SERIAL_CLAIMED" -eq 1 ]] || fail "serial mode should claim exactly 1 task"

OUT_HYBRID="$(bash "$RUNNER" --plan "$MODE_PLAN" --mode hybrid --max-lanes 5 --plan-approved --reviewer-pass --tester-pass)"
HYBRID_STATE="$(awk -F= '/^STATE_FILE=/{print $2}' <<<"$OUT_HYBRID")"
HYBRID_CLAIMED="$(python3 - "$HYBRID_STATE" <<'PY'
import json,sys
state=json.load(open(sys.argv[1]))
print(len([t for t in state["tasks"] if t["status"]=="claimed"]))
PY
)"
[[ "$HYBRID_CLAIMED" -le 2 ]] || fail "hybrid mode should claim at most 2 tasks"
rm -f "$MODE_PLAN"

echo "[TEST] blocked state when unknown dependency allowed"
BLOCKED_PLAN="$(mktemp)"
cat > "$BLOCKED_PLAN" <<'MD'
- [ ] **B-1** First [depends: none]
- [ ] **B-2** Second [depends: Z-404]
MD
OUT_BLOCKED="$(bash "$RUNNER" --plan "$BLOCKED_PLAN" --mode parallel --max-lanes 2 --no-strict --plan-approved --reviewer-pass --tester-pass)"
assert_contains "$OUT_BLOCKED" "RESULT=active"
OUT_BLOCKED2="$(bash "$RUNNER" --plan "$BLOCKED_PLAN" --mode parallel --max-lanes 2 --no-strict --resume --complete B-1 --plan-approved --reviewer-pass --tester-pass)"
assert_contains "$OUT_BLOCKED2" "RESULT=blocked"
assert_contains "$OUT_BLOCKED2" "BLOCKED task=B-2 missing=Z-404"
rm -f "$BLOCKED_PLAN"

echo "[PASS] ralph-loop tests"
