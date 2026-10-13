import { sha256Hex } from "../auth/crypto";
import { Access } from "../data/access";
import { Mutator } from "../data/mutations";
import { type Row, TABLES } from "../data/rows";
import type { ImportBundle, ImportedProject, ImportedReminder, ImportedSection, ImportedTask } from "./model";
import { isDerivedKey } from "./source";

export type ImportEntity = "project" | "section" | "task" | "reminder";

/** One record to write, in an order where everything a record points to comes first. */
export type Item =
  | { entity: "project"; record: ImportedProject }
  | { entity: "section"; record: ImportedSection }
  | { entity: "task"; record: Omit<ImportedTask, "reminders"> }
  | { entity: "reminder"; record: ImportedReminder; taskKey: string; taskTitle: string };

/**
 * The bundle as a flat list: folders and projects (parents first), sections, tasks
 * (parents first, as `orderTasks` left them), then reminders. Links to records that
 * are not in the bundle are dropped here, so the importer can trust every key.
 */
export function flatten(bundle: ImportBundle): Item[] {
  const projectByKey = new Map(bundle.projects.map((p) => [p.key, p]));
  const projects: ImportedProject[] = [];
  const placed = new Set<string>();
  const place = (p: ImportedProject, depth = 0) => {
    if (placed.has(p.key)) return;
    const parent = p.parentKey ? projectByKey.get(p.parentKey) : undefined;
    if (!parent || parent.kind !== "folder" || depth > 10) p.parentKey = null;
    else place(parent, depth + 1);
    placed.add(p.key);
    projects.push(p);
  };
  bundle.projects.forEach((p) => place(p));

  const isProject = (key: string | null) => key !== null && projectByKey.get(key)?.kind === "project";
  const sections = bundle.sections.filter((s) => isProject(s.projectKey));
  const sectionProject = new Map(sections.map((s) => [s.key, s.projectKey]));
  const taskKeys = new Set<string>();
  const items: Item[] = [
    ...projects.map((record) => ({ entity: "project" as const, record })),
    ...sections.map((record) => ({ entity: "section" as const, record })),
  ];
  for (const { reminders: _, ...task } of bundle.tasks) {
    const projectKey = isProject(task.projectKey) ? task.projectKey : null;
    const sectionKey = task.sectionKey && projectKey && sectionProject.get(task.sectionKey) === projectKey ? task.sectionKey : null;
    const parentKey = task.parentKey && taskKeys.has(task.parentKey) ? task.parentKey : null;
    taskKeys.add(task.key);
    items.push({ entity: "task", record: { ...task, projectKey, sectionKey, parentKey } });
  }
  for (const task of bundle.tasks) {
    for (const reminder of task.reminders) {
      items.push({ entity: "reminder", record: reminder, taskKey: task.key, taskTitle: task.title });
    }
  }
  return items;
}

export interface Counts {
  created: number;
  updated: number;
  /** Same as last import: nothing written. */
  unchanged: number;
  /** Edited or deleted in Zimam since the last import: Zimam's version is kept. */
  skipped: number;
  failed: number;
}

export type CountsByEntity = Partial<Record<ImportEntity, Counts>>;

export interface ItemError {
  entity: ImportEntity;
  title: string;
  /** Arabic, for the user. */
  message: string;
}

export interface ChunkResult {
  counts: CountsByEntity;
  errors: ItemError[];
}

interface Ref {
  external_id: string;
  entity: string;
  entity_id: string;
  synced_at: number;
}

const ENTITY_NAMES: Record<ImportEntity, string> = {
  project: "المشروع",
  section: "القسم",
  task: "المهمة",
  reminder: "تذكير المهمة",
};

const REASONS: Record<string, string> = {
  forbidden: "لا تملك صلاحية التعديل في مكانها",
  invalid: "لا تقبلها قواعد زمام",
};

const itemKeys = (item: Item): (string | null)[] => {
  switch (item.entity) {
    case "project":
      return [item.record.key, item.record.parentKey];
    case "section":
      return [item.record.key, item.record.projectKey];
    case "task":
      return [item.record.key, item.record.projectKey, item.record.sectionKey, item.record.parentKey];
    case "reminder":
      return [item.record.key, item.taskKey];
  }
};

const itemTitle = (item: Item) =>
  item.entity === "project" || item.entity === "section" ? item.record.name : item.entity === "task" ? item.record.title : item.taskTitle;

/**
 * Writes a slice of an import for one user through the Mutator, so every write has
 * the app's access checks and a change row that devices pull.
 *
 * Each record's source key maps to a Zimam id in `external_refs`. A record seen
 * before is updated in place, unless it was edited or deleted in Zimam after the
 * last import (its `updated_at` is past the ref's `synced_at`): then Zimam's version
 * wins and the record is skipped. Identical records are not written at all, so a
 * repeated import writes no change rows.
 *
 * Refs are written before the records, so a slice retried after a crash reuses the
 * same ids instead of making copies.
 */
