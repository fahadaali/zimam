import { dayOfHijri } from "../data/dates";

/**
 * Date handling for imports. Zimam keeps a task's due date and time as the user's
 * local wall clock ("2026-10-20", "09:00"), so:
 *
 * - A date or time without a zone is taken as written, in the user's zone.
 * - An instant (with "Z" or an offset) is converted to the given zone, normally
 *   `settings.timeZone`.
 */

export interface LocalDateTime {
  date: string;
  time: string | null;
}

/** Arabic-Indic and Persian digits to Latin, and the Arabic date separators to ASCII ones. */
export function latinDigits(text: string): string {
  return text
    .replace(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x0660))
    .replace(/[۰-۹]/g, (d) => String(d.charCodeAt(0) - 0x06f0))
    .replace(/[٫]/g, ".")
    .replace(/[،]/g, ",");
}

const pad = (n: number) => String(n).padStart(2, "0");

export function isTimeZone(zone: string | null | undefined): zone is string {
  if (!zone) return false;
  try {
    new Intl.DateTimeFormat("en", { timeZone: zone });
    return true;
  } catch {
    return false;
  }
}

/** The local date and "HH:mm" of an instant in a zone. */
export function zonedDateTime(instant: number, timeZone: string): { date: string; time: string } {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(instant));
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "00";
  return { date: `${get("year")}-${get("month")}-${get("day")}`, time: `${get("hour")}:${get("minute")}` };
}

/** Offset of a zone at an instant, in minutes east of UTC. */
function offsetMinutes(instant: number, timeZone: string): number {
  const { date, time } = zonedDateTime(instant, timeZone);
  const asUtc = Date.parse(`${date}T${time}:00Z`);
  return Math.round((asUtc - Math.floor(instant / 60_000) * 60_000) / 60_000);
}

/** The instant of a local wall-clock time in a zone (the earlier one when the clock repeats). */
export function localToInstant(date: string, time: string, timeZone: string): number {
  const guess = Date.parse(`${date}T${time}:00Z`);
  let instant = guess - offsetMinutes(guess, timeZone) * 60_000;
  // A second pass settles zones whose offset changed between the guess and the answer.
  instant = guess - offsetMinutes(instant, timeZone) * 60_000;
  return instant;
}

/** "2026-10-20T09:00:00+03:00": an instant written with the zone's offset at that moment. */
export function isoWithOffset(instant: number, timeZone: string): string {
  const offset = offsetMinutes(instant, timeZone);
  const { date, time } = zonedDateTime(instant, timeZone);
  const sign = offset < 0 ? "-" : "+";
  const abs = Math.abs(offset);
  return `${date}T${time}:00${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`;
}

function validDay(y: number, m: number, d: number): string | null {
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  const date = new Date(Date.UTC(y, m - 1, d));
  if (date.getUTCMonth() !== m - 1 || date.getUTCDate() !== d) return null;
  return `${String(y).padStart(4, "0")}-${pad(m)}-${pad(d)}`;
}

/** Years in this range are Hijri (Umm al-Qura); Gregorian years in it are not plausible for tasks. */
const isHijriYear = (y: number) => y >= 1300 && y <= 1600;

/** A day from year, month and day, Gregorian or Hijri by the year. */
function makeDay(y: number, m: number, d: number): string | null {
  if (isHijriYear(y)) return dayOfHijri({ year: y, month: m, day: d }, "2026-01-01");
  if (y < 1900 || y > 2200) return null;
  return validDay(y, m, d);
}

const MONTHS: Record<string, number> = {
  jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, sept: 9, oct: 10, nov: 11, dec: 12,
  january: 1, february: 2, march: 3, april: 4, june: 6, july: 7, august: 8, september: 9, october: 10,
  november: 11, december: 12,
  يناير: 1, فبراير: 2, مارس: 3, أبريل: 4, ابريل: 4, مايو: 5, يونيو: 6, يوليو: 7, أغسطس: 8, اغسطس: 8,
  سبتمبر: 9, أكتوبر: 10, اكتوبر: 10, نوفمبر: 11, ديسمبر: 12,
};

