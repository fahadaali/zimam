import { type Context, Hono } from "hono";
import { z } from "zod";
import { purgeAttachments } from "../attachments";
import { revokeAppleAuthorization, storeAppleRefreshToken } from "../auth/account";
import { verifyAppleToken } from "../auth/apple";
import { appleRedirectUris } from "../auth/apple-tokens";
import { googleAudiences, verifyGoogleToken } from "../auth/google";
import { appleAudiences } from "../auth/users";
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

/** How recently the re-authentication token must have been issued. */
export const REAUTH_MAX_AGE = "10m";

/** A fresh sign-in, as POST /v1/auth/apple and /v1/auth/google take it, minus name and device. */
const Reauth = z.discriminatedUnion("provider", [
  z.object({
    provider: z.literal("apple"),
    identityToken: z.string().min(1),
    nonce: z.string().min(1).max(200),
    authorizationCode: z.string().min(1).max(1000).optional(),
    redirectUri: z.string().url().max(500).optional(),
  }),
  z.object({
    provider: z.literal("google"),
    idToken: z.string().min(1),
    nonce: z.string().min(1).max(200),
  }),
]);

/**
 * Checks a re-authentication: the token verified exactly as sign-in verifies it (signature,
 * issuer, audience, expiry, nonce), issued within `REAUTH_MAX_AGE`, for a sign-in linked to
 * the calling user. Returns the refusal, or null when it holds. Never 401: the apps take 401 as
 * the session ending and sign out, while this only asks the person to sign in again.
 */
async function reauthenticate(c: Context<AppEnv>): Promise<Response | null> {
  const body = Reauth.safeParse(await readJson(c));
  const required = () => fail(c, 403, "reauth_required", "Sign in again to delete the account");
  if (!body.success) return required();
  const data = body.data;
  const db = c.env.DB;
  if (data.provider === "apple") {
    const audiences = appleAudiences(c.env.APPLE_AUDIENCES);
    const identity = await verifyAppleToken(data.identityToken, c.var.deps.appleKeys, audiences, data.nonce, REAUTH_MAX_AGE).catch(
      () => null,
    );
    if (!identity) return required();
    if (!(await isLinked(db, "apple", identity.sub, c.var.userId))) return mismatch(c);
    if (data.authorizationCode) {
      // As at sign-in: keeps a fresh Apple refresh token, so the deletion can revoke it.
      const code = { authorizationCode: data.authorizationCode, redirectUri: data.redirectUri };
      await storeAppleRefreshToken(db, c.var.deps.appleTokens(c.env), c.var.userId, identity, code, appleRedirectUris(c.env));
    }
  } else {
    const audiences = googleAudiences(c.env.GOOGLE_CLIENT_IDS);
    const identity = await verifyGoogleToken(data.idToken, c.var.deps.googleKeys, audiences, data.nonce, REAUTH_MAX_AGE).catch(
      () => null,
    );
    if (!identity) return required();
    if (!(await isLinked(db, "google", identity.sub, c.var.userId))) return mismatch(c);
  }
  return null;
}

/** A valid sign-in, but not one of this account's: another account's, or no account's. */
const mismatch = (c: Context<AppEnv>) => fail(c, 403, "reauth_mismatch", "That sign-in belongs to another account");

async function isLinked(db: D1Database, provider: "apple" | "google", sub: string, userId: string): Promise<boolean> {
  const row = await db
    .prepare(`SELECT user_id FROM identities WHERE provider = ? AND subject = ?`)
    .bind(provider, sub)
    .first<{ user_id: string }>();
  return row?.user_id === userId;
}

/**
 * DELETE /v1/me — deletes the account as App Store rules require (see
 * `deleteAccount`): shared projects the user owns pass to the earliest-joined
 * member, everything else of theirs goes, every session ends, and their Sign
 * in with Apple authorization is revoked with Apple.
 *
 * The body is a fresh sign-in with one of the account's own Apple or Google accounts
 * (`reauthenticate`), so a session left open on a borrowed or stolen device cannot delete it.
 */
me.delete("/", async (c) => {
  if (!(await loadUser(c.env.DB, c.var.userId))) return fail(c, 404, "not_found", "User not found");
  const refused = await reauthenticate(c);
  if (refused) return refused;
  // Read after re-authentication, which may have stored a new Apple refresh token to revoke.
  const user = (await loadUser(c.env.DB, c.var.userId))!;
  await deleteAccount(c.env.DB, c.var.access, c.var.mutator, c.var.userId);
  // Their attachments' files and photo leave R2 now; anything left over goes with the next cron run.
  await purgeAttachments(c.env.DB, c.env.ATTACHMENTS);
  await c.env.ATTACHMENTS.delete(avatarKey(c.var.userId));
  await revokeAppleAuthorization(() => c.var.deps.appleTokens(c.env), user);
  closeSockets(c, c.var.userId);
  return c.body(null, 204);
});
