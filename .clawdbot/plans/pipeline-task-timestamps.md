# Plan: Add Per-Task Age/Started Timestamps to Pipeline Notifications

## Problem

Pipeline notifications in Slack show task-id, phase, goal, and message — but not how long a task has been running. Stale tasks (stuck in `plan_review` for hours, or looping through audit/fix cycles) are invisible until someone manually checks `active-tasks.json`. The goal is to glance at `#alerts-kopi-claw` and immediately see which tasks need attention based on age.

## Current Notification Format

```
🔧 *Task:* {task-id} | *Phase:* {phase}
📦 *Goal:* {product-goal}
⚙️ {message}
➡️ *Next:* {next_step}
```

## Target Notification Format

```
🔧 *Task:* {task-id} | *Phase:* {phase}
📦 *Goal:* {product-goal}
⏱️ *Age:* 2h 15m (started 2026-02-28 19:02 UTC)
⚙️ {message}
➡️ *Next:* {next_step}
```

---

## Files to Modify

### 1. `pipeline/scripts/notify.sh` (MODIFY)

**What changes:** Add an optional `--started-at` flag. When provided, compute human-readable age and include a timestamp line in the notification.

**Specific changes:**

- Add `started_at=""` to the local variable declarations in `notify()` (line 34)
- Add `--started-at` case to the argument parser (after line 43):
  ```bash
  --started-at)   started_at="$2"; shift 2 ;;
  ```
- Add a helper function `_format_age()` that takes an ISO timestamp and returns a human-readable duration using Python:
  - `< 60s` → `"Xs"`
  - `< 1h` → `"Xm"`
  - `< 1d` → `"Xh Ym"`
  - `>= 1d` → `"Xd Yh"`
  - On parse error → `"unknown"`

- In the notification formatting block (lines 56-63), conditionally build and insert an age line between the Goal line and the message line:
  ```
  ⏱️ *Age:* {age} (started {formatted_timestamp})
  ```
  Only included when `--started-at` is provided and non-empty.

- Update the Python JSONL append (lines 70-73) to include `started_at` in the JSON record.

### 2. `pipeline/scripts/monitor.sh` (MODIFY)

**What changes:** Pass each task's `startedAt` to every `run_notify()` call so all monitor notifications include task age.

**Specific changes:**

- Modify the `run_notify()` Python function (lines 60-67) to accept a `started_at` parameter and pass `--started-at` to the notify command:
  ```python
  def run_notify(task_id, phase, message, product_goal='', next_step='', started_at=''):
      cmd = [notify, '--task-id', task_id, '--phase', phase, '--message', message]
      if product_goal:
          cmd += ['--product-goal', product_goal]
      if next_step:
          cmd += ['--next', next_step]
      if started_at:
          cmd += ['--started-at', started_at]
      subprocess.run(cmd, capture_output=True)
  ```

- At the top of the `for task in tasks:` loop (around line 413), extract `started_at`:
  ```python
  started_at = task.get('startedAt', '')
  ```

- At every `run_notify()` call site (~25 calls), add `started_at=started_at` as a keyword argument. The pattern is mechanical — just append the kwarg to each existing call.

### 3. `pipeline/scripts/check-agents.sh` (MODIFY)

**What changes:** Add computed `age` (human-readable) and `elapsedSeconds` fields to each task's JSON output.

**Specific changes:**

- In the per-task processing loop, after the `result` dict is built (~line 76), compute age from `started`:
  ```python
  elapsed_seconds = None
  age_str = ''
  if started:
      try:
          start_dt = datetime.fromisoformat(started.replace('Z', '+00:00'))
          elapsed = (now - start_dt).total_seconds()
          elapsed_seconds = int(elapsed)
          if elapsed < 60:
              age_str = f'{int(elapsed)}s'
          elif elapsed < 3600:
              age_str = f'{int(elapsed // 60)}m'
          elif elapsed < 86400:
              h, m = int(elapsed // 3600), int((elapsed % 3600) // 60)
              age_str = f'{h}h {m}m'
          else:
              d, h = int(elapsed // 86400), int((elapsed % 86400) // 3600)
              age_str = f'{d}d {h}h'
      except (ValueError, TypeError):
          pass
  result['age'] = age_str
  result['elapsedSeconds'] = elapsed_seconds
  ```

  Note: the timeout-check block (lines 112-121) already computes `elapsed` from `started` — the age computation reuses the same parsing logic but stores the result in the output JSON instead of just checking a threshold.

