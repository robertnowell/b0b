# Ops runbook: Migrate kopiclaw to multi-workspace pattern

This is a live-system step. Execute in a quiet window when no tasks are mid-flight.

## Why

After the multi-workspace refactor, kopiclaw should run via the new `B0B_WORKSPACE=kopiclaw` cascade rather than relying on backward-compat defaults. This validates the cascade end-to-end and is the prerequisite for bringing up a second workspace alongside it.

## Pre-flight

1. Confirm no in-flight tasks:

   ```bash
   bash ~/Projects/b0b/.clawdbot/scripts/pipeline-status.sh
   ```

   Wait until no rows are in `implementing`, `auditing`, `testing`, or `pr_creating`. If a task is stuck, decide whether to wait or `kill-task.sh` it before proceeding.

2. Identify the existing kopiclaw plist and back it up:

   ```bash
   launchctl list | grep -E 'openclaw|kopiclaw'
   # Note the label, then back up:
   ts=$(date +%Y%m%d-%H%M)
   mkdir -p ~/.openclaw/_backups/$ts
   cp ~/Library/LaunchAgents/<existing-plist>.plist ~/.openclaw/_backups/$ts/
   cp -R ~/.openclaw/workspace-kopiclaw ~/.openclaw/_backups/$ts/
   ```

## Migration

3. Create the workspace config file:

   ```bash
   cat > ~/.openclaw/kopiclaw/config.sh <<'EOF'
   #!/usr/bin/env bash
   # Workspace config for kopiclaw — preserves legacy state-dir name.
   WORKSPACE_REPO="tryrendition/Rendition"
   BOT_USER="kopi-claw"
   WORKTREE_BASE="/Users/kopi/Projects/kopi-worktrees"
   SLACK_PROJECT_CHANNEL="C0AJAR3S76U"
   SLACK_ALERTS_CHANNEL="C0AHGH5FH42"
   SLACK_REVIEW_USER="U020AAXG1DE"
   STATE_DIR="${HOME}/.openclaw/workspace-kopiclaw/pipeline"
   EOF
   ```

   Note `STATE_DIR` keeps the legacy `workspace-kopiclaw` directory name — do NOT rename to `~/.openclaw/kopiclaw/pipeline`. There's existing state there.

4. Edit the existing kopiclaw launchd plist (`~/Library/LaunchAgents/<existing-plist>.plist`) and add to `EnvironmentVariables`:

   ```xml
   <key>B0B_WORKSPACE</key>
   <string>kopiclaw</string>
   <key>B0B_LEGACY</key>
   <string>1</string>
   ```

   The `B0B_LEGACY=1` is the safety belt — even if the workspace config.sh has a bug, kopiclaw uses backward-compat defaults until you remove the flag.

5. Reload the plist:

   ```bash
   launchctl unload ~/Library/LaunchAgents/<existing-plist>.plist
   launchctl load ~/Library/LaunchAgents/<existing-plist>.plist
   ```

6. Wait for one monitor cycle (~5 min). Verify:
   - `pipeline-status.sh` runs cleanly
   - `~/.openclaw/workspace-kopiclaw/pipeline/logs/launchd.out` shows the heartbeat
   - Slack notifications still land in `#alerts-kopi-claw` and `#project-kopi-claw`

## Cutover (remove the safety belt)

7. Once stable for at least one full task lifecycle (planning → PR), remove `B0B_LEGACY=1` from the plist `EnvironmentVariables`. Reload.

8. Verify the cascade is actually doing work:

   ```bash
   tail -f ~/.openclaw/workspace-kopiclaw/pipeline/logs/launchd.out
   # In another shell, dispatch a trivial task. Confirm:
   #   - Plan posts to C0AJAR3S76U (project channel)
   #   - Alert posts to C0AHGH5FH42 (alerts channel)
   #   - PR created in tryrendition/Rendition
   ```

## Rollback

If anything goes wrong:

```bash
launchctl unload ~/Library/LaunchAgents/<existing-plist>.plist
cp ~/.openclaw/_backups/<timestamp>/<existing-plist>.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/<existing-plist>.plist
# If state was corrupted:
rm -rf ~/.openclaw/workspace-kopiclaw
cp -R ~/.openclaw/_backups/<timestamp>/workspace-kopiclaw ~/.openclaw/
```

The kopi-claw bot stays as kopi-claw; this migration does not rename or replace the GitHub machine account.
