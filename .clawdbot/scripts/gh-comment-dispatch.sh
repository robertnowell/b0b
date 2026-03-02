#!/usr/bin/env bash
# gh-comment-dispatch.sh — Poll GitHub comments, dispatch pipeline tasks
# Called by monitor.sh each cycle. Outputs log lines to stdout.
#
# Flow:
#   1. Run gh-poll.sh → JSON lines of new @kopi-claw mentions
#   2. For each comment:
#      - Known bots → LLM evaluation (skip if no real changes needed)
#      - Existing task for PR → route as feedback, spawn fix agent if fixable
#      - New task → dispatch planning agent
#      - "plan only" in comment → gate at plan_review
#   3. Reply in GitHub thread + add reactions

set -euo pipefail

# Source shared config
# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

# Prevent concurrent dispatch runs (causes duplicate task creation)
DISPATCH_LOCK="${STATE_DIR}/.gh-comment-dispatch.lock"
exec 9>"$DISPATCH_LOCK"
if ! flock -n 9; then
  echo "Another gh-comment-dispatch is already running — skipping"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPATCH="${SCRIPT_DIR}/dispatch.sh"
POLL="${SCRIPT_DIR}/gh-poll.sh"

# shellcheck source=notify.sh
source "${SCRIPT_DIR}/notify.sh"

REPO="tryrendition/Rendition"
BOT_USER="kopi-claw"
MAX_DISPATCHES_PER_CYCLE="${GH_COMMENT_MAX_DISPATCHES:-3}"
QUEUE_FILE="${GH_COMMENT_QUEUE_FILE:-${STATE_DIR}/gh-comment-queue.jsonl}"

# Check if dispatch is enabled
if [ "${GH_COMMENT_DISPATCH_ENABLED:-true}" != "true" ]; then
  echo "gh-comment-dispatch disabled via GH_COMMENT_DISPATCH_ENABLED"
  exit 0
fi

# --- Helpers ---

slugify() {
  # First 4 words, lowercased, joined with hyphens
  echo "$1" | tr '[:upper:]' '[:lower:]' | \
    sed 's/[^a-z0-9 ]//g' | \
    awk '{for(i=1;i<=4&&i<=NF;i++) printf "%s%s",$i,(i<4&&i<NF?"-":""); print ""}'
}

generate_task_id() {
  local number="$1"
  local description="$2"
  local slug
  slug=$(slugify "$description")
  # Remove trailing hyphens
  slug="${slug%-}"
  local base_id="gh-${number}-${slug}"
  local task_id="$base_id"

  # Check for collisions
  local suffix=2
  while python3 -c "
import json, sys
try:
    tasks = json.load(open(sys.argv[1]))
    sys.exit(0 if any(t.get('id', '') == sys.argv[2] for t in tasks) else 1)
except Exception: sys.exit(1)
" "$TASKS_FILE" "$task_id" 2>/dev/null; do
    task_id="${base_id}-${suffix}"
    suffix=$((suffix + 1))
  done
  echo "$task_id"
}

generate_branch() {
  local number="$1"
  local description="$2"
  local slug
  slug=$(slugify "$description")
  slug="${slug%-}"
  # Default to feat/ prefix
  local lower_desc
  lower_desc=$(echo "$description" | tr '[:upper:]' '[:lower:]')
  local prefix="feat"
  if echo "$lower_desc" | grep -qE '^(fix|bug|patch|hotfix)'; then
    prefix="fix"
  fi
  echo "${prefix}/gh-${number}-${slug}"
}

add_reaction() {
  local comment_id="$1"
  local comment_type="$2"  # "comment" or "review_comment"
  local reaction="$3"       # emoji name: eyes, rocket, +1
  local endpoint
  if [ "$comment_type" = "review_comment" ]; then
    endpoint="repos/${REPO}/pulls/comments/${comment_id}/reactions"
  else
    endpoint="repos/${REPO}/issues/comments/${comment_id}/reactions"
  fi
  gh api "$endpoint" -f content="$reaction" --silent 2>/dev/null || true
}

