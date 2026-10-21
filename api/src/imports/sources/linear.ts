import { fitName, fitTask, type ImportBundle, ImportError, type ImportedProject, type ImportedSection, type ImportedTask, LIMITS, orderTasks, Warnings } from "../model";
import { nativeKey, type ParseContext, type TokenSource } from "../source";
import { instantOf, MAX_PAGES, type Provider, providerGet } from "./provider-http";

export const LINEAR_API = "https://api.linear.app/graphql";

interface LinearState {
  id: string;
  name?: string;
  /** "triage", "backlog", "unstarted", "started", "completed" or "canceled". */
  type?: string;
  position?: number;
}

export interface LinearTeam {
  id: string;
  name?: string;
  states?: { nodes?: LinearState[] };
}

export interface LinearIssue {
  id: string;
  title?: string;
  description?: string | null;
  /** 0 none, 1 urgent, 2 high, 3 medium, 4 low. */
  priority?: number;
  /** A day, "2026-10-22". */
  dueDate?: string | null;
  completedAt?: string | null;
  sortOrder?: number;
  state?: { id: string; type?: string } | null;
  team?: { id: string } | null;
  project?: { name?: string } | null;
  parent?: { id: string } | null;
  labels?: { nodes?: { name?: string }[] };
}

export interface LinearData {
  teams: LinearTeam[];
  issues: LinearIssue[];
}

/** Linear's priorities: urgent and high are Zimam's high, medium medium, low low. */
const PRIORITY: Record<number, number> = { 1: 3, 2: 3, 3: 2, 4: 1 };
/** Open state types, in the order Linear's board shows them. */
const OPEN_TYPES = ["triage", "backlog", "unstarted", "started"];

/**
 * Linear: each team a kanban project, its open workflow states (triage, backlog, unstarted,
 * started, in Linear's order) its columns. Issues are tasks in their state's column; completed
 * ones come in done with their time, canceled ones are left out. Priority and due day carry over;
 * labels become tags, and the issue's Linear project one more tag. Sub-issues sit under their
 * parent in the same team.
 */
export function mapLinear(data: LinearData, _ctx: ParseContext): ImportBundle {
  const warnings = new Warnings();
  const projects: ImportedProject[] = [];
  const sections: ImportedSection[] = [];
  const tasks: ImportedTask[] = [];
  const sectionOf = new Map<string, string>();

  data.teams.forEach((team, index) => {
    const projectKey = nativeKey("team", team.id);
    projects.push({
      key: projectKey,
      name: fitName(team.name ?? "", LIMITS.projectName) || "Linear",
      kind: "project",
      parentKey: null,
      view: "kanban",
      sortOrder: index,
      archived: false,
    });
    (team.states?.nodes ?? [])
      .filter((s) => OPEN_TYPES.includes(s.type ?? ""))
      .sort((a, b) => OPEN_TYPES.indexOf(a.type ?? "") - OPEN_TYPES.indexOf(b.type ?? "") || (a.position ?? 0) - (b.position ?? 0))
      .forEach((s, i) => {
        const key = nativeKey("state", s.id);
        sectionOf.set(s.id, key);
        sections.push({ key, projectKey, name: fitName(s.name ?? "", LIMITS.sectionName) || "Linear", sortOrder: i });
      });
  });
  const teams = new Set(data.teams.map((t) => t.id));

  [...data.issues]
    .sort((a, b) => (a.sortOrder ?? 0) - (b.sortOrder ?? 0))
    .forEach((issue, index) => {
      if (issue.state?.type === "canceled") {
        warnings.add("canceledSkipped");
        return;
      }
      const title = issue.title?.trim();
      if (!title) {
        warnings.add("untitledSkipped");
        return;
      }
      const done = issue.state?.type === "completed";
      const tags = (issue.labels?.nodes ?? []).map((l) => l.name ?? "");
      if (issue.project?.name) tags.push(issue.project.name);
      tasks.push({
        key: nativeKey("issue", issue.id),
        projectKey: issue.team && teams.has(issue.team.id) ? nativeKey("team", issue.team.id) : null,
        sectionKey: !done && issue.state ? (sectionOf.get(issue.state.id) ?? null) : null,
        parentKey: issue.parent ? nativeKey("issue", issue.parent.id) : null,
        title,
        notes: issue.description?.trim() || null,
        priority: PRIORITY[issue.priority ?? 0] ?? 0,
        tags,
        dueDate: issue.dueDate ?? null,
        dueTime: null,
        recurrence: null,
        done,
        completedAt: done ? instantOf(issue.completedAt) : null,
        sortOrder: index,
        reminders: [],
      });
    });
  return { projects, sections, tasks: orderTasks(tasks).map(fitTask), warnings: warnings.list() };
}

const TEAMS_QUERY = `query Teams($after: String) {
  teams(first: 50, after: $after) {
    nodes { id name states(first: 100) { nodes { id name type position } } }
    pageInfo { hasNextPage endCursor }
  }
}`;

const ISSUES_QUERY = `query Issues($after: String) {
  issues(first: 100, after: $after) {
    nodes {
      id title description priority dueDate completedAt sortOrder
      state { id type } team { id } project { name } parent { id } labels(first: 50) { nodes { name } }
    }
    pageInfo { hasNextPage endCursor }
  }
}`;

interface Page<T> {
  nodes?: T[];
  pageInfo?: { hasNextPage?: boolean; endCursor?: string | null };
}

/** Every node of a connection, following `endCursor`. A GraphQL error fails the import with Linear's name. */
async function allNodes<T>(provider: Provider, query: string, field: "teams" | "issues"): Promise<T[]> {
  const out: T[] = [];
  let after: string | null = null;
  for (let page = 0; page < MAX_PAGES; page++) {
    const body: { data?: Record<string, Page<T>>; errors?: unknown[] } = await providerGet(provider, LINEAR_API, {
      method: "POST",
      body: { query, variables: { after } },
    });
    if (body?.errors?.length || !body?.data?.[field]) {
      throw new ImportError("source_error", "رفض Linear الطلب. أعد المحاولة لاحقاً.");
    }
    const connection: Page<T> = body.data[field];
    out.push(...(connection.nodes ?? []));
    if (!connection.pageInfo?.hasNextPage || !connection.pageInfo.endCursor) break;
    after = connection.pageInfo.endCursor;
  }
  return out;
}

export const linear: TokenSource = {
  id: "linear",
  label: "Linear",
  refSource: "linear",
  input: "oauth",
  async load(token, ctx) {
    const provider: Provider = { label: "Linear", fetch: ctx.fetch, headers: { Authorization: `Bearer ${token}` } };
    const teams = await allNodes<LinearTeam>(provider, TEAMS_QUERY, "teams");
    const issues = await allNodes<LinearIssue>(provider, ISSUES_QUERY, "issues");
    return mapLinear({ teams, issues }, ctx);
  },
};
