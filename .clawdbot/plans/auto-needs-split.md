# Plan: Auto-retry / Auto-split for `needs_split` Tasks

## Summary

When a task hits `MAX_ITERATIONS` and enters `needs_split`, the monitor currently stops (terminal state). This plan adds automatic decision-making: **retry once** if failures look transient, or **auto-split** if the task is structurally too complex. Safeguards prevent infinite loops.

---

## Files to Modify/Create

| File | Action | Description |
|------|--------|-------------|
| `.clawdbot/scripts/monitor.sh` | **Modify** | Remove `needs_split` from terminal-phase skip list; add retry-vs-split decision logic |
| `.clawdbot/scripts/auto-split.sh` | **Create** | Script that spawns a split-planning agent, parses subtasks, dispatches them |
| `.clawdbot/prompts/split.md` | **Create** | Prompt template for the split-planning agent |
| `.clawdbot/scripts/config.sh` | **Modify** | Add `MAX_AUTO_RETRIES` and `MAX_SPLIT_DEPTH` config vars |
| `.clawdbot/scripts/test_auto_needs_split.py` | **Create** | Unit tests for the retry-vs-split decision logic |

---

## Specific Changes

### 1. `.clawdbot/scripts/config.sh`

Add two new config variables after the existing `MAX_ITERATIONS`:

```bash
MAX_AUTO_RETRIES="${MAX_AUTO_RETRIES:-1}"   # Max times a task can auto-retry from needs_split
MAX_SPLIT_DEPTH="${MAX_SPLIT_DEPTH:-1}"     # Max depth of auto-split (no splitting splits of splits)
```

### 2. `.clawdbot/scripts/monitor.sh` — State Machine Changes

#### 2a. Remove `needs_split` from terminal skip list

Change line ~451:
```python
# Before:
if phase in ('merged', 'needs_split', 'plan_review'):
    continue

# After:
if phase in ('merged', 'plan_review'):
    continue
```

#### 2b. Pass new config vars to the Python block

Add `max_auto_retries` and `max_split_depth` as new `sys.argv` parameters to the Python block (lines ~43-55), reading from the shell vars set in config.sh.

#### 2c. Add `needs_split` handler in the state machine (new block, before the `needs_action` check)

Insert a new handler block for `needs_split` phase after the `pr_ready` handler and before the `needs_action` guard. The logic:

```python
if phase == 'needs_split':
    auto_retry_count = task.get('autoRetryCount', 0)
    split_depth = task.get('splitDepth', 0)

    # Decide: retry or split
    should_retry = can_auto_retry(task, auto_retry_count, max_auto_retries)
    should_split = not should_retry and can_auto_split(task, split_depth, max_split_depth)

    if should_retry:
        # Reset iteration, bump autoRetryCount, respawn in planning phase
        ...
    elif should_split:
        # Spawn the split agent via auto-split.sh
        ...
    else:
        # Truly terminal — needs human intervention
        pass  # (already in needs_split, do nothing)
    continue
```

#### 2d. Define decision helper functions

Add two helper functions inside the Python block:

