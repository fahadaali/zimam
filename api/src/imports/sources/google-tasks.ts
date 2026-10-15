import { addNote, fitName, fitTask, type ImportBundle, ImportError, type ImportedProject, type ImportedTask, LIMITS, orderTasks, Warnings } from "../model";
import { type FileSource, nativeKey, type ParseContext } from "../source";

interface GoogleTask {
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

interface GoogleTaskList {
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
 * Each list becomes a project. Google keeps only a due date (the time part of `due`
 * is always midnight UTC and means nothing), so the date is read as written.
 * Completed tasks come in as done; deleted ones are skipped.
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
  const warnings = new Warnings();
  const projects: ImportedProject[] = [];
  const tasks: ImportedTask[] = [];
  (lists as GoogleTaskList[]).forEach((list, listIndex) => {
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
