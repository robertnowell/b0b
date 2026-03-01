# Plan: Add Planning Phase to monitor.sh State Machine

## Prerequisite: Restore `.clawdbot/` Infrastructure

The `.clawdbot/` infra was added in `3120b6c87` then reverted in `99084ea90`. The current branch has **no `.clawdbot/` scripts** — only an empty `plans/` directory. Before any new work, the base infra must be restored.

**Action:** Cherry-pick or re-apply commit `3120b6c87` to restore these files:
- `.clawdbot/check-agents.sh` — agent liveness checker (reads logs for `AGENT_EXIT_SUCCESS` / `AGENT_EXIT_FAIL:*`, writes `status` back to `active-tasks.json`)
- `.clawdbot/spawn-agent.sh` — creates worktree, spawns agent in tmux, registers task (5 args: `task-id`, `branch`, `agent`, `prompt-file`, `[model]`)
- `.clawdbot/cleanup-worktrees.sh` — removes worktrees for completed/failed tasks
- `.clawdbot/WORKFLOW.md` — pipeline phases documentation
- `.clawdbot/active-tasks.json` — empty array `[]`
- `.clawdbot/prompts/` — `audit.md`, `create-pr.md`, `fix-feedback.md`, `implement.md`, `review-plan.md`
- `CLAUDE.md` — repo conventions
- `.gitignore` additions — `.clawdbot/logs/`, `.clawdbot/.tasks.lock`

---

## Files to Create

### 1. `.clawdbot/monitor.sh` (CREATE — primary deliverable)

The cron-driven state machine. Bash wrapper that calls `check-agents.sh` first, then runs a Python block for phase transitions.

**Structure:**
```
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 1. Refresh agent statuses
"$SCRIPT_DIR/check-agents.sh" > /dev/null

# 2. Python state machine
python3 -c "..." "$REPO_ROOT" "$SCRIPT_DIR"
```

**Python state machine logic — planning phase only (MVP scope):**

```python
import json, subprocess, sys, fcntl, os, glob as globmod
from datetime import datetime, timezone

repo_root = sys.argv[1]
script_dir = sys.argv[2]
tasks_file = f"{repo_root}/.clawdbot/active-tasks.json"
lock_file = f"{repo_root}/.clawdbot/.tasks.lock"

def notify(task_id, message, emoji=":robot_face:"):
    subprocess.run([f"{script_dir}/notify.sh", task_id, message, emoji], capture_output=True)

def advance_phase(task, new_phase):
    now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    task['phase'] = new_phase
    task.setdefault('phaseHistory', []).append({'phase': new_phase, 'enteredAt': now})
    task['failCount'] = 0

def find_plan_file(task):
    worktree = task.get('worktree', '')
    candidates = [
        os.path.join(worktree, '.clawdbot', 'plans', f"{task['id']}.md"),
        os.path.join(worktree, 'plan.md'),
        os.path.join(worktree, 'PLAN.md'),
    ]
    for path in candidates:
        if os.path.exists(path):
            return path
    plans_dir = os.path.join(worktree, '.clawdbot', 'plans')
    if os.path.isdir(plans_dir):
        mds = globmod.glob(os.path.join(plans_dir, '*.md'))
        if len(mds) == 1:
            return mds[0]
    return None

# Main
lock_fd = open(lock_file, 'w')
fcntl.flock(lock_fd, fcntl.LOCK_EX)
try:
    with open(tasks_file) as f:
        tasks = json.load(f)

    for task in tasks:
        phase = task.get('phase', 'implementing')  # backward compat
        status = task.get('status')

        if phase in ('done', 'failed') or status == 'running':
            continue

        if phase == 'planning':
            if status == 'succeeded':
                plan_path = find_plan_file(task)
                if plan_path:
                    # Archive plan to main repo
                    archive_dir = f"{repo_root}/.clawdbot/plans"
                    os.makedirs(archive_dir, exist_ok=True)
                    archive_path = os.path.join(archive_dir, f"{task['id']}.md")
                    if plan_path != archive_path:
                        import shutil
                        shutil.copy2(plan_path, archive_path)
                    task['planFile'] = archive_path
                    advance_phase(task, 'plan_review')
                    notify(task['id'],
                        f":memo: Plan ready for review: *{task['id']}*\\n"
                        f"Plan: `{archive_path}`\\n"
                        f"Approve: `.clawdbot/dispatch.sh approve-plan {task['id']}`",
                        ":memo:")
                else:
                    task['failCount'] = task.get('failCount', 0) + 1
                    max_retries = task.get('maxRetries', 1)
                    if task['failCount'] <= max_retries:
                        notify(task['id'],
                            f":warning: Planning succeeded but no plan file found. Retrying ({task['failCount']}/{max_retries}): *{task['id']}*",
                            ":warning:")
                        task['status'] = 'pending_respawn'
                        task['respawnHint'] = 'no_plan_file'
                    else:
                        advance_phase(task, 'failed')
                        notify(task['id'],
                            f":x: Planning failed (no plan file after retries): *{task['id']}*",
                            ":x:")

            elif status in ('failed', 'unknown'):
                task['failCount'] = task.get('failCount', 0) + 1
                max_retries = task.get('maxRetries', 1)
                if task['failCount'] <= max_retries:
                    notify(task['id'],
                        f":warning: Planning agent failed. Retrying ({task['failCount']}/{max_retries}): *{task['id']}*",
                        ":warning:")
                    task['status'] = 'pending_respawn'
                else:
                    advance_phase(task, 'failed')
                    notify(task['id'],
                        f":x: Planning failed after {task['failCount']} attempts: *{task['id']}*",
                        ":x:")

        elif phase == 'plan_review':
            pass  # Human gate — no automatic transition

        elif phase == 'implementing':
            if status == 'succeeded':
                advance_phase(task, 'creating_pr')
                notify(task['id'], f":white_check_mark: Implementation complete: *{task['id']}*", ":white_check_mark:")
            elif status in ('failed', 'unknown'):
                task['failCount'] = task.get('failCount', 0) + 1
                max_retries = task.get('maxRetries', 1)
                if task['failCount'] <= max_retries:
                    task['status'] = 'pending_respawn'
                    notify(task['id'], f":warning: Implementation failed. Retrying: *{task['id']}*", ":warning:")
                else:
                    advance_phase(task, 'failed')
                    notify(task['id'], f":x: Implementation failed: *{task['id']}*", ":x:")

        elif phase == 'creating_pr':
            if status == 'succeeded':
                advance_phase(task, 'pr_review')
                notify(task['id'], f":pull_request: PR created: *{task['id']}*", ":pull_request:")
            elif status in ('failed', 'unknown'):
                advance_phase(task, 'failed')
                notify(task['id'], f":x: PR creation failed: *{task['id']}*", ":x:")

        elif phase == 'pr_review':
            pass  # Human gate / CI gate

    with open(tasks_file, 'w') as f:
        json.dump(tasks, f, indent=2)
        f.write('\n')
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
```

