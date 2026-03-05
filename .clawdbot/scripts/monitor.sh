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

# Step 1.5: Process new GitHub comments → auto-dispatch
GH_DISPATCH="${SCRIPT_DIR}/gh-comment-dispatch.sh"
if [ -x "$GH_DISPATCH" ]; then
  log "Running gh-comment-dispatch..."
  "$GH_DISPATCH" 2>&1 | while IFS= read -r line; do log "[gh-dispatch] $line"; done || log "WARNING: gh-comment-dispatch failed"
fi

# Step 2: Process each task with the state machine
python3 -c "
import json, sys, subprocess, os, fcntl, re, datetime

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
max_auto_retries = int(sys.argv[12])
max_split_depth = int(sys.argv[13])
max_auto_split_attempts = int(sys.argv[14])

check_output = json.loads(sys.stdin.read())

# Minimal environment for subprocess calls to avoid ARG_MAX from env bloat
_clean_env = {k: v for k, v in os.environ.items()
              if k in ('PATH', 'HOME', 'USER', 'SHELL', 'TERM', 'LANG', 'LC_ALL',
                        'SLACK_BOT_TOKEN', 'GITHUB_TOKEN',
                        'GH_TOKEN', 'TMPDIR', 'CLAWDBOT_STATE_DIR')}

def get_task_repo(task):
    return repo_root

def get_task_worktree_base(task):
    return worktree_base

def run_notify(task_id, phase, message, product_goal='', next_step='', started_at='', plan_file=''):
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
    if plan_file:
        cmd += ['--plan-file', plan_file]
    subprocess.run(cmd, input=message, capture_output=True, text=True, env=_clean_env)

def _get_last_spawn_meta(tid, phase):
    \"\"\"Read the last spawn_agent entry for this task+phase from transitions JSONL.\"\"\"
    jsonl_path = os.path.join(log_dir, f'transitions-{tid}.jsonl')
    if not os.path.exists(jsonl_path):
        return {}
    last = {}
    try:
        with open(jsonl_path) as f:
            for line in f:
                try:
                    e = json.loads(line)
                    if e.get('event') == 'spawn_agent' and e.get('phase') == phase:
                        last = e
                except json.JSONDecodeError:
                    continue
    except OSError:
        pass
    return last

def log_transition(task, from_phase, to_phase, verdict='', structured_findings=None,
                   iteration=None, feedback_source='', feedback_size=0,
                   prompt_template='', prompt_file='', prompt_size=0, plan_size=0,
                   extra=None):
    \"\"\"Write a JSONL transition entry and return a formatted Slack message.\"\"\"
    import time as _time
    tid = task.get('id', '')
    started_at = task.get('startedAt', '')
    elapsed = ''
    if started_at:
        try:
            from datetime import datetime, timezone
            start_dt = datetime.fromisoformat(started_at.replace('Z', '+00:00'))
            elapsed_s = int((_time.time() - start_dt.timestamp()))
            elapsed = f'{elapsed_s // 60}m {elapsed_s % 60}s'
        except (ValueError, TypeError):
            pass

    sf = structured_findings or {}
    iter_num = iteration if iteration is not None else task.get('iteration', 0)
    max_iter = task.get('maxIterations', max_iterations)

    # Auto-populate input sizes from last spawn event if not explicitly provided
    _spawn = _get_last_spawn_meta(tid, from_phase)
    if _spawn:
        if not prompt_size:
            prompt_size = _spawn.get('prompt_size_bytes', 0)
        if not plan_size:
            plan_size = _spawn.get('plan_size_bytes', 0)
        if not feedback_size:
            feedback_size = _spawn.get('feedback_size_bytes', 0)

    entry = {
        'task_id': tid,
        'from_phase': from_phase,
        'to_phase': to_phase,
        'timestamp': _time.strftime('%Y-%m-%dT%H:%M:%SZ', _time.gmtime()),
        'iteration': iter_num,
        'max_iterations': max_iter,
        'verdict': verdict,
        'structured_findings': sf,
        'input': {
            'prompt_template': prompt_template,
            'prompt_file': prompt_file,
            'prompt_size_bytes': prompt_size,
            'plan_size_bytes': plan_size,
            'image_count': len(task.get('imageFiles', [])),
            'image_files': task.get('imageFiles', []),
            'user_request_size_bytes': len(task.get('userRequest', '')),
        },
        'context_forwarded': {
            'feedback_source': feedback_source,
            'feedback_size_bytes': feedback_size,
            'findings_carried': len(task.get('findings', [])),
        },
    }
    if extra:
        entry.update(extra)

    transitions_file = os.path.join(log_dir, f'transitions-{tid}.jsonl')
    try:
        with open(transitions_file, 'a') as tf:
            tf.write(json.dumps(entry) + '\\n')
    except OSError as e:
        print(f'WARNING: Could not write transition log for {tid}: {e}')

    return format_transition_slack(entry, elapsed)

def format_transition_slack(entry, elapsed=''):
    \"\"\"Format a transition log entry into an enriched Slack notification.\"\"\"
    from_p = entry.get('from_phase', '?')
    to_p = entry.get('to_phase', '?')
    iter_num = entry.get('iteration', 0)
    max_iter = entry.get('max_iterations', 0)
    verdict = entry.get('verdict', '')
    sf = entry.get('structured_findings', {})
    inp = entry.get('input', {})
    ctx = entry.get('context_forwarded', {})

    # Line 1: compact transition summary (task_id already in notify header)
    line1 = f'{from_p} → {to_p} | iter {iter_num}/{max_iter}'
    if elapsed:
        line1 += f' | {elapsed}'
    lines = [line1]

    # Input summary
    input_parts = []
    if inp.get('prompt_size_bytes'):
        input_parts.append(f'prompt ({inp[\"prompt_size_bytes\"] / 1024:.1f}kb)')
    if inp.get('plan_size_bytes'):
        input_parts.append(f'plan ({inp[\"plan_size_bytes\"] / 1024:.1f}kb)')
    ur_size = inp.get('user_request_size_bytes', 0)
    if ur_size:
        input_parts.append(f'user_request ({ur_size / 1024:.1f}kb)')
    elif inp.get('prompt_template', '') not in ('plan.md', 'review-plan.md', ''):
        input_parts.append('user_request (MISSING)')
    if ctx.get('feedback_size_bytes'):
        input_parts.append(f'feedback ({ctx[\"feedback_size_bytes\"] / 1024:.1f}kb)')
    if ctx.get('findings_carried'):
        input_parts.append(f'{ctx[\"findings_carried\"]} findings')
    img_count = inp.get('image_count', 0)
    if img_count:
        input_parts.append(f'{img_count} images')
    if input_parts:
        lines.append('📥 Input: ' + ' + '.join(input_parts))

    # Verdict + finding counts on one line
    if verdict:
        _pass = 'PASS'
        _fail = 'FAIL'
        v_line = f'📤 {_pass if verdict.lower() == _pass.lower() else _fail}'
        if sf:
            cc = sf.get('critical_count')
            mc = sf.get('minor_count')
            if cc is not None or mc is not None:
                v_line += f' — {cc or 0} critical, {mc or 0} minor'
        lines.append(v_line)

    # Structured findings detail (indented under verdict)
    if sf:
        missing = sf.get('missing', [])
        if missing:
            lines.append(f'  Missing: ' + ', '.join(missing[:5]))
        summary = sf.get('summary', '')
        if summary:
            lines.append(f'  {summary[:300]}')
        tp = sf.get('tests_passed')
        bp = sf.get('build_passed')
        if tp is not None or bp is not None:
            s_parts = []
            if tp is not None:
                s_parts.append(f'tests={\"pass\" if tp else \"fail\"}')
            if bp is not None:
                s_parts.append(f'build={\"pass\" if bp else \"fail\"}')
            lines.append(f'  Status: ' + ', '.join(s_parts))

    # Context forwarded
    if ctx.get('feedback_source'):
        lines.append(f'Context → {to_p}: via {ctx[\"feedback_source\"]}')

    if inp.get('prompt_template'):
        lines.append(f'Template: {inp[\"prompt_template\"]}')

    return '\\n'.join(lines)

