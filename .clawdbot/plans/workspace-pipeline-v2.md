# Implementation Plan: --workspace flag for pipeline (v2 — correct architecture)

## Summary

The `--workspace` flag allows the pipeline to run "self-improvement" tasks (tasks that modify the pipeline/workspace repo itself) alongside regular product tasks. The core flag plumbing is already implemented across all `.clawdbot/scripts/`. What remains is:

1. **Smoke tests** — verify both product and workspace flows work end-to-end
2. **README update** — document `--workspace` usage and workspace architecture
3. **Prompt template gap** — workspace tasks reference `pnpm lint`/`pnpm build` in audit/test/implement prompts, but workspace tasks are bash scripts, not TypeScript packages

---

## Files to Modify/Create

### 1. `.clawdbot/scripts/smoke-test.sh` (CREATE)
Smoke test script that validates both product and workspace task flows through dispatch → spawn → check → cleanup, using mocked agents.

### 2. `.clawdbot/README.md` (MODIFY)
Add documentation for `--workspace` flag: what it does, when to use it, how workspace vs product path resolution works.

### 3. `.clawdbot/prompts/audit.md` (MODIFY)
Add conditional instructions: for workspace tasks (bash scripts in `.clawdbot/`), run `shellcheck` and `bash -n` instead of `pnpm lint`/`pnpm build`.

### 4. `.clawdbot/prompts/test.md` (MODIFY)
Add conditional instructions: for workspace tasks, run `bash -n` syntax checks and the smoke test script instead of `pnpm test`.

### 5. `.clawdbot/prompts/implement.md` (MODIFY)
Add conditional note: workspace tasks should run `shellcheck` instead of `pnpm lint`/`pnpm build`.

---

## Specific Changes

### `.clawdbot/scripts/smoke-test.sh` (CREATE)

A self-contained smoke test that validates pipeline mechanics without spawning real agents:

```
Functions:
- setup_test_env()     — create temp STATE_DIR, mock TASKS_FILE
- mock_agent_wrapper() — write a minimal wrapper that writes AGENT_EXIT_SUCCESS + AGENT_DONE
- test_product_flow()  — dispatch a product task, verify:
    * worktree created at WORKTREE_BASE
    * task registered in active-tasks.json with workspace=false (absent)
    * pnpm install runs (check log for "DEPS INSTALLED")
    * check-agents.sh reports correct status
    * cleanup-worktrees.sh removes the worktree
- test_workspace_flow() — dispatch with --workspace, verify:
    * worktree created at WORKSPACE_WORKTREE_BASE
    * task registered with workspace=true
    * pnpm install skipped (check log for "WORKSPACE TASK — SKIPPING DEPS")
    * check-agents.sh routes PR checks to workspace repo
    * cleanup-worktrees.sh removes workspace worktree
- test_path_resolution() — unit test get_task_paths() returns correct paths
- cleanup()            — remove temp dirs, kill test tmux sessions
```

Imports/dependencies: sources `config.sh`, uses `dispatch.sh`, `check-agents.sh`, `cleanup-worktrees.sh`. Uses a mock prompt file instead of real agent invocations.

The test script will:
1. Override `CLAWDBOT_STATE_DIR` to use a temp directory
2. Create a minimal mock prompt file
3. Replace the actual agent binary paths with a mock that immediately writes success markers
4. Run dispatch → check → cleanup for both product and workspace flows
5. Assert expected state at each step
6. Clean up all artifacts

### `.clawdbot/README.md` (MODIFY)

Add a new section after "Dispatching a Task":

```markdown
## Workspace (Self-Improvement) Tasks

Use `--workspace` for tasks that modify the pipeline itself or the workspace repo
(~/.openclaw/workspace-kopiclaw):

    .clawdbot/scripts/dispatch.sh \
      --task-id improve-monitor \
      --branch feat/improve-monitor \
      --product-goal "Better monitor error handling" \
      --description "Add retry logic to monitor.sh" \
      --agent claude \
      --phase planning \
      --workspace

### How it works

- **Worktrees** are created under `~/.openclaw/kopi-worktrees/` instead of
  `~/Projects/kopi-worktrees/`
- **Git operations** (fetch, branch, PR) target the workspace repo instead of
  the product repo
- **Dependencies**: `pnpm install` is skipped (workspace tasks are bash scripts)
- The `workspace: true` field is stored in `active-tasks.json` and propagated
  through all pipeline phases

### Path Resolution

| Flag | Repo | Worktree Base |
|------|------|---------------|
| (default) | `$REPO_ROOT` (product) | `~/Projects/kopi-worktrees/` |
| `--workspace` | `~/.openclaw/workspace-kopiclaw` | `~/.openclaw/kopi-worktrees/` |
```

