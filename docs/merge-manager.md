# Merge Manager

## Purpose

`merge-manager` 是新的 branch integration 制度层与编排层，职责是：
- 扫描候选分支
- 做风险分类
- 分析 overlap 与 merge order
- 在 dry-run 下验证分支相对最新 `main` 的可重放性
- 输出 Markdown + JSON 报告
- 交付 GitHub PR gate / auto-merge / conflict-repair 模板资产

## Skill Split

### `$merge-manager`

负责：
- inventory / classify / validate / order / report
- multi-agent gate 映射
- dry-run planning
- GitHub gate config / scripts / workflow templates

不负责：
- 真正批量 merge
- cleanup delete
- ref 写入

### `$review-merge-main-cleanup`

继续作为 legacy execute 入口，负责：
- 已批准场景的自动收敛与 cleanup
- 既有调用方兼容

在 phase 1 中，旧 skill 仍保留原 CLI；只有可安全复用的只读核心才会与 `merge-manager` 共享。

`merge-manager` 默认作用于当前调用目录所在的 git 仓库；skill 自身安装路径只用于解析脚本与静态资产，不作为 branch inventory 目标仓库。

## Dry-Run vs Future Execute

- 当前开放：`--mode dry-run`
- 当前关闭：`--mode execute`（明确返回 `not enabled in MVP`）
- future execute 需要额外 Gate 审核与 isolated worktree 执行

## GitHub v1 Positioning

- GitHub Actions 是 merge manager 宿主
- Worker 只在 task branch / worktree 开发，并负责 commit / push / 开 PR（由目标仓库采用时执行）
- branch protection + required checks + required review 是最终硬门禁
- `merge-manager` 只负责判定、打标签、评论、启用 `--auto --squash`
- 高风险目录永远人工审核；`CODEOWNERS` 是 adoption 前置项之一
- `merge queue` 保留到 phase 2，不在 v1 对同一受保护分支做动态切换

## Adoption Assets

v1 交付但不在当前仓库启用的模板资产：
- `skills/merge-manager/templates/github/workflows/pr-gate.yml`
- `skills/merge-manager/templates/github/workflows/automerge-manager.yml`
- `skills/merge-manager/templates/github/workflows/conflict-repair.yml`
- `skills/merge-manager/templates/pr_template.md`
- `skills/merge-manager/config/*.yaml`
- `skills/merge-manager/prompts/*.md`

推荐把整个 `skills/merge-manager/` vendoring 到目标仓库，再把 workflow 模板复制到目标仓库 `.github/workflows/`。

## Phase 2 Filtering

phase 2 的 dry-run 会额外过滤：
- 任一 git worktree 当前正在 checkout 的分支
- 已经并入 base 的本地分支

这些分支不会进入 `candidate_branches`，但会在 Markdown + JSON 报告的 `filtered_out` 中保留原因，便于审计。

## Validation Detection

validation command detection 采用“显式优先 + 保守自动探测”：
- 先使用 policy 中显式声明且在仓库根可执行的命令
- 若未命中且 `detect_if_missing: true`，再尝试根目录 manifest 对应命令
- 仍未命中时，只尝试 policy 允许的 root-only 保守脚本，不递归 nested repos

phase 1 的 `scripts/lib/validation.sh` 只负责 detection helpers；dry-run replay、临时 worktree、`git merge --no-commit` 和验证命令执行保留在 `validate_branch.sh`。

## Multi-Agent Mapping

- `Orchestrator`: 汇总输入、Root Cause Matrix、merge order、最终报告
- `Explorer`: inventory lane / risk-overlap lane
- `Worker`: future execute 中单 slice 实施
- `Reviewer`: Gate B / Pre-Merge / Gate D2
- `Tester`: dry-run 非破坏性与 legacy facade 回归验证

## Recommended Dry-Run Command

```bash
cd /path/to/target-repo && \
bash /Users/crane/.codex/skills/merge-manager/scripts/run_merge_manager.sh \
  --mode dry-run \
  --base main \
  --branch-pattern 'worker/*' \
  --report /tmp/merge-manager.md \
  --json
```
