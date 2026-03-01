# Plan: Add Slack Alert on Library Inspiration Image Upload

## Problem

When an inspiration image is uploaded via the library page, no Slack notification is sent. All existing Slack alerts in the upload pipeline are **error-only** (GIF compression failure, SVG conversion failure, HEIC/AVIF conversion failure, AI metadata failure). There is no success notification for any inspiration image upload path.

## Root Cause

The library upload flow calls:
1. `uploadImage()` (client-upload.ts) → processes the image
2. `addAssets()` → `appendBrandAssets()` (brand-assets.ts) → persists to DB

Neither `appendBrandAssets()` nor the `/api/brand-assets` POST route sends a Slack alert on successful upload. The only Slack alerts are for processing errors deep in the image pipeline.

The figma-email upload flow (`/api/figma-email/upload/route.ts`) also uploads inspiration images but only sends a Slack alert on **failure** (line 717), not success.

## Upload Flow Trace

```
Library page: handleFileFromPasteOrDrop() (library/page.tsx:2541)
  → uploadImage() (client-upload.ts) — client-side resize + Firebase upload + server processing
  → addAssets([newAsset]) where type="inspiration" (library/page.tsx:2561)
    → useBrandAssets hook (useBrandAssets.ts:142)
      → POST /api/brand-assets (brand-assets/route.ts:25)
        → appendBrandAssets(brandId, assets) (brand-assets.ts:55)
          → upsertBrandAsset() per asset
          → ensureAssetEmbedding() per asset
          → NO Slack alert ❌
```

## Implementation

### Option A: Add alert in `appendBrandAssets()` (server action) — Recommended

**File:** `promotions/src/server/actions/brand-assets.ts`

**Change:** After the successful insert loop (around line 144, before the `getBrandAssetsFromTable` call), add a Slack alert for inspiration-type assets.

```typescript
// After insertResults are tallied, before fetching allAssets
const inspirationAssets = normalizedAdditions.filter(a => a.type === "inspiration");
if (inspirationAssets.length > 0 && insertResults.success > 0) {
  const brand = await getBrandById(brandId);
  const message = [
    `📸 Inspiration Image Uploaded`,
    `Brand: *${brand?.brandName || brandId}*`,
    `Images: ${inspirationAssets.length}`,
    ...inspirationAssets.map(a => `• ${a.fileName || a.altText || a.url.substring(0, 80)}`),
  ].join("\n");

  sendSlackAlert({}, message, "brands").catch((err) =>
    console.error("[appendBrandAssets] Slack alert failed:", err)
  );
}
```

**Why this location:**
- Server-side — works for ALL upload paths (library page, figma-email, any future paths)
- `sendSlackAlert` is already imported in this file (line 29)
- `getBrandById` is already imported (line 10) for brand name context
- Fire-and-forget (non-blocking) with `.catch()` — same pattern used elsewhere
- Uses `"brands"` channel (same as the "Brand Created from Inspiration" alert in brands.ts:2212)
- Only triggers for `type: "inspiration"` assets, not regular brand assets

**Why NOT other locations:**
- Library page (client-side): Would only cover library uploads, not figma-email or future paths
- `/api/brand-assets` route: Thin passthrough, wrong layer for business logic
- `processUploadedImage()`: Doesn't know the asset type (inspiration vs brand)

### Steps

1. **Edit `promotions/src/server/actions/brand-assets.ts`**
   - Add Slack alert logic after the insert loop in `appendBrandAssets()` (after line 144, before line 153)
   - Filter for inspiration-type assets only
   - Include brand name and image details in the message
   - Fire-and-forget with `.catch()` to avoid blocking the upload response

That's it — single file change, ~10 lines of code.

### Slack Alert Details

- **Channel:** `"brands"` (C0A954MRN3G) — consistent with other inspiration-related alerts
- **Format:** Matches existing alert patterns (emoji prefix, brand name in bold, details)
- **Blocking:** No — fire-and-forget with `.catch()`
- **Scope:** Only inspiration uploads, not regular brand asset uploads

### Testing

- Upload an inspiration image via the library page → verify Slack alert in `#alerts-brands`
- Upload a regular brand asset → verify NO extra Slack alert
- Upload via figma-email with reference image → verify Slack alert fires
- Verify upload response time is not affected (fire-and-forget)

PLAN_VERDICT:READY
