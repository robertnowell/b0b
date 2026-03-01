#!/usr/bin/env bash
# monitor.sh — Pipeline brain that advances tasks through phases
# Run every 5 minutes (launchd). Idempotent — safe to run repeatedly.
#
# For each active task, checks status and decides what to do:
#   planning + succeeded   → plan_review (if requiresPlanReview) or implementing
#   implementing + succeeded → audit
#   auditing + succeeded     → check result → fixing or testing
#   fixing + succeeded       → re-audit or re-test (based on fixTarget)
#   testing + succeeded      → check result → pr_creating or fixing
#   pr_creating + succeeded  → reviewing
#   failed (any phase)       → respawn or auto-revert based on iteration count
#   timeout                  → kill and treat as failed

set -euo pipefail

# Source shared config
# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTIFY="${SCRIPT_DIR}/notify.sh"
SPAWN="${SCRIPT_DIR}/spawn-agent.sh"
CHECK="${SCRIPT_DIR}/check-agents.sh"
FILL_TEMPLATE="${SCRIPT_DIR}/fill-template.sh"

mkdir -p "$LOG_DIR"
MONITOR_LOG="${LOG_DIR}/monitor.log"

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$MONITOR_LOG"
}

log "=== Monitor run started ==="

# Step 1: Run check-agents.sh and capture JSON
CHECK_OUTPUT=$("$CHECK" 2>/dev/null) || {
  log "ERROR: check-agents.sh failed"
  exit 1
}

# Step 2: Process each task with the state machine
python3 -c "
import json, sys, subprocess, os, fcntl

script_dir = sys.argv[1]
tasks_file = sys.argv[2]
lock_file = sys.argv[3]
repo_root = sys.argv[4]
worktree_base = sys.argv[5]
max_iterations = int(sys.argv[6])
notify = sys.argv[7]
spawn = sys.argv[8]
log_dir = sys.argv[9]
fill_template = sys.argv[10]
plans_dir = sys.argv[11]
workspace_repo = sys.argv[12]
workspace_worktree_base = sys.argv[13]

check_output = json.loads(sys.stdin.read())

# Minimal environment for subprocess calls to avoid ARG_MAX from env bloat
_clean_env = {k: v for k, v in os.environ.items()
              if k in ('PATH', 'HOME', 'USER', 'SHELL', 'TERM', 'LANG', 'LC_ALL',
                        'SLACK_WEBHOOK_URL', 'CLAWDBOT_SLACK_WEBHOOK', 'GITHUB_TOKEN',
                        'GH_TOKEN', 'TMPDIR')}

def get_task_repo(task):
    return workspace_repo if task.get('workspace') else repo_root

def get_task_worktree_base(task):
    return workspace_worktree_base if task.get('workspace') else worktree_base

def run_notify(task_id, phase, message, product_goal='', next_step='', started_at=''):
    \"\"\"Send a Slack notification. Pipes message via stdin to avoid ARG_MAX.\"\"\"
    # Auto-lookup startedAt from task_map if not explicitly provided
    if not started_at and task_id in task_map:
        started_at = task_map[task_id].get('startedAt', '')
    cmd = [notify, '--task-id', task_id, '--phase', phase, '--message', '-']
    if product_goal:
        cmd += ['--product-goal', product_goal]
    if next_step:
        cmd += ['--next', next_step]
    if started_at:
        cmd += ['--started-at', started_at]
    subprocess.run(cmd, input=message, capture_output=True, text=True, env=_clean_env)

def read_tasks():
    \"\"\"Read tasks from JSON with flock.\"\"\"
    fd = open(lock_file, 'w')
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        if os.path.exists(tasks_file):
            with open(tasks_file) as f:
                try:
                    return json.load(f)
                except (json.JSONDecodeError, ValueError):
                    return []
        return []
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        fd.close()

def apply_updates(task_id, updates):
    \"\"\"Atomically read-modify-write a single task's fields.\"\"\"
    fd = open(lock_file, 'w')
    fcntl.flock(fd, fcntl.LOCK_EX)
    try:
        if os.path.exists(tasks_file):
            with open(tasks_file) as f:
                try:
                    tasks_data = json.load(f)
                except (json.JSONDecodeError, ValueError):
                    tasks_data = []
        else:
            tasks_data = []
        for t in tasks_data:
            if t.get('id') == task_id:
                t.update(updates)
                break
        with open(tasks_file, 'w') as f:
            json.dump(tasks_data, f, indent=2)
            f.write('\n')
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        fd.close()

