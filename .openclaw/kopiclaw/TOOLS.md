# TOOLS.md - Local Notes

## Kopi Repo
- Path: `/Users/kopi/Projects/kopi`
- Monorepo: pnpm + turbo
- Packages: assistant (Next.js), shopify-conjure, promotions, landing-pages, rendition-figma-plugin, blog, discord, doc-sync-engine, supabase
- Deploy: Vercel (web), GCP Cloud Run (services), GitHub Actions on merge to main

## Coding Agents
- Claude Code: `${CLAUDE_PATH:-claude}` (v2.1.62)
- Codex: `codex` (v0.2.3)
- Worktrees: `/Users/kopi/Projects/kopi-worktrees/`

## Agent Swarm Scripts
- `$REPO_ROOT/.clawdbot/scripts/spawn-agent.sh` — Spawn agent in tmux with worktree
- `$REPO_ROOT/.clawdbot/scripts/dispatch.sh` — Orchestrator dispatch: validate, fill template, spawn agent
- `$REPO_ROOT/.clawdbot/scripts/check-agents.sh` — Check all agent statuses (tmux, PR, CI)
- `$REPO_ROOT/.clawdbot/scripts/monitor.sh` — Advance pipeline phases (launchd runs this)
- `$REPO_ROOT/.clawdbot/scripts/cleanup-worktrees.sh` — Clean merged/failed worktrees
- Standard prompts: `$REPO_ROOT/.clawdbot/prompts/` (committed to repo)
- State: `~/.openclaw/workspace-kopiclaw/pipeline/` (active-tasks.json, logs/, plans/)

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
| `#project-kopi-claw` | `C0AJAR3S76U` | Discussion, full plans posted here for review |
| `#alerts-kopi-claw` | `C0AHGH5FH42` | Pipeline audit log, status updates, approvals |

- **Always use `accountId=kopiclaw`** when posting to these channels (default account is `kl` which can't access them)
- **When a plan reaches plan_review**: post the FULL plan to `#project-kopi-claw` (C0AJAR3S76U), not just a summary. This is non-negotiable — Robert wants the complete plan text, not a summary.

## Agent Selection
- **Codex**: Backend logic, complex bugs, multi-file refactors, reasoning-heavy tasks
- **Claude Code**: Frontend work, UI changes, git operations, faster turnaround
- Default to Codex for most tasks unless frontend-specific
