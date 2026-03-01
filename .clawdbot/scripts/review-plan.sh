#!/usr/bin/env bash
# review-plan.sh — Send a plan to a second agent for review and uncertainty scoring
# Usage:
#   ./review-plan.sh \
#     --feature "Feature description" \
#     --plan-file <path-to-plan.md> \
#     --agent <codex|claude>
#
# Runs the review agent NON-INTERACTIVELY (waits for result, no tmux).
# Parses output for uncertainty score, concerns, and improvements.
# Outputs structured JSON to stdout.
# Times out after MAX_RUNTIME_SECONDS.

set -euo pipefail

# Source shared config
# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILL_TEMPLATE="${SCRIPT_DIR}/fill-template.sh"

# --- Parse arguments ---
FEATURE=""
PLAN_FILE=""
AGENT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature)    [[ $# -ge 2 ]] || { echo "ERROR: --feature requires a value" >&2; exit 1; };    FEATURE="$2"; shift 2 ;;
    --plan-file)  [[ $# -ge 2 ]] || { echo "ERROR: --plan-file requires a value" >&2; exit 1; };  PLAN_FILE="$2"; shift 2 ;;
    --agent)      [[ $# -ge 2 ]] || { echo "ERROR: --agent requires a value" >&2; exit 1; };      AGENT="$2"; shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# --- Validate inputs ---
[[ -n "$FEATURE" ]]   || { echo "ERROR: --feature is required" >&2; exit 1; }
[[ -n "$PLAN_FILE" ]] || { echo "ERROR: --plan-file is required" >&2; exit 1; }
[[ -n "$AGENT" ]]     || { echo "ERROR: --agent is required" >&2; exit 1; }

[[ "$AGENT" =~ ^(codex|claude)$ ]] || { echo "ERROR: Agent must be codex or claude" >&2; exit 1; }

if [ ! -f "$PLAN_FILE" ]; then
  echo "ERROR: Plan file not found: $PLAN_FILE" >&2
  exit 1
fi

# --- Read the plan ---
PLAN_CONTENT="$(cat "$PLAN_FILE")"

# --- Fill review-plan.md template ---
TEMPLATE="${PROMPTS_DIR}/review-plan.md"
if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: Template not found: $TEMPLATE" >&2
  exit 1
fi

FILLED_PROMPT_FILE="$(mktemp /tmp/review-plan-XXXXXX.md)"
trap 'rm -f "$FILLED_PROMPT_FILE"' EXIT

"$FILL_TEMPLATE" "$TEMPLATE" \
  --var FEATURE="$FEATURE" \
  --var PLAN="$PLAN_CONTENT" \
  > "$FILLED_PROMPT_FILE"

# --- Run the agent non-interactively with timeout ---
AGENT_OUTPUT=""

if [ "$AGENT" = "claude" ]; then
  AGENT_OUTPUT=$(timeout "${MAX_RUNTIME_SECONDS}" \
    "$CLAUDE_PATH" --model claude-opus-4-6 --dangerously-skip-permissions -p - \
    < "$FILLED_PROMPT_FILE" 2>/dev/null) || {
    EXIT_CODE=$?
    if [ "$EXIT_CODE" -eq 124 ]; then
      echo '{"uncertainty":5,"concerns":["Review agent timed out"],"improvements":[],"recommendation":"split"}'
      exit 0
    fi
    echo "{\"uncertainty\":5,\"concerns\":[\"Review agent failed with exit code $EXIT_CODE\"],\"improvements\":[],\"recommendation\":\"split\"}"
    exit 0
  }
elif [ "$AGENT" = "codex" ]; then
  AGENT_OUTPUT=$(timeout "${MAX_RUNTIME_SECONDS}" \
    "$CODEX_PATH" exec --dangerously-bypass-approvals-and-sandbox \
    < "$FILLED_PROMPT_FILE" 2>/dev/null) || {
    EXIT_CODE=$?
    if [ "$EXIT_CODE" -eq 124 ]; then
      echo '{"uncertainty":5,"concerns":["Review agent timed out"],"improvements":[],"recommendation":"split"}'
      exit 0
    fi
    echo "{\"uncertainty\":5,\"concerns\":[\"Review agent failed with exit code $EXIT_CODE\"],\"improvements\":[],\"recommendation\":\"split\"}"
    exit 0
  }
fi

# --- Parse the output into structured JSON ---
python3 -c "
import json, re, sys

output = sys.argv[1]

# Extract uncertainty score: prefer structured UNCERTAINTY_SCORE:<N> line, fall back to heuristics
uncertainty = 3  # default to medium
structured_match = re.search(r'^UNCERTAINTY_SCORE:(\d)\s*$', output, re.MULTILINE)
if structured_match:
    val = int(structured_match.group(1))
    if 1 <= val <= 5:
        uncertainty = val
else:
    score_patterns = [
        r'[Uu]ncertainty\s*(?:score)?[\s:]*(\d)',
        r'[Ss]core[\s:]*(\d)\s*/?\s*5',
        r'\*\*(\d)\s*/?\s*5\*\*',
        r'(\d)\s*/\s*5',
    ]
    for pattern in score_patterns:
        match = re.search(pattern, output)
        if match:
            val = int(match.group(1))
            if 1 <= val <= 5:
                uncertainty = val
                break

# Extract concerns: look for numbered/bulleted items under concern-like headers
concerns = []
concern_patterns = [
    r'[Cc]oncerns?.*?:?\s*\n((?:\s*[-*\d.]+\s+.+\n?)+)',
    r'[Rr]isks?.*?:?\s*\n((?:\s*[-*\d.]+\s+.+\n?)+)',
    r'[Ii]ssues?.*?:?\s*\n((?:\s*[-*\d.]+\s+.+\n?)+)',
]
for pattern in concern_patterns:
    match = re.search(pattern, output)
    if match:
        items = re.findall(r'[-*\d.]+\s+(.+)', match.group(1))
        concerns.extend([item.strip() for item in items if item.strip()])
        break

# Extract improvements: look for numbered/bulleted items under improvement-like headers
improvements = []
improvement_patterns = [
    r'[Ii]mprovements?.*?:?\s*\n((?:\s*[-*\d.]+\s+.+\n?)+)',
    r'[Ss]uggested?.*?:?\s*\n((?:\s*[-*\d.]+\s+.+\n?)+)',
    r'[Mm]issing\s+steps?.*?:?\s*\n((?:\s*[-*\d.]+\s+.+\n?)+)',
    r'[Rr]ecommendations?.*?:?\s*\n((?:\s*[-*\d.]+\s+.+\n?)+)',
]
for pattern in improvement_patterns:
    match = re.search(pattern, output)
    if match:
        items = re.findall(r'[-*\d.]+\s+(.+)', match.group(1))
        improvements.extend([item.strip() for item in items if item.strip()])
        break

# Determine recommendation based on uncertainty
if uncertainty >= 3:
    recommendation = 'split'
else:
    recommendation = 'proceed'

# Look for explicit split/proceed recommendations in the text
if re.search(r'\bsplit\b', output, re.IGNORECASE) and uncertainty >= 3:
    recommendation = 'split'
elif re.search(r'\bproceed\b', output, re.IGNORECASE) and uncertainty < 3:
    recommendation = 'proceed'

result = {
    'uncertainty': uncertainty,
    'concerns': concerns if concerns else ['No specific concerns extracted'],
    'improvements': improvements if improvements else [],
    'recommendation': recommendation,
}

print(json.dumps(result, indent=2))
" "$AGENT_OUTPUT"
