#!/usr/bin/env bash
# fill-template.sh — Fill prompt templates with variable substitution
# Usage: ./fill-template.sh <template-file> --var KEY="value" --var KEY2="value2" ...
#
# Reads the template, replaces {VAR_NAME} placeholders with provided values,
# outputs the filled template to stdout. Handles multi-line values.
#
# Variables are passed to Python via a temp file to avoid ARG_MAX limits
# when plan/diff content is large.
#
# Example:
#   ./fill-template.sh prompts/implement.md \
#     --var PRD="Build a widget" \
#     --var PLAN="$(cat plan.md)" \
#     --var DELIVERABLES="Widget component, tests"

set -euo pipefail

# Source shared config
# shellcheck source=config.sh
source "$(cd "$(dirname "$0")" && pwd)/config.sh"

TEMPLATE_FILE="${1:?Usage: fill-template.sh <template-file> --var KEY=VALUE ...}"
shift

if [ ! -f "$TEMPLATE_FILE" ]; then
  echo "ERROR: Template file not found: $TEMPLATE_FILE" >&2
  exit 1
fi

# Collect --var KEY=VALUE pairs
VAR_KEYS=()
VAR_VALUES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --var)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --var requires a KEY=VALUE argument" >&2
        exit 1
      fi
      PAIR="$2"
      KEY="${PAIR%%=*}"
      VALUE="${PAIR#*=}"
      if [[ "$KEY" == "$PAIR" ]]; then
        echo "ERROR: --var argument must be KEY=VALUE, got: $PAIR" >&2
        exit 1
      fi
      if [[ ! "$KEY" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "ERROR: Invalid variable name: $KEY (must be [A-Za-z_][A-Za-z0-9_]*)" >&2
        exit 1
      fi
      VAR_KEYS+=("$KEY")
      VAR_VALUES+=("$VALUE")
      shift 2
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Write variables to a temp JSON file to avoid ARG_MAX limits
VARS_FILE=$(mktemp)
trap 'rm -f "$VARS_FILE"' EXIT

python3 -c "
import json, sys
keys = sys.argv[1::2]
values = sys.argv[2::2]
# This initial call is small — just writing key names to the JSON structure
with open('$VARS_FILE', 'w') as f:
    json.dump(dict(zip(keys, [''] * len(keys))), f)
" "${VAR_KEYS[@]}"

# Write actual values via stdin to avoid argv limits
python3 -c "
import json, sys

# Read key-value pairs from stdin (null-delimited)
data = sys.stdin.buffer.read()
parts = data.split(b'\x00')
# pairs: key1, val1, key2, val2, ...
keys = []
values = []
for i in range(0, len(parts) - 1, 2):
    keys.append(parts[i].decode())
    values.append(parts[i+1].decode())

with open(sys.argv[1], 'w') as f:
    json.dump(dict(zip(keys, values)), f)
" "$VARS_FILE" < <(
  for i in "${!VAR_KEYS[@]}"; do
    printf '%s\0%s\0' "${VAR_KEYS[$i]}" "${VAR_VALUES[$i]}"
  done
)

# Do the template substitution reading vars from the file
python3 -c "
import json, sys, re

template_file = sys.argv[1]
vars_file = sys.argv[2]

with open(template_file) as f:
    content = f.read()

with open(vars_file) as f:
    variables = json.load(f)

for key, value in variables.items():
    placeholder = '{' + key + '}'
    content = content.replace(placeholder, value)

# Warn about unresolved placeholders
unresolved = re.findall(r'\{([A-Za-z_][A-Za-z0-9_]*)\}', content)
for var in unresolved:
    print(f'WARNING: unresolved placeholder {{{var}}} in {template_file}', file=sys.stderr)

sys.stdout.write(content)
" "$TEMPLATE_FILE" "$VARS_FILE"
