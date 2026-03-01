# Plan: Migrate Pipeline to Workspace + Planning Phase + Plan Review Gate

## Current State Analysis

### Two divergent copies exist

1. **Repo copy** (`/Users/kopi/Projects/kopi/.clawdbot/`):
   - Original scripts. config.sh resolves paths relative to repo root.
   - `active-tasks.json` has 5 tasks (newer tasks including `planning-in-monitor-v2`).
   - monitor.sh does NOT have planning phase support.
   - Was reverted from the repo in commit `99084ea90`.

2. **Workspace copy** (`/Users/kopi/.openclaw/workspace-kopiclaw/scripts/`):
   - More evolved. config.sh uses `WORKSPACE_ROOT`.
   - State lives at `workspace/.clawdbot/active-tasks.json` (2 older tasks).
   - Already has `planning` phase in monitor.sh, `plan.md` template, `get_plan_result()`.
   - But: planning auto-advances to implementing (no human gate).
   - Plans written to worktree `.clawdbot/plans/` (wrong — gets reverted with repo).
   - Has `NOTIFY_OUTBOX`, Slack webhook in config.

3. **Launchd** (`com.kopiclaw.monitor.plist`):
   - Runs workspace `scripts/monitor.sh` every 300s.
   - Logs to `workspace/.clawdbot/logs/launchd-monitor.log`.
   - This means the cron is NOT monitoring the repo's active-tasks.json tasks.

### Key problems
- Two task registries, two sets of scripts, diverged state.
- Plan output goes to worktree (gets reverted/lost).
- No human review gate for plans.
- Hardcoded `.clawdbot` naming throughout.

---

## Target State

Single canonical location for all pipeline infra:

```
/Users/kopi/.openclaw/workspace-kopiclaw/pipeline/
├── scripts/
│   ├── config.sh
│   ├── monitor.sh
│   ├── spawn-agent.sh
│   ├── dispatch.sh
│   ├── check-agents.sh
│   ├── notify.sh
│   ├── fill-template.sh
│   ├── review-plan.sh
│   ├── approve-plan.sh      ← NEW
│   ├── reject-plan.sh       ← NEW
│   ├── cleanup-worktrees.sh
│   ├── gh-poll.sh
│   └── gh-poll-process.py
├── prompts/
│   ├── plan.md
│   ├── implement.md
│   ├── audit.md
│   ├── fix-feedback.md
│   ├── test.md
│   ├── create-pr.md
│   └── review-plan.md
├── plans/                    ← plan output goes here, not in worktrees
│   └── {task-id}.md
├── logs/
│   ├── monitor.log
│   ├── launchd-monitor.log
│   ├── agent-{task-id}.log
│   └── prompt-{task-id}-{phase}-{timestamp}.md
├── active-tasks.json
├── .tasks.lock
├── gh-poll-state.json
└── notify-outbox.jsonl
```

### Phase lifecycle with plan_review gate

```
planning → plan_review → implementing → auditing → [fixing ↔ auditing] → testing → [fixing ↔ testing] → pr_creating → reviewing → merged
                ↑                                                                                                                ↑
                │ requiresPlanReview: true (default)                                                                              │
                └─ If requiresPlanReview: false, skip plan_review and go straight to implementing ──────────────────────────────────
```

---

## Implementation Steps

### Step 1: Create `pipeline/` directory structure

```bash
mkdir -p /Users/kopi/.openclaw/workspace-kopiclaw/pipeline/{scripts,prompts,plans,logs}
```

### Step 2: Update `config.sh`

The single source of truth for all paths. Key changes:

```bash
#!/usr/bin/env bash
# config.sh — Shared configuration for agent pipeline scripts

REPO_ROOT="/Users/kopi/Projects/kopi"
PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKTREE_BASE="/Users/kopi/Projects/kopi-worktrees"
TASKS_FILE="${PIPELINE_DIR}/active-tasks.json"
LOCK_FILE="${PIPELINE_DIR}/.tasks.lock"
LOG_DIR="${PIPELINE_DIR}/logs"
PROMPTS_DIR="${PIPELINE_DIR}/prompts"
PLANS_DIR="${PIPELINE_DIR}/plans"
MAX_RUNTIME_SECONDS="${MAX_RUNTIME_SECONDS:-2700}"
MAX_ITERATIONS="${MAX_ITERATIONS:-4}"
CLAUDE_PATH="${CLAUDE_PATH:-claude}"
CODEX_PATH="${CODEX_PATH:-codex}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-https://hooks.slack.com/services/XXXXX/XXXXX/XXXXX}"
NOTIFY_OUTBOX="${PIPELINE_DIR}/notify-outbox.jsonl"

mkdir -p "$LOG_DIR" "$PLANS_DIR"
```

