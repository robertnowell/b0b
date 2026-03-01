# Smart Dead-Agent Recovery — Implementation Plan

## Summary

Restore the `.clawdbot/` agent orchestration infrastructure (reverted in `99084ea90`) and upgrade it with intelligent death classification and recovery. Instead of blind retry, dead agents are classified into categories (fast-fail, runtime crash, deps failure, timeout, spawn error) and each category gets a tailored recovery strategy with correct workspace paths.

---

## Files to Create

All files below are restored from git history (commits `2cdd3bb1e` and `fb81388ff`) and then modified with the new smart-recovery logic.

### 1. `.clawdbot/check-agents.sh` — Agent status checker
**Source:** Restore from `2cdd3bb1e` (unchanged from history)
**Changes:** Add fast-fail detection and richer death classification.

### 2. `.clawdbot/monitor.sh` — Pipeline state machine
**Source:** Restore from `fb81388ff` (latest version)
**Changes:** Major rewrite of retry logic to use classified deaths.

### 3. `.clawdbot/spawn-agent.sh` — Agent spawner
**Source:** Restore from `fb81388ff` (latest version)
**Changes:** Add workspace path validation, record start timestamp for fast-fail detection.

### 4. `.clawdbot/cleanup-worktrees.sh` — Worktree cleanup
**Source:** Restore from `2cdd3bb1e` (unchanged)
**Changes:** None needed — already handles plan archival.

### 5. `.clawdbot/notify.sh` — Slack notifications
**Source:** Restore from `3120b6c87` — simple notification helper
**Changes:** None needed (already exists in original, or may need to be created if not in original commit — check-agents calls it).

### 6. `.clawdbot/approve-plan.sh` / `.clawdbot/reject-plan.sh` — Human gates
**Source:** Referenced by monitor.sh but may not exist yet.
**Changes:** Create if missing. Simple scripts that update `active-tasks.json`.

### 7. `.clawdbot/WORKFLOW.md` — Pipeline documentation
**Source:** Restore from `2cdd3bb1e`
**Changes:** Add "Smart Recovery" section documenting death categories and strategies.

### 8. `.clawdbot/prompts/` — All prompt templates
**Source:** Restore from `2cdd3bb1e`: `implement.md`, `audit.md`, `create-pr.md`, `fix-feedback.md`, `review-plan.md`
**Changes:** Add a new `plan.md` prompt template (referenced by monitor.sh but never committed). Add a `deps-fix.md` prompt for deps-specific recovery.

### 9. `.clawdbot/active-tasks.json` — Task registry
**Source:** Restore empty array `[]` from `2cdd3bb1e`
**Changes:** None.

### 10. `CLAUDE.md` — Agent coding context
**Source:** Restore from `2cdd3bb1e`
**Changes:** None — already comprehensive.

### 11. `.gitignore` — Add clawdbot entries
**Changes:** Append `.clawdbot/logs/` and `.clawdbot/.tasks.lock` to existing `.gitignore`.

---

## Specific Changes

### A. Death Classification System (`check-agents.sh`)

Add structured death classification to the status report. Currently `check-agents.sh` detects:
- `deps_install` — dependency failure
- `timeout` — exceeded 45-minute limit
- `agent_error` — generic failure

**Add these classifications:**

