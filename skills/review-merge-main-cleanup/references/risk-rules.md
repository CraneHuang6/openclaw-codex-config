# 风险判定规则

## 目标

将“自动合并”限制在可确定、低风险、可审计的分支；对不确定项先完整审计并保留。

## 命中即不确定（高风险）

1. 运行态/缓存/数据库/媒体落地文件改动
- 路径示例：
  - `browser/openclaw/user-data/`
  - `memory/*.sqlite`
  - `media/inbound/`
  - `workspace/` 或 `workspace`
  - `exec-approvals.json`

2. 大量二进制改动
- 使用 `git diff --numstat <base>...<branch>` 统计二进制条目（`- -`）。
- 默认阈值：`> 20` 记为高风险。

3. 可疑锁文件改动
- 文件名匹配 `*.lock` 或 `*.lock.*`。

4. 冲突预测失败
- 使用 `git merge-tree $(git merge-base <base> <branch>) <base> <branch>`。
- 出现冲突标记视为高风险。

## 审计包内容（不确定分支）

- 分支名称
- 风险等级（默认 `high`）
- 风险原因列表
- 改动摘要（提交列表 + name-status）
- 处理建议（默认：人工审计后决定 merge/cherry-pick/放弃）

## 默认策略

- 不确定分支一律保留，不自动合并，不自动删除。
- 清理动作仅允许删除“已合并本地分支”。
