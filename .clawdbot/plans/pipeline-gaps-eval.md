# Plan: Staleness Alerts + Smart Respawn in monitor.sh

## Problem Statement

The pipeline monitor currently handles agent failures and timeouts but lacks two capabilities:

1. **Staleness alerts**: Tasks that have been running for a long time (but haven't timed out yet) generate no warnings. Operators get no visibility into "stuck" tasks until the hard timeout kills them.

2. **Smart respawn (failure classification)**: When an agent dies unexpectedly (`status == 'unknown'`), the monitor blindly respawns it in the same phase. It doesn't classify *why* the agent died (OOM, crash, hang, bad prompt, infrastructure issue) to decide whether respawning will help or if the task needs a different approach.

## Files to Modify/Create

### 1. `.clawdbot/scripts/monitor.sh` — Primary changes
Add staleness detection and smart respawn classification to the main state machine.

### 2. `.clawdbot/scripts/config.sh` — New config constants
Add staleness threshold configuration.

### 3. `.clawdbot/scripts/notify.sh` — No changes needed
The existing `notify` function already supports all the parameters we need (`--task-id`, `--phase`, `--message`, `--product-goal`, `--next`, `--started-at`). No modifications required.

## Specific Changes

### A. `config.sh` — Add staleness threshold

Add after the `MAX_ITERATIONS` line:

```bash
# Staleness: warn when an agent has been running longer than this (seconds).
# Default: 20 minutes (2/3 of the 45-min timeout). This gives operators ~25 min
# to investigate before the hard timeout kills the agent.
STALE_THRESHOLD_SECONDS="${STALE_THRESHOLD_SECONDS:-1200}"
```

Also document the new env var in the README table (see section below).

### B. `monitor.sh` — Staleness alerts for running tasks

**Where**: After the main `for task in tasks:` loop processes succeeded/failed/unknown tasks, add a second pass (or integrate into the existing loop) that handles `status == 'running'` tasks.

**What**: For each task where `status == 'running'`:
1. Parse `startedAt` from the task's check-agents report.
2. Compute elapsed time: `now - startedAt`.
3. If elapsed > `STALE_THRESHOLD_SECONDS` and we haven't already sent a staleness alert for this run:
   - Send a Slack notification via `run_notify()` with a warning message: `"Agent has been running for {elapsed_minutes}m in {phase} phase (threshold: {threshold_minutes}m). May be stuck."`
   - Set a `staleAlertSent` flag on the task (persisted via `apply_updates`) to avoid spamming alerts every 5 minutes.
4. The `staleAlertSent` flag gets cleared whenever `spawn_agent()` is called (i.e., on any respawn/phase transition), since a fresh agent resets the clock.

**Integration point**: Pass `STALE_THRESHOLD_SECONDS` as an additional `sys.argv` to the Python block. The staleness check should happen *before* the `needs_action` guard (which only fires on terminal statuses), since stale tasks are still `running`.

**Specific code location**: Inside the `for task in tasks:` loop, after the `if phase in ('merged', 'needs_split', 'plan_review'): continue` check and after the race guard, add a new block before `needs_action`:

```python
# --- Handle staleness alerts for running tasks ---
if status == 'running':
    started_at_str = report.get('startedAt', '')
    if started_at_str and not task.get('staleAlertSent', False):
        try:
            from datetime import datetime, timezone
            start_dt = datetime.fromisoformat(started_at_str.replace('Z', '+00:00'))
            elapsed = (datetime.now(timezone.utc) - start_dt).total_seconds()
            if elapsed > stale_threshold:
                elapsed_min = int(elapsed / 60)
                threshold_min = int(stale_threshold / 60)
                run_notify(tid, phase,
                    f'⚠️ Agent has been running for {elapsed_min}m in {phase} phase '
                    f'(stale threshold: {threshold_min}m). May be stuck.',
                    product_goal,
                    f'Will auto-timeout at {int(max_runtime / 60)}m')
                apply_updates(tid, {'staleAlertSent': True})
                changes_made += 1
        except (ValueError, TypeError):
            pass
    continue  # Running tasks don't need further processing
```

**Also**: Clear the `staleAlertSent` flag in `spawn_agent()` by adding `'staleAlertSent': False` to the `apply_updates` call after a successful spawn in each transition. Specifically, add it inside the existing `apply_updates` dict in every `if ok:` block.

### C. `monitor.sh` — Smart respawn (failure classification for dead agents)

**Where**: In the `status == 'unknown'` block, after `agent_actually_succeeded` is determined to be `False` (the "genuinely dead" path, around line 623).

**What**: Before respawning, classify the failure to decide whether respawning is likely to help:

1. **Read the last N lines of the agent's log file** to classify the failure:
   - `oom` — log contains "out of memory", "OOM", "killed", "signal 9"
   - `rate_limit` — log contains "rate limit", "429", "too many requests"
   - `bad_prompt` — log contains "token limit", "context length exceeded", "prompt too long"
   - `infra` — log contains "connection refused", "ECONNRESET", "network error", "DNS"
   - `crash` — log contains "segfault", "core dumped", "SIGSEGV", "SIGABRT"
   - `unknown` — no pattern matched

2. **Decision matrix** based on classification:
   - `oom` → Respawn is unlikely to help. Mark as `failed` with `failReason: 'oom'`. Notify operator.
   - `rate_limit` → Transient. Respawn after a brief note. (No actual delay needed since monitor runs every 5 min.)
   - `bad_prompt` → Respawn won't help (same prompt). Mark as `failed` with `failReason: 'bad_prompt'`. Notify.
   - `infra` → Transient. Respawn normally.
   - `crash` → Respawn once. If it's the second crash, mark as `failed`.
   - `unknown` → Use existing respawn logic (respawn up to `max_respawns` times).

3. **Implementation**: Add a `classify_failure(task)` function in the Python block that reads the log tail and returns a `(category, detail)` tuple. Then replace the current blind respawn logic with classification-aware branching.

```python
def classify_failure(task):
    """Classify why an agent died by scanning its log tail.

    Returns (category, detail) where category is one of:
        oom, rate_limit, bad_prompt, infra, crash, unknown
    """
    log_file = task.get('logFile', '')
    if not log_file or not os.path.exists(log_file):
        return 'unknown', 'No log file'

    with open(log_file) as f:
        # Read last 100 lines for classification
        lines = f.readlines()
        tail = ''.join(lines[-100:]).lower()

    patterns = [
        ('oom', ['out of memory', 'oom', 'killed', 'signal 9', 'cannot allocate']),
        ('rate_limit', ['rate limit', '429', 'too many requests', 'quota exceeded']),
        ('bad_prompt', ['token limit', 'context length exceeded', 'prompt too long',
                        'maximum context length', 'too many tokens']),
        ('infra', ['connection refused', 'econnreset', 'network error',
                   'dns resolution', 'enotfound', 'etimedout']),
        ('crash', ['segfault', 'core dumped', 'sigsegv', 'sigabrt', 'bus error']),
    ]

    for category, keywords in patterns:
        for kw in keywords:
            if kw in tail:
                # Extract the matching line for context
                for line in reversed(lines[-100:]):
                    if kw in line.lower():
                        return category, line.strip()[:200]
                return category, kw

    return 'unknown', 'No recognizable failure pattern'
```

Then in the dead-agent handler, replace the current respawn block with:

```python
# Classify the failure before deciding what to do
failure_cat, failure_detail = classify_failure(task)

# Non-retriable failures: don't waste respawn budget
if failure_cat in ('oom', 'bad_prompt'):
    cleanup_dead_agent(task)
    apply_updates(tid, {
        'phase': 'failed',
        'status': 'failed',
        'failReason': failure_cat,
        'failDetail': failure_detail,
        'findings': task.get('findings', []) + [
            f'Agent died during {phase}: {failure_cat} — {failure_detail}'
        ],
    })
    run_notify(tid, 'failed',
        f'Agent died ({failure_cat}): {failure_detail}. Not retriable — needs investigation.',
        product_goal,
        'Needs manual investigation')
    changes_made += 1
    continue

# Retriable failures: respawn (but still count against budget)
# For crash, use tighter budget (max 1 respawn instead of default 2)
effective_max_respawns = 1 if failure_cat == 'crash' else max_respawns

if respawn_count >= effective_max_respawns:
    cleanup_dead_agent(task)
    # ... existing max-respawn-exceeded logic ...
else:
    cleanup_dead_agent(task)
    respawn_count += 1
    run_notify(tid, phase,
        f'Agent died ({failure_cat}): {failure_detail}. '
        f'Respawning (attempt {respawn_count}/{effective_max_respawns})',
        product_goal,
        f'Respawning in {phase} phase')
    # ... existing respawn logic ...
```

### D. `.clawdbot/README.md` — Document new env vars

Add to the Environment Variables table:

| `STALE_THRESHOLD_SECONDS` | Warn when agent runs longer than this | `1200` (20 min) |

## Testing Strategy

### Manual Testing

Since this is shell/Python infrastructure code with no test framework, testing is manual:

1. **Staleness alert test**:
   - Dispatch a task and let it run
   - Set `STALE_THRESHOLD_SECONDS=60` (1 minute) for testing
   - Run `monitor.sh` and verify:
     - Slack notification is sent with staleness warning
     - `staleAlertSent` is set to `true` in `active-tasks.json`
     - Running `monitor.sh` again does NOT send a duplicate alert
     - When the task transitions to a new phase, `staleAlertSent` is cleared

2. **Smart respawn test**:
   - Create a fake task entry in `active-tasks.json` with `status: 'unknown'`
   - Write different failure patterns to the log file (OOM keywords, rate limit keywords, etc.)
   - Run `monitor.sh` and verify:
     - OOM/bad_prompt → task marked as `failed`, no respawn
     - rate_limit/infra → task respawned
     - crash → respawn once, then fail on second crash
     - unknown → existing behavior (respawn up to 2 times)

3. **Integration test**:
   - Run a full pipeline dispatch with `STALE_THRESHOLD_SECONDS=60`
   - Verify staleness alerts fire during a long planning phase
   - Kill the agent's tmux session to simulate a crash
   - Verify classify_failure detects it and respawns appropriately

### Validation Commands

```bash
# Lint the bash scripts
shellcheck .clawdbot/scripts/monitor.sh .clawdbot/scripts/config.sh

# Verify Python syntax within the embedded block
python3 -c "import ast; ast.parse(open('.clawdbot/scripts/monitor.sh').read())"
# (This won't work directly since it's embedded bash — manual syntax review instead)

# Dry run: set a short stale threshold and run monitor
STALE_THRESHOLD_SECONDS=60 .clawdbot/scripts/monitor.sh
```

## Risk Assessment

### What Could Go Wrong

1. **Alert spam**: If `staleAlertSent` flag isn't properly persisted or cleared, operators could get flooded. **Mitigation**: The flag is persisted via `apply_updates()` which uses file locking, and cleared on spawn.

2. **False classification**: Log patterns could match innocuous text (e.g., a code comment mentioning "out of memory"). **Mitigation**: We scan only the last 100 lines (tail of log), which is mostly agent output, not source code. The `lower()` comparison is intentional to catch variations.

3. **Race condition on staleAlertSent**: Two monitor runs could both see `staleAlertSent: False` and both send alerts. **Mitigation**: The existing 60-second race guard (`lastMonitorAction`) already prevents this for non-running tasks. For running tasks, the staleness check happens inside the same guard window — but since we set the flag via `apply_updates` (which uses flock), the second run will see the updated flag.

4. **Missing log file**: If the log file doesn't exist or is empty, `classify_failure` returns `'unknown'` which falls through to the existing respawn logic. No regression.

### Edge Cases

- Task with no `startedAt` field → staleness check safely skipped (try/except)
- Task that becomes stale, gets respawned, then becomes stale again → `staleAlertSent` cleared on respawn, so a new alert fires correctly
- Agent that outputs OOM-like text in its normal output (false positive) → Acceptable risk; operators can investigate and re-dispatch
- `STALE_THRESHOLD_SECONDS` set to 0 → every running task triggers an alert immediately; not harmful, just noisy. Could add a minimum but not worth the complexity.

### Dependencies / Breaking Changes

- **No breaking changes**: All additions are additive. Existing task JSON fields are untouched.
- **New task fields**: `staleAlertSent` (boolean), `failDetail` (string) — both optional, defaulting to `False`/empty.
- **New env var**: `STALE_THRESHOLD_SECONDS` — optional, defaults to 1200.
- **Backward compatible**: Old tasks without the new fields work fine (all new code uses `.get()` with defaults).

## Estimated Complexity

**small** — The changes are confined to two files (monitor.sh, config.sh) plus a README update. The logic is straightforward pattern matching and threshold comparison. No new scripts, no architectural changes, no external dependencies.

PLAN_VERDICT:READY
