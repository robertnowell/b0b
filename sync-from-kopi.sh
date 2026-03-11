#!/usr/bin/env bash
# sync-from-kopi.sh — Pull latest .clawdbot/ and .openclaw/ from the kopi repo
set -euo pipefail

KOPI_DIR="${KOPI_DIR:-$HOME/Projects/kopi}"
B0B_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -d "$KOPI_DIR/.clawdbot" ]; then
  echo "ERROR: $KOPI_DIR/.clawdbot not found. Set KOPI_DIR if your kopi repo is elsewhere."
  exit 1
fi

echo "Syncing from $KOPI_DIR → $B0B_DIR"

rsync -av --delete \
  --exclude='.git' \
  "$KOPI_DIR/.clawdbot/" "$B0B_DIR/.clawdbot/"

rsync -av --delete \
  --exclude='.git' \
  "$KOPI_DIR/.openclaw/" "$B0B_DIR/.openclaw/"

cd "$B0B_DIR"

if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  echo "Already up to date — no changes to sync."
  exit 0
fi

echo ""
echo "=== Changes ==="
git --no-pager diff --stat
git ls-files --others --exclude-standard | sed 's/^/  new: /'
echo ""
echo "Review above, then commit and push:"
echo "  cd $B0B_DIR && git add -A && git commit -m 'sync from kopi' && git push"
