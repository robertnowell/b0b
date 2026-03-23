# Fix Review Feedback

## Feedback to Address
{FEEDBACK}

## Instructions — Read This Before Doing Anything
**You MUST address the feedback above. Do NOT skip it.** Read the feedback, investigate the issue it describes, and make code changes to fix it. If you believe the existing code already handles it, explain exactly why with evidence (file paths, line numbers, test output). Simply declaring "already done" is not acceptable.

## Context

### Original Task
{TASK_DESCRIPTION}

### Product Goal
{PRODUCT_GOAL}

### Original User Request
{USER_REQUEST}

{IMAGES}

### Implementation Plan
{PLAN}

### Implementation Changes
Run `git diff --stat {AGENT_COMMIT_BOUNDARY}...HEAD` to see the current state of changes. Use `git diff {AGENT_COMMIT_BOUNDARY}...HEAD -- <file>` to inspect specific files.

## Instructions
1. Read each piece of feedback carefully
2. Fix ONLY critical issues **that are within scope of the Original User Request** — ignore style nits, "consider..." suggestions, and any feedback about pre-existing issues unrelated to the task
3. Ensure fixes stay aligned with the product goal and implementation plan above
4. **Scope discipline:**
   - Only modify files directly related to the task described above
   - **NEVER revert, remove, or undo changes from commits that existed on this branch before this task started.** Use `git log --oneline origin/main...HEAD` to identify pre-existing commits vs. agent-authored commits. Pre-existing commits from other developers are sacred — do not touch them.
   - If tests fail due to pre-existing issues unrelated to this task, report them in your summary but do NOT attempt to fix them
   - Never modify files outside the scope of the original task
5. **Out-of-scope findings:** If the audit flagged issues outside the scope of the Original User Request (e.g., pre-existing bugs in touched files, adjacent improvements), do NOT fix them. Note them in your summary as "out of scope — skipped" so they can be tracked separately.
6. Run `pnpm lint` and `pnpm build` in changed packages
7. Write brief commit messages matching repo style (see CLAUDE.md). The PR number will be added automatically by GitHub on squash-merge, so do NOT include (#NNN) in your commits — just write clear descriptions like `address review feedback`
8. Push to the same branch
9. Summarize what you fixed and what you intentionally skipped (with reasoning)
