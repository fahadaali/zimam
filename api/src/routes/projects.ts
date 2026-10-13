import { Hono } from "hono";
import { projectOut, type Row, sectionOut } from "../data/rows";
import type { AppEnv } from "../types";
import { createResource, deleteResource, loadVisible, updateResource } from "./resources";
import { fail } from "../http";

export const projects = new Hono<AppEnv>();

/** Projects and folders the user belongs to, with top-level task counts for the project card. */
projects.get("/", async (c) => {
  const { results } = await c.env.DB.prepare(
    `SELECT p.*, m.role,
       (SELECT COUNT(*) FROM tasks t WHERE t.project_id = p.id AND t.parent_id IS NULL AND t.deleted_at IS NULL) AS total,
       (SELECT COUNT(*) FROM tasks t WHERE t.project_id = p.id AND t.parent_id IS NULL AND t.deleted_at IS NULL
          AND t.status = 'done') AS done
     FROM projects p JOIN project_members m ON m.project_id = p.id AND m.user_id = ?
     WHERE p.deleted_at IS NULL ORDER BY p.sort_order, p.created_at`,
  )
    .bind(c.var.userId)
    .all<Row>();
  return c.json({
    projects: results.map((r) => ({ ...projectOut(r), role: r.role, taskCount: r.total, doneCount: r.done })),
  });
});

projects.post("/", (c) => createResource(c, "project"));

projects.get("/:id", async (c) => {
  const row = await loadVisible(c, "project", c.req.param("id"));
  if (!row) return fail(c, 404, "not_found", "project not found");
  const { results } = await c.env.DB.prepare(
    `SELECT * FROM sections WHERE project_id = ? AND deleted_at IS NULL ORDER BY sort_order, created_at`,
  )
    .bind(row.id)
    .all<Row>();
  return c.json({ ...projectOut(row), role: await c.var.access.role(row.id as string), sections: results.map(sectionOut) });
});

projects.patch("/:id", (c) => updateResource(c, "project", c.req.param("id")));
projects.delete("/:id", (c) => deleteResource(c, "project", c.req.param("id")));
