# Migration Plan: Consolidate Pipeline into .clawdbot/ (Updated)

## Current State

Commit `1c1c614ac` ("add agent pipeline scripts and prompts to .clawdbot") already completed Phase 1:
- 13 scripts copied to `.clawdbot/scripts/`
- 7 standard prompt templates copied to `.clawdbot/prompts/`
- `config.sh` rewritten with `CLAWDBOT_DIR`/`STATE_DIR` split (env var `CLAWDBOT_STATE_DIR` for override)
- `gh-poll.sh` updated to use `STATE_DIR` instead of `PIPELINE_DIR`
- `README.md` created in `.clawdbot/`
- `.gitignore` partially updated (has `.clawdbot/logs/` and `.clawdbot/.tasks.lock`)

The workspace copies at `/Users/kopi/.openclaw/workspace-kopiclaw/pipeline/scripts/` and `pipeline/prompts/` still exist (old versions). All non-config scripts are byte-identical between workspace and repo.

## Remaining Work

### 1. Complete `.gitignore` defensive entries

**File:** `.gitignore` (repo root)

Add missing defensive entries to prevent accidental commits of state files:

```gitignore
# Agent pipeline state (not committed)
.clawdbot/logs/
.clawdbot/.tasks.lock
.clawdbot/plans/
.clawdbot/active-tasks.json
.clawdbot/notify-outbox.jsonl
.clawdbot/gh-poll-state.json
```

Currently only `.clawdbot/logs/` and `.clawdbot/.tasks.lock` are present.

### 2. Update launchd plist

**File:** `~/Library/LaunchAgents/com.kopiclaw.monitor.plist`

Change ProgramArguments from:
```
/Users/kopi/.openclaw/workspace-kopiclaw/pipeline/scripts/monitor.sh
```
to:
```
/Users/kopi/Projects/kopi/.clawdbot/scripts/monitor.sh
```

Then reload:
```bash
launchctl unload ~/Library/LaunchAgents/com.kopiclaw.monitor.plist
launchctl load ~/Library/LaunchAgents/com.kopiclaw.monitor.plist
```

### 3. Update OpenClaw cron jobs

**File:** `/Users/kopi/.openclaw/cron/jobs.json`

Two jobs need path updates:

