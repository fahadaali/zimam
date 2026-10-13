import { Hono } from "hono";
import { z } from "zod";
import { verifyAppleToken } from "../auth/apple";
import { createSession, deleteSession } from "../auth/sessions";
import { userOut, type Row } from "../data/rows";
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
  const audiences = c.env.APPLE_AUDIENCES.split(",").map((a) => a.trim()).filter(Boolean);

  let identity;
  try {
    identity = await verifyAppleToken(body.data.identityToken, c.var.deps.appleKeys, audiences, body.data.nonce);
  } catch {
    return fail(c, 401, "invalid_token", "Apple identity token was rejected");
  }

  const db = c.env.DB;
  const now = Date.now();
  await db
    .prepare(
      `INSERT INTO users (id, apple_sub, email, name, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT (apple_sub) DO UPDATE SET email = COALESCE(excluded.email, users.email),
         name = COALESCE(users.name, excluded.name), updated_at = excluded.updated_at`,
    )
    .bind(crypto.randomUUID(), identity.sub, identity.email, body.data.name ?? null, now, now)
    .run();
  const user = await db.prepare(`SELECT * FROM users WHERE apple_sub = ?`).bind(identity.sub).first<Row>();
  if (!user) throw new Error("User upsert failed");

  const token = await createSession(db, user.id as string, body.data.device ?? null);
  return c.json({ token, user: userOut(user) });
});

auth.post("/logout", requireUser, async (c) => {
  await deleteSession(c.env.DB, c.var.token);
  return c.body(null, 204);
});
