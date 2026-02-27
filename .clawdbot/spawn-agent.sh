#!/usr/bin/env bash
# spawn-agent.sh — Spawn a coding agent in a worktree with tmux
# Usage: ./spawn-agent.sh <task-id> <branch-name> <agent: codex|claude> <prompt-file> [model]
#
# Example:
#   ./spawn-agent.sh feat-templates feat/custom-templates codex /tmp/prompt-templates.md
#   ./spawn-agent.sh fix-button fix/button-style claude /tmp/prompt-button.md claude-opus-4-6

set -euo pipefail

TASK_ID="${1:?Usage: spawn-agent.sh <task-id> <branch> <agent> <prompt-file> [model]}"
BRANCH="${2:?Missing branch name}"
AGENT="${3:?Missing agent (codex|claude)}"
PROMPT_FILE="${4:?Missing prompt file path}"
MODEL="${5:-}"

# Validate inputs to prevent injection and path traversal
[[ "$TASK_ID" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo "ERROR: Invalid task ID (must start with alphanumeric, only [a-zA-Z0-9._-] allowed)"; exit 1; }
[[ "$BRANCH" =~ ^[a-zA-Z0-9._/-]+$ ]] || { echo "ERROR: Invalid branch name (only [a-zA-Z0-9._/-] allowed)"; exit 1; }
[[ "$AGENT" =~ ^(codex|claude)$ ]] || { echo "ERROR: Unknown agent: $AGENT (use codex or claude)"; exit 1; }
if [ -n "$MODEL" ]; then
  [[ "$MODEL" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "ERROR: Invalid model name (only [a-zA-Z0-9._-] allowed)"; exit 1; }
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKTREE_DIR="${REPO_ROOT}/../kopi-worktrees/${TASK_ID}"
TMUX_SESSION="agent-${TASK_ID}"
LOG_DIR="${REPO_ROOT}/.clawdbot/logs"
LOG_FILE="${LOG_DIR}/agent-${TASK_ID}.log"
TASKS_FILE="${REPO_ROOT}/.clawdbot/active-tasks.json"
LOCK_FILE="${REPO_ROOT}/.clawdbot/.tasks.lock"

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
  printf 'AGENT_WORKTREE_DIR=%q\n' "$WORKTREE_DIR"
  printf 'AGENT_LOG_FILE=%q\n' "$LOG_FILE"
  printf 'AGENT_PROMPT_FILE=%q\n' "$PROMPT_FILE"
  printf 'AGENT_TYPE=%q\n' "$AGENT"
  printf 'AGENT_MODEL=%q\n' "${MODEL:-claude-opus-4-6}"
  cat <<'SCRIPT_BODY'
cd "$AGENT_WORKTREE_DIR"
if ! pnpm install --frozen-lockfile 2>&1 | tee -a "$AGENT_LOG_FILE"; then
  echo 'AGENT_FAIL:deps_install' >> "$AGENT_LOG_FILE"
  echo 'AGENT_DONE' >> "$AGENT_LOG_FILE"
  exit 1
fi
echo '=== DEPS INSTALLED ===' >> "$AGENT_LOG_FILE"
if [ "$AGENT_TYPE" = "codex" ]; then
  ${CODEX_PATH:-codex} exec --dangerously-bypass-approvals-and-sandbox < "$AGENT_PROMPT_FILE" 2>&1 | tee -a "$AGENT_LOG_FILE"
elif [ "$AGENT_TYPE" = "claude" ]; then
  ${CLAUDE_PATH:-claude} --model "$AGENT_MODEL" --dangerously-skip-permissions -p - < "$AGENT_PROMPT_FILE" 2>&1 | tee -a "$AGENT_LOG_FILE"
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
lock_file = sys.argv[9]
entry = {
    'id': sys.argv[2],
    'branch': sys.argv[3],
    'agent': sys.argv[4],
    'tmuxSession': sys.argv[5],
    'status': 'running',
    'startedAt': sys.argv[6],
    'worktree': sys.argv[7],
    'logFile': sys.argv[8]
}

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

    # Remove any existing entry with same id
    tasks = [t for t in tasks if t.get('id') != entry['id']]
    tasks.append(entry)

    with open(tasks_file, 'w') as f:
        json.dump(tasks, f, indent=2)
        f.write('\n')
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
" "$TASKS_FILE" "$TASK_ID" "$BRANCH" "$AGENT" "$TMUX_SESSION" "$STARTED_AT" "$WORKTREE_DIR" "$LOG_FILE" "$LOCK_FILE"

echo "Spawned $AGENT agent"
echo "  Task:     $TASK_ID"
echo "  Branch:   $BRANCH"
echo "  tmux:     $TMUX_SESSION"
echo "  Worktree: $WORKTREE_DIR"
echo "  Logs:     $LOG_FILE"
