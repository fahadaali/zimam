/**
 * The next occurrence of a repeating task, as the apps compute it when a task is completed:
 * `Recurrence.swift` in ZimamKit and web/public/app/lib/recurrence.js, ported as is. Rules are
 * RFC 5545 as Zimam stores them: FREQ (daily, weekly, monthly, yearly), INTERVAL, BYDAY (weekly;
 * daily with BYDAY is weekly on those days), BYMONTHDAY (one day, monthly or yearly), BYMONTH (one
 * month, yearly), COUNT (occurrences left, this one included) and UNTIL (a day); WKST is read and
 * dropped. A rule with anything else (BYSETPOS, 1MO, several month days…) reads as null, rather than
 * as a plainer rule that would put the next occurrence on another day. A monthly or yearly series
 * keeps its day across a short month: the occurrence it moves earlier carries the series' day
 * (BYMONTHDAY=31) until it is back on it. Keep the three in step; the cases are shared with
 * web/test/recurrence.test.mjs.
 */

const FREQUENCIES = ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"] as const;
/** Sunday first, as `Date.getUTCDay`. */
const WEEKDAYS = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"] as const;

type Frequency = (typeof FREQUENCIES)[number];
type Weekday = (typeof WEEKDAYS)[number];

interface Rule {
  frequency: Frequency;
  interval: number;
  weekdays: Weekday[];
  count: number | null;
  /** "YYYY-MM-DD". */
  until: string | null;
  /** Monthly and yearly: the series' day of the month (1–31), or a short month's last day. */
  monthDay: number | null;
  /** Yearly: the series' month (1–12). */
  month: number | null;
}

/** "FREQ=WEEKLY;BYDAY=MO,TH", or null when Zimam cannot follow it. */
function parseRule(text: string): Rule | null {
  let body = text.trim();
  if (!body) return null;
  if (body.toUpperCase().startsWith("RRULE:")) body = body.slice(6);
  let frequency: Frequency | null = null;
  const rule: Omit<Rule, "frequency"> = { interval: 1, weekdays: [], count: null, until: null, monthDay: null, month: null };
  let byDay = false;
  for (const part of body.split(";")) {
    const [key, value, extra] = part.split("=");
    if (key === undefined || value === undefined || extra !== undefined) return null;
    switch (key.toUpperCase()) {
      case "FREQ":
        if (!(FREQUENCIES as readonly string[]).includes(value.toUpperCase())) return null;
        frequency = value.toUpperCase() as Frequency;
        break;
      case "INTERVAL":
        if (!/^\d+$/.test(value) || Number(value) < 1) return null;
        rule.interval = Number(value);
        break;
      case "BYDAY": {
        const days = value.split(",").map((d) => d.toUpperCase());
        if (days.some((d) => !(WEEKDAYS as readonly string[]).includes(d))) return null;
        rule.weekdays = days as Weekday[];
        byDay = true;
        break;
      }
      case "BYMONTHDAY":
        if (!/^\d+$/.test(value) || Number(value) < 1 || Number(value) > 31) return null;
        rule.monthDay = Number(value);
        break;
      case "BYMONTH":
        if (!/^\d+$/.test(value) || Number(value) < 1 || Number(value) > 12) return null;
        rule.month = Number(value);
        break;
      case "COUNT":
        if (!/^\d+$/.test(value) || Number(value) < 1) return null;
        rule.count = Number(value);
        break;
      case "UNTIL": {
        const m = /^(\d{4})(\d{2})(\d{2})/.exec(value);
        if (!m) return null;
        rule.until = `${m[1]}-${m[2]}-${m[3]}`;
        break;
      }
      case "WKST":
        break; // Only where weeks start; Zimam's weeks start on Monday.
      default:
        return null; // BYSETPOS, BYYEARDAY, BYWEEKNO, BYHOUR…: days or times Zimam cannot follow.
    }
  }
  if (!frequency) return null;
  if (byDay && frequency !== "WEEKLY") {
    // Every day, on some weekdays only, is weekly on those days; anything else is not followed.
    if (frequency !== "DAILY" || rule.interval !== 1 || rule.weekdays.length === 0) return null;
    frequency = "WEEKLY";
  }
  // A yearly month day without its month would be that day of every month.
  if (rule.monthDay !== null && frequency !== "MONTHLY" && (frequency !== "YEARLY" || rule.month === null)) return null;
  if (rule.month !== null && frequency !== "YEARLY") return null;
  return { ...rule, frequency, weekdays: frequency === "WEEKLY" ? sortDays(rule.weekdays) : [] };
}

