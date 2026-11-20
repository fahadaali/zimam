import { Hono } from "hono";
import { z } from "zod";
import { sha256Hex } from "../auth/crypto";
import { fail, readJson } from "../http";
import type { AppEnv } from "../types";

/** APNs device tokens are 32 bytes today; Apple says not to rely on the length. */
const DeviceToken = z
  .string()
  .regex(/^[0-9a-fA-F]{64,200}$/)
  .transform((s) => s.toLowerCase());

const DeviceBody = z.object({
  platform: z.enum(["ios", "macos", "watchos"]),
  /** "sandbox" for development builds, "production" for TestFlight and the App Store. */
  environment: z.enum(["sandbox", "production"]),
  bundleId: z
    .string()
    .max(155)
    .regex(/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/),
});

/** Device registration for reminder pushes. The app calls it at launch and on sign-out. */
export const devices = new Hono<AppEnv>();

/**
 * APNS_BUNDLE_IDS: the bundle ids a device may register with. The cron sends to each device with
 * its bundle id as the APNs topic, so an id outside the list would only get errors back, or
 * reach an app this key should not send to.
 */
export function allowedBundleIds(value: string | undefined): string[] {
  return (value ?? "").split(",").map((s) => s.trim()).filter(Boolean);
}

/**
 * PUT /v1/devices/:token { platform, environment, bundleId } — registers this install's
 * APNs token for the signed-in user and session; `bundleId` must be in APNS_BUNDLE_IDS (400
 * otherwise). A token already registered elsewhere moves here (the install signed in to
 * another account). An older token of the same session and platform is dropped, since APNs
 * gave this install a new one.
 */
devices.put("/:token", async (c) => {
  const token = DeviceToken.safeParse(c.req.param("token"));
  if (!token.success) return fail(c, 400, "invalid", "Device token must be hex");
  const body = DeviceBody.safeParse(await readJson(c));
  if (!body.success) return fail(c, 400, "invalid", "platform, environment and bundleId are required");
  const { platform, environment, bundleId } = body.data;
  if (!allowedBundleIds(c.env.APNS_BUNDLE_IDS).includes(bundleId)) return fail(c, 400, "invalid", "bundleId is not one of the app's");
  const db = c.env.DB;
  const sessionHash = await sha256Hex(c.var.token);
  const now = Date.now();
  await db.batch([
    db
      .prepare(`DELETE FROM devices WHERE session_hash = ?1 AND platform = ?2 AND token <> ?3`)
      .bind(sessionHash, platform, token.data),
    // Seen only counts pulls (the app reschedules after each), so a new or moved
    // registration starts unseen; the same session keeps its last pull. How far its local
    // notifications reach (PATCH) is the whole window until it says otherwise, and moves with it.
    db
      .prepare(
        `INSERT INTO devices (token, user_id, session_hash, platform, environment, bundle_id, created_at, updated_at, last_seen_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, 0)
         ON CONFLICT (token) DO UPDATE SET
           last_seen_at = CASE WHEN devices.session_hash = excluded.session_hash THEN devices.last_seen_at ELSE 0 END,
           scheduled_through = CASE WHEN devices.session_hash = excluded.session_hash THEN devices.scheduled_through END,
           user_id = excluded.user_id, session_hash = excluded.session_hash, platform = excluded.platform,
           environment = excluded.environment, bundle_id = excluded.bundle_id, updated_at = excluded.updated_at`,
      )
      .bind(token.data, c.var.userId, sessionHash, platform, environment, bundleId, now),
  ]);
  return c.body(null, 204);
});

const ScheduledBody = z.object({
  /** Unix ms; null for the whole window. */
  scheduledThrough: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).nullable(),
});

/**
 * PATCH /v1/devices/:token { scheduledThrough } — how far this install's local notifications
 * reach, sent after it schedules following a pull: as of its last pull, it has every task
 * reminder it knows firing at or before `scheduledThrough` (Unix ms) scheduled locally, and
 * may have dropped later ones for the 64-notification limit; null when nothing was dropped.
 * The cron pushes the reminders past it (src/push/reminders.ts). Only the registering session
 * can set it; another gets 404 like an unknown token.
 */
devices.patch("/:token", async (c) => {
  const token = DeviceToken.safeParse(c.req.param("token"));
  if (!token.success) return fail(c, 400, "invalid", "Device token must be hex");
  const body = ScheduledBody.safeParse(await readJson(c));
  if (!body.success) return fail(c, 400, "invalid", "scheduledThrough must be Unix ms or null");
  const result = await c.env.DB.prepare(`UPDATE devices SET scheduled_through = ?3, updated_at = ?4 WHERE token = ?1 AND session_hash = ?2`)
    .bind(token.data, await sha256Hex(c.var.token), body.data.scheduledThrough, Date.now())
    .run();
  if (!result.meta.changes) return fail(c, 404, "not_found", "device not found");
  return c.body(null, 204);
});

/** DELETE /v1/devices/:token — stops pushes to this install (sign-out). Only the token's owner can. */
devices.delete("/:token", async (c) => {
  const token = DeviceToken.safeParse(c.req.param("token"));
  if (!token.success) return fail(c, 400, "invalid", "Device token must be hex");
  const result = await c.env.DB.prepare(`DELETE FROM devices WHERE token = ? AND user_id = ?`)
    .bind(token.data, c.var.userId)
    .run();
  if (!result.meta.changes) return fail(c, 404, "not_found", "device not found");
  return c.body(null, 204);
});

/**
 * Marks the session's devices as having pulled the data as of `now`. Called before a
 * pull reads anything, so every change before `now` is in what the device receives.
 */
export async function markDevicesSeen(db: D1Database, sessionToken: string, now = Date.now()) {
  await db
    .prepare(`UPDATE devices SET last_seen_at = ?2 WHERE session_hash = ?1 AND last_seen_at < ?2`)
    .bind(await sha256Hex(sessionToken), now)
    .run();
}