Changes from current workspace `config.sh`:
- `CLAWDBOT_DIR` → eliminated, replaced by `PIPELINE_DIR`
- All paths derive from `PIPELINE_DIR` (which is the parent of `scripts/`)
- Added `PLANS_DIR` for plan output
- Removed `WORKSPACE_ROOT` (not needed — `PIPELINE_DIR` is sufficient)

### Step 3: Copy scripts from workspace `scripts/` to `pipeline/scripts/`

These are the workspace versions (more evolved than repo), with path updates:

| Script | Source | Changes needed |
|--------|--------|----------------|
| `config.sh` | Rewrite (see above) | New path scheme |
| `monitor.sh` | `workspace/scripts/monitor.sh` | Use `PLANS_DIR`, add `plan_review` phase, add `requiresPlanReview` logic |
| `spawn-agent.sh` | `workspace/scripts/spawn-agent.sh` | Update `source config.sh`, no other changes |
| `dispatch.sh` | `workspace/scripts/dispatch.sh` | Update `source config.sh`, add `--require-plan-review` flag |
| `check-agents.sh` | `workspace/scripts/check-agents.sh` | Update `source config.sh`, no other changes |
| `notify.sh` | `workspace/scripts/notify.sh` | Update `source config.sh`, add `plan_review` to `_infer_next_step` |
| `fill-template.sh` | `workspace/scripts/fill-template.sh` | Update `source config.sh`, no other changes |
| `review-plan.sh` | `workspace/scripts/review-plan.sh` | Update `source config.sh`, no other changes |
| `approve-plan.sh` | NEW | See below |
| `reject-plan.sh` | NEW | See below |
| `cleanup-worktrees.sh` | `workspace/scripts/cleanup-worktrees.sh` | Update `source config.sh` |
| `gh-poll.sh` | `workspace/scripts/gh-poll.sh` | Update state file path to `PIPELINE_DIR` |
| `gh-poll-process.py` | `workspace/scripts/gh-poll-process.py` | No changes |

### Step 4: Copy prompts to `pipeline/prompts/`

Copy all 7 templates from `workspace/scripts/prompts/`. One change needed:

**`plan.md`**: Change plan output path from worktree `.clawdbot/plans/{TASK_ID}.md` to a message that the agent should output the plan to stdout (since the plan needs to end up in `PLANS_DIR` which is outside the worktree). OR: have the agent write to a well-known path and have `get_plan_result()` look for it.

**Decision**: Keep the agent writing to the worktree at a known path, but change `get_plan_result()` to also copy it to `PLANS_DIR`. The agent runs inside the worktree and doesn't know about `PIPELINE_DIR`. Two options:

- **Option A**: Agent writes plan to `{worktree}/plan.md` (repo root of worktree). `get_plan_result()` reads from there and copies to `PLANS_DIR/{task-id}.md`.
- **Option B**: Pass `PLANS_DIR` as a template variable so the agent writes directly there.

**Go with Option A** — simpler, the agent just writes `plan.md` at repo root of its worktree (not inside `.clawdbot/`). `get_plan_result()` reads it from there and copies to `PLANS_DIR`.

Update `plan.md` template:
```
Write your plan to `plan.md` at the repository root of your worktree.
```
(Currently says `.clawdbot/plans/{TASK_ID}.md`)

### Step 5: Schema changes to `active-tasks.json`

Add these fields per task:

```jsonc
{
  "id": "...",
  "phase": "planning",       // NEW values: "plan_review" added
  "requiresPlanReview": true, // NEW — default true, controls human gate
  "planFile": "",             // NEW — absolute path to plan file in PLANS_DIR
  "planContent": "",          // EXISTING in workspace — content of the approved plan
  // ... all existing fields unchanged
}
```

