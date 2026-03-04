#!/usr/bin/env bash
set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

CONFIG_FILE="$CODEX_HOME/config.toml"
EXPLORER_FILE="$CODEX_HOME/agents/explorer.toml"
MONITOR_FILE="$CODEX_HOME/agents/monitor.toml"
ORCHESTRATOR_FILE="$CODEX_HOME/agents/orchestrator.toml"

require_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "FAIL: missing file: $file" >&2
    exit 1
  fi
}

require_pattern() {
  local pattern="$1"
  local file="$2"
  local label="$3"
  if rg -n --fixed-strings "$pattern" "$file" >/dev/null; then
    echo "PASS: $label"
  else
    echo "FAIL: $label (pattern not found)" >&2
    echo "  pattern: $pattern" >&2
    echo "  file: $file" >&2
    exit 1
  fi
}

require_file "$CONFIG_FILE"
require_file "$EXPLORER_FILE"
require_file "$MONITOR_FILE"
require_file "$ORCHESTRATOR_FILE"

require_pattern "max_depth = 1" "$CONFIG_FILE" "global depth guard"

require_pattern "Do not call \`spawn_agent\`; Explorer lanes are terminal leaf investigations." "$EXPLORER_FILE" "explorer no subagent spawn rule"
require_pattern "Checkpoint SLA:" "$EXPLORER_FILE" "explorer checkpoint SLA header"
require_pattern "Role: Explorer" "$EXPLORER_FILE" "explorer checkpoint role prefix rule"
require_pattern "BLOCK: incomplete Explorer checkpoint" "$EXPLORER_FILE" "explorer checkpoint block rule"

require_pattern "For Explorer-owned investigation waits" "$MONITOR_FILE" "monitor explorer wait escalation rule"
require_pattern "missing Explorer checkpoint after interrupt" "$MONITOR_FILE" "monitor missing checkpoint escalation reason"

require_pattern "Explorer interrupt issued without a checkpoint template => BLOCK interrupt." "$ORCHESTRATOR_FILE" "orchestrator interrupt template hard block"
require_pattern "depth > 1 as \`non-compliant evidence\`" "$ORCHESTRATOR_FILE" "orchestrator depth governance rule"
require_pattern "Explorer interrupt template (required):" "$ORCHESTRATOR_FILE" "orchestrator explorer checkpoint template"

echo "PASS: all agent contract checks"
