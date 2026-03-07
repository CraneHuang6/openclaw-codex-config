#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_BIN="${OPENCLAW_BIN:-/opt/homebrew/bin/openclaw}"
OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
GATEWAY_ERR_LOG="${OPENCLAW_GATEWAY_ERR_LOG:-$OPENCLAW_HOME/logs/gateway.err.log}"
SESSIONS_DIR="${OPENCLAW_SESSIONS_DIR:-$OPENCLAW_HOME/agents/main/sessions}"
OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$OPENCLAW_HOME/openclaw.json}"
LINES="${OPENCLAW_FEISHU_PRECHECK_LINES:-120}"
LAUNCHD_LABEL="${OPENCLAW_FEISHU_PRECHECK_LAUNCHD_LABEL:-ai.openclaw.gateway}"
PROXY_TEST_URL="${OPENCLAW_FEISHU_PRECHECK_PROXY_TEST_URL:-https://open.feishu.cn}"
PROXY_TEST_TIMEOUT="${OPENCLAW_FEISHU_PRECHECK_PROXY_TIMEOUT:-5}"

if [[ $# -gt 0 ]]; then
  while (($#)); do
    case "$1" in
      --lines)
        if (($# < 2)); then
          echo "missing value for --lines" >&2
          exit 2
        fi
        LINES="$2"
        shift 2
        ;;
      -h|--help)
        cat <<'USAGE'
Usage: feishu-no-reply-precheck.sh [--lines <n>]

Quickly diagnose "Feishu receives message but no reply" by checking:
1) gateway/channel health
2) recent Feishu inbound + dispatch markers
3) async session delivery-mirror markers when dispatch metrics are false-negative
4) shared-main DM session contention hints from live config + dispatch session
5) fatal plugin/runtime errors in gateway.err.log
USAGE
        exit 0
        ;;
      *)
        echo "unknown option: $1" >&2
        exit 2
        ;;
    esac
  done
fi

if ! [[ "$LINES" =~ ^[0-9]+$ ]] || (( LINES < 20 )); then
  echo "LINES must be >= 20" >&2
  exit 2
fi

if [[ ! -x "$OPENCLAW_BIN" ]]; then
  echo "openclaw binary not executable: $OPENCLAW_BIN" >&2
  exit 2
fi

read_session_dm_scope() {
  local config_path="$1"

  if [[ ! -f "$config_path" ]]; then
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  python3 - "$config_path" <<'PY'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
try:
    data = json.loads(config_path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)

session = data.get("session")
if not isinstance(session, dict):
    raise SystemExit(1)

dm_scope = session.get("dmScope")
if isinstance(dm_scope, str) and dm_scope.strip():
    print(dm_scope.strip())
    raise SystemExit(0)

raise SystemExit(1)
PY
}

detect_async_delivery_mirror() {
  local sessions_dir="$1"
  local channel_logs="$2"

  if [[ ! -d "$sessions_dir" ]]; then
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi

  CHANNEL_LOGS="$channel_logs" python3 - "$sessions_dir" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

sessions_dir = Path(sys.argv[1])
channel_logs = os.environ.get("CHANNEL_LOGS", "")
message_ids = re.findall(r"received message from .*?messageId=([^\s]+)", channel_logs)
if not message_ids:
    raise SystemExit(1)

for session_file in sorted(sessions_dir.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True):
    pending = {}
    try:
        with session_file.open("r", encoding="utf-8") as fh:
            for raw in fh:
                try:
                    obj = json.loads(raw)
                except Exception:
                    continue
                if obj.get("type") != "message":
                    continue
                msg = obj.get("message") or {}
                role = msg.get("role")
                ts = obj.get("timestamp") or ""
                if role == "user":
                    text_parts = []
                    for item in msg.get("content") or []:
                        if item.get("type") == "text":
                            text_parts.append(item.get("text", ""))
                    joined = "\n".join(text_parts)
                    for mid in message_ids:
                        if mid in joined:
                            pending[mid] = ts
                elif role == "assistant" and msg.get("provider") == "openclaw" and msg.get("model") == "delivery-mirror":
                    for mid, user_ts in pending.items():
                        if not user_ts or not ts or ts >= user_ts:
                            print(mid)
                            raise SystemExit(0)
    except SystemExit:
        raise
    except Exception:
        continue

raise SystemExit(1)
PY
}