**`requiresPlanReview`**:
- `true` (default): When planning succeeds → transition to `plan_review` (human gate). Monitor sends Slack notification with plan summary. Human runs `approve-plan.sh` to advance to implementing.
- `false`: When planning succeeds → auto-advance to `implementing` (no human gate). Monitor sends notification and immediately spawns the implementation agent.

### Step 6: Monitor.sh state machine changes

The workspace version already has a `planning` phase handler. Changes needed:

#### 6a: Update `get_plan_result()` to use new plan paths

```python
def get_plan_result(task):
    """Parse the plan file for PLAN_VERDICT line."""
    tid = task.get('id', '')
    worktree = task.get('worktree', os.path.join(worktree_base, tid))

    # Look for plan at worktree root first, then legacy .clawdbot/plans/ path
    plan_paths = [
        os.path.join(worktree, 'plan.md'),
        os.path.join(worktree, '.clawdbot', 'plans', f'{tid}.md'),
    ]

    plan_path = None
    for p in plan_paths:
        if os.path.exists(p):
            plan_path = p
            break

    if plan_path is None:
        return 'not_ready', 'No plan file found', ''

    with open(plan_path) as f:
        content = f.read()

    # Also check agent log for the verdict
    log_file = task.get('logFile', '')
    verdict = None
    for line in reversed(content.split('\n')):
        stripped = line.strip()
        if stripped.startswith('PLAN_VERDICT:'):
            verdict = stripped.split(':', 1)[1].strip().upper()
            break

    if verdict is None and log_file and os.path.exists(log_file):
        with open(log_file) as f:
            log_content = f.read()
        for line in reversed(log_content.split('\n')):
            stripped = line.strip()
            if stripped.startswith('PLAN_VERDICT:'):
                verdict = stripped.split(':', 1)[1].strip().upper()
                break

    summary = content[:500].replace('\n', ' ').strip()

    # Copy plan to PLANS_DIR for persistence
    plans_dir = os.environ.get('PLANS_DIR', os.path.join(script_dir, '..', 'plans'))
    os.makedirs(plans_dir, exist_ok=True)
    import shutil
    dest = os.path.join(plans_dir, f'{tid}.md')
    shutil.copy2(plan_path, dest)

    if verdict == 'READY':
        return 'ready', summary, content, dest
    else:
        return 'not_ready', summary or 'Plan not marked as ready', content, dest
```

#### 6b: Replace `planning` succeeded handler with `requiresPlanReview` logic

Current workspace logic (planning succeeded → auto-advance to implementing):

```python
if phase == 'planning':
    plan_status, plan_summary, plan_content = get_plan_result(task)
    if plan_status == 'ready':
        # auto-advance to implementing
        ...
```

New logic:

```python
if phase == 'planning':
    plan_status, plan_summary, plan_content, plan_file = get_plan_result(task)
    if plan_status == 'ready':
        requires_review = task.get('requiresPlanReview', True)
        if requires_review:
            # Human gate — park in plan_review
            apply_updates(tid, {
                'phase': 'plan_review',
                'status': 'plan_review',
                'planFile': plan_file,
                'planContent': plan_content,
            })
            run_notify(tid, 'plan_review',
                f'Plan ready for review. Run approve-plan.sh {tid} to proceed.\nSummary: {plan_summary[:200]}',
                product_goal,
                'Awaiting human plan approval')
        else:
            # Auto-advance — no human gate
            task['planContent'] = plan_content
            run_notify(tid, 'implementing',
                f'Plan auto-approved (requiresPlanReview=false). Starting implementation.',
                product_goal,
                'Starting implementation')
            ok = spawn_agent(task, 'implementing', 'implement.md', task.get('agent'))
            if ok:
                apply_updates(tid, {
                    'phase': 'implementing',
                    'status': 'running',
                    'planContent': plan_content,
                    'planFile': plan_file,
                })
            else:
                print(f'ERROR: spawn failed for {tid} during planning->implementing')
                run_notify(tid, phase, f'Failed to spawn implementation agent', product_goal)
    else:
        # Plan not ready — respawn or needs_split (existing logic)
        ...
    changes_made += 1
```

#### 6c: Add `plan_review` to terminal/skip phases

`plan_review` is a **parking state** — the monitor should skip it (like `reviewing`). The monitor doesn't advance it; only `approve-plan.sh` or `reject-plan.sh` do.

