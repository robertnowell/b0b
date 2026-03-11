# Monitor.sh Cron Investigation — 2026-02-27

## What Exists ✅
- **monitor.sh** — exists, executable (`-rwxr-xr-x`), 25KB. Full state machine that advances tasks through pipeline phases (implementing→auditing→fixing→testing→pr_creating→reviewing→merged). Well-written.
- **notify.sh** — exists, executable. Sends Slack notifications via webhook. Gracefully degrades: if no `SLACK_WEBHOOK_URL`, logs to stdout and exits 0 (no crash).
- **config.sh** — exists, executable. Defines `SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"` (defaults to empty).
- **All supporting scripts** — check-agents.sh, spawn-agent.sh, fill-template.sh, dispatch.sh all present.

## What's Missing ❌
1. **No cron job** — `crontab -l` returns "no crontab for kopi". Monitor.sh is not scheduled.
2. **No launchd plist** — No `*monitor*` or `*clawdbot*` entries in `~/Library/LaunchAgents/`.
3. **No `.env` file** — No `.env` or similar in `.clawdbot/`. `SLACK_WEBHOOK_URL` is never set.
4. **No OpenClaw cron job** — No cron entries found for monitor (tool not available to verify, but no evidence of setup).

## Why Notifications Weren't Working
- `SLACK_WEBHOOK_URL` defaults to empty string in config.sh
- notify.sh correctly detects this and skips Slack delivery (logs to stdout only)
- Even if monitor.sh ran, notifications would only go to stdout/log file — never to Slack
- **Root cause: The script was built but never scheduled, and the webhook was never configured**

## Recommendations
1. **Use OpenClaw cron** to run monitor.sh every 10 minutes — more reliable than system cron for this use case since it can post results to Slack via the message tool directly
2. **Replace webhook-based notifications with OpenClaw message tool** — Instead of needing `SLACK_WEBHOOK_URL`, have monitor.sh output structured JSON and let the OpenClaw cron handler post to `#alerts-kopi-claw` (C0AHGH5FH42). This eliminates the webhook dependency entirely.
3. **Alternative: Create a launchd plist** if you want system-level scheduling independent of OpenClaw
4. **If keeping webhook approach**: Create `.clawdbot/.env` with `SLACK_WEBHOOK_URL=https://hooks.slack.com/...` and source it from config.sh
5. **Quick test**: Run `cd ~/Projects/kopi && .clawdbot/monitor.sh` manually to verify it works (will need active tasks in active-tasks.json)
