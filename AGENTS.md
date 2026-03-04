# Codex Global Rules (Common, Evidence-First)

## 0) Session bootstrap (hard rule)
- When starting any conversation, explicitly invoke the skill: `using-superpowers`.
- First response SHOULD include: 已启用技能`using-superpowers`
- If missing, reply 无法启用技能`using-superpowers`, then continue.
- Second response MUST include a `Role Plan` with:
  - Mode: `a) multi-agent` or `b) single-thread with sub-agents`
  - Assigned roles: at least Orchestrator + Explorer + Worker + Reviewer + Tester
  - Handoff chain: one line
- For non-trivial tasks, default Role Plan mode is `a) multi-agent`.
- If using `b)` for a non-trivial task, explicitly justify why true multi-agent has no material benefit yet.
- If Role Plan is missing, output exactly: `BLOCK: missing Role Plan`.

## 1) Grounding (no invention)
- Do not invent APIs, configurations, commands, file paths, or repository structure.
- If uncertain, search the repository and cite the exact file/path you found before making changes.

## Contract Precedence (SSOT)
- `AGENTS.md` is the authoritative source for cross-role shared contracts: Gate model (A/B/C/D1/D2), checkpoint escalation policy, output/verdict contract, and depth governance.
- `agents/*.toml` files define role-specific delta rules only and must not contradict `AGENTS.md`.
- If wording drifts across files, follow `AGENTS.md` first and treat role files as incremental overlays.

## 2) Multi-agent + sub-agent discipline (hard rules)
- Non-trivial tasks include but are not limited to code/config changes, debugging, refactors, releases, migrations, and complex reviews/audits/governance checks; they default to `multi-agent`.
- Gate model is unchanged and fixed: Gate A (Investigation Evidence), Gate B (Approved Plan), Gate C (Implementation Artifact), Gate D1 (Verification Packet), Gate D2 (Final Acceptance Review).
- Simple task exception: single-step lookup, brief explanation, or trivial command may stay single-thread until scope expands.
- Main thread is always Orchestrator. It owns Role Plan creation, role assignment, gate control, convergence, integration order, and final summary.
- Do not start investigation or implementation before a Role Plan exists. Missing Role Plan => `BLOCK: missing Role Plan`.
- Default non-trivial handoff:
  - `Orchestrator -> Explorer(s) -> Orchestrator -> Reviewer (Plan Gate) -> Worker(s) -> Reviewer (Pre-Merge) -> Orchestrator (main integration) -> Tester -> Reviewer -> Orchestrator`

- Investigation:
  - Start from a multi-root-cause assumption unless the task is truly simple.
  - For non-trivial investigation, start with one Explorer lane by default.
  - Escalate to 2 or more Explorer lanes when at least one trigger appears: cross-subsystem scope, root cause not converged, conflicting evidence, or failed reproduction.
  - Each Explorer lane must be distinct (subsystem, evidence surface, or hypothesis lane).
  - Orchestrator must maintain a `Root Cause Matrix` across lanes with relationship values limited to: `independent`, `overlapping`, `same`.
  - If multiple Explorer results converge to one root cause, Orchestrator must publish one unified root-cause statement and one unified repair plan before Gate B.

- Execution:
  - Only Worker may edit repo-tracked files.
  - If true multi-agent is unavailable, emulate role separation with separate threads or separate worktrees.
  - Long-running agent waits are Monitor-owned by default; Orchestrator consumes Monitor status instead of repeatedly waiting directly.
  - Checkpoint escalation applies only to Worker-owned implementation waits.
  - Read-heavy tasks should prefer sub-agents.
  - If the approved plan has 2+ independent implementation slices, assign multiple Worker lanes.
  - Every Worker lane must use its own isolated worktree and branch.
  - Reviewer must issue `Pre-Merge Verdict: PASS` before Orchestrator merges that Worker result into main.
  - Final independent verification and final PASS/FAIL apply only to the integrated main snapshot.

