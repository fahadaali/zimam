import type { z } from "zod";
import type { Access } from "./access";
import { foldForSearch } from "./arabic";
import type { Row } from "./rows";
import { TABLES } from "./rows";
import {
  CommentInput,
  type EntityName,
  Mutation,
  PlaceInput,
  ProjectInput,
  ReminderInput,
  SectionInput,
  TaskInput,
} from "./schemas";

export type MutationStatus = "applied" | "stale" | "gone" | "forbidden" | "invalid";

export interface MutationResult {
  entity?: EntityName;
  id?: string;
  status: MutationStatus;
  message?: string;
}

/** Who must hear about a change: every member of a project, or one user. */
interface Scope {
  projectId: string | null;
  userId: string | null;
}

const MAX_TASK_DEPTH = 10;

/** Ids of every task below `?1` (not including it). UNION stops on cycles. */
const DESCENDANTS = `WITH RECURSIVE sub(id) AS (
  SELECT id FROM tasks WHERE parent_id = ?1
  UNION SELECT t.id FROM tasks t JOIN sub ON t.parent_id = sub.id
)`;

/** The task's audience as change-log columns, for set-based logging. */
const TASK_SCOPE_COLUMNS = `project_id, CASE WHEN project_id IS NULL THEN owner_id END`;

class Rejection extends Error {
  constructor(
    readonly status: MutationStatus,
    message: string,
  ) {
    super(message);
  }
}

const reject = (status: MutationStatus, message: string): never => {
  throw new Rejection(status, message);
};