```python
# Skip tasks that are already terminal or parked
if phase in ('merged', 'needs_split', 'plan_review'):
    continue
```

#### 6d: Pass `PLANS_DIR` as env var to the Python block

Add `plans_dir = sys.argv[12]` and pass `$PLANS_DIR` as the 12th argument.

### Step 7: New script — `approve-plan.sh`

```bash
#!/usr/bin/env bash
# approve-plan.sh — Approve a plan and advance task to implementing
# Usage: ./approve-plan.sh <task-id> [--agent <codex|claude>]
#
# Reads the plan from plans/{task-id}.md, spawns an implementing agent.
# Only works on tasks in plan_review phase.

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPAWN="${SCRIPT_DIR}/spawn-agent.sh"
FILL_TEMPLATE="${SCRIPT_DIR}/fill-template.sh"
source "${SCRIPT_DIR}/notify.sh"

# Parse args
TASK_ID="${1:?Usage: approve-plan.sh <task-id> [--agent codex|claude]}"
shift
AGENT_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT_OVERRIDE="$2"; shift 2 ;;
    *) echo "ERROR: Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Read task from active-tasks.json
TASK_JSON=$(python3 -c "
import json, sys, fcntl
tasks_file = sys.argv[1]
lock_file = sys.argv[2]
task_id = sys.argv[3]
fd = open(lock_file, 'w')
fcntl.flock(fd, fcntl.LOCK_EX)
try:
    with open(tasks_file) as f:
        tasks = json.load(f)
    task = next((t for t in tasks if t['id'] == task_id), None)
    if not task:
        print('ERROR:not_found')
    elif task.get('phase') != 'plan_review':
        print(f'ERROR:wrong_phase:{task.get(\"phase\",\"unknown\")}')
    else:
        print(json.dumps(task))
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    fd.close()
" "$TASKS_FILE" "$LOCK_FILE" "$TASK_ID")

if [[ "$TASK_JSON" == ERROR:not_found ]]; then
  echo "ERROR: Task $TASK_ID not found" >&2; exit 1
fi
if [[ "$TASK_JSON" == ERROR:wrong_phase:* ]]; then
  CURRENT_PHASE="${TASK_JSON#ERROR:wrong_phase:}"
  echo "ERROR: Task $TASK_ID is in phase '$CURRENT_PHASE', not 'plan_review'" >&2; exit 1
fi

# Extract fields
BRANCH=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['branch'])")
AGENT=$(echo "$TASK_JSON" | python3 -c "import json,sys; t=json.load(sys.stdin); print(sys.argv[1] if sys.argv[1] else t.get('agent','claude'))" "$AGENT_OVERRIDE")
DESCRIPTION=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('description',''))")
PRODUCT_GOAL=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('productGoal',''))")

# Read plan content
PLAN_FILE="${PLANS_DIR}/${TASK_ID}.md"
if [ ! -f "$PLAN_FILE" ]; then
  echo "ERROR: Plan file not found: $PLAN_FILE" >&2; exit 1
fi
PLAN_CONTENT="$(cat "$PLAN_FILE")"

# Fill implementation prompt
TEMPLATE="${PROMPTS_DIR}/implement.md"
FILLED_PROMPT="${LOG_DIR}/prompt-${TASK_ID}-implementing-$(date +%s).md"
"$FILL_TEMPLATE" "$TEMPLATE" \
  --var PRD="$PRODUCT_GOAL" \
  --var PLAN="$PLAN_CONTENT" \
  --var DELIVERABLES="$DESCRIPTION" \
  --var TASK_DESCRIPTION="$DESCRIPTION" \
  --var FEATURE="$DESCRIPTION" \
  --var FEEDBACK="" \
  --var DESCRIPTION="$DESCRIPTION" \
  --var PRODUCT_GOAL="$PRODUCT_GOAL" \
  --var DIFF="$PLAN_CONTENT" \
  --var TASK_ID="$TASK_ID" \
  > "$FILLED_PROMPT"

# Spawn implementing agent
"$SPAWN" "$TASK_ID" "$BRANCH" "$AGENT" "$FILLED_PROMPT" "" \
  --phase implementing \
  --description "$DESCRIPTION" \
  --product-goal "$PRODUCT_GOAL"

# Update task phase (spawn-agent.sh writes its own entry, but we need to carry planContent)
python3 -c "
import json, sys, fcntl
tasks_file, lock_file, task_id, plan_content = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
fd = open(lock_file, 'w')
fcntl.flock(fd, fcntl.LOCK_EX)
try:
    with open(tasks_file) as f:
        tasks = json.load(f)
    for t in tasks:
        if t['id'] == task_id:
            t['planContent'] = plan_content
            break
    with open(tasks_file, 'w') as f:
        json.dump(tasks, f, indent=2)
        f.write('\n')
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    fd.close()
" "$TASKS_FILE" "$LOCK_FILE" "$TASK_ID" "$PLAN_CONTENT"

# Notify
notify \
  --task-id "$TASK_ID" \
  --phase "implementing" \
  --message "Plan approved. Implementation started with ${AGENT}." \
  --product-goal "$PRODUCT_GOAL" \
  --next "Will run audit on completion"

echo "Plan approved for $TASK_ID. Implementation agent spawned."
```

