#!/usr/bin/env bash
set -euo pipefail

SCRIPT="/Users/crane/.codex/skills/openclaw-update-workflow/scripts/feishu-no-reply-precheck.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

run_capture() {
  local out
  set +e
  out="$($SCRIPT "$@" 2>&1)"
  local code=$?
  set -e
  printf '%s\n' "$code" > "$TMP_DIR/last.code"
  printf '%s\n' "$out" > "$TMP_DIR/last.out"
}

assert_code() {
  local expected="$1"
  local actual
  actual="$(cat "$TMP_DIR/last.code")"
  [[ "$actual" == "$expected" ]] || fail "expected exit code=$expected, got $actual"
}

assert_out_contains() {
  local needle="$1"
  rg -q --fixed-strings "$needle" "$TMP_DIR/last.out" || fail "missing output: $needle"
}

make_fake_openclaw() {
  local bin="$1"
  local log_blob="$2"
  cat > "$bin" <<EOF2
#!/usr/bin/env bash
set -euo pipefail
cmd="\${1:-}"
sub="\${2:-}"
case "\$cmd \$sub" in
  "status --deep")
    cat <<'OUT'
Channels
Feishu ON OK
Gateway OK
OUT
    ;;
  "gateway probe")
    cat <<'OUT'
Gateway
Reachable: yes
RPC: ok
OUT
    ;;
  "channels logs")
    cat <<'OUT'
$log_blob
OUT
    ;;
  *)
    echo "unexpected command: \$*" >&2
    exit 2
    ;;
esac
EOF2
  chmod +x "$bin"
}

write_session_file() {
  local sessions_dir="$1"
  local sid="$2"
  local message_id="$3"
  local include_mirror="$4"
  mkdir -p "$sessions_dir"
  cat > "$sessions_dir/${sid}.jsonl" <<EOF2
{"type":"session","version":3,"id":"${sid}","timestamp":"2026-03-07T02:32:34.000Z"}
{"type":"message","timestamp":"2026-03-07T02:32:34.963Z","message":{"role":"user","content":[{"type":"text","text":"[message_id: ${message_id}] Crane: 你检查一下吧。"}]}}
EOF2
  if [[ "$include_mirror" == "1" ]]; then
    cat >> "$sessions_dir/${sid}.jsonl" <<'EOF2'
{"type":"message","timestamp":"2026-03-07T02:33:34.409Z","message":{"role":"assistant","content":[{"type":"text","text":"异步回复已送达"}],"api":"openai-responses","provider":"openclaw","model":"delivery-mirror","stopReason":"stop"}}
EOF2
  fi
}

scenario_async_delivery_mirror_passes() {
  local td="$TMP_DIR/async-pass"
  local home="$td/home"
  local bin="$td/openclaw"
  local sessions_dir="$home/agents/main/sessions"
  local err_log="$home/logs/gateway.err.log"
  local channel_log
  mkdir -p "$home/logs"
  : > "$err_log"
  channel_log=$'2026-03-07T02:32:33.382Z [feishu] feishu[default]: received message from ou_x in oc_x (p2p) messageId=om_async_1 eventId=evt_1\n2026-03-07T02:32:33.407Z [feishu] feishu[default]: dispatching to agent (session=agent:main:main)\n2026-03-07T02:32:33.527Z [feishu] feishu[default]: dispatch complete (queuedFinal=false, replies=0)'
  make_fake_openclaw "$bin" "$channel_log"
  write_session_file "$sessions_dir" "sid-async" "om_async_1" 1

  OPENCLAW_BIN="$bin" OPENCLAW_HOME="$home" GATEWAY_ERR_LOG="$err_log" run_capture

  assert_code 0
  assert_out_contains "RESULT=pass"
  assert_out_contains "REASON=inbound observed with async session delivery marker"
}

scenario_missing_async_marker_stays_warn() {
  local td="$TMP_DIR/async-warn"
  local home="$td/home"
  local bin="$td/openclaw"
  local sessions_dir="$home/agents/main/sessions"
  local err_log="$home/logs/gateway.err.log"
  local channel_log
  mkdir -p "$home/logs"
  : > "$err_log"
  channel_log=$'2026-03-07T02:32:33.382Z [feishu] feishu[default]: received message from ou_x in oc_x (p2p) messageId=om_async_2 eventId=evt_2\n2026-03-07T02:32:33.407Z [feishu] feishu[default]: dispatching to agent (session=agent:main:main)\n2026-03-07T02:32:33.527Z [feishu] feishu[default]: dispatch complete (queuedFinal=false, replies=0)'
  make_fake_openclaw "$bin" "$channel_log"
  write_session_file "$sessions_dir" "sid-warn" "om_async_2" 0

  OPENCLAW_BIN="$bin" OPENCLAW_HOME="$home" GATEWAY_ERR_LOG="$err_log" run_capture

  assert_code 0
  assert_out_contains "RESULT=warn"
  assert_out_contains "REASON=inbound observed but no clear success dispatch marker in recent window"
}

scenario_shared_main_dm_scope_diagnosis() {
  local td="$TMP_DIR/dm-scope"
  local home="$td/home"
  local bin="$td/openclaw"
  local sessions_dir="$home/agents/main/sessions"
  local err_log="$home/logs/gateway.err.log"
  local channel_log
  mkdir -p "$home/logs"
  : > "$err_log"
  cat > "$home/openclaw.json" <<'EOF2'
{"session":{"idleMinutes":60}}
EOF2
  channel_log=$'2026-03-07T02:32:33.382Z [feishu] feishu[default]: received message from ou_x in oc_x (p2p) messageId=om_async_3 eventId=evt_3
2026-03-07T02:32:33.407Z [feishu] feishu[default]: dispatching to agent (session=agent:main:main)
2026-03-07T02:32:33.527Z [feishu] feishu[default]: dispatch complete (queuedFinal=false, replies=0)'
  make_fake_openclaw "$bin" "$channel_log"
  write_session_file "$sessions_dir" "sid-dm-scope" "om_async_3" 1

  OPENCLAW_BIN="$bin" OPENCLAW_HOME="$home" GATEWAY_ERR_LOG="$err_log" run_capture

  assert_code 0
  assert_out_contains "RESULT=pass"
  assert_out_contains "LIKELY_ROOT_CAUSE=shared-main-dm-session-contention"
  assert_out_contains 'RECOMMENDED_FIX=openclaw config set session.dmScope "per-channel-peer"'
  assert_out_contains "session_dm_scope=<unset>"
}

scenario_async_delivery_mirror_passes
scenario_missing_async_marker_stays_warn
scenario_shared_main_dm_scope_diagnosis

echo "[PASS] feishu-no-reply-precheck tests"
