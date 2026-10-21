import { csvRecords, parseCsv } from "../csv";
import { parseDateText, recurrenceFromText } from "../dates";
import {
  addNote,
  fitName,
  fitTask,
  type ImportBundle,
  ImportError,
  type ImportedProject,
  type ImportedSection,
  type ImportedTask,
  LIMITS,
  orderTasks,
  TransientImportError,
  Warnings,
} from "../model";
import { derivedKey, type FileSource, type LoadContext, nativeKey, Occurrences, type ParseContext, type TokenSource } from "../source";
import { tokenRejected } from "./provider-http";

/** Todoist p1 (4, red) is Zimam's high (3); p4 (1) is none. The CSV uses the API's numbers. */
export function todoistPriority(value: unknown): number {
  const n = Number(value);
  return n === 4 ? 3 : n === 3 ? 2 : n === 2 ? 1 : 0;
}

/** Labels written into a task's text ("Buy milk @errands"): the title without them, and the labels. */
export function splitLabels(content: string): { title: string; labels: string[] } {
  const labels: string[] = [];
  const title = content
    .replace(/(^|\s)@([\p{L}\p{N}_-]+)/gu, (_, space: string, label: string) => {
      labels.push(label);
      return space;
    })
    .replace(/\s+/g, " ")
    .trim();
  return { title: title || content.trim(), labels };
}

interface DueInfo {
  dueDate: string | null;
  dueTime: string | null;
  recurrence: string | null;
  notes: string | null;
}

/**
 * Todoist's due text: an absolute date becomes the due date; a recurring phrase
 * becomes an RRULE only when there is a date to start from (the API's next
 * occurrence) and the phrase is understood; anything else is kept in the notes.
 */
function mapDue(
  input: { text: string; date?: string | null; recurring: boolean },
  notes: string | null,
  timeZone: string,
  warnings: Warnings,
): DueInfo {
  const out: DueInfo = { dueDate: null, dueTime: null, recurrence: null, notes };
  const text = input.text.trim();
  const parsed = input.date ? parseDateText(input.date, timeZone) : null;
  const recurring = input.recurring || /^every!?\s/i.test(text) || /^(daily|weekly|monthly|yearly)$/i.test(text);
  if (recurring) {
    const rule = parsed ? recurrenceFromText(text) : null;
    if (rule && parsed) {
      out.dueDate = parsed.date;
      out.dueTime = parsed.time;
      out.recurrence = rule;
    } else {
      if (parsed) {
        out.dueDate = parsed.date;
        out.dueTime = parsed.time;
      }
      out.notes = addNote(out.notes, `التكرار في Todoist: ${text}`);
      warnings.add("recurrenceKept");
    }
    return out;
  }
  const absolute = parsed ?? (text ? parseDateText(text, timeZone) : null);
  if (absolute) {
    out.dueDate = absolute.date;
    out.dueTime = absolute.time;
  } else if (text) {
    out.notes = addNote(out.notes, `الموعد في Todoist: ${text}`);
    warnings.add("dateKept");
  }
  return out;
}

/** A deadline is the due date when there is none, and a note otherwise. */
function mapDeadline(due: DueInfo, deadline: string | null, timeZone: string, warnings: Warnings): DueInfo {
  if (!deadline) return due;
  const parsed = parseDateText(deadline, timeZone);
  if (parsed && !due.dueDate) return { ...due, dueDate: parsed.date, dueTime: parsed.time };
  warnings.add(parsed ? "deadlineKept" : "dateKept");
  return { ...due, notes: addNote(due.notes, `الموعد النهائي في Todoist: ${deadline}`) };
}

const NOT_TODOIST_CSV = new ImportError(
  "invalid_file",
  "هذا ليس ملف Todoist بصيغة CSV. في Todoist افتح المشروع ثم اختر «قوالب ← تصدير كقالب» وصيغة CSV.",
);

