import type { Access } from "./access";
import { OUT, type Row, TABLES } from "./rows";
import { type ChangeEntity, OPT_IN_ENTITIES } from "./schemas";

export interface Change {
  entity: ChangeEntity;
  id: string;
  op: "upsert" | "delete";
  data?: Record<string, unknown>;
}

/** D1 allows 100 bound parameters per statement. */
const CHUNK = 90;

async function loadRows(db: D1Database, entity: ChangeEntity, ids: string[]): Promise<Map<string, Row>> {
  const rows = new Map<string, Row>();
  for (let i = 0; i < ids.length; i += CHUNK) {
    const chunk = ids.slice(i, i + CHUNK);
    const { results } = await db
      .prepare(`SELECT * FROM ${TABLES[entity]} WHERE id IN (${chunk.map(() => "?").join(",")})`)
      .bind(...chunk)
      .all<Row>();
    for (const row of results) rows.set(row.id as string, row);
  }
  return rows;
}

/**
 * Returns what changed for this user after `cursor`: the latest state of each
 * touched record, or a delete when it is gone or no longer visible to them.
 *
 * Opt-in entities (attachments) are left out unless `include` names them, but the
 * cursor still moves past their rows, so older apps neither see nor re-pull them.
 */
export async function pullChanges(
  db: D1Database,
  access: Access,
  cursor: number,
  limit: number,
  include: readonly ChangeEntity[] = [],
) {
  const { results } = await db
    .prepare(
      `SELECT entity, entity_id, MAX(seq) AS seq FROM changes
       WHERE seq > ?1 AND (user_id = ?2 OR project_id IN (SELECT project_id FROM project_members WHERE user_id = ?2))
       GROUP BY entity, entity_id ORDER BY seq LIMIT ?3`,
    )
    .bind(cursor, access.userId, limit + 1)
    .all<{ entity: ChangeEntity; entity_id: string; seq: number }>();

  const hasMore = results.length > limit;
  const page = results.slice(0, limit);
  const wanted = page.filter((c) => !OPT_IN_ENTITIES.includes(c.entity) || include.includes(c.entity));

  const idsByEntity = new Map<ChangeEntity, string[]>();
  for (const c of wanted) idsByEntity.set(c.entity, [...(idsByEntity.get(c.entity) ?? []), c.entity_id]);
  const rows = new Map<ChangeEntity, Map<string, Row>>();
  for (const [entity, ids] of idsByEntity) rows.set(entity, await loadRows(db, entity, ids));

  // Comments and attachments are visible through their task.
  const childTaskIds = [...(rows.get("comment")?.values() ?? []), ...(rows.get("attachment")?.values() ?? [])].map(
    (c) => c.task_id as string,
  );
  const childTasks = await loadRows(db, "task", [...new Set(childTaskIds)]);

  const visible = async (entity: ChangeEntity, row: Row): Promise<boolean> => {
    if (row.deleted_at != null) return false;
    switch (entity) {
      case "project":
        return (await access.role(row.id as string)) !== null;
      case "section":
        return (await access.role(row.project_id as string)) !== null;
      case "task":
        return access.canSeeTask(row);
      case "reminder":
        return row.user_id === access.userId;
      case "comment":
      case "attachment": {
        const task = childTasks.get(row.task_id as string);
        return task != null && task.deleted_at == null && access.canSeeTask(task);
      }
    }
  };

  const changes: Change[] = [];
  for (const c of wanted) {
    const row = rows.get(c.entity)?.get(c.entity_id);
    if (row && (await visible(c.entity, row))) {
      changes.push({ entity: c.entity, id: c.entity_id, op: "upsert", data: OUT[c.entity](row) });
    } else {
      changes.push({ entity: c.entity, id: c.entity_id, op: "delete" });
    }
  }

  const last = page.at(-1);
  return { changes, cursor: last ? last.seq : cursor, hasMore };
}