# --- API issue detection ---
_API_ISSUE_PATTERNS = [
    (re.compile(r'hit your.*(limit|quota)', re.IGNORECASE), 'rate_limit'),
    (re.compile(r'rate.limit', re.IGNORECASE), 'rate_limit'),
    (re.compile(r'usage.limit', re.IGNORECASE), 'rate_limit'),
    (re.compile(r'exceeded.*quota', re.IGNORECASE), 'rate_limit'),
    (re.compile(r'invalid.*api.key', re.IGNORECASE), 'invalid_key'),
    (re.compile(r'api.key.*invalid', re.IGNORECASE), 'invalid_key'),
    (re.compile(r'unauthorized|authentication.*fail', re.IGNORECASE), 'auth_error'),
    (re.compile(r'temporarily limited.*(?:suspicious|cybersecurity)', re.IGNORECASE), 'account_blocked'),
    (re.compile(r'access.*(?:blocked|suspended|disabled)', re.IGNORECASE), 'account_blocked'),
]

def detect_api_issue(text):
    \"\"\"Check if text contains an API infrastructure issue. Returns (issue_type, matched_text) or None.\"\"\"
    for pattern, issue_type in _API_ISSUE_PATTERNS:
        m = pattern.search(text)
        if m:
            return issue_type, m.group(0)
    return None

def check_and_alert_api_issues(task, new_finding=''):
    \"\"\"Scan task findings for API issues and send a dedicated alert if not already alerted.\"\"\"
    if task.get('apiIssueAlerted'):
        return None
    # Check new finding, all findings, and log file tail
    texts_to_check = []
    if new_finding:
        texts_to_check.append(new_finding)
    texts_to_check.extend(task.get('findings', []))
    # Also check log file tail for errors not captured in findings
    log_file = task.get('logFile', '')
    if log_file and os.path.exists(log_file):
        try:
            with open(log_file) as f:
                content = f.read()
            texts_to_check.append(content[-2000:] if len(content) > 2000 else content)
        except (IOError, OSError):
            pass
    for text in texts_to_check:
        result = detect_api_issue(text)
        if result:
            issue_type, matched = result
            tid = task.get('id', '?')
            agent = task.get('agent', '?')
            issue_labels = {'rate_limit': 'Rate limit hit', 'invalid_key': 'Invalid API key', 'auth_error': 'Authentication error', 'account_blocked': 'Account blocked/suspended'}
            issue_label = issue_labels.get(issue_type, issue_type)
            product_goal = task.get('productGoal', '')
            alert_msg = (
                f'\U0001f6a8 *API Issue Detected*\\n'
                f'*Task:* {tid}\\n'
                f'*Agent:* {agent}\\n'
                f'*Issue:* {issue_label}\\n'
                f'*Error:* \"{matched}\"\\n'
                f'*Action needed:* Check API quota/key for {agent}'
            )
            run_notify(tid, task.get('phase', 'failed'), alert_msg, product_goal,
                       next_step=f'Manual intervention: check {agent} API access')
            apply_updates(tid, {'apiIssueAlerted': True, 'apiIssueType': issue_type})
            task['apiIssueAlerted'] = True
            return issue_type
    return None

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

def extract_structured_verdict(content, verdict_key):
    \"\"\"Extract PASS/FAIL from a structured verdict line, allowing light formatting wrappers.\"\"\"
    pattern = re.compile(rf'\\b{re.escape(verdict_key)}\\s*:\\s*(PASS|FAIL)\\b', re.IGNORECASE)
    for line in reversed(content.split('\n')):
        match = pattern.search(line.strip())
        if match:
            return match.group(1).lower()
    return None

def extract_findings_block(content, block_key):
    \"\"\"Extract structured findings from a delimited block (e.g. AUDIT_FINDINGS_START/END).
    Returns a dict with parsed fields, or empty dict if block not found.\"\"\"
    start_tag = f'{block_key}_START'
    end_tag = f'{block_key}_END'
    start_idx = content.rfind(start_tag)
    if start_idx == -1:
        return {}
    end_idx = content.find(end_tag, start_idx)
    if end_idx == -1:
        return {}
    block = content[start_idx + len(start_tag):end_idx].strip()
    result = {}
    for line in block.split('\n'):
        line = line.strip()
        if ':' in line:
            key, _, value = line.partition(':')
            key = key.strip().lower()
            value = value.strip()
            if key in ('critical', 'minor'):
                try:
                    result[key + '_count'] = int(value)
                except ValueError:
                    result[key + '_count'] = 0
            elif key == 'missing':
                if value.lower() == 'none':
                    result['missing'] = []
                else:
                    result['missing'] = [m.strip() for m in value.split(',') if m.strip()]
            elif key == 'summary':
                result['summary'] = value
            elif key in ('tests_passed', 'build_passed', 'lint_passed'):
                result[key] = value.lower().startswith('yes')
    return result

def get_audit_result(task):
    \"\"\"Parse the agent's log for structured AUDIT_VERDICT and AUDIT_FINDINGS block.
    Returns (verdict, summary, findings_dict).\"\"\"
    log_file = task.get('logFile', '')
    if not log_file or not os.path.exists(log_file):
        return 'unknown', 'No log file found', {}

    with open(log_file) as f:
        content = f.read()

    verdict = extract_structured_verdict(content, 'AUDIT_VERDICT')
    findings = extract_findings_block(content, 'AUDIT_FINDINGS')

    # Use structured summary if available, else fall back to last non-agent line
    if findings.get('summary'):
        findings_summary = findings['summary']
    else:
        tail = content[-2000:] if len(content) > 2000 else content
        findings_summary = ''
        for line in tail.split('\n'):
            stripped = line.strip()
            if stripped and not stripped.startswith('AGENT_') and 'AUDIT_VERDICT:' not in stripped.upper():
                findings_summary = stripped

    if verdict == 'pass':
        return 'pass', findings_summary, findings
    elif verdict == 'fail':
        return 'fail', findings_summary, findings
    else:
        return 'fail', findings_summary or 'No structured AUDIT_VERDICT found in output', findings