/**
 * Todoist's CSV project template ("Export as a template"): one project per file,
 * named after the file. Rows are `task`, `section` or `note`; INDENT nests subtasks;
 * DATE is Todoist's own text ("Oct 20 2026", "every day"). Completed tasks are not
 * in this export.
 */
export function parseTodoistCsv(text: string, ctx: ParseContext): ImportBundle {
  const { header, records } = csvRecords(parseCsv(text));
  if (!header.includes("type") || !header.includes("content")) throw NOT_TODOIST_CSV;
  const warnings = new Warnings();
  const name = fitName(ctx.fileName?.replace(/\.[^.]+$/, "") || "مستورد من Todoist", LIMITS.projectName);
  const projectKey = derivedKey("todoist", "project", name);
  const project: ImportedProject = {
    key: projectKey, name, kind: "project", parentKey: null, view: "list", sortOrder: 0, archived: false,
  };
  const sections: ImportedSection[] = [];
  const tasks: ImportedTask[] = [];
  const seen = new Occurrences();
  let section: ImportedSection | null = null;
  /** The last task at each indent level, to find a subtask's parent. */
  const stack: ImportedTask[] = [];

  for (const record of records) {
    const type = (record.get("type") ?? "").toLowerCase();
    const content = record.get("content") ?? "";
    if (type === "section") {
      const sectionName = fitName(content, LIMITS.sectionName);
      if (!sectionName) continue;
      const n = seen.next(projectKey, "section", sectionName);
      section = { key: derivedKey(projectKey, "section", sectionName, n), projectKey, name: sectionName, sortOrder: sections.length };
      sections.push(section);
      stack.length = 0;
    } else if (type === "task") {
      const { title, labels } = splitLabels(content);
      if (!title) {
        warnings.add("untitledSkipped");
        continue;
      }
      const indent = Math.max(1, Number.parseInt(record.get("indent") ?? "1", 10) || 1);
      stack.length = Math.min(stack.length, indent - 1);
      const parent = stack.at(-1) ?? null;
      const container = parent?.key ?? section?.key ?? projectKey;
      const n = seen.next(container, title);
      const zone = ctx.timeZone;
      let due = mapDue({ text: record.get("date") ?? "", recurring: false }, record.get("description") || null, zone, warnings);
      due = mapDeadline(due, record.get("deadline") || null, zone, warnings);
      const task: ImportedTask = {
        key: derivedKey(container, "task", title, n),
        projectKey,
        sectionKey: section?.key ?? null,
        parentKey: parent?.key ?? null,
        title,
        notes: due.notes,
        priority: todoistPriority(record.get("priority")),
        tags: labels,
        dueDate: due.dueDate,
        dueTime: due.dueTime,
        recurrence: due.recurrence,
        done: false,
        completedAt: null,
        sortOrder: tasks.length,
        reminders: [],
      };
      tasks.push(task);
      stack.push(task);
    } else if (type === "note") {
      const task = stack.at(-1);
      if (task && content) task.notes = addNote(task.notes, content);
      else if (content) warnings.add("notesSkipped");
    }
  }
  return { projects: [project], sections, tasks: orderTasks(tasks).map(fitTask), warnings: warnings.list() };
}

export const todoistCsv: FileSource = {
  id: "todoist-csv",
  label: "Todoist",
  refSource: "todoist-csv",
  input: "file",
  extensions: [".csv"],
  parse: parseTodoistCsv,
};

// MARK: REST API

/** Todoist REST API v2. Todoist's newer unified API (`/api/v1`) pages its lists; `getAll` follows those pages too. */
export const TODOIST_API = "https://api.todoist.com/rest/v2";

interface TodoistProject {
  id: string;
  name: string;
  parent_id?: string | null;
  order?: number;
  child_order?: number;
  is_inbox_project?: boolean;
  inbox_project?: boolean;
  view_style?: string;
  is_archived?: boolean;
}

interface TodoistSection {
  id: string;
  project_id: string;
  name: string;
  order?: number;
  section_order?: number;
}

