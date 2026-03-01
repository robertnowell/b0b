#!/usr/bin/env bash
# notify.sh — Send Slack notifications for pipeline events
# Usage: ./notify.sh --task-id <id> --phase <phase> --message <msg> [--product-goal <goal>] [--channel <channel>]
#
# Requires SLACK_WEBHOOK_URL set in environment or config.sh.
# If no webhook is configured, logs the notification to stdout and exits 0.

# Source shared config
# shellcheck source=config.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

# --- Sourceable function ---
# Other scripts can: source notify.sh && notify --task-id X --phase Y --message Z
_infer_next_step() {
  local phase="$1"
  case "$phase" in
    queued)        echo "Waiting for agent slot" ;;
    planning)      echo "Will produce implementation plan for review" ;;
    plan_review)   echo "Awaiting human plan approval (approve-plan.sh or reject-plan.sh)" ;;
    implementing)  echo "Will run audit on completion" ;;
    auditing)      echo "Will fix issues or create PR based on audit result" ;;
    fixing)        echo "Will re-audit after fixes" ;;
    testing)       echo "Will create PR on test pass" ;;
    pr_creating)   echo "Will run automated reviews" ;;
    reviewing)     echo "Awaiting human review" ;;
    pr_ready)      echo "Awaiting human merge" ;;
    merged)        echo "Done" ;;
    needs_split)   echo "Needs manual split into subtasks" ;;
    failed)        echo "Needs investigation" ;;
    *)             echo "Unknown" ;;
  esac
}

_relative_time() {
  # Given an ISO-8601 timestamp, return a human-readable relative time string
  local iso_ts="$1"
  [[ -z "$iso_ts" ]] && return
  local ts_epoch now_epoch diff_s
  ts_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$iso_ts" "+%s" 2>/dev/null || date -d "$iso_ts" "+%s" 2>/dev/null) || return
  now_epoch=$(date "+%s")
  diff_s=$((now_epoch - ts_epoch))
  if (( diff_s < 60 )); then echo "just now"
  elif (( diff_s < 3600 )); then echo "$(( diff_s / 60 ))m ago"
  elif (( diff_s < 86400 )); then echo "$(( diff_s / 3600 ))h ago"
  else echo "$(( diff_s / 86400 ))d ago"
  fi
}

notify() {
  local task_id="" phase="" message="" product_goal="" channel="" next_step="" started_at=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id)      task_id="$2"; shift 2 ;;
      --phase)        phase="$2"; shift 2 ;;
      --message)      if [[ "$2" == "-" ]]; then message="$(cat)"; else message="$2"; fi; shift 2 ;;
      --product-goal) product_goal="$2"; shift 2 ;;
      --channel)      channel="$2"; shift 2 ;;
      --next)         next_step="$2"; shift 2 ;;
      --started-at)   started_at="$2"; shift 2 ;;
      *) echo "ERROR: Unknown flag: $1" >&2; return 1 ;;
    esac
  done

  [[ -n "$task_id" ]] || { echo "ERROR: --task-id required" >&2; return 1; }
  [[ -n "$phase" ]]   || { echo "ERROR: --phase required" >&2; return 1; }
  [[ -n "$message" ]] || { echo "ERROR: --message required" >&2; return 1; }

  if [ -z "$next_step" ]; then
    next_step="$(_infer_next_step "$phase")"
  fi

  local timestamp relative_str age_label
  timestamp="$(date +"%Y-%m-%d %H:%M %Z")"
  relative_str=""
  if [[ -n "$started_at" ]]; then
    relative_str=$(_relative_time "$started_at" 2>/dev/null || true)
  fi
  age_label=""
  if [[ -n "$relative_str" ]]; then
    age_label=" | ⏱️ started ${relative_str}"
  fi

  local notification
  notification="$(cat <<EOF
🔧 *Task:* ${task_id} | *Phase:* ${phase} | 🕐 ${timestamp}${age_label}
📦 *Goal:* ${product_goal:-N/A}
⚙️ ${message}
➡️ *Next:* ${next_step}
EOF
)"

  # Log to stdout regardless
  echo "[notify] ${task_id} (${phase}): ${message}"

  # Append to outbox for Kopiclaw to relay via Slack
  if [ -n "${NOTIFY_OUTBOX:-}" ]; then
    python3 -c "
import json, sys
lines = sys.stdin.read().split('\n', 1)
msg = lines[0]
notif = lines[1] if len(lines) > 1 else ''
entry = {'task_id': sys.argv[1], 'phase': sys.argv[2], 'message': msg, 'product_goal': sys.argv[3], 'next_step': sys.argv[4], 'text': notif}
# For plan_review, include planFile path so Kopiclaw can post the full plan
if sys.argv[2] == 'plan_review':
    entry['requiresFullPlanPost'] = True
print(json.dumps(entry))
" "$task_id" "$phase" "${product_goal:-}" "$next_step" <<< "${message}
${notification}" >> "$NOTIFY_OUTBOX"
  fi

  # Send to Slack if webhook is configured
  if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    local payload http_code
    payload=$(python3 -c "
import json, sys
notif = sys.stdin.read()
channel = sys.argv[1]
payload = {'text': notif}
if channel:
    payload['channel'] = channel
print(json.dumps(payload))
" "$channel" <<< "$notification")

    http_code=$(echo "$payload" | curl -s -o /dev/null -w '%{http_code}' \
      -X POST \
      -H 'Content-type: application/json' \
      --data @- \
      "$SLACK_WEBHOOK_URL")

    if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
      echo "[notify] Slack notification sent (HTTP ${http_code})"
    else
      echo "[notify] WARNING: Slack notification failed (HTTP ${http_code})" >&2
    fi
  else
    echo "[notify] No SLACK_WEBHOOK_URL configured — skipping Slack delivery" >&2
  fi
}

# --- CLI entrypoint: only run when executed, not when sourced ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  notify "$@"
fi