def get_test_result(task):
    \"\"\"Parse the agent's log for structured TEST_VERDICT and TEST_FINDINGS block.
    Returns (verdict, summary, findings_dict).\"\"\"
    log_file = task.get('logFile', '')
    if not log_file or not os.path.exists(log_file):
        return 'unknown', 'No log file found', {}

    with open(log_file) as f:
        content = f.read()

    verdict = extract_structured_verdict(content, 'TEST_VERDICT')
    findings = extract_findings_block(content, 'TEST_FINDINGS')

    if findings.get('summary'):
        findings_summary = findings['summary']
    else:
        tail = content[-2000:] if len(content) > 2000 else content
        findings_summary = ''
        for line in tail.split('\n'):
            stripped = line.strip()
            if stripped and not stripped.startswith('AGENT_') and 'TEST_VERDICT:' not in stripped.upper():
                findings_summary = stripped

    if verdict == 'pass':
        return 'pass', findings_summary, findings
    elif verdict == 'fail':
        return 'fail', findings_summary, findings
    else:
        return 'fail', findings_summary or 'No structured TEST_VERDICT found in output', findings

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
            ['git', 'diff', 'origin/main...HEAD'],
            capture_output=True, text=True, cwd=worktree)
        if diff_result.returncode == 0 and diff_result.stdout.strip():
            plan_text = diff_result.stdout
        else:
            print(f'WARNING: git diff empty/failed for {tid}, falling back to description')

    # Build feedback text: for fixing phase, prepend structured assessment then raw log tail
    findings = task.get('findings', [])
    feedback_text = '\n'.join(f'- {f}' for f in findings) if findings else 'No previous findings.'
    if phase == 'fixing':
        structured = task.get('lastStructuredFindings', {})
        structured_header = ''
        if structured:
            parts = []
            cc = structured.get('critical_count')
            mc = structured.get('minor_count')
            if cc is not None or mc is not None:
                parts.append(f'Issues: {cc or 0} critical, {mc or 0} minor')
            missing = structured.get('missing', [])
            if missing:
                parts.append('Missing:\\n' + '\\n'.join(f'- {m}' for m in missing))
            summary = structured.get('summary', '')
            if summary:
                parts.append(f'Assessment: {summary}')
            tp = structured.get('tests_passed')
            bp = structured.get('build_passed')
            lp = structured.get('lint_passed')
            if tp is not None or bp is not None or lp is not None:
                status_parts = []
                if tp is not None:
                    status_parts.append(f'tests={\"pass\" if tp else \"fail\"}')
                if bp is not None:
                    status_parts.append(f'build={\"pass\" if bp else \"fail\"}')
                if lp is not None:
                    status_parts.append(f'lint={\"pass\" if lp else \"fail\"}')
                parts.append('Status: ' + ', '.join(status_parts))
            if parts:
                structured_header = '## Structured Assessment Summary\\n' + '\\n'.join(parts) + '\\n\\n'

        log_file = task.get('logFile', '')
        if log_file and os.path.exists(log_file):
            with open(log_file) as lf:
                log_lines = lf.readlines()
            tail_lines = log_lines[-200:] if len(log_lines) > 200 else log_lines
            feedback_text = structured_header + '## Raw Log (last 200 lines)\\n' + ''.join(tail_lines)
        elif structured_header:
            feedback_text = structured_header

    # Fill template in-process (avoids ARG_MAX/E2BIG when plan/diff/feedback are large)
    import re as _re
    try:
        with open(prompt_path) as _pf:
            prompt_content = _pf.read()
    except OSError as e:
        print(f'WARNING: Could not read prompt template {prompt_path}: {e}')
        return False

    # Build images instruction from task.imageFiles
    _image_files = task.get('imageFiles', [])
    if _image_files and isinstance(_image_files, list):
        _images_text = 'Visual context from the original request. Read these image files to see screenshots:\\n' + '\\n'.join(f'- {p}' for p in _image_files)
    else:
        _images_text = ''

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
        'IMAGES': _images_text,
        'USER_REQUEST': task.get('userRequest', '') or 'No original request provided. Base your plan strictly on the task description and product goal. Do NOT add scope beyond what is explicitly described.',
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

    # Log spawn input context to transition JSONL
    _spawn_entry = {
        'event': 'spawn_agent',
        'task_id': tid,
        'phase': phase,
        'timestamp': _time.strftime('%Y-%m-%dT%H:%M:%SZ', _time.gmtime()),
        'agent': agent,
        'prompt_template': prompt_template,
        'prompt_file': prompt_file,
        'prompt_size_bytes': len(prompt_content),
        'plan_size_bytes': len(plan_text),
        'feedback_size_bytes': len(feedback_text),
        'findings_count': len(findings),
        'image_count': len(task.get('imageFiles', [])),
        'user_request_size_bytes': len(task.get('userRequest', '')),
        'iteration': task.get('iteration', 0),
    }
    _transitions_file = os.path.join(log_dir, f'transitions-{tid}.jsonl')
    try:
        with open(_transitions_file, 'a') as _tf:
            _tf.write(json.dumps(_spawn_entry) + '\\n')
    except OSError:
        pass

    cmd = [
        spawn, tid, branch, agent, prompt_file,
        '',  # model (use default)
        '--phase', phase,
        '--description', description,
        '--product-goal', product_goal,
    ]
    task_repo = get_task_repo(task)
    result = subprocess.run(cmd, capture_output=True, text=True, cwd=task_repo)
    if result.returncode != 0:
        print(f'WARNING: Failed to spawn agent for {tid}: {result.stderr}')
        return False
    return True