interface TodoistDue {
  date?: string;
  datetime?: string | null;
  string?: string;
  is_recurring?: boolean;
}

interface TodoistTask {
  id: string;
  project_id: string;
  section_id?: string | null;
  parent_id?: string | null;
  content: string;
  description?: string;
  priority?: number;
  labels?: string[];
  order?: number;
  child_order?: number;
  due?: TodoistDue | null;
  deadline?: { date?: string } | null;
  is_completed?: boolean;
  checked?: boolean;
}

export interface TodoistData {
  projects: TodoistProject[];
  sections: TodoistSection[];
  tasks: TodoistTask[];
}

/**
 * Maps what the API returned. Todoist nests projects; Zimam nests projects only in
 * folders, so a parent project with no tasks or sections of its own becomes a
 * folder, and the children of one that has some move up to the nearest folder.
 * The inbox maps to Zimam's inbox. The API returns open tasks only.
 */
export function mapTodoist(data: TodoistData, ctx: ParseContext): ImportBundle {
  const warnings = new Warnings();
  const inboxIds = new Set(data.projects.filter((p) => p.is_inbox_project || p.inbox_project).map((p) => p.id));
  const projectIds = new Set(data.projects.map((p) => p.id));
  const hasContent = new Set([...data.tasks.map((t) => t.project_id), ...data.sections.map((s) => s.project_id)]);
  const hasChildren = new Set(data.projects.map((p) => p.parent_id).filter((id): id is string => !!id));
  const byId = new Map(data.projects.map((p) => [p.id, p]));
  const isFolder = (p: TodoistProject) => hasChildren.has(p.id) && !hasContent.has(p.id) && !inboxIds.has(p.id);
  const folderAbove = (p: TodoistProject): string | null => {
    for (let id = p.parent_id, hops = 0; id && hops < 20; id = byId.get(id)?.parent_id, hops++) {
      const parent = byId.get(id);
      if (parent && isFolder(parent)) return nativeKey("project", parent.id);
    }
    return null;
  };
  const order = (o: { order?: number; child_order?: number; section_order?: number }) =>
    o.order ?? o.child_order ?? o.section_order ?? 0;

  const projects: ImportedProject[] = data.projects
    .filter((p) => !inboxIds.has(p.id))
    .map((p) => ({
      key: nativeKey("project", p.id),
      name: fitName(p.name, LIMITS.projectName) || "Todoist",
      kind: isFolder(p) ? "folder" : "project",
      parentKey: folderAbove(p),
      view: p.view_style === "board" ? "kanban" : p.view_style === "calendar" ? "calendar" : "list",
      sortOrder: order(p),
      archived: p.is_archived === true,
    }));

  const sectionIds = new Set<string>();
  const sections: ImportedSection[] = [];
  for (const s of data.sections) {
    if (inboxIds.has(s.project_id)) {
      warnings.add("sectionsDropped");
      continue;
    }
    if (!projectIds.has(s.project_id)) continue;
    sectionIds.add(s.id);
    sections.push({
      key: nativeKey("section", s.id),
      projectKey: nativeKey("project", s.project_id),
      name: fitName(s.name, LIMITS.sectionName) || "—",
      sortOrder: order(s),
    });
  }

  const tasks: ImportedTask[] = [];
  for (const t of data.tasks) {
    const title = t.content?.trim();
    if (!title) {
      warnings.add("untitledSkipped");
      continue;
    }
    const inInbox = inboxIds.has(t.project_id) || !projectIds.has(t.project_id);
    let due = mapDue(
      { text: t.due?.string ?? "", date: t.due?.datetime || t.due?.date || null, recurring: t.due?.is_recurring === true },
      t.description?.trim() || null,
      ctx.timeZone,
      warnings,
    );
    due = mapDeadline(due, t.deadline?.date ?? null, ctx.timeZone, warnings);
    const done = t.is_completed === true || t.checked === true;
    tasks.push({
      key: nativeKey("task", t.id),
      projectKey: inInbox ? null : nativeKey("project", t.project_id),
      sectionKey: !inInbox && t.section_id && sectionIds.has(t.section_id) ? nativeKey("section", t.section_id) : null,
      parentKey: t.parent_id ? nativeKey("task", t.parent_id) : null,
      title,
      notes: due.notes,
      priority: todoistPriority(t.priority),
      tags: t.labels ?? [],
      dueDate: due.dueDate,
      dueTime: due.dueTime,
      recurrence: due.recurrence,
      done,
      completedAt: null,
      sortOrder: order(t),
      reminders: [],
    });
  }
  return { projects, sections, tasks: orderTasks(tasks).map(fitTask), warnings: warnings.list() };
}

