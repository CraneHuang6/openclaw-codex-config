# Codex 自动化走 Clash LAN 代理 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让 Codex 自动化执行 `run_openclaw_update_flow.sh` 时默认支持“LAN Host 可配置代理”，并在进入主流程前做代理可达性预检，避免继续使用自动化环境内不可达的 `127.0.0.1:7890/7891`。

**Architecture:** 在 `/Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh` 增加“显式 URL > HOST/PORT 组合 > loopback 回退”的代理解析顺序，并仅对 `stable/monitor/full` 模式增加 `curl --proxy` 预检门禁。自动化侧更新 `/Users/crane/.codex/automations/automation/automation.toml` prompt，使其显式设置 LAN Host 变量。补充一个最小 shell 回归测试，覆盖 host 组合与预检失败退出码。

**Tech Stack:** Bash、curl、TOML、`rg`、`bash -n`

---

### Task 1: 新增代理 LAN 回归测试（先 Red）

**Files:**
- Create: `/Users/crane/.codex/skills/openclaw-update-workflow/scripts/tests/run_openclaw_update_flow.proxy-lan.test.sh`
- Test target: `/Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh`

**Step 1: Write the failing test**

创建测试脚本，至少包含 3 个场景：

```bash
#!/usr/bin/env bash
set -euo pipefail

RUNNER="/Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh"
fail() { echo "[FAIL] $*" >&2; exit 1; }

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

scenario_defaults_to_loopback() {
  local out
  out="$(run_stable)"
  grep -Fq 'HTTP_PROXY=http://127.0.0.1:7890' <<<"$out" || fail "loopback default missing"
  grep -Fq 'ALL_PROXY=socks5://127.0.0.1:7891' <<<"$out" || fail "loopback socks default missing"
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
  out="$(
    OPENCLAW_SKILL_PROXY_ENV_ENABLED=1 \
    OPENCLAW_SKILL_DAILY_SCRIPT="$stub_daily" \
    OPENCLAW_SKILL_PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    OPENCLAW_SKILL_HTTP_PROXY_HOST="192.168.1.23" \
    OPENCLAW_SKILL_PROXY_PRECHECK_ENABLED=1 \
    bash "$RUNNER" monitor 2>&1
  )"
  code=$?
  set -e
  [[ "$code" -eq 12 ]] || fail "expected exit 12, got $code"
  grep -Fq '[precheck] proxy unreachable:' <<<"$out" || fail "missing precheck failure log"
}

scenario_defaults_to_loopback
scenario_uses_lan_host
scenario_precheck_failure_exits_12
echo "[PASS] run_openclaw_update_flow proxy lan tests"
```

**Step 2: Run test to verify it fails**

Run:

```bash
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/tests/run_openclaw_update_flow.proxy-lan.test.sh
```

Expected: FAIL（当前实现没有 `OPENCLAW_SKILL_HTTP_PROXY_HOST` 组装，也没有预检退出码 12）

**Step 3: Commit checkpoint**

```bash
if git -C /Users/crane/.codex rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C /Users/crane/.codex add /Users/crane/.codex/skills/openclaw-update-workflow/scripts/tests/run_openclaw_update_flow.proxy-lan.test.sh
  git -C /Users/crane/.codex commit -m "test: 增加LAN代理与预检回归测试"
else
  echo "skip commit: /Users/crane/.codex 不是 git 仓库"
fi
```

### Task 2: 在入口脚本实现 HOST/PORT 代理组装与预检（Green）

**Files:**
- Modify: `/Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh`
- Test: `/Users/crane/.codex/skills/openclaw-update-workflow/scripts/tests/run_openclaw_update_flow.proxy-lan.test.sh`

**Step 1: Implement proxy host/port resolution with strict precedence**

在 `OPENCLAW_SKILL_PROXY_ENV_ENABLED` 分支中改为以下优先级：
1. 现有显式 URL：`OPENCLAW_SKILL_HTTP_PROXY` / `OPENCLAW_SKILL_HTTPS_PROXY` / `OPENCLAW_SKILL_ALL_PROXY`
2. 新增 host+port：`OPENCLAW_SKILL_HTTP_PROXY_HOST` + `OPENCLAW_SKILL_HTTP_PROXY_PORT` / `OPENCLAW_SKILL_SOCKS_PROXY_PORT`
3. 默认 loopback：`127.0.0.1:7890` / `127.0.0.1:7891`

最小实现示例：

