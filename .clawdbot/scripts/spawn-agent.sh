#!/usr/bin/env bash
# spawn-agent.sh — Spawn a coding agent in a worktree with tmux
# Usage: ./spawn-agent.sh <task-id> <branch-name> <agent: codex|claude> <prompt-file> [model]
#        Optional flags: --description "..." --product-goal "..."
#
# Example:
#   ./spawn-agent.sh feat-templates feat/custom-templates codex /tmp/prompt-templates.md
#   ./spawn-agent.sh fix-button fix/button-style claude /tmp/prompt-button.md claude-opus-4-6 \
#     --description "Fix button hover styles" --product-goal "Improve UI consistency"

set -euo pipefail

# Source shared config
# shellcheck source=config.sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Source notify for Slack alerts
# shellcheck source=notify.sh
source "$SCRIPT_DIR/notify.sh"

# Parse positional args first, then optional flags
POSITIONAL_ARGS=()
TASK_DESCRIPTION=""
PRODUCT_GOAL=""
USER_REQUEST=""
TASK_PHASE="implementing"
WORKSPACE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --description)
      [[ $# -ge 2 ]] || { echo "ERROR: --description requires a value" >&2; exit 1; }
      TASK_DESCRIPTION="$2"; shift 2 ;;
    --product-goal)
      [[ $# -ge 2 ]] || { echo "ERROR: --product-goal requires a value" >&2; exit 1; }
      PRODUCT_GOAL="$2"; shift 2 ;;
    --user-request)
      [[ $# -ge 2 ]] || { echo "ERROR: --user-request requires a value" >&2; exit 1; }
      USER_REQUEST="$2"; shift 2 ;;
    --phase)
      [[ $# -ge 2 ]] || { echo "ERROR: --phase requires a value" >&2; exit 1; }
      TASK_PHASE="$2"; shift 2 ;;
    --workspace)
      WORKSPACE="true"; shift ;;
    *)
      POSITIONAL_ARGS+=("$1"); shift ;;
  esac
done

TASK_ID="${POSITIONAL_ARGS[0]:?Usage: spawn-agent.sh <task-id> <branch> <agent> <prompt-file> [model] [--description ...] [--product-goal ...]}"
BRANCH="${POSITIONAL_ARGS[1]:?Missing branch name}"
AGENT="${POSITIONAL_ARGS[2]:?Missing agent (codex|claude)}"
PROMPT_FILE="${POSITIONAL_ARGS[3]:?Missing prompt file path}"
MODEL="${POSITIONAL_ARGS[4]:-}"

# Validate inputs to prevent injection and path traversal
[[ "$TASK_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo "ERROR: Invalid task ID (must start with alphanumeric, only [a-zA-Z0-9._-] allowed)"; exit 1; }
[[ "$BRANCH" =~ ^[a-zA-Z0-9._/-]+$ ]] || { echo "ERROR: Invalid branch name (only [a-zA-Z0-9._/-] allowed)"; exit 1; }
[[ "$AGENT" =~ ^(codex|claude)$ ]] || { echo "ERROR: Unknown agent: $AGENT (use codex or claude)"; exit 1; }
if [ -n "$MODEL" ]; then
  [[ "$MODEL" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "ERROR: Invalid model name (only [a-zA-Z0-9._-] allowed)"; exit 1; }
fi

# Resolve repo + worktree paths based on --workspace flag
eval "$(get_task_paths "$WORKSPACE")"
WORKTREE_DIR="${EFFECTIVE_WORKTREE_BASE}/${TASK_ID}"
TMUX_SESSION="agent-${TASK_ID}"
LOG_FILE="${LOG_DIR}/agent-${TASK_ID}.log"

# Ensure logs dir exists
mkdir -p "$LOG_DIR"

# Truncate log file for fresh run
> "$LOG_FILE"

# Validate prompt file exists
if [ ! -f "$PROMPT_FILE" ]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE"
  exit 1
fi

# Resolve to absolute path for use inside worktree
PROMPT_FILE="$(cd "$(dirname "$PROMPT_FILE")" && pwd)/$(basename "$PROMPT_FILE")"

# Ensure worktrees dir exists
mkdir -p "$(dirname "$WORKTREE_DIR")"

# Create worktree
cd "$EFFECTIVE_REPO"
git fetch origin main --quiet 2>/dev/null || true

if [ ! -d "$WORKTREE_DIR" ]; then
  git worktree add "$WORKTREE_DIR" -b "$BRANCH" origin/main 2>/dev/null || \
  git worktree add "$WORKTREE_DIR" "$BRANCH" 2>/dev/null || \
  { echo "ERROR: Failed to create worktree"; exit 1; }
fi

# Kill existing session if any
tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

# Build the wrapper script safely using printf %q for variable embedding
# This avoids shell injection from paths containing special characters
WRAPPER="/tmp/agent-${TASK_ID}-run.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo 'export PATH="/opt/homebrew/Cellar/node@22/22.22.0/lib/node_modules/corepack/shims:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"'
  echo 'export COREPACK_ENABLE_AUTO_PIN=0'
  echo 'export COREPACK_ENABLE_STRICT=0'
  printf 'AGENT_WORKTREE_DIR=%q\n' "$WORKTREE_DIR"
  printf 'AGENT_LOG_FILE=%q\n' "$LOG_FILE"
  printf 'AGENT_PROMPT_FILE=%q\n' "$PROMPT_FILE"
  printf 'AGENT_TYPE=%q\n' "$AGENT"
  printf 'AGENT_MODEL=%q\n' "${MODEL:-claude-opus-4-6}"
  printf 'AGENT_CLAUDE_PATH=%q\n' "$CLAUDE_PATH"
  printf 'AGENT_CODEX_PATH=%q\n' "$CODEX_PATH"
  printf 'WORKSPACE_TASK=%q\n' "$WORKSPACE"
  cat <<'SCRIPT_BODY'
cd "$AGENT_WORKTREE_DIR"
if [ "$WORKSPACE_TASK" != "true" ]; then
  if ! pnpm install --frozen-lockfile 2>&1 | tee -a "$AGENT_LOG_FILE"; then
    echo 'AGENT_FAIL:deps_install' >> "$AGENT_LOG_FILE"
    echo 'AGENT_DONE' >> "$AGENT_LOG_FILE"
    exit 1
  fi
  echo '=== DEPS INSTALLED ===' >> "$AGENT_LOG_FILE"
else
  echo '=== WORKSPACE TASK — SKIPPING DEPS ===' >> "$AGENT_LOG_FILE"
fi
if [ "$AGENT_TYPE" = "codex" ]; then
  "$AGENT_CODEX_PATH" exec --dangerously-bypass-approvals-and-sandbox < "$AGENT_PROMPT_FILE" 2>&1 | tee -a "$AGENT_LOG_FILE"
elif [ "$AGENT_TYPE" = "claude" ]; then
  "$AGENT_CLAUDE_PATH" --model "$AGENT_MODEL" --dangerously-skip-permissions -p - < "$AGENT_PROMPT_FILE" 2>&1 | tee -a "$AGENT_LOG_FILE"
fi
EXIT_CODE=${PIPESTATUS[0]}
if [ "$EXIT_CODE" -eq 0 ]; then
  echo 'AGENT_EXIT_SUCCESS' >> "$AGENT_LOG_FILE"
else
  echo "AGENT_EXIT_FAIL:${EXIT_CODE}" >> "$AGENT_LOG_FILE"
fi
echo 'AGENT_DONE' >> "$AGENT_LOG_FILE"
SCRIPT_BODY
} > "$WRAPPER"
chmod +x "$WRAPPER"

# Spawn in tmux
tmux new-session -d -s "$TMUX_SESSION" -c "$WORKTREE_DIR" "$WRAPPER"

# Register task in active-tasks.json (with file locking)
# The Python block handles file creation under the lock to avoid races
STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
python3 -c "
import json, sys, fcntl, os

tasks_file = sys.argv[1]
lock_file = sys.argv[2]
task_id = sys.argv[3]
branch = sys.argv[4]
agent = sys.argv[5]
tmux_session = sys.argv[6]
started_at = sys.argv[7]
worktree = sys.argv[8]
log_file = sys.argv[9]
phase = sys.argv[10]
max_iterations = int(sys.argv[11])
description = sys.argv[12]
product_goal = sys.argv[13]
user_request = sys.argv[14]
workspace = sys.argv[15].lower() == 'true'

lock_fd = open(lock_file, 'w')
fcntl.flock(lock_fd, fcntl.LOCK_EX)
try:
    if os.path.exists(tasks_file):
        with open(tasks_file) as f:
            try:
                tasks = json.load(f)
            except (json.JSONDecodeError, ValueError):
                tasks = []
    else:
        tasks = []

    # Check if task already exists (respawn case — preserve iteration/findings/fixTarget)
    existing = next((t for t in tasks if t.get('id') == task_id), None)
    iteration = 0
    findings = []
    fix_target = 'auditing'
    require_plan_review = True
    if existing:
        iteration = existing.get('iteration', 0)
        findings = existing.get('findings', [])
        fix_target = existing.get('fixTarget', 'auditing')
        require_plan_review = existing.get('requiresPlanReview', True)
        workspace = existing.get('workspace', workspace)
        tasks = [t for t in tasks if t.get('id') != task_id]

    entry = {
        'id': task_id,
        'branch': branch,
        'agent': agent,
        'tmuxSession': tmux_session,
        'status': 'running',
        'phase': phase,
        'iteration': iteration,
        'maxIterations': max_iterations,
        'startedAt': started_at,
        'worktree': worktree,
        'logFile': log_file,
        'description': description,
        'productGoal': product_goal,
        'findings': findings,
        'fixTarget': fix_target,
        'requiresPlanReview': require_plan_review,
        'userRequest': user_request,
    }
    if workspace:
        entry['workspace'] = True
    tasks.append(entry)

    with open(tasks_file, 'w') as f:
        json.dump(tasks, f, indent=2)
        f.write('\n')
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
" "$TASKS_FILE" "$LOCK_FILE" "$TASK_ID" "$BRANCH" "$AGENT" "$TMUX_SESSION" "$STARTED_AT" "$WORKTREE_DIR" "$LOG_FILE" "$TASK_PHASE" "$MAX_ITERATIONS" "$TASK_DESCRIPTION" "$PRODUCT_GOAL" "$USER_REQUEST" "$WORKSPACE"

echo "Spawned $AGENT agent"
echo "  Task:      $TASK_ID"
echo "  Branch:    $BRANCH"
echo "  Phase:     $TASK_PHASE"
echo "  tmux:      $TMUX_SESSION"
echo "  Worktree:  $WORKTREE_DIR"
echo "  Logs:      $LOG_FILE"
if [ -n "$TASK_DESCRIPTION" ]; then
  echo "  Desc:      $TASK_DESCRIPTION"
fi
if [ -n "$PRODUCT_GOAL" ]; then
  echo "  Goal:      $PRODUCT_GOAL"
fi

# Send Slack notification
notify \
  --task-id "$TASK_ID" \
  --phase "$TASK_PHASE" \
  --message "Agent spawned (${AGENT}). ${TASK_DESCRIPTION:-No description}" \
  --product-goal "${PRODUCT_GOAL:-N/A}"
