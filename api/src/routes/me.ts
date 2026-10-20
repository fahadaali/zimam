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
  // Their attachments' files leave R2 now; anything left over goes with the next cron run.
  await purgeAttachments(c.env.DB, c.env.ATTACHMENTS);
  await revokeAppleAuthorization(() => c.var.deps.appleTokens(c.env), user);
  closeSockets(c, c.var.userId);
  return c.body(null, 204);
});
