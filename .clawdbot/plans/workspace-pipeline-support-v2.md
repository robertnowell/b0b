# Plan: Workspace Pipeline Support v2

## Status: Delta from v1

The v1 plan was implemented across `config.sh`, `spawn-agent.sh`, `dispatch.sh`, `check-agents.sh`, and `monitor.sh`. Core workspace routing works. This v2 plan addresses **three remaining gaps** between the current implementation and the target requirements.

---

## Gap 1: Task Schema — `repo` Field (string) Instead of `workspace` Boolean

### Current behavior
`spawn-agent.sh` sets `"workspace": true` (boolean, only present when true, absent for product tasks). All downstream scripts check `task.get('workspace')`.

### Target behavior
Every task entry has a `"repo"` field: `"product"` (default) or `"workspace"`. This is more explicit and extensible than a boolean.

### Changes

**`spawn-agent.sh`** (Python block, lines 198-218):
- Replace `if workspace: entry['workspace'] = True` with:
  ```python
  entry['repo'] = 'workspace' if workspace else 'product'
  ```
- On respawn (existing task), read `workspace = existing.get('repo') == 'workspace'` instead of `existing.get('workspace', workspace)`.

**`dispatch.sh`** (Python block, lines 163-183):
- Replace `if workspace.lower() == 'true': t['workspace'] = True` with:
  ```python
  t['repo'] = 'workspace' if workspace.lower() == 'true' else 'product'
  ```

**`check-agents.sh`** (Python `get_task_repo` helper, line 33):
- Change from: `return workspace_repo if task.get('workspace') else repo_root`
- Change to: `return workspace_repo if task.get('repo') == 'workspace' else repo_root`

**`monitor.sh`** (Python helpers, lines 68-71):
- `get_task_repo`: `return workspace_repo if task.get('repo') == 'workspace' else repo_root`
- `get_task_worktree_base`: `return workspace_worktree_base if task.get('repo') == 'workspace' else worktree_base`
- `spawn_agent` (line 360): `if task.get('repo') == 'workspace':` instead of `if task.get('workspace'):`

**Backward compatibility**: Existing tasks in `active-tasks.json` may still have `"workspace": true`. Add a one-time migration or dual-read: `task.get('repo') == 'workspace' or task.get('workspace')`. The migration helper should normalize old entries on first read. After one monitor cycle, all entries will be updated.

---

## Gap 2: `WORKSPACE_WORKTREE_BASE` Path

### Current behavior
`config.sh` line 16:
```bash
WORKSPACE_WORKTREE_BASE="/Users/kopi/.openclaw/kopi-worktrees"
```

### Target behavior
```bash
WORKSPACE_WORKTREE_BASE="/Users/kopi/.openclaw/workspace-kopiclaw-worktrees"
```

### Rationale
The current path `/Users/kopi/.openclaw/kopi-worktrees` is ambiguous — it could be confused with product repo worktrees. The new path makes the relationship to the workspace repo explicit.

### Changes

**`config.sh`** (line 16):
- Update the constant:
  ```bash
  WORKSPACE_WORKTREE_BASE="/Users/kopi/.openclaw/workspace-kopiclaw-worktrees"
  ```

**Migration**: Any existing workspace worktrees under the old path will become orphaned. Before changing the path:
1. Run `git -C /Users/kopi/.openclaw/workspace-kopiclaw worktree list` to check for active workspace worktrees.
2. If any exist, either finish/remove them first, or do a one-time `git worktree move` for each.
3. After confirming no active workspace worktrees exist, update the constant.

---

## Gap 3: Slack Alert Differentiation

### Current behavior
`notify.sh` line 85 prefixes ALL notifications with 🔧:
```
🔧 *Task:* ${task_id} | *Phase:* ${phase} | 🕐 ${timestamp}${age_label}
```

No distinction between workspace and product tasks.

### Target behavior
- Workspace tasks: prefix with `🔧` (wrench = infrastructure/tooling)
- Product tasks: prefix with `📱` (or similar product-oriented emoji)

### Changes

**`notify.sh`**:
1. Add `--workspace` flag to the `notify()` function:
   ```bash
   local workspace="false"
   # ... in the case block:
   --workspace) workspace="true"; shift ;;
   ```

2. Choose emoji prefix based on flag:
   ```bash
   local task_prefix="📱"
   if [ "$workspace" = "true" ]; then
     task_prefix="🔧"
   fi
   ```