status_out="$($OPENCLAW_BIN status --deep 2>&1 || true)"
probe_out="$($OPENCLAW_BIN gateway probe 2>&1 || true)"
channel_logs_out="$($OPENCLAW_BIN channels logs --channel feishu --lines "$LINES" 2>&1 || true)"
gateway_err_tail="$(tail -n "$LINES" "$GATEWAY_ERR_LOG" 2>/dev/null || true)"

launchctl_gateway_out="$(launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null || true)"
gateway_proxy_env_lines="$({
  printf '%s\n' "$launchctl_gateway_out" \
    | rg -n '^\s+(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy)\s+=>' -S \
    || true
})"
has_gateway_proxy_env=0
if [[ -n "$gateway_proxy_env_lines" ]]; then
  has_gateway_proxy_env=1
fi

proxy_candidate=""
if (( has_gateway_proxy_env == 1 )); then
  proxy_candidate="$({
    printf '%s\n' "$gateway_proxy_env_lines" \
      | awk -F'=>' '/HTTP_PROXY|http_proxy/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}'
  })"
  if [[ -z "$proxy_candidate" ]]; then
    proxy_candidate="$({
      printf '%s\n' "$gateway_proxy_env_lines" \
        | awk -F'=>' '/HTTPS_PROXY|https_proxy/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}'
    })"
  fi
fi

proxy_reachability="unknown"
if [[ -n "$proxy_candidate" ]]; then
  if curl --proxy "$proxy_candidate" --max-time "$PROXY_TEST_TIMEOUT" -I "$PROXY_TEST_URL" >/dev/null 2>&1; then
    proxy_reachability="reachable"
  else
    proxy_reachability="unreachable"
  fi
fi

fatal_markers=(
  "failed to load plugin"
  "Cannot find module './reply-voice-tts.js'"
  "feishu failed to load"
)

has_fatal_error=0
for marker in "${fatal_markers[@]}"; do
  if [[ "$channel_logs_out" == *"$marker"* ]] || [[ "$gateway_err_tail" == *"$marker"* ]]; then
    has_fatal_error=1
    break
  fi
done

has_inbound=0
if [[ "$channel_logs_out" == *"received message from"* ]]; then
  has_inbound=1
fi

has_dispatch_success=0
if [[ "$channel_logs_out" == *"dispatch complete (queuedFinal=true, replies=1)"* ]] || \
   [[ "$channel_logs_out" == *"sent no-final fallback text via reply"* ]] || \
   [[ "$channel_logs_out" == *"dispatch complete (queuedFinal=true, replies="* ]]; then
  has_dispatch_success=1
fi

has_async_delivery_mirror=0
async_delivery_message_id=""
if async_delivery_message_id="$(detect_async_delivery_mirror "$SESSIONS_DIR" "$channel_logs_out" 2>/dev/null)"; then
  has_async_delivery_mirror=1
fi

session_dm_scope="<unset>"
if read_dm_scope="$(read_session_dm_scope "$OPENCLAW_CONFIG_PATH" 2>/dev/null)"; then
  session_dm_scope="$read_dm_scope"
fi

has_main_session_dispatch=0
if [[ "$channel_logs_out" == *"dispatching to agent (session=agent:main:main)"* ]]; then
  has_main_session_dispatch=1
fi

has_zero_reply_dispatch=0
if [[ "$channel_logs_out" == *"dispatch complete (queuedFinal=false, replies=0)"* ]]; then
  has_zero_reply_dispatch=1
fi

likely_shared_main_dm_contention=0
if (( has_async_delivery_mirror == 1 && has_main_session_dispatch == 1 && has_zero_reply_dispatch == 1 )) && [[ "$session_dm_scope" != "per-channel-peer" ]]; then
  likely_shared_main_dm_contention=1
fi

