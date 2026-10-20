// Repeating tasks as RFC 5545 rules, read and written as apple/ZimamKit/Sources/ZimamKit/Recurrence.swift
// does: FREQ (daily, weekly, monthly, yearly), INTERVAL, BYDAY (weekly), COUNT and UNTIL. A rule
// with anything else Zimam cannot follow reads as null («تكرار مخصص»). Pure functions; tested in
// test/recurrence.test.mjs.
import { arabicNumber } from "./numbers.js";

export const FREQUENCIES = ["DAILY", "WEEKLY", "MONTHLY", "YEARLY"];
/** Sunday first, as Weekday.allCases. */
export const WEEKDAYS = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];
export const WEEKDAY_NAMES = { SU: "الأحد", MO: "الإثنين", TU: "الثلاثاء", WE: "الأربعاء", TH: "الخميس", FR: "الجمعة", SA: "السبت" };

/** "FREQ=WEEKLY;BYDAY=MO,TH" → { frequency, interval, weekdays, count, until }, or null. */
export function parseRule(text) {
  if (typeof text !== "string" || !text.trim()) return null;
  let body = text.trim();
  if (body.toUpperCase().startsWith("RRULE:")) body = body.slice(6);
  const rule = { frequency: null, interval: 1, weekdays: [], count: null, until: null };
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
  if (!rule.frequency) return null;
  rule.weekdays = rule.frequency === "WEEKLY" ? sortDays(rule.weekdays) : [];
  return rule;
}

const sortDays = (days) => [...new Set(days)].sort((a, b) => WEEKDAYS.indexOf(a) - WEEKDAYS.indexOf(b));

/** The rule as the API stores it: "FREQ=WEEKLY;BYDAY=MO,TH". */
export function formatRule({ frequency, interval = 1, weekdays = [], count = null, until = null }) {
  const parts = [`FREQ=${frequency}`];
  if (interval > 1) parts.push(`INTERVAL=${interval}`);
  if (frequency === "WEEKLY" && weekdays.length) parts.push(`BYDAY=${sortDays(weekdays).join(",")}`);
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
  return formatRule({ frequency, interval: same ? current.interval : 1, weekdays, count: current?.count ?? null, until: current?.until ?? null });
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

/** Months later, kept to the month's last day (31 January + 1 month is 28 or 29 February), as Calendar does. */
function addMonths(iso, months) {
  const date = toDate(iso);
  const day = date.getUTCDate();
  const target = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth() + months, 1, 12));
  const last = new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth() + 1, 0, 12)).getUTCDate();
  target.setUTCDate(Math.min(day, last));
  return toIso(target);
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
 * What completing a repeating task due `day` adds: { day, recurrence } for the next occurrence, its
 * rule one occurrence shorter when COUNT is set, skipping days before `notBefore` (today), or null.
 */
export function nextOccurrence(text, day, notBefore = null) {
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
