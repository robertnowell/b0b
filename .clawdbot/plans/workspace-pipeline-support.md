# Plan: Add --workspace flag to pipeline

## Summary

Re-introduce the `.clawdbot/` pipeline infrastructure (reverted in `99084ea90`) and extend it with a `--workspace` flag so workspace/self-improvement tasks (tooling, CI/CD, configs, CLAUDE.md updates, etc.) are tracked through the same pipeline as product tasks. Goal: **all agent work flows through the pipeline — no untracked agents**.

---

## Files to Modify/Create

| File | Action | Description |
|------|--------|-------------|
| `.clawdbot/spawn-agent.sh` | Create | Re-introduce from commit `3120b6c87` + add `--workspace` flag |
| `.clawdbot/check-agents.sh` | Create | Re-introduce from commit `3120b6c87` + show task type in reports |
| `.clawdbot/cleanup-worktrees.sh` | Create | Re-introduce unchanged from commit `3120b6c87` |
| `.clawdbot/active-tasks.json` | Create | Empty array `[]` |
| `.clawdbot/WORKFLOW.md` | Create | Re-introduce + add workspace pipeline section |
| `.clawdbot/prompts/implement.md` | Create | Re-introduce unchanged |
| `.clawdbot/prompts/audit.md` | Create | Re-introduce unchanged |
| `.clawdbot/prompts/create-pr.md` | Create | Re-introduce unchanged |
| `.clawdbot/prompts/fix-feedback.md` | Create | Re-introduce unchanged |
| `.clawdbot/prompts/review-plan.md` | Create | Re-introduce unchanged |
| `.clawdbot/prompts/plan.md` | Create | New planning-phase prompt template |
| `CLAUDE.md` | Create | Re-introduce from commit `3120b6c87` + mention workspace flag |
| `.gitignore` | Modify | Add `.clawdbot/logs/` and `.clawdbot/.tasks.lock` entries |

---

## Specific Changes

### 1. `.clawdbot/spawn-agent.sh`

Base: the version from commit `3120b6c87`. Changes:

- **Add `--workspace` flag** as an optional 6th positional argument or as a flag:
  ```
  Usage: spawn-agent.sh [--workspace] <task-id> <branch> <agent> <prompt-file> [model]
  ```
- Parse `--workspace` flag before positional args. If present, set `TASK_TYPE="workspace"`, otherwise `TASK_TYPE="product"`.
- **Branch naming enforcement**: When `--workspace` is set, validate the branch starts with `workspace/` (e.g., `workspace/update-ci`). When not set, validate it starts with `feat/`, `fix/`, or `refactor/`.
- **Task registry entry**: Add `"type": "$TASK_TYPE"` to the JSON entry written to `active-tasks.json` via the Python block. The entry dict should include `'type': sys.argv[10]` (new arg position).
- No other behavioral changes — workspace tasks use the same worktree, tmux, logging, and agent-execution flow as product tasks.

### 2. `.clawdbot/check-agents.sh`

Base: the version from commit `3120b6c87`. Changes:

- **Read and include `type`** from each task entry in the status output: `result['type'] = task.get('type', 'product')`.
- **Summary section**: Add type counts to the summary: `summary.workspace` and `summary.product` tallying how many tasks of each type.
- **Filter flag** (optional): Accept `--type workspace` or `--type product` env var (`TASK_TYPE_FILTER`) to filter the report. Default: show all.

### 3. `.clawdbot/cleanup-worktrees.sh`

Re-introduce unchanged from commit `3120b6c87`. Cleanup logic is type-agnostic — it operates on task status, not type.

### 4. `.clawdbot/active-tasks.json`

Create as `[]`. Task entries will now have this shape:

```json
{
  "id": "task-id",
  "branch": "workspace/update-ci",
  "agent": "claude",
  "tmuxSession": "agent-task-id",
  "status": "running",
  "type": "workspace",
  "startedAt": "2026-02-28T00:00:00Z",
  "worktree": "/path/to/worktree",
  "logFile": "/path/to/log"
}
```

### 5. `.clawdbot/WORKFLOW.md`

Base: the version from commit `3120b6c87`. Add a new section:

```markdown
## Workspace Tasks

Workspace tasks are self-improvement work: CI/CD, tooling, configs, CLAUDE.md updates,
dependency bumps, test infra, developer experience improvements.

These tasks follow the **same pipeline** as product tasks (plan → implement → audit → PR)
but are flagged with `--workspace` when spawned:

```bash
./spawn-agent.sh --workspace update-ci workspace/update-ci claude /tmp/prompt.md
```

### Differences from product tasks:
- Branch prefix: `workspace/` instead of `feat/` / `fix/` / `refactor/`
- PR title convention: `[Workspace] Brief description`
- Screenshots not required (unless the change affects developer UI)
- Same audit rigor applies — workspace changes can break the pipeline itself
```

Also update the "Worktree Convention" section to include `workspace/<task-id>` in the branch naming list.

### 6. `.clawdbot/prompts/plan.md` (NEW)

New template for the planning phase:

