// Repeating tasks as RFC 5545 rules, read and written as apple/ZimamKit/Sources/ZimamKit/Recurrence.swift
// does: FREQ (daily, weekly, monthly, yearly), INTERVAL, BYDAY (weekly; daily with BYDAY is weekly on
// those days), BYMONTHDAY (one day, monthly or yearly), BYMONTH (one month, yearly), COUNT and UNTIL;
// WKST is read and dropped. A rule with anything else (BYSETPOS, «the first Monday» as 1MO, several
// month days…) reads as null («تكرار مخصص»), rather than as a plainer rule that would put the next
// occurrence on another day. A monthly or yearly series keeps its day across a short month: the
// occurrence it moves earlier carries the series' day (BYMONTHDAY=31) until it is back on it. Pure
// functions; tested in test/recurrence.test.mjs.
import { arabicNumber } from "./numbers.js";

export const FREQUENCIES = ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"];
/** Sunday first, as Weekday.allCases. */
export const WEEKDAYS = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];
export const WEEKDAY_NAMES = { SU: "الأحد", MO: "الإثنين", TU: "الثلاثاء", WE: "الأربعاء", TH: "الخميس", FR: "الجمعة", SA: "السبت" };

/** "FREQ=WEEKLY;BYDAY=MO,TH" → { frequency, interval, weekdays, count, until, monthDay, month }, or null. */
export function parseRule(text) {
  if (typeof text !== "string" || !text.trim()) return null;
  let body = text.trim();
  if (body.toUpperCase().startsWith("RRULE:")) body = body.slice(6);
  const rule = { frequency: null, interval: 1, weekdays: [], count: null, until: null, monthDay: null, month: null };
  let byDay = false;
  for (const part of body.split(";")) {
    const [key, value, extra] = part.split("=");
    if (value === undefined || extra !== undefined) return null;
    switch (key.toUpperCase()) {
      case "FREQ":
        if (!FREQUENCIES.includes(value.toUpperCase())) return null;
        rule.frequency = value.toUpperCase();
        break;
      case "INTERVAL":
        if (!/^\d+$/.test(value) || Number(value) < 1) return null;
        rule.interval = Number(value);
        break;
      case "BYDAY": {
        const days = value.split(",").map((d) => d.toUpperCase());
        if (days.some((d) => !WEEKDAYS.includes(d))) return null;
        rule.weekdays = days;
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
  if (!rule.frequency) return null;
  if (byDay && rule.frequency !== "WEEKLY") {
    // Every day, on some weekdays only, is weekly on those days; anything else is not followed.
    if (rule.frequency !== "DAILY" || rule.interval !== 1 || rule.weekdays.length === 0) return null;
    rule.frequency = "WEEKLY";
  }
  // A yearly month day without its month would be that day of every month.
  if (rule.monthDay != null && rule.frequency !== "MONTHLY" && (rule.frequency !== "YEARLY" || rule.month == null)) return null;
  if (rule.month != null && rule.frequency !== "YEARLY") return null;
  rule.weekdays = rule.frequency === "WEEKLY" ? sortDays(rule.weekdays) : [];
  return rule;
}

const sortDays = (days) => [...new Set(days)].sort((a, b) => WEEKDAYS.indexOf(a) - WEEKDAYS.indexOf(b));

/** The rule as the API stores it: "FREQ=WEEKLY;BYDAY=MO,TH". */
export function formatRule({ frequency, interval = 1, weekdays = [], count = null, until = null, monthDay = null, month = null }) {
  const parts = [`FREQ=${frequency}`];
  if (interval > 1) parts.push(`INTERVAL=${interval}`);
  if (frequency === "WEEKLY" && weekdays.length) parts.push(`BYDAY=${sortDays(weekdays).join(",")}`);
  const yearMonth = frequency === "YEARLY" ? month : null;
  if (yearMonth != null) parts.push(`BYMONTH=${yearMonth}`);
  if (monthDay != null && (frequency === "MONTHLY" || yearMonth != null)) parts.push(`BYMONTHDAY=${monthDay}`);
  if (count) parts.push(`COUNT=${count}`);
  if (until) parts.push(`UNTIL=${until.replaceAll("-", "")}`);
  return parts.join(";");
}

/** «يومياً» … for the picker: "off", a frequency, or "custom" for a rule Zimam cannot edit. */
export function ruleChoice(text) {
  if (!text) return "off";
  return parseRule(text)?.frequency ?? "custom";
}

/**
 * The rule after choosing a frequency in «التكرار», as TaskRecurrenceSection.choose: the interval
 * and days stay when the frequency does; a weekly rule starts on the due day's weekday.
 */
export function chooseFrequency(text, frequency, dueDate) {
  if (frequency === "off") return null;
  const current = parseRule(text);
  const same = current?.frequency === frequency;
  let weekdays = same ? current.weekdays : [];
  if (frequency === "WEEKLY" && weekdays.length === 0) weekdays = [weekdayOf(dueDate)];
  // The same frequency again keeps the series' day of the month (BYMONTHDAY).
  return formatRule({
    frequency,
    interval: same ? current.interval : 1,
    weekdays,
    count: current?.count ?? null,
    until: current?.until ?? null,
    monthDay: same ? current.monthDay : null,
    month: same ? current.month : null,
  });
}

/** Adds or removes a weekday of a weekly rule; the last one stays. */
export function toggleWeekday(text, day) {
  const rule = parseRule(text);
  if (!rule || rule.frequency !== "WEEKLY") return text;
  const has = rule.weekdays.includes(day);
  if (has && rule.weekdays.length === 1) return text;
  rule.weekdays = has ? rule.weekdays.filter((d) => d !== day) : [...rule.weekdays, day];
  return formatRule(rule);
}

/** The weekday code of a "YYYY-MM-DD" day (today's when there is none). */
export function weekdayOf(iso, now = new Date()) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso ?? "");
  const day = m ? new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), 12)).getUTCDay() : now.getDay();
  return WEEKDAYS[day];
}