const TOKEN_REJECTED = new ImportError(
  "token_rejected",
  "رفض Todoist رمز الوصول. انسخ الرمز من Todoist: «الإعدادات ← التكاملات ← المطوّر»، ثم أعد المحاولة.",
);

/** Every item of a list endpoint, following `next_cursor` pages when the API pages. `rejected` is the job's message for a refused token. */
async function getAll<T>(path: string, token: string, fetcher: typeof fetch, rejected: ImportError): Promise<T[]> {
  const out: T[] = [];
  let cursor: string | null = null;
  for (let page = 0; page < 200; page++) {
    const url = new URL(`${TODOIST_API}/${path}`);
    if (cursor) url.searchParams.set("cursor", cursor);
    let response: Response;
    try {
      response = await fetcher(url.toString(), { headers: { Authorization: `Bearer ${token}` } });
    } catch {
      throw new TransientImportError(`Todoist ${path}: network error`);
    }
    if (response.status === 401 || response.status === 403) throw rejected;
    if (response.status === 429 || response.status >= 500) {
      const retryAfter = Number(response.headers.get("Retry-After"));
      throw new TransientImportError(`Todoist ${path}: HTTP ${response.status}`, Number.isFinite(retryAfter) ? retryAfter : undefined);
    }
    if (!response.ok) {
      throw new ImportError("source_error", `رفض Todoist الطلب (${response.status}). أعد المحاولة لاحقاً.`);
    }
    let body: unknown;
    try {
      body = await response.json();
    } catch {
      throw new TransientImportError(`Todoist ${path}: unreadable response`);
    }
    if (Array.isArray(body)) return [...out, ...(body as T[])];
    const pageBody = body as { results?: T[]; next_cursor?: string | null };
    if (!Array.isArray(pageBody?.results)) throw new TransientImportError(`Todoist ${path}: unexpected response`);
    out.push(...pageBody.results);
    cursor = pageBody.next_cursor ?? null;
    if (!cursor) return out;
  }
  return out;
}

/** Projects, sections and open tasks, read with a pasted token or one from Todoist's OAuth flow. */
async function loadTodoist(token: string, ctx: LoadContext, rejected: ImportError): Promise<ImportBundle> {
  const [projects, sections, tasks] = await Promise.all([
    getAll<TodoistProject>("projects", token, ctx.fetch, rejected),
    getAll<TodoistSection>("sections", token, ctx.fetch, rejected),
    getAll<TodoistTask>("tasks", token, ctx.fetch, rejected),
  ]);
  return mapTodoist({ projects, sections, tasks }, ctx);
}

export const todoistApi: TokenSource = {
  id: "todoist-api",
  label: "Todoist",
  refSource: "todoist",
  input: "token",
  load: (token, ctx) => loadTodoist(token, ctx, TOKEN_REJECTED),
};

/** The same import, with the token from Todoist's OAuth flow (`data:read`) instead of a pasted one. */
export const todoistOAuth: TokenSource = {
  id: "todoist-oauth",
  label: "Todoist",
  refSource: "todoist",
  input: "oauth",
  load: (token, ctx) => loadTodoist(token, ctx, tokenRejected("Todoist")),
};
