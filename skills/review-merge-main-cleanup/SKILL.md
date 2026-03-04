---
name: review-merge-main-cleanup
description: 自动审查本地分支并安全收敛到 main：可确定分支自动合并，不确定分支先完整审计并保留，最后仅清理已合并本地分支。用于“审查代码、合并到main、清理已合并分支、保留未合并分支供最终人工统一处理”的场景。
---

# Review Merge Main Cleanup

## Overview

使用本技能时，执行器会按“安全优先”的固定流程完成分支收敛：

1. 审查所有本地分支相对 `main` 的差异。
2. 自动合并可确定、低风险且可无冲突合并的分支。
3. 对不确定分支输出完整审计包（改动、风险、建议），并保留不合并。
4. 清理已合并本地分支（仅本地，不删除远端分支）。

## Workflow Contract

### Safety Rules

- 只处理本地分支与本地 worktree。
- 不删除远端分支。
- 命中风险规则的分支必须进入“不确定审计队列”，不得自动合并。
- 若检测到非预期状态漂移（工作区状态变更），流程报告并以非零状态退出。

### Core CLI

```bash
bash /Users/crane/.codex/skills/review-merge-main-cleanup/scripts/review_merge_main_cleanup.sh \
  --base main \
  --cleanup local-only \
  --mode auto \
  --report /abs/path/report.md \
  --json
```

参数说明：

- `--base`: 基线分支，默认 `main`
- `--cleanup`: 仅支持 `local-only`
- `--mode`: 仅支持 `auto`
- `--report`: Markdown 报告输出路径（必填）
- `--json`: 附加生成同名 `.json` 报告并打印 JSON 摘要

## Decision Logic

### 自动合并条件（全部满足）

- 分支尚未合并进基线。
- 不命中风险规则（见 `references/risk-rules.md`）。
- 冲突预测通过（`git merge-tree` 无冲突标记）。

### 不确定审计触发

任一命中即进入完整审计并保留：

- 运行态/缓存/数据库/媒体落地文件改动。
- 二进制改动量过大或出现可疑锁文件。
- 冲突预测失败或实际 merge 失败。

## Outputs

- Markdown 报告：按 `references/report-template.md` 结构输出。
- JSON 报告：与 Markdown 同目录同名 `.json`。
- 报告必须包含：
  - 已合并分支列表
  - 已清理分支列表
  - 不确定分支审计包（改动摘要、风险、建议）
  - 保留未合并分支列表
  - 执行命令与关键结果

## References

- 风险判定规则：`references/risk-rules.md`
- 报告结构模板：`references/report-template.md`