def get_audit_result(task):
    \"\"\"Parse the agent's log for structured AUDIT_VERDICT line.\"\"\"
    log_file = task.get('logFile', '')
    if not log_file or not os.path.exists(log_file):
        return 'unknown', 'No log file found'

    with open(log_file) as f:
        content = f.read()

    # Look for structured verdict line: AUDIT_VERDICT:PASS or AUDIT_VERDICT:FAIL
    verdict = None
    for line in reversed(content.split('\n')):
        stripped = line.strip()
        if stripped.startswith('AUDIT_VERDICT:'):
            verdict = stripped.split(':', 1)[1].strip().lower()
            break

    # Extract findings summary from the tail
    tail = content[-2000:] if len(content) > 2000 else content
    findings_summary = ''
    for line in tail.split('\n'):
        stripped = line.strip()
        if stripped and not stripped.startswith('AGENT_') and not stripped.startswith('AUDIT_VERDICT:'):
            findings_summary = stripped

    if verdict == 'pass':
        return 'pass', findings_summary
    elif verdict == 'fail':
        return 'fail', findings_summary
    else:
        # No structured verdict found - treat as fail for safety
        return 'fail', findings_summary or 'No structured AUDIT_VERDICT found in output'

def get_test_result(task):
    \"\"\"Parse the agent's log for structured TEST_VERDICT line.\"\"\"
    log_file = task.get('logFile', '')
    if not log_file or not os.path.exists(log_file):
        return 'unknown', 'No log file found'

    with open(log_file) as f:
        content = f.read()

    # Look for structured verdict line: TEST_VERDICT:PASS or TEST_VERDICT:FAIL
    verdict = None
    for line in reversed(content.split('\n')):
        stripped = line.strip()
        if stripped.startswith('TEST_VERDICT:'):
            verdict = stripped.split(':', 1)[1].strip().lower()
            break

    # Extract summary from the tail
    tail = content[-2000:] if len(content) > 2000 else content
    findings_summary = ''
    for line in tail.split('\n'):
        stripped = line.strip()
        if stripped and not stripped.startswith('AGENT_') and not stripped.startswith('TEST_VERDICT:'):
            findings_summary = stripped

    if verdict == 'pass':
        return 'pass', findings_summary
    elif verdict == 'fail':
        return 'fail', findings_summary
    else:
        # No structured verdict found - treat as fail for safety
        return 'fail', findings_summary or 'No structured TEST_VERDICT found in output'

def choose_audit_agent(impl_agent):
    \"\"\"The agent that implements never audits its own work.\"\"\"
    return 'claude' if impl_agent == 'codex' else 'codex'

def get_plan_result(task):
    \"\"\"Parse the plan file for PLAN_VERDICT line.

    Looks for plan at worktree root (plan.md), then legacy path.
    Copies found plan to PLANS_DIR for persistence.
    Returns (status, summary, content, plan_dest_path).
    \"\"\"
    import shutil
    tid = task.get('id', '')
    task_wb = get_task_worktree_base(task)
    worktree = task.get('worktree', os.path.join(task_wb, tid))

    # Look for plan at worktree root first, then legacy .clawdbot/plans/ path
    plan_paths = [
        os.path.join(worktree, 'plan.md'),
        os.path.join(worktree, '.clawdbot', 'plans', f'{tid}.md'),
    ]

    plan_path = None
    for p in plan_paths:
        if os.path.exists(p):
            plan_path = p
            break

    if plan_path is None:
        return 'not_ready', 'No plan file found', '', ''

    with open(plan_path) as f:
        content = f.read()

    # Look for PLAN_VERDICT:READY in plan file
    verdict = None
    for line in reversed(content.split('\n')):
        stripped = line.strip()
        if stripped.startswith('PLAN_VERDICT:'):
            verdict = stripped.split(':', 1)[1].strip().upper()
            break

    # Also check agent log for the verdict (agent may output it there)
    log_file = task.get('logFile', '')
    if verdict is None and log_file and os.path.exists(log_file):
        with open(log_file) as f:
            log_content = f.read()
        for line in reversed(log_content.split('\n')):
            stripped = line.strip()
            if stripped.startswith('PLAN_VERDICT:'):
                verdict = stripped.split(':', 1)[1].strip().upper()
                break

    # Extract summary (first 500 chars of plan)
    summary = content[:500].replace('\n', ' ').strip()

    # Copy plan to PLANS_DIR for persistence
    os.makedirs(plans_dir, exist_ok=True)
    dest = os.path.join(plans_dir, f'{tid}.md')
    shutil.copy2(plan_path, dest)

    if verdict == 'READY':
        return 'ready', summary, content, dest
    else:
        return 'not_ready', summary or 'Plan not marked as ready', content, dest

def phase_to_template(phase):
    \"\"\"Map a phase to its prompt template file.\"\"\"
    mapping = {
        'planning': 'plan.md',
        'implementing': 'implement.md',
        'auditing': 'audit.md',
        'fixing': 'fix-feedback.md',
        'testing': 'test.md',
        'pr_creating': 'create-pr.md',
    }
    return mapping.get(phase, 'implement.md')