### Step 8: New script — `reject-plan.sh`

```bash
#!/usr/bin/env bash
# reject-plan.sh — Reject a plan and send task back to planning or needs_split
# Usage: ./reject-plan.sh <task-id> [--reason "why"] [--split]
#
# --split: Mark as needs_split instead of re-planning
# Without --split: Respawns planning agent with feedback

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPAWN="${SCRIPT_DIR}/spawn-agent.sh"
FILL_TEMPLATE="${SCRIPT_DIR}/fill-template.sh"
source "${SCRIPT_DIR}/notify.sh"

TASK_ID="${1:?Usage: reject-plan.sh <task-id> [--reason 'why'] [--split]}"
shift
REASON=""
SPLIT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reason) REASON="$2"; shift 2 ;;
    --split)  SPLIT=true; shift ;;
    *) echo "ERROR: Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Read and validate task
TASK_JSON=$(python3 -c "
import json, sys, fcntl
tasks_file, lock_file, task_id = sys.argv[1], sys.argv[2], sys.argv[3]
fd = open(lock_file, 'w')
fcntl.flock(fd, fcntl.LOCK_EX)
try:
    with open(tasks_file) as f:
        tasks = json.load(f)
    task = next((t for t in tasks if t['id'] == task_id), None)
    if not task:
        print('ERROR:not_found')
    elif task.get('phase') != 'plan_review':
        print(f'ERROR:wrong_phase:{task.get(\"phase\",\"unknown\")}')
    else:
        print(json.dumps(task))
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    fd.close()
" "$TASKS_FILE" "$LOCK_FILE" "$TASK_ID")

if [[ "$TASK_JSON" == ERROR:not_found ]]; then
  echo "ERROR: Task $TASK_ID not found" >&2; exit 1
fi
if [[ "$TASK_JSON" == ERROR:wrong_phase:* ]]; then
  CURRENT_PHASE="${TASK_JSON#ERROR:wrong_phase:}"
  echo "ERROR: Task $TASK_ID is in phase '$CURRENT_PHASE', not 'plan_review'" >&2; exit 1
fi

if [ "$SPLIT" = true ]; then
  # Mark as needs_split
  python3 -c "
import json, sys, fcntl
tasks_file, lock_file, task_id, reason = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
fd = open(lock_file, 'w')
fcntl.flock(fd, fcntl.LOCK_EX)
try:
    with open(tasks_file) as f:
        tasks = json.load(f)
    for t in tasks:
        if t['id'] == task_id:
            t['phase'] = 'needs_split'
            t['status'] = 'needs_split'
            t.setdefault('findings', []).append(f'Plan rejected (split requested): {reason}')
            break
    with open(tasks_file, 'w') as f:
        json.dump(tasks, f, indent=2)
        f.write('\n')
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    fd.close()
" "$TASKS_FILE" "$LOCK_FILE" "$TASK_ID" "$REASON"

  notify --task-id "$TASK_ID" --phase "needs_split" \
    --message "Plan rejected. Task needs manual split. Reason: ${REASON:-none given}" \
    --next "Needs manual split into subtasks"
  echo "Task $TASK_ID marked as needs_split."
else
  # Respawn planning agent with feedback
  BRANCH=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['branch'])")
  AGENT=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('agent','claude'))")
  DESCRIPTION=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('description',''))")
  PRODUCT_GOAL=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('productGoal',''))")
  ITERATION=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('iteration',0))")

  # Increment iteration
  NEW_ITERATION=$((ITERATION + 1))
  MAX_ITER=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('maxIterations',4))")

  if [ "$NEW_ITERATION" -ge "$MAX_ITER" ]; then
    echo "ERROR: Task $TASK_ID has reached max iterations ($MAX_ITER). Use --split instead." >&2
    exit 1
  fi

  # Read previous plan for context
  PREV_PLAN=""
  PLAN_FILE="${PLANS_DIR}/${TASK_ID}.md"
  if [ -f "$PLAN_FILE" ]; then
    PREV_PLAN="$(cat "$PLAN_FILE")"
  fi

  # Fill planning prompt with feedback
  TEMPLATE="${PROMPTS_DIR}/plan.md"
  FILLED_PROMPT="${LOG_DIR}/prompt-${TASK_ID}-planning-$(date +%s).md"
  "$FILL_TEMPLATE" "$TEMPLATE" \
    --var PRD="$PRODUCT_GOAL" \
    --var PLAN="$PREV_PLAN" \
    --var DELIVERABLES="$DESCRIPTION" \
    --var TASK_DESCRIPTION="$DESCRIPTION" \
    --var FEATURE="$DESCRIPTION" \
    --var FEEDBACK="Plan rejected. Reason: ${REASON:-No specific reason given}. Please revise." \
    --var DESCRIPTION="$DESCRIPTION" \
    --var PRODUCT_GOAL="$PRODUCT_GOAL" \
    --var DIFF="" \
    --var TASK_ID="$TASK_ID" \
    > "$FILLED_PROMPT"

  # Append rejection context
  if [ -n "$REASON" ]; then
    echo "" >> "$FILLED_PROMPT"
    echo "## Plan Rejection Feedback" >> "$FILLED_PROMPT"
    echo "$REASON" >> "$FILLED_PROMPT"
    echo "" >> "$FILLED_PROMPT"
    echo "Revise your plan to address this feedback." >> "$FILLED_PROMPT"
  fi

  # Update iteration before spawning
  python3 -c "
import json, sys, fcntl
tasks_file, lock_file, task_id, iteration, reason = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5]
fd = open(lock_file, 'w')
fcntl.flock(fd, fcntl.LOCK_EX)
try:
    with open(tasks_file) as f:
        tasks = json.load(f)
    for t in tasks:
        if t['id'] == task_id:
            t['iteration'] = iteration
            t.setdefault('findings', []).append(f'Plan rejected: {reason}')
            break
    with open(tasks_file, 'w') as f:
        json.dump(tasks, f, indent=2)
        f.write('\n')
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    fd.close()
" "$TASKS_FILE" "$LOCK_FILE" "$TASK_ID" "$NEW_ITERATION" "$REASON"

  # Spawn planning agent
  "$SPAWN" "$TASK_ID" "$BRANCH" "$AGENT" "$FILLED_PROMPT" "" \
    --phase planning \
    --description "$DESCRIPTION" \
    --product-goal "$PRODUCT_GOAL"

  notify --task-id "$TASK_ID" --phase "planning" \
    --message "Plan rejected. Re-planning (iteration ${NEW_ITERATION}/${MAX_ITER}). Reason: ${REASON:-none given}" \
    --product-goal "$PRODUCT_GOAL" \
    --next "Will produce revised plan"

  echo "Plan rejected for $TASK_ID. Re-planning spawned (iteration ${NEW_ITERATION}/${MAX_ITER})."
fi
```

