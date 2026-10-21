import { fitName, fitTask, type ImportBundle, ImportError, type ImportedProject, type ImportedSection, type ImportedTask, LIMITS, orderTasks, Warnings } from "../model";
import { nativeKey, type ParseContext, type TokenSource } from "../source";
import { instantOf, MAX_PAGES, type Provider, providerGet } from "./provider-http";

/** Atlassian's API gateway: the sites the token reaches, then each site's Jira under `/ex/jira/<cloudId>`. */
export const ATLASSIAN_API = "https://api.atlassian.com";

/** Atlassian Document Format: the JSON tree Jira Cloud keeps descriptions in. */
interface AdfNode {
  type?: string;
  text?: string;
  attrs?: Record<string, unknown>;
  content?: AdfNode[];
}

export interface JiraIssue {
  id: string;
  fields?: {
    summary?: string;
    description?: AdfNode | string | null;
    status?: { id?: string; name?: string; statusCategory?: { key?: string } } | null;
    priority?: { name?: string } | null;
    /** A day, "2026-10-22". */
    duedate?: string | null;
    labels?: string[];
    parent?: { id: string } | null;
    project?: { id: string } | null;
    resolutiondate?: string | null;
  };
}

export interface JiraData {
  sites: { site: { id: string; name?: string }; projects: { id: string; name?: string }[]; issues: JiraIssue[] }[];
}

const BLOCKS = new Set(["paragraph", "heading", "blockquote", "codeBlock", "rule", "mediaSingle"]);

