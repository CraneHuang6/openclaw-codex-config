from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
FIXTURES = SCRIPTS / "tests" / "fixtures"

sys.path.insert(0, str(SCRIPTS / "lib"))

from github_gate_support import derive_legacy_policy, load_simple_yaml  # noqa: E402


def run_command(*args: str, check: bool = False, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=cwd, text=True, capture_output=True, check=check)


class GitRepoFixture:
    def __init__(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self.root = Path(self._tmpdir.name) / "repo"

    def setup(self) -> "GitRepoFixture":
        self.root.mkdir(parents=True, exist_ok=True)
        run_command("git", "init", "-q", str(self.root), check=True)
        run_command("git", "-C", str(self.root), "config", "user.name", "Codex Test", check=True)
        run_command("git", "-C", str(self.root), "config", "user.email", "codex@example.com", check=True)
        (self.root / "src").mkdir(parents=True, exist_ok=True)
        (self.root / "scripts").mkdir(parents=True, exist_ok=True)
        (self.root / "package.json").write_text(
            '{"scripts":{"lint":"echo lint","typecheck":"echo typecheck","test":"echo test"}}',
            encoding="utf-8",
        )
        (self.root / "scripts" / "check-agent-contracts.sh").write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        run_command("chmod", "+x", str(self.root / "scripts" / "check-agent-contracts.sh"), check=True)
        (self.root / "src" / "app.txt").write_text("base\n", encoding="utf-8")
        run_command("git", "-C", str(self.root), "add", ".", check=True)
        run_command("git", "-C", str(self.root), "commit", "-q", "-m", "base", check=True)
        run_command("git", "-C", str(self.root), "branch", "-M", "main", check=True)
        run_command("git", "-C", str(self.root), "remote", "add", "origin", str(self.root), check=True)
        run_command(
            "git",
            "-C",
            str(self.root),
            "fetch",
            "-q",
            "origin",
            "main:refs/remotes/origin/main",
            check=True,
        )
        return self

    def create_feature_branch(self, name: str = "task/test") -> None:
        run_command("git", "-C", str(self.root), "checkout", "-q", "-b", name, check=True)

    def cleanup(self) -> None:
        self._tmpdir.cleanup()


class MergeManagerGitHubTests(unittest.TestCase):
    def test_risk_gate_matches_protected_paths(self) -> None:
        repo = GitRepoFixture().setup()
        self.addCleanup(repo.cleanup)
        repo.create_feature_branch()
        (repo.root / "infra").mkdir(parents=True, exist_ok=True)
        (repo.root / "infra" / "config.tf").write_text("ops\n", encoding="utf-8")
        run_command("git", "-C", str(repo.root), "add", ".", check=True)
        run_command("git", "-C", str(repo.root), "commit", "-q", "-m", "infra change", check=True)

        result = run_command(
            "python3",
            str(SCRIPTS / "risk_gate.py"),
            "--repo",
            str(repo.root),
            "--base-ref",
            "origin/main",
            "--head-ref",
            "HEAD",
            "--protected-paths",
            str(ROOT / "config" / "protected_paths.yaml"),
        )

        self.assertEqual(result.returncode, 2)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["risk_level"], "high")
        self.assertIn("infra/config.tf", payload["protected_paths_touched"])

    def test_pr_size_gate_blocks_oversized_change(self) -> None:
        repo = GitRepoFixture().setup()
        self.addCleanup(repo.cleanup)
        repo.create_feature_branch()
        large = repo.root / "src" / "large.txt"
        large.write_text("".join(f"line-{index}\n" for index in range(900)), encoding="utf-8")
        run_command("git", "-C", str(repo.root), "add", ".", check=True)
        run_command("git", "-C", str(repo.root), "commit", "-q", "-m", "large change", check=True)

        result = run_command(
            "python3",
            str(SCRIPTS / "pr_size_gate.py"),
            "--repo",
            str(repo.root),
            "--base-ref",
            "origin/main",
            "--head-ref",
            "HEAD",
            "--rules",
            str(ROOT / "config" / "merge_rules.yaml"),
        )

        self.assertEqual(result.returncode, 2)
        payload = json.loads(result.stdout)
        self.assertTrue(payload["too_large"])
        self.assertGreater(payload["lines_changed"], payload["max_lines_changed"])

    def test_pr_body_gate_requires_sections(self) -> None:
        result = run_command(
            "python3",
            str(SCRIPTS / "pr_body_gate.py"),
            "--rules",
            str(ROOT / "config" / "merge_rules.yaml"),
            "--body-file",
            str(FIXTURES / "pr-body-missing.md"),
        )

        self.assertEqual(result.returncode, 2)
        payload = json.loads(result.stdout)
        self.assertIn("missing rollback plan", payload["missing"])

    def test_evaluate_merge_readiness_blocks_and_fails_closed(self) -> None:
        blocked = run_command(
            "python3",
            str(SCRIPTS / "evaluate_merge_readiness.py"),
            "--rules",
            str(ROOT / "config" / "merge_rules.yaml"),
            "--state-json",
            str(FIXTURES / "blocked-state.json"),
        )
        self.assertEqual(blocked.returncode, 0)
        blocked_payload = json.loads(blocked.stdout)
        self.assertEqual(blocked_payload["decision"], "BLOCK_AND_COMMENT")
        self.assertIn("blocking label present", blocked_payload["failures"])

        fail_closed = run_command(
            "python3",
            str(SCRIPTS / "evaluate_merge_readiness.py"),
            "--rules",
            str(ROOT / "config" / "merge_rules.yaml"),
            "--state-json",
            str(FIXTURES / "missing-fields-state.json"),
        )
        self.assertEqual(fail_closed.returncode, 2)
        fail_payload = json.loads(fail_closed.stdout)
        self.assertEqual(fail_payload["decision"], "BLOCK_AND_COMMENT")
        self.assertIn("missing required state keys", fail_payload["error"])

    def test_canonical_config_generates_legacy_policy_snapshot(self) -> None:
        payload = derive_legacy_policy(ROOT / "config")
        snapshot = load_simple_yaml(ROOT / "assets" / "merge-policy.yaml")

        self.assertEqual(payload, snapshot)
        self.assertIn("secrets/**", payload["high_risk_paths"])
        self.assertEqual(payload["validation_commands"]["explicit"], ["bash scripts/check-agent-contracts.sh"])

    def test_workflow_templates_live_under_templates_github(self) -> None:
        workflow_dir = ROOT / "templates" / "github" / "workflows"
        self.assertTrue((workflow_dir / "pr-gate.yml").is_file())
        self.assertTrue((workflow_dir / "automerge-manager.yml").is_file())
        self.assertTrue((workflow_dir / "conflict-repair.yml").is_file())
        self.assertFalse((ROOT / "templates" / "workflows").exists())

    def test_enqueue_automerge_public_script_supports_dry_run(self) -> None:
        result = run_command(
            "bash",
            str(SCRIPTS / "enqueue_automerge.sh"),
            "--decision-json",
            str(FIXTURES / "ready-decision.json"),
            "--pr",
            "42",
            "--repo",
            "owner/repo",
            "--dry-run",
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertIn("gh pr merge 42 --repo owner/repo --auto --squash", result.stdout)


if __name__ == "__main__":
    unittest.main()