```python
# In the log-parsing section, add:

# 1. FAST-FAIL detection: agent died within 60 seconds of start
elapsed_seconds = 0
if started:
    start_dt = datetime.fromisoformat(started.replace('Z', '+00:00'))
    elapsed_seconds = (now - start_dt).total_seconds()

is_fast_fail = (effective == 'failed' and elapsed_seconds < 60)

# 2. Richer log pattern matching for death cause
death_cause = None
if os.path.exists(logfile):
    with open(logfile) as f:
        content = f.read()
    # Check patterns in order of specificity
    if 'AGENT_FAIL:deps_install' in content:
        death_cause = 'deps_install'
    elif 'OOMKilled' in content or 'out of memory' in content.lower():
        death_cause = 'oom'
    elif 'SIGKILL' in content or 'signal 9' in content:
        death_cause = 'killed'
    elif 'SIGTERM' in content or 'signal 15' in content:
        death_cause = 'terminated'
    elif 'ENOSPC' in content:
        death_cause = 'disk_full'
    elif 'rate limit' in content.lower() or 'too many requests' in content.lower():
        death_cause = 'rate_limited'
    elif 'AGENT_EXIT_FAIL:' in content:
        death_cause = 'agent_error'
    elif timed_out:
        death_cause = 'timeout'
    elif not tmux_alive and not agent_done:
        death_cause = 'vanished'  # tmux died without writing exit marker

# 3. Classify into recovery categories
if is_fast_fail:
    death_class = 'fast_fail'
elif death_cause in ('deps_install',):
    death_class = 'deps_failure'
elif death_cause in ('oom', 'killed', 'terminated', 'vanished'):
    death_class = 'runtime_crash'
elif death_cause in ('timeout',):
    death_class = 'timeout'
elif death_cause in ('rate_limited',):
    death_class = 'rate_limited'
elif death_cause in ('disk_full',):
    death_class = 'infra_failure'
else:
    death_class = 'unknown_failure'
```

**New fields added to task JSON and status report:**
- `deathCause`: string — specific cause (e.g., `deps_install`, `oom`, `rate_limited`)
- `deathClass`: string — recovery category (e.g., `fast_fail`, `runtime_crash`, `deps_failure`)
- `elapsedSeconds`: number — how long the agent ran
- `isFastFail`: boolean — died within 60s

### B. Smart Recovery Logic (`monitor.sh`)

Replace the current uniform retry logic with category-specific recovery strategies. The core change is in the `elif status in ('failed', 'unknown')` blocks for each phase.

**Add a `get_recovery_strategy()` function:**

```python
def get_recovery_strategy(task, death_class, death_cause):
    """Returns (action, reason) tuple.

    Actions:
      'retry'        — respawn same agent with same prompt
      'retry_deps'   — respawn with deps-fix prompt
      'retry_gentle' — respawn with reduced scope / different model
      'backoff'      — wait before retrying (set a cooldown timestamp)
      'escalate'     — mark failed, notify human
      'skip'         — mark failed immediately, no retry
    """
    fail_count = task.get('failCount', 0)
    max_retries = task.get('maxRetries', 1)

    if death_class == 'fast_fail':
        # Agent died immediately — likely bad prompt, missing config, or broken setup
        # Don't retry blindly; escalate after 1 attempt
        if fail_count == 0:
            return ('retry', 'Fast-fail on first attempt — retrying once')
        return ('escalate', f'Fast-fail on attempt {fail_count + 1} — likely systemic issue')

    elif death_class == 'deps_failure':
        # Dependency install failed — try with a deps-fix prompt
        if fail_count == 0:
            return ('retry_deps', 'Deps install failed — retrying with pnpm cache clear')
        return ('escalate', 'Deps install failed twice — needs manual intervention')

    elif death_class == 'runtime_crash':
        # OOM, SIGKILL, etc. — might work on retry, but limit attempts
        if fail_count < max_retries:
            return ('retry', f'Runtime crash ({death_cause}) — retrying ({fail_count + 1}/{max_retries})')
        return ('escalate', f'Runtime crash ({death_cause}) after {fail_count + 1} attempts')

    elif death_class == 'timeout':
        # Agent took too long — retry once with hint to work faster
        if fail_count == 0:
            return ('retry_gentle', 'Timed out — retrying with scope reduction hint')
        return ('escalate', 'Timed out twice — task may be too large')

    elif death_class == 'rate_limited':
        # API rate limit — backoff and retry
        if fail_count < 3:
            return ('backoff', f'Rate limited — backing off before retry ({fail_count + 1}/3)')
        return ('escalate', 'Rate limited 3 times — check API quotas')

    elif death_class == 'infra_failure':
        # Disk full, etc. — no point retrying
        return ('skip', f'Infrastructure failure ({death_cause}) — cannot auto-recover')

    else:
        # Unknown — use default retry behavior
        if fail_count < max_retries:
            return ('retry', f'Unknown failure — retrying ({fail_count + 1}/{max_retries})')
        return ('escalate', f'Unknown failure after {fail_count + 1} attempts')
```