export class Importer {
  private readonly mutator: Mutator;

  constructor(
    private readonly db: D1Database,
    private readonly userId: string,
    private readonly refSource: string,
  ) {
    this.mutator = new Mutator(db, new Access(db, userId));
  }

  /** What a key is stored as: native ids as they are, keys built from names as their hash. */
  private async externalId(key: string): Promise<string> {
    return isDerivedKey(key) ? `h:${await sha256Hex(key)}` : key;
  }

  async apply(items: Item[], now = Date.now()): Promise<ChunkResult> {
    const counts: CountsByEntity = {};
    const errors: ItemError[] = [];
    const count = (entity: ImportEntity, kind: keyof Counts) => {
      const c = (counts[entity] ??= { created: 0, updated: 0, unchanged: 0, skipped: 0, failed: 0 });
      c[kind]++;
    };

    // Source keys → stored external ids → refs → current rows.
    const external = new Map<string, string>();
    for (const key of new Set(items.flatMap(itemKeys).filter((k): k is string => k !== null))) {
      external.set(key, await this.externalId(key));
    }
    const refs = new Map<string, Ref>();
    const { results: refRows } = await this.db
      .prepare(
        `SELECT external_id, entity, entity_id, synced_at FROM external_refs
         WHERE user_id = ?1 AND source = ?2 AND external_id IN (SELECT value FROM json_each(?3))`,
      )
      .bind(this.userId, this.refSource, JSON.stringify([...new Set(external.values())]))
      .all<Ref>();
    for (const ref of refRows) refs.set(ref.external_id, ref);

    const rows = new Map<string, Row>();
    const idsByEntity = new Map<string, string[]>();
    for (const ref of refs.values()) idsByEntity.set(ref.entity, [...(idsByEntity.get(ref.entity) ?? []), ref.entity_id]);
    for (const [entity, ids] of idsByEntity) {
      const table = TABLES[entity as ImportEntity];
      if (!table) continue;
      const { results } = await this.db
        .prepare(`SELECT * FROM ${table} WHERE id IN (SELECT value FROM json_each(?))`)
        .bind(JSON.stringify(ids))
        .all<Row>();
      for (const row of results) rows.set(`${entity}:${row.id}`, row);
    }

    const refFor = (key: string | null, entity: ImportEntity) => {
      const ref = key ? refs.get(external.get(key)!) : undefined;
      return ref && ref.entity === entity ? ref : undefined;
    };
    /** The Zimam id of an earlier record, and whether it still exists there. */
    const resolve = (key: string | null, entity: ImportEntity): { id: string; alive: boolean } | null => {
      const ref = refFor(key, entity);
      if (!ref) return null;
      const row = rows.get(`${entity}:${ref.entity_id}`);
      // No row: written earlier in this slice, or its write failed (then the dependant fails too).
      return { id: ref.entity_id, alive: !row || row.deleted_at == null };
    };

    type Plan = { item: Item; id: string; existing: Row | null; updatedAt: number; data: Record<string, unknown> };
    const plans: Plan[] = [];
    for (const item of items) {
      const ref = refFor(item.record.key, item.entity);
      const existing = ref ? (rows.get(`${item.entity}:${ref.entity_id}`) ?? null) : null;
      if (existing && (existing.deleted_at != null || (existing.updated_at as number) > ref!.synced_at)) {
        count(item.entity, "skipped");
        continue;
      }
      const id = ref?.entity_id ?? crypto.randomUUID();
      const updatedAt = existing ? Math.max(now, (existing.updated_at as number) + 1) : now;
      const data = this.data(item, id, existing, updatedAt, resolve);
      if (data === null) {
        count(item.entity, "skipped");
        continue;
      }
      if (existing && same(item.entity, data, existing)) {
        count(item.entity, "unchanged");
        continue;
      }
      // Later items in this slice resolve this key to the new id.
      if (!ref) refs.set(external.get(item.record.key)!, { external_id: external.get(item.record.key)!, entity: item.entity, entity_id: id, synced_at: updatedAt });
      plans.push({ item, id, existing, updatedAt, data });
    }

    if (plans.length > 0) {
      await this.db.batch(
        plans.map((p) =>
          this.db
            .prepare(
              `INSERT INTO external_refs (user_id, source, external_id, entity, entity_id, synced_at) VALUES (?, ?, ?, ?, ?, ?)
               ON CONFLICT (user_id, source, external_id) DO UPDATE SET
                 entity = excluded.entity, entity_id = excluded.entity_id, synced_at = excluded.synced_at`,
            )
            .bind(this.userId, this.refSource, external.get(p.item.record.key)!, p.item.entity, p.id, p.updatedAt),
        ),
      );
    }

    for (const p of plans) {
      const result = await this.mutator.apply({ op: "upsert", entity: p.item.entity, data: p.data });
      if (result.status === "applied") count(p.item.entity, p.existing ? "updated" : "created");
      else if (result.status === "stale" || result.status === "gone") count(p.item.entity, "skipped");
      else {
        count(p.item.entity, "failed");
        errors.push({
          entity: p.item.entity,
          title: itemTitle(p.item),
          message: `تعذّر استيراد ${ENTITY_NAMES[p.item.entity]} «${itemTitle(p.item)}»: ${REASONS[result.status] ?? REASONS.invalid}.`,
        });
      }
    }
    return { counts, errors };
  }