gh_reply() {
  local number="$1"
  local comment_id="$2"
  local comment_type="$3"
  local message="$4"
  if [ "$comment_type" = "review_comment" ]; then
    # Reply to PR review comment thread
    gh api "repos/${REPO}/pulls/comments/${comment_id}/replies" \
      -f body="$message" --silent 2>/dev/null || true
  else
    # Reply to issue/PR comment
    gh issue comment "$number" --repo "$REPO" --body "$message" 2>/dev/null || true
  fi
}

find_task_by_number() {
  # Find an active task matching this PR/issue number
  local number="$1"
  python3 -c "
import json, re, sys
number = sys.argv[2]
try:
    tasks = json.load(open(sys.argv[1]))
    for t in tasks:
        phase = t.get('phase', '')
        if phase in ('merged', 'needs_split', 'split', 'failed'):
            continue
        src = str(t.get('sourceNumber', ''))
        pr = str(t.get('prNumber', ''))
        branch = t.get('branch', '')
        if src == number or pr == number or t.get('id', '').startswith(f'gh-{number}-'):
            print(t.get('id', ''))
            sys.exit(0)
        # Match branch containing the number as a discrete segment
        # e.g. 'fix/1659-foo' matches 1659, but 'feat/16590-bar' does not
        if re.search(rf'(?:^|[/\-_.])({re.escape(number)})(?:[/\-_.]|$)', branch):
            print(t.get('id', ''))
            sys.exit(0)
    sys.exit(1)
except Exception:
    sys.exit(1)
" "$TASKS_FILE" "$number" 2>/dev/null
}

apply_task_update() {
  local task_id="$1"
  shift
  # Remaining args are key=value pairs to set on the task
  python3 -c "
import json, sys, fcntl
tasks_file = sys.argv[1]
lock_file = sys.argv[2]
task_id = sys.argv[3]
updates = {}
for kv in sys.argv[4:]:
    k, v = kv.split('=', 1)
    updates[k] = v
fd = open(lock_file, 'w')
fcntl.flock(fd, fcntl.LOCK_EX)
try:
    with open(tasks_file) as f:
        tasks = json.load(f)
    for t in tasks:
        if t.get('id', '') == task_id:
            for k, v in updates.items():
                t[k] = v
            break
    with open(tasks_file, 'w') as f:
        json.dump(tasks, f, indent=2)
        f.write('\n')
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    fd.close()
" "$TASKS_FILE" "$LOCK_FILE" "$task_id" "$@"
}

append_finding() {
  local task_id="$1"
  local finding="$2"
  python3 -c "
import json, sys, fcntl
tasks_file, lock_file, task_id, finding = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
fd = open(lock_file, 'w')
fcntl.flock(fd, fcntl.LOCK_EX)
try:
    with open(tasks_file) as f:
        tasks = json.load(f)
    for t in tasks:
        if t.get('id', '') == task_id:
            t.setdefault('findings', []).append(finding)
            break
    with open(tasks_file, 'w') as f:
        json.dump(tasks, f, indent=2)
        f.write('\n')
finally:
    fcntl.flock(fd, fcntl.LOCK_UN)
    fd.close()
" "$TASKS_FILE" "$LOCK_FILE" "$task_id" "$finding"
}

is_known_bot() {
  local author="$1"
  local known_bots="${GH_COMMENT_KNOWN_BOTS:-}"
  [ -z "$known_bots" ] && return 1
  local item
  IFS=',' read -r -a bot_arr <<< "$known_bots"
  for item in "${bot_arr[@]}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    if [ -n "$item" ] && [ "$author" = "$item" ]; then
      return 0
    fi
  done
  return 1
}

enqueue_comment() {
  local line="$1"
  local comment_id
  comment_id=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['commentId'])") || return 1

  touch "$QUEUE_FILE"
  if python3 -c "
import json, sys
comment_id = sys.argv[1]
queue_file = sys.argv[2]
found = False
with open(queue_file) as f:
    for raw in f:
        raw = raw.strip()
        if not raw:
            continue
        try:
            if str(json.loads(raw).get('commentId')) == comment_id:
                found = True
                break
        except Exception:
            continue
sys.exit(0 if found else 1)
" "$comment_id" "$QUEUE_FILE"; then
    return 0
  fi

  echo "$line" >> "$QUEUE_FILE"
}

