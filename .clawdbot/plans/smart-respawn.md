# Smart Dead-Agent Recovery — Implementation Plan

## Problem

The existing monitor.sh retry mechanism treats all agent failures identically — it increments `failCount`, checks against `maxRetries`, and blindly respawns. If an agent died due to a bad spawn config (wrong model flag, invalid prompt path, bad CLI args), the respawn retries the same broken config, wasting all retry attempts in a fail→respawn→fail loop.

## Current State (from `feat/planning-in-monitor` branch)

The agent orchestration infra already exists:

| File | What It Does | Gap |
|------|-------------|-----|
| `spawn-agent.sh` | Creates worktree, runs agent in tmux, registers in `active-tasks.json` | Doesn't store `promptFile`, `model`, or `spawnArgs` in task entry — only runtime-specific fields |
| `check-agents.sh` | Polls tmux, reads log signals, detects timeouts, writes status back | Detects `deps_install` and `timeout` fail reasons but doesn't compute `spawnDuration` or store `lastLogLines` |
| `monitor.sh` | Cron-driven state machine advancing pipeline phases; handles failures with `failCount`/`maxRetries` | No failure classification — all failures treated identically. No fast-fail detection. No config-error detection. Respawn prompt has no continuation context |
| `cleanup-worktrees.sh` | Removes done/failed worktrees | Cleans up failed tasks unconditionally — doesn't check if respawn is still pending |
| `notify.sh` | Slack notifications | No diagnostic context in failure alerts |

## Approach

This plan modifies the EXISTING scripts on `feat/planning-in-monitor` rather than creating from scratch. The branch `feat/smart-respawn` should be rebased onto or merged from `feat/planning-in-monitor` to get the base infrastructure.

---

## Files to Modify/Create

### 1. `.clawdbot/spawn-agent.sh` — Modify

**What changes:** Store spawn metadata in the task entry so monitor.sh can reconstruct spawn commands and classify failures.

**Specific changes to the Python block** (the `entry = {...}` dict around line 80):

Add these fields to the initial `entry` dict:
```python
'promptFile': sys.argv[?],   # new arg: original prompt file path
'model': sys.argv[?],        # new arg: model used
'spawnArgs': [task_id, branch, agent, prompt_file, model, phase],  # full arg list for replay
'respawnCount': 0,
'maxRespawns': 2,
```

**Also in the merge logic** (the `if existing:` block around line 95): Add `'promptFile'` and `'model'` to `spawn_fields` tuple so they get overwritten on respawn. Add special handling for `respawnCount` — DON'T overwrite it from the new entry (preserve the existing count).

**Add `--respawn` flag support** at the top of the script:
```bash
RESPAWN=false
if [ "$1" = "--respawn" ]; then
  RESPAWN=true
  shift
fi
```

When `--respawn` is true:
- Skip worktree creation (reuse existing)
- Skip `pnpm install` if `node_modules` already exists (check in wrapper script)
- Append `=== RESPAWN #N ===` separator to log instead of truncating
- Don't truncate log file (`> "$LOG_FILE"` → conditional)

### 2. `.clawdbot/check-agents.sh` — Modify

**What changes:** Compute `spawnDuration` and store `lastLogLines` when an agent reaches a terminal state, so monitor.sh has the data it needs for failure classification.

**Specific changes** in the Python block, after `effective` status is determined (around the `# Write back status to the task entry` section):

```python
# After setting effective status:
if effective in ('succeeded', 'failed', 'unknown'):
    if started and 'completedAt' not in task:
        task['completedAt'] = now.strftime('%Y-%m-%dT%H:%M:%SZ')
    # Compute spawn duration
    if started:
        try:
            start_dt = datetime.fromisoformat(started.replace('Z', '+00:00'))
            task['spawnDuration'] = round((now - start_dt).total_seconds(), 1)
        except (ValueError, TypeError):
            pass
    # Store last log lines for diagnostics
    task['lastLogLines'] = last_lines[-10:] if last_lines else []
```

Note: `last_lines` is already computed (line `last_lines = [l.strip() for l in lines[-5:]]` — change `-5` to `-20` to capture more context). The `lastAgentCompletedAt` field already being set can stay.