const sortDays = (days: Weekday[]) => [...new Set(days)].sort((a, b) => WEEKDAYS.indexOf(a) - WEEKDAYS.indexOf(b));

function formatRule({ frequency, interval, weekdays, count, until, monthDay, month }: Rule): string {
  const parts = [`FREQ=${frequency}`];
  if (interval > 1) parts.push(`INTERVAL=${interval}`);
  if (frequency === "WEEKLY" && weekdays.length) parts.push(`BYDAY=${sortDays(weekdays).join(",")}`);
  const yearMonth = frequency === "YEARLY" ? month : null;
  if (yearMonth !== null) parts.push(`BYMONTH=${yearMonth}`);
  if (monthDay !== null && (frequency === "MONTHLY" || yearMonth !== null)) parts.push(`BYMONTHDAY=${monthDay}`);
  if (count) parts.push(`COUNT=${count}`);
  if (until) parts.push(`UNTIL=${until.replaceAll("-", "")}`);
  return parts.join(";");
}

const DAY_MS = 86_400_000;
const toDate = (day: string) => {
  const [y, m, d] = day.split("-").map(Number) as [number, number, number];
  return new Date(Date.UTC(y, m - 1, d, 12));
};
const toDay = (date: Date) => date.toISOString().slice(0, 10);

/** "2026-10-15" → [year, month (1–12), day]. */
const partsOf = (day: string) => day.split("-").map(Number) as [number, number, number];

/** Days in a month (1–12) of a year. */
const monthLength = (year: number, month: number) => new Date(Date.UTC(year, month, 0, 12)).getUTCDate();

/**
 * Monthly and yearly: the series' day (monthDay, else the day's own) in the month `interval` months
 * or years on, or that month's last day when it is shorter. With monthDay or month set the next
 * occurrence may still fall in the day's own month or year: BYMONTHDAY=20 after the 15th is the 20th.
 */
function nextInMonth(rule: Rule, day: string): string | null {
  const start = toDate(day);
  const yearly = rule.frequency === "YEARLY";
  const dayOfMonth = rule.monthDay ?? start.getUTCDate();
  const steps = rule.monthDay === null && rule.month === null ? [rule.interval] : [0, rule.interval];
  for (const step of steps) {
    const year = start.getUTCFullYear() + (yearly ? step : 0);
    const month = rule.month !== null ? rule.month - 1 : start.getUTCMonth() + (yearly ? 0 : step);
    const last = new Date(Date.UTC(year, month + 1, 0, 12)).getUTCDate();
    const candidate = new Date(Date.UTC(year, month, Math.min(dayOfMonth, last), 12));
    if (candidate > start) return toDay(candidate);
  }
  return null;
}

/** The Monday that starts a date's week, the anchor every-n-weeks counts from. */
const mondayOf = (date: Date) => new Date(date.getTime() - ((date.getUTCDay() + 6) % 7) * DAY_MS);

function nextWeekly(rule: Rule, day: string): string | null {
  const start = toDate(day);
  if (rule.weekdays.length === 0) return toDay(new Date(start.getTime() + 7 * rule.interval * DAY_MS));
  const wanted = new Set(rule.weekdays.map((d) => WEEKDAYS.indexOf(d)));
  const startWeek = mondayOf(start);
  for (let offset = 1; offset <= 7 * rule.interval + 7; offset++) {
    const candidate = new Date(start.getTime() + offset * DAY_MS);
    if (!wanted.has(candidate.getUTCDay())) continue;
    const weeks = Math.round((mondayOf(candidate).getTime() - startWeek.getTime()) / (7 * DAY_MS));
    if (weeks % rule.interval === 0) return toDay(candidate);
  }
  return null;
}

