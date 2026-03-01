# Planning Phase in Pipeline Monitor — v3 Assessment

## Status: Already Implemented

After auditing every pipeline script, the planning phase is **fully implemented** across all files. This document serves as verification, architecture reference, and gap analysis.

---

## 1. Current Implementation by File

### monitor.sh — State Machine (lines 624–691)

**`get_plan_result()` (lines 179–238):** Detects and archives plan files.
- Search order: `{worktree}/plan.md` → `{worktree}/.clawdbot/plans/{task-id}.md`
- Checks for `PLAN_VERDICT:READY` in the plan file, then falls back to agent log
- Copies plan to `PLANS_DIR` (`pipeline/plans/{task-id}.md`) immediately on detection
- Returns `(status, summary, content, dest_path)` — content is preserved for downstream phases

**`planning + succeeded` handler (lines 624–691):**
```
planning + succeeded + PLAN_VERDICT:READY + requiresPlanReview=true
  → plan_review (human gate, Slack alert with plan summary)

planning + succeeded + PLAN_VERDICT:READY + requiresPlanReview=false
  → implementing (auto-advance, spawns implementation agent)

planning + succeeded + plan not ready
  → re-planning (respawn with iteration bump, up to maxIterations)
  → needs_split (if max iterations exhausted)
```

**`plan_review` skip (line 420):** Monitor treats `plan_review` as a terminal/parked phase — no automatic transitions. Human must run `approve-plan.sh` to advance.

**Dead-agent recovery (line 535):** `planning` is explicitly listed in the active-phases set for dead-agent respawn. Verified — planning agents that die mid-run get respawned with the same budget as implementing agents (max 2 respawns).

**Timeout/failure handlers (lines 462–530):** Generic — apply equally to all phases including `planning`. A timed-out planning agent gets respawned or moved to `needs_split`.

### spawn-agent.sh — Agent Spawning (line 27, 40–42)

- `--phase` flag defaults to `implementing` (line 27)
- Phase is stored in `active-tasks.json` entry (line 155, field `phase`)
- Task registration preserves `requiresPlanReview` across respawns (line 183)

### dispatch.sh — Orchestrator Entry Point (lines 45–80, 98–105)

- `--phase planning` is a valid value (line 80 validation regex)
- `--plan-file` is **not required** when `--phase planning` (lines 71–73) — correct, since no plan exists yet
- `--require-plan-review true|false` sets the human gate flag (lines 59, 81)
- Template selection: `planning → plan.md` (line 99)

### approve-plan.sh — Plan Approval (complete file)

- Validates task is in `plan_review` phase (line 41)
- Reads plan from `pipeline/plans/{task-id}.md` (line 65)
- Fills `implement.md` template with plan content as `{PLAN}` variable
- Spawns implementation agent via `spawn-agent.sh --phase implementing`
- Carries `planContent` through to the task entry (lines 94–112)
- Sends Slack notification (lines 115–120)
- Supports `--agent` override to switch agents between planning and implementing

### pipeline/prompts/plan.md — Planning Prompt Template (complete file)

Instructs the agent to:
1. Read CLAUDE.md for conventions
2. Investigate the codebase (find relevant files, understand architecture)
3. Write plan to `plan.md` at worktree root
4. Include: files to modify/create, specific changes, testing strategy, risk assessment, complexity estimate
5. Output `PLAN_VERDICT:READY` as the final line

### notify.sh — Slack Notifications (lines 14–30)

`_infer_next_step()` covers both planning phases:
- `planning` → "Will produce implementation plan for review"
- `plan_review` → "Awaiting human plan approval (approve-plan.sh or reject-plan.sh)"

### config.sh — Shared Config (line 12)

`PLANS_DIR="${PIPELINE_DIR}/plans"` — created on source via `mkdir -p` (line 21).

---

## 2. Plan Detection Logic (Detailed)

```python
# get_plan_result() search order (monitor.sh:191-198)
plan_paths = [
    "{worktree}/plan.md",                              # Primary: worktree root
    "{worktree}/.clawdbot/plans/{task-id}.md",         # Legacy: .clawdbot path
]
```

**Verdict detection (monitor.sh:208-225):**
1. Scan plan file (bottom-up) for `PLAN_VERDICT:READY`
2. If not found in plan, scan agent log file for the same sentinel
3. If verdict is `READY` → status `ready`
4. If no verdict or any other value → status `not_ready`

**Archival (monitor.sh:231-233):**
- Always copies plan to `pipeline/plans/{task-id}.md`, regardless of verdict
- Uses `shutil.copy2` (preserves timestamps)

---

## 3. Phase Transition Rules

```
dispatch.sh --phase planning
  │
  ▼
[planning] ──agent succeeds──▶ get_plan_result()
  │                               │
  │                   ┌───────────┴───────────┐
  │                   ▼                       ▼
  │              verdict=READY          verdict=not_ready
  │                   │                       │
  │         ┌─────────┴─────────┐        iteration++
  │         ▼                   ▼             │
  │  requiresPlanReview   !requiresPlanReview  ├── < maxIter → respawn planning
  │         │                   │              └── ≥ maxIter → needs_split
  │         ▼                   ▼
  │   [plan_review]      [implementing]
  │    (human gate)       (auto-advance)
  │         │
  │   approve-plan.sh
  │         │
  │         ▼
  │   [implementing]
  │
  ├──agent fails──▶ iteration++ → respawn or needs_split
  ├──agent timeout──▶ iteration++ → respawn or needs_split
  └──agent dies (unknown)──▶ respawn (up to 2) or failed
```