### Step 9: Update `dispatch.sh`

Add `--require-plan-review` flag (defaults to `true`):

```bash
# In argument parsing:
REQUIRE_PLAN_REVIEW="true"
...
    --require-plan-review)
      [[ $# -ge 2 ]] || { echo "ERROR: --require-plan-review requires a value" >&2; exit 1; }
      REQUIRE_PLAN_REVIEW="$2"; shift 2 ;;
```

Pass to spawn-agent or write directly to active-tasks.json after spawn:

```python
# After spawn, update task with requiresPlanReview
python3 -c "
import json, sys, fcntl
tasks_file, lock_file, task_id, require_review = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
fd = open(lock_file, 'w')
fcntl.flock(fd, fcntl.LOCK_EX)
try:
    with open(tasks_file) as f:
        tasks = json.load(f)
    for t in tasks:
        if t['id'] == task_id:
            t['requiresPlanReview'] = require_review.lower() == 'true'
            break
    with open(tasks_file, 'w') as f:
        json.dump(tasks, f, indent=2)
        f.write('\n')
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    fd.close()
" "$TASKS_FILE" "$LOCK_FILE" "$TASK_ID" "$REQUIRE_PLAN_REVIEW"
```

### Step 10: Update `notify.sh` — add `plan_review` phase

