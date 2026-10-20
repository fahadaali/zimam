// Dates in Zimam: a task's due date is a local Gregorian day ("2026-10-13"). Every date is shown in
// Hijri (Umm al-Qura) and Gregorian together, the user's primary calendar first, separated by the
// Arabic comma «،» (never a middle dot: the Arabic zero is a dot). Near days read as one word.
// Pure functions: no DOM, no clock unless one is passed in.

const ISO = /^(\d{4})-(\d{2})-(\d{2})$/;
const DAY = 86_400_000;

// Formatting happens at UTC noon of the day, in UTC, so the viewer's time zone never shifts it.
const opts = (extra) => ({ timeZone: "UTC", day: "numeric", month: "long", ...extra });
const hijriFmt = new Intl.DateTimeFormat("ar-SA-u-ca-islamic-umalqura-nu-arab", opts());
const hijriYearFmt = new Intl.DateTimeFormat("ar-SA-u-ca-islamic-umalqura-nu-arab", opts({ year: "numeric" }));
const gregorianFmt = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-arab", opts());
const gregorianYearFmt = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-arab", opts({ year: "numeric" }));
const clockFmt = new Intl.DateTimeFormat("ar-SA-u-nu-arab", { timeZone: "UTC", hour: "numeric", minute: "2-digit" });
const weekdayFmt = new Intl.DateTimeFormat("ar-SA-u-ca-gregory-nu-arab", { timeZone: "UTC", weekday: "long" });

/** "2026-10-13" → a Date at 12:00 UTC that day. Throws on anything else. */
export function parseIsoDate(iso) {
  const m = ISO.exec(iso ?? "");
  if (!m) throw new RangeError(`Not an ISO date: ${iso}`);
  const date = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]), 12));
  if (date.getUTCDate() !== Number(m[3])) throw new RangeError(`Not a real date: ${iso}`);
  return date;
}

export function isIsoDate(value) {
  try {
    parseIsoDate(value);
    return true;
  } catch {
    return false;
  }
}

/** The viewer's local calendar day as "YYYY-MM-DD". */
export function localIsoDate(now = new Date()) {
  const pad = (n) => String(n).padStart(2, "0");
  return `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
}

export function addDays(iso, days) {
  return new Date(parseIsoDate(iso).getTime() + days * DAY).toISOString().slice(0, 10);
}

/** Whole days from `fromIso` to `toIso` (tomorrow is 1, yesterday −1). */
export function dayDiff(fromIso, toIso) {
  return Math.round((parseIsoDate(toIso).getTime() - parseIsoDate(fromIso).getTime()) / DAY);
}

/** "٢ جمادى الأولى" (with the year, "٢ جمادى الأولى ١٤٤٨ هـ", when asked). */
export function formatHijri(iso, { year = false } = {}) {
  return (year ? hijriYearFmt : hijriFmt).format(parseIsoDate(iso));
}

/** "١٣ أكتوبر" (or "١٣ أكتوبر ٢٠٢٦"). */
export function formatGregorian(iso, { year = false } = {}) {
  return (year ? gregorianYearFmt : gregorianFmt).format(parseIsoDate(iso));
}

export function weekdayName(iso) {
  return weekdayFmt.format(parseIsoDate(iso));
}

/**
 * Both calendars, primary first: "٢ جمادى الأولى، ١٣ أكتوبر".
 * Years are added only when the date falls in another Gregorian year than `today`.
 */
export function dualDate(iso, { primary = "hijri", today } = {}) {
  const year = today ? parseIsoDate(iso).getUTCFullYear() !== parseIsoDate(today).getUTCFullYear() : false;
  const hijri = formatHijri(iso, { year });
  const gregorian = formatGregorian(iso, { year });
  return primary === "gregorian" ? `${gregorian}، ${hijri}` : `${hijri}، ${gregorian}`;
}

/** Both calendars with their years, primary first: «٩ جمادى الأولى ١٤٤٨ هـ، ٢٠ أكتوبر ٢٠٢٦». */
export function dualDateWithYear(iso, { primary = "hijri" } = {}) {
  const hijri = formatHijri(iso, { year: true });
  const gregorian = formatGregorian(iso, { year: true });
  return primary === "gregorian" ? `${gregorian}، ${hijri}` : `${hijri}، ${gregorian}`;
}

/** "اليوم", "غداً", or the weekday for the rest of the coming week; null otherwise. */
export function relativeDay(iso, today) {
  const diff = dayDiff(today, iso);
  if (diff === 0) return "اليوم";
  if (diff === 1) return "غداً";
  if (diff >= 2 && diff <= 6) return weekdayName(iso);
  return null;
}

/** What a date chip says: the near-day word, or both calendars. */
export function dateLabel(iso, { today, primary = "hijri" }) {
  return relativeDay(iso, today) ?? dualDate(iso, { primary, today });
}

/**
 * Everything a DateChip needs for a due date. Past days are overdue and always show the full
 * dual date; near days show their word.
 */
export function dueChip(iso, { today, primary = "hijri" }) {
  const overdue = dayDiff(today, iso) < 0;
  return {
    text: overdue ? dualDate(iso, { primary, today }) : dateLabel(iso, { today, primary }),
    full: dualDate(iso, { primary, today }),
    tone: overdue ? "overdue" : "default",
  };
}

/** A day heading: the word for near days, with the dual date beneath; or the dual date alone. */
export function dayHeading(iso, { today, primary = "hijri" }) {
  const word = relativeDay(iso, today);
  const full = dualDate(iso, { primary, today });
  if (word === "اليوم" || word === "غداً") return { title: word, subtitle: `${weekdayName(iso)}، ${full}` };
  if (word) return { title: word, subtitle: full };
  return { title: full, subtitle: weekdayName(iso) };
}

/** A task's clock time, "14:30" → «٢:٣٠ م» (the app's TimeChip); null for anything else. */
export function timeLabel(hhmm) {
  const m = /^(\d{2}):(\d{2})$/.exec(hhmm ?? "");
  if (!m) return null;
  return clockFmt.format(new Date(Date.UTC(2026, 0, 1, Number(m[1]), Number(m[2]))));
}
