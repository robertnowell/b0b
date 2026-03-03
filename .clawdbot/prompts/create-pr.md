# Create Pull Request

## Task
{TASK_DESCRIPTION}

{IMAGES}

## Instructions
1. Ensure all changes are committed
2. Run `pnpm lint` and `pnpm build` in changed packages — fix any errors
3. Push your branch
4. Create a PR with `gh pr create` including:
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

5. If you changed UI, capture screenshots and include them
6. The Manual Testing section is MANDATORY — do not skip it. Think about how a human tester would verify this change.
