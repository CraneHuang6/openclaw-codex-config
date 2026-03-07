#!/usr/bin/env bash
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

CONFIG_FILE="$CODEX_HOME/config.toml"
EXPLORER_FILE="$CODEX_HOME/agents/explorer.toml"
MONITOR_FILE="$CODEX_HOME/agents/monitor.toml"
ORCHESTRATOR_FILE="$CODEX_HOME/agents/orchestrator.toml"
REVIEWER_FILE="$CODEX_HOME/agents/reviewer.toml"
AGENTS_FILE="$CODEX_HOME/AGENTS.md"
AUTO_COMMIT_HOOK_FILE="$CODEX_HOME/hooks/auto-commit-on-turn.sh"
FEISHU_HOOK_FILE="$CODEX_HOME/hooks/feishu-notify-on-turn.sh"
AUTOMATION_FILE="$CODEX_HOME/automations/automation/automation.toml"
RUN_FLOW_FILE="$CODEX_HOME/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh"

detect_toml_python() {
  local candidate
  for candidate in python3.11 python3; do
    if ! command -v "$candidate" >/dev/null 2>&1; then
      continue
    fi
    if "$candidate" - <<'PY' >/dev/null 2>&1
try:
    import tomllib
except Exception:
    raise SystemExit(1)
PY
    then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

TOML_PYTHON="$(detect_toml_python || true)"

emit_failure() {
  local category="$1"
  local label="$2"
  local file="${3:-}"
  local detail="${4:-}"

  echo "CHECK_RESULT=FAIL"
  echo "CHECK_CATEGORY=${category}"
  echo "CHECK_LABEL=${label}"
  if [[ -n "$file" ]]; then
    echo "CHECK_FILE=${file}"
  fi
  if [[ -n "$detail" ]]; then
    echo "CHECK_DETAIL=${detail}"
  fi

  echo "FAIL: [${category}] ${label}" >&2
  if [[ -n "$file" ]]; then
    echo "  file: ${file}" >&2
  fi
  if [[ -n "$detail" ]]; then
    echo "  detail: ${detail}" >&2
  fi

  case "$category" in
    missing-file)
      exit 3
      ;;
    syntax)
      exit 4
      ;;
    *)
      exit 5
      ;;
  esac
}

require_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    emit_failure "missing-file" "required file missing" "$file"
  fi
}

require_shell_syntax() {
  local file="$1"
  local label="$2"
  if ! bash -n "$file" >/dev/null 2>&1; then
    emit_failure "syntax" "$label" "$file" "bash syntax check failed"
  fi
  echo "PASS: $label"
}

require_toml_syntax() {
  local file="$1"
  local label="$2"
  if [[ -z "$TOML_PYTHON" ]]; then
    emit_failure "syntax" "$label" "$file" "no python with tomllib support found"
  fi
  if ! "$TOML_PYTHON" - "$file" <<'PY' >/dev/null 2>&1
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
raw = path.read_text(encoding="utf-8")

try:
    import tomllib  # py311+
except Exception:
    raise SystemExit(9)

tomllib.loads(raw)
PY
  then
    emit_failure "syntax" "$label" "$file" "toml parse failed"
  fi
  echo "PASS: $label"
}

require_pattern() {
  local pattern="$1"
  local file="$2"
  local label="$3"
  if rg -n --fixed-strings "$pattern" "$file" >/dev/null; then
    echo "PASS: $label"
  else
    emit_failure "contract" "$label" "$file" "pattern not found: $pattern"
  fi
}

require_file "$CONFIG_FILE"
require_file "$EXPLORER_FILE"
require_file "$MONITOR_FILE"
require_file "$ORCHESTRATOR_FILE"
require_file "$REVIEWER_FILE"
require_file "$AGENTS_FILE"
require_file "$AUTO_COMMIT_HOOK_FILE"
require_file "$FEISHU_HOOK_FILE"
require_file "$AUTOMATION_FILE"
require_file "$RUN_FLOW_FILE"

