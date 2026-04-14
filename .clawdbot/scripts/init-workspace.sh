#!/usr/bin/env bash
# init-workspace.sh — Stamp out a new b0b workspace from .openclaw/_template/.
#
# Creates ~/.openclaw/<name>/ with all manifest files + config.sh, plus a
# launchd plist at ~/Library/LaunchAgents/com.openclaw.<name>.monitor.plist.
#
# Does NOT touch the network. GitHub/Slack provisioning is a separate step.
#
# Usage:
#   ./init-workspace.sh \
#     --name <slug> \
#     --repo <org/repo> \
#     [--bot-user b0b] \
#     [--slack-project-channel <id>] \
#     [--slack-alerts-channel <id>] \
#     [--slack-review-user <id>] \
#     [--worktree-base ~/Projects/<name>-worktrees] \
#     [--human-name "Robert"] \
#     [--human-github "robertnowell"] \
#     [--project-name "<slug>"] \
#     [--project-tagline "..."] \
#     [--project-description "..."] \
#     [--load-plist]      # immediately launchctl load (default: print instructions)
#     [--dry-run]         # print substitutions, don't write files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
B0B_REPO_PATH="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEMPLATE_DIR="$B0B_REPO_PATH/.openclaw/_template"
PLIST_TEMPLATE="$B0B_REPO_PATH/.clawdbot/templates/monitor.plist.template"

# Defaults
NAME=""
WORKSPACE_REPO=""
BOT_USER="b0b"
SLACK_PROJECT_CHANNEL=""
SLACK_ALERTS_CHANNEL=""
SLACK_REVIEW_USER=""
WORKTREE_BASE=""
CLAUDE_PATH="${CLAUDE_PATH:-${HOME}/.local/bin/claude}"
HUMAN_NAME=""
HUMAN_GITHUB=""
HUMAN_PRONOUNS="—"
HUMAN_TIMEZONE="$(date +%Z 2>/dev/null || echo 'UTC')"
PROJECT_NAME=""
PROJECT_URL=""
PROJECT_TAGLINE="(TBD)"
PROJECT_DESCRIPTION="(TBD)"
PROJECT_PHILOSOPHY="(TBD)"
PROJECT_STACK="(TBD)"
PROJECT_DEPLOY="(TBD)"
LOAD_PLIST=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)                      NAME="$2"; shift 2 ;;
    --repo)                      WORKSPACE_REPO="$2"; shift 2 ;;
    --bot-user)                  BOT_USER="$2"; shift 2 ;;
    --slack-project-channel)     SLACK_PROJECT_CHANNEL="$2"; shift 2 ;;
    --slack-alerts-channel)      SLACK_ALERTS_CHANNEL="$2"; shift 2 ;;
    --slack-review-user)         SLACK_REVIEW_USER="$2"; shift 2 ;;
    --worktree-base)             WORKTREE_BASE="$2"; shift 2 ;;
    --claude-path)               CLAUDE_PATH="$2"; shift 2 ;;
    --human-name)                HUMAN_NAME="$2"; shift 2 ;;
    --human-github)              HUMAN_GITHUB="$2"; shift 2 ;;
    --human-pronouns)            HUMAN_PRONOUNS="$2"; shift 2 ;;
    --human-timezone)            HUMAN_TIMEZONE="$2"; shift 2 ;;
    --project-name)              PROJECT_NAME="$2"; shift 2 ;;
    --project-url)               PROJECT_URL="$2"; shift 2 ;;
    --project-tagline)           PROJECT_TAGLINE="$2"; shift 2 ;;
    --project-description)       PROJECT_DESCRIPTION="$2"; shift 2 ;;
    --project-philosophy)        PROJECT_PHILOSOPHY="$2"; shift 2 ;;
    --project-stack)             PROJECT_STACK="$2"; shift 2 ;;
    --project-deploy)            PROJECT_DEPLOY="$2"; shift 2 ;;
    --load-plist)                LOAD_PLIST=1; shift ;;
    --dry-run)                   DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,25p' "$0" | sed 's/^# //; s/^#//'
      exit 0
      ;;
    *) echo "ERROR: Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# --- Validate ---
