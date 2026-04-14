#!/usr/bin/env bash
# bootstrap-openclaw.sh — One-shot setup on the openclaw machine.
#
# Migrates the running kopiclaw workspace to the new multi-workspace pattern
# (Phase 7) AND brings up konid as workspace #2 (Phase 8).
#
# Idempotent: safe to re-run (skips steps already done).
# Use --dry-run to preview changes without touching anything.
#
# Usage:
#   bash bootstrap-openclaw.sh [--dry-run] [--skip-kopiclaw] [--skip-konid]
#
# Pre-requisites on the openclaw machine:
#   - ~/Projects/b0b/ checked out at branch refactor/multi-workspace (or main once merged)
#   - ~/Projects/kopi/ exists (kopiclaw product repo)
#   - ~/Projects/konid/ exists (konid product repo) — clone if not:
#       git clone git@github.com:robertnowell/konid-language-learning.git ~/Projects/konid
#   - gh CLI authed as robertnowell
#   - Slack bot token at ~/.openclaw/credentials/slack-bot-token
#   - Slack channels #project-b0b (C0ASUGC787Q) and #alerts-b0b (C0ATQS3NJRE)
#     created with the bot invited

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
B0B_REPO_PATH="$(cd "$SCRIPT_DIR/../.." && pwd)"

DRY_RUN=0
SKIP_KOPICLAW=0
SKIP_KONID=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)        DRY_RUN=1; shift ;;
    --skip-kopiclaw)  SKIP_KOPICLAW=1; shift ;;
    --skip-konid)     SKIP_KONID=1; shift ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# //; s/^#//'
      exit 0
      ;;
    *) echo "ERROR: Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Echo + execute, or just echo when --dry-run.
do_run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] $*"
  else
    echo "  + $*"
    eval "$@"
  fi
}

