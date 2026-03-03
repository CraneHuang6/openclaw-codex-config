---
name: ralph-loop
description: 当需要把 Markdown 任务清单按依赖关系进行并行优先编排，并与 superpowers 门禁流程联动执行时使用。
---

# Ralph Loop

## Overview

将 Ralph loop 从“逐任务串行”升级为“依赖感知并行优先”调度器。
本技能只做编排与状态管理，不复制 superpowers 的实现能力。

## Trigger

在以下请求中使用本技能：

- “按 PRD/plan 自动推进任务并可恢复”
- “多任务并行执行但要遵守 depends”
- “要和 superpowers 的 review/verification 门禁联动”

## Workflow Contract (Mandatory)

执行顺序与门禁：

1. `superpowers:brainstorming`（设计确认）
2. `superpowers:writing-plans`（落地计划）
3. `superpowers:subagent-driven-development` 或 `superpowers:dispatching-parallel-agents`（实施）
4. `superpowers:requesting-code-review`（评审）
5. `superpowers:verification-before-completion`（最终验证）

阻断条件：

- 未确认计划（Plan Gate）不得进入非 dry-run 调度
- Reviewer 未 PASS 不得进入集成
- Tester 未通过不得宣告完成

## CLI

主入口：

```bash
bash /Users/crane/.codex/skills/ralph-loop/scripts/ralph-loop.sh --plan <abs-path> --mode <parallel|hybrid|serial> --max-lanes <N> --dry-run
```

恢复：

```bash
bash /Users/crane/.codex/skills/ralph-loop/scripts/ralph-loop.sh --plan <abs-path> --resume
```

非 dry-run 需显式门禁确认：

```bash
bash /Users/crane/.codex/skills/ralph-loop/scripts/ralph-loop.sh \
  --plan <abs-path> \
  --mode parallel \
  --max-lanes 3 \
  --plan-approved \
  --reviewer-pass \
  --tester-pass
```

更新任务状态：

```bash
bash /Users/crane/.codex/skills/ralph-loop/scripts/ralph-loop.sh --plan <abs-path> --resume --complete US-001
bash /Users/crane/.codex/skills/ralph-loop/scripts/ralph-loop.sh --plan <abs-path> --resume --fail US-004
```

## Plan Format

- 任务行：`- [ ] ...` 或 `- [x] ...`
- 推荐任务 ID：`**US-001**`（若缺失会自动生成 `T001`）
- 可选依赖：`[depends: US-001,US-002]` 或 `none`

## Outputs

运行状态目录：`/Users/crane/.codex/workspace/outputs/ralph-loop/<run-id>/`

- `run_state.json`：任务状态、lane、重试计数
- `progress.log`：关键事件日志
- `claims.lock`：认领互斥锁

## Mode Semantics

- `parallel`：按 `max-lanes` 并行派发 ready 任务
- `hybrid`：最多 2 个 lane（研究并行、实现收敛）
- `serial`：单 lane 串行

## References

- 流程映射与差异：`references/workflow.md`
- 示例计划：`references/examples/sample-plan.md`
- 验收模板：`references/acceptance-report-template.md`
