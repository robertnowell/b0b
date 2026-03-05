# Testing & Validation

## Context
Read CLAUDE.md for repo conventions.

## What was implemented
{DESCRIPTION}

## Product Goal
{PRODUCT_GOAL}

## Implementation Plan
{PLAN}

## Original User Request
{USER_REQUEST}

{IMAGES}

## Implementation Diff
{DIFF}

## Your Task
1. Identify which packages were changed (from the diff)
2. In each changed package, run:
   - `pnpm lint` — report any lint errors
   - `pnpm build` — report any build errors
   - `pnpm test` — report test results
3. Check test coverage:
   - Are there tests for the new functionality?
   - If not, write them
4. If tests fail:
   - If the failure is caused by changes in this task, fix it
   - If the failure is pre-existing / unrelated to this task's diff, report it but do NOT fix it — never modify files outside the scope of the original task
5. Output a test report covering results, new tests written, manual testing notes, and issues found.

IMPORTANT: Your final output MUST end with the following structured block.
Every field is required — use "yes" or "no" for pass fields, 0 for counts, and "none" for empty lists.
```
TEST_FINDINGS_START
TESTS_PASSED: yes/no
BUILD_PASSED: yes/no
LINT_PASSED: yes/no
CRITICAL: <number of critical issues>
MINOR: <number of minor issues>
MISSING: <comma-separated missing items, or "none">
SUMMARY: <1-3 sentence assessment of test results>
TEST_FINDINGS_END
TEST_VERDICT:PASS or TEST_VERDICT:FAIL
```
The TEST_FINDINGS block and TEST_VERDICT line must each appear on their own lines at the very end of your output, after all other content.
