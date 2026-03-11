#!/usr/bin/env bash
# config.sh — Shared configuration for agent pipeline scripts
# Source this at the top of every pipeline script

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLAWDBOT_DIR="${REPO_ROOT}/.clawdbot"
PROMPTS_DIR="${CLAWDBOT_DIR}/prompts"

# State lives outside the repo (not committed). Override with CLAWDBOT_STATE_DIR env var.
STATE_DIR="${CLAWDBOT_STATE_DIR:-${HOME}/.openclaw/workspace-kopiclaw/pipeline}"

TASKS_FILE="${STATE_DIR}/active-tasks.json"
LOCK_FILE="${STATE_DIR}/.tasks.lock"
LOG_DIR="${STATE_DIR}/logs"
PLANS_DIR="${STATE_DIR}/plans"

WORKTREE_BASE="${WORKTREE_BASE:-${HOME}/Projects/kopi-worktrees}"

MAX_RUNTIME_SECONDS="${MAX_RUNTIME_SECONDS:-2700}"
PLANNING_TIMEOUT_SECONDS="${PLANNING_TIMEOUT_SECONDS:-1200}"   # 20 minutes
MAX_ITERATIONS="${MAX_ITERATIONS:-4}"
MAX_AUTO_RETRIES="${MAX_AUTO_RETRIES:-1}"   # Max times a task can auto-retry from needs_split
MAX_SPLIT_DEPTH="${MAX_SPLIT_DEPTH:-1}"     # Max depth of auto-split (no splitting splits of splits)
MAX_AUTO_SPLIT_ATTEMPTS="${MAX_AUTO_SPLIT_ATTEMPTS:-2}"  # Max failed auto-split attempts before terminal needs_split

# Usage: eval "$(get_task_paths true)"  or  eval "$(get_task_paths false)"
# Sets: EFFECTIVE_REPO, EFFECTIVE_WORKTREE_BASE
get_task_paths() {
  local is_workspace="${1:-false}"
  if [ "$is_workspace" = "true" ]; then
    echo "EFFECTIVE_REPO='$WORKSPACE_REPO'"
    echo "EFFECTIVE_WORKTREE_BASE='$WORKSPACE_WORKTREE_BASE'"
  else
    echo "EFFECTIVE_REPO='$REPO_ROOT'"
    echo "EFFECTIVE_WORKTREE_BASE='$WORKTREE_BASE'"
  fi
}

# GitHub comment dispatch config
GH_COMMENT_DISPATCH_ENABLED="${GH_COMMENT_DISPATCH_ENABLED:-true}"
GH_COMMENT_DEFAULT_AGENT="${GH_COMMENT_DEFAULT_AGENT:-claude}"
GH_COMMENT_MAX_DISPATCHES="${GH_COMMENT_MAX_DISPATCHES:-3}"
GH_POLL_STATE_FILE="${GH_POLL_STATE_FILE:-${STATE_DIR}/gh-poll-state.json}"
GH_COMMENT_KNOWN_BOTS="${GH_COMMENT_KNOWN_BOTS:-kilo-code[bot],github-actions[bot]}"
GH_COMMENT_QUEUE_FILE="${STATE_DIR}/gh-comment-queue.jsonl"

CLAUDE_PATH="${CLAUDE_PATH:-claude}"
CODEX_PATH="${CODEX_PATH:-codex}"
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
SLACK_PROJECT_CHANNEL="C0AJAR3S76U"    # #project-kopi-claw
SLACK_ALERTS_CHANNEL="C0AHGH5FH42"     # #alerts-kopi-claw
SLACK_REVIEW_USER="UXXXXXXXXXXXX"        # reviewer — ping on plan_review

# Read bot token from credentials file if env var not set
if [ -z "${SLACK_BOT_TOKEN:-}" ] && [ -f "${HOME}/.openclaw/credentials/slack-bot-token" ]; then
  SLACK_BOT_TOKEN="$(cat "${HOME}/.openclaw/credentials/slack-bot-token")"
fi

# Ensure dirs exist
mkdir -p "$LOG_DIR" "$PLANS_DIR"
