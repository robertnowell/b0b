#!/usr/bin/env bash
# dispatch-replan.sh — Re-dispatch a planning agent for an existing task
# Usage: ./dispatch-replan.sh --task-id <id> --feedback "text" [--agent claude|codex]
#
# Like dispatch-fix.sh but triggers a full planning phase instead of direct fix.
# Used when feedback indicates the approach was fundamentally wrong and needs rethinking.

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/config.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPAWN="${SCRIPT_DIR}/spawn-agent.sh"
source "${SCRIPT_DIR}/notify.sh"

# Parse args
TASK_ID=""
FEEDBACK=""
AGENT_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)   [[ $# -ge 2 ]] || { echo "ERROR: --task-id requires a value" >&2; exit 1; };  TASK_ID="$2"; shift 2 ;;
    --feedback)  [[ $# -ge 2 ]] || { echo "ERROR: --feedback requires a value" >&2; exit 1; };  FEEDBACK="$2"; shift 2 ;;
    --agent)     [[ $# -ge 2 ]] || { echo "ERROR: --agent requires a value" >&2; exit 1; };     AGENT_OVERRIDE="$2"; shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$TASK_ID" ]]  || { echo "ERROR: --task-id is required" >&2; exit 1; }
[[ -n "$FEEDBACK" ]] || { echo "ERROR: --feedback is required" >&2; exit 1; }

# Read task from active-tasks.json
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
    else:
        print(json.dumps(task))
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    fd.close()
" "$TASKS_FILE" "$LOCK_FILE" "$TASK_ID")

if [[ "$TASK_JSON" == ERROR:not_found ]]; then
  echo "ERROR: Task $TASK_ID not found" >&2
  exit 1
fi

BRANCH=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['branch'])")
AGENT=$(echo "$TASK_JSON" | python3 -c "import json,sys; t=json.load(sys.stdin); print(sys.argv[1] if sys.argv[1] else t.get('agent','claude'))" "$AGENT_OVERRIDE")
DESCRIPTION=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('description',''))")
PRODUCT_GOAL=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('productGoal',''))")
USER_REQUEST=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('userRequest',''))")

# Build planning prompt with feedback context prepended
BUILD_VARS="${SCRIPT_DIR}/build-context-vars.sh"
TEMPLATE="${PROMPTS_DIR}/plan.md"
FILLED_PROMPT="${LOG_DIR}/prompt-${TASK_ID}-replan-$(date +%s).md"
mkdir -p "$LOG_DIR"

# Create a modified description that includes the feedback
REPLAN_DESC="RE-PLAN NEEDED: Previous implementation did not work. Feedback: ${FEEDBACK}

Original task: ${DESCRIPTION}"

"$BUILD_VARS" --task-id "$TASK_ID" --phase planning \
  --template "$TEMPLATE" \
  --override TASK_DESCRIPTION="$REPLAN_DESC" \
  --override USER_REQUEST="$USER_REQUEST" \
  --override PRODUCT_GOAL="$PRODUCT_GOAL" \
  > "$FILLED_PROMPT"

# Spawn planning agent in existing worktree
SPAWN_ARGS=("$TASK_ID" "$BRANCH" "$AGENT" "$FILLED_PROMPT" ""
  --phase planning
  --description "$DESCRIPTION"
  --product-goal "$PRODUCT_GOAL")
"$SPAWN" "${SPAWN_ARGS[@]}"

# Update task state
python3 -c "
import json, sys, fcntl
tasks_file, lock_file, task_id, feedback = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
fd = open(lock_file, 'w')
fcntl.flock(fd, fcntl.LOCK_EX)
try:
    with open(tasks_file) as f:
        tasks = json.load(f)
    for t in tasks:
        if t['id'] == task_id:
            t['phase'] = 'planning'
            t['status'] = 'running'
            t['lastFeedback'] = feedback
            t['replanCount'] = t.get('replanCount', 0) + 1
            break
    with open(tasks_file, 'w') as f:
        json.dump(tasks, f, indent=2)
        f.write('\n')
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    fd.close()
" "$TASKS_FILE" "$LOCK_FILE" "$TASK_ID" "$FEEDBACK"

notify \
  --task-id "$TASK_ID" \
  --phase "planning" \
  --message "Re-planning triggered — previous approach didn't work. Feedback: ${FEEDBACK:0:200}" \
  --product-goal "$PRODUCT_GOAL" \
  --next "Planning agent will investigate and propose new approach"

echo "Dispatch-replan complete."
echo "  Task:   $TASK_ID"
echo "  Branch: $BRANCH"
echo "  Agent:  $AGENT"