  /** The Mutator input for an item, or null when what it belongs to was deleted in Zimam. */
  private data(
    item: Item,
    id: string,
    existing: Row | null,
    updatedAt: number,
    resolve: (key: string | null, entity: ImportEntity) => { id: string; alive: boolean } | null,
  ): Record<string, unknown> | null {
    switch (item.entity) {
      case "project": {
        const p = item.record;
        const parent = resolve(p.parentKey, "project");
        return {
          id,
          parentId: parent?.alive ? parent.id : null,
          kind: p.kind,
          name: p.name,
          view: p.view,
          sortOrder: p.sortOrder,
          archivedAt: p.archived ? ((existing?.archived_at as number | null) ?? updatedAt) : null,
          updatedAt,
        };
      }
      case "section": {
        const project = resolve(item.record.projectKey, "project");
        if (!project?.alive) return null;
        return { id, projectId: project.id, name: item.record.name, sortOrder: item.record.sortOrder, updatedAt };
      }
      case "task": {
        const t = item.record;
        let projectId: string | null = null;
        if (t.projectKey) {
          const project = resolve(t.projectKey, "project");
          if (!project?.alive) return null;
          projectId = project.id;
        }
        let parentId: string | null = null;
        if (t.parentKey) {
          const parent = resolve(t.parentKey, "task");
          if (!parent?.alive) return null;
          parentId = parent.id;
        }
        const section = resolve(t.sectionKey, "section");
        return {
          id,
          projectId,
          sectionId: section?.alive ? section.id : null,
          parentId,
          title: t.title,
          notes: t.notes,
          status: t.done ? "done" : "todo",
          priority: t.priority,
          tags: t.tags,
          dueDate: t.dueDate,
          dueTime: t.dueTime,
          // What the source has no field for stays as the user set it.
          duePrayer: (existing?.due_prayer as string | null) ?? null,
          duePrayerOffset: (existing?.due_prayer_offset as number | null) ?? null,
          assigneeId: (existing?.assignee_id as string | null) ?? null,
          recurrence: t.recurrence,
          sortOrder: t.sortOrder,
          completedAt: t.done ? (t.completedAt ?? (existing?.completed_at as number | null) ?? null) : null,
          updatedAt,
        };
      }
      case "reminder": {
        const task = resolve(item.taskKey, "task");
        if (!task?.alive) return null;
        return { id, taskId: task.id, kind: "time", at: item.record.at, updatedAt };
      }
    }
  }
}

/** Whether a write would change nothing the source controls. */
function same(entity: ImportEntity, d: Record<string, unknown>, row: Row): boolean {
  const eq = (a: unknown, b: unknown) => (a ?? null) === (b ?? null);
  switch (entity) {
    case "project":
      return (
        eq(d.name, row.name) && eq(d.kind, row.kind) && eq(d.parentId, row.parent_id) && eq(d.view, row.view) &&
        eq(d.sortOrder, row.sort_order) && (d.archivedAt === null) === (row.archived_at == null)
      );
    case "section":
      return eq(d.name, row.name) && eq(d.sortOrder, row.sort_order);
    case "task":
      return (
        eq(d.projectId, row.project_id) && eq(d.sectionId, row.section_id) && eq(d.parentId, row.parent_id) &&
        eq(d.title, row.title) && eq(d.notes, row.notes) && eq(d.status, row.status) && eq(d.priority, row.priority) &&
        JSON.stringify(d.tags) === row.tags && eq(d.dueDate, row.due_date) && eq(d.dueTime, row.due_time) &&
        eq(d.recurrence, row.recurrence) && eq(d.sortOrder, row.sort_order) &&
        (d.completedAt === null || eq(d.completedAt, row.completed_at))
      );
    case "reminder":
      return Date.parse(d.at as string) === Date.parse(row.at as string) && row.kind === "time";
  }
}
