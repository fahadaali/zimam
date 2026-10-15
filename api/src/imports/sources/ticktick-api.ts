import { durationMs, isoWithOffset, isTimeZone, localToInstant, parseDateText } from "../dates";
import {
  addNote,
  fitName,
  fitTask,
  type ImportBundle,
  type ImportedProject,
  type ImportedReminder,
  type ImportedSection,
  type ImportedTask,
  LIMITS,
  orderTasks,
  Warnings,
} from "../model";
import { zimamRule } from "../recurrence";
import { derivedKey, nativeKey, type ParseContext, type TokenSource } from "../source";
import { type Provider, providerGet, providerJson } from "./provider-http";
import { tickTickPriority } from "./ticktick";

export const TICKTICK_API = "https://api.ticktick.com/open/v1";

interface TickTickProject {
  id: string;
  name?: string;
  closed?: boolean;
  /** "list", "kanban" or "timeline". */
  viewMode?: string;
  /** "TASK" or "NOTE". */
  kind?: string;
  sortOrder?: number;
}

interface TickTickItem {
  id: string;
  title?: string;
  /** 0 open, 1 done. */
  status?: number;
  sortOrder?: number;
  completedTime?: string;
}

export interface TickTickTask {
  id: string;
  projectId?: string;
  parentId?: string;
  title?: string;
  content?: string;
  desc?: string;
  isAllDay?: boolean;
  /** Instants, "2026-10-19T21:00:00+0000". */
  startDate?: string;
  dueDate?: string;
  timeZone?: string;
  /** "TRIGGER:-PT15M", relative to the due time (midnight for all-day tasks). */
  reminders?: string[];
  repeatFlag?: string;
  /** 0 none, 1 low, 3 medium, 5 high. */
  priority?: number;
  /** 0 open, 2 completed. */
  status?: number;
  completedTime?: string;
  sortOrder?: number;
  columnId?: string;
  tags?: string[];
  items?: TickTickItem[];
  kind?: string;
}

export interface TickTickData {
  /** Lists; the inbox is not among them. */
  projects: TickTickProject[];
  /** `GET /project/{id}/data` by project id, and "inbox" for the inbox. */
  data: Record<string, { tasks?: TickTickTask[]; columns?: { id: string; name?: string; sortOrder?: number }[] } | null>;
}

/** "2026-10-10T08:00:00+0000" as epoch ms. */
function instant(text: string | undefined): number | null {
  if (!text) return null;
  const ms = Date.parse(text.replace(/([+-]\d{2})(\d{2})$/, "$1:$2"));
  return Number.isFinite(ms) ? ms : null;
}

/**
 * TickTick's Open API. The same records as the CSV backup (`ticktick.ts`), with the same keys,
 * so importing one after the other updates instead of copying: lists by name, kanban columns
 * by name within their list, tasks by TickTick's id (refSource "ticktick").
 *
 * - Lists → projects (kanban view kept), the inbox → Zimam's inbox; columns → sections.
 * - Dates are read in the task's own zone, as TickTick showed them; a start day before the due
 *   day becomes the start day. Completed tasks (status 2) come in done.
 * - repeatFlag → recurrence when Zimam repeats it on the same days, else a note.
 * - Reminders → time reminders on open tasks that do not repeat; checklist items → subtasks.
 * The Open API returns open tasks only, and no folders: lists come in outside any folder.
 */
