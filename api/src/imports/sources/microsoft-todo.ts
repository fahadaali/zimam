import { isoWithOffset, isTimeZone, localToInstant, zonedDateTime } from "../dates";
import {
  addNote,
  fitName,
  fitTask,
  type ImportBundle,
  type ImportedProject,
  type ImportedReminder,
  type ImportedTask,
  LIMITS,
  orderTasks,
  Warnings,
} from "../model";
import { weekdayCode } from "../recurrence";
import { nativeKey, type ParseContext, type TokenSource } from "../source";
import { htmlToText, instantOf, MAX_PAGES, type Provider, providerGet } from "./provider-http";

export const GRAPH_API = "https://graph.microsoft.com/v1.0";

/** Graph's dateTimeTimeZone: a wall-clock time and the zone it is in (usually "UTC"). */
interface GraphDateTime {
  dateTime: string;
  timeZone?: string;
}

interface TodoList {
  id: string;
  displayName?: string;
  /** "defaultList" (the «Tasks» list), "flaggedEmails", or "none". */
  wellknownListName?: string;
}

interface ChecklistItem {
  id: string;
  displayName?: string;
  isChecked?: boolean;
  checkedDateTime?: string;
}

interface Recurrence {
  pattern?: {
    type?: string;
    interval?: number;
    daysOfWeek?: string[];
    dayOfMonth?: number;
    month?: number;
    index?: string;
  };
  range?: { type?: string; endDate?: string; numberOfOccurrences?: number };
}

export interface TodoTask {
  id: string;
  title?: string;
  body?: { content?: string; contentType?: string };
  /** "low", "normal" or "high" («مهمة» in To Do). */
  importance?: string;
  /** "notStarted", "inProgress", "completed", "waitingOnOthers", "deferred". */
  status?: string;
  dueDateTime?: GraphDateTime;
  startDateTime?: GraphDateTime;
  reminderDateTime?: GraphDateTime;
  isReminderOn?: boolean;
  completedDateTime?: GraphDateTime;
  recurrence?: Recurrence | null;
  categories?: string[];
  checklistItems?: ChecklistItem[];
}

export interface MicrosoftTodoData {
  lists: { list: TodoList; tasks: TodoTask[] }[];
}

const DAYS: Record<string, string> = {
  sunday: "SU", monday: "MO", tuesday: "TU", wednesday: "WE", thursday: "TH", friday: "FR", saturday: "SA",
};

/** An instant from Graph's wall clock and zone. A zone Graph names the Windows way is read as the user's. */
function graphInstant(value: GraphDateTime | undefined, userZone: string): number | null {
  if (!value?.dateTime) return null;
  const text = value.dateTime.replace(/(\.\d{3})\d+$/, "$1");
  const zone = value.timeZone ?? "UTC";
  if (/^(utc|etc\/utc|gmt)$/i.test(zone)) return instantOf(`${text}Z`);
  const m = text.match(/^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/);
  if (!m) return null;
  return localToInstant(m[1]!, m[2]!, isTimeZone(zone) ? zone : userZone);
}

/**
 * To Do keeps a due or start day, not a time, as the local midnight of the user's zone written
 * in UTC ("2026-10-19T21:00:00" for the 20th in Riyadh), or as midnight UTC: midnight is read
 * as written, anything else in the user's zone.
 */
function graphDay(value: GraphDateTime | undefined, userZone: string): string | null {
  if (!value?.dateTime) return null;
  const m = value.dateTime.match(/^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})/);
  if (!m) return null;
  if (m[2] === "00:00") return m[1]!;
  const ms = graphInstant(value, userZone);
  return ms === null ? m[1]! : zonedDateTime(ms, userZone).date;
}

/** The task's recurrence as Zimam's rule, or null when Zimam cannot repeat it on the same days. */
export function todoRecurrence(r: Recurrence, dueDate: string): string | null {
  const p = r.pattern ?? {};
  const interval = Math.max(1, Math.floor(p.interval ?? 1));
  const [, month, day] = dueDate.split("-").map(Number) as [number, number, number];
  const parts: string[] = [];
  switch (p.type) {
    case "daily":
      parts.push("FREQ=DAILY");
      break;
    case "weekly": {
      parts.push("FREQ=WEEKLY");
      const codes = (p.daysOfWeek ?? []).map((d) => DAYS[d.toLowerCase()]);
      if (codes.some((c) => !c)) return null;
      const order = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"].filter((c) => codes.includes(c));
      if (order.length && !(order.length === 1 && order[0] === weekdayCode(dueDate))) parts.push(`BYDAY=${order.join(",")}`);
      break;
    }
    case "absoluteMonthly":
      if (p.dayOfMonth && p.dayOfMonth !== day) return null;
      parts.push("FREQ=MONTHLY");
      break;
    case "absoluteYearly":
      if ((p.dayOfMonth && p.dayOfMonth !== day) || (p.month && p.month !== month)) return null;
      parts.push("FREQ=YEARLY");
      break;
    default:
      // relativeMonthly, relativeYearly ("the second Monday"): Zimam repeats on the same date.
      return null;
  }
  if (interval > 1) parts.splice(1, 0, `INTERVAL=${interval}`);
  const range = r.range ?? {};
  if (range.type === "endDate" && range.endDate && /^\d{4}-\d{2}-\d{2}$/.test(range.endDate)) parts.push(`UNTIL=${range.endDate.replace(/-/g, "")}`);
  if (range.type === "numbered" && range.numberOfOccurrences && range.numberOfOccurrences > 0) parts.push(`COUNT=${range.numberOfOccurrences}`);
  return parts.join(";");
}

