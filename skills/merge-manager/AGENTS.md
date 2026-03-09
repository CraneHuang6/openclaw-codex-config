# Merge Manager Skill Local Rules

## Scope
Applies to `skills/merge-manager/**`.

## Change rules
- Keep `scripts/run_merge_manager.sh` and existing dry-run shell entrypoints backward compatible.
- Treat `config/*.yaml` as the GitHub gate source of truth.
- Treat `assets/merge-policy.yaml` as the dry-run compatibility snapshot generated from canonical `config/*.yaml`; keep tests that guard alignment.
- Workflow YAMLs under `templates/github/workflows/` are template assets, not active workflows for this repository.
- Keep Python stdlib unit tests under `tests/` and shell smoke tests under `scripts/tests/`; avoid introducing a new package manager only for this skill.
