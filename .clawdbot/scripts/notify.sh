#!/usr/bin/env bash
# notify.sh — Send Slack notifications for pipeline events
# Usage: ./notify.sh --task-id <id> --phase <phase> --message <msg> [--product-goal <goal>]
#
# Delivery: SLACK_BOT_TOKEN via Slack API (chat.postMessage) to specific channels.
# If not configured, logs the notification to stdout and exits 0.

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
    split)         echo "Subtasks dispatched" ;;
    failed)        echo "Needs investigation" ;;
    *)             echo "Unknown" ;;
  esac
}

_format_age() {
  # Given an ISO-8601 timestamp, return a compound duration string (e.g. "2h 15m")
  local iso_ts="$1"
  [[ -z "$iso_ts" ]] && return
  local ts_epoch now_epoch diff_s
  ts_epoch=$(TZ=UTC date -jf "%Y-%m-%dT%H:%M:%SZ" "$iso_ts" "+%s" 2>/dev/null || date -d "$iso_ts" "+%s" 2>/dev/null) || return
  now_epoch=$(date "+%s")
  diff_s=$((now_epoch - ts_epoch))
  if (( diff_s < 0 )); then echo "just now"
  elif (( diff_s < 60 )); then echo "${diff_s}s"
  elif (( diff_s < 3600 )); then echo "$(( diff_s / 60 ))m"
  elif (( diff_s < 86400 )); then echo "$(( diff_s / 3600 ))h $(( (diff_s % 3600) / 60 ))m"
  else echo "$(( diff_s / 86400 ))d $(( (diff_s % 86400) / 3600 ))h"
  fi
}

_slack_bot_post() {
  # Post a message to a Slack channel via bot token
  # Usage: _slack_bot_post <channel_id> <<< "message text"
  local channel="$1"
  local text
  text="$(cat)"

  [[ -n "${SLACK_BOT_TOKEN:-}" ]] || return 1

  local response http_code body
  response=$(python3 -c "
import json, sys
text = sys.stdin.read()
if len(text) > 39000:
    text = text[:39000] + '\n\n_(truncated — see plan file for full text)_'
payload = {'channel': sys.argv[1], 'text': text, 'unfurl_links': False, 'unfurl_media': False}
print(json.dumps(payload))
" "$channel" <<< "$text" | curl -s -w '\n%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    -H 'Content-type: application/json; charset=utf-8' \
    --data @- \
    'https://slack.com/api/chat.postMessage')

  # Split response: last line is HTTP code, everything before is the body
  http_code=$(echo "$response" | tail -n1)
  body=$(echo "$response" | sed '$d')

  if ! { [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; }; then
    echo "[notify] WARNING: Slack bot post to ${channel} failed (HTTP ${http_code})" >&2
    return 1
  fi

  # Slack API returns HTTP 200 even on errors; check JSON "ok" field
  local ok
  ok=$(echo "$body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ok', False))" 2>/dev/null || echo "False")
  if [ "$ok" != "True" ]; then
    local err
    err=$(echo "$body" | python3 -c "import json,sys; print(json.load(sys.stdin).get('error', 'unknown'))" 2>/dev/null || echo "unknown")
    echo "[notify] WARNING: Slack bot post to ${channel} failed (ok=false, error=${err})" >&2
    return 1
  fi

  echo "[notify] Slack bot post to ${channel} (HTTP ${http_code}, ok=true)"
}

_post_plan_to_slack() {
  # Post the full plan to #project-kopi-claw with @mention
  local task_id="$1" plan_text="$2" product_goal="$3"

  [[ -n "${SLACK_BOT_TOKEN:-}" ]] || {
    echo "[notify] No SLACK_BOT_TOKEN — skipping plan post to #project-kopi-claw" >&2
    return 0
  }

  _slack_bot_post "$SLACK_PROJECT_CHANNEL" <<EOF
:clipboard: *Plan ready for review:* \`${task_id}\`
:package: *Goal:* ${product_goal:-N/A}

<@${SLACK_REVIEW_USER}> — please review and run \`approve-plan.sh ${task_id}\` to proceed.

---

${plan_text}
EOF
}

notify() {
  local task_id="" phase="" message="" product_goal="" next_step="" started_at="" plan_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id)      task_id="$2"; shift 2 ;;
      --phase)        phase="$2"; shift 2 ;;
      --message)      if [[ "$2" == "-" ]]; then message="$(cat)"; else message="$2"; fi; shift 2 ;;
      --product-goal) product_goal="$2"; shift 2 ;;
      --next)         next_step="$2"; shift 2 ;;
      --started-at)   started_at="$2"; shift 2 ;;
      --plan-file)    plan_file="$2"; shift 2 ;;
      *) echo "ERROR: Unknown flag: $1" >&2; return 1 ;;
    esac
  done

  [[ -n "$task_id" ]] || { echo "ERROR: --task-id required" >&2; return 1; }
  [[ -n "$phase" ]]   || { echo "ERROR: --phase required" >&2; return 1; }
  [[ -n "$message" ]] || { echo "ERROR: --message required" >&2; return 1; }

  if [ -z "$next_step" ]; then
    next_step="$(_infer_next_step "$phase")"
  fi

  local timestamp age_str age_line
  timestamp="$(date +"%Y-%m-%d %H:%M %Z")"
  age_str=""
  if [[ -n "$started_at" ]]; then
    age_str=$(_format_age "$started_at" 2>/dev/null || true)
  fi
  age_line=""
  if [[ -n "$age_str" ]]; then
    age_line=$'\n'"⏱️ *Age:* ${age_str} (started ${started_at})"
  fi

  local notification
  notification="$(cat <<EOF
🔧 *Task:* ${task_id} | *Phase:* ${phase} | 🕐 ${timestamp}
📦 *Goal:* ${product_goal:-N/A}${age_line}
⚙️ ${message}
➡️ *Next:* ${next_step}
EOF
)"

  # Log to stdout regardless
  echo "[notify] ${task_id} (${phase}): ${message}"

  # Send to #alerts-kopi-claw via bot token
  if [ -n "${SLACK_BOT_TOKEN:-}" ]; then
    _slack_bot_post "$SLACK_ALERTS_CHANNEL" <<< "$notification"
  else
    echo "[notify] No SLACK_BOT_TOKEN configured — skipping Slack delivery" >&2
  fi

  # For plan_review: post full plan to #project-kopi-claw with @mention
  if [ "$phase" = "plan_review" ]; then
    _post_plan_to_slack "$task_id" "$message" "$product_goal"
  fi
}

# --- CLI entrypoint: only run when executed, not when sourced ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  notify "$@"
fi
