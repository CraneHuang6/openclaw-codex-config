# Merge Playbook

## State Meanings

- `ready`: dry-run 下满足低风险、无高风险 overlap、验证通过，可作为 future execute 候选
- `blocked`: 缺少验证命令、重放冲突、验证失败或 prerequisite 不满足
- `manual_review`: 命中高风险路径或核心文件 overlap，需要人工判断
- `stale`: 分支过旧，需要先 refresh/rebase

## Order Heuristics

默认顺序：
1. foundation / shared
2. interface / schema support
3. business logic
4. docs / tests only

## MVP Boundary

- 只产出 dry-run 结论
- 不执行真实 merge
- 真实执行继续走 legacy `$review-merge-main-cleanup`
