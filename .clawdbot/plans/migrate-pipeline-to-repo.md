# Plan: Migrate Pipeline Scripts into Rendition Repo

## Summary

Move agent pipeline scripts and prompt templates from `~/.openclaw/workspace-kopiclaw/pipeline/` into `.clawdbot/` in the Rendition repo. State files (active-tasks.json, logs, plans, etc.) remain in the workspace. The central config.sh is rewritten to split "repo paths" (scripts, prompts) from "state paths" (tasks, logs, plans), with state location configurable via env var.

## Analysis: What Changes and What Doesn't

### Why This Is Low-Risk

All scripts source `config.sh` at the top and derive paths from its variables (`TASKS_FILE`, `LOG_DIR`, `PROMPTS_DIR`, etc.). No script hardcodes absolute paths to the pipeline directory — they all go through config.sh. This means:

- **Only config.sh needs a structural rewrite** (new path derivation logic)
- **Only gh-poll.sh needs a one-line fix** (uses `PIPELINE_DIR` directly for state file)
- **All other scripts (11 files) need zero changes** — they already use the derived variables
- **All prompt templates need zero changes** — they're pure `{VAR}` templates with no path references

### monitor.sh Python Internals — Already Compatible

The Python code in monitor.sh builds its prompts path as:
```python
prompts_dir_local = os.path.join(os.path.dirname(script_dir), 'prompts')
```
With the new layout (`.clawdbot/scripts/` → `.clawdbot/prompts/`), `os.path.dirname` of `.clawdbot/scripts/` gives `.clawdbot/`, making the prompts path `.clawdbot/prompts/`. This is correct without any changes.

### Credential Concern: SLACK_WEBHOOK_URL

The current config.sh hardcodes a Slack webhook URL. In the repo, this must be env-var-only (no default). The scripts already handle the case where `SLACK_WEBHOOK_URL` is empty (notify.sh logs to stdout and skips Slack delivery).

---

## Files to Create

### 1. `.clawdbot/scripts/config.sh` (rewritten)

The only file with substantial changes. New logic:

```bash
#!/usr/bin/env bash
# config.sh — Shared configuration for agent pipeline scripts
# Source this at the top of every pipeline script

# Repo root — auto-detected from git (works in worktrees)
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "~/Projects/kopi")"

# Pipeline infrastructure in the repo
CLAWDBOT_DIR="${REPO_ROOT}/.clawdbot"
PROMPTS_DIR="${CLAWDBOT_DIR}/prompts"

# State directory — machine-specific, outside the repo
# Override with CLAWDBOT_STATE_DIR env var
STATE_DIR="${CLAWDBOT_STATE_DIR:-${HOME}/.openclaw/workspace-kopiclaw/pipeline}"

# State files (all in STATE_DIR)
TASKS_FILE="${STATE_DIR}/active-tasks.json"
LOCK_FILE="${STATE_DIR}/.tasks.lock"
LOG_DIR="${STATE_DIR}/logs"
PLANS_DIR="${STATE_DIR}/plans"
NOTIFY_OUTBOX="${STATE_DIR}/notify-outbox.jsonl"

# Worktree bases (configurable via env vars)
WORKTREE_BASE="${CLAWDBOT_WORKTREE_BASE:-~/Projects/kopi-worktrees}"
WORKSPACE_REPO="${CLAWDBOT_WORKSPACE_REPO:-${HOME}/.openclaw/workspace-kopiclaw}"
WORKSPACE_WORKTREE_BASE="${CLAWDBOT_WORKSPACE_WORKTREE_BASE:-${HOME}/.openclaw/kopi-worktrees}"

# Runtime config
MAX_RUNTIME_SECONDS="${MAX_RUNTIME_SECONDS:-2700}"
MAX_ITERATIONS="${MAX_ITERATIONS:-4}"

# Tool paths
CLAUDE_PATH="${CLAUDE_PATH:-${HOME}/.local/bin/claude}"
CODEX_PATH="${CODEX_PATH:-${CODEX_PATH:-codex}}"

# Slack (env var only — no hardcoded webhook in repo)
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

# Legacy compat: PIPELINE_DIR still points to STATE_DIR for any straggling references
PIPELINE_DIR="${STATE_DIR}"

# Usage: eval "$(get_task_paths true)" or eval "$(get_task_paths false)"
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

# Ensure state dirs exist
mkdir -p "$LOG_DIR" "$PLANS_DIR"
```

**Key differences from current config.sh:**
- `REPO_ROOT`: git-detected instead of hardcoded
- `PROMPTS_DIR`: now `$CLAWDBOT_DIR/prompts` (repo) instead of `$PIPELINE_DIR/prompts`
- State vars (`TASKS_FILE`, `LOG_DIR`, `PLANS_DIR`, etc.): now derived from `STATE_DIR` instead of `PIPELINE_DIR`
- `SLACK_WEBHOOK_URL`: no hardcoded default (security)
- All hardcoded paths become env-var-configurable with sensible defaults
- `PIPELINE_DIR` kept as legacy alias for `STATE_DIR`

### 2. `.clawdbot/scripts/` — All other scripts (copied verbatim)

These files are copied with no modifications:
- `spawn-agent.sh`
- `dispatch.sh`
- `check-agents.sh`
- `monitor.sh`
- `cleanup-worktrees.sh`
- `notify.sh`
- `approve-plan.sh`
- `reject-plan.sh`
- `review-plan.sh`
- `fill-template.sh`
- `gh-poll-process.py`

### 3. `.clawdbot/scripts/gh-poll.sh` — One-line fix

