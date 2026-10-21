import { zonedDateTime } from "../dates";
import { fitName, fitTask, type ImportBundle, type ImportedProject, type ImportedSection, type ImportedTask, LIMITS, orderTasks, Warnings } from "../model";
import { nativeKey, type ParseContext, type TokenSource } from "../source";
import { instantOf, MAX_PAGES, type Provider, providerGet } from "./provider-http";

export const GRAPH_API = "https://graph.microsoft.com/v1.0";

interface PlannerPlan {
  id: string;
  title?: string;
}

interface PlannerBucket {
  id: string;
  name?: string;
  orderHint?: string;
}

export interface PlannerTask {
  id: string;
  title?: string;
  bucketId?: string | null;
  /** 0, 50 (in progress) or 100 (completed). */
  percentComplete?: number;
  /** 0–10: 1 urgent, 3 important, 5 medium (the default), 9 low. */
  priority?: number;
  dueDateTime?: string | null;
  startDateTime?: string | null;
  completedDateTime?: string | null;
  orderHint?: string;
}

export interface PlannerData {
  plans: { plan: PlannerPlan; buckets: PlannerBucket[]; tasks: PlannerTask[] }[];
}

/** Ordinal, as Planner compares its order hints. */
const byHint = (a?: string, b?: string) => ((a ?? "") < (b ?? "") ? -1 : (a ?? "") > (b ?? "") ? 1 : 0);

/** Urgent and important are Zimam's high, low low; medium, Planner's default, is no priority. */
function plannerPriority(value: number | undefined): number {
  if (value === undefined) return 0;
  if (value <= 4) return 3;
  if (value >= 8) return 1;
  return 0;
}

/**
 * Microsoft Planner: each plan a kanban project, its buckets (in Planner's order) its columns, and
 * its tasks in their bucket. A task at 100% comes in done at its completion time. Due and start
 * dates are days in the user's zone; urgent and important are high priority, low low.
 */
export function mapPlanner(data: PlannerData, ctx: ParseContext): ImportBundle {
  const warnings = new Warnings();
  const projects: ImportedProject[] = [];
  const sections: ImportedSection[] = [];
  const tasks: ImportedTask[] = [];
  const day = (value: string | null | undefined) => {
    const at = instantOf(value);
    return at === null ? null : zonedDateTime(at, ctx.timeZone).date;
  };

  data.plans.forEach(({ plan, buckets, tasks: planTasks }, planIndex) => {
    const projectKey = nativeKey("plan", plan.id);
    projects.push({
      key: projectKey,
      name: fitName(plan.title ?? "", LIMITS.projectName) || "Planner",
      kind: "project",
      parentKey: null,
      view: "kanban",
      sortOrder: planIndex,
      archived: false,
    });
    const bucketKeys = new Set<string>();
    [...buckets]
      .sort((a, b) => byHint(a.orderHint, b.orderHint))
      .forEach((bucket, i) => {
        const key = nativeKey("bucket", bucket.id);
        bucketKeys.add(key);
        sections.push({ key, projectKey, name: fitName(bucket.name ?? "", LIMITS.sectionName) || "Planner", sortOrder: i });
      });
    [...planTasks]
      .sort((a, b) => byHint(a.orderHint, b.orderHint))
      .forEach((t, index) => {
        const title = t.title?.trim();
        if (!title) {
          warnings.add("untitledSkipped");
          return;
        }
        const done = t.percentComplete === 100;
        const bucketKey = t.bucketId ? nativeKey("bucket", t.bucketId) : null;
        const dueDate = day(t.dueDateTime);
        const startDate = day(t.startDateTime);
        tasks.push({
          key: nativeKey("task", t.id),
          projectKey,
          sectionKey: bucketKey && bucketKeys.has(bucketKey) ? bucketKey : null,
          parentKey: null,
          title,
          notes: null,
          priority: plannerPriority(t.priority),
          tags: [],
          dueDate,
          dueTime: null,
          startDate: startDate && dueDate && startDate < dueDate ? startDate : null,
          recurrence: null,
          done,
          completedAt: done ? instantOf(t.completedDateTime) : null,
          sortOrder: index,
          reminders: [],
        });
      });
  });
  return { projects, sections, tasks: orderTasks(tasks).map(fitTask), warnings: warnings.list() };
}

/** Every page of a Graph collection (`value`, `@odata.nextLink`). */
async function graphAll<T>(provider: Provider, url: string): Promise<T[]> {
  const out: T[] = [];
  let next: string | undefined = url;
  for (let page = 0; next && page < MAX_PAGES; page++) {
    const body: { value?: T[]; "@odata.nextLink"?: string } = await providerGet(provider, next);
    out.push(...(body?.value ?? []));
    next = body?.["@odata.nextLink"];
  }
  return out;
}

export const planner: TokenSource = {
  id: "planner",
  label: "Microsoft Planner",
  refSource: "planner",
  input: "oauth",
  async load(token, ctx) {
    const provider: Provider = { label: "Microsoft Planner", fetch: ctx.fetch, headers: { Authorization: `Bearer ${token}` } };
    const data: PlannerData = { plans: [] };
    for (const plan of await graphAll<PlannerPlan>(provider, `${GRAPH_API}/me/planner/plans`)) {
      const id = encodeURIComponent(plan.id);
      const [buckets, tasks] = await Promise.all([
        graphAll<PlannerBucket>(provider, `${GRAPH_API}/planner/plans/${id}/buckets`),
        graphAll<PlannerTask>(provider, `${GRAPH_API}/planner/plans/${id}/tasks`),
      ]);
      data.plans.push({ plan, buckets, tasks });
    }
    return mapPlanner(data, ctx);
  },
};