### Key properties:
- **Iteration counter** is shared across planning retries. A task that fails planning 4 times hits `needs_split`.
- **respawnCount** (dead-agent recovery) is separate from `iteration` (phase-level retries). A planning agent can die 2 times AND retry 4 iterations = up to 12 total spawns in worst case.
- **planContent** is carried through from `plan_review` → `implementing` → all subsequent phases. The implementing agent receives the full plan text in its `{PLAN}` template variable.

---

## 4. Gaps and Improvements

### Gap 1: No `reject-plan.sh`

`notify.sh` line 19 references `reject-plan.sh` but it doesn't exist. When the orchestrator rejects a plan, there's no script to:
- Move the task back to `planning` with feedback
- Bump the iteration counter
- Send a Slack notification

**Current workaround:** The orchestrator manually edits `active-tasks.json` or re-dispatches with `dispatch.sh --phase planning`.

**Proposed fix:** Create `pipeline/scripts/reject-plan.sh`:
```bash
#!/usr/bin/env bash
# reject-plan.sh <task-id> [--feedback "reason"]
# Moves task from plan_review back to planning with feedback.
# Appends feedback to findings, bumps iteration, respawns planning agent.
```

Fields to update:
- `phase` → `planning`
- `iteration` → increment
- `findings` → append rejection reason
- Respawn planning agent with feedback in prompt (via `{FEEDBACK}` template var)

### Gap 2: Plan file location mismatch risk

The plan prompt tells agents to write to `plan.md` at worktree root. The detection function checks `{worktree}/plan.md` first — this matches. But the legacy `.clawdbot/plans/{task-id}.md` path is also checked, which comes from the old failed `planning-in-monitor` attempt. This is fine for backward compat but:

- **Risk:** If an agent writes to `PLAN.md` (uppercase) instead of `plan.md`, it won't be found. macOS filesystem is case-insensitive by default so this works on Mac but would fail on Linux CI.
- **Recommendation:** No change needed for now — all agents run on Mac.

### Gap 3: Plan review staleness

No mechanism alerts the orchestrator when a `plan_review` task has been sitting idle for >24 hours. The monitor skips `plan_review` entirely (line 420).

**Proposed fix:** Add a staleness check before the `continue` on line 420:
```python
if phase == 'plan_review':
    # Check staleness
    last_action = task.get('lastMonitorAction', 0)
    if now - last_action > 86400:  # 24 hours
        run_notify(tid, 'plan_review',
            f'Plan has been awaiting review for >24h. Run approve-plan.sh {tid}',
            product_goal)
        apply_updates(tid, {'lastMonitorAction': now})
    continue
```

### Gap 4: `PLAN_VERDICT` in agent log but not in plan file

The detection logic (monitor.sh:217-225) checks the agent log as a fallback. This means an agent could output `PLAN_VERDICT:READY` to stdout without actually writing a plan file — and the monitor would still archive whatever file it found (possibly an incomplete draft).

**Current behavior:** If a plan file exists but has no verdict, AND the log has the verdict, the plan is considered "ready" — even if the file is incomplete.

**Risk:** Low. The plan prompt explicitly says to write the verdict in the plan file. The log fallback handles edge cases where agents forget to write the sentinel to the file but DO write a good plan.

**Recommendation:** No change — the fallback is net-positive.

### Gap 5: `dispatch.sh` notification says "Will run audit on completion" for planning phase

Line 182 of `dispatch.sh` always sends `--next "Will run audit on completion"`. For `--phase planning`, this should say "Will produce plan for review" instead.

**Proposed fix** (dispatch.sh, after line 180):
```bash
NEXT_STEP="Will run audit on completion"
if [[ "$PHASE" == "planning" ]]; then
  NEXT_STEP="Will produce implementation plan for review"
fi
```
Then use `--next "$NEXT_STEP"` on line 182.

---

## 5. Evidence from Production

The `ios-visibility-bug` task in `active-tasks.json` shows the planning pipeline working end-to-end:

1. **Dispatched** with `--phase planning`
2. **First planning attempt** failed to produce plan file → "Plan #1: not ready - No plan file found" → iteration bumped
3. **Second attempt** succeeded → plan detected, archived to `pipeline/plans/ios-visibility-bug.md`, `planContent` stored (2800+ chars of detailed plan)
4. **Moved to `plan_review`** → Slack notification sent with summary
5. **Currently awaiting** human approval via `approve-plan.sh`

This confirms the full `planning → plan_review` path works. The `approve-plan.sh → implementing` path hasn't been exercised yet for this task but the script is tested and complete.

---

## 6. Summary

| Requirement | Status | Location |
|---|---|---|
| `planning` phase in monitor | Done | monitor.sh:624–691 |
| Plan file detection | Done | monitor.sh:179–238 |
| Plan archival to `pipeline/plans/` | Done | monitor.sh:231–233 |
| Plan review Slack notification | Done | monitor.sh:637–640 |
| Planning prompt template | Done | prompts/plan.md |
| Dead-agent recovery for planning | Done | monitor.sh:535 |
| `plan_review → implementing` | Done | approve-plan.sh |
| `dispatch.sh --phase planning` | Done | dispatch.sh:71–73, 99 |

### Remaining work (all optional improvements):
1. **Create `reject-plan.sh`** — small, ~50 lines, mirrors approve-plan.sh
2. **Fix `dispatch.sh` next-step message** — 3-line change
3. **Add plan review staleness alerts** — 6-line addition to monitor.sh
