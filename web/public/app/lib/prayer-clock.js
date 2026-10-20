// The prayer clock on the web (PrayerClock.swift), from GET /v1/prayers: counting down to the next
// adhan, or for half an hour after one, the time since it; the clock time a prayer-anchored task
// falls at on its day; and the names of the calculation methods. Pure functions; tested in
// test/prayer-clock.test.mjs.
import { arabicNumber } from "./numbers.js";
import { PRAYERS } from "./prayer.js";

/** How long after an adhan the clock counts up before moving on (PrayerClock.elapsedWindow). */
export const ELAPSED_WINDOW = 30 * 60 * 1000;

export const METHOD_NAMES = {
  ummAlQura: "أم القرى",
  muslimWorldLeague: "رابطة العالم الإسلامي",
  egyptian: "الهيئة المصرية العامة للمساحة",
  karachi: "جامعة العلوم الإسلامية بكراتشي",
  dubai: "دبي",
  kuwait: "الكويت",
  qatar: "قطر",
  northAmerica: "الجمعية الإسلامية لأمريكا الشمالية",
};

export const MADHAB_NAMES = { shafi: "الجمهور", hanafi: "الحنفي" };

/** Every adhan in `days` (the API's days), in order: [{ prayer, at, date, time }]. */
export function adhans(days) {
  return days
    .flatMap((day) => PRAYERS.filter((p) => day.times?.[p]).map((prayer) => ({ prayer, at: day.times[prayer].at, time: day.times[prayer].time, date: day.date })))
    .sort((a, b) => a.at - b.at);
}

/** { kind: "since" | "until", prayer, at } at `now`, or null when the days hold no next adhan. */
export function clockState(days, now) {
  const all = adhans(days);
  const last = all.filter((a) => a.at <= now).at(-1);
  if (last && now - last.at < ELAPSED_WINDOW) return { kind: "since", prayer: last.prayer, at: last.at };
  const next = all.find((a) => a.at > now);
  return next ? { kind: "until", prayer: next.prayer, at: next.at } : null;
}

/** A timer as Text(.timer) shows it: «١:١٢:٠٥» past an hour, «١٢:٠٣» under one. */
export function timerText(ms) {
  const total = Math.max(0, Math.floor(Math.abs(ms) / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const two = (n) => arabicNumber(n).padStart(2, arabicNumber(0));
  return h > 0 ? `${arabicNumber(h)}:${two(m)}:${two(s)}` : `${arabicNumber(m)}:${two(s)}`;
}

/** The instant (ms) a task anchored to `prayer` with `offset` minutes falls at on `date`, or null. */
export function prayerInstant(days, date, prayer, offset = 0) {
  const day = days.find((d) => d.date === date);
  const at = day?.times?.[prayer]?.at;
  return Number.isFinite(at) ? at + (offset ?? 0) * 60_000 : null;
}

/** "HH:mm" of an instant in a time zone. */
export function clockIn(at, timeZone) {
  return new Intl.DateTimeFormat("en-GB", { timeZone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(new Date(at));
}
