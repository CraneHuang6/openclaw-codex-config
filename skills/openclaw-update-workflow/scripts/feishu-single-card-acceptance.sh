#!/usr/bin/env bash
set -euo pipefail

LOG_PATH="${OPENCLAW_FEISHU_ACCEPT_LOG_PATH:-/tmp/openclaw/openclaw-$(date +%F).log}"
CHAT_ID="${OPENCLAW_FEISHU_ACCEPT_CHAT_ID:-}"
MARKER=""
LOOKAROUND_LINES="${OPENCLAW_FEISHU_ACCEPT_LOOKAROUND_LINES:-60}"

usage() {
  cat <<'USAGE'
Usage:
  feishu-single-card-acceptance.sh --marker <unique_marker> [--log <path>] [--chat-id <chat_id>] [--lookaround <lines>]

Purpose:
  Validate one Feishu message window by marker and report whether it meets:
  Started streaming + Closed streaming + dispatch complete replies=1.

Options:
  --marker <text>     Unique marker included in the inbound DM text (required).
  --log <path>        Log path (default: /tmp/openclaw/openclaw-$(date +%F).log).
  --chat-id <id>      Optional chat id filter (example: oc_xxx).
  --lookaround <n>    Lines around marker to locate inbound "received message" (default: 60).
  -h, --help          Show this help.

Exit code:
  0: pass
  1: fail (missing chain or replies != 1)
  2: bad usage
USAGE
}

