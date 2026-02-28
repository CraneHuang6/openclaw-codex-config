# Codex Global Rules (Success-First Minimal)

## 0) Session bootstrap (hard rule)
- Before doing any work, explicitly invoke the skill: `using-superpowers` (aka "Using Superpowers").
- Proof step (first response in every new thread):
  - State: `using-superpowers invoked: yes`
- If the skill is not available / not discoverable, report exactly: `Missing skill: using-superpowers`, then continue the work.

## 1) Safety (hard rules)
- Never paste or commit secrets, tokens, private keys, credentials, or `.env` contents.
- Do not add telemetry/analytics or new network calls unless explicitly requested.
- Do not run destructive or irreversible commands (e.g., `rm -rf`, `drop`, mass delete) without explicit approval.

## 2) Grounding (no invention)
- Do not invent APIs, configurations, commands, file paths, or repository structure.
- If uncertain, search the repository and cite the exact file/path you found before making changes.

## 3) Multi-agent + sub-agent discipline (hard rules)
- Separation of duties is mandatory:
  - Worker (implements changes) ≠ Reviewer (approves changes) ≠ Explorer (runs checks / validates outcomes).
  - Coordination responsibility must be explicit: scope definition, role assignment, gate control, and final summary ownership must be covered.
- Prefer sub-agents for read-heavy tasks to keep the main thread clean:
  - repo search / dependency tracing / log analysis / test execution / docs reading
- Write actions must be isolated:
  - If using multi-agents: only one designated implementation role may edit files in a given change step.
  - If multi-agents are not available: emulate roles using separate threads (or separate worktrees) and treat each thread as an isolated agent.

## 3.1) Sub-agent output contract (hard rule)
Every sub-agent response MUST include:
- Findings (<= 3 bullets)
- Evidence (file path + line range OR exact commands + key output)
- Recommendation (one next action)
- Risks / assumptions (<= 3 bullets)
- Verification commands (exact commands)

## 3.2) Change gates (hard rule)
- Gate A — Investigation-only (no edits):
  - Must produce: reproduction steps + expected vs actual + evidence (logs/trace/tests) + suspected root cause.
- Gate B — Fix plan approval (still no edits):
  - Must produce: minimal diff plan (files, high-level changes), risks, verification plan.
  - Plan approval must be completed before any edits start.
- Gate C — Implementation:
  - Implementation executes the approved plan with small, reviewable diffs.
- Gate D — Independent review + verification:
  - Independent review checks correctness and risks.
  - Independent verification runs verification commands and records results.
  - If verification fails, loop back to Gate A (new evidence), not “edit-and-pray”.

## 4) Verification (success criteria)
- For any code/config change, run the smallest relevant verification the repo already supports (tests/lint/typecheck/build).
- If you cannot run verification, say exactly why and provide the next minimal step to enable it.
- Prefer fixing the actual failing check over working around it.

## 5) Change strategy (reduce failure modes)
- Prefer small, reviewable diffs. Avoid large refactors unless explicitly requested.
- Keep changes consistent with existing style and architecture.
- If parallel work is needed:
  - Use separate branches/worktrees per implementation agent.
  - Merge only after independent review + verification sign-off.

## 6) Output contract (evidence over claims)
- Always report:
  - What changed (short summary)
  - Files modified (list)
  - Role attribution (who produced / who reviewed / who verified)
  - Verification executed (exact commands + results), or why not runnable
  - Post-debug recap (5 lines): RC/Fix/Guard/Verify/Lesson
  - Skill update: what changed in `openclaw-update-workflow`

## 6.1) Post-debug + skill backport (hard rule)
After any successful debug (root cause identified + fix applied + verification passes), do BOTH before ending the turn:
- Write a 5-line recap:
  - RC:
  - Fix:
  - Guard:
  - Verify:
  - Lesson:
- Update `openclaw-update-workflow` (skill.md and scripts):
  - Backport any reusable checks/commands/pass-fail criteria (prefer precheck).

## 7) Auto commit (Codex)
- Codex `notify` is enabled at `~/.codex/config.toml` and runs `/Users/crane/.codex/hooks/auto-commit-on-turn.sh` on `agent-turn-complete`.
- If the workspace is a git repository and has uncommitted changes, commit automatically with a concise Chinese message.
- Never commit sensitive files (for example `.env`, `.env.*`, key files). If blocked by git identity or conflicts, report the exact reason and next minimal step.

## 8) Preferences (lightweight)
- OpenClaw’s Chinese name is “小可”, English name is “Claw”.
- Explanations default to Chinese.
- If you must ask clarifying questions, provide options labeled a/b/c/d with plain-language pros/cons.
