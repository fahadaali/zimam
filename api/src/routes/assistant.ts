import type { Context } from "hono";
import { Hono } from "hono";
import { z } from "zod";
import type { AiRequest } from "../ai/provider";
import { breakdownRequest, parseRequest, type SummaryTask, summaryRequest } from "../ai/prompts";
import { checkQuota, monthlyLimit, recordUsage } from "../ai/quota";
import { validateSubtasks, validateSuggestion, validateSummary } from "../ai/validate";
import { Assistant, type AssistantTask } from "../assistant";
import { dayIn, timeIn } from "../data/dates";
import { listProjects } from "../data/queries";
import { type Row, userOut } from "../data/rows";
import { Id, PRAYERS } from "../data/schemas";
import { fail, readJson } from "../http";
import type { AppEnv } from "../types";
import { loadVisible } from "./resources";

/**
 * The in-app assistant: natural-language task entry, subtasks and the morning summary.
 * Nothing here is saved; the app shows the suggestion and the user confirms it.
 */
export const assistant = new Hono<AppEnv>();

type Ctx = Context<AppEnv>;
type Run<T> = { ok: true; value: T } | { ok: false; response: Response };

function issues(error: z.ZodError): string {
  return error.issues.map((i) => `${i.path.join(".") || "input"}: ${i.message}`).join("; ");
}

/**
 * Checks the monthly quota, calls the provider, validates its answer, then counts the request.
 * Provider failures and unusable answers are not counted.
 */
async function runAi<T>(c: Ctx, request: AiRequest, validate: (json: unknown) => T | null): Promise<Run<T>> {
  const now = new Date();
  const quota = await checkQuota(c.env.DB, c.var.userId, monthlyLimit(c.env.AI_MONTHLY_LIMIT), now);
  if (!quota.allowed) {
    const error = {
      code: "ai_quota_exceeded",
      message: `Monthly assistant limit of ${quota.limit} requests reached`,
      limit: quota.limit,
      resetsOn: quota.resetsOn,
    };
    return { ok: false, response: c.json({ error }, 429) };
  }
  const provider = c.var.deps.ai(c.env);
  const unavailable = (): Run<T> => ({
    ok: false,
    response: fail(c, 503, "ai_unavailable", "The assistant is unavailable, try again later"),
  });
  let result;
  try {
    result = await provider.complete(request);
  } catch (err) {
    console.error(`ai ${provider.name} ${request.name} failed:`, (err as Error).message);
    return unavailable();
  }
  const value = validate(result.json);
  if (value === null) {
    console.error(`ai ${provider.name} ${request.name} returned an unusable answer`);
    return unavailable();
  }
  await recordUsage(c.env.DB, c.var.userId, result.usage, now);
  return { ok: true, value };
}

async function loadSettings(c: Ctx) {
  const user = await c.env.DB.prepare(`SELECT * FROM users WHERE id = ?`).bind(c.var.userId).first<Row>();
  return userOut(user ?? { settings: "{}" }).settings;
}

// MARK: POST /v1/assistant/parse

const ParseBody = z.object({
  text: z.string().trim().min(1).max(1000),
  /** The device's current time; the server's by default. */
  now: z.iso.datetime({ offset: true }).optional(),
});

assistant.post("/parse", async (c) => {
  const body = ParseBody.safeParse(await readJson(c));
  if (!body.success) return fail(c, 400, "invalid", issues(body.error));
  const settings = await loadSettings(c);
  const now = body.data.now ? new Date(body.data.now) : new Date();
  const today = dayIn(settings.timeZone, now);

  // Only projects the user can add tasks to.
  const projects = (await listProjects(c.env.DB, c.var.userId))
    .filter((p) => p.kind === "project" && p.archived_at == null && (p.role === "owner" || p.role === "editor"))
    .map((p) => ({ id: p.id as string, name: p.name as string }));
  const projectIds = new Set(projects.map((p) => p.id));

  const request = parseRequest({
    text: body.data.text,
    today,
    localTime: timeIn(settings.timeZone, now),
    timeZone: settings.timeZone,
    projects,
  });
  const result = await runAi(c, request, (json) => validateSuggestion(json, today, projectIds));
  return result.ok ? c.json(result.value) : result.response;
});

// MARK: POST /v1/assistant/breakdown

const BreakdownBody = z.object({ taskId: Id });

