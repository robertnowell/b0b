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

MAX_RUNTIME_SECONDS="${MAX_RUNTIME_SECONDS:-2700}"
MAX_ITERATIONS="${MAX_ITERATIONS:-4}"
MAX_AUTO_RETRIES="${MAX_AUTO_RETRIES:-1}"   # Max times a task can auto-retry from needs_split
MAX_SPLIT_DEPTH="${MAX_SPLIT_DEPTH:-1}"     # Max depth of auto-split (no splitting splits of splits)
MAX_AUTO_SPLIT_ATTEMPTS="${MAX_AUTO_SPLIT_ATTEMPTS:-2}"  # Max failed auto-split attempts before terminal needs_split

CLAUDE_PATH="${CLAUDE_PATH:-claude}"
CODEX_PATH="${CODEX_PATH:-codex}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

# Ensure dirs exist
mkdir -p "$LOG_DIR" "$PLANS_DIR"
