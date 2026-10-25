import type { Env } from "../env";
import type { Plan } from "../subscriptions/entitlements";
import type { AiUsage } from "./provider";

/** Monthly assistant quota. Months are calendar months in UTC. */

export const DEFAULT_MONTHLY_LIMIT = 300;

export function monthOf(now: Date): string {
  return now.toISOString().slice(0, 7);
}

/** The first day of the next month, when the count starts again ("2026-11-01"). */
export function resetDate(now: Date): string {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1)).toISOString().slice(0, 10);
}

/** A whole number of requests, or null when the value is missing or not one. */
function parseLimit(value: string | undefined): number | null {
  const text = value?.trim() ?? "";
  if (!/^\d+$/.test(text)) return null;
  const n = Number.parseInt(text, 10);
  return Number.isSafeInteger(n) ? n : null;
}

export function monthlyLimit(value: string | undefined): number {
  return parseLimit(value) ?? DEFAULT_MONTHLY_LIMIT;
}

type LimitVars = Pick<Env, "AI_MONTHLY_LIMIT" | "AI_MONTHLY_LIMIT_FREE" | "AI_MONTHLY_LIMIT_PRO">;

/**
 * The monthly limit for a plan: `AI_MONTHLY_LIMIT_FREE` or `AI_MONTHLY_LIMIT_PRO`, falling back
 * to `AI_MONTHLY_LIMIT`, then to 300. While SUBSCRIPTIONS_ENFORCED is not "true" everyone's
 * plan for limits is pro (`limitsPlan`), so everyone gets the pro limit.
 */
export function planMonthlyLimit(env: LimitVars, plan: Plan["plan"]): number {
  const specific = plan === "pro" ? env.AI_MONTHLY_LIMIT_PRO : env.AI_MONTHLY_LIMIT_FREE;
  return parseLimit(specific) ?? monthlyLimit(env.AI_MONTHLY_LIMIT);
}

export interface QuotaState {
  allowed: boolean;
  limit: number;
  resetsOn: string;
}

/**
 * Takes one request from the month's quota before the model is called, in one statement: a
 * request in flight holds its place, so requests sent together cannot pass the limit together.
 * Refused once the month's requests, or its failed requests (`settleRequest`), reach the limit.
 */
export async function reserveRequest(db: D1Database, userId: string, limit: number, now: Date): Promise<QuotaState> {
  const state = { limit, resetsOn: resetDate(now) };
  if (limit <= 0) return { allowed: false, ...state };
  // When the update's WHERE fails, nothing changes and RETURNING gives no row.
  const row = await db
    .prepare(
      `INSERT INTO ai_usage (user_id, month, requests) VALUES (?1, ?2, 1)
       ON CONFLICT (user_id, month) DO UPDATE SET requests = requests + 1
         WHERE requests < ?3 AND failed_requests < ?3
       RETURNING requests`,
    )
    .bind(userId, monthOf(now), limit)
    .first<{ requests: number }>();
  return { allowed: row !== null, ...state };
}

/**
 * Settles a reserved request (`now` is the reservation's, so it lands in the same month). A
 * success adds its tokens. A failure gives the request back; one the provider was paid for
 * (`billed`: a refusal, a cut-off or unusable answer) also counts as failed.
 */
export async function settleRequest(
  db: D1Database,
  userId: string,
  now: Date,
  outcome: { ok: true; usage: AiUsage } | { ok: false; billed: boolean },
): Promise<void> {
  const where = `WHERE user_id = ?1 AND month = ?2`;
  const statement = outcome.ok
    ? db
        .prepare(`UPDATE ai_usage SET input_tokens = input_tokens + ?3, output_tokens = output_tokens + ?4 ${where}`)
        .bind(userId, monthOf(now), Math.max(0, Math.round(outcome.usage.input)), Math.max(0, Math.round(outcome.usage.output)))
    : db
        .prepare(`UPDATE ai_usage SET requests = MAX(requests - 1, 0), failed_requests = failed_requests + ?3 ${where}`)
        .bind(userId, monthOf(now), outcome.billed ? 1 : 0);
  await statement.run();
}
