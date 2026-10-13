import type { Context } from "hono";
import type { AppEnv } from "../types";
import type { UserChannel } from "./channel";

/**
 * Tells a user's open sockets to pull. Never carries data: only the newest change
 * sequence number the user can see, so a client that already has it does nothing.
 */
export interface Realtime {
  notify(userId: string, seq: number): Promise<void>;
  /** Closes the sockets opened with one session, or every socket of the user. */
  close(userId: string, sessionHash?: string): Promise<void>;
}

/** The real channel: one `UserChannel` Durable Object per user. */
export function channelRealtime(namespace: DurableObjectNamespace<UserChannel>): Realtime {
  const channel = (userId: string) => namespace.getByName(userId);
  return {
    async notify(userId, seq) {
      await channel(userId).notify(seq);
    },
    async close(userId, sessionHash) {
      await channel(userId).close(sessionHash ?? null);
    },
  };
}

/** The newest change row, read before a write; null when it cannot be read (the write goes on). */
export async function latestSeq(db: D1Database): Promise<number | null> {
  try {
    const row = await db.prepare(`SELECT COALESCE(MAX(seq), 0) AS seq FROM changes`).first<{ seq: number }>();
    return row?.seq ?? 0;
  } catch (error) {
    console.error("realtime: could not read the change log", error);
    return null;
  }
}

/** D1 allows 100 bound parameters per statement. */
const CHUNK = 90;

/**
 * Who must hear about the change rows after `since`, and the newest of those rows
 * each of them can see. The audience is the one `pullChanges` reads: every member
 * of a row's project, or the row's user. Membership is read after the write, so a
 * removed member hears only of the rows addressed to them.
 */
export async function audiencesSince(db: D1Database, since: number): Promise<Map<string, number>> {
  const { results } = await db
    .prepare(`SELECT project_id, user_id, MAX(seq) AS seq FROM changes WHERE seq > ? GROUP BY project_id, user_id`)
    .bind(since)
    .all<{ project_id: string | null; user_id: string | null; seq: number }>();

  const seqs = new Map<string, number>();
  const raise = (userId: string, seq: number) => seqs.set(userId, Math.max(seqs.get(userId) ?? 0, seq));
  const byProject = new Map<string, number>();
  for (const row of results) {
    if (row.user_id) raise(row.user_id, row.seq);
    if (row.project_id) byProject.set(row.project_id, Math.max(byProject.get(row.project_id) ?? 0, row.seq));
  }

  const projectIds = [...byProject.keys()];
  for (let i = 0; i < projectIds.length; i += CHUNK) {
    const chunk = projectIds.slice(i, i + CHUNK);
    const { results: members } = await db
      .prepare(`SELECT project_id, user_id FROM project_members WHERE project_id IN (${chunk.map(() => "?").join(",")})`)
      .bind(...chunk)
      .all<{ project_id: string; user_id: string }>();
    for (const m of members) raise(m.user_id, byProject.get(m.project_id)!);
  }
  return seqs;
}

/**
 * Nudges everyone who can see a change row written after `since`. Runs after the
 * response (`waitUntil`) and never throws: realtime is a hint on top of sync, and a
 * failure here must not touch the write that caused it.
 */
export async function notifyChangesSince(db: D1Database, realtime: Realtime, since: number): Promise<void> {
  try {
    const audiences = await audiencesSince(db, since);
    const results = await Promise.allSettled([...audiences].map(([userId, seq]) => realtime.notify(userId, seq)));
    const failed = results.filter((r) => r.status === "rejected");
    if (failed.length) console.error(`realtime: ${failed.length} of ${results.length} notifications failed`, failed[0]);
  } catch (error) {
    console.error("realtime: notify failed", error);
  }
}

/** The configured realtime channel, or null (tests without one, or a broken factory). */
export function realtimeOf(c: Context<AppEnv>): Realtime | null {
  try {
    return c.var.deps.realtime?.(c.env) ?? null;
  } catch (error) {
    console.error("realtime: unavailable", error);
    return null;
  }
}

/** Lets `work` finish after the response; without an execution context (some tests) it just runs. */
export function afterResponse(c: Context, work: Promise<unknown>) {
  try {
    c.executionCtx.waitUntil(work);
  } catch {
    void work;
  }
}

/** Closes the user's sockets after the response: one session's on sign-out, all on account deletion. */
export function closeSockets(c: Context<AppEnv>, userId: string, sessionHash?: string) {
  const realtime = realtimeOf(c);
  if (!realtime) return;
  afterResponse(
    c,
    realtime.close(userId, sessionHash).catch((error) => console.error("realtime: close failed", error)),
  );
}