**Key design decisions:**
- `monitor.sh` does NOT spawn agents itself. It sets `status: 'pending_respawn'` and a separate dispatch mechanism handles spawning. This avoids monitor.sh needing to know prompt-building details and keeps it idempotent.
- Plan files are archived from the worktree into the main repo's `.clawdbot/plans/` so they survive worktree cleanup.
- The `find_plan_file()` search order: `{worktree}/.clawdbot/plans/{task-id}.md` → `{worktree}/plan.md` → `{worktree}/PLAN.md` → single `.md` in `{worktree}/.clawdbot/plans/`.

### 2. `.clawdbot/notify.sh` (CREATE)

Slack webhook notification script.

```bash
#!/usr/bin/env bash
set -euo pipefail
TASK_ID="${1:?Missing task ID}"
MESSAGE="${2:?Missing message}"
EMOJI="${3:-:robot_face:}"

WEBHOOK_URL="${CLAWDBOT_SLACK_WEBHOOK:-}"
if [ -z "$WEBHOOK_URL" ]; then
  echo "[notify] No CLAWDBOT_SLACK_WEBHOOK set, skipping" >&2
  exit 0
fi

PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
    'text': f'{sys.argv[1]} [{sys.argv[2]}] {sys.argv[3]}',
    'blocks': [{'type': 'section', 'text': {'type': 'mrkdwn', 'text': f'{sys.argv[1]} *{sys.argv[2]}*\n{sys.argv[3]}'}}]
}))
" "$EMOJI" "$TASK_ID" "$MESSAGE")

curl -sf -X POST -H 'Content-type: application/json' --data "$PAYLOAD" "$WEBHOOK_URL" > /dev/null
```

**Env var:** `CLAWDBOT_SLACK_WEBHOOK` — Slack incoming webhook URL. If unset, notifications are silently skipped (log message only).

### 3. `.clawdbot/prompts/plan.md` (CREATE)

Planning agent prompt template. This is what gets fed to the planning agent via `spawn-agent.sh`.

