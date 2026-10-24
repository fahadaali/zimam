import { Hono } from "hono";
import { z } from "zod";
import { Access } from "../data/access";
import { Mutator } from "../data/mutations";
import { pullChanges } from "../data/pull";
import { type ChangeEntity, OPT_IN_ENTITIES, OPT_IN_REMINDER_KINDS, OPT_IN_VIEWS } from "../data/schemas";
import { fail, readJson } from "../http";
import { markDevicesSeen } from "../push/devices";
import type { AppEnv } from "../types";

const MAX_PUSH = 200;
/** The D1 queries one Worker invocation may make. */
const INVOCATION_QUERIES = 1000;
/**
 * The most one mutation makes (`Mutator.upsertTask`): a subtask ten levels down, in a section and
 * assigned, loads itself, the memberships, the section, the assignee, its parent and nine more
 * ancestors, then writes in one batch.
 */
const MAX_MUTATION_QUERIES = 16;
/**
 * The rest of the request, with room to spare: the session (2) and the newest change (1) before
 * it, and the realtime audiences after the response (1, and 1 per 90 projects touched).
 */
const REQUEST_QUERIES = 20;
/**
 * The D1 queries one push may spend on its mutations. A mutation starts only while the push is
 * under it, so the last one ends at most `MAX_MUTATION_QUERIES` past it, still inside the limit.
 * It sits that close to the limit because the shipped Apple app sends the next slice of its queue
 * after a short answer and resends the rest only in its next round, so a dependant in between can
 * fail (api/DEVELOPMENT.md, «المزامنة»): the push is answered in part only where it would
 * otherwise fail whole.
 */
const PUSH_QUERY_BUDGET = INVOCATION_QUERIES - REQUEST_QUERIES - MAX_MUTATION_QUERIES;

export const sync = new Hono<AppEnv>();

/**
 * GET /v1/sync?cursor=0&limit=500 — changes since the cursor, oldest first.
 * `include=attachment` adds attachment metadata and `include=place` saved places, which older
 * apps cannot decode, and `include=timeline` sends a project's "timeline" view as it is rather
 * than "list". `include=relative` adds reminders relative to their task's time.
 */
sync.get("/", async (c) => {
  const query = z
    .object({
      cursor: z.coerce.number().int().nonnegative().default(0),
      limit: z.coerce.number().int().min(1).max(1000).default(500),
      include: z.string().max(200).optional(),
    })
    .safeParse(c.req.query());
  if (!query.success) return fail(c, 400, "invalid", "cursor and limit must be non-negative integers");
  // Before reading: the device then reschedules its local notifications from this pull.
  await markDevicesSeen(c.env.DB, c.var.token);
  const asked = (query.data.include ?? "").split(",").map((s) => s.trim());
  const include = asked.filter((s): s is ChangeEntity => (OPT_IN_ENTITIES as readonly string[]).includes(s));
  const views = asked.filter((s) => OPT_IN_VIEWS.includes(s) || OPT_IN_REMINDER_KINDS.includes(s));
  return c.json(await pullChanges(c.env.DB, c.var.access, query.data.cursor, query.data.limit, include, views));
});

/**
 * POST /v1/sync { mutations: [...] } — applied in order; each gets its own result. Once the push
 * has spent `PUSH_QUERY_BUDGET` it stops, so `results` can be shorter than `mutations`: the ones
 * without a result were not touched, and the client sends them again.
 */
sync.post("/", async (c) => {
  const body = z
    .object({ mutations: z.array(z.unknown()).max(MAX_PUSH) })
    .safeParse(await readJson(c));
  if (!body.success) return fail(c, 400, "invalid", `Send up to ${MAX_PUSH} mutations`);
  const queries = countingQueries(c.env.DB);
  const mutator = new Mutator(queries.db, new Access(queries.db, c.var.userId));
  const results = [];
  for (const mutation of body.data.mutations) {
    if (queries.count() >= PUSH_QUERY_BUDGET) break;
    results.push(await mutator.apply(mutation));
  }
  return c.json({ results });
});

/**
 * `db` with a count of the queries made through it. A batch is one query, as D1 counts it, so a
 * statement counts when it runs, not when it is prepared. Only what the Mutator and Access use.
 */
function countingQueries(db: D1Database): { db: D1Database; count: () => number } {
  let count = 0;
  const counted = <F extends (...args: never[]) => Promise<unknown>>(run: F): F =>
    ((...args: Parameters<F>) => {
      count += 1;
      return run(...args);
    }) as F;
  const track = (statement: D1PreparedStatement): D1PreparedStatement => {
    const bind = statement.bind.bind(statement);
    statement.bind = (...values: unknown[]) => track(bind(...values));
    statement.first = counted(statement.first.bind(statement));
    statement.run = counted(statement.run.bind(statement));
    statement.all = counted(statement.all.bind(statement));
    statement.raw = counted(statement.raw.bind(statement));
    return statement;
  };
  const wrapped = {
    prepare: (query: string) => track(db.prepare(query)),
    batch: counted(db.batch.bind(db)),
  } as Partial<D1Database> as D1Database;
  return { db: wrapped, count: () => count };
}
