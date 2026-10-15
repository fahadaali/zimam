import type { Access } from "./access";
import { removeMemberStatements } from "./membership";
import type { Mutator } from "./mutations";

interface OwnedProject {
  id: string;
  updated_at: number;
  /** The earliest-joined other member, who inherits a shared project. */
  heir: string | null;
}

/**
 * Deletes an account's data (App Store guideline 5.1.1(v)), writing change rows
 * so every device that saw the data drops it:
 *
 * - A project the user owns alone is deleted with its sections, tasks and reminders.
 * - A project the user owns with others passes to the earliest-joined remaining
 *   member (ties by user id), so their shared work is not lost; the user then
 *   leaves it like any removed member.
 * - The user leaves every other project the same way (`removeMemberStatements`):
 *   tasks assigned to them become unassigned, and their reminders go.
 * - Inbox tasks, reminders and the comments they wrote are deleted everywhere.
 *   Tasks they created in projects that live on stay with those projects.
 * - Their App Store entitlements are deleted; the subscription itself is Apple's, and
 *   the user cancels it in their Apple account settings.
 * - Invites they created are revoked, every session ends, and their sign-in
 *   identities (Apple, Google) are unlinked, so signing in again starts afresh.
 * - Deleted rows stay as tombstones for sync, but their text is cleared, and
 *   the user row is anonymised (other rows still reference its id).
 *
 * Sessions go last, so a failure part-way leaves the user signed in to retry;
 * each step skips what an earlier attempt already did.
 */