```markdown
# Planning Phase

## Context
Read CLAUDE.md for repo conventions, project structure, and tooling.

## Product Goal
{PRD}

## Task Description
{DELIVERABLES}

## Instructions
Create a detailed implementation plan. Include:
1. Files to modify/create with specific changes
2. Implementation steps (numbered, actionable)
3. Testing strategy
4. Risks and edge cases
5. Uncertainty score (1-5)

**IMPORTANT:** Write your plan to `.clawdbot/plans/{TASK_ID}.md` in the worktree.
Do NOT just output the plan — it must be saved as a file.

When complete, output this exact line at the end:
`PLAN_VERDICT:READY`
```

---

## Files to Modify

### 4. `.clawdbot/spawn-agent.sh` (MODIFY)

Add optional 6th positional arg for `phase` (default: `implementing`).

**Change 1:** Add after the `MODEL` parameter line:
```bash
PHASE="${6:-implementing}"
```

Add validation:
```bash
[[ "$PHASE" =~ ^[a-z_]+$ ]] || { echo "ERROR: Invalid phase"; exit 1; }
```

**Change 2:** In the Python task-registration block, add these fields to `entry`:
```python
entry['phase'] = sys.argv[10]       # new arg
entry['phaseHistory'] = [{'phase': sys.argv[10], 'enteredAt': entry['startedAt']}]
entry['failCount'] = 0
entry['maxRetries'] = 1
```

Update the `sys.argv` index mapping and the final `python3 -c "..." ...` invocation to pass `$PHASE` as an additional positional argument.

### 5. `.clawdbot/cleanup-worktrees.sh` (MODIFY — minor)

Before removing a worktree, archive the plan file if it exists:

```python
# Add before the worktree removal block:
plan_src = os.path.join(worktree, '.clawdbot', 'plans')
plan_dst = os.path.join(repo_root, '.clawdbot', 'plans')
if os.path.isdir(plan_src):
    os.makedirs(plan_dst, exist_ok=True)
    for md in os.listdir(plan_src):
        if md.endswith('.md'):
            import shutil
            shutil.copy2(os.path.join(plan_src, md), os.path.join(plan_dst, md))
```

### 6. `.clawdbot/active-tasks.json` (SCHEMA CHANGE — documentation only)

