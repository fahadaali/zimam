import { randomToken, sha256Hex } from "../auth/crypto";

/** How long a ticket can be used; the web app asks for one right before it connects. */
export const TICKET_TTL_MS = 60_000;
const PREFIX = "zt_";

/** Issues a single-use ticket for the session; only its hash is stored. */
export async function issueTicket(db: D1Database, userId: string, sessionHash: string, now = Date.now()) {
  const ticket = PREFIX + randomToken();
  const expiresAt = now + TICKET_TTL_MS;
  await db.batch([
    db.prepare(`DELETE FROM realtime_tickets WHERE expires_at <= ?`).bind(now),
    db
      .prepare(`INSERT INTO realtime_tickets (ticket_hash, user_id, session_hash, expires_at) VALUES (?, ?, ?, ?)`)
      .bind(await sha256Hex(ticket), userId, sessionHash, expiresAt),
  ]);
  return { ticket, expiresAt };
}

/** Uses up a ticket: the user and session it was issued to, or null if unknown, used or expired. */
export async function redeemTicket(db: D1Database, ticket: string, now = Date.now()) {
  if (!ticket.startsWith(PREFIX) || ticket.length > 100) return null;
  const row = await db
    .prepare(`DELETE FROM realtime_tickets WHERE ticket_hash = ? RETURNING user_id, session_hash, expires_at`)
    .bind(await sha256Hex(ticket))
    .first<{ user_id: string; session_hash: string; expires_at: number }>();
  if (!row || row.expires_at <= now) return null;
  return { userId: row.user_id, sessionHash: row.session_hash };
}