```bash
_infer_next_step() {
  local phase="$1"
  case "$phase" in
    queued)        echo "Waiting for agent slot" ;;
    planning)      echo "Will produce implementation plan for review" ;;
    plan_review)   echo "Awaiting human plan approval (approve-plan.sh or reject-plan.sh)" ;;  # NEW
    implementing)  echo "Will run audit on completion" ;;
    ...
  esac
}
```

### Step 11: Update launchd plist

Update `com.kopiclaw.monitor.plist` to point to new paths:

```xml
<key>ProgramArguments</key>
<array>
    <string>/bin/bash</string>
    <string>/Users/kopi/.openclaw/workspace-kopiclaw/pipeline/scripts/monitor.sh</string>
</array>
...
<key>StandardOutPath</key>
<string>/Users/kopi/.openclaw/workspace-kopiclaw/pipeline/logs/launchd-monitor.log</string>
<key>StandardErrorPath</key>
<string>/Users/kopi/.openclaw/workspace-kopiclaw/pipeline/logs/launchd-monitor.log</string>
```

Then:
```bash
launchctl unload ~/Library/LaunchAgents/com.kopiclaw.monitor.plist
launchctl load ~/Library/LaunchAgents/com.kopiclaw.monitor.plist
```

### Step 12: Migrate active-tasks.json

Two registries need merging. The repo one has the current tasks; the workspace one has older completed tasks.

Strategy:
1. Copy repo's `active-tasks.json` to `pipeline/active-tasks.json` (it has the current working tasks)
2. Merge workspace's entries that don't conflict (by task ID)
3. Update all `logFile` paths in migrated entries to use `pipeline/logs/` prefix
4. Update all `worktree` paths to use normalized absolute paths

```python
# One-time migration script
import json

repo_tasks = json.load(open('/Users/kopi/Projects/kopi/.clawdbot/active-tasks.json'))
ws_tasks = json.load(open('/Users/kopi/.openclaw/workspace-kopiclaw/.clawdbot/active-tasks.json'))

repo_ids = {t['id'] for t in repo_tasks}
merged = repo_tasks + [t for t in ws_tasks if t['id'] not in repo_ids]

# Update logFile paths
pipeline_log_dir = '/Users/kopi/.openclaw/workspace-kopiclaw/pipeline/logs'
for t in merged:
    old_log = t.get('logFile', '')
    if old_log:
        basename = old_log.rsplit('/', 1)[-1]
        t['logFile'] = f'{pipeline_log_dir}/{basename}'
    # Normalize worktree paths
    wt = t.get('worktree', '')
    if '/../' in wt:
        import os
        t['worktree'] = os.path.normpath(wt)
    # Add requiresPlanReview default
    if 'requiresPlanReview' not in t:
        t['requiresPlanReview'] = True

json.dump(merged, open('/Users/kopi/.openclaw/workspace-kopiclaw/pipeline/active-tasks.json', 'w'), indent=2)
```

### Step 13: Copy log files

```bash
# Copy logs from both locations to pipeline/logs/
cp /Users/kopi/Projects/kopi/.clawdbot/logs/* /Users/kopi/.openclaw/workspace-kopiclaw/pipeline/logs/ 2>/dev/null || true
cp /Users/kopi/.openclaw/workspace-kopiclaw/.clawdbot/logs/agent-* /Users/kopi/.openclaw/workspace-kopiclaw/pipeline/logs/ 2>/dev/null || true
cp /Users/kopi/.openclaw/workspace-kopiclaw/.clawdbot/logs/prompt-* /Users/kopi/.openclaw/workspace-kopiclaw/pipeline/logs/ 2>/dev/null || true
```

