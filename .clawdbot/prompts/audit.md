# Code Audit

## Original PRD
{PRD}

## Implementation Plan
{PLAN}

## Implementation Changes
Run `git diff --stat {AGENT_COMMIT_BOUNDARY}...HEAD` to see which files changed, then `git diff {AGENT_COMMIT_BOUNDARY}...HEAD -- <file>` to inspect specific files. Focus on source code changes — skip generated files, lock files, and snapshots.

## Scope Awareness
This branch may contain commits from human developers that pre-date this pipeline task. Use `git log --oneline origin/main...HEAD` to see all commits on this branch. Only audit changes that were made as part of THIS task's implementation — do NOT flag or recommend reverting pre-existing human commits. If you see files changed by commits that are clearly not part of the agent's implementation (e.g., different author, different topic), note them as "pre-existing / out of scope" and exclude them from your audit assessment.

**CRITICAL: Never recommend reverting, removing, or undoing changes from pre-existing commits. Your audit scope is limited to the agent's implementation of the plan.**

## Original User Request
{USER_REQUEST}

{IMAGES}

## Your Task
Audit this implementation against the PRD and plan. Compare the implementation changes to the plan.
1. Does the implementation match the PRD requirements?
2. Are all deliverables present?
3. Any bugs, edge cases, or security issues?
4. Are tests adequate?
5. Does it follow repo conventions (see CLAUDE.md)?
6. Are there any changes outside the plan's scope that were introduced by the agent? (Pre-existing human commits are NOT in scope — ignore them.)

Run `pnpm lint` and `pnpm build` in changed packages.

Output a structured assessment covering issues found, missing deliverables, and suggested fixes.

IMPORTANT: Your final output MUST end with the following structured block.
Every field is required — use 0 for counts and "none" for empty lists.
```
AUDIT_FINDINGS_START
CRITICAL: <number of critical issues>
MINOR: <number of minor issues>
MISSING: <comma-separated missing deliverables, or "none">
SUMMARY: <1-3 sentence assessment of the implementation>
AUDIT_FINDINGS_END
AUDIT_VERDICT:PASS or AUDIT_VERDICT:FAIL
```
The AUDIT_FINDINGS block and AUDIT_VERDICT line must each appear on their own lines at the very end of your output, after all other content.