**`can_auto_retry(task, auto_retry_count, max_auto_retries)`**
Returns `True` if:
- `auto_retry_count < max_auto_retries` (default: hasn't been retried yet)
- `splitDepth == 0` (not a subtask from a split — those shouldn't auto-retry, they should fail up)

Logic: The first time a task hits `needs_split`, we give it one more shot by resetting it to the `planning` phase with a fresh iteration counter but preserving findings as context.

**`can_auto_split(task, split_depth, max_split_depth)`**
Returns `True` if:
- `split_depth < max_split_depth` (hasn't been split already, or is depth 0)
- Task has a `description` and `productGoal` (needed for the split agent)

#### 2e. Retry logic implementation

When retrying:
1. Reset `iteration` to 0
2. Increment `autoRetryCount`
3. Preserve `findings` as context for the retry
4. Set phase back to `planning`
5. Spawn a planning agent with the accumulated findings
6. Send Slack notification: "Auto-retrying (attempt {n})"

```python
if should_retry:
    new_retry_count = auto_retry_count + 1
    run_notify(tid, 'planning',
        f'Auto-retrying from needs_split (retry {new_retry_count}/{max_auto_retries}). Previous findings preserved.',
        product_goal,
        f'Re-planning with context from {len(task.get("findings", []))} previous findings')
    task['iteration'] = 0
    task['autoRetryCount'] = new_retry_count
    task['findings'] = task.get('findings', []) + [f'Auto-retry #{new_retry_count} triggered']
    ok = spawn_agent(task, 'planning', 'plan.md', task.get('agent'))
    if ok:
        apply_updates(tid, {
            'phase': 'planning',
            'status': 'running',
            'iteration': 0,
            'autoRetryCount': new_retry_count,
            'findings': task['findings'],
        })
    else:
        print(f'ERROR: spawn failed for {tid} during auto-retry')
        run_notify(tid, 'needs_split', f'Auto-retry spawn failed', product_goal)
    changes_made += 1
```

#### 2f. Split logic implementation

When splitting:
1. Call `auto-split.sh` as a subprocess (non-interactive, synchronous)
2. Parse the JSON output (list of subtasks)
3. For each subtask, call `dispatch.sh` with `splitDepth + 1`
4. Mark the parent task as `split` (new terminal state) with `subtasks` field
5. Send Slack notification with subtask IDs

```python
elif should_split:
    auto_split_script = os.path.join(script_dir, 'auto-split.sh')
    split_result = subprocess.run(
        [auto_split_script,
         '--task-id', tid,
         '--description', description,
         '--product-goal', product_goal,
         '--findings', json.dumps(task.get('findings', [])),
         '--agent', task.get('agent', 'claude')],
        capture_output=True, text=True, cwd=get_task_repo(task),
        env=_clean_env)

    if split_result.returncode == 0 and split_result.stdout.strip():
        try:
            subtasks = json.loads(split_result.stdout)
            subtask_ids = []
            dispatch_script = os.path.join(script_dir, 'dispatch.sh')
            for st in subtasks:
                st_id = f"{tid}-{st['suffix']}"
                st_branch = f"{task.get('branch', tid)}-{st['suffix']}"
                dispatch_cmd = [
                    dispatch_script,
                    '--task-id', st_id,
                    '--branch', st_branch,
                    '--product-goal', product_goal,
                    '--description', st['description'],
                    '--agent', task.get('agent', 'claude'),
                    '--phase', 'planning',
                    '--require-plan-review', 'false',
                ]
                if task.get('workspace'):
                    dispatch_cmd.append('--workspace')
                d_result = subprocess.run(dispatch_cmd, capture_output=True, text=True,
                                          cwd=get_task_repo(task), env=_clean_env)
                if d_result.returncode == 0:
                    subtask_ids.append(st_id)
                    # Set splitDepth on the subtask
                    apply_updates(st_id, {'splitDepth': split_depth + 1, 'parentTask': tid})
                else:
                    print(f'WARNING: Failed to dispatch subtask {st_id}: {d_result.stderr}')

            if subtask_ids:
                apply_updates(tid, {
                    'phase': 'split',
                    'status': 'split',
                    'subtasks': subtask_ids,
                })
                run_notify(tid, 'split',
                    f'Auto-split into {len(subtask_ids)} subtasks: {", ".join(subtask_ids)}',
                    product_goal,
                    'Subtasks are now running')
            else:
                print(f'WARNING: No subtasks dispatched for {tid}')
                run_notify(tid, 'needs_split', f'Auto-split failed: no subtasks created', product_goal)
        except (json.JSONDecodeError, KeyError) as e:
            print(f'WARNING: Failed to parse split output for {tid}: {e}')
            run_notify(tid, 'needs_split', f'Auto-split failed: bad output', product_goal)
    else:
        print(f'WARNING: auto-split.sh failed for {tid}: {split_result.stderr}')
        run_notify(tid, 'needs_split', f'Auto-split failed', product_goal)
    changes_made += 1
```

#### 2g. Add `split` to terminal phases and cleanup

Add `'split'` to the terminal phase skip list:
```python
if phase in ('merged', 'plan_review', 'split'):
    continue
```

And update `cleanup-worktrees.sh` to also clean up `split` tasks (line 33):
```python
if task.get('status') in ('merged', 'needs_split', 'abandoned', 'split'):
```

### 3. `.clawdbot/scripts/auto-split.sh` (New File)

A script that:
1. Accepts `--task-id`, `--description`, `--product-goal`, `--findings`, `--agent`
2. Fills the `split.md` prompt template with the task context and findings
3. Runs the agent non-interactively (like `review-plan.sh` does) with a timeout
4. Parses the agent's output for a JSON array of subtasks
5. Outputs the subtask array to stdout

Each subtask in the output array has:
```json
{
  "suffix": "part1",
  "description": "Specific scoped description of this subtask"
}
```

The script uses the same pattern as `review-plan.sh`: run agent synchronously with `timeout`, parse structured output.

### 4. `.clawdbot/prompts/split.md` (New File)

```markdown
# Task Split Planning

## Original Task
{TASK_DESCRIPTION}

## Product Goal
{PRODUCT_GOAL}

## Previous Findings (why this task failed)
{FINDINGS}

## Instructions

This task exceeded its iteration budget and could not be completed as a single unit.
Your job is to analyze WHY it failed and split it into 2-4 smaller, independently
completable subtasks.

### Rules
1. Each subtask must be self-contained and independently testable
2. Subtasks should not depend on each other (can run in parallel)
3. Each subtask must be simpler than the original task
4. Aim for 2-3 subtasks (4 only if truly necessary)
5. Each subtask description must be specific and actionable

### Output Format

Output a JSON array with this exact structure at the end of your response:

```json
SPLIT_RESULT:[
  {"suffix": "part1", "description": "Specific description of subtask 1"},
  {"suffix": "part2", "description": "Specific description of subtask 2"}
]
```

The `SPLIT_RESULT:` prefix must appear on its own line, followed immediately by the JSON array.
The `suffix` will be appended to the parent task ID (e.g., `my-task-part1`).
Use short, descriptive suffixes like `ui`, `api`, `tests`, `refactor`, etc.
```

### 5. `.clawdbot/scripts/auto-split.sh` — Detailed Implementation

```bash
#!/usr/bin/env bash
# auto-split.sh — Analyze a failed task and produce subtask definitions
# Usage: ./auto-split.sh --task-id <id> --description <desc> --product-goal <goal> --findings <json> --agent <agent>
# Outputs JSON array of subtasks to stdout.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILL_TEMPLATE="${SCRIPT_DIR}/fill-template.sh"

# Parse args
TASK_ID="" DESCRIPTION="" PRODUCT_GOAL="" FINDINGS="[]" AGENT="claude"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)       TASK_ID="$2"; shift 2 ;;
    --description)   DESCRIPTION="$2"; shift 2 ;;
    --product-goal)  PRODUCT_GOAL="$2"; shift 2 ;;
    --findings)      FINDINGS="$2"; shift 2 ;;
    --agent)         AGENT="$2"; shift 2 ;;
    *) echo "ERROR: Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Validate
[[ -n "$TASK_ID" ]]     || { echo "ERROR: --task-id required" >&2; exit 1; }
[[ -n "$DESCRIPTION" ]] || { echo "ERROR: --description required" >&2; exit 1; }

# Format findings for the prompt
FINDINGS_TEXT=$(python3 -c "
import json, sys
findings = json.loads(sys.argv[1])
for i, f in enumerate(findings):
    print(f'- Iteration {i+1}: {f}')
" "$FINDINGS" 2>/dev/null || echo "- No findings available")

# Fill template
TEMPLATE="${PROMPTS_DIR}/split.md"
FILLED_PROMPT="$(mktemp /tmp/split-${TASK_ID}-XXXXXX.md)"
trap 'rm -f "$FILLED_PROMPT"' EXIT

"$FILL_TEMPLATE" "$TEMPLATE" \
  --var TASK_DESCRIPTION="$DESCRIPTION" \
  --var PRODUCT_GOAL="$PRODUCT_GOAL" \
  --var FINDINGS="$FINDINGS_TEXT" \
  --var TASK_ID="$TASK_ID" \
  > "$FILLED_PROMPT"

# Run agent synchronously with timeout (same pattern as review-plan.sh)
SPLIT_TIMEOUT="${MAX_RUNTIME_SECONDS:-2700}"
AGENT_OUTPUT=""

if [ "$AGENT" = "claude" ]; then
  AGENT_OUTPUT=$(timeout "$SPLIT_TIMEOUT" \
    "$CLAUDE_PATH" --model claude-opus-4-6 --dangerously-skip-permissions -p - \
    < "$FILLED_PROMPT" 2>/dev/null) || {
    echo "[]" ; exit 0
  }
elif [ "$AGENT" = "codex" ]; then
  AGENT_OUTPUT=$(timeout "$SPLIT_TIMEOUT" \
    "$CODEX_PATH" exec --dangerously-bypass-approvals-and-sandbox \
    < "$FILLED_PROMPT" 2>/dev/null) || {
    echo "[]" ; exit 0
  }
fi

# Parse SPLIT_RESULT from agent output
python3 -c "
import json, re, sys

output = sys.argv[1]

# Look for SPLIT_RESULT: followed by JSON array
match = re.search(r'SPLIT_RESULT:\s*(\[.*?\])', output, re.DOTALL)
if not match:
    # Fallback: look for any JSON array with suffix/description keys
    match = re.search(r'\[\s*\{[^}]*\"suffix\"[^]]*\]', output, re.DOTALL)

if match:
    try:
        result = json.loads(match.group(1) if 'SPLIT_RESULT' in (match.group(0) if hasattr(match, 'group') else '') else match.group(0))
        # Validate structure
        validated = []
        for item in result:
            if isinstance(item, dict) and 'suffix' in item and 'description' in item:
                # Sanitize suffix for use in task IDs
                suffix = re.sub(r'[^a-zA-Z0-9-]', '', item['suffix'])[:20]
                if suffix:
                    validated.append({'suffix': suffix, 'description': item['description'][:500]})
        if 2 <= len(validated) <= 4:
            print(json.dumps(validated))
        else:
            print('[]')
    except (json.JSONDecodeError, TypeError):
        print('[]')
else:
    print('[]')
" "$AGENT_OUTPUT"
```

### 6. `.clawdbot/scripts/test_auto_needs_split.py` (New File)

Tests covering the retry-vs-split decision logic:

```python
#!/usr/bin/env python3
"""Tests for auto needs_split handling in monitor.sh.

Covers:
  - needs_split → auto-retry (first time, transient failures)
  - needs_split → auto-split (after retry exhausted)
  - needs_split stays terminal (both retry and split exhausted)
  - needs_split stays terminal for deep-split tasks (splitDepth >= max)
  - Split subtask dispatch with correct splitDepth propagation
  - Infinite loop prevention (autoRetryCount, splitDepth bounds)
"""
```

Key test cases:
1. **`test_first_needs_split_triggers_retry`**: Task with `autoRetryCount=0`, `splitDepth=0` → should retry
2. **`test_already_retried_triggers_split`**: Task with `autoRetryCount=1` → should split
3. **`test_deep_split_stays_terminal`**: Task with `splitDepth=1` → stays needs_split (no retry, no split)
4. **`test_subtask_no_retry`**: Task with `splitDepth=1`, `autoRetryCount=0` → stays terminal (subtasks don't auto-retry)
5. **`test_retry_resets_iteration`**: After retry, `iteration=0` and phase is `planning`
6. **`test_retry_preserves_findings`**: Findings from previous attempts are preserved
7. **`test_split_creates_subtask_ids`**: Subtask IDs follow `{parent}-{suffix}` convention
8. **`test_split_sets_parent_task_phase`**: Parent transitions to `split` phase
9. **`test_max_auto_retries_configurable`**: Respects `MAX_AUTO_RETRIES` setting

The tests follow the same pattern as `test_monitor_pr_ready.py`: extract the decision logic into testable helper functions, simulate the state machine fragments.

---

## Integration Points

1. **`cleanup-worktrees.sh`**: Add `'split'` to the cleanup status list (line 33)
2. **`notify.sh`**: Add `_infer_next_step` case for `'split'` phase: `"Subtasks dispatched"`
3. **`check-agents.sh`**: No changes needed — split tasks won't have tmux sessions
4. **`dispatch.sh`**: No changes needed — subtasks are dispatched as normal tasks
5. **Monitor race guard**: `needs_split` should bypass the 60s race guard (like `pr_ready` and `reviewing`) since the retry/split decision should happen promptly

---

## Testing Strategy

### Unit Tests (`test_auto_needs_split.py`)
- Test `can_auto_retry()` with various `autoRetryCount`/`splitDepth` combinations
- Test `can_auto_split()` with various `splitDepth`/`max_split_depth` combinations
- Test the full decision flow: `needs_split` → retry → needs_split → split → terminal
- Test subtask ID generation and sanitization
- Test `SPLIT_RESULT` JSON parsing (valid, malformed, missing)

### Manual Validation
1. Run existing tests: `python3 .clawdbot/scripts/test_monitor_pr_ready.py`
2. Run new tests: `python3 .clawdbot/scripts/test_auto_needs_split.py`
3. `shellcheck .clawdbot/scripts/auto-split.sh`
4. Dry-run: Create a fake `needs_split` task in `active-tasks.json` and run `monitor.sh` — verify it triggers retry logic
5. Verify `split.md` template fills correctly via `fill-template.sh`

---

## Risk Assessment

### What Could Go Wrong
1. **Infinite loop**: Task retries → needs_split → retries → needs_split...
   - **Mitigation**: `autoRetryCount` hard cap (default 1), `splitDepth` hard cap (default 1). After both exhausted, task stays terminal.
2. **Split agent produces bad subtasks**: Vague descriptions, too many/few tasks
   - **Mitigation**: Validate 2-4 subtasks with non-empty suffix/description. Fall back to terminal `needs_split` if parsing fails.
3. **Subtask dispatch failure**: `dispatch.sh` fails for some subtasks
   - **Mitigation**: Dispatch each independently, report partial success. Parent only moves to `split` if at least one subtask dispatched.
4. **Race condition**: Monitor runs twice during split agent execution
   - **Mitigation**: `lastMonitorAction` timestamp guard already prevents this. Also add `needs_split` to the race-guard bypass list so the decision happens promptly on the first qualifying cycle.
5. **Agent timeout during split analysis**: Split agent takes too long
   - **Mitigation**: Uses same `MAX_RUNTIME_SECONDS` timeout as other agents. On timeout, outputs `[]` and task stays in `needs_split`.

### Edge Cases
- Task with no description/productGoal: Skip auto-split, stay terminal
- Task already in `split` phase when monitor runs: Skip (terminal)
- Subtask suffix collision: Handled by `dispatch.sh` worktree creation (will use existing branch)
- Parent task was `--workspace`: Subtasks inherit workspace flag

---

## Estimated Complexity

**Medium** — Core logic is a new decision point in the existing state machine (~100 lines of Python in monitor.sh), plus a new shell script following established patterns (auto-split.sh), a prompt template, and tests. No architectural changes needed.

PLAN_VERDICT:READY
