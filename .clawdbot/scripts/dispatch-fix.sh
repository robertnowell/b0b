#!/usr/bin/env bash
# dispatch-fix.sh — Dispatch a fixing agent into an existing task's worktree
# Usage: ./dispatch-fix.sh --task-id <id> --feedback "text" [--agent claude|codex]
#
# Reads the task from active-tasks.json, fills fix-feedback.md prompt with
# the feedback text, spawns agent in the existing worktree on the same branch.
# Sets the task phase to "fixing" and fixTarget to "reviewing".

set -euo pipefail

# Source shared config
# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPAWN="${SCRIPT_DIR}/spawn-agent.sh"

# shellcheck source=notify.sh
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

# Extract fields needed for spawn-agent.sh (which doesn't use the helper)
BRANCH=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['branch'])")
AGENT=$(echo "$TASK_JSON" | python3 -c "import json,sys; t=json.load(sys.stdin); print(sys.argv[1] if sys.argv[1] else t.get('agent','claude'))" "$AGENT_OVERRIDE")
DESCRIPTION=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('description',''))")
PRODUCT_GOAL=$(echo "$TASK_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('productGoal',''))")

# Fill fix-feedback prompt using centralized context builder
BUILD_VARS="${SCRIPT_DIR}/build-context-vars.sh"
TEMPLATE="${PROMPTS_DIR}/fix-feedback.md"
FILLED_PROMPT="${LOG_DIR}/prompt-${TASK_ID}-fixing-$(date +%s).md"
mkdir -p "$LOG_DIR"

"$BUILD_VARS" --task-id "$TASK_ID" --phase fixing \
  --template "$TEMPLATE" \
  --override FEEDBACK="$FEEDBACK" \
  > "$FILLED_PROMPT"

# Spawn agent — spawn-agent.sh will reuse existing worktree
SPAWN_ARGS=("$TASK_ID" "$BRANCH" "$AGENT" "$FILLED_PROMPT" ""
  --phase fixing
  --description "$DESCRIPTION"
  --product-goal "$PRODUCT_GOAL")
"$SPAWN" "${SPAWN_ARGS[@]}"

# Update task state: set fixTarget to reviewing and store feedback for PR comment
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
            t['fixTarget'] = 'reviewing'
            t['lastFeedback'] = feedback
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
  --phase "fixing" \
  --message "Fix agent dispatched for feedback: ${FEEDBACK:0:200}" \
  --product-goal "$PRODUCT_GOAL" \
  --next "Will push fixes to existing branch"

echo "Dispatch-fix complete."
echo "  Task:   $TASK_ID"
echo "  Branch: $BRANCH"
echo "  Agent:  $AGENT"
