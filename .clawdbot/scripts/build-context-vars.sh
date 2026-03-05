#!/usr/bin/env bash
# build-context-vars.sh — Centralized template variable builder
#
# Reads a task from active-tasks.json, builds ALL standard template variables,
# fills the template, and outputs the filled prompt to stdout.
# This is the single source of truth for template variable construction.
#
# Usage:
#   ./build-context-vars.sh --task-id <id> --phase <phase> --template <file> \
#     [--override KEY=VALUE ...] > filled-prompt.md
#
# Overrides are for phase-specific variables (FEEDBACK, FINDINGS) that callers provide.

set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/config.sh"

TASK_ID=""
PHASE=""
TEMPLATE=""
OVERRIDE_KEYS=()
OVERRIDE_VALUES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)
      [[ $# -ge 2 ]] || { echo "ERROR: --task-id requires a value" >&2; exit 1; }
      TASK_ID="$2"; shift 2 ;;
    --phase)
      [[ $# -ge 2 ]] || { echo "ERROR: --phase requires a value" >&2; exit 1; }
      PHASE="$2"; shift 2 ;;
    --template)
      [[ $# -ge 2 ]] || { echo "ERROR: --template requires a value" >&2; exit 1; }
      TEMPLATE="$2"; shift 2 ;;
    --override)
      [[ $# -ge 2 ]] || { echo "ERROR: --override requires KEY=VALUE" >&2; exit 1; }
      PAIR="$2"
      KEY="${PAIR%%=*}"
      VALUE="${PAIR#*=}"
      [[ "$KEY" != "$PAIR" ]] || { echo "ERROR: --override must be KEY=VALUE, got: $PAIR" >&2; exit 1; }
      OVERRIDE_KEYS+=("$KEY")
      OVERRIDE_VALUES+=("$VALUE")
      shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$TASK_ID" ]]  || { echo "ERROR: --task-id is required" >&2; exit 1; }
[[ -n "$PHASE" ]]    || { echo "ERROR: --phase is required" >&2; exit 1; }
[[ -n "$TEMPLATE" ]] || { echo "ERROR: --template is required" >&2; exit 1; }
[[ -f "$TEMPLATE" ]] || { echo "ERROR: Template not found: $TEMPLATE" >&2; exit 1; }

# Write overrides to a temp file (avoids ARG_MAX for large FEEDBACK values)
OVERRIDES_FILE=$(mktemp)
trap 'rm -f "$OVERRIDES_FILE"' EXIT

python3 -c "
import json, sys
keys = []
values = []
data = sys.stdin.buffer.read()
parts = data.split(b'\x00')
for i in range(0, len(parts) - 1, 2):
    keys.append(parts[i].decode())
    values.append(parts[i+1].decode())
with open(sys.argv[1], 'w') as f:
    json.dump(dict(zip(keys, values)), f)
" "$OVERRIDES_FILE" < <(
  for i in "${!OVERRIDE_KEYS[@]}"; do
    printf '%s\0%s\0' "${OVERRIDE_KEYS[$i]}" "${OVERRIDE_VALUES[$i]}"
  done
)

# All logic in Python to avoid ARG_MAX and handle large plan/diff content
python3 -c "
import json, sys, os, re, subprocess, fcntl

tasks_file = sys.argv[1]
lock_file = sys.argv[2]
task_id = sys.argv[3]
phase = sys.argv[4]
template_file = sys.argv[5]
overrides_file = sys.argv[6]
worktree_base = sys.argv[7]

# Read task from active-tasks.json under lock
fd = open(lock_file, 'w')
fcntl.flock(fd, fcntl.LOCK_SH)
try:
    with open(tasks_file) as f:
        tasks = json.load(f)
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    fd.close()

task = next((t for t in tasks if t.get('id') == task_id), None)
if not task:
    print(f'ERROR: Task {task_id} not found in {tasks_file}', file=sys.stderr)
    sys.exit(1)

# Build standard variables (mirrors build_context_vars() in monitor.sh)
description = task.get('description', '')
product_goal = task.get('productGoal', '')

plan_text = task.get('planContent', '') or description

# Compute diff from worktree (always separate from plan)
diff_text = ''
worktree = task.get('worktree', os.path.join(worktree_base, task_id))
if worktree and os.path.isdir(worktree):
    diff_result = subprocess.run(
        ['git', 'diff', 'origin/main...HEAD'],
        capture_output=True, text=True, cwd=worktree)
    if diff_result.returncode == 0 and diff_result.stdout.strip():
        diff_text = diff_result.stdout

image_files = task.get('imageFiles', [])
images_text = ''
if image_files and isinstance(image_files, list):
    images_text = 'Visual context from the original request. Read these image files to see screenshots:\n' + '\n'.join(f'- {p}' for p in image_files)

user_request = task.get('userRequest', '') or \
    'No original request provided. Base your plan strictly on the task description and product goal. Do NOT add scope beyond what is explicitly described.'

_vars = {
    'TASK_DESCRIPTION': description,
    'PRD': product_goal,
    'PLAN': plan_text,
    'DELIVERABLES': description,
    'FEEDBACK': '',
    'FEATURE': description,
    'DESCRIPTION': description,
    'PRODUCT_GOAL': product_goal,
    'DIFF': diff_text,
    'TASK_ID': task_id,
    'IMAGES': images_text,
    'USER_REQUEST': user_request,
    'FINDINGS': '',
}

# Apply caller overrides (FEEDBACK, FINDINGS, etc.)
with open(overrides_file) as f:
    overrides = json.load(f)
_vars.update(overrides)

# Validate context completeness
_phase_required = {
    'planning':     ['PRODUCT_GOAL', 'TASK_DESCRIPTION', 'USER_REQUEST'],
    'implementing': ['PLAN', 'PRODUCT_GOAL', 'TASK_DESCRIPTION', 'USER_REQUEST'],
    'auditing':     ['PLAN', 'DIFF', 'PRD', 'USER_REQUEST'],
    'testing':      ['PLAN', 'DIFF', 'PRODUCT_GOAL', 'USER_REQUEST'],
    'fixing':       ['PLAN', 'DIFF', 'FEEDBACK', 'PRODUCT_GOAL', 'USER_REQUEST'],
    'pr_creating':  ['PLAN', 'DIFF', 'PRODUCT_GOAL', 'TASK_DESCRIPTION', 'USER_REQUEST'],
}
required = _phase_required.get(phase, [])
fallback_prefix = 'No original request provided.'
missing = [k for k in required
           if not _vars.get(k, '').strip() or _vars.get(k, '').startswith(fallback_prefix)]
if missing:
    print(f'WARNING: Phase {phase} for {task_id} missing context: {\", \".join(missing)}', file=sys.stderr)

# Read and fill template
with open(template_file) as f:
    content = f.read()

for key, value in _vars.items():
    content = content.replace('{' + key + '}', value)

# Warn about unresolved placeholders
unresolved = re.findall(r'\{([A-Za-z_][A-Za-z0-9_]*)\}', content)
for u in unresolved:
    print(f'WARNING: unresolved placeholder {{{u}}} in {template_file}', file=sys.stderr)

sys.stdout.write(content)
" "$TASKS_FILE" "$LOCK_FILE" "$TASK_ID" "$PHASE" "$TEMPLATE" "$OVERRIDES_FILE" "$WORKTREE_BASE"
