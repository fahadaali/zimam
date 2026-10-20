import { CalculationMethod, Coordinates, Madhab, PrayerTimes } from "adhan";
import { hijriMonth, timeIn } from "./dates";
import type { Settings } from "./schemas";

const METHODS = {
  ummAlQura: CalculationMethod.UmmAlQura,
  muslimWorldLeague: CalculationMethod.MuslimWorldLeague,
  egyptian: CalculationMethod.Egyptian,
  karachi: CalculationMethod.Karachi,
  dubai: CalculationMethod.Dubai,
  kuwait: CalculationMethod.Kuwait,
  qatar: CalculationMethod.Qatar,
  northAmerica: CalculationMethod.NorthAmerica,
} as const;

export type PrayerTimesOfDay = Record<"fajr" | "dhuhr" | "asr" | "maghrib" | "isha", string>;

/** The instants of a day's prayers at the saved location, or null without one. */
export function prayerInstants(day: string, settings: Settings): Record<keyof PrayerTimesOfDay, Date> | null {
  if (!settings.location) return null;
  const params = METHODS[settings.prayerMethod]();
  params.madhab = settings.asrMadhab === "hanafi" ? Madhab.Hanafi : Madhab.Shafi;
  // Umm al-Qura sets Isha 120 minutes after Maghrib in Ramadan instead of 90.
  if (settings.prayerMethod === "ummAlQura" && hijriMonth(day) === 9) params.ishaInterval = 120;
  const [y, m, d] = day.split("-").map(Number) as [number, number, number];
  // adhan reads the calendar day from the Date's local fields; Workers run in UTC.
  const times = new PrayerTimes(new Coordinates(settings.location.latitude, settings.location.longitude), new Date(y, m - 1, d), params);
  return { fajr: times.fajr, dhuhr: times.dhuhr, asr: times.asr, maghrib: times.maghrib, isha: times.isha };
}

/** Local "HH:mm" prayer times for a day, or null without a saved location. */
export function prayerTimes(day: string, settings: Settings): PrayerTimesOfDay | null {
  const times = prayerInstants(day, settings);
  if (!times) return null;
  const at = (instant: Date) => timeIn(settings.timeZone, instant);
  return { fajr: at(times.fajr), dhuhr: at(times.dhuhr), asr: at(times.asr), maghrib: at(times.maghrib), isha: at(times.isha) };
}

const PRAYER_NAMES = { fajr: "الفجر", dhuhr: "الظهر", asr: "العصر", maghrib: "المغرب", isha: "العشاء" } as const;

/** «بعد العصر بـ٢٠ د», «قبل المغرب بـ١٠ د», «عند الفجر», «بعد الظهر بساعة» — as the app's prayer chip says it. */
export function prayerPhrase(prayer: keyof typeof PRAYER_NAMES, offsetMinutes: number): string {
  const name = PRAYER_NAMES[prayer];
  if (offsetMinutes === 0) return `عند ${name}`;
  const direction = offsetMinutes > 0 ? "بعد" : "قبل";
  const minutes = Math.abs(offsetMinutes);
  const number = (n: number) => new Intl.NumberFormat("ar-SA", { useGrouping: false }).format(n);
  let duration: string;
  if (minutes % 60 === 0) {
    const hours = minutes / 60;
    duration = hours === 1 ? "بساعة" : hours === 2 ? "بساعتين" : `بـ${number(hours)} س`;
  } else {
    duration = `بـ${number(minutes)} د`;
  }
  return `${direction} ${name} ${duration}`;
}