def auto_revert(task):
    \"\"\"Remove a task's worktree and branch for a completely clean restart.\"\"\"
    tmux = task.get('tmuxSession', f'agent-{task[\"id\"]}')
    subprocess.run(['tmux', 'kill-session', '-t', tmux], capture_output=True)

    worktree = task.get('worktree', '')
    branch = task.get('branch', '')
    task_repo = get_task_repo(task)

    if worktree and os.path.exists(worktree):
        subprocess.run(['git', 'worktree', 'remove', '--force', worktree],
                       capture_output=True, cwd=task_repo)

    if branch:
        subprocess.run(['git', 'branch', '-D', branch],
                       capture_output=True, cwd=task_repo)
        if not task.get('prNumber'):
            subprocess.run(['git', 'push', 'origin', '--delete', branch],
                           capture_output=True, cwd=task_repo)

    print(f'Cleaned up worktree and branch for {task[\"id\"]}')

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
    2. Explicit 'parentTaskId' linkage (phase check only).
    3. Convention: same base name (-vN suffix), higher version, at least as advanced phase.
    \"\"\"
    import re as _re

    PHASE_ORDER = ['planning', 'plan_review', 'implementing', 'auditing',
                   'fixing', 'testing', 'pr_creating', 'reviewing',
                   'pr_ready', 'merged']

    def phase_rank(phase):
        try:
            return PHASE_ORDER.index(phase)
        except ValueError:
            return -1

    # Compatibility note: \"needs_split\" is legacy; \"split\" replaced it.
    terminal_phases = {'failed', 'needs_split', 'split'}

    # Find our own task to get our phase
    my_task = None
    for t in all_tasks:
        if t.get('id') == tid:
            my_task = t
            break

    # 1. Explicit supersededBy field
    if my_task and my_task.get('supersededBy'):
        return my_task['supersededBy']

    my_phase = my_task.get('phase', '') if my_task else ''
    my_rank = phase_rank(my_phase)

    # 2. Convention: same base name, other task is still active
    match = _re.match(r'^(.*?)(?:-v(\d+))?$', tid)
    if not match:
        return None
    base = match.group(1)
    my_version = int(match.group(2)) if match.group(2) else 0

    best_candidate = None
    best_score = None
    for t in all_tasks:
        other_id = t.get('id', '')
        if other_id == tid:
            continue

        # Skip terminal tasks — they're broken, not superseding
        if t.get('phase', '') in terminal_phases:
            continue

        # Determine relationship: explicit child->parent linkage or same base name
        is_linked = (t.get('parentTaskId') == tid)

        other_match = _re.match(r'^(.*?)(?:-v(\d+))?$', other_id)
        if not other_match:
            continue
        other_base = other_match.group(1)
        is_same_base = (other_base == base)

        if not is_linked and not is_same_base:
            continue

        # Version check: only for same-base tasks (not parentTaskId-linked)
        # parentTaskId linkage is explicit — the child is the intended successor
        if is_same_base and not is_linked:
            other_version = int(other_match.group(2)) if other_match.group(2) else 0
            if other_version <= my_version:
                continue

        # Phase check: superseder must be at least as far along
        other_rank = phase_rank(t.get('phase', ''))
        if other_rank < my_rank:
            continue

        score = (other_rank, int(other_match.group(2)) if other_match.group(2) else 0)
        if best_score is None or score > best_score:
            best_candidate = other_id
            best_score = score

    return best_candidate

# --- Main state machine ---
# Pattern: read snapshot for decisions, call spawn (which writes its own entry),
# then use apply_updates() to re-read fresh JSON and apply monitor-specific fields.

