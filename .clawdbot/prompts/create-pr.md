# Create Pull Request

## Task
{TASK_DESCRIPTION}

## Original User Request
{USER_REQUEST}

{IMAGES}

## Instructions
1. Run `git status` to see all changes in the worktree
2. Stage ONLY files relevant to this task using `git add <specific-files>` (NOT `git add .`). If there are unrelated modified or untracked files, leave them unstaged — do not commit them.
3. Commit with a clear message matching repo style
4. Run `pnpm lint` and `pnpm build` in changed packages — fix any errors
5. Push your branch
6. Check if a PR already exists on this branch: `gh pr list --head <branch-name> --json number,url`
   - **If a PR exists**: just push your changes — the existing PR updates automatically. Do NOT create a new PR. Skip to step 8.
   - **If no PR exists**: create one with `gh pr create` including:
   - Title: [Package] Brief description
   - Body with ALL sections below (mandatory):

### PR Body Template

```
## Problem
What's broken or missing? Be specific.

## Solution
What did you change and why?

## Manual Testing

### 🐛 How to reproduce (before fix)
Step-by-step instructions to see the bug/missing feature on `main`:
1. Go to...
2. Do...
3. Observe: [broken behavior]

### ✅ How to verify (after fix)
Step-by-step instructions to confirm the fix works on this branch:
1. Go to...
2. Do...
3. Observe: [expected behavior]

### ⚠️ Regression checks
Other flows to sanity-check that weren't broken by this change:
- [ ] Check A still works
- [ ] Check B still works

## Automated Testing
- [ ] Unit tests pass
- [ ] Lint passes
- [ ] Build succeeds

## Screenshots
(If UI changes — before/after)
```

7. If you changed UI, capture screenshots and include them
8. The Manual Testing section is MANDATORY — do not skip it. Think about how a human tester would verify this change.