[[ -n "$NAME" ]] || { echo "ERROR: --name required" >&2; exit 1; }
[[ -n "$WORKSPACE_REPO" ]] || { echo "ERROR: --repo required" >&2; exit 1; }
[[ "$NAME" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "ERROR: --name must be lowercase alphanumeric + hyphens, starting with a letter" >&2; exit 1; }
[[ "$WORKSPACE_REPO" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]] || { echo "ERROR: --repo must be 'org/repo' format" >&2; exit 1; }
[[ -d "$TEMPLATE_DIR" ]] || { echo "ERROR: template dir not found: $TEMPLATE_DIR" >&2; exit 1; }
[[ -f "$PLIST_TEMPLATE" ]] || { echo "ERROR: plist template not found: $PLIST_TEMPLATE" >&2; exit 1; }

WORKSPACE_DIR="${HOME}/.openclaw/${NAME}"
PLIST_PATH="${HOME}/Library/LaunchAgents/com.openclaw.${NAME}.monitor.plist"

if [[ -d "$WORKSPACE_DIR" ]]; then
  echo "ERROR: workspace already exists at $WORKSPACE_DIR" >&2
  exit 1
fi

# --- Defaults derived from name ---
[[ -n "$WORKTREE_BASE" ]] || WORKTREE_BASE="${HOME}/Projects/${NAME}-worktrees"
[[ -n "$PROJECT_NAME" ]] || PROJECT_NAME="$(echo "${NAME:0:1}" | tr '[:lower:]' '[:upper:]')${NAME:1}"
[[ -n "$HUMAN_NAME" ]] || HUMAN_NAME="(TBD — edit USER.md)"
[[ -n "$HUMAN_GITHUB" ]] || HUMAN_GITHUB="(TBD — edit USER.md)"
[[ -n "$SLACK_PROJECT_CHANNEL" ]] || echo "WARNING: --slack-project-channel not set; bot will skip plan_review notifications"
[[ -n "$SLACK_ALERTS_CHANNEL" ]] || echo "WARNING: --slack-alerts-channel not set; bot will skip phase-transition notifications"

# Slack channel display names (derived from workspace)
SLACK_PROJECT_CHANNEL_NAME="#project-${NAME}"
SLACK_ALERTS_CHANNEL_NAME="#alerts-${NAME}"

# IDENTITY.md placeholders — sensible neutral defaults; user edits IDENTITY.md to taste
IDENTITY_NAME="$PROJECT_NAME"
IDENTITY_CREATURE="AI orchestrator — autonomous dev pipeline"
IDENTITY_VIBE="Direct, resourceful, ships fast."
IDENTITY_EMOJI="🤖"

# --- Substitute and write ---
export NAME WORKSPACE_REPO BOT_USER SLACK_PROJECT_CHANNEL SLACK_ALERTS_CHANNEL SLACK_REVIEW_USER \
       WORKTREE_BASE CLAUDE_PATH HUMAN_NAME HUMAN_GITHUB HUMAN_PRONOUNS HUMAN_TIMEZONE \
       PROJECT_NAME PROJECT_URL PROJECT_TAGLINE PROJECT_DESCRIPTION PROJECT_PHILOSOPHY \
       PROJECT_STACK PROJECT_DEPLOY SLACK_PROJECT_CHANNEL_NAME SLACK_ALERTS_CHANNEL_NAME \
       IDENTITY_NAME IDENTITY_CREATURE IDENTITY_VIBE IDENTITY_EMOJI \
       TEMPLATE_DIR WORKSPACE_DIR PLIST_TEMPLATE PLIST_PATH B0B_REPO_PATH DRY_RUN

python3 <<'PYEOF'
import os, sys, re, shutil
from pathlib import Path

DRY_RUN = os.environ['DRY_RUN'] == '1'

# Workspace name placeholder maps to the --name CLI arg
WORKSPACE_NAME = os.environ['NAME']

substitutions = {
    'WORKSPACE_NAME':            WORKSPACE_NAME,
    'WORKSPACE_REPO':            os.environ['WORKSPACE_REPO'],
    'WORKSPACE_REPO_PATH':       f"{os.environ['HOME']}/Projects/{WORKSPACE_NAME}",
    'BOT_USER':                  os.environ['BOT_USER'],
    'WORKTREE_BASE':             os.environ['WORKTREE_BASE'],
    'CLAUDE_PATH':               os.environ['CLAUDE_PATH'],
    'SLACK_PROJECT_CHANNEL':     os.environ['SLACK_PROJECT_CHANNEL'],
    'SLACK_ALERTS_CHANNEL':      os.environ['SLACK_ALERTS_CHANNEL'],
    'SLACK_REVIEW_USER':         os.environ['SLACK_REVIEW_USER'],
    'SLACK_PROJECT_CHANNEL_NAME': os.environ['SLACK_PROJECT_CHANNEL_NAME'],
    'SLACK_ALERTS_CHANNEL_NAME':  os.environ['SLACK_ALERTS_CHANNEL_NAME'],
    'NAME':                      os.environ['IDENTITY_NAME'],
    'CREATURE':                  os.environ['IDENTITY_CREATURE'],
    'VIBE':                      os.environ['IDENTITY_VIBE'],
    'EMOJI':                     os.environ['IDENTITY_EMOJI'],
    'HUMAN_NAME':                os.environ['HUMAN_NAME'],
    'HUMAN_GITHUB':              os.environ['HUMAN_GITHUB'],
    'HUMAN_PRONOUNS':            os.environ['HUMAN_PRONOUNS'],
    'HUMAN_TIMEZONE':            os.environ['HUMAN_TIMEZONE'],
    'PROJECT_NAME':              os.environ['PROJECT_NAME'],
    'PROJECT_URL':               os.environ['PROJECT_URL'],
    'PROJECT_TAGLINE':           os.environ['PROJECT_TAGLINE'],
    'PROJECT_DESCRIPTION':       os.environ['PROJECT_DESCRIPTION'],
    'PROJECT_PHILOSOPHY':        os.environ['PROJECT_PHILOSOPHY'],
    'PROJECT_STACK':             os.environ['PROJECT_STACK'],
    'PROJECT_DEPLOY':            os.environ['PROJECT_DEPLOY'],
    'B0B_REPO_PATH':             os.environ['B0B_REPO_PATH'],
    'HOME':                      os.environ['HOME'],
}

def substitute(text):
    """Replace all {{KEY}} placeholders. Unknown placeholders are left in place
    and reported as warnings."""
    unknown = []
    def repl(m):
        key = m.group(1)
        if key not in substitutions:
            unknown.append(key)
            return m.group(0)
        return substitutions[key]
    # Allow digits in placeholder names (e.g. B0B_REPO_PATH).
    result = re.sub(r'\{\{([A-Z0-9_]+)\}\}', repl, text)
    return result, set(unknown)

template_dir = Path(os.environ['TEMPLATE_DIR'])
workspace_dir = Path(os.environ['WORKSPACE_DIR'])
plist_template = Path(os.environ['PLIST_TEMPLATE'])
plist_path = Path(os.environ['PLIST_PATH'])

# Collect all unknown placeholders across files for a single warning
all_unknown = set()

if not DRY_RUN:
    workspace_dir.mkdir(parents=True, exist_ok=False)
    (workspace_dir / 'pipeline' / 'logs').mkdir(parents=True)
    (workspace_dir / 'pipeline' / 'plans').mkdir(parents=True)
    (workspace_dir / 'memory').mkdir(parents=True)

# Manifest files
written = []
for src in sorted(template_dir.glob('*')):
    if src.name in ('memory', 'pipeline'):
        continue
    if not src.is_file():
        continue
    text = src.read_text()
    result, unknown = substitute(text)
    all_unknown.update(unknown)
    dst = workspace_dir / src.name
    if DRY_RUN:
        print(f'  [dry-run] would write: {dst} ({len(result)} bytes)')
    else:
        dst.write_text(result)
        written.append(str(dst))

# Plist
plist_content, plist_unknown = substitute(plist_template.read_text())
all_unknown.update(plist_unknown)
if DRY_RUN:
    print(f'  [dry-run] would write: {plist_path} ({len(plist_content)} bytes)')
else:
    plist_path.parent.mkdir(parents=True, exist_ok=True)
    plist_path.write_text(plist_content)
    written.append(str(plist_path))

print(f'\nSubstituted {len(substitutions)} variables across {len(written)} files.')
if all_unknown:
    print(f'WARNING: unknown placeholders not substituted: {sorted(all_unknown)}')
if not DRY_RUN:
    print('\nFiles written:')
    for f in written:
        print(f'  {f}')
PYEOF

if [[ $DRY_RUN -eq 1 ]]; then
  echo ""
  echo "=== DRY RUN — no files written ==="
  exit 0
fi

# --- Validate plist ---
if ! plutil "$PLIST_PATH" >/dev/null 2>&1; then
  echo "ERROR: generated plist is not valid; check $PLIST_PATH" >&2
  exit 1
fi

# --- Optionally load plist ---
if [[ $LOAD_PLIST -eq 1 ]]; then
  launchctl load "$PLIST_PATH"
  echo "Loaded launchd plist: com.openclaw.${NAME}.monitor"
fi

# --- Print next steps ---
cat <<EOF

=== Workspace '${NAME}' initialized ===

Files:
  Workspace:  ${WORKSPACE_DIR}/
  Plist:      ${PLIST_PATH}

Next steps:

  1. Edit the workspace files to fit:
       \$EDITOR ${WORKSPACE_DIR}/IDENTITY.md
       \$EDITOR ${WORKSPACE_DIR}/USER.md

  2. Provision the GitHub side (manual for now):
       - If using shared @${BOT_USER} bot, ensure it has access to ${WORKSPACE_REPO}
       - Otherwise, create a machine account named ${BOT_USER} and invite it

  3. Provision the Slack side (manual for now):
       - Create channels matching ${SLACK_PROJECT_CHANNEL_NAME} and ${SLACK_ALERTS_CHANNEL_NAME}
       - Invite the bot
       - Ensure ${HOME}/.openclaw/credentials/slack-bot-token exists

  4. Smoke test:
       B0B_WORKSPACE=${NAME} bash ${B0B_REPO_PATH}/.clawdbot/scripts/monitor.sh
EOF

if [[ $LOAD_PLIST -eq 0 ]]; then
  cat <<EOF

  5. Load the launchd plist when ready:
       launchctl load ${PLIST_PATH}
EOF
fi