**Apply the strategy in each phase handler:**

Replace the current uniform `if task['failCount'] <= max_retries` blocks with:

```python
# Instead of:
task['failCount'] = task.get('failCount', 0) + 1
if task['failCount'] <= max_retries:
    # always retry with same prompt
    ...

# Do:
task['failCount'] = task.get('failCount', 0) + 1
death_class = task.get('deathClass', 'unknown_failure')
death_cause = task.get('deathCause', 'unknown')
action, reason = get_recovery_strategy(task, death_class, death_cause)

if action == 'retry':
    advance_phase(task, current_phase, reset_fail_count=False)
    prompt = build_appropriate_prompt(task, phase)
    queue_spawn(task['id'], task['branch'], task.get('agent', 'claude'), prompt, phase)
    queue_notify(task, f"{reason}: *{task['id']}*", ':warning:')

elif action == 'retry_deps':
    advance_phase(task, current_phase, reset_fail_count=False)
    prompt = build_deps_fix_prompt(task)
    queue_spawn(task['id'], task['branch'], task.get('agent', 'claude'), prompt, phase)
    queue_notify(task, f"{reason}: *{task['id']}*", ':wrench:')

elif action == 'retry_gentle':
    advance_phase(task, current_phase, reset_fail_count=False)
    prompt = build_appropriate_prompt(task, phase,
        hint="IMPORTANT: Focus on the most critical deliverables only. Skip non-essential work.")
    queue_spawn(task['id'], task['branch'], task.get('agent', 'claude'), prompt, phase)
    queue_notify(task, f"{reason}: *{task['id']}*", ':hourglass:')

elif action == 'backoff':
    cooldown_until = (datetime.now(timezone.utc) + timedelta(minutes=10)).strftime(...)
    task['cooldownUntil'] = cooldown_until
    queue_notify(task, f"{reason}: *{task['id']}* (cooldown until {cooldown_until})", ':clock3:')

elif action in ('escalate', 'skip'):
    advance_phase(task, 'failed')
    task['failReason'] = reason
    queue_notify(task, f"{reason}: *{task['id']}*", ':x:')
```

**Add cooldown support at the top of the task loop:**

```python
# Skip tasks in cooldown
cooldown = task.get('cooldownUntil')
if cooldown:
    try:
        cooldown_dt = datetime.fromisoformat(cooldown.replace('Z', '+00:00'))
        if datetime.now(timezone.utc) < cooldown_dt:
            continue  # Still cooling down
        else:
            del task['cooldownUntil']  # Cooldown expired, proceed
    except (ValueError, TypeError):
        del task['cooldownUntil']
```

### C. Workspace Path Fixes (`spawn-agent.sh`)

**Problem:** The current `WORKTREE_DIR` uses a relative path `${REPO_ROOT}/../kopi-worktrees/${TASK_ID}` which can break if `REPO_ROOT` itself is inside `kopi-worktrees/` (which it is when the orchestrator runs from a worktree).

**Fix:**

```bash
# Replace:
WORKTREE_DIR="${REPO_ROOT}/../kopi-worktrees/${TASK_ID}"

# With: Always resolve to the canonical worktree base directory
WORKTREE_BASE="/Users/kopi/Projects/kopi-worktrees"
WORKTREE_DIR="${WORKTREE_BASE}/${TASK_ID}"
```

**Also add validation:**

```bash
# After worktree creation, validate it exists and has expected content
if [ ! -d "$WORKTREE_DIR/.git" ] && [ ! -f "$WORKTREE_DIR/.git" ]; then
  echo "ERROR: Worktree created but .git not found in $WORKTREE_DIR"
  exit 1
fi

# Validate the worktree is on the correct branch
ACTUAL_BRANCH="$(cd "$WORKTREE_DIR" && git rev-parse --abbrev-ref HEAD)"
if [ "$ACTUAL_BRANCH" != "$BRANCH" ]; then
  echo "WARNING: Worktree is on branch '$ACTUAL_BRANCH' instead of '$BRANCH'"
fi
```

