---
name: openclaw-model-upgrade-sync
description: 在本机 OpenClaw 或 Claude 默认模型升级后，统一扫描、同步并验证模型选择配置。用于把主模型/回退链（例如主 `gpt-5.4`、回退 `gpt-5.3-codex`）一次性对齐到固定目标文件，并避免误改 worktree、备份、历史与日志。
---

# OpenClaw Model Upgrade Sync

## Overview

沉淀“模型升级后的同步更新”经验，提供可重复执行的标准流程：`scan -> apply -> verify`。  
优先使用本技能脚本，避免手工逐文件替换导致漏改、重复 key/id 或误改历史文件。

## Quick Start

```bash
python3 /Users/crane/.codex/skills/openclaw-model-upgrade-sync/scripts/sync_model_upgrade.py \
  --mode all \
  --primary-model gpt-5.4 \
  --fallback-model gpt-5.3-codex \
  --provider qmcode \
  --claude-model gpt-5.4 \
  --run-tests
```

## Workflow

1. 先 `scan`：读取当前主模型、回退链、10 个目标文件命中情况，不改任何文件。
2. 再 `apply`：只更新目标文件中的模型选择配置与测试常量，保持 OpenClaw 主模型与回退链一致。
3. 最后 `verify`：校验 JSON 结构、关键常量、目标状态；可加 `--run-tests` 跑 3 组回归脚本。

## Target Files (Fixed 10)

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

## Safety Rules

- 不修改以下路径族：`.openclaw/.worktrees/**`、`.codex/worktrees/**`、`.openclaw/backup/**`、`.Trash/**`、会话/日志/历史文件。
- 不做全盘字符串替换；仅对固定文件执行结构化更新与定点常量替换。
- 若目标模型在三份 OpenClaw JSON 中都不存在，立即失败并提示人工补充模型定义，不盲目造字段。

## Common Commands

只看现状（不落盘）：

```bash
python3 /Users/crane/.codex/skills/openclaw-model-upgrade-sync/scripts/sync_model_upgrade.py \
  --mode scan \
  --primary-model gpt-5.4 \
  --fallback-model gpt-5.3-codex
```

仅应用更新（不跑测试）：

```bash
python3 /Users/crane/.codex/skills/openclaw-model-upgrade-sync/scripts/sync_model_upgrade.py \
  --mode apply \
  --primary-model gpt-5.5 \
  --fallback-model gpt-5.4 \
  --claude-model gpt-5.5
```

只做验收：

```bash
python3 /Users/crane/.codex/skills/openclaw-model-upgrade-sync/scripts/sync_model_upgrade.py \
  --mode verify \
  --primary-model gpt-5.5 \
  --fallback-model gpt-5.4 \
  --claude-model gpt-5.5 \
  --run-tests
```

## Outputs

- 输出当前与目标模型链路（primary/fallback/provider）。
- 输出每个目标文件是否变更与变更摘要。
- 在 `verify` 下输出 PASS/FAIL 与失败项原因。

## Script

核心脚本：`scripts/sync_model_upgrade.py`
