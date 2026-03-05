# WORKFLOW.md — Kopiclaw Engineering Pipeline

## The Loop

Every feature follows this pipeline. No shortcuts.

### Phase 1: Plan
1. **Scope the feature** — Understand the request, research the codebase
2. **Write PRD** — Clear problem statement, specific outcomes, deliverables
3. **Check with human** — Present PRD, get confirmation before any code

### Phase 2: Plan Agents
1. **Write coding plan** — Break feature into implementation steps
2. **Create plan with Agent A** (primary coder)
3. **Review plan with Agent B** (second opinion)
4. **Integrate feedback, ask for uncertainty score** (1-5 scale)
5. **If uncertainty > 2 (not low/minimal):** split into sub-plans, repeat review
6. **Final plan approved → execute**

### Phase 3: Implement
1. **Spawn coding agent** with detailed prompt + plan + context
2. **Monitor progress** — check tmux, redirect if needed
3. **Post-implementation checks** (ask the agent):
   - "Have we tested this? What test coverage exists?"
   - "Any risks or bugs here? What could go wrong?"

### Phase 4: Audit
1. **Spawn audit agent** (different from implementer) with:
   - Original PRD
   - Coding plan
   - Prompt: "Audit the codebase to verify this has been implemented correctly"
2. **If significant issues found:** play back to original coding agent to fix
3. **Iterate until audit passes**

### Phase 5: PR
1. **Create PR** with:
   - Clear description linking to PRD
   - Screenshots (required for any UI changes)
   - Test results
2. **Execute automated PR reviews** (Codex, Claude, Gemini)
3. **Iterate on critical review feedback**
4. **Ensure build passes** — if CI fails, fix and re-push
5. **Notify human: "PR #X ready for review"**

## Agent Selection

| Task Type | Primary Agent | Audit Agent |
|-----------|--------------|-------------|
| Backend logic, APIs, complex bugs | Codex | Claude Code |
| Frontend, UI, components | Claude Code | Codex |
| Multi-file refactors | Codex | Claude Code |
| Git operations, quick fixes | Claude Code | Codex |

**Rule:** The agent that implements never audits its own work.

## Uncertainty Scoring

When reviewing a plan, agents rate uncertainty 1-5:
- **1 (Minimal):** Straightforward, well-understood. Execute immediately.
- **2 (Low):** Minor unknowns, but clear path. Execute.
- **3 (Medium):** Some unknowns. Consider splitting. Ask human if unsure.
- **4 (High):** Significant unknowns. Must split into sub-plans.
- **5 (Very High):** Needs research/spike first. Do not implement directly.

## Worktree Convention

- Base: `/Users/kopi/Projects/kopi-worktrees/`
- Branch naming: `feat/<task-id>`, `fix/<task-id>`, `refactor/<task-id>`
- One worktree per task, one tmux session per agent
- Worktree name = task ID

## Slack Alerts

Alert on EVERY iteration within a task. Each alert includes:
- **Product context:** what product goal/feature this serves
- **Engineering task:** what specific work is being done
- **Findings:** what happened in this iteration (implement result, audit findings, fix results)
- **Pipeline position:** which phase we're in and what's next

Make it clear if this is a step in a broader pipeline (e.g. "Audit #2 of 'content calendar export' — 2 minor issues found, sending back for fixes").

## Three-Iteration Rule

If a task goes through MORE THAN 3 implement→audit→fix cycles and issues are NOT quickly converging to trivial:
1. **STOP** — do not continue iterating
2. **Revert** all changes on the branch (`git reset --hard origin/main`)
3. **Split** the task into smaller subtasks
4. **Re-plan** each subtask independently (new PRD, new plan, new execution loop)
5. Alert human: "Task X exceeded 3 iterations without converging. Reverted and split into N subtasks."

This prevents infinite loops on tasks that are too complex for a single agent pass.

## Git Rules

- **NEVER commit directly to Rendition main** — all changes go through PRs on feature branches
- Kopiclaw (orchestrator) does not write code — only dispatches to coding agents
- All Rendition changes must go through the full pipeline: plan → implement → audit → PR

## PR Standards

- Title: `[Package] Brief description (#issue)`
- Body: Problem → Solution → Testing → Screenshots
- All UI changes MUST include screenshots
- Must pass: lint, types, unit tests, CI
- Must pass: at least 2/3 automated code reviews