```markdown
# Planning Phase

## Context
Read CLAUDE.md for repo conventions, project structure, and tooling.

## Product Goal
{GOAL}

## Task Description
{TASK}

## PRD
{PRD}

## Deliverables
{DELIVERABLES}

## Instructions

You are a **planning agent**. Your job is to investigate the codebase and produce a detailed implementation plan — you must NOT write any implementation code.

### Step 1: Investigate
- Read CLAUDE.md and understand repo conventions
- Find and read all files relevant to the task
- Understand the current architecture, patterns, and dependencies
- Identify existing tests and how new code should be tested

### Step 2: Produce Implementation Plan

Write your plan to `plan.md` at the root of your worktree.

The plan must include:

#### Files to Modify/Create
List every file that needs changes, with a brief description of what changes are needed.

#### Specific Changes
For each file, describe the concrete changes:
- Functions/components to add or modify
- Imports needed
- Integration points with existing code

#### Testing Strategy
- Which test files to create or modify
- Key test cases to cover
- How to validate the implementation (lint, build, manual checks)

#### Risk Assessment
- What could go wrong
- Edge cases to watch for
- Dependencies or breaking changes

#### Estimated Complexity
Rate as: trivial | small | medium | large | very-large

### Step 3: Verdict

After writing the plan file, output this line at the very end of your response:
`PLAN_VERDICT:READY`

This line must appear on its own line at the very end of your output, after all other content.
```

### 7. Other prompt templates

Re-introduce unchanged from commit `3120b6c87`:
- `prompts/implement.md`
- `prompts/audit.md`
- `prompts/create-pr.md`
- `prompts/fix-feedback.md`
- `prompts/review-plan.md`

### 8. `CLAUDE.md`

Re-introduce from commit `3120b6c87` with one addition. Add to the "Git Conventions" section:

```markdown
- **Workspace branches:** `workspace/<name>` — for self-improvement tasks (CI, tooling, configs)
- **Spawn with flag:** Use `--workspace` flag in spawn-agent.sh for workspace tasks
```

### 9. `.gitignore`

Add these lines (same as commit `3120b6c87`):

```
# Agent swarm logs
.clawdbot/logs/
.clawdbot/.tasks.lock
```

---

## Testing Strategy

### Manual Validation

1. **spawn-agent.sh flag parsing**:
   - Run `./spawn-agent.sh --workspace test-ws workspace/test-ws claude /tmp/test-prompt.md` — should register with `"type": "workspace"` in `active-tasks.json`
   - Run `./spawn-agent.sh test-prod feat/test-prod claude /tmp/test-prompt.md` — should register with `"type": "product"`
   - Run `./spawn-agent.sh --workspace bad-branch feat/wrong-prefix claude /tmp/test-prompt.md` — should fail (branch must start with `workspace/`)
   - Run `./spawn-agent.sh test-prod workspace/wrong-prefix claude /tmp/test-prompt.md` — should fail (non-workspace task can't use `workspace/` prefix)

2. **check-agents.sh type reporting**:
   - Manually populate `active-tasks.json` with entries of both types
   - Run `check-agents.sh` and verify `type` appears in output and summary counts are correct

3. **Shellcheck**:
   - Run `shellcheck .clawdbot/spawn-agent.sh .clawdbot/check-agents.sh .clawdbot/cleanup-worktrees.sh`

4. **Dry-run test script** (optional):
   - Create `.clawdbot/test-spawn.sh` that tests flag parsing without actually creating worktrees/tmux sessions

### What to Validate Before PR

- [ ] `shellcheck` passes on all shell scripts
- [ ] `spawn-agent.sh --workspace` correctly sets type in active-tasks.json
- [ ] `spawn-agent.sh` without flag defaults to type `product`
- [ ] Branch prefix validation works for both modes
- [ ] `check-agents.sh` includes type in output
- [ ] All prompt templates are present and valid markdown
- [ ] `.gitignore` entries are correct
- [ ] CLAUDE.md is accurate

---

## Risk Assessment

### What could go wrong

1. **Flag parsing breaks existing usage**: The `--workspace` flag is parsed before positional args, so existing invocations without the flag continue to work unchanged. Low risk.

2. **Branch prefix enforcement too strict**: If users want `chore/` or `docs/` prefixes for workspace tasks, the validation would reject them. Mitigation: only enforce `workspace/` prefix when `--workspace` is passed; for non-workspace tasks, keep the existing `feat/|fix/|refactor/` validation.

3. **Python arg positions shift**: Adding `TASK_TYPE` as a new argument to the Python block changes positional arg numbering. Must be careful to update all `sys.argv[N]` references.

### Edge cases

- Running `spawn-agent.sh` with `--workspace` but no other args should print usage and exit
- Task entries in `active-tasks.json` from before the `type` field was added should default to `"product"` in `check-agents.sh`
- Lock file handling is unchanged and works the same for both types

### Dependencies / breaking changes

- No external dependencies added
- No breaking changes to existing scripts (flag is optional, defaults to product behavior)
- The `.clawdbot/` directory was previously reverted, so re-introducing it is intentional and expected on this branch

---

## Estimated Complexity

**small** — The core change is adding flag parsing to `spawn-agent.sh`, a `type` field to task entries, and type reporting in `check-agents.sh`. Most files are re-introduced unchanged from commit `3120b6c87`.
