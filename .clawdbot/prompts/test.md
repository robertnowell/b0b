# Testing & Validation

## Context
Read CLAUDE.md for repo conventions.

## What was implemented
{DESCRIPTION}

## Product Goal
{PRODUCT_GOAL}

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
4. If any tests fail, fix them
5. Output a test report:
   - TESTS_PASSED: yes/no
   - BUILD_PASSED: yes/no
   - LINT_PASSED: yes/no
   - NEW_TESTS_WRITTEN: list of test files
   - MANUAL_TESTING: list of things a human should verify (UI flows, edge cases, integrations)
   - ISSUES_FOUND: any bugs or concerns discovered during testing

IMPORTANT: Your final output MUST end with a structured verdict line in exactly this format:
`TEST_VERDICT:PASS` or `TEST_VERDICT:FAIL`
This line must appear on its own line at the very end of your output, after all other content.
