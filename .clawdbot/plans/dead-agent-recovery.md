# Plan: Dead Agent Recovery in Pipeline Monitor

## Problem

When a coding agent dies (tmux killed, `pnpm install` hangs then gets OOM-killed, signal 9, etc.), the task stays in an active phase forever. The monitor reports `status: "unknown"` but never acts on it.

### Root Cause

`monitor.sh` line 410-411 — the `needs_action` guard:

```python
needs_action = (status in ('timeout', 'failed', 'succeeded')
                or report.get('failReason') == 'timeout')
```

Status `"unknown"` is not in this list. Dead agents are silently skipped every monitor cycle.

### Current Dead Agents

| Task ID | Phase | Status | Last Log | Cause |
|---------|-------|--------|----------|-------|
| `add-error-tests` | implementing | unknown | pnpm install done | Agent died after deps installed |
| `planning-in-monitor-v2` | implementing | unknown | deps installed | Same — agent never started coding |

Both died during worktree setup. `planning-in-monitor-v2` is also superseded by `planning-in-monitor`.

---

## Detection Logic

**Already handled by `check-agents.sh`** (lines 124-137):

```python
# When tmux is dead and agent never wrote exit status:
elif not tmux_alive and not agent_done:
    effective = 'unknown'
```

A dead agent is:
- `status == 'unknown'` (from check-agents.sh)
- `phase` is an active phase: `planning`, `implementing`, `auditing`, `fixing`, `testing`, `pr_creating`
- NOT in a terminal/parked phase: `merged`, `needs_split`, `plan_review`, `reviewing`, `failed`

No changes needed to `check-agents.sh` — detection already works.

---

## Changes

### File 1: `pipeline/scripts/monitor.sh` — Add dead agent handler

**New field in task schema: `respawnCount`** (integer, default 0).

This is separate from `iteration` (which counts phase-level iterations for the audit→fix→audit loop). `respawnCount` tracks how many times we've re-spawned a dead agent in the *same* phase due to crashes, not due to work-product failures.

**Add to `needs_action` check** (line 410):

```python
needs_action = (status in ('timeout', 'failed', 'succeeded', 'unknown')
                or report.get('failReason') == 'timeout')
```

**Add new handler block** — insert after the `# --- Handle failures ---` block (after line 484) and before `# --- Handle succeeded ---` (line 487):

```python
# --- Handle dead agents (unknown status = tmux dead, no exit signal) ---
if status == 'unknown':
    # Only act on active phases
    if phase not in ('planning', 'implementing', 'auditing', 'fixing',
                      'testing', 'pr_creating'):
        continue

    respawn_count = task.get('respawnCount', 0)
    max_respawns = 2

    # Check if this task is superseded by a newer version
    superseded_by = get_superseding_task(tid, tasks)
    if superseded_by:
        # Clean up and mark as failed/superseded
        cleanup_dead_agent(task)
        apply_updates(tid, {
            'phase': 'failed',
            'status': 'failed',
            'failReason': f'superseded by {superseded_by}',
        })
        run_notify(tid, 'failed',
            f'Agent dead and superseded by `{superseded_by}`. Marked as failed.',
            product_goal,
            'No action needed — newer task exists')
        changes_made += 1
        continue

    # Check respawn budget
    if respawn_count >= max_respawns:
        cleanup_dead_agent(task)
        new_findings = task.get('findings', []) + [
            f'Agent died {respawn_count + 1} times during {phase} — giving up'
        ]
        apply_updates(tid, {
            'phase': 'failed',
            'status': 'failed',
            'respawnCount': respawn_count + 1,
            'findings': new_findings,
            'failReason': 'max_respawns_exceeded',
        })
        run_notify(tid, 'failed',
            f'Agent died {respawn_count + 1} times during {phase}. Max respawns exceeded. Marked as failed.',
            product_goal,
            'Needs manual investigation')
        changes_made += 1
        continue

    # Validate worktree before respawn
    worktree = task.get('worktree', os.path.join(worktree_base, tid))
    if not os.path.isdir(worktree):
        # Worktree gone — can't respawn without it
        cleanup_dead_agent(task)
        apply_updates(tid, {
            'phase': 'failed',
            'status': 'failed',
            'failReason': 'worktree_missing',
            'findings': task.get('findings', []) + [
                f'Agent died during {phase} and worktree is missing'
            ],
        })
        run_notify(tid, 'failed',
            f'Agent died and worktree is missing. Cannot respawn.',
            product_goal,
            'Needs manual re-dispatch')
        changes_made += 1
        continue

    # Respawn the agent
    cleanup_dead_agent(task)
    respawn_count += 1
    run_notify(tid, phase,
        f'Agent died during {phase}. Respawning (respawn {respawn_count}/{max_respawns})',
        product_goal,
        f'Respawning in {phase} phase')

    # For auditing phase, use the cross-agent logic
    agent_override = task.get('agent')
    if phase == 'auditing':
        agent_override = choose_audit_agent(task.get('agent', 'claude'))

    ok = spawn_agent(task, phase, phase_to_template(phase), agent_override)
    if ok:
        apply_updates(tid, {
            'respawnCount': respawn_count,
        })
    else:
        print(f'ERROR: spawn failed for {tid} during dead-agent respawn')
        run_notify(tid, phase, f'Spawn failed during dead-agent respawn', product_goal)
    changes_made += 1
    continue
```

