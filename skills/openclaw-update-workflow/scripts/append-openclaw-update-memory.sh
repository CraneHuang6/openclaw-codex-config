#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_EXTRACTOR="${OPENCLAW_UPDATE_REPORT_EXTRACTOR:-$SCRIPT_DIR/extract-openclaw-update-report-summary.py}"
DEFAULT_MEMORY_FILE="${OPENCLAW_AUTOMATION_MEMORY_FILE:-$HOME/.codex/automations/automation/memory.md}"

report_path=""
memory_file="$DEFAULT_MEMORY_FILE"
extractor="$DEFAULT_EXTRACTOR"

show_help() {
  cat <<'EOF'
Usage: append-openclaw-update-memory.sh --report <path> [options]

Options:
  --report <path>        OpenClaw daily update report markdown path. (required)
  --memory-file <path>   Codex automation memory markdown path.
  --extractor <path>     Override summary extractor script path.
  -h, --help             Show this help message.
EOF
}

while (($#)); do
  case "$1" in
    --report)
      if (($# < 2)); then
        echo "missing value for --report" >&2
        exit 2
      fi
      report_path="$2"
      shift 2
      ;;
    --memory-file)
      if (($# < 2)); then
        echo "missing value for --memory-file" >&2
        exit 2
      fi
      memory_file="$2"
      shift 2
      ;;
    --extractor)
      if (($# < 2)); then
        echo "missing value for --extractor" >&2
        exit 2
      fi
      extractor="$2"
      shift 2
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$report_path" ]]; then
  echo "--report is required" >&2
  exit 2
fi

if [[ ! -x "$extractor" ]]; then
  echo "extractor not executable: $extractor" >&2
  exit 1
fi

mkdir -p "$(dirname "$memory_file")"

summary_kv="$("$extractor" --report "$report_path" --format kv)"

getv() {
  local key="$1"
  printf '%s\n' "$summary_kv" | awk -F= -v k="$key" '$1==k {sub($1 FS,""); print; exit}'
}

{
  printf '%s\n' "- last_run_at: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf '  mode: %s\n' "$(getv mode)"
  printf '  result: %s\n' "$(getv status)"
  printf '  before_version: %s\n' "$(getv before_version)"
  printf '  after_version: %s\n' "$(getv after_version)"
  printf '  dns_precheck: %s\n' "$(getv dns_precheck)"
  printf '  status_deep: %s\n' "$(getv status_deep)"
  printf '  gateway_probe: %s\n' "$(getv gateway_probe)"
  printf '  security_audit: %s\n' "$(getv security_audit)"
  printf '  feishu_probe: %s\n' "$(getv feishu_probe)"
  printf '  first_error_class: %s\n' "$(getv first_error_class)"
  printf '  result_domain: %s\n' "$(getv result_domain)"
  printf '  report: %s\n' "$(getv report_path)"
} >> "$memory_file"

echo "memory_appended=$memory_file"
