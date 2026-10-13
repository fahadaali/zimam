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
