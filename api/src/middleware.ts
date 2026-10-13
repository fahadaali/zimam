import { createMiddleware } from "hono/factory";
import { resolveSession } from "./auth/sessions";
import { Access } from "./data/access";
import { Mutator } from "./data/mutations";
import { fail } from "./http";
import type { AppEnv } from "./types";

/** Requires `Authorization: Bearer <session token>` and sets the user's access context. */
export const requireUser = createMiddleware<AppEnv>(async (c, next) => {
  const header = c.req.header("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  const userId = token ? await resolveSession(c.env.DB, token) : null;
  if (!userId) return fail(c, 401, "unauthorized", "Sign in required");
  const access = new Access(c.env.DB, userId);
  c.set("token", token);
  c.set("userId", userId);
  c.set("access", access);
  c.set("mutator", new Mutator(c.env.DB, access));
  await next();
});