function parse<S extends z.ZodType>(schema: S, data: unknown): z.infer<S> {
  const result = schema.safeParse(data);
  if (!result.success) reject("invalid", result.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; "));
  return (result as { data: z.infer<S> }).data;
}

/**
 * Applies client mutations (from sync or the REST routes) with access checks,
 * last-writer-wins on `updatedAt`, and a change-log entry for every touched row.
 */
export class Mutator {
  constructor(
    private readonly db: D1Database,
    private readonly access: Access,
  ) {}

  private get me() {
    return this.access.userId;
  }

  async apply(raw: unknown): Promise<MutationResult> {
    const envelope = Mutation.safeParse(raw);
    if (!envelope.success) return { status: "invalid", message: "Malformed mutation" };
    const m = envelope.data;
    const id = m.op === "delete" ? m.id : typeof m.data.id === "string" ? m.data.id.toLowerCase() : undefined;
    try {
      if (m.op === "delete") await this.delete(m.entity, m.id, m.updatedAt);
      else await this.upsert(m.entity, m.data);
      return { entity: m.entity, id, status: "applied" };
    } catch (e) {
      if (e instanceof Rejection) return { entity: m.entity, id, status: e.status, message: e.message };
      throw e;
    }
  }

  private async upsert(entity: EntityName, data: unknown) {
    switch (entity) {
      case "project":
        return this.upsertProject(parse(ProjectInput, data));
      case "section":
        return this.upsertSection(parse(SectionInput, data));
      case "task":
        return this.upsertTask(parse(TaskInput, data));
      case "reminder":
        return this.upsertReminder(parse(ReminderInput, data));
      case "comment":
        return this.upsertComment(parse(CommentInput, data));
      case "place":
        return this.upsertPlace(parse(PlaceInput, data));
    }
  }

  // MARK: Shared helpers

  private async load(entity: EntityName, id: string): Promise<Row | null> {
    return this.db.prepare(`SELECT * FROM ${TABLES[entity]} WHERE id = ?`).bind(id).first<Row>();
  }

  /** Loads the current row and enforces deletion and last-writer-wins. */
  private async current(entity: EntityName, id: string, updatedAt: number): Promise<Row | null> {
    const row = await this.load(entity, id);
    if (row?.deleted_at != null) reject("gone", `${entity} was deleted`);
    if (row && (row.updated_at as number) > updatedAt) reject("stale", `${entity} has a newer version`);
    return row;
  }

  private logChange(entity: EntityName, id: string, scope: Scope, at: number) {
    return this.db
      .prepare(`INSERT INTO changes (entity, entity_id, project_id, user_id, at) VALUES (?, ?, ?, ?, ?)`)
      .bind(entity, id, scope.projectId, scope.userId, at);
  }

  private taskScope(task: { project_id?: unknown; owner_id?: unknown }): Scope {
    return task.project_id != null
      ? { projectId: task.project_id as string, userId: null }
      : { projectId: null, userId: task.owner_id as string };
  }

  private async loadTask(id: string): Promise<Row> {
    const task = await this.load("task", id);
    if (!task || task.deleted_at != null) reject("invalid", "Task not found");
    return task as Row;
  }

  // MARK: Projects

  private async upsertProject(p: ProjectInput) {
    const existing = await this.current("project", p.id, p.updatedAt);
    if (existing && !(await this.access.canEditProject(p.id))) reject("forbidden", "Cannot edit this project");
    if (p.parentId) {
      if (p.parentId === p.id) reject("invalid", "A project cannot contain itself");
      const parent = await this.load("project", p.parentId);
      if (!parent || parent.deleted_at != null || parent.kind !== "folder") reject("invalid", "Parent must be a folder");
      if (!(await this.access.canEditProject(p.parentId))) reject("forbidden", "Cannot edit the parent folder");
    }
    const now = Date.now();
    const statements = [
      this.db
        .prepare(
          `INSERT INTO projects (id, owner_id, parent_id, kind, name, view, sort_order, archived_at, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT (id) DO UPDATE SET parent_id = excluded.parent_id, kind = excluded.kind, name = excluded.name,
             view = excluded.view, sort_order = excluded.sort_order, archived_at = excluded.archived_at,
             updated_at = excluded.updated_at`,
        )
        .bind(p.id, this.me, p.parentId, p.kind, p.name, p.view, p.sortOrder, p.archivedAt, now, p.updatedAt),
    ];
    if (!existing) {
      statements.push(
        this.db
          .prepare(`INSERT INTO project_members (project_id, user_id, role, added_at) VALUES (?, ?, 'owner', ?)`)
          .bind(p.id, this.me, now),
      );
    }
    statements.push(this.logChange("project", p.id, { projectId: p.id, userId: null }, now));
    await this.db.batch(statements);
    this.access.invalidate();
  }

  private async deleteProject(project: Row, at: number) {
    if ((await this.access.role(project.id as string)) !== "owner") reject("forbidden", "Only the owner can delete a project");
    const id = project.id as string;
    const now = Date.now();
    await this.db.batch([
      // Reminders on the project's tasks, logged to each reminder's owner.
      this.db
        .prepare(
          `INSERT INTO changes (entity, entity_id, project_id, user_id, at)
           SELECT 'reminder', id, NULL, user_id, ?2 FROM reminders
           WHERE deleted_at IS NULL AND task_id IN (SELECT id FROM tasks WHERE project_id = ?1)`,
        )
        .bind(id, now),
      this.db
        .prepare(
          `UPDATE reminders SET deleted_at = ?2, updated_at = ?2
           WHERE deleted_at IS NULL AND task_id IN (SELECT id FROM tasks WHERE project_id = ?1)`,
        )
        .bind(id, at),
      // Attachments on the project's tasks; their files leave R2 on the next purge (src/attachments.ts).
      this.db
        .prepare(
          `INSERT INTO changes (entity, entity_id, project_id, user_id, at)
           SELECT 'attachment', id, ?1, NULL, ?2 FROM attachments
           WHERE deleted_at IS NULL AND task_id IN (SELECT id FROM tasks WHERE project_id = ?1)`,
        )
        .bind(id, now),
      this.db
        .prepare(
          `UPDATE attachments SET deleted_at = ?2, updated_at = ?2
           WHERE deleted_at IS NULL AND task_id IN (SELECT id FROM tasks WHERE project_id = ?1)`,
        )
        .bind(id, at),
      ...(["task", "section"] as const).flatMap((entity) => [
        this.db
          .prepare(
            `INSERT INTO changes (entity, entity_id, project_id, user_id, at)
             SELECT '${entity}', id, ?1, NULL, ?2 FROM ${TABLES[entity]} WHERE project_id = ?1 AND deleted_at IS NULL`,
          )
          .bind(id, now),
        this.db
          .prepare(`UPDATE ${TABLES[entity]} SET deleted_at = ?2, updated_at = ?2 WHERE project_id = ?1 AND deleted_at IS NULL`)
          .bind(id, at),
      ]),
      // Projects inside a deleted folder move to the top level.
      this.db
        .prepare(
          `INSERT INTO changes (entity, entity_id, project_id, user_id, at)
           SELECT 'project', id, id, NULL, ?2 FROM projects WHERE parent_id = ?1 AND deleted_at IS NULL`,
        )
        .bind(id, now),
      this.db
        .prepare(`UPDATE projects SET parent_id = NULL, updated_at = MAX(updated_at, ?2) WHERE parent_id = ?1 AND deleted_at IS NULL`)
        .bind(id, at),
      this.db.prepare(`UPDATE projects SET deleted_at = ?2, updated_at = ?2 WHERE id = ?1`).bind(id, at),
      this.logChange("project", id, { projectId: id, userId: null }, now),
    ]);
    this.access.invalidate();
  }

  // MARK: Sections

  private async upsertSection(s: SectionInput) {
    const existing = await this.current("section", s.id, s.updatedAt);
    if (existing && existing.project_id !== s.projectId) reject("invalid", "A section cannot move between projects");
    if (!(await this.access.canEditProject(s.projectId))) reject("forbidden", "Cannot edit this project");
    const now = Date.now();
    await this.db.batch([
      this.db
        .prepare(
          `INSERT INTO sections (id, project_id, name, sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)
           ON CONFLICT (id) DO UPDATE SET name = excluded.name, sort_order = excluded.sort_order, updated_at = excluded.updated_at`,
        )
        .bind(s.id, s.projectId, s.name, s.sortOrder, now, s.updatedAt),
      this.logChange("section", s.id, { projectId: s.projectId, userId: null }, now),
    ]);
  }

  private async deleteSection(section: Row, at: number) {
    const projectId = section.project_id as string;
    if (!(await this.access.canEditProject(projectId))) reject("forbidden", "Cannot edit this project");
    const now = Date.now();
    await this.db.batch([
      this.db
        .prepare(
          `INSERT INTO changes (entity, entity_id, project_id, user_id, at)
           SELECT 'task', id, ?2, NULL, ?3 FROM tasks WHERE section_id = ?1 AND deleted_at IS NULL`,
        )
        .bind(section.id, projectId, now),
      this.db
        .prepare(`UPDATE tasks SET section_id = NULL, updated_at = MAX(updated_at, ?2) WHERE section_id = ?1 AND deleted_at IS NULL`)
        .bind(section.id, at),
      this.db.prepare(`UPDATE sections SET deleted_at = ?2, updated_at = ?2 WHERE id = ?1`).bind(section.id, at),
      this.logChange("section", section.id as string, { projectId, userId: null }, now),
    ]);
  }

  // MARK: Tasks

  private async upsertTask(t: TaskInput) {
    const existing = await this.current("task", t.id, t.updatedAt);
    if (existing && !(await this.access.canEditTask(existing))) reject("forbidden", "Cannot edit this task");
    const ownerId = (existing?.owner_id as string | undefined) ?? this.me;

    if (t.projectId === null) {
      if (ownerId !== this.me) reject("forbidden", "Only the task's creator can move it to their inbox");
      if (t.assigneeId !== null && t.assigneeId !== this.me) reject("invalid", "Inbox tasks cannot be assigned to others");
      if (t.sectionId !== null) reject("invalid", "Inbox tasks have no sections");
    } else {
      if (!(await this.access.canEditProject(t.projectId))) reject("forbidden", "Cannot edit this project");
      if (t.sectionId !== null) {
        const section = await this.load("section", t.sectionId);
        if (!section || section.deleted_at != null || section.project_id !== t.projectId) reject("invalid", "Section is not in this project");
      }
      if (t.assigneeId !== null) {
        const member = await this.db
          .prepare(`SELECT 1 FROM project_members WHERE project_id = ? AND user_id = ?`)
          .bind(t.projectId, t.assigneeId)
          .first();
        if (!member) reject("invalid", "Assignee is not a member of this project");
      }
    }

    if (t.parentId !== null) {
      const parent = await this.loadTask(t.parentId);
      if (parent.project_id !== t.projectId || (t.projectId === null && parent.owner_id !== ownerId)) {
        reject("invalid", "A subtask must be in its parent's project");
      }
      let ancestor: Row | null = parent;
      for (let depth = 0; ancestor; depth++) {
        if (ancestor.id === t.id) reject("invalid", "A task cannot be inside itself");
        if (depth >= MAX_TASK_DEPTH) reject("invalid", "Subtasks are nested too deeply");
        ancestor = ancestor.parent_id ? await this.load("task", ancestor.parent_id as string) : null;
      }
    }

    // An app that predates start dates leaves the field out: keep the stored day while the
    // (possibly new) due day still allows it, as TaskInput would require.
    const kept = (existing?.start_date as string | null | undefined) ?? null;
    const startDate =
      t.startDate !== undefined ? t.startDate : kept !== null && t.dueDate !== null && kept <= t.dueDate ? kept : null;
    const completedAt = t.status === "done" ? (t.completedAt ?? t.updatedAt) : null;
    const searchText = foldForSearch(`${t.title} ${t.notes ?? ""} ${t.tags.join(" ")}`);
    const now = Date.now();
    const newScope = this.taskScope({ project_id: t.projectId, owner_id: ownerId });
    const moved = existing !== null && existing.project_id !== t.projectId;

    const statements = [
      this.db
        .prepare(
          `INSERT INTO tasks (id, owner_id, project_id, section_id, parent_id, title, notes, status, priority, tags,
             due_date, start_date, due_time, due_prayer, due_prayer_offset, recurrence, assignee_id, sort_order,
             completed_at, search_text, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT (id) DO UPDATE SET project_id = excluded.project_id, section_id = excluded.section_id,
             parent_id = excluded.parent_id, title = excluded.title, notes = excluded.notes, status = excluded.status,
             priority = excluded.priority, tags = excluded.tags, due_date = excluded.due_date,
             start_date = excluded.start_date, due_time = excluded.due_time,
             due_prayer = excluded.due_prayer, due_prayer_offset = excluded.due_prayer_offset,
             recurrence = excluded.recurrence, assignee_id = excluded.assignee_id, sort_order = excluded.sort_order,
             completed_at = excluded.completed_at, search_text = excluded.search_text, updated_at = excluded.updated_at`,
        )
        .bind(
          t.id, ownerId, t.projectId, t.sectionId, t.parentId, t.title, t.notes, t.status, t.priority,
          JSON.stringify(t.tags), t.dueDate, startDate, t.dueTime, t.duePrayer, t.duePrayerOffset, t.recurrence,
          t.assigneeId, t.sortOrder, completedAt, searchText, now, t.updatedAt,
        ),
      this.logChange("task", t.id, newScope, now),
    ];

    if (moved) {
      // Reminders are personal and live only while their user can see the task: those of anyone
      // outside the new place (not a member of the project, or not the inbox's owner) go, as
      // when a member is removed, logged to each reminder's owner.
      const tree = `${DESCENDANTS}, tree(id) AS (SELECT ?1 UNION SELECT id FROM sub)`;
      const outsiders = `task_id IN tree AND deleted_at IS NULL AND CASE WHEN ?2 IS NULL THEN user_id <> ?3
        ELSE user_id NOT IN (SELECT user_id FROM project_members WHERE project_id = ?2) END`;
      // Tell the old audience, then carry subtasks and comments to the new place.
      statements.push(
        this.db
          .prepare(
            `${tree} INSERT INTO changes (entity, entity_id, project_id, user_id, at)
             SELECT 'reminder', id, NULL, user_id, ?4 FROM reminders WHERE ${outsiders}`,
          )
          .bind(t.id, t.projectId, ownerId, now),
        this.db
          .prepare(`${tree} UPDATE reminders SET deleted_at = ?4, updated_at = ?4 WHERE ${outsiders}`)
          .bind(t.id, t.projectId, ownerId, now),
        this.logChange("task", t.id, this.taskScope(existing), now),
        this.db
          .prepare(
            `${DESCENDANTS} INSERT INTO changes (entity, entity_id, project_id, user_id, at)
             SELECT 'task', id, ${TASK_SCOPE_COLUMNS}, ?2 FROM tasks WHERE id IN sub`,
          )
          .bind(t.id, now),
        this.db
          .prepare(
            `${DESCENDANTS} UPDATE tasks SET project_id = ?2, section_id = NULL,
               owner_id = CASE WHEN ?2 IS NULL THEN ?3 ELSE owner_id END,
               assignee_id = CASE WHEN ?2 IS NULL THEN NULL ELSE assignee_id END,
               updated_at = MAX(updated_at, ?4)
             WHERE id IN sub AND deleted_at IS NULL`,
          )
          .bind(t.id, t.projectId, ownerId, t.updatedAt),
        this.db
          .prepare(
            `${DESCENDANTS} INSERT INTO changes (entity, entity_id, project_id, user_id, at)
             SELECT 'task', id, ${TASK_SCOPE_COLUMNS}, ?2 FROM tasks WHERE id IN sub`,
          )
          .bind(t.id, now),
        this.db
          .prepare(
            `${DESCENDANTS} INSERT INTO changes (entity, entity_id, project_id, user_id, at)
             SELECT 'comment', id, ?2, ?3, ?4 FROM comments WHERE (task_id = ?1 OR task_id IN sub) AND deleted_at IS NULL`,
          )
          .bind(t.id, newScope.projectId, newScope.userId, now),
        // Attachments follow their task: the old audience drops them, the new one gets them.
        this.logAttachmentsOfTree(t.id, this.taskScope(existing), now),
        this.db
          .prepare(
            `${DESCENDANTS} UPDATE attachments SET project_id = ?2, updated_at = MAX(updated_at, ?3)
             WHERE (task_id = ?1 OR task_id IN sub) AND deleted_at IS NULL`,
          )
          .bind(t.id, t.projectId, now),
        this.logAttachmentsOfTree(t.id, newScope, now),
      );
    }
    await this.db.batch(statements);
  }

  /** Change rows for the live attachments of a task and its subtasks, addressed to `scope`. */
  private logAttachmentsOfTree(taskId: string, scope: Scope, at: number) {
    return this.db
      .prepare(
        `${DESCENDANTS} INSERT INTO changes (entity, entity_id, project_id, user_id, at)
         SELECT 'attachment', id, ?2, ?3, ?4 FROM attachments WHERE (task_id = ?1 OR task_id IN sub) AND deleted_at IS NULL`,
      )
      .bind(taskId, scope.projectId, scope.userId, at);
  }

  private async deleteTask(task: Row, at: number) {
    if (!(await this.access.canEditTask(task))) reject("forbidden", "Cannot edit this task");
    const now = Date.now();
    const tree = `${DESCENDANTS}, tree(id) AS (SELECT ?1 UNION SELECT id FROM sub)`;
    await this.db.batch([
      this.db
        .prepare(
          `${tree} INSERT INTO changes (entity, entity_id, project_id, user_id, at)
           SELECT 'reminder', id, NULL, user_id, ?2 FROM reminders WHERE task_id IN tree AND deleted_at IS NULL`,
        )
        .bind(task.id, now),
      this.db
        .prepare(`${tree} UPDATE reminders SET deleted_at = ?2, updated_at = ?2 WHERE task_id IN tree AND deleted_at IS NULL`)
        .bind(task.id, at),
      // Attachments, logged to their task's audience; their files leave R2 on the next purge.
      this.db
        .prepare(
          `${tree} INSERT INTO changes (entity, entity_id, project_id, user_id, at)
           SELECT 'attachment', a.id, t.project_id, CASE WHEN t.project_id IS NULL THEN t.owner_id END, ?2
           FROM attachments a JOIN tasks t ON t.id = a.task_id WHERE a.task_id IN tree AND a.deleted_at IS NULL`,
        )
        .bind(task.id, now),
      this.db
        .prepare(`${tree} UPDATE attachments SET deleted_at = ?2, updated_at = ?2 WHERE task_id IN tree AND deleted_at IS NULL`)
        .bind(task.id, at),
      this.db
        .prepare(
          `${tree} INSERT INTO changes (entity, entity_id, project_id, user_id, at)
           SELECT 'task', id, ${TASK_SCOPE_COLUMNS}, ?2 FROM tasks WHERE id IN tree AND deleted_at IS NULL`,
        )
        .bind(task.id, now),
      this.db
        .prepare(`${tree} UPDATE tasks SET deleted_at = ?2, updated_at = ?2 WHERE id IN tree AND deleted_at IS NULL`)
        .bind(task.id, at),
    ]);
  }

  // MARK: Reminders

  private async upsertReminder(r: ReminderInput) {
    const existing = await this.current("reminder", r.id, r.updatedAt);
    if (existing && existing.user_id !== this.me) reject("forbidden", "Reminders are personal");
    if (existing && existing.task_id !== r.taskId) reject("invalid", "A reminder cannot move between tasks");
    const task = await this.loadTask(r.taskId);
    if (!(await this.access.canSeeTask(task))) reject("forbidden", "Cannot see this task");
    // A copy of a saved place keeps its link only to one of the user's own live places.
    const location = r.location && r.location.placeId !== null && !(await this.ownPlace(r.location.placeId))
      ? { ...r.location, placeId: null }
      : r.location;
    // An app that predates firedAt leaves it out: keep the stored one.
    const firedAt = r.firedAt !== undefined ? r.firedAt : ((existing?.fired_at as number | null | undefined) ?? null);
    const now = Date.now();
    await this.db.batch([
      this.db
        .prepare(
          `INSERT INTO reminders (id, user_id, task_id, kind, at, prayer, offset_minutes, location, fired_at, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, at = excluded.at, prayer = excluded.prayer,
             offset_minutes = excluded.offset_minutes, location = excluded.location, fired_at = excluded.fired_at,
             updated_at = excluded.updated_at`,
        )
        .bind(
          r.id, this.me, r.taskId, r.kind, r.at, r.prayer, r.offsetMinutes,
          location ? JSON.stringify(location) : null, firedAt, now, r.updatedAt,
        ),
      this.logChange("reminder", r.id, { projectId: null, userId: this.me }, now),
    ]);
  }

  // MARK: Places

  private async ownPlace(id: string): Promise<boolean> {
    const place = await this.load("place", id);
    return place != null && place.deleted_at == null && place.user_id === this.me;
  }

  /**
   * Saves a place, and rewrites the copy in the user's reminders that use it, so moving «البيت»
   * or widening it moves every reminder there, in apps that predate places too.
   */
  private async upsertPlace(p: PlaceInput) {
    const existing = await this.current("place", p.id, p.updatedAt);
    if (existing && existing.user_id !== this.me) reject("forbidden", "Places are personal");
    const now = Date.now();
    const linked = `user_id = ?1 AND deleted_at IS NULL AND kind = 'location' AND json_valid(location)
      AND json_extract(location, '$.placeId') = ?2`;
    const statements = [
      this.db
        .prepare(
          `INSERT INTO places (id, user_id, name, latitude, longitude, radius, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)
           ON CONFLICT (id) DO UPDATE SET name = excluded.name, latitude = excluded.latitude,
             longitude = excluded.longitude, radius = excluded.radius, updated_at = excluded.updated_at`,
        )
        .bind(p.id, this.me, p.name, p.latitude, p.longitude, p.radius, now, p.updatedAt),
      this.logChange("place", p.id, { projectId: null, userId: this.me }, now),
    ];
    if (existing) {
      statements.push(
        this.db
          .prepare(
            `UPDATE reminders SET location = json_set(location, '$.latitude', ?3, '$.longitude', ?4, '$.radius', ?5, '$.name', ?6),
               updated_at = MAX(updated_at + 1, ?7)
             WHERE ${linked}`,
          )
          .bind(this.me, p.id, p.latitude, p.longitude, p.radius, p.name, now),
        this.db
          .prepare(
            `INSERT INTO changes (entity, entity_id, project_id, user_id, at)
             SELECT 'reminder', id, NULL, user_id, ?3 FROM reminders WHERE ${linked}`,
          )
          .bind(this.me, p.id, now),
      );
    }
    await this.db.batch(statements);
  }

  /** Deletes a place. Its reminders stay where it was, unlinked. */
  private async deletePlace(place: Row, at: number) {
    if (place.user_id !== this.me) reject("forbidden", "Places are personal");
    const now = Date.now();
    const linked = `user_id = ?1 AND deleted_at IS NULL AND kind = 'location' AND json_valid(location)
      AND json_extract(location, '$.placeId') = ?2`;
    await this.db.batch([
      this.db
        .prepare(
          `INSERT INTO changes (entity, entity_id, project_id, user_id, at)
           SELECT 'reminder', id, NULL, user_id, ?3 FROM reminders WHERE ${linked}`,
        )
        .bind(this.me, place.id, now),
      this.db
        .prepare(
          `UPDATE reminders SET location = json_set(location, '$.placeId', NULL), updated_at = MAX(updated_at + 1, ?3)
           WHERE ${linked}`,
        )
        .bind(this.me, place.id, now),
      this.db.prepare(`UPDATE places SET deleted_at = ?2, updated_at = ?2 WHERE id = ?1`).bind(place.id, at),
      this.logChange("place", place.id as string, { projectId: null, userId: this.me }, now),
    ]);
  }

  // MARK: Comments

  private async upsertComment(c: CommentInput) {
    const existing = await this.current("comment", c.id, c.updatedAt);
    if (existing && existing.author_id !== this.me) reject("forbidden", "Only the author can edit a comment");
    if (existing && existing.task_id !== c.taskId) reject("invalid", "A comment cannot move between tasks");
    const task = await this.loadTask(c.taskId);
    if (!(await this.access.canSeeTask(task))) reject("forbidden", "Cannot see this task");
    const now = Date.now();
    await this.db.batch([
      this.db
        .prepare(
          `INSERT INTO comments (id, task_id, author_id, body, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)
           ON CONFLICT (id) DO UPDATE SET body = excluded.body, updated_at = excluded.updated_at`,
        )
        .bind(c.id, c.taskId, this.me, c.body, now, c.updatedAt),
      this.logChange("comment", c.id, this.taskScope(task), now),
    ]);
  }

  // MARK: Deletes

  private async delete(entity: EntityName, id: string, at: number) {
    const row = await this.load(entity, id);
    if (!row) return reject("invalid", `${entity} not found`);
    // Deleting twice is a no-op, so a retried request still succeeds.
    if (row.deleted_at != null) return;
    if ((row.updated_at as number) > at) reject("stale", `${entity} has a newer version`);
    switch (entity) {
      case "project":
        return this.deleteProject(row, at);
      case "section":
        return this.deleteSection(row, at);
      case "task":
        return this.deleteTask(row, at);
      case "reminder": {
        if (row.user_id !== this.me) reject("forbidden", "Reminders are personal");
        return this.softDelete("reminder", row, { projectId: null, userId: this.me }, at);
      }
      case "comment": {
        if (row.author_id !== this.me) reject("forbidden", "Only the author can delete a comment");
        const task = await this.load("task", row.task_id as string);
        return this.softDelete("comment", row, this.taskScope(task ?? { owner_id: this.me }), at);
      }
      case "place":
        return this.deletePlace(row, at);
    }
  }

  private async softDelete(entity: EntityName, row: Row, scope: Scope, at: number) {
    await this.db.batch([
      this.db.prepare(`UPDATE ${TABLES[entity]} SET deleted_at = ?2, updated_at = ?2 WHERE id = ?1`).bind(row.id, at),
      this.logChange(entity, row.id as string, scope, Date.now()),
    ]);
  }
}
