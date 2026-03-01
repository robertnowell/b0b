#!/usr/bin/env bash
# config.sh — Shared configuration for agent pipeline scripts
# Source this at the top of every pipeline script

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "/Users/kopi/Projects/kopi")"
CLAWDBOT_DIR="${REPO_ROOT}/.clawdbot"
PROMPTS_DIR="${CLAWDBOT_DIR}/prompts"

# State lives outside the repo (not committed). Override with CLAWDBOT_STATE_DIR env var.
STATE_DIR="${CLAWDBOT_STATE_DIR:-${HOME}/.openclaw/workspace-kopiclaw/pipeline}"

TASKS_FILE="${STATE_DIR}/active-tasks.json"
LOCK_FILE="${STATE_DIR}/.tasks.lock"
LOG_DIR="${STATE_DIR}/logs"
PLANS_DIR="${STATE_DIR}/plans"
NOTIFY_OUTBOX="${STATE_DIR}/notify-outbox.jsonl"

WORKTREE_BASE="/Users/kopi/Projects/kopi-worktrees"
WORKSPACE_REPO="/Users/kopi/.openclaw/workspace-kopiclaw"
WORKSPACE_WORKTREE_BASE="/Users/kopi/.openclaw/kopi-worktrees"

MAX_RUNTIME_SECONDS="${MAX_RUNTIME_SECONDS:-2700}"
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

CLAUDE_PATH="${CLAUDE_PATH:-claude}"
CODEX_PATH="${CODEX_PATH:-codex}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

# Ensure dirs exist
mkdir -p "$LOG_DIR" "$PLANS_DIR"
