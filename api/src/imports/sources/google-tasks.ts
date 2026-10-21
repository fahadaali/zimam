import { addNote, fitName, fitTask, type ImportBundle, ImportError, type ImportedProject, type ImportedTask, LIMITS, orderTasks, Warnings } from "../model";
import { type FileSource, nativeKey, type ParseContext, type TokenSource } from "../source";
import { MAX_PAGES, type Provider, providerGet } from "./provider-http";

export const TASKS_API = "https://tasks.googleapis.com/tasks/v1";

/** A task as both Takeout's Tasks.json and the Tasks API write it. */
export interface GoogleTask {
  id?: string;
  title?: string;
  notes?: string;
  status?: string;
  due?: string;
  completed?: string;
  parent?: string;
  position?: string;
  deleted?: boolean;
  links?: { type?: string; description?: string; link?: string }[];
}

export interface GoogleTaskList {
  id?: string;
  title?: string;
  items?: GoogleTask[];
}

const NOT_GOOGLE_TASKS = new ImportError(
  "invalid_file",
  "هذا ليس ملف مهام Google. نزّل بياناتك من Google Takeout باختيار «Tasks»، ثم ارفع ملف Tasks.json من داخل الأرشيف.",
);

/**
 * Tasks.json from Google Takeout: `{ items: [taskList] }`, each list with its tasks.
 */
export function parseGoogleTasks(text: string, _ctx: ParseContext): ImportBundle {
  let data: unknown;
  try {
    data = JSON.parse(text);
  } catch {
    throw NOT_GOOGLE_TASKS;
  }
  const lists = (data as { items?: unknown })?.items;
  const isList = (l: unknown) => !!l && typeof l === "object" && ("items" in l || "title" in l);
  if (!Array.isArray(lists) || !lists.every(isList)) {
    throw NOT_GOOGLE_TASKS;
  }
  return mapGoogleTasks(lists as GoogleTaskList[]);
}

/**
 * Task lists, from the file or the API, to a bundle. Each list becomes a project. Google keeps
 * only a due date (the time part of `due` is always midnight UTC and means nothing), so the date
 * is read as written. Completed tasks come in as done; deleted ones are skipped. Keys are Google's
 * own ids, so the file and the account import update the same tasks.
 */
export function mapGoogleTasks(lists: GoogleTaskList[]): ImportBundle {
  const warnings = new Warnings();
  const projects: ImportedProject[] = [];
  const tasks: ImportedTask[] = [];
  lists.forEach((list, listIndex) => {
    if (!list.id) return;
    const projectKey = nativeKey("list", list.id);
    projects.push({
      key: projectKey,
      name: fitName(list.title ?? "", LIMITS.projectName) || "Google Tasks",
      kind: "project",
      parentKey: null,
      view: "list",
      sortOrder: listIndex,
      archived: false,
    });
    const items = (Array.isArray(list.items) ? list.items : []).filter((t) => t && t.id);
    // Google orders siblings by `position`, a zero-padded string.
    items.sort((a, b) => (a.position ?? "").localeCompare(b.position ?? ""));
    items.forEach((t, index) => {
      if (t.deleted) {
        warnings.add("deletedSkipped");
        return;
      }
      const title = t.title?.trim();
      if (!title) {
        warnings.add("untitledSkipped");
        return;
      }
      let notes = t.notes?.trim() || null;
      for (const link of t.links ?? []) {
        if (link.link) notes = addNote(notes, [link.description, link.link].filter(Boolean).join(": "));
      }
      const due = t.due?.match(/^(\d{4}-\d{2}-\d{2})/)?.[1] ?? null;
      const done = t.status === "completed";
      const completed = t.completed ? Date.parse(t.completed) : Number.NaN;
      tasks.push({
        key: nativeKey("task", t.id!),
        projectKey,
        sectionKey: null,
        parentKey: t.parent ? nativeKey("task", t.parent) : null,
        title,
        notes,
        priority: 0,
        tags: [],
        dueDate: due,
        dueTime: null,
        recurrence: null,
        done,
        completedAt: done && Number.isFinite(completed) ? completed : null,
        sortOrder: index,
        reminders: [],
      });
    });
  });
  return { projects, sections: [], tasks: orderTasks(tasks).map(fitTask), warnings: warnings.list() };
}

export const googleTasks: FileSource = {
  id: "google-tasks",
  label: "Google Tasks",
  refSource: "google-tasks",
  input: "file",
  extensions: [".json"],
  parse: parseGoogleTasks,
};

/** Every page of a Tasks API listing (`items`, `nextPageToken`). */
async function listAll<T>(provider: Provider, url: URL): Promise<T[]> {
  const out: T[] = [];
  for (let page = 0; page < MAX_PAGES; page++) {
    const body = await providerGet<{ items?: T[]; nextPageToken?: string }>(provider, url.toString());
    out.push(...(body?.items ?? []));
    if (!body?.nextPageToken) break;
    url.searchParams.set("pageToken", body.nextPageToken);
  }
  return out;
}

/** The user's task lists and their tasks, completed ones included, read with `tasks.readonly`. */
export async function readGoogleTasks(provider: Provider): Promise<GoogleTaskList[]> {
  const listsUrl = new URL(`${TASKS_API}/users/@me/lists`);
  listsUrl.searchParams.set("maxResults", "100");
  const lists = await listAll<GoogleTaskList>(provider, listsUrl);
  const out: GoogleTaskList[] = [];
  for (const list of lists) {
    if (!list.id) continue;
    const url = new URL(`${TASKS_API}/lists/${encodeURIComponent(list.id)}/tasks`);
    url.searchParams.set("maxResults", "100");
    // Completed tasks cleared from the list are hidden; Takeout has them, so the import does too.
    url.searchParams.set("showCompleted", "true");
    url.searchParams.set("showHidden", "true");
    out.push({ id: list.id, title: list.title, items: await listAll<GoogleTask>(provider, url) });
  }
  return out;
}

export const googleTasksApi: TokenSource = {
  id: "google-tasks-api",
  label: "Google Tasks",
  refSource: "google-tasks",
  input: "oauth",
  async load(token, ctx) {
    const lists = await readGoogleTasks({ label: "Google Tasks", fetch: ctx.fetch, headers: { Authorization: `Bearer ${token}` } });
    return mapGoogleTasks(lists);
  },
};