/** The day after `day` the rule falls on, or null when the series ends. */
function nextDay(rule: Rule, day: string): string | null {
  if (rule.count != null && rule.count <= 1) return null;
  let next: string | null;
  switch (rule.frequency) {
    case "DAILY":
      next = toDay(new Date(toDate(day).getTime() + rule.interval * DAY_MS));
      break;
    case "WEEKLY":
      next = nextWeekly(rule, day);
      break;
    default:
      next = nextInMonth(rule, day);
  }
  if (!next || (rule.until && next > rule.until)) return null;
  return next;
}

/**
 * Without monthDay and month once an occurrence falls on them: from there the plain rule gives the
 * same days, until a short month, which nextOccurrence keeps the day across.
 */
function settled(rule: Rule, day: string): Rule {
  if (rule.monthDay === null && rule.month === null) return rule;
  const [, month, dayOfMonth] = partsOf(day);
  if ((rule.monthDay !== null && rule.monthDay !== dayOfMonth) || (rule.month !== null && rule.month !== month)) return rule;
  return { ...rule, monthDay: null, month: null };
}

/**
 * The rule of a task due `day` once it is moved to another day (Recurrence.moved(from:)): without
 * the series' day (BYMONTHDAY, BYMONTH) when `day` was on it, or on the last day of a month too short
 * for it, so the series follows the move as a plain rule's does rather than add a second occurrence
 * in the month it was moved within. A day the rule picks other than the task's own stays. The text
 * as it was when nothing changes, or when it cannot be read.
 */
export function movedRule(text: string, day: string): string {
  const rule = parseRule(text);
  if (!rule || (rule.monthDay === null && rule.month === null) || !/^\d{4}-\d{2}-\d{2}$/.test(day)) return text;
  const [year, month, dayOfMonth] = partsOf(day);
  if (rule.month !== null && rule.month !== month) return text;
  if (rule.monthDay !== null && dayOfMonth !== Math.min(rule.monthDay, monthLength(year, month))) return text;
  return formatRule({ ...rule, monthDay: null, month: null });
}

/**
 * What completing a repeating task due `day` adds: the next occurrence's day and its rule, one
 * occurrence shorter when COUNT is set, skipping days before `notBefore` (today); or null. A monthly
 * or yearly series keeps `day`'s day of the month, so a short month on the way does not move the ones
 * after it; the rule returned carries it only while it is needed.
 */
export function nextOccurrence(text: string, day: string, notBefore: string | null = null): { day: string; recurrence: string } | null {
  let rule = parseRule(text);
  if (!rule) return null;
  if ((rule.frequency === "MONTHLY" || rule.frequency === "YEARLY") && rule.monthDay === null) {
    const [, month, dayOfMonth] = partsOf(day);
    rule = { ...rule, monthDay: dayOfMonth, month: rule.frequency === "YEARLY" ? (rule.month ?? month) : rule.month };
  }
  let current = day;
  for (let i = 0; i < 1000; i++) {
    const next = nextDay(rule, current);
    if (!next) return null;
    rule = rule.count != null ? { ...rule, count: Math.max(1, rule.count - 1) } : rule;
    if (notBefore && next < notBefore) {
      current = next;
      continue;
    }
    return { day: next, recurrence: formatRule(settled(rule, next)) };
  }
  return null;
}

/**
 * A task merged with a patch that moves it to another day keeps the series following the move
 * (movedRule), as the app's Store.update does; a patch that sets the rule itself is left alone.
 */
export function followMove(current: Record<string, unknown>, patch: Record<string, unknown>): Record<string, unknown> {
  const from = current.dueDate, to = patch.dueDate, rule = current.recurrence;
  if ("recurrence" in patch || typeof from !== "string" || typeof to !== "string" || from === to || typeof rule !== "string") return {};
  return { recurrence: movedRule(rule, from) };
}
