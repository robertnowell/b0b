#!/usr/bin/env bash
# check-agents.sh — Check status of all active coding agents
# Reads active-tasks.json and checks:
#   - tmux session alive?
#   - Agent exit code (success/failure)
#   - Task timeout?
#   - PR created?
#   - CI status?
# Outputs structured JSON status report and writes status back to active-tasks.json

set -euo pipefail

# Source shared config
# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

if [ ! -f "$TASKS_FILE" ]; then
  echo '{"tasks":[],"summary":{"total":0,"running":0,"succeeded":0,"failed":0}}'
  exit 0
fi

python3 -c "
import json, sys, subprocess, os, fcntl
from datetime import datetime, timezone

repo_root = sys.argv[1]
tasks_file = sys.argv[2]
lock_file = sys.argv[3]
max_runtime = int(sys.argv[4])
def get_task_repo(task):
    return repo_root

lock_fd = open(lock_file, 'w')
fcntl.flock(lock_fd, fcntl.LOCK_EX)
try:
    with open(tasks_file) as f:
        try:
            tasks = json.load(f)
        except (json.JSONDecodeError, ValueError):
            tasks = []

    if not tasks:
        print(json.dumps({'tasks':[],'summary':{'total':0,'running':0,'succeeded':0,'failed':0}}))
        sys.exit(0)

    results = []
    counts = {'running': 0, 'succeeded': 0, 'failed': 0, 'unknown': 0}
    now = datetime.now(timezone.utc)

    for task in tasks:
      try:
        tid = task.get('id', 'unknown')
        tmux = task.get('tmuxSession', f'agent-{tid}')
        branch = task.get('branch', '')
        agent = task.get('agent', 'unknown')
        started = task.get('startedAt', '')
        logfile = task.get('logFile', '')

        phase = task.get('phase', 'implementing')
        iteration = task.get('iteration', 0)
        max_iter = task.get('maxIterations', int(sys.argv[5]))
        product_goal = task.get('productGoal', '')
        description = task.get('description', '')
        findings = task.get('findings', [])

        result = {
            'id': tid,
            'agent': agent,
            'branch': branch,
            'startedAt': started,
            'tmuxSession': tmux,
            'phase': phase,
            'iteration': iteration,
            'maxIterations': max_iter,
            'productGoal': product_goal,
            'description': description,
            'findings': findings,
        }

        # Check tmux session
        rc = subprocess.run(['tmux', 'has-session', '-t', tmux], capture_output=True).returncode
        tmux_alive = rc == 0
        result['tmuxAlive'] = tmux_alive

        # Check log for exit signals
        agent_done = False
        exit_status = None
        fail_reason = None
        last_lines = []
        if logfile and os.path.exists(logfile):
            with open(logfile) as f:
                lines = f.readlines()
                last_lines = [l.strip() for l in lines[-5:]] if lines else []
                for line in reversed(lines):
                    line = line.strip()
                    if line == 'AGENT_EXIT_SUCCESS':
                        exit_status = 'success'
                        break
                    elif line.startswith('AGENT_EXIT_FAIL:'):
                        exit_status = 'fail'
                        result['exitCode'] = line.split(':',1)[1] if ':' in line else 'unknown'
                        break
                    elif line == 'AGENT_FAIL:deps_install':
                        exit_status = 'fail'
                        fail_reason = 'deps_install'
                        break
                agent_done = any('AGENT_DONE' in l for l in last_lines)

        result['agentDone'] = agent_done
        result['exitStatus'] = exit_status

        # Check for timeout
        timed_out = False
        if started and tmux_alive and exit_status is None:
            try:
                start_dt = datetime.fromisoformat(started.replace('Z', '+00:00'))
                elapsed = (now - start_dt).total_seconds()
                if elapsed > max_runtime:
                    timed_out = True
                    subprocess.run(['tmux', 'kill-session', '-t', tmux], capture_output=True)
                    fail_reason = 'timeout'
            except (ValueError, TypeError):
                pass

        # Derive effective status
        if timed_out:
            effective = 'failed'
        elif exit_status == 'success':
            effective = 'succeeded'
        elif exit_status == 'fail':
            effective = 'failed'
            if fail_reason is None:
                fail_reason = 'agent_error'
        elif not tmux_alive and not agent_done:
            effective = 'unknown'
        elif tmux_alive:
            effective = 'running'
        else:
            effective = 'unknown'

        result['status'] = effective
        if fail_reason:
            result['failReason'] = fail_reason
        counts[effective] = counts.get(effective, 0) + 1
        result['lastLog'] = last_lines[-1] if last_lines else None

        # Compute age and elapsed time
        elapsed_seconds = None
        age_str = ''
        if started:
            try:
                start_dt = datetime.fromisoformat(started.replace('Z', '+00:00'))
                elapsed = (now - start_dt).total_seconds()
                elapsed_seconds = int(elapsed)
                if elapsed < 60:
                    age_str = f'{int(elapsed)}s'
                elif elapsed < 3600:
                    age_str = f'{int(elapsed // 60)}m'
                elif elapsed < 86400:
                    h, m = int(elapsed // 3600), int((elapsed % 3600) // 60)
                    age_str = f'{h}h {m}m'
                else:
                    d, h = int(elapsed // 86400), int((elapsed % 86400) // 3600)
                    age_str = f'{d}d {h}h'
            except (ValueError, TypeError):
                pass
        result['age'] = age_str
        result['elapsedSeconds'] = elapsed_seconds

        # Check for PR
        if branch:
            try:
                task_repo = get_task_repo(task)
                pr_result = subprocess.run(
                    ['gh', 'pr', 'list', '--head', branch, '--json', 'number,state,statusCheckRollup', '--limit', '1'],
                    capture_output=True, text=True, cwd=task_repo
                )
                if pr_result.returncode == 0 and pr_result.stdout.strip() not in ('', '[]'):
                    pr_data = json.loads(pr_result.stdout)
                    if pr_data:
                        pr = pr_data[0]
                        result['pr'] = {
                            'number': pr['number'],
                            'state': pr['state'],
                        }
                        checks = pr.get('statusCheckRollup') or []
                        if checks:
                            result['pr']['checks'] = [
                                {'name': c.get('name',''), 'conclusion': c.get('conclusion', c.get('state', '?'))}
                                for c in checks
                            ]
            except (json.JSONDecodeError, KeyError, IndexError, TypeError):
                pass

        # Write back status to the task entry
        task['status'] = effective
        if fail_reason:
            task['failReason'] = fail_reason
        elif 'failReason' in task:
            # Clear stale failReason when transitioning to a non-failed state
            del task['failReason']
        if effective in ('succeeded', 'failed', 'unknown') and 'completedAt' not in task:
            task['completedAt'] = now.strftime('%Y-%m-%dT%H:%M:%SZ')

        results.append(result)

      except Exception as e:
        # One bad task shouldn't kill the whole report
        results.append({
            'id': task.get('id', 'unknown'),
            'status': 'unknown',
            'error': str(e),
        })
        counts['unknown'] = counts.get('unknown', 0) + 1

    # Write updated tasks back to file
    with open(tasks_file, 'w') as f:
        json.dump(tasks, f, indent=2)
        f.write('\n')
finally:
    fcntl.flock(lock_fd, fcntl.LOCK_UN)
    lock_fd.close()

output = {
    'tasks': results,
    'summary': {
        'total': len(results),
        **counts
    }
}
print(json.dumps(output, indent=2))
" "$REPO_ROOT" "$TASKS_FILE" "$LOCK_FILE" "$MAX_RUNTIME_SECONDS" "$MAX_ITERATIONS"
