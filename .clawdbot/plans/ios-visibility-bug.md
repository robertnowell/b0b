# Plan: Fix iOS Tab Backgrounding — Durable Backend Approach

## Problem

Chrome on iOS (WebKit-based) kills long-running `fetch()` connections when the user switches tabs. Image generation takes 5-30s via TRPC mutation (`conjure.generateImage`). When iOS kills the connection, the client gets a network error even though the backend completed successfully. The current code treats ALL errors as generation failures (toast + cleanup).

**Critical constraint**: Retrying the mutation causes DOUBLE image generation — wasting AI compute and creating duplicate assets.

## Why the Previous Plan Was Rejected

The previous plan relied on client-side heuristics (visibility tracking, error message parsing, polling brand assets by timestamp matching). This was fragile because:
- Error classification via message strings is brittle across browsers/versions
- Matching recovered assets by `createdAt > startTime` can false-match concurrent generations
- Only worked for library page (not popover, which doesn't save to brand)
- No single source of truth — the client was guessing whether the backend succeeded

## New Approach: Server-Authoritative Generation Job Tracking

Instead of client-side guessing, make the **backend the source of truth** for generation status. The client can always ask the server: "Did my generation complete?"

### Architecture

```
Client                           Server (TRPC)                    Firebase RTDB
  |                                  |                                |
  |-- generateImage(requestId) ----->|                                |
  |                                  |-- set /gen-jobs/{requestId}    |
  |                                  |   { status: "processing" } --->|
  |                                  |                                |
  |     [iOS kills connection]       |-- buildImageForUrl() (5-30s)   |
  |                                  |                                |
  |  X <--- response lost ---        |-- update /gen-jobs/{requestId} |
  |                                  |   { status: "completed",       |
  |                                  |     asset: {...} }          -->|
  |                                  |                                |
  |-- getGenerationStatus(reqId) --->|                                |
  |                                  |-- get /gen-jobs/{requestId} <--|
  |<--- { status: "completed",      |                                |
  |       asset: {...} }             |                                |
```

### Why Firebase RTDB (not PostgreSQL)?

- Already initialized in the codebase (`adminDatabase` from `firebase-admin.ts`)
- No SQL migration required
- Generation job data is transient (only needed for minutes, not permanently)
- Fast reads for polling
- Firebase RTDB is durable — data persists until explicitly deleted

---

## Files to Modify/Create

### 1. **NEW**: `promotions/src/server/services/generation-jobs.ts`
Server-side service for reading/writing generation job status to Firebase RTDB.

### 2. **MODIFY**: `promotions/src/server/routers/conjure.ts`
Add `requestId` parameter to `generateImage`, create/update job records, add `getGenerationStatus` query.

### 3. **NEW**: `promotions/src/lib/utils/poll-generation-status.ts`
Client-side utility to poll the `getGenerationStatus` endpoint with timeout and visibility-aware retry.

### 4. **MODIFY**: `promotions/src/app/app/library/page.tsx`
Generate `requestId`, pass to mutation, start recovery polling on error.

### 5. **MODIFY**: `promotions/src/components/image-generation-popover.tsx`
Same pattern — generate `requestId`, pass to mutation, start recovery polling on error.

### 6. **NEW**: `promotions/src/__tests__/generation-jobs.test.ts`
Unit tests for the generation jobs service and polling utility.

---

## Specific Changes

### File 1: `promotions/src/server/services/generation-jobs.ts` (NEW)

Service that wraps Firebase RTDB operations for generation job tracking.

```typescript
import { adminDatabase } from "@/lib/infrastructure/firebase/firebase-admin";

const JOBS_PATH = "generation-jobs";
const JOB_EXPIRY_MS = 10 * 60 * 1000; // 10 minutes

export type GenerationJobStatus = "processing" | "completed" | "failed";

export interface GenerationJob {
  status: GenerationJobStatus;
  startedAt: number;
  completedAt?: number;
  prompt?: string;
  model?: string;
  asset?: Record<string, unknown>; // The generated asset object
  error?: string;
}

export async function createGenerationJob(
  requestId: string,
  metadata: { prompt: string; model?: string }
): Promise<void> {
  await adminDatabase.ref(`${JOBS_PATH}/${requestId}`).set({
    status: "processing",
    startedAt: Date.now(),
    prompt: metadata.prompt,
    model: metadata.model,
  });
}

export async function completeGenerationJob(
  requestId: string,
  asset: Record<string, unknown>
): Promise<void> {
  await adminDatabase.ref(`${JOBS_PATH}/${requestId}`).update({
    status: "completed",
    completedAt: Date.now(),
    asset,
  });
}

export async function failGenerationJob(
  requestId: string,
  error: string
): Promise<void> {
  await adminDatabase.ref(`${JOBS_PATH}/${requestId}`).update({
    status: "failed",
    completedAt: Date.now(),
    error,
  });
}

export async function getGenerationJob(
  requestId: string
): Promise<GenerationJob | null> {
  const snapshot = await adminDatabase
    .ref(`${JOBS_PATH}/${requestId}`)
    .get();

  if (!snapshot.exists()) return null;

  const job = snapshot.val() as GenerationJob;

  // Auto-expire old jobs
  if (Date.now() - job.startedAt > JOB_EXPIRY_MS) {
    // Clean up expired entry (fire and forget)
    void adminDatabase.ref(`${JOBS_PATH}/${requestId}`).remove();
    return null;
  }

  return job;
}
```

**Key design decisions:**
- Jobs auto-expire after 10 minutes (checked on read, cleaned up lazily)
- `asset` is stored as a generic record to avoid coupling to the Asset type on the server
- Operations are simple RTDB set/update/get — no transactions needed since each job has exactly one writer (the mutation handler)

---

### File 2: `promotions/src/server/routers/conjure.ts` (MODIFY)

#### 2a. Add imports (top of file):
```typescript
import {
  createGenerationJob,
  completeGenerationJob,
  failGenerationJob,
  getGenerationJob,
} from "@/server/services/generation-jobs";
```

#### 2b. Add `requestId` to `generateImage` input schema (around line 28):

Add `requestId` as optional to maintain backward compatibility:
```typescript
.input(
  z.object({
    prompt: z.string(),
    options: imageOptionsSchema,
    saveToBrandId: z.string().min(1).optional(),
    requestId: z.string().min(1).optional(), // NEW: for durable job tracking
  })
)
```

#### 2c. Modify the `generateImage` mutation handler:

**After input validation, before `buildImageForUrl` call (~line 44):**
```typescript
// Track generation job for recovery from connection drops (e.g., iOS backgrounding)
if (input.requestId) {
  await createGenerationJob(input.requestId, {
    prompt: input.prompt,
    model: input.options.model,
  });
}
```

**After successful generation and brand save, before the return (~line 87):**
```typescript
// Update job status to completed
if (input.requestId) {
  void completeGenerationJob(input.requestId, result);
}
```

**In the catch block (~line 90), before re-throwing:**
```typescript
// Update job status to failed
if (input.requestId) {
  void failGenerationJob(
    input.requestId,
    error instanceof Error ? error.message : "Unknown error"
  );
}
```

Note: `completeGenerationJob` and `failGenerationJob` are fire-and-forget (`void`) — if RTDB write fails, the main mutation flow is unaffected. The job tracking is best-effort.

#### 2d. Add new `getGenerationStatus` query (after the `generateImage` mutation):

```typescript
getGenerationStatus: publicProcedure
  .input(z.object({ requestId: z.string().min(1) }))
  .query(async ({ input }) => {
    const job = await getGenerationJob(input.requestId);

    if (!job) {
      return { status: "not_found" as const };
    }

    return {
      status: job.status,
      asset: job.status === "completed" ? job.asset : undefined,
      error: job.status === "failed" ? job.error : undefined,
    };
  }),
```

**Return type summary:**
- `{ status: "not_found" }` — No job with this requestId (expired or never created)
- `{ status: "processing" }` — Generation in progress
- `{ status: "completed", asset: {...} }` — Generation completed, asset available
- `{ status: "failed", error: "..." }` — Generation failed with error

---

### File 3: `promotions/src/lib/utils/poll-generation-status.ts` (NEW)

Client-side utility that polls `getGenerationStatus` and calls callbacks when the status resolves. Uses direct `fetch` to the TRPC endpoint (no hook dependency — can be called from catch blocks).

```typescript
interface PollOptions {
  requestId: string;
  onCompleted: (asset: any) => void;
  onFailed: (error: string) => void;
  onTimeout: () => void;
  intervalMs?: number;
  timeoutMs?: number;
}

export function pollGenerationStatus(options: PollOptions): () => void {
  const {
    requestId,
    onCompleted,
    onFailed,
    onTimeout,
    intervalMs = 3_000,
    timeoutMs = 90_000,
  } = options;

  const startTime = Date.now();
  let stopped = false;
  let timeoutId: ReturnType<typeof setTimeout> | null = null;

  const poll = async () => {
    if (stopped) return;

    if (Date.now() - startTime > timeoutMs) {
      onTimeout();
      return;
    }

    try {
      const input = JSON.stringify({ requestId });
      const res = await fetch(
        `/api/trpc/conjure.getGenerationStatus?input=${encodeURIComponent(input)}`
      );
      if (!res.ok) throw new Error(`HTTP ${res.status}`);

      const data = await res.json();
      const result = data?.result?.data;

      if (result?.status === "completed" && result.asset) {
        onCompleted(result.asset);
        return;
      }
      if (result?.status === "failed") {
        onFailed(result.error || "Image generation failed");
        return;
      }
      // status is "processing" or "not_found" — keep polling
    } catch {
      // Network error on the poll itself (tab still backgrounded?) — retry
    }

    if (!stopped) {
      timeoutId = setTimeout(poll, intervalMs);
    }
  };

  // Also poll immediately when the page becomes visible (user returns to tab)
  const onVisibilityChange = () => {
    if (!document.hidden && !stopped) {
      poll();
    }
  };
  document.addEventListener("visibilitychange", onVisibilityChange);

  // Start first poll after a short delay (give the server a moment)
  timeoutId = setTimeout(poll, 1_000);

  // Return cancel function
  return () => {
    stopped = true;
    if (timeoutId) clearTimeout(timeoutId);
    document.removeEventListener("visibilitychange", onVisibilityChange);
  };
}
```

**Key features:**
- **Visibility-aware**: Immediately polls when user returns to the tab (catches the common case where user backgrounds and returns)
- **Timeout**: Gives up after 90s and calls `onTimeout`
- **Cancel function**: Returns a cleanup function for React effect cleanup or manual cancellation
- **Error-tolerant**: If a poll request fails (still backgrounded), silently retries next interval
- **No hook dependency**: Can be called from catch blocks, event handlers, etc.

---

### File 4: `promotions/src/app/app/library/page.tsx` (MODIFY)

#### 4a. Add imports (top of file):
```typescript
import { pollGenerationStatus } from "@/lib/utils/poll-generation-status";
```

#### 4b. Add cleanup ref (near `activeGenerations` state, ~line 2138):
```typescript
// Track cancel functions for recovery polls
const recoveryPollCancels = useRef<Map<string, () => void>>(new Map());
```

#### 4c. Cleanup on unmount (add useEffect):
```typescript
useEffect(() => {
  return () => {
    // Cancel all active recovery polls on unmount
    for (const cancel of recoveryPollCancels.current.values()) {
      cancel();
    }
    recoveryPollCancels.current.clear();
  };
}, []);
```

#### 4d. Modify `handleGenerate` callback (~lines 2857-3011):

**Generate requestId before mutation call (before line 2915):**
```typescript
const requestId = nanoid();
```

**Pass requestId to mutation (line 2915-2927):**
```typescript
const result = await generateImageMutation.mutateAsync({
  prompt: snapshotPrompt || "Generate a variation of the reference image",
  options: {
    orientation: snapshotOrientation,
    model: snapshotModel,
    referenceAssets: snapshotReferenceAssets.length > 0 ? snapshotReferenceAssets : undefined,
  },
  saveToBrandId: currentBrand.id,
  requestId, // NEW
});
```

**Replace the catch block (lines 3002-3010) with recovery polling:**
```typescript
} catch (error: any) {
  console.warn("[Library] Generation mutation error, attempting recovery via server status", {
    generationId,
    requestId,
    error: error?.message,
  });

  // Don't show error immediately — poll the server for the authoritative status.
  // The backend may have completed even though the client connection was lost.
  const cancel = pollGenerationStatus({
    requestId,
    onCompleted: (asset) => {
      recoveryPollCancels.current.delete(generationId);

      // Mirror the success path (lines 2970-3001)
      const generatedAsset: Asset = {
        ...asset,
        type: "generated",
      };
      setUrlToGenerationId((prev) => {
        const next = new Map(prev);
        next.set(generatedAsset.url, generationId);
        return next;
      });
      setActiveGenerations((prev) => prev.filter((g) => g.id !== generationId));
      setUploadedReferences((prev) => [...prev, generatedAsset]);
      setLastGeneratedUrl(generatedAsset.url);

      // Update React Query cache
      queryClient.setQueryData<Asset[]>(
        ["brand-assets", currentBrand.id],
        (previous = []) => [generatedAsset, ...previous.filter((a) => a.url !== generatedAsset.url)]
      );
      void queryClient.invalidateQueries({
        queryKey: ["brand-assets", currentBrand.id],
      });

      toast.success("Image generated!");
    },
    onFailed: (errorMsg) => {
      recoveryPollCancels.current.delete(generationId);
      setActiveGenerations((prev) => prev.filter((g) => g.id !== generationId));
      const displayMessage = errorMsg.includes("could not generate")
        ? "Unable to generate image with that prompt. Try a different description."
        : "Failed to generate image";
      toastError(displayMessage);
    },
    onTimeout: () => {
      recoveryPollCancels.current.delete(generationId);
      setActiveGenerations((prev) => prev.filter((g) => g.id !== generationId));
      toastError("Image generation may have failed. Please try again.");
    },
  });

  recoveryPollCancels.current.set(generationId, cancel);
  // Keep the loading card visible (don't remove from activeGenerations)
  // The poll callbacks above will clean up when resolved.
}
```

**Why this works:**
- On ANY error (network, server, or unknown), we ask the server for the authoritative status
- If the server says "completed": we process the result as if the mutation succeeded
- If the server says "failed": we show the server's error message (not the client's network error)
- If the server doesn't respond within 90s: we give up and show an error
- The loading card stays visible during recovery (no false "Failed" toast)