### 3. `.clawdbot/monitor.sh` — Modify

**What changes:** Replace the current "increment failCount, check maxRetries, respawn blindly" pattern with smart failure classification. This is the core change.

**Add a `classify_failure(task)` function** that returns one of: `'respawn'` | `'fail_permanent'` with a reason string.

```python
def classify_failure(task):
    """Decide whether to respawn or permanently fail a dead agent.
    Returns: ('respawn', reason) or ('fail_permanent', reason)
    """
    spawn_duration = task.get('spawnDuration')
    log_lines = task.get('lastLogLines', [])
    fail_reason = task.get('failReason', '')
    respawn_count = task.get('respawnCount', 0)
    max_respawns = task.get('maxRespawns', 2)

    # Gate 1: Max respawns exhausted
    if respawn_count >= max_respawns:
        return ('fail_permanent', 'max_respawns')

    # Gate 2: Fast-fail (died in <30s with no meaningful work)
    FAST_FAIL_THRESHOLD = 30
    if spawn_duration is not None and spawn_duration < FAST_FAIL_THRESHOLD:
        if not has_meaningful_work(task):
            return ('fail_permanent', 'fast_fail')

    # Gate 3: Config error signals in early logs
    CONFIG_ERROR_PATTERNS = [
        'ERROR: Invalid',
        'command not found',
        'No such file or directory',
        'unknown model',
        'unrecognized option',
        'Permission denied',
    ]
    if spawn_duration is not None and spawn_duration < 60:
        for pattern in CONFIG_ERROR_PATTERNS:
            if any(pattern in line for line in log_lines):
                return ('fail_permanent', 'config_error')

    # Gate 4: Deps install — retry once then stop
    if fail_reason == 'deps_install':
        if respawn_count >= 1:
            return ('fail_permanent', 'deps_install_persistent')
        return ('respawn', 'deps_retry')

    # Gate 5: Runtime crash (ran >60s = did real work)
    RUNTIME_THRESHOLD = 60
    if spawn_duration is not None and spawn_duration > RUNTIME_THRESHOLD:
        return ('respawn', 'runtime_crash')

    # Gate 6: Ambiguous (30-60s) — respawn once, then stop
    if respawn_count >= 1:
        return ('fail_permanent', 'ambiguous_repeated')
    return ('respawn', 'ambiguous_first')
```

**Add `has_meaningful_work(task)` helper:**
```python
def has_meaningful_work(task):
    """Check if agent produced any real work (git changes) in the worktree."""
    worktree = task.get('worktree', '')
    if not worktree or not os.path.isdir(worktree):
        return False
    try:
        diff = subprocess.run(
            ['git', 'diff', '--stat', 'origin/main...HEAD'],
            capture_output=True, text=True, cwd=worktree
        )
        if diff.stdout.strip():
            return True
        status = subprocess.run(
            ['git', 'status', '--porcelain'],
            capture_output=True, text=True, cwd=worktree
        )
        return bool(status.stdout.strip())
    except (OSError, FileNotFoundError):
        return False
```

**Modify every phase's failure handling block.** Currently each phase does:
```python
elif status in ('failed', 'unknown'):
    task['failCount'] = task.get('failCount', 0) + 1
    max_retries = task.get('maxRetries', 1)
    if task['failCount'] <= max_retries:
        # respawn
    else:
        # permanent fail
```

Replace with:
```python
elif status in ('failed', 'unknown'):
    decision, reason = classify_failure(task)
    if decision == 'respawn':
        task['respawnCount'] = task.get('respawnCount', 0) + 1
        # build respawn prompt with context (see §4)
        prompt = build_respawn_prompt(task, original_prompt_builder)
        queue_spawn(task['id'], task['branch'], task.get('agent', 'claude'),
                    prompt, phase, task.get('model', ''))
        # pass --respawn flag (modify queue_spawn/deferred spawn to support this)
        queue_notify(task, f"Agent respawning ({reason}): *{task['id']}* "
                     f"(attempt {task['respawnCount']}/{task.get('maxRespawns', 2)})",
                     ':recycle:')
    else:
        task['failReason'] = reason
        advance_phase(task, 'failed')
        queue_notify(task, build_failure_alert(task, reason), ':x:')
```

