# Merge Manager Skill Assets

`skills/merge-manager` 现在同时提供两类能力：
- 本地 dry-run branch inventory / classify / validate / report；
- GitHub PR gate / auto-merge / conflict-repair 的可落盘模板资产。

## Adoption model

推荐把整个 `skills/merge-manager/` 目录 vendoring 到目标仓库，然后：
1. 将 `skills/merge-manager/templates/github/workflows/*.yml` 复制到目标仓库 `.github/workflows/`。
2. 将 `skills/merge-manager/templates/pr_template.md` 复制到目标仓库 `.github/pull_request_template.md`。
3. 将 `skills/merge-manager/config/*.yaml` 保持在仓库内并纳入 code review。
4. 补一份目标仓库自己的 `CODEOWNERS`，让 protected paths 有明确人工审核人。

## What ships in v1

- `config/`: GitHub gate 规则单一权威
- `scripts/`: risk / size / body / readiness / conflict / enqueue-automerge
- `templates/github/workflows/`: `pr-gate`、`automerge-manager`、`conflict-repair`
- `prompts/`: Worker / Reviewer / Merge Manager / Conflict Repair
- `templates/`: PR / issue / handoff 模板

## Local verification

```bash
python3 -m unittest discover -s /Users/crane/.codex/skills/merge-manager/tests -p 'test_*.py'
bash /Users/crane/.codex/skills/merge-manager/scripts/tests/run-tests.sh
```

## Notes

- v1 只实现 `ENABLE_AUTO_MERGE`，默认 `--auto --squash`。
- `merge queue` 只在配置与文档中预留；phase 2 再接 GitHub queue。
- `assets/merge-policy.yaml` 是由 canonical `config/*.yaml` 派生的兼容快照；dry-run 默认会先从 `config/*.yaml` 生成临时 legacy policy，再进入现有 shell CLI。