assistant.post("/breakdown", async (c) => {
  const body = BreakdownBody.safeParse(await readJson(c));
  if (!body.success) return fail(c, 400, "invalid", issues(body.error));
  const task = await loadVisible(c, "task", body.data.taskId);
  if (!task) return fail(c, 404, "not_found", "task not found");

  const { results: children } = await c.env.DB.prepare(
    `SELECT title FROM tasks WHERE parent_id = ? AND deleted_at IS NULL ORDER BY sort_order, created_at LIMIT 50`,
  )
    .bind(task.id)
    .all<{ title: string }>();
  const project = task.project_id
    ? await c.env.DB.prepare(`SELECT name FROM projects WHERE id = ?`).bind(task.project_id).first<{ name: string }>()
    : null;

  const request = breakdownRequest({
    title: task.title as string,
    notes: (task.notes as string | null) ?? null,
    project: project?.name ?? null,
    existingSubtasks: children.map((r) => r.title),
  });
  const result = await runAi(c, request, (json) => validateSubtasks(json, task.title as string));
  return result.ok ? c.json({ subtasks: result.value }) : result.response;
});

// MARK: GET /v1/assistant/summary

const SummaryQuery = z.object({ date: z.iso.date().optional() });
const MAX_LISTED = 30;

/** Minutes since midnight of "HH:mm". */
const minutes = (hhmm: string) => Number(hhmm.slice(0, 2)) * 60 + Number(hhmm.slice(3, 5));

assistant.get("/summary", async (c) => {
  const query = SummaryQuery.safeParse(c.req.query());
  if (!query.success) return fail(c, 400, "invalid", issues(query.error));
  const settings = await loadSettings(c);
  const now = new Date();
  const today = dayIn(settings.timeZone, now);
  const date = query.data.date ?? today;

  const agenda = await new Assistant(c.env, { apple: c.var.deps.appleKeys, google: c.var.deps.googleKeys }).getAgenda(c.var.userId, { from: date, days: 1 });
  if (!agenda.ok) return fail(c, 401, agenda.error.code, agenda.error.message);
  const day = agenda.value.days[0]!;
  const prayers = day.prayers;

  const anchorMinutes = (t: AssistantTask): number | null => {
    if (!t.prayer || !prayers) return null;
    return minutes(prayers[t.prayer.prayer as keyof typeof prayers]) + t.prayer.offsetMinutes;
  };
  const describe = (t: AssistantTask, withDate = false): SummaryTask => {
    const out: SummaryTask = { title: t.title, priority: t.priority, project: t.project };
    if (t.due?.time) out.time = t.due.time;
    if (t.prayer) {
      out.prayer = t.prayer.text;
      const at = anchorMinutes(t);
      if (at !== null) {
        const m = ((at % 1440) + 1440) % 1440;
        out.prayerTime = `${String(Math.floor(m / 60)).padStart(2, "0")}:${String(m % 60).padStart(2, "0")}`;
      }
    }
    if (withDate && t.due) out.dueDate = `${t.due.hijri}، ${t.due.gregorian}`;
    return out;
  };

  const open = day.tasks.filter((t) => t.status !== "done");
  const doneCount = day.tasks.length - open.length;
  const overdue = agenda.value.overdue;

  if (open.length === 0 && overdue.length === 0) {
    // Nothing to summarise: answer without calling the model or using the quota.
    const text = doneCount > 0 ? "أنجزت كل مهام اليوم، ولا مهام متأخرة." : "لا مهام لهذا اليوم ولا مهام متأخرة. يومك متاح.";
    return c.json({ date, text });
  }

  // The next prayer-anchored task: the first still ahead today, or the earliest on another day.
  const prayerOrder = (t: AssistantTask) =>
    anchorMinutes(t) ?? PRAYERS.indexOf(t.prayer!.prayer as (typeof PRAYERS)[number]) * 1440 + t.prayer!.offsetMinutes;
  const anchored = open.filter((t) => t.prayer).sort((a, b) => prayerOrder(a) - prayerOrder(b));
  const nowMinutes = minutes(timeIn(settings.timeZone, now));
  const next =
    date === today && prayers ? anchored.find((t) => (anchorMinutes(t) ?? 0) >= nowMinutes) : anchored[0];

  const request = summaryRequest({
    date,
    dateText: day.label,
    weekday: day.weekday,
    isToday: date === today,
    counts: { dueOpen: open.length, dueDone: doneCount, overdue: overdue.length },
    dueToday: open.slice(0, MAX_LISTED).map((t) => describe(t)),
    overdue: overdue.slice(0, MAX_LISTED).map((t) => describe(t, true)),
    nextPrayerTask: next ? describe(next) : null,
  });
  const result = await runAi(c, request, validateSummary);
  return result.ok ? c.json({ date, text: result.value }) : result.response;
});
