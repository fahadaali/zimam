import type { JWTVerifyGetKey } from "jose";
import { z } from "zod";
import { type AppleCode, storeAppleRefreshToken } from "./auth/account";
import { verifyAppleToken } from "./auth/apple";
import { type AppleTokens, appleRedirectUris } from "./auth/apple-tokens";
import { googleAudiences, verifyGoogleToken } from "./auth/google";
import { appleAudiences, signInUser } from "./auth/users";
import { Access } from "./data/access";
import { foldForSearch } from "./data/arabic";
import { addDays, dayIn, dualText, gregorianText, hijriText, localDateTime, weekdayText } from "./data/dates";
import { Mutator } from "./data/mutations";
import { prayerPhrase, prayerTimes, type PrayerTimesOfDay } from "./data/prayers";
import { listProjects, listTasks } from "./data/queries";
import { followMove, nextOccurrence } from "./data/recurrence";
import { reminderOut, type Row, taskOut, userOut } from "./data/rows";
import { Id, PRAYERS } from "./data/schemas";
import type { Env } from "./env";

/**
 * What assistants (the MCP server) can do with a user's tasks. Answers are shaped for a
 * language model: names instead of codes, dates in both calendars, prayer times in words.
 * Every method takes the user id the MCP OAuth grant was issued for.
 */

export type Outcome<T> = { ok: true; value: T } | { ok: false; error: { code: string; message: string } };

const ok = <T>(value: T): Outcome<T> => ({ ok: true, value });
const fail = <T>(code: string, message: string): Outcome<T> => ({ ok: false, error: { code, message } });

const PRIORITIES = ["none", "low", "medium", "high"] as const;
type PriorityName = (typeof PRIORITIES)[number];

export interface AssistantTask {
  id: string;
  title: string;
  notes: string | null;
  status: "todo" | "doing" | "done";
  priority: PriorityName;
  tags: string[];
  projectId: string | null;
  project: string | null;
  parentId: string | null;
  due: { date: string; time: string | null; hijri: string; gregorian: string } | null;
  /** The first day of a task that spans days, up to `due`; null for a one-day task. */
  start: { date: string; hijri: string; gregorian: string } | null;
  prayer: { prayer: string; offsetMinutes: number; text: string } | null;
  recurrence: string | null;
  completedAt: string | null;
}

export interface AssistantProject {
  id: string;
  name: string;
  kind: string;
  role: string;
  view: string;
  taskCount: number;
  doneCount: number;
}

/** A saved place («أماكني»). Coordinates stay out: the assistant only names places. */
export interface AssistantPlace {
  id: string;
  name: string;
  radiusMeters: number;
}

/** A location reminder: on arriving at or leaving a saved place, or at a time, whichever comes first. */
export interface AssistantPlaceReminder {
  id: string;
  taskId: string;
  place: string;
  trigger: "arrive" | "leave";
  /** Also at this time; the reminder fires once, at whichever comes first. */
  at: { date: string; time: string; hijri: string; gregorian: string } | null;
  text: string;
}

export interface AgendaDay {
  date: string;
  weekday: string;
  /** Both calendars, the user's primary first. */
  label: string;
  hijri: string;
  gregorian: string;
  prayers: PrayerTimesOfDay | null;
  tasks: AssistantTask[];
}

export interface Agenda {
  timeZone: string;
  hasLocation: boolean;
  overdue: AssistantTask[];
  days: AgendaDay[];
}

export const TaskFilter = z.object({
  projectId: z.union([z.literal("inbox"), Id]).optional(),
  status: z.enum(["open", "done", "all"]).default("open"),
  from: z.iso.date().optional(),
  to: z.iso.date().optional(),
  query: z.string().trim().min(1).max(200).optional(),
  limit: z.number().int().min(1).max(200).default(50),
});
export type TaskFilter = z.input<typeof TaskFilter>;

export const TaskFields = z.object({
  title: z.string().trim().min(1).max(500).optional(),
  notes: z.string().max(20_000).nullable().optional(),
  projectId: Id.nullable().optional(),
  parentId: Id.nullable().optional(),
  dueDate: z.iso.date().nullable().optional(),
  startDate: z.iso.date().nullable().optional(),
  dueTime: z
    .string()
    .regex(/^([01]\d|2[0-3]):[0-5]\d$/)
    .nullable()
    .optional(),
  duePrayer: z.enum(PRAYERS).nullable().optional(),
  duePrayerOffset: z.number().int().min(-720).max(720).nullable().optional(),
  priority: z.enum(PRIORITIES).optional(),
  tags: z.array(z.string().trim().min(1).max(50)).max(30).optional(),
  status: z.enum(["todo", "doing", "done"]).optional(),
  recurrence: z.string().max(500).nullable().optional(),
});
export type TaskFields = z.input<typeof TaskFields>;

