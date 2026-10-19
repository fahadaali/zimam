/** Arabic date text for server-built answers (MCP), matching the app's wording. */

const AR = "ar-SA";

/** The local day ("2026-10-13") that `instant` falls on in `timeZone`. */
export function dayIn(timeZone: string, instant = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(instant);
}

export function addDays(day: string, days: number): string {
  const [y, m, d] = day.split("-").map(Number) as [number, number, number];
  return new Date(Date.UTC(y, m - 1, d + days)).toISOString().slice(0, 10);
}

/** Noon UTC of a day: safe for calendar formatting in any zone from UTC-11 to UTC+11. */
function noon(day: string): Date {
  return new Date(`${day}T12:00:00Z`);
}

function format(day: string, options: Intl.DateTimeFormatOptions): string {
  return new Intl.DateTimeFormat(AR, { timeZone: "UTC", ...options }).format(noon(day));
}

/** «٢ جمادى الأولى ١٤٤٨» (Umm al-Qura). */
export function hijriText(day: string): string {
  return format(day, { calendar: "islamic-umalqura", day: "numeric", month: "long", year: "numeric" }).replace(/\s*هـ$/, "");
}

/** «١٣ أكتوبر ٢٠٢٦». */
export function gregorianText(day: string): string {
  return format(day, { calendar: "gregory", day: "numeric", month: "long", year: "numeric" });
}

/** «الثلاثاء». */
export function weekdayText(day: string): string {
  return format(day, { calendar: "gregory", weekday: "long" });
}

/** Hijri month number (9 = Ramadan). */
export function hijriMonth(day: string): number {
  const part = new Intl.DateTimeFormat("en-u-ca-islamic-umalqura", { timeZone: "UTC", month: "numeric" })
    .formatToParts(noon(day))
    .find((p) => p.type === "month");
  return Number(part?.value);
}

/** Both calendars, the user's primary first, joined by the Arabic comma. */
export function dualText(day: string, primary: "hijri" | "gregorian"): string {
  const parts = [hijriText(day), gregorianText(day)];
  return (primary === "hijri" ? parts : parts.reverse()).join("، ");
}

/** "HH:mm" of an instant in a zone, Latin digits (machine-readable). */
export function timeIn(timeZone: string, instant: Date): string {
  return new Intl.DateTimeFormat("en-GB", { timeZone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(instant);
}

/** Minutes `timeZone` is ahead of UTC at `instant` (180 for Riyadh). */
function offsetMinutes(timeZone: string, instant: Date): number {
  const name = new Intl.DateTimeFormat("en-US", { timeZone, timeZoneName: "longOffset" })
    .formatToParts(instant)
    .find((p) => p.type === "timeZoneName")?.value;
  const match = /GMT([+-])(\d{2}):?(\d{2})?/.exec(name ?? "");
  if (!match) return 0;
  const minutes = Number(match[2]) * 60 + Number(match[3] ?? 0);
  return match[1] === "-" ? -minutes : minutes;
}

/** A local day and "HH:mm" in a zone as ISO 8601 with its offset: "2026-10-13T17:00:00+03:00". */
export function localDateTime(day: string, time: string, timeZone: string): string {
  const [y, m, d] = day.split("-").map(Number) as [number, number, number];
  const [hh, mm] = time.split(":").map(Number) as [number, number];
  const wall = Date.UTC(y, m - 1, d, hh, mm);
  // The offset at the wall time read as UTC, then again at the instant it gives (daylight saving).
  let offset = offsetMinutes(timeZone, new Date(wall));
  offset = offsetMinutes(timeZone, new Date(wall - offset * 60_000));
  const sign = offset < 0 ? "-" : "+";
  const abs = Math.abs(offset);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${day}T${time}:00${sign}${pad(Math.floor(abs / 60))}:${pad(abs % 60)}`;
}

export interface HijriParts {
  year: number;
  month: number;
  day: number;
}

/** Umm al-Qura year, month and day of a local day. */
export function hijriParts(day: string): HijriParts {
  const parts = new Intl.DateTimeFormat("en-u-ca-islamic-umalqura-nu-latn", {
    timeZone: "UTC",
    year: "numeric",
    month: "numeric",
    day: "numeric",
  }).formatToParts(noon(day));
  const get = (type: string) => Number.parseInt(parts.find((p) => p.type === type)?.value ?? "", 10);
  return { year: get("year"), month: get("month"), day: get("day") };
}

const HIJRI_YEAR_DAYS = 354.367;
const HIJRI_MONTH_DAYS = 29.5306;

/**
 * The Gregorian day of an Umm al-Qura date. Without a year it is the next such date on or
 * after `from`. Null when the date does not exist (the 30th of a 29-day month).
 */
export function dayOfHijri(target: { year?: number | null; month: number; day: number }, from: string): string | null {
  if (target.month < 1 || target.month > 12 || target.day < 1 || target.day > 30) return null;
  const start = hijriParts(from);
  let year = target.year ?? start.year;
  if (target.year == null && (target.month < start.month || (target.month === start.month && target.day < start.day))) {
    year += 1;
  }
  const estimate = Math.round(
    (year - start.year) * HIJRI_YEAR_DAYS + (target.month - start.month) * HIJRI_MONTH_DAYS + (target.day - start.day),
  );
  // The mean-length estimate lands within a few days of the real date; search around it.
  for (const delta of [0, -1, 1, -2, 2, -3, 3, -4, 4]) {
    const candidate = addDays(from, estimate + delta);
    const p = hijriParts(candidate);
    if (p.year === year && p.month === target.month && p.day === target.day) return candidate;
  }
  return null;
}
