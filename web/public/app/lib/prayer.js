// Prayer-linked times: «بعد العصر بـ٢٠ د», «قبل المغرب بـ١٠ د», «عند الفجر», word for word as the
// app's PrayerPhrase (apple/ZimamKit/Sources/ZimamKit/DateText.swift) and the API's prayerPhrase.
// Offsets are minutes: positive after the prayer, negative before.
import { arabicNumber } from "./numbers.js";

export const PRAYERS = ["fajr", "dhuhr", "asr", "maghrib", "isha"];

export const PRAYER_NAMES = {
  fajr: "الفجر",
  dhuhr: "الظهر",
  asr: "العصر",
  maghrib: "المغرب",
  isha: "العشاء",
};

/** How long, joined to «بـ»: "بـ٢٠ د", "بساعة", "بساعتين", "بـ٣ س", "بـ٩٠ د" (whole hours only). */
export function durationPhrase(minutes) {
  const m = Math.abs(Math.trunc(minutes));
  if (m % 60 === 0) {
    const hours = m / 60;
    if (hours === 1) return "بساعة";
    if (hours === 2) return "بساعتين";
    return `بـ${arabicNumber(hours)} س`;
  }
  return `بـ${arabicNumber(m)} د`;
}

/** «بعد العصر بـ٢٠ د». Without an offset (or with zero) it reads «عند العصر». Null for no prayer. */
export function prayerPhrase(prayer, offsetMinutes) {
  const name = PRAYER_NAMES[prayer];
  if (!name) return null;
  const offset = Number.isFinite(offsetMinutes) ? Math.trunc(offsetMinutes) : 0;
  if (offset === 0) return `عند ${name}`;
  return `${offset < 0 ? "قبل" : "بعد"} ${name} ${durationPhrase(offset)}`;
}
