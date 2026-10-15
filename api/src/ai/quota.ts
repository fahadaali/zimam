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
  used: number;
  limit: number;
  resetsOn: string;
}

export async function checkQuota(db: D1Database, userId: string, limit: number, now: Date): Promise<QuotaState> {
  const row = await db
    .prepare(`SELECT requests FROM ai_usage WHERE user_id = ? AND month = ?`)
    .bind(userId, monthOf(now))
    .first<{ requests: number }>();
  const used = row?.requests ?? 0;
  return { allowed: used < limit, used, limit, resetsOn: resetDate(now) };
}

/** Counts one successful request and its tokens. */
export async function recordUsage(db: D1Database, userId: string, usage: AiUsage, now: Date): Promise<void> {
  await db
    .prepare(
      `INSERT INTO ai_usage (user_id, month, requests, input_tokens, output_tokens) VALUES (?1, ?2, 1, ?3, ?4)
       ON CONFLICT (user_id, month) DO UPDATE SET
         requests = requests + 1,
         input_tokens = input_tokens + excluded.input_tokens,
         output_tokens = output_tokens + excluded.output_tokens`,
    )
    .bind(userId, monthOf(now), Math.max(0, Math.round(usage.input)), Math.max(0, Math.round(usage.output)))
    .run();
}

