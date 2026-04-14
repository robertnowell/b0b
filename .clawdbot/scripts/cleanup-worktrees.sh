#!/usr/bin/env bash
# cleanup-worktrees.sh — Remove completed worktrees and update task registry
set -euo pipefail

# Source shared config
# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

if [ ! -f "$TASKS_FILE" ]; then
  exit 0
fi

python3 -c "
import json, os, subprocess, sys, fcntl

workspace_repo_path = sys.argv[1]
tasks_file = sys.argv[2]
worktree_base = sys.argv[3]
lock_file = sys.argv[4]
def get_task_repo(task):
    return workspace_repo_path

ws = os.environ.get('B0B_WORKSPACE', 'default')

lock_fd = open(lock_file, 'w')
fcntl.flock(lock_fd, fcntl.LOCK_EX)
try:
    with open(tasks_file) as f:
        tasks = json.load(f)

    active = []
    for task in tasks:
        if task.get('status') in ('merged', 'abandoned', 'split'):
            tid = task['id']
            worktree = task.get('worktree', os.path.join(worktree_base, tid))
            # Fallback matches spawn-agent.sh:70 workspace-prefixed convention.
            tmux = task.get('tmuxSession', f'agent-{ws}-{tid}')

            # Kill tmux if still running
            subprocess.run(['tmux', 'kill-session', '-t', tmux], capture_output=True)

            # Remove worktree
            if os.path.exists(worktree):
                task_repo = get_task_repo(task)
                subprocess.run(['git', 'worktree', 'remove', worktree, '--force'],
                             capture_output=True, cwd=task_repo)
                print(f'Cleaned up: {tid}')
        else:
            active.append(task)

    with open(tasks_file, 'w') as f:
        json.dump(active, f, indent=2)
        f.write('\n')

    # Advance local main to match origin/main (ff-only so it's safe).
    # This is the PRODUCT repo, not the b0b scripts repo.
    subprocess.run(['git', 'fetch', 'origin', 'main'], capture_output=True, cwd=workspace_repo_path)
    result = subprocess.run(
        ['git', 'merge', '--ff-only', 'origin/main'],
        capture_output=True, text=True, cwd=workspace_repo_path
    )
    if result.returncode == 0 and 'Already up to date' not in result.stdout:
        print(f'Advanced local main: {result.stdout.strip()}')
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()
" "$WORKSPACE_REPO_PATH" "$TASKS_FILE" "$WORKTREE_BASE" "$LOCK_FILE"
