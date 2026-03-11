# ARCHITECTURE.md — Kopiclaw Agent Orchestration System

> Last updated: 2026-02-28

## 1. System Overview

Kopiclaw is an AI engineering orchestrator that manages the full lifecycle of software development tasks for the **Kopi AI** product (trykopi.ai). It runs inside [OpenClaw](https://openclaw.com), a platform for persistent AI agents with tool access, cron jobs, and messaging integrations.

**What Kopiclaw does:**
- Receives feature requests and bug reports (via Slack, webchat, or GitHub mentions)
- Decomposes them into pipeline tasks with structured phases
- Spawns coding agents (Claude Code, Codex) in isolated git worktrees
- Advances tasks through plan → review → implement → audit → fix → test → PR → merge
- Posts status updates to Slack at every phase transition
- Auto-reverts and splits tasks that exceed iteration limits

**What Kopiclaw does NOT do:**
- Read source code to investigate bugs (delegates to planning agents)
- Write or edit application code (delegates to coding agents)
- Skip pipeline phases, even for "simple" fixes

**Key principle:** Kopiclaw is an orchestrator, not a coder. Its value is product judgment, task decomposition, and quality gates.

## 2. Component Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                          OpenClaw Platform                          │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                    Kopiclaw Agent (main)                      │  │
│  │  • Webchat / Slack interface                                  │  │
│  │  • Product judgment & plan review                             │  │
│  │  • Task creation & pipeline management                        │  │
│  │  • Subagent spawning for investigation                        │  │
│  └──────────────┬──────────────────────────────┬─────────────────┘  │
│                 │                              │                     │
│     ┌───────────▼──────────┐      ┌────────────▼──────────────┐    │
│     │  Cron: monitor-      │      │  Cron: gh-poll-kopiclaw   │    │
│     │  pipeline (2 min)    │      │  (2 min, isolated)        │    │
│     │  → monitor.sh        │      │  → gh-poll.sh             │    │
│     └───────────┬──────────┘      └────────────┬──────────────┘    │
│                 │                              │                     │
│  ┌──────────────▼──────────────────────────────▼─────────────────┐  │
│  │                    Pipeline Scripts                            │  │
│  │  config.sh │ spawn-agent.sh │ dispatch.sh │ monitor.sh        │  │
│  │  check-agents.sh │ notify.sh │ fill-template.sh               │  │
│  │  approve-plan.sh │ reject-plan.sh │ review-plan.sh            │  │
│  │  cleanup-worktrees.sh │ gh-poll.sh │ gh-poll-process.py       │  │
│  └──────────┬────────────────────────────┬───────────────────────┘  │
│             │                            │                           │
│  ┌──────────▼──────────┐    ┌────────────▼──────────────────┐      │
│  │  Slack Integration   │    │  Notify Outbox                │      │
│  │  #alerts-kopi-claw   │    │  (notify-outbox.jsonl)        │      │
│  │  #project-kopi-claw  │    │  + Slack Webhook              │      │
│  └──────────────────────┘    └───────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────────┘
        │
        │ tmux sessions
        ▼
┌───────────────────────────────────────────────────────────────┐
│                      Coding Agents                             │
│                                                                │
│  ┌─────────────────┐          ┌─────────────────┐             │
│  │  Claude Code     │          │  Codex            │           │
│  │  (claude -p)     │          │  (codex exec)     │           │
│  │  Frontend, UI,   │          │  Backend, logic,  │           │
│  │  git ops         │          │  complex bugs     │           │
│  └────────┬────────┘          └────────┬──────────┘           │
│           │                            │                       │
│  ┌────────▼────────────────────────────▼──────────────────┐   │
│  │              Git Worktrees                              │   │
│  │  ~/Projects/kopi-worktrees/{task-id}/         │   │
│  │  One worktree per task, branched from origin/main       │   │
│  └────────────────────────┬───────────────────────────────┘   │
└───────────────────────────┼───────────────────────────────────┘
                            │
                            ▼
                ┌───────────────────────┐
                │  GitHub (PR + CI)     │
                │  tryrendition/        │
                │  Rendition            │
                └───────────────────────┘
```

## 3. Task Lifecycle

### Phase Diagram

```
                    ┌──────────┐
                    │  queued   │  (task created, not yet started)
                    └────┬─────┘
                         │
                    ┌────▼─────┐
              ┌────►│ planning  │◄──────────────────────────────┐
              │     └────┬─────┘                                │
              │          │ agent succeeds + plan file found      │
              │          │                                       │
              │     ┌────▼────────┐     plan rejected            │
              │     │ plan_review  │─────(reject-plan.sh)────────┘
              │     │ (human gate) │
              │     └────┬────────┘
              │          │ plan approved (approve-plan.sh)
              │          │
              │     ┌────▼──────────┐
              │     │ implementing   │
              │     └────┬──────────┘
              │          │ agent succeeds
              │          │
              │     ┌────▼─────┐     audit fails     ┌────────┐
              │     │ auditing  │────────────────────►│ fixing  │
              │     └────┬─────┘                      └───┬────┘
              │          │ audit passes                    │
              │          │                    ┌────────────┘
              │     ┌────▼─────┐              │ fixes applied
              │     │ testing   │◄────────────┘
              │     └────┬─────┘     test fails     ┌────────┐
              │          │ ─────────────────────────►│ fixing  │
              │          │ tests pass                └────────┘
              │          │
              │     ┌────▼────────┐
              │     │ pr_creating  │
              │     └────┬────────┘
              │          │
              │     ┌────▼────────┐
              │     │ reviewing    │  (wait for CI + human merge)
              │     └────┬────────┘
              │          │ CI passes
              │     ┌────▼─────┐
              │     │  merged   │  ✓ terminal
              │     └──────────┘
              │
              │ (any phase, max iterations exceeded)
              │     ┌────────────┐
              └─────│ needs_split │  ✗ terminal — requires manual decomposition
                    └────────────┘
```

### Phase Transitions Summary

| From | To | Trigger |
|---|---|---|
| planning | plan_review | Agent succeeds + plan file found + requiresPlanReview=true |
| planning | implementing | Agent succeeds + plan file found + requiresPlanReview=false |
| planning | needs_split | Max iterations exceeded |
| plan_review | implementing | Human runs `approve-plan.sh` |
| plan_review | planning | Human runs `reject-plan.sh` |
| plan_review | needs_split | Human runs `reject-plan.sh --split` |
| implementing | auditing | Agent succeeds |
| auditing | testing | AUDIT_VERDICT:PASS |
| auditing | fixing | AUDIT_VERDICT:FAIL (iterations remaining) |
| auditing | needs_split | AUDIT_VERDICT:FAIL (max iterations) |
| fixing | auditing | fixTarget=auditing, agent succeeds |
| fixing | testing | fixTarget=testing, agent succeeds |
| testing | pr_creating | TEST_VERDICT:PASS |
| testing | fixing | TEST_VERDICT:FAIL (iterations remaining) |
| pr_creating | reviewing | Agent succeeds |
| reviewing | merged | CI passes (polled by monitor.sh) |
| *any phase* | *same phase* | Timeout or failure (respawn, iteration++) |
| *any phase* | needs_split | Max iterations (4) exceeded → auto-revert |

### Verdict Protocol

Agents communicate results via structured lines in their log output:
- `AGENT_EXIT_SUCCESS` / `AGENT_EXIT_FAIL:<code>` — agent completion status
- `AGENT_DONE` — written after exit signal
- `AUDIT_VERDICT:PASS` / `AUDIT_VERDICT:FAIL` — audit result
- `TEST_VERDICT:PASS` / `TEST_VERDICT:FAIL` — test result
- `PLAN_VERDICT:READY` — plan is complete (in plan file or log)

## 4. Pipeline Scripts

All scripts live in `$REPO_ROOT/.clawdbot/scripts/` (committed to the Rendition repo). `$REPO_ROOT` is `~/Projects/kopi`.

### config.sh
Shared configuration sourced by every other script. Defines paths:
- `REPO_ROOT` → `~/Projects/kopi` (git rev-parse)
- `CLAWDBOT_DIR` → `$REPO_ROOT/.clawdbot` (scripts + prompts, committed)
- `STATE_DIR` → `~/.openclaw/workspace-kopiclaw/pipeline` (runtime state, not committed; override with `CLAWDBOT_STATE_DIR` env var)
- `WORKTREE_BASE` → `~/Projects/kopi-worktrees`
- `TASKS_FILE` → `$STATE_DIR/active-tasks.json`
- `LOCK_FILE` → `$STATE_DIR/.tasks.lock`
- `MAX_RUNTIME_SECONDS` → 2700 (45 min)
- `MAX_ITERATIONS` → 4
- `CLAUDE_PATH`, `CODEX_PATH` — agent binaries
- `SLACK_WEBHOOK_URL` — Slack incoming webhook
- `NOTIFY_OUTBOX` — JSONL file for async notification relay

### spawn-agent.sh
**The foundational agent launcher.** Creates a git worktree, spawns a coding agent in a tmux session, and registers the task.

Flow:
1. Parse args: task-id, branch, agent type, prompt file, optional model, flags (--phase, --description, --product-goal)
2. Validate inputs (regex checks to prevent injection)
3. `git worktree add` from `origin/main`
4. Kill any existing tmux session for this task
5. Write a wrapper script to `/tmp/agent-{task-id}-run.sh` that:
   - Sets up PATH and environment
   - Runs `pnpm install --frozen-lockfile`
   - Runs the agent (claude -p or codex exec) with the prompt
   - Writes `AGENT_EXIT_SUCCESS`/`AGENT_EXIT_FAIL` + `AGENT_DONE` to log
6. Launch wrapper in tmux: `tmux new-session -d -s agent-{task-id}`
7. Register task in active-tasks.json (with flock for concurrency safety)
8. Send Slack notification via `notify()`

### dispatch.sh
**High-level task dispatcher.** Entry point for starting a new task or advancing to a specific phase.

Flow:
1. Parse named args (--task-id, --branch, --agent, --phase, --plan-file, etc.)
2. Select prompt template based on phase (plan.md, implement.md, audit.md, etc.)
3. Fill template via `fill-template.sh`
4. Call `spawn-agent.sh` with the filled prompt
5. Set `requiresPlanReview` flag on the task
6. Send Slack notification

### monitor.sh
**The state machine brain.** Runs on cron (every 2 min via OpenClaw, every 5 min via launchd). Idempotent.

Flow:
1. Call `check-agents.sh` to get current status of all tasks
2. For each task, evaluate the state machine:
   - **Running** → skip (wait for completion)
   - **Timeout** → increment iteration, respawn or mark needs_split
   - **Failed** → increment iteration, respawn or mark needs_split
   - **Succeeded** → advance to next phase (spawn next agent)
   - **plan_review / reviewing** → human gates, no auto-advance
3. Uses `apply_updates()` with flock for atomic task updates
4. 60-second race guard prevents concurrent monitor runs from double-acting
5. Cross-agent rule: implementing agent ≠ auditing agent (codex↔claude)

### check-agents.sh
**Status checker.** Reads active-tasks.json and determines each task's effective status.

Checks:
- Is tmux session alive? (`tmux has-session`)
- Does log contain `AGENT_EXIT_SUCCESS` or `AGENT_EXIT_FAIL`?
- Has the agent exceeded `MAX_RUNTIME_SECONDS`? (kills tmux if so)
- Any open PR on the branch? CI status?

Outputs structured JSON with per-task status and summary counts. Also writes status back to active-tasks.json.

### approve-plan.sh / reject-plan.sh
**Plan review gates.** Only operate on tasks in `plan_review` phase.

- `approve-plan.sh <task-id>` → reads plan from `plans/{task-id}.md`, fills implement.md template, spawns implementing agent
- `reject-plan.sh <task-id> [--reason "..."]` → respawns planning agent with rejection feedback appended to prompt
- `reject-plan.sh <task-id> --split` → marks task as `needs_split`

### notify.sh
**Slack notification dispatcher.** Dual-mode: sourceable function + CLI entrypoint.

- Formats notification with task-id, phase, message, product goal, next step
- Appends to `notify-outbox.jsonl` for async relay by Kopiclaw
- Also sends directly via Slack webhook (`curl -X POST`)
- Auto-infers next step from phase if not provided

### fill-template.sh
**Prompt template engine.** Replaces `{VAR_NAME}` placeholders in template files.

- Usage: `fill-template.sh template.md --var KEY="value" --var KEY2="value2"`
- Handles multi-line values (via Python replacement)
- Warns on unresolved placeholders to stderr

### review-plan.sh
**Synchronous plan review.** Runs a second agent (non-interactively, no tmux) to review a plan and score uncertainty.

- Fills `review-plan.md` template with feature description and plan
- Runs agent with timeout, captures output
- Parses output for uncertainty score (1-5), concerns, improvements
- Returns structured JSON with recommendation (proceed/split)

### cleanup-worktrees.sh
**Garbage collector.** Removes worktrees and task entries for completed/abandoned tasks.

- Kills tmux sessions for merged/needs_split/abandoned tasks
- `git worktree remove --force`
- Removes cleaned tasks from active-tasks.json

### gh-poll.sh + gh-poll-process.py
**GitHub mention poller.** Checks for `@kopi-claw` mentions in the product repo.

- Uses `gh api` to fetch issue comments and PR review comments since last check
- `gh-poll-process.py` filters for mentions, deduplicates via `seenCommentIds`
- State persisted in `gh-poll-state.json`
- Outputs JSONL of new mentions to stdout

## 5. Data Model

### active-tasks.json

The central task registry. Lives at `~/.openclaw/workspace-kopiclaw/pipeline/active-tasks.json` (runtime state, not committed to repo). Array of task objects, protected by flock on `.tasks.lock`.

```jsonc
{
  "id": "ios-visibility-bug",          // unique task identifier
  "branch": "fix/ios-visibility-image-gen", // git branch name
  "agent": "claude",                    // primary agent: "claude" | "codex"
  "tmuxSession": "agent-ios-visibility-bug", // tmux session name
  "status": "succeeded",               // effective status (set by check-agents.sh)
  "phase": "plan_review",              // current pipeline phase
  "iteration": 1,                      // current iteration count
  "maxIterations": 4,                  // max before auto-revert
  "startedAt": "2026-02-27T23:48:35Z", // UTC timestamp
  "completedAt": "2026-02-27T23:53:37Z", // set on completion
  "worktree": "~/Projects/kopi-worktrees/ios-visibility-bug",
  "logFile": "...pipeline/logs/agent-ios-visibility-bug.log",
  "description": "iOS Safari tab backgrounding triggers false error toast",
  "productGoal": "Image generation survives tab backgrounding on iOS",
  "userRequest": "",                   // original user request text
  "findings": [                        // accumulated per-iteration findings
    "Plan #1: not ready - No plan file found"
  ],
  "fixTarget": "auditing",            // where fixing routes back to: "auditing" | "testing"
  "requiresPlanReview": true,          // whether plan_review is a human gate
  "planFile": "...pipeline/plans/ios-visibility-bug.md",
  "planContent": "# Plan: Fix iOS...", // full plan text (carried through phases)
  "lastMonitorAction": 1772236421,     // epoch timestamp of last monitor action (race guard)
  "failReason": "timeout"              // set on failure: "timeout" | "agent_error" | "deps_install"
}
```

### Phase Values
`planning` → `plan_review` → `implementing` → `auditing` → `fixing` → `testing` → `pr_creating` → `reviewing` → `merged` | `needs_split`

### Other State Files

| File | Purpose |
|---|---|
| `pipeline/active-tasks.json` | Task registry |
| `pipeline/.tasks.lock` | flock file for concurrent access |
| `pipeline/gh-poll-state.json` | GitHub polling cursor + seen comment IDs |
| `pipeline/notify-outbox.jsonl` | Queued Slack notifications for async relay |
| `pipeline/plans/{task-id}.md` | Archived plans (copied from worktrees) |
| `pipeline/logs/agent-{task-id}.log` | Agent stdout/stderr |
| `pipeline/logs/prompt-{task-id}-{phase}-{timestamp}.md` | Filled prompts (audit trail) |
| `pipeline/logs/monitor.log` | Monitor run log |
| `pipeline/logs/launchd-monitor.log` | launchd stdout/stderr |

## 6. Cron / Monitoring

### OpenClaw Cron Jobs

| Job | Schedule | Session | What it does |
|---|---|---|---|
| `monitor-pipeline` | Every 2 min | Main session | Runs `monitor.sh` — advances tasks through phases |
| `gh-poll-kopiclaw` | Every 2 min | Isolated | Runs `gh-poll.sh` — checks for @kopi-claw GitHub mentions |

### launchd Agent

`com.kopiclaw.monitor` — runs `$REPO_ROOT/.clawdbot/scripts/monitor.sh` every 5 minutes as a macOS launch agent. This is a redundant execution path alongside the OpenClaw cron (belt and suspenders).

### Failure Detection

- **Agent timeout:** `check-agents.sh` compares `startedAt` + `MAX_RUNTIME_SECONDS` (45 min). Kills tmux on timeout.
- **Agent crash:** tmux session dead + no `AGENT_DONE` in log → status `unknown`
- **Agent error:** `AGENT_EXIT_FAIL` or `AGENT_FAIL:deps_install` in log
- **Max iterations:** After 4 iterations (implement→audit→fix loops), auto-revert to `origin/main` and mark `needs_split`
- **Stale plan_review:** Currently no timeout — human gate can stall indefinitely (known gap)

## 7. Communication

### Slack Channels

| Channel | ID | Purpose |
|---|---|---|
| `#alerts-kopi-claw` | `C0AHGH5FH42` | **Pipeline audit log.** Every phase transition, every agent spawn, every verdict. The single source of truth for task status. |
| `#project-kopi-claw` | `C0AJAR3S76U` | Discussion channel for the Kopiclaw project itself. |

### Notification Flow

```
Pipeline event (phase transition, spawn, failure)
    │
    ├──► notify.sh appends to notify-outbox.jsonl (async relay queue)
    │
    └──► notify.sh POSTs to Slack webhook (direct, best-effort)
```

### Notification Format

```
🔧 *Task:* {task-id} | *Phase:* {phase}
📦 *Goal:* {product-goal}
⚙️ {message}
➡️ *Next:* {inferred or explicit next step}
```

### Slack Account

Kopiclaw posts via `accountId=kopiclaw` (bound in OpenClaw config). The default account (`kl`) cannot access these channels.

## 8. Prompt System

### Templates

Standard templates live in `$REPO_ROOT/.clawdbot/prompts/` (committed to repo). Task-specific one-off prompts live in `~/.openclaw/workspace-kopiclaw/pipeline/prompts/`. All templates use `{VAR_NAME}` placeholder syntax.

| Template | Phase | Key Variables |
|---|---|---|
| `plan.md` | planning | PRODUCT_GOAL, TASK_DESCRIPTION, PRD, DELIVERABLES, TASK_ID |
| `implement.md` | implementing | PRD, PLAN, DELIVERABLES, TASK_DESCRIPTION |
| `audit.md` | auditing | PRD, PLAN (receives git diff) |
| `fix-feedback.md` | fixing | TASK_DESCRIPTION, FEEDBACK (last 200 lines of audit/test log) |
| `test.md` | testing | DESCRIPTION, PRODUCT_GOAL, DIFF (git diff) |
| `create-pr.md` | pr_creating | TASK_DESCRIPTION |
| `review-plan.md` | plan review | FEATURE, PLAN |

### Template Filling

`fill-template.sh` handles substitution. The pipeline automatically enriches prompts:
- **Audit/test phases:** DIFF is populated with `git diff main...HEAD` from the worktree
- **Fix phase:** FEEDBACK is populated with the last 200 lines of the previous agent's log
- **Iteration context:** If there are previous findings, they're appended as a section

### Custom Prompts

Some tasks use one-off prompt files (e.g., `ios-visibility-image-gen-bug.md`, `mobile-library-gen.md`) that are passed directly to `spawn-agent.sh` instead of going through `dispatch.sh` template filling.

## 9. Infrastructure

### Git Worktrees

- **Base:** `~/Projects/kopi-worktrees/`
- **Convention:** One worktree per task, named by task-id
- **Branch:** Created from `origin/main` (fetched before creation)
- **Lifecycle:** Created by `spawn-agent.sh`, cleaned by `cleanup-worktrees.sh`
- **Reuse:** If a worktree already exists (respawn case), it's reused with the existing branch

### tmux Sessions

- **Naming:** `agent-{task-id}`
- **One session per active task**
- **Killed:** On respawn, timeout, cleanup, or auto-revert
- **Wrapper scripts:** Written to `/tmp/agent-{task-id}-run.sh` — sets up PATH, installs deps, runs agent, writes exit signals

### Coding Agents

| Agent | Path | Usage | Invocation |
|---|---|---|---|
| Claude Code | `${CLAUDE_PATH:-claude}` | Frontend, UI, git ops, faster | `claude --model claude-opus-4-6 --dangerously-skip-permissions -p - < prompt` |
| Codex | `${CODEX_PATH:-codex}` | Backend, complex bugs, reasoning | `codex exec --dangerously-bypass-approvals-and-sandbox < prompt` |

**Cross-agent rule:** The implementing agent never audits its own work. If Claude implements, Codex audits (and vice versa).

### Product Repo

- **Path:** `~/Projects/kopi/`
- **GitHub:** `tryrendition/Rendition`
- **Stack:** pnpm monorepo + turbo (Next.js, Shopify, promotions, etc.)
- **Deploy:** Vercel (web), GCP Cloud Run (services), GitHub Actions on merge to main

### Workspace Layout

```
~/Projects/kopi/.clawdbot/    # Committed to repo
├── scripts/                # All pipeline bash/python scripts
├── prompts/                # Standard prompt templates (plan.md, implement.md, etc.)
└── README.md

~/.openclaw/workspace-kopiclaw/   # Runtime state (not committed)
├── AGENTS.md          # Session startup instructions
├── ARCHITECTURE.md    # This document
├── HEARTBEAT.md       # Periodic check configuration
├── IDENTITY.md        # Kopiclaw identity (name, GitHub, vibe)
├── SOUL.md            # Personality, execution discipline, boundaries
├── TOOLS.md           # Local notes (paths, channels, agent tips)
├── USER.md            # About the human (Robert)
├── WORKFLOW.md        # Engineering pipeline methodology
├── memory/            # Daily notes + investigation logs
├── plans/             # Migration plans and workspace-level plans
└── pipeline/
    ├── active-tasks.json       # Task registry
    ├── gh-poll-state.json      # GitHub polling state
    ├── notify-outbox.jsonl     # Notification queue
    ├── .tasks.lock             # flock concurrency lock
    ├── prompts/                # Task-specific one-off prompts only
    ├── plans/                  # Archived task plans
    └── logs/                   # Agent logs, monitor logs, filled prompts
```

## 10. Known Gaps & Limitations

### Dead Agent Detection
- If a tmux session dies without writing `AGENT_DONE` to the log, `check-agents.sh` reports status `unknown`. The monitor treats `unknown` similarly to `failed` only for explicit failure handling, but running tasks that silently die may not be detected until the next monitor cycle evaluates them.

### Plan Review Staleness
- `plan_review` has no timeout. A task can sit in plan_review indefinitely waiting for human approval. No reminder notifications are sent. Future improvement: staleness alert after 24h.

### No Concurrent Task Limit
- There's no limit on how many agents can run simultaneously. Multiple tmux sessions with Claude Code / Codex could exhaust system resources (memory, API rate limits).

### Notification Reliability
- Slack webhook delivery is best-effort (`curl` ignoring errors). The `notify-outbox.jsonl` provides a secondary record but there's no retry mechanism for failed webhook deliveries.

### Out-of-Band Task Tracking
- Tasks created outside the pipeline (manual git branches, direct PRs) are invisible to the system. Only tasks registered in `active-tasks.json` are tracked.

### Single-Machine Dependency
- The entire system runs on one MacBook Pro. tmux sessions, worktrees, launchd agents, and the OpenClaw runtime are all local. No remote/cloud redundancy.

### Duplicate Cron Execution
- `monitor.sh` runs via both OpenClaw cron (every 2 min) and launchd (every 5 min). The 60-second race guard in monitor.sh prevents double-acting, but this is a fragile dedup mechanism.

### No Rollback on Partial Phase Transitions
- If `spawn-agent.sh` succeeds but the subsequent `apply_updates()` fails, the task state in JSON may not reflect the spawned agent. The agent runs but the pipeline doesn't know about the phase change.

### GitHub Polling Limitations
- `gh-poll.sh` only checks issue comments and PR review comments. Direct PR body mentions, commit message mentions, and issue body mentions are not polled.

### Worktree Cleanup Timing
- `cleanup-worktrees.sh` must be run manually. There's no cron job for it. Merged/abandoned worktrees accumulate until someone runs it.
