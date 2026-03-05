# PLAN.md — Kopiclaw Agent Swarm: Remaining Work

## Audit Summary (from Claude Code + Codex, 2026-02-26)

### What's Solid
- Worktree isolation + tmux execution model ✅
- Shell injection fix (prompt via file, not interpolation) ✅
- Task registration on spawn ✅
- Structured JSON status output (check-agents.sh) ✅
- CLAUDE.md repo context for agents ✅
- WORKFLOW.md pipeline design ✅

### Critical Issues (both agents agree)
1. **Broken lifecycle** — Tasks created as `running` but nothing writes terminal states back. Cleanup script is dead code.
2. **No file locking** on active-tasks.json — concurrent writes will corrupt.
3. **No timeout/kill** — hung agents live forever.
4. **No orchestration logic** — Scripts are "hands" but the "brain" (WORKFLOW.md phases) is 0% automated.
5. **No prompt templates** — Every dispatch requires hand-writing prompts.
6. **pnpm install in every spawn** — Slow, can fail silently.
7. **Logs in /tmp** — Lost on reboot.
8. **Codex via npx** — Can hang on install prompt.

### Gap: Current State vs Vision

| Capability | Status |
|---|---|
| Spawn/monitor agents | ~70% (scripts work, missing lifecycle) |
| Plan features (PRD → confirm) | 0% |
| Plan agents (create plan → review → uncertainty) | 0% |
| Post-implementation checks | 0% |
| Cross-agent audit | 0% |
| PR pipeline (create, review, iterate) | 0% |
| Monitor loop (cron, respawn, alert) | 10% (cron exists, disabled, no logic) |
| Learning loop | 0% |

---

## Prioritized Implementation Plan

### Week 1: Fix Infra + Prompt Templates

| # | Task | Size | Agent |
|---|---|---|---|
| 1 | **Status writeback** — check-agents.sh writes derived status back to active-tasks.json | S | Orchestrator fix |
| 2 | **Log file reset** — truncate on re-spawn, move logs to .clawdbot/logs/ | S | Orchestrator fix |
| 3 | **Task timeout** — kill after MAX_RUNTIME, mark failed | S | Script fix |
| 4 | **File locking** — flock on active-tasks.json reads/writes | S | Script fix |
| 5 | **Pin Codex path** — direct binary, no npx | S | Config |
| 6 | **Prompt templates** — implement.md, audit.md, create-pr.md, review-plan.md, fix-feedback.md | M | Human + orchestrator |

### Week 2: Monitor Loop + State Machine

| # | Task | Size | Agent |
|---|---|---|---|
| 7 | **Task state machine** — phases: planning → implementing → auditing → pr → reviewing → merged | M | Codex |
| 8 | **Monitor script** — check → decide → act loop with retry budget and Slack alerts | M | Codex |
| 9 | **Enable cron** — 10 min monitor, daily cleanup | S | Config |
| 10 | **Slack notifications** — task failed, PR ready, CI failing, human needed | S | Script |

### Week 3: Orchestrator Brain

| # | Task | Size | Agent |
|---|---|---|---|
| 11 | **Orchestrator dispatch** — receives feature → PRD → plan → spawn → audit → PR → review → iterate | L | The big one |
| 12 | **Plan → review → spawn flow** — create plan with Agent A, review with Agent B, uncertainty scoring | M | Part of #11 |
| 13 | **Post-impl quality gate** — "tested? risks? migration impact?" | S | Prompt template |

### Week 4: PR Pipeline + Learning

| # | Task | Size | Agent |
|---|---|---|---|
| 14 | **Auto-PR creation** — generate PR body from plan + diff, screenshots for UI | M | Claude Code |
| 15 | **Multi-reviewer dispatch** — parallel reviews (Codex + Claude + Gemini), route critical back | M | Orchestrator |
| 16 | **CI watch + auto-fix** — extract failures, spawn fix agent | M | Orchestrator |
| 17 | **Outcome logging** — .clawdbot/outcomes.jsonl, prompt history | S | Script |
| 18 | **Retrospective analysis** — what works, prompt improvements | M | Ongoing |

### Critical Path
```
Infra fixes (#1-5) → Prompt templates (#6) → State machine (#7) → Monitor loop (#8-10) → Orchestrator brain (#11-12) → PR pipeline (#14-16)
```