/** A description as plain text: paragraphs and list items on their own lines, marks and media dropped. */
export function adfToText(node: AdfNode | string | null | undefined): string {
  if (!node) return "";
  if (typeof node === "string") return node.trim();
  const out: string[] = [];
  const walk = (n: AdfNode, prefix = "") => {
    if (n.type === "text") {
      out.push(n.text ?? "");
      return;
    }
    if (n.type === "hardBreak") {
      out.push("\n");
      return;
    }
    if (n.type === "mention" || n.type === "emoji") {
      out.push(String(n.attrs?.text ?? ""));
      return;
    }
    if (n.type === "listItem") out.push(prefix);
    for (const child of n.content ?? []) walk(child, n.type === "bulletList" || n.type === "orderedList" ? "• " : prefix);
    if (BLOCKS.has(n.type ?? "") || n.type === "listItem") out.push("\n");
  };
  walk(node);
  return out
    .join("")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** Jira's default priorities: Highest and High are Zimam's high, Medium medium, Low and Lowest low. */
const PRIORITY: Record<string, number> = { highest: 3, high: 3, medium: 2, low: 1, lowest: 1 };

/**
 * Jira Cloud: each project a kanban project (in a folder named after its site when the token
 * reaches more than one), and its open statuses (to do first, then in progress) its columns. An
 * issue in a done status comes in done at its resolution time. Priority, due day and labels carry
 * over; the description becomes the notes as text; sub-tasks sit under their parent.
 */
export function mapJira(data: JiraData, _ctx: ParseContext): ImportBundle {
  const warnings = new Warnings();
  const projects: ImportedProject[] = [];
  const sections: ImportedSection[] = [];
  const tasks: ImportedTask[] = [];
  const several = data.sites.length > 1;

  data.sites.forEach(({ site, projects: siteProjects, issues }, siteIndex) => {
    const siteKey = nativeKey("site", site.id);
    if (several) {
      projects.push({ key: siteKey, name: fitName(site.name ?? "", LIMITS.projectName) || "Jira", kind: "folder", parentKey: null, view: "list", sortOrder: siteIndex, archived: false });
    }
    const projectKeys = new Map<string, string>();
    siteProjects.forEach((p, index) => {
      const key = nativeKey("project", `${site.id}:${p.id}`);
      projectKeys.set(p.id, key);
      projects.push({
        key,
        name: fitName(p.name ?? "", LIMITS.projectName) || "Jira",
        kind: "project",
        parentKey: several ? siteKey : null,
        view: "kanban",
        sortOrder: index,
        archived: false,
      });
    });
    // Each project's open statuses, as its issues use them: to do first, then in progress.
    const columns = new Map<string, Map<string, { name: string; rank: number }>>();
    for (const issue of issues) {
      const f = issue.fields ?? {};
      const projectKey = f.project ? projectKeys.get(f.project.id) : undefined;
      const category = f.status?.statusCategory?.key;
      if (!projectKey || !f.status?.id || category === "done") continue;
      const byStatus = columns.get(projectKey) ?? new Map();
      columns.set(projectKey, byStatus);
      if (!byStatus.has(f.status.id)) byStatus.set(f.status.id, { name: f.status.name ?? "", rank: category === "new" ? 0 : 1 });
    }
    for (const [projectKey, byStatus] of columns) {
      [...byStatus.entries()]
        .sort((a, b) => a[1].rank - b[1].rank)
        .forEach(([statusId, { name }], i) => {
          sections.push({ key: nativeKey("status", `${projectKey}:${statusId}`), projectKey, name: fitName(name, LIMITS.sectionName) || "Jira", sortOrder: i });
        });
    }
    issues.forEach((issue, index) => {
      const f = issue.fields ?? {};
      const title = f.summary?.trim();
      if (!title) {
        warnings.add("untitledSkipped");
        return;
      }
      const projectKey = (f.project && projectKeys.get(f.project.id)) || null;
      const done = f.status?.statusCategory?.key === "done";
      tasks.push({
        key: nativeKey("issue", `${site.id}:${issue.id}`),
        projectKey,
        sectionKey: !done && projectKey && f.status?.id ? nativeKey("status", `${projectKey}:${f.status.id}`) : null,
        parentKey: f.parent ? nativeKey("issue", `${site.id}:${f.parent.id}`) : null,
        title,
        notes: adfToText(f.description) || null,
        priority: PRIORITY[(f.priority?.name ?? "").toLowerCase()] ?? 0,
        tags: f.labels ?? [],
        dueDate: f.duedate ?? null,
        dueTime: null,
        recurrence: null,
        done,
        completedAt: done ? instantOf(f.resolutiondate) : null,
        sortOrder: index,
        reminders: [],
      });
    });
  });
  return { projects, sections, tasks: orderTasks(tasks).map(fitTask), warnings: warnings.list() };
}

const FIELDS = "summary,description,status,priority,duedate,labels,parent,project,resolutiondate";

export const jira: TokenSource = {
  id: "jira",
  label: "Jira",
  refSource: "jira",
  input: "oauth",
  async load(token, ctx) {
    const provider: Provider = { label: "Jira", fetch: ctx.fetch, headers: { Authorization: `Bearer ${token}` } };
    const resources = await providerGet<{ id: string; name?: string; scopes?: string[] }[]>(provider, `${ATLASSIAN_API}/oauth/token/accessible-resources`);
    const sites = (resources ?? []).filter((r) => !r.scopes || r.scopes.some((s) => s.includes("jira")));
    if (sites.length === 0) throw new ImportError("source_error", "لا يصل هذا الإذن إلى أي موقع Jira. اختر موقعك في صفحة Atlassian ثم أعد المحاولة.");
    const data: JiraData = { sites: [] };
    for (const site of sites) {
      const base = `${ATLASSIAN_API}/ex/jira/${encodeURIComponent(site.id)}/rest/api/3`;
      const projects: { id: string; name?: string }[] = [];
      for (let startAt = 0, page = 0; page < MAX_PAGES; page++) {
        const body = await providerGet<{ values?: { id: string; name?: string }[]; isLast?: boolean }>(provider, `${base}/project/search?maxResults=50&startAt=${startAt}`);
        const values = body?.values ?? [];
        projects.push(...values);
        if (body?.isLast !== false || values.length === 0) break;
        startAt += values.length;
      }
      // Enhanced search refuses an unbounded query: one search per project.
      const issues: JiraIssue[] = [];
      for (const project of projects) {
        const url = new URL(`${base}/search/jql`);
        url.searchParams.set("jql", `project = ${project.id} ORDER BY created ASC`);
        url.searchParams.set("fields", FIELDS);
        url.searchParams.set("maxResults", "100");
        for (let page = 0; page < MAX_PAGES; page++) {
          const body = await providerGet<{ issues?: JiraIssue[]; nextPageToken?: string; isLast?: boolean }>(provider, url.toString());
          issues.push(...(body?.issues ?? []));
          if (!body?.nextPageToken || body.isLast === true) break;
          url.searchParams.set("nextPageToken", body.nextPageToken);
        }
      }
      data.sites.push({ site, projects, issues });
    }
    return mapJira(data, ctx);
  },
};
