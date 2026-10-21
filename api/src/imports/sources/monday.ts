import { zonedDateTime } from "../dates";
import { fitName, fitTask, type ImportBundle, ImportError, type ImportedProject, type ImportedSection, type ImportedTask, LIMITS, orderTasks, Warnings } from "../model";
import { nativeKey, type ParseContext, type TokenSource } from "../source";
import { MAX_PAGES, type Provider, providerGet } from "./provider-http";

export const MONDAY_API = "https://api.monday.com/v2";

interface MondayColumnValue {
  id: string;
  type?: string;
  text?: string | null;
  /** DateValue: a day, and a time in UTC when the column has one. */
  date?: string | null;
  time?: string | null;
  /** TimelineValue: the first and last day. */
  from?: string | null;
  to?: string | null;
  column?: { title?: string } | null;
}

export interface MondayItem {
  id: string;
  name?: string;
  /** "active", "archived" or "deleted". */
  state?: string;
  group?: { id: string } | null;
  column_values?: MondayColumnValue[];
  subitems?: MondayItem[];
}

export interface MondayBoard {
  id: string;
  name?: string;
  /** "board"; sub-item boards and documents are left out. */
  type?: string;
  groups?: { id: string; title?: string; position?: string }[];
}

export interface MondayData {
  boards: { board: MondayBoard; items: MondayItem[] }[];
}

/** Status labels that mean done, in the languages Zimam's users are likely to name them. */
const DONE = /^(done|complete|completed|finished|closed|تم|منجز|منجزة|مكتمل|مكتملة|منتهي|منتهية|انتهى)$/i;
/** A status column that holds the priority rather than the progress. */
const PRIORITY_COLUMN = /priority|أولوية|الأولوية/i;
const PRIORITY: Record<string, number> = {
  critical: 3, high: 3, urgent: 3, "عالية": 3, "عاجلة": 3, "حرجة": 3,
  medium: 2, "متوسطة": 2,
  low: 1, "منخفضة": 1,
};

/**
 * monday.com: each board a project, its groups (in their order) its sections, and each item a task
 * in its group, with its sub-items as subtasks. The first status column that is not a priority
 * marks the item done when its label means done («Done», «تم»…); a priority status column gives the
 * priority. A date column gives the due day (and time, in the user's zone, when it has one), a
 * timeline its start and due days; a tags column the tags; a long text column the notes. Archived
 * and deleted items are left out.
 */
export function mapMonday(data: MondayData, ctx: ParseContext): ImportBundle {
  const warnings = new Warnings();
  const projects: ImportedProject[] = [];
  const sections: ImportedSection[] = [];
  const tasks: ImportedTask[] = [];

  const toTask = (item: MondayItem, projectKey: string, sectionKey: string | null, parentKey: string | null, index: number) => {
    if (item.state && item.state !== "active") {
      warnings.add("archivedSkipped");
      return;
    }
    const title = item.name?.trim();
    if (!title) {
      warnings.add("untitledSkipped");
      return;
    }
    const values = item.column_values ?? [];
    const statuses = values.filter((v) => v.type === "status");
    const priorityValue = statuses.find((v) => PRIORITY_COLUMN.test(v.column?.title ?? ""));
    const progress = statuses.find((v) => v !== priorityValue);
    const date = values.find((v) => v.type === "date" && v.date);
    const timeline = values.find((v) => v.type === "timeline" && (v.from || v.to));
    let dueDate: string | null = null;
    let dueTime: string | null = null;
    if (date?.date && date.time) {
      const at = zonedDateTime(Date.parse(`${date.date}T${date.time}Z`), ctx.timeZone);
      dueDate = at.date;
      dueTime = at.time;
    } else if (date?.date) {
      dueDate = date.date;
    } else if (timeline) {
      dueDate = timeline.to ?? timeline.from ?? null;
    }
    const tags = (values.find((v) => v.type === "tags")?.text ?? "")
      .split(",")
      .map((t) => t.trim())
      .filter(Boolean);
    const key = nativeKey("item", item.id);
    tasks.push({
      key,
      projectKey,
      sectionKey,
      parentKey,
      title,
      notes: values.find((v) => v.type === "long_text")?.text?.trim() || null,
      priority: PRIORITY[(priorityValue?.text ?? "").trim().toLowerCase()] ?? 0,
      tags,
      dueDate,
      dueTime,
      startDate: !date && timeline?.from && timeline.to && timeline.from < timeline.to ? timeline.from : null,
      recurrence: null,
      done: DONE.test((progress?.text ?? "").trim()),
      completedAt: null,
      sortOrder: index,
      reminders: [],
    });
    (item.subitems ?? []).forEach((sub, i) => toTask(sub, projectKey, sectionKey, key, i));
  };

  data.boards.forEach(({ board, items }, boardIndex) => {
    const projectKey = nativeKey("board", board.id);
    projects.push({
      key: projectKey,
      name: fitName(board.name ?? "", LIMITS.projectName) || "monday.com",
      kind: "project",
      parentKey: null,
      view: "list",
      sortOrder: boardIndex,
      archived: false,
    });
    [...(board.groups ?? [])]
      .sort((a, b) => Number(a.position ?? 0) - Number(b.position ?? 0))
      .forEach((g, i) => {
        sections.push({ key: nativeKey("group", `${board.id}:${g.id}`), projectKey, name: fitName(g.title ?? "", LIMITS.sectionName) || "monday.com", sortOrder: i });
      });
    items.forEach((item, index) => toTask(item, projectKey, item.group ? nativeKey("group", `${board.id}:${item.group.id}`) : null, null, index));
  });
  return { projects, sections, tasks: orderTasks(tasks).map(fitTask), warnings: warnings.list() };
}

