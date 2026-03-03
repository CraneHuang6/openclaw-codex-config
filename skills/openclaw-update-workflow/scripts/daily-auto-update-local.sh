#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_OPENCLAW_HOME="${OPENCLAW_HOME:-$HOME/.openclaw}"
DEFAULT_OPENCLAW_BIN="${OPENCLAW_BIN:-/opt/homebrew/bin/openclaw}"
DEFAULT_UPDATE_SCRIPT="${OPENCLAW_DAILY_UPDATE_SCRIPT:-$SCRIPT_DIR/update-openclaw-with-feishu-repatch.sh}"
DEFAULT_SNAPSHOT_SCRIPT="${OPENCLAW_DAILY_UPDATE_SNAPSHOT_SCRIPT:-$SCRIPT_DIR/openclaw-update-snapshot-rollback.sh}"
DEFAULT_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-$DEFAULT_OPENCLAW_HOME/openclaw.json}"
DEFAULT_REPORT_DIR="${OPENCLAW_DAILY_UPDATE_REPORT_DIR:-$DEFAULT_OPENCLAW_HOME/workspace/outputs/system-updates}"
DEFAULT_MAX_RETRIES="${OPENCLAW_DAILY_UPDATE_MAX_RETRIES:-3}"
DEFAULT_RETRY_SLEEP_SECONDS="${OPENCLAW_DAILY_UPDATE_RETRY_SLEEP_SECONDS:-10}"
DEFAULT_REQUIRED_LAUNCHD_LABELS="${OPENCLAW_DAILY_UPDATE_REQUIRED_LAUNCHD_LABELS:-ai.openclaw.gateway,ai.openclaw.config-guard,ai.openclaw.config-guard-watch}"
DEFAULT_RETRY_REGISTRIES="${OPENCLAW_DAILY_UPDATE_RETRY_REGISTRIES:-https://registry.npmjs.org,https://registry.npmmirror.com}"
DEFAULT_KNOWN_BUG_FIX_SCRIPT="${OPENCLAW_DAILY_UPDATE_KNOWN_BUG_FIX_SCRIPT:-$DEFAULT_OPENCLAW_HOME/scripts/openclaw-update-known-bug-fix.sh}"
DEFAULT_EXPECTED_PRIMARY_MODEL="${OPENCLAW_DAILY_UPDATE_EXPECTED_PRIMARY_MODEL:-qmcode/gpt-5.3-codex}"
DEFAULT_EXPECTED_FALLBACKS_JSON="${OPENCLAW_DAILY_UPDATE_EXPECTED_FALLBACKS_JSON:-[\"qmcode/gpt-5.2\",\"openrouter/arcee-ai/trinity-large-preview:free\"]}"

do_update=false
openclaw_home="$DEFAULT_OPENCLAW_HOME"
openclaw_bin="$DEFAULT_OPENCLAW_BIN"
update_script="$DEFAULT_UPDATE_SCRIPT"
snapshot_script="$DEFAULT_SNAPSHOT_SCRIPT"
skills_sync_script="${OPENCLAW_DAILY_UPDATE_SKILLS_SYNC_SCRIPT:-$SCRIPT_DIR/update-installed-skills.sh}"
skills_root="${OPENCLAW_DAILY_UPDATE_SKILLS_ROOT:-}"
skills_sync_enabled="${OPENCLAW_DAILY_UPDATE_SKILLS_SYNC:-1}"
config_path="$DEFAULT_CONFIG_PATH"
report_dir="$DEFAULT_REPORT_DIR"
feishu_target="${OPENCLAW_DAILY_UPDATE_FEISHU_TARGET:-}"
npm_registry="${OPENCLAW_NPM_REGISTRY:-}"
max_retries="$DEFAULT_MAX_RETRIES"
retry_sleep_seconds="$DEFAULT_RETRY_SLEEP_SECONDS"
required_launchd_labels="$DEFAULT_REQUIRED_LAUNCHD_LABELS"
expected_primary_model="$DEFAULT_EXPECTED_PRIMARY_MODEL"
expected_fallbacks_json="$DEFAULT_EXPECTED_FALLBACKS_JSON"
skip_launchd_check="${OPENCLAW_DAILY_UPDATE_SKIP_LAUNCHD_CHECK:-0}"
latest_version_cmd="${OPENCLAW_DAILY_UPDATE_LATEST_VERSION_CMD:-}"
check_latest_on_skip="${OPENCLAW_DAILY_UPDATE_CHECK_LATEST_ON_SKIP:-0}"
retry_registries="$DEFAULT_RETRY_REGISTRIES"
known_bug_fix_script="$DEFAULT_KNOWN_BUG_FIX_SCRIPT"
known_bug_fix_enabled="${OPENCLAW_DAILY_UPDATE_KNOWN_BUG_FIX:-1}"
known_bug_fix_apply="${OPENCLAW_DAILY_UPDATE_KNOWN_BUG_FIX_APPLY:-0}"
dns_http_precheck_enabled="${OPENCLAW_DAILY_UPDATE_DNS_HTTP_PRECHECK:-1}"
dns_http_precheck_attempts="${OPENCLAW_DAILY_UPDATE_DNS_HTTP_PRECHECK_ATTEMPTS:-2}"
dns_http_precheck_connect_timeout="${OPENCLAW_DAILY_UPDATE_DNS_HTTP_PRECHECK_CONNECT_TIMEOUT:-3}"
dns_http_precheck_max_time="${OPENCLAW_DAILY_UPDATE_DNS_HTTP_PRECHECK_MAX_TIME:-8}"
dns_precheck_rounds="${OPENCLAW_DAILY_UPDATE_DNS_PRECHECK_ROUNDS:-2}"
dns_precheck_sleep_seconds="${OPENCLAW_DAILY_UPDATE_DNS_PRECHECK_SLEEP_SECONDS:-30}"
gateway_self_heal_enabled="${OPENCLAW_DAILY_UPDATE_GATEWAY_SELF_HEAL:-1}"
gateway_app_evict_enabled="${OPENCLAW_DAILY_UPDATE_GATEWAY_APP_EVICT:-1}"
pairing_self_heal_enabled="${OPENCLAW_DAILY_UPDATE_PAIRING_SELF_HEAL:-1}"

show_help() {
  cat <<'EOF'
Usage: daily-auto-update-local.sh [options]

Options:
  --with-update                  Run `openclaw update` inside unified patch script.
  --skip-update                  Skip `openclaw update` (default).
  --openclaw-home <path>         Override OPENCLAW_HOME.
  --openclaw-bin <path>          Override openclaw binary.
  --update-script <path>         Override unified update+patch script.
  --snapshot-script <path>       Override snapshot/rollback script.
  --skills-sync-script <path>    Override installed-skills sync script.
  --skills-root <path>           Override installed-skills root directory.
  --skip-skills-sync             Skip installed-skills git sync.
  --config-path <path>           Override openclaw config path.
  --report-dir <path>            Override report output directory.
  --feishu-target <id>           Optional Feishu target for short completion notice.
  --npm-registry <url>           Optional npm registry used when --with-update is enabled.
  --max-retries <n>              Max self-heal phases during --with-update (1-3).
  --retry-sleep-seconds <n>      Sleep seconds between retries.
  --latest-version-cmd <cmd>     Command that prints latest version tag (default: GitHub tags).
  --check-latest-on-skip         Resolve latest stable version even in --skip-update mode.
  --retry-registries <csv>       Fallback registries for self-heal phase 2.
  --known-bug-fix-script <path>  Override known-bug-fix handler script path.
  --disable-known-bug-fix        Disable known-bug-fix handler execution.
  --enable-known-bug-fix-apply   Execute known fixes in apply mode (default is dry-run).
  --dns-http-precheck            Enable HTTP DNS precheck before --with-update (default).
  --no-dns-http-precheck         Disable HTTP DNS precheck before --with-update.
  --dns-precheck-rounds <n>      Retry full DNS/HTTP precheck rounds before failing (default: 2).
  --dns-precheck-sleep <n>       Sleep seconds between DNS precheck rounds (default: 30).
  --required-launchd-labels <s>  Comma-separated launchd labels required after update.
  --skip-launchd-check           Skip launchd loaded-state checks.
  --disable-gateway-self-heal    Disable gateway restart self-heal for status/probe checks.
  --disable-gateway-app-evict    Disable app-evict phase during gateway self-heal.
  --disable-pairing-self-heal    Disable pairing-repair auto-approve self-heal.
  -h, --help                     Show this help message.
EOF
}