status_feishu_ok=0
if [[ "$status_out" == *"Feishu"* && "$status_out" == *"ON"* && "$status_out" == *"OK"* ]]; then
  status_feishu_ok=1
fi

probe_ok=0
if [[ "$probe_out" == *"Reachable: yes"* ]]; then
  probe_ok=1
fi

result="warn"
reason="limited evidence"
exit_code=0

if (( has_fatal_error == 1 )); then
  result="fail"
  reason="fatal feishu plugin/runtime error detected"
  exit_code=1
elif (( has_gateway_proxy_env == 1 )) && [[ "$proxy_reachability" == "unreachable" ]]; then
  result="warn"
  reason="gateway launchd proxy env detected but proxy endpoint is unreachable"
  exit_code=0
elif (( status_feishu_ok == 1 && probe_ok == 1 && has_inbound == 1 && has_dispatch_success == 1 )); then
  result="pass"
  reason="inbound + dispatch markers observed"
  exit_code=0
elif (( status_feishu_ok == 1 && probe_ok == 1 && has_inbound == 1 && has_async_delivery_mirror == 1 )); then
  result="pass"
  reason="inbound observed with async session delivery marker"
  exit_code=0
elif (( status_feishu_ok == 1 && probe_ok == 1 && has_inbound == 1 )); then
  result="warn"
  reason="inbound observed but no clear success dispatch marker in recent window"
  exit_code=0
elif (( status_feishu_ok == 1 && probe_ok == 1 )); then
  result="warn"
  reason="channel healthy but no recent inbound marker in recent window"
  exit_code=0
else
  result="fail"
  reason="channel health check failed"
  exit_code=1
fi

echo "RESULT=$result"
echo "REASON=$reason"
echo "WINDOW_LINES=$LINES"
echo

echo "== status --deep (summary) =="
printf '%s\n' "$status_out" | rg -n "Channels|Feishu|Health|Gateway|reachable|OK|ON" -S || true
echo

echo "== gateway probe (summary) =="
printf '%s\n' "$probe_out" | rg -n "Reachable|Connect|RPC|Gateway" -S || true
echo

echo "== feishu channel logs (tail window key lines) =="
printf '%s\n' "$channel_logs_out" | rg -n "received message from|dispatching to agent|dispatch complete|no-final fallback|failed to load|Cannot find module" -S || true
echo

echo "== async session delivery mirror =="
echo "sessions_dir=$SESSIONS_DIR"
echo "has_async_delivery_mirror=$has_async_delivery_mirror"
if [[ -n "$async_delivery_message_id" ]]; then
  echo "async_delivery_message_id=$async_delivery_message_id"
fi
echo

echo "== shared main DM session contention =="
echo "config_path=$OPENCLAW_CONFIG_PATH"
echo "session_dm_scope=$session_dm_scope"
echo "has_main_session_dispatch=$has_main_session_dispatch"
echo "has_zero_reply_dispatch=$has_zero_reply_dispatch"
if (( likely_shared_main_dm_contention == 1 )); then
  echo "LIKELY_ROOT_CAUSE=shared-main-dm-session-contention"
  echo 'RECOMMENDED_FIX=openclaw config set session.dmScope "per-channel-peer"'
  echo "LIVE_CONFIG_HINT=$OPENCLAW_CONFIG_PATH"
  echo "TRACKED_CONFIG_HINT=$OPENCLAW_HOME/openclaw_codex.json"
fi
echo

echo "== gateway.err tail (key lines) =="
printf '%s\n' "$gateway_err_tail" | rg -n "No reply from agent|failed to load plugin|Cannot find module|Request failed with status code 400|Invalid ids|sendMediaFeishu failed" -S || true
echo

echo "== gateway launchd proxy env =="
if (( has_gateway_proxy_env == 1 )); then
  printf '%s\n' "$gateway_proxy_env_lines"
  echo "proxy_candidate=${proxy_candidate:-<none>}"
  echo "proxy_reachability=$proxy_reachability"
  echo "proxy_test_url=$PROXY_TEST_URL"
else
  echo "No proxy env vars found on launchd service $LAUNCHD_LABEL"
fi

exit "$exit_code"