**Also fix the `cd "$REPO_ROOT"` issue** — when spawning from a worktree, `git worktree add` needs to run from the main repo, not another worktree:

```bash
# Resolve the main repo root (not a worktree)
MAIN_REPO="$(cd "$REPO_ROOT" && git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||' || echo "$REPO_ROOT")"

# Use MAIN_REPO for git worktree operations
cd "$MAIN_REPO"
git fetch origin main --quiet 2>/dev/null || true
```

### D. New Prompt Template: `plan.md`

Create `.clawdbot/prompts/plan.md` — referenced by `monitor.sh`'s `build_planning_prompt()` but was never committed:

```markdown
# Planning Phase

## Context
Read CLAUDE.md for repo conventions, project structure, and tooling.

## Product Goal
{PRD}

## Task Description
{TASK_ID}

## Instructions
1. Read CLAUDE.md and understand repo conventions
2. Explore the codebase to find all relevant files
3. Write a detailed implementation plan to `.clawdbot/plans/{TASK_ID}.md`
4. The plan MUST include:
   - Files to modify/create
   - Specific changes per file
   - Testing strategy
   - Risk assessment
   - Estimated complexity (trivial/small/medium/large/very-large)
5. Do NOT implement anything — only produce the plan
```

### E. New Prompt Template: `deps-fix.md`

Create `.clawdbot/prompts/deps-fix.md` for the `retry_deps` recovery strategy:

```markdown
# Fix Dependency Installation

## Task
{TASK_DESCRIPTION}

## Problem
The dependency installation step (`pnpm install --frozen-lockfile`) failed in this worktree.

## Instructions
1. Check the pnpm-lock.yaml for inconsistencies
2. Try `pnpm install` (without --frozen-lockfile) to regenerate
3. If that fails, check for:
   - Node version compatibility issues
   - Missing peer dependencies
   - Corrupted cache: try `pnpm store prune`
4. Once deps install succeeds, continue with the original task
5. Commit any lock file changes
```

### F. Updated Spawn Script: Record Runtime Metadata

In `spawn-agent.sh`, record `startTimestamp` (Unix epoch) in the wrapper script so `check-agents.sh` can compute elapsed time precisely:

```bash
# In the wrapper script generation:
printf 'AGENT_START_EPOCH=%q\n' "$(date +%s)"
```

And echo it to the log:
```bash
echo "AGENT_START_EPOCH=${AGENT_START_EPOCH}" >> "$AGENT_LOG_FILE"
```

### G. Documentation Updates (`WORKFLOW.md`)

Add a new section:

```markdown
## Smart Recovery

When an agent dies, the monitor classifies the death and applies a tailored strategy:

| Death Class | Examples | Strategy | Max Retries |
|---|---|---|---|
| `fast_fail` | Bad prompt, missing config | Retry once, then escalate | 1 |
| `deps_failure` | pnpm install fails | Retry with deps-fix prompt | 1 |
| `runtime_crash` | OOM, SIGKILL, tmux vanished | Retry with same prompt | configurable (default 1) |
| `timeout` | Exceeded 45-min limit | Retry with scope hint, then escalate | 1 |
| `rate_limited` | API 429 responses | Backoff 10 min, retry up to 3x | 3 |
| `infra_failure` | Disk full | Fail immediately | 0 |
| `unknown_failure` | Unrecognized error | Default retry behavior | configurable |
```

---

## Testing Strategy

### Manual Testing

Since this is bash/Python infrastructure (not application code with a test framework), validation is manual:

1. **Spawn test:** Run `spawn-agent.sh` with a trivial prompt and verify:
   - Worktree created at correct absolute path
   - tmux session started
   - `active-tasks.json` updated with all new fields
   - Log file created

2. **Fast-fail test:** Spawn an agent with an invalid prompt file and verify:
   - Agent exits within seconds
   - `check-agents.sh` classifies it as `fast_fail`
   - `monitor.sh` retries once, then escalates

