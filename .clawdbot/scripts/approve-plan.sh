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
SPAWN_ARGS=("$TASK_ID" "$BRANCH" "$AGENT" "$FILLED_PROMPT" ""
  --phase implementing
  --description "$DESCRIPTION"
  --product-goal "$PRODUCT_GOAL")
"$SPAWN" "${SPAWN_ARGS[@]}"

# Update task — carry planContent through
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