trim_spaces() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

normalize_registry() {
  local reg
  reg="$(trim_spaces "$1")"
  reg="${reg%/}"
  printf '%s' "$reg"
}

extract_host_from_url() {
  local url
  url="$(trim_spaces "${1:-}")"
  if [[ -z "$url" ]]; then
    return 1
  fi
  url="${url#http://}"
  url="${url#https://}"
  url="${url%%/*}"
  url="${url%%:*}"
  url="$(trim_spaces "$url")"
  if [[ -z "$url" ]]; then
    return 1
  fi
  printf '%s' "$url"
}

can_resolve_host() {
  local host="$1"
  if command -v dscacheutil >/dev/null 2>&1; then
    dscacheutil -q host -a name "$host" >/dev/null 2>&1 && return 0
  fi
  python3 - "$host" <<'PY' >/dev/null 2>&1
import socket
import sys
socket.getaddrinfo(sys.argv[1], None)
PY
}

resolve_dns_http_precheck_proxy() {
  local candidate
  for candidate in \
    "${OPENCLAW_DAILY_UPDATE_DNS_HTTP_PRECHECK_PROXY:-}" \
    "${HTTPS_PROXY:-}" \
    "${HTTP_PROXY:-}" \
    "${https_proxy:-}" \
    "${http_proxy:-}"
  do
    candidate="$(trim_spaces "${candidate:-}")"
    if [[ -n "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

sanitize_proxy_for_log() {
  local raw
  raw="$(trim_spaces "${1:-}")"
  if [[ -z "$raw" ]]; then
    printf '<empty>'
    return 0
  fi
  local scheme="" rest
  rest="$raw"
  if [[ "$rest" == *"://"* ]]; then
    scheme="${rest%%://*}"
    rest="${rest#*://}"
  fi
  # Strip credentials if present.
  if [[ "$rest" == *"@"* ]]; then
    rest="${rest##*@}"
  fi
  if [[ -n "$scheme" ]]; then
    printf '%s://%s' "$scheme" "$rest"
  else
    printf '%s' "$rest"
  fi
}

check_local_port_state() {
  local host="$1"
  local port="$2"
  if ! command -v nc >/dev/null 2>&1; then
    printf 'missing'
    return 0
  fi
  if nc -z "$host" "$port" >/dev/null 2>&1; then
    printf 'ok'
  else
    printf 'fail'
  fi
}

collect_net_debug_summary() {
  local selected_proxy http_proxy_log https_proxy_log all_proxy_log no_proxy_log selected_proxy_log
  http_proxy_log="$(sanitize_proxy_for_log "${HTTP_PROXY:-${http_proxy:-}}")"
  https_proxy_log="$(sanitize_proxy_for_log "${HTTPS_PROXY:-${https_proxy:-}}")"
  all_proxy_log="$(sanitize_proxy_for_log "${ALL_PROXY:-${all_proxy:-}}")"
  no_proxy_log="$(trim_spaces "${NO_PROXY:-${no_proxy:-}}")"
  [[ -n "$no_proxy_log" ]] || no_proxy_log="<empty>"
  selected_proxy="$(resolve_dns_http_precheck_proxy || true)"
  selected_proxy_log="$(sanitize_proxy_for_log "$selected_proxy")"

  printf '%s\n' \
    "PATH=$PATH" \
    "HTTP_PROXY=$http_proxy_log" \
    "HTTPS_PROXY=$https_proxy_log" \
    "ALL_PROXY=$all_proxy_log" \
    "NO_PROXY=$no_proxy_log" \
    "dns_http_precheck_proxy_selected=$selected_proxy_log" \
    "proxy_port_7890=$(check_local_port_state 127.0.0.1 7890)" \
    "proxy_port_7891=$(check_local_port_state 127.0.0.1 7891)"
}

run_http_head_precheck() {
  local url="$1"
  local label="$2"
  local attempts="${dns_http_precheck_attempts:-2}"
  local connect_timeout="${dns_http_precheck_connect_timeout:-3}"
  local max_time="${dns_http_precheck_max_time:-8}"
  local tmp_err http_code code attempt err_summary precheck_proxy proxy_log
  local -a curl_args

  if ! command -v curl >/dev/null 2>&1; then
    printf 'http:%s=fail reason=curl-missing url=%s' "$label" "$url"
    return 1
  fi

  precheck_proxy="$(resolve_dns_http_precheck_proxy || true)"
  proxy_log="$(sanitize_proxy_for_log "$precheck_proxy")"
  tmp_err="$(mktemp -t openclaw-http-precheck.XXXXXX 2>/dev/null || printf '/tmp/openclaw-http-precheck.%s.%s' "$$" "$RANDOM")"
  : >"$tmp_err"
  for (( attempt = 1; attempt <= attempts; attempt++ )); do
    curl_args=(
      -I -sS -o /dev/null -w '%{http_code}'
      --connect-timeout "$connect_timeout"
      --max-time "$max_time"
    )
    if [[ -n "$precheck_proxy" ]]; then
      curl_args+=( --proxy "$precheck_proxy" )
    fi
    curl_args+=( "$url" )
    set +e
    http_code="$(curl "${curl_args[@]}" 2>"$tmp_err")"
    code=$?
    set -e
    err_summary="$(tr '\n' ' ' < "$tmp_err" | sed 's/[[:space:]]\+/ /g')"
    err_summary="$(trim_spaces "$err_summary")"
    if (( code == 0 )) && [[ -n "$http_code" && "$http_code" != "000" ]]; then
      rm -f "$tmp_err" >/dev/null 2>&1 || true
      printf 'http:%s=ok attempt=%s code=%s url=%s proxy=%s' "$label" "$attempt" "$http_code" "$url" "$proxy_log"
      return 0
    fi
    if (( attempt < attempts )); then
      sleep 1
    fi
  done
  rm -f "$tmp_err" >/dev/null 2>&1 || true
  printf 'http:%s=fail attempts=%s last_exit=%s last_code=%s url=%s proxy=%s err=%s' \
    "$label" "$attempts" "${code:-1}" "${http_code:-000}" "$url" "$proxy_log" "${err_summary:-none}"
  return 1
}

run_dns_precheck() {
  local registry_url="${1:-}"
  local hosts=()
  local urls=()
  local host url registry_norm registry_host http_label http_out
  local out=""

  registry_norm="$(normalize_registry "$registry_url")"
  hosts+=("api.github.com")
  urls+=("https://api.github.com")
  registry_host="$(extract_host_from_url "$registry_norm" || true)"
  if [[ -n "$registry_host" ]]; then
    hosts+=("$registry_host")
  fi
  if [[ -n "$registry_norm" ]]; then
    urls+=("$registry_norm")
  fi

  local seen="|"
  local unique_hosts=()
  for host in "${hosts[@]}"; do
    if [[ "$seen" == *"|$host|"* ]]; then
      continue
    fi
    seen="${seen}${host}|"
    unique_hosts+=("$host")
  done
  seen="|"
  local unique_urls=()
  for url in "${urls[@]}"; do
    if [[ -z "$url" ]]; then
      continue
    fi
    if [[ "$seen" == *"|$url|"* ]]; then
      continue
    fi
    seen="${seen}${url}|"
    unique_urls+=("$url")
  done

  local failed=0
  for host in "${unique_hosts[@]}"; do
    if can_resolve_host "$host"; then
      out="${out}
dns:${host}=ok"
    else
      failed=1
      out="${out}
dns:${host}=fail"
    fi
  done
  if [[ "$dns_http_precheck_enabled" == "1" ]]; then
    for url in "${unique_urls[@]}"; do
      if [[ "$url" == "https://api.github.com" ]]; then
        http_label="api.github.com"
      else
        http_label="$(extract_host_from_url "$url" || printf '%s' "$url")"
      fi
      if http_out="$(run_http_head_precheck "$url" "$http_label" 2>&1)"; then
        out="${out}
${http_out}"
      else
        failed=1
        out="${out}
${http_out}"
      fi
    done
  else
    out="${out}
http_precheck=disabled"
  fi
  out="$(trim_spaces "$out")"
  printf '%s' "$out"
  return "$failed"
}

detect_file_mode() {
  local path="$1"
  local mode=""
  mode="$(stat -f '%Lp' "$path" 2>/dev/null || true)"
  if [[ -z "$mode" ]]; then
    mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
  fi
  printf '%s' "$mode"
}

update_output_has_dns_failure() {
  local text="$1"
  local lower
  lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')"
  [[ "$lower" == *"curl: (6)"* ]] || [[ "$lower" == *"could not resolve host"* ]] || [[ "$lower" == *"enotfound"* ]]
}

resolve_known_bug_fix_signature() {
  local first_error_class="$1"
  local patch_out="$2"
  local status_out="$3"
  local lower_patch lower_status
  lower_patch="$(printf '%s' "$patch_out" | tr '[:upper:]' '[:lower:]')"
  lower_status="$(printf '%s' "$status_out" | tr '[:upper:]' '[:lower:]')"

  if [[ "$first_error_class" == "dns_network" ]]; then
    printf 'dns_network'
    return 0
  fi
  if [[ "$lower_status" == *"gateway closed"* ]] && [[ "$lower_status" == *"1006"* ]]; then
    printf 'gateway_1006'
    return 0
  fi
  if [[ "$patch_out" == *"reply voice script not found"* ]] || [[ "$patch_out" == *"无法找到语音脚本"* ]]; then
    printf 'missing_reply_voice_script'
    return 0
  fi
  if { [[ "$lower_patch" == *"tryrecordmessagepersistent"* ]] || [[ "$lower_status" == *"tryrecordmessagepersistent"* ]]; } &&
     { [[ "$lower_patch" == *"is not a function"* ]] || [[ "$lower_status" == *"is not a function"* ]] || [[ "$lower_patch" == *"missing marker"* ]] || [[ "$lower_status" == *"missing marker"* ]]; }; then
    printf 'missing_dedup_persistent_export'
    return 0
  fi
  if [[ "$lower_patch" == *"didaapi"* ]] && [[ "$lower_patch" == *"target file missing:"* ]]; then
    printf 'didaapi_target_missing'
    return 0
  fi
  if [[ -n "$first_error_class" && "$first_error_class" != "none" ]]; then
    printf '%s' "$first_error_class"
    return 0
  fi
  printf 'none'
}

is_stable_version_tag() {
  local tag
  tag="$(trim_spaces "$1")"
  [[ "$tag" =~ ^v?[0-9]+([.][0-9]+)*$ ]]
}

version_gt() {
  local latest="$1"
  local current="$2"
  python3 - "$latest" "$current" <<'PY'
import re
import sys

latest = sys.argv[1].strip()
current = sys.argv[2].strip()

def parse(version: str):
    version = version.strip()
    if version.startswith("v"):
        version = version[1:]
    nums = [int(x) for x in re.findall(r"\d+", version)]
    return tuple(nums)

lp = parse(latest)
cp = parse(current)
if lp > cp:
    raise SystemExit(0)
raise SystemExit(1)
PY
}

resolve_latest_version() {
  local cmd output
  cmd="$latest_version_cmd"
  if [[ -z "$cmd" ]]; then
    cmd='git ls-remote --tags https://github.com/openclaw/openclaw.git 2>/dev/null | awk -F/ '\''/refs\/tags\/v[0-9]/{print $3}'\'' | grep -E '\''^v[0-9]+([.][0-9]+)*$'\'' | sort -V | tail -n1'
  fi
  set +e
  output="$(eval "$cmd" 2>/dev/null)"
  local code=$?
  set -e
  if (( code != 0 )); then
    return 1
  fi
  output="$(printf '%s\n' "$output" | head -n1 | tr -d '\r')"
  output="$(trim_spaces "$output")"
  if [[ -z "$output" ]]; then
    return 1
  fi
  if ! is_stable_version_tag "$output"; then
    return 3
  fi
  printf '%s' "$output"
}

pick_retry_registry() {
  local prefer_exclude="$1"
  local raw reg normalized
  IFS=',' read -r -a raw <<< "$retry_registries"
  prefer_exclude="$(normalize_registry "$prefer_exclude")"
  for reg in "${raw[@]}"; do
    normalized="$(normalize_registry "$reg")"
    if [[ -z "$normalized" ]]; then
      continue
    fi
    if [[ -n "$prefer_exclude" && "$normalized" == "$prefer_exclude" ]]; then
      continue
    fi
    printf '%s' "$normalized"
    return 0
  done
  return 1
}

count_gateway_node_role_errors() {
  local window_lines="${1:-4000}"
  if [[ ! -f "$gateway_log_path" ]]; then
    printf '0'
    return 0
  fi
  local count
  count="$(tail -n "$window_lines" "$gateway_log_path" 2>/dev/null | grep -c 'unauthorized role: node' || true)"
  if [[ -z "$count" ]]; then
    count=0
  fi
  printf '%s' "$count"
}

has_safe_repair_pairing_request() {
  local payload="$1"
  PAYLOAD="$payload" python3 - <<'PY'
import json
import os
import sys
from collections import deque

ALLOWED_CLIENTS = {"cli", "gateway-client"}
PENDING_STATES = {"pending", "requested", "awaiting_approval", "waiting", "unapproved"}

raw = os.environ.get("PAYLOAD", "").strip()
if not raw:
    raise SystemExit(1)

data = None
candidates = [raw]
for line in raw.splitlines():
    line = line.strip()
    if line.startswith("{") or line.startswith("["):
        candidates.append(line)

for candidate in candidates:
    try:
        data = json.loads(candidate)
        break
    except Exception:
        continue

if data is None:
    raise SystemExit(1)

def as_bool(value):
    if isinstance(value, bool):
        return value
    if value is None:
        return False
    text = str(value).strip().lower()
    return text in {"1", "true", "yes", "y", "on"}

def is_candidate(item):
    if not isinstance(item, dict):
        return False
    is_repair = as_bool(
        item.get("isRepair", item.get("is_repair", item.get("repair")))
    )
    if not is_repair:
        return False
    client = str(
        item.get("clientId", item.get("client_id", item.get("client", "")))
    ).strip().lower()
    if client not in ALLOWED_CLIENTS:
        return False
    status = str(item.get("status", item.get("state", "pending"))).strip().lower()
    return status in PENDING_STATES

queue = deque([data])
seen = set()
while queue:
    current = queue.popleft()
    current_id = id(current)
    if current_id in seen:
        continue
    seen.add(current_id)
    if isinstance(current, dict):
        if is_candidate(current):
            raise SystemExit(0)
        for value in current.values():
            queue.append(value)
    elif isinstance(current, list):
        queue.extend(current)

raise SystemExit(1)
PY
}

run_gateway_command_with_self_heal() {
  local label="$1"
  local out_var="$2"
  local code_var="$3"
  shift 3
  local cmd=("$@")

  local out code
  local node_role_before node_role_after node_role_delta node_role_new
  node_role_before="$(count_gateway_node_role_errors)"
  set +e
  out="$("${cmd[@]}" 2>&1)"
  code=$?
  set -e

  local action_parts=()
  local timeout_hint="no"
  if [[ "$out" == *"gateway timeout"* ]]; then
    timeout_hint="yes"
  fi
  node_role_after="$(count_gateway_node_role_errors)"
  node_role_delta=0
  node_role_new="no"
  if [[ "$node_role_before" =~ ^[0-9]+$ && "$node_role_after" =~ ^[0-9]+$ ]]; then
    if (( node_role_after > node_role_before )); then
      node_role_delta=$((node_role_after - node_role_before))
      node_role_new="yes"
    fi
  fi

  if [[ "$pairing_self_heal_enabled" == "1" && $code -ne 0 ]]; then
    local lower_out
    lower_out="$(printf '%s' "$out" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lower_out" == *"pairing required"* ]]; then
      set +e
      local pairing_list_out pairing_list_code
      pairing_list_out="$("$openclaw_bin" devices list --json 2>&1)"
      pairing_list_code=$?
      set -e
      local pairing_safe="no"
      if (( pairing_list_code == 0 )) && has_safe_repair_pairing_request "$pairing_list_out"; then
        pairing_safe="yes"
      fi
      gateway_self_heal_log="${gateway_self_heal_log}
[${label}] pairing-repair-check exit=${pairing_list_code} safe=${pairing_safe}
${pairing_list_out}
"
      if [[ "$pairing_safe" == "yes" ]]; then
        set +e
        local pairing_approve_out pairing_approve_code
        pairing_approve_out="$("$openclaw_bin" devices approve --latest --json 2>&1)"
        pairing_approve_code=$?
        set -e
        gateway_self_heal_log="${gateway_self_heal_log}
[${label}] approve-pairing-repair exit=${pairing_approve_code}
${pairing_approve_out}
"
        if (( pairing_approve_code == 0 )); then
          action_parts+=("approve-pairing-repair")
          sleep 1
          set +e
          out="$("${cmd[@]}" 2>&1)"
          code=$?
          set -e
        fi
      fi
    fi
  fi

  if [[ "$gateway_self_heal_enabled" == "1" && $code -ne 0 ]]; then
    if [[ "$timeout_hint" == "yes" || "$node_role_new" == "yes" ]]; then
      set +e
      local restart_out restart_code
      restart_out="$("$openclaw_bin" gateway restart 2>&1)"
      restart_code=$?
      set -e
      gateway_self_heal_log="${gateway_self_heal_log}
[${label}] restart-gateway exit=${restart_code} timeout=${timeout_hint} node_role_before=${node_role_before} node_role_after=${node_role_after} node_role_delta=${node_role_delta}
${restart_out}
"
      if (( restart_code == 0 )); then
        action_parts+=("restart-gateway")
        sleep 2
        set +e
        out="$("${cmd[@]}" 2>&1)"
        code=$?
        set -e
      fi

      if [[ "$gateway_app_evict_enabled" == "1" && $code -ne 0 ]]; then
        local node_role_after_retry node_role_retry_delta node_role_retry_new
        node_role_after_retry="$(count_gateway_node_role_errors)"
        node_role_retry_delta=0
        node_role_retry_new="no"
        if [[ "$node_role_after" =~ ^[0-9]+$ && "$node_role_after_retry" =~ ^[0-9]+$ ]]; then
          if (( node_role_after_retry > node_role_after )); then
            node_role_retry_delta=$((node_role_after_retry - node_role_after))
            node_role_retry_new="yes"
          fi
        fi
        if [[ "$node_role_retry_new" == "yes" ]]; then
          set +e
          pkill -f '/Applications/OpenClaw.app/Contents/MacOS/OpenClaw' >/dev/null 2>&1
          local evict_code
          evict_code=$?
          restart_out="$("$openclaw_bin" gateway restart 2>&1)"
          restart_code=$?
          set -e
          gateway_self_heal_log="${gateway_self_heal_log}
[${label}] evict-openclaw-app exit=${evict_code}; restart-gateway exit=${restart_code} node_role_before=${node_role_after} node_role_after=${node_role_after_retry} node_role_delta=${node_role_retry_delta}
${restart_out}
"
          if (( restart_code == 0 )); then
            action_parts+=("evict-openclaw-app+restart-gateway")
            sleep 2
            set +e
            out="$("${cmd[@]}" 2>&1)"
            code=$?
            set -e
          fi
        fi
      fi
    fi
  fi

  if ((${#action_parts[@]} > 0)); then
    local action
    action="$(IFS='+'; printf '%s' "${action_parts[*]}")"
    gateway_self_heal_actions="${gateway_self_heal_actions}
${label}=${action}"
  fi

  printf -v "$out_var" '%s' "$out"
  printf -v "$code_var" '%s' "$code"
}

while (($#)); do
  case "$1" in
    --with-update)
      do_update=true
      shift
      ;;
    --skip-update)
      do_update=false
      shift
      ;;
    --openclaw-home)
      if (($# < 2)); then
        echo "missing value for --openclaw-home" >&2
        exit 2
      fi
      openclaw_home="$2"
      shift 2
      ;;
    --openclaw-bin)
      if (($# < 2)); then
        echo "missing value for --openclaw-bin" >&2
        exit 2
      fi
      openclaw_bin="$2"
      shift 2
      ;;
    --update-script)
      if (($# < 2)); then
        echo "missing value for --update-script" >&2
        exit 2
      fi
      update_script="$2"
      shift 2
      ;;
    --snapshot-script)
      if (($# < 2)); then
        echo "missing value for --snapshot-script" >&2
        exit 2
      fi
      snapshot_script="$2"
      shift 2
      ;;
    --skills-sync-script)
      if (($# < 2)); then
        echo "missing value for --skills-sync-script" >&2
        exit 2
      fi
      skills_sync_script="$2"
      shift 2
      ;;
    --skills-root)
      if (($# < 2)); then
        echo "missing value for --skills-root" >&2
        exit 2
      fi
      skills_root="$2"
      shift 2
      ;;
    --skip-skills-sync)
      skills_sync_enabled=0
      shift
      ;;
    --config-path)
      if (($# < 2)); then
        echo "missing value for --config-path" >&2
        exit 2
      fi
      config_path="$2"
      shift 2
      ;;
    --report-dir)
      if (($# < 2)); then
        echo "missing value for --report-dir" >&2
        exit 2
      fi
      report_dir="$2"
      shift 2
      ;;
    --feishu-target)
      if (($# < 2)); then
        echo "missing value for --feishu-target" >&2
        exit 2
      fi
      feishu_target="$2"
      shift 2
      ;;
    --npm-registry)
      if (($# < 2)); then
        echo "missing value for --npm-registry" >&2
        exit 2
      fi
      npm_registry="$2"
      shift 2
      ;;
    --max-retries)
      if (($# < 2)); then
        echo "missing value for --max-retries" >&2
        exit 2
      fi
      max_retries="$2"
      shift 2
      ;;
    --retry-sleep-seconds)
      if (($# < 2)); then
        echo "missing value for --retry-sleep-seconds" >&2
        exit 2
      fi
      retry_sleep_seconds="$2"
      shift 2
      ;;
    --latest-version-cmd)
      if (($# < 2)); then
        echo "missing value for --latest-version-cmd" >&2
        exit 2
      fi
      latest_version_cmd="$2"
      shift 2
      ;;
    --check-latest-on-skip)
      check_latest_on_skip=1
      shift
      ;;
    --retry-registries)
      if (($# < 2)); then
        echo "missing value for --retry-registries" >&2
        exit 2
      fi
      retry_registries="$2"
      shift 2
      ;;
    --known-bug-fix-script)
      if (($# < 2)); then
        echo "missing value for --known-bug-fix-script" >&2
        exit 2
      fi
      known_bug_fix_script="$2"
      shift 2
      ;;
    --disable-known-bug-fix)
      known_bug_fix_enabled=0
      shift
      ;;
    --enable-known-bug-fix-apply)
      known_bug_fix_apply=1
      shift
      ;;
    --required-launchd-labels)
      if (($# < 2)); then
        echo "missing value for --required-launchd-labels" >&2
        exit 2
      fi
      required_launchd_labels="$2"
      shift 2
      ;;
    --dns-http-precheck)
      dns_http_precheck_enabled=1
      shift
      ;;
    --no-dns-http-precheck)
      dns_http_precheck_enabled=0
      shift
      ;;
    --dns-precheck-rounds)
      if (($# < 2)); then
        echo "missing value for --dns-precheck-rounds" >&2
        exit 2
      fi
      dns_precheck_rounds="$2"
      shift 2
      ;;
    --dns-precheck-sleep)
      if (($# < 2)); then
        echo "missing value for --dns-precheck-sleep" >&2
        exit 2
      fi
      dns_precheck_sleep_seconds="$2"
      shift 2
      ;;
    --skip-launchd-check)
      skip_launchd_check=1
      shift
      ;;
    --disable-gateway-self-heal)
      gateway_self_heal_enabled=0
      shift
      ;;
    --disable-gateway-app-evict)
      gateway_app_evict_enabled=0
      shift
      ;;
    --disable-pairing-self-heal)
      pairing_self_heal_enabled=0
      shift
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

if ! [[ "$max_retries" =~ ^[0-9]+$ ]] || (( max_retries < 1 )); then
  echo "max-retries must be a positive integer" >&2
  exit 2
fi

if (( max_retries > 3 )); then
  max_retries=3
fi

if ! [[ "$retry_sleep_seconds" =~ ^[0-9]+$ ]]; then
  echo "retry-sleep-seconds must be a non-negative integer" >&2
  exit 2
fi

if [[ "$skills_sync_enabled" != "0" && "$skills_sync_enabled" != "1" ]]; then
  echo "OPENCLAW_DAILY_UPDATE_SKILLS_SYNC must be 0 or 1" >&2
  exit 2
fi

if [[ "$gateway_self_heal_enabled" != "0" && "$gateway_self_heal_enabled" != "1" ]]; then
  echo "OPENCLAW_DAILY_UPDATE_GATEWAY_SELF_HEAL must be 0 or 1" >&2
  exit 2
fi

if [[ "$gateway_app_evict_enabled" != "0" && "$gateway_app_evict_enabled" != "1" ]]; then
  echo "OPENCLAW_DAILY_UPDATE_GATEWAY_APP_EVICT must be 0 or 1" >&2
  exit 2
fi

if [[ "$pairing_self_heal_enabled" != "0" && "$pairing_self_heal_enabled" != "1" ]]; then
  echo "OPENCLAW_DAILY_UPDATE_PAIRING_SELF_HEAL must be 0 or 1" >&2
  exit 2
fi

if [[ "$check_latest_on_skip" != "0" && "$check_latest_on_skip" != "1" ]]; then
  echo "OPENCLAW_DAILY_UPDATE_CHECK_LATEST_ON_SKIP must be 0 or 1" >&2
  exit 2
fi

if [[ "$dns_http_precheck_enabled" != "0" && "$dns_http_precheck_enabled" != "1" ]]; then
  echo "OPENCLAW_DAILY_UPDATE_DNS_HTTP_PRECHECK must be 0 or 1" >&2
  exit 2
fi

if [[ "$known_bug_fix_enabled" != "0" && "$known_bug_fix_enabled" != "1" ]]; then
  echo "OPENCLAW_DAILY_UPDATE_KNOWN_BUG_FIX must be 0 or 1" >&2
  exit 2
fi

if [[ "$known_bug_fix_apply" != "0" && "$known_bug_fix_apply" != "1" ]]; then
  echo "OPENCLAW_DAILY_UPDATE_KNOWN_BUG_FIX_APPLY must be 0 or 1" >&2
  exit 2
fi

for n in "$dns_http_precheck_attempts" "$dns_http_precheck_connect_timeout" "$dns_http_precheck_max_time"; do
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "DNS HTTP precheck attempt/timeout values must be non-negative integers" >&2
    exit 2
  fi
done

for n in "$dns_precheck_rounds" "$dns_precheck_sleep_seconds"; do
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "DNS precheck rounds/sleep values must be non-negative integers" >&2
    exit 2
  fi
done

if (( dns_http_precheck_attempts < 1 )); then
  dns_http_precheck_attempts=1
fi

if (( dns_precheck_rounds < 1 )); then
  dns_precheck_rounds=1
fi

if [[ -z "$skills_sync_script" ]]; then
  skills_sync_script="$openclaw_home/scripts/update-installed-skills.sh"
fi

if [[ -z "$skills_root" ]]; then
  skills_root="$openclaw_home/workspace/skills"
fi

if [[ ! -x "$openclaw_bin" ]]; then
  echo "openclaw binary not executable: $openclaw_bin" >&2
  exit 1
fi

if [[ ! -x "$update_script" ]]; then
  echo "update script not executable: $update_script" >&2
  exit 1
fi

if [[ ! -f "$config_path" ]]; then
  echo "config path not found: $config_path" >&2
  exit 1
fi

mkdir -p "$report_dir" "$openclaw_home/logs"

lock_dir="${OPENCLAW_DAILY_UPDATE_LOCK_DIR:-$openclaw_home/run/daily-auto-update.lock}"
mkdir -p "$(dirname "$lock_dir")"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "lock-held: $lock_dir" >&2
  exit 1
fi
cleanup_daily_lock() {
  rmdir "$lock_dir" >/dev/null 2>&1 || true
}
trap cleanup_daily_lock EXIT

TS_HUMAN="$(date '+%Y-%m-%d %H:%M:%S %Z')"
DATE_KEY="$(date '+%Y-%m-%d')"
RUN_KEY="$(date '+%H%M%S')-$$"
REPORT_FILE="$report_dir/${DATE_KEY}-daily-auto-update-${RUN_KEY}.md"
CURRENT_VERSION="$("$openclaw_bin" --version 2>/dev/null || echo unknown)"
net_debug_out="$(collect_net_debug_summary 2>&1 || true)"

config_perm_fix_status="skip"
config_perm_fix_out=""
config_perm_fix_exit=0
if [[ -f "$config_path" ]]; then
  config_mode_before="$(detect_file_mode "$config_path")"
  if [[ "$config_mode_before" == "600" ]]; then
    config_perm_fix_status="pass"
    config_perm_fix_out="config permissions already 600: $config_path"
  else
    set +e
    chmod 600 "$config_path" 2>/tmp/openclaw-config-chmod.err.$$
    chmod_code=$?
    set -e
    if (( chmod_code == 0 )); then
      config_mode_after="$(detect_file_mode "$config_path")"
      config_perm_fix_status="fixed"
      config_perm_fix_out="config permissions hardened to 600 (before=${config_mode_before:-unknown} after=${config_mode_after:-unknown}): $config_path"
    else
      config_perm_fix_status="fail"
      config_perm_fix_exit=$chmod_code
      config_perm_fix_out="failed to chmod 600 $config_path (before=${config_mode_before:-unknown}): $(cat /tmp/openclaw-config-chmod.err.$$ 2>/dev/null || true)"
    fi
    rm -f /tmp/openclaw-config-chmod.err.$$ >/dev/null 2>&1 || true
  fi
fi

NET_PATTERN='network|fetch|Connection|ENOTFOUND|ECONN|timeout'
MODE_LABEL="skip-update"
PATCH_OUT=""
latest_version="$CURRENT_VERSION"
update_requested="no"
self_heal_phase="none"
attempt=0
update_exit=1
selected_registry="$(normalize_registry "$npm_registry")"
snapshot_auth_profiles_path="${OPENCLAW_AUTH_PROFILES_PATH:-$openclaw_home/agents/main/agent/auth-profiles.json}"
snapshot_status="skip"
snapshot_out=""
snapshot_taken="false"
rollback_status="skip"
rollback_out=""
gateway_log_path="$openclaw_home/logs/gateway.log"
gateway_self_heal_actions=""
gateway_self_heal_log=""
dns_precheck_status="skip"
dns_precheck_out="dns precheck skipped"
dns_precheck_exit=0
skip_runtime_checks_reason=""
[[ -n "$net_debug_out" ]] || net_debug_out="net debug not collected"

UPDATE_ATTEMPT_ARGS=()
set_mode_args() {
  local mode="$1"
  local reg="$2"
  UPDATE_ATTEMPT_ARGS=()
  if [[ "$mode" == "skip-update" ]]; then
    UPDATE_ATTEMPT_ARGS=(--skip-update --no-restart)
  else
    UPDATE_ATTEMPT_ARGS=(--no-restart)
    if [[ -n "$reg" ]]; then
      UPDATE_ATTEMPT_ARGS+=(--npm-registry "$reg")
    fi
    UPDATE_ATTEMPT_ARGS+=(-- --yes)
  fi
}

run_update_attempt() {
  local label="$1"
  shift
  attempt=$((attempt + 1))
  set +e
  local out
  out="$("$update_script" "$@" 2>&1)"
  local code=$?
  set -e
  PATCH_OUT="${PATCH_OUT}
### Attempt ${attempt} (${label}) (exit ${code})
${out}
"
  update_exit="$code"
  LAST_UPDATE_OUT="$out"
}

if [[ "$do_update" == "true" ]]; then
  latest_resolve_code=0
  update_requested="yes"
  MODE_LABEL="with-update"
  if latest_detected="$(resolve_latest_version 2>/dev/null)"; then
    latest_version="$latest_detected"
    if ! version_gt "$latest_version" "$CURRENT_VERSION"; then
      MODE_LABEL="with-update-no-new-version"
    fi
  else
    latest_resolve_code=$?
    latest_version="unknown"
    if (( latest_resolve_code == 3 )); then
      MODE_LABEL="with-update-no-new-version"
    fi
  fi
fi

if [[ "$do_update" != "true" && "$check_latest_on_skip" == "1" ]]; then
  if latest_detected="$(resolve_latest_version 2>/dev/null)"; then
    latest_version="$latest_detected"
  else
    latest_version="unknown"
  fi
fi

if [[ "$MODE_LABEL" == "skip-update" || "$MODE_LABEL" == "with-update-no-new-version" ]]; then
  set_mode_args "skip-update" ""
  primary_args=("${UPDATE_ATTEMPT_ARGS[@]}")
else
  set_mode_args "with-update" "$selected_registry"
  primary_args=("${UPDATE_ATTEMPT_ARGS[@]}")
fi

LAST_UPDATE_OUT=""
run_update_pipeline=true
if [[ "$MODE_LABEL" == "with-update" ]]; then
  dns_registry_for_check="$selected_registry"
  if [[ -z "$dns_registry_for_check" ]]; then
    first_retry_registry="$(pick_retry_registry "" || true)"
    dns_registry_for_check="$first_retry_registry"
  fi
  dns_precheck_status="pass"
  dns_precheck_round_output=""
  for (( dns_precheck_round = 1; dns_precheck_round <= dns_precheck_rounds; dns_precheck_round++ )); do
    set +e
    dns_round_out="$(run_dns_precheck "$dns_registry_for_check" 2>&1)"
    dns_round_code=$?
    set -e
    dns_precheck_round_output="${dns_precheck_round_output}
-- round ${dns_precheck_round}/${dns_precheck_rounds} (exit ${dns_round_code}) --
${dns_round_out}
"
    if (( dns_round_code == 0 )); then
      dns_precheck_exit=0
      if (( dns_precheck_round == 1 )); then
        dns_precheck_status="pass"
      else
        dns_precheck_status="warn"
      fi
      dns_precheck_out="$(trim_spaces "$dns_precheck_round_output")"
      break
    fi
    dns_precheck_exit=$dns_round_code
    if (( dns_precheck_round < dns_precheck_rounds )) && (( dns_precheck_sleep_seconds > 0 )); then
      sleep "$dns_precheck_sleep_seconds"
    fi
  done
  if (( dns_precheck_exit != 0 )); then
    dns_precheck_status="fail"
    dns_precheck_out="$(trim_spaces "$dns_precheck_round_output")"
    run_update_pipeline=false
    update_exit=1
    skip_runtime_checks_reason="dns precheck failed (api.github.com / registry host unresolved)"
    PATCH_OUT="${PATCH_OUT}
### DNS precheck (exit ${dns_precheck_exit})
registry=${dns_registry_for_check:-none}
${dns_precheck_out}
"
    LAST_UPDATE_OUT="dns precheck failed before update:
registry=${dns_registry_for_check:-none}
${dns_precheck_out}"
  elif [[ -z "$dns_precheck_out" ]]; then
    dns_precheck_out="$(trim_spaces "$dns_precheck_round_output")"
  fi
fi

if [[ "$MODE_LABEL" == "with-update" && "$run_update_pipeline" == "true" ]]; then
  if [[ ! -x "$snapshot_script" ]]; then
    snapshot_status="fail"
    snapshot_out="snapshot script not executable: $snapshot_script"
    run_update_pipeline=false
    update_exit=1
  else
    set +e
    snapshot_out="$("$snapshot_script" \
      --mode snapshot \
      --config-path "$config_path" \
      --auth-profiles-path "$snapshot_auth_profiles_path" \
      --openclaw-bin "$openclaw_bin" 2>&1)"
    snapshot_code=$?
    set -e
    if (( snapshot_code == 0 )); then
      snapshot_status="pass"
      snapshot_taken="true"
    else
      snapshot_status="fail"
      run_update_pipeline=false
      PATCH_OUT="${PATCH_OUT}
### Snapshot (exit ${snapshot_code})
${snapshot_out}
"
      update_exit=1
    fi
  fi
fi

if [[ "$run_update_pipeline" == "true" ]]; then
  run_update_attempt "primary" "${primary_args[@]}"

  if (( update_exit != 0 )) && [[ "$MODE_LABEL" == "with-update" ]]; then
    if (( max_retries >= 2 )); then
      retry_registry="$(pick_retry_registry "$selected_registry" || true)"
      if [[ -n "$retry_registry" ]]; then
        set_mode_args "with-update" "$retry_registry"
        retry_args=("${UPDATE_ATTEMPT_ARGS[@]}")
        run_update_attempt "self-heal-registry" "${retry_args[@]}"
        self_heal_phase="registry-retry"
        if (( update_exit != 0 )); then
          sleep "$retry_sleep_seconds"
        fi
      fi
    fi

    if (( update_exit != 0 )) && (( max_retries >= 3 )); then
      set_mode_args "skip-update" ""
      patch_only_args=("${UPDATE_ATTEMPT_ARGS[@]}")
      run_update_attempt "self-heal-patch-only" "${patch_only_args[@]}"
      self_heal_phase="patch-only"
    fi
  fi
fi

update_dns_failure_detected="no"
if [[ "$MODE_LABEL" == "with-update" ]] && update_output_has_dns_failure "$PATCH_OUT"; then
  update_dns_failure_detected="yes"
  if [[ -z "$skip_runtime_checks_reason" ]]; then
    skip_runtime_checks_reason="update stage dns/network failure detected (curl resolve host)"
  fi
  if [[ "$dns_precheck_status" == "pass" ]]; then
    dns_precheck_status="warn"
    dns_precheck_out="${dns_precheck_out}
post_update_dns_failure_detected=yes"
  elif [[ "$dns_precheck_status" == "skip" ]]; then
    dns_precheck_out="${dns_precheck_out}
post_update_dns_failure_detected=yes"
  fi
fi

UPDATED_VERSION="$("$openclaw_bin" --version 2>/dev/null || echo unknown)"

dependency_status="pass"
dependency_out="openclaw=${openclaw_bin}"
for bin in node npx perl python3 curl launchctl; do
  resolved="$(command -v "$bin" 2>/dev/null || true)"
  if [[ -n "$resolved" ]]; then
    dependency_out="${dependency_out}
${bin}=${resolved}"
  else
    dependency_status="fail"
    dependency_out="${dependency_out}
${bin}=MISSING"
  fi
done

skills_sync_status="skip"
skills_sync_out="skills sync skipped"
skills_sync_exit=0
if [[ "$skills_sync_enabled" == "1" ]]; then
  if [[ -n "$skip_runtime_checks_reason" && "$skip_runtime_checks_reason" == *"dns"* ]]; then
    skills_sync_status="skip"
    skills_sync_out="skills sync skipped: ${skip_runtime_checks_reason}"
  elif [[ ! -x "$skills_sync_script" ]]; then
    skills_sync_status="fail"
    skills_sync_exit=1
    skills_sync_out="skills sync script not executable: $skills_sync_script"
  else
    set +e
    skills_sync_out="$("$skills_sync_script" --skills-root "$skills_root" 2>&1)"
    skills_sync_exit=$?
    set -e
    if (( skills_sync_exit != 0 )); then
      skills_sync_status="fail"
    else
      parsed_skills_status="$(printf '%s\n' "$skills_sync_out" | awk -F= '/^status=/{print $2; exit}')"
      parsed_skills_status="$(trim_spaces "$parsed_skills_status")"
      case "$parsed_skills_status" in
        pass|warn|skip)
          skills_sync_status="$parsed_skills_status"
          ;;
        *)
          skills_sync_status="warn"
          skills_sync_out="status=warn
reason=missing-status-from-skills-sync
${skills_sync_out}"
          ;;
      esac
    fi
  fi
fi

status_deep_exit=0
status_deep_status="pass"
status_deep_out=""
if [[ -n "$skip_runtime_checks_reason" ]]; then
  status_deep_status="skip"
  status_deep_out="status --deep skipped: ${skip_runtime_checks_reason}"
else
  run_gateway_command_with_self_heal "status_deep" status_deep_out status_deep_exit "$openclaw_bin" status --deep
  status_deep_lower="$(printf '%s' "$status_deep_out" | tr '[:upper:]' '[:lower:]')"
  if (( status_deep_exit != 0 )) && [[ "$status_deep_lower" == *"gateway closed"* ]] && [[ "$status_deep_lower" == *"1006"* ]]; then
    first_status_deep_out="$status_deep_out"
    first_status_deep_exit="$status_deep_exit"
    sleep 2
    run_gateway_command_with_self_heal "status_deep_retry_1006" status_deep_out status_deep_exit "$openclaw_bin" status --deep
    status_deep_out="[status_deep] transient gateway closed 1006 detected; retried once (first exit=${first_status_deep_exit})
${first_status_deep_out}

--- retry ---
${status_deep_out}"
  fi
  if (( status_deep_exit != 0 )); then
    status_deep_status="fail"
  fi
fi

security_audit_exit=0
security_audit_status="pass"
security_audit_out=""
set +e
security_audit_out="$("$openclaw_bin" security audit --deep 2>&1)"
security_audit_exit=$?
set -e
if [[ -n "$config_perm_fix_out" ]]; then
  security_audit_out="[config_permission_fix] status=${config_perm_fix_status}
${config_perm_fix_out}

${security_audit_out}"
fi
if (( config_perm_fix_exit != 0 )); then
  security_audit_exit=1
fi
if (( security_audit_exit != 0 )); then
  security_audit_status="fail"
fi

model_fields="$(
  python3 - "$config_path" "$expected_primary_model" "$expected_fallbacks_json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1], "r", encoding="utf-8"))
expected_primary = sys.argv[2]
expected_fallbacks_raw = sys.argv[3]
try:
  expected_fallbacks = json.loads(expected_fallbacks_raw)
except Exception as exc:
  print(f"invalid expected fallbacks json: {exc}", file=sys.stderr)
  raise SystemExit(1)
if not isinstance(expected_fallbacks, list):
  print("invalid expected fallbacks json: expected a JSON array", file=sys.stderr)
  raise SystemExit(1)
m = doc.get("agents", {}).get("defaults", {}).get("model", {})
primary = m.get("primary")
fallbacks = m.get("fallbacks")
plugins = doc.get("plugins", {})
skills = doc.get("skills", {})
plugins_enabled = bool(plugins.get("enabled", False))
plugins_entries = plugins.get("entries", {}) or {}
skills_entries = skills.get("entries", {}) or {}
plugin_feishu = bool((plugins_entries.get("feishu") or {}).get("enabled", False))
plugin_memory = bool((plugins_entries.get("memory-core") or {}).get("enabled", False))
skill_selfie = bool((skills_entries.get("xiaoke-selfie") or {}).get("enabled", False))
fallbacks_match = isinstance(fallbacks, list) and fallbacks == expected_fallbacks
model_pass = (primary == expected_primary) and fallbacks_match
config_pass = plugins_enabled and plugin_feishu and plugin_memory and skill_selfie
print(f"primary={primary}")
print(f"fallbacks={fallbacks}")
print(f"expected_primary={expected_primary}")
print(f"expected_fallbacks={expected_fallbacks}")
print("fallbacks_match=yes" if fallbacks_match else "fallbacks_match=no")
print(f"plugins_enabled={plugins_enabled}")
print(f"plugin_feishu={plugin_feishu}")
print(f"plugin_memory_core={plugin_memory}")
print(f"skill_xiaoke_selfie={skill_selfie}")
print("model_pass=yes" if model_pass else "model_pass=no")
print("config_pass=yes" if config_pass else "config_pass=no")
PY
)"
model_primary="$(printf '%s\n' "$model_fields" | awk -F= '/^primary=/{print $2}')"
model_fallbacks="$(printf '%s\n' "$model_fields" | awk -F= '/^fallbacks=/{print $2}')"
model_expected_primary="$(printf '%s\n' "$model_fields" | awk -F= '/^expected_primary=/{print $2}')"
model_expected_fallbacks="$(printf '%s\n' "$model_fields" | awk -F= '/^expected_fallbacks=/{print $2}')"
model_fallbacks_match="$(printf '%s\n' "$model_fields" | awk -F= '/^fallbacks_match=/{print $2}')"
model_pass="$(printf '%s\n' "$model_fields" | awk -F= '/^model_pass=/{print $2}')"
config_pass="$(printf '%s\n' "$model_fields" | awk -F= '/^config_pass=/{print $2}')"

config_status="pass"
if [[ "$config_pass" != "yes" ]]; then
  config_status="fail"
fi

launchd_status="pass"
launchd_out=""
if [[ "$skip_launchd_check" == "1" ]]; then
  launchd_status="skip"
  launchd_out="launchd checks skipped by flag"
else
  uid="$(id -u)"
  IFS=',' read -r -a labels <<< "$required_launchd_labels"
  for raw_label in "${labels[@]}"; do
    label="$(trim_spaces "$raw_label")"
    if [[ -z "$label" ]]; then
      continue
    fi
    set +e
    label_out="$(launchctl print "gui/$uid/$label" 2>&1)"
    label_code=$?
    set -e
    if (( label_code != 0 )); then
      launchd_status="fail"
      launchd_out="${launchd_out}
${label}: missing"
      continue
    fi
    state="$(printf '%s\n' "$label_out" | awk -F'= ' '/state =/{print $2; exit}')"
    path="$(printf '%s\n' "$label_out" | awk -F'= ' '/path =/{print $2; exit}')"
    if [[ -z "$state" ]]; then
      state="unknown"
    fi
    launchd_out="${launchd_out}
${label}: state=${state} path=${path}"
  done
  launchd_out="$(trim_spaces "$launchd_out")"
fi

result_status="ok"
gateway_probe_exit=0
gateway_probe_status="pass"
gateway_probe_out=""
if [[ -n "$skip_runtime_checks_reason" ]]; then
  gateway_probe_status="skip"
  gateway_probe_out="gateway probe skipped: ${skip_runtime_checks_reason}"
else
  run_gateway_command_with_self_heal "gateway_probe" gateway_probe_out gateway_probe_exit "$openclaw_bin" gateway probe
  gateway_probe_lower="$(printf '%s' "$gateway_probe_out" | tr '[:upper:]' '[:lower:]')"
  if (( gateway_probe_exit != 0 )) && [[ "$gateway_probe_lower" == *"eperm"* ]] && [[ "$gateway_probe_lower" == *"127.0.0.1"* ]]; then
    gateway_probe_status="skip"
    gateway_probe_out="[gateway_probe] downgraded to skip due to automation environment loopback restriction (EPERM)
${gateway_probe_out}"
    gateway_probe_exit=0
  elif (( gateway_probe_exit != 0 )); then
    gateway_probe_status="fail"
  fi
fi

gateway_self_heal_actions="$(trim_spaces "$gateway_self_heal_actions")"
if [[ -z "$gateway_self_heal_actions" ]]; then
  gateway_self_heal_actions="none"
fi
gateway_self_heal_log="$(trim_spaces "$gateway_self_heal_log")"
if [[ -z "$gateway_self_heal_log" ]]; then
  gateway_self_heal_log="no gateway self-heal actions"
fi
gateway_self_heal_status="skip"
if [[ "$gateway_self_heal_enabled" == "1" ]]; then
  if [[ -n "$skip_runtime_checks_reason" ]]; then
    gateway_self_heal_status="skip"
    gateway_self_heal_log="[gateway_self_heal] skipped: ${skip_runtime_checks_reason}"
  else
  gateway_self_heal_status="none"
  if [[ "$gateway_self_heal_actions" != "none" ]]; then
    gateway_self_heal_status="triggered"
  fi
  if (( status_deep_exit != 0 )) || (( gateway_probe_exit != 0 )); then
    gateway_self_heal_status="fail"
  fi
  fi
fi

feishu_probe_status="skip"
feishu_probe_exit=0
feishu_probe_out=""
if [[ -n "$skip_runtime_checks_reason" ]]; then
  feishu_probe_status="skip"
  feishu_probe_out="feishu probe skipped: ${skip_runtime_checks_reason}"
elif [[ -n "$feishu_target" ]]; then
  feishu_probe_status="pass"
  probe_message="daily-update probe
ts: ${TS_HUMAN}
version: ${UPDATED_VERSION}
mode: ${MODE_LABEL}"
  set +e
  feishu_probe_out="$("$openclaw_bin" message send \
    --channel feishu \
    --target "$feishu_target" \
    --message "$probe_message" \
    --json 2>&1)"
  feishu_probe_exit=$?
  set -e
  if (( feishu_probe_exit != 0 )); then
    feishu_probe_status="fail"
  fi
fi

if (( update_exit != 0 )) || [[ "$snapshot_status" == "fail" ]] || [[ "$dependency_status" != "pass" ]] || [[ "$skills_sync_status" == "fail" ]] || (( status_deep_exit != 0 )) || (( security_audit_exit != 0 )) || [[ "$model_pass" != "yes" ]] || [[ "$config_status" != "pass" ]] || [[ "$launchd_status" == "fail" ]] || (( gateway_probe_exit != 0 )) || (( feishu_probe_exit != 0 )); then
  result_status="error"
fi

first_error_class="none"
result_domain="none"
if [[ "$result_status" != "ok" ]]; then
  if [[ "$update_dns_failure_detected" == "yes" ]] || [[ "$skip_runtime_checks_reason" == *"dns"* ]]; then
    first_error_class="dns_network"
    result_domain="infra"
  elif [[ "$dependency_status" != "pass" ]]; then
    first_error_class="dependency_check"
    result_domain="env"
  elif [[ "$launchd_status" == "fail" ]]; then
    first_error_class="launchd_check"
    result_domain="env"
  elif [[ "$security_audit_status" == "fail" ]]; then
    first_error_class="security_audit"
    result_domain="app"
  elif [[ "$status_deep_status" == "fail" ]]; then
    first_error_class="status_deep"
    result_domain="app"
  elif [[ "$gateway_probe_status" == "fail" ]]; then
    first_error_class="gateway_probe"
    result_domain="app"
  elif [[ "$feishu_probe_status" == "fail" ]]; then
    first_error_class="feishu_probe"
    result_domain="app"
  elif [[ "$config_status" == "fail" ]]; then
    first_error_class="config_check"
    result_domain="app"
  elif [[ "$model_pass" != "yes" ]]; then
    first_error_class="model_check"
    result_domain="app"
  elif [[ "$snapshot_status" == "fail" ]]; then
    first_error_class="snapshot"
    result_domain="app"
  elif (( update_exit != 0 )); then
    first_error_class="update_or_patch"
    result_domain="app"
  else
    first_error_class="unknown"
    result_domain="app"
  fi
fi

known_bug_fix_status="skip"
known_bug_fix_signature="none"
known_bug_fix_out="known bug fix skipped"
known_bug_fix_exit=0
if [[ "$result_status" != "ok" && "$known_bug_fix_enabled" == "1" ]]; then
  known_bug_fix_signature="$(resolve_known_bug_fix_signature "$first_error_class" "$PATCH_OUT" "$status_deep_out")"
  if [[ "$known_bug_fix_signature" == "none" ]]; then
    known_bug_fix_status="skip"
    known_bug_fix_out="known bug fix skipped: no signature"
  elif [[ ! -x "$known_bug_fix_script" ]]; then
    known_bug_fix_status="fail"
    known_bug_fix_exit=1
    known_bug_fix_out="known bug fix script not executable: $known_bug_fix_script"
  else
    known_bug_fix_mode="--dry-run"
    if [[ "$known_bug_fix_apply" == "1" ]]; then
      known_bug_fix_mode="--apply"
    fi
    set +e
    known_bug_fix_out="$("$known_bug_fix_script" \
      --signature "$known_bug_fix_signature" \
      "$known_bug_fix_mode" \
      --openclaw-bin "$openclaw_bin" 2>&1)"
    known_bug_fix_exit=$?
    set -e
    case "$known_bug_fix_exit" in
      0)
        known_bug_fix_status="pass"
        ;;
      2|10)
        known_bug_fix_status="skip"
        ;;
      *)
        known_bug_fix_status="fail"
        ;;
    esac
  fi
fi

if [[ "$result_status" != "ok" && "$snapshot_taken" == "true" && "$MODE_LABEL" == "with-update" ]]; then
  set +e
  rollback_out="$("$snapshot_script" \
    --mode rollback \
    --config-path "$config_path" \
    --auth-profiles-path "$snapshot_auth_profiles_path" \
    --openclaw-bin "$openclaw_bin" 2>&1)"
  rollback_code=$?
  set -e
  if (( rollback_code == 0 )); then
    rollback_status="pass"
    result_status="rolled_back"
    set +e
    rollback_smoke_out="$("$openclaw_bin" --version 2>&1)"
    rollback_smoke_code=$?
    set -e
    rollback_out="${rollback_out}
rollback_smoke_openclaw_version_exit=${rollback_smoke_code}
${rollback_smoke_out}
"
    if (( rollback_smoke_code != 0 )); then
      rollback_status="fail"
      result_status="error"
    fi
  else
    rollback_status="fail"
    result_status="error"
  fi
fi

cat > "$REPORT_FILE" <<EOF
# OpenClaw Daily Auto Update - ${DATE_KEY}

- ts: ${TS_HUMAN}
- mode: ${MODE_LABEL}
- before_version: ${CURRENT_VERSION}
- latest_version: ${latest_version}
- after_version: ${UPDATED_VERSION}
- update_requested: ${update_requested}
- self_heal_phase: ${self_heal_phase}
- snapshot: ${snapshot_status}
- rollback: ${rollback_status}
- update_exit: ${update_exit}
- attempts: ${attempt}
- dns_precheck: ${dns_precheck_status}
- dependency_check: ${dependency_status}
- skills_sync: ${skills_sync_status}
- status_deep: ${status_deep_status}
- security_audit: ${security_audit_status}
- config_permission_fix: ${config_perm_fix_status}
- model_check: $( [[ "$model_pass" == "yes" ]] && echo pass || echo fail )
- model_primary: ${model_primary}
- model_fallbacks: ${model_fallbacks}
- model_expected_primary: ${model_expected_primary}
- model_expected_fallbacks: ${model_expected_fallbacks}
- model_fallbacks_match: ${model_fallbacks_match}
- config_check: ${config_status}
- launchd_check: ${launchd_status}
- gateway_self_heal: ${gateway_self_heal_status}
- gateway_self_heal_actions: ${gateway_self_heal_actions}
- gateway_probe: ${gateway_probe_status}
- feishu_probe: ${feishu_probe_status}
- first_error_class: ${first_error_class}
- result_domain: ${result_domain}
- known_bug_fix: ${known_bug_fix_status}
- known_bug_fix_signature: ${known_bug_fix_signature}
- status: ${result_status}

## update+patch
${PATCH_OUT}

## dns_precheck
${dns_precheck_out}

## net_debug
${net_debug_out}

## snapshot
${snapshot_out}

## rollback
${rollback_out}

## dependencies
${dependency_out}

## skills_sync
${skills_sync_out}

## status_deep
${status_deep_out}

## security_audit
${security_audit_out}

## model_config
${model_fields}

## launchd_check
${launchd_out}

## gateway_self_heal
${gateway_self_heal_log}

## gateway_probe
${gateway_probe_out}

## feishu_probe
${feishu_probe_out}

## known_bug_fix
${known_bug_fix_out}
EOF

printf 'REPORT_FILE=%s\n' "$REPORT_FILE"
printf 'CURRENT_VERSION=%s\n' "$UPDATED_VERSION"
printf 'STATUS=%s\n' "$result_status"

if [[ "$result_status" != "ok" ]]; then
  exit 1
fi
