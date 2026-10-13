import { Hono } from "hono";
import { z } from "zod";
import { type Row, userOut } from "../data/rows";
import { Settings } from "../data/schemas";
import { fail, readJson } from "../http";
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

/** PATCH /v1/me { name?, settings?: { calendar?, prayerMethod?, weekStart? } } */
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
 * DELETE /v1/me — deletes the account as App Store rules require: owned
 * projects, inbox tasks, reminders and comments go; tasks the user created in
 * other people's projects stay with those projects; the user row is anonymised.
 */
me.delete("/", async (c) => {
  const db = c.env.DB;
  const userId = c.var.userId;
  const now = Date.now();

  const owned = await db
    .prepare(`SELECT project_id FROM project_members WHERE user_id = ? AND role = 'owner'`)
    .bind(userId)
    .all<{ project_id: string }>();
  for (const { project_id } of owned.results) {
    await c.var.mutator.apply({ op: "delete", entity: "project", id: project_id, updatedAt: now });
  }

  await db.batch([
    db
      .prepare(
        `INSERT INTO changes (entity, entity_id, project_id, user_id, at)
         SELECT 'task', id, NULL, owner_id, ?2 FROM tasks WHERE project_id IS NULL AND owner_id = ?1 AND deleted_at IS NULL`,
      )
      .bind(userId, now),
    db
      .prepare(`UPDATE tasks SET deleted_at = ?2, updated_at = ?2 WHERE project_id IS NULL AND owner_id = ?1 AND deleted_at IS NULL`)
      .bind(userId, now),
    db
      .prepare(
        `INSERT INTO changes (entity, entity_id, project_id, user_id, at)
         SELECT 'reminder', id, NULL, user_id, ?2 FROM reminders WHERE user_id = ?1 AND deleted_at IS NULL`,
      )
      .bind(userId, now),
    db.prepare(`UPDATE reminders SET deleted_at = ?2, updated_at = ?2 WHERE user_id = ?1 AND deleted_at IS NULL`).bind(userId, now),
    db
      .prepare(
        `INSERT INTO changes (entity, entity_id, project_id, user_id, at)
         SELECT 'comment', c.id, t.project_id, CASE WHEN t.project_id IS NULL THEN t.owner_id END, ?2
         FROM comments c JOIN tasks t ON t.id = c.task_id WHERE c.author_id = ?1 AND c.deleted_at IS NULL`,
      )
      .bind(userId, now),
    db
      .prepare(`UPDATE comments SET body = '', deleted_at = ?2, updated_at = ?2 WHERE author_id = ?1 AND deleted_at IS NULL`)
      .bind(userId, now),
    db
      .prepare(
        `INSERT INTO changes (entity, entity_id, project_id, user_id, at)
         SELECT 'task', id, project_id, NULL, ?2 FROM tasks WHERE assignee_id = ?1 AND deleted_at IS NULL`,
      )
      .bind(userId, now),
    db.prepare(`UPDATE tasks SET assignee_id = NULL, updated_at = ?2 WHERE assignee_id = ?1 AND deleted_at IS NULL`).bind(userId, now),
    db.prepare(`DELETE FROM project_members WHERE user_id = ?`).bind(userId),
    db.prepare(`DELETE FROM external_refs WHERE user_id = ?`).bind(userId),
    db.prepare(`DELETE FROM sessions WHERE user_id = ?`).bind(userId),
    db
      .prepare(
        `UPDATE users SET apple_sub = 'deleted:' || id, email = NULL, name = NULL, settings = '{}', updated_at = ?2 WHERE id = ?1`,
      )
      .bind(userId, now),
  ]);
  return c.body(null, 204);
});
