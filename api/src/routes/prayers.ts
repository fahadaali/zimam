import { Hono } from "hono";
import { z } from "zod";
import { addDays, dayIn, timeIn } from "../data/dates";
import { dayInstants } from "../data/prayers";
import { type Row, userOut } from "../data/rows";
import { fail } from "../http";
import type { AppEnv } from "../types";

/**
 * GET /v1/prayers?from=YYYY-MM-DD&to=YYYY-MM-DD — prayer times at the user's saved location, by
 * their method and Asr madhab, for the web app's «أوقات الصلاة», its next-prayer line and the clock
 * time in prayer chips. The apps compute these on the device. Days default to today in the user's
 * zone; at most 31 at once. Without a saved location `days` is empty and `location` null.
 */
export const prayers = new Hono<AppEnv>();

const MAX_DAYS = 31;
const Day = z.iso.date();
const Query = z.object({ from: Day.optional(), to: Day.optional() });
const NAMES = ["fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha"] as const;

prayers.get("/", async (c) => {
  const query = Query.safeParse(c.req.query());
  if (!query.success) return fail(c, 400, "invalid", "from and to are days (YYYY-MM-DD)");
  const row = await c.env.DB.prepare(`SELECT * FROM users WHERE id = ?`).bind(c.var.userId).first<Row>();
  if (!row) return fail(c, 404, "not_found", "User not found");
  const { settings } = userOut(row);
  const from = query.data.from ?? dayIn(settings.timeZone);
  const to = query.data.to ?? from;
  if (to < from) return fail(c, 400, "invalid", "to is before from");
  const days: { date: string; times: Record<string, { time: string; at: number }> }[] = [];
  for (let day = from; day <= to; day = addDays(day, 1)) {
    if (days.length === MAX_DAYS) return fail(c, 400, "invalid", `At most ${MAX_DAYS} days at once`);
    const instants = dayInstants(day, settings);
    if (!instants) break;
    const times: Record<string, { time: string; at: number }> = {};
    for (const name of NAMES) times[name] = { time: timeIn(settings.timeZone, instants[name]), at: instants[name].getTime() };
    days.push({ date: day, times });
  }
  return c.json({
    timeZone: settings.timeZone,
    method: settings.prayerMethod,
    asrMadhab: settings.asrMadhab,
    location: settings.location,
    days,
  });
});