prompt_continue() {
  local msg="$1"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [dry-run] would prompt: $msg"
    return 0
  fi
  read -r -p "$msg (y/N) " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# ============================================================================
# Pre-flight
# ============================================================================
echo "=== Pre-flight ==="

# Sanity check: are we on the openclaw machine?
if [[ ! -d "$HOME/Projects/kopi" ]]; then
  echo "WARNING: $HOME/Projects/kopi not found — this might not be the openclaw machine."
  prompt_continue "Continue anyway?" || exit 1
fi

# Pull latest b0b
echo "Syncing b0b code..."
do_run "(cd '$B0B_REPO_PATH' && git fetch origin --quiet)"
current_branch=$(cd "$B0B_REPO_PATH" && git branch --show-current)
if [[ "$current_branch" != "refactor/multi-workspace" && "$current_branch" != "main" ]]; then
  echo "  WARNING: on branch '$current_branch'. Expected refactor/multi-workspace or main."
  prompt_continue "Continue with current branch?" || exit 1
fi
do_run "(cd '$B0B_REPO_PATH' && git pull --ff-only origin '$current_branch')"

# Backup directory (single timestamp for the whole run)
ts=$(date +%Y%m%d-%H%M%S)
backup_dir="$HOME/.openclaw/_backups/$ts"
do_run "mkdir -p '$backup_dir'"
echo "  Backups will go to: $backup_dir"

# ============================================================================
# Phase 7 — Migrate kopiclaw
# ============================================================================
if [[ $SKIP_KOPICLAW -eq 0 ]]; then
  echo ""
  echo "=== Phase 7: Migrate kopiclaw ==="

  # Drain check
  active_tasks_file="$HOME/.openclaw/workspace-kopiclaw/pipeline/active-tasks.json"
  if [[ -f "$active_tasks_file" ]]; then
    busy=$(python3 -c "
import json
try:
    with open('$active_tasks_file') as f:
        tasks = json.load(f)
    busy = [t['id'] for t in tasks if t.get('phase') in ('implementing', 'auditing', 'testing', 'pr_creating', 'fixing')]
    print(','.join(busy) if busy else '')
except Exception:
    print('')
")
    if [[ -n "$busy" ]]; then
      echo "ERROR: kopiclaw has tasks in active phases: $busy"
      echo "       Wait for them to finish or kill them via:"
      echo "         $B0B_REPO_PATH/.clawdbot/scripts/kill-task.sh <task-id>"
      exit 1
    fi
    echo "  Drain check: no kopiclaw tasks in active phases."
  fi

  # Discover existing kopiclaw plist
  existing_label=$(launchctl list 2>/dev/null | awk '/openclaw|kopiclaw/ && $3 ~ /monitor|kopiclaw/ {print $3}' | head -1 || true)
  plist_file=""
  if [[ -n "$existing_label" ]]; then
    plist_file="$HOME/Library/LaunchAgents/${existing_label}.plist"
    [[ -f "$plist_file" ]] || plist_file=""
  fi
  if [[ -z "$plist_file" ]]; then
    # Fallback: scan disk for plist files matching common patterns
    for f in "$HOME/Library/LaunchAgents/"com.kopiclaw.monitor.plist \
             "$HOME/Library/LaunchAgents/"com.openclaw.kopiclaw.monitor.plist \
             "$HOME/Library/LaunchAgents/"com.openclaw.monitor.plist; do
      if [[ -f "$f" ]]; then plist_file="$f"; break; fi
    done
  fi

  if [[ -z "$plist_file" ]]; then
    echo "  No existing kopiclaw plist found. Will write workspace config.sh only;"
    echo "  generate a plist later via init-workspace.sh --name kopiclaw if needed."
  else
    echo "  Existing kopiclaw plist: $plist_file"
    echo "  Existing launchd label:  ${existing_label:-(detected from filename)}"
    do_run "cp '$plist_file' '$backup_dir/'"
  fi

  # Back up state dir
  if [[ -d "$HOME/.openclaw/workspace-kopiclaw" ]]; then
    do_run "cp -R '$HOME/.openclaw/workspace-kopiclaw' '$backup_dir/'"
  fi

  # Write kopiclaw workspace config.sh
  kopi_config="$HOME/.openclaw/kopiclaw/config.sh"
  if [[ -f "$kopi_config" ]]; then
    echo "  $kopi_config already exists — leaving it alone (idempotent)."
  else
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [dry-run] would write $kopi_config"
    else
      mkdir -p "$HOME/.openclaw/kopiclaw"
      cat > "$kopi_config" <<'EOF'
#!/usr/bin/env bash
# Workspace config for kopiclaw — preserves legacy state-dir name.
# Generated by bootstrap-openclaw.sh.
WORKSPACE_REPO="tryrendition/Rendition"
WORKSPACE_REPO_PATH="/Users/kopi/Projects/kopi"
BOT_USER="kopi-claw"
WORKTREE_BASE="/Users/kopi/Projects/kopi-worktrees"
SLACK_PROJECT_CHANNEL="C0AJAR3S76U"
SLACK_ALERTS_CHANNEL="C0AHGH5FH42"
SLACK_REVIEW_USER="U020AAXG1DE"
STATE_DIR="${HOME}/.openclaw/workspace-kopiclaw/pipeline"
EOF
      echo "  Wrote $kopi_config"
    fi
  fi

  # Update kopiclaw plist:
  #   (a) Repoint ProgramArguments at b0b standalone monitor.sh (so kopiclaw
  #       starts running the new multi-workspace scripts, not the legacy
  #       in-kopi-monorepo copy).
  #   (b) Add EnvironmentVariables.B0B_WORKSPACE=kopiclaw + B0B_LEGACY=1
  #       (cascade activation + safety belt).
  # Preserves all other plist fields. Backup in $backup_dir/ for rollback.
  if [[ -n "$plist_file" ]]; then
    new_monitor="$B0B_REPO_PATH/.clawdbot/scripts/monitor.sh"
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [dry-run] would patch $plist_file:"
      echo "    ProgramArguments[1] -> $new_monitor"
      echo "    EnvironmentVariables.B0B_WORKSPACE = kopiclaw"
      echo "    EnvironmentVariables.B0B_LEGACY = 1"
    else
      python3 - "$plist_file" "$new_monitor" <<'PYEOF'
import plistlib, sys
path, new_monitor = sys.argv[1], sys.argv[2]
with open(path, 'rb') as f:
    pl = plistlib.load(f)

# (a) Repoint ProgramArguments at b0b standalone monitor.sh.
# Preserve anything past index 1 in case the existing plist passes flags.
old_args = pl.get('ProgramArguments', [])
extra_args = old_args[2:] if len(old_args) > 2 else []
new_args = ['/bin/bash', new_monitor] + extra_args
if old_args == new_args:
    print(f'  ProgramArguments already correct — no change needed')
else:
    print(f'  ProgramArguments was: {old_args}')
    print(f'  ProgramArguments now: {new_args}')
    pl['ProgramArguments'] = new_args

# (b) Add cascade env vars + safety belt
env = pl.setdefault('EnvironmentVariables', {})
env['B0B_WORKSPACE'] = 'kopiclaw'
env['B0B_LEGACY'] = '1'

with open(path, 'wb') as f:
    plistlib.dump(pl, f)
print(f'  Patched {path}')
PYEOF
      # Validate
      plutil "$plist_file" >/dev/null
      # Reload
      launchctl unload "$plist_file"
      launchctl load "$plist_file"
      echo "  Reloaded launchd service."
    fi
  fi

  echo ""
  echo "  Kopiclaw migration complete."
  if [[ -n "$plist_file" ]]; then
    echo "    Watch logs: tail -f $HOME/.openclaw/workspace-kopiclaw/pipeline/logs/launchd.out"
    echo "    Once stable for one task lifecycle, drop the safety belt:"
    echo "      python3 -c \"import plistlib; p='$plist_file'; pl=plistlib.load(open(p,'rb')); pl['EnvironmentVariables'].pop('B0B_LEGACY', None); plistlib.dump(pl, open(p,'wb'))\""
    echo "      launchctl unload '$plist_file' && launchctl load '$plist_file'"
  fi
fi

# ============================================================================
# Phase 8 — Init konid
# ============================================================================
if [[ $SKIP_KONID -eq 0 ]]; then
  echo ""
  echo "=== Phase 8: Init konid ==="

  konid_workspace="$HOME/.openclaw/konid"
  konid_plist="$HOME/Library/LaunchAgents/com.openclaw.konid.monitor.plist"

  if [[ -d "$konid_workspace" ]]; then
    echo "  $konid_workspace already exists — skipping init (idempotent)."
    echo "  Remove it first if you want to re-init:"
    echo "    launchctl unload '$konid_plist' 2>/dev/null"
    echo "    rm '$konid_plist' && rm -rf '$konid_workspace'"
  else
    if [[ ! -d "$HOME/Projects/konid" ]]; then
      echo "  WARNING: $HOME/Projects/konid does not exist."
      echo "           konid pipeline can't git fetch / worktree add until you clone:"
      echo "             git clone git@github.com:robertnowell/konid-language-learning.git $HOME/Projects/konid"
      prompt_continue "Continue init anyway?" || { echo "  Skipping konid init."; SKIP_KONID=1; }
    fi
  fi

  if [[ $SKIP_KONID -eq 0 && ! -d "$konid_workspace" ]]; then
    init_args=(
      --name konid
      --repo robertnowell/konid-language-learning
      --bot-user b0b
      --slack-project-channel C0ASUGC787Q
      --slack-alerts-channel C0ATQS3NJRE
      --slack-review-user U020AAXG1DE
      --human-name Robert
      --human-github robertnowell
      --project-name Konid
      --project-tagline "Language expression coach with audio playback + learning tracking"
      --project-description "MCP server (TypeScript) — coach/speak/replay/card tools"
      --project-stack "TypeScript + tsx + MCP SDK + ElevenLabs"
    )
    [[ $DRY_RUN -eq 1 ]] && init_args+=(--dry-run)
    "$B0B_REPO_PATH/.clawdbot/scripts/init-workspace.sh" "${init_args[@]}"
  fi

  # Load konid plist
  if [[ $SKIP_KONID -eq 0 && -f "$konid_plist" ]]; then
    if launchctl list 2>/dev/null | grep -q 'com.openclaw.konid.monitor'; then
      echo "  konid plist already loaded — skipping."
    else
      do_run "launchctl load '$konid_plist'"
    fi
  fi
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=== Bootstrap complete ==="
echo ""
echo "Loaded launchd services:"
launchctl list | grep -E 'openclaw|kopiclaw' || echo "  (none — check ~/Library/LaunchAgents/ and 'launchctl load')"
echo ""
echo "Workspaces on disk:"
ls -d "$HOME/.openclaw/"*/ 2>/dev/null | grep -v _backups | grep -v credentials || echo "  (none)"
echo ""
echo "Backups: $backup_dir"
echo ""
echo "Verification commands:"
echo "  bash $B0B_REPO_PATH/.clawdbot/scripts/pipeline-status.sh"
echo "  tail -f $HOME/.openclaw/workspace-kopiclaw/pipeline/logs/launchd.out  # kopiclaw"
echo "  tail -f $HOME/.openclaw/konid/pipeline/logs/launchd.out                # konid"
echo ""
if [[ $DRY_RUN -eq 1 ]]; then
  echo "(--dry-run mode — nothing actually changed.)"
fi
