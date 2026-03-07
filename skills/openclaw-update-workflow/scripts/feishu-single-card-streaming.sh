#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$OPENCLAW_HOME/openclaw.json}"
BACKUP_FILE=""

usage() {
  cat <<'EOF'
Usage:
  feishu-single-card-streaming.sh [apply|verify|rollback] [--config <path>] [--backup <path>]

Commands:
  apply     Enforce Feishu single-card streaming config and create a timestamped backup.
  verify    Validate target config values (non-zero exit if mismatch).
  rollback  Restore config from backup file (explicit --backup or latest auto backup).
  (default: verify)

Options:
  --config <path>  openclaw.json path (default: ~/.openclaw/openclaw.json)
  --backup <path>  backup file path for rollback; for apply, force backup output path.
  -h, --help       Show this help.
EOF
}

if (($# < 1)); then
  command_name="verify"
else
  command_name="$1"
  shift || true
fi

case "$command_name" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

while (($#)); do
  case "$1" in
    --config)
      if (($# < 2)); then
        echo "missing value for --config" >&2
        exit 2
      fi
      CONFIG_PATH="$2"
      shift 2
      ;;
    --backup)
      if (($# < 2)); then
        echo "missing value for --backup" >&2
        exit 2
      fi
      BACKUP_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq not found in PATH" >&2
    exit 1
  fi
}

require_config_readable() {
  if [[ ! -f "$CONFIG_PATH" ]]; then
    echo "config file not found: $CONFIG_PATH" >&2
    exit 1
  fi
  if [[ ! -r "$CONFIG_PATH" ]]; then
    echo "config file not readable: $CONFIG_PATH" >&2
    exit 1
  fi
}

require_config_writable() {
  require_config_readable
  if [[ ! -w "$CONFIG_PATH" ]]; then
    echo "config file not writable: $CONFIG_PATH" >&2
    exit 1
  fi
}

check_setting() {
  local label="$1"
  local has_expr="$2"
  local value_expr="$3"
  local expected="$4"
  local exists actual
  exists="$(jq -r "$has_expr" "$CONFIG_PATH" 2>/dev/null || echo "__ERROR__")"
  if [[ "$exists" != "true" ]]; then
    echo "FAIL $label expected=$expected actual=__MISSING__" >&2
    return 1
  fi
  actual="$(jq -r "$value_expr" "$CONFIG_PATH" 2>/dev/null || echo "__ERROR__")"
  if [[ "$actual" == "$expected" ]]; then
    echo "OK   $label=$actual"
    return 0
  fi
  echo "FAIL $label expected=$expected actual=$actual" >&2
  return 1
}

verify_config() {
  local failures=0

  check_setting "channels.feishu.streaming" \
    '((.channels // {}) | (.feishu // {}) | has("streaming"))' \
    '((.channels // {}) | (.feishu // {}) | .streaming)' \
    "true" || failures=$((failures + 1))
  check_setting "channels.feishu.blockStreaming" \
    '((.channels // {}) | (.feishu // {}) | has("blockStreaming"))' \
    '((.channels // {}) | (.feishu // {}) | .blockStreaming)' \
    "false" || failures=$((failures + 1))
  check_setting "channels.feishu.renderMode" \
    '((.channels // {}) | (.feishu // {}) | has("renderMode"))' \
    '((.channels // {}) | (.feishu // {}) | .renderMode)' \
    "card" || failures=$((failures + 1))
  check_setting "channels.feishu.textChunkLimit" \
    '((.channels // {}) | (.feishu // {}) | has("textChunkLimit"))' \
    '((.channels // {}) | (.feishu // {}) | .textChunkLimit)' \
    "2000" || failures=$((failures + 1))
  check_setting "channels.feishu.chunkMode" \
    '((.channels // {}) | (.feishu // {}) | has("chunkMode"))' \
    '((.channels // {}) | (.feishu // {}) | .chunkMode)' \
    "newline" || failures=$((failures + 1))
  check_setting "agents.defaults.blockStreamingDefault" \
    '((.agents // {}) | (.defaults // {}) | has("blockStreamingDefault"))' \
    '((.agents // {}) | (.defaults // {}) | .blockStreamingDefault)' \
    "off" || failures=$((failures + 1))
  check_setting "agents.defaults.blockStreamingBreak" \
    '((.agents // {}) | (.defaults // {}) | has("blockStreamingBreak"))' \
    '((.agents // {}) | (.defaults // {}) | .blockStreamingBreak)' \
    "message_end" || failures=$((failures + 1))

  if ((failures > 0)); then
    echo "VERIFY_RESULT=fail" >&2
    return 1
  fi
  echo "VERIFY_RESULT=pass"
  return 0
}

apply_config() {
  local backup_path="${BACKUP_FILE:-${CONFIG_PATH}.feishu-single-card.$(date +%Y%m%d-%H%M%S).bak}"
  local tmp_path
  tmp_path="$(mktemp "${CONFIG_PATH}.tmp.XXXXXX")"
  trap 'rm -f "$tmp_path" >/dev/null 2>&1 || true' EXIT

  cp "$CONFIG_PATH" "$backup_path"
  jq '
    .channels = ((.channels // {}) | if type == "object" then . else {} end) |
    .channels.feishu = ((.channels.feishu // {}) | if type == "object" then . else {} end) |
    .agents = ((.agents // {}) | if type == "object" then . else {} end) |
    .agents.defaults = ((.agents.defaults // {}) | if type == "object" then . else {} end) |
    .channels.feishu.streaming = true |
    .channels.feishu.blockStreaming = false |
    .channels.feishu.renderMode = "card" |
    .channels.feishu.textChunkLimit = 2000 |
    .channels.feishu.chunkMode = "newline" |
    .agents.defaults.blockStreamingDefault = "off" |
    .agents.defaults.blockStreamingBreak = "message_end"
  ' "$CONFIG_PATH" > "$tmp_path"
  mv "$tmp_path" "$CONFIG_PATH"
  trap - EXIT

  echo "APPLY_RESULT=ok"
  echo "CONFIG_PATH=$CONFIG_PATH"
  echo "BACKUP_PATH=$backup_path"
  verify_config
}

latest_backup() {
  local latest=""
  set +e
  latest="$(ls -1t "${CONFIG_PATH}".feishu-single-card.*.bak 2>/dev/null | head -n 1)"
  set -e
  printf '%s' "$latest"
}

rollback_config() {
  local source_backup="$BACKUP_FILE"
  if [[ -z "$source_backup" ]]; then
    source_backup="$(latest_backup)"
  fi
  if [[ -z "$source_backup" ]]; then
    echo "rollback backup not found; pass --backup <path>" >&2
    exit 1
  fi
  if [[ ! -f "$source_backup" ]]; then
    echo "backup file not found: $source_backup" >&2
    exit 1
  fi

  cp "$source_backup" "$CONFIG_PATH"
  echo "ROLLBACK_RESULT=ok"
  echo "CONFIG_PATH=$CONFIG_PATH"
  echo "BACKUP_PATH=$source_backup"
}

require_jq

case "$command_name" in
  apply)
    require_config_writable
    apply_config
    ;;
  verify)
    require_config_readable
    verify_config
    ;;
  rollback)
    require_config_writable
    rollback_config
    ;;
  *)
    echo "unknown command: $command_name" >&2
    usage
    exit 2
    ;;
esac
