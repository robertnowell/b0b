# SVG Preview Not Rendering in Library — Implementation Plan

## Root Cause

The bug is a **format detection mismatch** in `process-image.ts`, the server-side processing function used by the library upload path.

### How the bug works

When a user uploads an SVG via the library:

1. **Client side** (`handleFileFromPasteOrDrop` in `library/page.tsx`): For SVGs ≤ 500KB, the original SVG file is passed through unchanged to the upload function. (SVGs > 500KB get rasterized to JPEG via Canvas API client-side, which incidentally "works" but destroys vector quality.)

2. **Client upload** (`client-upload.ts`): The SVG is uploaded to Firebase temp storage, then `processUploadedImage()` is called server-side.

3. **Server processing** (`process-image.ts` line 121-123):
   ```js
   const metadata = await getImageMetadata(buffer, mimeType);
   const detectedFormat = metadata.detectedFormat || normalizeMimeType(mimeType);
   ```
   `getImageMetadata` (in `sharp-utils.ts`) calls `sharp(buffer).metadata()`, which returns `format: "svg"`. The code maps this to `detectedFormat = "image/svg"` (by prepending `"image/"`).

4. **The broken check** (`process-image.ts` line 175):
   ```js
   else if (detectedFormat === "image/svg+xml") {  // ← ONLY checks "image/svg+xml"
   ```
   **This condition is FALSE** because `detectedFormat` is `"image/svg"`, not `"image/svg+xml"`. So the SVG → PNG conversion is **never executed**.

5. **Result**: The SVG is uploaded to GCS as-is with MIME type `"image/svg"` (an invalid/non-standard MIME type — the correct one is `image/svg+xml`). The browser's `<img>` tag fails to render the file because the Content-Type header is wrong.

### Why `unified-upload.ts` works but `process-image.ts` doesn't

The `unified-upload.ts` file (line 374) already handles both format strings:
```js
if (detectedFormat === "image/svg+xml" || detectedFormat === "image/svg") {
```

But `process-image.ts` (the code path used by library uploads via `client-upload.ts`) was **never updated** with this fix. Two separate processing pipelines, only one got the SVG detection fix.

### Secondary issue: Client-side SVG rasterization

In `handleFileFromPasteOrDrop`, SVGs > 500KB get compressed via Canvas API (which rasterizes them to JPEG). This is unnecessary since the server handles SVG → PNG conversion via Sharp. SVGs should be passed through to the server unchanged, like animated GIFs/WebPs.

The same issue exists in `client-upload.ts` where SVGs > 2MB would hit the `resizeImageClientSide` path.

---

## Implementation Plan

### Fix 1: Add `"image/svg"` to SVG detection in `process-image.ts` (Critical)

**File**: `promotions/src/lib/features/image-processing/process-image.ts`
**Line**: 175

Change:
```js
else if (detectedFormat === "image/svg+xml") {
```

To:
```js
else if (detectedFormat === "image/svg+xml" || detectedFormat === "image/svg") {
```

This matches the existing fix in `unified-upload.ts` line 374 and ensures SVGs are converted to PNG regardless of how Sharp reports the format.

### Fix 2: Skip client-side compression for SVGs in library upload handler

**File**: `promotions/src/app/app/library/page.tsx`
**Location**: `handleFileFromPasteOrDrop` function (~line 2514-2538)

Currently SVG is not excluded from client-side compression:
```js
const mightBeAnimated = file.type === "image/gif" || file.type === "image/webp";
const needsCompression = file.size > 500 * 1024 && !mightBeAnimated;
```

Change to also skip SVGs (server handles SVG rasterization via Sharp):
```js
const mightBeAnimated = file.type === "image/gif" || file.type === "image/webp";
const isSvg = file.type === "image/svg+xml";
const needsCompression = file.size > 500 * 1024 && !mightBeAnimated && !isSvg;
```

And add an else-if branch for SVG (after the animated image log):
```js
} else if (file.size > 500 * 1024 && isSvg) {
  console.log(
    `[handleFileFromPasteOrDrop] Skipping client compression for SVG (server handles rasterization via Sharp).`
  );
}
```

### Fix 3: Skip client-side resize for SVGs in client-upload.ts

**File**: `promotions/src/lib/features/image-processing/client-upload.ts`
**Location**: `uploadImage` function (~line 199-231)

Currently:
```js
const mightBeAnimated = mimeType === "image/webp" || mimeType === "image/gif" || ext === "webp" || ext === "gif";

if (file.size > MAX_CLIENT_SIZE && !mightBeAnimated) {
```

Change to also skip SVGs:
```js
const mightBeAnimated = mimeType === "image/webp" || mimeType === "image/gif" || ext === "webp" || ext === "gif";
const isSvg = mimeType === "image/svg+xml" || ext === "svg";

if (file.size > MAX_CLIENT_SIZE && !mightBeAnimated && !isSvg) {
```

And update the animated skip log to also cover SVG:
```js
} else if (file.size > MAX_CLIENT_SIZE && isSvg) {
  console.log(
    `[uploadImage] Skipping client resize for SVG. Server will handle rasterization.`
  );
}
```

---

## Files Changed

| File | Change | Priority |
|------|--------|----------|
| `promotions/src/lib/features/image-processing/process-image.ts` | Add `"image/svg"` to SVG format detection (line 175) | **Critical** |
| `promotions/src/app/app/library/page.tsx` | Skip client-side compression for SVGs in `handleFileFromPasteOrDrop` | Medium |
| `promotions/src/lib/features/image-processing/client-upload.ts` | Skip client-side resize for SVGs in `uploadImage` | Medium |

## Testing

1. Upload a small SVG (< 500KB) via the library → should convert to PNG and display correctly
2. Upload a large SVG (> 500KB) via the library → should still pass through to server as SVG, convert to PNG
3. Upload a regular PNG/JPEG → should still work as before (no regression)
4. Verify the stored URL ends in `.png` (not `.svg` or `.svg+xml`)
5. Verify the stored MIME type is `image/png`
6. Check that the preview renders in the library masonry grid

PLAN_VERDICT:READY