This applies to phases: `planning`, `implementing`, `auditing`, `creating_pr`.

**Add `build_failure_alert(task, reason)` function** for richer Slack notifications:
```python
def build_failure_alert(task, reason):
    REASON_LABELS = {
        'fast_fail': 'Died within 30s — likely bad config',
        'config_error': 'Config/setup error detected in logs',
        'deps_install_persistent': 'pnpm install failed on retry',
        'max_respawns': 'Max respawn attempts exhausted',
        'ambiguous_repeated': 'Repeated ambiguous failure',
    }
    label = REASON_LABELS.get(reason, reason)
    duration = task.get('spawnDuration', '?')
    respawns = task.get('respawnCount', 0)
    log_preview = '\n'.join(task.get('lastLogLines', [])[-5:])
    parts = [
        f"*Agent Failed: `{task['id']}`*",
        f"Phase: `{task.get('phase', '?')}`",
        f"Reason: {label}",
        f"Duration: {duration}s | Respawns: {respawns}",
    ]
    if log_preview:
        parts.append(f"```{log_preview}```")
    return '\n'.join(parts)
```

**Modify `queue_spawn` and the deferred spawn execution** to support a `--respawn` flag. Add an optional `respawn=False` parameter:
```python
def queue_spawn(task_id, branch, agent, prompt_file, phase, model='', respawn=False):
    deferred_actions.append({
        'kind': 'spawn',
        'task_id': task_id,
        'branch': branch,
        'agent': agent,
        'prompt_file': prompt_file,
        'phase': phase,
        'model': model,
        'respawn': respawn,
    })
```

In the deferred execution loop, prepend `'--respawn'` to args when `action.get('respawn')` is True:
```python
args = [f'{script_dir}/spawn-agent.sh']
if action.get('respawn'):
    args.append('--respawn')
args.extend([action['task_id'], action['branch'], action['agent'],
             action['prompt_file'], action.get('model', ''), action['phase']])
```

### 4. `.clawdbot/prompts/respawn.md` — Create (new file)

Respawn prompt template that gives the new agent continuation context:

```markdown
# Continuation Task (Respawn #{respawnCount})

## Important Context
A previous agent was working on this task but died unexpectedly.
This is respawn attempt #{respawnCount} of {maxRespawns}.

## Original Task
{originalPromptContent}

## What the Previous Agent Accomplished

### Last Log Output
```
{lastLogLines}
```

### Work in the Worktree
{worktreeStatus}

## Instructions
1. **Assess the current state** — check `git status`, `git log`, and any partial files
2. **Continue from where the previous agent left off** — do NOT start over
3. If you find a partial plan file, complete or revise it rather than rewriting from scratch
4. If you find partially implemented code, continue the implementation
5. If the previous agent's approach seems wrong, you may adjust — but explain why
6. Follow all conventions in CLAUDE.md
```

### 5. `.clawdbot/monitor.sh` — Add `build_respawn_prompt(task, phase)` function

This function generates a respawn prompt by filling the template above with real data:

```python
def build_respawn_prompt(task, phase):
    template_path = f'{script_dir}/prompts/respawn.md'
    with open(template_path) as f:
        template = f.read()

    # Read original prompt content
    original = ''
    prompt_file = task.get('promptFile', '')
    if prompt_file and os.path.exists(prompt_file):
        with open(prompt_file) as f:
            original = f.read()
    else:
        original = f'[Original prompt not found: {prompt_file}]'

    # Get last log lines
    log_lines = task.get('lastLogLines', [])
    last_log = '\n'.join(log_lines) if log_lines else '[No log output]'

    # Get worktree git status
    worktree = task.get('worktree', '')
    worktree_status = '[Worktree not found]'
    if worktree and os.path.isdir(worktree):
        diff = subprocess.run(
            ['git', 'diff', '--stat', 'origin/main...HEAD'],
            capture_output=True, text=True, cwd=worktree
        ).stdout.strip()
        status_out = subprocess.run(
            ['git', 'status', '--short'],
            capture_output=True, text=True, cwd=worktree
        ).stdout.strip()
        worktree_status = (
            f'Commits ahead of main:\n{diff or "(none)"}\n\n'
            f'Uncommitted changes:\n{status_out or "(none)"}'
        )

    filled = template.replace('{respawnCount}', str(task.get('respawnCount', '?')))
    filled = filled.replace('{maxRespawns}', str(task.get('maxRespawns', 2)))
    filled = filled.replace('{originalPromptContent}', original)
    filled = filled.replace('{lastLogLines}', last_log)
    filled = filled.replace('{worktreeStatus}', worktree_status)

    out_path = f"/tmp/respawn-{task['id']}-{task.get('respawnCount', 0)}.md"
    with open(out_path, 'w') as f:
        f.write(filled)
    return out_path
```

