import { Hono } from "hono";
import { z } from "zod";
import { pullChanges } from "../data/pull";
import { type ChangeEntity, OPT_IN_ENTITIES, OPT_IN_VIEWS } from "../data/schemas";
import { fail, readJson } from "../http";
import { markDevicesSeen } from "../push/devices";
import type { AppEnv } from "../types";

const MAX_PUSH = 200;

export const sync = new Hono<AppEnv>();

/**
 * GET /v1/sync?cursor=0&limit=500 — changes since the cursor, oldest first.
 * `include=attachment` adds attachment metadata, which older apps cannot decode, and
 * `include=timeline` sends a project's "timeline" view as it is rather than "list".
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
  const views = asked.filter((s) => OPT_IN_VIEWS.includes(s));
  return c.json(await pullChanges(c.env.DB, c.var.access, query.data.cursor, query.data.limit, include, views));
});

/** POST /v1/sync { mutations: [...] } — applied in order; each gets its own result. */
sync.post("/", async (c) => {
  const body = z
    .object({ mutations: z.array(z.unknown()).max(MAX_PUSH) })
    .safeParse(await readJson(c));
  if (!body.success) return fail(c, 400, "invalid", `Send up to ${MAX_PUSH} mutations`);
  const results = [];
  for (const mutation of body.data.mutations) results.push(await c.var.mutator.apply(mutation));
  return c.json({ results });
});
