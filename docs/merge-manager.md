# Merge Manager

## Purpose

`merge-manager` 是新的 branch integration 制度层与编排层，职责是：
- 扫描候选分支
- 做风险分类
- 分析 overlap 与 merge order
- 在 dry-run 下验证分支相对最新 `main` 的可重放性
- 输出 Markdown + JSON 报告

## Skill Split

### `$merge-manager`

负责：
- inventory / classify / validate / order / report
- multi-agent gate 映射
- dry-run planning

不负责：
- 真正批量 merge
- cleanup delete
- ref 写入

### `$review-merge-main-cleanup`

继续作为 legacy execute 入口，负责：
- 已批准场景的自动收敛与 cleanup
- 既有调用方兼容

在 phase 1 中，旧 skill 仍保留原 CLI；只有可安全复用的只读核心才会与 `merge-manager` 共享。

## Dry-Run vs Future Execute

- 当前开放：`--mode dry-run`
- 当前关闭：`--mode execute`（明确返回 `not enabled in MVP`）
- future execute 需要额外 Gate 审核与 isolated worktree 执行

## Multi-Agent Mapping

- `Orchestrator`: 汇总输入、Root Cause Matrix、merge order、最终报告
- `Explorer`: inventory lane / risk-overlap lane
- `Worker`: future execute 中单 slice 实施
- `Reviewer`: Gate B / Pre-Merge / Gate D2
- `Tester`: dry-run 非破坏性与 legacy facade 回归验证

## Recommended Dry-Run Command

```bash
bash /Users/crane/.codex/skills/merge-manager/scripts/run_merge_manager.sh \
  --mode dry-run \
  --base main \
  --branch-pattern 'worker/*' \
  --report /tmp/merge-manager.md \
  --json
```