---

### File 5: `promotions/src/components/image-generation-popover.tsx` (MODIFY)

#### 5a. Add imports (top of file):
```typescript
import { pollGenerationStatus } from "@/lib/utils/poll-generation-status";
import { nanoid } from "nanoid";
```

#### 5b. Add cleanup ref (near `generateImageMutation`, ~line 172):
```typescript
const recoveryPollCancel = useRef<(() => void) | null>(null);

// Cleanup on unmount
useEffect(() => {
  return () => {
    recoveryPollCancel.current?.();
  };
}, []);
```

#### 5c. Generate requestId before mutation (~before line 366):
```typescript
const requestId = nanoid();
```

#### 5d. Pass requestId to mutation (line 366-376):
```typescript
const result = await generateImageMutation.mutateAsync({
  prompt: prompt.trim(),
  options: {
    orientation: orientation,
    model: model,
    referenceAssets: typedReferenceAssets.length > 0 ? typedReferenceAssets : undefined,
    ...(shouldUseEditMode && { imageUrl: validImageSrc }),
  },
  requestId, // NEW
});
```

#### 5e. Replace catch block (lines 472-488) with recovery polling:
```typescript
} catch (error: any) {
  console.warn("[ImageGen] Generation mutation error, attempting recovery", {
    requestId,
    error: error?.message,
  });

  const cancel = pollGenerationStatus({
    requestId,
    onCompleted: (recoveredAsset) => {
      recoveryPollCancel.current = null;

      // Mirror the success path (lines 377-460)
      const newAsset: Asset = {
        ...recoveredAsset,
        type: "generated",
      };

      if (onImageGenerated) {
        onImageGenerated(newAsset.url, newAsset);
      }

      // Save to brand (same as success path lines 407-450)
      const saveBrandId = chatBrandId || brand?.id;
      if (saveBrandId) {
        void saveGeneratedImageToBrand(saveBrandId, newAsset).then((saved) => {
          if (saved) {
            void queryClient.invalidateQueries({
              queryKey: ["brand-assets", saveBrandId],
            });
          }
        });
      }

      toast.success("Image generated!");
    },
    onFailed: (errorMsg) => {
      recoveryPollCancel.current = null;
      const displayMessage = errorMsg.includes("Gemini could not generate")
        ? "Unable to generate image with that prompt. Please try a different description."
        : errorMsg || "Failed to generate image. Please try again.";
      toastError(displayMessage);

      // Send Slack alert for real failures
      const chatId = useAppStore.getState().currentChat?.id;
      const chatLink = chatId ? `https://trykopi.ai/p/${chatId}` : "N/A";
      sendSlackAlertClient(
        `❌ Popover Image generation failed\nPrompt: ${prompt.trim()}\nModel: ${model}\nOrientation: ${orientation}\nChat: ${chatLink}\nError: ${errorMsg}`,
        "critical"
      );
    },
    onTimeout: () => {
      recoveryPollCancel.current = null;
      toast.info("Image generation timed out. Please try again.");
    },
  });

  recoveryPollCancel.current = cancel;
}
```

**Key difference from library page:**
- The popover doesn't pass `saveToBrandId` in the mutation, so the backend doesn't save to brand_assets. But with the new approach, the generated asset is stored in the RTDB job record. The popover can recover the asset URL from the job and then manually save to brand (same as the normal success path).
- Slack alerts only fire for real failures (from `onFailed`), not for recoverable connection drops.

---

## What This Does NOT Do (By Design)

- **Does NOT retry the mutation** — retrying would cause double generation (costly + duplicates)
- **Does NOT add client-side visibility heuristics** — the server is the source of truth
- **Does NOT require SQL migrations** — uses Firebase RTDB (already initialized)
- **Does NOT add new npm packages** — uses existing `nanoid`, standard `fetch()`, Firebase Admin SDK
- **Does NOT change the happy path** — when the connection stays alive, behavior is identical (requestId is simply ignored by the client)

---

## Testing Strategy

### Unit Tests (`promotions/src/__tests__/generation-jobs.test.ts`)

**Server service tests** (mock Firebase RTDB):
- `createGenerationJob` writes correct data to RTDB path
- `completeGenerationJob` updates status and stores asset
- `failGenerationJob` updates status and stores error
- `getGenerationJob` returns job data when exists
- `getGenerationJob` returns null for expired jobs (>10 min old)
- `getGenerationJob` returns null when job doesn't exist

**Polling utility tests** (mock fetch):
- Calls `onCompleted` when server returns `status: "completed"`
- Calls `onFailed` when server returns `status: "failed"`
- Calls `onTimeout` after `timeoutMs` elapsed
- Retries on fetch error (network failure during poll)
- Immediately polls on `visibilitychange` event (tab return)
- Cancel function stops polling and cleans up listeners
- Handles `status: "not_found"` by continuing to poll
- Handles `status: "processing"` by continuing to poll

### Build Validation
```bash
cd promotions && npx tsc --noEmit
```

### Manual Testing (Chrome on iOS)

1. **Library page — connection drop recovery:**
   Generate image → switch tabs → return.
   **Expect**: Loading card stays visible, image appears after a few seconds, "Image generated!" toast.

2. **Library page — real backend failure:**
   Trigger actual error (e.g., bad prompt that fails server-side).
   **Expect**: Error toast with server's error message.

3. **Library page — timeout:**
   Generate image → background for 2+ minutes.
   **Expect**: Loading card clears with "may have failed" toast after 90s.

4. **Popover — connection drop recovery:**
   Generate image → switch tabs → return.
   **Expect**: Image recovered, saved to brand, "Image generated!" toast.

5. **Desktop Chrome (no change):**
   Generate image normally.
   **Expect**: Zero behavior change — mutation succeeds normally, requestId is just extra metadata.

6. **Concurrent generations:**
   Start 2+ generations → background → return.
   **Expect**: Each generation recovers independently via its own requestId.

---

## Risk Assessment

### Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Firebase RTDB write fails during generation | Job tracking is fire-and-forget (`void`). If RTDB write fails, the mutation still completes normally. The client falls back to the 90s timeout. |
| `getGenerationStatus` endpoint returns stale/wrong data | Each job has a unique `requestId` (nanoid). No possibility of cross-contamination between generations. |
| Firebase RTDB fills up with old jobs | Jobs auto-expire on read (10 min TTL). Old entries are lazily cleaned up when accessed. |
| Poll request itself fails (tab still backgrounded) | Polling silently retries on fetch error. `visibilitychange` listener triggers immediate poll when tab becomes active. |
| `requestId` not provided (old client version) | `requestId` is optional in the schema. Backend only creates/updates jobs when `requestId` is present. Zero impact on existing behavior. |
| Server crashes mid-generation | Job stays in "processing" state. Client hits 90s timeout, shows "may have failed" message. Same UX as current behavior but without the false error. |

### Edge Cases

- **User returns quickly (<1s)**: Fetch may not have been killed → original await succeeds → recovery polling never starts
- **User backgrounds for minutes**: Backend completed long ago → first poll returns "completed" → instant recovery
- **Non-iOS browsers**: They don't kill fetches → mutation succeeds/fails normally → recovery polling only starts on actual errors (which will return "failed" from server)
- **Multiple tabs generating simultaneously**: Each has unique requestId → no interference
- **Component unmounts during recovery**: Cancel function runs via cleanup effect → polling stops cleanly

### Dependencies

- **Firebase RTDB** (already initialized via `adminDatabase`)
- **nanoid** (already used in the library page for `generationId`)
- No new npm packages
- No SQL migrations
- Backward compatible (requestId is optional)

---

## Estimated Complexity

**Small-medium**

- 1 new server service (~60 lines)
- 1 new client utility (~60 lines)
- 1 router modification (~25 lines added)
- 2 component modifications (~50 lines each)
- 1 test file (~80 lines)

Total: ~325 lines of new/modified code across 6 files.
