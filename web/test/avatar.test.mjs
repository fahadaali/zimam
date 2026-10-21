import assert from "node:assert/strict";
import { test } from "node:test";
import { AVATAR_SIDE, JPEG_QUALITIES, MAX_AVATAR_BYTES, encodeWithin, squareCrop } from "../public/app/lib/avatar.js";

test("the photo is the middle square, at most 512 px", () => {
  assert.deepEqual(squareCrop(4000, 3000), { sx: 500, sy: 0, edge: 3000, side: AVATAR_SIDE });
  assert.deepEqual(squareCrop(1080, 1920), { sx: 0, sy: 420, edge: 1080, side: 512 });
  assert.deepEqual(squareCrop(600, 600), { sx: 0, sy: 0, edge: 600, side: 512 });
});

test("a small photo is not enlarged", () => {
  assert.deepEqual(squareCrop(300, 200), { sx: 50, sy: 0, edge: 200, side: 200 });
  assert.equal(squareCrop(0, 0).side, 0);
});

test("the quality drops until the JPEG fits under 1 MB", async () => {
  assert.equal(MAX_AVATAR_BYTES, 1024 * 1024);
  assert.equal(JPEG_QUALITIES[0], 0.85);
  const tried = [];
  const sizes = { 0.85: 2_000_000, 0.75: 1_100_000, 0.65: 900_000 };
  const blob = await encodeWithin(async (quality) => {
    tried.push(quality);
    return { size: sizes[quality] ?? 100 };
  });
  assert.deepEqual(tried, [0.85, 0.75, 0.65]);
  assert.equal(blob.size, 900_000);
});

test("the first quality is kept when it already fits, and nothing when none does", async () => {
  const tried = [];
  await encodeWithin(async (quality) => {
    tried.push(quality);
    return { size: 50_000 };
  });
  assert.deepEqual(tried, [0.85]);
  assert.equal(await encodeWithin(async () => ({ size: MAX_AVATAR_BYTES + 1 })), null);
  assert.equal(await encodeWithin(async () => null), null);
});