def spawn_agent(task, phase, prompt_template, agent_override=None):
    \"\"\"Spawn an agent for the next phase. Uses fill-template.sh for prompt generation.\"\"\"
    import time as _time
    tid = task['id']
    branch = task['branch']
    agent = agent_override or task.get('agent', 'claude')
    description = task.get('description', '')
    product_goal = task.get('productGoal', '')
    task_wb = get_task_worktree_base(task)
    worktree = task.get('worktree', os.path.join(task_wb, tid))

    # Build prompt file path
    prompts_dir_local = os.path.join(os.path.dirname(script_dir), 'prompts')
    prompt_path = os.path.join(prompts_dir_local, prompt_template)
    if not os.path.exists(prompt_path):
        print(f'WARNING: Prompt template not found: {prompt_path}')
        return False

    # Build PLAN: use planContent if available, git diff for audit phases, description otherwise
    plan_text = task.get('planContent', '') or description
    if phase in ('auditing', 'testing') and worktree and os.path.isdir(worktree):
        diff_result = subprocess.run(
            ['git', 'diff', 'main...HEAD'],
            capture_output=True, text=True, cwd=worktree)
        if diff_result.returncode == 0 and diff_result.stdout.strip():
            plan_text = diff_result.stdout
        else:
            print(f'WARNING: git diff empty/failed for {tid}, falling back to description')

    # Build feedback text: for fixing phase, use full audit log (last 200 lines)
    findings = task.get('findings', [])
    feedback_text = '\n'.join(f'- {f}' for f in findings) if findings else 'No previous findings.'
    if phase == 'fixing':
        log_file = task.get('logFile', '')
        if log_file and os.path.exists(log_file):
            with open(log_file) as lf:
                log_lines = lf.readlines()
            # Use last 200 lines of audit log for full context
            tail_lines = log_lines[-200:] if len(log_lines) > 200 else log_lines
            feedback_text = ''.join(tail_lines)

    # Fill template in-process (avoids ARG_MAX/E2BIG when plan/diff/feedback are large)
    import re as _re
    try:
        with open(prompt_path) as _pf:
            prompt_content = _pf.read()
    except OSError as e:
        print(f'WARNING: Could not read prompt template {prompt_path}: {e}')
        return False

    _vars = {
        'TASK_DESCRIPTION': description,
        'PRD': product_goal,
        'PLAN': plan_text,
        'DELIVERABLES': description,
        'FEEDBACK': feedback_text,
        'FEATURE': description,
        'DESCRIPTION': description,
        'PRODUCT_GOAL': product_goal,
        'DIFF': plan_text,
        'TASK_ID': tid,
    }
    for _k, _v in _vars.items():
        prompt_content = prompt_content.replace('{' + _k + '}', _v)

    _unresolved = _re.findall(r'\{([A-Za-z_][A-Za-z0-9_]*)\}', prompt_content)
    for _u in _unresolved:
        print(f'WARNING: unresolved placeholder {{{_u}}} in {prompt_path}', file=sys.stderr)

    # Add iteration context if we have findings
    if findings:
        iteration = task.get('iteration', 0)
        findings_text = '\n'.join(f'- Iteration {i+1}: {f}' for i, f in enumerate(findings))
        prompt_content += f'\n\n## Previous Iteration Findings (iteration {iteration})\n{findings_text}\n'
        prompt_content += '\nAddress the issues from previous iterations.\n'

    # Write the filled prompt — include timestamp to avoid collisions on concurrent runs
    prompt_file = os.path.join(log_dir, f'prompt-{tid}-{phase}-{int(_time.time())}.md')
    with open(prompt_file, 'w') as f:
        f.write(prompt_content)

    cmd = [
        spawn, tid, branch, agent, prompt_file,
        '',  # model (use default)
        '--phase', phase,
        '--description', description,
        '--product-goal', product_goal,
    ]
    if task.get('workspace'):
        cmd.append('--workspace')
    task_repo = get_task_repo(task)
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=task_repo)
    if result.returncode != 0:
        print(f'WARNING: Failed to spawn agent for {tid}: {result.stderr}')
        return False
    return True

def auto_revert(task):
    \"\"\"Revert a task's worktree branch to origin/main.\"\"\"
    worktree = task.get('worktree', '')
    if worktree and os.path.exists(worktree):
        subprocess.run(['git', 'reset', '--hard', 'origin/main'], cwd=worktree, capture_output=True)
        print(f'Reverted worktree for {task[\"id\"]}')

    # Kill tmux session
    tmux = task.get('tmuxSession', f'agent-{task[\"id\"]}')
    subprocess.run(['tmux', 'kill-session', '-t', tmux], capture_output=True)

def cleanup_dead_agent(task):
    \"\"\"Kill zombie tmux session and remove stale wrapper script.\"\"\"
    tmux = task.get('tmuxSession', f'agent-{task[\"id\"]}')
    subprocess.run(['tmux', 'kill-session', '-t', tmux], capture_output=True)

    # Remove the wrapper script if it exists
    wrapper = f'/tmp/agent-{task[\"id\"]}-run.sh'
    if os.path.exists(wrapper):
        os.remove(wrapper)

