# Plan: Add user uid, name, email to inspiration image upload Slack alert

## Status: Implementation Already Complete (Uncommitted)

The implementation for this feature already exists as **uncommitted working tree changes** on branch `fix/svg-upload-slack-alert`. The changes span 5 files and correctly thread user info (uid, name, email) from the frontend through the API to the Slack alert.

## Files Modified (all changes already present as unstaged diffs)

### 1. `promotions/src/app/app/inspiration/page.tsx`
**Change:** Pass Firebase `currentUser` info when saving inspiration images.
- Gets `getAuth().currentUser` and passes `userName`, `userEmail`, `userUid` to `addAssets()`.

### 2. `promotions/src/lib/hooks/useBrandAssets.ts`
**Change:** Thread `userInfo` parameter through the hook's mutation pipeline.
- `appendAssets()` function accepts optional `userInfo` param and spreads it into the POST body.
- `addMutation` accepts `userInfo` in its mutation variables.
- `addAssets` callback accepts and forwards `userInfo`.

### 3. `promotions/src/app/api/brand-assets/route.ts`
**Change:** Extract user fields from request body and pass to server action.
- Destructures `userName`, `userEmail`, `userUid` from POST body.
- Constructs `userInfo` object and passes it to `appendBrandAssets()`.

### 4. `promotions/src/server/actions/brand-assets.ts`
**Change:** Accept `userInfo` param and include user details in Slack alert message.
- `appendBrandAssets()` accepts optional `userInfo?: { uid?: string; name?: string; email?: string }`.
- Slack message now includes `*User:* name (email)` and `*UID:* uid` lines.
- Falls back to "Unknown" when user info is not provided.
- Passes user info to `sendSlackAlert()` first argument as `{ uid, email, displayName }`.

### 5. `promotions/src/server/actions/brand-assets.test.ts`
**Change:** Tests updated and new test added for user info in Slack alerts.
- Existing test updated to verify `*User:* Unknown (Unknown)` and `*UID:* Unknown` when no user info provided.
- New test `"includes user info in the Slack alert when provided"` verifies user details appear in the message.
- Test assertions updated for bold markdown formatting (`*Images:*` instead of `Images:`).

## What Needs to Happen

### Step 1: Validate tests pass
```bash
cd promotions && npx vitest run src/server/actions/brand-assets.test.ts
```

### Step 2: Commit the changes
Stage and commit the 5 modified files (do NOT commit the stale `promotions/package-lock.json` — it's an untracked artifact not part of this feature).

### Step 3: Create PR targeting `main`
Title: "Add user info to inspiration image upload Slack alert"

## Previous Iteration Issue: `deps_install` Failure

The previous iteration failed during dependency installation. This is likely because:
- The `promotions/` package is **not** in the pnpm workspace (`pnpm-workspace.yaml` only includes `rendition-figma-plugin` and `assistant`).
- A stale `promotions/package-lock.json` was generated (untracked file). This should **not** be committed.
- `node_modules` already exists in `promotions/` — no dependency installation is needed for this change (no new dependencies were added).

**Resolution:** Skip dependency installation entirely. The changes are pure TypeScript/React code changes with no new imports or dependencies.

## Testing Strategy

- **Unit tests:** Run `vitest` on `brand-assets.test.ts` — covers all scenarios:
  - Slack alert sent with user info when provided
  - Falls back to "Unknown" when user info is missing
  - Multiple images listed correctly
  - No alert for non-inspiration assets
  - No alert when all inserts fail
  - Graceful handling of Slack failures
  - Mixed upload types only count inspiration assets
- **Type checking:** Run `npx tsc --noEmit` in promotions to verify no type errors
- **No new dependencies** — no build/install changes needed

## Risk Assessment

- **Low risk:** All changes are additive (new optional parameter, richer Slack message)
- **No breaking changes:** `userInfo` parameter is optional with "Unknown" fallback
- **Edge case:** If `getAuth().currentUser` is null on the frontend, all fields will be `undefined`, and the alert will show "Unknown" — this is handled correctly
- **The `sendSlackAlert` function appends user JSON** to the message text (line 82-83 of slack.ts), so user info will appear both in the formatted message AND as raw JSON at the bottom — this is existing behavior and acceptable

## Estimated Complexity

**trivial** — Implementation is already complete. Just needs test validation and commit/PR.