3. Update the notification template:
   ```
   ${task_prefix} *Task:* ${task_id} | *Phase:* ${phase} | 🕐 ${timestamp}${age_label}
   ```

**Callers that pass `--workspace`**:

`spawn-agent.sh` (line 244): Add workspace flag to notify call:
```bash
NOTIFY_EXTRA_ARGS=()
if [ "$WORKSPACE" = "true" ]; then
  NOTIFY_EXTRA_ARGS+=(--workspace)
fi
notify \
  --task-id "$TASK_ID" \
  --phase "$TASK_PHASE" \
  --message "Agent spawned (${AGENT}). ${TASK_DESCRIPTION:-No description}" \
  --product-goal "${PRODUCT_GOAL:-N/A}" \
  "${NOTIFY_EXTRA_ARGS[@]}"
```

`dispatch.sh` (line 186): Same pattern — add `--workspace` to the notify call if `WORKSPACE=true`.

`monitor.sh` (`run_notify` Python helper): Pass workspace flag. The helper already has access to `task.get('repo')`. Add `--workspace` to the command when `task.get('repo') == 'workspace'`:
```python
def run_notify(task_id, phase, message, product_goal='', next_step='', started_at=''):
    # ... existing code ...
    cmd = [notify, '--task-id', task_id, '--phase', phase, '--message', '-']
    # Add workspace flag
    if task_id in task_map_full:
        t = task_map_full[task_id]
        if t.get('repo') == 'workspace' or t.get('workspace'):
            cmd.append('--workspace')
    # ... rest of existing code ...
```

Where `task_map_full` is built from the full task list (not just check output). This requires threading the task list into `run_notify`, or building a lookup from the `tasks` list at the top of the state machine.

---

## Files to Modify (5 files)

| File | Change | Lines affected |
|---|---|---|
| `config.sh` | Fix `WORKSPACE_WORKTREE_BASE` path | Line 16 |
| `spawn-agent.sh` | `repo` field instead of `workspace` boolean; pass `--workspace` to notify | Lines 195, 217-218, 244-248 |
| `dispatch.sh` | `repo` field in Python block; pass `--workspace` to notify | Lines 174, 186-191 |
| `check-agents.sh` | Read `repo` field instead of `workspace` boolean | Line 33 |
| `monitor.sh` | Read `repo` field in all helpers; pass `--workspace` to notify | Lines 68-71, 360, 74-86 |
| `notify.sh` | Accept `--workspace` flag, conditional emoji prefix | Lines 48-90 |

## Implementation Order

1. **`notify.sh`** — Add `--workspace` flag support (no callers use it yet, so safe)
2. **`config.sh`** — Fix worktree path (after confirming no active workspace worktrees)
3. **`spawn-agent.sh`** — Switch to `repo` field + pass `--workspace` to notify
4. **`dispatch.sh`** — Switch to `repo` field + pass `--workspace` to notify
5. **`check-agents.sh`** — Read `repo` field (with backward-compat fallback)
6. **`monitor.sh`** — Read `repo` field in all helpers + pass `--workspace` to notify

## Backward Compatibility

All scripts that read the `repo` field should also check the legacy `workspace` boolean as a fallback for one transition cycle:
```python
is_workspace = task.get('repo') == 'workspace' or task.get('workspace', False)
```

After one full monitor cycle, all tasks will have the `repo` field set, and the fallback can be removed.

## What Does NOT Change

- **Prompt templates** — same templates work for both task types
- **Phase state machine** — identical for workspace and product tasks
- **`fill-template.sh`** — no changes
- **`approve-plan.sh` / `reject-plan.sh`** — already pass `--workspace` through (v1 handled this)
- **`cleanup-worktrees.sh`** — already uses `get_task_repo()` (v1 handled this)

## Risks

1. **Active workspace worktrees on old path**: Must check before changing `WORKSPACE_WORKTREE_BASE`. Mitigation: check `git worktree list` first.
2. **In-flight tasks with old schema**: The backward-compat fallback (`task.get('workspace')`) handles this. Remove after one cycle.
3. **Notify callers missing `--workspace`**: Only three call sites (spawn, dispatch, monitor). All listed above. Product tasks default to 📱 which is correct.

PLAN_VERDICT:READY