export const PlaceReminderRequest = z.object({
  taskId: z.string(),
  /** A saved place's id or name. */
  place: z.string().trim().min(1).max(200),
  trigger: z.enum(["arrive", "leave"]).default("arrive"),
  /** Optional local day and time: the reminder then fires at whichever comes first. */
  date: z.iso.date().optional(),
  time: z
    .string()
    .regex(/^([01]\d|2[0-3]):[0-5]\d$/)
    .optional(),
});
export type PlaceReminderRequest = z.input<typeof PlaceReminderRequest>;

export const AgendaRequest = z.object({
  from: z.iso.date().optional(),
  days: z.number().int().min(1).max(14).default(1),
});
export type AgendaRequest = z.input<typeof AgendaRequest>;

function issues(error: z.ZodError): string {
  return error.issues.map((i) => `${i.path.join(".") || "input"}: ${i.message}`).join("; ");
}

/** The providers' token signing keys; tests pass local key sets. */
export interface SignInKeys {
  apple: JWTVerifyGetKey;
  google: JWTVerifyGetKey;
}

export class Assistant {
  constructor(
    private readonly env: Env,
    private readonly keys: SignInKeys,
    /** Sign in with Apple's token endpoint, to keep the refresh token account deletion revokes. */
    private readonly appleTokens: (env: Env) => AppleTokens | null = () => null,
  ) {}

  private get db() {
    return this.env.DB;
  }

  /**
   * Verifies a Sign in with Apple identity token from the web and returns the Zimam user.
   * With the page's authorization code (and the redirect URI it used), keeps Apple's refresh
   * token as `/v1/auth/apple` does; that never blocks signing in.
   */
  async signInWithApple(
    identityToken: string,
    nonce: string,
    code?: AppleCode,
  ): Promise<Outcome<{ userId: string; name: string | null }>> {
    let identity;
    try {
      identity = await verifyAppleToken(identityToken, this.keys.apple, appleAudiences(this.env.APPLE_AUDIENCES), nonce);
    } catch {
      return fail("invalid_token", "Apple identity token was rejected");
    }
    const user = await signInUser(this.db, { provider: "apple", ...identity }, null);
    if (code?.authorizationCode) {
      await storeAppleRefreshToken(this.db, this.appleTokens(this.env), user.id as string, identity, code, appleRedirectUris(this.env));
    }
    return ok({ userId: user.id as string, name: (user.name as string | null) ?? null });
  }

  /**
   * Verifies a Google ID token from the web (its nonce claim is the SHA-256 of `nonce`) and
   * returns the Zimam user, joining an existing account by verified email as the API does.
   */
  async signInWithGoogle(idToken: string, nonce: string): Promise<Outcome<{ userId: string; name: string | null }>> {
    const audiences = googleAudiences(this.env.GOOGLE_CLIENT_IDS);
    if (audiences.length === 0) return fail("google_unavailable", "Sign in with Google is not configured");
    let identity;
    try {
      identity = await verifyGoogleToken(idToken, this.keys.google, audiences, nonce);
    } catch {
      return fail("invalid_token", "Google ID token was rejected");
    }
    const user = await signInUser(this.db, { provider: "google", ...identity }, identity.name);
    return ok({ userId: user.id as string, name: (user.name as string | null) ?? null });
  }

  async listTasks(userId: string, filter: TaskFilter): Promise<Outcome<AssistantTask[]>> {
    const parsed = TaskFilter.safeParse(filter);
    if (!parsed.success) return fail("invalid", issues(parsed.error));
    if (!(await this.activeUser(userId))) return this.gone();
    const f = parsed.data;
    const rows = await listTasks(this.db, userId, {
      projectId: f.projectId,
      status: f.status === "all" ? undefined : f.status,
      dueFrom: f.from,
      dueTo: f.to,
      q: f.query,
      limit: f.limit,
      offset: 0,
    });
    return ok(await this.present(userId, rows));
  }

