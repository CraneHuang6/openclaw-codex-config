---
name: openclaw-model-upgrade-sync
description: 在本机 OpenClaw 或 Claude 默认模型升级后，统一扫描、同步并验证模型选择配置；并补齐 cron payload.model、cron 会话清理与运行态灰度验收。
---

# OpenClaw Model Upgrade Sync

## Overview

这个技能用于把“小可”模型升级流程固化成一套可重复动作，避免只改静态配置却遗漏运行态链路。

推荐顺序：
- `scan -> apply -> verify`：先对齐固定 10 个静态目标文件。
- `runtime-cron-scan -> runtime-cron-fix -> runtime-cron-verify`：再修正 cron payload 与 cron 会话。
- `doctor`：一条命令汇总静态、cron、主会话、probe 与近期灰度异常。
- `runtime apply -> runtime verify`：最后做入口硬切、首条验模与防漂移观察。

## Static Scope

静态同步只允许改这 10 个目标文件：
- `/Users/crane/.openclaw/openclaw_codex.json`
- `/Users/crane/.claude/settings.json`
- `/Users/crane/.openclaw/openclaw.json`
- `/Users/crane/.openclaw/agents/main/agent/models.json`
- `/Users/crane/.openclaw/scripts/daily-auto-update-local.sh`
- `/Users/crane/.openclaw/scripts/update-openclaw-with-feishu-repatch.sh`
- `/Users/crane/.openclaw/scripts/enforce-openclaw-kimi-model.sh`
- `/Users/crane/.openclaw/scripts/tests/daily-auto-update-local.test.sh`
- `/Users/crane/.openclaw/scripts/tests/enforce-openclaw-kimi-model.test.sh`
- `/Users/crane/.openclaw/scripts/tests/update-openclaw-with-feishu-repatch.test.sh`

不修改 worktree、备份、历史、日志、缓存与其他配置文件。

## Quick Start

1) 仅切到 `gpt-5.4`（无回退链）

```bash
python3 /Users/crane/.codex/skills/openclaw-model-upgrade-sync/scripts/sync_model_upgrade.py \
  --mode all \
  --primary-model gpt-5.4 \
  --provider qmcode \
  --claude-model gpt-5.4 \
  --run-tests
```

2) 保留“主 + 回退”模式

```bash
python3 /Users/crane/.codex/skills/openclaw-model-upgrade-sync/scripts/sync_model_upgrade.py \
  --mode all \
  --primary-model gpt-5.4 \
  --fallback-model gpt-5.3-codex \
  --provider qmcode \
  --claude-model gpt-5.4 \
  --run-tests
```

3) 扫描所有 cron 是否仍硬编码旧模型

```bash
python3 /Users/crane/.codex/skills/openclaw-model-upgrade-sync/scripts/sync_model_upgrade.py \
  --mode runtime-cron-scan \
  --primary-model gpt-5.4 \
  --provider qmcode
```

4) 一键修正 cron payload.model，并清理 cron 会话键

```bash
python3 /Users/crane/.codex/skills/openclaw-model-upgrade-sync/scripts/sync_model_upgrade.py \
  --mode runtime-cron-fix \
  --primary-model gpt-5.4 \
  --provider qmcode \
  --clear-cron-sessions
```

5) 一条命令跑最小自检总控

```bash
python3 /Users/crane/.codex/skills/openclaw-model-upgrade-sync/scripts/sync_model_upgrade.py \
  --mode doctor \
  --primary-model gpt-5.4 \
  --provider qmcode \
  --doctor-old-model gpt-5.3-codex
```

6) 验证 cron 已全部切到目标模型，且无旧 cron 会话残留

```bash
python3 /Users/crane/.codex/skills/openclaw-model-upgrade-sync/scripts/sync_model_upgrade.py \
  --mode runtime-cron-verify \
  --primary-model gpt-5.4 \
  --provider qmcode
```

7) 做入口硬切与首条验模

```bash
python3 /Users/crane/.codex/skills/openclaw-model-upgrade-sync/scripts/hardcut_runtime_model.py apply \
  --target-model gpt-5.4 \
  --monitor-model gpt-5.1-codex-mini \
  --kill-runtime

python3 /Users/crane/.codex/skills/openclaw-model-upgrade-sync/scripts/hardcut_runtime_model.py verify \
  --target-model gpt-5.4 \
  --window-minutes 30
```

## 2026-03-07 Lessons Learned

