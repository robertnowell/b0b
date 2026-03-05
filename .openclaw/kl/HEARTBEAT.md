# HEARTBEAT.md

## Log heartbeat to Slack
After completing all checks below, send a short summary to Slack channel `C0AGMMZDYD6`:
- Timestamp + what was checked + outcome (e.g. "nothing to report" or brief action taken)
- Keep it to 1-2 lines max

## Slack health check
- Check if Slack has received any events recently: `grep -c slack /tmp/openclaw/openclaw-$(date +%Y-%m-%d).log`
- If the count seems stale (no new Slack log lines in hours and it's daytime):
  1. **First** send an alert to Slack `C0AGMMZDYD6`: "⚠️ Slack events look stale — restarting gateway"
  2. **Then** restart the gateway to refresh the socket connection
  3. The heartbeat summary log (step above) should be sent *before* any restart since the session won't survive it