**gh-poll-kopiclaw** (line 20): References `/Users/kopi/.openclaw/workspace-kopiclaw/scripts/gh-poll.sh` (note: `scripts/` not `pipeline/scripts/` — this path doesn't even exist; the workspace has no `scripts/` at root). Update to:
```
/Users/kopi/Projects/kopi/.clawdbot/scripts/gh-poll.sh
```

**monitor-pipeline** (line 50): Uses `cd /Users/kopi/.openclaw/workspace-kopiclaw && bash pipeline/scripts/check-agents.sh` and `pipeline/scripts/monitor.sh`. Update to use absolute paths to repo:
```
/Users/kopi/Projects/kopi/.clawdbot/scripts/check-agents.sh
/Users/kopi/Projects/kopi/.clawdbot/scripts/monitor.sh
```
The `cat pipeline/active-tasks.json` reference should use `CLAWDBOT_STATE_DIR` or the absolute path `~/.openclaw/workspace-kopiclaw/pipeline/active-tasks.json` (state stays in workspace).

### 4. Update workspace docs — AGENTS.md

**File:** `/Users/kopi/.openclaw/workspace-kopiclaw/AGENTS.md`

Update the "Quick Reference" section (lines 258-273) — script paths change from `pipeline/scripts/X.sh` to paths relative to repo or absolute:

```bash
# Old
pipeline/scripts/spawn-agent.sh <task-id> ...
pipeline/scripts/dispatch.sh --task-id ...
pipeline/scripts/check-agents.sh
pipeline/scripts/monitor.sh
pipeline/scripts/cleanup-worktrees.sh

# New (use $REPO_ROOT which is set in config.sh)
$REPO_ROOT/.clawdbot/scripts/spawn-agent.sh <task-id> ...
$REPO_ROOT/.clawdbot/scripts/dispatch.sh --task-id ...
$REPO_ROOT/.clawdbot/scripts/check-agents.sh
$REPO_ROOT/.clawdbot/scripts/monitor.sh
$REPO_ROOT/.clawdbot/scripts/cleanup-worktrees.sh
```

Also update line 244 reference to `spawn-agent.sh`, `dispatch.sh`, `monitor.sh` and line 259/263/267/270/273 with the new paths.

### 5. Update workspace docs — TOOLS.md

**File:** `/Users/kopi/.openclaw/workspace-kopiclaw/TOOLS.md`

Lines 14-20 — update "Agent Swarm Scripts" section:

```markdown
## Agent Swarm Scripts
- `$REPO_ROOT/.clawdbot/scripts/spawn-agent.sh` — Spawn agent in tmux with worktree
- `$REPO_ROOT/.clawdbot/scripts/dispatch.sh` — Orchestrator dispatch
- `$REPO_ROOT/.clawdbot/scripts/check-agents.sh` — Check all agent statuses
- `$REPO_ROOT/.clawdbot/scripts/monitor.sh` — Advance pipeline phases (launchd runs this)
- `$REPO_ROOT/.clawdbot/scripts/cleanup-worktrees.sh` — Clean merged/failed worktrees
- State: `~/.openclaw/workspace-kopiclaw/pipeline/` (active-tasks.json, logs/, plans/)
```

### 6. Update workspace docs — ARCHITECTURE.md

**File:** `/Users/kopi/.openclaw/workspace-kopiclaw/ARCHITECTURE.md`

Major updates needed:
- **Line 174:** "All scripts live in `/Users/kopi/.openclaw/workspace-kopiclaw/pipeline/scripts/`" → "All scripts live in `$REPO_ROOT/.clawdbot/scripts/` (committed to the Rendition repo)"
- **Section 4 (Pipeline Scripts):** Update config.sh description to reflect new `CLAWDBOT_DIR`/`STATE_DIR` split
- **Section 5 (Data Model):** Clarify state files remain at `~/.openclaw/workspace-kopiclaw/pipeline/`
- **Section 6 (Cron):** Update monitor cron to reference new paths
- **Section 8 (Prompt System):** "All templates live in `pipeline/prompts/`" → "Standard templates live in `$REPO_ROOT/.clawdbot/prompts/`. Task-specific one-off prompts live in `~/.openclaw/workspace-kopiclaw/pipeline/prompts/`"
- **Section 9 (Workspace Layout):** Update the workspace tree diagram — `pipeline/` no longer has `scripts/` or standard prompt templates

### 7. Remove workspace `pipeline/scripts/` and standard prompt templates

**Directory:** `/Users/kopi/.openclaw/workspace-kopiclaw/pipeline/scripts/` (delete entirely)
**Files:** Delete standard templates from `/Users/kopi/.openclaw/workspace-kopiclaw/pipeline/prompts/`:
- `audit.md`, `create-pr.md`, `fix-feedback.md`, `implement.md`, `plan.md`, `review-plan.md`, `test.md`

Keep task-specific one-offs in `pipeline/prompts/`:
- `consolidate-clawdbot.md`, `fix-arg-too-long.md`, `ios-visibility-bug-replan.md`, `ios-visibility-image-gen-bug.md`, `migrate-pipeline-to-repo.md`, `mobile-library-gen.md`, `pipeline-task-timestamps-planning.md`, `planning-in-monitor-v2.md`, `planning-in-monitor.md`

Keep the `pipeline/` directory for runtime state:
- `active-tasks.json`, `.tasks.lock`, `gh-poll-state.json`, `notify-outbox.jsonl`, `logs/`, `plans/`

### 8. Remove legacy `PIPELINE_DIR` alias from config.sh

**File:** `.clawdbot/scripts/config.sh` line 19

The alias `PIPELINE_DIR="${STATE_DIR}"` exists for backward compatibility. After workspace scripts are deleted (step 7), nothing should reference `PIPELINE_DIR` anymore. Remove it.

Verify first: grep all scripts for `PIPELINE_DIR` references. Currently only `config.sh:19` in the repo uses it. The workspace copy of `gh-poll.sh` uses it (line 12), but that copy will be deleted.

---

## Files to Modify/Create

| File | Action | Description |
|------|--------|-------------|
| `.gitignore` | Modify | Add 4 missing defensive gitignore entries for state files |
| `.clawdbot/scripts/config.sh` | Modify | Remove `PIPELINE_DIR` legacy alias (line 19) |
| `~/Library/LaunchAgents/com.kopiclaw.monitor.plist` | Modify | Update monitor.sh path to repo location |
| `/Users/kopi/.openclaw/cron/jobs.json` | Modify | Update both cron jobs to use repo script paths |
| `~/.openclaw/workspace-kopiclaw/AGENTS.md` | Modify | Update Quick Reference script paths |
| `~/.openclaw/workspace-kopiclaw/TOOLS.md` | Modify | Update Agent Swarm Scripts paths |
| `~/.openclaw/workspace-kopiclaw/ARCHITECTURE.md` | Modify | Update script/template locations throughout |
| `~/.openclaw/workspace-kopiclaw/pipeline/scripts/` | Delete | Remove entire directory (old copies) |
| `~/.openclaw/workspace-kopiclaw/pipeline/prompts/{standard}` | Delete | Remove 7 standard template copies |

---

## Execution Order

1. Ensure no agents are actively running (`check-agents.sh`)
2. Update `.gitignore` in Rendition repo
3. Remove `PIPELINE_DIR` alias from `.clawdbot/scripts/config.sh`
4. Update launchd plist + reload
5. Update OpenClaw cron jobs
6. Test: run `check-agents.sh` and `monitor.sh` from new paths
7. Update workspace docs (AGENTS.md, TOOLS.md, ARCHITECTURE.md)
8. Delete workspace `pipeline/scripts/` and standard prompt templates
9. Commit repo changes to `feat/consolidate-clawdbot` branch

---

## Testing Strategy

- Run `.clawdbot/scripts/check-agents.sh` from repo — should list active tasks correctly
- Run `.clawdbot/scripts/monitor.sh` from repo — should process tasks
- Verify launchd is using new path: `launchctl list | grep kopiclaw`
- Dispatch a small test task to verify end-to-end pipeline still works
- Verify state files are still written to `~/.openclaw/workspace-kopiclaw/pipeline/` (not to `.clawdbot/`)

No automated tests exist for the pipeline scripts (bash + python). Validation is manual/functional.

---

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Cron/launchd points to wrong path → monitor stops | Medium | Test immediately after update; workspace copy exists as fallback until step 8 |
| OpenClaw cron `gh-poll-kopiclaw` already broken | High | Currently references non-existent `workspace-kopiclaw/scripts/gh-poll.sh` (no `scripts/` dir at workspace root). Fixing this is an improvement. |
| Active agents during cutover | Low | Check first; only proceed when no agents running |
| Workspace docs get stale | Low | Update in same session; these are reference docs |

---

## Estimated Complexity

**small** — All scripts are already in the repo. Remaining work is path updates in config files and documentation, plus cleanup of old copies. No code logic changes.