/** Words for To Do's pattern in a note, when it cannot be a rule: «relativeMonthly، كل ١». */
function recurrenceText(r: Recurrence): string {
  const p = r.pattern ?? {};
  return [p.type, p.index, p.daysOfWeek?.join(", "), p.interval && p.interval > 1 ? `every ${p.interval}` : null].filter(Boolean).join("، ");
}

/**
 * Microsoft To Do through Microsoft Graph. Each list is a project, the «Tasks» list (defaultList)
 * is Zimam's inbox, and flagged emails are skipped. Importance high is high priority (low is
 * low, normal none); completed tasks come in done; the due day and the start day are days
 * (To Do has no due time); a reminder that is on becomes a time reminder on an open task that
 * does not repeat; checklist steps become subtasks; categories become tags.
 */
export function mapMicrosoftTodo(data: MicrosoftTodoData, ctx: ParseContext): ImportBundle {
  const warnings = new Warnings();
  const projects: ImportedProject[] = [];
  const tasks: ImportedTask[] = [];
  const zone = ctx.timeZone;

  data.lists.forEach(({ list, tasks: items }, listIndex) => {
    if (list.wellknownListName === "flaggedEmails") {
      warnings.add("flaggedEmailsSkipped");
      return;
    }
    let projectKey: string | null = null;
    if (list.wellknownListName !== "defaultList") {
      projectKey = nativeKey("list", list.id);
      projects.push({
        key: projectKey,
        name: fitName(list.displayName ?? "", LIMITS.projectName) || "Microsoft To Do",
        kind: "project",
        parentKey: null,
        view: "list",
        sortOrder: listIndex,
        archived: false,
      });
    }

    items.forEach((t, index) => {
      const title = t.title?.trim();
      if (!title) {
        warnings.add("untitledSkipped");
        return;
      }
      const key = nativeKey("task", t.id);
      const content = t.body?.content?.trim() ?? "";
      let notes: string | null = (t.body?.contentType === "html" ? htmlToText(content) : content) || null;
      const done = t.status === "completed";
      const dueDate = graphDay(t.dueDateTime, zone);
      let recurrence: string | null = null;
      if (t.recurrence?.pattern) {
        recurrence = dueDate ? todoRecurrence(t.recurrence, dueDate) : null;
        if (!recurrence) {
          notes = addNote(notes, `التكرار في Microsoft To Do: ${recurrenceText(t.recurrence)}`);
          warnings.add("recurrenceKept");
        }
      }
      const reminders: ImportedReminder[] = [];
      const remindAt = t.isReminderOn ? graphInstant(t.reminderDateTime, zone) : null;
      if (remindAt !== null) {
        if (done || recurrence) warnings.add("remindersSkipped");
        else reminders.push({ key: `${key}/reminder`, at: isoWithOffset(remindAt, zone) });
      }
      tasks.push({
        key,
        projectKey,
        sectionKey: null,
        parentKey: null,
        title,
        notes,
        priority: t.importance === "high" ? 3 : t.importance === "low" ? 1 : 0,
        tags: t.categories ?? [],
        dueDate,
        dueTime: null,
        startDate: graphDay(t.startDateTime, zone),
        recurrence,
        done,
        completedAt: done ? graphInstant(t.completedDateTime, zone) : null,
        sortOrder: index,
        reminders,
      });
      (t.checklistItems ?? []).forEach((step, stepIndex) => {
        const stepTitle = step.displayName?.trim();
        if (!stepTitle) return;
        const stepDone = step.isChecked === true;
        tasks.push({
          key: nativeKey("checklist", step.id),
          projectKey,
          sectionKey: null,
          parentKey: key,
          title: stepTitle,
          notes: null,
          priority: 0,
          tags: [],
          dueDate: null,
          dueTime: null,
          recurrence: null,
          done: stepDone,
          completedAt: stepDone ? instantOf(step.checkedDateTime) : null,
          sortOrder: stepIndex,
          reminders: [],
        });
      });
    });
  });
  return { projects, sections: [], tasks: orderTasks(tasks).map(fitTask), warnings: warnings.list() };
}

async function allPages<T>(provider: Provider, url: string): Promise<T[]> {
  const out: T[] = [];
  let next: string | undefined = url;
  for (let page = 0; next && page < MAX_PAGES; page++) {
    const body: { value?: T[]; "@odata.nextLink"?: string } = await providerGet(provider, next);
    out.push(...(body?.value ?? []));
    next = body?.["@odata.nextLink"];
  }
  return out;
}

export const microsoftTodo: TokenSource = {
  id: "microsoft-todo",
  label: "Microsoft To Do",
  refSource: "microsoft-todo",
  input: "oauth",
  async load(token, ctx) {
    const provider: Provider = { label: "Microsoft To Do", fetch: ctx.fetch, headers: { Authorization: `Bearer ${token}` } };
    const lists = await allPages<TodoList>(provider, `${GRAPH_API}/me/todo/lists`);
    const out: MicrosoftTodoData["lists"] = [];
    for (const list of lists) {
      if (list.wellknownListName === "flaggedEmails") {
        out.push({ list, tasks: [] });
        continue;
      }
      const tasks = await allPages<TodoTask>(provider, `${GRAPH_API}/me/todo/lists/${encodeURIComponent(list.id)}/tasks?$expand=checklistItems&$top=100`);
      out.push({ list, tasks });
    }
    return mapMicrosoftTodo({ lists: out }, ctx);
  },
};
