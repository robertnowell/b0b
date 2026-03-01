#!/usr/bin/env bash
# gh-poll.sh — Poll GitHub for @kopi-claw mentions in tryrendition/Rendition
# Outputs JSON lines of new mentions to stdout.
set -euo pipefail

# Source shared config
# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="tryrendition/Rendition"
STATE_FILE="${STATE_DIR}/gh-poll-state.json"

# Initialize state file if missing
if [ ! -f "$STATE_FILE" ]; then
  echo '{"lastChecked":"1970-01-01T00:00:00Z","seenCommentIds":[]}' > "$STATE_FILE"
fi

LAST_CHECKED=$(python3 -c "import json; print(json.load(open('$STATE_FILE'))['lastChecked'])")
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Fetch issue comments and PR review comments since last check
gh api "repos/${REPO}/issues/comments?since=${LAST_CHECKED}&sort=updated&direction=desc&per_page=100" > /tmp/gh-poll-issue-comments.json 2>/dev/null || echo '[]' > /tmp/gh-poll-issue-comments.json
gh api "repos/${REPO}/pulls/comments?since=${LAST_CHECKED}&sort=updated&direction=desc&per_page=100" > /tmp/gh-poll-review-comments.json 2>/dev/null || echo '[]' > /tmp/gh-poll-review-comments.json

# Process with python
python3 "${SCRIPT_DIR}/gh-poll-process.py" \
  "$STATE_FILE" \
  "$NOW" \
  /tmp/gh-poll-issue-comments.json \
  /tmp/gh-poll-review-comments.json
