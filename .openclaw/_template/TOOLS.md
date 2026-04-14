# TOOLS.md - Local Notes

## {{PROJECT_NAME}} Repo
- Path: `{{WORKSPACE_REPO_PATH}}`
- Repo: `{{WORKSPACE_REPO}}` on GitHub
- Stack: {{PROJECT_STACK}}
- Deploy: {{PROJECT_DEPLOY}}

## Coding Agents
- Claude Code: `{{CLAUDE_PATH}}`
- Codex: `codex`
- Worktrees: `{{WORKTREE_BASE}}/`

## Agent Swarm Scripts

**Primary entry points (use these):**
- `$REPO_ROOT/.clawdbot/scripts/dispatch.sh` — Dispatch a new task or phase: validates args, fills prompt template, spawns agent. Use for ALL phases including planning.
- `$REPO_ROOT/.clawdbot/scripts/approve-plan.sh` — Approve a plan and advance plan_review → implementing
- `$REPO_ROOT/.clawdbot/scripts/reject-plan.sh` — Reject a plan with feedback, sends back to planning
- `$REPO_ROOT/.clawdbot/scripts/dispatch-fix.sh` — Dispatch a fix with specific feedback
- `$REPO_ROOT/.clawdbot/scripts/monitor.sh` — Advance pipeline phases (cron runs this every 2min)
- `$REPO_ROOT/.clawdbot/scripts/check-agents.sh` — Check all agent statuses (tmux, PR, CI)
- `$REPO_ROOT/.clawdbot/scripts/pipeline-status.sh` — Generate Slack-formatted pipeline summary
- `$REPO_ROOT/.clawdbot/scripts/cleanup-worktrees.sh` — Clean merged/failed worktrees

**Internal (called by scripts above, not directly):**
- `$REPO_ROOT/.clawdbot/scripts/spawn-agent.sh` — Spawn agent in tmux with worktree (called by dispatch.sh)
- `$REPO_ROOT/.clawdbot/scripts/fill-template.sh` — Substitute {VARIABLES} in prompt templates
- `$REPO_ROOT/.clawdbot/scripts/build-context-vars.sh` — Centralized template var builder (all phases)
- `$REPO_ROOT/.clawdbot/scripts/notify.sh` — Post Slack notifications
- `$REPO_ROOT/.clawdbot/scripts/auto-split.sh` — Split oversized tasks into subtasks
- `$REPO_ROOT/.clawdbot/scripts/gh-comment-dispatch.sh` — Dispatch fixes from GitHub PR comments

**Data:**
- Standard prompts: `$REPO_ROOT/.clawdbot/prompts/` (committed to repo)
- State: `~/.openclaw/{{WORKSPACE_NAME}}/pipeline/` (active-tasks.json, logs/, plans/) — this is separate from the workspace dir (which lives in the repo at `.openclaw/{{WORKSPACE_NAME}}/`)

## Task Registry
- `pipeline/active-tasks.json` — All active/completed tasks

## Claude Code Lessons
- **Always use `-p` flag** for background/non-interactive runs — skips trust + permissions prompts
- `--dangerously-skip-permissions` alone still shows interactive prompts that can race with keystrokes
- Correct: `claude --dangerously-skip-permissions -p "prompt"`
- Wrong: `claude --dangerously-skip-permissions "prompt"` (interactive, needs PTY + keystroke navigation)

## Slack Channels

| Channel Name | Channel ID | Purpose |
|---|---|---|
| `{{SLACK_PROJECT_CHANNEL_NAME}}` | `{{SLACK_PROJECT_CHANNEL}}` | Discussion, full plans posted here for review |
| `{{SLACK_ALERTS_CHANNEL_NAME}}` | `{{SLACK_ALERTS_CHANNEL}}` | Pipeline audit log, status updates, approvals |

- **For `message` tool `send` action: use `target` for the channel ID, NOT `channel`.** `channel` is for provider routing (slack/telegram/etc). Using `channel` with a channel ID causes a lowercase lookup bug and fails.
- **For `message` tool `react` action: use `channel` for the channel ID** (different from send!)
- **When a plan reaches plan_review**: post the FULL plan to the project channel (`{{SLACK_PROJECT_CHANNEL}}`), not just a summary. The human wants the complete plan text, not a summary.

## Agent Selection
- **Codex**: Backend logic, complex bugs, multi-file refactors, reasoning-heavy tasks
- **Claude Code**: Frontend work, UI changes, git operations, faster turnaround
- Pipeline default is `claude` (pass `--agent codex` to dispatch.sh for backend/reasoning-heavy tasks)
