# 报告模板（Markdown）

## 1. 执行摘要

- 时间
- 仓库路径
- 基线分支
- 执行模式
- 清理模式（cleanup_mode）
- 是否使用隔离 worktree
- run_token

## 2. 目标范围与门禁

- target_scope
- target_branches
- approval_gate
- test_gate
- gate_stop（如有）

## 3. 已合并分支

- 分支列表（按执行顺序）

## 4. 清理信息

- cleanup_candidates
- cleaned_branches
- archive_refs（cleanup=archive 时）
- 清理失败项与原因

## 5. 不确定分支完整审计

每个分支至少包含：

- 风险等级
- 风险原因
- 建议
- 提交列表
- 文件改动摘要（name-status）

## 6. blocked_by_gate

- 审批/测试/风险/清理门禁阻断项

## 7. 保留未合并分支

- 最终保留列表

## 8. 执行命令与关键结果

- 关键 git 命令
- 合并/清理结果（成功或失败）
- warnings（如有）

## 9. 漂移检查

- 工作区状态签名（开始 vs 结束）
- 是否检测到非预期状态漂移