```bash
proxy_host="${OPENCLAW_SKILL_HTTP_PROXY_HOST:-}"
http_proxy_port="${OPENCLAW_SKILL_HTTP_PROXY_PORT:-7890}"
socks_proxy_port="${OPENCLAW_SKILL_SOCKS_PROXY_PORT:-7891}"

default_http_proxy="http://127.0.0.1:7890"
default_all_proxy="socks5://127.0.0.1:7891"
if [[ -n "$proxy_host" ]]; then
  default_http_proxy="http://${proxy_host}:${http_proxy_port}"
  default_all_proxy="socks5://${proxy_host}:${socks_proxy_port}"
fi

: "${HTTP_PROXY:=${OPENCLAW_SKILL_HTTP_PROXY:-$default_http_proxy}}"
: "${HTTPS_PROXY:=${OPENCLAW_SKILL_HTTPS_PROXY:-$HTTP_PROXY}}"
: "${ALL_PROXY:=${OPENCLAW_SKILL_ALL_PROXY:-$default_all_proxy}}"
: "${NO_PROXY:=${OPENCLAW_SKILL_NO_PROXY:-localhost,127.0.0.1,::1,.local}}"
```

**Step 2: Add proxy precheck gate before `stable/monitor/full`**

新增预检函数，默认开启，可通过变量关闭：

```bash
run_proxy_precheck() {
  local enabled="${OPENCLAW_SKILL_PROXY_PRECHECK_ENABLED:-1}"
  local url="${OPENCLAW_SKILL_PROXY_PRECHECK_URL:-https://registry.npmjs.org}"
  local timeout="${OPENCLAW_SKILL_PROXY_PRECHECK_TIMEOUT:-5}"
  if [[ "$enabled" != "1" ]]; then
    return 0
  fi
  if ! curl --proxy "$HTTP_PROXY" -I --max-time "$timeout" "$url" >/dev/null 2>&1; then
    echo "[precheck] proxy unreachable: $HTTP_PROXY" >&2
    return 12
  fi
}
```

在 `stable|monitor|full` 分支调用，失败即 `exit 12`。

**Step 3: Run test to verify it passes**

Run:

```bash
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/tests/run_openclaw_update_flow.proxy-lan.test.sh
```

Expected: PASS

**Step 4: Syntax + help smoke**

Run:

```bash
bash -n /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh help
```

Expected:
- `bash -n` 无输出，退出码 0
- `help` 正常输出所有模式

**Step 5: Commit checkpoint**

```bash
if git -C /Users/crane/.codex rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C /Users/crane/.codex add /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh
  git -C /Users/crane/.codex add /Users/crane/.codex/skills/openclaw-update-workflow/scripts/tests/run_openclaw_update_flow.proxy-lan.test.sh
  git -C /Users/crane/.codex commit -m "fix: 支持LAN代理host并增加主流程预检"
else
  echo "skip commit: /Users/crane/.codex 不是 git 仓库"
fi
```

### Task 3: 更新 Codex 自动化 prompt 注入 LAN 代理变量

**Files:**
- Modify: `/Users/crane/.codex/automations/automation/automation.toml`

**Step 1: Write a failing content check**

先写一个最小检查（可放在临时命令里），断言 prompt 尚未包含新变量名：

```bash
rg -n "OPENCLAW_SKILL_HTTP_PROXY_HOST|OPENCLAW_SKILL_HTTP_PROXY_PORT|OPENCLAW_SKILL_SOCKS_PROXY_PORT" /Users/crane/.codex/automations/automation/automation.toml
```

Expected: 无匹配（当前应失败）

**Step 2: Update prompt text with explicit LAN env injection**

把 prompt 里的“先设置 OPENCLAW_NPM_REGISTRY=...”替换为：

```text
先设置 OPENCLAW_SKILL_HTTP_PROXY_HOST=<你的Mac局域网IP>、OPENCLAW_SKILL_HTTP_PROXY_PORT=7890、OPENCLAW_SKILL_SOCKS_PROXY_PORT=7891、OPENCLAW_NPM_REGISTRY=https://registry.npmjs.org，
再执行 bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh monitor。
```

要求：
- `<你的Mac局域网IP>` 直接落成固定值（例如 `192.168.1.23`），不要留占位符。
- 保留后续分类、doctor、append memory 逻辑不变。

**Step 3: Run check to verify it passes**

Run:

```bash
rg -n "OPENCLAW_SKILL_HTTP_PROXY_HOST|OPENCLAW_SKILL_HTTP_PROXY_PORT|OPENCLAW_SKILL_SOCKS_PROXY_PORT|OPENCLAW_NPM_REGISTRY" /Users/crane/.codex/automations/automation/automation.toml
```

Expected: 命中新变量与 npm registry

**Step 4: Commit checkpoint**

```bash
if git -C /Users/crane/.codex rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C /Users/crane/.codex add /Users/crane/.codex/automations/automation/automation.toml
  git -C /Users/crane/.codex commit -m "chore: 自动化prompt注入LAN代理变量"
else
  echo "skip commit: /Users/crane/.codex 不是 git 仓库"
fi
```

### Task 4: 文档同步（避免后续回归到 loopback 误配置）

