#!/usr/bin/env bash
# slack-health.sh — Monitor Slack socket mode health, auto-restart gateway on failure
#
# Runs via launchd every 90s (independent of gateway).
# Detects dead WebSocket connections by analyzing gateway logs for:
#   - Dense pong timeout clusters (≥10 in 5 min window)
#   - "Failed to send" errors (any in window = dead)
#   - Absence of "delivered reply" (no successful operations)
#
# On detection: `launchctl kickstart -k` the gateway (full process restart).
# Escalates to macOS notification + Slack HTTP API alert after 3 restarts in 30 min.

set -euo pipefail

# --- Config ---
LAUNCHD_LABEL="ai.openclaw.gateway"
LAUNCHD_DOMAIN="gui/501"
ERR_LOG="${HOME}/.openclaw/logs/gateway.err.log"
GW_LOG="${HOME}/.openclaw/logs/gateway.log"
STATE_FILE="${HOME}/.openclaw/slack-health-state.json"
HEALTH_LOG="${HOME}/.openclaw/logs/slack-health.log"

WINDOW_MINUTES=5
PONG_THRESHOLD=10        # ≥10 pong timeouts in window = dead
SEND_FAIL_THRESHOLD=1    # ≥1 "Failed to send" in window = dead
COOLDOWN_SECONDS=180     # Don't restart within 3 min of last restart
MAX_RESTARTS=3           # Max restarts before escalation
ESCALATION_WINDOW=1800   # 30 minutes

# Slack alerting (direct HTTP API, works even when socket mode is dead)
SLACK_ALERTS_CHANNEL="C0AHGH5FH42"
SLACK_BOT_TOKEN_FILE="${HOME}/.openclaw/credentials/slack-bot-token"

# --- Helpers ---
log() {
  local ts
  ts="$(date +"%Y-%m-%dT%H:%M:%S%z")"
  echo "[${ts}] $*"
}

read_state() {
  if [[ -f "$STATE_FILE" ]]; then
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    s = json.load(f)
print(s.get('lastRestartEpoch', 0))
print(s.get('restartCount', 0))
print(s.get('firstRestartEpoch', 0))
print('true' if s.get('escalated', False) else 'false')
print(s.get('lastRestartIso', ''))
" "$STATE_FILE"
  else
    echo "0"
    echo "0"
    echo "0"
    echo "false"
    echo ""
  fi
}

write_state() {
  local last_restart="$1" count="$2" first_restart="$3" escalated="$4" last_restart_iso="${5:-}"
  python3 -c "
import json, sys
state = {
    'lastRestartEpoch': int(sys.argv[1]),
    'restartCount': int(sys.argv[2]),
    'firstRestartEpoch': int(sys.argv[3]),
    'escalated': sys.argv[4] == 'true',
    'lastRestartIso': sys.argv[5]
}
with open(sys.argv[6], 'w') as f:
    json.dump(state, f, indent=2)
    f.write('\n')
" "$last_restart" "$count" "$first_restart" "$escalated" "$last_restart_iso" "$STATE_FILE"
}

slack_alert() {
  local message="$1"
  local token=""
  [[ -f "$SLACK_BOT_TOKEN_FILE" ]] && token="$(cat "$SLACK_BOT_TOKEN_FILE")"
  [[ -z "$token" ]] && { log "WARN: No Slack bot token for alert"; return 1; }

  python3 -c "
import json, sys
payload = {'channel': sys.argv[1], 'text': sys.argv[2], 'unfurl_links': False, 'unfurl_media': False}
print(json.dumps(payload))
" "$SLACK_ALERTS_CHANNEL" "$message" | curl -s -o /dev/null -w '' \
    -X POST \
    -H "Authorization: Bearer ${token}" \
    -H 'Content-type: application/json; charset=utf-8' \
    --data @- \
    'https://slack.com/api/chat.postMessage' || true
}

macos_alert() {
  local message="$1"
  osascript -e "display notification \"${message}\" with title \"Slack Health\" sound name \"Sosumi\"" 2>/dev/null || true
  say "Slack connection unhealthy. Check gateway." 2>/dev/null &
}

# --- Pre-checks ---

# Network connectivity
if ! nc -z -w 3 slack.com 443 2>/dev/null; then
  log "SKIP: Network unreachable (slack.com:443)"
  exit 0
fi

# Log files must exist
if [[ ! -f "$ERR_LOG" ]]; then
  log "SKIP: Error log not found (${ERR_LOG})"
  exit 0
fi
if [[ ! -f "$GW_LOG" ]]; then
  log "SKIP: Gateway log not found (${GW_LOG})"
  exit 0
fi

# --- Read state (needed for effective cutoff calculation) ---
NOW_EPOCH="$(date +%s)"
state_values=($(read_state))
last_restart_epoch="${state_values[0]}"
restart_count="${state_values[1]}"
first_restart_epoch="${state_values[2]}"
escalated="${state_values[3]}"
last_restart_iso="${state_values[4]:-}"

# --- Analyze logs ---
CUTOFF="$(date -u -v-${WINDOW_MINUTES}M +"%Y-%m-%dT%H:%M:%S" 2>/dev/null)"