### `.clawdbot/prompts/audit.md` (MODIFY)

Add a conditional section after the existing instructions:

```markdown
**If this is a workspace/pipeline task** (changes are to `.clawdbot/` bash scripts):
- Run `shellcheck` on all modified `.sh` files instead of `pnpm lint`
- Run `bash -n <file>` to syntax-check all modified scripts instead of `pnpm build`
- Verify scripts are executable (`chmod +x`)
- Check that `set -euo pipefail` is present at the top of each script
```

### `.clawdbot/prompts/test.md` (MODIFY)

Add a conditional section:

```markdown
**If this is a workspace/pipeline task** (changes are to `.clawdbot/` bash scripts):
- Run `bash -n <file>` on all modified `.sh` files to verify syntax
- Run `shellcheck <file>` on all modified `.sh` files
- If `.clawdbot/scripts/smoke-test.sh` exists, run it
- Check that all scripts source `config.sh` correctly
- Verify `--workspace` flag is accepted by dispatch.sh and spawn-agent.sh
```

### `.clawdbot/prompts/implement.md` (MODIFY)

Add a note after instruction #3:

```markdown
3. Run `pnpm lint` and `pnpm build` in the package(s) you changed
   - **Exception**: For workspace/pipeline tasks (`.clawdbot/` scripts), run `shellcheck` and `bash -n` instead
```

---

## Testing Strategy

### Test file: `.clawdbot/scripts/smoke-test.sh`

Key test cases:
1. **Product task dispatch** — task registered with correct paths, no `workspace` field
2. **Workspace task dispatch** — task registered with `workspace: true`, correct paths
3. **Path resolution** — `get_task_paths true` returns workspace paths, `get_task_paths false` returns product paths
4. **Dep skipping** — workspace agents log "SKIPPING DEPS", product agents log "DEPS INSTALLED"
5. **Cleanup isolation** — cleaning up workspace tasks doesn't affect product worktrees and vice versa
6. **Monitor routing** — workspace tasks use `workspace_repo` for git operations in monitor's `get_task_repo()`

### Validation approach
- Run `bash -n` on all modified scripts (syntax check)
- Run `shellcheck` if available
- Run the smoke test script itself
- Manually verify: dispatch a workspace task, confirm it flows through planning → implementation correctly

---

## Risk Assessment

### What could go wrong
- **Mock agent in smoke tests** — if the mock doesn't accurately simulate the real agent wrapper, tests may pass but real flows could fail. Mitigation: keep the mock minimal, only writing the exact exit markers the pipeline looks for.
- **Path collisions** — smoke tests creating real worktrees could conflict with active pipeline tasks. Mitigation: use a dedicated temp directory and unique task IDs with `smoke-test-` prefix.
- **Prompt template changes** — adding workspace-specific instructions to prompts could confuse agents running product tasks. Mitigation: clearly gate the instructions behind "if this is a workspace task" conditions.

### Edge cases
- Workspace task where `WORKSPACE_REPO` doesn't exist yet (first run)
- Workspace task with a branch that already exists in the workspace repo
- Mixed product + workspace tasks running concurrently (both using same `STATE_DIR`)
- `approve-plan.sh` and `reject-plan.sh` correctly propagating `--workspace` to respawned agents

### Dependencies or breaking changes
- No breaking changes to existing product task flows
- Smoke test requires `tmux` to be available (already a pipeline requirement)
- `shellcheck` is recommended but not required (tests should degrade gracefully if missing)

---

## Estimated Complexity

**small** — The core `--workspace` plumbing is already implemented. The remaining work is tests, docs, and minor prompt tweaks.

PLAN_VERDICT:READY
