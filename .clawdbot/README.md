# .clawdbot — Agent Pipeline Infrastructure

Scripts and prompt templates for the automated agent pipeline. This directory is committed to the repo so that worktrees have access to the pipeline tooling.

## Directory Structure

```
.clawdbot/
├── scripts/       # Pipeline orchestration scripts
│   ├── config.sh           # Shared config (sourced by all scripts)
│   ├── dispatch.sh         # Dispatch a new task into the pipeline
│   ├── spawn-agent.sh      # Spawn a coding agent in a worktree + tmux
│   ├── monitor.sh          # State machine that advances tasks through phases
│   ├── check-agents.sh     # Check status of all active agents
│   ├── fill-template.sh    # Fill prompt templates with variable substitution
│   ├── notify.sh           # Slack notifications for pipeline events
│   ├── approve-plan.sh     # Approve a plan and start implementation
│   ├── reject-plan.sh      # Reject a plan (re-plan or split)
│   ├── review-plan.sh      # Send plan to a second agent for review
│   ├── cleanup-worktrees.sh # Remove completed worktrees
│   ├── gh-poll.sh          # Poll GitHub for @kopi-claw mentions
│   └── gh-poll-process.py  # Process GitHub poll results
└── prompts/       # Generic prompt templates ({VAR} placeholders)
    ├── plan.md
    ├── implement.md
    ├── audit.md
    ├── test.md
    ├── fix-feedback.md
    ├── create-pr.md
    └── review-plan.md
```

## State Files

State files (active tasks, logs, plans, lock files) live **outside** the repo at:

```
~/.openclaw/workspace-kopiclaw/pipeline/
```

Override with the `CLAWDBOT_STATE_DIR` environment variable.

## Environment Variables

| Variable | Description | Default |
|---|---|---|
| `CLAWDBOT_STATE_DIR` | Where state files live | `~/.openclaw/workspace-kopiclaw/pipeline` |
| `SLACK_WEBHOOK_URL` | Slack webhook for notifications | *(none)* |
| `MAX_RUNTIME_SECONDS` | Agent timeout | `2700` (45 min) |
| `MAX_ITERATIONS` | Max audit/fix iterations | `4` |

## Dispatching a Task

```bash
.clawdbot/scripts/dispatch.sh \
  --task-id my-feature \
  --branch feat/my-feature \
  --product-goal "Add widget support" \
  --description "Implement widget component with tests" \
  --agent claude \
  --phase planning
```

The pipeline will advance the task through: planning → plan_review → implementing → auditing → fixing → testing → pr_creating → reviewing → pr_ready → merged.
