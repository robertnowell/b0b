# Plan: Pipeline Cron Comparison — launchd vs OpenClaw cron

## Summary

This is a **research/comparison deliverable**, not a code implementation task. The goal is to produce a thorough comparison of launchd vs OpenClaw cron for running `monitor.sh` and pipeline crons, then recommend an approach.

A comprehensive comparison document already exists at `pipeline/plans/pipeline-cron-comparison.md` (279 lines). It was produced during this branch's work and covers all required dimensions.

---

## Files to Modify/Create

### 1. `pipeline/plans/pipeline-cron-comparison.md` (already created — no changes needed)

The comparison document covers:
- **Architecture diagrams** for both launchd and OpenClaw cron (systemEvent + agentTurn modes)
- **Detailed comparison across 6 dimensions:** reliability, visibility, token/cost efficiency, flexibility, failure modes, and hybrid approaches
- **Failure mode tables** for both approaches with detection and recovery strategies
- **Edge cases specific to this setup** (macOS sleep/wake, tmux session limits, 142KB active-tasks.json, worktree paths, Slack webhook rotation, GH_TOKEN auth)
- **Hybrid architecture recommendation** with ASCII diagram
- **Migration paths** for both full migration (not recommended) and hybrid (recommended)
- **Pros/cons summary tables** for all four options (launchd, OpenClaw systemEvent, OpenClaw agentTurn, hybrid)

### 2. No other files need modification

This task is purely analytical. The recommendation is to keep the existing launchd + monitor.sh setup and optionally layer OpenClaw cron on top for visibility. No code changes to the pipeline are required.

---

## Specific Changes

No code changes. The deliverable is the comparison document itself.

### Key Findings from the Comparison

1. **Reliability**: launchd wins decisively. It's a system-level daemon independent of OpenClaw's availability, handles sleep/wake gracefully, and the monitor.sh state machine is idempotent with flock-based concurrency.

2. **Visibility**: OpenClaw cron wins. The biggest gap in the current setup — Kopiclaw has no awareness of pipeline state unless Slack fires. systemEvent mode gives direct visibility; agentTurn can announce to channels.

3. **Token/Cost Efficiency**: launchd is free. OpenClaw cron burns tokens every cycle (~$2-20/month depending on mode and activity), even when idle.

4. **Flexibility**: launchd wins for complex logic (900-line state machine can't be reliably prompt-engineered). OpenClaw cron wins for schedule management ergonomics.

5. **Failure Modes**: launchd failures are well-understood, bounded, and self-healing. OpenClaw cron introduces novel failure modes (prompt hallucination, context bloat, OpenClaw process dependency).

### Recommendation: Hybrid Approach

- **Keep launchd as primary scheduler** — no changes to monitor.sh or the plist
- **Add OpenClaw cron as a visibility/summary layer**:
  - `pipeline-status` cron (every 5 min, agentTurn): reads `notify-outbox.jsonl`, summarizes new entries
  - `pipeline-dashboard` cron (every 30 min, agentTurn): reads `active-tasks.json`, posts dashboard summary
- **Rollback**: `cron remove pipeline-status && cron remove pipeline-dashboard` — zero impact on pipeline
- **Cost**: ~$2-5/month in tokens for summary jobs
- **Risk**: Zero — OpenClaw cron failure is invisible to pipeline operation

---

## Testing Strategy

No code changes means no automated tests. Validation of the comparison itself:

- **Accuracy check**: Cross-reference claims against `monitor.sh` source (verified — flock concurrency at line 91, idempotent design confirmed by state machine structure, respawn budget logic confirmed)
- **Architecture check**: Verified `config.sh` paths, `notify.sh` outbox population, and the full pipeline phase flow
- **Completeness check**: All dimensions requested (reliability, visibility, cost, flexibility, failure modes, migration) are covered

If the hybrid approach is implemented in a future task:
- Run both launchd and OpenClaw cron in parallel for 1 week
- Verify outbox is reliably read by OpenClaw cron job
- Confirm no interference with existing pipeline operation
- Check token costs match estimates

---

## Risk Assessment

- **Risk of doing nothing**: Low. Current launchd setup works. Only gap is visibility.
- **Risk of full migration to OpenClaw cron**: High. 900-line state machine cannot be reliably prompt-engineered. Single point of failure on OpenClaw process.
- **Risk of hybrid approach**: Very low. OpenClaw cron is read-only (reads outbox/tasks JSON). If it fails, nothing breaks.
- **Edge case**: `notify-outbox.jsonl` must be reliably populated by `notify.sh` — already confirmed in source (line 96-105 of notify.sh).

---

## Estimated Complexity

**trivial** — This is a research/comparison deliverable. The document is already written. No code changes required.

---

## Implementation of Hybrid (if approved as follow-up)

If the team decides to implement the hybrid approach, the follow-up task would be:

1. Create OpenClaw cron job for pipeline status summaries
2. Create OpenClaw cron job for dashboard summaries (30 min interval)
3. Test both jobs for 1 week alongside existing launchd
4. Document the cron job setup in `.clawdbot/README.md`

This would be a **small** complexity follow-up task.
