import { randomToken, sha256Hex } from "./crypto";

const SESSION_DAYS = 180;
const DAY = 24 * 60 * 60 * 1000;
const TOKEN_PREFIX = "zs_";

/** Creates a session and returns the bearer token. Only its hash is stored. */
export async function createSession(db: D1Database, userId: string, device: string | null): Promise<string> {
  const token = TOKEN_PREFIX + randomToken();
  const now = Date.now();
  await db
    .prepare(`INSERT INTO sessions (token_hash, user_id, device, created_at, expires_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?)`)
    .bind(await sha256Hex(token), userId, device, now, now + SESSION_DAYS * DAY, now)
    .run();
  return token;
}

/** Returns the user id for a live session token, extending it once a day. */
export async function resolveSession(db: D1Database, token: string): Promise<string | null> {
  if (!token.startsWith(TOKEN_PREFIX)) return null;
  const hash = await sha256Hex(token);
  const now = Date.now();
  const session = await db
    .prepare(`SELECT user_id, last_used_at FROM sessions WHERE token_hash = ? AND expires_at > ?`)
    .bind(hash, now)
    .first<{ user_id: string; last_used_at: number }>();
  if (!session) return null;
  if (now - session.last_used_at > DAY) {
    await db
      .prepare(`UPDATE sessions SET last_used_at = ?2, expires_at = ?3 WHERE token_hash = ?1`)
      .bind(hash, now, now + SESSION_DAYS * DAY)
      .run();
  }
  return session.user_id;
}

export async function deleteSession(db: D1Database, token: string) {
  await db.prepare(`DELETE FROM sessions WHERE token_hash = ?`).bind(await sha256Hex(token)).run();
}
