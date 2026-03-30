#!/usr/bin/env bash
# rebuild-from-kopi.sh — Rebuild b0b repo from filtered kopi history
#
# Extracts .clawdbot/, .openclaw/, and b0b-world/ from the kopi monorepo,
# preserving full commit history, then force-pushes to robertnowell/b0b.
#
# Secrets are scrubbed via .secret-replacements (gitignored, not committed).
# Format: one line per secret, e.g.:  secret_value==>REDACTED_LABEL
#
# Usage: ./rebuild-from-kopi.sh
set -euo pipefail

KOPI_DIR="${KOPI_DIR:-$HOME/Projects/kopi}"
B0B_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPLACEMENTS_FILE="$B0B_DIR/.secret-replacements"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

echo "=== Step 1: Clone kopi into temp dir ==="
git clone --no-local "$KOPI_DIR" "$TEMP_DIR/kopi"
cd "$TEMP_DIR/kopi"

echo ""
echo "=== Step 2: Filter to b0b-related paths ==="
git filter-repo \
  --path .clawdbot/ \
  --path .openclaw/ \
  --path promotions/b0b-world/ \
  --path-rename 'promotions/b0b-world/:b0b-world/' \
  --force

if [ -f "$REPLACEMENTS_FILE" ]; then
  echo ""
  echo "=== Step 2b: Scrub secrets ==="
  git filter-repo --replace-text "$REPLACEMENTS_FILE" --force
else
  echo ""
  echo "WARNING: No .secret-replacements file found at $REPLACEMENTS_FILE"
  echo "         Secrets will NOT be scrubbed. Create the file to fix this."
fi

echo ""
echo "=== Step 3: Copy standalone b0b files ==="
for f in README.md LICENSE .gitignore b0b.png rebuild-from-kopi.sh; do
  if [ -f "$B0B_DIR/$f" ]; then
    cp "$B0B_DIR/$f" .
    echo "  copied $f"
  fi
done
chmod +x rebuild-from-kopi.sh 2>/dev/null || true

git add -A
git commit -m "Add README, LICENSE, .gitignore, b0b.png, rebuild script" || true

echo ""
echo "=== Step 4: Summary ==="
echo "Branches:"
git branch
echo ""
echo "Commit count (main): $(git rev-list --count main)"
echo "Repo size:"
du -sh .git
echo ""
git log --oneline -15
echo ""

read -p "Force push main to robertnowell/b0b? [y/N] " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo "Aborted."
  exit 0
fi

echo ""
echo "=== Step 5: Force push ==="
git remote add b0b git@github.com:robertnowell/b0b.git 2>/dev/null || git remote set-url b0b git@github.com:robertnowell/b0b.git
git push b0b --force main

echo ""
echo "=== Done! ==="
