// The account photo, as AvatarImage in the Apple app (AvatarStore.swift): the middle square of the
// chosen image, at most 512 px, as JPEG under the API's 1 MB limit (PUT /v1/me/avatar).
// Pure functions, no DOM; tested in test/avatar.test.mjs. The drawing is in ../avatar.js.

/** The longest side of the uploaded square, in pixels. */
export const AVATAR_SIDE = 512;
/** The API's limit (api/src/routes/me.ts MAX_AVATAR_BYTES). */
export const MAX_AVATAR_BYTES = 1024 * 1024;
/** JPEG qualities tried in turn until the photo fits under the limit. */
export const JPEG_QUALITIES = [0.85, 0.75, 0.65, 0.5, 0.35];

/**
 * The middle square of a `width`×`height` image and the side it is drawn at: { sx, sy, edge, side }.
 * A smaller image is not enlarged.
 */
export function squareCrop(width, height, maxSide = AVATAR_SIDE) {
  const w = Math.max(0, Math.floor(width));
  const h = Math.max(0, Math.floor(height));
  const edge = Math.min(w, h);
  return { sx: Math.floor((w - edge) / 2), sy: Math.floor((h - edge) / 2), edge, side: Math.min(maxSide, edge) };
}

/**
 * Encodes at each quality in turn, `encode(quality)` → Promise<Blob | null>, and answers the first
 * result that fits under `maxBytes`, or null when none does.
 */
export async function encodeWithin(encode, { qualities = JPEG_QUALITIES, maxBytes = MAX_AVATAR_BYTES } = {}) {
  for (const quality of qualities) {
    const blob = await encode(quality);
    if (blob && blob.size > 0 && blob.size <= maxBytes) return blob;
  }
  return null;
}
