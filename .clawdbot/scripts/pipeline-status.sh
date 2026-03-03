#!/usr/bin/env bash
# pipeline-status.sh — Deterministic pipeline status formatter
# Reads active-tasks.json and outputs formatted Slack text with accurate timestamps.
# No LLM involved — all time computation is done in code.
#
# Usage: bash pipeline-status.sh
# Output: Formatted Slack message to stdout

set -euo pipefail

# Source shared config (TASKS_FILE, etc.) and notify.sh (_format_age)
# shellcheck source=config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
# shellcheck source=notify.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/notify.sh"

if [ ! -f "$TASKS_FILE" ]; then
  echo "No active tasks."
  exit 0
fi

python3 -c "
import json, sys, os
from datetime import datetime, timezone

tasks_file = sys.argv[1]
now = datetime.now(timezone.utc)
now_epoch = int(now.timestamp())
DAY_SECONDS = 86400

with open(tasks_file) as f:
    try:
        tasks = json.load(f)
    except (json.JSONDecodeError, ValueError):
        tasks = []

if not tasks:
    print('No active tasks.')
    sys.exit(0)

def parse_iso(ts):
    if not ts:
        return None
    try:
        return datetime.fromisoformat(ts.replace('Z', '+00:00'))
    except (ValueError, TypeError):
        return None

def format_age(dt):
    if not dt:
        return '?'
    diff = int((now - dt).total_seconds())
    if diff < 0:
        return 'just now'
    if diff < 60:
        return f'{diff}s'
    if diff < 3600:
        return f'{diff // 60}m'
    if diff < DAY_SECONDS:
        return f'{diff // 3600}h {(diff % 3600) // 60}m'
    return f'{diff // DAY_SECONDS}d {(diff % DAY_SECONDS) // 3600}h'

def phase_emoji(phase):
    return {
        'planning': '\U0001f4ad',      # 💭
        'plan_review': '\U0001f4cb',   # 📋
        'implementing': '\U0001f528',  # 🔨
        'auditing': '\U0001f528',      # 🔨
        'fixing': '\U0001f528',        # 🔨
        'testing': '\U0001f528',       # 🔨
        'pr_creating': '\U0001f4dd',   # 📝
        'reviewing': '\U0001f440',     # 👀
        'pr_ready': '\U0001f440',      # 👀
        'needs_split': '\u26a0\ufe0f', # ⚠️
        'merged': '\u2705',            # ✅
        'failed': '\u274c',            # ❌
        'split': '\U0001f500',         # 🔀
    }.get(phase, '\u2753')             # ❓

ACTIVE_PHASES = {'planning', 'plan_review', 'implementing', 'auditing', 'fixing', 'testing', 'pr_creating'}
REVIEW_PHASES = {'reviewing', 'pr_ready'}

# Categorize tasks
active = []
in_review = []
needs_attention = []
merged = []
failed = []

for task in tasks:
    tid = task.get('id', '?')
    phase = task.get('phase', '')
    created_at = parse_iso(task.get('createdAt', '')) or parse_iso(task.get('startedAt', ''))
    completed_at = parse_iso(task.get('completedAt', ''))

    entry = {
        'id': tid,
        'phase': phase,
        'agent': task.get('agent', '?'),
        'created_at': created_at,
        'completed_at': completed_at,
        'age': format_age(created_at),
        'emoji': phase_emoji(phase),
        'task': task,
    }

    if phase in ACTIVE_PHASES:
        active.append(entry)
    elif phase in REVIEW_PHASES:
        in_review.append(entry)
    elif phase == 'needs_split':
        # Check if redispatched — if so, skip (the new task will show)
        if task.get('redispatchedTo'):
            continue
        needs_attention.append(entry)
    elif phase == 'merged':
        if completed_at and (now - completed_at).total_seconds() < DAY_SECONDS:
            merged.append(entry)
    elif phase == 'failed':
        if completed_at and (now - completed_at).total_seconds() < DAY_SECONDS:
            failed.append(entry)
    # skip: split, queued, or other terminal phases

# Sort each section by created_at oldest-first
for section in [active, in_review, needs_attention, merged, failed]:
    section.sort(key=lambda e: e['created_at'] or datetime.min.replace(tzinfo=timezone.utc))

# Format output
now_str = now.strftime('%a %b %-d, %-I:%M %p') + ' UTC'
lines = [f'\U0001f4ca *Pipeline Status* \u2014 {now_str}']

def format_entry(e):
    phase_display = e['phase']
    extra = ''
    task = e['task']
    if e['phase'] == 'needs_split':
        retry_count = task.get('autoRetryCount', 0)
        split_count = task.get('autoSplitAttemptCount', 0)
        if split_count >= 2:
            extra = ' (auto-recovery exhausted)'
        elif retry_count > 0:
            extra = f' (retried {retry_count}x)'
    return f\"\u2022 \`{e['id']}\` \u2014 {phase_display} {e['emoji']}{extra} ({e['age']})\"

if active:
    lines.append('')
    lines.append('*Active*')
    for e in active:
        lines.append(format_entry(e))

if in_review:
    lines.append('')
    lines.append('*In Review*')
    for e in in_review:
        lines.append(format_entry(e))

if needs_attention:
    lines.append('')
    lines.append('*Needs Attention*')
    for e in needs_attention:
        lines.append(format_entry(e))

if merged:
    lines.append('')
    lines.append('*Merged*')
    for e in merged:
        lines.append(format_entry(e))

if failed:
    lines.append('')
    lines.append('*Failed*')
    for e in failed:
        lines.append(format_entry(e))

if not any([active, in_review, needs_attention, merged, failed]):
    lines.append('')
    lines.append('No active tasks.')

print('\n'.join(lines))
" "$TASKS_FILE"
