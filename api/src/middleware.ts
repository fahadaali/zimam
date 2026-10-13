import { createMiddleware } from "hono/factory";
import { resolveSession } from "./auth/sessions";
import { Access } from "./data/access";
import { Mutator } from "./data/mutations";
import { fail } from "./http";
import { afterResponse, latestSeq, notifyChangesSince, realtimeOf } from "./realtime/notify";
import type { AppEnv } from "./types";

const READS = new Set(["GET", "HEAD", "OPTIONS"]);

/**
 * Requires `Authorization: Bearer <session token>` and sets the user's access context.
 *
 * Every signed-in write passes here, so this is where realtime hooks in: the newest
 * change row is read alongside the session (no extra round trip), and after the
 * response everyone who can see a row written since then is told to pull.
 */
export const requireUser = createMiddleware<AppEnv>(async (c, next) => {
  // "/v1/tasks/*" also matches "/v1/tasks", so a request can pass here twice.
  if (c.var.userId) return next();
  const header = c.req.header("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  const realtime = READS.has(c.req.method) ? null : realtimeOf(c);
  const [userId, since] = await Promise.all([
    token ? resolveSession(c.env.DB, token) : null,
    realtime ? latestSeq(c.env.DB) : null,
  ]);
  if (!userId) return fail(c, 401, "unauthorized", "Sign in required");
  const access = new Access(c.env.DB, userId);
  c.set("token", token);
  c.set("userId", userId);
  c.set("access", access);
  c.set("mutator", new Mutator(c.env.DB, access));
  await next();
  if (realtime && since !== null) afterResponse(c, notifyChangesSince(c.env.DB, realtime, since));
});
