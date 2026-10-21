import { zonedDateTime } from "../dates";
import { fitName, fitTask, type ImportBundle, type ImportedProject, type ImportedSection, type ImportedTask, LIMITS, orderTasks, Warnings } from "../model";
import { nativeKey, type ParseContext, type TokenSource } from "../source";
import { MAX_PAGES, type Provider, providerGet } from "./provider-http";

export const CLICKUP_API = "https://api.clickup.com/api/v2";

interface ClickUpStatus {
  status?: string;
  /** "open" (the first), "custom", "done" or "closed". */
  type?: string;
  orderindex?: number | string;
}

export interface ClickUpTask {
  id: string;
  name?: string;
  text_content?: string | null;
  description?: string | null;
  status?: ClickUpStatus;
  /** Milliseconds since the epoch, as a string. */
  due_date?: string | null;
  /** Whether the due date carries a time; without it the date is a day. */
  due_date_time?: boolean;
  start_date?: string | null;
  date_closed?: string | null;
  date_done?: string | null;
  priority?: { priority?: string } | null;
  tags?: { name?: string }[];
  parent?: string | null;
  orderindex?: string | number;
  archived?: boolean;
}

interface ClickUpList {
  id: string;
  name?: string;
  archived?: boolean;
}

export interface ClickUpData {
  spaces: {
    space: { id: string; name?: string };
    /** Folders hidden by ClickUp hold a space's folderless lists: those go straight in the space. */
    folders: { folder: { id: string; name?: string; hidden?: boolean }; lists: { list: ClickUpList; tasks: ClickUpTask[] }[] }[];
    lists: { list: ClickUpList; tasks: ClickUpTask[] }[];
  }[];
}

/** ClickUp's priorities: urgent and high are Zimam's high, normal medium, low low. */
const PRIORITY: Record<string, number> = { urgent: 3, high: 3, normal: 2, low: 1 };

const isDone = (status: ClickUpStatus | undefined) => status?.type === "done" || status?.type === "closed";
const order = (value: string | number | undefined) => {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
};
const instant = (value: string | null | undefined) => {
  const n = Number(value);
  return value && Number.isFinite(n) && n > 0 ? n : null;
};

/**
 * ClickUp: each space a folder, each visible folder a folder inside it, and each list a project.
 * The list's open statuses (from its tasks, in ClickUp's order) become sections, and the list a
 * kanban board when it has more than one; a task in a done or closed status comes in done. The
 * due date is a day in the user's zone, with its time when ClickUp marks it timed; the start date
 * a day. Priorities and tags carry over; subtasks sit under their task. A task in several lists
 * is imported once, in the first.
 */
export function mapClickUp(data: ClickUpData, ctx: ParseContext): ImportBundle {
  const warnings = new Warnings();
  const projects: ImportedProject[] = [];
  const sections: ImportedSection[] = [];
  const tasks: ImportedTask[] = [];
  const seen = new Set<string>();
  const zone = ctx.timeZone;

  const addList = (list: ClickUpList, listTasks: ClickUpTask[], parentKey: string, sortOrder: number) => {
    if (list.archived) {
      warnings.add("archivedSkipped");
      return;
    }
    const projectKey = nativeKey("list", list.id);
    // Open statuses in ClickUp's order: the list's columns.
    const statuses = new Map<string, number>();
    for (const t of listTasks) {
      const name = t.status?.status?.trim();
      if (name && !isDone(t.status) && !statuses.has(name)) statuses.set(name, order(t.status?.orderindex));
    }
    const sectionKeys = new Map<string, string>();
    [...statuses.entries()]
      .sort((a, b) => a[1] - b[1])
      .forEach(([name], index) => {
        const key = nativeKey("status", `${list.id}:${name}`);
        sectionKeys.set(name, key);
        sections.push({ key, projectKey, name: fitName(name, LIMITS.sectionName), sortOrder: index });
      });
    projects.push({
      key: projectKey,
      name: fitName(list.name ?? "", LIMITS.projectName) || "ClickUp",
      kind: "project",
      parentKey,
      view: sectionKeys.size > 1 ? "kanban" : "list",
      sortOrder,
      archived: false,
    });
    [...listTasks].sort((a, b) => order(a.orderindex) - order(b.orderindex)).forEach((t, index) => {
      if (seen.has(t.id)) return;
      seen.add(t.id);
      if (t.archived) {
        warnings.add("archivedSkipped");
        return;
      }
      const title = t.name?.trim();
      if (!title) {
        warnings.add("untitledSkipped");
        return;
      }
      const dueAt = instant(t.due_date);
      const due = dueAt !== null ? zonedDateTime(dueAt, zone) : null;
      const startAt = instant(t.start_date);
      const done = isDone(t.status);
      tasks.push({
        key: nativeKey("task", t.id),
        projectKey,
        sectionKey: done ? null : (sectionKeys.get(t.status?.status?.trim() ?? "") ?? null),
        parentKey: t.parent ? nativeKey("task", t.parent) : null,
        title,
        notes: (t.text_content ?? t.description)?.trim() || null,
        priority: PRIORITY[t.priority?.priority ?? ""] ?? 0,
        tags: (t.tags ?? []).map((tag) => tag.name ?? ""),
        dueDate: due?.date ?? null,
        dueTime: due && t.due_date_time === true ? due.time : null,
        startDate: startAt !== null ? zonedDateTime(startAt, zone).date : null,
        recurrence: null,
        done,
        completedAt: done ? (instant(t.date_done) ?? instant(t.date_closed)) : null,
        sortOrder: index,
        reminders: [],
      });
    });
  };

  data.spaces.forEach(({ space, folders, lists }, spaceIndex) => {
    const spaceKey = nativeKey("space", space.id);
    projects.push({
      key: spaceKey,
      name: fitName(space.name ?? "", LIMITS.projectName) || "ClickUp",
      kind: "folder",
      parentKey: null,
      view: "list",
      sortOrder: spaceIndex,
      archived: false,
    });
    let sortOrder = 0;
    for (const { folder, lists: folderLists } of folders) {
      let parentKey = spaceKey;
      if (!folder.hidden) {
        parentKey = nativeKey("folder", folder.id);
        projects.push({
          key: parentKey,
          name: fitName(folder.name ?? "", LIMITS.projectName) || "ClickUp",
          kind: "folder",
          parentKey: spaceKey,
          view: "list",
          sortOrder: sortOrder++,
          archived: false,
        });
      }
      folderLists.forEach(({ list, tasks: listTasks }, i) => addList(list, listTasks, parentKey, i));
    }
    for (const { list, tasks: listTasks } of lists) addList(list, listTasks, spaceKey, sortOrder++);
  });
  return { projects, sections, tasks: orderTasks(tasks).map(fitTask), warnings: warnings.list() };
}

