import { Hono } from "hono";
import { listTasks, TaskQuery } from "../data/queries";
import { reminderOut, taskOut, type Row } from "../data/rows";
import { fail } from "../http";
import type { AppEnv } from "../types";
import { createResource, deleteResource, loadVisible, updateResource } from "./resources";

export const tasks = new Hono<AppEnv>();

/** GET /v1/tasks — tasks the user can see, filtered; dated tasks first, by date. */
tasks.get("/", async (c) => {
  const parsed = TaskQuery.safeParse(c.req.query());
  if (!parsed.success) return fail(c, 400, "invalid", parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; "));
  const rows = await listTasks(c.env.DB, c.var.userId, parsed.data);
  return c.json({ tasks: rows.map(taskOut) });
});

tasks.post("/", (c) => createResource(c, "task"));

tasks.get("/:id", async (c) => {
  const row = await loadVisible(c, "task", c.req.param("id"));
  return row ? c.json(taskOut(row)) : fail(c, 404, "not_found", "task not found");
});

/**
 * GET /v1/tasks/:id/reminders — the signed-in user's reminders on a task they can see, oldest
 * first. Reminders are personal: another member's on a shared task stay theirs. The web app reads
 * them here and writes them through POST /v1/sync, as the apps do.
 */
tasks.get("/:id/reminders", async (c) => {
  const task = await loadVisible(c, "task", c.req.param("id"));
  if (!task) return fail(c, 404, "not_found", "task not found");
  const { results } = await c.env.DB.prepare(
    `SELECT * FROM reminders WHERE task_id = ?1 AND user_id = ?2 AND deleted_at IS NULL ORDER BY created_at, id`,
  )
    .bind(task.id, c.var.userId)
    .all<Row>();
  return c.json({ reminders: results.map(reminderOut) });
});

tasks.patch("/:id", (c) => updateResource(c, "task", c.req.param("id")));
tasks.post("/:id/complete", (c) => updateResource(c, "task", c.req.param("id"), { status: "done" }));
tasks.delete("/:id", (c) => deleteResource(c, "task", c.req.param("id")));
