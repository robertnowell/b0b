# Code Audit

## Original PRD
{PRD}

## Implementation Plan
{PLAN}

## Your Task
Audit this implementation against the PRD and plan. Check:
1. Does the implementation match the PRD requirements?
2. Are all deliverables present?
3. Any bugs, edge cases, or security issues?
4. Are tests adequate?
5. Does it follow repo conventions (see CLAUDE.md)?

Run `git diff main...HEAD` to see all changes.
Run `pnpm lint` and `pnpm build` in changed packages.

Output a structured assessment:
- PASS / FAIL
- Issues found (critical / minor)
- Missing deliverables
- Suggested fixes
