// The calendar screen's date logic: month and week grids in Hijri (Umm al-Qura) or Gregorian, the
// titles over them, and the order of a day's tasks. The same rules as CalendarGrid in
// apple/ZimamKit. Days are always the API's local Gregorian day ("2026-10-15"), whichever calendar
// the grid is laid out in; Intl does the Umm al-Qura arithmetic (`islamic-umalqura`).
// Pure functions, no DOM; tested in test/calendar.test.mjs.
import { addDays, parseIsoDate } from "./dates.js";
import { arabicNumber } from "./numbers.js";

export const KINDS = ["hijri", "gregorian"];

const CALENDAR = { hijri: "islamic-umalqura", gregorian: "gregory" };
const numeric = Object.fromEntries(
  KINDS.map((kind) => [
    kind,
    new Intl.DateTimeFormat(`en-u-ca-${CALENDAR[kind]}-nu-latn`, { timeZone: "UTC", year: "numeric", month: "numeric", day: "numeric" }),
  ]),
);
const monthName = Object.fromEntries(
  KINDS.map((kind) => [kind, new Intl.DateTimeFormat(`ar-SA-u-ca-${CALENDAR[kind]}-nu-arab`, { timeZone: "UTC", month: "long" })]),
);
const weekdayLong = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-arab", { timeZone: "UTC", weekday: "long" });
const weekdayNarrow = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-arab", { timeZone: "UTC", weekday: "narrow" });

export const otherKind = (kind) => (kind === "hijri" ? "gregorian" : "hijri");
const known = (kind) => (kind === "gregorian" ? "gregorian" : "hijri");

/** «هـ» after a Hijri year, «م» after a Gregorian one: «١٤٤٨هـ»، «٢٠٢٦م». */
export const yearSuffix = (kind) => (known(kind) === "hijri" ? "هـ" : "م");

/** The day in a calendar: { year, month, day } as numbers. */
export function calendarParts(iso, kind) {
  const parts = numeric[known(kind)].formatToParts(parseIsoDate(iso));
  const get = (type) => Number(parts.find((p) => p.type === type)?.value);
  return { year: get("year"), month: get("month"), day: get("day") };
}

/** 0 = Sunday … 6 = Saturday. */
export const weekday = (iso) => parseIsoDate(iso).getUTCDay();

/** The first day of the month (in `kind`) that contains `iso`. */
export function startOfMonth(iso, kind) {
  return addDays(iso, 1 - calendarParts(iso, kind).day);
}

/** How many days the month containing `iso` has: 29 or 30 in Hijri, 28 to 31 in Gregorian. */
export function monthLength(iso, kind) {
  const start = startOfMonth(iso, kind);
  for (let n = 28; n <= 31; n++) if (calendarParts(addDays(start, n), kind).day === 1) return n;
  return 30;
}

/** Empty cells before the month's first day, so it falls under its weekday. */
export function leadingPadding(iso, { kind, weekStart = 0 }) {
  return (weekday(startOfMonth(iso, kind)) - weekStart + 7) % 7;
}

function cell(iso, kind, inPeriod) {
  return {
    day: iso,
    primaryDay: calendarParts(iso, kind).day,
    secondaryDay: calendarParts(iso, otherKind(kind)).day,
    inPeriod,
  };
}

/**
 * The month containing `iso` in whole weeks: padding days from the months around it
 * (`inPeriod: false`), then the month, then padding again. Always a multiple of seven, in column
 * order (the first column is `weekStart`, 0 = Sunday). → [{ day, primaryDay, secondaryDay, inPeriod }]
 */
export function monthDays(iso, { kind = "hijri", weekStart = 0 } = {}) {
  const start = startOfMonth(iso, kind);
  const count = monthLength(iso, kind);
  const leading = leadingPadding(iso, { kind, weekStart });
  const trailing = (7 - ((leading + count) % 7)) % 7;
  const out = [];
  for (let offset = -leading; offset < count + trailing; offset++) {
    out.push(cell(addDays(start, offset), kind, offset >= 0 && offset < count));
  }
  return out;
}

/** The seven days of the week containing `iso`, starting on `weekStart`. */
export function weekDays(iso, { kind = "hijri", weekStart = 0 } = {}) {
  const back = (weekday(iso) - weekStart + 7) % 7;
  return Array.from({ length: 7 }, (_, i) => cell(addDays(iso, i - back), kind, true));
}

/** The same day of the month `months` months away in `kind`; the last day when that month is shorter. */
export function addMonths(iso, months, kind) {
  const { day } = calendarParts(iso, kind);
  let start = startOfMonth(iso, kind);
  for (let i = 0; i < Math.abs(months); i++) {
    start = months > 0 ? addDays(start, monthLength(start, kind)) : startOfMonth(addDays(start, -1), kind);
  }
  return addDays(start, Math.min(day, monthLength(start, kind)) - 1);
}

/** Weekday names in column order: [{ short: «ح», long: «الأحد» }, …]. */
export function weekdayHeaders(weekStart = 0) {
  // 2026-10-18 is a Sunday.
  return Array.from({ length: 7 }, (_, i) => {
    const iso = addDays("2026-10-18", (weekStart + i) % 7);
    return { short: weekdayNarrow.format(parseIsoDate(iso)), long: weekdayLong.format(parseIsoDate(iso)) };
  });
}

