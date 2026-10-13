import { Hono } from "hono";
import { z } from "zod";
import { escapeLike, foldForSearch } from "../data/arabic";
import { type Row, taskOut } from "../data/rows";
import { Id } from "../data/schemas";
import { fail } from "../http";
import type { AppEnv } from "../types";
import { createResource, deleteResource, loadVisible, updateResource } from "./resources";

export const tasks = new Hono<AppEnv>();

const ListQuery = z.object({
  /** A project id, or "inbox" for tasks outside any project. */
  projectId: z.union([z.literal("inbox"), Id]).optional(),
  /** "open" means todo or doing. */
  status: z.enum(["todo", "doing", "done", "open"]).optional(),
  dueFrom: z.iso.date().optional(),
  dueTo: z.iso.date().optional(),
  q: z.string().trim().min(1).max(200).optional(),
  assignee: z.literal("me").optional(),
  limit: z.coerce.number().int().min(1).max(500).default(100),
  offset: z.coerce.number().int().min(0).default(0),
});

/** GET /v1/tasks — tasks the user can see, filtered; dated tasks first, by date. */
tasks.get("/", async (c) => {
  const parsed = ListQuery.safeParse(c.req.query());
  if (!parsed.success) return fail(c, 400, "invalid", parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; "));
  const q = parsed.data;
  const where = [
    "t.deleted_at IS NULL",
    `((t.project_id IS NULL AND t.owner_id = ?1) OR t.project_id IN (
       SELECT m.project_id FROM project_members m JOIN projects p ON p.id = m.project_id
       WHERE m.user_id = ?1 AND p.deleted_at IS NULL))`,
  ];
  const params: unknown[] = [c.var.userId];
  const bind = (value: unknown) => {
    params.push(value);
    return `?${params.length}`;
  };
  if (q.projectId === "inbox") where.push("t.project_id IS NULL");
  else if (q.projectId) where.push(`t.project_id = ${bind(q.projectId)}`);
  if (q.status === "open") where.push("t.status != 'done'");
  else if (q.status) where.push(`t.status = ${bind(q.status)}`);
  if (q.dueFrom) where.push(`t.due_date >= ${bind(q.dueFrom)}`);
  if (q.dueTo) where.push(`t.due_date <= ${bind(q.dueTo)}`);
  if (q.assignee === "me") where.push("t.assignee_id = ?1");
  if (q.q) where.push(`t.search_text LIKE ${bind(`%${escapeLike(foldForSearch(q.q))}%`)} ESCAPE '\\'`);

  const { results } = await c.env.DB.prepare(
    `SELECT t.* FROM tasks t WHERE ${where.join(" AND ")}
     ORDER BY t.due_date IS NULL, t.due_date, t.due_time IS NULL, t.due_time, t.sort_order, t.created_at
     LIMIT ${bind(q.limit)} OFFSET ${bind(q.offset)}`,
  )
    .bind(...params)
    .all<Row>();
  return c.json({ tasks: results.map(taskOut) });
});

tasks.post("/", (c) => createResource(c, "task"));

tasks.get("/:id", async (c) => {
  const row = await loadVisible(c, "task", c.req.param("id"));
  return row ? c.json(taskOut(row)) : fail(c, 404, "not_found", "task not found");
});

tasks.patch("/:id", (c) => updateResource(c, "task", c.req.param("id")));
tasks.post("/:id/complete", (c) => updateResource(c, "task", c.req.param("id"), { status: "done" }));
tasks.delete("/:id", (c) => deleteResource(c, "task", c.req.param("id")));
