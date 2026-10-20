import { z } from "zod";

export const ENTITIES = ["project", "section", "task", "reminder", "comment", "place"] as const;
export type EntityName = (typeof ENTITIES)[number];

/**
 * Entities in the change log: the synced ones, and attachments, which their own routes write
 * (src/routes/attachments.ts). Clients pull attachments and saved places only when they ask
 * (`include=attachment`, `include=place`), because apps built before them cannot decode an
 * entity they do not know.
 */
export const CHANGE_ENTITIES = [...ENTITIES, "attachment"] as const;
export type ChangeEntity = (typeof CHANGE_ENTITIES)[number];
export const OPT_IN_ENTITIES: readonly ChangeEntity[] = ["attachment", "place"];

export const PRAYERS = ["fajr", "dhuhr", "asr", "maghrib", "isha"] as const;

/**
 * How a project opens. "timeline" («المخطط الزمني», migrations/0012) is newer than the apps that
 * decode `view` strictly, so a pull sends it only to clients that ask (`include=timeline`) and
 * "list" to the rest (src/data/pull.ts).
 */
export const PROJECT_VIEWS = ["list", "kanban", "calendar", "timeline"] as const;
export const OPT_IN_VIEWS: readonly string[] = ["timeline"];

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
  view: z.enum(PROJECT_VIEWS).default("list"),
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

export const TaskInput = z
  .object({
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
    /**
     * The first day of a task that spans days, up to `dueDate`; null for a one-day task. Left out
     * (apps that predate it) keeps the stored one, which the server drops if the due day no
     * longer allows it (src/data/mutations.ts).
     */
    startDate: z.iso.date().nullable().optional(),
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
  })
  .refine((t) => t.startDate == null || (t.dueDate !== null && t.startDate <= t.dueDate), {
    message: "startDate needs a dueDate on or after it",
    path: ["startDate"],
  });
export type TaskInput = z.infer<typeof TaskInput>;

const Latitude = z.number().min(-90).max(90);
const Longitude = z.number().min(-180).max(180);
/** Meters around a place that count as being there. */
const Radius = z.number().min(50).max(10_000);

const Location = z.object({
  latitude: Latitude,
  longitude: Longitude,
  radius: Radius,
  name: z.string().max(200).nullable().default(null),
  trigger: z.enum(["arrive", "leave"]),
  /**
   * The saved place this copy came from, if any. The server keeps the copy in step when the
   * place changes, and clears this when the place is deleted or is not the user's.
   */
  placeId: NullableId,
});

export const ReminderInput = z
  .object({
    id: Id,
    taskId: Id,
    kind: z.enum(["time", "prayer", "location"]),
    /**
     * ISO 8601 date-time with offset, for kind "time". On a "location" reminder it is the time
     * that competes with the place: the reminder fires once, at whichever comes first.
     */
    at: z.iso.datetime({ offset: true }).nullable().default(null),
    prayer: z.enum(PRAYERS).nullable().default(null),
    offsetMinutes: z.number().int().min(-720).max(720).nullable().default(null),
    location: Location.nullable().default(null),
    /**
     * When a location reminder with a time fired at the place, before its time (Unix ms). Left
     * out (apps that predate it) keeps the stored value.
     */
    firedAt: Timestamp.nullable().optional(),
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

/** A saved place («أماكني»), personal to its owner. */
export const PlaceInput = z.object({
  id: Id,
  name: z.string().trim().min(1).max(200),
  latitude: Latitude,
  longitude: Longitude,
  radius: Radius,
  updatedAt: Timestamp,
});
export type PlaceInput = z.infer<typeof PlaceInput>;

export const Mutation = z.discriminatedUnion("op", [
  z.object({ op: z.literal("upsert"), entity: z.enum(ENTITIES), data: z.record(z.string(), z.unknown()) }),
  z.object({ op: z.literal("delete"), entity: z.enum(ENTITIES), id: Id, updatedAt: Timestamp }),
]);
export type Mutation = z.infer<typeof Mutation>;

/** One prayer's alerts: at the adhan, and before the iqama after `iqamaMinutes`. */
export const PrayerAlert = z.object({
  adhan: z.boolean(),
  iqama: z.boolean(),
  iqamaMinutes: z.number().int().min(5).max(60),
});
export type PrayerAlert = z.infer<typeof PrayerAlert>;

export const Settings = z.object({
  /** The calendar shown first; the other one is always shown beside it. */
  calendar: z.enum(["hijri", "gregorian"]),
  prayerMethod: z.enum(["ummAlQura", "muslimWorldLeague", "egyptian", "karachi", "dubai", "kuwait", "qatar", "northAmerica"]),
  /** Asr at one shadow length (shafi: the majority) or two (hanafi). */
  asrMadhab: z.enum(["shafi", "hanafi"]),
  /** Adhan and iqama alerts per prayer; the device schedules them. A missing prayer has none. */
  prayerAlerts: z
    .object({
      fajr: PrayerAlert.optional(),
      dhuhr: PrayerAlert.optional(),
      asr: PrayerAlert.optional(),
      maghrib: PrayerAlert.optional(),
      isha: PrayerAlert.optional(),
    })
    .strict(),
  /** 0 = Sunday. */
  weekStart: z.number().int().min(0).max(6),
  /** IANA zone the user's days start in, for agendas built on the server (MCP). */
  timeZone: z.string().refine(isTimeZone, "Unknown time zone"),
  /** Where prayer times are computed for server-built agendas; the app sends it when allowed. */
  location: z
    .object({ latitude: z.number().min(-90).max(90), longitude: z.number().min(-180).max(180) })
    .nullable(),
});
export type Settings = z.infer<typeof Settings>;

export const DEFAULT_SETTINGS: Settings = {
  calendar: "hijri",
  prayerMethod: "ummAlQura",
  asrMadhab: "shafi",
  prayerAlerts: {},
  weekStart: 0,
  timeZone: "Asia/Riyadh",
  location: null,
};

function isTimeZone(zone: string): boolean {
  try {
    new Intl.DateTimeFormat("en", { timeZone: zone });
    return true;
  } catch {
    return false;
  }
}