Change:
```bash
STATE_FILE="${PIPELINE_DIR}/gh-poll-state.json"
```
To:
```bash
STATE_FILE="${STATE_DIR}/gh-poll-state.json"
```

(With the `PIPELINE_DIR` legacy alias in config.sh, this would actually work unchanged, but using the correct variable is cleaner and removes the dependency on the legacy alias.)

### 4. `.clawdbot/prompts/` — Generic templates (copied verbatim)

These 7 template files are copied with no modifications:
- `audit.md`
- `create-pr.md`
- `fix-feedback.md`
- `implement.md`
- `plan.md`
- `review-plan.md`
- `test.md`

**NOT migrated** (task-specific, stay in workspace):
- `fix-arg-too-long.md`
- `ios-visibility-image-gen-bug.md`
- `migrate-pipeline-to-repo.md`
- `mobile-library-gen.md`
- `pipeline-task-timestamps-planning.md`
- `planning-in-monitor-v2.md`
- `planning-in-monitor.md`

### 5. `.clawdbot/README.md`

Brief docs explaining:
- What `.clawdbot/` is
- Directory structure (scripts/, prompts/)
- Where state lives (configurable via `CLAWDBOT_STATE_DIR`)
- How to dispatch a task
- Env vars reference

### 6. `.gitignore` additions

Add to the repo's root `.gitignore`:
```
# Clawdbot pipeline state (should never be committed)
.clawdbot/logs/
.clawdbot/.tasks.lock
```

---

## Files NOT Migrated (Stay in Workspace)

These are runtime/machine-specific state — they must NOT be in the repo:
- `active-tasks.json` — task registry
- `logs/` — agent log files and filled prompts
- `plans/` — generated plan files
- `.tasks.lock` — file lock
- `notify-outbox.jsonl` — notification queue
- `gh-poll-state.json` — GitHub polling state
- Task-specific prompt files (see above)

---

## Implementation Steps

### Step 1: Create directory structure
```
.clawdbot/
├── README.md
├── scripts/
│   ├── config.sh          (rewritten)
│   ├── spawn-agent.sh     (verbatim)
│   ├── dispatch.sh        (verbatim)
│   ├── check-agents.sh    (verbatim)
│   ├── monitor.sh         (verbatim)
│   ├── cleanup-worktrees.sh (verbatim)
│   ├── notify.sh          (verbatim)
│   ├── approve-plan.sh    (verbatim)
│   ├── reject-plan.sh     (verbatim)
│   ├── review-plan.sh     (verbatim)
│   ├── fill-template.sh   (verbatim)
│   ├── gh-poll.sh         (one-line fix)
│   └── gh-poll-process.py (verbatim)
└── prompts/
    ├── audit.md
    ├── create-pr.md
    ├── fix-feedback.md
    ├── implement.md
    ├── plan.md
    ├── review-plan.md
    └── test.md
```

### Step 2: Write config.sh with new path logic
As described above.

### Step 3: Copy all other scripts verbatim
One `cp` per file, then `chmod +x`.

### Step 4: Fix gh-poll.sh
Change `PIPELINE_DIR` to `STATE_DIR` for the state file path.

### Step 5: Copy prompt templates
Copy the 7 generic templates verbatim.

### Step 6: Update .gitignore
Add `.clawdbot/logs/` and `.clawdbot/.tasks.lock`.

### Step 7: Create README.md

### Step 8: Verify
- Run `bash -n .clawdbot/scripts/*.sh` to syntax-check all scripts
- Verify all scripts can source config.sh without errors
- Verify `PROMPTS_DIR` resolves to `.clawdbot/prompts/` in repo
- Verify `STATE_DIR` resolves to workspace directory

---

## Risk Assessment

### Low Risk
- **All scripts except config.sh are copied verbatim** — no behavioral changes
- **Variable names are preserved** — `TASKS_FILE`, `LOG_DIR`, `PROMPTS_DIR`, etc. all keep their names
- **Script sourcing pattern is preserved** — `source "$SCRIPT_DIR/config.sh"` works identically since config.sh is still in the same directory as all other scripts
- **monitor.sh Python internals work unchanged** — the `os.path.dirname(script_dir)` + `'prompts'` pattern produces the correct path with the new layout
- **State files are untouched** — nothing moves, nothing gets reformatted

### Medium Risk
- **SLACK_WEBHOOK_URL removal** — the hardcoded default is removed from config.sh. If the env var isn't set, Slack notifications silently skip (existing behavior in notify.sh when URL is empty). This is the correct behavior but means existing launchd/cron setups that relied on the hardcoded URL will need to set the env var.
  - **Mitigation**: Document in README.md. The user can set it in their launchd plist or shell profile.

### No Risk
- **Worktree availability** — `.clawdbot/` is part of the repo, so it's automatically present in every worktree. This is the whole point of the migration.
- **Task-specific prompts** — they stay in the workspace and are referenced by absolute path (via `--plan-file`), so they're unaffected.

---

## Testing Strategy

1. **Syntax check**: `bash -n .clawdbot/scripts/*.sh` — all scripts parse without errors
2. **Config resolution**: Source config.sh from within the repo and verify:
   - `PROMPTS_DIR` → `<repo>/.clawdbot/prompts/`
   - `STATE_DIR` → `~/.openclaw/workspace-kopiclaw/pipeline/`
   - `TASKS_FILE` → `<state>/active-tasks.json`
3. **Template verification**: Check that all 7 prompt templates exist in `.clawdbot/prompts/`
4. **Dry-run dispatch**: After merging, dispatch a small test task and verify the pipeline runs end-to-end

PLAN_VERDICT:READY
