import { z } from "zod";

export const ENTITIES = ["project", "section", "task", "reminder", "comment"] as const;
export type EntityName = (typeof ENTITIES)[number];

export const PRAYERS = ["fajr", "dhuhr", "asr", "maghrib", "isha"] as const;

/** Swift sends uppercase UUIDs; the server stores them lowercase. */
export const Id = z.uuid().transform((s) => s.toLowerCase());
const NullableId = Id.nullable().default(null);
/** Unix milliseconds set by the client when it last edited the record. */
const Timestamp = z.number().int().nonnegative();
const SortOrder = z.number().finite().default(0);

export const ProjectInput = z.object({
  id: Id,
  parentId: NullableId,
  kind: z.enum(["project", "folder"]).default("project"),
  name: z.string().trim().min(1).max(200),
  view: z.enum(["list", "kanban", "calendar"]).default("list"),
  sortOrder: SortOrder,
  archivedAt: Timestamp.nullable().default(null),
  updatedAt: Timestamp,
});
export type ProjectInput = z.infer<typeof ProjectInput>;

export const SectionInput = z.object({
  id: Id,
  projectId: Id,
  name: z.string().trim().min(1).max(100),
  sortOrder: SortOrder,
  updatedAt: Timestamp,
});
export type SectionInput = z.infer<typeof SectionInput>;

export const TaskInput = z.object({
  id: Id,
  projectId: NullableId,
  sectionId: NullableId,
  parentId: NullableId,
  title: z.string().trim().min(1).max(500),
  notes: z.string().max(20_000).nullable().default(null),
  status: z.enum(["todo", "doing", "done"]).default("todo"),
  /** 0 none, 1 low, 2 medium, 3 high. */
  priority: z.number().int().min(0).max(3).default(0),
  tags: z.array(z.string().trim().min(1).max(50)).max(30).default([]),
  dueDate: z.iso.date().nullable().default(null),
  dueTime: z
    .string()
    .regex(/^([01]\d|2[0-3]):[0-5]\d$/)
    .nullable()
    .default(null),
  duePrayer: z.enum(PRAYERS).nullable().default(null),
  /** Minutes after (positive) or before (negative) the prayer. */
  duePrayerOffset: z.number().int().min(-720).max(720).nullable().default(null),
  /** RFC 5545 RRULE, e.g. "FREQ=WEEKLY;BYDAY=TH". */
  recurrence: z.string().max(500).nullable().default(null),
  assigneeId: NullableId,
  sortOrder: SortOrder,
  completedAt: Timestamp.nullable().default(null),
  updatedAt: Timestamp,
});
export type TaskInput = z.infer<typeof TaskInput>;

const Location = z.object({
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
  radius: z.number().min(50).max(10_000),
  name: z.string().max(200).nullable().default(null),
  trigger: z.enum(["arrive", "leave"]),
});

export const ReminderInput = z
  .object({
    id: Id,
    taskId: Id,
    kind: z.enum(["time", "prayer", "location"]),
    /** ISO 8601 date-time with offset, for kind "time". */
    at: z.iso.datetime({ offset: true }).nullable().default(null),
    prayer: z.enum(PRAYERS).nullable().default(null),
    offsetMinutes: z.number().int().min(-720).max(720).nullable().default(null),
    location: Location.nullable().default(null),
    updatedAt: Timestamp,
  })
  .refine(
    (r) =>
      (r.kind === "time" && r.at !== null) ||
      (r.kind === "prayer" && r.prayer !== null) ||
      (r.kind === "location" && r.location !== null),
    { message: "A reminder needs the field that matches its kind" },
  );
export type ReminderInput = z.infer<typeof ReminderInput>;

export const CommentInput = z.object({
  id: Id,
  taskId: Id,
  body: z.string().trim().min(1).max(5_000),
  updatedAt: Timestamp,
});
export type CommentInput = z.infer<typeof CommentInput>;

export const Mutation = z.discriminatedUnion("op", [
  z.object({ op: z.literal("upsert"), entity: z.enum(ENTITIES), data: z.record(z.string(), z.unknown()) }),
  z.object({ op: z.literal("delete"), entity: z.enum(ENTITIES), id: Id, updatedAt: Timestamp }),
]);
export type Mutation = z.infer<typeof Mutation>;

export const Settings = z.object({
  /** The calendar shown first; the other one is always shown beside it. */
  calendar: z.enum(["hijri", "gregorian"]),
  prayerMethod: z.enum(["ummAlQura", "muslimWorldLeague", "egyptian", "karachi", "dubai", "kuwait", "qatar", "northAmerica"]),
  /** 0 = Sunday. */
  weekStart: z.number().int().min(0).max(6),
});
export type Settings = z.infer<typeof Settings>;

export const DEFAULT_SETTINGS: Settings = { calendar: "hijri", prayerMethod: "ummAlQura", weekStart: 0 };
