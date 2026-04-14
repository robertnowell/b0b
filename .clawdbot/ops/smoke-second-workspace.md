# Ops runbook: Bring up a second workspace alongside kopiclaw

This runbook validates that two b0b instances can run in parallel on one Mac without collision. Run this only after `migrate-kopiclaw.md` is complete and stable.

## Pre-requisites

- kopiclaw is migrated to the new pattern and running stably (no `B0B_LEGACY=1`).
- A throwaway GitHub repo you own (e.g. `<you>/sandbox`).
- A Slack channel pair the existing bot has access to (or skip Slack and pass empty channel IDs to bypass notifications).

## Init

1. Create the workspace:

   ```bash
   ~/Projects/b0b/.clawdbot/scripts/init-workspace.sh \
     --name sandbox \
     --repo <you>/sandbox \
     --slack-project-channel <id-or-blank> \
     --slack-alerts-channel <id-or-blank> \
     --slack-review-user <your-user-id> \
     --human-name "Robert" \
     --human-github "robertnowell"
   ```

2. Inspect the generated workspace and plist:

   ```bash
   ls ~/.openclaw/sandbox/
   cat ~/.openclaw/sandbox/config.sh
   plutil ~/Library/LaunchAgents/com.openclaw.sandbox.monitor.plist
   ```

3. Edit `~/.openclaw/sandbox/IDENTITY.md` and `USER.md` if you want a non-default persona.

## Smoke test (manual run, no launchd)

4. Run monitor.sh once manually with the workspace env set:

   ```bash
   B0B_WORKSPACE=sandbox bash ~/Projects/b0b/.clawdbot/scripts/monitor.sh
   ```

   Confirm:
   - Logs go to `~/.openclaw/sandbox/pipeline/logs/`
   - No interference with `~/.openclaw/workspace-kopiclaw/pipeline/`

5. Dispatch a trivial test task:

   ```bash
   B0B_WORKSPACE=sandbox bash ~/Projects/b0b/.clawdbot/scripts/dispatch.sh \
     --task-id smoketest-1 \
     --branch test/smoketest \
     --product-goal "Add a comment to README" \
     --description "Append one line to README.md" \
     --user-request "Smoke test for multi-workspace b0b" \
     --agent claude \
     --phase planning
   ```

   Verify:
   - Worktree is created at the sandbox `WORKTREE_BASE` (NOT in `kopi-worktrees`)
   - Tmux session is named `agent-sandbox-smoketest-1` (workspace-prefixed)
   - State lives at `~/.openclaw/sandbox/pipeline/`
   - kopiclaw's pipeline keeps running undisturbed (`pipeline-status.sh` from a default shell still shows kopi tasks)

## Load via launchd

6. Once the manual smoke test passes:

   ```bash
   launchctl load ~/Library/LaunchAgents/com.openclaw.sandbox.monitor.plist
   launchctl list | grep openclaw   # should show both kopiclaw and sandbox
   ```

7. Tail both log streams in parallel:

   ```bash
   tail -f ~/.openclaw/workspace-kopiclaw/pipeline/logs/launchd.out \
           ~/.openclaw/sandbox/pipeline/logs/launchd.out
   ```

## Teardown

```bash
launchctl unload ~/Library/LaunchAgents/com.openclaw.sandbox.monitor.plist
rm ~/Library/LaunchAgents/com.openclaw.sandbox.monitor.plist
rm -rf ~/.openclaw/sandbox
# If you created GitHub PRs during the smoke test, delete them on github.com/<you>/sandbox.
```

## What to confirm before declaring multi-workspace ready

- [ ] Two plists loaded simultaneously without launchd errors
- [ ] `tmux ls` shows both `agent-kopiclaw-*` and `agent-sandbox-*` sessions during overlapping tasks
- [ ] No corrupted JSON in either workspace's `pipeline/active-tasks.json`
- [ ] No collisions in `${STATE_DIR}/gh-poll-*.json` (each workspace has its own copy)
- [ ] Slack notifications route correctly per-workspace
- [ ] `cleanup-worktrees.sh` from each workspace only removes its own worktrees

If all six pass, the refactor is verified. Document any rough edges as follow-up tasks.