  async createTask(userId: string, fields: TaskFields): Promise<Outcome<AssistantTask>> {
    const parsed = TaskFields.safeParse(fields);
    if (!parsed.success) return fail("invalid", issues(parsed.error));
    if (!parsed.data.title) return fail("invalid", "title is required");
    if (!(await this.activeUser(userId))) return this.gone();
    const id = crypto.randomUUID();
    const data = { ...toTaskInput(parsed.data), id, updatedAt: Date.now() };
    const created = await this.write(userId, id, data);
    // A task with a time gets «عند الموعد» for whoever added it, as in the app.
    if (created.ok && (created.value.due?.time || created.value.prayer)) {
      await new Mutator(this.db, new Access(this.db, userId)).apply({
        op: "upsert",
        entity: "reminder",
        data: { id: crypto.randomUUID(), taskId: id, kind: "relative", offsetMinutes: 0, updatedAt: Date.now() },
      });
    }
    return created;
  }

  async updateTask(userId: string, id: string, fields: TaskFields): Promise<Outcome<AssistantTask>> {
    const parsed = TaskFields.safeParse(fields);
    if (!parsed.success) return fail("invalid", issues(parsed.error));
    const row = await this.visibleTask(userId, id);
    if (!row) return fail("not_found", "Task not found");
    const current = taskOut(row);
    const changes = toTaskInput(parsed.data);
    const data = {
      ...current,
      ...changes,
      ...followMove(current, changes),
      id: row.id as string,
      updatedAt: Math.max(Date.now(), (row.updated_at as number) + 1),
    };
    const written = await this.write(userId, row.id as string, data);
    // Completing a repeating task adds its next occurrence, as the apps do when the user ticks it.
    // The completion is stored by then, so a failure here is logged and the completion still
    // answered: reported as a failure, a retry would find the task done and add nothing either.
    if (written.ok && row.status !== "done" && written.value.status === "done" && written.value.recurrence) {
      try {
        await this.addNextOccurrence(userId, row.id as string);
      } catch (error) {
        console.error("assistant: could not add the next occurrence", error);
      }
    }
    return written;
  }

  async completeTask(userId: string, id: string): Promise<Outcome<AssistantTask>> {
    return this.updateTask(userId, id, { status: "done" });
  }

  async listProjects(userId: string): Promise<Outcome<AssistantProject[]>> {
    if (!(await this.activeUser(userId))) return this.gone();
    const rows = await listProjects(this.db, userId);
    return ok(
      rows.map((r) => ({
        id: r.id as string,
        name: r.name as string,
        kind: r.kind as string,
        role: r.role as string,
        view: r.view as string,
        taskCount: r.total as number,
        doneCount: r.done as number,
      })),
    );
  }

  async listPlaces(userId: string): Promise<Outcome<AssistantPlace[]>> {
    if (!(await this.activeUser(userId))) return this.gone();
    const { results } = await this.db
      .prepare(`SELECT id, name, radius FROM places WHERE user_id = ? AND deleted_at IS NULL ORDER BY name`)
      .bind(userId)
      .all<{ id: string; name: string; radius: number }>();
    return ok(results.map((p) => ({ id: p.id, name: p.name, radiusMeters: p.radius })));
  }

  /**
   * Reminds the user about a task on arriving at or leaving one of their saved places, and
   * optionally at a time too, whichever comes first. Places are added in the app, where the
   * user picks them on the map; an assistant only refers to them by id or name.
   */
  async addPlaceReminder(userId: string, request: PlaceReminderRequest): Promise<Outcome<AssistantPlaceReminder>> {
    const parsed = PlaceReminderRequest.safeParse(request);
    if (!parsed.success) return fail("invalid", issues(parsed.error));
    const { taskId, trigger, date, time } = parsed.data;
    if (time && !date) return fail("invalid", "time needs a date");
    const user = await this.activeUser(userId);
    if (!user) return this.gone();
    const task = await this.visibleTask(userId, taskId);
    if (!task) return fail("not_found", "Task not found");

    const { results: places } = await this.db
      .prepare(`SELECT * FROM places WHERE user_id = ? AND deleted_at IS NULL`)
      .bind(userId)
      .all<Row>();
    const wanted = parsed.data.place.toLowerCase();
    const folded = foldForSearch(parsed.data.place);
    const place =
      places.find((p) => p.id === wanted) ?? places.find((p) => foldForSearch(p.name as string) === folded);
    if (!place) {
      const names = places.map((p) => `«${p.name}»`).join("، ") || "none";
      return fail(
        "not_found",
        `No saved place named «${parsed.data.place}». Saved places: ${names}. The user adds places in the Zimam app (Settings, «أماكني»).`,
      );
    }

    const settings = userOut(user).settings;
    const at = date ? localDateTime(date, time ?? "09:00", settings.timeZone) : null;
    const id = crypto.randomUUID();
    const location = {
      latitude: place.latitude,
      longitude: place.longitude,
      radius: place.radius,
      name: place.name,
      trigger,
      placeId: place.id,
    };
    const result = await new Mutator(this.db, new Access(this.db, userId)).apply({
      op: "upsert",
      entity: "reminder",
      data: { id, taskId: task.id, kind: "location", location, at, updatedAt: Date.now() },
    });
    if (result.status !== "applied") return fail(result.status, result.message ?? result.status);

    const name = place.name as string;
    const action = trigger === "arrive" ? `عند الوصول إلى ${name}` : `عند مغادرة ${name}`;
    const day = date ?? null;
    return ok({
      id,
      taskId: task.id as string,
      place: name,
      trigger,
      at: day ? { date: day, time: time ?? "09:00", hijri: hijriText(day), gregorian: gregorianText(day) } : null,
      text: day ? `${action} أو في الوقت المحدد، أيهما أسبق` : action,
    });
  }

