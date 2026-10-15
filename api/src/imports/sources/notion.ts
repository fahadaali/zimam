import { foldForSearch } from "../../data/arabic";
import { isTimeZone, type LocalDateTime, localToInstant, parseDateText, zonedDateTime } from "../dates";
import { fitName, fitTask, type ImportBundle, ImportError, type ImportedProject, type ImportedTask, LIMITS, orderTasks, Warnings } from "../model";
import { nativeKey, type ParseContext, type TokenSource } from "../source";
import { genericPriority } from "./generic-csv";
import { MAX_PAGES, type Provider, providerGet } from "./provider-http";

export const NOTION_API = "https://api.notion.com/v1";
/** The API version every request names. 2022-06-28 reads a database as one table (before data sources). */
export const NOTION_VERSION = "2022-06-28";

interface RichText {
  plain_text?: string;
}

interface PropertySchema {
  id?: string;
  name?: string;
  type: string;
  status?: { options?: { id: string; name: string }[]; groups?: { name: string; option_ids?: string[] }[] };
}

export interface NotionDatabase {
  id: string;
  title?: RichText[];
  properties: Record<string, PropertySchema>;
  archived?: boolean;
  in_trash?: boolean;
}

interface PropertyValue {
  type: string;
  title?: RichText[];
  rich_text?: RichText[];
  date?: { start?: string; end?: string | null; time_zone?: string | null } | null;
  checkbox?: boolean;
  status?: { id?: string; name?: string } | null;
  select?: { name?: string } | null;
  multi_select?: { name?: string }[];
  relation?: { id: string }[];
}

export interface NotionPage {
  id: string;
  archived?: boolean;
  in_trash?: boolean;
  properties: Record<string, PropertyValue>;
}

export interface NotionData {
  databases: { database: NotionDatabase; pages: NotionPage[] }[];
}

const text = (parts: RichText[] | undefined) => (parts ?? []).map((p) => p.plain_text ?? "").join("");

/** Property names, matched case- and diacritic-insensitively. */
const NAMES = {
  date: /(due|deadline|date|when|schedule|موعد|تاريخ|استحقاق|تسليم)/i,
  done: /(done|complete|finished|checked|منجز|تم|مكتمل|انتهى)/i,
  status: /(status|state|progress|الحالة|حالة)/i,
  priority: /(priority|importance|urgency|أولوي|الأهمية|أهمية)/i,
  tags: /(tag|label|categor|وسم|وسوم|تصنيف)/i,
  notes: /(note|description|details|summary|ملاحظ|وصف|تفاصيل)/i,
  parent: /(parent|الأب|الأصل)/i,
};

const DONE_WORDS = new Set(
  ["done", "complete", "completed", "finished", "closed", "منجز", "منجزة", "مكتمل", "مكتملة", "تم", "تمت", "منتهية"].map(foldForSearch),
);

/** Notion's own bookkeeping, not the user's data: not reported as left behind. */
const SYSTEM_TYPES = new Set(["created_time", "created_by", "last_edited_time", "last_edited_by", "unique_id", "formula", "rollup", "button", "verification"]);

/** Which property of a database fills which field of a task. */
export interface NotionMapping {
  title: string;
  date: string | null;
  done: { name: string; type: "status" | "checkbox" | "select"; doneIds: Set<string> } | null;
  priority: string | null;
  tags: string | null;
  notes: string | null;
  parent: string | null;
}

/**
 * The heuristics, in order (api/DEVELOPMENT.md, «الاستيراد»):
 * - title: the database's title property (every database has one).
 * - date: the date property named like «due/deadline/date/موعد/تاريخ», else the first date property.
 * - done: a status property (named like «status/الحالة» first) whose option is in the «Complete»
 *   group or is named «Done/منجز»; else a checkbox named like «done/منجز», else the first
 *   checkbox; else a select named like «status/الحالة» whose option is named «Done/منجز».
 * - priority: a select (or status) named like «priority/الأولوية»: High/عالية 3, Medium/متوسطة 2, Low/منخفضة 1.
 * - tags: a multi-select named like «tags/labels/وسوم», else the first multi-select.
 * - notes: a text property named like «notes/description/ملاحظات/وصف».
 * - subtasks: a relation named like «Parent item» (Notion's sub-items) with one page.
 */
