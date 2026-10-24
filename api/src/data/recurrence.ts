/**
 * The next occurrence of a repeating task, as the apps compute it when a task is completed:
 * `Recurrence.swift` in ZimamKit and web/public/app/lib/recurrence.js, ported as is. Rules are
 * RFC 5545 as Zimam stores them: FREQ (daily, weekly, monthly, yearly), INTERVAL, BYDAY (weekly),
 * COUNT (occurrences left, this one included) and UNTIL (a day). A rule with anything else Zimam
 * cannot follow reads as null. Keep the three in step; the cases are shared with
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
}

/** "FREQ=WEEKLY;BYDAY=MO,TH", or null when Zimam cannot follow it. */
function parseRule(text: string): Rule | null {
  let body = text.trim();
  if (!body) return null;
  if (body.toUpperCase().startsWith("RRULE:")) body = body.slice(6);
  let frequency: Frequency | null = null;
  const rule: Omit<Rule, "frequency"> = { interval: 1, weekdays: [], count: null, until: null };
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
        break;
      }
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
      default:
        break; // WKST and the like do not change the days Zimam computes.
    }
  }
  if (!frequency) return null;
  return { ...rule, frequency, weekdays: frequency === "WEEKLY" ? sortDays(rule.weekdays) : [] };
}

const sortDays = (days: Weekday[]) => [...new Set(days)].sort((a, b) => WEEKDAYS.indexOf(a) - WEEKDAYS.indexOf(b));

function formatRule({ frequency, interval, weekdays, count, until }: Rule): string {
  const parts = [`FREQ=${frequency}`];
  if (interval > 1) parts.push(`INTERVAL=${interval}`);
  if (frequency === "WEEKLY" && weekdays.length) parts.push(`BYDAY=${sortDays(weekdays).join(",")}`);
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

/** Months later, kept to the month's last day (31 January + 1 month is 28 or 29 February), as Calendar does. */
function addMonths(day: string, months: number): string {
  const date = toDate(day);
  const dayOfMonth = date.getUTCDate();
  const target = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + months, 1, 12));
  const last = new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth() + 1, 0, 12)).getUTCDate();
  target.setUTCDate(Math.min(dayOfMonth, last));
  return toDay(target);
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
    case "MONTHLY":
      next = addMonths(day, rule.interval);
      break;
    default:
      next = addMonths(day, 12 * rule.interval);
  }
  if (!next || (rule.until && next > rule.until)) return null;
  return next;
}

/**
 * What completing a repeating task due `day` adds: the next occurrence's day and its rule, one
 * occurrence shorter when COUNT is set, skipping days before `notBefore` (today); or null.
 */
export function nextOccurrence(text: string, day: string, notBefore: string | null = null): { day: string; recurrence: string } | null {
  let rule = parseRule(text);
  if (!rule) return null;
  let current = day;
  for (let i = 0; i < 1000; i++) {
    const next = nextDay(rule, current);
    if (!next) return null;
    rule = rule.count != null ? { ...rule, count: Math.max(1, rule.count - 1) } : rule;
    if (notBefore && next < notBefore) {
      current = next;
      continue;
    }
    return { day: next, recurrence: formatRule(rule) };
  }
  return null;
}