# Use the later of: (5-min-ago cutoff) or (last restart timestamp)
# This excludes pre-restart log entries that would cause false positives
if [[ -n "$last_restart_iso" ]] && [[ "$last_restart_iso" > "$CUTOFF" ]]; then
  EFFECTIVE_CUTOFF="$last_restart_iso"
else
  EFFECTIVE_CUTOFF="$CUTOFF"
fi

# Count pong timeouts in window (tail last 1000 lines, filter by timestamp)
pong_count=$(tail -1000 "$ERR_LOG" \
  | awk -v cutoff="$EFFECTIVE_CUTOFF" '$0 >= cutoff' \
  | grep -c "pong wasn't received" || true)

# Count "Failed to send" errors in window
send_fail_count=$(tail -1000 "$ERR_LOG" \
  | awk -v cutoff="$EFFECTIVE_CUTOFF" '$0 >= cutoff' \
  | grep -c "Failed to send a message" || true)

# Count "delivered reply" in window (successful operations)
delivered_count=$(tail -1000 "$GW_LOG" \
  | awk -v cutoff="$EFFECTIVE_CUTOFF" '$0 >= cutoff' \
  | grep -c "delivered reply" || true)

log "CHECK: pong_timeouts=${pong_count} send_failures=${send_fail_count} delivered=${delivered_count} (cutoff=${EFFECTIVE_CUTOFF})"

# --- Health determination ---
unhealthy=false

# Primary signal: dense pong timeouts + no successful delivery
if (( pong_count >= PONG_THRESHOLD )) && (( delivered_count == 0 )); then
  unhealthy=true
  log "UNHEALTHY: Dense pong timeouts (${pong_count}≥${PONG_THRESHOLD}), no deliveries"
fi

# Secondary signal: any "Failed to send"
if (( send_fail_count >= SEND_FAIL_THRESHOLD )); then
  unhealthy=true
  log "UNHEALTHY: Send failures detected (${send_fail_count})"
fi

if [[ "$unhealthy" != "true" ]]; then
  # Healthy — reset escalation counters but preserve lastRestart for cutoff
  if [[ "$escalated" == "true" ]] || (( restart_count > 0 )); then
    write_state "$last_restart_epoch" 0 0 false "$last_restart_iso"
    log "HEALTHY: Reset escalation state"
  else
    log "HEALTHY"
  fi
  exit 0
fi

# --- Cooldown check ---
if (( last_restart_epoch > 0 )); then
  elapsed=$(( NOW_EPOCH - last_restart_epoch ))
  if (( elapsed < COOLDOWN_SECONDS )); then
    log "COOLDOWN: Last restart was ${elapsed}s ago (< ${COOLDOWN_SECONDS}s), skipping"
    exit 0
  fi
fi

# --- Escalation window management ---
# Reset restart counter if outside the escalation window
if (( first_restart_epoch > 0 )) && (( NOW_EPOCH - first_restart_epoch > ESCALATION_WINDOW )); then
  restart_count=0
  first_restart_epoch=0
  escalated=false
  log "Escalation window expired, resetting counters"
fi

# --- Escalation check ---
if (( restart_count >= MAX_RESTARTS )); then
  if [[ "$escalated" != "true" ]]; then
    log "ESCALATE: ${restart_count} restarts in $(( (NOW_EPOCH - first_restart_epoch) / 60 ))min, alerting user"
    macos_alert "Slack sockets stuck after ${restart_count} restarts. Manual intervention needed."
    slack_alert ":rotating_light: *Slack Health Alert*: Gateway restarted ${restart_count} times in $(( (NOW_EPOCH - first_restart_epoch) / 60 )) min but sockets are still dead. Manual intervention needed. Check \`~/.openclaw/logs/slack-health.log\`"
    write_state "$last_restart_epoch" "$restart_count" "$first_restart_epoch" true "$last_restart_iso"
  else
    log "ESCALATED: Already alerted user, waiting for manual intervention"
  fi
  exit 0
fi

# --- Restart gateway ---
log "RESTARTING: launchctl kickstart -k -p ${LAUNCHD_DOMAIN}/${LAUNCHD_LABEL}"
launchctl kickstart -k -p "${LAUNCHD_DOMAIN}/${LAUNCHD_LABEL}" 2>&1 | while read -r line; do log "  kickstart: $line"; done

# Get new PID
new_pid=$(launchctl print "${LAUNCHD_DOMAIN}/${LAUNCHD_LABEL}" 2>/dev/null | grep -o 'pid = [0-9]*' | grep -o '[0-9]*' || echo "unknown")
log "RESTARTED: New PID=${new_pid}"

# Update state
RESTART_ISO="$(date -u +"%Y-%m-%dT%H:%M:%S")"
if (( restart_count == 0 )); then
  first_restart_epoch="$NOW_EPOCH"
fi
restart_count=$(( restart_count + 1 ))
write_state "$NOW_EPOCH" "$restart_count" "$first_restart_epoch" false "$RESTART_ISO"

log "STATE: restart #${restart_count} in current window (started $(( (NOW_EPOCH - first_restart_epoch) / 60 ))min ago)"
