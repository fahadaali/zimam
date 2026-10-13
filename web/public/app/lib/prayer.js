// Prayer-linked times: «بعد العصر بـ٢٠ د», «قبل المغرب بـ١٠ د». The clock time is never shown in
// the chip, because it moves every day. Offsets are minutes: positive after the prayer, negative before.
import { arabicNumber } from "./numbers.js";

export const PRAYERS = ["fajr", "dhuhr", "asr", "maghrib", "isha"];

export const PRAYER_NAMES = {
  fajr: "الفجر",
  dhuhr: "الظهر",
  asr: "العصر",
  maghrib: "المغرب",
  isha: "العشاء",
};

/** How long, after «بـ»: "٢٠ د", "ساعة", "ساعتين", "٣ س", "١ س و١٥ د". */
export function durationPhrase(minutes) {
  const m = Math.abs(Math.trunc(minutes));
  if (m < 60) return `${arabicNumber(m)} د`;
  const hours = Math.floor(m / 60);
  const rest = m % 60;
  if (rest === 0 && hours === 1) return "ساعة";
  if (rest === 0 && hours === 2) return "ساعتين";
  if (rest === 0) return `${arabicNumber(hours)} س`;
  return `${arabicNumber(hours)} س و${arabicNumber(rest)} د`;
}

/** «بعد العصر بـ٢٠ د». Without an offset (or with zero) it reads «بعد العصر». Null for no prayer. */
export function prayerPhrase(prayer, offsetMinutes) {
  const name = PRAYER_NAMES[prayer];
  if (!name) return null;
  const offset = Number.isFinite(offsetMinutes) ? Math.trunc(offsetMinutes) : 0;
  if (offset === 0) return `بعد ${name}`;
  const relation = offset < 0 ? "قبل" : "بعد";
  const duration = durationPhrase(offset);
  // «بساعة» joins directly; numbers take «بـ» so the digit does not touch the letter.
  const joined = /^[٠-٩]/.test(duration) ? `بـ${duration}` : `ب${duration}`;
  return `${relation} ${name} ${joined}`;
}
