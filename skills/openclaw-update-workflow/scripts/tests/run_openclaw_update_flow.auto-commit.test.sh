#!/usr/bin/env bash
set -euo pipefail

RUNNER="/Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh"

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

make_daily_stub() {
  local target="$1"
  cat >"$target" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
mode="${1:-}"
if [[ "$mode" == "--skip-update" || "$mode" == "--with-update" ]]; then
  echo "STATUS=ok"
  exit 0
fi
echo "unexpected mode: $mode" >&2
exit 90
STUB
  chmod +x "$target"
}

make_repo() {
  local root="$1"
  mkdir -p "$root/skills/openclaw-update-workflow"
  cat >"$root/AGENTS.md" <<'EOF1'
# test agents
EOF1
  cat >"$root/skills/openclaw-update-workflow/SKILL.md" <<'EOF2'
# test skill
EOF2

  git -C "$root" init -q
  git -C "$root" config user.email "test@example.com"
  git -C "$root" config user.name "Test Runner"
  git -C "$root" add AGENTS.md skills/openclaw-update-workflow/SKILL.md
  git -C "$root" commit -q -m "init"
}

run_stable() {
  local repo="$1"
  local verdict="$2"
  local auto_enabled="${3:-1}"
  local stub_daily="$4"
  local output
  local code

  set +e
  output="$(
    OPENCLAW_SKILL_DAILY_SCRIPT="$stub_daily" \
    OPENCLAW_SKILL_FAST_PREFLIGHT_ENABLED=0 \
    OPENCLAW_SKILL_PROXY_PRECHECK_ENABLED=0 \
    OPENCLAW_SKILL_AUTO_COMMIT_REPO="$repo" \
    OPENCLAW_SKILL_GATE_D2_VERDICT="$verdict" \
    OPENCLAW_SKILL_AUTO_COMMIT_ENABLED="$auto_enabled" \
    bash "$RUNNER" stable
  )"
  code=$?
  set -e

  RUN_OUTPUT="$output"
  RUN_CODE="$code"
}

scenario_gate_pass_commits_allowlisted() {
  local tmp
  tmp="$(mktemp -d -t openclaw-auto-commit-pass.XXXXXX)"
  make_repo "$tmp/repo"
  make_daily_stub "$tmp/daily.sh"

  echo "pass-change" >> "$tmp/repo/AGENTS.md"
  before_head="$(git -C "$tmp/repo" rev-parse HEAD)"
  run_stable "$tmp/repo" "PASS" "1" "$tmp/daily.sh"
  [[ "$RUN_CODE" -eq 0 ]] || fail "expected exit 0, got $RUN_CODE"
  grep -Fq "AUTO_COMMIT_RESULT=committed" <<<"$RUN_OUTPUT" || fail "expected committed result"
  grep -Fq "AUTO_COMMIT_REASON=ok" <<<"$RUN_OUTPUT" || fail "expected ok reason"
  after_head="$(git -C "$tmp/repo" rev-parse HEAD)"
  [[ "$before_head" != "$after_head" ]] || fail "expected new commit when Gate D2 is PASS"
  msg="$(git -C "$tmp/repo" log -1 --pretty=%s)"
  [[ "$msg" == "chore(openclaw-update-workflow): auto commit after gate d2 pass (stable)" ]] || fail "unexpected commit message: $msg"
  rm -rf "$tmp"
}

scenario_gate_not_pass_skips() {
  local tmp
  tmp="$(mktemp -d -t openclaw-auto-commit-gate.XXXXXX)"
  make_repo "$tmp/repo"
  make_daily_stub "$tmp/daily.sh"

  echo "gate-change" >> "$tmp/repo/AGENTS.md"
  before_head="$(git -C "$tmp/repo" rev-parse HEAD)"
  run_stable "$tmp/repo" "FAIL" "1" "$tmp/daily.sh"
  [[ "$RUN_CODE" -eq 0 ]] || fail "expected exit 0, got $RUN_CODE"
  grep -Fq "AUTO_COMMIT_RESULT=skipped" <<<"$RUN_OUTPUT" || fail "expected skipped result"
  grep -Fq "AUTO_COMMIT_REASON=gate_d2_not_pass" <<<"$RUN_OUTPUT" || fail "expected gate skip reason"
  after_head="$(git -C "$tmp/repo" rev-parse HEAD)"
  [[ "$before_head" == "$after_head" ]] || fail "did not expect commit when Gate D2 is not PASS"
  rm -rf "$tmp"
}

