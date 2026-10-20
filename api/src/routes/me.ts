import { Hono } from "hono";
import { z } from "zod";
import { purgeAttachments } from "../attachments";
import { revokeAppleAuthorization } from "../auth/account";
import { deleteAccount } from "../data/account";
import { type Row, userOut } from "../data/rows";
import { Settings } from "../data/schemas";
import { fail, readJson } from "../http";
import { closeSockets } from "../realtime/notify";
import type { AppEnv } from "../types";

export const me = new Hono<AppEnv>();

const loadUser = (db: D1Database, id: string) => db.prepare(`SELECT * FROM users WHERE id = ?`).bind(id).first<Row>();

/** The account's photo in the ATTACHMENTS bucket; one per user, replaced in place. */
export const avatarKey = (userId: string) => `avatars/${userId}`;
/** The apps send a square JPEG of 512 px, well under this. */
export const MAX_AVATAR_BYTES = 1024 * 1024;

/** JPEG or PNG, told by the file's first bytes rather than the header the client sent. */
function imageType(bytes: Uint8Array): string | null {
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return "image/jpeg";
  const png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (png.every((byte, i) => bytes[i] === byte)) return "image/png";
  return null;
}

me.get("/", async (c) => {
  const user = await loadUser(c.env.DB, c.var.userId);
  return user ? c.json(userOut(user)) : fail(c, 404, "not_found", "User not found");
});

const MePatch = z
  .object({
    name: z.string().trim().max(200).optional(),
    settings: Settings.partial().strict().optional(),
  })
  .strict();

/** PATCH /v1/me { name?, settings?: { calendar?, prayerMethod?, asrMadhab?, prayerAlerts?, weekStart?, … } } */
me.patch("/", async (c) => {
  const body = MePatch.safeParse(await readJson(c));
  if (!body.success) return fail(c, 400, "invalid", "Invalid name or settings");
  const user = await loadUser(c.env.DB, c.var.userId);
  if (!user) return fail(c, 404, "not_found", "User not found");
  const settings = { ...userOut(user).settings, ...body.data.settings };
  const name = body.data.name === undefined ? user.name : body.data.name || null;
  await c.env.DB.prepare(`UPDATE users SET name = ?2, settings = ?3, updated_at = ?4 WHERE id = ?1`)
    .bind(c.var.userId, name, JSON.stringify(settings), Date.now())
    .run();
  return c.json(userOut((await loadUser(c.env.DB, c.var.userId))!));
});

/** PUT /v1/me/avatar — the photo as the body (image/jpeg or image/png, up to 1 MB). */
me.put("/avatar", async (c) => {
  const declared = Number(c.req.header("Content-Length") ?? "0");
  if (declared > MAX_AVATAR_BYTES) return fail(c, 413, "too_large", "The photo is larger than 1 MB");
  const bytes = new Uint8Array(await c.req.arrayBuffer());
  if (bytes.byteLength > MAX_AVATAR_BYTES) return fail(c, 413, "too_large", "The photo is larger than 1 MB");
  if (bytes.byteLength === 0) return fail(c, 400, "empty_file", "The photo is empty");
  const contentType = imageType(bytes);
  if (!contentType) return fail(c, 400, "invalid_file_type", "JPEG or PNG only");
  const userId = c.var.userId;
  await c.env.ATTACHMENTS.put(avatarKey(userId), bytes, {
    httpMetadata: { contentType },
    customMetadata: { userId },
  });
  const now = Date.now();
  await c.env.DB.prepare(`UPDATE users SET avatar_updated_at = ?2, updated_at = ?2 WHERE id = ?1`).bind(userId, now).run();
  const user = await loadUser(c.env.DB, userId);
  return user ? c.json(userOut(user)) : fail(c, 404, "not_found", "User not found");
});

/** GET /v1/me/avatar — the photo, for the account's own apps. */
me.get("/avatar", async (c) => {
  const object = await c.env.ATTACHMENTS.get(avatarKey(c.var.userId));
  if (!object) return fail(c, 404, "not_found", "No photo");
  return new Response(object.body, {
    headers: {
      "Content-Type": object.httpMetadata?.contentType ?? "image/jpeg",
      // The apps ask again only when `avatarVersion` changes.
      "Cache-Control": "private, max-age=86400",
    },
  });
});

/** DELETE /v1/me/avatar — removes the photo; the apps show the name's first letter. */
me.delete("/avatar", async (c) => {
  const userId = c.var.userId;
  await c.env.ATTACHMENTS.delete(avatarKey(userId));
  await c.env.DB.prepare(`UPDATE users SET avatar_updated_at = NULL, updated_at = ?2 WHERE id = ?1`).bind(userId, Date.now()).run();
  const user = await loadUser(c.env.DB, userId);
  return user ? c.json(userOut(user)) : fail(c, 404, "not_found", "User not found");
});

/**
 * DELETE /v1/me — deletes the account as App Store rules require (see
 * `deleteAccount`): shared projects the user owns pass to the earliest-joined
 * member, everything else of theirs goes, every session ends, and their Sign
 * in with Apple authorization is revoked with Apple.
 */
me.delete("/", async (c) => {
  const user = await loadUser(c.env.DB, c.var.userId);
  if (!user) return fail(c, 404, "not_found", "User not found");
  await deleteAccount(c.env.DB, c.var.access, c.var.mutator, c.var.userId);
  // Their attachments' files and photo leave R2 now; anything left over goes with the next cron run.
  await purgeAttachments(c.env.DB, c.env.ATTACHMENTS);
  await c.env.ATTACHMENTS.delete(avatarKey(c.var.userId));
  await revokeAppleAuthorization(() => c.var.deps.appleTokens(c.env), user);
  closeSockets(c, c.var.userId);
  return c.body(null, 204);
});