**Add helper function `cleanup_dead_agent`** (near `auto_revert`):

```python
def cleanup_dead_agent(task):
    """Kill zombie tmux session and remove stale lock/tmp files."""
    tmux = task.get('tmuxSession', f'agent-{task["id"]}')
    subprocess.run(['tmux', 'kill-session', '-t', tmux], capture_output=True)

    # Remove the wrapper script if it exists
    wrapper = f'/tmp/agent-{task["id"]}-run.sh'
    if os.path.exists(wrapper):
        os.remove(wrapper)
```

**Add helper function `get_superseding_task`** (near `cleanup_dead_agent`):

```python
def get_superseding_task(tid, all_tasks):
    """Check if another task supersedes this one.

    Convention: task IDs like 'foo-v2' supersede 'foo' and 'foo-v1'.
    Also checks explicit 'supersededBy' field.
    """
    # Check explicit supersession marker
    for t in all_tasks:
        if t.get('id') == tid:
            superseded_by = t.get('supersededBy')
            if superseded_by:
                return superseded_by

    # Check naming convention: base-vN supersedes base and base-vM (M < N)
    import re
    match = re.match(r'^(.*?)(?:-v(\d+))?$', tid)
    if not match:
        return None
    base = match.group(1)
    version = int(match.group(2)) if match.group(2) else 0

    for t in all_tasks:
        other_id = t.get('id', '')
        if other_id == tid:
            continue
        other_match = re.match(r'^(.*?)(?:-v(\d+))?$', other_id)
        if not other_match:
            continue
        other_base = other_match.group(1)
        other_version = int(other_match.group(2)) if other_match.group(2) else 0

        # Same base, higher version, and not itself dead/failed
        if other_base == base and other_version > version:
            other_phase = t.get('phase', '')
            if other_phase not in ('failed',):
                return other_id

    return None
```

### File 2: `pipeline/scripts/check-agents.sh` — Minor enhancement

No structural changes. One small addition: when `status == 'unknown'`, include the last few log lines in the report for diagnostics.

**Already done** (line 143): `result['lastLog'] = last_lines[-1] if last_lines else None`

Add `lastLogLines` for richer context in the dead-agent handler:

```python
result['lastLogLines'] = last_lines  # full last 5 lines, not just the last one
```

This is optional — the current `lastLog` field is sufficient for basic diagnostics.

### File 3: `pipeline/active-tasks.json` — Schema addition (documentation)

New fields per task:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `respawnCount` | int | 0 | Times agent was respawned due to crashes (not iteration failures) |
| `supersededBy` | string\|null | null | Task ID that supersedes this one (set manually or by convention) |