/** «جمادى الأولى ١٤٤٨هـ». */
export function monthYear(iso, kind) {
  return `${monthName[known(kind)].format(parseIsoDate(iso))} ${arabicNumber(calendarParts(iso, kind).year)}${yearSuffix(kind)}`;
}

/** «أكتوبر ٢٠٢٦م», «أكتوبر – نوفمبر ٢٠٢٦م», «ديسمبر ٢٠٢٦م – يناير ٢٠٢٧م». */
export function monthSpan(startIso, endIso, kind) {
  const a = calendarParts(startIso, kind);
  const b = calendarParts(endIso, kind);
  if (a.year === b.year && a.month === b.month) return monthYear(startIso, kind);
  if (a.year === b.year) return `${monthName[known(kind)].format(parseIsoDate(startIso))} – ${monthYear(endIso, kind)}`;
  return `${monthYear(startIso, kind)} – ${monthYear(endIso, kind)}`;
}

/**
 * A month grid's title: the month in `kind` with its year, then the months of the other calendar
 * it spans, joined with the Arabic comma: «جمادى الأولى ١٤٤٨هـ، أكتوبر – نوفمبر ٢٠٢٦م».
 */
export function monthTitle(iso, kind) {
  const start = startOfMonth(iso, kind);
  const end = addDays(start, monthLength(iso, kind) - 1);
  return `${monthYear(start, kind)}، ${monthSpan(start, end, otherKind(kind))}`;
}

/** «٧ – ١٣ جمادى الأولى ١٤٤٨هـ», «٢٨ ربيع الآخر – ٤ جمادى الأولى ١٤٤٨هـ». */
export function daySpan(startIso, endIso, kind) {
  const a = calendarParts(startIso, kind);
  const b = calendarParts(endIso, kind);
  const name = (iso) => monthName[known(kind)].format(parseIsoDate(iso));
  if (a.year === b.year && a.month === b.month) return `${arabicNumber(a.day)} – ${arabicNumber(b.day)} ${monthYear(endIso, kind)}`;
  if (a.year === b.year) return `${arabicNumber(a.day)} ${name(startIso)} – ${arabicNumber(b.day)} ${monthYear(endIso, kind)}`;
  return `${arabicNumber(a.day)} ${monthYear(startIso, kind)} – ${arabicNumber(b.day)} ${monthYear(endIso, kind)}`;
}

/** A week's title in both calendars, `kind` first. */
export function rangeTitle(startIso, endIso, kind) {
  return `${daySpan(startIso, endIso, kind)}، ${daySpan(startIso, endIso, otherKind(kind))}`;
}

// A usual time for each prayer, close enough to order a day's tasks by when no times are known.
const USUAL_PRAYER_MINUTE = { fajr: 5 * 60, dhuhr: 12 * 60, asr: 15 * 60, maghrib: 18 * 60, isha: 19 * 60 + 30 };

/** Minutes after midnight to order a task in its day: the prayer's usual time with its offset, the clock time, or −1 for neither. */
export function minuteOfDay(task) {
  if (task.duePrayer && USUAL_PRAYER_MINUTE[task.duePrayer] != null) {
    return USUAL_PRAYER_MINUTE[task.duePrayer] + (task.duePrayerOffset ?? 0);
  }
  const m = /^(\d{2}):(\d{2})/.exec(task.dueTime ?? "");
  return m ? Number(m[1]) * 60 + Number(m[2]) : -1;
}

/** A day's tasks as the calendar lists them: untimed first, then by time of day, then manual order. */
export function orderDay(tasks) {
  return tasks
    .map((task) => ({ task, minute: minuteOfDay(task) }))
    .sort((a, b) => a.minute - b.minute || (a.task.sortOrder ?? 0) - (b.task.sortOrder ?? 0) || (a.task.createdAt ?? 0) - (b.task.createdAt ?? 0))
    .map((x) => x.task);
}

/** Open top-level tasks by due day: { "2026-10-15": [task, …] }, each day in calendar order. */
export function tasksByDay(tasks) {
  const out = {};
  for (const task of tasks) {
    if (task.parentId || !task.dueDate) continue;
    (out[task.dueDate] ??= []).push(task);
  }
  for (const day of Object.keys(out)) out[day] = orderDay(out[day]);
  return out;
}

/** The new day for a keyboard move inside the grid (RTL: the right arrow goes back a day). */
export function keyMove(iso, key, { kind, weekStart = 0, rtl = true }) {
  switch (key) {
    case "ArrowRight":
      return addDays(iso, rtl ? -1 : 1);
    case "ArrowLeft":
      return addDays(iso, rtl ? 1 : -1);
    case "ArrowUp":
      return addDays(iso, -7);
    case "ArrowDown":
      return addDays(iso, 7);
    case "Home":
      return addDays(iso, -((weekday(iso) - weekStart + 7) % 7));
    case "End":
      return addDays(iso, 6 - ((weekday(iso) - weekStart + 7) % 7));
    case "PageUp":
      return addMonths(iso, -1, kind);
    case "PageDown":
      return addMonths(iso, 1, kind);
    default:
      return null;
  }
}