# Fetch latest main so origin/main is fresh for diffs and reverts
subprocess.run(['git', 'fetch', 'origin', 'main', '--quiet'],
               capture_output=True, cwd=repo_root)

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
    if phase in ('merged', 'plan_review', 'split', 'failed'):
        continue

    # Race guard: skip if another monitor run acted on this task within 60s
    import time as _time
    last_action = task.get('lastMonitorAction', 0)
    now = int(_time.time())
    if now - last_action < 60 and phase not in ('reviewing', 'pr_ready', 'needs_split'):
        continue

    # --- Handle reviewing (independent of status) ---
    if phase == 'reviewing':
        branch = task.get('branch', '')
        pr_number = None
        ci_pass = False
        pr_closed_state = None
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
            if not pr_number:
                task_pr = task.get('prNumber')
                if task_pr:
                    state_result = subprocess.run(
                        ['gh', 'pr', 'view', str(task_pr), '--json', 'state'],
                        capture_output=True, text=True, cwd=task_repo)
                    if state_result.returncode == 0 and state_result.stdout.strip():
                        pr_closed_state = str(json.loads(state_result.stdout).get('state', '')).upper()
        if pr_number and ci_pass:
            apply_updates(tid, {'phase': 'pr_ready', 'status': 'pr_ready', 'prNumber': pr_number, 'conflictFixCount': 0})
            _t_msg = log_transition(task, 'reviewing', 'pr_ready', verdict='pass',
                extra={'pr_number': pr_number})
            run_notify(tid, 'pr_ready', _t_msg, product_goal, 'Merge when ready')
            changes_made += 1
        elif pr_number and not ci_pass:
            # Check for merge conflicts while waiting for CI
            merge_result = subprocess.run(
                ['gh', 'pr', 'view', str(pr_number), '--json', 'mergeable'],
                capture_output=True, text=True, cwd=task_repo)
            if merge_result.returncode == 0 and merge_result.stdout.strip():
                mergeable = json.loads(merge_result.stdout).get('mergeable', '')
                if mergeable == 'CONFLICTING':
                    conflict_fix_count = task.get('conflictFixCount', 0)
                    if conflict_fix_count >= 2:
                        print(f'WARNING: {tid} has had {conflict_fix_count} conflict fix attempts — needs human intervention')
                        run_notify(tid, phase,
                            f'PR #{pr_number} still has merge conflicts after {conflict_fix_count} fix attempts. Needs manual resolution.',
                            product_goal,
                            'Manual conflict resolution needed')
                    else:
                        dispatch_fix = os.path.join(script_dir, 'dispatch-fix.sh')
                        fix_result = subprocess.run(
                            [dispatch_fix, '--task-id', tid,
                             '--feedback', 'PR has merge conflicts with main. Resolve conflicts, commit, and push.'],
                            capture_output=True, text=True, cwd=task_repo, env=_clean_env)
                        if fix_result.returncode == 0:
                            apply_updates(tid, {'conflictFixCount': conflict_fix_count + 1})
                            _t_msg = log_transition(task, 'reviewing', 'fixing',
                                extra={'reason': 'merge_conflicts', 'pr_number': pr_number})
                            run_notify(tid, 'fixing', _t_msg, product_goal, 'Resolving merge conflicts')
                        else:
                            print(f'WARNING: dispatch-fix.sh failed for {tid} merge conflicts: {fix_result.stderr}')
                    changes_made += 1
        elif pr_closed_state == 'MERGED':
            apply_updates(tid, {'phase': 'merged', 'status': 'merged'})
            _t_msg = log_transition(task, 'reviewing', 'merged', verdict='pass',
                extra={'pr_number': task.get('prNumber')})
            run_notify(tid, 'merged', _t_msg, product_goal, 'Done')
            changes_made += 1
        elif pr_closed_state == 'CLOSED':
            apply_updates(tid, {'phase': 'failed', 'status': 'failed',
                'completedAt': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')})
            _t_msg = log_transition(task, 'reviewing', 'failed', verdict='closed',
                extra={'pr_number': task.get('prNumber'), 'reason': 'pr_manually_closed'})
            run_notify(tid, 'failed', _t_msg, product_goal, 'PR was closed without merging')
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
                ['gh', 'pr', 'view', str(pr_number), '--json', 'state,mergeable'],
                capture_output=True, text=True, cwd=task_repo)
            if pr_state_result.returncode == 0 and pr_state_result.stdout.strip():
                pr_data = json.loads(pr_state_result.stdout)
                pr_state = pr_data.get('state', '')
                if str(pr_state).upper() == 'MERGED':
                    apply_updates(tid, {'phase': 'merged', 'status': 'merged'})
                    _t_msg = log_transition(task, 'pr_ready', 'merged', verdict='pass',
                        extra={'pr_number': pr_number})
                    run_notify(tid, 'merged', _t_msg, product_goal, 'Done')
                    changes_made += 1
                elif str(pr_state).upper() == 'CLOSED':
                    apply_updates(tid, {'phase': 'failed', 'status': 'failed',
                        'completedAt': datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')})
                    _t_msg = log_transition(task, 'pr_ready', 'failed', verdict='closed',
                        extra={'pr_number': pr_number, 'reason': 'pr_manually_closed'})
                    run_notify(tid, 'failed', _t_msg, product_goal, 'PR was closed without merging')
                    changes_made += 1
                elif pr_data.get('mergeable', '') == 'CONFLICTING':
                    # PR has merge conflicts — dispatch fix agent (with retry guard)
                    conflict_fix_count = task.get('conflictFixCount', 0)
                    if conflict_fix_count >= 2:
                        print(f'WARNING: {tid} has had {conflict_fix_count} conflict fix attempts — needs human intervention')
                        run_notify(tid, phase,
                            f'PR #{pr_number} still has merge conflicts after {conflict_fix_count} fix attempts. Needs manual resolution.',
                            product_goal,
                            'Manual conflict resolution needed')
                    else:
                        dispatch_fix = os.path.join(script_dir, 'dispatch-fix.sh')
                        fix_result = subprocess.run(
                            [dispatch_fix, '--task-id', tid,
                             '--feedback', 'PR has merge conflicts with main. Resolve conflicts, commit, and push.'],
                            capture_output=True, text=True, cwd=task_repo, env=_clean_env)
                        if fix_result.returncode == 0:
                            apply_updates(tid, {'conflictFixCount': conflict_fix_count + 1})
                            _t_msg = log_transition(task, 'pr_ready', 'fixing',
                                extra={'reason': 'merge_conflicts', 'pr_number': pr_number})
                            run_notify(tid, 'fixing', _t_msg, product_goal, 'Resolving merge conflicts')
                        else:
                            print(f'WARNING: dispatch-fix.sh failed for {tid} merge conflicts: {fix_result.stderr}')
                    changes_made += 1
        # If not yet merged, stay in pr_ready (wait for next cycle)
        continue

    # --- Handle needs_split: auto-retry or auto-split ---
    if phase == 'needs_split':
        # Check for API infrastructure issues first — retry/split won't help
        api_issue = check_and_alert_api_issues(task)
        if api_issue:
            print(f'INFO: {tid} has API issue ({api_issue}) — skipping auto-recovery')
            changes_made += 1
            continue

        auto_retry_count = task.get('autoRetryCount', 0)
        auto_split_attempt_count = task.get('autoSplitAttemptCount', 0)
        split_depth = task.get('splitDepth', 0)

        # Decide: retry or split
        # Retry if: hasn't been retried yet AND is not a subtask (splitDepth == 0)
        should_retry = (auto_retry_count < max_auto_retries and split_depth == 0)
        # Split if: retry exhausted AND hasn't been split already AND has required fields
        should_split = (not should_retry
                        and split_depth < max_split_depth
                        and auto_split_attempt_count < max_auto_split_attempts
                        and description and product_goal)

        if should_retry:
            new_retry_count = auto_retry_count + 1
            prev_findings = task.get('findings', [])
            preserved_findings = prev_findings + [f'Auto-retry #{new_retry_count} triggered']
            prev_count = len(prev_findings)
            _t_msg = log_transition(task, 'needs_split', 'planning',
                extra={'reason': f'auto_retry_{new_retry_count}/{max_auto_retries}', 'prev_findings_count': prev_count})
            run_notify(tid, 'planning', _t_msg, product_goal,
                f'Re-planning with context from {prev_count} previous findings')
            task['iteration'] = 0
            task['autoRetryCount'] = new_retry_count
            task['findings'] = preserved_findings
            ok = spawn_agent(task, 'planning', 'plan.md', task.get('agent'))
            if ok:
                apply_updates(tid, {
                    'phase': 'planning',
                    'status': 'running',
                    'iteration': 0,
                    'autoRetryCount': new_retry_count,
                    'autoSplitAttemptCount': 0,
                    'findings': preserved_findings,
                })
            else:
                print(f'ERROR: spawn failed for {tid} during auto-retry')
                run_notify(tid, 'needs_split', f'Auto-retry spawn failed', product_goal)
            changes_made += 1

        elif should_split:
            auto_split_script = os.path.join(script_dir, 'auto-split.sh')
            split_result = subprocess.run(
                [auto_split_script,
                 '--task-id', tid,
                 '--description', description,
                 '--product-goal', product_goal,
                 '--findings', json.dumps(task.get('findings', [])),
                 '--agent', task.get('agent', 'claude')],
                capture_output=True, text=True, cwd=get_task_repo(task),
                env=_clean_env)

            if split_result.returncode == 0 and split_result.stdout.strip():
                try:
                    subtasks = json.loads(split_result.stdout)
                    subtask_ids = []
                    dispatch_script = os.path.join(script_dir, 'dispatch.sh')
                    for st in subtasks:
                        st_id = f'{tid}-{st[\"suffix\"]}'
                        st_branch = f'{task.get(\"branch\", tid)}-{st[\"suffix\"]}'
                        dispatch_cmd = [
                            dispatch_script,
                            '--task-id', st_id,
                            '--branch', st_branch,
                            '--product-goal', product_goal,
                            '--description', st['description'],
                            '--agent', task.get('agent', 'claude'),
                            '--phase', 'planning',
                            '--require-plan-review', 'false',
                        ]
                        d_result = subprocess.run(dispatch_cmd, capture_output=True, text=True,
                                                  cwd=get_task_repo(task), env=_clean_env)
                        if d_result.returncode == 0:
                            subtask_ids.append(st_id)
                            apply_updates(st_id, {'splitDepth': split_depth + 1, 'parentTask': tid})
                        else:
                            print(f'WARNING: Failed to dispatch subtask {st_id}: {d_result.stderr}')

                    if subtask_ids:
                        apply_updates(tid, {
                            'phase': 'split',
                            'status': 'split',
                            'autoSplitAttemptCount': auto_split_attempt_count,
                            'subtasks': subtask_ids,
                        })
                        _t_msg = log_transition(task, 'needs_split', 'split',
                            extra={'subtask_ids': subtask_ids, 'subtask_count': len(subtask_ids)})
                        run_notify(tid, 'split', _t_msg, product_goal, 'Subtasks are now running')
                    else:
                        print(f'WARNING: No subtasks dispatched for {tid}')
                        new_split_attempt_count = auto_split_attempt_count + 1
                        new_findings = task.get('findings', []) + [f'Auto-split attempt #{new_split_attempt_count} failed: no subtasks created']
                        updates = {
                            'phase': 'needs_split',
                            'status': 'needs_split',
                            'autoSplitAttemptCount': new_split_attempt_count,
                            'findings': new_findings,
                        }
                        if new_split_attempt_count >= max_auto_split_attempts:
                            updates['findings'] = new_findings + [f'Auto-split exhausted after {new_split_attempt_count} failed attempts']
                        apply_updates(tid, updates)
                        run_notify(tid, 'needs_split', f'Auto-split failed: no subtasks created', product_goal)
                except (json.JSONDecodeError, KeyError) as e:
                    print(f'WARNING: Failed to parse split output for {tid}: {e}')
                    new_split_attempt_count = auto_split_attempt_count + 1
                    new_findings = task.get('findings', []) + [f'Auto-split attempt #{new_split_attempt_count} failed: bad output']
                    updates = {
                        'phase': 'needs_split',
                        'status': 'needs_split',
                        'autoSplitAttemptCount': new_split_attempt_count,
                        'findings': new_findings,
                    }
                    if new_split_attempt_count >= max_auto_split_attempts:
                        updates['findings'] = new_findings + [f'Auto-split exhausted after {new_split_attempt_count} failed attempts']
                    apply_updates(tid, updates)
                    run_notify(tid, 'needs_split', f'Auto-split failed: bad output', product_goal)
            else:
                print(f'WARNING: auto-split.sh failed for {tid}: {split_result.stderr}')
                new_split_attempt_count = auto_split_attempt_count + 1
                new_findings = task.get('findings', []) + [f'Auto-split attempt #{new_split_attempt_count} failed: split command error']
                updates = {
                    'phase': 'needs_split',
                    'status': 'needs_split',
                    'autoSplitAttemptCount': new_split_attempt_count,
                    'findings': new_findings,
                }
                if new_split_attempt_count >= max_auto_split_attempts:
                    updates['findings'] = new_findings + [f'Auto-split exhausted after {new_split_attempt_count} failed attempts']
                apply_updates(tid, updates)
                run_notify(tid, 'needs_split', f'Auto-split failed', product_goal)
            changes_made += 1

        else:
            # Reset in place: revert worktree, keep findings as learnings, re-plan
            should_reset = (
                task.get('redispatchCount', 0) < 1
                and split_depth == 0
                and description and product_goal
            )
            if should_reset:
                auto_revert(task)
                reset_findings = task.get('findings', []) + ['Auto-recovery exhausted \u2014 resetting for fresh attempt']
                task['iteration'] = 0
                task['findings'] = reset_findings
                task['redispatchCount'] = 1
                task['autoRetryCount'] = 0
                ok = spawn_agent(task, 'planning', 'plan.md', task.get('agent'))
                if ok:
                    apply_updates(tid, {
                        'phase': 'planning',
                        'status': 'running',
                        'iteration': 0,
                        'findings': reset_findings,
                        'redispatchCount': 1,
                        'autoSplitAttemptCount': 0,
                        'autoRetryCount': 0,
                    })
                    _t_msg = log_transition(task, 'needs_split', 'planning',
                        extra={'reason': 'reset_fresh_attempt'})
                    run_notify(tid, 'planning', _t_msg, product_goal,
                        'Re-planning from scratch with learnings')
                else:
                    print(f'ERROR: Reset spawn failed for {tid}')
                    run_notify(tid, 'needs_split', f'Reset spawn failed', product_goal)
                changes_made += 1
            # else: truly terminal — needs human intervention, do nothing
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
            _t_msg = log_transition(task, phase, 'needs_split', iteration=iteration,
                extra={'reason': 'timeout_max_iter'})
            run_notify(tid, 'needs_split', _t_msg, product_goal, 'Needs manual split into subtasks')
        else:
            _t_msg = log_transition(task, phase, phase, iteration=iteration,
                extra={'reason': 'timeout_respawn'})
            run_notify(tid, phase, _t_msg, product_goal, f'Respawning in {phase} phase')
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
        # Check fail reason for API issues — alert immediately
        api_issue = detect_api_issue(fail_reason)
        if api_issue:
            task['findings'] = task.get('findings', []) + [f'Failed during {phase}: {fail_reason}']
            check_and_alert_api_issues(task, fail_reason)
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
            _t_msg = log_transition(task, phase, 'needs_split', iteration=iteration,
                extra={'reason': 'failure_max_iter', 'fail_reason': fail_reason})
            run_notify(tid, 'needs_split', _t_msg, product_goal, 'Needs manual split into subtasks')
        else:
            _t_msg = log_transition(task, phase, phase, iteration=iteration,
                extra={'reason': 'failure_respawn', 'fail_reason': fail_reason})
            run_notify(tid, phase, _t_msg, product_goal, f'Respawning in {phase} phase')
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
            audit_result, _, _ = get_audit_result(task)
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
                    ['gh', 'pr', 'list', '--head', branch, '--state', 'all', '--json', 'number', '--limit', '1'],
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
                _t_msg = log_transition(task, phase, 'failed',
                    extra={'reason': 'superseded', 'superseded_by': superseded_by})
                run_notify(tid, 'failed', _t_msg, product_goal, 'No action needed — newer task exists')
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
                _t_msg = log_transition(task, phase, 'failed',
                    extra={'reason': 'max_respawns', 'respawn_count': respawn_count + 1})
                run_notify(tid, 'failed', _t_msg, product_goal, 'Needs manual investigation')
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
                _t_msg = log_transition(task, phase, 'failed',
                    extra={'reason': 'worktree_missing'})
                run_notify(tid, 'failed', _t_msg, product_goal, 'Needs manual re-dispatch')
                changes_made += 1
                continue

            # Respawn the agent
            cleanup_dead_agent(task)
            respawn_count += 1
            _t_msg = log_transition(task, phase, phase,
                extra={'reason': 'dead_agent_respawn', 'respawn_attempt': respawn_count, 'max_respawns': max_respawns})
            run_notify(tid, phase, _t_msg, product_goal, f'Respawning in {phase} phase')

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
                requires_review = task.get('requiresPlanReview', False)
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
                    log_transition(task, 'planning', 'plan_review', verdict='ready',
                        plan_size=len(plan_content))
                    run_notify(tid, 'plan_review',
                        plan_notify_text,
                        product_goal,
                        'Awaiting human plan approval',
                        plan_file=plan_file)
                else:
                    # Auto-advance — no human gate
                    task['planContent'] = plan_content
                    _t_msg = log_transition(task, 'planning', 'implementing', verdict='ready',
                        plan_size=len(plan_content), prompt_template='implement.md')
                    run_notify(tid, 'implementing', _t_msg, product_goal,
                        'Starting implementation', plan_file=plan_file)
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
                    _t_msg = log_transition(task, 'planning', 'needs_split', iteration=iteration,
                        extra={'reason': 'plan_max_iter'})
                    run_notify(tid, 'needs_split', _t_msg, product_goal, 'Needs manual split into subtasks')
                else:
                    _t_msg = log_transition(task, 'planning', 'planning', verdict='not_ready',
                        iteration=iteration, prompt_template='plan.md')
                    run_notify(tid, 'planning', _t_msg, product_goal,
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
            _t_msg = log_transition(task, 'implementing', 'auditing',
                prompt_template='audit.md', extra={'audit_agent': audit_agent})
            run_notify(tid, 'auditing', _t_msg, product_goal, 'Running code audit')
            ok = spawn_agent(task, 'auditing', 'audit.md', audit_agent)
            if ok:
                apply_updates(tid, {'phase': 'auditing', 'status': 'running'})
            else:
                print(f'ERROR: spawn failed for {tid} during implementing->auditing')
                run_notify(tid, phase, f'Failed to spawn audit agent', product_goal)
            changes_made += 1

        elif phase == 'auditing':
            # Check audit result
            audit_result, audit_summary, audit_findings = get_audit_result(task)
            task['lastStructuredFindings'] = audit_findings
            _af_entry = f'Audit #{iteration + 1}: {audit_result.upper()}'
            if audit_findings.get('critical_count') is not None or audit_findings.get('minor_count') is not None:
                _af_entry += f' ({audit_findings.get(\"critical_count\", 0)}C/{audit_findings.get(\"minor_count\", 0)}m)'
            if audit_findings.get('summary'):
                _af_entry += f' -- {audit_findings[\"summary\"][:200]}'
            elif audit_summary:
                _af_entry += f' -- {audit_summary[:200]}'
            new_findings = task.get('findings', []) + [_af_entry]

            if audit_result == 'pass':
                # Advance to testing
                _t_msg = log_transition(task, 'auditing', 'testing', verdict='pass',
                    structured_findings=audit_findings, prompt_template='test.md')
                run_notify(tid, 'testing', _t_msg, product_goal, 'Running tests and validation')
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
                    _t_msg = log_transition(task, 'auditing', 'needs_split', verdict='fail',
                        structured_findings=audit_findings, iteration=iteration,
                        extra={'reason': 'audit_max_iter'})
                    run_notify(tid, 'needs_split', _t_msg, product_goal, 'Needs manual split into subtasks')
                else:
                    _t_msg = log_transition(task, 'auditing', 'fixing', verdict='fail',
                        structured_findings=audit_findings, iteration=iteration,
                        prompt_template='fix-feedback.md')
                    run_notify(tid, 'fixing', _t_msg, product_goal,
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
                            'lastStructuredFindings': audit_findings,
                        })
                    else:
                        print(f'ERROR: spawn failed for {tid} during auditing->fixing')
                        run_notify(tid, phase, f'Failed to spawn fix agent', product_goal)
            changes_made += 1

        elif phase == 'testing':
            # Check test result
            test_result, test_summary, test_findings = get_test_result(task)
            task['lastStructuredFindings'] = test_findings
            _tf_entry = f'Test #{iteration + 1}: {test_result.upper()}'
            if test_findings.get('critical_count') is not None or test_findings.get('minor_count') is not None:
                _tf_entry += f' ({test_findings.get(\"critical_count\", 0)}C/{test_findings.get(\"minor_count\", 0)}m)'
            _tf_status = []
            if test_findings.get('tests_passed') is not None:
                _tf_status.append(f'tests={\"pass\" if test_findings[\"tests_passed\"] else \"fail\"}')
            if test_findings.get('build_passed') is not None:
                _tf_status.append(f'build={\"pass\" if test_findings[\"build_passed\"] else \"fail\"}')
            if _tf_status:
                _tf_entry += f' [{\"  \".join(_tf_status)}]'
            if test_findings.get('summary'):
                _tf_entry += f' -- {test_findings[\"summary\"][:200]}'
            elif test_summary:
                _tf_entry += f' -- {test_summary[:200]}'
            new_findings = task.get('findings', []) + [_tf_entry]

            if test_result == 'pass':
                # Advance to PR creation
                _t_msg = log_transition(task, 'testing', 'pr_creating', verdict='pass',
                    structured_findings=test_findings, prompt_template='create-pr.md')
                run_notify(tid, 'pr_creating', _t_msg, product_goal, 'Creating pull request')
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
                    _t_msg = log_transition(task, 'testing', 'needs_split', verdict='fail',
                        structured_findings=test_findings, iteration=iteration,
                        extra={'reason': 'test_max_iter'})
                    run_notify(tid, 'needs_split', _t_msg, product_goal, 'Needs manual split into subtasks')
                else:
                    _t_msg = log_transition(task, 'testing', 'fixing', verdict='fail',
                        structured_findings=test_findings, iteration=iteration,
                        prompt_template='fix-feedback.md')
                    run_notify(tid, 'fixing', _t_msg, product_goal,
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
                            'lastStructuredFindings': test_findings,
                        })
                    else:
                        print(f'ERROR: spawn failed for {tid} during testing->fixing')
                        run_notify(tid, phase, f'Failed to spawn fix agent', product_goal)
            changes_made += 1

        elif phase == 'fixing':
            # Route back based on fixTarget
            fix_target = task.get('fixTarget', 'auditing')
            if fix_target == 'reviewing':
                # Post-PR feedback fix: go back to reviewing to re-check CI
                apply_updates(tid, {'phase': 'reviewing', 'status': 'reviewing'})
                _t_msg = log_transition(task, 'fixing', 'reviewing',
                    extra={'fix_target': 'reviewing'})
                run_notify(tid, 'reviewing', _t_msg, product_goal, 'Awaiting CI re-check')
                # Post feedback-addressed comment on the PR
                pr_num = task.get('prNumber')
                feedback = task.get('lastFeedback', '')
                if pr_num and feedback:
                    safe_feedback = feedback.replace('@kopi-claw', 'kopi-claw')
                    body = f'## Feedback Addressed\\n\\n{safe_feedback}\\n\\n---\\n*Posted by Kopiclaw pipeline*'
                    subprocess.run(
                        ['gh', 'issue', 'comment', str(pr_num), '--repo', 'tryrendition/Rendition', '--body', body],
                        capture_output=True, text=True, cwd=repo_root, env=_clean_env)
            elif fix_target == 'testing':
                _t_msg = log_transition(task, 'fixing', 'testing',
                    iteration=iteration, prompt_template='test.md',
                    extra={'fix_target': 'testing'})
                run_notify(tid, 'testing', _t_msg, product_goal, f'Running tests #{iteration + 1}')
                ok = spawn_agent(task, 'testing', 'test.md', task.get('agent'))
                if ok:
                    apply_updates(tid, {'phase': 'testing', 'status': 'running'})
                else:
                    print(f'ERROR: spawn failed for {tid} during fixing->testing')
                    run_notify(tid, phase, f'Failed to spawn testing agent', product_goal)
            else:
                audit_agent = choose_audit_agent(task.get('agent', 'claude'))
                _t_msg = log_transition(task, 'fixing', 'auditing',
                    iteration=iteration, prompt_template='audit.md',
                    extra={'fix_target': 'auditing', 'audit_agent': audit_agent})
                run_notify(tid, 'auditing', _t_msg, product_goal, f'Running audit #{iteration + 1}')
                ok = spawn_agent(task, 'auditing', 'audit.md', audit_agent)
                if ok:
                    apply_updates(tid, {'phase': 'auditing', 'status': 'running'})
                else:
                    print(f'ERROR: spawn failed for {tid} during fixing->auditing')
                    run_notify(tid, phase, f'Failed to spawn audit agent', product_goal)
            changes_made += 1

        elif phase == 'pr_creating':
            # Validate PR existence before advancing to reviewing.
            branch = task.get('branch', '')
            task_repo = get_task_repo(task)
            pr_number = task.get('prNumber')  # May already be set (e.g. existing PR from dispatch)
            pr_lookup_reason = 'no_pr_found'
            if pr_number:
                # Verify the pre-existing PR is still valid
                verify_result = subprocess.run(
                    ['gh', 'api', f'repos/tryrendition/Rendition/pulls/{pr_number}', '--jq', '.state'],
                    capture_output=True, text=True, cwd=task_repo)
                if verify_result.returncode == 0 and verify_result.stdout.strip() == 'open':
                    pr_lookup_reason = 'pre_existing_pr'
                else:
                    pr_number = None  # Fall through to branch-based lookup
                    pr_lookup_reason = 'pre_existing_pr_invalid'
            if not pr_number:
                if branch:
                    pr_result = subprocess.run(
                        ['gh', 'pr', 'list', '--head', branch, '--state', 'all', '--json', 'number', '--limit', '1'],
                        capture_output=True, text=True, cwd=task_repo)
                    if pr_result.returncode == 0 and pr_result.stdout.strip():
                        try:
                            prs = json.loads(pr_result.stdout)
                        except json.JSONDecodeError:
                            prs = []
                            pr_lookup_reason = 'invalid_pr_list_json'
                        if prs:
                            pr_number = prs[0].get('number')
                        else:
                            pr_lookup_reason = 'no_pr_found'
                    elif pr_result.returncode != 0:
                        pr_lookup_reason = f'gh_pr_list_failed_rc_{pr_result.returncode}'
                    else:
                        pr_lookup_reason = 'empty_pr_list_output'
                else:
                    pr_lookup_reason = 'missing_branch'

            if pr_number:
                apply_updates(tid, {
                    'phase': 'reviewing',
                    'status': 'reviewing',
                    'prNumber': pr_number,
                    'missingPrRetryCount': 0,
                })
                _t_msg = log_transition(task, 'pr_creating', 'reviewing',
                    extra={'pr_number': pr_number})
                run_notify(tid, 'reviewing', _t_msg, product_goal, 'Awaiting human review')
                # Post implementation plan as PR comment
                plan_path = os.path.join(plans_dir, f'{tid}.md')
                if os.path.isfile(plan_path):
                    with open(plan_path) as pf:
                        plan_text = pf.read().strip()
                    if plan_text:
                        body = f'## Implementation Plan\\n\\n{plan_text}\\n\\n---\\n*Posted by Kopiclaw pipeline*'
                        subprocess.run(
                            ['gh', 'issue', 'comment', str(pr_number), '--repo', 'tryrendition/Rendition', '--body', body],
                            capture_output=True, text=True, cwd=task_repo, env=_clean_env)
            else:
                # If PR is missing after a successful pr_creating run, auto-remediate
                # with bounded retries; then escalate to explicit terminal failure.
                max_missing_pr_retries = 2
                retry_count = int(task.get('missingPrRetryCount', 0))
                if retry_count < max_missing_pr_retries:
                    dispatch_fix = os.path.join(script_dir, 'dispatch-fix.sh')
                    feedback = (
                        'PR creation did not complete. Ensure branch changes are committed and pushed, '
                        'then create or recover the PR with gh pr create (or equivalent), and verify it exists.'
                    )
                    fix_result = subprocess.run(
                        [dispatch_fix, '--task-id', tid, '--feedback', feedback],
                        capture_output=True, text=True, cwd=task_repo, env=_clean_env)
                    next_retry = retry_count + 1
                    if fix_result.returncode == 0:
                        apply_updates(tid, {'missingPrRetryCount': next_retry})
                        _t_msg = log_transition(task, 'pr_creating', 'fixing',
                            extra={'reason': 'missing_pr', 'pr_lookup_reason': pr_lookup_reason,
                                   'remediation_attempt': f'{next_retry}/{max_missing_pr_retries}'})
                        run_notify(tid, 'fixing', _t_msg, product_goal,
                            'Remediating PR creation and push state')
                    else:
                        print(f'WARNING: dispatch-fix.sh failed for {tid} missing PR: {fix_result.stderr}')
                        apply_updates(tid, {'missingPrRetryCount': next_retry})
                        _t_msg = log_transition(task, 'pr_creating', 'pr_creating',
                            extra={'reason': 'missing_pr_dispatch_failed', 'pr_lookup_reason': pr_lookup_reason,
                                   'remediation_attempt': f'{next_retry}/{max_missing_pr_retries}'})
                        run_notify(tid, 'pr_creating', _t_msg, product_goal,
                            'Waiting for next remediation attempt')
                else:
                    apply_updates(tid, {
                        'phase': 'failed',
                        'status': 'failed',
                        'failReason': 'pr_missing_after_retries',
                    })
                    _t_msg = log_transition(task, 'pr_creating', 'failed',
                        extra={'reason': 'pr_missing_after_retries', 'pr_lookup_reason': pr_lookup_reason,
                               'retry_count': retry_count})
                    run_notify(tid, 'failed', _t_msg, product_goal,
                        'Create/fix PR manually, then re-dispatch from reviewing')
            changes_made += 1

    # running tasks in non-terminal phases: no action needed (wait for completion)

print(json.dumps({'processed': len(task_map), 'changes_made': changes_made}, indent=2))
" "$SCRIPT_DIR" "$TASKS_FILE" "$LOCK_FILE" "$REPO_ROOT" "$WORKTREE_BASE" "$MAX_ITERATIONS" "$NOTIFY" "$SPAWN" "$LOG_DIR" "$FILL_TEMPLATE" "$PLANS_DIR" "$MAX_AUTO_RETRIES" "$MAX_SPLIT_DEPTH" "$MAX_AUTO_SPLIT_ATTEMPTS" <<< "$CHECK_OUTPUT"

log "=== Monitor run completed ==="