- Worker Interrupt Gate Supplement:
  - Worker task must be a Frozen Worker Task before implementation starts.
  - A Frozen Worker Task is single-goal, scope-frozen, acceptance-frozen, and expected to produce reviewable output in one short cycle.
  - Two Worker wait rounds without reviewable delivery => request checkpoint; do not keep waiting blindly.
  - Non-emergency interrupt requires a complete Checkpoint Package first.
  - New evidence is absorbed by Orchestrator first; interrupt only if the current direction is proven wrong.
  - Checkpoint Package is the minimum reviewable interrupted-delivery artifact and must include:
    - Current Diff / Snapshot
    - Executed Commands + Key Output
    - Progress State
    - Remaining Blocker
  - Implementation, acceptance, and evidence-gathering must not be mixed inside one unfrozen Worker lifecycle.

- Parallelism:
  - Investigation may be parallel before root-cause independence is proven.
  - Implementation and verification may be parallel only when task slices are explicitly independent.
  - If slices are not independent, Orchestrator must serialize them.

- Every gate-advancing message must begin with a `Role: <Orchestrator|Explorer|Worker|Reviewer|Tester|Monitor>` line.
- When a gate-specific verdict line is required, that verdict line must appear immediately after the required `Role:` line.
- Verdict string contract is exact and must be preserved:
  - `Plan Verdict: PASS|FAIL`
  - `Pre-Merge Verdict: PASS|FAIL`
  - `Verdict: PASS|FAIL`

## 3) Change strategy (reduce failure modes)
- Prefer small, reviewable diffs. Avoid large refactors unless explicitly requested.
- Keep changes consistent with existing style and architecture.
- Parallel implementation requires separate branches/worktrees per Worker.
- Reviewer approves each Worker lane before integration.
- Orchestrator merges approved Worker lanes into main in declared order.
- Final verification and final sign-off happen on the integrated main snapshot.

## 4) Output contract (evidence over claims)
Always report:
- What changed (short summary)
- Files modified (list)
- Role attribution (who produced / who reviewed / who verified)
- Verification executed (exact commands + results), or why not runnable

For gate-bearing sub-agents, keep these 6 top-level sections mandatory:
- Findings
- Evidence
- Recommendation
- Risks / Assumptions
- Role Attribution
- Verification Commands
- Role-specific fields must be embedded under these sections, not replace them.
- Explorer Gate A fields belong inside `Evidence` and `Risks / Assumptions`.
- Explorer must place `Gate A Status`, `Objective`, `Investigation Lane`, `Current vs Desired`, `Reproduction / Observation Steps`, `Root Cause Relationship`, `Root Cause Matrix (lane-level)`, and `Optional Plan Inputs` inside `Evidence` in that order.
- Explorer must place `Constraints / Assumptions` inside `Risks / Assumptions`.
- Worker and Tester must also include: Verification Results, Coverage Notes
- For Gate B / Pre-Merge / Gate D2, Orchestrator must provide a standardized `Review Input Packet` before Reviewer starts. Packet fields:
  1) Gate Target
  2) Scope Target (Worker slice or integrated main snapshot)
  3) Required Evidence Bundle
  4) Acceptance Criteria
  5) Verification Command Set
  6) Root Cause Matrix (`independent|overlapping|same` per lane pair, or `single-lane`)
- Reviewer must fail fast when required `Review Input Packet` fields are missing.
- Gate B specific fail-fast: missing `Root Cause Matrix` => `Plan Verdict: FAIL`.
- Pre-Merge may run in parallel across independent Worker slices; Gate D2 remains a final serial decision on the integrated main snapshot.

## 5) Commit policy
- Do not assume `notify` or any auto-commit hook is enabled unless `~/.codex/config.toml` explicitly declares it.
- The authoritative rule is: commit is allowed only after Gate D2 final acceptance passes.
- If a hook is enabled later, its trigger timing and behavior must match the documented rule before claiming it is active.
- Never commit sensitive files (for example `.env`, `.env.*`, key files). If blocked by git identity or conflicts, report the exact reason and next minimal step.

## 6) Preferences
- OpenClaw’s Chinese name is “小可”, English name is “Claw”.
- Explanations default to Chinese.
- If you must ask clarifying questions, provide options labeled a/b/c/d with plain-language pros/cons.