/** A list's tasks, every page: open and closed, subtasks included, archived ones left out. */
async function listTasks(provider: Provider, listId: string): Promise<ClickUpTask[]> {
  const out: ClickUpTask[] = [];
  const url = new URL(`${CLICKUP_API}/list/${encodeURIComponent(listId)}/task`);
  url.searchParams.set("archived", "false");
  url.searchParams.set("include_closed", "true");
  url.searchParams.set("subtasks", "true");
  for (let page = 0; page < MAX_PAGES; page++) {
    url.searchParams.set("page", String(page));
    const body = await providerGet<{ tasks?: ClickUpTask[]; last_page?: boolean }>(provider, url.toString());
    const batch = body?.tasks ?? [];
    out.push(...batch);
    if (body?.last_page !== false || batch.length === 0) break;
  }
  return out;
}

export const clickup: TokenSource = {
  id: "clickup",
  label: "ClickUp",
  refSource: "clickup",
  input: "oauth",
  async load(token, ctx) {
    // ClickUp takes the OAuth token as it is, without "Bearer".
    const provider: Provider = { label: "ClickUp", fetch: ctx.fetch, headers: { Authorization: token } };
    const get = <T>(path: string) => providerGet<T>(provider, `${CLICKUP_API}${path}`);
    const withTasks = async (lists: ClickUpList[] | undefined) => {
      const out: { list: ClickUpList; tasks: ClickUpTask[] }[] = [];
      for (const list of lists ?? []) out.push({ list, tasks: list.archived ? [] : await listTasks(provider, list.id) });
      return out;
    };
    const data: ClickUpData = { spaces: [] };
    const { teams } = await get<{ teams?: { id: string }[] }>("/team");
    for (const team of teams ?? []) {
      const { spaces } = await get<{ spaces?: { id: string; name?: string }[] }>(`/team/${encodeURIComponent(team.id)}/space?archived=false`);
      for (const space of spaces ?? []) {
        const id = encodeURIComponent(space.id);
        const { folders } = await get<{ folders?: { id: string; name?: string; hidden?: boolean }[] }>(`/space/${id}/folder?archived=false`);
        const entry: ClickUpData["spaces"][number] = { space, folders: [], lists: [] };
        for (const folder of folders ?? []) {
          const { lists } = await get<{ lists?: ClickUpList[] }>(`/folder/${encodeURIComponent(folder.id)}/list?archived=false`);
          entry.folders.push({ folder, lists: await withTasks(lists) });
        }
        const { lists } = await get<{ lists?: ClickUpList[] }>(`/space/${id}/list?archived=false`);
        entry.lists = await withTasks(lists);
        data.spaces.push(entry);
      }
    }
    return mapClickUp(data, ctx);
  },
};