# --- Main ---

# 1. Poll for new comments
RAW_POLL_OUTPUT=$("$POLL" 2>/dev/null) || {
  echo "WARNING: gh-poll.sh failed or returned no results"
  RAW_POLL_OUTPUT=""
}

# Separate state_update line from comment lines (two-phase commit:
# state is only written after all comments are processed successfully)
PENDING_STATE_UPDATE=""
NEW_POLL_OUTPUT=""
if [ -n "$RAW_POLL_OUTPUT" ]; then
  PENDING_STATE_UPDATE=$(echo "$RAW_POLL_OUTPUT" | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        if obj.get('_type') == 'state_update':
            print(line)
            break
    except Exception:
        pass
" 2>/dev/null) || PENDING_STATE_UPDATE=""

  NEW_POLL_OUTPUT=$(echo "$RAW_POLL_OUTPUT" | python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        if obj.get('_type') == 'state_update':
            continue
    except Exception:
        pass
    print(line)
" 2>/dev/null) || NEW_POLL_OUTPUT=""
fi

QUEUED_POLL_OUTPUT=""
if [ -f "$QUEUE_FILE" ]; then
  QUEUED_POLL_OUTPUT=$(cat "$QUEUE_FILE")
fi

if [ -z "$NEW_POLL_OUTPUT" ] && [ -z "$QUEUED_POLL_OUTPUT" ]; then
  # Even with no comments, commit state to advance lastChecked
  if [ -n "$PENDING_STATE_UPDATE" ]; then
    STATE_FILE="${GH_POLL_STATE_FILE:-${STATE_DIR}/gh-poll-state.json}"
    echo "$PENDING_STATE_UPDATE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
state = data.get('state', {})
with open(sys.argv[1], 'w') as f:
    json.dump(state, f, indent=2)
    f.write('\n')
" "$STATE_FILE" || echo "ERROR: Failed to commit poll state update"
  fi
  echo "No new @kopi-claw mentions found"
  exit 0
fi

if [ -n "$QUEUED_POLL_OUTPUT" ] && [ -n "$NEW_POLL_OUTPUT" ]; then
  POLL_OUTPUT="${QUEUED_POLL_OUTPUT}"$'\n'"${NEW_POLL_OUTPUT}"
elif [ -n "$QUEUED_POLL_OUTPUT" ]; then
  POLL_OUTPUT="$QUEUED_POLL_OUTPUT"
else
  POLL_OUTPUT="$NEW_POLL_OUTPUT"
fi

NEXT_QUEUE_FILE=""
if [ -f "$QUEUE_FILE" ]; then
  NEXT_QUEUE_FILE=$(mktemp)
fi

dispatch_count=0

# 2. Process each comment
while IFS= read -r line; do
  [ -z "$line" ] && continue

  # Parse comment JSON once and reject malformed payloads without aborting the loop.
  normalized=$(echo "$line" | python3 -c '
import json, sys
try:
    raw = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(raw, dict):
    sys.exit(1)

comment_id = raw.get("commentId")
comment_type = raw.get("type")
number = raw.get("number")
author = raw.get("author")
body = raw.get("body", "")
comment_url = raw.get("url", "")

if comment_id is None or str(comment_id).strip() == "":
    sys.exit(1)
if comment_type not in ("comment", "review_comment"):
    sys.exit(1)
if number is None or str(number).strip() == "":
    sys.exit(1)
if author is None or str(author).strip() == "":
    sys.exit(1)
if not isinstance(body, str):
    body = str(body)
if not isinstance(comment_url, str):
    comment_url = str(comment_url)

print(json.dumps({
    "commentId": str(comment_id),
    "type": comment_type,
    "number": str(number),
    "author": str(author),
    "body": body,
    "url": comment_url,
}))
') || {
    echo "WARNING: Skipping malformed comment payload"
    continue
  }

  comment_id=$(echo "$normalized" | python3 -c "import json,sys; print(json.load(sys.stdin)['commentId'])")
  comment_type=$(echo "$normalized" | python3 -c "import json,sys; print(json.load(sys.stdin)['type'])")
  number=$(echo "$normalized" | python3 -c "import json,sys; print(json.load(sys.stdin)['number'])")
  author=$(echo "$normalized" | python3 -c "import json,sys; print(json.load(sys.stdin)['author'])")
  body=$(echo "$normalized" | python3 -c "import json,sys; print(json.load(sys.stdin)['body'])")
  comment_url=$(echo "$normalized" | python3 -c "import json,sys; print(json.load(sys.stdin)['url'])")

  # Skip bot's own comments
  if [ "$author" = "$BOT_USER" ]; then
    echo "Skipping self-comment ${comment_id} by ${author}"
    continue
  fi

  # Add eyes reaction — processing
  add_reaction "$comment_id" "$comment_type" "eyes"

  # Use comment body as task description (strip @kopi-claw mention, take first 200 chars)
  task_desc=$(echo "$body" | sed 's/@kopi-claw//gI' | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-200)

  echo "Comment ${comment_id} from ${author} on #${number}"

  # Skip closed/merged PRs and issues — no point dispatching work for them
  if [ "$number" != "unknown" ]; then
    pr_state=$(gh api "repos/${REPO}/pulls/${number}" --jq '.state + ":" + (.merged | tostring)' 2>/dev/null) || pr_state=""
    if [ "$pr_state" = "closed:true" ]; then
      echo "Skipping comment on merged PR #${number}"
      continue
    elif [ "$pr_state" = "closed:false" ]; then
      echo "Skipping comment on closed PR #${number}"
      continue
    fi
    # If not a PR (404), check issue state
    if [ -z "$pr_state" ]; then
      issue_state=$(gh api "repos/${REPO}/issues/${number}" --jq '.state' 2>/dev/null) || issue_state=""
      if [ "$issue_state" = "closed" ]; then
        echo "Skipping comment on closed issue #${number}"
        continue
      fi
    fi
  fi

  # --- Bot evaluation gate ---
  # Known bots (e.g. kilo-code[bot]) get LLM evaluation to filter out noise
  if is_known_bot "$author"; then
    echo "Evaluating bot comment from ${author} on #${number}"
    EVALUATE_BOT="${SCRIPT_DIR}/gh-comment-evaluate-bot.py"
    eval_result=$(echo "$body" | python3 "$EVALUATE_BOT" 2>/dev/null) || eval_result='{"needsChanges":true,"taskDescription":"","reason":"Evaluation script failed"}'
    needs_changes=$(echo "$eval_result" | python3 -c "import json,sys; d=json.load(sys.stdin); print('true' if d.get('needsChanges') else 'false')")
    task_desc_override=$(echo "$eval_result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('taskDescription',''))")
    eval_reason=$(echo "$eval_result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('reason',''))")

    if [ "$needs_changes" != "true" ]; then
      echo "Bot comment on #${number} evaluated — no actionable changes: ${eval_reason}"
      gh_reply "$number" "$comment_id" "$comment_type" "Evaluated — no actionable code changes required. ${eval_reason}"
      add_reaction "$comment_id" "$comment_type" "+1"
      continue
    fi
    # Use LLM-extracted task description if available
    [ -n "$task_desc_override" ] && task_desc="$task_desc_override"
    echo "Bot comment on #${number} evaluated — changes needed: ${eval_reason}"
  fi

  # --- Existing task dedup ---
  # If there's already an active task for this PR/issue, route as feedback
  existing_task=$(find_task_by_number "$number") || existing_task=""
  if [ -n "$existing_task" ]; then
    echo "Active task ${existing_task} found for #${number} — routing as feedback"
    append_finding "$existing_task" "GitHub comment from ${author} on #${number}: ${task_desc}"

    task_phase=$(python3 -c "
import json, sys
tasks = json.load(open(sys.argv[1]))
task = next((t for t in tasks if t.get('id') == sys.argv[2]), None)
print(task.get('phase', '') if task else '')
" "$TASKS_FILE" "$existing_task" 2>/dev/null) || task_phase=""

    FIXABLE_PHASES="reviewing pr_ready"
    if echo "$FIXABLE_PHASES" | grep -qw "$task_phase"; then
      if [ "$dispatch_count" -lt "$MAX_DISPATCHES_PER_CYCLE" ]; then
        DISPATCH_FIX="${SCRIPT_DIR}/dispatch-fix.sh"
        "$DISPATCH_FIX" \
          --task-id "$existing_task" \
          --feedback "GitHub comment from ${author} on #${number}: ${task_desc}" || {
          echo "WARNING: dispatch-fix.sh failed for ${existing_task}"
        }
        gh_reply "$number" "$comment_id" "$comment_type" "Feedback applied to existing task \`${existing_task}\` — fix agent dispatched."
        add_reaction "$comment_id" "$comment_type" "rocket"
        dispatch_count=$((dispatch_count + 1))
      else
        gh_reply "$number" "$comment_id" "$comment_type" "Feedback noted on task \`${existing_task}\` — fix queued for next cycle."
        add_reaction "$comment_id" "$comment_type" "+1"
      fi
    else
      gh_reply "$number" "$comment_id" "$comment_type" "Feedback noted on task \`${existing_task}\` (phase: ${task_phase})."
      add_reaction "$comment_id" "$comment_type" "+1"
    fi
    continue
  fi

  # --- Dispatch limit ---
  if [ "$dispatch_count" -ge "$MAX_DISPATCHES_PER_CYCLE" ]; then
    echo "WARNING: Max dispatches per cycle (${MAX_DISPATCHES_PER_CYCLE}) reached, queueing comment ${comment_id}"
    enqueue_comment "$line"
    gh_reply "$number" "$comment_id" "$comment_type" "Queued — dispatch limit reached. Will process next cycle."
    continue
  fi

  # --- Detect "plan only" mode ---
  require_review="false"
  if echo "$body" | grep -qi "plan only"; then
    require_review="true"
  fi

  # --- Dispatch task ---
  task_id=$(generate_task_id "$number" "$task_desc")
  branch=$(generate_branch "$number" "$task_desc")
  agent="${GH_COMMENT_DEFAULT_AGENT:-claude}"

  echo "Dispatching: task=${task_id} branch=${branch} agent=${agent} planOnly=${require_review}"

  "$DISPATCH" \
    --task-id "$task_id" \
    --branch "$branch" \
    --product-goal "$task_desc" \
    --description "$task_desc" \
    --agent "$agent" \
    --phase planning \
    --require-plan-review "$require_review" \
    --user-request "$body" || {
    echo "ERROR: dispatch.sh failed for task ${task_id}"
    continue
  }

  apply_task_update "$task_id" \
    "sourceNumber=$number" \
    "sourceCommentId=$comment_id" \
    "sourceCommentUrl=$comment_url"

  add_reaction "$comment_id" "$comment_type" "rocket"

  if [ "$require_review" = "true" ]; then
    gh_reply "$number" "$comment_id" "$comment_type" "Plan-only task dispatched: \`${task_id}\`. Will post plan for review."
  else
    gh_reply "$number" "$comment_id" "$comment_type" "Task dispatched: \`${task_id}\`. Planning → implementing → PR."
  fi

  notify --task-id "$task_id" --phase "planning" \
    --message "Task from #${number} by ${author}: ${task_desc}" \
    --product-goal "$task_desc"

  dispatch_count=$((dispatch_count + 1))

done <<< "$POLL_OUTPUT"

if [ -n "$NEXT_QUEUE_FILE" ]; then
  if [ -s "$NEXT_QUEUE_FILE" ]; then
    mv "$NEXT_QUEUE_FILE" "$QUEUE_FILE"
  else
    rm -f "$NEXT_QUEUE_FILE" "$QUEUE_FILE"
  fi
fi

# Commit poll state — only after all comments have been processed/queued
if [ -n "$PENDING_STATE_UPDATE" ]; then
  STATE_FILE="${GH_POLL_STATE_FILE:-${STATE_DIR}/gh-poll-state.json}"
  echo "$PENDING_STATE_UPDATE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
state = data.get('state', {})
with open(sys.argv[1], 'w') as f:
    json.dump(state, f, indent=2)
    f.write('\n')
" "$STATE_FILE" || echo "ERROR: Failed to commit poll state update"
fi

echo "gh-comment-dispatch complete. Dispatched ${dispatch_count} new task(s)."