/** Arabic number agreement: «يوم»، «يومين»، «٣ أيام»، «١١ يوماً». */
function counted(n, one, two, few, many) {
  if (n === 1) return one;
  if (n === 2) return two;
  if (n >= 3 && n <= 10) return `${arabicNumber(n)} ${few}`;
  return `${arabicNumber(n)} ${many}`;
}

/** «كل يوم»، «كل ٣ أيام»، «كل أسبوع يوم الخميس»، «كل شهر»، «كل سنة» (Recurrence.arabicDescription). */
export function ruleText(text) {
  const rule = typeof text === "string" ? parseRule(text) : text;
  if (!rule) return null;
  switch (rule.frequency) {
    case "DAILY":
      return `كل ${counted(rule.interval, "يوم", "يومين", "أيام", "يوماً")}`;
    case "WEEKLY": {
      if (rule.interval === 1 && rule.weekdays.length === 7) return "كل يوم";
      const base = `كل ${counted(rule.interval, "أسبوع", "أسبوعين", "أسابيع", "أسبوعاً")}`;
      const names = rule.weekdays.map((d) => WEEKDAY_NAMES[d]);
      if (names.length === 0) return base;
      if (names.length === 1) return `${base} يوم ${names[0]}`;
      if (names.length === 2) return `${base} يومي ${names[0]} و${names[1]}`;
      return `${base} أيام ${names.join(" و")}`;
    }
    case "MONTHLY":
      return `كل ${counted(rule.interval, "شهر", "شهرين", "أشهر", "شهراً")}`;
    default:
      return `كل ${counted(rule.interval, "سنة", "سنتين", "سنوات", "سنة")}`;
  }
}

// ——— The next occurrence (Recurrence.nextDay / nextOccurrence) ———

const DAY_MS = 86_400_000;
const toDate = (iso) => {
  const [y, m, d] = iso.split("-").map(Number);
  return new Date(Date.UTC(y, m - 1, d, 12));
};
const toIso = (date) => date.toISOString().slice(0, 10);

/** "2026-10-15" → [year, month (1–12), day]. */
const partsOf = (iso) => iso.split("-").map(Number);

/** Days in a month (1–12) of a year. */
const monthLength = (year, month) => new Date(Date.UTC(year, month, 0, 12)).getUTCDate();