const VALUES = `column_values { id type text column { title } ... on DateValue { date time } ... on TimelineValue { from to } }`;
const ITEM = `id name state group { id } ${VALUES} subitems { id name state ${VALUES} }`;

const BOARDS_QUERY = `query Boards($page: Int!) {
  boards(limit: 50, page: $page, state: active) { id name type groups { id title position } }
}`;
const FIRST_ITEMS = `query Items($board: [ID!]) {
  boards(ids: $board) { items_page(limit: 100) { cursor items { ${ITEM} } } }
}`;
const NEXT_ITEMS = `query Next($cursor: String!) {
  next_items_page(limit: 100, cursor: $cursor) { cursor items { ${ITEM} } }
}`;

/** One GraphQL request. A GraphQL error fails the import with monday.com's name. */
async function graphql<T>(provider: Provider, query: string, variables: Record<string, unknown>): Promise<T> {
  const body = await providerGet<{ data?: T; errors?: unknown[]; error_message?: string }>(provider, MONDAY_API, { method: "POST", body: { query, variables } });
  if (!body?.data || body.errors?.length || body.error_message) {
    throw new ImportError("source_error", "رفض monday.com الطلب. أعد المحاولة لاحقاً.");
  }
  return body.data;
}

export const monday: TokenSource = {
  id: "monday",
  label: "monday.com",
  refSource: "monday",
  input: "oauth",
  async load(token, ctx) {
    // monday.com takes the token as it is.
    const provider: Provider = { label: "monday.com", fetch: ctx.fetch, headers: { Authorization: token } };
    const data: MondayData = { boards: [] };
    for (let page = 1; page <= MAX_PAGES; page++) {
      const { boards } = await graphql<{ boards?: MondayBoard[] }>(provider, BOARDS_QUERY, { page });
      for (const board of boards ?? []) {
        if (board.type && board.type !== "board") continue;
        const first = await graphql<{ boards?: { items_page?: { cursor?: string | null; items?: MondayItem[] } }[] }>(provider, FIRST_ITEMS, { board: [board.id] });
        const items = [...(first.boards?.[0]?.items_page?.items ?? [])];
        let cursor = first.boards?.[0]?.items_page?.cursor ?? null;
        for (let i = 0; cursor && i < MAX_PAGES; i++) {
          const next = await graphql<{ next_items_page?: { cursor?: string | null; items?: MondayItem[] } }>(provider, NEXT_ITEMS, { cursor });
          items.push(...(next.next_items_page?.items ?? []));
          cursor = next.next_items_page?.cursor ?? null;
        }
        data.boards.push({ board, items });
      }
      if (!boards || boards.length < 50) break;
    }
    return mapMonday(data, ctx);
  },
};
