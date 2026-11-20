import type { Env } from "../env";
import type { Plan } from "../subscriptions/entitlements";
import { parseLimit } from "./quota";

/**
 * Short-window assistant limits, beside the monthly quota (src/ai/quota.ts): requests per user
 * per minute and per UTC day by plan, against flooding, and a cap per UTC day across all users,
 * a circuit breaker for the bill. Windows are fixed (the minute, the UTC day) and kept in
 * `ai_rate` (migrations/0023_ai_rate_limits.sql).
 *
 * The defaults sit well above what the apps send in normal use: every assistant call is a tap
 * («اقرأ», «تقسيم إلى خطوات», «ملخص اليوم») or the end of a dictation, never a keystroke or a
 * timer, and one dictate-review-accept round takes about ten seconds.
 */
export const DEFAULT_RATE_LIMITS = {
  minute: { free: 5, pro: 10 },
  day: { free: 10, pro: 60 },
  global: 2000,
} as const;

const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;

export interface RateLimits {
  minute: number;
  day: number;
  global: number;
}

type RateVars = Pick<
  Env,
  "AI_MINUTE_LIMIT_FREE" | "AI_MINUTE_LIMIT_PRO" | "AI_DAILY_LIMIT_FREE" | "AI_DAILY_LIMIT_PRO" | "AI_GLOBAL_DAILY_LIMIT"
>;

/**
 * The plan's limits from the vars, each falling back to its default when missing or not a whole
 * number. "0" for a user limit closes the assistant to that plan: a free user gets 403
 * `pro_required` (as with AI_MONTHLY_LIMIT_FREE "0"), and pro every request refused. "0" for
 * the global cap turns the assistant off for everyone (503 `ai_busy`).
 */
export function planRateLimits(env: Partial<RateVars>, plan: Plan["plan"]): RateLimits {
  const pro = plan === "pro";
  return {
    minute: parseLimit(pro ? env.AI_MINUTE_LIMIT_PRO : env.AI_MINUTE_LIMIT_FREE) ?? DEFAULT_RATE_LIMITS.minute[plan],
    day: parseLimit(pro ? env.AI_DAILY_LIMIT_PRO : env.AI_DAILY_LIMIT_FREE) ?? DEFAULT_RATE_LIMITS.day[plan],
    global: parseLimit(env.AI_GLOBAL_DAILY_LIMIT) ?? DEFAULT_RATE_LIMITS.global,
  };
}

/** The windows a request was taken from, to give it back. */
export interface RateHold {
  userId: string;
  minuteStart: number;
  dayStart: number;
}

export interface RateRefusal {
  /** "minute" or "day": the user's own limit (429). "global": everyone's daily cap (503). */
  scope: "minute" | "day" | "global";
  limit: number;
  /** Whole seconds until that window ends, at least 1. */
  retryAfter: number;
}

export type RateResult = { allowed: true; hold: RateHold } | { allowed: false; refusal: RateRefusal };

const windowsOf = (userId: string, now: number): RateHold => ({
  userId,
  minuteStart: Math.floor(now / MINUTE) * MINUTE,
  dayStart: Math.floor(now / DAY) * DAY,
});

const secondsUntil = (end: number, now: number) => Math.max(1, Math.ceil((end - now) / 1000));

// The request's windows, with ?1 the user, ?2 the minute's start and ?3 the day's start.
const MINUTE_WINDOW = `(user_id = ?1 AND scope = 'minute' AND window_start = ?2)`;
const DAY_WINDOWS = `(user_id = ?1 AND scope = 'day' AND window_start = ?3) OR (user_id = '' AND scope = 'global' AND window_start = ?3)`;
const WINDOWS = `${MINUTE_WINDOW} OR ${DAY_WINDOWS}`;

const count = (scope: string, user: string, start: string) =>
  `COALESCE((SELECT requests FROM ai_rate WHERE user_id = ${user} AND scope = '${scope}' AND window_start = ${start}), 0)`;

/**
 * Takes one request from the user's minute and day and from the global day, in one statement,
 * before the model is called: all three when each is under its limit, otherwise none, so a
 * refused request counts nowhere. As with `reserveRequest`, a request in flight holds its place,
 * and requests sent together cannot pass a limit together.
 */
export async function takeRequest(db: D1Database, userId: string, limits: RateLimits, now: number): Promise<RateResult> {
  const hold = windowsOf(userId, now);
  // The WHERE reads only the counts from before the statement (constant subqueries, evaluated
  // once), so either every row is written or none is. A 0 limit refuses every request.
  const { results } = await db
    .prepare(
      `INSERT INTO ai_rate (user_id, scope, window_start, requests)
       SELECT w.user_id, w.scope, w.window_start, 1 FROM (
         SELECT ?1 AS user_id, 'minute' AS scope, ?2 AS window_start
         UNION ALL SELECT ?1, 'day', ?3
         UNION ALL SELECT '', 'global', ?3
       ) AS w
       WHERE ${count("minute", "?1", "?2")} < ?4
         AND ${count("day", "?1", "?3")} < ?5
         AND ${count("global", "''", "?3")} < ?6
       ON CONFLICT (user_id, scope, window_start) DO UPDATE SET requests = requests + 1
       RETURNING scope`,
    )
    .bind(userId, hold.minuteStart, hold.dayStart, limits.minute, limits.day, limits.global)
    .all<{ scope: string }>();
  if (results.length > 0) return { allowed: true, hold };

  // Refused: say which window, read after the fact (only for the answer). The longest wait
  // first, so a client that waits `retryAfter` is not refused again by another window.
  const { results: rows } = await db
    .prepare(`SELECT scope, requests FROM ai_rate WHERE ${WINDOWS}`)
    .bind(userId, hold.minuteStart, hold.dayStart)
    .all<{ scope: "minute" | "day" | "global"; requests: number }>();
  const used = (scope: string) => rows.find((r) => r.scope === scope)?.requests ?? 0;
  const dayEnd = hold.dayStart + DAY;
  if (used("day") >= limits.day) return { allowed: false, refusal: { scope: "day", limit: limits.day, retryAfter: secondsUntil(dayEnd, now) } };
  if (used("global") >= limits.global) {
    return { allowed: false, refusal: { scope: "global", limit: limits.global, retryAfter: secondsUntil(dayEnd, now) } };
  }
  const minuteEnd = hold.minuteStart + MINUTE;
  return { allowed: false, refusal: { scope: "minute", limit: limits.minute, retryAfter: secondsUntil(minuteEnd, now) } };
}

/**
 * Gives a taken request back. "all" when the request did not go ahead (the monthly quota refused
 * it). "spend" when the provider was not reached or not paid (`AiError.billed` false): the day
 * windows measure spend and are given back, so an outage does not use up the global day, but the
 * minute keeps it, since it limits how fast requests come.
 */
export async function releaseRequest(db: D1Database, hold: RateHold, which: "all" | "spend"): Promise<void> {
  const scopes = which === "all" ? WINDOWS : DAY_WINDOWS;
  await db
    .prepare(`UPDATE ai_rate SET requests = MAX(requests - 1, 0) WHERE ${scopes}`)
    .bind(hold.userId, hold.minuteStart, hold.dayStart)
    .run();
}

/** Deletes every window that has ended: minutes before this one, days before today (UTC). Run by the cron. */
export async function deleteEndedRateWindows(db: D1Database, now: number): Promise<void> {
  const { minuteStart, dayStart } = windowsOf("", now);
  await db
    .prepare(`DELETE FROM ai_rate WHERE (scope = 'minute' AND window_start < ?1) OR window_start < ?2`)
    .bind(minuteStart, dayStart)
    .run();
}
