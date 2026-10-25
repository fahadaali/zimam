import { z } from "zod";
import { escapeLike, foldForSearch } from "./arabic";
import type { Row } from "./rows";
import { Id } from "./schemas";

export const TaskQuery = z.object({
  /** A project id, or "inbox" for tasks outside any project. */
  projectId: z.union([z.literal("inbox"), Id]).optional(),
  /** The subtasks of one task. */
  parentId: Id.optional(),
  /** "open" means todo or doing. */
  status: z.enum(["todo", "doing", "done", "open"]).optional(),
  dueFrom: z.iso.date().optional(),
  dueTo: z.iso.date().optional(),
  q: z.string().trim().min(1).max(200).optional(),
  assignee: z.literal("me").optional(),
  limit: z.coerce.number().int().min(1).max(500).default(100),
  offset: z.coerce.number().int().min(0).default(0),
});
export type TaskQuery = z.infer<typeof TaskQuery>;

/** Tasks the user can see, filtered; dated tasks first, by date and time. */
export async function listTasks(db: D1Database, userId: string, q: TaskQuery): Promise<Row[]> {
  const where = [
    "t.deleted_at IS NULL",
    `((t.project_id IS NULL AND t.owner_id = ?1) OR t.project_id IN (
       SELECT m.project_id FROM project_members m JOIN projects p ON p.id = m.project_id
       WHERE m.user_id = ?1 AND p.deleted_at IS NULL))`,
  ];
  const params: unknown[] = [userId];
  const bind = (value: unknown) => {
    params.push(value);
    return `?${params.length}`;
  };
  if (q.projectId === "inbox") where.push("t.project_id IS NULL");
  else if (q.projectId) where.push(`t.project_id = ${bind(q.projectId)}`);
  if (q.parentId) where.push(`t.parent_id = ${bind(q.parentId)}`);
  if (q.status === "open") where.push("t.status != 'done'");
  else if (q.status) where.push(`t.status = ${bind(q.status)}`);
  if (q.dueFrom) where.push(`t.due_date >= ${bind(q.dueFrom)}`);
  if (q.dueTo) where.push(`t.due_date <= ${bind(q.dueTo)}`);
  if (q.assignee === "me") where.push("t.assignee_id = ?1");
  if (q.q) where.push(`t.search_text LIKE ${bind(`%${escapeLike(foldForSearch(q.q))}%`)} ESCAPE '\\'`);

  const { results } = await db
    .prepare(
      `SELECT t.* FROM tasks t WHERE ${where.join(" AND ")}
       ORDER BY t.due_date IS NULL, t.due_date, t.due_time IS NULL, t.due_time, t.sort_order, t.created_at, t.id
       LIMIT ${bind(q.limit)} OFFSET ${bind(q.offset)}`,
    )
    .bind(...params)
    .all<Row>();
  return results;
}

/** Projects and folders the user belongs to, with their role and top-level task counts. */
export async function listProjects(db: D1Database, userId: string): Promise<Row[]> {
  const { results } = await projectsStatement(db, userId).all<Row>();
  return results;
}

/**
 * The project list with each project's live sections, in one round trip: the sections of every
 * project the user belongs to come from one query, ordered as a project page orders them.
 */
export async function listProjectsWithSections(
  db: D1Database,
  userId: string,
): Promise<{ projects: Row[]; sections: Map<string, Row[]> }> {
  const [projects, sections] = await db.batch<Row>([
    projectsStatement(db, userId),
    db
      .prepare(
        `SELECT s.* FROM sections s
         JOIN project_members m ON m.project_id = s.project_id AND m.user_id = ?
         JOIN projects p ON p.id = s.project_id
         WHERE p.deleted_at IS NULL AND s.deleted_at IS NULL
         ORDER BY s.project_id, s.sort_order, s.created_at`,
      )
      .bind(userId),
  ]);
  const byProject = new Map<string, Row[]>();
  for (const row of sections!.results) {
    const key = row.project_id as string;
    const list = byProject.get(key);
    if (list) list.push(row);
    else byProject.set(key, [row]);
  }
  return { projects: projects!.results, sections: byProject };
}

function projectsStatement(db: D1Database, userId: string) {
  return db
    .prepare(
      `SELECT p.*, m.role,
         (SELECT COUNT(*) FROM tasks t WHERE t.project_id = p.id AND t.parent_id IS NULL AND t.deleted_at IS NULL) AS total,
         (SELECT COUNT(*) FROM tasks t WHERE t.project_id = p.id AND t.parent_id IS NULL AND t.deleted_at IS NULL
            AND t.status = 'done') AS done
       FROM projects p JOIN project_members m ON m.project_id = p.id AND m.user_id = ?
       WHERE p.deleted_at IS NULL ORDER BY p.sort_order, p.created_at`,
    )
    .bind(userId);
}
