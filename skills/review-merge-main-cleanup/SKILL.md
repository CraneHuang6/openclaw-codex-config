---
name: review-merge-main-cleanup
description: 自动审查本地分支并安全收敛到 main：可确定分支自动合并，不确定分支先完整审计并保留，最后清理已合并本地分支。用于“审查代码、合并到main、清理已合并分支、保留未合并分支供最终人工统一处理”的场景。
---

# Review Merge Main Cleanup

## Overview

执行器按“安全优先”流程收敛分支：

1. 加载目标分支范围（清单/模式/全量）。
2. 通过风险规则、审批门禁、测试门禁筛选可合并分支。
3. 自动合并通过门禁的分支。
4. 对不确定分支输出完整审计并保留。
5. 按 cleanup 模式处理已合并本地分支。

## Safety Rules

- 只处理本地分支与本地 worktree。
- 不删除远端分支。
- 命中风险规则、审批门禁或测试门禁失败的分支必须保留并进入审计包。
- 若检测到非预期状态漂移（工作区状态变更），流程报告并以非零状态退出。

## Core CLI

推荐默认（安全门禁全开，先只出清理计划）：

```bash
bash /Users/crane/.codex/skills/review-merge-main-cleanup/scripts/review_merge_main_cleanup.sh \
  --base main \
  --branch-pattern 'worker/*' \
  --max-branches 20 \
  --approval-file /abs/path/approvals.json \
  --require-approval \
  --pre-test 'npm test' \
  --post-test 'npm test' \
  --require-tests \
  --cleanup plan-only \
  --report /abs/path/report.md \
  --json
```

确认清理时，使用报告中的 `run_token`：

```bash
bash /Users/crane/.codex/skills/review-merge-main-cleanup/scripts/review_merge_main_cleanup.sh \
  --base main \
  --branch-pattern 'worker/*' \
  --max-branches 20 \
  --approval-file /abs/path/approvals.json \
  --require-approval \
  --pre-test 'npm test' \
  --post-test 'npm test' \
  --require-tests \
  --cleanup archive \
  --confirm-cleanup <run_token> \
  --report /abs/path/report.md \
  --json
```

## Parameters

- `--base`: 基线分支，默认 `main`
- `--cleanup`: `plan-only|archive|local-only`，默认 `local-only`
- `--mode`: 仅支持 `auto`
- `--report`: Markdown 报告输出路径（必填）
- `--json`: 附加生成同名 `.json` 报告并打印 JSON 摘要
- `--branches-file`: 目标分支清单文件（每行一个）
- `--branch-pattern`: 目标分支 glob 过滤
- `--max-branches`: 目标分支上限，超限直接失败
- `--approval-file`: 审批 JSON 文件
- `--require-approval`: 开启后，未审批分支只审计不合并
- `--pre-test`: 合并前执行一次测试命令
- `--post-test`: 每次成功合并后执行测试命令
- `--require-tests`: 开启后，必须同时提供 pre-test/post-test
- `--archive-prefix`: `cleanup=archive` 时备份 ref 前缀
- `--confirm-cleanup`: 清理确认令牌，需要与运行令牌匹配

## Approval File

```json
{
  "approved_branches": ["worker/a", "worker/b"],
  "reviewer": "name-or-id",
  "approved_at": "2026-03-04T12:00:00+08:00"
}
```

## Outputs

- Markdown 报告：按 `references/report-template.md` 结构输出。
- JSON 报告：与 Markdown 同目录同名 `.json`。
- 报告包含：
  - `target_scope`、`target_branches`
  - `approval_gate`、`test_gate`、`cleanup_mode`
  - `cleanup_candidates`、`archive_refs`、`blocked_by_gate`
  - 已合并分支、已清理分支、不确定分支审计包、保留未合并分支、执行命令证据

## References

- 风险判定规则：`references/risk-rules.md`
- 报告结构模板：`references/report-template.md`