No file modification needed (it's already `[]`). But the schema now includes:

| Field | Type | Description |
|-------|------|-------------|
| `phase` | string | `planning` \| `plan_review` \| `implementing` \| `creating_pr` \| `pr_review` \| `done` \| `failed` |
| `phaseHistory` | array | `[{phase, enteredAt}]` — audit trail |
| `planFile` | string\|null | Archived plan file path (main repo) |
| `prd` | string\|null | Path to the PRD that spawned the task |
| `failCount` | int | Consecutive failures in current phase |
| `maxRetries` | int | Max retries before `failed` (default 1) |

---

## Phase Transition Diagram (planning focus)

```
planning ──(agent succeeds + plan file found)──→ plan_review
planning ──(agent succeeds + no plan file, retries left)──→ pending_respawn
planning ──(agent succeeds + no plan file, no retries)──→ failed
planning ──(agent fails, retries left)──→ pending_respawn
planning ──(agent fails, no retries)──→ failed

plan_review ──(human approves via dispatch.sh)──→ implementing
plan_review ──(human rejects via dispatch.sh)──→ planning (respawn with feedback)
```

Each transition sends a Slack notification via `notify.sh`.

---

## Testing Strategy

### Unit-style tests (bash + Python)

Create `.clawdbot/tests/test-monitor.sh`:

1. **Test planning success with plan file:**
   - Seed `active-tasks.json` with a task in `phase: planning, status: succeeded`
   - Create a mock plan file at the expected path
   - Run `monitor.sh`
   - Assert: task phase is now `plan_review`, `planFile` is set, plan archived to main repo

2. **Test planning success without plan file (retry):**
   - Seed task with `phase: planning, status: succeeded, failCount: 0`
   - Don't create a plan file
   - Run `monitor.sh`
   - Assert: `failCount` incremented, `status` is `pending_respawn`

3. **Test planning failure (exhaust retries):**
   - Seed task with `phase: planning, status: failed, failCount: 1, maxRetries: 1`
   - Run `monitor.sh`
   - Assert: phase is `failed`

4. **Test idempotency:**
   - Seed task with `phase: plan_review`
   - Run `monitor.sh` twice
   - Assert: no change, no duplicate notifications

5. **Test backward compatibility:**
   - Seed task with no `phase` field
   - Run `monitor.sh`
   - Assert: treated as `implementing` (default)

6. **Test notification (mock):**
   - Set `CLAWDBOT_SLACK_WEBHOOK` to a local HTTP echo server or `/dev/null`
   - Verify `notify.sh` is called with correct args

### Manual smoke test

```bash
# 1. Restore .clawdbot/ infra
git cherry-pick 3120b6c87

# 2. Create test task
python3 -c "
import json
tasks = [{
    'id': 'test-plan',
    'branch': 'feat/test-plan',
    'agent': 'claude',
    'tmuxSession': 'agent-test-plan',
    'status': 'succeeded',
    'startedAt': '2026-02-27T00:00:00Z',
    'worktree': '/tmp/test-worktree',
    'logFile': '/tmp/test-agent.log',
    'phase': 'planning',
    'failCount': 0,
    'maxRetries': 1
}]
json.dump(tasks, open('.clawdbot/active-tasks.json', 'w'), indent=2)
"

# 3. Create fake plan file
mkdir -p /tmp/test-worktree/.clawdbot/plans
echo '# Test Plan' > /tmp/test-worktree/.clawdbot/plans/test-plan.md

# 4. Create AGENT_EXIT_SUCCESS log
echo 'AGENT_EXIT_SUCCESS' > /tmp/test-agent.log
echo 'AGENT_DONE' >> /tmp/test-agent.log

# 5. Run monitor
.clawdbot/monitor.sh

# 6. Verify
python3 -c "import json; t=json.load(open('.clawdbot/active-tasks.json'))[0]; print(f'phase={t[\"phase\"]} planFile={t.get(\"planFile\")}')"
# Expected: phase=plan_review planFile=.../.clawdbot/plans/test-plan.md
```

### Validation checklist
- [ ] `shellcheck .clawdbot/monitor.sh`
- [ ] `shellcheck .clawdbot/notify.sh`
- [ ] `python3 -m py_compile` on the inline Python (extract to temp file first)
- [ ] All scripts have `#!/usr/bin/env bash` and `set -euo pipefail`
- [ ] All scripts are `chmod +x`
- [ ] File locking uses the same `.tasks.lock` as existing scripts
- [ ] No secrets committed (webhook URL is env var only)

---

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Planning agent writes plan to stdout only, not a file | Medium | Prompt template explicitly says to write to `.clawdbot/plans/{TASK_ID}.md`. `find_plan_file()` checks 4 locations. Retry with stronger hint on failure. |
| `planFile` absolute path breaks after worktree cleanup | Medium | Plan is archived to main repo's `.clawdbot/plans/` immediately on detection. `planFile` stores the archive path. |
| Concurrent cron runs race on `active-tasks.json` | Low | `fcntl.flock(LOCK_EX)` on `.tasks.lock` — same pattern as existing scripts. Second run blocks until first finishes; idempotent logic means it's safe. |
| `check-agents.sh` not restored before `monitor.sh` runs | Low | Cherry-pick restores all scripts atomically. `monitor.sh` calls `check-agents.sh` as first action — will error if missing. |
| Slack webhook failures block monitor | Low | `notify.sh` exits 0 when `CLAWDBOT_SLACK_WEBHOOK` is unset. `curl -sf` with `> /dev/null` means failures don't propagate. `monitor.sh` calls `notify()` with `capture_output=True`. |
| `plan_review` stalls indefinitely with no human action | Medium | Not a bug — it's a designed human gate. Nice-to-have: add staleness reminder if `plan_review` > 24h (out of scope for this PR). |

---

## Estimated Complexity

**Medium** — 3 new files (monitor.sh ~120 lines, notify.sh ~25 lines, plan prompt ~20 lines), 2 modified files (spawn-agent.sh, cleanup-worktrees.sh — small changes each), 1 test file. The core logic (Python state machine) is straightforward but has several edge cases around plan file detection and retry logic.

---

## Implementation Order

1. Cherry-pick `3120b6c87` to restore base `.clawdbot/` infra + `CLAUDE.md`
2. Create `.clawdbot/notify.sh` (standalone, no deps)
3. Create `.clawdbot/prompts/plan.md` (standalone template)
4. Modify `.clawdbot/spawn-agent.sh` — add `phase` as 6th positional arg
5. Create `.clawdbot/monitor.sh` — the state machine (depends on notify.sh + check-agents.sh)
6. Modify `.clawdbot/cleanup-worktrees.sh` — add plan file archival
7. Create `.clawdbot/tests/test-monitor.sh` — automated tests
8. Run shellcheck + manual smoke test
