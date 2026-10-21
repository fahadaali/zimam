import { Hono } from "hono";
import { listProjectsWithSections } from "../data/queries";
import { projectOut, type Row, sectionOut } from "../data/rows";
import type { AppEnv } from "../types";
import { createResource, deleteResource, loadVisible, updateResource } from "./resources";
import { fail } from "../http";

export const projects = new Hono<AppEnv>();

/**
 * Projects and folders the user belongs to, with top-level task counts for the project card and
 * each project's sections (empty for a folder or a project without any).
 */
projects.get("/", async (c) => {
  const { projects: rows, sections } = await listProjectsWithSections(c.env.DB, c.var.userId);
  return c.json({
    projects: rows.map((r) => ({
      ...projectOut(r),
      role: r.role,
      taskCount: r.total,
      doneCount: r.done,
      sections: (sections.get(r.id as string) ?? []).map(sectionOut),
    })),
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