def get_superseding_task(tid, all_tasks):
    \"\"\"Check if another active task makes this dead task redundant.

    1. Explicit 'supersededBy' field on the task.
    2. Convention: same base name (stripping -vN suffix), other task is alive.
    \"\"\"
    import re as _re

    # 1. Explicit supersededBy field
    for t in all_tasks:
        if t.get('id') == tid:
            if t.get('supersededBy'):
                return t['supersededBy']

    # 2. Convention: same base name, other task is not failed/needs_split
    match = _re.match(r'^(.*?)(?:-v(\d+))?$', tid)
    if not match:
        return None
    base = match.group(1)

    terminal_phases = {'failed', 'needs_split'}
    for t in all_tasks:
        other_id = t.get('id', '')
        if other_id == tid:
            continue
        other_match = _re.match(r'^(.*?)(?:-v(\d+))?$', other_id)
        if not other_match:
            continue
        other_base = other_match.group(1)

        # Same base, other task is still alive (not failed/needs_split)
        if other_base == base and t.get('phase', '') not in terminal_phases:
            return other_id

    return None

# --- Main state machine ---
# Pattern: read snapshot for decisions, call spawn (which writes its own entry),
# then use apply_updates() to re-read fresh JSON and apply monitor-specific fields.

tasks = read_tasks()
task_map = {r['id']: r for r in check_output.get('tasks', [])}
changes_made = 0