### 4. `pipeline/scripts/spawn-agent.sh` (MODIFY)

**What changes:** Add a `createdAt` field that persists across respawns, so the data model distinguishes "task first created" from "current agent spawned."

**Specific changes:**

- In the Python task-registration block (lines 173-204), preserve `createdAt` from existing task entries on respawn:
  ```python
  created_at = started_at  # default for brand new tasks
  if existing:
      iteration = existing.get('iteration', 0)
      findings = existing.get('findings', [])
      fix_target = existing.get('fixTarget', 'auditing')
      require_plan_review = existing.get('requiresPlanReview', True)
      created_at = existing.get('createdAt', existing.get('startedAt', started_at))
      tasks = [t for t in tasks if t.get('id') != task_id]
  ```
- Add `createdAt` to the entry dict:
  ```python
  entry['createdAt'] = created_at
  ```

This means:
- `createdAt` = when the task was first dispatched (set once, never overwritten)
- `startedAt` = when the current agent was spawned (reset on each respawn)

For notifications, `startedAt` (current agent age) is the primary indicator. `createdAt` is stored for future use (e.g., total pipeline duration reporting).

---

## Testing Strategy

### Manual Testing

1. **notify.sh with `--started-at`:**
   ```bash
   STARTED=$(date -u -v-2H +"%Y-%m-%dT%H:%M:%SZ")
   ./pipeline/scripts/notify.sh \
     --task-id test-timestamps \
     --phase implementing \
     --message "Test notification with age" \
     --started-at "$STARTED"
   ```
   Expected: output includes `⏱️ *Age:* 2h 0m (started ...)`

2. **notify.sh without `--started-at` (backward compat):**
   ```bash
   ./pipeline/scripts/notify.sh --task-id t1 --phase auditing --message "no age"
   ```
   Expected: no age line, no error, identical to current behavior.

3. **Age edge cases via notify.sh:**
   - `< 1 min` → shows seconds
   - `> 1 day` → shows `Xd Yh`
   - Invalid timestamp → shows `unknown`

4. **check-agents.sh output includes age:**
   ```bash
   ./pipeline/scripts/check-agents.sh | python3 -c "import json,sys; d=json.load(sys.stdin); [print(f'{t[\"id\"]}: age={t.get(\"age\")}, elapsed={t.get(\"elapsedSeconds\")}') for t in d['tasks']]"
   ```

5. **createdAt persistence:**
   - Dispatch a task, note `createdAt` in active-tasks.json
   - Trigger a respawn (via timeout or manual)
   - Verify `createdAt` unchanged, `startedAt` updated

### Validation Checklist

- [ ] `shellcheck pipeline/scripts/notify.sh` passes
- [ ] `shellcheck pipeline/scripts/spawn-agent.sh` passes
- [ ] All inline Python blocks parse without syntax errors
- [ ] Existing tests/scripts calling `notify()` without `--started-at` still work
- [ ] JSONL outbox records include `started_at` when provided
- [ ] Slack webhook payload renders correctly with the extra line

---

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| `startedAt` missing or malformed on old tasks | Low | `_format_age()` catches all exceptions, returns `'unknown'`. `--started-at` is optional — missing = no age line. |
| Age computation wrong across timezones | Very Low | All timestamps are UTC (`Z` suffix). `datetime` with `timezone.utc` handles correctly. |
| Breaking existing notify() callers | None | `--started-at` is purely additive. All existing calls work unchanged. |
| Monitor.sh performance from extra arg | Negligible | One extra string per notify call, no additional subprocess. |
| Slack notification parsing by automation | Low | Currently nothing parses notifications programmatically — they're for human consumption. The extra line is between existing lines. |

### Edge Cases

- **Task with no `startedAt`:** `--started-at` not passed → no age line. Graceful degradation.
- **Very old task (days):** Shows `Xd Yh` — readable and clearly stale.
- **Just-spawned task:** Shows `Xs` — clearly fresh.
- **Respawned task:** Shows current agent age via `startedAt`, not total lifetime.

---

## Estimated Complexity

**Small** — 4 files modified with targeted, additive changes. No new files. No architectural changes. No breaking changes. The core work is: (1) a helper function in notify.sh, (2) propagating `--started-at` through monitor.sh's ~25 notify calls, (3) computing age in check-agents.sh output, (4) a 3-line `createdAt` preservation in spawn-agent.sh.

PLAN_VERDICT:READY
