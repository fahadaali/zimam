import { zonedDateTime } from "../dates";
import { fitName, fitTask, type ImportBundle, type ImportedProject, type ImportedSection, type ImportedTask, LIMITS, orderTasks, Warnings } from "../model";
import { nativeKey, type ParseContext, type TokenSource } from "../source";
import { instantOf, MAX_PAGES, type Provider, providerGet } from "./provider-http";

export const ASANA_API = "https://app.asana.com/api/1.0";

interface AsanaProject {
  gid: string;
  name?: string;
  archived?: boolean;
  /** "list", "board", "calendar", "timeline". */
  default_view?: string;
}

interface AsanaSection {
  gid: string;
  name?: string;
}

export interface AsanaTask {
  gid: string;
  name?: string;
  notes?: string;
  completed?: boolean;
  completed_at?: string | null;
  /** A day, "2026-10-20". */
  due_on?: string | null;
  /** An instant, when the task has a due time. */
  due_at?: string | null;
  start_on?: string | null;
  start_at?: string | null;
  memberships?: { project?: { gid: string }; section?: { gid: string } }[];
  tags?: { name?: string }[];
  num_subtasks?: number;
}

export interface AsanaData {
  projects: { project: AsanaProject; sections: AsanaSection[]; tasks: AsanaTask[] }[];
  /** A task's subtasks, by the task's gid (read only for tasks with `num_subtasks`). */
  subtasks: Record<string, AsanaTask[]>;
}

/** The section Asana makes for tasks in no section of their own. */
const isDefaultSection = (name: string) => /^(untitled section|\(no section\))$/i.test(name.trim());

/**
 * Asana: each project (not archived) a project in Zimam, with its view (board → kanban), its
 * sections (Asana's unnamed default section aside) and tasks; subtasks under their task. A due
 * time (due_at) becomes the due day and time in the user's zone, a due day (due_on) the day;
 * start_on (or start_at) the start day; completed tasks come in done with their time; tags
 * become tags. A task in several projects is imported once, in the first.
 */
export function mapAsana(data: AsanaData, ctx: ParseContext): ImportBundle {
  const warnings = new Warnings();
  const projects: ImportedProject[] = [];
  const sections: ImportedSection[] = [];
  const tasks: ImportedTask[] = [];
  const seen = new Set<string>();
  const zone = ctx.timeZone;

  const add = (t: AsanaTask, projectKey: string, sectionKey: string | null, parentKey: string | null, index: number, depth: number) => {
    if (seen.has(t.gid)) return;
    seen.add(t.gid);
    const title = t.name?.trim();
    if (!title) {
      warnings.add("untitledSkipped");
      return;
    }
    const key = nativeKey("task", t.gid);
    const dueAt = instantOf(t.due_at);
    const due = dueAt !== null ? zonedDateTime(dueAt, zone) : null;
    const startAt = instantOf(t.start_at);
    const done = t.completed === true;
    tasks.push({
      key,
      projectKey,
      sectionKey,
      parentKey,
      title,
      notes: t.notes?.trim() || null,
      priority: 0,
      tags: (t.tags ?? []).map((tag) => tag.name ?? ""),
      dueDate: due?.date ?? t.due_on ?? null,
      dueTime: due?.time ?? null,
      startDate: t.start_on ?? (startAt !== null ? zonedDateTime(startAt, zone).date : null),
      recurrence: null,
      done,
      completedAt: done ? instantOf(t.completed_at) : null,
      sortOrder: index,
      reminders: [],
    });
    if (depth < 5) (data.subtasks[t.gid] ?? []).forEach((sub, i) => add(sub, projectKey, sectionKey, key, i, depth + 1));
  };

  data.projects.forEach(({ project, sections: projectSections, tasks: projectTasks }, projectIndex) => {
    if (project.archived) {
      warnings.add("archivedSkipped");
      return;
    }
    const projectKey = nativeKey("project", project.gid);
    projects.push({
      key: projectKey,
      name: fitName(project.name ?? "", LIMITS.projectName) || "Asana",
      kind: "project",
      parentKey: null,
      view: project.default_view === "board" ? "kanban" : project.default_view === "calendar" ? "calendar" : "list",
      sortOrder: projectIndex,
      archived: false,
    });
    const sectionKeys = new Set<string>();
    for (const s of projectSections) {
      const name = fitName(s.name ?? "", LIMITS.sectionName);
      if (!name || isDefaultSection(name)) continue;
      const key = nativeKey("section", s.gid);
      sectionKeys.add(key);
      sections.push({ key, projectKey, name, sortOrder: sections.filter((x) => x.projectKey === projectKey).length });
    }
    projectTasks.forEach((t, index) => {
      const membership = t.memberships?.find((m) => m.project?.gid === project.gid);
      const sectionKey = membership?.section ? nativeKey("section", membership.section.gid) : null;
      add(t, projectKey, sectionKey && sectionKeys.has(sectionKey) ? sectionKey : null, null, index, 0);
    });
  });
  return { projects, sections, tasks: orderTasks(tasks).map(fitTask), warnings: warnings.list() };
}