### 6. `.clawdbot/cleanup-worktrees.sh` — Modify

**What changes:** Don't clean up failed tasks that haven't been evaluated for respawn yet.

In the Python block, change the cleanup condition from:
```python
if task.get('phase') in ('done', 'failed'):
```
to:
```python
if task.get('phase') == 'done':
    # Always clean up done tasks
    ...
elif task.get('phase') == 'failed':
    # Only clean up if respawn evaluation is complete
    respawn_count = task.get('respawnCount', 0)
    max_respawns = task.get('maxRespawns', 2)
    if respawn_count >= max_respawns or task.get('failReason') in (
        'fast_fail', 'config_error', 'deps_install_persistent',
        'ambiguous_repeated', 'max_respawns'
    ):
        # Permanently failed — safe to clean up
        ...
    else:
        # May still be respawned by monitor — keep alive
        active.append(task)
        continue
```

---

## Task Schema Changes (`active-tasks.json`)

New fields added to each task entry:

| Field | Type | Set By | Purpose |
|-------|------|--------|---------|
| `promptFile` | string | spawn-agent.sh | Original prompt file path for respawn context |
| `model` | string | spawn-agent.sh | Model used (for replaying spawn) |
| `spawnArgs` | string[] | spawn-agent.sh | Full arg list for spawn replay |
| `respawnCount` | int | monitor.sh | Times this task has been respawned |
| `maxRespawns` | int | spawn-agent.sh | Per-task respawn cap (default 2) |
| `spawnDuration` | float | check-agents.sh | Seconds from spawn to death |
| `lastLogLines` | string[] | check-agents.sh | Last 10 log lines at time of failure |
| `completedAt` | string | check-agents.sh | ISO timestamp when agent reached terminal state |

Existing fields used but unchanged: `failCount`, `maxRetries` (still used by monitor for phase-level retries within a single spawn), `failReason` (extended with new reason values).

---

## Decision Flow

```
Agent dies (check-agents.sh detects terminal state)
    │
    │  check-agents.sh records: spawnDuration, lastLogLines, completedAt
    │
    ▼
monitor.sh picks up failed task
    │
    ├─ respawnCount >= maxRespawns? ──→ FAIL: max_respawns
    │
    ├─ died in <30s, no git changes? ──→ FAIL: fast_fail
    │
    ├─ config error pattern in logs (within 60s)? ──→ FAIL: config_error
    │
    ├─ deps_install failure?
    │     ├─ first time ──→ RESPAWN
    │     └─ already retried ──→ FAIL: deps_install_persistent
    │
    ├─ ran >60s? ──→ RESPAWN (runtime crash, with continuation context)
    │
    └─ 30-60s, ambiguous
          ├─ first time ──→ RESPAWN
          └─ already retried ──→ FAIL: ambiguous_repeated
```

---

## Testing Strategy

### Manual Testing

Since the agent infra is shell scripts with embedded Python — no unit test framework exists for these. Testing is manual:

1. **Fast-fail detection:** Spawn an agent with a bad model name → verify it's classified as `config_error` and NOT respawned.

2. **Respawn on runtime crash:** Spawn a normal agent, kill the tmux session after 2 minutes → verify monitor detects it, classifies as `runtime_crash`, generates respawn prompt with context, and respawns.