export function notionMapping(db: NotionDatabase): NotionMapping | null {
  const entries = Object.entries(db.properties ?? {});
  const named = (type: string | string[], pattern?: RegExp, except: (string | null)[] = []) => {
    const types = Array.isArray(type) ? type : [type];
    const of = entries.filter(([name, p]) => types.includes(p.type) && !except.includes(name));
    return (pattern ? of.find(([name]) => pattern.test(name)) : undefined)?.[0] ?? null;
  };
  const first = (type: string, except: (string | null)[] = []) => entries.find(([name, p]) => p.type === type && !except.includes(name))?.[0] ?? null;

  const title = first("title");
  if (!title) return null;
  const date = named("date", NAMES.date) ?? first("date");

  let done: NotionMapping["done"] = null;
  const status = named("status", NAMES.status) ?? first("status");
  if (status) {
    const schema = db.properties[status]!.status;
    const complete = (schema?.groups ?? []).filter((g) => /complete|done|مكتمل|منجز/i.test(g.name)).flatMap((g) => g.option_ids ?? []);
    const doneOptions = (schema?.options ?? []).filter((o) => DONE_WORDS.has(foldForSearch(o.name))).map((o) => o.id);
    done = { name: status, type: "status", doneIds: new Set([...complete, ...doneOptions]) };
  } else {
    const checkbox = named("checkbox", NAMES.done) ?? first("checkbox");
    if (checkbox) done = { name: checkbox, type: "checkbox", doneIds: new Set() };
    else {
      const select = named("select", NAMES.status);
      if (select) done = { name: select, type: "select", doneIds: new Set() };
    }
  }
  const priority = named(["select", "status"], NAMES.priority, [done?.name ?? null]);
  const tags = named("multi_select", NAMES.tags) ?? first("multi_select");
  const notes = named("rich_text", NAMES.notes);
  const parent = named("relation", NAMES.parent);
  return { title, date, done, priority, tags, notes, parent };
}

/** A Notion date ("2026-10-20", "2026-10-20T09:00:00.000+03:00", or a wall clock with `time_zone`) in the user's zone. */
function notionDate(value: string | null | undefined, zone: string | null | undefined, userZone: string): LocalDateTime | null {
  if (!value) return null;
  const wall = value.match(/^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})(?::\d{2}(?:\.\d+)?)?$/);
  if (wall && isTimeZone(zone)) return zonedDateTime(localToInstant(wall[1]!, wall[2]!, zone), userZone);
  return parseDateText(value, userZone);
}

function isDone(mapping: NotionMapping, value: PropertyValue | undefined): boolean {
  if (!mapping.done || !value) return false;
  switch (mapping.done.type) {
    case "checkbox":
      return value.checkbox === true;
    case "status":
      return (!!value.status?.id && mapping.done.doneIds.has(value.status.id)) || DONE_WORDS.has(foldForSearch(value.status?.name ?? ""));
    case "select":
      return DONE_WORDS.has(foldForSearch(value.select?.name ?? ""));
  }
}

/**
 * The databases shared with Zimam in Notion's consent page, each a project, and their pages as
 * tasks through `notionMapping`. Pages in the trash are skipped. Properties that no field takes
 * are named in a warning, per database.
 */
