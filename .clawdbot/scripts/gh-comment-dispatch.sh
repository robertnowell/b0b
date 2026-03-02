#!/usr/bin/env bash
# gh-comment-dispatch.sh — Poll GitHub comments, classify intent, dispatch pipeline actions
# Called by monitor.sh each cycle. Outputs log lines to stdout.
#
# Flow:
#   1. Run gh-poll.sh → JSON lines of new @kopi-claw mentions
#   2. For each comment: classify intent via gh-comment-classify.py
#   3. Dispatch based on intent:
#      - action_request → generate task-id, dispatch planning agent
#      - feedback       → append to existing task findings
#      - approval       → approve-plan.sh for matching task
#      - rejection      → reject-plan.sh with feedback
#      - question/other → notify Slack only
#   4. Add GitHub reactions for feedback

set -euo pipefail

# Source shared config
# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISPATCH="${SCRIPT_DIR}/dispatch.sh"
APPROVE="${SCRIPT_DIR}/approve-plan.sh"
REJECT="${SCRIPT_DIR}/reject-plan.sh"
CLASSIFY="${SCRIPT_DIR}/gh-comment-classify.py"
POLL="${SCRIPT_DIR}/gh-poll.sh"

# shellcheck source=notify.sh
source "${SCRIPT_DIR}/notify.sh"

REPO="tryrendition/Rendition"
BOT_USER="kopi-claw"
MAX_DISPATCHES_PER_CYCLE="${GH_COMMENT_MAX_DISPATCHES:-3}"
ALLOWED_USERS="${GH_COMMENT_ALLOWED_USERS:-kopi}"
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