3. **Max respawns cap:** Set `maxRespawns: 1` on a task, kill it twice → verify it fails permanently after the second kill.

4. **Deps install retry:** Create a worktree with broken pnpm lockfile → verify first failure triggers respawn, second triggers `deps_install_persistent`.

5. **Cleanup safety:** Verify `cleanup-worktrees.sh` does NOT remove a failed task that hasn't exhausted respawns.

6. **Respawn prompt content:** After a respawn, read the generated `/tmp/respawn-*.md` file and verify it contains the original prompt, last log lines, and worktree status.

### Validation Commands

```bash
# After implementation, verify scripts are valid:
bash -n .clawdbot/spawn-agent.sh
bash -n .clawdbot/check-agents.sh
bash -n .clawdbot/monitor.sh
bash -n .clawdbot/cleanup-worktrees.sh

# Verify Python blocks parse correctly:
python3 -c "compile(open('.clawdbot/monitor.sh').read(), 'monitor.sh', 'exec')"
# (this won't work directly since Python is embedded — extract and test separately)

# Dry-run monitor with a test active-tasks.json
```

### Smoke Test Script (optional, if time permits)

Create `.clawdbot/test-smart-respawn.sh` that:
1. Creates a test `active-tasks.json` with a task entry in `failed` status with `spawnDuration: 5` (fast fail)
2. Runs monitor.sh
3. Asserts the task is now in `failed` phase with `failReason: fast_fail`
4. Resets with `spawnDuration: 120` (runtime crash)
5. Runs monitor.sh
6. Asserts the task status was updated and spawn was attempted

---

## Risk Assessment

### Risks

1. **Branch merge conflict:** `feat/smart-respawn` is based on `main` but the scripts live on `feat/planning-in-monitor`. Must merge/rebase first. **Mitigation:** First step of implementation is `git merge origin/feat/planning-in-monitor`.

2. **Embedded Python complexity:** All logic lives in Python blocks inside bash scripts. Long Python strings are fragile — a mismatched quote kills the whole script. **Mitigation:** Test with `bash -n` and manual dry runs after every change.

3. **Race between monitor and cleanup:** If cleanup runs between check-agents marking a task failed and monitor evaluating it, the worktree could be deleted. **Mitigation:** The cleanup guard (§6) prevents this.

4. **Respawn prompt file deleted:** `/tmp/` files can be cleaned by the OS. **Mitigation:** `build_respawn_prompt` always generates fresh from stored metadata + worktree state. Original prompt file loss is handled with a fallback message.

5. **`spawnDuration` not set:** If check-agents.sh hasn't run since the agent died, `spawnDuration` will be missing. **Mitigation:** `classify_failure` treats `spawn_duration is None` conservatively — falls through to the ambiguous case rather than fast-failing.

### Edge Cases

- **Prompt file deleted between original spawn and respawn:** Handled — respawn prompt embeds `[Original prompt not found]` and the agent still has worktree context.
- **Worktree removed by cleanup before respawn evaluates:** Handled — cleanup guard prevents this.
- **Monitor crashes mid-run:** Safe — `respawnCount` is incremented atomically with the task file write. A re-run of monitor won't re-process already-respawned tasks because they're back in `running` status.
- **Concurrent monitor instances:** Safe — file locking (already used) prevents races.
- **Agent that writes 0 bytes to log:** `lastLogLines` will be empty, `spawnDuration` will still work for classification.

---

## Estimated Complexity

**Medium** — 4 files modified, 1 file created. Core logic is ~100 lines of Python (classify_failure + build_respawn_prompt). Main risk is working with embedded Python in bash scripts.

---

## Implementation Order

1. Merge `feat/planning-in-monitor` into `feat/smart-respawn`
2. Modify `check-agents.sh` — add `spawnDuration`, `lastLogLines`, `completedAt`
3. Modify `spawn-agent.sh` — store spawn metadata, add `--respawn` flag
4. Create `prompts/respawn.md` — template
5. Modify `monitor.sh` — add `classify_failure`, `build_respawn_prompt`, `build_failure_alert`, update all phase failure handlers
6. Modify `cleanup-worktrees.sh` — add respawn-aware cleanup guard
7. Manual smoke test