require_shell_syntax "$0" "contract checker script syntax"
require_toml_syntax "$CONFIG_FILE" "config toml syntax"
require_toml_syntax "$EXPLORER_FILE" "explorer toml syntax"
require_toml_syntax "$MONITOR_FILE" "monitor toml syntax"
require_toml_syntax "$ORCHESTRATOR_FILE" "orchestrator toml syntax"
require_toml_syntax "$REVIEWER_FILE" "reviewer toml syntax"
require_toml_syntax "$AUTOMATION_FILE" "automation toml syntax"
require_shell_syntax "$AUTO_COMMIT_HOOK_FILE" "auto commit hook shell syntax"
require_shell_syntax "$FEISHU_HOOK_FILE" "feishu hook shell syntax"
require_shell_syntax "$RUN_FLOW_FILE" "run flow shell syntax"

require_pattern "max_depth = 1" "$CONFIG_FILE" "global depth guard"
require_pattern "notify = [\"bash\", \"/Users/crane/.codex/hooks/auto-commit-on-turn.sh\"]" "$CONFIG_FILE" "config notify hook points to auto commit"

require_pattern "Do not call \`spawn_agent\`; Explorer lanes are terminal leaf investigations." "$EXPLORER_FILE" "explorer no subagent spawn rule"
require_pattern "Checkpoint SLA:" "$EXPLORER_FILE" "explorer checkpoint SLA header"
require_pattern "Role: Explorer" "$EXPLORER_FILE" "explorer checkpoint role prefix rule"
require_pattern "BLOCK: incomplete Explorer checkpoint" "$EXPLORER_FILE" "explorer checkpoint block rule"

require_pattern "For Explorer-owned investigation waits" "$MONITOR_FILE" "monitor explorer wait escalation rule"
require_pattern "missing Explorer checkpoint after interrupt" "$MONITOR_FILE" "monitor missing checkpoint escalation reason"
require_pattern "long-term non-convergence" "$MONITOR_FILE" "monitor non-convergence escalation signal"

require_pattern "Explorer interrupt issued without a checkpoint template => BLOCK interrupt." "$ORCHESTRATOR_FILE" "orchestrator interrupt template hard block"
require_pattern "depth > 1 as \`non-compliant evidence\`" "$ORCHESTRATOR_FILE" "orchestrator depth governance rule"
require_pattern "Explorer interrupt template (required):" "$ORCHESTRATOR_FILE" "orchestrator explorer checkpoint template"
require_pattern "Root Cause Matrix" "$ORCHESTRATOR_FILE" "orchestrator root cause matrix requirement"

require_pattern "Gate B fails fast if required \`Review Input Packet\` fields are missing." "$REVIEWER_FILE" "reviewer packet fail-fast"
require_pattern "Missing Root Cause Matrix => \`Plan Verdict: FAIL\`." "$REVIEWER_FILE" "reviewer root cause matrix fail-fast"

require_pattern "Root Cause Matrix" "$AGENTS_FILE" "global root cause matrix contract"
require_pattern "Review Input Packet" "$AGENTS_FILE" "global review input packet contract"

require_pattern "OPENCLAW_SKILL_MONITOR_AUTO_FULL_ON_NEW_VERSION=0" "$AUTOMATION_FILE" "automation monitor default no auto full"
require_pattern "check-agent-contracts.sh" "$AUTOMATION_FILE" "automation contract precheck trigger"
require_pattern "CHECK_CATEGORY" "$AUTOMATION_FILE" "automation governance failure classification hint"
require_pattern "agent-turn-complete" "$AUTO_COMMIT_HOOK_FILE" "auto commit turn trigger"
require_pattern "commit -m \"\${message}\"" "$AUTO_COMMIT_HOOK_FILE" "auto commit performs local commit"
require_pattern "notify hook failed" "$FEISHU_HOOK_FILE" "feishu notify failure visible logging"
require_pattern "OPENCLAW_SKILL_MONITOR_AUTO_FULL_ON_NEW_VERSION:-0" "$RUN_FLOW_FILE" "run flow monitor default no auto full"

echo "CHECK_RESULT=PASS"
echo "CHECK_CATEGORY=none"
echo "CHECK_LABEL=all agent contract checks"
echo "PASS: all agent contract checks"