  /** Days from `from` (today in the user's zone by default), with prayer times and the tasks due on each. */
  async getAgenda(userId: string, request: AgendaRequest): Promise<Outcome<Agenda>> {
    const parsed = AgendaRequest.safeParse(request);
    if (!parsed.success) return fail("invalid", issues(parsed.error));
    const user = await this.activeUser(userId);
    if (!user) return this.gone();
    const settings = userOut(user).settings;
    const today = dayIn(settings.timeZone);
    const from = parsed.data.from ?? today;
    const to = addDays(from, parsed.data.days - 1);

    const dated = await listTasks(this.db, userId, { dueFrom: from, dueTo: to, limit: 500, offset: 0 });
    const overdueRows =
      from <= today
        ? await listTasks(this.db, userId, { status: "open", dueTo: addDays(from, -1), limit: 100, offset: 0 })
        : [];
    const tasks = await this.present(userId, dated);
    const overdue = await this.present(userId, overdueRows);

    const days: AgendaDay[] = [];
    for (let i = 0; i < parsed.data.days; i++) {
      const date = addDays(from, i);
      days.push({
        date,
        weekday: weekdayText(date),
        label: dualText(date, settings.calendar),
        hijri: hijriText(date),
        gregorian: gregorianText(date),
        prayers: prayerTimes(date, settings),
        tasks: tasks.filter((t) => t.due?.date === date),
      });
    }
    return ok({ timeZone: settings.timeZone, hasLocation: settings.location !== null, overdue, days });
  }

  // MARK: Helpers

  private async activeUser(userId: string): Promise<Row | null> {
    const user = await this.db.prepare(`SELECT * FROM users WHERE id = ?`).bind(userId).first<Row>();
    return user && !(user.apple_sub as string).startsWith("deleted:") ? user : null;
  }

  private gone<T>(): Outcome<T> {
    return fail("unauthorized", "This Zimam account no longer exists");
  }

  private async visibleTask(userId: string, id: string): Promise<Row | null> {
    if (!(await this.activeUser(userId))) return null;
    const parsedId = Id.safeParse(id);
    if (!parsedId.success) return null;
    const row = await this.db.prepare(`SELECT * FROM tasks WHERE id = ?`).bind(parsedId.data).first<Row>();
    if (!row || row.deleted_at != null) return null;
    return (await new Access(this.db, userId).canSeeTask(row)) ? row : null;
  }

  /**
   * Adds the next occurrence of a repeating task just completed, as the apps do (`addNextOccurrence`
   * in apple/Shared/Model/Store.swift and web/public/app/main.js): a copy due on the rule's next day,
   * from today on, its COUNT one less and its span kept, with the user's reminders on it moved by as
   * many days. An open task with the same title already on that day, in the same place, is the next
   * occurrence (another device added it), so nothing is added twice.
   */
  private async addNextOccurrence(userId: string, id: string) {
    const user = await this.activeUser(userId);
    const row = await this.db.prepare(`SELECT * FROM tasks WHERE id = ?`).bind(id).first<Row>();
    if (!user || !row) return;
    const task = taskOut(row);
    const today = dayIn(userOut(user).settings.timeZone);
    const base = task.dueDate ?? today;
    const next = task.recurrence ? nextOccurrence(task.recurrence, base, today) : null;
    if (!next) return;

    const twin = await this.db
      .prepare(
        `SELECT 1 FROM tasks
         WHERE id <> ?1 AND deleted_at IS NULL AND status <> 'done' AND due_date = ?2 AND title = ?3
           AND parent_id IS ?4 AND project_id IS ?5 AND (project_id IS NOT NULL OR owner_id = ?6)
         LIMIT 1`,
      )
      .bind(id, next.day, task.title, task.parentId, task.projectId, task.ownerId)
      .first();
    if (twin) return;

    const mutator = new Mutator(this.db, new Access(this.db, userId));
    const copyId = crypto.randomUUID();
    const now = Date.now();
    const span = task.startDate && task.dueDate ? daysBetween(task.startDate, task.dueDate) : 0;
    const created = await mutator.apply({
      op: "upsert",
      entity: "task",
      data: {
        ...task,
        id: copyId,
        status: "todo",
        completedAt: null,
        dueDate: next.day,
        startDate: span > 0 ? addDays(next.day, -span) : null,
        recurrence: next.recurrence,
        updatedAt: now,
      },
    });
    if (created.status !== "applied") return;

    // Times, alone or with a place, move with the task; a place's race starts again.
    const shift = daysBetween(base, next.day);
    const { results } = await this.db
      .prepare(`SELECT * FROM reminders WHERE task_id = ? AND user_id = ? AND deleted_at IS NULL ORDER BY created_at`)
      .bind(id, userId)
      .all<Row>();
    for (const reminder of results.map(reminderOut)) {
      let { at, firedAt } = reminder;
      if (reminder.kind === "time" || (reminder.kind === "location" && at)) {
        at = shiftedTime(at, shift);
        if (!at) continue;
        firedAt = null;
      }
      await mutator.apply({
        op: "upsert",
        entity: "reminder",
        data: { ...reminder, id: crypto.randomUUID(), taskId: copyId, at, firedAt, updatedAt: now },
      });
    }
  }

