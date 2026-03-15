# Fix Review Feedback

## Original Task
{TASK_DESCRIPTION}

## Product Goal
{PRODUCT_GOAL}

## Original User Request
{USER_REQUEST}

{IMAGES}

## Implementation Plan
{PLAN}

## Implementation Changes
Run `git diff --stat {AGENT_COMMIT_BOUNDARY}...HEAD` to see the current state of changes. Use `git diff {AGENT_COMMIT_BOUNDARY}...HEAD -- <file>` to inspect specific files.

## Feedback to Address
{FEEDBACK}

## Instructions
1. Read each piece of feedback carefully
2. Fix ONLY critical issues — ignore style nits and "consider..." suggestions
3. Ensure fixes stay aligned with the product goal and implementation plan above
4. **Scope discipline:**
   - Only modify files directly related to the task described above
   - **NEVER revert, remove, or undo changes from commits that existed on this branch before this task started.** Use `git log --oneline origin/main...HEAD` to identify pre-existing commits vs. agent-authored commits. Pre-existing commits from other developers are sacred — do not touch them.
   - If tests fail due to pre-existing issues unrelated to this task, report them in your summary but do NOT attempt to fix them
   - Never modify files outside the scope of the original task
5. Run `pnpm lint` and `pnpm build` in changed packages
6. Write brief commit messages matching repo style (see CLAUDE.md). The PR number will be added automatically by GitHub on squash-merge, so do NOT include (#NNN) in your commits — just write clear descriptions like `address review feedback`
7. Push to the same branch
8. Summarize what you fixed and what you intentionally skipped (with reasoning)
