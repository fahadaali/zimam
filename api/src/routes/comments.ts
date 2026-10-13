import { Hono } from "hono";
import { commentOut, type Row } from "../data/rows";
import { fail, failMutation, readJson } from "../http";
import type { AppEnv } from "../types";
import { loadVisible } from "./resources";

/** Task comments, mounted under /v1. Anyone who can see the task can comment. */
export const comments = new Hono<AppEnv>();

const SELECT_WITH_AUTHOR = `SELECT c.*, u.name AS author_name FROM comments c JOIN users u ON u.id = c.author_id`;

const withAuthor = (r: Row) => ({ ...commentOut(r), authorName: (r.author_name ?? null) as string | null });

/** GET /tasks/:id/comments — oldest first. */
comments.get("/tasks/:id/comments", async (c) => {
  const task = await loadVisible(c, "task", c.req.param("id"));
  if (!task) return fail(c, 404, "not_found", "task not found");
  const { results } = await c.env.DB.prepare(
    `${SELECT_WITH_AUTHOR} WHERE c.task_id = ? AND c.deleted_at IS NULL ORDER BY c.created_at, c.id`,
  )
    .bind(task.id)
    .all<Row>();
  return c.json({ comments: results.map(withAuthor) });
});

/** POST /tasks/:id/comments { body } */
comments.post("/tasks/:id/comments", async (c) => {
  const task = await loadVisible(c, "task", c.req.param("id"));
  if (!task) return fail(c, 404, "not_found", "task not found");
  const input = await readJson(c);
  const body = typeof input === "object" && input !== null ? (input as Record<string, unknown>).body : undefined;
  const id = crypto.randomUUID();
  const result = await c.var.mutator.apply({
    op: "upsert",
    entity: "comment",
    data: { id, taskId: task.id, body, updatedAt: Date.now() },
  });
  if (result.status !== "applied") return failMutation(c, result);
  const row = await c.env.DB.prepare(`${SELECT_WITH_AUTHOR} WHERE c.id = ?`).bind(id).first<Row>();
  return c.json(withAuthor(row!), 201);
});

/** DELETE /comments/:id — the author only. */
comments.delete("/comments/:id", async (c) => {
  const row = await c.env.DB.prepare(`SELECT * FROM comments WHERE id = ?`).bind(c.req.param("id").toLowerCase()).first<Row>();
  const visible = row && row.deleted_at == null && (await loadVisible(c, "task", row.task_id as string));
  if (!row || !visible) return fail(c, 404, "not_found", "comment not found");
  const updatedAt = Math.max(Date.now(), (row.updated_at as number) + 1);
  const result = await c.var.mutator.apply({ op: "delete", entity: "comment", id: row.id, updatedAt });
  return result.status === "applied" ? c.body(null, 204) : failMutation(c, result);
});
