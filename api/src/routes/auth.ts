import { Hono } from "hono";
import { z } from "zod";
import { verifyAppleToken } from "../auth/apple";
import { createSession, deleteSession } from "../auth/sessions";
import { appleAudiences, upsertAppleUser } from "../auth/users";
import { userOut } from "../data/rows";
import { fail, readJson } from "../http";
import { requireUser } from "../middleware";
import type { AppEnv } from "../types";

const AppleSignIn = z.object({
  identityToken: z.string().min(1),
  /** The raw nonce the client hashed into the Apple request, if any. */
  nonce: z.string().min(1).optional(),
  /** Apple sends the name only on the first sign-in, to the client. */
  name: z.string().trim().max(200).optional(),
  device: z.string().trim().max(100).optional(),
});

export const auth = new Hono<AppEnv>();

auth.post("/apple", async (c) => {
  const body = AppleSignIn.safeParse(await readJson(c));
  if (!body.success) return fail(c, 400, "invalid", "identityToken is required");
  const audiences = appleAudiences(c.env.APPLE_AUDIENCES);

  let identity;
  try {
    identity = await verifyAppleToken(body.data.identityToken, c.var.deps.appleKeys, audiences, body.data.nonce);
  } catch {
    return fail(c, 401, "invalid_token", "Apple identity token was rejected");
  }

  const db = c.env.DB;
  const user = await upsertAppleUser(db, identity, body.data.name ?? null);

  const token = await createSession(db, user.id as string, body.data.device ?? null);
  return c.json({ token, user: userOut(user) });
});

auth.post("/logout", requireUser, async (c) => {
  await deleteSession(c.env.DB, c.var.token);
  return c.body(null, 204);
});