export function mapTickTickApi(data: TickTickData, ctx: ParseContext): ImportBundle {
  const warnings = new Warnings();
  const projects: ImportedProject[] = [];
  const sections: ImportedSection[] = [];
  const tasks: ImportedTask[] = [];

  const places: { projectKey: string | null; dataKey: string }[] = [{ projectKey: null, dataKey: "inbox" }];
  [...data.projects]
    .sort((a, b) => (a.sortOrder ?? 0) - (b.sortOrder ?? 0))
    .forEach((p) => {
      if (p.closed) {
        warnings.add("archivedSkipped");
        return;
      }
      if (p.kind === "NOTE") {
        warnings.add("notesSkipped");
        return;
      }
      const name = fitName(p.name ?? "", LIMITS.projectName) || "TickTick";
      const key = derivedKey("ticktick", "list", name);
      if (!projects.some((x) => x.key === key)) {
        projects.push({ key, name, kind: "project", parentKey: null, view: p.viewMode === "kanban" ? "kanban" : "list", sortOrder: projects.length, archived: false });
      }
      places.push({ projectKey: key, dataKey: p.id });
    });

  for (const { projectKey, dataKey } of places) {
    const content = data.data[dataKey];
    if (!content) continue;
    const columns = new Map<string, string>();
    if (projectKey) {
      for (const column of [...(content.columns ?? [])].sort((a, b) => (a.sortOrder ?? 0) - (b.sortOrder ?? 0))) {
        const name = fitName(column.name ?? "", LIMITS.sectionName);
        if (!name) continue;
        const key = derivedKey(projectKey, "column", name);
        columns.set(column.id, key);
        if (!sections.some((s) => s.key === key)) sections.push({ key, projectKey, name, sortOrder: sections.length });
      }
    }
    for (const t of content.tasks ?? []) {
      if (t.kind === "NOTE") {
        warnings.add("notesSkipped");
        continue;
      }
      const title = t.title?.trim();
      if (!title) {
        warnings.add("untitledSkipped");
        continue;
      }
      const key = nativeKey("task", t.id);
      const zone = isTimeZone(t.timeZone) ? t.timeZone : ctx.timeZone;
      const allDay = t.isAllDay === true;
      const when = parseDateText(t.dueDate || t.startDate || "", zone);
      const start = t.dueDate && t.startDate ? parseDateText(t.startDate, zone) : null;
      let notes = (t.content || t.desc)?.trim() || null;
      const done = t.status === 2;
      let recurrence: string | null = null;
      if (t.repeatFlag) {
        recurrence = when ? zimamRule(t.repeatFlag, when.date) : null;
        if (!recurrence) {
          notes = addNote(notes, `التكرار في TickTick: ${t.repeatFlag}`);
          warnings.add("recurrenceKept");
        }
      }
      const reminders: ImportedReminder[] = [];
      const triggers = (t.reminders ?? []).filter(Boolean);
      if (triggers.length) {
        if (!when || done || recurrence) warnings.add("remindersSkipped", triggers.length);
        else {
          const base = localToInstant(when.date, allDay || !when.time ? "00:00" : when.time, zone);
          for (const trigger of triggers) {
            const offset = durationMs(trigger.replace(/^TRIGGER:/i, ""));
            if (offset === null) warnings.add("remindersSkipped");
            else reminders.push({ key: `${key}/reminder:${trigger}`, at: isoWithOffset(base + offset, ctx.timeZone) });
          }
        }
      }
      tasks.push({
        key,
        projectKey,
        sectionKey: t.columnId ? (columns.get(t.columnId) ?? null) : null,
        parentKey: t.parentId ? nativeKey("task", t.parentId) : null,
        title,
        notes,
        priority: tickTickPriority(String(t.priority ?? 0)),
        tags: t.tags ?? [],
        dueDate: when?.date ?? null,
        dueTime: allDay ? null : (when?.time ?? null),
        startDate: start?.date ?? null,
        recurrence,
        done,
        completedAt: done ? instant(t.completedTime) : null,
        sortOrder: t.sortOrder ?? 0,
        reminders,
      });
      [...(t.items ?? [])]
        .sort((a, b) => (a.sortOrder ?? 0) - (b.sortOrder ?? 0))
        .forEach((item, index) => {
          const itemTitle = item.title?.trim();
          if (!itemTitle) return;
          const itemDone = item.status === 1;
          tasks.push({
            key: nativeKey("item", item.id),
            projectKey,
            sectionKey: null,
            parentKey: key,
            title: itemTitle,
            notes: null,
            priority: 0,
            tags: [],
            dueDate: null,
            dueTime: null,
            recurrence: null,
            done: itemDone,
            completedAt: itemDone ? instant(item.completedTime) : null,
            sortOrder: index,
            reminders: [],
          });
        });
    }
  }
  return { projects, sections, tasks: orderTasks(tasks).map(fitTask), warnings: warnings.list() };
}

export const tickTickApi: TokenSource = {
  id: "ticktick-api",
  label: "TickTick",
  refSource: "ticktick",
  input: "oauth",
  async load(token, ctx) {
    const provider: Provider = { label: "TickTick", fetch: ctx.fetch, headers: { Authorization: `Bearer ${token}` } };
    const projects = (await providerGet<TickTickProject[]>(provider, `${TICKTICK_API}/project`)) ?? [];
    const data: TickTickData["data"] = {};
    // The inbox has no entry in the list; its data is at "inbox", where TickTick serves it.
    data.inbox = await providerJson<NonNullable<TickTickData["data"][string]>>(provider, `${TICKTICK_API}/project/inbox/data`, { optional: true }).catch(() => null);
    for (const p of projects) {
      if (p.closed || p.kind === "NOTE") continue;
      data[p.id] = await providerGet(provider, `${TICKTICK_API}/project/${encodeURIComponent(p.id)}/data`);
    }
    return mapTickTickApi({ projects, data }, ctx);
  },
};