**Files:**
- Modify: `/Users/crane/.codex/skills/openclaw-update-workflow/SKILL.md`
- Modify: `/Users/crane/.codex/skills/openclaw-update-workflow/references/update-flow-cheatsheet.md`

**Step 1: Write failing doc check**

Run:

```bash
rg -n "OPENCLAW_SKILL_HTTP_PROXY_HOST|OPENCLAW_SKILL_PROXY_PRECHECK_ENABLED|Clash|LAN" /Users/crane/.codex/skills/openclaw-update-workflow/SKILL.md /Users/crane/.codex/skills/openclaw-update-workflow/references/update-flow-cheatsheet.md
```

Expected: 缺少完整说明（检查失败）

**Step 2: Add minimal docs**

在两个文档都补充：
- 新变量说明：`OPENCLAW_SKILL_HTTP_PROXY_HOST`、`OPENCLAW_SKILL_HTTP_PROXY_PORT`、`OPENCLAW_SKILL_SOCKS_PROXY_PORT`
- 预检控制：`OPENCLAW_SKILL_PROXY_PRECHECK_ENABLED`、`OPENCLAW_SKILL_PROXY_PRECHECK_URL`
- 典型命令：

```bash
OPENCLAW_SKILL_HTTP_PROXY_HOST=192.168.1.23 \
OPENCLAW_SKILL_HTTP_PROXY_PORT=7890 \
OPENCLAW_SKILL_SOCKS_PROXY_PORT=7891 \
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh monitor
```

**Step 3: Run doc check to verify it passes**

Run:

```bash
rg -n "OPENCLAW_SKILL_HTTP_PROXY_HOST|OPENCLAW_SKILL_PROXY_PRECHECK_ENABLED|OPENCLAW_SKILL_PROXY_PRECHECK_URL" /Users/crane/.codex/skills/openclaw-update-workflow/SKILL.md /Users/crane/.codex/skills/openclaw-update-workflow/references/update-flow-cheatsheet.md
```

Expected: 命中上述关键字

**Step 4: Commit checkpoint**

```bash
if git -C /Users/crane/.codex rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C /Users/crane/.codex add /Users/crane/.codex/skills/openclaw-update-workflow/SKILL.md
  git -C /Users/crane/.codex add /Users/crane/.codex/skills/openclaw-update-workflow/references/update-flow-cheatsheet.md
  git -C /Users/crane/.codex commit -m "docs: 增加Clash LAN代理与预检说明"
else
  echo "skip commit: /Users/crane/.codex 不是 git 仓库"
fi
```

### Task 5: 端到端最小验收（先轻量再 full）

**Files:**
- Verify runtime config: `/Users/crane/.codex/automations/automation/automation.toml`
- Verify wrapper: `/Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh`

**Step 1: 本机代理前置检查（手工终端）**

Run:

```bash
lsof -nP -iTCP:7890 -sTCP:LISTEN
lsof -nP -iTCP:7891 -sTCP:LISTEN
ipconfig getifaddr en0 || ipconfig getifaddr en1
curl --proxy http://<LAN_IP>:7890 -I --max-time 8 https://api.github.com
curl --proxy http://<LAN_IP>:7890 -I --max-time 8 https://registry.npmjs.org
```

Expected:
- 端口监听存在
- LAN IP 可用
- 两个 `curl` 非连接失败/超时

**Step 2: 轻量模式验收**

Run:

```bash
OPENCLAW_SKILL_HTTP_PROXY_HOST=<LAN_IP> \
OPENCLAW_SKILL_HTTP_PROXY_PORT=7890 \
OPENCLAW_SKILL_SOCKS_PROXY_PORT=7891 \
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh monitor
```

Expected:
- 不再出现 `Failed to connect to 127.0.0.1 port 7890`
- 报告输出 `REPORT_FILE=...`

**Step 3: doctor 验收**

Run:

```bash
OPENCLAW_SKILL_HTTP_PROXY_HOST=<LAN_IP> \
OPENCLAW_SKILL_HTTP_PROXY_PORT=7890 \
OPENCLAW_SKILL_SOCKS_PROXY_PORT=7891 \
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh doctor
```

Expected: `status --deep` / `gateway probe` / `security audit --deep` 完成或给出明确非代理类错误

**Step 4: full 仅手动触发**

Run:

```bash
OPENCLAW_SKILL_HTTP_PROXY_HOST=<LAN_IP> \
OPENCLAW_SKILL_HTTP_PROXY_PORT=7890 \
OPENCLAW_SKILL_SOCKS_PROXY_PORT=7891 \
bash /Users/crane/.codex/skills/openclaw-update-workflow/scripts/run_openclaw_update_flow.sh full
```

Expected:
- 流程进入真实更新路径
- 若失败，首错应在报告中可归类，不再是 loopback 代理不可达