3. **Deps failure test:** Corrupt `pnpm-lock.yaml` in a worktree and spawn:
   - Verify `AGENT_FAIL:deps_install` appears in log
   - `check-agents.sh` classifies as `deps_failure`
   - `monitor.sh` respawns with `deps-fix.md` prompt

4. **Timeout test:** Set `MAX_RUNTIME_SECONDS=10` and spawn a long-running agent:
   - Verify timeout detection and classification
   - Verify retry with scope hint

5. **Workspace path test:** Run `spawn-agent.sh` from **inside** an existing worktree:
   - Verify `WORKTREE_DIR` resolves to the correct absolute path
   - Verify `git worktree add` runs against main repo, not the current worktree

6. **Cooldown test:** Simulate a rate-limited death and verify:
   - `cooldownUntil` is set in `active-tasks.json`
   - `monitor.sh` skips the task during cooldown
   - After cooldown expires, retry proceeds

### Validation Checklist

```bash
# Lint the shell scripts
shellcheck .clawdbot/*.sh

# Verify Python syntax
python3 -m py_compile <(python3 -c "..." )  # Extract inline Python and check

# Verify JSON structure
python3 -c "import json; json.load(open('.clawdbot/active-tasks.json'))"

# Dry run monitor with empty task list
.clawdbot/monitor.sh  # Should log "nothing to do"
```

---

## Risk Assessment

### What Could Go Wrong

1. **Race conditions in `active-tasks.json`**: Multiple monitor runs or spawn scripts could collide. **Mitigation:** File locking with `fcntl.LOCK_EX` is already implemented — preserved as-is.

2. **Python version differences**: The inline Python uses f-strings and `datetime.timezone` which require Python 3.6+. macOS ships 3.9+ so this is fine.

3. **Workspace path resolution from worktrees**: If `git rev-parse --git-common-dir` behaves differently across git versions. **Mitigation:** Fall back to `REPO_ROOT` if the command fails.

4. **Log file parsing false positives**: A code comment containing `AGENT_FAIL:deps_install` could trigger false classification. **Mitigation:** Only check the last N lines of the log, and the markers are written by our wrapper script after agent completion.

5. **Cooldown drift**: If the monitor cron runs every 5 minutes and cooldown is 10 minutes, the actual wait could be up to 15 minutes. **Mitigation:** Acceptable — precision isn't critical here.

### Edge Cases

- Agent writes `AGENT_EXIT_SUCCESS` but tmux is dead (normal case — agent finished)
- Agent writes nothing to the log and tmux vanishes (classified as `vanished` → `runtime_crash`)
- `active-tasks.json` is corrupted (existing `try/except json.JSONDecodeError` handles this)
- Worktree already exists from a previous run (existing `git worktree add || ...` fallback handles this)
- Two tasks with the same ID (existing merge logic in `spawn-agent.sh` handles this)

### Dependencies / Breaking Changes

- No application code changes — this is pure infrastructure
- No changes to `assistant/`, `promotions/`, or any other package
- The `.clawdbot/` directory is self-contained
- `CLAUDE.md` at repo root is restored (provides context for all agents)
- `.gitignore` additions are additive-only

---

## Estimated Complexity

**Medium**

The bulk of the code already exists in git history and needs to be restored. The new work is:
- Death classification logic in `check-agents.sh` (~30 lines of Python)
- Recovery strategy function in `monitor.sh` (~60 lines of Python)
- Applying the strategy in each phase handler (~40 lines of Python changes)
- Workspace path fix in `spawn-agent.sh` (~10 lines of bash)
- Two new prompt templates (~20 lines each)
- WORKFLOW.md documentation update (~15 lines)

Total new/modified: ~195 lines across 6 files, on top of ~700 lines restored from history.

---

## Implementation Order

1. Restore all files from git history (bulk restore)
2. Fix workspace paths in `spawn-agent.sh`
3. Add death classification to `check-agents.sh`
4. Add `get_recovery_strategy()` and refactor retry logic in `monitor.sh`
5. Create missing prompt templates (`plan.md`, `deps-fix.md`)
6. Update `WORKFLOW.md` with smart recovery documentation
7. Update `.gitignore`
8. Run `shellcheck` on all `.sh` files
9. Manual testing with dry runs