### File 4: No changes to `spawn-agent.sh` or `dispatch.sh`

`spawn-agent.sh` already handles the respawn case correctly (lines 173-184): it preserves `iteration`, `findings`, `fixTarget` when re-registering an existing task ID. The new `respawnCount` field will be preserved through `apply_updates()` in monitor.sh after spawn completes.

---

## Superseded Task Detection

### Convention-based (automatic)

Task ID naming convention: `{base}-v{N}` supersedes `{base}` and `{base}-v{M}` where `M < N`.

Example from current state:
- `planning-in-monitor-v2` (dead, implementing) → check for `planning-in-monitor-v3`, `planning-in-monitor-v4`, etc.
- `planning-in-monitor` (alive, plan_review) → base = `planning-in-monitor`, version = 0

Wait — this is backwards. `planning-in-monitor-v2` has version 2, `planning-in-monitor` has version 0. The v2 task is *newer* but it's the one that's dead. The v0 (`planning-in-monitor`) is the one that succeeded.

**Revised logic**: A dead task is superseded if another task with the same base exists AND that other task is in a non-failed, more-advanced phase. We don't just compare version numbers — we check if the other task is actually alive and progressing.

```python
def get_superseding_task(tid, all_tasks):
    """Check if another active task makes this dead task redundant."""
    import re

    # 1. Explicit supersededBy field
    for t in all_tasks:
        if t.get('id') == tid:
            if t.get('supersededBy'):
                return t['supersededBy']

    # 2. Convention: same base name, other task is alive and not failed
    match = re.match(r'^(.*?)(?:-v(\d+))?$', tid)
    if not match:
        return None
    base = match.group(1)

    terminal_phases = {'failed', 'needs_split'}
    for t in all_tasks:
        other_id = t.get('id', '')
        if other_id == tid:
            continue
        other_match = re.match(r'^(.*?)(?:-v(\d+))?$', other_id)
        if not other_match:
            continue
        other_base = other_match.group(1)

        # Same base, other task is still alive (not failed/needs_split)
        if other_base == base and t.get('phase', '') not in terminal_phases:
            return other_id

    return None
```

This correctly identifies `planning-in-monitor-v2` as superseded by `planning-in-monitor` (same base `planning-in-monitor`, the latter is in `plan_review` which is alive).

### Explicit (manual)

Set `"supersededBy": "other-task-id"` in `active-tasks.json` directly. The detection function checks this first.

---

## Slack Notification Format

Current format (from `notify.sh`):
```
🔧 *Task:* {task_id} | *Phase:* {phase}
📦 *Goal:* {product_goal}
⚙️ {message}
➡️ *Next:* {next_step}
```

New messages use this same format with these specific `message` and `next_step` values:

| Scenario | Phase arg | Message | Next step |
|----------|-----------|---------|-----------|
| Respawned | current phase | `Agent died during {phase}. Respawning (respawn {n}/{max})` | `Respawning in {phase} phase` |
| Max respawns | `failed` | `Agent died {n} times during {phase}. Max respawns exceeded. Marked as failed.` | `Needs manual investigation` |
| Superseded | `failed` | `Agent dead and superseded by \`{other_id}\`. Marked as failed.` | `No action needed — newer task exists` |
| Worktree missing | `failed` | `Agent died and worktree is missing. Cannot respawn.` | `Needs manual re-dispatch` |
| Spawn failed | current phase | `Spawn failed during dead-agent respawn` | (inferred by notify.sh) |

---

## Edge Cases and Failure Modes

### 1. Race condition: agent finishes between check-agents and monitor

`check-agents.sh` runs first, reports `unknown`. Between then and monitor acting, the agent's tmux session comes back (e.g., it was just slow).

**Mitigation**: `spawn-agent.sh` kills existing tmux session before creating a new one (line 95: `tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true`). Worst case: we kill a session that just recovered and respawn. The agent's work is preserved in the worktree — `spawn-agent.sh` reuses existing worktrees.