find_task_by_number() {
  # Find an active task matching this PR/issue number
  local number="$1"
  python3 -c "
import json, sys
number = sys.argv[2]
try:
    tasks = json.load(open(sys.argv[1]))
    for t in tasks:
        phase = t.get('phase', '')
        if phase in ('merged', 'needs_split', 'failed'):
            continue
        src = str(t.get('sourceNumber', ''))
        pr = str(t.get('prNumber', ''))
        branch = t.get('branch', '')
        if src == number or pr == number or t.get('id', '').startswith(f'gh-{number}-'):
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

is_authorized_user() {
  local author="$1"
  local allowed_csv="$2"
  local item
  IFS=',' read -r -a allowed_arr <<< "$allowed_csv"
  for item in "${allowed_arr[@]}"; do
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
NEW_POLL_OUTPUT=$("$POLL" 2>/dev/null) || {
  echo "WARNING: gh-poll.sh failed or returned no results"
  NEW_POLL_OUTPUT=""
}

QUEUED_POLL_OUTPUT=""
if [ -f "$QUEUE_FILE" ]; then
  QUEUED_POLL_OUTPUT=$(cat "$QUEUE_FILE")
fi

if [ -z "$NEW_POLL_OUTPUT" ] && [ -z "$QUEUED_POLL_OUTPUT" ]; then
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

  # Classify intent
  classification=$(echo "$normalized" | python3 "$CLASSIFY") || {
    echo "WARNING: Classification failed for comment ${comment_id}"
    continue
  }

  intent=$(echo "$classification" | python3 -c "import json,sys; print(json.load(sys.stdin)['intent'])")
  task_desc=$(echo "$classification" | python3 -c "import json,sys; print(json.load(sys.stdin)['taskDescription'])")
  product_goal=$(echo "$classification" | python3 -c "import json,sys; print(json.load(sys.stdin).get('productGoal',''))")

  echo "Comment ${comment_id} from ${author} on #${number}: intent=${intent}"

  case "$intent" in
    action_request)
      if ! is_authorized_user "$author" "$ALLOWED_USERS"; then
        echo "Skipping unauthorized action request ${comment_id} by ${author}"
        notify --task-id "gh-${number}" --phase "other" \
          --message "Ignored action request from unauthorized user ${author} on #${number}" \
          --next "Authorize user via GH_COMMENT_ALLOWED_USERS to enable automation"
        continue
      fi

      # Check dispatch limit
      if [ "$dispatch_count" -ge "$MAX_DISPATCHES_PER_CYCLE" ]; then
        echo "WARNING: Max dispatches per cycle (${MAX_DISPATCHES_PER_CYCLE}) reached, queueing comment ${comment_id}"
        if [ -n "$NEXT_QUEUE_FILE" ]; then
          echo "$line" >> "$NEXT_QUEUE_FILE"
        else
          enqueue_comment "$line"
        fi
        notify --task-id "gh-${number}" --phase "queued" \
          --message "Action request queued (dispatch limit reached) from ${author}: ${task_desc}" \
          --product-goal "$product_goal"
        continue
      fi

      # Generate task ID and branch
      task_id=$(generate_task_id "$number" "$task_desc")
      branch=$(generate_branch "$number" "$task_desc")
      agent="${GH_COMMENT_DEFAULT_AGENT:-claude}"
      require_review="${GH_COMMENT_REQUIRE_PLAN_REVIEW:-true}"

      echo "Dispatching: task=${task_id} branch=${branch} agent=${agent}"

      # Dispatch planning agent
      "$DISPATCH" \
        --task-id "$task_id" \
        --branch "$branch" \
        --product-goal "$product_goal" \
        --description "$task_desc" \
        --agent "$agent" \
        --phase planning \
        --require-plan-review "$require_review" \
        --user-request "$body" || {
        echo "ERROR: dispatch.sh failed for task ${task_id}"
        continue
      }

      # Store source comment metadata on the task
      apply_task_update "$task_id" \
        "sourceNumber=$number" \
        "sourceCommentId=$comment_id" \
        "sourceCommentUrl=$comment_url"

      # Add rocket reaction
      add_reaction "$comment_id" "$comment_type" "rocket"

      notify --task-id "$task_id" --phase "planning" \
        --message "New task from GitHub comment on #${number} by ${author}: ${task_desc}" \
        --product-goal "$product_goal"

      dispatch_count=$((dispatch_count + 1))
      ;;

    feedback)
      if ! is_authorized_user "$author" "$ALLOWED_USERS"; then
        echo "Skipping unauthorized feedback ${comment_id} by ${author}"
        notify --task-id "gh-${number}" --phase "other" \
          --message "Ignored feedback from unauthorized user ${author} on #${number}" \
          --next "Authorize user via GH_COMMENT_ALLOWED_USERS to allow task mutations"
        continue
      fi

      matching_task=$(find_task_by_number "$number") || {
        echo "No matching task for #${number} — notifying only"
        notify --task-id "gh-${number}" --phase "other" \
          --message "Feedback from ${author} on #${number}, but no matching task found: ${task_desc}"
        continue
      }

      echo "Appending feedback to task ${matching_task}"
      append_finding "$matching_task" "GitHub feedback from ${author} on #${number}: ${task_desc}"
      add_reaction "$comment_id" "$comment_type" "+1"
      ;;

    approval)
      if ! is_authorized_user "$author" "$ALLOWED_USERS"; then
        echo "Skipping unauthorized approval ${comment_id} by ${author}"
        notify --task-id "gh-${number}" --phase "other" \
          --message "Ignored approval from unauthorized user ${author} on #${number}" \
          --next "Authorize user via GH_COMMENT_ALLOWED_USERS to allow plan approval"
        continue
      fi

      matching_task=$(find_task_by_number "$number") || {
        echo "No matching task for approval on #${number}"
        notify --task-id "gh-${number}" --phase "other" \
          --message "Approval from ${author} on #${number}, but no matching task found"
        continue
      }

      echo "Processing approval for task ${matching_task}"
      "$APPROVE" "$matching_task" 2>&1 || {
        echo "WARNING: approve-plan.sh failed for ${matching_task} (may not be in plan_review)"
      }
      add_reaction "$comment_id" "$comment_type" "+1"
      ;;

    rejection)
      if ! is_authorized_user "$author" "$ALLOWED_USERS"; then
        echo "Skipping unauthorized rejection ${comment_id} by ${author}"
        notify --task-id "gh-${number}" --phase "other" \
          --message "Ignored rejection from unauthorized user ${author} on #${number}" \
          --next "Authorize user via GH_COMMENT_ALLOWED_USERS to allow plan rejection"
        continue
      fi

      matching_task=$(find_task_by_number "$number") || {
        echo "No matching task for rejection on #${number}"
        notify --task-id "gh-${number}" --phase "other" \
          --message "Rejection from ${author} on #${number}, but no matching task found"
        continue
      }

      echo "Processing rejection for task ${matching_task}"
      "$REJECT" "$matching_task" --reason "GitHub comment from ${author}: ${task_desc}" 2>&1 || {
        echo "WARNING: reject-plan.sh failed for ${matching_task} (may not be in plan_review)"
      }
      add_reaction "$comment_id" "$comment_type" "+1"
      ;;

    question)
      echo "Question from ${author} on #${number} — notify only"
      notify --task-id "gh-${number}" --phase "other" \
        --message "Question from ${author} on #${number}: ${task_desc}" \
        --next "Manual response needed"
      ;;

    other|*)
      echo "Unclassified comment from ${author} on #${number} — notify only"
      notify --task-id "gh-${number}" --phase "other" \
        --message "Unclassified @kopi-claw mention from ${author} on #${number}: ${task_desc}" \
        --next "Manual triage needed"
      ;;
  esac

done <<< "$POLL_OUTPUT"

if [ -n "$NEXT_QUEUE_FILE" ]; then
  if [ -s "$NEXT_QUEUE_FILE" ]; then
    mv "$NEXT_QUEUE_FILE" "$QUEUE_FILE"
  else
    rm -f "$NEXT_QUEUE_FILE" "$QUEUE_FILE"
  fi
fi

echo "gh-comment-dispatch complete. Dispatched ${dispatch_count} new task(s)."
