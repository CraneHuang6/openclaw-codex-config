---
name: merge-manager
description: 使用 multi-agent 门禁来盘点、分类、验证、排序并生成本地分支 dry-run 集成报告；第一版不执行真实批量 merge。
---

# Merge Manager

## Overview

`merge-manager` 是本地 branch 集成的制度层与编排层：

1. inventory 候选分支
2. classify 风险与高风险路径
3. detect overlap 与 merge order
4. validate 分支在最新 base 上的可重放性与验证命令结果
5. 生成 dry-run Markdown + JSON 报告
6. 为 future execute 预留入口，但 MVP 不执行真实 merge

## Role Model

- `Orchestrator`：收敛输入，维护 Root Cause Matrix，决定 merge order，汇总最终报告
- `Explorer`：
  - `inventory lane`：候选分支、ahead/behind、freshness、merged 状态
  - `risk/overlap lane`：高风险路径、核心文件重叠、验证命令检测
- `Reviewer`：Gate B、Pre-Merge、Gate D2
- `Worker`：future real-exec 时只处理单一冻结 merge slice
- `Tester`：验证 dry-run 非破坏性、legacy facade 不回归

## Routing

优先使用 `$merge-manager` 的场景：
- branch 扫描
- risk classify
- overlap / merge order 分析
- dry-run 集成规划
- 汇总候选分支报告

继续使用 `$review-merge-main-cleanup` 的场景：
- 真实执行 legacy 自动收敛
- 兼容既有调用方
- 已批准 merge/cleanup 的执行阶段

## MVP Boundaries

第一版只支持：
- `--mode dry-run`
- Markdown + JSON 报告
- 状态枚举固定为 `ready / blocked / manual_review / stale`

第一版不支持：
- 真实批量 merge
- cleanup delete
- ref 写入

`--mode execute` 当前会返回 `not enabled in MVP`。

## Shared Read-Only Core

phase 1 共享核心仅包含：
- inventory
- classify
- validation command detection
- policy load
- report render/assembly

不抽取 mutating merge / cleanup 逻辑。

## Core CLI

```bash
bash /Users/crane/.codex/skills/merge-manager/scripts/run_merge_manager.sh \
  --mode dry-run \
  --base main \
  --branch-pattern 'worker/*' \
  --report /abs/path/merge-manager.md \
  --json
```

## Required Output

报告固定包含：
- assumptions
- candidate_branches
- filtered_out
- merge_order
- branch states (`ready / blocked / manual_review / stale`)
- validation_summary
- blockers
- next_action
- exact next command for legacy real execution

## Phase 2 Notes

phase 2 dry-run 额外要求：
- 过滤任一 worktree 当前 checkout 的分支
- 过滤已经并入 base 的本地分支
- validation command detection 采用显式优先 + 保守 root-only 自动探测
- 不递归 nested repos 寻找验证命令
