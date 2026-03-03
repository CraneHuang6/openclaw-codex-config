# Ralph Loop Workflow Mapping

## Reference Project 3 -> Local Skill Mapping

- 参考项目 3（gist）默认是串行循环：每轮找第一个未完成任务并执行。
- 本地 `ralph-loop` 默认改为依赖感知并行：同一轮可派发多个 ready 任务。
- 依赖规则保留：只有依赖完成的任务才能进入 ready 集合。

## Multi-Agent Integration

- `parallel`：适配当前 multi-agent，按 lane 并发派发。
- `hybrid`：最多 2 个 lane，适合“研究并行 + 实现收敛”。
- `serial`：与原始 Ralph loop 行为接近。

## Superpowers Gate Integration

- 设计门禁：`superpowers:brainstorming`
- 计划门禁：`superpowers:writing-plans`
- 实施门禁：`superpowers:subagent-driven-development` 或 `superpowers:dispatching-parallel-agents`
- 收尾门禁：`superpowers:requesting-code-review` + `superpowers:verification-before-completion`

## Failure and Resume

- 所有状态持久化在 `run_state.json`。
- `--resume` 会在原状态上继续调度，不会重做已完成任务。
- `progress.log` 记录初始化、认领、完成、失败、阻塞事件。