### Step 14: Update `plan.md` prompt template

Change the plan output instruction from:
```
Write your plan to `.clawdbot/plans/{TASK_ID}.md` (create the directory if needed).
```
To:
```
Write your plan to `plan.md` at the root of your worktree.
```

This is important because the agent doesn't have access to PLANS_DIR (outside the worktree). The monitor's `get_plan_result()` will find it at `{worktree}/plan.md` and copy it to `PLANS_DIR/{task-id}.md`.

---

## Edge Cases

### 1. Race condition: monitor runs while approve-plan.sh is executing
- `approve-plan.sh` uses flock on `LOCK_FILE` for all reads/writes.
- Monitor skips `plan_review` phase tasks entirely — no conflict.

### 2. Task dispatched with `--phase implementing` (skip planning)
- `dispatch.sh` already supports `--phase implementing` with `--plan-file`.
- `requiresPlanReview` is irrelevant when starting from implementing.
- No changes needed — just ensure the phase validation regex includes `plan_review`.

### 3. Planning agent fails to write plan.md
- `get_plan_result()` returns `not_ready` → monitor respawns planning agent (existing logic).

### 4. Monitor finds task in `plan_review` on every cron run
- Task is skipped (added to terminal/skip set). No duplicate notifications.

### 5. Agent writes PLAN_VERDICT:READY in log but not in plan.md
- `get_plan_result()` already checks both the plan file and the agent log for the verdict line.

### 6. Old tasks reference stale log paths after migration
- Migration script updates `logFile` paths. For tasks in terminal states (merged, needs_split), stale paths don't matter since monitor skips them.

### 7. Worktree already exists when re-planning after rejection
- `spawn-agent.sh` handles this: `if [ ! -d "$WORKTREE_DIR" ]` — reuses existing worktree.

### 8. `requiresPlanReview` set per-task, not globally
- Stored in `active-tasks.json` per task entry.
- Dispatch sets it via `--require-plan-review true|false`.
- Default is `true` when not specified (both in dispatch and in monitor fallback).

---

## Execution Order

1. Create directory structure (`pipeline/{scripts,prompts,plans,logs}`)
2. Write new `config.sh`
3. Copy and update all scripts (monitor.sh is the big one)
4. Copy and update prompts (plan.md path change)
5. Run migration script for active-tasks.json
6. Copy log files
7. Update and reload launchd plist
8. Verify: run `pipeline/scripts/check-agents.sh` and confirm output
9. Verify: run `pipeline/scripts/monitor.sh` manually and check it handles all phases
10. Clean up: leave old `.clawdbot/` dirs in place but no longer referenced (can remove later)

## Files Changed Summary

| File | Action | Description |
|------|--------|-------------|
| `pipeline/scripts/config.sh` | New (rewrite) | New path scheme with PIPELINE_DIR |
| `pipeline/scripts/monitor.sh` | Copy + modify | Add plan_review phase, requiresPlanReview logic, updated plan paths |
| `pipeline/scripts/spawn-agent.sh` | Copy | Update config source path |
| `pipeline/scripts/dispatch.sh` | Copy + modify | Add --require-plan-review flag, planning defaults |
| `pipeline/scripts/check-agents.sh` | Copy | Update config source path |
| `pipeline/scripts/notify.sh` | Copy + modify | Add plan_review to _infer_next_step |
| `pipeline/scripts/fill-template.sh` | Copy | Update config source path |
| `pipeline/scripts/review-plan.sh` | Copy | Update config source path |
| `pipeline/scripts/approve-plan.sh` | New | Approve plan and advance to implementing |
| `pipeline/scripts/reject-plan.sh` | New | Reject plan, re-plan or mark needs_split |
| `pipeline/scripts/cleanup-worktrees.sh` | Copy | Update config source path |
| `pipeline/scripts/gh-poll.sh` | Copy + modify | Update state file path |
| `pipeline/scripts/gh-poll-process.py` | Copy | No changes |
| `pipeline/prompts/plan.md` | Copy + modify | Change plan output path to worktree root |
| `pipeline/prompts/*.md` | Copy | All other templates unchanged |
| `pipeline/active-tasks.json` | New (migrated) | Merged from both sources |
| `com.kopiclaw.monitor.plist` | Modify | Update script and log paths |