const TASK_FIELDS = "name,notes,completed,completed_at,due_on,due_at,start_on,start_at,memberships.project.gid,memberships.section.gid,tags.name,num_subtasks";

/** Every item of an Asana listing, following `next_page.offset`. */
async function allData<T>(provider: Provider, path: string): Promise<T[]> {
  const out: T[] = [];
  const url = new URL(`${ASANA_API}${path}`);
  url.searchParams.set("limit", "100");
  for (let page = 0; page < MAX_PAGES; page++) {
    const body = await providerGet<{ data?: T[]; next_page?: { offset?: string } | null }>(provider, url.toString());
    out.push(...(body?.data ?? []));
    const offset = body?.next_page?.offset;
    if (!offset) break;
    url.searchParams.set("offset", offset);
  }
  return out;
}

export const asana: TokenSource = {
  id: "asana",
  label: "Asana",
  refSource: "asana",
  input: "oauth",
  async load(token, ctx) {
    const provider: Provider = { label: "Asana", fetch: ctx.fetch, headers: { Authorization: `Bearer ${token}` } };
    const data: AsanaData = { projects: [], subtasks: {} };
    const workspaces = await allData<{ gid: string }>(provider, "/workspaces");
    const withSubtasks: AsanaTask[] = [];
    for (const workspace of workspaces) {
      const projects = await allData<AsanaProject>(provider, `/projects?workspace=${encodeURIComponent(workspace.gid)}&archived=false&opt_fields=name,archived,default_view`);
      for (const project of projects) {
        const id = encodeURIComponent(project.gid);
        const [sections, tasks] = await Promise.all([
          allData<AsanaSection>(provider, `/projects/${id}/sections?opt_fields=name`),
          allData<AsanaTask>(provider, `/projects/${id}/tasks?opt_fields=${TASK_FIELDS}`),
        ]);
        data.projects.push({ project, sections, tasks });
        withSubtasks.push(...tasks.filter((t) => (t.num_subtasks ?? 0) > 0));
      }
    }
    // Subtasks, a level at a time, to the depth the mapping keeps.
    for (let depth = 0; depth < 5 && withSubtasks.length; depth++) {
      const level = withSubtasks.splice(0).filter((t) => !data.subtasks[t.gid]);
      for (const t of level) {
        const subtasks = await allData<AsanaTask>(provider, `/tasks/${encodeURIComponent(t.gid)}/subtasks?opt_fields=${TASK_FIELDS}`);
        data.subtasks[t.gid] = subtasks;
        withSubtasks.push(...subtasks.filter((s) => (s.num_subtasks ?? 0) > 0));
      }
    }
    return mapAsana(data, ctx);
  },
};
