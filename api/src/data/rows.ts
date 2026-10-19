import { type ChangeEntity, DEFAULT_SETTINGS, Settings } from "./schemas";

export type Row = Record<string, unknown>;

export const TABLES: Record<ChangeEntity, string> = {
  project: "projects",
  section: "sections",
  task: "tasks",
  reminder: "reminders",
  comment: "comments",
  place: "places",
  attachment: "attachments",
};

const str = (v: unknown) => v as string;
const strOrNull = (v: unknown) => (v ?? null) as string | null;
const num = (v: unknown) => v as number;
const numOrNull = (v: unknown) => (v ?? null) as number | null;
const json = (v: unknown) => (v == null ? null : JSON.parse(v as string));

export function projectOut(r: Row) {
  return {
    id: str(r.id),
    ownerId: str(r.owner_id),
    parentId: strOrNull(r.parent_id),
    kind: str(r.kind),
    name: str(r.name),
    view: str(r.view),
    sortOrder: num(r.sort_order),
    archivedAt: numOrNull(r.archived_at),
    createdAt: num(r.created_at),
    updatedAt: num(r.updated_at),
  };
}

export function sectionOut(r: Row) {
  return {
    id: str(r.id),
    projectId: str(r.project_id),
    name: str(r.name),
    sortOrder: num(r.sort_order),
    createdAt: num(r.created_at),
    updatedAt: num(r.updated_at),
  };
}

export function taskOut(r: Row) {
  return {
    id: str(r.id),
    ownerId: str(r.owner_id),
    projectId: strOrNull(r.project_id),
    sectionId: strOrNull(r.section_id),
    parentId: strOrNull(r.parent_id),
    title: str(r.title),
    notes: strOrNull(r.notes),
    status: str(r.status),
    priority: num(r.priority),
    tags: json(r.tags) as string[],
    dueDate: strOrNull(r.due_date),
    startDate: strOrNull(r.start_date),
    dueTime: strOrNull(r.due_time),
    duePrayer: strOrNull(r.due_prayer),
    duePrayerOffset: numOrNull(r.due_prayer_offset),
    recurrence: strOrNull(r.recurrence),
    assigneeId: strOrNull(r.assignee_id),
    sortOrder: num(r.sort_order),
    completedAt: numOrNull(r.completed_at),
    createdAt: num(r.created_at),
    updatedAt: num(r.updated_at),
  };
}

export function reminderOut(r: Row) {
  return {
    id: str(r.id),
    taskId: str(r.task_id),
    kind: str(r.kind),
    at: strOrNull(r.at),
    prayer: strOrNull(r.prayer),
    offsetMinutes: numOrNull(r.offset_minutes),
    location: json(r.location),
    firedAt: numOrNull(r.fired_at),
    createdAt: num(r.created_at),
    updatedAt: num(r.updated_at),
  };
}

export function commentOut(r: Row) {
  return {
    id: str(r.id),
    taskId: str(r.task_id),
    authorId: str(r.author_id),
    body: str(r.body),
    createdAt: num(r.created_at),
    updatedAt: num(r.updated_at),
  };
}

export function placeOut(r: Row) {
  return {
    id: str(r.id),
    name: str(r.name),
    latitude: num(r.latitude),
    longitude: num(r.longitude),
    radius: num(r.radius),
    createdAt: num(r.created_at),
    updatedAt: num(r.updated_at),
  };
}

/** An attachment's metadata; the file itself is GET /v1/attachments/:id. */
export function attachmentOut(r: Row) {
  return {
    id: str(r.id),
    taskId: str(r.task_id),
    projectId: strOrNull(r.project_id),
    uploaderId: str(r.user_id),
    fileName: str(r.file_name),
    contentType: str(r.content_type),
    size: num(r.size),
    createdAt: num(r.created_at),
    updatedAt: num(r.updated_at),
  };
}

export const OUT: Record<ChangeEntity, (r: Row) => Record<string, unknown>> = {
  project: projectOut,
  section: sectionOut,
  task: taskOut,
  reminder: reminderOut,
  comment: commentOut,
  place: placeOut,
  attachment: attachmentOut,
};

export function userOut(r: Row) {
  const stored = Settings.partial().safeParse(json(r.settings));
  return {
    id: str(r.id),
    name: strOrNull(r.name),
    email: strOrNull(r.email),
    settings: { ...DEFAULT_SETTINGS, ...(stored.success ? stored.data : {}) },
  };
}
