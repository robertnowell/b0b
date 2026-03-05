# WORKFLOW.md — Pipeline Details & Conventions

Supplements the pipeline rules in AGENTS.md with conventions and standards.

## Pipeline Phases (Actual)

All phases are managed by `monitor.sh`. Each runs a coding agent (Claude Code or Codex) in a git worktree.

```
planning → plan_review → implementing → auditing → fixing → testing → pr_creating → reviewing → pr_ready → merged
```

- **planning**: Agent investigates codebase, writes `plan.md`
- **plan_review**: Plan posted to Slack. Auto-advances by default; holds for approval if `--require-plan-review true`
- **implementing**: Agent implements the plan
- **auditing**: Different agent (codex↔claude swap) audits the diff against the plan
- **fixing**: Agent addresses audit/test findings (max 4 iterations total before auto-split)
- **testing**: Agent runs lint, build, tests in changed packages
- **pr_creating**: Agent creates or updates the PR
- **reviewing**: Awaiting human review/merge
- **pr_ready**: PR approved, ready to merge
- **merged**: Done

On failure after max iterations, `monitor.sh` auto-reverts the worktree and either retries (once) or auto-splits into subtasks.

## Agent Selection

- **Claude Code**: Default agent. Frontend work, UI changes, git operations, faster turnaround.
- **Codex**: Backend logic, complex bugs, multi-file refactors, reasoning-heavy tasks.

Pass `--agent codex` or `--agent claude` to `dispatch.sh`. The same agent type is used for implementation, testing, and PR phases. **Auditing always uses the opposite agent** (`choose_audit_agent()` in monitor.sh swaps codex↔claude) so the implementer never audits its own work.

## Worktree Convention

- Base: `/Users/kopi/Projects/kopi-worktrees/`
- Branch naming: `feat/<task-id>`, `fix/<task-id>`, `refactor/<task-id>`
- One worktree per task, one tmux session per agent
- Worktree name = task ID

## Slack Alerts

`notify.sh` posts to `#alerts-kopi-claw` on every phase transition. Each alert includes:
- **Product context:** what product goal/feature this serves
- **Engineering task:** what specific work is being done
- **Findings:** what happened in this iteration (audit findings, test results, fix results)
- **Pipeline position:** which phase we're in and what's next
- **Relative timestamps:** how long ago the task started or last changed phase

## Context Validation

Every agent spawn logs a `context_validation` block to `transitions-{task-id}.jsonl`. Check for `valid: false` entries to catch missing template variables. The pipeline warns on stderr when required context is missing for a phase.

## Git Rules

- **NEVER commit directly to main** — all changes go through PRs on feature branches
- Kopiclaw (orchestrator) does not write code — only dispatches to coding agents
- All changes must go through the full pipeline: plan -> implement -> audit -> PR

## PR Standards

- Title: `[Package] Brief description`
- Body: Problem -> Solution -> Testing -> Screenshots
- All UI changes MUST include screenshots
- Must pass: lint, build, unit tests
