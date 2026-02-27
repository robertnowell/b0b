#!/usr/bin/env bash
# cleanup-worktrees.sh — Remove completed worktrees and update task registry
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASKS_FILE="${REPO_ROOT}/.clawdbot/active-tasks.json"
WORKTREE_BASE="${REPO_ROOT}/../kopi-worktrees"
LOCK_FILE="${REPO_ROOT}/.clawdbot/.tasks.lock"

if [ ! -f "$TASKS_FILE" ]; then
  exit 0
fi

python3 -c "
import json, os, subprocess, sys, fcntl

repo_root = sys.argv[1]
tasks_file = sys.argv[2]
worktree_base = sys.argv[3]
lock_file = sys.argv[4]

lock_fd = open(lock_file, 'w')
fcntl.flock(lock_fd, fcntl.LOCK_EX)
try:
    with open(tasks_file) as f:
        tasks = json.load(f)

    active = []
    for task in tasks:
        if task.get('status') in ('done', 'merged', 'failed', 'succeeded', 'unknown'):
            tid = task['id']
            worktree = task.get('worktree', os.path.join(worktree_base, tid))
            tmux = task.get('tmuxSession', f'agent-{tid}')

            # Kill tmux if still running
            subprocess.run(['tmux', 'kill-session', '-t', tmux], capture_output=True)

            # Remove worktree
            if os.path.exists(worktree):
                subprocess.run(['git', 'worktree', 'remove', worktree, '--force'],
                             capture_output=True, cwd=repo_root)
                print(f'Cleaned up: {tid}')
        else:
            active.append(task)

    with open(tasks_file, 'w') as f:
        json.dump(active, f, indent=2)
        f.write('\n')
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
" "$REPO_ROOT" "$TASKS_FILE" "$WORKTREE_BASE" "$LOCK_FILE"