  private async write(userId: string, id: string, data: Record<string, unknown>): Promise<Outcome<AssistantTask>> {
    const result = await new Mutator(this.db, new Access(this.db, userId)).apply({ op: "upsert", entity: "task", data });
    if (result.status !== "applied") return fail(result.status, result.message ?? result.status);
    const row = await this.db.prepare(`SELECT * FROM tasks WHERE id = ?`).bind(id).first<Row>();
    const [task] = await this.present(userId, [row!]);
    return ok(task!);
  }

  private async present(userId: string, rows: Row[]): Promise<AssistantTask[]> {
    if (rows.length === 0) return [];
    const names = new Map((await listProjects(this.db, userId)).map((p) => [p.id as string, p.name as string]));
    return rows.map((row) => {
      const t = taskOut(row);
      return {
        id: t.id,
        title: t.title,
        notes: t.notes,
        status: t.status as AssistantTask["status"],
        priority: PRIORITIES[t.priority] ?? "none",
        tags: t.tags,
        projectId: t.projectId,
        project: t.projectId ? (names.get(t.projectId) ?? null) : null,
        parentId: t.parentId,
        due: t.dueDate
          ? { date: t.dueDate, time: t.dueTime, hijri: hijriText(t.dueDate), gregorian: gregorianText(t.dueDate) }
          : null,
        start: t.startDate ? { date: t.startDate, hijri: hijriText(t.startDate), gregorian: gregorianText(t.startDate) } : null,
        prayer: t.duePrayer
          ? {
              prayer: t.duePrayer,
              offsetMinutes: t.duePrayerOffset ?? 0,
              text: prayerPhrase(t.duePrayer as (typeof PRAYERS)[number], t.duePrayerOffset ?? 0),
            }
          : null,
        recurrence: t.recurrence,
        completedAt: t.completedAt ? new Date(t.completedAt).toISOString() : null,
      };
    });
  }
}

/** Whole days from one local day to another ("2026-10-13" to "2026-10-20" is 7). */
function daysBetween(from: string, to: string): number {
  return Math.round((Date.parse(`${to}T12:00:00Z`) - Date.parse(`${from}T12:00:00Z`)) / 86_400_000);
}

/** An ISO time moved by whole days, its clock time and offset kept; null if it cannot be read. */
function shiftedTime(at: string | null, days: number): string | null {
  const m = /^(\d{4}-\d{2}-\d{2})(T.*)$/.exec(at ?? "");
  return m ? `${addDays(m[1]!, days)}${m[2]}` : null;
}

/** Maps assistant field names onto the sync schema, keeping only the fields that were given. */
function toTaskInput(fields: z.output<typeof TaskFields>): Record<string, unknown> {
  const { priority, ...rest } = fields;
  const input: Record<string, unknown> = Object.fromEntries(Object.entries(rest).filter(([, v]) => v !== undefined));
  if (priority !== undefined) input.priority = PRIORITIES.indexOf(priority);
  if (fields.duePrayer === null) input.duePrayerOffset = null;
  // Clearing the due day clears the span with it; a start day alone is not allowed.
  if (fields.dueDate === null && fields.startDate === undefined) input.startDate = null;
  return input;
}
