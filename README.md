# b0b

<p align="center">
  <img src="b0b.png" alt="b0b" width="600">
</p>

An AI agent pipeline that takes coding tasks from dispatch through planning, implementation, auditing, testing, and PR creation using [Claude](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/overview) and [Codex](https://openai.com/index/introducing-codex/) agents in isolated git worktrees.

## How It Works

Each task moves through a state machine of phases, driven by a monitor loop that runs every few minutes. Agents run in tmux sessions against dedicated git worktrees, so multiple tasks can execute in parallel without interfering with each other.

```mermaid
flowchart LR
    planning --> plan_review
    plan_review --> implementing
    implementing --> auditing
    auditing --> fixing
    fixing --> testing
    testing --> pr_creating
    pr_creating --> reviewing
    reviewing --> pr_ready
    pr_ready --> merged
```

| Phase | What happens |
|---|---|
| **planning** | Agent writes a plan; outputs `PLAN_VERDICT:READY` when done |
| **plan_review** | Optional human gate -- approve or reject the plan |
| **implementing** | Agent implements the plan in an isolated worktree |
| **auditing** | A different agent reviews the implementation for correctness |
| **fixing** | Agent addresses audit findings |
| **testing** | Agent runs tests and verifies the change |
| **pr_creating** | Agent creates a pull request |
| **reviewing** | Waits for CI and human review |
| **pr_ready** | CI passes, ready for merge |
| **merged** | Done |

Tasks that exceed iteration limits are marked `needs_split` and can be broken into subtasks with `auto-split.sh`.

## Project Structure

```
.clawdbot/
├── scripts/          Bash pipeline orchestration (dispatch, monitor, spawn, notify, etc.)
├── prompts/          Prompt templates with {VAR} placeholders (plan, implement, audit, test, fix, PR)
└── plans/            Design documents for the pipeline itself

.openclaw/
├── kopiclaw/         Workspace identity, persona, tools, architecture, and memory files
└── kl/               Alternate workspace variant (K&L email pipeline)
```

See [`.clawdbot/README.md`](.clawdbot/README.md) for detailed script-by-script documentation.

## Prerequisites

- **macOS** (scripts assume macOS paths and `launchd`)
- **bash**, **python3** (stdlib only -- no pip dependencies), **git**, **tmux**, **curl**
- **[gh](https://cli.github.com/)** (GitHub CLI), authenticated via `gh auth login`
- **[claude](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/overview)** (Claude Code CLI) and/or **[codex](https://openai.com/index/introducing-codex/)** in your `PATH`

## Installation

```bash
# 1. Clone
git clone <repo-url> && cd b0b

# 2. Create the state directory (lives outside the repo)
mkdir -p ~/.openclaw/workspace-kopiclaw/pipeline/{logs,plans}

# 3. Create the worktree base directory
mkdir -p ~/Projects/kopi-worktrees
# Or override later: export WORKTREE_BASE=/your/preferred/path

# 4. Set up Slack credentials (optional -- needed for notifications)
mkdir -p ~/.openclaw/credentials
echo "xoxb-your-slack-bot-token" > ~/.openclaw/credentials/slack-bot-token
chmod 600 ~/.openclaw/credentials/slack-bot-token

# 5. Authenticate GitHub CLI
gh auth login
```

## Configuration

All configuration lives in [`.clawdbot/scripts/config.sh`](.clawdbot/scripts/config.sh). Every variable can be overridden via environment variables.

| Variable | Description | Default |
|---|---|---|
| `CLAWDBOT_STATE_DIR` | Root directory for state files, logs, and plans | `~/.openclaw/workspace-kopiclaw/pipeline` |
| `WORKTREE_BASE` | Where git worktrees are created for tasks | `~/Projects/kopi-worktrees` |
| `CLAUDE_PATH` | Path to the Claude CLI | `claude` |
| `CODEX_PATH` | Path to the Codex CLI | `codex` |
| `SLACK_BOT_TOKEN` | Slack bot token for notifications | *(read from `~/.openclaw/credentials/slack-bot-token` if unset)* |
| `MAX_RUNTIME_SECONDS` | Agent timeout per phase | `2700` (45 min) |
| `PLANNING_TIMEOUT_SECONDS` | Planning-specific timeout | `1200` (20 min) |
| `MAX_ITERATIONS` | Max audit/fix cycles before giving up | `4` |
| `MAX_AUTO_RETRIES` | Max times a task can auto-retry from `needs_split` | `1` |
| `MAX_SPLIT_DEPTH` | Max depth of automatic task splitting | `1` |
| `GH_COMMENT_DISPATCH_ENABLED` | Auto-dispatch tasks from GitHub `@kopi-claw` mentions | `true` |
| `GH_COMMENT_DEFAULT_AGENT` | Which agent to use for new tasks | `claude` |
| `GH_COMMENT_MAX_DISPATCHES` | Max tasks dispatched per monitor cycle | `3` |

## Usage

### Dispatch a task

```bash
.clawdbot/scripts/dispatch.sh \
  --task-id my-feature \
  --branch feat/my-feature \
  --product-goal "Add widget support" \
  --description "Implement widget component with tests" \
  --user-request "Original conversation context" \
  --agent claude \
  --phase planning
```

The `--user-request` flag provides the original conversation context shown to the planning agent. Without it, the agent investigates the codebase independently and may choose an approach you didn't intend.

### Approve or reject a plan

```bash
.clawdbot/scripts/approve-plan.sh <task-id>
.clawdbot/scripts/reject-plan.sh <task-id> --reason "scope too broad"
```

### Check pipeline status

```bash
.clawdbot/scripts/pipeline-status.sh   # Slack-formatted summary
.clawdbot/scripts/check-agents.sh      # Raw agent status
```

### Run the monitor loop

The monitor is the heartbeat of the pipeline. It checks agent status, advances phases, processes GitHub mentions, and sends Slack notifications.

```bash
.clawdbot/scripts/monitor.sh
```

In production, run it on a schedule (e.g. every 5 minutes via `launchd` or `cron`).

### Clean up completed worktrees

```bash
.clawdbot/scripts/cleanup-worktrees.sh
```

## Running Tests

```bash
python3 -m pytest .clawdbot/scripts/
```

Or run individual test files:

```bash
python3 .clawdbot/scripts/test_monitor_phase_advance.py
python3 .clawdbot/scripts/test_gh_poll_process.py
```

## License

[MIT](LICENSE)
