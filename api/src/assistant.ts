import type { JWTVerifyGetKey } from "jose";
import { z } from "zod";
import { verifyAppleToken } from "./auth/apple";
import { appleAudiences, upsertAppleUser } from "./auth/users";
import { Access } from "./data/access";
import { addDays, dayIn, dualText, gregorianText, hijriText, weekdayText } from "./data/dates";
import { Mutator } from "./data/mutations";
import { prayerPhrase, prayerTimes, type PrayerTimesOfDay } from "./data/prayers";
import { listProjects, listTasks } from "./data/queries";
import { type Row, taskOut, userOut } from "./data/rows";
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

export const AgendaRequest = z.object({
  from: z.iso.date().optional(),
  days: z.number().int().min(1).max(14).default(1),
});
export type AgendaRequest = z.input<typeof AgendaRequest>;

function issues(error: z.ZodError): string {
  return error.issues.map((i) => `${i.path.join(".") || "input"}: ${i.message}`).join("; ");
}

export class Assistant {
  constructor(
    private readonly env: Env,
    private readonly appleKeys: JWTVerifyGetKey,
  ) {}

  private get db() {
    return this.env.DB;
  }

  /** Verifies a Sign in with Apple identity token from the web and returns the Zimam user. */
  async signInWithApple(identityToken: string, nonce: string): Promise<Outcome<{ userId: string; name: string | null }>> {
    try {
      const identity = await verifyAppleToken(identityToken, this.appleKeys, appleAudiences(this.env.APPLE_AUDIENCES), nonce);
      const user = await upsertAppleUser(this.db, identity, null);
      return ok({ userId: user.id as string, name: (user.name as string | null) ?? null });
    } catch {
      return fail("invalid_token", "Apple identity token was rejected");
    }
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
    return this.write(userId, id, data);
  }

  async updateTask(userId: string, id: string, fields: TaskFields): Promise<Outcome<AssistantTask>> {
    const parsed = TaskFields.safeParse(fields);
    if (!parsed.success) return fail("invalid", issues(parsed.error));
    const row = await this.visibleTask(userId, id);
    if (!row) return fail("not_found", "Task not found");
    const data = {
      ...taskOut(row),
      ...toTaskInput(parsed.data),
      id: row.id as string,
      updatedAt: Math.max(Date.now(), (row.updated_at as number) + 1),
    };
    return this.write(userId, row.id as string, data);
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

/** Maps assistant field names onto the sync schema, keeping only the fields that were given. */
function toTaskInput(fields: z.output<typeof TaskFields>): Record<string, unknown> {
  const { priority, ...rest } = fields;
  const input: Record<string, unknown> = Object.fromEntries(Object.entries(rest).filter(([, v]) => v !== undefined));
  if (priority !== undefined) input.priority = PRIORITIES.indexOf(priority);
  if (fields.duePrayer === null) input.duePrayerOffset = null;
  return input;
}