scenario_dirty_outside_allowlist_skips() {
  local tmp
  tmp="$(mktemp -d -t openclaw-auto-commit-dirty.XXXXXX)"
  make_repo "$tmp/repo"
  make_daily_stub "$tmp/daily.sh"

  echo "allowlist-change" >> "$tmp/repo/AGENTS.md"
  echo "outside" > "$tmp/repo/outside.txt"
  before_head="$(git -C "$tmp/repo" rev-parse HEAD)"
  run_stable "$tmp/repo" "PASS" "1" "$tmp/daily.sh"
  [[ "$RUN_CODE" -eq 0 ]] || fail "expected exit 0, got $RUN_CODE"
  grep -Fq "AUTO_COMMIT_RESULT=skipped" <<<"$RUN_OUTPUT" || fail "expected skipped result"
  grep -Fq "AUTO_COMMIT_REASON=dirty_outside_allowlist" <<<"$RUN_OUTPUT" || fail "expected dirty allowlist reason"
  after_head="$(git -C "$tmp/repo" rev-parse HEAD)"
  [[ "$before_head" == "$after_head" ]] || fail "did not expect commit with outside dirty files"
  rm -rf "$tmp"
}

scenario_no_changes_skips() {
  local tmp
  tmp="$(mktemp -d -t openclaw-auto-commit-empty.XXXXXX)"
  make_repo "$tmp/repo"
  make_daily_stub "$tmp/daily.sh"

  run_stable "$tmp/repo" "PASS" "1" "$tmp/daily.sh"
  [[ "$RUN_CODE" -eq 0 ]] || fail "expected exit 0, got $RUN_CODE"
  grep -Fq "AUTO_COMMIT_RESULT=skipped" <<<"$RUN_OUTPUT" || fail "expected skipped result"
  grep -Fq "AUTO_COMMIT_REASON=no_changes" <<<"$RUN_OUTPUT" || fail "expected no_changes reason"
  rm -rf "$tmp"
}

scenario_sensitive_file_skips() {
  local tmp
  tmp="$(mktemp -d -t openclaw-auto-commit-sensitive.XXXXXX)"
  make_repo "$tmp/repo"
  make_daily_stub "$tmp/daily.sh"

  echo "allowlist-change" >> "$tmp/repo/AGENTS.md"
  echo "token=abc" > "$tmp/repo/.env.local"
  before_head="$(git -C "$tmp/repo" rev-parse HEAD)"
  run_stable "$tmp/repo" "PASS" "1" "$tmp/daily.sh"
  [[ "$RUN_CODE" -eq 0 ]] || fail "expected exit 0, got $RUN_CODE"
  grep -Fq "AUTO_COMMIT_RESULT=skipped" <<<"$RUN_OUTPUT" || fail "expected skipped result"
  grep -Fq "AUTO_COMMIT_REASON=sensitive_file_detected" <<<"$RUN_OUTPUT" || fail "expected sensitive reason"
  after_head="$(git -C "$tmp/repo" rev-parse HEAD)"
  [[ "$before_head" == "$after_head" ]] || fail "did not expect commit when sensitive files are changed"
  rm -rf "$tmp"
}

scenario_auto_commit_disabled_skips() {
  local tmp
  tmp="$(mktemp -d -t openclaw-auto-commit-disabled.XXXXXX)"
  make_repo "$tmp/repo"
  make_daily_stub "$tmp/daily.sh"

  echo "disabled-change" >> "$tmp/repo/AGENTS.md"
  run_stable "$tmp/repo" "PASS" "0" "$tmp/daily.sh"
  [[ "$RUN_CODE" -eq 0 ]] || fail "expected exit 0, got $RUN_CODE"
  grep -Fq "AUTO_COMMIT_RESULT=skipped" <<<"$RUN_OUTPUT" || fail "expected skipped result"
  grep -Fq "AUTO_COMMIT_REASON=disabled" <<<"$RUN_OUTPUT" || fail "expected disabled reason"
  rm -rf "$tmp"
}

scenario_gate_pass_commits_allowlisted
scenario_gate_not_pass_skips
scenario_dirty_outside_allowlist_skips
scenario_no_changes_skips
scenario_sensitive_file_skips
scenario_auto_commit_disabled_skips

echo "[PASS] run_openclaw_update_flow auto commit tests"