### 2. Worktree has uncommitted agent work

Agent wrote code but died before committing. Respawning runs `pnpm install` in the same worktree, preserving the uncommitted changes. The new agent session picks up where the old one left off (the prompt template tells it what to do, and it can see existing changes).

**No special handling needed** — this is actually the desired behavior.

### 3. Agent dies during `pnpm install` repeatedly

Both current dead agents died at this stage. If `pnpm install` hangs consistently (e.g., registry down, lockfile conflict), respawning will hit the same issue.

**Mitigation**: The `max_respawns = 2` limit prevents infinite loops. After 2 respawns (3 total attempts), the task is marked `failed` and needs manual investigation. The `findings` array will contain the crash context.

### 4. Monitor runs while respawn is in progress

The `lastMonitorAction` race guard (line 377-381) prevents acting on the same task within 60 seconds:
```python
if now - last_action < 60 and phase != 'reviewing':
    continue
```
Since we set `lastMonitorAction` for `unknown` status (via the expanded `needs_action` check), consecutive monitor runs won't double-respawn.

### 5. Superseded detection false positive

Two tasks with similar names but different scope (e.g., `auth-v2` for "auth system v2" and `auth` for "auth bug fix") could be falsely matched.

**Mitigation**: The convention-based match requires the *exact same base* after stripping `-v{N}`. `auth-v2` has base `auth`, and `auth` also has base `auth` — this IS a match. If the names are genuinely unrelated, users should use different base names (e.g., `auth-system-v2` vs `fix-auth-bug`). The `supersededBy` explicit field is always available as an override.

### 6. All agents die at once (system issue)

If the machine reboots or tmux server crashes, ALL agents become dead simultaneously. The monitor will try to respawn all of them in a single run.

**Mitigation**: Each respawn is independent and spawn-agent.sh creates separate tmux sessions. The main risk is resource exhaustion (too many concurrent agents). This is an existing problem with the pipeline — not introduced by this change. A future `maxConcurrentAgents` config could gate spawning.

### 7. `completedAt` already set on dead tasks

`check-agents.sh` line 176-177 sets `completedAt` when status is `unknown`. After respawn, `spawn-agent.sh` creates a new task entry with a new `startedAt`, which is correct. But the stale `completedAt` from the dead run persists if not cleared.

**Fix**: Add `'completedAt': None` (or use `del`) in `apply_updates` after successful respawn. Alternatively, `spawn-agent.sh` already replaces the entire task entry on respawn (line 184: it removes the old entry and appends a new one), so `completedAt` won't carry over.

**No additional fix needed** — `spawn-agent.sh` handles this.

---

## Implementation Order

1. Add `cleanup_dead_agent()` and `get_superseding_task()` helper functions to `monitor.sh`
2. Expand `needs_action` to include `'unknown'`
3. Add the dead agent handler block (between failure and success handlers)
4. Test with the two existing dead agents:
   - `planning-in-monitor-v2`: should be detected as superseded by `planning-in-monitor` → marked `failed`
   - `add-error-tests`: no superseding task → should respawn (respawn 1/2)
5. Verify Slack notifications fire correctly
6. Optionally add `lastLogLines` to `check-agents.sh` report for richer diagnostics

---

## What This Does NOT Cover

- **Proactive health checks**: The monitor only runs every 2 minutes via cron. A stuck `pnpm install` that hangs for 44 minutes will burn the full timeout before being killed by the timeout handler, not by dead-agent recovery. Dead-agent recovery only catches agents that *fully died* (tmux gone).
- **Worktree cleanup**: Dead agent worktrees are left intact for respawn. A separate `cleanup-worktrees.sh` handles cleanup for `failed`/`merged` tasks.
- **Max concurrent agents**: No gating on how many agents can be respawned simultaneously.
- **Root cause analysis**: The plan respawns agents but doesn't diagnose *why* they died. The `lastLog` field helps, but automated diagnosis (e.g., "OOM detected in dmesg") is out of scope.

PLAN_VERDICT:READY
