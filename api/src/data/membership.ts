import type { Role } from "./access";
import type { Row } from "./rows";

/** Roles an invite or a role change can grant; a project has exactly one owner. */
export const MEMBER_ROLES = ["editor", "viewer"] as const;
export type MemberRole = (typeof MEMBER_ROLES)[number];

const RANK: Record<Role, number> = { viewer: 0, editor: 1, owner: 2 };

export const outranks = (a: Role, b: Role) => RANK[a] > RANK[b];

export function memberOut(r: Row) {
  return {
    userId: r.user_id as string,
    name: (r.name ?? null) as string | null,
    role: r.role as Role,
    addedAt: r.added_at as number,
  };
}

const MEMBER_SELECT = `SELECT m.user_id, m.role, m.added_at, u.name FROM project_members m JOIN users u ON u.id = m.user_id`;

/** Owner first, then by join date. */
export async function listMembers(db: D1Database, projectId: string) {
  const { results } = await db
    .prepare(`${MEMBER_SELECT} WHERE m.project_id = ? ORDER BY m.role != 'owner', m.added_at, m.user_id`)
    .bind(projectId)
    .all<Row>();
  return results.map(memberOut);
}

export async function loadMember(db: D1Database, projectId: string, userId: string) {
  const row = await db.prepare(`${MEMBER_SELECT} WHERE m.project_id = ? AND m.user_id = ?`).bind(projectId, userId).first<Row>();
  return row ? memberOut(row) : null;
}

/**
 * Change rows addressed to one user for every live record of a project. A user
 * who joins or leaves has a cursor past the project's own change rows; pull
 * re-checks visibility, so these arrive as upserts for a new member and as
 * deletes for a removed one. Project first, so clients see it before its tasks.
 * Attachments go to clients that pull them (`include=attachment`).
 */
function projectChangesForUser(db: D1Database, projectId: string, userId: string, now: number): D1PreparedStatement[] {
  const insert = `INSERT INTO changes (entity, entity_id, project_id, user_id, at)`;
  return [
    `${insert} SELECT 'project', id, NULL, ?2, ?3 FROM projects WHERE id = ?1 AND deleted_at IS NULL`,
    `${insert} SELECT 'section', id, NULL, ?2, ?3 FROM sections WHERE project_id = ?1 AND deleted_at IS NULL`,
    `${insert} SELECT 'task', id, NULL, ?2, ?3 FROM tasks WHERE project_id = ?1 AND deleted_at IS NULL`,
    `${insert} SELECT 'comment', c.id, NULL, ?2, ?3 FROM comments c JOIN tasks t ON t.id = c.task_id
       WHERE t.project_id = ?1 AND t.deleted_at IS NULL AND c.deleted_at IS NULL`,
    `${insert} SELECT 'attachment', a.id, NULL, ?2, ?3 FROM attachments a JOIN tasks t ON t.id = a.task_id
       WHERE t.project_id = ?1 AND t.deleted_at IS NULL AND a.deleted_at IS NULL`,
  ].map((sql) => db.prepare(sql).bind(projectId, userId, now));
}

/**
 * Adds a member, or raises a viewer to `role`, and queues the whole project for their next pull.
 * A member already there keeps the higher role: two invites accepted at once, or a role read
 * before another request added them, do not fail on the primary key.
 */
export function addMemberStatements(db: D1Database, projectId: string, userId: string, role: MemberRole, now: number) {
  return [
    db
      .prepare(
        `INSERT INTO project_members (project_id, user_id, role, added_at) VALUES (?, ?, ?, ?)
         ON CONFLICT (project_id, user_id) DO UPDATE SET role = excluded.role WHERE project_members.role = 'viewer'`,
      )
      .bind(projectId, userId, role, now),
    ...projectChangesForUser(db, projectId, userId, now),
  ];
}

/**
 * Removes a member: their tasks in the project become unassigned, their
 * personal reminders on its tasks go, and their next pull deletes the project.
 */
export function removeMemberStatements(db: D1Database, projectId: string, userId: string, now: number) {
  const assigned = `project_id = ?1 AND assignee_id = ?2 AND deleted_at IS NULL`;
  const reminders = `user_id = ?2 AND deleted_at IS NULL AND task_id IN (SELECT id FROM tasks WHERE project_id = ?1)`;
  return [
    `INSERT INTO changes (entity, entity_id, project_id, user_id, at) SELECT 'task', id, ?1, NULL, ?3 FROM tasks WHERE ${assigned}`,
    `UPDATE tasks SET assignee_id = NULL, updated_at = MAX(updated_at, ?3) WHERE ${assigned}`,
    `INSERT INTO changes (entity, entity_id, project_id, user_id, at) SELECT 'reminder', id, NULL, ?2, ?3 FROM reminders WHERE ${reminders}`,
    `UPDATE reminders SET deleted_at = ?3, updated_at = ?3 WHERE ${reminders}`,
  ]
    .map((sql) => db.prepare(sql).bind(projectId, userId, now))
    .concat(
      db.prepare(`DELETE FROM project_members WHERE project_id = ? AND user_id = ?`).bind(projectId, userId),
      projectChangesForUser(db, projectId, userId, now),
    );
}