export async function deleteAccount(db: D1Database, access: Access, mutator: Mutator, userId: string) {
  const now = Date.now();

  const { results: owned } = await db
    .prepare(
      `SELECT p.id, p.updated_at,
         (SELECT o.user_id FROM project_members o WHERE o.project_id = p.id AND o.user_id != ?1
          ORDER BY o.added_at, o.user_id LIMIT 1) AS heir
       FROM project_members m JOIN projects p ON p.id = m.project_id
       WHERE m.user_id = ?1 AND m.role = 'owner' AND p.deleted_at IS NULL`,
    )
    .bind(userId)
    .all<OwnedProject>();

  // Shared projects change owner; the new owner's devices see it on the project row.
  for (const { id, heir } of owned) {
    if (!heir) continue;
    await db.batch([
      ...removeMemberStatements(db, id, userId, now),
      db.prepare(`UPDATE project_members SET role = 'owner' WHERE project_id = ? AND user_id = ?`).bind(id, heir),
      db.prepare(`UPDATE projects SET owner_id = ?2, updated_at = MAX(updated_at, ?3) WHERE id = ?1`).bind(id, heir, now),
      db
        .prepare(`INSERT INTO changes (entity, entity_id, project_id, user_id, at) VALUES ('project', ?1, ?1, NULL, ?2)`)
        .bind(id, now),
    ]);
  }
  access.invalidate();

  // Projects and folders nobody else is in go, the same way their owner deletes them.
  for (const { id, updated_at, heir } of owned) {
    if (heir) continue;
    const result = await mutator.apply({ op: "delete", entity: "project", id, updatedAt: Math.max(now, updated_at) });
    if (result.status !== "applied") throw new Error(`Could not delete project ${id}: ${result.status}`);
  }

  const { results: joined } = await db
    .prepare(
      `SELECT m.project_id FROM project_members m JOIN projects p ON p.id = m.project_id
       WHERE m.user_id = ? AND m.role != 'owner' AND p.deleted_at IS NULL`,
    )
    .bind(userId)
    .all<{ project_id: string }>();
  if (joined.length > 0) {
    await db.batch(joined.flatMap(({ project_id }) => removeMemberStatements(db, project_id, userId, now)));
  }
  access.invalidate();

  /** Projects the user owned that are now deleted: their contents are the user's data. */
  const ownedGone = `SELECT id FROM projects WHERE owner_id = ?1 AND deleted_at IS NOT NULL`;
  /** Tasks whose text was the user's: their inbox and their deleted projects. */
  const theirTasks = `((project_id IS NULL AND owner_id = ?1) OR project_id IN (${ownedGone}))`;
  /** Comments the user wrote anywhere, and every comment on their tasks. */
  const theirComments = (c = "comments") =>
    `(${c}.author_id = ?1 OR ${c}.task_id IN (SELECT id FROM tasks WHERE ${theirTasks}))`;

  await db.batch(
    [
      // Inbox tasks, logged to their owner.
      `INSERT INTO changes (entity, entity_id, project_id, user_id, at)
       SELECT 'task', id, NULL, owner_id, ?2 FROM tasks WHERE project_id IS NULL AND owner_id = ?1 AND deleted_at IS NULL`,
      `UPDATE tasks SET deleted_at = ?2, updated_at = ?2 WHERE project_id IS NULL AND owner_id = ?1 AND deleted_at IS NULL`,
      // Reminders are personal.
      `INSERT INTO changes (entity, entity_id, project_id, user_id, at)
       SELECT 'reminder', id, NULL, user_id, ?2 FROM reminders WHERE user_id = ?1 AND deleted_at IS NULL`,
      `UPDATE reminders SET deleted_at = ?2, updated_at = ?2 WHERE user_id = ?1 AND deleted_at IS NULL`,
      // Comments, logged to the audience of their task.
      `INSERT INTO changes (entity, entity_id, project_id, user_id, at)
       SELECT 'comment', c.id, t.project_id, CASE WHEN t.project_id IS NULL THEN t.owner_id END, ?2
       FROM comments c JOIN tasks t ON t.id = c.task_id WHERE c.deleted_at IS NULL AND ${theirComments("c")}`,
      `UPDATE comments SET deleted_at = ?2, updated_at = ?2 WHERE deleted_at IS NULL AND ${theirComments()}`,
      // Anything still assigned to them (removal already cleared their projects).
      `INSERT INTO changes (entity, entity_id, project_id, user_id, at)
       SELECT 'task', id, project_id, CASE WHEN project_id IS NULL THEN owner_id END, ?2 FROM tasks
       WHERE assignee_id = ?1 AND deleted_at IS NULL`,
      `UPDATE tasks SET assignee_id = NULL, updated_at = MAX(updated_at, ?2) WHERE assignee_id = ?1 AND deleted_at IS NULL`,
      // Tombstones keep their ids for sync, not their text.
      `UPDATE tasks SET title = '', notes = NULL, tags = '[]', search_text = '', recurrence = NULL
       WHERE deleted_at IS NOT NULL AND ${theirTasks}`,
      `UPDATE sections SET name = '' WHERE project_id IN (${ownedGone})`,
      `UPDATE projects SET name = '' WHERE owner_id = ?1 AND deleted_at IS NOT NULL`,
      `UPDATE reminders SET location = NULL WHERE user_id = ?1`,
      `UPDATE comments SET body = '' WHERE deleted_at IS NOT NULL AND ${theirComments()}`,
      `UPDATE invites SET revoked_at = ?2 WHERE created_by = ?1 AND accepted_at IS NULL AND revoked_at IS NULL`,
      `DELETE FROM project_members WHERE user_id = ?1`,
      `DELETE FROM external_refs WHERE user_id = ?1`,
      // Their files in R2 go when the queue next sees the job missing, or by the bucket's lifecycle rule.
      `DELETE FROM import_jobs WHERE user_id = ?1`,
      // The subscription itself stays with Apple until the user cancels it in their Apple account.
      `DELETE FROM entitlements WHERE user_id = ?1`,
      `DELETE FROM sessions WHERE user_id = ?1`,
      // Their Apple and Google accounts are no longer linked: signing in with them again starts a fresh account.
      `DELETE FROM identities WHERE user_id = ?1`,
      `UPDATE users SET apple_sub = 'deleted:' || id, email = NULL, name = NULL, settings = '{}',
         apple_refresh_token = NULL, apple_client_id = NULL, updated_at = ?2 WHERE id = ?1`,
    ].map((sql) => (sql.includes("?2") ? db.prepare(sql).bind(userId, now) : db.prepare(sql).bind(userId))),
  );
}