export function mapNotion(data: NotionData, ctx: ParseContext): ImportBundle {
  const warnings = new Warnings();
  const extra: string[] = [];
  const projects: ImportedProject[] = [];
  const tasks: ImportedTask[] = [];

  data.databases.forEach(({ database, pages }, dbIndex) => {
    if (database.archived || database.in_trash) {
      warnings.add("archivedSkipped");
      return;
    }
    const mapping = notionMapping(database);
    if (!mapping) {
      warnings.add("databasesSkipped");
      return;
    }
    const name = fitName(text(database.title), LIMITS.projectName) || "Notion";
    const projectKey = nativeKey("database", database.id);
    projects.push({ key: projectKey, name, kind: "project", parentKey: null, view: "list", sortOrder: dbIndex, archived: false });

    const used = new Set([mapping.title, mapping.date, mapping.done?.name, mapping.priority, mapping.tags, mapping.notes, mapping.parent]);
    const left = Object.entries(database.properties)
      .filter(([n, p]) => !used.has(n) && !SYSTEM_TYPES.has(p.type))
      .map(([n]) => n);
    if (left.length) extra.push(`خصائص من «${name}» لم تُنقل: ${left.join("، ")}`);

    pages.forEach((page, index) => {
      if (page.archived || page.in_trash) {
        warnings.add("archivedSkipped");
        return;
      }
      const p = page.properties ?? {};
      const title = text(p[mapping.title]?.title).trim();
      if (!title) {
        warnings.add("untitledSkipped");
        return;
      }
      const date = mapping.date ? p[mapping.date]?.date : null;
      const start = notionDate(date?.start, date?.time_zone, ctx.timeZone);
      const end = notionDate(date?.end, date?.time_zone, ctx.timeZone);
      const due = end ?? start;
      const done = isDone(mapping, mapping.done ? p[mapping.done.name] : undefined);
      const priorityValue = mapping.priority ? p[mapping.priority] : undefined;
      const parents = mapping.parent ? (p[mapping.parent]?.relation ?? []) : [];
      tasks.push({
        key: nativeKey("page", page.id),
        projectKey,
        sectionKey: null,
        parentKey: parents.length === 1 ? nativeKey("page", parents[0]!.id) : null,
        title,
        notes: mapping.notes ? text(p[mapping.notes]?.rich_text).trim() || null : null,
        priority: genericPriority(priorityValue?.select?.name ?? priorityValue?.status?.name ?? ""),
        tags: mapping.tags ? (p[mapping.tags]?.multi_select ?? []).map((t) => t.name ?? "") : [],
        dueDate: due?.date ?? null,
        dueTime: due?.time ?? null,
        startDate: end && start ? start.date : null,
        recurrence: null,
        done,
        completedAt: null,
        sortOrder: index,
        reminders: [],
      });
    });
  });
  return { projects, sections: [], tasks: orderTasks(tasks).map(fitTask), warnings: [...warnings.list(), ...extra] };
}

const NO_DATABASE = new ImportError(
  "nothing_to_import",
  "لم تُشارك أي قاعدة بيانات مع زمام في Notion. ابدأ الاستيراد مرة أخرى، واختر في صفحة Notion قاعدة بيانات المهام أو الصفحة التي فيها.",
);

/** Every result of a paged Notion listing (search or query), following `next_cursor`. */
async function allResults<T>(provider: Provider, url: string, body: Record<string, unknown>): Promise<T[]> {
  const out: T[] = [];
  let cursor: string | null = null;
  for (let page = 0; page < MAX_PAGES; page++) {
    const result: { results?: T[]; has_more?: boolean; next_cursor?: string | null } = await providerGet(provider, url, {
      method: "POST",
      body: { ...body, page_size: 100, ...(cursor ? { start_cursor: cursor } : {}) },
    });
    out.push(...(result?.results ?? []));
    cursor = result?.has_more ? (result.next_cursor ?? null) : null;
    if (!cursor) break;
  }
  return out;
}

export const notion: TokenSource = {
  id: "notion",
  label: "Notion",
  refSource: "notion",
  input: "oauth",
  async load(token, ctx) {
    const provider: Provider = {
      label: "Notion",
      fetch: ctx.fetch,
      headers: { Authorization: `Bearer ${token}`, "Notion-Version": NOTION_VERSION },
    };
    const databases = await allResults<NotionDatabase>(provider, `${NOTION_API}/search`, { filter: { property: "object", value: "database" } });
    if (databases.length === 0) throw NO_DATABASE;
    const out: NotionData["databases"] = [];
    for (const database of databases) {
      const pages = database.archived || database.in_trash ? [] : await allResults<NotionPage>(provider, `${NOTION_API}/databases/${encodeURIComponent(database.id)}/query`, {});
      out.push({ database, pages });
    }
    return mapNotion({ databases: out }, ctx);
  },
};