/**
 * Monthly and yearly: the series' day (monthDay, else the day's own) in the month `interval` months
 * or years on, or that month's last day when it is shorter. With monthDay or month set the next
 * occurrence may still fall in the day's own month or year: BYMONTHDAY=20 after the 15th is the 20th.
 */
function nextInMonth(rule, iso) {
  const start = toDate(iso);
  const yearly = rule.frequency === "YEARLY";
  const day = rule.monthDay ?? start.getUTCDate();
  const steps = rule.monthDay == null && rule.month == null ? [rule.interval] : [0, rule.interval];
  for (const step of steps) {
    const year = start.getUTCFullYear() + (yearly ? step : 0);
    const month = rule.month != null ? rule.month - 1 : start.getUTCMonth() + (yearly ? 0 : step);
    const last = new Date(Date.UTC(year, month + 1, 0, 12)).getUTCDate();
    const candidate = new Date(Date.UTC(year, month, Math.min(day, last), 12));
    if (candidate > start) return toIso(candidate);
  }
  return null;
}

/** The Monday that starts a date's week, the anchor every-n-weeks counts from. */
const mondayOf = (date) => new Date(date.getTime() - ((date.getUTCDay() + 6) % 7) * DAY_MS);

function nextWeekly(rule, day) {
  const start = toDate(day);
  if (rule.weekdays.length === 0) return toIso(new Date(start.getTime() + 7 * rule.interval * DAY_MS));
  const wanted = new Set(rule.weekdays.map((d) => WEEKDAYS.indexOf(d)));
  const startWeek = mondayOf(start);
  for (let offset = 1; offset <= 7 * rule.interval + 7; offset++) {
    const candidate = new Date(start.getTime() + offset * DAY_MS);
    if (!wanted.has(candidate.getUTCDay())) continue;
    const weeks = Math.round((mondayOf(candidate).getTime() - startWeek.getTime()) / (7 * DAY_MS));
    if (weeks % rule.interval === 0) return toIso(candidate);
  }
  return null;
}

/** The day after `day` the rule falls on, or null when the series ends. */
export function nextDay(rule, day) {
  if (rule.count != null && rule.count <= 1) return null;
  let next;
  switch (rule.frequency) {
    case "DAILY":
      next = toIso(new Date(toDate(day).getTime() + rule.interval * DAY_MS));
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
function settled(rule, day) {
  if (rule.monthDay == null && rule.month == null) return rule;
  const [, month, dayOfMonth] = partsOf(day);
  if ((rule.monthDay != null && rule.monthDay !== dayOfMonth) || (rule.month != null && rule.month !== month)) return rule;
  return { ...rule, monthDay: null, month: null };
}

/**
 * The rule of a task due `day` once it is moved to another day (Recurrence.moved(from:)): without
 * the series' day (BYMONTHDAY, BYMONTH) when `day` was on it, or on the last day of a month too short
 * for it, so the series follows the move as a plain rule's does rather than add a second occurrence
 * in the month it was moved within. A day the rule picks other than the task's own stays. The text
 * as it was when nothing changes, or when it cannot be read.
 */
export function movedRule(text, day) {
  const rule = parseRule(text);
  if (!rule || (rule.monthDay == null && rule.month == null) || !/^\d{4}-\d{2}-\d{2}$/.test(day ?? "")) return text;
  const [year, month, dayOfMonth] = partsOf(day);
  if (rule.month != null && rule.month !== month) return text;
  if (rule.monthDay != null && dayOfMonth !== Math.min(rule.monthDay, monthLength(year, month))) return text;
  return formatRule({ ...rule, monthDay: null, month: null });
}

/**
 * What completing a repeating task due `day` adds: { day, recurrence } for the next occurrence, its
 * rule one occurrence shorter when COUNT is set, skipping days before `notBefore` (today), or null.
 * A monthly or yearly series keeps `day`'s day of the month, so a short month on the way does not move
 * the ones after it; the rule returned carries it only while it is needed.
 */
export function nextOccurrence(text, day, notBefore = null) {
  let rule = parseRule(text);
  if (!rule) return null;
  if ((rule.frequency === "MONTHLY" || rule.frequency === "YEARLY") && rule.monthDay == null) {
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
