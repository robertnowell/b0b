#!/usr/bin/env bash
# kill-task.sh — Kill a task: set to failed, terminate any running agent
# Usage: ./kill-task.sh <task-id> [--reason "why"]

set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/notify.sh"

TASK_ID="${1:?Usage: kill-task.sh <task-id> [--reason 'why']}"
shift
REASON=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reason) REASON="$2"; shift 2 ;;
    *) echo "ERROR: Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Read task and mark as failed
TMUX_SESSION=$(python3 -c "
import json, sys, fcntl
tasks_file, lock_file, task_id, reason = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
fd = open(lock_file, 'w')
fcntl.flock(fd, fcntl.LOCK_EX)
try:
    with open(tasks_file) as f:
        tasks = json.load(f)
    task = next((t for t in tasks if t['id'] == task_id), None)
    if not task:
        print('ERROR:not_found')
        sys.exit(0)
    tmux = task.get('tmuxSession', '')
    task['phase'] = 'failed'
    task['status'] = 'failed'
    import datetime
    task['completedAt'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
    task.setdefault('findings', []).append(f'Task killed: {reason or \"no reason given\"}')
    with open(tasks_file, 'w') as f:
        json.dump(tasks, f, indent=2)
        f.write('\n')
    print(tmux)
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    fd.close()
" "$TASKS_FILE" "$LOCK_FILE" "$TASK_ID" "$REASON")

if [[ "$TMUX_SESSION" == "ERROR:not_found" ]]; then
  echo "ERROR: Task $TASK_ID not found" >&2
  exit 1
fi

# Kill tmux session if it exists
if [ -n "$TMUX_SESSION" ]; then
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null && echo "Killed tmux session: $TMUX_SESSION" || true
fi

notify --task-id "$TASK_ID" --phase "failed" \
  --message "Task killed. Reason: ${REASON:-none given}"

echo "Task $TASK_ID killed."