for task in tasks:
    tid = task.get('id', '')
    if not tid:
        continue

    report = task_map.get(tid)
    if not report:
        continue

    status = report.get('status', '')
    phase = task.get('phase', 'implementing')
    iteration = task.get('iteration', 0)
    max_iter = task.get('maxIterations', max_iterations)
    product_goal = task.get('productGoal', '')
    description = task.get('description', '')

    # Skip tasks that are already terminal or parked (plan_review is a human gate)
    if phase in ('merged', 'needs_split', 'plan_review'):
        continue

    # Race guard: skip if another monitor run acted on this task within 60s
    import time as _time
    last_action = task.get('lastMonitorAction', 0)
    now = int(_time.time())
    if now - last_action < 60 and phase not in ('reviewing', 'pr_ready'):
        continue

    # --- Handle reviewing (independent of status) ---
    if phase == 'reviewing':
        branch = task.get('branch', '')
        pr_number = None
        ci_pass = False
        if branch:
            task_repo = get_task_repo(task)
            pr_result = subprocess.run(
                ['gh', 'pr', 'list', '--head', branch, '--state', 'open', '--json', 'number,statusCheckRollup', '--limit', '1'],
                capture_output=True, text=True, cwd=task_repo)
            if pr_result.returncode == 0 and pr_result.stdout.strip():
                prs = json.loads(pr_result.stdout)
                if prs:
                    pr_number = prs[0].get('number')
                    checks = prs[0].get('statusCheckRollup', [])
                    ci_pass = checks and all((c.get('conclusion') or c.get('state', '')).upper() == 'SUCCESS' for c in checks)
        if pr_number and ci_pass:
            apply_updates(tid, {'phase': 'pr_ready', 'status': 'pr_ready', 'prNumber': pr_number})
            run_notify(tid, 'pr_ready',
                f'PR #{pr_number} passed CI — ready for human review',
                product_goal,
                'Merge when ready')
            changes_made += 1
        # If no PR or CI not passing yet, stay in reviewing (wait for next cycle)
        continue

    # --- Handle pr_ready: poll for actual merge ---
    if phase == 'pr_ready':
        branch = task.get('branch', '')
        task_repo = get_task_repo(task)
        pr_number = task.get('prNumber')

        # Backfill PR number for tasks created before prNumber tracking existed.
        if not pr_number and branch:
            pr_result = subprocess.run(
                ['gh', 'pr', 'list', '--head', branch, '--state', 'open', '--json', 'number', '--limit', '1'],
                capture_output=True, text=True, cwd=task_repo)
            if pr_result.returncode == 0 and pr_result.stdout.strip():
                prs = json.loads(pr_result.stdout)
                if prs:
                    pr_number = prs[0].get('number')
                    apply_updates(tid, {'prNumber': pr_number})
                    changes_made += 1

        if pr_number:
            pr_state_result = subprocess.run(
                ['gh', 'pr', 'view', str(pr_number), '--json', 'state'],
                capture_output=True, text=True, cwd=task_repo)
            if pr_state_result.returncode == 0 and pr_state_result.stdout.strip():
                pr_state = json.loads(pr_state_result.stdout).get('state', '')
                if str(pr_state).upper() == 'MERGED':
                    apply_updates(tid, {'phase': 'merged', 'status': 'merged'})
                    run_notify(tid, 'merged',
                        f'PR #{pr_number} has been merged',
                        product_goal,
                        'Done')
                    changes_made += 1
        # If not yet merged, stay in pr_ready (wait for next cycle)
        continue

    # Only stamp and act if the task needs action (not just running)
    needs_action = (status in ('timeout', 'failed', 'succeeded', 'unknown')
                    or report.get('failReason') == 'timeout')
    if needs_action:
        apply_updates(tid, {'lastMonitorAction': now})

    # --- Handle timeout ---
    if status == 'timeout' or report.get('failReason') == 'timeout':
        iteration += 1
        new_findings = task.get('findings', []) + [f'Timed out during {phase}']
        if iteration >= max_iter:
            auto_revert(task)
            apply_updates(tid, {
                'phase': 'needs_split',
                'status': 'needs_split',
                'iteration': iteration,
                'findings': new_findings + [f'Max iterations reached'],
            })
            run_notify(tid, 'needs_split',
                f'Task exceeded {max_iter} iterations without converging. Reverted. Needs manual split.',
                product_goal,
                'Needs manual split into subtasks')
        else:
            run_notify(tid, phase,
                f'Agent timed out during {phase}. Respawning (iteration {iteration}/{max_iter})',
                product_goal,
                f'Respawning in {phase} phase')
            task['iteration'] = iteration
            task['findings'] = new_findings
            ok = spawn_agent(task, phase, phase_to_template(phase), task.get('agent'))
            if ok:
                apply_updates(tid, {
                    'iteration': iteration,
                    'findings': new_findings,
                })
            else:
                print(f'ERROR: spawn failed for {tid} during timeout respawn')
                run_notify(tid, phase, f'Spawn failed during timeout respawn', product_goal)
        changes_made += 1
        continue

    # --- Handle failures ---
    if status == 'failed':
        fail_reason = report.get('failReason', 'unknown')
        iteration += 1
        new_findings = task.get('findings', []) + [f'Failed during {phase}: {fail_reason}']
        if iteration >= max_iter:
            auto_revert(task)
            apply_updates(tid, {
                'phase': 'needs_split',
                'status': 'needs_split',
                'iteration': iteration,
                'findings': new_findings + [f'Max iterations reached'],
            })
            run_notify(tid, 'needs_split',
                f'Task exceeded {max_iter} iterations without converging. Reverted. Needs manual split.',
                product_goal,
                'Needs manual split into subtasks')
        else:
            run_notify(tid, phase,
                f'Agent failed during {phase}: {fail_reason}. Respawning (iteration {iteration}/{max_iter})',
                product_goal,
                f'Respawning in {phase} phase')
            task['iteration'] = iteration
            task['findings'] = new_findings
            ok = spawn_agent(task, phase, phase_to_template(phase), task.get('agent'))
            if ok:
                apply_updates(tid, {
                    'iteration': iteration,
                    'findings': new_findings,
                })
            else:
                print(f'ERROR: spawn failed for {tid} during failure respawn')
                run_notify(tid, phase, f'Spawn failed during failure respawn', product_goal)
        changes_made += 1
        continue

    # --- Handle unknown status (tmux gone, no exit signal) ---
    # First check for success artifacts; only treat as failure if no output found.
    if status == 'unknown':
        # Only act on active phases
        if phase not in ('planning', 'implementing', 'auditing', 'fixing',
                          'testing', 'pr_creating'):
            continue

        # Before assuming failure, check if the agent actually completed its work.
        # tmux exiting without AGENT_EXIT_SUCCESS can happen when the wrapper script
        # is missing or the agent process exits cleanly but skips the exit signal.
        agent_actually_succeeded = False
        if phase == 'planning':
            plan_status, _, _, _ = get_plan_result(task)
            if plan_status == 'ready':
                agent_actually_succeeded = True
        elif phase in ('implementing', 'fixing'):
            # Check if there are new commits on the branch since task started
            task_wb = get_task_worktree_base(task)
            worktree = task.get('worktree', os.path.join(task_wb, tid))
            if os.path.isdir(worktree):
                result = subprocess.run(
                    ['git', 'log', '--oneline', '-1', '--since=1 hour ago'],
                    capture_output=True, text=True, cwd=worktree)
                if result.returncode == 0 and result.stdout.strip():
                    agent_actually_succeeded = True
        elif phase == 'auditing':
            audit_result, _ = get_audit_result(task)
            if audit_result in ('pass', 'fail'):
                # Audit produced a result (pass or fail) — agent completed
                agent_actually_succeeded = True
        elif phase == 'testing':
            # Check if test results exist
            task_wb = get_task_worktree_base(task)
            worktree = task.get('worktree', os.path.join(task_wb, tid))
            test_report = os.path.join(worktree, 'test-results.md')
            if os.path.exists(test_report):
                agent_actually_succeeded = True
        elif phase == 'pr_creating':
            # Check if a PR was actually created
            branch = task.get('branch', '')
            if branch:
                task_repo = get_task_repo(task)
                pr_result = subprocess.run(
                    ['gh', 'pr', 'list', '--head', branch, '--state', 'open', '--json', 'number', '--limit', '1'],
                    capture_output=True, text=True, cwd=task_repo)
                if pr_result.returncode == 0 and pr_result.stdout.strip():
                    prs = json.loads(pr_result.stdout)
                    if prs:
                        agent_actually_succeeded = True

        if agent_actually_succeeded:
            # Agent completed successfully but exited without proper signal.
            # Reclassify as succeeded and let the success handler process it.
            print(f'[monitor] {tid}: tmux gone but {phase} artifacts found — treating as success')
            status = 'succeeded'
            # Fall through to the succeeded handler below

        else:
            # Genuinely dead — proceed with existing dead-agent handling
            respawn_count = task.get('respawnCount', 0)
            max_respawns = 2

            # Check if this task is superseded by a newer version
            superseded_by = get_superseding_task(tid, tasks)
            if superseded_by:
                cleanup_dead_agent(task)
                apply_updates(tid, {
                    'phase': 'failed',
                    'status': 'failed',
                    'failReason': f'superseded by {superseded_by}',
                })
                run_notify(tid, 'failed',
                    f'Agent exited unexpectedly and superseded by \`{superseded_by}\`. Marked as failed.',
                    product_goal,
                    'No action needed — newer task exists')
                changes_made += 1
                continue

            # Check respawn budget
            if respawn_count >= max_respawns:
                cleanup_dead_agent(task)
                new_findings = task.get('findings', []) + [
                    f'Agent exited unexpectedly {respawn_count + 1} times during {phase} — giving up'
                ]
                apply_updates(tid, {
                    'phase': 'failed',
                    'status': 'failed',
                    'respawnCount': respawn_count + 1,
                    'findings': new_findings,
                    'failReason': 'max_respawns_exceeded',
                })
                run_notify(tid, 'failed',
                    f'Agent exited unexpectedly {respawn_count + 1} times during {phase}. Max respawns exceeded.',
                    product_goal,
                    'Needs manual investigation')
                changes_made += 1
                continue

            # Validate worktree before respawn
            task_wb = get_task_worktree_base(task)
            worktree = task.get('worktree', os.path.join(task_wb, tid))
            if not os.path.isdir(worktree):
                cleanup_dead_agent(task)
                apply_updates(tid, {
                    'phase': 'failed',
                    'status': 'failed',
                    'failReason': 'worktree_missing',
                    'findings': task.get('findings', []) + [
                        f'Agent exited unexpectedly during {phase} and worktree is missing'
                    ],
                })
                run_notify(tid, 'failed',
                    f'Agent exited unexpectedly and worktree is missing. Cannot respawn.',
                    product_goal,
                    'Needs manual re-dispatch')
                changes_made += 1
                continue

            # Respawn the agent
            cleanup_dead_agent(task)
            respawn_count += 1
            run_notify(tid, phase,
                f'Agent exited unexpectedly during {phase}. Respawning (attempt {respawn_count}/{max_respawns})',
                product_goal,
                f'Respawning in {phase} phase')

            # For auditing phase, use the cross-agent logic
            agent_override = task.get('agent')
            if phase == 'auditing':
                agent_override = choose_audit_agent(task.get('agent', 'claude'))

            ok = spawn_agent(task, phase, phase_to_template(phase), agent_override)
            if ok:
                apply_updates(tid, {
                    'respawnCount': respawn_count,
                })
            else:
                print(f'ERROR: spawn failed for {tid} during dead-agent respawn')
                run_notify(tid, phase, f'Spawn failed during dead-agent respawn', product_goal)
            changes_made += 1
            continue

    # --- Handle succeeded ---
    if status == 'succeeded':

        if phase == 'planning':
            # Check plan output and decide: plan_review gate or auto-advance
            plan_status, plan_summary, plan_content, plan_file = get_plan_result(task)
            if plan_status == 'ready':
                requires_review = task.get('requiresPlanReview', True)
                if requires_review:
                    # Human gate — park in plan_review
                    apply_updates(tid, {
                        'phase': 'plan_review',
                        'status': 'plan_review',
                        'planFile': plan_file,
                        'planContent': plan_content,
                    })
                    # Build full plan notification for #project-kopi-claw
                    plan_notify_text = (
                        f'Plan ready for review. Run approve-plan.sh {tid} to proceed.\n\n'
                        f'---\n\n'
                        f'{plan_content[:3800]}'
                    )
                    if len(plan_content) > 3800:
                        plan_notify_text += f'\n\n_(truncated — full plan in {plan_file})_'
                    run_notify(tid, 'plan_review',
                        plan_notify_text,
                        product_goal,
                        'Awaiting human plan approval')
                else:
                    # Auto-advance — no human gate
                    task['planContent'] = plan_content
                    run_notify(tid, 'implementing',
                        f'Plan auto-approved (requiresPlanReview=false). Starting implementation.',
                        product_goal,
                        'Starting implementation')
                    ok = spawn_agent(task, 'implementing', 'implement.md', task.get('agent'))
                    if ok:
                        apply_updates(tid, {
                            'phase': 'implementing',
                            'status': 'running',
                            'planContent': plan_content,
                            'planFile': plan_file,
                        })
                    else:
                        print(f'ERROR: spawn failed for {tid} during planning->implementing')
                        run_notify(tid, phase, f'Failed to spawn implementation agent', product_goal)
            else:
                # Plan not ready — send back to planning
                iteration += 1
                new_findings = task.get('findings', []) + [f'Plan #{iteration}: not ready - {plan_summary[:200]}']
                if iteration >= max_iter:
                    auto_revert(task)
                    apply_updates(tid, {
                        'phase': 'needs_split',
                        'status': 'needs_split',
                        'iteration': iteration,
                        'findings': new_findings + [f'Max iterations reached during planning'],
                    })
                    run_notify(tid, 'needs_split',
                        f'Task exceeded {max_iter} iterations without producing a ready plan. Needs manual split.',
                        product_goal,
                        'Needs manual split into subtasks')
                else:
                    run_notify(tid, 'planning',
                        f'Plan not ready. Respawning planning agent (iteration {iteration}/{max_iter})',
                        product_goal,
                        f'Re-planning (iteration {iteration}/{max_iter})')
                    task['iteration'] = iteration
                    task['findings'] = new_findings
                    ok = spawn_agent(task, 'planning', 'plan.md', task.get('agent'))
                    if ok:
                        apply_updates(tid, {
                            'iteration': iteration,
                            'findings': new_findings,
                        })
                    else:
                        print(f'ERROR: spawn failed for {tid} during plan_review->planning')
                        run_notify(tid, phase, f'Failed to spawn planning agent', product_goal)
            changes_made += 1

        elif phase == 'implementing':
            # Advance to auditing
            audit_agent = choose_audit_agent(task.get('agent', 'claude'))
            run_notify(tid, 'auditing',
                f'Implementation complete. Spawning {audit_agent} audit agent.',
                product_goal,
                'Running code audit')
            ok = spawn_agent(task, 'auditing', 'audit.md', audit_agent)
            if ok:
                apply_updates(tid, {'phase': 'auditing', 'status': 'running'})
            else:
                print(f'ERROR: spawn failed for {tid} during implementing->auditing')
                run_notify(tid, phase, f'Failed to spawn audit agent', product_goal)
            changes_made += 1

        elif phase == 'auditing':
            # Check audit result
            audit_result, audit_summary = get_audit_result(task)
            new_findings = task.get('findings', []) + [f'Audit #{iteration + 1}: {audit_summary}']

            if audit_result == 'pass':
                # Advance to testing
                run_notify(tid, 'testing',
                    f'Audit passed. Running tests.',
                    product_goal,
                    'Running tests and validation')
                ok = spawn_agent(task, 'testing', 'test.md', task.get('agent'))
                if ok:
                    apply_updates(tid, {
                        'phase': 'testing',
                        'status': 'running',
                        'findings': new_findings,
                    })
                else:
                    print(f'ERROR: spawn failed for {tid} during auditing->testing')
                    run_notify(tid, phase, f'Failed to spawn testing agent', product_goal)
            else:
                # Send back for fixes
                iteration += 1
                if iteration >= max_iter:
                    auto_revert(task)
                    apply_updates(tid, {
                        'phase': 'needs_split',
                        'status': 'needs_split',
                        'iteration': iteration,
                        'findings': new_findings + [f'Max iterations reached with unresolved audit issues'],
                    })
                    run_notify(tid, 'needs_split',
                        f'Task exceeded {max_iter} iterations without converging. Reverted. Needs manual split.',
                        product_goal,
                        'Needs manual split into subtasks')
                else:
                    run_notify(tid, 'fixing',
                        f'Audit found issues: {audit_summary}. Sending back for fixes (iteration {iteration}/{max_iter})',
                        product_goal,
                        f'Fixing audit feedback (iteration {iteration}/{max_iter})')
                    task['iteration'] = iteration
                    task['findings'] = new_findings
                    ok = spawn_agent(task, 'fixing', 'fix-feedback.md', task.get('agent'))
                    if ok:
                        apply_updates(tid, {
                            'phase': 'fixing',
                            'status': 'running',
                            'iteration': iteration,
                            'findings': new_findings,
                            'fixTarget': 'auditing',
                        })
                    else:
                        print(f'ERROR: spawn failed for {tid} during auditing->fixing')
                        run_notify(tid, phase, f'Failed to spawn fix agent', product_goal)
            changes_made += 1

        elif phase == 'testing':
            # Check test result
            test_result, test_summary = get_test_result(task)
            new_findings = task.get('findings', []) + [f'Test #{iteration + 1}: {test_summary}']

            if test_result == 'pass':
                # Advance to PR creation
                run_notify(tid, 'pr_creating',
                    f'Tests passed. Creating PR.',
                    product_goal,
                    'Creating pull request')
                ok = spawn_agent(task, 'pr_creating', 'create-pr.md', task.get('agent'))
                if ok:
                    apply_updates(tid, {
                        'phase': 'pr_creating',
                        'status': 'running',
                        'findings': new_findings,
                    })
                else:
                    print(f'ERROR: spawn failed for {tid} during testing->pr_creating')
                    run_notify(tid, phase, f'Failed to spawn PR creation agent', product_goal)
            else:
                # Send back for fixes
                iteration += 1
                if iteration >= max_iter:
                    auto_revert(task)
                    apply_updates(tid, {
                        'phase': 'needs_split',
                        'status': 'needs_split',
                        'iteration': iteration,
                        'findings': new_findings + [f'Max iterations reached with unresolved test failures'],
                    })
                    run_notify(tid, 'needs_split',
                        f'Task exceeded {max_iter} iterations without converging. Reverted. Needs manual split.',
                        product_goal,
                        'Needs manual split into subtasks')
                else:
                    run_notify(tid, 'fixing',
                        f'Tests failed: {test_summary}. Sending back for fixes (iteration {iteration}/{max_iter})',
                        product_goal,
                        f'Fixing test failures (iteration {iteration}/{max_iter})')
                    task['iteration'] = iteration
                    task['findings'] = new_findings
                    ok = spawn_agent(task, 'fixing', 'fix-feedback.md', task.get('agent'))
                    if ok:
                        apply_updates(tid, {
                            'phase': 'fixing',
                            'status': 'running',
                            'iteration': iteration,
                            'findings': new_findings,
                            'fixTarget': 'testing',
                        })
                    else:
                        print(f'ERROR: spawn failed for {tid} during testing->fixing')
                        run_notify(tid, phase, f'Failed to spawn fix agent', product_goal)
            changes_made += 1

        elif phase == 'fixing':
            # Route back to auditing or testing based on fixTarget
            fix_target = task.get('fixTarget', 'auditing')
            if fix_target == 'testing':
                run_notify(tid, 'testing',
                    f'Fixes applied. Re-running tests (iteration {iteration}/{max_iter})',
                    product_goal,
                    f'Running tests #{iteration + 1}')
                ok = spawn_agent(task, 'testing', 'test.md', task.get('agent'))
                if ok:
                    apply_updates(tid, {'phase': 'testing', 'status': 'running'})
                else:
                    print(f'ERROR: spawn failed for {tid} during fixing->testing')
                    run_notify(tid, phase, f'Failed to spawn testing agent', product_goal)
            else:
                audit_agent = choose_audit_agent(task.get('agent', 'claude'))
                run_notify(tid, 'auditing',
                    f'Fixes applied. Re-running audit (iteration {iteration}/{max_iter})',
                    product_goal,
                    f'Running audit #{iteration + 1}')
                ok = spawn_agent(task, 'auditing', 'audit.md', audit_agent)
                if ok:
                    apply_updates(tid, {'phase': 'auditing', 'status': 'running'})
                else:
                    print(f'ERROR: spawn failed for {tid} during fixing->auditing')
                    run_notify(tid, phase, f'Failed to spawn audit agent', product_goal)
            changes_made += 1

        elif phase == 'pr_creating':
            # Capture PR number immediately so it's available for all downstream phases
            branch = task.get('branch', '')
            pr_number = None
            if branch:
                task_repo = get_task_repo(task)
                pr_result = subprocess.run(
                    ['gh', 'pr', 'list', '--head', branch, '--state', 'all', '--json', 'number', '--limit', '1'],
                    capture_output=True, text=True, cwd=task_repo)
                if pr_result.returncode == 0 and pr_result.stdout.strip():
                    prs = json.loads(pr_result.stdout)
                    if prs:
                        pr_number = prs[0].get('number')

            # Advance to reviewing
            updates = {'phase': 'reviewing', 'status': 'reviewing'}
            if pr_number:
                updates['prNumber'] = pr_number
            apply_updates(tid, updates)

            pr_label = f' (PR #{pr_number})' if pr_number else ''
            run_notify(tid, 'reviewing',
                f'PR created{pr_label}. Awaiting review.',
                product_goal,
                'Awaiting human review')
            changes_made += 1

    # running tasks in non-terminal phases: no action needed (wait for completion)

print(json.dumps({'processed': len(task_map), 'changes_made': changes_made}, indent=2))
" "$SCRIPT_DIR" "$TASKS_FILE" "$LOCK_FILE" "$REPO_ROOT" "$WORKTREE_BASE" "$MAX_ITERATIONS" "$NOTIFY" "$SPAWN" "$LOG_DIR" "$FILL_TEMPLATE" "$PLANS_DIR" "$WORKSPACE_REPO" "$WORKSPACE_WORKTREE_BASE" <<< "$CHECK_OUTPUT"

log "=== Monitor run completed ==="