这次升级的关键经验要点：
- 新出现的 `gpt-5.3-codex` 会话，不一定是“fallback 触发”。真实根因可能是 `cron.payload.model` 仍硬编码旧模型。
- 即使静态配置已经是 `fallbacks=[]`，老的 `agent:main:cron:*` 会话键仍可能继续复用旧模型。
- 所以模型升级后，不能只看 `openclaw.json` / `openclaw_codex.json`，必须把 `cron` 和 `sessions.json` 一起纳入检查。

固定检查项：
- `openclaw cron list --json` 中每个 job 的 `payload.model` 都应等于 `qmcode/<primary>`。
- `/Users/crane/.openclaw/agents/main/sessions/sessions.json` 中所有 `agent:main:cron:*` 键都应是新模型，或直接清空后重建。
- 若灰度期目标是“仅 5.4”，则业务配置中不得再把 `gpt-5.3-codex` 放在默认回退链上。

## 2-Hour Canary

“短时灰度无回退”的验收口径固定为 2 小时，每 10 分钟检查一次：
- `openclaw models status --probe --json`：不应再出现新的 `401` / `membership` / 持续 timeout。
- `openclaw sessions --json`：`agent:main:main` 与当期 `agent:main:cron:*` 均应为 `gpt-5.4`。
- 相关运行日志：不应出现新的 `model-snapshot -> gpt-5.3-codex`。
- `runtime-cron-verify`：应持续通过，避免有新 cron job 被改回旧模型。
- `doctor`：应返回 `summary.ok=true`，否则先看 `static` / `cron` / `sessions` / `probe` / `canary` 哪一段失败。

若任一检查失败：
- 先停止“仅 5.4”全量切换。
- 先修复 probe / membership 或 cron payload 问题。
- 必要时临时回到“主 5.4 + 回退 5.3”，但不要在未定位根因前宣布切换完成。

## Manual Fallback Commands

技能脚本优先；必要时可手工复核：

列出所有 cron 的模型：

```bash
/opt/homebrew/bin/openclaw cron list --json | jq -r '.jobs[] | [.id, .name, .payload.model] | @tsv'
```

手工批量修正 cron：

```bash
/opt/homebrew/bin/openclaw cron list --json \
  | jq -r '.jobs[] | select(.payload.model != "qmcode/gpt-5.4") | .id' \
  | while read -r job_id; do
      /opt/homebrew/bin/openclaw cron edit "$job_id" --model qmcode/gpt-5.4
    done
```

清理 cron 会话键：

```bash
jq 'with_entries(select(.key | startswith("agent:main:cron:") | not))' \
  /Users/crane/.openclaw/agents/main/sessions/sessions.json \
  > /tmp/openclaw-sessions.clean.json \
  && mv /tmp/openclaw-sessions.clean.json /Users/crane/.openclaw/agents/main/sessions/sessions.json
```

查看 cron 会话当前模型：

```bash
jq -r 'to_entries[] | select(.key | startswith("agent:main:cron:")) | [.key, .value.model, .value.modelProvider] | @tsv' \
  /Users/crane/.openclaw/agents/main/sessions/sessions.json
```

## Runtime Scope

运行态相关文件和状态：
- `/Users/crane/.codex/.codex-global-state.json`
- `/Users/crane/.codex/state_5.sqlite`
- `/Users/crane/.claude.json`
- `/Users/crane/.claude/projects/**/*.jsonl`
- `/Users/crane/.openclaw/agents/main/sessions/sessions.json`

## Safety Rules

- `monitor` 固定保留 mini：`gpt-5.1-codex-mini`。
- 默认优先结构化更新，不做全盘字符串替换。
- `runtime-cron-fix --clear-cron-sessions` 会删除 `agent:main:cron:*` 键；执行前应确认这是预期行为。
- `runtime verify` 或 `runtime-cron-verify` 未通过时，不宣布升级完成。

## Outputs

- `scan/apply/verify`：输出静态 10 文件的目标态、变更摘要和 PASS/FAIL。
- `doctor`：输出单个 JSON 总报告，汇总静态、cron、主会话、probe 与近期日志异常，并给出 `[DOCTOR] PASS/FAIL`。
- `runtime-cron-scan`：输出所有 cron job 与 `payload.model` 不一致项。
- `runtime-cron-fix`：输出修正了哪些 cron、哪些失败、是否清理了 cron 会话。
- `runtime-cron-verify`：输出 cron payload 与 cron sessions 的最终一致性结果。
- `hardcut_runtime_model.py`：输出入口清理、首条验模与窗口期防漂移结果。

## Scripts

- 静态同步 + cron 运行态同步：`scripts/sync_model_upgrade.py`
- 入口硬切与首条验模：`scripts/hardcut_runtime_model.py`