/** "14:30", "2:30 PM", "2:30 م", "9am", "14:30:00". */
export function parseTime(text: string): string | null {
  const m = latinDigits(text)
    .trim()
    .toLowerCase()
    .match(/^(\d{1,2})(?::(\d{2}))?(?::\d{2}(?:\.\d+)?)?\s*(am|pm|a\.m\.|p\.m\.|ص|م|صباحاً|صباحا|مساءً|مساء)?$/);
  if (!m) return null;
  let hour = Number(m[1]);
  const minute = m[2] === undefined ? 0 : Number(m[2]);
  const meridiem = m[3];
  if (m[2] === undefined && !meridiem) return null;
  if (meridiem) {
    if (hour < 1 || hour > 12) return null;
    const pm = /^(pm|p\.m\.|م|مساءً|مساء)$/.test(meridiem);
    hour = (hour % 12) + (pm ? 12 : 0);
  }
  if (hour > 23 || minute > 59) return null;
  return `${pad(hour)}:${pad(minute)}`;
}

/**
 * Reads the absolute dates people and apps write in CSV files:
 *
 * - ISO: "2026-10-20", "2026/10/20", "2026-10-20 14:30", "2026-10-20T14:30:00".
 * - With "Z" or an offset: converted to `timeZone`.
 * - Day first: "20/10/2026", "20-10-2026 2:30 PM"; month first only when the day
 *   cannot be a month ("10/20/2026").
 * - Month names: "Oct 20 2026", "20 October 2026", "October 20, 2026", «٢٠ أكتوبر ٢٠٢٦».
 * - Hijri (Umm al-Qura) when the year is 1300–1600: «١٤٤٨/٠٤/١٥»، "15/4/1448 هـ".
 *
 * Relative or recurring text ("tomorrow", "every day") gives null: the caller keeps it as a note.
 */
export function parseDateText(input: string, timeZone: string): LocalDateTime | null {
  let text = latinDigits(input).trim().replace(/\s+/g, " ");
  if (!text) return null;
  text = text.replace(/(\d)\s*(هـ|ه)\.?$/u, "$1");

  // ISO with a zone: an instant.
  const instant = text.match(/^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?)\s*(Z|[+-]\d{2}:?\d{2})$/i);
  if (instant) {
    const zone = instant[3]!.toUpperCase() === "Z" ? "Z" : instant[3]!.replace(/^([+-]\d{2})(\d{2})$/, "$1:$2");
    const ms = Date.parse(`${instant[1]}T${instant[2]}${zone}`);
    if (Number.isNaN(ms)) return null;
    return zonedDateTime(ms, timeZone);
  }

  const [datePart, timeText0] = splitDateAndTime(text);
  const timeText = timeText0.trim();
  const time = timeText ? parseTime(timeText) : null;
  if (timeText && !time) return null;
  const date = parseDay(datePart);
  return date ? { date, time } : null;
}

/** Splits "2026-10-20 14:30" / "20 Oct 2026 2:30 PM" into the date and the time text. */
function splitDateAndTime(text: string): [string, string] {
  const iso = text.match(/^(\d{4}[-/.]\d{1,2}[-/.]\d{1,2})(?:[T ](.+))?$/);
  if (iso) return [iso[1]!, iso[2] ?? ""];
  const numeric = text.match(/^(\d{1,2}[-/.]\d{1,2}[-/.]\d{4})(?: (.+))?$/);
  if (numeric) return [numeric[1]!, numeric[2] ?? ""];
  // Month names: the time, if any, is what follows the four-digit year.
  const named = text.match(/^(.*?\d{4})(?:,? (?:at )?(.+))?$/i);
  if (named) return [named[1]!, named[2] ?? ""];
  return [text, ""];
}

