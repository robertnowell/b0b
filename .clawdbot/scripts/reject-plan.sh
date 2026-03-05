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

  # Fill planning prompt with feedback using centralized context builder
  BUILD_VARS="${SCRIPT_DIR}/build-context-vars.sh"
  TEMPLATE="${PROMPTS_DIR}/plan.md"
  FILLED_PROMPT="${LOG_DIR}/prompt-${TASK_ID}-planning-$(date +%s).md"
  "$BUILD_VARS" --task-id "$TASK_ID" --phase planning \
    --template "$TEMPLATE" \
    --override FEEDBACK="Plan rejected. Reason: ${REASON:-No specific reason given}. Please revise." \
    > "$FILLED_PROMPT"

  # Append rejection context
  if [ -n "$REASON" ]; then
    {
      echo ""
      echo "## Plan Rejection Feedback"
      echo "$REASON"
      echo ""
      echo "Revise your plan to address this feedback."
    } >> "$FILLED_PROMPT"
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
  SPAWN_ARGS=("$TASK_ID" "$BRANCH" "$AGENT" "$FILLED_PROMPT" ""
    --phase planning
    --description "$DESCRIPTION"
    --product-goal "$PRODUCT_GOAL")
  "$SPAWN" "${SPAWN_ARGS[@]}"

  notify --task-id "$TASK_ID" --phase "planning" \
    --message "Plan rejected. Re-planning (iteration ${NEW_ITERATION}/${MAX_ITER}). Reason: ${REASON:-none given}" \
    --product-goal "$PRODUCT_GOAL" \
    --next "Will produce revised plan"

  echo "Plan rejected for $TASK_ID. Re-planning spawned (iteration ${NEW_ITERATION}/${MAX_ITER})."
fi
