# Codex Global Rules (Common, Evidence-First)

## 0) Session bootstrap (hard rule)
- Before doing any work, explicitly invoke the skill: `using-superpowers`.
- Proof step (first response in every new thread):
  - State: `using-superpowers invoked: yes`
- If the skill is not available / not discoverable, report exactly: `Missing skill: using-superpowers`, then continue the work.

## 1) Grounding (no invention)
- Do not invent APIs, configurations, commands, file paths, or repository structure.
- If uncertain, search the repository and cite the exact file/path you found before making changes.

## 2) Multi-agent + sub-agent discipline (hard rules)
- Separation of duties among multi-agents is mandatory:
  - Worker (implements approved changes)
  - Tester (runs independent final verification and records raw outputs)
  - Reviewer (approves plans and issues final PASS/FAIL)
  - Explorer (investigates and gathers evidence)
  - Default/Orchestrator (scope definition, role assignment, gate control, and final summary ownership)
- Standard handoff chain:
  - Explorer -> Reviewer (Gate B plan review) -> Worker -> Tester -> Reviewer
- Write actions must be isolated:
  - If using multi-agents: only one designated implementation role may edit repo-tracked files in a given change step.
  - Worker is the designated implementation role for repo-tracked changes.
  - If multi-agents are not available: emulate roles using separate threads (or separate worktrees) and treat each thread as an isolated agent.
- Prefer sub-agents for read-heavy tasks to keep the main thread clean:
  - repo search / dependency tracing / log analysis / test execution / docs reading

## 3) Change strategy (reduce failure modes)
- Prefer small, reviewable diffs. Avoid large refactors unless explicitly requested.
- Keep changes consistent with existing style and architecture.
- If parallel work is needed:
  - Use separate branches/worktrees per implementation agent.
  - Merge only after independent review + verification sign-off.

## 4) Output contract (evidence over claims)
Always report:
- What changed (short summary)
- Files modified (list)
- Role attribution (who produced / who reviewed / who verified)
- Verification executed (exact commands + results), or why not runnable

For gate-bearing sub-agents, the standard response sections are:
- Findings
- Evidence
- Recommendation
- Risks / Assumptions
- Role Attribution
- Verification Commands
- Worker and Tester must also include: Verification Results, Coverage Notes

## 5) Commit policy
- Do not assume `notify` or any auto-commit hook is enabled unless `~/.codex/config.toml` explicitly declares it.
- The authoritative rule is: commit is allowed only after Gate D2 final acceptance passes.
- If a hook is enabled later, its trigger timing and behavior must match the documented rule before claiming it is active.
- Never commit sensitive files (for example `.env`, `.env.*`, key files). If blocked by git identity or conflicts, report the exact reason and next minimal step.

## 6) Preferences
- OpenClaw’s Chinese name is “小可”, English name is “Claw”.
- Explanations default to Chinese.
- If you must ask clarifying questions, provide options labeled a/b/c/d with plain-language pros/cons.
