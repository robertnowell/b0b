#!/usr/bin/env bash
# dispatch.sh — Orchestrator dispatch: takes a feature request and kicks off the pipeline
# Usage:
#   ./dispatch.sh \
#     --task-id <id> \
#     --branch <branch-name> \
#     --product-goal "What product goal this serves" \
#     --description "Specific engineering task" \
#     [--plan-file <path-to-implementation-plan.md>] \
#     --agent <codex|claude> \
#     [--model <model>] \
#     [--phase planning] \
#     [--require-plan-review true|false]
#
# What it does:
#   1. Validates inputs
#   2. Fills the implementation prompt template with plan, deliverables, and context
#   3. Spawns the first agent via spawn-agent.sh
#   4. Sets requiresPlanReview on the task
#   5. Sends Slack notification
#   6. Exits cleanly

set -euo pipefail

# Source shared config
# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILL_TEMPLATE="${SCRIPT_DIR}/fill-template.sh"
SPAWN="${SCRIPT_DIR}/spawn-agent.sh"

# Source notify.sh for the notify function
# shellcheck source=notify.sh
source "${SCRIPT_DIR}/notify.sh"

# --- Parse arguments ---
TASK_ID=""
BRANCH=""
PRODUCT_GOAL=""
DESCRIPTION=""
PLAN_FILE=""
AGENT=""
MODEL=""
PHASE="planning"
REQUIRE_PLAN_REVIEW="false"
USER_REQUEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)              [[ $# -ge 2 ]] || { echo "ERROR: --task-id requires a value" >&2; exit 1; };              TASK_ID="$2"; shift 2 ;;
    --branch)               [[ $# -ge 2 ]] || { echo "ERROR: --branch requires a value" >&2; exit 1; };               BRANCH="$2"; shift 2 ;;
    --product-goal)         [[ $# -ge 2 ]] || { echo "ERROR: --product-goal requires a value" >&2; exit 1; };         PRODUCT_GOAL="$2"; shift 2 ;;
    --description)          [[ $# -ge 2 ]] || { echo "ERROR: --description requires a value" >&2; exit 1; };          DESCRIPTION="$2"; shift 2 ;;
    --plan-file)            [[ $# -ge 2 ]] || { echo "ERROR: --plan-file requires a value" >&2; exit 1; };            PLAN_FILE="$2"; shift 2 ;;
    --agent)                [[ $# -ge 2 ]] || { echo "ERROR: --agent requires a value" >&2; exit 1; };                AGENT="$2"; shift 2 ;;
    --model)                [[ $# -ge 2 ]] || { echo "ERROR: --model requires a value" >&2; exit 1; };                MODEL="$2"; shift 2 ;;
    --phase)                [[ $# -ge 2 ]] || { echo "ERROR: --phase requires a value" >&2; exit 1; };                PHASE="$2"; shift 2 ;;
    --require-plan-review)  [[ $# -ge 2 ]] || { echo "ERROR: --require-plan-review requires a value" >&2; exit 1; };  REQUIRE_PLAN_REVIEW="$2"; shift 2 ;;
    --user-request)         [[ $# -ge 2 ]] || { echo "ERROR: --user-request requires a value" >&2; exit 1; };         USER_REQUEST="$2"; shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# --- Validate required inputs ---
[[ -n "$TASK_ID" ]]      || { echo "ERROR: --task-id is required" >&2; exit 1; }
[[ -n "$BRANCH" ]]       || { echo "ERROR: --branch is required" >&2; exit 1; }
[[ -n "$PRODUCT_GOAL" ]] || { echo "ERROR: --product-goal is required" >&2; exit 1; }
[[ -n "$DESCRIPTION" ]]  || { echo "ERROR: --description is required" >&2; exit 1; }
# plan-file is optional for the planning phase (no plan exists yet)
if [[ "$PHASE" != "planning" ]]; then
  [[ -n "$PLAN_FILE" ]] || { echo "ERROR: --plan-file is required for phase $PHASE" >&2; exit 1; }
fi
[[ -n "$AGENT" ]]        || { echo "ERROR: --agent is required" >&2; exit 1; }

# Validate formats (match spawn-agent.sh conventions)
[[ "$TASK_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo "ERROR: Invalid task ID" >&2; exit 1; }
[[ "$BRANCH" =~ ^[a-zA-Z0-9._/-]+$ ]]            || { echo "ERROR: Invalid branch name" >&2; exit 1; }
[[ "$AGENT" =~ ^(codex|claude)$ ]]                || { echo "ERROR: Agent must be codex or claude" >&2; exit 1; }
[[ "$PHASE" =~ ^(planning|plan_review|implementing|auditing|fixing|testing|pr_creating)$ ]] || { echo "ERROR: Invalid phase: $PHASE" >&2; exit 1; }
[[ "$REQUIRE_PLAN_REVIEW" =~ ^(true|false)$ ]]    || { echo "ERROR: --require-plan-review must be true or false" >&2; exit 1; }

if [ -n "$MODEL" ]; then
  [[ "$MODEL" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "ERROR: Invalid model name" >&2; exit 1; }
fi

# Validate plan file exists (skip for planning phase)
PLAN_CONTENT=""
if [[ -n "$PLAN_FILE" ]]; then
  if [ ! -f "$PLAN_FILE" ]; then
    echo "ERROR: Plan file not found: $PLAN_FILE" >&2
    exit 1
  fi
  PLAN_CONTENT="$(cat "$PLAN_FILE")"
fi

# --- Determine which template to use based on phase ---
case "$PHASE" in
  planning)     TEMPLATE="${PROMPTS_DIR}/plan.md" ;;
  implementing) TEMPLATE="${PROMPTS_DIR}/implement.md" ;;
  auditing)     TEMPLATE="${PROMPTS_DIR}/audit.md" ;;
  fixing)       TEMPLATE="${PROMPTS_DIR}/fix-feedback.md" ;;
  testing)      TEMPLATE="${PROMPTS_DIR}/test.md" ;;
  pr_creating)  TEMPLATE="${PROMPTS_DIR}/create-pr.md" ;;
esac

if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: Prompt template not found: $TEMPLATE" >&2
  exit 1
fi

# --- Fill the prompt template ---
FILLED_PROMPT_FILE="${LOG_DIR}/prompt-${TASK_ID}-${PHASE}-$(date +%s).md"
mkdir -p "$LOG_DIR"

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
  > "$FILLED_PROMPT_FILE"

# --- Spawn the agent ---
SPAWN_ARGS=(
  "$TASK_ID"
  "$BRANCH"
  "$AGENT"
  "$FILLED_PROMPT_FILE"
)

if [ -n "$MODEL" ]; then
  SPAWN_ARGS+=("$MODEL")
else
  SPAWN_ARGS+=("")  # empty model = use default
fi

SPAWN_ARGS+=(
  --phase "$PHASE"
  --description "$DESCRIPTION"
  --product-goal "$PRODUCT_GOAL"
)

if [ -n "$USER_REQUEST" ]; then
  SPAWN_ARGS+=(--user-request "$USER_REQUEST")
fi

"$SPAWN" "${SPAWN_ARGS[@]}"

# --- Set requiresPlanReview on the task ---
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

# --- Send Slack notification ---
notify \
  --task-id "$TASK_ID" \
  --phase "$PHASE" \
  --message "Task dispatched to ${AGENT}. Goal: ${PRODUCT_GOAL}. Phase: ${PHASE}." \
  --product-goal "$PRODUCT_GOAL" \
  --next "Will run audit on completion"

echo ""
echo "Dispatch complete."
echo "  Task:   $TASK_ID"
echo "  Agent:  $AGENT"
echo "  Phase:  $PHASE"
echo "  Review: $REQUIRE_PLAN_REVIEW"
echo "  Prompt: $FILLED_PROMPT_FILE"
