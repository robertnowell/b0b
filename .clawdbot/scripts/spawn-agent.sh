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
PARENT_TASK_ID=""
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
    --parent-task-id)
      [[ $# -ge 2 ]] || { echo "ERROR: --parent-task-id requires a value" >&2; exit 1; }
      PARENT_TASK_ID="$2"; shift 2 ;;
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

WORKTREE_DIR="${WORKTREE_BASE}/${TASK_ID}"
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
cd "$REPO_ROOT"
git fetch origin main --quiet 2>/dev/null || true
git fetch origin "$BRANCH" --quiet 2>/dev/null || true

# Use remote branch as base if it exists (e.g. existing PR), otherwise main
BASE_REF="origin/main"
if git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
  BASE_REF="origin/$BRANCH"
fi

if [ ! -d "$WORKTREE_DIR" ]; then
  git worktree add "$WORKTREE_DIR" -b "$BRANCH" "$BASE_REF" 2>/dev/null || \
  git worktree add "$WORKTREE_DIR" "$BRANCH" 2>/dev/null || \
  { echo "ERROR: Failed to create worktree"; exit 1; }
fi

# Ensure plan.md is gitignored in worktree so planning artifacts don't pollute git status
if ! grep -qx 'plan.md' "$WORKTREE_DIR/.gitignore" 2>/dev/null; then
  echo 'plan.md' >> "$WORKTREE_DIR/.gitignore"
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
  cat <<'SCRIPT_BODY'
cd "$AGENT_WORKTREE_DIR"
if [ -f "package.json" ]; then
  if ! pnpm install --frozen-lockfile 2>&1 | tee -a "$AGENT_LOG_FILE"; then
    echo 'AGENT_FAIL:deps_install' >> "$AGENT_LOG_FILE"
    echo 'AGENT_DONE' >> "$AGENT_LOG_FILE"
    exit 1
  fi
  echo '=== DEPS INSTALLED ===' >> "$AGENT_LOG_FILE"
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
parent_task_id = sys.argv[16]

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

    # Check if task already exists (respawn case — preserve execution metadata)
    existing = next((t for t in tasks if t.get('id') == task_id), None)
    iteration = 0
    findings = []
    fix_target = 'auditing'
    require_plan_review = False
    auto_retry_count = 0
    auto_split_attempt_count = 0
    split_depth = 0
    parent_task = None
    workspace = False
    created_at = started_at
    if existing:
        iteration = existing.get('iteration', 0)
        findings = existing.get('findings', [])
        fix_target = existing.get('fixTarget', 'auditing')
        require_plan_review = existing.get('requiresPlanReview', False)
        auto_retry_count = existing.get('autoRetryCount', 0)
        auto_split_attempt_count = existing.get('autoSplitAttemptCount', 0)
        split_depth = existing.get('splitDepth', 0)
        parent_task = existing.get('parentTask')
        workspace = existing.get('workspace', workspace)
        parent_task_id = existing.get('parentTaskId', '') or parent_task_id
        created_at = existing.get('createdAt', existing.get('startedAt', started_at))
        # Preserve PR/comment tracking fields that aren't passed via CLI args
        source_number = existing.get('sourceNumber')
        pr_number = existing.get('prNumber')
        source_comment_id = existing.get('sourceCommentId')
        source_comment_url = existing.get('sourceCommentUrl')
        conflict_fix_count = existing.get('conflictFixCount', 0)
        user_request = existing.get('userRequest', '') or user_request
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
        'createdAt': created_at,
        'worktree': worktree,
        'logFile': log_file,
        'description': description,
        'productGoal': product_goal,
        'findings': findings,
        'fixTarget': fix_target,
        'requiresPlanReview': require_plan_review,
        'autoRetryCount': auto_retry_count,
        'autoSplitAttemptCount': auto_split_attempt_count,
        'splitDepth': split_depth,
        'userRequest': user_request,
    }
    if parent_task:
        entry['parentTask'] = parent_task
    if workspace:
        entry['workspace'] = True
    if parent_task_id:
        entry['parentTaskId'] = parent_task_id
    if existing:
        if source_number:
            entry['sourceNumber'] = source_number
        if pr_number is not None:
            entry['prNumber'] = pr_number
        if source_comment_id:
            entry['sourceCommentId'] = source_comment_id
        if source_comment_url:
            entry['sourceCommentUrl'] = source_comment_url
        if conflict_fix_count:
            entry['conflictFixCount'] = conflict_fix_count
    tasks.append(entry)

    with open(tasks_file, 'w') as f:
        json.dump(tasks, f, indent=2)
        f.write('\n')
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
" "$TASKS_FILE" "$LOCK_FILE" "$TASK_ID" "$BRANCH" "$AGENT" "$TMUX_SESSION" "$STARTED_AT" "$WORKTREE_DIR" "$LOG_FILE" "$TASK_PHASE" "$MAX_ITERATIONS" "$TASK_DESCRIPTION" "$PRODUCT_GOAL" "$USER_REQUEST" "$WORKSPACE" "$PARENT_TASK_ID"

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