function parseDay(text: string): string | null {
  let m = text.match(/^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$/);
  if (m) return makeDay(Number(m[1]), Number(m[2]), Number(m[3]));
  m = text.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$/);
  if (m) {
    const a = Number(m[1]);
    const b = Number(m[2]);
    const y = Number(m[3]);
    // Day first, as written in Arabic-speaking countries, unless that cannot be.
    return b > 12 && a <= 12 ? makeDay(y, a, b) : makeDay(y, b, a);
  }
  const words = text.toLowerCase().replace(/,/g, " ").replace(/\s+/g, " ").trim().split(" ");
  // Drop a leading weekday ("Tue Oct 20 2026").
  if (words.length === 4 && !/\d/.test(words[0]!)) words.shift();
  if (words.length !== 3) return null;
  const [w1, w2, w3] = words as [string, string, string];
  const y = Number(w3);
  if (!/^\d{4}$/.test(w3)) return null;
  if (MONTHS[w1] && /^\d{1,2}(st|nd|rd|th)?$/.test(w2)) return makeDay(y, MONTHS[w1], Number.parseInt(w2, 10));
  if (MONTHS[w2] && /^\d{1,2}(st|nd|rd|th)?$/.test(w1)) return makeDay(y, MONTHS[w2], Number.parseInt(w1, 10));
  return null;
}

const DAY_CODES: Record<string, string> = {
  monday: "MO", mon: "MO", tuesday: "TU", tue: "TU", tues: "TU", wednesday: "WE", wed: "WE",
  thursday: "TH", thu: "TH", thur: "TH", thurs: "TH", friday: "FR", fri: "FR", saturday: "SA", sat: "SA",
  sunday: "SU", sun: "SU",
};

const FREQUENCIES: Record<string, string> = {
  day: "DAILY", days: "DAILY", week: "WEEKLY", weeks: "WEEKLY", month: "MONTHLY", months: "MONTHLY",
  year: "YEARLY", years: "YEARLY",
};

/**
 * The common English recurrence phrases (Todoist's) as an RRULE: "every day",
 * "every 2 weeks", "every monday, thursday", "every weekday", "daily" — with an
 * optional "at 9am". Anything else (e.g. "every! 3 days", "every last friday") gives null.
 */
export function recurrenceFromText(input: string): string | null {
  const text = input
    .toLowerCase()
    .trim()
    .replace(/\s+(at|@)\s+.+$/, "")
    .replace(/\s+/g, " ");
  const simple: Record<string, string> = {
    daily: "FREQ=DAILY", everyday: "FREQ=DAILY", weekly: "FREQ=WEEKLY", monthly: "FREQ=MONTHLY",
    yearly: "FREQ=YEARLY", annually: "FREQ=YEARLY",
    "every weekday": "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", "every workday": "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR",
    "every weekend": "FREQ=WEEKLY;BYDAY=SA,SU",
  };
  if (simple[text]) return simple[text];
  const m = text.match(/^every (?:(\d{1,3}|other) )?(day|days|week|weeks|month|months|year|years)$/);
  if (m) {
    const interval = m[1] === "other" ? 2 : m[1] ? Number(m[1]) : 1;
    if (interval < 1) return null;
    return `FREQ=${FREQUENCIES[m[2]!]}${interval > 1 ? `;INTERVAL=${interval}` : ""}`;
  }
  const days = text.match(/^every ([a-z]+(?:\s*(?:,|and)\s*[a-z]+)*)$/);
  if (days) {
    const codes = days[1]!.split(/\s*(?:,|and)\s*/).map((d) => DAY_CODES[d]);
    if (codes.length && codes.every(Boolean)) return `FREQ=WEEKLY;BYDAY=${[...new Set(codes)].join(",")}`;
  }
  return null;
}

/** ISO 8601 duration ("-PT15M", "P0DT9H0M0S", "P1D") in milliseconds, or null. */
export function durationMs(input: string): number | null {
  const m = input.trim().match(/^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/);
  if (!m || input.trim().replace(/^[+-]/, "") === "P") return null;
  const [, sign, w, d, h, min, s] = m;
  const ms = ((((Number(w ?? 0) * 7 + Number(d ?? 0)) * 24 + Number(h ?? 0)) * 60 + Number(min ?? 0)) * 60 + Number(s ?? 0)) * 1000;
  return sign === "-" ? -ms : ms;
}
