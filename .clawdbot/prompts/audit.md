# Code Audit

## Original PRD
{PRD}

## Implementation Plan
{PLAN}

## Original User Request
{USER_REQUEST}

{IMAGES}

## Your Task
Audit this implementation against the PRD and plan. Check:
1. Does the implementation match the PRD requirements?
2. Are all deliverables present?
3. Any bugs, edge cases, or security issues?
4. Are tests adequate?
5. Does it follow repo conventions (see CLAUDE.md)?

Run `git diff main...HEAD` to see all changes.
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
