#!/usr/bin/env bash
set -euo pipefail

RUNNER="/Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh"

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"

stub_daily="$tmp_dir/daily.sh"
cat >"$stub_daily" <<'EOF'
#!/usr/bin/env bash
echo "HTTP_PROXY=${HTTP_PROXY:-}"
echo "HTTPS_PROXY=${HTTPS_PROXY:-}"
echo "ALL_PROXY=${ALL_PROXY:-}"
echo "NO_PROXY=${NO_PROXY:-}"
EOF
chmod +x "$stub_daily"

run_stable() {
  OPENCLAW_SKILL_PROXY_ENV_ENABLED=1 \
  OPENCLAW_SKILL_PROXY_PRECHECK_ENABLED=0 \
  OPENCLAW_SKILL_DAILY_SCRIPT="$stub_daily" \
  OPENCLAW_SKILL_PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  bash "$RUNNER" stable
}

scenario_defaults_to_lan_default() {
  local out
  out="$(run_stable)"
  grep -Fq 'HTTP_PROXY=http://192.168.1.2:7897' <<<"$out" || fail "LAN default http proxy missing"
  grep -Fq 'ALL_PROXY=socks5://192.168.1.2:7897' <<<"$out" || fail "LAN default socks proxy missing"
}

scenario_uses_lan_host() {
  local out
  out="$(
    OPENCLAW_SKILL_HTTP_PROXY_HOST="192.168.1.23" \
    OPENCLAW_SKILL_HTTP_PROXY_PORT="7890" \
    OPENCLAW_SKILL_SOCKS_PROXY_PORT="7891" \
    run_stable
  )"
  grep -Fq 'HTTP_PROXY=http://192.168.1.23:7890' <<<"$out" || fail "LAN host http proxy missing"
  grep -Fq 'ALL_PROXY=socks5://192.168.1.23:7891' <<<"$out" || fail "LAN host socks proxy missing"
}

scenario_precheck_failure_exits_12() {
  cat >"$tmp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
  chmod +x "$tmp_dir/bin/curl"
  set +e
  local out
  out="$(
    OPENCLAW_SKILL_PROXY_ENV_ENABLED=1 \
    OPENCLAW_SKILL_DAILY_SCRIPT="$stub_daily" \
    OPENCLAW_SKILL_PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    OPENCLAW_SKILL_HTTP_PROXY_HOST="192.168.1.23" \
    OPENCLAW_SKILL_PROXY_PRECHECK_ENABLED=1 \
    OPENCLAW_SKILL_PROXY_PRECHECK_ATTEMPTS=1 \
    OPENCLAW_SKILL_PROXY_PRECHECK_RETRY_DELAY=0 \
    bash "$RUNNER" monitor 2>&1
  )"
  local code=$?
  set -e
  [[ "$code" -eq 12 ]] || fail "expected exit 12, got $code"
  grep -Fq '[precheck] proxy unreachable:' <<<"$out" || fail "missing precheck failure log"
}

scenario_precheck_retry_then_pass() {
  local count_file="$tmp_dir/curl.count"
  : >"$count_file"
  cat >"$tmp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count_file="${TMP_CURL_COUNT_FILE:?}"
count="$(cat "$count_file" 2>/dev/null || echo 0)"
count="$((count + 1))"
printf '%s\n' "$count" >"$count_file"
if [[ "$count" -eq 1 ]]; then
  exit 7
fi
exit 0
EOF
  chmod +x "$tmp_dir/bin/curl"

  local out
  out="$(
    TMP_CURL_COUNT_FILE="$count_file" \
    OPENCLAW_SKILL_PROXY_ENV_ENABLED=1 \
    OPENCLAW_SKILL_DAILY_SCRIPT="$stub_daily" \
    OPENCLAW_SKILL_PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    OPENCLAW_SKILL_HTTP_PROXY_HOST="192.168.1.23" \
    OPENCLAW_SKILL_PROXY_PRECHECK_ENABLED=1 \
    OPENCLAW_SKILL_PROXY_PRECHECK_ATTEMPTS=2 \
    OPENCLAW_SKILL_PROXY_PRECHECK_RETRY_DELAY=0 \
    bash "$RUNNER" monitor
  )"

  [[ "$(cat "$count_file")" -eq 2 ]] || fail "expected curl retry to run twice"
  grep -Fq 'HTTP_PROXY=http://192.168.1.23:7897' <<<"$out" || fail "retry pass should continue to daily script"
}

scenario_defaults_to_lan_default
scenario_uses_lan_host
scenario_precheck_failure_exits_12
scenario_precheck_retry_then_pass

echo "[PASS] run_openclaw_update_flow proxy lan tests"
