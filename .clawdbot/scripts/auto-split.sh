#!/usr/bin/env bash
# auto-split.sh — Analyze a failed task and produce subtask definitions
# Usage: ./auto-split.sh --task-id <id> --description <desc> --product-goal <goal> --findings <json> --agent <agent>
# Outputs JSON array of subtasks to stdout.
# On failure, outputs "[]" and exits 0 (caller handles empty array).

set -euo pipefail

# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILL_TEMPLATE="${SCRIPT_DIR}/fill-template.sh"

# Parse args
TASK_ID="" DESCRIPTION="" PRODUCT_GOAL="" FINDINGS="[]" AGENT="claude"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-id)       TASK_ID="$2"; shift 2 ;;
    --description)   DESCRIPTION="$2"; shift 2 ;;
    --product-goal)  PRODUCT_GOAL="$2"; shift 2 ;;
    --findings)      FINDINGS="$2"; shift 2 ;;
    --agent)         AGENT="$2"; shift 2 ;;
    *) echo "ERROR: Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Validate
[[ -n "$TASK_ID" ]]     || { echo "ERROR: --task-id required" >&2; exit 1; }
[[ -n "$DESCRIPTION" ]] || { echo "ERROR: --description required" >&2; exit 1; }

# Format findings for the prompt
FINDINGS_TEXT=$(python3 -c "
import json, sys
findings = json.loads(sys.argv[1])
for i, f in enumerate(findings):
    print(f'- Finding {i+1}: {f}')
" "$FINDINGS" 2>/dev/null || echo "- No findings available")

# Fill template
TEMPLATE="${PROMPTS_DIR}/split.md"
if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: Template not found: $TEMPLATE" >&2
  echo "[]"
  exit 0
fi

FILLED_PROMPT="$(mktemp "/tmp/split-${TASK_ID}-XXXXXX.md")"
trap 'rm -f "$FILLED_PROMPT"' EXIT

"$FILL_TEMPLATE" "$TEMPLATE" \
  --var TASK_DESCRIPTION="$DESCRIPTION" \
  --var PRODUCT_GOAL="${PRODUCT_GOAL:-N/A}" \
  --var FINDINGS="$FINDINGS_TEXT" \
  --var TASK_ID="$TASK_ID" \
  > "$FILLED_PROMPT"

# Run agent synchronously with timeout (same pattern as review-plan.sh)
SPLIT_TIMEOUT="${MAX_RUNTIME_SECONDS:-2700}"
AGENT_OUTPUT=""

if [ "$AGENT" = "claude" ]; then
  AGENT_OUTPUT=$(timeout "$SPLIT_TIMEOUT" \
    "$CLAUDE_PATH" --model claude-opus-4-6 --dangerously-skip-permissions -p - \
    < "$FILLED_PROMPT" 2>/dev/null) || {
    echo "[]"
    exit 0
  }
elif [ "$AGENT" = "codex" ]; then
  AGENT_OUTPUT=$(timeout "$SPLIT_TIMEOUT" \
    "$CODEX_PATH" exec --dangerously-bypass-approvals-and-sandbox \
    < "$FILLED_PROMPT" 2>/dev/null) || {
    echo "[]"
    exit 0
  }
else
  echo "ERROR: Unknown agent: $AGENT" >&2
  echo "[]"
  exit 0
fi

# Parse SPLIT_RESULT from agent output
python3 -c "
import json, re, sys

output = sys.argv[1]

# Look for SPLIT_RESULT: followed by JSON array
match = re.search(r'SPLIT_RESULT:\s*(\[.*?\])', output, re.DOTALL)
if not match:
    # Fallback: look for any JSON array with suffix/description keys
    match = re.search(r'\[\s*\{[^}]*\"suffix\"[^]]*\]', output, re.DOTALL)

if match:
    try:
        raw = match.group(1) if 'SPLIT_RESULT' in output[:match.start() + 20] else match.group(0)
        result = json.loads(raw)
        # Validate structure
        validated = []
        for item in result:
            if isinstance(item, dict) and 'suffix' in item and 'description' in item:
                # Sanitize suffix for use in task IDs
                suffix = re.sub(r'[^a-zA-Z0-9-]', '', item['suffix'])[:20]
                if suffix:
                    validated.append({'suffix': suffix, 'description': item['description'][:500]})
        if 2 <= len(validated) <= 4:
            print(json.dumps(validated))
        else:
            print('[]')
    except (json.JSONDecodeError, TypeError):
        print('[]')
else:
    print('[]')
" "$AGENT_OUTPUT"
