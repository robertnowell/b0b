# Fix: Logo LLM selection error should be loud + fall through to wordmark

## Context
When `selectBestLogoWithLLM` throws (line 755 in crawl-utils.ts), the catch block silently returns the first candidate with a generic reason string. The caller treats this as a successful LLM selection.

**Problems:**
1. Errors look like successes in Slack (same "llm-selection" method, no error detail)
2. The actual error is only in `console.error` — can't diagnose from Slack
3. No critical alert — goes to "assets" channel like normal
4. Blindly picks first candidate instead of falling through to wordmark generation

## Changes

**File: `src/lib/features/crawling/crawl-utils.ts`**

### 1. Error catch returns null + error info (lines 755-761)
Instead of returning the first candidate, return `selectedUrl: null` with the error details so the caller falls through to wordmark generation:

```typescript
// Before
} catch (error) {
  console.error("[selectLogo] LLM selection failed:", error);
  return {
    selectedUrl: topCandidates[0].url,
    reason: "Selection skipped due to error, using first candidate",
  };
}

// After
} catch (error) {
  console.error("[selectLogo] LLM selection failed:", error);
  const errorMessage = error instanceof Error ? error.message : String(error);
  return {
    selectedUrl: null,
    reason: `LLM selection failed: ${errorMessage}`,
    error: true,
  };
}
```

Update the return type to `Promise<{ selectedUrl: string | null; reason: string; error?: boolean }>`.

### 2. Handle error flag in processLogoCandidates (after line 887)
After the LLM selection call, add a branch for `selection.error` before the existing `selection.selectedUrl` check:

```typescript
const selection = await selectBestLogoWithLLM(llmCandidates, brandName);

if (selection.error) {
  // Log error to critical Slack channel, then fall through to wordmark
  logLogoSelectionToSlack(null, "llm-error", selection.reason, "critical");
} else if (selection.selectedUrl) {
  // ... existing success path (lines 891-922) ...
} else {
  // ... existing "LLM rejected all" path (lines 925-931) ...
}
```

This way, on error the code falls through to the wordmark generation at line 941.

### 3. Update logLogoSelectionToSlack to accept optional channel (line 847)
Add a channel parameter defaulting to "assets":

```typescript
const logLogoSelectionToSlack = (
  selectedUrl: string | null,
  selectionMethod: string,
  reason: string,
  channel: SlackChannel = "assets"
) => {
  // ... existing message building ...
  sendSlackAlert({}, slackMessage, channel).catch(() => { });
};
```

Need to import `SlackChannel` type if not already imported — check existing imports at top of file.

## Files to modify
- `src/lib/features/crawling/crawl-utils.ts` — all changes are in this single file

## Verification
1. Trigger a logo selection that errors (e.g., mock the Gemini call to throw)
2. Confirm Slack alert goes to #critical with method "llm-error" and includes the actual error message
3. Confirm the logo falls through to wordmark generation (not first candidate)
4. Confirm normal LLM selections still go to #assets with method "llm-selection" as before
