import type { AppleIdentity } from "./apple";
import type { Row } from "../data/rows";

/** Finds or creates the user for an Apple identity. Apple sends the name only once, so keep the first. */
export async function upsertAppleUser(db: D1Database, identity: AppleIdentity, name: string | null): Promise<Row> {
  const now = Date.now();
  await db
    .prepare(
      `INSERT INTO users (id, apple_sub, email, name, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)
       ON CONFLICT (apple_sub) DO UPDATE SET email = COALESCE(excluded.email, users.email),
         name = COALESCE(users.name, excluded.name), updated_at = excluded.updated_at`,
    )
    .bind(crypto.randomUUID(), identity.sub, identity.email, name, now, now)
    .run();
  const user = await db.prepare(`SELECT * FROM users WHERE apple_sub = ?`).bind(identity.sub).first<Row>();
  if (!user) throw new Error("User upsert failed");
  return user;
}

/** Sign in with Apple audiences configured for this deployment. */
export function appleAudiences(value: string): string[] {
  return value.split(",").map((a) => a.trim()).filter(Boolean);
}