while (($#)); do
  case "$1" in
    --marker)
      if (($# < 2)); then
        echo "missing value for --marker" >&2
        exit 2
      fi
      MARKER="$2"
      shift 2
      ;;
    --log)
      if (($# < 2)); then
        echo "missing value for --log" >&2
        exit 2
      fi
      LOG_PATH="$2"
      shift 2
      ;;
    --chat-id)
      if (($# < 2)); then
        echo "missing value for --chat-id" >&2
        exit 2
      fi
      CHAT_ID="$2"
      shift 2
      ;;
    --lookaround)
      if (($# < 2)); then
        echo "missing value for --lookaround" >&2
        exit 2
      fi
      LOOKAROUND_LINES="$2"
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

if [[ -z "$MARKER" ]]; then
  echo "--marker is required" >&2
  usage
  exit 2
fi
if [[ ! "$LOOKAROUND_LINES" =~ ^[0-9]+$ ]]; then
  echo "--lookaround must be a non-negative integer" >&2
  exit 2
fi
if [[ ! -f "$LOG_PATH" ]]; then
  echo "log file not found: $LOG_PATH" >&2
  exit 1
fi
if [[ ! -r "$LOG_PATH" ]]; then
  echo "log file not readable: $LOG_PATH" >&2
  exit 1
fi
if ! command -v rg >/dev/null 2>&1; then
  echo "rg command not found" >&2
  exit 1
fi

extract_time() {
  local line="$1"
  printf '%s\n' "$line" | sed -n 's/.*"time":"\([^"]*\)".*/\1/p'
}

extract_msg_id() {
  local line="$1"
  printf '%s\n' "$line" | sed -n -E 's/.*messageId=([^ ,)\"]*).*/\1/p'
}

extract_line_no() {
  local line="$1"
  printf '%s\n' "$line" | cut -d: -f1
}

marker_entry="$(rg -n -F -- "$MARKER" "$LOG_PATH" | tail -n 1 || true)"
if [[ -z "$marker_entry" ]]; then
  echo "RESULT=fail"
  echo "REASON=marker_not_found"
  echo "LOG_PATH=$LOG_PATH"
  echo "MARKER=$MARKER"
  exit 1
fi

marker_line_no="$(extract_line_no "$marker_entry")"
start_line=$((marker_line_no - LOOKAROUND_LINES))
if ((start_line < 1)); then
  start_line=1
fi
end_line=$((marker_line_no + LOOKAROUND_LINES))

inbound_entry="$(awk -v s="$start_line" -v e="$end_line" -v chat="$CHAT_ID" '
NR >= s && NR <= e {
  if (index($0, "received message from") > 0) {
    if (chat == "" || index($0, " in " chat " ") > 0) {
      print NR ":" $0
      exit
    }
  }
}
' "$LOG_PATH")"

if [[ -z "$inbound_entry" ]]; then
  echo "RESULT=fail"
  echo "REASON=inbound_not_found_near_marker"
  echo "LOG_PATH=$LOG_PATH"
  echo "MARKER=$MARKER"
  echo "MARKER_LINE=$marker_line_no"
  echo "LOOKAROUND_LINES=$LOOKAROUND_LINES"
  exit 1
fi

inbound_line_no="$(extract_line_no "$inbound_entry")"
inbound_message_id="$(extract_msg_id "$inbound_entry")"

next_inbound_line_no="$(awk -v s="$((inbound_line_no + 1))" -v chat="$CHAT_ID" '
NR >= s {
  if (index($0, "received message from") > 0) {
    if (chat == "" || index($0, " in " chat " ") > 0) {
      print NR
      exit
    }
  }
}
' "$LOG_PATH")"

line_total="$(wc -l < "$LOG_PATH" | tr -d '[:space:]')"
window_end_line="$line_total"
if [[ -n "$next_inbound_line_no" ]]; then
  window_end_line=$((next_inbound_line_no - 1))
fi

slice="$(awk -v s="$inbound_line_no" -v e="$window_end_line" 'NR >= s && NR <= e { print NR ":" $0 }' "$LOG_PATH")"

dispatch_entry="$(printf '%s\n' "$slice" | awk '/dispatching to agent/ { print; exit }')"
started_entry="$(printf '%s\n' "$slice" | awk '/Started streaming:/ { print; exit }')"
complete_entry="$(printf '%s\n' "$slice" | awk '/dispatch complete \(queuedFinal=.*replies=[0-9]+\)/ { print; exit }')"

card_id=""
started_message_id=""
if [[ -n "$started_entry" ]]; then
  card_id="$(printf '%s\n' "$started_entry" | sed -n 's/.*cardId=\([^, ]*\).*/\1/p')"
  started_message_id="$(extract_msg_id "$started_entry")"
fi

closed_entry=""
if [[ -n "$card_id" ]]; then
  closed_entry="$(printf '%s\n' "$slice" | awk -v card="$card_id" 'index($0, "Closed streaming: cardId=" card) > 0 { print; exit }')"
else
  closed_entry="$(printf '%s\n' "$slice" | awk '/Closed streaming: cardId=/ { print; exit }')"
fi

replies=""
if [[ -n "$complete_entry" ]]; then
  replies="$(printf '%s\n' "$complete_entry" | sed -n -E 's/.*replies=([0-9]+).*/\1/p')"
fi

result="pass"
reason="ok"
if [[ -z "$dispatch_entry" ]]; then
  result="fail"
  reason="dispatching_missing"
elif [[ -z "$started_entry" ]]; then
  result="fail"
  reason="started_streaming_missing"
elif [[ -z "$complete_entry" ]]; then
  result="fail"
  reason="dispatch_complete_missing"
elif [[ -z "$replies" ]]; then
  result="fail"
  reason="replies_parse_failed"
elif [[ "$replies" != "1" ]]; then
  result="fail"
  reason="replies_not_one"
elif [[ -z "$closed_entry" ]]; then
  result="fail"
  reason="closed_streaming_missing"
fi

echo "RESULT=$result"
echo "REASON=$reason"
echo "LOG_PATH=$LOG_PATH"
echo "MARKER=$MARKER"
echo "CHAT_ID=${CHAT_ID:-__not_set__}"
echo "MARKER_LINE=$marker_line_no"
echo "INBOUND_LINE=$inbound_line_no"
echo "WINDOW_END_LINE=$window_end_line"
echo "INBOUND_MESSAGE_ID=${inbound_message_id:-__missing__}"
echo "DISPATCH_LINE=$(extract_line_no "${dispatch_entry:-0:}")"
echo "START_LINE=$(extract_line_no "${started_entry:-0:}")"
echo "START_MESSAGE_ID=${started_message_id:-__missing__}"
echo "CARD_ID=${card_id:-__missing__}"
echo "DISPATCH_COMPLETE_LINE=$(extract_line_no "${complete_entry:-0:}")"
echo "REPLIES=${replies:-__missing__}"
echo "CLOSED_LINE=$(extract_line_no "${closed_entry:-0:}")"
echo "INBOUND_TIME=$(extract_time "${inbound_entry:-}")"
echo "START_TIME=$(extract_time "${started_entry:-}")"
echo "DISPATCH_COMPLETE_TIME=$(extract_time "${complete_entry:-}")"
echo "CLOSED_TIME=$(extract_time "${closed_entry:-}")"

if [[ "$result" == "pass" ]]; then
  echo "VERDICT=PASS"
  exit 0
fi

echo "VERDICT=FAIL" >&2
exit 1
